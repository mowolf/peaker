"""Publish built packs into a static-file checkout (e.g. the public GitHub repo mowolf/height-data).

Copies ``<out>/v1`` into ``<repo>/v1``, keeps countries published earlier, rebuilds ``catalog.json`` from all
manifests, and deletes peak DBs no manifest refers to any more (each build gets a new file name).
"""

from __future__ import annotations

import json
import shutil
import time
from pathlib import Path

from .packs import ATTRIBUTION, FORMAT_VERSION, update_tile_index


def publish(out: Path, repo: Path) -> dict:
    src, dst = Path(out) / "v1", Path(repo) / "v1"
    # Keep the repo's tile indexes: the copy would overwrite them with the build's (fewer tiles).
    old_indexes = {d.name: (d / "index.json").read_text() for d in (dst / "tiles").glob("*")
                   if (d / "index.json").exists()} if (dst / "tiles").exists() else {}
    for sub in ("tiles", "peaks", "countries"):
        if (src / sub).exists():
            shutil.copytree(src / sub, dst / sub, dirs_exist_ok=True, ignore=shutil.ignore_patterns("*.tmp"))
    for tile_dir in (dst / "tiles").glob("*") if (dst / "tiles").exists() else []:
        merged = json.loads(old_indexes.get(tile_dir.name, "{}"))
        new_path = src / "tiles" / tile_dir.name / "index.json"
        merged.update(json.loads(new_path.read_text()) if new_path.exists() else {})
        (tile_dir / "index.json").write_text(json.dumps(merged))
        update_tile_index(tile_dir, sorted(p.stem for p in tile_dir.glob("*.pkt")))

    manifests = [json.loads(p.read_text()) for p in sorted((dst / "countries").glob("*.json"))]
    referenced = {m["peaks"]["path"] for m in manifests}
    removed = []
    for db in (dst / "peaks").glob("*.sqlite.deflate"):
        if f"peaks/{db.name}" not in referenced:
            db.unlink()
            removed.append(db.name)

    old = json.loads((dst / "catalog.json").read_text()) if (dst / "catalog.json").exists() else {}
    new = json.loads((src / "catalog.json").read_text()) if (src / "catalog.json").exists() else {}
    land = {**old.get("land_tiles", {}), **new.get("land_tiles", {})}
    catalog = {
        "format_version": FORMAT_VERSION,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "attribution": ATTRIBUTION,
        "land_tiles": land,
        "countries": [{
            "code": m["code"], "name": m["name"], "bbox": m["bbox"], "manifest": f"countries/{m['code']}.json",
            "built_at": m["built_at"],
            "bytes": {r: sum(t["bytes"] for t in tiles) + m["peaks"]["bytes"] for r, tiles in m["tiles"].items()},
            "tiles": {r: len(t) for r, t in m["tiles"].items()},
            "peaks": m["peaks"]["count"],
            "neighbours": m.get("neighbours", []),
        } for m in manifests],
    }
    (dst / "catalog.json").write_text(json.dumps(catalog, indent=1, ensure_ascii=False))
    return {"countries": [m["code"] for m in manifests], "removed_peak_dbs": removed}
