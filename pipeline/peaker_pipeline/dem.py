"""Download Copernicus DEM tiles and turn them into Peaker grids.

A Peaker grid for tile ``N45E007`` at GLO-90 has 1201 rows × (cols + 1) columns:
row 0 is lat 46.0, the last row lat 45.0; column 0 is lon 7.0, the last
column lon 8.0. The extra row/column comes from the southern/eastern
neighbour, so the app can interpolate inside one tile. Missing neighbours
(ocean, or not in the dataset) are filled by repeating the edge.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .http import download
from .tiles import Resolution, TileId

log = logging.getLogger(__name__)


@dataclass
class Grid:
    tile: TileId
    res: Resolution
    heights: np.ndarray  # float32, shape (rows, cols), row 0 = north edge

    @property
    def rows(self) -> int:
        return self.heights.shape[0]

    @property
    def cols(self) -> int:
        return self.heights.shape[1]

    def latlon_of(self, r: int, c: int) -> tuple[float, float]:
        lat = self.tile.lat + 1 - r / (self.rows - 1)
        lon = self.tile.lon + c / (self.cols - 1)
        return lat, lon

    def index_of(self, lat: float, lon: float) -> tuple[float, float]:
        """Fractional (row, col) of a coordinate inside this tile."""
        r = (self.tile.lat + 1 - lat) * (self.rows - 1)
        c = (lon - self.tile.lon) * (self.cols - 1)
        return r, c

    def sample(self, lat: float, lon: float) -> float:
        """Bilinear sample (same maths the app uses)."""
        r, c = self.index_of(lat, lon)
        r0 = int(np.clip(np.floor(r), 0, self.rows - 2))
        c0 = int(np.clip(np.floor(c), 0, self.cols - 2))
        fr, fc = r - r0, c - c0
        h = self.heights
        top = h[r0, c0] * (1 - fc) + h[r0, c0 + 1] * fc
        bot = h[r0 + 1, c0] * (1 - fc) + h[r0 + 1, c0 + 1] * fc
        return float(top * (1 - fr) + bot * fr)

    def max_near(self, lat: float, lon: float, radius_m: float) -> float:
        """Highest grid value within ``radius_m`` (square window) — used to check summits."""
        r, c = self.index_of(lat, lon)
        dr = max(1, int(np.ceil(radius_m / 111_320 * (self.rows - 1))))
        coslat = max(np.cos(np.radians(lat)), 0.01)
        dc = max(1, int(np.ceil(radius_m / (111_320 * coslat) * (self.cols - 1))))
        r, c = int(round(r)), int(round(c))
        win = self.heights[max(0, r - dr) : r + dr + 1, max(0, c - dc) : c + dc + 1]
        return float(win.max()) if win.size else float("nan")


class TileSource:
    """Copernicus DEM tiles with a local download cache."""

    def __init__(self, res: Resolution, cache_dir: Path | str):
        self.res = res
        self.cache_dir = Path(cache_dir) / f"copernicus-{res.value}m"
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._available: set[TileId] | None = None
        # Each grid also reads 3 neighbours; processing tiles row by row keeps hits high.
        self._read_cache: dict[TileId, np.ndarray | None] = {}
        self._read_cache_size = 12

    # -- availability --------------------------------------------------------
    @property
    def available(self) -> set[TileId]:
        """Tiles that exist in the dataset. Anything else is ocean (or withheld)."""
        if self._available is None:
            path = self.cache_dir / "tileList.txt"
            if not path.exists():
                download(f"https://{self.res.bucket}.s3.amazonaws.com/tileList.txt", path)
            self._available = {
                TileId.from_copernicus_name(line) for line in path.read_text().splitlines() if line.strip()
            }
        return self._available

    def exists(self, tile: TileId) -> bool:
        return tile in self.available

    # -- raw source tiles ------------------------------------------------------
    def source_path(self, tile: TileId) -> Path | None:
        if not self.exists(tile):
            return None
        path = self.cache_dir / f"{tile.copernicus_name(self.res)}.tif"
        if not path.exists():
            log.info("downloading %s (%s m)", tile, self.res.value)
            download(tile.copernicus_url(self.res), path)
        return path

    def read_source(self, tile: TileId) -> np.ndarray | None:
        if tile in self._read_cache:
            self._read_cache[tile] = self._read_cache.pop(tile)  # mark as recently used
            return self._read_cache[tile]
        path = self.source_path(tile)
        a = None
        if path is not None:
            import rasterio

            with rasterio.open(path) as ds:
                a = ds.read(1).astype(np.float32)
                nodata = ds.nodata
            if nodata is not None:
                a[a == nodata] = np.nan
        self._read_cache[tile] = a
        while len(self._read_cache) > self._read_cache_size:
            self._read_cache.pop(next(iter(self._read_cache)))
        return a

    # -- Peaker grid -----------------------------------------------------------
    def grid(self, tile: TileId) -> Grid | None:
        """Source tile + southern row + eastern column. ``None`` for ocean tiles."""
        a = self.read_source(tile)
        if a is None:
            return None
        rows, cols = a.shape

        south = self._edge_row(tile, cols)
        east = self._edge_col(tile, rows)
        corner = self._corner(tile)
        if south is None:
            south = a[-1, :].copy()
        if east is None:
            east = a[:, -1].copy()
        if corner is None:
            corner = south[-1] if np.isfinite(south[-1]) else east[-1]

        out = np.empty((rows + 1, cols + 1), dtype=np.float32)
        out[:rows, :cols] = a
        out[rows, :cols] = south
        out[:rows, cols] = east
        out[rows, cols] = corner
        out = fill_voids(out)
        return Grid(tile, self.res, out)

    def _edge_row(self, tile: TileId, cols: int) -> np.ndarray | None:
        """First row (north edge) of the southern neighbour, resampled to ``cols``."""
        n = tile.neighbour(-1, 0)
        a = self.read_source(n) if n else None
        if a is None:
            return None
        row = a[0, :]
        if row.size == cols:
            return row
        # Latitude band boundary (e.g. 50°): neighbour has a different column count.
        src_x = np.arange(row.size) / row.size
        dst_x = np.arange(cols) / cols
        return np.interp(dst_x, src_x, row).astype(np.float32)

    def _edge_col(self, tile: TileId, rows: int) -> np.ndarray | None:
        n = tile.neighbour(0, 1)
        a = self.read_source(n) if n else None
        if a is None:
            return None
        return a[:, 0]  # same latitude band ⇒ same row count

    def _corner(self, tile: TileId) -> float | None:
        n = tile.neighbour(-1, 1)
        a = self.read_source(n) if n else None
        return None if a is None else float(a[0, 0])


def fill_voids(a: np.ndarray, sea_level: float = 0.0) -> np.ndarray:
    """Replace NaNs by the mean of valid neighbours, repeated until filled.

    Copernicus has very few voids; this is a safety net. A grid that is all
    NaN becomes sea level.
    """
    a = a.copy()
    mask = ~np.isfinite(a)
    if not mask.any():
        return a
    if mask.all():
        a[:] = sea_level
        return a
    for _ in range(max(a.shape)):
        if not mask.any():
            break
        vals = np.where(mask, 0.0, a)
        cnt = (~mask).astype(np.float32)
        p_vals = np.pad(vals, 1)
        p_cnt = np.pad(cnt, 1)
        s = p_vals[:-2, 1:-1] + p_vals[2:, 1:-1] + p_vals[1:-1, :-2] + p_vals[1:-1, 2:]
        n = p_cnt[:-2, 1:-1] + p_cnt[2:, 1:-1] + p_cnt[1:-1, :-2] + p_cnt[1:-1, 2:]
        fill = mask & (n > 0)
        a[fill] = s[fill] / n[fill]
        mask &= ~fill
    return a


def default_cache_dir() -> Path:
    return Path(os.environ.get("PEAKER_CACHE", Path.home() / ".cache" / "peaker"))
