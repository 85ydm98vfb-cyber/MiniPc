#!/usr/bin/env python3
"""Watch Time - tracker personal de seriale si filme, multi-utilizator.
Doar Python 3 standard (fara pip). Date: SQLite in ./data, informatii: TMDB."""
import base64
import datetime
import io
import zipfile
import hashlib
import hmac
import ipaddress
import json
import mimetypes
import os
import platform
import re
import secrets
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import imdb
import push

BASE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(BASE, "config.json")
DB_PATH = os.path.join(BASE, "data", "watchtime.db")
STATIC = os.path.join(BASE, "static")
TMDB = "https://api.themoviedb.org/3"
COOKIE = "wt_session"
START = time.time()
mimetypes.add_type("application/manifest+json", ".webmanifest")


def load_cfg():
    cfg = {"tmdb_key": "", "language": "en-US", "port": 8765, "host": "0.0.0.0",
           "session_days": 365, "max_login_fails": 8,
           "notify_times": ["11:30", "18:30"], "timezone": "", "push_contact": "mailto:watchtime@example.com",
           "lan_networks": ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "127.0.0.0/8", "::1/128", "fe80::/10"]}
    if os.path.exists(CFG_PATH):
        with open(CFG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    cfg["tmdb_key"] = os.environ.get("TMDB_KEY", cfg["tmdb_key"]).strip()
    return cfg


CFG = load_cfg()
LAN = [ipaddress.ip_network(n) for n in CFG["lan_networks"]]


def sess_days():
    return max(1, int(CFG.get("session_days") or 365))
os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
DB = sqlite3.connect(DB_PATH, check_same_thread=False)
DB.row_factory = sqlite3.Row
LOCK = threading.Lock()
DB.executescript("""
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE COLLATE NOCASE,
  pw TEXT NOT NULL, is_admin INTEGER DEFAULT 0, created_at TEXT);
CREATE TABLE IF NOT EXISTS sessions(
  token TEXT PRIMARY KEY, user_id INTEGER NOT NULL, created_at TEXT, expires REAL);
CREATE TABLE IF NOT EXISTS items(
  user_id INTEGER NOT NULL, type TEXT NOT NULL, tmdb_id INTEGER NOT NULL,
  title TEXT, poster TEXT, year TEXT, status TEXT, prev_status TEXT, rewatch INTEGER DEFAULT 0,
  rating INTEGER, added_at TEXT, runtime INTEGER,
  PRIMARY KEY(user_id, type, tmdb_id));
CREATE TABLE IF NOT EXISTS plays(
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, type TEXT NOT NULL,
  tmdb_id INTEGER NOT NULL, season INTEGER DEFAULT 0, episode INTEGER DEFAULT 0,
  watched_at TEXT, runtime INTEGER);
CREATE INDEX IF NOT EXISTS plays_idx ON plays(user_id, type, tmdb_id);
CREATE TABLE IF NOT EXISTS cache(key TEXT PRIMARY KEY, body TEXT, fetched REAL);
CREATE TABLE IF NOT EXISTS push_subs(
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, endpoint TEXT UNIQUE,
  p256dh TEXT, auth TEXT, device TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS notify_sent(
  user_id INTEGER, kind TEXT, tmdb_id INTEGER, season INTEGER, episode INTEGER, sent_at TEXT,
  PRIMARY KEY(user_id, kind, tmdb_id, season, episode));
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS notifs(
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, created_at TEXT, kind TEXT,
  tmdb_id INTEGER, season INTEGER, episode INTEGER, title TEXT, body TEXT, url TEXT, poster TEXT, read INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS notifs_idx ON notifs(user_id, id);
""")
_ucols = [r[1] for r in DB.execute("PRAGMA table_info(users)")]
for _c, _def in (("lang", "TEXT"), ("notify_eps", "INTEGER DEFAULT 1"), ("notify_movies", "INTEGER DEFAULT 1"),
                 ("notify_compact", "INTEGER DEFAULT 1"), ("notify_format", "INTEGER DEFAULT 2"), ("notify_times", "TEXT")):
    if _c not in _ucols:
        DB.execute(f"ALTER TABLE users ADD COLUMN {_c} {_def}")
DB.commit()
_ncols = [r[1] for r in DB.execute("PRAGMA table_info(notifs)")]
if "pushed" not in _ncols:
    DB.execute("ALTER TABLE notifs ADD COLUMN pushed INTEGER DEFAULT 0")
    DB.execute("UPDATE notifs SET pushed=1")        # ce exista deja a fost deja trimis
if "name" not in _ncols:
    DB.execute("ALTER TABLE notifs ADD COLUMN name TEXT")
DB.commit()

TV_STATUSES = ("watching", "plan", "completed", "stopped")
MOVIE_STATUSES = ("watchlist", "watched")
FAILS = {}  # ip -> [timestamps] pentru limitarea incercarilor de logare


MESSAGES = {
    "bad_username": ("Numele de utilizator: 2-32 caractere, doar litere, cifre, punct, minus sau _", "Username: 2-32 characters, only letters, digits, dot, dash or _"),
    "short_password": ("Parola trebuie sa aiba minim 6 caractere", "Password must be at least 6 characters"),
    "no_tmdb_key": ("Lipseste cheia TMDB. Pune-o in config.json si reporneste serverul.", "The TMDB key is missing. The admin can add it in Settings."),
    "tmdb_404": ("Titlul nu exista in TMDB", "This title does not exist on TMDB"),
    "tmdb_bad_key": ("Cheia TMDB din config.json nu este valida", "The TMDB key is not valid"),
    "tmdb_http": ("TMDB a raspuns cu eroarea {code}", "TMDB returned error {code}"),
    "tmdb_offline": ("Nu pot contacta TMDB. Verifica internetul mini PC-ului.", "Can't reach TMDB. Check the mini PC's internet connection."),
    "bad_type": ("Tip invalid", "Invalid type"),
    "no_route": ("Ruta necunoscuta", "Unknown route"),
    "admin_only": ("Doar adminul poate face asta", "Only the admin can do this"),
    "admin_no_lists": ("Contul admin nu are liste proprii. Foloseste un cont normal.", "The admin account has no lists. Use a regular account."),
    "user_exists": ("Exista deja un utilizator cu acest nume", "A user with this name already exists"),
    "no_self_delete": ("Nu iti poti sterge propriul cont", "You can't delete your own account"),
    "bad_lang": ("Limba necunoscuta", "Unknown language"),
    "bad_network": ("Retea invalida: {err}", "Invalid network: {err}"),
    "need_network": ("Trebuie cel putin o retea de acasa", "At least one home network is required"),
    "self_lockout": ("Lista nu include reteaua de pe care esti conectat acum ({ip}). Te-ai bloca singur.", "The list doesn't include the network you're connected from ({ip}). You would lock yourself out."),
    "no_action": ("Actiune necunoscuta", "Unknown action"),
    "wrong_old_pw": ("Parola actuala e gresita", "Current password is wrong"),
    "bad_request": ("Cerere invalida", "Invalid request"),
    "bad_status": ("Status invalid", "Invalid status"),
    "rewatch_first": ("Mai intai vezi toate episoadele aparute, apoi poti incepe rewatch", "Watch all aired episodes first, then you can start a rewatch"),
    "login_needed": ("Trebuie sa te autentifici", "You need to sign in"),
    "admin_wifi": ("Contul admin se poate folosi doar din Wi-Fi-ul de acasa", "The admin account only works from the home Wi-Fi"),
    "setup_done": ("Configurarea a fost deja facuta", "Setup has already been done"),
    "setup_wifi": ("Configurarea initiala se face doar din Wi-Fi-ul de acasa", "Initial setup only works from the home Wi-Fi"),
    "too_many": ("Prea multe incercari gresite. Mai incearca peste 15 minute.", "Too many failed attempts. Try again in 15 minutes."),
    "push_unavailable": ("Notificarile nu sunt disponibile pe server (lipseste pachetul py3-cryptography)",
                         "Notifications are not available on the server (package py3-cryptography is missing)"),
    "push_none": ("Nu ai niciun dispozitiv abonat la notificari", "You have no device subscribed to notifications"),
    "import_running": ("Un import este deja in curs", "An import is already running"),
    "import_bad_file": ("Fisierul nu este un export valid (JSON sau ZIP cu JSON)", "The file is not a valid export (JSON or ZIP of JSON)"),
    "import_nothing": ("Nu am gasit in fisier seriale sau filme de importat", "No shows or movies to import were found in the file"),
    "import_too_big": ("Fisierul e prea mare (maxim 60 MB)", "The file is too large (60 MB max)"),
    "bad_login": ("Utilizator sau parola gresita", "Wrong username or password"),
}


class ApiError(Exception):
    def __init__(self, code, key, **kw):
        super().__init__(key)
        self.code, self.key, self.kw = code, key, kw

    def text(self, lang):
        ro, en = MESSAGES.get(self.key, (self.key, self.key))
        return (en if lang == "en" else ro).format(**{k: str(v) for k, v in self.kw.items()})


# ---------- utilitare ----------
def local_now():
    tz = CFG.get("timezone") or ""
    if tz:
        try:
            from zoneinfo import ZoneInfo
            return datetime.datetime.now(ZoneInfo(tz)).replace(tzinfo=None)
        except Exception:
            pass
    return datetime.datetime.now()


def now():
    return local_now().isoformat(timespec="seconds")


def today():
    return local_now().date().isoformat()


def aired(date):
    return bool(date) and date <= today()


def year_of(d):
    return (d or "")[:4]


def q(sql, args=()):
    with LOCK:
        return [dict(r) for r in DB.execute(sql, args).fetchall()]


def q1(sql, args=()):
    r = q(sql, args)
    return r[0] if r else None


def x(sql, args=()):
    with LOCK:
        cur = DB.execute(sql, args)
        DB.commit()
        return cur.lastrowid


def xmany(sql, rows):
    with LOCK:
        DB.executemany(sql, rows)
        DB.commit()


# ---------- parole si sesiuni ----------
def hash_pw(pw):
    salt = secrets.token_bytes(16)
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, 200_000)
    return f"pbkdf2$200000${salt.hex()}${h.hex()}"


def check_pw(pw, stored):
    try:
        _, it, salt, h = stored.split("$")
        calc = hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt), int(it))
        return hmac.compare_digest(calc.hex(), h)
    except Exception:
        return False


def valid_username(u):
    if not re.fullmatch(r"[A-Za-z0-9._-]{2,32}", u or ""):
        raise ApiError(400, "bad_username")


def valid_password(p):
    if len(p or "") < 6:
        raise ApiError(400, "short_password")


def new_session(uid):
    tok = secrets.token_urlsafe(32)
    x("INSERT INTO sessions VALUES(?,?,?,?)", (tok, uid, now(), time.time() + sess_days() * 86400))
    return tok


# ---------- TMDB (cu cache comun) ----------
TMDB_SEM = threading.BoundedSemaphore(8)        # cel mult 8 cereri simultane spre TMDB
REFRESH_POOL = ThreadPoolExecutor(3)             # reimprospatare cache in fundal
INFLIGHT, INFLIGHT_LOCK = set(), threading.Lock()


def _tmdb_fetch(path, params, ck):
    key = CFG["tmdb_key"]
    params = dict(params)
    headers = {"Accept": "application/json"}
    if len(key) > 40:
        headers["Authorization"] = "Bearer " + key
    else:
        params["api_key"] = key
    req = urllib.request.Request(TMDB + path + "?" + urllib.parse.urlencode(params), headers=headers)
    for attempt in range(2):
        try:
            with TMDB_SEM:
                with urllib.request.urlopen(req, timeout=10) as r:
                    body = r.read().decode("utf-8")
            x("INSERT OR REPLACE INTO cache(key, body, fetched) VALUES(?,?,?)", (ck, body, time.time()))
            return body
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt == 0:   # prea multe cereri: asteapta putin si mai incearca o data
                time.sleep(1.5)
                continue
            raise


def _refresh_bg(path, params, ck):
    with INFLIGHT_LOCK:
        if ck in INFLIGHT:
            return
        INFLIGHT.add(ck)

    def job():
        try:
            _tmdb_fetch(path, params, ck)
        except Exception:
            pass
        finally:
            with INFLIGHT_LOCK:
                INFLIGHT.discard(ck)
    REFRESH_POOL.submit(job)


def tmdb(path, params=None, ttl=6 * 3600, sync=False):
    """Date TMDB cu cache. Daca exista in cache (chiar si vechi), raspunde imediat;
    datele vechi se reimprospateaza in fundal, deci aplicatia nu asteapta dupa TMDB."""
    if not CFG["tmdb_key"]:
        raise ApiError(503, "no_tmdb_key")
    params = dict(params or {})
    params.setdefault("language", CFG["language"])
    ck = path + "?" + urllib.parse.urlencode(sorted(params.items()))
    row = q1("SELECT body, fetched FROM cache WHERE key=?", (ck,))
    if row and ttl:
        if time.time() - row["fetched"] < ttl:
            return json.loads(row["body"])
        if not sync:
            _refresh_bg(path, params, ck)
            return json.loads(row["body"])
    try:
        return json.loads(_tmdb_fetch(path, params, ck))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise ApiError(404, "tmdb_404")
        if row:
            return json.loads(row["body"])
        if e.code == 401:
            raise ApiError(502, "tmdb_bad_key")
        raise ApiError(502, "tmdb_http", code=e.code)
    except (urllib.error.URLError, TimeoutError, OSError):
        if row:
            return json.loads(row["body"])
        raise ApiError(502, "tmdb_offline")


# cererile grele identice (acelasi user, acelasi ecran) nu se mai calculeaza de doua ori in paralel
CO, CO_LOCK = {}, threading.Lock()


def coalesce(key, fn):
    with CO_LOCK:
        ent = CO.get(key)
        leader = ent is None
        if leader:
            ent = CO[key] = {"ev": threading.Event()}
    if not leader:
        if not ent["ev"].wait(90):
            raise ApiError(502, "tmdb_offline")
        if "err" in ent:
            raise ent["err"]
        return ent["res"]
    try:
        ent["res"] = fn()
        return ent["res"]
    except Exception as e:
        ent["err"] = e
        raise
    finally:
        ent["ev"].set()
        with CO_LOCK:
            CO.pop(key, None)


def tv_details(sid):
    return tmdb(f"/tv/{sid}")


def season_details(sid, n):
    return tmdb(f"/tv/{sid}/season/{n}")


def ep_out(ep):
    return {"season": ep.get("season_number"), "episode": ep.get("episode_number"),
            "name": ep.get("name") or f"Episodul {ep.get('episode_number')}",
            "air_date": ep.get("air_date"), "runtime": ep.get("runtime"),
            "still": ep.get("still_path"), "overview": ep.get("overview") or ""}


# ---------- vizionari (plays) ----------
def counts(u, sid):
    return {(r["season"], r["episode"]): r["c"] for r in q(
        "SELECT season, episode, COUNT(*) c FROM plays WHERE user_id=? AND type='tv' AND tmdb_id=? GROUP BY season, episode",
        (u, sid))}


def add_plays(u, t, i, rows):
    ts = now()
    xmany("INSERT INTO plays(user_id,type,tmdb_id,season,episode,watched_at,runtime) VALUES(?,?,?,?,?,?,?)",
          [(u, t, i, s, e, ts, rt) for s, e, rt in rows])


def remove_plays(u, t, i, s, e, k=1):
    x("""DELETE FROM plays WHERE id IN (SELECT id FROM plays WHERE user_id=? AND type=? AND tmdb_id=?
         AND season=? AND episode=? ORDER BY id DESC LIMIT ?)""", (u, t, i, s, e, k))


def real_seasons(d):
    return sorted((s for s in d.get("seasons", []) if (s.get("season_number") or 0) > 0),
                  key=lambda s: s["season_number"])


def aired_total(d):
    last = d.get("last_episode_to_air") or {}
    ls, le = last.get("season_number") or 0, last.get("episode_number") or 0
    seasons = real_seasons(d)
    if ls > 0:
        return sum(s.get("episode_count", 0) for s in seasons if s["season_number"] < ls) + le
    return sum(s.get("episode_count", 0) for s in seasons if aired(s.get("air_date")))


def th_of(it):
    """Pragul de vizionari: 1 normal, N in timpul unui rewatch (runda N)."""
    return it["rewatch"] if it and it["status"] == "rewatching" and it["rewatch"] else 1


def progress(u, sid, d, th=1, cnt=None):
    cnt = counts(u, sid) if cnt is None else cnt
    w = sum(1 for (s, _), c in cnt.items() if s > 0 and c >= th)
    a = aired_total(d)
    return min(w, a) if a else w, a, max(0, a - w)


def next_episode(u, sid, d, th=1, cnt=None):
    last = d.get("last_episode_to_air") or {}
    ls, le = last.get("season_number") or 0, last.get("episode_number") or 0
    if not ls:
        return None
    cnt = counts(u, sid) if cnt is None else cnt
    per = {}
    for (s, _), c in cnt.items():
        if c >= th:
            per[s] = per.get(s, 0) + 1
    for sea in real_seasons(d):
        n = sea["season_number"]
        if n > ls:
            break
        if per.get(n, 0) >= (sea.get("episode_count", 0) if n < ls else le):
            continue
        for ep in season_details(sid, n).get("episodes", []):
            c = cnt.get((n, ep["episode_number"]), 0)
            if c >= th:
                continue
            if not aired(ep.get("air_date")):
                break
            return dict(ep_out(ep), count=c)
    return None


def get_item(u, t, i):
    return q1("SELECT * FROM items WHERE user_id=? AND type=? AND tmdb_id=?", (u, t, i))


def ensure_item(u, t, i, status=None):
    it = get_item(u, t, i)
    if it:
        return it
    d = tv_details(i) if t == "tv" else tmdb(f"/movie/{i}")
    status = status or ("watching" if t == "tv" else "watchlist")
    x("""INSERT INTO items(user_id,type,tmdb_id,title,poster,year,status,added_at,runtime)
         VALUES(?,?,?,?,?,?,?,?,?)""",
      (u, t, i, d.get("name") or d.get("title") or "?", d.get("poster_path"),
       year_of(d.get("first_air_date") or d.get("release_date")), status, now(), d.get("runtime")))
    return get_item(u, t, i)


def end_rewatch(u, sid, it, restore=False):
    """restore=True: rewatch anulat (revine la statusul de dinainte); altfel rewatch terminat -> Terminat."""
    new = (it["prev_status"] if it["prev_status"] in TV_STATUSES else "watching") if restore else "completed"
    x("UPDATE items SET status=?, rewatch=0, prev_status=NULL WHERE user_id=? AND type='tv' AND tmdb_id=?", (new, u, sid))
    return new


def first_episode(d):
    seas = [s for s in real_seasons(d) if s.get("episode_count")]
    return (seas[0]["season_number"], 1) if seas else None


def auto_rewatch(u, sid, season, episode):
    it = get_item(u, "tv", sid)
    if not it or it["status"] == "rewatching":
        return
    d = tv_details(sid)
    if (season, episode) != first_episode(d):
        return
    cnt = counts(u, sid)
    k = cnt.get((season, episode), 0)
    if k < 2:
        return
    w, a, rem = progress(u, sid, d, k - 1, cnt)
    if a and rem == 0:        # runda anterioara completa -> incepe runda k
        x("UPDATE items SET status='rewatching', prev_status=?, rewatch=? WHERE user_id=? AND type='tv' AND tmdb_id=?",
          (it["status"] if it["status"] in TV_STATUSES else "completed", k, u, sid))


def undo_auto_rewatch(u, sid):
    """Daca ai scos vizionarea care pornise runda si nu mai exista niciun episod vazut de N ori, runda se anuleaza."""
    it = get_item(u, "tv", sid)
    if it and it["status"] == "rewatching" and it["rewatch"]:
        if not any(c >= it["rewatch"] for (s_, _), c in counts(u, sid).items() if s_ > 0):
            end_rewatch(u, sid, it, restore=True)


def after_watch(u, sid):
    """Actualizeaza automat statusul dupa marcarea episoadelor."""
    d = tv_details(sid)
    it = get_item(u, "tv", sid)
    cnt = counts(u, sid)
    th = th_of(it)
    w, a, rem = progress(u, sid, d, th, cnt)
    done = False
    st = it["status"] if it else None
    if it and st == "rewatching":
        if a and rem == 0:
            st, done = end_rewatch(u, sid, it), True
            w, a, rem = progress(u, sid, d, 1, cnt)
    elif it:
        new = st
        if rem == 0 and a > 0 and d.get("status") in ("Ended", "Canceled"):
            new = "completed"
        elif st in ("plan", "completed", "stopped") and rem > 0 and w > 0:
            new = "watching"
        if st in ("watching", "completed") and not any(cnt.values()):   # toate episoadele debifate -> De vazut
            new = "plan"
        if new != st:
            x("UPDATE items SET status=? WHERE user_id=? AND type='tv' AND tmdb_id=?", (new, u, sid))
            st = new
    return {"status": st, "watched": w, "aired": a, "remaining": rem, "rewatch_done": done}


def lib_map(u):
    return {(r["type"], r["tmdb_id"]): r["status"] for r in q("SELECT type, tmdb_id, status FROM items WHERE user_id=?", (u,))}


def card(r, t, lib):
    return {"type": t, "id": r["id"], "title": r.get("name") or r.get("title"),
            "year": year_of(r.get("first_air_date") or r.get("release_date")),
            "poster": r.get("poster_path"), "overview": r.get("overview") or "",
            "rating": round(r.get("vote_average") or 0, 1), "status": lib.get((t, r["id"]))}


# ---------- GET ----------
def api_search(u, qs):
    text = (qs.get("q") or [""])[0].strip()
    t = (qs.get("type") or ["tv"])[0]
    if t not in ("tv", "movie"):
        raise ApiError(400, "bad_type")
    if not text:
        return {"results": []}
    page = max(1, int((qs.get("page") or ["1"])[0]))
    d = tmdb(f"/search/{t}", {"query": text, "include_adult": "false", "page": str(page)}, ttl=3600)
    lib = lib_map(u)
    return {"results": [card(r, t, lib) for r in d.get("results", [])],
            "page": page, "total_pages": min(d.get("total_pages") or 1, 20)}


def api_discover(u, qs):
    t = (qs.get("type") or ["tv"])[0]
    if t not in ("tv", "movie"):
        raise ApiError(400, "bad_type")
    lib = lib_map(u)
    genre = (qs.get("genre") or [""])[0]
    section = (qs.get("section") or [""])[0]
    if section:
        paths = {"trending": f"/trending/{t}/week", "popular": f"/{t}/popular", "top_rated": f"/{t}/top_rated",
                 "on_air": "/tv/on_the_air", "upcoming": "/movie/upcoming"}
        if section not in paths:
            raise ApiError(400, "bad_request")
        page = int((qs.get("page") or ["1"])[0])
        d = tmdb(paths[section], {"page": str(page)}, ttl=3 * 3600)
        return {"results": [card(r, t, lib) for r in d.get("results", [])],
                "page": page, "total_pages": min(d.get("total_pages") or 1, 30)}
    sort = (qs.get("sort") or ["rec"])[0]      # fara sortare -> pagina cu sectiuni (Recomandate)
    if genre or sort not in ("", "rec"):
        page = int((qs.get("page") or ["1"])[0])
        date = "primary_release_date" if t == "movie" else "first_air_date"
        # sortare -> (sort_by TMDB, minim de voturi ca sa nu apara titluri necunoscute)
        opts = {"pop": ("popularity.desc", 50), "rating": ("vote_average.desc", 300),
                "new": (f"{date}.desc", 20), "old": (f"{date}.asc", 100),
                "title": ("title.asc" if t == "movie" else "name.asc", 200), "votes": ("vote_count.desc", 0)}
        sort_by, min_votes = opts.get(sort, opts["pop"])
        params = {"sort_by": sort_by, "vote_count.gte": str(min_votes), "include_adult": "false", "page": str(page)}
        if genre:
            params["with_genres"] = genre
        if sort == "new":
            params[f"{date}.lte"] = today()          # doar titluri deja aparute
        d = tmdb(f"/discover/{t}", params)
        return {"results": [card(r, t, lib) for r in d.get("results", [])],
                "page": page, "total_pages": min(d.get("total_pages") or 1, 50)}
    secs = [("trending", f"/trending/{t}/week"), ("popular", f"/{t}/popular"), ("top_rated", f"/{t}/top_rated"),
            ("on_air", "/tv/on_the_air") if t == "tv" else ("upcoming", "/movie/upcoming")]

    def load(sec):
        try:
            return {"key": sec[0], "items": [card(r, t, lib) for r in tmdb(sec[1], ttl=3 * 3600).get("results", [])]}
        except ApiError:
            return {"key": sec[0], "items": []}
    with ThreadPoolExecutor(4) as ex:
        sections = list(ex.map(load, secs))
    genres = tmdb(f"/genre/{t}/list", ttl=7 * 86400).get("genres", [])
    return {"sections": sections, "genres": genres}


def trailer(t, i):
    """Cheia YouTube a trailerului oficial (TMDB), sau None -> interfata cauta pe YouTube."""
    try:
        lang2 = CFG["language"][:2]
        vids = tmdb(f"/{t}/{i}/videos", {"language": CFG["language"], "include_video_language": f"{lang2},en,null"},
                    ttl=7 * 86400).get("results", [])
    except ApiError:
        return None
    yt = [v for v in vids if v.get("site") == "YouTube" and v.get("key")]
    for pick in (lambda v: v.get("type") == "Trailer" and v.get("official"), lambda v: v.get("type") == "Trailer",
                 lambda v: v.get("type") == "Teaser", lambda v: True):
        hit = [v for v in yt if pick(v)]
        if hit:
            hit.sort(key=lambda v: (v.get("iso_639_1") != "en", v.get("published_at") or ""))
            return hit[0]["key"]
    return None


IMDB = imdb.Ratings(os.path.join(BASE, "data"), log=lambda m: print(f"{now()} {m}", flush=True))


def imdb_info(tconst):
    if not tconst:
        return None
    r = IMDB.get(tconst)
    return {"id": tconst, "rating": r["rating"], "votes": r["votes"]} if r else {"id": tconst, "rating": None, "votes": None}


def tv_imdb_id(sid):
    try:
        return tmdb(f"/tv/{sid}/external_ids", ttl=30 * 86400).get("imdb_id")
    except ApiError:
        return None


def api_tv_imdb(sid):
    tid = tv_imdb_id(sid)
    if not tid:
        return {"seasons": [], "state": "no_id"}
    rows = IMDB.episodes(tid)
    if rows is None:
        return {"seasons": [], "state": "pending"}
    seas = {}
    for sn, en, r, v, _ in rows:
        if sn > 0:
            seas.setdefault(sn, []).append({"e": en, "r": r, "v": v})
    out = []
    for sn in sorted(seas):
        eps = sorted(seas[sn], key=lambda e: e["e"])
        out.append({"n": sn, "eps": eps, "avg": round(sum(e["r"] for e in eps) / len(eps), 1)})
    return {"seasons": out, "state": "ok", "imdb": tid}


def api_tv(u, sid):
    d = tv_details(sid)
    it = get_item(u, "tv", sid)
    th = th_of(it)
    cnt = counts(u, sid)
    per = {}
    for (s, _), c in cnt.items():
        if c >= th:
            per[s] = per.get(s, 0) + 1
    w, a, rem = progress(u, sid, d, th, cnt)
    w1, _, rem1 = progress(u, sid, d, 1, cnt)
    seasons = sorted(d.get("seasons", []), key=lambda s: (s.get("season_number") == 0, s.get("season_number")))
    last = d.get("last_episode_to_air") or {}
    ls, le = last.get("season_number") or 0, last.get("episode_number") or 0

    def aired_in(s):
        n = s["season_number"]
        if n == 0 or not ls:
            return s.get("episode_count", 0) if aired(s.get("air_date")) else 0
        return s.get("episode_count", 0) if n < ls else (le if n == ls else 0)
    return {
        "id": sid, "title": d.get("name"), "poster": d.get("poster_path"), "backdrop": d.get("backdrop_path"),
        "year": year_of(d.get("first_air_date")), "overview": d.get("overview") or "", "status": d.get("status"),
        "networks": [n["name"] for n in d.get("networks", [])], "genres": [g["name"] for g in d.get("genres", [])],
        "seasons": [{"n": s["season_number"], "name": s.get("name"), "episode_count": s.get("episode_count", 0),
                     "aired": aired_in(s), "watched": per.get(s["season_number"], 0)} for s in seasons],
        "item": it and {"status": it["status"], "rating": it["rating"], "rewatch": it["rewatch"]},
        "watched": w, "aired": a, "remaining": rem, "seen_all": a > 0 and rem1 == 0 and w1 > 0,
        "total_plays": sum(c for (s, _), c in cnt.items() if s > 0),
        "next_air": ep_out(d["next_episode_to_air"]) if d.get("next_episode_to_air") else None,
        "next": next_episode(u, sid, d, th, cnt) if it else None,
        "trailer": trailer("tv", sid),
        "imdb": imdb_info(tv_imdb_id(sid)),
    }


def api_season(u, sid, n):
    s = season_details(sid, n)
    th = th_of(get_item(u, "tv", sid))
    cnt = counts(u, sid)
    out = []
    for e in s.get("episodes", []):
        c = cnt.get((n, e["episode_number"]), 0)
        out.append(dict(ep_out(e), count=c, done=c >= th, aired=aired(e.get("air_date"))))
    by_se = {}
    tid = tv_imdb_id(sid) if IMDB.conn else None
    for sn, en, r, v, eid in (IMDB.episodes(tid) or []) if tid else []:
        by_se[(sn, en)] = (r, v, eid)
    if by_se:
        for ep in out:
            hit = by_se.get((n, ep["episode"]))
            if hit:
                ep["imdb"] = {"id": hit[2], "rating": hit[0], "votes": hit[1]}
    elif IMDB.conn:  # nota IMDb pe episod (ID-ul IMDb al episodului vine de la TMDB, nota din setul IMDb local)
        def rate(ep):
            if not ep["aired"]:
                return
            try:
                tid = tmdb(f"/tv/{sid}/season/{n}/episode/{ep['episode']}/external_ids", ttl=30 * 86400).get("imdb_id")
            except ApiError:
                return
            ep["imdb"] = imdb_info(tid)
        with ThreadPoolExecutor(6) as ex:
            list(ex.map(rate, out))
    return {"episodes": out, "th": th}


def movie_plays(u, mid):
    return q1("SELECT COUNT(*) c, MAX(watched_at) last FROM plays WHERE user_id=? AND type='movie' AND tmdb_id=?", (u, mid))


def api_movie(u, mid):
    d = tmdb(f"/movie/{mid}")
    it = get_item(u, "movie", mid)
    p = movie_plays(u, mid)
    return {"id": mid, "title": d.get("title"), "poster": d.get("poster_path"), "backdrop": d.get("backdrop_path"),
            "year": year_of(d.get("release_date")), "overview": d.get("overview") or "", "runtime": d.get("runtime"),
            "genres": [g["name"] for g in d.get("genres", [])], "release_date": d.get("release_date"),
            "item": it and {"status": it["status"], "rating": it["rating"]}, "plays": p["c"], "last_watched": p["last"],
            "trailer": trailer("movie", mid), "imdb": imdb_info(d.get("imdb_id")),
            "collection": movie_collection(u, d, mid)}


# ---------- acelasi univers (Wikidata: univers fictional / francriza) ----------
# Wikidata prin API-ul obisnuit (www.wikidata.org/w/api.php), nu prin serviciul SPARQL (limitat des la 1 cerere/min)
WD_API = "https://www.wikidata.org/w/api.php"
WD_HEADERS = {"User-Agent": "WatchTime/1.0 (self-hosted personal app; python-urllib)"}
WD_LOCK = threading.Lock()
WD_BLOCK = [0.0]            # dupa un 429, asteptam cat cere serverul


def wd_get(params):
    if time.time() < WD_BLOCK[0]:
        raise RuntimeError("wikidata: pauza dupa limitare")
    params = dict(params, format="json", formatversion="2")
    req = urllib.request.Request(WD_API + "?" + urllib.parse.urlencode(params), headers=WD_HEADERS)
    with WD_LOCK:
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                data = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                ra = e.headers.get("Retry-After") or ""
                WD_BLOCK[0] = time.time() + (int(ra) if ra.isdigit() else 300)
            raise
        finally:
            time.sleep(0.15)
    if "error" in data:
        raise RuntimeError(f"wikidata: {data['error'].get('code')}")
    return data


def wd_search(query, limit=150):
    out, off = [], 0
    while len(out) < limit:
        d = wd_get({"action": "query", "list": "search", "srsearch": query, "srnamespace": 0,
                    "srlimit": 50, "sroffset": off, "srprop": ""})
        hits = [h["title"] for h in d.get("query", {}).get("search", [])]
        out += hits
        if len(hits) < 50 or "continue" not in d:
            break
        off += 50
    return out[:limit]


def wd_entities(ids, props="claims", languages=None):
    ents = {}
    ids = list(dict.fromkeys(ids))
    for k in range(0, len(ids), 50):
        p = {"action": "wbgetentities", "ids": "|".join(ids[k:k + 50]), "props": props}
        if languages:
            p["languages"] = languages
        ents.update(wd_get(p).get("entities", {}))
    return ents


def wd_vals(ent, prop):
    out = []
    for c in (ent.get("claims") or {}).get(prop, []):
        v = (c.get("mainsnak") or {}).get("datavalue", {}).get("value")
        if isinstance(v, dict):
            v = v.get("id") or v.get("time")
        if v:
            out.append(v)
    return out


def wikidata_universe(kind, tid, lang):
    """Titlurile (film/serial, id TMDB) din acelasi univers, cu seria din care fac parte. Cache 7 zile."""
    key = f"wd2|{kind}|{tid}|{lang}"
    row = q1("SELECT body, fetched FROM cache WHERE key=?", (key,))
    if row and time.time() - row["fetched"] < 7 * 86400:
        return json.loads(row["body"])
    try:
        src = wd_search(f"haswbstatement:{'P4947' if kind == 'movie' else 'P4983'}={int(tid)}", limit=1)
        out = []
        if src:
            ent = wd_entities(src).get(src[0], {})
            # universul fictional / franciza; daca lipsesc: seria, apoi opera pe care se bazeaza
            for props in (("P1434", "P8345"), ("P179",), ("P144",)):
                pairs = [(p, v) for p in props for v in wd_vals(ent, p) if isinstance(v, str) and v.startswith("Q")]
                if pairs:
                    break
            if pairs:
                ors = "|".join(f"{p}={v}" for p, v in pairs)
                qids = wd_search(f"haswbstatement:{ors} haswbstatement:P4947") + \
                    wd_search(f"haswbstatement:{ors} haswbstatement:P4983")
                ents = wd_entities(qids)
                series_ids = [v for e in ents.values() for v in wd_vals(e, "P179")]
                labels = {}
                if series_ids:
                    langs = "ro|en" if lang == "ro" else "en"
                    for q_, e in wd_entities(series_ids, props="labels", languages=langs).items():
                        lb = e.get("labels") or {}
                        labels[q_] = ((lb.get("ro") if lang == "ro" else None) or lb.get("en") or {}).get("value")
                seen = set()
                for e in ents.values():
                    ser = next((labels.get(v) for v in wd_vals(e, "P179") if labels.get(v)), None)
                    dates = sorted(d_[1:11] for d_ in wd_vals(e, "P577") if isinstance(d_, str))
                    for p, ty in (("P4947", "movie"), ("P4983", "tv")):
                        for v in wd_vals(e, p):
                            if str(v).isdigit() and (ty, int(v)) not in seen:
                                seen.add((ty, int(v)))
                                out.append({"type": ty, "id": int(v), "series": ser, "date": dates[0] if dates else None})
    except Exception as e:
        print(f"{now()} Wikidata nu a raspuns pentru {kind} {tid}: {e}", flush=True)
        return json.loads(row["body"]) if row else None
    if not out:
        print(f"{now()} Wikidata: niciun univers gasit pentru {kind} {tid}", flush=True)
    # rezultat gol: se reincearca peste o zi; altfel peste 7 zile
    x("INSERT OR REPLACE INTO cache(key, body, fetched) VALUES(?,?,?)",
      (key, json.dumps(out), time.time() - (6 * 86400 if not out else 0)))
    return out


def api_universe(u, kind, tid, lang):
    found = wikidata_universe(kind, tid, lang)
    if found is None:
        return {"groups": [], "state": "offline"}
    skip = {(kind, tid)}
    if kind == "movie":     # filmele din propria colectie apar deja in sectiunea Seria
        c = (tmdb(f"/movie/{tid}").get("belongs_to_collection") or {}).get("id")
        if c:
            try:
                skip |= {("movie", p["id"]) for p in tmdb(f"/collection/{c}", ttl=7 * 86400).get("parts") or []}
            except ApiError:
                pass
    cand = [f for f in found if (f["type"], f["id"]) not in skip][:80]
    lib = lib_map(u)

    def load(f):
        try:
            d = tmdb(f"/{f['type']}/{f['id']}", ttl=7 * 86400)
        except ApiError:
            return None
        c = card(dict(d, id=f["id"]), f["type"], lib)
        c["date"] = d.get("release_date") or d.get("first_air_date") or f["date"] or ""
        c["group"] = f["series"] or ("__movies" if f["type"] == "movie" else "__tv")
        return c
    with ThreadPoolExecutor(6) as ex:
        cards = [c for c in ex.map(load, cand) if c]
    groups = {}
    for c in cards:
        groups.setdefault(c["group"], []).append(c)
    out = []
    for name, lst in groups.items():
        lst.sort(key=lambda c: c["date"] or "9999")
        out.append({"name": name, "items": lst})
    out.sort(key=lambda g: (g["name"] in ("__movies", "__tv"), g["items"][0]["date"] or "9999"))
    return {"groups": out, "state": "ok"}


def movie_collection(u, d, mid):
    """Celelalte filme din aceeasi serie (colectie TMDB), in ordinea lansarii."""
    c = d.get("belongs_to_collection")
    if not c or not c.get("id"):
        return None
    try:
        col = tmdb(f"/collection/{c['id']}", ttl=7 * 86400)
    except ApiError:
        return None
    lib = lib_map(u)
    parts = sorted(col.get("parts") or [], key=lambda p: p.get("release_date") or "9999")
    if len(parts) < 2:
        return None
    return {"id": c["id"], "name": col.get("name") or c.get("name"),
            "parts": [dict(card(p, "movie", lib), current=p["id"] == mid) for p in parts]}


def api_library(u, qs):
    t = (qs.get("type") or ["tv"])[0]
    if t == "movie":
        items = q("""SELECT i.*, COUNT(p.id) plays, MAX(p.watched_at) watched_at FROM items i
            LEFT JOIN plays p ON p.user_id=i.user_id AND p.type='movie' AND p.tmdb_id=i.tmdb_id
            WHERE i.user_id=? AND i.type='movie' GROUP BY i.tmdb_id ORDER BY i.added_at DESC""", (u,))

        def rel(it):
            try:
                it["release_date"] = tmdb(f"/movie/{it['tmdb_id']}").get("release_date") or None
            except ApiError:
                it["release_date"] = None
            return it
        with ThreadPoolExecutor(6) as ex:
            return {"items": list(ex.map(rel, items))}
    items = q("SELECT * FROM items WHERE user_id=? AND type='tv' ORDER BY added_at DESC", (u,))

    def enrich(it):
        try:
            d = tv_details(it["tmdb_id"])
            w, a, rem = progress(u, it["tmdb_id"], d, th_of(it))
            it.update(watched=w, aired=a, remaining=rem, show_status=d.get("status"),
                      next_air=(d.get("next_episode_to_air") or {}).get("air_date"))
        except ApiError:
            it.update(watched=0, aired=0, remaining=0, show_status=None, next_air=None)
        return it
    with ThreadPoolExecutor(6) as ex:
        return {"items": list(ex.map(enrich, items))}


def api_shows(u):
    """Ecranul Seriale: De vazut / Neincepute / In curand."""
    shows = q("SELECT * FROM items WHERE user_id=? AND type='tv' AND status<>'stopped'", (u,))
    acts = {r["tmdb_id"]: r["m"] for r in q(
        "SELECT tmdb_id, MAX(watched_at) m FROM plays WHERE user_id=? AND type='tv' GROUP BY tmdb_id", (u,))}

    def work(it):
        sid = it["tmdb_id"]
        try:
            d = tv_details(sid)
            th, cnt = th_of(it), counts(u, sid)
            w1, aired1, _ = progress(u, sid, d, 1, cnt)
            wt, at, _ = progress(u, sid, d, th, cnt)
            base = {"id": sid, "title": it["title"], "poster": it["poster"], "status": it["status"], "rewatch": it["rewatch"],
                    "watched": wt, "aired": at}
            out = {"base": base, "to_watch": None, "not_started": None, "soon": None}
            if w1 == 0 and aired1 > 0 and it["status"] in ("watching", "plan"):
                ep = next_episode(u, sid, d, 1, cnt)
                if ep:
                    out["not_started"] = dict(base, ep=ep, aired=aired1, added=it["added_at"] or "")
            elif w1 > 0 and it["status"] in ("watching", "rewatching", "completed"):
                ep = next_episode(u, sid, d, th, cnt)
                if ep:
                    rem = progress(u, sid, d, th, cnt)[2]
                    out["to_watch"] = dict(base, ep=ep, remaining=rem, last=acts.get(sid) or it["added_at"] or "")
            nxt = d.get("next_episode_to_air")
            if nxt and nxt.get("air_date") and nxt["air_date"] >= today():
                out["soon"] = dict(base, **ep_out(nxt))
            elif not d.get("last_episode_to_air") and (d.get("first_air_date") or "") > today():
                out["soon"] = dict(base, season=1, episode=1, name="", air_date=d["first_air_date"], runtime=None,
                                   still=None, overview="")
            return out
        except ApiError:
            return None
    with ThreadPoolExecutor(6) as ex:
        res = [r for r in ex.map(work, shows) if r]
    to_watch = sorted((r["to_watch"] for r in res if r["to_watch"]), key=lambda r: r["last"], reverse=True)
    not_started = sorted((r["not_started"] for r in res if r["not_started"]), key=lambda r: r["added"], reverse=True)
    soon = sorted((r["soon"] for r in res if r["soon"]), key=lambda r: r["air_date"])
    return {"to_watch": to_watch, "not_started": not_started, "coming_soon": soon}


def api_history(u, qs):
    """Episoadele vazute, cele mai noi primele (pentru zona de deasupra listei)."""
    limit = min(100, int((qs.get("limit") or ["30"])[0]))
    offset = int((qs.get("offset") or ["0"])[0])
    rows = q("""SELECT p.id, p.tmdb_id, p.season, p.episode, p.watched_at, i.title, i.poster FROM plays p
                JOIN items i ON i.user_id=p.user_id AND i.type='tv' AND i.tmdb_id=p.tmdb_id
                WHERE p.user_id=? AND p.type='tv' ORDER BY p.watched_at DESC, p.id DESC LIMIT ? OFFSET ?""",
             (u, limit + 1, offset))
    more = len(rows) > limit
    rows = rows[:limit]
    names = {}
    for r in rows:
        k = (r["tmdb_id"], r["season"])
        if k not in names:
            try:
                names[k] = {e["episode_number"]: e.get("name") for e in season_details(*k).get("episodes", [])}
            except ApiError:
                names[k] = {}
        r["name"] = names[k].get(r["episode"]) or ""
    return {"items": rows, "more": more}


def api_stats(u):
    e = q1("SELECT COUNT(*) c, COALESCE(SUM(runtime),0) m FROM plays WHERE user_id=? AND type='tv' AND season>0", (u,))
    re_ = q1("""SELECT COUNT(*) c FROM (SELECT tmdb_id, season, episode, COUNT(*) n FROM plays
              WHERE user_id=? AND type='tv' AND season>0 GROUP BY tmdb_id, season, episode HAVING n>1)""", (u,))
    mv = q1("SELECT COUNT(*) c, COALESCE(SUM(runtime),0) m FROM plays WHERE user_id=? AND type='movie'", (u,))
    d = datetime.date.today().replace(day=1)
    months = [d.strftime("%Y-%m")]
    for _ in range(11):
        d = (d - datetime.timedelta(days=1)).replace(day=1)
        months.insert(0, d.strftime("%Y-%m"))
    cm = {r["m"]: r["c"] for r in q("""SELECT substr(watched_at,1,7) m, COUNT(*) c FROM plays
        WHERE user_id=? AND type='tv' AND watched_at >= ? GROUP BY m""", (u, months[0]))}
    top = q("""SELECT i.tmdb_id id, i.title, i.poster, COUNT(*) c FROM plays p
               JOIN items i ON i.user_id=p.user_id AND i.type='tv' AND i.tmdb_id=p.tmdb_id
               WHERE p.user_id=? AND p.type='tv' AND p.season>0 GROUP BY p.tmdb_id ORDER BY c DESC LIMIT 5""", (u,))
    return {"episodes": e["c"], "tv_minutes": e["m"], "rewatched_eps": re_["c"], "movies": mv["c"],
            "movie_minutes": mv["m"], "months": [{"month": m, "count": cm.get(m, 0)} for m in months], "top": top}


# ---------- notificari: episoade si filme noi ----------
VAPID = None
if push.AVAILABLE:
    try:
        VAPID = push.Vapid(os.path.join(BASE, "data", "vapid.pem"))
    except Exception as _e:
        print("Notificari dezactivate:", _e, flush=True)
NOTIFY_LOCK = threading.Lock()
NOTIFY_TXT = {
    "ro": {"new_ep": "A apărut {code}: {name}", "new_eps": "Episoade noi", "more": "și încă {n}", "new_range": "Au apărut {code}",
           "movie_out": "Film nou: {title}", "movie_body": "S-a lansat azi. E în lista ta De văzut.",
           "movies_out": "Filme noi din lista ta", "test_t": "Watch Time", "test_b": "Notificările funcționează ✓"},
    "en": {"new_ep": "{code} is out: {name}", "new_eps": "New episodes", "more": "and {n} more", "new_range": "{code} are out",
           "movie_out": "New movie: {title}", "movie_body": "Released today. It's on your watchlist.",
           "movies_out": "New movies from your list", "test_t": "Watch Time", "test_b": "Notifications are working ✓"},
}


def send_to_user(uid, data):
    if not VAPID:
        return 0
    pref = q1("SELECT notify_format FROM users WHERE id=?", (uid,))
    data = dict(data, fmt=pref["notify_format"] if pref and pref["notify_format"] is not None else 2)
    n = 0
    for sub in q("SELECT * FROM push_subs WHERE user_id=?", (uid,)):
        res = push.send(VAPID, sub, data, CFG.get("push_contact") or "mailto:watchtime@example.com")
        if res == "ok":
            n += 1
        elif res == "gone":
            x("DELETE FROM push_subs WHERE id=?", (sub["id"],))
        else:
            print(f"{now()} notificare esuata pentru user {uid}: {res}", flush=True)
    return n


def check_new(uid, dry=False):
    """Episoade aparute ieri/azi la serialele urmarite si filme din lista lansate ieri/azi, nenotificate inca."""
    user = q1("SELECT * FROM users WHERE id=?", (uid,))
    if not user:
        return {"eps": [], "movies": []}
    tday = local_now().date()
    window = {(tday - datetime.timedelta(days=1)).isoformat(), tday.isoformat()}
    eps, movies = [], []
    sent = {(r["kind"], r["tmdb_id"], r["season"], r["episode"]) for r in q(
        "SELECT kind, tmdb_id, season, episode FROM notify_sent WHERE user_id=?", (uid,))}
    if user["notify_eps"]:
        for it in q("SELECT * FROM items WHERE user_id=? AND type='tv' AND status IN ('watching','rewatching','completed','plan')", (uid,)):
            sid = it["tmdb_id"]
            try:
                d = tmdb(f"/tv/{sid}", ttl=3600, sync=True)
                last = d.get("last_episode_to_air") or {}
                if last.get("air_date") not in window:
                    continue
                cnt = counts(uid, sid)
                sn = last.get("season_number")
                for ep in tmdb(f"/tv/{sid}/season/{sn}", ttl=3600, sync=True).get("episodes", []):
                    k = ("ep", sid, sn, ep["episode_number"])
                    if ep.get("air_date") in window and k not in sent and not cnt.get((sn, ep["episode_number"])):
                        eps.append({"id": sid, "title": it["title"], "poster": it["poster"], "season": sn, "episode": ep["episode_number"],
                                    "name": ep.get("name") or ""})
            except ApiError:
                continue
    if user["notify_movies"]:
        for it in q("SELECT * FROM items WHERE user_id=? AND type='movie' AND status='watchlist'", (uid,)):
            try:
                rd = tmdb(f"/movie/{it['tmdb_id']}", ttl=6 * 3600, sync=True).get("release_date")
            except ApiError:
                continue
            if rd in window and ("movie", it["tmdb_id"], 0, 0) not in sent:
                movies.append({"id": it["tmdb_id"], "title": it["title"], "poster": it["poster"]})
    return {"eps": eps, "movies": movies}


def user_lang(uid):
    r = q1("SELECT lang FROM users WHERE id=?", (uid,))
    return NOTIFY_TXT["en" if (r and r["lang"] == "en") else "ro"]


def collect_user(uid):
    """Verificarea din fiecare ora: noutatile ajung in istoric (clopotel), marcate ca netrimise pe telefon."""
    L = user_lang(uid)
    found = check_new(uid)
    eps, movies = found["eps"], found["movies"]
    ts = now()
    hist = [(uid, ts, "ep", e["id"], e["season"], e["episode"], e["title"],
             L["new_ep"].format(code=f"S{e['season']} E{e['episode']}", name=e["name"]).rstrip(": "),
             f"/#/ep/{e['id']}-{e['season']}-{e['episode']}", e.get("poster"), e["title"]) for e in eps] + \
           [(uid, ts, "movie", m["id"], 0, 0, L["movie_out"].format(title=m["title"]), L["movie_body"],
             f"/#/movie/{m['id']}", m.get("poster"), m["title"]) for m in movies]
    if hist:
        xmany("""INSERT INTO notifs(user_id,created_at,kind,tmdb_id,season,episode,title,body,url,poster,name,pushed)
                 VALUES(?,?,?,?,?,?,?,?,?,?,?,0)""", hist)
        x("DELETE FROM notifs WHERE user_id=? AND id NOT IN (SELECT id FROM notifs WHERE user_id=? ORDER BY id DESC LIMIT 300)", (uid, uid))
        xmany("INSERT OR IGNORE INTO notify_sent VALUES(?,?,?,?,?,?)",
              [(uid, "ep", e["id"], e["season"], e["episode"], ts) for e in eps] +
              [(uid, "movie", m["id"], 0, 0, ts) for m in movies])
    return {"episodes": len(eps), "movies": len(movies)}


def push_pending(uid):
    """Trimite pe telefon noutatile din istoric netrimise inca (grupate), apoi le marcheaza trimise."""
    rows = q("SELECT * FROM notifs WHERE user_id=? AND pushed=0 ORDER BY id", (uid,))
    if not rows:
        return 0
    L = user_lang(uid)
    eps = [r for r in rows if r["kind"] == "ep"]
    movies = [r for r in rows if r["kind"] == "movie"]
    sent = 0
    if eps:
        shows = {}
        for e in eps:
            shows.setdefault(e["tmdb_id"], []).append(e)
        if len(shows) == 1:
            sid, lst = next(iter(shows.items()))
            lst.sort(key=lambda e: (e["season"], e["episode"]))
            e = lst[-1]
            if len(lst) == 1:
                data = {"title": e["name"] or e["title"], "body": e["body"], "url": e["url"]}
            else:
                code = f"S{e['season']} E{lst[0]['episode']}–E{e['episode']}" if lst[0]["season"] == e["season"] \
                    else f"S{lst[0]['season']}E{lst[0]['episode']} – S{e['season']}E{e['episode']}"
                data = {"title": e["name"] or e["title"], "body": L["new_range"].format(code=code), "url": f"/#/tv/{sid}"}
        else:
            parts = [f"{lst[0]['name'] or lst[0]['title']} S{lst[-1]['season']}E{lst[-1]['episode']}" for lst in shows.values()]
            body = ", ".join(parts[:3]) + (f" {L['more'].format(n=len(parts) - 3)}" if len(parts) > 3 else "")
            data = {"title": L["new_eps"], "body": body, "url": "/#/notifs"}
        data["tag"] = "wt-eps-" + now()[:13]
        sent += send_to_user(uid, data)
    if movies:
        if len(movies) == 1:
            m = movies[0]
            data = {"title": m["title"], "body": m["body"], "url": m["url"]}
        else:
            data = {"title": L["movies_out"], "body": ", ".join((m["name"] or m["title"]) for m in movies[:4]), "url": "/#/notifs"}
        data["tag"] = "wt-movies-" + now()[:13]
        sent += send_to_user(uid, data)
    x("UPDATE notifs SET pushed=1 WHERE user_id=? AND id<=?", (uid, rows[-1]["id"]))
    return sent


def push_times(row):
    """Orele pentru notificarile pe telefon; lista goala = imediat (la verificarea din fiecare ora)."""
    try:
        t = json.loads(row["notify_times"]) if row["notify_times"] else []
    except ValueError:
        t = []
    return t or []


def clean_times(lst, limit=12):
    out = []
    for hm in lst or []:
        hm = str(hm).strip()
        if not hm:
            continue
        m = re.fullmatch(r"(\d{1,2}):(\d{2})", hm)
        if not m or int(m[1]) > 23 or int(m[2]) > 59:
            raise ApiError(400, "bad_request")
        out.append(f"{int(m[1]):02d}:{m[2]}")
    return sorted(set(out))[:limit]


def hourly_all():
    """Verificarea din fiecare ora pentru toti: actualizeaza clopotelul; cine n-are ore setate primeste push imediat."""
    with NOTIFY_LOCK:
        for u in q("SELECT id, notify_times FROM users WHERE is_admin=0"):
            try:
                res = collect_user(u["id"])
                if res["episodes"] or res["movies"]:
                    print(f"{now()} noutati user {u['id']}: {res}", flush=True)
                if not push_times(u):
                    push_pending(u["id"])
            except Exception as e:
                print(f"{now()} eroare verificare user {u['id']}: {e}", flush=True)


def run_notify_all():
    threading.Thread(target=hourly_all, daemon=True).start()


def notify_scheduler():
    """La fiecare ora fixa: verificare + clopotel. La orele alese de fiecare utilizator: notificarile pe telefon.
    Daca serverul a fost oprit, verificarea orei se face la pornire, iar o ora de push ratata se recupereaza in 3 ore."""
    while True:
        try:
            n = local_now()
            hk = n.strftime("%Y-%m-%d %H")
            last = q1("SELECT value FROM meta WHERE key='hourly_last'")
            if not last or last["value"] < hk:
                x("INSERT OR REPLACE INTO meta VALUES('hourly_last', ?)", (hk,))
                hourly_all()
            for u in q("SELECT id, notify_times FROM users WHERE is_admin=0 AND notify_times IS NOT NULL"):
                due = None
                for hm in push_times(u):
                    h, m = map(int, hm.split(":"))
                    slot = n.replace(hour=h, minute=m, second=0, microsecond=0)
                    if slot <= n < slot + datetime.timedelta(hours=3):
                        key = slot.strftime("%Y-%m-%d %H:%M")
                        if not due or key > due:
                            due = key
                mk = f"push_last|{u['id']}"
                lastp = q1("SELECT value FROM meta WHERE key=?", (mk,))
                if due and (not lastp or lastp["value"] < due):
                    x("INSERT OR REPLACE INTO meta VALUES(?, ?)", (mk, due))
                    with NOTIFY_LOCK:
                        push_pending(u["id"])
        except Exception as e:
            print(f"{now()} eroare planificator notificari: {e}", flush=True)
        time.sleep(30)


def api_push(ctx, a, b):
    u = ctx["user"]["id"]
    if a == "subscribe":
        s = b.get("sub") or {}
        keys = s.get("keys") or {}
        if not VAPID or not s.get("endpoint") or not keys.get("p256dh") or not keys.get("auth"):
            raise ApiError(400, "push_unavailable")
        x("""INSERT INTO push_subs(user_id,endpoint,p256dh,auth,device,created_at) VALUES(?,?,?,?,?,?)
             ON CONFLICT(endpoint) DO UPDATE SET user_id=excluded.user_id, p256dh=excluded.p256dh, auth=excluded.auth""",
          (u, s["endpoint"], keys["p256dh"], keys["auth"], (b.get("device") or "")[:120], now()))
        return {"ok": True}
    if a == "unsubscribe":
        x("DELETE FROM push_subs WHERE user_id=? AND endpoint=?", (u, b.get("endpoint") or ""))
        return {"ok": True}
    if a == "times":   # orele pentru push; lista goala = imediat, la verificarea din fiecare ora
        t = clean_times(b.get("times"))
        x("UPDATE users SET notify_times=? WHERE id=?", (json.dumps(t) if t else None, u))
        return {"times": t}
    if a == "prefs":
        fmt = int(b.get("fmt", 2))
        x("UPDATE users SET notify_eps=?, notify_movies=?, notify_format=? WHERE id=?",
          (1 if b.get("eps") else 0, 1 if b.get("movies") else 0, fmt if fmt in (0, 1, 2) else 2, u))
        return {"ok": True}
    if a == "test":
        L = NOTIFY_TXT["en" if ctx["user"].get("lang") == "en" else "ro"]
        n = send_to_user(u, {"title": L["test_t"], "body": L["test_b"], "url": "/#/profile", "tag": "wt-test"})
        if not n:
            raise ApiError(400, "push_none")
        return {"sent": n}
    if a == "check":
        res = collect_user(u)
        res["sent"] = push_pending(u)
        return res
    raise ApiError(404, "no_action")


# ---------- import (Trakt, TV Time in format Trakt, backup Watch Time) ----------
IMPORT_JOBS = {}


def norm_ts(v):
    """Data din export (ISO, adesea UTC cu Z) -> ora locala, format ISO fara fus orar."""
    if not v:
        return None
    try:
        d = datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        if d.tzinfo:
            d = d.astimezone().replace(tzinfo=None)
        return d.isoformat(timespec="seconds")
    except ValueError:
        return None


def walk_dicts(o, depth=0):
    if depth > 6:
        return
    if isinstance(o, list):
        for e in o:
            if isinstance(e, dict):
                yield e
            elif isinstance(e, list):
                yield from walk_dicts(e, depth + 1)
    elif isinstance(o, dict):
        for v in o.values():
            if isinstance(v, (list, dict)):
                yield from walk_dicts(v, depth + 1)


def parse_import(docs):
    data = {"tv": {}, "movie": {}}

    def ent(t, i):
        return data[t].setdefault(int(i), {"hist": [], "counts": {}, "watchlist": False, "rating": None, "status": None})

    def tmid(o):
        return ((o or {}).get("ids") or {}).get("tmdb") if isinstance(o, dict) else None

    for doc in docs:
        # backup Watch Time
        if isinstance(doc, dict) and isinstance(doc.get("items"), list) and isinstance(doc.get("plays"), list):
            for it in doc["items"]:
                if it.get("type") in ("tv", "movie") and it.get("tmdb_id"):
                    e = ent(it["type"], it["tmdb_id"])
                    e["status"] = it.get("status")
                    e["rating"] = it.get("rating") and ("wt", it["rating"])
            for p in doc["plays"]:
                if p.get("type") in ("tv", "movie") and p.get("tmdb_id"):
                    ent(p["type"], p["tmdb_id"])["hist"].append(
                        (int(p.get("season") or 0), int(p.get("episode") or 0), p.get("watched_at")))
            continue
        for r in walk_dicts(doc):
            show, movie = r.get("show"), r.get("movie")
            if isinstance(show, dict) and isinstance(r.get("episode"), dict) and r.get("watched_at") and tmid(show):
                ep = r["episode"]
                if ep.get("season") is not None and ep.get("number") is not None:
                    ent("tv", tmid(show))["hist"].append((int(ep["season"]), int(ep["number"]), norm_ts(r["watched_at"])))
            elif isinstance(movie, dict) and r.get("watched_at") and tmid(movie) and r.get("type", "movie") == "movie":
                ent("movie", tmid(movie))["hist"].append((0, 0, norm_ts(r["watched_at"])))
            elif isinstance(show, dict) and isinstance(r.get("seasons"), list) and tmid(show):
                e = ent("tv", tmid(show))
                for sea in r["seasons"]:
                    for ep in sea.get("episodes") or []:
                        if sea.get("number") is None or ep.get("number") is None:
                            continue
                        e["counts"][(int(sea["number"]), int(ep["number"]))] = (
                            int(ep.get("plays") or 1), norm_ts(ep.get("last_watched_at") or r.get("last_watched_at")))
            elif isinstance(movie, dict) and "plays" in r and tmid(movie):
                ent("movie", tmid(movie))["counts"][(0, 0)] = (int(r.get("plays") or 1), norm_ts(r.get("last_watched_at")))
            if r.get("listed_at"):
                if isinstance(movie, dict) and tmid(movie) and r.get("type", "movie") == "movie":
                    ent("movie", tmid(movie))["watchlist"] = True
                elif isinstance(show, dict) and tmid(show):
                    ent("tv", tmid(show))["watchlist"] = True
            if r.get("rating") and r.get("rated_at"):
                kind = r.get("type")
                if kind == "movie" and tmid(movie):
                    ent("movie", tmid(movie))["rating"] = ("trakt", r["rating"])
                elif kind == "show" and tmid(show):
                    ent("tv", tmid(show))["rating"] = ("trakt", r["rating"])
    return data


def run_import(u, data, job):
    existing = {(r["type"], r["tmdb_id"], r["season"], r["episode"], r["watched_at"]) for r in q(
        "SELECT type, tmdb_id, season, episode, watched_at FROM plays WHERE user_id=?", (u,))}
    had = {(r["type"], r["tmdb_id"]) for r in q("SELECT type, tmdb_id FROM items WHERE user_id=?", (u,))}
    tlock = threading.Lock()
    res = {"shows": 0, "movies": 0, "plays": 0, "skipped": 0}

    def one(args):
        t, i, e = args
        try:
            plays = {}
            for s_, e_, ts in e["hist"]:
                plays.setdefault((s_, e_), []).append(ts or now())
            for k, (n, last) in e["counts"].items():
                cur = plays.setdefault(k, [])
                cur += [last or now()] * max(0, n - len(cur))
            new_item = (t, i) not in had
            status = e["status"] if e["status"] else (
                ("watching" if t == "tv" else "watched") if plays else ("plan" if t == "tv" else "watchlist"))
            ensure_item(u, t, i, status)
            runtimes = {}
            if t == "tv" and plays:
                for sn in {k[0] for k in plays}:
                    try:
                        runtimes.update({(sn, ep["episode_number"]): ep.get("runtime")
                                         for ep in season_details(i, sn).get("episodes", [])})
                    except ApiError:
                        pass
            elif t == "movie" and plays:
                runtimes[(0, 0)] = tmdb(f"/movie/{i}").get("runtime")
            rows = []
            for (s_, e_), stamps in plays.items():
                for ts in stamps:
                    key = (t, i, s_, e_, ts)
                    if key in existing:
                        continue
                    existing.add(key)
                    rows.append((u, t, i, s_, e_, ts, runtimes.get((s_, e_))))
            if rows:
                xmany("INSERT INTO plays(user_id,type,tmdb_id,season,episode,watched_at,runtime) VALUES(?,?,?,?,?,?,?)", rows)
            if e["rating"]:
                src, val = e["rating"]
                stars = int(val) if src == "wt" else max(1, min(5, round(float(val) / 2)))
                x("UPDATE items SET rating=? WHERE user_id=? AND type=? AND tmdb_id=?", (stars, u, t, i))
            if t == "movie" and plays:
                x("UPDATE items SET status='watched' WHERE user_id=? AND type='movie' AND tmdb_id=?", (u, i))
            elif t == "tv" and plays and not e["status"]:
                if new_item:
                    x("UPDATE items SET status='watching' WHERE user_id=? AND type='tv' AND tmdb_id=?", (u, i))
                after_watch(u, i)
            with tlock:
                res["shows" if t == "tv" else "movies"] += 1
                res["plays"] += len(rows)
        except Exception:
            with tlock:
                res["skipped"] += 1
        finally:
            with tlock:
                job["done"] += 1

    tasks = [(t, i, e) for t in ("tv", "movie") for i, e in data[t].items()]
    with ThreadPoolExecutor(6) as ex:
        list(ex.map(one, tasks))
    job.update(state="done", result=res)


def api_import_start(u, b):
    job = IMPORT_JOBS.get(u)
    if job and job["state"] == "running":
        raise ApiError(400, "import_running")
    try:
        raw = base64.b64decode(b.get("data") or "")
    except ValueError:
        raise ApiError(400, "import_bad_file")
    if len(raw) > 60 * 1024 * 1024:
        raise ApiError(400, "import_too_big")
    docs = []
    try:
        if raw[:2] == b"PK":
            with zipfile.ZipFile(io.BytesIO(raw)) as z:
                for n in z.namelist():
                    if n.lower().endswith(".json") and "__MACOSX" not in n:
                        try:
                            docs.append(json.loads(z.read(n).decode("utf-8-sig")))
                        except ValueError:
                            pass
        else:
            docs.append(json.loads(raw.decode("utf-8-sig")))
    except (ValueError, zipfile.BadZipFile):
        raise ApiError(400, "import_bad_file")
    data = parse_import(docs)
    total = len(data["tv"]) + len(data["movie"])
    if not total:
        raise ApiError(400, "import_nothing")
    job = {"state": "running", "done": 0, "total": total, "result": None, "started": now()}
    IMPORT_JOBS[u] = job
    threading.Thread(target=run_import, args=(u, data, job), daemon=True).start()
    return job


def api_export(u):
    return {"exported_at": now(), "items": q("SELECT * FROM items WHERE user_id=?", (u,)),
            "plays": q("SELECT * FROM plays WHERE user_id=?", (u,))}


def get_api(ctx, parts, qs):
    a = parts[0] if parts else ""
    if a == "admin":
        need_admin(ctx)
        return admin_get(parts[1:])
    need_user(ctx)
    u = ctx["user"]["id"]
    if a == "search":
        return api_search(u, qs)
    if a == "discover":
        return api_discover(u, qs)
    if a == "tv" and len(parts) == 2:
        return api_tv(u, int(parts[1]))
    if a in ("tv", "movie") and len(parts) == 3 and parts[2] == "universe":
        lang = "en" if (ctx["user"].get("lang") == "en") else "ro"
        return coalesce(("univ", u, a, parts[1]), lambda: api_universe(u, a, int(parts[1]), lang))
    if a == "tv" and len(parts) == 3 and parts[2] == "imdb":
        return api_tv_imdb(int(parts[1]))
    if a == "tv" and len(parts) == 4 and parts[2] == "season":
        return api_season(u, int(parts[1]), int(parts[3]))
    if a == "movie" and len(parts) == 2:
        return api_movie(u, int(parts[1]))
    if a == "libmap":   # statusul tuturor titlurilor din liste (pentru bifele colorate)
        m = {"tv": {}, "movie": {}}
        for r in q("SELECT type, tmdb_id, status FROM items WHERE user_id=?", (u,)):
            m[r["type"]][r["tmdb_id"]] = r["status"]
        return m
    if a == "library":
        return coalesce(("library", u, str(qs.get("type"))), lambda: api_library(u, qs))
    if a == "shows":
        return coalesce(("shows", u), lambda: api_shows(u))
    if a == "history":
        return api_history(u, qs)
    if a == "stats":
        return coalesce(("stats", u), lambda: api_stats(u))
    if a == "export":
        return api_export(u)
    if a == "import":
        return IMPORT_JOBS.get(u) or {"state": "none"}
    if a == "notifs":
        if len(parts) > 1 and parts[1] == "count":
            return {"unread": q1("SELECT COUNT(*) c FROM notifs WHERE user_id=? AND read=0", (u,))["c"]}
        return {"items": q("SELECT * FROM notifs WHERE user_id=? ORDER BY created_at DESC, id DESC LIMIT 200", (u,)),
                "unread": q1("SELECT COUNT(*) c FROM notifs WHERE user_id=? AND read=0", (u,))["c"]}
    if a == "push":
        us = q1("SELECT notify_eps, notify_movies, notify_format, notify_times FROM users WHERE id=?", (u,))
        return {"available": bool(VAPID), "key": VAPID.public_b64 if VAPID else None,
                "devices": q1("SELECT COUNT(*) c FROM push_subs WHERE user_id=?", (u,))["c"],
                "eps": bool(us["notify_eps"]), "movies": bool(us["notify_movies"]), "fmt": us["notify_format"] if us["notify_format"] is not None else 2, "times": push_times(us)}
    raise ApiError(404, "no_route")


# ---------- POST ----------
def need_admin(ctx):
    if not ctx["user"]["is_admin"]:
        raise ApiError(403, "admin_only")


def need_user(ctx):
    if ctx["user"]["is_admin"]:
        raise ApiError(400, "admin_no_lists")


# ---------- administrare ----------
LANGS = ["en-US", "ro-RO", "de-DE", "fr-FR", "es-ES", "it-IT", "hu-HU"]


def save_cfg():
    with open(CFG_PATH, "w", encoding="utf-8") as f:
        json.dump(CFG, f, indent=2, ensure_ascii=False)


def admin_get(parts):
    a = parts[0] if parts else ""
    if a == "users":
        return {"users": q("""SELECT u.id, u.username, u.is_admin, u.created_at,
            (SELECT COUNT(*) FROM items i WHERE i.user_id=u.id AND i.type='tv') shows,
            (SELECT COUNT(*) FROM items i WHERE i.user_id=u.id AND i.type='movie') movies,
            (SELECT COUNT(*) FROM plays p WHERE p.user_id=u.id) plays,
            (SELECT MAX(watched_at) FROM plays p WHERE p.user_id=u.id) last_activity,
            (SELECT COUNT(*) FROM sessions s WHERE s.user_id=u.id AND s.expires>?) sessions
            FROM users u ORDER BY u.is_admin DESC, u.username""", (time.time(),))}
    if a == "settings":
        k = CFG["tmdb_key"]
        return {"tmdb_key_set": bool(k), "tmdb_key_hint": ("…" + k[-4:]) if k else "",
                "language": CFG["language"], "languages": LANGS, "lan_networks": CFG["lan_networks"],
                "session_days": sess_days(), "max_login_fails": int(CFG["max_login_fails"]),
                "port": CFG["port"], "notify_times": CFG.get("notify_times") or [], "timezone": CFG.get("timezone") or "",
                "server_time": now(), "push_ok": bool(VAPID)}
    if a == "system":
        return {"users": q1("SELECT COUNT(*) c FROM users WHERE is_admin=0")["c"],
                "items": q1("SELECT COUNT(*) c FROM items")["c"], "plays": q1("SELECT COUNT(*) c FROM plays")["c"],
                "cache": q1("SELECT COUNT(*) c FROM cache")["c"],
                "db_bytes": sum(os.path.getsize(p) for p in (DB_PATH, DB_PATH + "-wal") if os.path.exists(p)),
                "uptime": int(time.time() - START), "python": platform.python_version(), "host": platform.node(),
                "restart_cmd": "doas rc-service watchtime restart" if os.path.exists("/etc/alpine-release")
                else "sudo systemctl restart watchtime"}
    raise ApiError(404, "no_route")


def admin_post(ctx, a, b):
    if a == "users/create":
        name, pw = (b.get("username") or "").strip(), b.get("password") or ""
        valid_username(name)
        valid_password(pw)
        if q1("SELECT id FROM users WHERE username=?", (name,)):
            raise ApiError(400, "user_exists")
        x("INSERT INTO users(username,pw,is_admin,created_at) VALUES(?,?,?,?)",
          (name, hash_pw(pw), 1 if b.get("is_admin") else 0, now()))
        return {"ok": True}
    if a == "users/password":
        valid_password(b.get("password"))
        uid = int(b["id"])
        x("UPDATE users SET pw=? WHERE id=?", (hash_pw(b["password"]), uid))
        x("DELETE FROM sessions WHERE user_id=? AND token<>?", (uid, ctx["token"]))
        return {"ok": True}
    if a == "users/rename":
        name = (b.get("username") or "").strip()
        valid_username(name)
        if q1("SELECT id FROM users WHERE username=? AND id<>?", (name, int(b["id"]))):
            raise ApiError(400, "user_exists")
        x("UPDATE users SET username=? WHERE id=?", (name, int(b["id"])))
        return {"ok": True}
    if a == "users/logout":
        x("DELETE FROM sessions WHERE user_id=?", (int(b["id"]),))
        return {"ok": True}
    if a == "users/delete":
        uid = int(b["id"])
        if uid == ctx["user"]["id"]:
            raise ApiError(400, "no_self_delete")
        for tbl in ("items", "plays", "sessions"):
            x(f"DELETE FROM {tbl} WHERE user_id=?", (uid,))
        x("DELETE FROM users WHERE id=?", (uid,))
        return {"ok": True}
    if a == "settings":
        global LAN
        if b.get("tmdb_key"):
            CFG["tmdb_key"] = b["tmdb_key"].strip()
        if b.get("language"):
            if b["language"] not in LANGS:
                raise ApiError(400, "bad_lang")
            if b["language"] != CFG["language"]:
                x("DELETE FROM cache")
            CFG["language"] = b["language"]
        if "lan_networks" in b:
            try:
                nets = [ipaddress.ip_network(n.strip(), strict=False) for n in b["lan_networks"] if n.strip()]
            except ValueError as e:
                raise ApiError(400, "bad_network", err=e)
            if not nets:
                raise ApiError(400, "need_network")
            me = ipaddress.ip_address(ctx["ip"])
            me = (me.ipv4_mapped or me) if me.version == 6 else me
            if not me.is_loopback and not any(me in n for n in nets if n.version == me.version):
                raise ApiError(400, "self_lockout", ip=me)
            CFG["lan_networks"] = [str(n) for n in nets]
            LAN = nets
        if b.get("session_days"):
            CFG["session_days"] = max(1, min(3650, int(b["session_days"])))
        if b.get("max_login_fails"):
            CFG["max_login_fails"] = max(3, min(100, int(b["max_login_fails"])))
        if "notify_times" in b:
            times = []
            for hm in b["notify_times"]:
                hm = str(hm).strip()
                if not hm:
                    continue
                m = re.fullmatch(r"(\d{1,2}):(\d{2})", hm)
                if not m or int(m[1]) > 23 or int(m[2]) > 59:
                    raise ApiError(400, "bad_request")
                times.append(f"{int(m[1]):02d}:{m[2]}")
            CFG["notify_times"] = sorted(set(times))
        if "timezone" in b:
            tz = (b.get("timezone") or "").strip()
            if tz:
                try:
                    from zoneinfo import ZoneInfo
                    ZoneInfo(tz)
                except Exception:
                    raise ApiError(400, "bad_request")
            CFG["timezone"] = tz
        save_cfg()
        return {"ok": True}
    if a == "tmdb-test":
        x("DELETE FROM cache WHERE key LIKE '/configuration%'")
        tmdb("/configuration", {}, ttl=0)
        return {"ok": True}
    if a == "notify-now":
        threading.Thread(target=run_notify_all, daemon=True).start()
        return {"ok": True}
    if a == "cache-clear":
        x("DELETE FROM cache")
        return {"ok": True}
    raise ApiError(404, "no_action")


def post_api(ctx, parts, b):
    u = ctx["user"]["id"]
    a = "/".join(parts)
    if a == "lang":  # limba interfetei, salvata pe cont
        if b.get("lang") not in ("ro", "en"):
            raise ApiError(400, "bad_lang")
        x("UPDATE users SET lang=? WHERE id=?", (b["lang"], u))
        return {"ok": True}
    if a == "password":  # orice cont isi poate schimba parola
        row = q1("SELECT pw FROM users WHERE id=?", (u,))
        if not check_pw(b.get("old", ""), row["pw"]):
            raise ApiError(400, "wrong_old_pw")
        valid_password(b.get("new"))
        x("UPDATE users SET pw=? WHERE id=?", (hash_pw(b["new"]), u))
        x("DELETE FROM sessions WHERE user_id=? AND token<>?", (u, ctx["token"]))
        return {"ok": True}
    if a.startswith("admin/"):
        need_admin(ctx)
        return admin_post(ctx, a[6:], b)
    need_user(ctx)

    if a == "import":
        return api_import_start(u, b)
    if a.startswith("push/"):
        return api_push(ctx, a[5:], b)
    if a == "notifs/read":
        if b.get("id"):
            x("UPDATE notifs SET read=1 WHERE user_id=? AND id=?", (u, int(b["id"])))
        else:
            x("UPDATE notifs SET read=1 WHERE user_id=?", (u,))
        return {"ok": True}
    if a == "notifs/clear":
        x("DELETE FROM notifs WHERE user_id=?", (u,))
        return {"ok": True}
    t, i = b.get("type", "tv"), int(b.get("id") or 0)
    if t not in ("tv", "movie") or not i:
        raise ApiError(400, "bad_request")
    if a == "add":
        return {"item": ensure_item(u, t, i, b.get("status"))}
    if a == "remove":
        x("DELETE FROM items WHERE user_id=? AND type=? AND tmdb_id=?", (u, t, i))
        x("DELETE FROM plays WHERE user_id=? AND type=? AND tmdb_id=?", (u, t, i))
        return {"ok": True}
    if a == "status":
        st = b.get("status")
        if st not in (TV_STATUSES if t == "tv" else MOVIE_STATUSES):
            raise ApiError(400, "bad_status")
        ensure_item(u, t, i, st)
        x("UPDATE items SET status=?, rewatch=0, prev_status=NULL WHERE user_id=? AND type=? AND tmdb_id=?", (st, u, t, i))
        if t == "movie":
            n = movie_plays(u, i)["c"]
            if st == "watched" and n == 0:
                add_plays(u, "movie", i, [(0, 0, tmdb(f"/movie/{i}").get("runtime"))])
            elif st == "watchlist" and n:
                x("DELETE FROM plays WHERE user_id=? AND type='movie' AND tmdb_id=?", (u, i))
        return {"ok": True}
    if a == "rate":
        ensure_item(u, t, i)
        r = b.get("rating")
        x("UPDATE items SET rating=? WHERE user_id=? AND type=? AND tmdb_id=?", (int(r) if r else None, u, t, i))
        return {"ok": True}
    if a == "play":
        if t == "movie":
            ensure_item(u, t, i)
            add_plays(u, "movie", i, [(0, 0, tmdb(f"/movie/{i}").get("runtime"))])
            x("UPDATE items SET status='watched' WHERE user_id=? AND type='movie' AND tmdb_id=?", (u, i))
            return {"plays": movie_plays(u, i)["c"]}
        ensure_item(u, "tv", i)
        add_plays(u, "tv", i, [(int(b["season"]), int(b["episode"]), b.get("runtime"))])
        auto_rewatch(u, i, int(b["season"]), int(b["episode"]))
        return after_watch(u, i)
    if a == "unplay":
        if t == "movie":
            remove_plays(u, "movie", i, 0, 0)
            n = movie_plays(u, i)["c"]
            if not n:
                x("UPDATE items SET status='watchlist' WHERE user_id=? AND type='movie' AND tmdb_id=?", (u, i))
            return {"plays": n}
        remove_plays(u, "tv", i, int(b["season"]), int(b["episode"]))
        undo_auto_rewatch(u, i)
        return after_watch(u, i)
    if a in ("season", "upto"):
        it = ensure_item(u, "tv", i)
        th, cnt = th_of(it), counts(u, i)
        s = int(b["season"])
        if a == "season":
            targets = [(s, ep) for ep in season_details(i, s).get("episodes", [])]
        else:
            e, targets = int(b["episode"]), []
            for sea in real_seasons(tv_details(i)):
                n = sea["season_number"]
                if n > s:
                    break
                targets += [(n, ep) for ep in season_details(i, n).get("episodes", [])
                            if n < s or ep["episode_number"] <= e]
        if a == "upto" or b.get("watched", True):
            rows = []
            for n, ep in targets:
                if aired(ep.get("air_date")):
                    need = th - cnt.get((n, ep["episode_number"]), 0)
                    rows += [(n, ep["episode_number"], ep.get("runtime"))] * max(0, need)
            add_plays(u, "tv", i, rows)
        else:
            for n, ep in targets:
                k = cnt.get((n, ep["episode_number"]), 0) - (th - 1)
                if k > 0:
                    remove_plays(u, "tv", i, n, ep["episode_number"], k)
        return after_watch(u, i)
    if a == "rewatch":
        it = ensure_item(u, "tv", i)
        if b.get("stop"):
            if it["status"] == "rewatching":
                end_rewatch(u, i, it, restore=True)
            return {"ok": True}
        d, cnt = tv_details(i), counts(u, i)
        rnd = 1
        while rnd < 99 and progress(u, i, d, rnd, cnt)[2] == 0:
            rnd += 1
        if rnd == 1:
            raise ApiError(400, "rewatch_first")
        prev = it["status"] if it["status"] in TV_STATUSES else "completed"
        x("UPDATE items SET status='rewatching', prev_status=?, rewatch=? WHERE user_id=? AND type='tv' AND tmdb_id=?",
          (prev, rnd, u, i))
        return {"ok": True, "round": rnd}
    raise ApiError(404, "no_action")


# ---------- server HTTP ----------
class Handler(BaseHTTPRequestHandler):
    timeout = 60  # o conexiune agatata nu mai tine un fir de executie blocat la nesfarsit

    def log_message(self, *args):
        pass

    # --- retea / identitate ---
    def forwarded(self):
        return any(self.headers.get(h) for h in ("X-Forwarded-For", "Forwarded", "Tailscale-User-Login", "X-Real-IP"))

    def lang(self):
        return "en" if (self.headers.get("X-Lang") or "").startswith("en") else "ro"

    def client_ip(self):
        xff = self.headers.get("X-Forwarded-For")
        return xff.split(",")[0].strip() if xff else self.client_address[0]

    def is_local(self):
        """Adevarat doar pentru conexiuni directe din reteaua de acasa (nu prin Tailscale/proxy)."""
        if self.forwarded():
            return False
        try:
            ip = ipaddress.ip_address(self.client_address[0])
            ip = ip.ipv4_mapped or ip if ip.version == 6 else ip
        except ValueError:
            return False
        return ip.is_loopback or any(ip in n for n in LAN if n.version == ip.version)

    def token(self):
        c = SimpleCookie(self.headers.get("Cookie") or "")
        return c[COOKIE].value if COOKIE in c else None

    def session(self):
        tok = self.token()
        if not tok:
            return None
        s = q1("""SELECT s.token, u.id, u.username, u.is_admin, u.lang FROM sessions s JOIN users u ON u.id=s.user_id
                  WHERE s.token=? AND s.expires>?""", (tok, time.time()))
        if not s:
            return None
        return {"token": s["token"], "user": {"id": s["id"], "username": s["username"], "is_admin": bool(s["is_admin"]), "lang": s["lang"]}}

    def cookie_header(self, tok, max_age):
        secure = "; Secure" if self.headers.get("X-Forwarded-Proto") == "https" else ""
        return f"{COOKIE}={tok}; Path=/; HttpOnly; SameSite=Lax; Max-Age={max_age}{secure}"

    # --- raspunsuri ---
    def send_body(self, body, ctype, code=200, cache="no-cache", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, code=200, extra=None):
        self.send_body(json.dumps(obj, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8",
                       code, "no-store", extra)

    def guarded(self, fn):
        t0 = time.time()
        try:
            res = fn()
            if res == "BACKUP":
                return self.send_backup()
            if isinstance(res, tuple):
                self.send_json(res[0], extra=res[1])
            else:
                self.send_json(res)
        except ApiError as e:
            self.send_json({"error": e.text(self.lang()), "code": e.key}, e.code)
        except (ValueError, KeyError, TypeError) as e:
            self.send_json({"error": f"{'Invalid request' if self.lang() == 'en' else 'Cerere invalida'}: {e}", "code": "bad_request"}, 400)
        except Exception as e:  # noqa
            self.send_json({"error": f"{'Server error' if self.lang() == 'en' else 'Eroare server'}: {e}", "code": "server"}, 500)
        finally:
            dt = time.time() - t0
            if dt > 3:
                print(f"{now()} cerere lenta {dt:.1f}s: {self.command} {self.path.split('?')[0]}", flush=True)

    def send_backup(self):
        tmp = DB_PATH + ".backup"
        dst = sqlite3.connect(tmp)
        with LOCK:
            DB.backup(dst)
        dst.close()
        with open(tmp, "rb") as f:
            body = f.read()
        os.remove(tmp)
        name = f"watchtime-{datetime.date.today().isoformat()}.db"
        self.send_body(body, "application/octet-stream", cache="no-store",
                       extra={"Content-Disposition": f'attachment; filename="{name}"'})

    def require(self):
        ctx = self.session()
        if not ctx:
            raise ApiError(401, "login_needed")
        if ctx["user"]["is_admin"] and not self.is_local():
            raise ApiError(403, "admin_wifi")
        ctx["ip"] = self.client_address[0]
        return ctx

    # --- autentificare ---
    def auth_api(self, a, b):
        local = self.is_local()
        if a == "me":
            ctx = self.session()
            user = ctx["user"] if ctx else None
            blocked = bool(user and user["is_admin"] and not local)
            return {"user": None if blocked else user, "admin_blocked": blocked, "local": local,
                    "setup_needed": q1("SELECT COUNT(*) c FROM users")["c"] == 0, "has_key": bool(CFG["tmdb_key"])}
        if a == "setup":
            if q1("SELECT COUNT(*) c FROM users")["c"]:
                raise ApiError(400, "setup_done")
            if not local:
                raise ApiError(403, "setup_wifi")
            name, pw = (b.get("username") or "").strip(), b.get("password") or ""
            valid_username(name)
            valid_password(pw)
            uid = x("INSERT INTO users(username,pw,is_admin,created_at) VALUES(?,?,1,?)", (name, hash_pw(pw), now()))
            return {"ok": True}, {"Set-Cookie": self.cookie_header(new_session(uid), sess_days() * 86400)}
        if a == "login":
            ip = self.client_ip()
            recent = [t for t in FAILS.get(ip, []) if time.time() - t < 900]
            FAILS[ip] = recent
            if len(recent) >= int(CFG["max_login_fails"]):
                raise ApiError(429, "too_many")
            row = q1("SELECT * FROM users WHERE username=?", ((b.get("username") or "").strip(),))
            if not row or not check_pw(b.get("password") or "", row["pw"]):
                recent.append(time.time())
                raise ApiError(400, "bad_login")
            if row["is_admin"] and not local:
                raise ApiError(403, "admin_wifi")
            FAILS.pop(ip, None)
            return {"ok": True}, {"Set-Cookie": self.cookie_header(new_session(row["id"]), sess_days() * 86400)}
        if a == "logout":
            tok = self.token()
            if tok:
                x("DELETE FROM sessions WHERE token=?", (tok,))
            return {"ok": True}, {"Set-Cookie": self.cookie_header("", 0)}
        return None

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path.startswith("/api/"):
            parts = [p for p in u.path[5:].split("/") if p]
            if parts == ["me"]:
                return self.guarded(lambda: self.auth_api("me", {}))

            def run():
                ctx = self.require()
                if parts == ["admin", "backup"]:
                    need_admin(ctx)
                    return "BACKUP"
                res = get_api(ctx, parts, urllib.parse.parse_qs(u.query))
                if parts == ["export"]:
                    return res, {"Content-Disposition": 'attachment; filename="watchtime-backup.json"'}
                return res
            return self.guarded(run)
        rel = "index.html" if u.path in ("", "/") else urllib.parse.unquote(u.path.lstrip("/"))
        full = os.path.normpath(os.path.join(STATIC, rel))
        if not full.startswith(STATIC + os.sep) or not os.path.isfile(full):
            return self.send_body(b"Not found", "text/plain", 404)
        with open(full, "rb") as f:
            body = f.read()
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype.endswith("javascript"):
            ctype += "; charset=utf-8"
        self.send_body(body, ctype, cache="no-cache" if full.endswith((".html", "sw.js", ".webmanifest")) else "max-age=86400")

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if not u.path.startswith("/api/"):
            return self.send_body(b"Not found", "text/plain", 404)
        if "application/json" not in (self.headers.get("Content-Type") or ""):
            return self.send_json({"error": "Content-Type trebuie sa fie application/json"}, 415)
        parts = [p for p in u.path[5:].split("/") if p]
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"

        def run():
            b = json.loads(raw or b"{}")
            if len(parts) == 1 and parts[0] in ("setup", "login", "logout"):
                return self.auth_api(parts[0], b)
            return post_api(self.require(), parts, b)
        self.guarded(run)


if __name__ == "__main__":
    x("DELETE FROM sessions WHERE expires<?", (time.time(),))
    ThreadingHTTPServer.daemon_threads = True
    threading.Thread(target=notify_scheduler, daemon=True).start()
    threading.Thread(target=IMDB.loop, daemon=True).start()
    if not VAPID:
        print("Notificari dezactivate: instaleaza pachetul cryptography (Alpine: doas apk add py3-cryptography)", flush=True)
    srv = ThreadingHTTPServer((CFG["host"], int(CFG["port"])), Handler)
    print(f"Watch Time ruleaza pe http://{CFG['host']}:{CFG['port']}  (Ctrl+C pentru oprire)")
    if not CFG["tmdb_key"]:
        print("ATENTIE: lipseste cheia TMDB din config.json")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
