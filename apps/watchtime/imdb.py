"""Note IMDb din setul oficial de date IMDb (title.ratings.tsv.gz, actualizat zilnic de IMDb,
gratuit pentru uz personal). Se descarca o data pe zi intr-o baza separata: data/imdb.db."""
import gzip
import os
import sqlite3
import threading
import time
import urllib.request

URL = "https://datasets.imdbws.com/title.ratings.tsv.gz"
EP_URL = "https://datasets.imdbws.com/title.episode.tsv.gz"   # legatura episod -> serial, sezon, numar


class Ratings:
    def __init__(self, data_dir, log=print):
        self.path = os.path.join(data_dir, "imdb.db")
        self.log = log
        self.lock = threading.Lock()
        self.conn = sqlite3.connect(self.path, check_same_thread=False) if os.path.exists(self.path) else None

    def get(self, tconst):
        if not tconst or not self.conn:
            return None
        with self.lock:
            try:
                r = self.conn.execute("SELECT rating, votes FROM r WHERE id=?", (tconst,)).fetchone()
            except sqlite3.Error:
                return None
        return {"rating": r[0], "votes": r[1]} if r else None

    def episodes(self, parent):
        """(sezon, episod, nota, voturi, id IMDb) pentru episoadele cu nota ale unui serial; None daca lista nu e gata."""
        if not self.conn:
            return None
        with self.lock:
            try:
                return self.conn.execute("""SELECT e.season, e.episode, r.rating, r.votes, e.id FROM e JOIN r ON r.id=e.id
                                            WHERE e.parent=? ORDER BY e.season, e.episode""", (parent,)).fetchall()
            except sqlite3.Error:
                return None

    def has_episodes(self):
        if not self.conn:
            return False
        with self.lock:
            try:     # tabelul trebuie sa existe si sa aiba date (altfel reincerc descarcarea)
                return bool(self.conn.execute("SELECT 1 FROM e LIMIT 1").fetchone())
            except sqlite3.Error:
                return False

    def age_hours(self):
        return (time.time() - os.path.getmtime(self.path)) / 3600 if os.path.exists(self.path) else None

    def _download(self, url, dest):
        for attempt in range(4):
            try:
                return self._download_once(url, dest)
            except Exception as e:
                if attempt == 3:
                    raise
                self.log(f"Descarcarea {url.rsplit('/', 1)[-1]} a esuat ({e}); reincerc in {30 * (attempt + 1)}s")
                time.sleep(30 * (attempt + 1))

    def _download_once(self, url, dest):
        req = urllib.request.Request(url, headers={"User-Agent": "WatchTime/1.0"})
        with urllib.request.urlopen(req, timeout=600) as r, open(dest, "wb") as f:
            while True:
                chunk = r.read(1 << 16)
                if not chunk:
                    break
                f.write(chunk)

    def update(self):
        tmp_gz, tmp_db, tmp_ep = self.path + ".gz.part", self.path + ".part", self.path + ".ep.gz.part"
        t0 = time.time()
        try:
            self._download(URL, tmp_gz)
            if os.path.exists(tmp_db):
                os.remove(tmp_db)
            db = sqlite3.connect(tmp_db)
            db.execute("CREATE TABLE r(id TEXT PRIMARY KEY, rating REAL, votes INTEGER) WITHOUT ROWID")
            n = 0
            with gzip.open(tmp_gz, "rt", encoding="utf-8") as f:
                next(f, None)  # antet
                batch = []
                for line in f:
                    p = line.rstrip("\n").split("\t")
                    if len(p) >= 3:
                        try:
                            batch.append((p[0], float(p[1]), int(p[2])))
                        except ValueError:
                            continue
                    if len(batch) >= 50000:
                        db.executemany("INSERT OR REPLACE INTO r VALUES(?,?,?)", batch)
                        n += len(batch)
                        batch = []
                if batch:
                    db.executemany("INSERT OR REPLACE INTO r VALUES(?,?,?)", batch)
                    n += len(batch)
            db.commit()
            # episoadele (doar cele care au nota) -> grafice pe sezoane
            db.execute("CREATE TABLE e(parent TEXT, season INTEGER, episode INTEGER, id TEXT, PRIMARY KEY(parent, season, episode)) WITHOUT ROWID")
            db.execute("CREATE TEMP TABLE b(parent TEXT, season INTEGER, episode INTEGER, id TEXT)")
            ne = 0

            def flush(batch):
                # pastrez doar episoadele care au nota (filtrarea o face SQLite, fara liste mari in memorie)
                db.executemany("INSERT INTO b VALUES(?,?,?,?)", batch)
                db.execute("INSERT OR IGNORE INTO e SELECT b.parent, b.season, b.episode, b.id FROM b JOIN r ON r.id=b.id")
                db.execute("DELETE FROM b")
            try:
                self._download(EP_URL, tmp_ep)
                with gzip.open(tmp_ep, "rt", encoding="utf-8") as f:
                    next(f, None)
                    batch = []
                    for line in f:
                        p = line.rstrip("\n").split("\t")
                        if len(p) < 4 or p[2] == "\\N" or p[3] == "\\N":
                            continue
                        try:
                            batch.append((p[1], int(p[2]), int(p[3]), p[0]))
                        except ValueError:
                            continue
                        if len(batch) >= 50000:
                            flush(batch)
                            batch = []
                    if batch:
                        flush(batch)
                db.commit()
                ne = db.execute("SELECT COUNT(*) FROM e").fetchone()[0]
            except Exception as e:
                self.log(f"Lista de episoade IMDb nu a putut fi descarcata: {e}")
                try:
                    db.execute("DELETE FROM e")
                    if os.path.exists(self.path):
                        db.execute("ATTACH DATABASE ? AS old", (self.path,))
                        if db.execute("SELECT 1 FROM old.sqlite_master WHERE name='e'").fetchone():
                            db.execute("INSERT OR IGNORE INTO e SELECT * FROM old.e")
                        db.commit()
                        db.execute("DETACH DATABASE old")
                    ne = db.execute("SELECT COUNT(*) FROM e").fetchone()[0]
                    if ne:
                        self.log(f"Pastrez lista de episoade anterioara ({ne} episoade)")
                except Exception as e2:
                    self.log(f"Nu am putut pastra lista veche de episoade: {e2}")
            db.close()
            with self.lock:
                if self.conn:
                    self.conn.close()
                os.replace(tmp_db, self.path)
                self.conn = sqlite3.connect(self.path, check_same_thread=False)
            self.log(f"Note IMDb actualizate: {n} titluri, {ne} episoade, in {time.time() - t0:.0f}s")
        except Exception as e:
            self.log(f"Nu am putut actualiza notele IMDb: {e}")
        finally:
            for p in (tmp_gz, tmp_db, tmp_ep):
                try:
                    os.remove(p)
                except OSError:
                    pass

    def loop(self):
        time.sleep(20)  # lasa serverul sa porneasca
        while True:
            age = self.age_hours()
            if age is None or age > 24 or not self.has_episodes():
                self.update()
            time.sleep(3 * 3600)
