import json

from peaker_pipeline.publish import publish


def _manifest(code, peaks):
    return {"format_version": 1, "code": code, "name": code, "built_at": "2026", "bbox": [0, 0, 1, 1],
            "buffer_km": 50, "tile_codec": "x", "tiles": {"90": [{"name": "N00E000", "bytes": 10, "sha256": "a"}]},
            "peaks": {"path": f"peaks/{peaks}", "bytes": 5, "uncompressed_bytes": 5, "sha256": "b", "count": 3,
                      "schema_version": 1}}


def test_publish_merges_and_cleans(tmp_path):
    repo, out = tmp_path / "repo" / "v1", tmp_path / "out" / "v1"
    for d in (repo / "countries", repo / "peaks", out / "countries", out / "peaks", out / "tiles" / "90"):
        d.mkdir(parents=True)
    (repo / "countries" / "CH.json").write_text(json.dumps(_manifest("CH", "CH.1.sqlite.deflate")))
    (repo / "peaks" / "CH.1.sqlite.deflate").write_bytes(b"ch")
    (repo / "peaks" / "NP.1.sqlite.deflate").write_bytes(b"old np")  # superseded by the new build
    (out / "countries" / "NP.json").write_text(json.dumps(_manifest("NP", "NP.2.sqlite.deflate")))
    (out / "peaks" / "NP.2.sqlite.deflate").write_bytes(b"np")
    (out / "tiles" / "90" / "N00E000.pkt").write_bytes(b"t")
    (out / "catalog.json").write_text(json.dumps({"land_tiles": {"90": "AA=="}}))
    r = publish(tmp_path / "out", tmp_path / "repo")
    assert r == {"countries": ["CH", "NP"], "removed_peak_dbs": ["NP.1.sqlite.deflate"]}
    cat = json.loads((repo / "catalog.json").read_text())
    assert [c["code"] for c in cat["countries"]] == ["CH", "NP"] and cat["land_tiles"]["90"] == "AA=="
    assert (repo / "tiles" / "90" / "N00E000.pkt").exists()
