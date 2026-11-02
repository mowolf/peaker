"""Write the per-pack peak database (SQLite) that the app reads.

Schema version 1. The app opens it read-only; the R-tree answers "peaks
within 250 km of me", FTS5 answers name search.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from .merge import importance
from .model import Peak
from .names import choose_display_name

SCHEMA_VERSION = 1

SCHEMA = """
PRAGMA user_version = {version};
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE peaks (
    rowid       INTEGER PRIMARY KEY,
    id          TEXT NOT NULL UNIQUE,      -- stable id: wd:Q… | osm:n… | gn:…
    name        TEXT NOT NULL,             -- local name
    names       TEXT,                      -- JSON {{lang: name}}
    lat         REAL NOT NULL,
    lon         REAL NOT NULL,
    ele         REAL,                      -- metres, official where known
    ele_source  TEXT,                      -- osm | wikidata | geonames | dem
    dem_ele     REAL,                      -- highest DEM value near the summit
    prominence  REAL,
    isolation_km REAL,
    importance  REAL NOT NULL,             -- 0..1, label priority
    kind        TEXT NOT NULL,             -- peak | volcano | hill | mountain
    wikidata    TEXT,
    osm_id      INTEGER,
    geonames_id INTEGER,
    wikipedia   TEXT,                      -- "en:Matterhorn"
    sources     TEXT NOT NULL,             -- comma separated
    qa          TEXT                       -- comma separated flags: unit_fixed, alt_source, snapped, ele_conflict
);
CREATE TABLE peak_aliases (alias TEXT PRIMARY KEY, peak_id TEXT NOT NULL);
CREATE VIRTUAL TABLE peaks_rtree USING rtree(rowid, min_lat, max_lat, min_lon, max_lon);
CREATE VIRTUAL TABLE peaks_fts USING fts5(name, names, alt_names, content='', tokenize='unicode61 remove_diacritics 2');
"""


def write_peak_db(path: Path | str, peaks: list[Peak], meta: dict[str, str]) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.unlink(missing_ok=True)
    con = sqlite3.connect(tmp)
    try:
        con.executescript(SCHEMA.format(version=SCHEMA_VERSION))
        con.executemany("INSERT INTO meta VALUES (?, ?)",
                        [("schema_version", str(SCHEMA_VERSION)), *sorted(meta.items())])
        seen: set[str] = set()
        rows, rtree, fts, aliases = [], [], [], []
        for i, p in enumerate(sorted(peaks, key=lambda p: (-(p.ele or 0), p.id)), start=1):
            if p.id in seen:
                continue
            seen.add(p.id)
            name, local = choose_display_name(p)  # readable main name; local script kept in names["local"]
            names = dict(p.names)
            if local and local != name:
                names.setdefault("local", local)
            name = name or p.display_name()
            rows.append((i, p.id, name, json.dumps(names, ensure_ascii=False, sort_keys=True) if names else None,
                         round(p.lat, 6), round(p.lon, 6), p.ele, p.ele_source, p.dem_ele, p.prominence,
                         None if p.isolation_km is None else round(p.isolation_km, 2), importance(p), p.kind,
                         p.wikidata, p.osm_id, p.geonames_id, p.wikipedia, ",".join(p.sources),
                         ",".join(p.qa) or None))
            rtree.append((i, p.lat, p.lat, p.lon, p.lon))
            fts.append((i, name, " ".join(names.values()), " ".join(p.alt_names)))
            aliases += [(a, p.id) for a in p.all_ids if a != p.id]
        con.executemany(f"INSERT INTO peaks VALUES ({','.join('?' * 19)})", rows)
        con.executemany("INSERT INTO peaks_rtree VALUES (?, ?, ?, ?, ?)", rtree)
        con.executemany("INSERT INTO peaks_fts(rowid, name, names, alt_names) VALUES (?, ?, ?, ?)", fts)
        con.executemany("INSERT OR IGNORE INTO peak_aliases VALUES (?, ?)", aliases)
        con.commit()
        con.execute("VACUUM")
    finally:
        con.close()
    tmp.replace(path)


def read_peak_db(path: Path | str) -> list[Peak]:
    """Load peaks from a peak DB written by write_peak_db (e.g. to rebuild a pack's tiles with the same peaks).

    Search-only alternative names aren't stored in the DB, so they are lost; everything else round-trips.
    """
    con = sqlite3.connect(path)
    try:
        cols = [r[1] for r in con.execute("PRAGMA table_info(peaks)")]
        out: list[Peak] = []
        for row in con.execute("SELECT * FROM peaks"):
            r = dict(zip(cols, row))
            out.append(Peak(
                lat=r["lat"], lon=r["lon"], name=r["name"], names=json.loads(r["names"]) if r["names"] else {},
                ele=r["ele"], ele_source=r["ele_source"], dem_ele=r["dem_ele"], prominence=r["prominence"],
                isolation_km=r["isolation_km"], kind=r["kind"], osm_id=r["osm_id"], wikidata=r["wikidata"],
                geonames_id=r["geonames_id"], wikipedia=r["wikipedia"],
                sources=(r["sources"] or "").split(",") if r["sources"] else [],
                qa=(r.get("qa") or "").split(",") if r.get("qa") else [],
            ))
        return out
    finally:
        con.close()
