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
import os
import time
from typing import Callable
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
from .peaks import wikitext
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
    {"name": "Wikipedia", "text": "Peak descriptions from Wikipedia articles, CC BY-SA 4.0",
     "url": "https://creativecommons.org/licenses/by-sa/4.0/"},
]


@dataclass
class PackOptions:
    resolutions: list[Resolution] = field(default_factory=lambda: [Resolution.GLO90])
    buffer_km: float = 50.0
    use_osm: bool = True
    osm_pbfs: list[Path] = field(default_factory=list)  # use these instead of downloading from Geofabrik
    use_wikidata: bool = True
    use_wikipedia_text: bool = True  # article intros for offline peak details (peaks/wikitext.py)
    use_geonames: bool = True
    include_hills: bool = False
    keep_pbf: bool = True  # False in CI: delete each Geofabrik extract after reading it
    osm_mirror: str = "geofabrik"  # or "osmfr" (openstreetmap.fr, Europe only, fewer countries)
    # Publish even if no OpenStreetMap peak lies inside the country itself (see check_osm_coverage).
    allow_missing_osm: bool = False
    peaks_db: Path | None = None  # reuse the peaks of an existing peak DB instead of collecting them
    workers: int = 1  # parallel tile encoding
    # 30 m only where it matters for peak views: tiles with this much relief or summits this high.
    hd_min_relief: float = 1000
    hd_min_peak: float = 1500
    # Published tiles (dir or URL of .../v1): write manifests from their index instead of building tiles.
    tile_index: str | None = None
    # Only the part of the country inside this (west, south, east, north) box, e.g. Europe without overseas parts.
    clip: tuple[float, float, float, float] | None = None
    codec: str = DEFAULT_CODEC


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _tile_header_range(path: Path) -> tuple[int, int] | None:
    """(min, max) height from a .pkt header, without decoding the tile."""
    import struct

    from .encode import HEADER

    try:
        with open(path, "rb") as f:
            h = HEADER.unpack(f.read(HEADER.size))
        return h[11], h[12]
    except (OSError, ValueError, struct.error):
        return None


def is_mountainous(tile: TileId, out_dir: Path, min_relief: float, min_peak: float) -> bool:
    """Decide from the tile's 90 m version whether 30 m is worth it (flat land gains nothing for peak views)."""
    r = _tile_header_range(out_dir / "tiles" / "90" / f"{tile.name}.pkt")
    if r is None:
        return True
    lo, hi = r
    return (hi - lo) >= min_relief or hi >= min_peak


_worker_source: TileSource | None = None


def _init_worker(res_value: str, cache_dir: str) -> None:
    global _worker_source
    _worker_source = TileSource(Resolution(res_value), cache_dir)


def _encode_one(name: str, path: str, codec_name: str) -> tuple[str, float]:
    t = TileId.parse(name)
    g = _worker_source.grid(t)
    assert g is not None
    data = pack_tile(t.lat, t.lon, g.heights, codec_by_name(codec_name))
    tmp = Path(path).with_suffix(f".{os.getpid()}.tmp")
    tmp.write_bytes(data)
    tmp.replace(path)
    return name, len(data) / 1e6


def build_tiles(tiles: list[TileId], source: TileSource, out_dir: Path, codec_name: str, workers: int = 1,
                only: "Callable[[TileId], bool] | None" = None) -> list[dict]:
    """Encode tiles that aren't built yet (in parallel). Returns manifest entries for the land tiles.

    ``only`` filters which tiles to build at all (e.g. 30 m only for mountainous tiles).
    """
    tile_dir = out_dir / "tiles" / source.res.value
    tile_dir.mkdir(parents=True, exist_ok=True)
    wanted = [t for t in tiles if source.exists(t) and (only is None or only(t))]
    todo = [t for t in wanted if not (tile_dir / f"{t.name}.pkt").exists()]
    if todo:
        log.info("%s m: %d tiles to encode (%d already built), %d workers", source.res.value, len(todo),
                 len(wanted) - len(todo), workers)
    if todo and workers > 1:
        from concurrent.futures import ProcessPoolExecutor, as_completed

        with ProcessPoolExecutor(workers, initializer=_init_worker,
                                 initargs=(source.res.value, str(source.cache_dir.parent))) as pool:
            futures = [pool.submit(_encode_one, t.name, str(tile_dir / f"{t.name}.pkt"), codec_name) for t in todo]
            for i, f in enumerate(as_completed(futures), 1):
                name, mb = f.result()
                log.info("[%d/%d] %s %s: %.2f MB", i, len(todo), source.res.value, name, mb)
    else:
        codec = codec_by_name(codec_name)
        for i, t in enumerate(todo, 1):
            g = source.grid(t)
            assert g is not None
            data = pack_tile(t.lat, t.lon, g.heights, codec)
            path = tile_dir / f"{t.name}.pkt"
            tmp = path.with_suffix(".tmp")
            tmp.write_bytes(data)
            tmp.replace(path)
            log.info("[%d/%d] %s %s: %.2f MB", i, len(todo), source.res.value, t, len(data) / 1e6)
    index = update_tile_index(tile_dir, [t.name for t in wanted])
    return [index[t.name] for t in wanted]


def update_tile_index(tile_dir: Path, names: list[str]) -> dict[str, dict]:
    """``tiles/<res>/index.json``: name → {name, bytes, sha256, min, max}. Lets CI write manifests for
    published tiles without having the tile files (see ``--tile-index``)."""
    path = tile_dir / "index.json"
    index = json.loads(path.read_text()) if path.exists() else {}
    for name in names:
        f = tile_dir / f"{name}.pkt"
        entry = index.get(name)
        if entry is None or entry["bytes"] != f.stat().st_size:
            r = _tile_header_range(f) or (0, 0)
            index[name] = {"name": name, "bytes": f.stat().st_size, "sha256": sha256_file(f), "min": r[0], "max": r[1]}
    path.write_text(json.dumps(dict(sorted(index.items())), indent=0))
    return index


def load_tile_index(source: str, res: str) -> dict[str, dict]:
    """Tile index from a local directory/checkout or a URL prefix (…/v1)."""
    if source.startswith("http"):
        import requests

        r = requests.get(f"{source.rstrip('/')}/tiles/{res}/index.json", timeout=120)
        if r.status_code == 404:
            return {}
        r.raise_for_status()
        return r.json()
    path = Path(source) / "tiles" / res / "index.json"
    return json.loads(path.read_text()) if path.exists() else {}


class MissingOSMPeaks(RuntimeError):
    """The country's own OpenStreetMap peaks are missing (extract not found, or empty)."""


def osm_peaks_inside(country: Country, peaks: list[Peak]) -> int:
    """Number of OpenStreetMap peaks inside the country itself (not in the border buffer)."""
    own = prep(country.geometry)
    return sum(1 for p in peaks if p.osm_id is not None and own.contains(Point(p.lon, p.lat)))


def check_osm_coverage(country: Country, peaks: list[Peak], opts: PackOptions) -> None:
    """Refuse to build a pack whose country has no OpenStreetMap peaks of its own.

    That happens when the country's extract is missing on the mirror used: the pack then only has GeoNames
    peaks plus the neighbours' OSM peaks in the border buffer (the November 2026 build via openstreetmap.fr
    published the Balkans, Iceland and the Baltics like that). Failing keeps the previously published pack.
    Tiny countries without any tagged peak pass ``allow_missing_osm`` (``--allow-missing-osm`` in packs.txt).
    """
    if not opts.use_osm or opts.osm_pbfs or opts.allow_missing_osm:
        return
    if osm_peaks_inside(country, peaks) == 0:
        raise MissingOSMPeaks(
            f"no OpenStreetMap peaks inside {country.code} ({country.name}): its extract on '{opts.osm_mirror}' "
            "is probably missing. Use another --osm-mirror, or --allow-missing-osm if it really has none.")


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
            try:
                osm_peaks += osm.osm_peaks_for_country(c.code, cache_dir, include_hills=opts.include_hills,
                                                       keep_pbf=opts.keep_pbf, mirror=opts.osm_mirror)
            except LookupError as e:
                # The pack's own country is checked after merging (check_osm_coverage).
                (log.error if c.code == country.code else log.warning)("no OSM peaks for %s: %s", c.code, e)

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

    # Extracts of neighbouring countries overlap at the border, so the same OSM node can appear twice.
    unique: dict[int, Peak] = {}
    for p in osm_peaks:
        unique.setdefault(p.osm_id, p)
    osm_peaks = list(unique.values())
    log.info("raw peaks: osm=%d wikidata=%d geonames=%d", len(osm_peaks), len(wd_peaks), len(gn_peaks))
    merged = merge_peaks(osm_peaks, wd_peaks, gn_peaks)
    inside = prep(area)
    result = [p for p in merged if inside.contains(Point(p.lon, p.lat))]
    check_osm_coverage(country, result, opts)
    return result, [c.code for c in involved]


def build_pack(code: str, out: Path, cache_dir: Path, opts: PackOptions) -> dict:
    t0 = time.time()
    code = code.upper()
    countries = load_countries(cache_dir)
    if code not in countries:
        raise KeyError(f"unknown country code {code}")
    country = countries[code]
    if opts.clip:
        country = Country(country.code, country.name, country.geometry.intersection(box(*opts.clip)),
                          country.wikidata, country.continent)
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
        if opts.tile_index:
            index = load_tile_index(opts.tile_index, res.value)
            entries = [index[t.name] for t in tiles if t.name in index]
            if res == opts.resolutions[0]:
                missing = [t.name for t in tiles if src.exists(t) and t.name not in index]
                if missing:
                    raise RuntimeError(f"{len(missing)} {res.value} m tiles not in the published index: {missing[:5]}")
            manifest["tiles"][res.value] = [{k: e[k] for k in ("name", "bytes", "sha256")} for e in entries]
        else:
            only = None
            if res == Resolution.GLO30:
                only = lambda t: is_mountainous(t, out_v, opts.hd_min_relief, opts.hd_min_peak)  # noqa: E731
            entries = build_tiles(tiles, src, out_v, opts.codec, workers=opts.workers, only=only)
            manifest["tiles"][res.value] = [{k: e[k] for k in ("name", "bytes", "sha256")} for e in entries]

    # Peaks: the area is the land tiles of the base resolution.
    base = sources[opts.resolutions[0]]
    land = [t for t in tiles if base.exists(t)]
    if opts.peaks_db:
        from .peaks.db import read_peak_db

        area = prep(unary_union([box(*t.bounds) for t in land]))
        peaks = [p for p in read_peak_db(opts.peaks_db) if area.contains(Point(p.lon, p.lat))]
        involved = [code]
        log.info("reusing %d peaks from %s", len(peaks), opts.peaks_db)
    else:
        peaks, involved = collect_peaks(country, countries, land, cache_dir, opts)
        add_dem_heights(peaks, base.grid)
        compute_isolation(peaks)
    texts: dict = {}
    if opts.use_wikipedia_text:
        try:
            texts = wikitext.collect(peaks, cache_dir)
        except Exception as e:  # nice to have: never fail a pack over it
            log.warning("wikipedia texts for %s skipped: %s", code, e)
    db_path = out / "build" / f"{code}.sqlite"
    write_peak_db(db_path, peaks, {"country": code, "built_at": manifest["built_at"],
                                   "sources": ",".join(involved)}, texts)
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
        "wikipedia_texts": len(texts),
        "tiles": {r: len(v) for r, v in manifest["tiles"].items()},
        "tile_mb": {r: round(sum(e["bytes"] for e in v) / 1e6, 1) for r, v in manifest["tiles"].items()},
        "peaks": len(peaks),
        "peaks_by_source": _count_sources(peaks),
        # OSM peaks inside the country itself; 0 means its extract was missing (see check_osm_coverage).
        "osm_peaks_in_country": osm_peaks_inside(country, peaks),
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


def build_country_tiles(codes: list[str], out: Path, cache_dir: Path, opts: PackOptions,
                        evict_hd_sources: bool = True) -> dict:
    """Tiles only (no peaks/manifests), e.g. to publish a continent's tiles before its peak DBs exist."""
    countries = load_countries(cache_dir)
    out_v = out / f"v{FORMAT_VERSION}"
    sources = {r: TileSource(r, cache_dir) for r in opts.resolutions}
    summary = {}
    for code in codes:
        geom = countries[code].geometry
        if opts.clip:
            geom = geom.intersection(box(*opts.clip))
        if geom.is_empty:
            continue
        tiles = tiles_for_geometry(geom, opts.buffer_km)
        counts = {}
        for res, src in sources.items():
            only = None
            if res == Resolution.GLO30:
                only = lambda t: is_mountainous(t, out_v, opts.hd_min_relief, opts.hd_min_peak)  # noqa: E731
            counts[res.value] = len(build_tiles(tiles, src, out_v, opts.codec, workers=opts.workers, only=only))
            if res == Resolution.GLO30 and evict_hd_sources:
                for f in src.cache_dir.glob("*.tif"):  # 40 MB each; re-downloaded if another country needs one
                    f.unlink()
        summary[code] = counts
        log.info("%s: %s", code, counts)
    return summary
