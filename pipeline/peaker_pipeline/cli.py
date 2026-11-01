"""Command line entry point: ``peaker-pipeline <command>``."""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path

from .dem import TileSource, default_cache_dir
from .tiles import Resolution


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="peaker-pipeline", description=__doc__)
    ap.add_argument("--cache", type=Path, default=default_cache_dir(), help="download cache (env PEAKER_CACHE)")
    ap.add_argument("-v", "--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("tiles", help="list the tiles of a country pack and estimate its size")
    p.add_argument("country", nargs="+")
    p.add_argument("--buffer-km", type=float, default=50)

    p = sub.add_parser("pack", help="build country pack(s)")
    p.add_argument("country", nargs="+", help="ISO 3166-1 alpha-2 codes, e.g. CH AT")
    p.add_argument("--out", type=Path, default=Path("out"))
    p.add_argument("--res", choices=["90", "30"], nargs="+", default=["90"],
                   help="DEM resolutions; the first one is used for peak heights")
    p.add_argument("--buffer-km", type=float, default=50)
    p.add_argument("--no-osm", action="store_true", help="skip OpenStreetMap (e.g. Geofabrik unreachable)")
    p.add_argument("--osm-pbf", type=Path, nargs="*", default=[], help="use these .osm.pbf files instead of Geofabrik")
    p.add_argument("--no-wikidata", action="store_true")
    p.add_argument("--no-geonames", action="store_true")
    p.add_argument("--hills", action="store_true", help="also include natural=hill / GeoNames HLL")
    p.add_argument("--drop-pbf", action="store_true",
                   help="delete each Geofabrik extract after reading it (saves disk in CI)")

    p = sub.add_parser("bundle", help="export a built pack for bundling in the iOS app")
    p.add_argument("country", help="pack to export (must be built into --out first)")
    p.add_argument("--out", type=Path, default=Path("out"), help="pipeline output directory")
    p.add_argument("--dest", type=Path, required=True, help="e.g. ../ios/Peaker/Resources/BundledPacks/NP")
    p.add_argument("--bbox", help="west,south,east,north: only tiles/peaks inside (e.g. a demo region)")
    p.add_argument("--code", help="code of the bundled pack (default: the country code)")
    p.add_argument("--name", help="display name (default: the country name)")

    p = sub.add_parser("bench-encoding", help="compare tile encodings (decision F-3)")
    p.add_argument("--res", choices=["90", "30"], default="90")
    p.add_argument("--tiles", nargs="*")

    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    if args.cmd == "tiles":
        from .countries import load_countries, tiles_for_geometry

        countries = load_countries(args.cache)
        src = TileSource(Resolution.GLO90, args.cache)
        for code in args.country:
            c = countries[code.upper()]
            tiles = tiles_for_geometry(c.geometry, args.buffer_km)
            land = [t for t in tiles if src.exists(t)]
            # Average GLO-90 tile ≈ 1.0 MB with the default codec (bench: 0.3 MB sea … 1.3 MB Himalaya).
            print(f"{c.code} {c.name}: {len(tiles)} tiles, {len(land)} with land, "
                  f"≈{len(land) * 1.0:.0f} MB at 90 m, ≈{len(land) * 9:.0f} MB at 30 m")
            if args.verbose:
                print(" ".join(t.name for t in land))

    elif args.cmd == "pack":
        from .packs import PackOptions, build_pack

        opts = PackOptions(
            resolutions=[Resolution(r) for r in args.res],
            buffer_km=args.buffer_km,
            use_osm=not args.no_osm,
            osm_pbfs=args.osm_pbf,
            use_wikidata=not args.no_wikidata,
            use_geonames=not args.no_geonames,
            include_hills=args.hills,
            keep_pbf=not args.drop_pbf,
        )
        for code in args.country:
            report = build_pack(code, args.out, args.cache, opts)
            print(json.dumps(report, indent=1, ensure_ascii=False))

    elif args.cmd == "bundle":
        from .bundle import export_bundle

        bbox = tuple(float(v) for v in args.bbox.split(",")) if args.bbox else None
        print(json.dumps(export_bundle(args.out, args.country, args.dest, bbox=bbox, new_code=args.code,
                                       name=args.name)))

    elif args.cmd == "bench-encoding":
        from . import bench

        res = Resolution(args.res)
        print(bench.report(bench.run(res, TileSource(res, args.cache), args.tiles), res))


if __name__ == "__main__":
    main()
