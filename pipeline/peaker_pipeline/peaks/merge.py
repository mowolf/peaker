"""Merge peaks from OSM, Wikidata and GeoNames into one list.

Priority for position and local name: OSM > Wikidata > GeoNames. Matching:

1. by ID: OSM ``wikidata=Q…`` tag ↔ Wikidata item, Wikidata P11693 ↔ OSM node id
2. by distance + name: within ``name_radius_m`` and names match
3. by distance only: within ``blind_radius_m`` (when one of the names is missing)
"""

from __future__ import annotations

import math
from collections import defaultdict
from typing import Iterable

import numpy as np

from .model import Peak, names_match

EARTH_RADIUS_M = 6_371_008.8


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


class _Grid:
    """Bucket peaks into ~1 km cells for neighbour lookups."""

    def __init__(self, cell_deg: float = 0.01):
        self.cell = cell_deg
        self.buckets: dict[tuple[int, int], list[Peak]] = defaultdict(list)

    def key(self, lat: float, lon: float) -> tuple[int, int]:
        return int(math.floor(lat / self.cell)), int(math.floor(lon / self.cell))

    def add(self, p: Peak) -> None:
        self.buckets[self.key(p.lat, p.lon)].append(p)

    def near(self, lat: float, lon: float, radius_m: float) -> Iterable[tuple[float, Peak]]:
        r_lat = radius_m / 111_320
        r_lon = radius_m / (111_320 * max(math.cos(math.radians(lat)), 0.01))
        k0 = self.key(lat - r_lat, lon - r_lon)
        k1 = self.key(lat + r_lat, lon + r_lon)
        for i in range(k0[0], k1[0] + 1):
            for j in range(k0[1], k1[1] + 1):
                for p in self.buckets.get((i, j), ()):
                    d = haversine_m(lat, lon, p.lat, p.lon)
                    if d <= radius_m:
                        yield d, p


def _absorb(base: Peak, other: Peak) -> None:
    """Fill gaps in ``base`` from ``other`` (base keeps its position and local name)."""
    for lang, n in other.names.items():
        base.names.setdefault(lang, n)
    if other.name and other.name != base.name and other.name not in base.alt_names:
        if base.name is None:
            base.name = other.name
        else:
            base.alt_names.append(other.name)
    for a in other.alt_names:
        if a not in base.alt_names and a != base.name:
            base.alt_names.append(a)
    if base.ele is None and other.ele is not None:
        base.ele, base.ele_source = other.ele, other.ele_source
    base.prominence = base.prominence if base.prominence is not None else other.prominence
    base.wikidata = base.wikidata or other.wikidata
    base.osm_id = base.osm_id if base.osm_id is not None else other.osm_id
    base.geonames_id = base.geonames_id if base.geonames_id is not None else other.geonames_id
    base.wikipedia = base.wikipedia or other.wikipedia
    if base.kind == "peak" and other.kind == "volcano":
        base.kind = "volcano"
    base.sources += [s for s in other.sources if s not in base.sources]


def merge_peaks(osm: list[Peak], wikidata: list[Peak], geonames: list[Peak],
                name_radius_m: float = 600, blind_radius_m: float = 150) -> list[Peak]:
    merged: list[Peak] = list(osm)
    grid = _Grid()
    by_qid: dict[str, Peak] = {}
    by_osm: dict[int, Peak] = {}
    for p in merged:
        grid.add(p)
        if p.wikidata:
            by_qid[p.wikidata] = p
        if p.osm_id is not None:
            by_osm[p.osm_id] = p

    def find(c: Peak) -> Peak | None:
        if c.wikidata and c.wikidata in by_qid:
            return by_qid[c.wikidata]
        if c.osm_id is not None and c.osm_id in by_osm:
            return by_osm[c.osm_id]
        best: tuple[float, Peak] | None = None
        for d, p in grid.near(c.lat, c.lon, name_radius_m):
            ok = names_match(p.name, c.name) or any(names_match(n, c.name) for n in p.names.values()) \
                or any(names_match(p.name, n) for n in c.names.values())
            if not ok and d <= blind_radius_m and (not p.name or not c.name):
                ok = True
            # Don't let two different Wikidata items collapse into one.
            if ok and p.wikidata and c.wikidata and p.wikidata != c.wikidata:
                ok = False
            if ok and (best is None or d < best[0]):
                best = (d, p)
        return best[1] if best else None

    for source in (wikidata, geonames):
        for c in source:
            target = find(c)
            if target is None:
                merged.append(c)
                grid.add(c)
                target = c
            else:
                _absorb(target, c)
            if target.wikidata:
                by_qid[target.wikidata] = target
            if target.osm_id is not None:
                by_osm[target.osm_id] = target
    # Peaks without any name are useless as labels.
    return [p for p in merged if p.display_name()]


def compute_isolation(peaks: list[Peak], max_km: float = 500.0) -> None:
    """Isolation = distance to the nearest higher peak (km). The highest peak gets ``max_km``.

    Used as a ranking fallback where prominence is unknown. Computed only
    within the given set, so values near the edge of a pack are approximate.
    """
    from scipy.spatial import cKDTree

    pts = [p for p in peaks if _height(p) is not None]
    if not pts:
        return
    lat = np.radians([p.lat for p in pts])
    lon = np.radians([p.lon for p in pts])
    xyz = np.column_stack([np.cos(lat) * np.cos(lon), np.cos(lat) * np.sin(lon), np.sin(lat)])
    h = np.array([_height(p) for p in pts])
    tree = cKDTree(xyz)
    n = len(pts)
    for i, p in enumerate(pts):
        k = 16
        found = None
        while found is None:
            kk = min(k, n)
            dist, idx = tree.query(xyz[i], k=kk)
            dist, idx = np.atleast_1d(dist), np.atleast_1d(idx)
            higher = h[idx] > h[i]
            if higher.any():
                found = float(dist[higher][0])  # chord length on the unit sphere
            elif kk == n:
                break
            k *= 4
        if found is None:
            p.isolation_km = max_km
        else:
            p.isolation_km = min(max_km, 2 * math.asin(min(1.0, found / 2)) * EARTH_RADIUS_M / 1000)


def _height(p: Peak) -> float | None:
    return p.ele if p.ele is not None else p.dem_ele


def importance(p: Peak) -> float:
    """0..1 score for label priority when labels collide.

    Prominence is the best signal; isolation stands in where it's missing.
    A Wikipedia article and a name are small bonuses. Tuned by eye, revisit with the app.
    """
    if p.prominence is not None and p.prominence > 0:
        s = min(1.0, math.log10(1 + p.prominence) / math.log10(1 + 4000))
    elif p.isolation_km is not None:
        s = 0.9 * min(1.0, math.log10(1 + p.isolation_km) / math.log10(1 + 300))
    else:
        s = 0.1
    if p.wikipedia:
        s += 0.1
    if p.kind == "hill":
        s *= 0.7
    return round(min(1.0, s), 4)
