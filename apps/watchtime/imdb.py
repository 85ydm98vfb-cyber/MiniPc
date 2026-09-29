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
        """(sezon, episod, nota, voturi) pentru episoadele cu nota ale unui serial; None daca lista nu e gata."""
        if not self.conn:
            return None
        with self.lock:
            try:
                return self.conn.execute("""SELECT e.season, e.episode, r.rating, r.votes FROM e JOIN r ON r.id=e.id
                                            WHERE e.parent=? ORDER BY e.season, e.episode""", (parent,)).fetchall()
            except sqlite3.Error:
                return None

    def has_episodes(self):
        if not self.conn:
            return False
        with self.lock:
            return bool(self.conn.execute("SELECT 1 FROM sqlite_master WHERE name='e'").fetchone())

    def age_hours(self):
        return (time.time() - os.path.getmtime(self.path)) / 3600 if os.path.exists(self.path) else None

    def _download(self, url, dest):
        req = urllib.request.Request(url, headers={"User-Agent": "WatchTime/1.0"})
        with urllib.request.urlopen(req, timeout=180) as r, open(dest, "wb") as f:
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
            rated = {int(r[0][2:]) for r in db.execute("SELECT id FROM r")}
            db.execute("CREATE TABLE e(parent TEXT, season INTEGER, episode INTEGER, id TEXT, PRIMARY KEY(parent, season, episode)) WITHOUT ROWID")
            ne = 0
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
                            if int(p[0][2:]) not in rated:
                                continue
                            batch.append((p[1], int(p[2]), int(p[3]), p[0]))
                        except ValueError:
                            continue
                        if len(batch) >= 50000:
                            db.executemany("INSERT OR IGNORE INTO e VALUES(?,?,?,?)", batch)
                            ne += len(batch)
                            batch = []
                    if batch:
                        db.executemany("INSERT OR IGNORE INTO e VALUES(?,?,?,?)", batch)
                        ne += len(batch)
                db.commit()
            except Exception as e:
                self.log(f"Lista de episoade IMDb nu a putut fi descarcata: {e}")
            del rated
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
