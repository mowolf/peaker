"""Command line entry point: ``peaker-pipeline <command>``."""

from __future__ import annotations

import argparse
import os
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
    p.add_argument("--peaks-db", type=Path, help="reuse the peaks of an existing peak DB (rebuild tiles only)")
    p.add_argument("--workers", type=int, default=1, help="parallel tile encoding")
    p.add_argument("--tile-index", help="use published tiles (dir or URL of …/v1) instead of building them")
    p.add_argument("--osm-mirror", choices=["geofabrik", "osmfr"], default="geofabrik",
                   help="where to get OSM extracts (osmfr: openstreetmap.fr, Europe, not all countries)")
    p.add_argument("--clip", help="west,south,east,north: only this part of the country")
    p.add_argument("--allow-missing-osm", action="store_true",
                   help="build even without OpenStreetMap peaks inside the country (tiny countries)")

    p = sub.add_parser("build-tiles", help="build elevation tiles only (no peaks), e.g. for a whole continent")
    p.add_argument("country", nargs="*", help="ISO codes (or use --continent)")
    p.add_argument("--continent", help="all countries of a Natural Earth continent, e.g. Europe")
    p.add_argument("--exclude", nargs="*", default=[], help="ISO codes to skip, e.g. RU")
    p.add_argument("--clip", help="west,south,east,north: only this part of each country (no overseas parts)")
    p.add_argument("--out", type=Path, default=Path("out"))
    p.add_argument("--res", choices=["90", "30"], nargs="+", default=["90", "30"])
    p.add_argument("--buffer-km", type=float, default=50)
    p.add_argument("--workers", type=int, default=os.cpu_count() or 1)
    p.add_argument("--hd-min-relief", type=float, default=1000, help="30 m only for tiles with this much relief…")
    p.add_argument("--hd-min-peak", type=float, default=1500, help="…or summits at least this high")

    p = sub.add_parser("publish", help="copy built packs into a static-file checkout (e.g. height-data repo)")
    p.add_argument("--out", type=Path, default=Path("out"), help="pipeline output directory")
    p.add_argument("--repo", type=Path, required=True, help="checkout to publish into, e.g. ../../height-data")

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
            peaks_db=args.peaks_db,
            workers=args.workers,
            tile_index=args.tile_index,
            osm_mirror=args.osm_mirror,
            allow_missing_osm=args.allow_missing_osm,
            clip=tuple(float(v) for v in args.clip.split(",")) if args.clip else None,
        )
        for code in args.country:
            report = build_pack(code, args.out, args.cache, opts)
            print(json.dumps(report, indent=1, ensure_ascii=False))

    elif args.cmd == "build-tiles":
        from .countries import load_countries
        from .packs import PackOptions, build_country_tiles

        codes = [c.upper() for c in args.country]
        if args.continent:
            codes += sorted(c.code for c in load_countries(args.cache).values() if c.continent == args.continent)
        codes = [c for c in dict.fromkeys(codes) if c not in {e.upper() for e in args.exclude}]
        opts = PackOptions(resolutions=[Resolution(r) for r in args.res], buffer_km=args.buffer_km,
                           workers=args.workers, hd_min_relief=args.hd_min_relief, hd_min_peak=args.hd_min_peak,
                           clip=tuple(float(v) for v in args.clip.split(",")) if args.clip else None)
        print(json.dumps(build_country_tiles(codes, args.out, args.cache, opts)))

    elif args.cmd == "publish":
        from .publish import publish

        print(json.dumps(publish(args.out, args.repo)))

    elif args.cmd == "bench-encoding":
        from . import bench

        res = Resolution(args.res)
        print(bench.report(bench.run(res, TileSource(res, args.cache), args.tiles), res))


if __name__ == "__main__":
    main()
