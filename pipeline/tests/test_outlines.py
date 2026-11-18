from shapely.geometry import MultiPolygon, Polygon, box

from peaker_pipeline.countries import Country
from peaker_pipeline.outlines import decode, encode


def test_round_trip_with_hole_and_dropped_islet():
    outer = box(0, 0, 10, 10)
    with_hole = Polygon(outer.exterior.coords, [box(4, 4, 6, 6).exterior.coords])
    islet = box(20, 20, 20.001, 20.001)
    countries = {
        "ZA": Country("ZA", "South Africa", MultiPolygon([with_hole, islet])),
        "LS": Country("LS", "Lesotho", box(4, 4, 6, 6)),
        "-99": Country("-99", "Nowhere", box(0, 0, 1, 1)),
    }
    out = decode(encode(countries, tolerance=0.02))
    assert sorted(out) == ["LS", "ZA"]
    assert len(out["ZA"]) == 2  # outer ring and the hole; the islet is dropped
    assert len(out["ZA"][0]) == 4 and (0.0, 0.0) in out["ZA"][0]
    assert len(out["LS"]) == 1


def test_lakes_are_one_more_entry():
    countries = {"CH": Country("CH", "Switzerland", box(6, 45.8, 10.5, 47.8))}
    lakes = MultiPolygon([box(6.2, 46.2, 6.9, 46.5), box(8.9, 47.5, 9.7, 47.7)])
    out = decode(encode(countries, tolerance=0.02, lakes=lakes))
    assert sorted(out) == ["CH", "~~"]
    assert len(out["~~"]) == 2
