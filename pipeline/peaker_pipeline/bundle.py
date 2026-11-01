"""Export a built pack in the layout the iOS app ships in its bundle (ios/Peaker/Resources/BundledPacks/<CODE>/).

    <CODE>/manifest.json     same format as v1/countries/<CC>.json, peaks.path = "peaks.sqlite"
    <CODE>/tiles/90/*.pkt
    <CODE>/peaks.sqlite      uncompressed (the app opens it read-only straight from the bundle)

Optionally restricted to a bounding box, e.g. a small demo region cut out of a country pack.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sqlite3
import tempfile
import zlib
from pathlib import Path

from .tiles import TileId


def subset_peak_db(src: Path, dst: Path, bbox: tuple[float, float, float, float] | None, code: str) -> int:
    """Copy the peak DB (schema included), keeping only peaks inside bbox (west, south, east, north)."""
    dst.unlink(missing_ok=True)
    s = sqlite3.connect(src)
    d = sqlite3.connect(dst)
    try:
        d.execute(f"PRAGMA user_version = {s.execute('PRAGMA user_version').fetchone()[0]}")
        for (sql,) in s.execute("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL "
                                "AND name NOT LIKE 'peaks_rtree_%' AND name NOT LIKE 'peaks_fts_%' "
                                "AND name NOT LIKE 'sqlite_%'"):
            d.execute(sql)
        d.executemany("INSERT INTO meta VALUES (?, ?)",
                      [(k, code if k == "country" else v) for k, v in s.execute("SELECT key, value FROM meta")])
        if bbox:
            w, so, e, n = bbox
            rows = s.execute("SELECT * FROM peaks WHERE lon >= ? AND lat >= ? AND lon < ? AND lat < ?",
                             (w, so, e, n)).fetchall()
        else:
            rows = s.execute("SELECT * FROM peaks").fetchall()
        if rows:
            d.executemany(f"INSERT INTO peaks VALUES ({','.join('?' * len(rows[0]))})", rows)
        d.execute("INSERT INTO peaks_rtree SELECT rowid, lat, lat, lon, lon FROM peaks")
        # The FTS table is contentless, so rebuild it from the copied rows.
        d.execute("INSERT INTO peaks_fts(rowid, name, names, alt_names) "
                  "SELECT rowid, name, coalesce(names, ''), '' FROM peaks")
        ids = {r[1] for r in rows}
        d.executemany("INSERT OR IGNORE INTO peak_aliases VALUES (?, ?)",
                      [a for a in s.execute("SELECT alias, peak_id FROM peak_aliases") if a[1] in ids])
        d.commit()
        d.execute("VACUUM")
    finally:
        s.close()
        d.close()
    return len(rows)


def export_bundle(out: Path, code: str, dest: Path, bbox: tuple[float, float, float, float] | None = None,
                  new_code: str | None = None, name: str | None = None) -> dict:
    v1 = Path(out) / "v1"
    m = json.loads((v1 / "countries" / f"{code.upper()}.json").read_text())
    tiles = m["tiles"]["90"]
    if bbox:
        w, s, e, n = bbox
        tiles = [t for t in tiles if w <= TileId.parse(t["name"]).lon < e and s <= TileId.parse(t["name"]).lat < n]

    dest = Path(dest)
    if dest.exists():
        shutil.rmtree(dest)
    (dest / "tiles" / "90").mkdir(parents=True)
    for t in tiles:
        shutil.copy(v1 / "tiles" / "90" / f"{t['name']}.pkt", dest / "tiles" / "90" / f"{t['name']}.pkt")

    with tempfile.TemporaryDirectory() as tmp:
        full = Path(tmp) / "full.sqlite"
        full.write_bytes(zlib.decompress((v1 / m["peaks"]["path"]).read_bytes(), -15))
        count = subset_peak_db(full, dest / "peaks.sqlite", bbox, new_code or m["code"])
    db = (dest / "peaks.sqlite").read_bytes()

    manifest = {
        "format_version": m["format_version"],
        "code": new_code or m["code"],
        "name": name or m["name"],
        "built_at": m["built_at"],
        "buffer_km": m["buffer_km"] if not bbox else 0,
        "bbox": list(bbox) if bbox else m["bbox"],
        "tile_codec": m["tile_codec"],
        "tiles": {"90": tiles},
        "peaks": {"path": "peaks.sqlite", "bytes": len(db), "uncompressed_bytes": len(db),
                  "sha256": hashlib.sha256(db).hexdigest(), "count": count, "schema_version": m["peaks"]["schema_version"]},
        "neighbours": [],
    }
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False))
    return {"code": manifest["code"], "tiles": len(tiles), "peaks": count,
            "mb": round((sum(t["bytes"] for t in tiles) + len(db)) / 1e6, 1)}
