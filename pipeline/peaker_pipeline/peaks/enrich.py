"""Add DEM heights to peaks, and repair or flag implausible elevations and positions.

The DEM is the referee. Copernicus cuts sharp summits by up to ~150 m and
its 90 m pixels miss narrow tops, so an official height is *plausible* when it
lies within ``[dem - TOL_BELOW, dem + TOL_ABOVE]`` of the highest DEM point
near the peak. For each peak, in order:

1. the primary elevation, then the other sources' values (``ele_alts``): first plausible one wins
2. unit fix: values < 10 that become plausible ×1000 ("2.257" typed for 2,257 m)
3. snap: for peaks without OSM position, the highest DEM point within
   ``SNAP_RADIUS_M`` that matches a source's height becomes the position (bad Wikidata/GeoNames coordinates)
4. otherwise: DEM height, flagged ``ele_conflict``

The ``qa`` flags go into the DB, so the app and future reviews can see what was changed.
"""

from __future__ import annotations

import logging
from collections import defaultdict
from typing import Callable

from ..dem import Grid
from ..tiles import TileId
from .model import Peak

log = logging.getLogger(__name__)

SUMMIT_RADIUS_M = 120.0
SNAP_RADIUS_M = 1500.0
TOL_ABOVE = 250.0  # official may exceed DEM a lot (sharp summits, small pinnacles)
TOL_BELOW = 100.0  # official below the DEM max nearby: usually a wrong value or a fore-summit


def plausible(value: float, dem: float) -> bool:
    return dem - TOL_BELOW <= value <= dem + TOL_ABOVE


def resolve_elevation(p: Peak, g: Grid) -> None:
    dem = round(g.max_near(p.lat, p.lon, SUMMIT_RADIUS_M), 1)
    p.dem_ele = dem
    candidates = ([(p.ele_source or "?", p.ele)] if p.ele is not None else []) + list(p.ele_alts)
    if not candidates:
        p.ele, p.ele_source = dem, "dem"
        return

    for i, (src, v) in enumerate(candidates):
        if plausible(v, dem):
            if i > 0:
                p.qa.append("alt_source")
            p.ele, p.ele_source = v, src
            return

    for src, v in candidates:
        if 0 < v < 10 and plausible(v * 1000, dem):
            p.ele, p.ele_source = round(v * 1000, 1), src
            p.qa.append("unit_fixed")
            return

    if "osm" not in p.sources:
        h, lat, lon = g.argmax_near(p.lat, p.lon, SNAP_RADIUS_M)
        for src, v in candidates:
            for value, flag in ((v, None), (v * 1000, "unit_fixed")):
                if plausible(value, h):
                    p.lat, p.lon = round(lat, 6), round(lon, 6)
                    p.ele, p.ele_source, p.dem_ele = round(value, 1), src, round(h, 1)
                    p.qa += ["snapped"] + ([flag] if flag else [])
                    return

    p.ele_alts = [(p.ele_source or "?", p.ele)] + [a for a in p.ele_alts]
    p.ele, p.ele_source = dem, "dem"
    p.qa.append("ele_conflict")


def add_dem_heights(peaks: list[Peak], grid_for: Callable[[TileId], Grid | None]) -> None:
    by_tile: dict[TileId, list[Peak]] = defaultdict(list)
    for p in peaks:
        by_tile[TileId.containing(p.lat, p.lon)].append(p)
    for tile in sorted(by_tile, key=lambda t: (-t.lat, t.lon)):
        g = grid_for(tile)
        if g is None:
            continue
        for p in by_tile[tile]:
            resolve_elevation(p, g)


def elevation_report(peaks: list[Peak]) -> dict:
    """QA summary for reports/<CC>.json."""
    import numpy as np

    flags: dict[str, int] = defaultdict(int)
    for p in peaks:
        for f in p.qa:
            flags[f] += 1
    official = [p for p in peaks if p.ele is not None and p.dem_ele is not None and p.ele_source != "dem"]
    diffs = np.array([p.ele - p.dem_ele for p in official])
    conflicts = [p for p in peaks if "ele_conflict" in p.qa]
    return {
        "with_official_height": len(official),
        "median_official_minus_dem_m": round(float(np.median(diffs)), 1) if diffs.size else None,
        "p90_abs_diff_m": round(float(np.percentile(np.abs(diffs), 90)), 1) if diffs.size else None,
        "qa_flags": dict(sorted(flags.items())),
        "conflict_examples": [
            {"id": p.id, "name": p.display_name(), "dem_ele": p.dem_ele,
             "claimed": [list(a) for a in p.ele_alts], "sources": p.sources}
            for p in sorted(conflicts, key=lambda p: -abs((p.ele_alts[0][1] if p.ele_alts else 0) - (p.dem_ele or 0)))[:15]
        ],
        "snapped_examples": [
            {"id": p.id, "name": p.display_name(), "ele": p.ele, "lat": p.lat, "lon": p.lon}
            for p in peaks if "snapped" in p.qa
        ][:10],
    }
