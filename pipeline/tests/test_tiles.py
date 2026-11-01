import pytest

from peaker_pipeline.tiles import Resolution, TileId, copernicus_cols, tiles_in_bbox


def test_names_roundtrip():
    for lat, lon, name in [(45, 7, "N45E007"), (-33, -70, "S33W070"), (0, 0, "N00E000"), (-1, -1, "S01W001"),
                           (89, 179, "N89E179"), (-90, -180, "S90W180")]:
        t = TileId(lat, lon)
        assert t.name == name
        assert TileId.parse(name) == t


def test_containing_handles_negative_and_wrap():
    assert TileId.containing(45.97, 7.65).name == "N45E007"
    assert TileId.containing(-0.5, -0.5).name == "S01W001"
    assert TileId.containing(10.0, 180.0).name == "N10W180"
    assert TileId.containing(90.0, 0.0).lat == 89


def test_copernicus_names():
    t = TileId(45, 7)
    assert t.copernicus_name(Resolution.GLO90) == "Copernicus_DSM_COG_30_N45_00_E007_00_DEM"
    assert t.copernicus_name(Resolution.GLO30) == "Copernicus_DSM_COG_10_N45_00_E007_00_DEM"
    assert TileId.from_copernicus_name("Copernicus_DSM_COG_30_S33_00_W070_00_DEM") == TileId(-33, -70)
    assert t.copernicus_url(Resolution.GLO90).startswith("https://copernicus-dem-90m.s3.amazonaws.com/")


@pytest.mark.parametrize("lat,cols", [(45, 1200), (-50, 1200), (52, 800), (-51, 800), (61, 600), (75, 400),
                                      (82, 240), (87, 120)])
def test_copernicus_cols(lat, cols):
    assert copernicus_cols(lat, Resolution.GLO90) == cols


def test_neighbour_wraps_antimeridian():
    assert TileId(10, 179).neighbour(0, 1) == TileId(10, -180)
    assert TileId(89, 0).neighbour(1, 0) is None


def test_tiles_in_bbox():
    assert len(tiles_in_bbox(6.5, 45.5, 8.5, 46.5)) == 3 * 2
    across = tiles_in_bbox(179.2, -17.5, -179.5, -16.2)  # crosses antimeridian (Fiji)
    assert {t.name for t in across} == {"S18E179", "S17E179", "S18W180", "S17W180"}
