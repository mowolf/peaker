import numpy as np

from peaker_pipeline.dem import Grid, fill_voids
from peaker_pipeline.tiles import Resolution, TileId


def test_fill_voids():
    a = np.array([[1, 1, 1], [1, np.nan, 1], [np.nan, np.nan, 3]], dtype=np.float32)
    f = fill_voids(a)
    assert np.isfinite(f).all()
    assert f[1, 1] == 1
    assert np.isnan(fill_voids(np.full((2, 2), np.nan))).sum() == 0


def test_grid_geometry_and_sampling():
    # 1201×1201 grid: row 0 = lat 46, last row = lat 45; heights = 1000 * lat + lon (planar → bilinear exact)
    rows = cols = 1201
    lat = 46 - np.arange(rows) / (rows - 1)
    lon = 7 + np.arange(cols) / (cols - 1)
    h = (1000 * lat[:, None] + lon[None, :]).astype(np.float64)
    g = Grid(TileId(45, 7), Resolution.GLO90, h)
    assert g.latlon_of(0, 0) == (46.0, 7.0)
    assert g.latlon_of(1200, 1200) == (45.0, 8.0)
    assert abs(g.sample(45.5, 7.5) - (45500 + 7.5)) < 1e-6
    assert abs(g.sample(45.123456, 7.987654) - (45123.456 + 7.987654)) < 1e-6
    assert g.max_near(45.5, 7.5, 200) > g.sample(45.5, 7.5)
