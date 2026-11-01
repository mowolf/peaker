import hashlib
import json
import sqlite3
import zlib

from peaker_pipeline.bundle import export_bundle
from peaker_pipeline.peaks.db import write_peak_db
from peaker_pipeline.peaks.model import Peak


def test_export_bundle_with_bbox(tmp_path):
    out = tmp_path / "out"
    (out / "v1" / "tiles" / "90").mkdir(parents=True)
    (out / "v1" / "countries").mkdir()
    (out / "v1" / "peaks").mkdir()
    tiles = []
    for name in ["N45E007", "N46E007", "N47E009"]:
        data = name.encode() * 10
        (out / "v1" / "tiles" / "90" / f"{name}.pkt").write_bytes(data)
        tiles.append({"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    db = tmp_path / "x.sqlite"
    write_peak_db(db, [Peak(45.97, 7.65, name="Matterhorn", ele=4478, osm_id=1, wikidata="Q1374", sources=["osm"]),
                       Peak(47.5, 9.5, name="Far away", ele=900, osm_id=2, sources=["osm"])], {"country": "CH"})
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    (out / "v1" / "peaks" / "CH.1.sqlite.deflate").write_bytes(c.compress(db.read_bytes()) + c.flush())
    (out / "v1" / "countries" / "CH.json").write_text(json.dumps({
        "format_version": 1, "code": "CH", "name": "Switzerland", "built_at": "2026-11-01T00:00:00Z",
        "buffer_km": 50, "bbox": [5, 45, 11, 48], "tile_codec": "pred2d-deflate@1m", "tiles": {"90": tiles},
        "peaks": {"path": "peaks/CH.1.sqlite.deflate", "bytes": 1, "uncompressed_bytes": 1, "sha256": "x",
                  "count": 2, "schema_version": 1}}))

    dest = tmp_path / "DEMO"
    r = export_bundle(out, "CH", dest, bbox=(7, 45, 9, 47), new_code="DEMO", name="Demo")
    assert r["tiles"] == 2 and r["peaks"] == 1
    m = json.loads((dest / "manifest.json").read_text())
    assert m["code"] == "DEMO" and m["peaks"]["path"] == "peaks.sqlite" and m["peaks"]["count"] == 1
    assert sorted(p.name for p in (dest / "tiles" / "90").iterdir()) == ["N45E007.pkt", "N46E007.pkt"]
    con = sqlite3.connect(dest / "peaks.sqlite")
    assert con.execute("SELECT name FROM peaks").fetchall() == [("Matterhorn",)]
    assert con.execute("SELECT count(*) FROM peaks_rtree").fetchone()[0] == 1
    assert con.execute("SELECT rowid FROM peaks_fts WHERE peaks_fts MATCH 'matterhorn'").fetchall()
    assert con.execute("SELECT value FROM meta WHERE key = 'country'").fetchone()[0] == "DEMO"
    assert con.execute("PRAGMA user_version").fetchone()[0] == 1
