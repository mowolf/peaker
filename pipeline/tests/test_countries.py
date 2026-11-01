from shapely.geometry import Polygon, box

from peaker_pipeline.countries import tiles_for_geometry


def test_tiles_without_buffer():
    poly = box(7.2, 45.2, 8.8, 46.8)
    assert {t.name for t in tiles_for_geometry(poly, 0)} == {"N45E007", "N45E008", "N46E007", "N46E008"}


def test_buffer_adds_nearby_tiles_only():
    poly = box(7.5, 45.5, 7.6, 45.6)  # small square inside N45E007
    names = {t.name for t in tiles_for_geometry(poly, 50)}
    assert "N45E007" in names
    assert "N45E006" in names  # 7.5°E is ~39 km from 7.0°E at 45.5°N
    assert "N45E008" in names  # 8.0 is ~31 km away
    assert "N47E007" not in names  # > 150 km away
    assert len(tiles_for_geometry(poly, 10)) == 1


def test_antimeridian():
    poly = Polygon([(179.5, -17), (180, -17), (180, -16.5), (179.5, -16.5)])
    names = {t.name for t in tiles_for_geometry(poly, 30)}
    assert "S17E179" in names and "S17W180" in names
