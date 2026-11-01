"""Build country packs: tiles + peak DB + manifests (see docs/pack-format.md).

Output layout (everything under ``<out>/v1/`` is immutable once published,
apart from ``catalog.json`` and the country manifests):

    v1/catalog.json                 list of countries, sizes, land-tile bitset
    v1/countries/CH.json            tiles (with size + sha256) and peak DB of one pack
    v1/tiles/90/N45E007.pkt         one file per tile, shared by all packs
    v1/peaks/CH.<built>.sqlite.deflate   raw-deflate compressed SQLite, new name per build (docs/pack-format.md)
    reports/CH.json                 QA report (not published)
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import time
import zlib
from dataclasses import dataclass, field
from pathlib import Path

from shapely.geometry import Point, box
from shapely.ops import unary_union
from shapely.prepared import prep

from .countries import Country, load_countries, tiles_for_geometry
from .dem import TileSource
from .encode import DEFAULT_CODEC, codec_by_name, pack_tile
from .peaks import geonames, osm, wikidata
from .peaks.db import write_peak_db
from .peaks.enrich import add_dem_heights, elevation_report
from .peaks.merge import compute_isolation, merge_peaks
from .peaks.model import Peak
from .tiles import Resolution, TileId

log = logging.getLogger(__name__)

FORMAT_VERSION = 1
ATTRIBUTION = [
    {"name": "Copernicus DEM", "text": "© DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 "
     "provided under COPERNICUS by the European Union and ESA; all rights reserved", "url":
     "https://spacedata.copernicus.eu/collections/copernicus-digital-elevation-model"},
    {"name": "OpenStreetMap", "text": "© OpenStreetMap contributors, ODbL 1.0",
     "url": "https://www.openstreetmap.org/copyright"},
    {"name": "Wikidata", "text": "Wikidata, CC0", "url": "https://www.wikidata.org"},
    {"name": "GeoNames", "text": "GeoNames, CC BY 4.0", "url": "https://www.geonames.org"},
    {"name": "Natural Earth", "text": "Made with Natural Earth (public domain)", "url": "https://www.naturalearthdata.com"},
]


@dataclass
class PackOptions:
    resolutions: list[Resolution] = field(default_factory=lambda: [Resolution.GLO90])
    buffer_km: float = 50.0
    use_osm: bool = True
    osm_pbfs: list[Path] = field(default_factory=list)  # use these instead of downloading from Geofabrik
    use_wikidata: bool = True
    use_geonames: bool = True
    include_hills: bool = False
    keep_pbf: bool = True  # False in CI: delete each Geofabrik extract after reading it
    codec: str = DEFAULT_CODEC


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_tiles(tiles: list[TileId], source: TileSource, out_dir: Path, codec_name: str) -> list[dict]:
    """Encode tiles that aren't built yet. Returns manifest entries for all land tiles."""
    codec = codec_by_name(codec_name)
    entries = []
    tile_dir = out_dir / "tiles" / source.res.value
    tile_dir.mkdir(parents=True, exist_ok=True)
    for i, t in enumerate(tiles, 1):
        if not source.exists(t):
            continue  # ocean: the app treats missing land tiles as sea level
        path = tile_dir / f"{t.name}.pkt"
        if not path.exists():
            g = source.grid(t)
            assert g is not None
            data = pack_tile(t.lat, t.lon, g.heights, codec)
            tmp = path.with_suffix(".tmp")
            tmp.write_bytes(data)
            tmp.replace(path)
            log.info("[%d/%d] %s %s: %.2f MB", i, len(tiles), source.res.value, t, len(data) / 1e6)
        entries.append({"name": t.name, "bytes": path.stat().st_size, "sha256": sha256_file(path)})
    return entries


def collect_peaks(country: Country, countries: dict[str, Country], area_tiles: list[TileId],
                  cache_dir: Path, opts: PackOptions) -> tuple[list[Peak], list[str]]:
    """Peaks inside the pack area, including those in neighbouring countries."""
    area = unary_union([box(*t.bounds) for t in area_tiles])
    involved = [country] + [c for c in countries.values() if c.code != country.code and c.geometry.intersects(area)]
    log.info("peak sources for %s: %s", country.code, ", ".join(c.code for c in involved))

    osm_peaks: list[Peak] = []
    if opts.osm_pbfs:
        for p in opts.osm_pbfs:
            osm_peaks += osm.read_osm_peaks(p, include_hills=opts.include_hills)
    elif opts.use_osm:
        for c in involved:
            osm_peaks += osm.osm_peaks_for_country(c.code, cache_dir, include_hills=opts.include_hills,
                                                   keep_pbf=opts.keep_pbf)

    # Wikidata is queried per tile (no country filter), cached per tile and shared between packs.
    wd_peaks = wikidata.fetch_area_peaks(area_tiles, cache_dir) if opts.use_wikidata else []

    gn_peaks: list[Peak] = []
    if opts.use_geonames:
        for c in involved:
            try:
                gn_peaks += geonames.read_geonames_peaks(geonames.geonames_path(c.code, cache_dir),
                                                         include_hills=opts.include_hills)
            except Exception as e:  # small territories may have no dump
                log.warning("geonames %s: %s", c.code, e)

    log.info("raw peaks: osm=%d wikidata=%d geonames=%d", len(osm_peaks), len(wd_peaks), len(gn_peaks))
    merged = merge_peaks(osm_peaks, wd_peaks, gn_peaks)
    inside = prep(area)
    return [p for p in merged if inside.contains(Point(p.lon, p.lat))], [c.code for c in involved]


def build_pack(code: str, out: Path, cache_dir: Path, opts: PackOptions) -> dict:
    t0 = time.time()
    code = code.upper()
    countries = load_countries(cache_dir)
    if code not in countries:
        raise KeyError(f"unknown country code {code}")
    country = countries[code]
    out_v = out / f"v{FORMAT_VERSION}"
    tiles = tiles_for_geometry(country.geometry, opts.buffer_km)
    log.info("%s %s: %d tiles within %.0f km", code, country.name, len(tiles), opts.buffer_km)

    manifest: dict = {
        "format_version": FORMAT_VERSION,
        "code": code,
        "name": country.name,
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "buffer_km": opts.buffer_km,
        "bbox": [round(v, 4) for v in country.bbox],
        "tile_codec": opts.codec,
        "tiles": {},
    }
    sources = {r: TileSource(r, cache_dir) for r in opts.resolutions}
    for res, src in sources.items():
        manifest["tiles"][res.value] = build_tiles(tiles, src, out_v, opts.codec)

    # Peaks: the area is the land tiles of the base resolution.
    base = sources[opts.resolutions[0]]
    land = [t for t in tiles if base.exists(t)]
    peaks, involved = collect_peaks(country, countries, land, cache_dir, opts)
    add_dem_heights(peaks, base.grid)
    compute_isolation(peaks)
    db_path = out / "build" / f"{code}.sqlite"
    write_peak_db(db_path, peaks, {"country": code, "built_at": manifest["built_at"],
                                   "sources": ",".join(involved)})
    raw = db_path.read_bytes()
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = c.compress(raw) + c.flush()
    # A new file name per build keeps every published file immutable: an app holding an
    # older manifest still finds the matching DB, and CDNs can cache everything forever.
    stamp = manifest["built_at"].replace("-", "").replace(":", "").replace("T", "").rstrip("Z")[:12]
    peaks_name = f"{code}.{stamp}.sqlite.deflate"
    peaks_path = out_v / "peaks" / peaks_name
    peaks_path.parent.mkdir(parents=True, exist_ok=True)
    peaks_path.write_bytes(packed)
    manifest["peaks"] = {
        "path": f"peaks/{peaks_name}",
        "bytes": len(packed),
        "uncompressed_bytes": len(raw),
        "sha256": hashlib.sha256(packed).hexdigest(),
        "count": len(peaks),
        "schema_version": 1,
    }
    manifest["neighbours"] = [c for c in involved if c != code]

    (out_v / "countries").mkdir(parents=True, exist_ok=True)
    (out_v / "countries" / f"{code}.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False))

    report = {
        "code": code,
        "tiles": {r: len(v) for r, v in manifest["tiles"].items()},
        "tile_mb": {r: round(sum(e["bytes"] for e in v) / 1e6, 1) for r, v in manifest["tiles"].items()},
        "peaks": len(peaks),
        "peaks_by_source": _count_sources(peaks),
        "elevation_check": elevation_report(peaks),
        "seconds": round(time.time() - t0, 1),
    }
    (out / "reports").mkdir(parents=True, exist_ok=True)
    (out / "reports" / f"{code}.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))
    update_catalog(out, sources)
    return report


def _count_sources(peaks: list[Peak]) -> dict[str, int]:
    out: dict[str, int] = {}
    for p in peaks:
        key = "+".join(sorted(p.sources))
        out[key] = out.get(key, 0) + 1
    return dict(sorted(out.items(), key=lambda kv: -kv[1]))


def land_bitset(source: TileSource) -> str:
    """Base64 bitset of tiles that have data; bit index = (lat + 90) * 360 + (lon + 180), LSB first."""
    bits = bytearray(180 * 360 // 8)
    for t in source.available:
        i = (t.lat + 90) * 360 + (t.lon + 180)
        bits[i // 8] |= 1 << (i % 8)
    return base64.b64encode(bytes(bits)).decode()


def update_catalog(out: Path, sources: dict[Resolution, TileSource]) -> dict:
    out_v = out / f"v{FORMAT_VERSION}"
    entries = []
    for mf in sorted((out_v / "countries").glob("*.json")):
        m = json.loads(mf.read_text())
        entries.append({
            "code": m["code"],
            "name": m["name"],
            "bbox": m["bbox"],
            "manifest": f"countries/{m['code']}.json",
            "built_at": m["built_at"],
            "bytes": {r: sum(e["bytes"] for e in tiles) + m["peaks"]["bytes"] for r, tiles in m["tiles"].items()},
            "tiles": {r: len(t) for r, t in m["tiles"].items()},
            "peaks": m["peaks"]["count"],
            "neighbours": m.get("neighbours", []),
        })
    path = out_v / "catalog.json"
    land = json.loads(path.read_text()).get("land_tiles", {}) if path.exists() else {}
    land.update({r.value: land_bitset(s) for r, s in sources.items()})
    catalog = {
        "format_version": FORMAT_VERSION,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "attribution": ATTRIBUTION,
        "land_tiles": land,
        "countries": entries,
    }
    (out_v / "catalog.json").write_text(json.dumps(catalog, indent=1, ensure_ascii=False))
    return catalog
