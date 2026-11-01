"""Add DEM heights to peaks and flag suspicious elevations."""

from __future__ import annotations

import logging
from collections import defaultdict
from typing import Callable

from ..dem import Grid
from ..tiles import TileId
from .model import Peak

log = logging.getLogger(__name__)


def add_dem_heights(peaks: list[Peak], grid_for: Callable[[TileId], Grid | None],
                    radius_m: float = 120.0) -> None:
    """Set ``dem_ele`` = highest DEM value within ``radius_m`` (peaks are often a few pixels off).

    Peaks without an official elevation get ``ele = dem_ele`` with source "dem".
    """
    by_tile: dict[TileId, list[Peak]] = defaultdict(list)
    for p in peaks:
        by_tile[TileId.containing(p.lat, p.lon)].append(p)
    for tile in sorted(by_tile, key=lambda t: (-t.lat, t.lon)):
        g = grid_for(tile)
        for p in by_tile[tile]:
            if g is None:
                continue
            p.dem_ele = round(g.max_near(p.lat, p.lon, radius_m), 1)
            if p.ele is None:
                p.ele, p.ele_source = p.dem_ele, "dem"


def elevation_report(peaks: list[Peak], threshold_m: float = 150.0) -> dict:
    """Stats on official vs DEM elevation. Large gaps hint at wrong tags or wrong positions."""
    import numpy as np

    diffs = np.array([p.ele - p.dem_ele for p in peaks
                      if p.ele is not None and p.dem_ele is not None and p.ele_source != "dem"])
    suspicious = [p for p in peaks if p.ele is not None and p.dem_ele is not None and p.ele_source != "dem"
                  and abs(p.ele - p.dem_ele) > threshold_m]
    if diffs.size == 0:
        return {"count": 0}
    return {
        "count": int(diffs.size),
        "median_official_minus_dem_m": round(float(np.median(diffs)), 1),
        "p90_abs_diff_m": round(float(np.percentile(np.abs(diffs), 90)), 1),
        "suspicious_over_%dm" % threshold_m: len(suspicious),
        "suspicious_examples": [
            {"id": p.id, "name": p.display_name(), "ele": p.ele, "dem_ele": p.dem_ele, "source": p.ele_source}
            for p in sorted(suspicious, key=lambda p: -abs(p.ele - p.dem_ele))[:15]
        ],
    }
