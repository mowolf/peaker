"""Country polygons (Natural Earth admin-0, public domain) and country → tile selection."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

from shapely.geometry import box, shape
from shapely.geometry.base import BaseGeometry
from shapely.ops import unary_union

from .http import download
from .tiles import TileId, tiles_in_bbox

NE_URL = "https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_0_countries.zip"
KM_PER_DEG = 111.32


@dataclass
class Country:
    code: str  # ISO 3166-1 alpha-2
    name: str
    geometry: BaseGeometry  # lon/lat, EPSG:4326
    wikidata: str | None = None
    continent: str | None = None

    @property
    def bbox(self) -> tuple[float, float, float, float]:
        return self.geometry.bounds


def load_countries(cache_dir: Path) -> dict[str, Country]:
    """ISO alpha-2 → Country. Uses ``ISO_A2_EH`` because ``ISO_A2`` is -99 for e.g. France and Norway."""
    path = Path(cache_dir) / "naturalearth" / "ne_10m_admin_0_countries.zip"
    if not path.exists():
        download(NE_URL, path)
    out: dict[str, Country] = {}
    for code, name, qid, continent, geom in _read_rows(path):
        if not code or code == "-99" or geom is None:
            continue
        if code in out:  # some codes appear more than once (e.g. overseas parts) → merge
            out[code].geometry = unary_union([out[code].geometry, geom])
        else:
            out[code] = Country(code, name, geom, qid or None, continent or None)
    return out


def _read_rows(path: Path):
    import pyogrio
    from shapely import from_wkb

    wanted = ["ISO_A2_EH", "NAME_EN", "WIKIDATAID", "CONTINENT"]
    meta, _, geoms, fields = pyogrio.raw.read(f"/vsizip/{path}", columns=wanted)
    idx = {name: i for i, name in enumerate(meta["fields"])}  # returned in file order, not request order
    cols = [fields[idx[w]] for w in wanted]
    for code, name, qid, continent, wkb in zip(*cols, geoms):
        yield code, name, qid, continent, (from_wkb(wkb) if wkb is not None else None)


def tiles_for_geometry(geom: BaseGeometry, buffer_km: float) -> list[TileId]:
    """Tiles that intersect ``geom`` or lie within ``buffer_km`` of it.

    Distances use a local equirectangular approximation per tile (x scaled by
    cos(lat)), which slightly over-includes near the poles. That's the safe direction.
    """
    west, south, east, north = geom.bounds
    pad_lat = buffer_km / KM_PER_DEG
    max_abs_lat = min(89.0, max(abs(south), abs(north)) + pad_lat)
    pad_lon = min(180.0, buffer_km / (KM_PER_DEG * max(math.cos(math.radians(max_abs_lat)), 0.05)))
    candidates = tiles_in_bbox(max(-180, west - pad_lon), max(-90, south - pad_lat),
                               min(180, east + pad_lon), min(90, north + pad_lat))
    # Natural Earth splits geometries at the antimeridian, so also look across it.
    if west - pad_lon < -180:
        candidates += tiles_in_bbox(360 + west - pad_lon, max(-90, south - pad_lat), 180, min(90, north + pad_lat))
    if east + pad_lon > 180:
        candidates += tiles_in_bbox(-180, max(-90, south - pad_lat), east + pad_lon - 360, min(90, north + pad_lat))

    out = set()
    for t in set(candidates):
        tb = box(*t.bounds)
        if geom.intersects(tb):
            out.add(t)
            continue
        if buffer_km <= 0:
            continue
        coslat = max(math.cos(math.radians(t.lat + 0.5)), 0.05)
        for shift in (0.0, 360.0, -360.0):  # tile seen across the antimeridian
            near = geom.intersection(box(t.lon + shift - pad_lon, t.lat - pad_lat,
                                         t.lon + shift + 1 + pad_lon, t.lat + 1 + pad_lat))
            if near.is_empty:
                continue
            d = _scaled_distance(near, box(t.lon + shift, t.lat, t.lon + shift + 1, t.lat + 1), coslat)
            if d * KM_PER_DEG <= buffer_km:
                out.add(t)
                break
    return sorted(out, key=lambda t: (-t.lat, t.lon))  # north→south, west→east (cache friendly)


def _scaled_distance(a: BaseGeometry, b: BaseGeometry, coslat: float) -> float:
    from shapely import affinity

    return affinity.scale(a, xfact=coslat, yfact=1, origin=(0, 0)).distance(
        affinity.scale(b, xfact=coslat, yfact=1, origin=(0, 0)))


def geometry_from_geojson(path: Path) -> BaseGeometry:
    """For custom regions (e.g. "Alps"): any GeoJSON Feature/FeatureCollection/geometry."""
    data = json.loads(Path(path).read_text())
    if data.get("type") == "FeatureCollection":
        return unary_union([shape(f["geometry"]) for f in data["features"]])
    if data.get("type") == "Feature":
        return shape(data["geometry"])
    return shape(data)
