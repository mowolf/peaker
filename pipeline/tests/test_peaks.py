import sqlite3
import textwrap

import pytest

from peaker_pipeline.peaks.db import write_peak_db
from peaker_pipeline.peaks.merge import compute_isolation, haversine_m, importance, merge_peaks
from peaker_pipeline.peaks.model import Peak, names_match, normalise_name, parse_ele
from peaker_pipeline.peaks.osm import read_osm_peaks
from peaker_pipeline.peaks.wikidata import rows_to_peaks


@pytest.mark.parametrize("raw,expected", [("4478", 4478), ("4478 m", 4478), ("4478.5", 4478.5), ("4478,5", 4478.5),
                                          ("14505 ft", 14505 * 0.3048), ("~3000", 3000), ("4,478", None),
                                          ("high", None), ("", None), (None, None), ("99999", None)])
def test_parse_ele(raw, expected):
    v = parse_ele(raw)
    assert (v is None and expected is None) or abs(v - expected) < 1e-6


def test_names():
    assert normalise_name("Piz Bernina!") == "piz bernina"
    assert normalise_name("Mönch") == "monch"
    assert names_match("Matterhorn", "Monte Cervino / Matterhorn")
    assert names_match("Dufourspitze", "Dufour Spitze")
    assert not names_match("Eiger", "Mönch")
    assert not names_match(None, "Eiger")


def test_haversine():
    # Matterhorn → Dufourspitze ≈ 16.7 km
    assert 16_000 < haversine_m(45.9763, 7.6586, 45.9369, 7.8668) < 17_500


def test_read_osm_xml(tmp_path):
    xml = textwrap.dedent("""\
        <?xml version="1.0" encoding="UTF-8"?>
        <osm version="0.6">
          <node id="1" lat="45.9763" lon="7.6586" version="1">
            <tag k="natural" v="peak"/><tag k="name" v="Matterhorn"/><tag k="name:it" v="Monte Cervino"/>
            <tag k="ele" v="4478"/><tag k="wikidata" v="Q1374"/><tag k="alt_name" v="Cervin;Horu"/>
          </node>
          <node id="2" lat="46.0" lon="7.0" version="1"><tag k="natural" v="tree"/></node>
          <node id="3" lat="40.8" lon="14.4" version="1"><tag k="natural" v="volcano"/><tag k="name" v="Vesuvio"/></node>
          <node id="4" lat="47.0" lon="8.0" version="1"><tag k="natural" v="hill"/><tag k="name" v="Hügel"/></node>
        </osm>""")
    f = tmp_path / "t.osm"
    f.write_text(xml)
    peaks = read_osm_peaks(f)
    assert [p.osm_id for p in peaks] == [1, 3]
    m = peaks[0]
    assert (m.name, m.ele, m.wikidata, m.names["it"], m.alt_names) == ("Matterhorn", 4478, "Q1374", "Monte Cervino",
                                                                        ["Cervin", "Horu"])
    assert peaks[1].kind == "volcano"
    assert len(read_osm_peaks(f, include_hills=True)) == 3


def test_wikidata_rows():
    rows = [
        {"item": {"value": "http://www.wikidata.org/entity/Q1374"}, "lat": {"value": "45.976"}, "lon": {"value": "7.658"},
         "elev": {"value": "4478"}, "label": {"value": "Matterhorn"}, "lang": {"value": "en"},
         "class": {"value": "http://www.wikidata.org/entity/Q8502"},
         "article": {"value": "https://en.wikipedia.org/wiki/Matterhorn"}},
        {"item": {"value": "http://www.wikidata.org/entity/Q1374"}, "lat": {"value": "45.976"}, "lon": {"value": "7.658"},
         "label": {"value": "Cervino"}, "lang": {"value": "it"}, "prom": {"value": "1031"}},
    ]
    (p,) = rows_to_peaks(rows)
    assert p.wikidata == "Q1374" and p.ele == 4478 and p.prominence == 1031
    assert p.names == {"en": "Matterhorn", "it": "Cervino"} and p.name == "Matterhorn"
    assert p.wikipedia == "en:Matterhorn" and p.id == "wd:Q1374"


def test_merge_by_qid_name_and_distance():
    osm = [Peak(45.9763, 7.6586, name="Matterhorn", ele=4478, osm_id=1, wikidata="Q1374", sources=["osm"]),
           Peak(45.9369, 7.8668, name="Dufourspitze", osm_id=2, sources=["osm"])]
    wd = [Peak(45.9766, 7.6580, names={"it": "Cervino", "en": "Matterhorn"}, name="Matterhorn", wikidata="Q1374",
               prominence=1031, sources=["wikidata"]),
          Peak(45.9371, 7.8670, name="Dufour Spitze", wikidata="Q35600", ele=4634, sources=["wikidata"]),
          Peak(46.5, 8.0, name="Only In Wikidata", wikidata="Q1", sources=["wikidata"])]
    gn = [Peak(45.98, 7.66, name="Matterhorn", geonames_id=99, ele=4477, sources=["geonames"]),
          Peak(45.9370, 7.8669, name=None, geonames_id=100, sources=["geonames"]),  # unnamed, very close → merged
          Peak(45.0, 6.0, name=None, geonames_id=101, sources=["geonames"])]  # unnamed, alone → dropped
    m = merge_peaks(osm, wd, gn)
    assert len(m) == 3
    mh = next(p for p in m if p.osm_id == 1)
    assert mh.prominence == 1031 and mh.names["it"] == "Cervino" and mh.geonames_id == 99 and mh.ele == 4478
    assert mh.sources == ["osm", "wikidata", "geonames"]
    df = next(p for p in m if p.osm_id == 2)
    assert df.wikidata == "Q35600" and df.ele == 4634 and df.id == "wd:Q35600" and "osm:n2" in df.all_ids
    assert df.geonames_id == 100


def test_merge_keeps_distinct_wikidata_items_apart():
    wd = [Peak(46.0, 7.0, name="Twin", wikidata="Q1", sources=["wikidata"])]
    osm = [Peak(46.0001, 7.0001, name="Twin", wikidata="Q2", osm_id=5, sources=["osm"])]
    assert len(merge_peaks(osm, wd, [])) == 2


def test_isolation_and_importance():
    peaks = [Peak(46.0, 7.0, name="A", ele=4000), Peak(46.0, 7.1, name="B", ele=3000),
             Peak(46.5, 7.0, name="C", ele=3500)]
    compute_isolation(peaks, max_km=500)
    a, b, c = peaks
    assert a.isolation_km == 500
    assert 7 < b.isolation_km < 8.5  # 0.1° lon at 46°N ≈ 7.7 km
    assert 55 < c.isolation_km < 56
    assert importance(a) > importance(c) > importance(b)


def test_peak_db(tmp_path):
    peaks = [Peak(45.9763, 7.6586, name="Matterhorn", names={"it": "Cervino"}, ele=4478, osm_id=1, wikidata="Q1374",
                  sources=["osm"]),
             Peak(46.5, 8.0, name="Mönch", ele=4110, osm_id=2, sources=["osm"])]
    db = tmp_path / "p.sqlite"
    write_peak_db(db, peaks, {"country": "CH"})
    con = sqlite3.connect(db)
    assert con.execute("PRAGMA user_version").fetchone()[0] == 1
    ids = [r[0] for r in con.execute(
        "SELECT p.id FROM peaks_rtree r JOIN peaks p ON p.rowid = r.rowid "
        "WHERE r.min_lat <= 46.1 AND r.max_lat >= 45.9 AND r.min_lon <= 7.8 AND r.max_lon >= 7.5")]
    assert ids == ["wd:Q1374"]
    hits = [r[0] for r in con.execute(
        "SELECT p.name FROM peaks_fts f JOIN peaks p ON p.rowid = f.rowid WHERE peaks_fts MATCH 'cervino'")]
    assert hits == ["Matterhorn"]
    assert [r[0] for r in con.execute(
        "SELECT p.name FROM peaks_fts f JOIN peaks p ON p.rowid = f.rowid WHERE peaks_fts MATCH 'monch'")] == ["Mönch"]
    assert con.execute("SELECT peak_id FROM peak_aliases WHERE alias = 'osm:n1'").fetchone()[0] == "wd:Q1374"


def _cone_grid(peak_lat=45.5, peak_lon=7.5, top=3000.0):
    """1201×1201 grid with one conical mountain (DEM summit = top)."""
    import numpy as np

    from peaker_pipeline.dem import Grid
    from peaker_pipeline.tiles import Resolution, TileId

    n = 1201
    lat = 46 - np.arange(n) / (n - 1)
    lon = 7 + np.arange(n) / (n - 1)
    dy = (lat[:, None] - peak_lat) * 111_320
    dx = (lon[None, :] - peak_lon) * 111_320 * np.cos(np.radians(45.5))
    h = np.maximum(500.0, top - 0.5 * np.hypot(dx, dy)).astype(np.float32)  # 50% slope
    return Grid(TileId(45, 7), Resolution.GLO90, h)


def test_resolve_elevation_cases():
    from peaker_pipeline.peaks.enrich import resolve_elevation

    g = _cone_grid()
    ok = Peak(45.5, 7.5, name="A", ele=3100, ele_source="osm", sources=["osm"])
    resolve_elevation(ok, g)
    assert ok.ele == 3100 and ok.qa == [] and abs(ok.dem_ele - 3000) < 1

    unit = Peak(45.5, 7.5, name="B", ele=3.05, ele_source="wikidata", sources=["wikidata"])
    resolve_elevation(unit, g)
    assert unit.ele == 3050 and unit.qa == ["unit_fixed"]

    alt = Peak(45.5, 7.5, name="C", ele=1200, ele_source="wikidata", ele_alts=[("geonames", 2990)],
               sources=["wikidata", "geonames"])
    resolve_elevation(alt, g)
    assert alt.ele == 2990 and alt.ele_source == "geonames" and alt.qa == ["alt_source"]

    # Wikidata position ~1 km off the summit: snapped onto the DEM maximum
    off = Peak(45.5 + 0.009, 7.5, name="D", ele=3010, ele_source="wikidata", sources=["wikidata"])
    resolve_elevation(off, g)
    assert off.qa == ["snapped"] and abs(off.lat - 45.5) < 0.001 and off.ele == 3010

    # Same, but from OSM: OSM positions are trusted, so no snapping
    off_osm = Peak(45.5 + 0.009, 7.5, name="E", ele=3010, ele_source="osm", sources=["osm"])
    resolve_elevation(off_osm, g)
    assert off_osm.qa == ["ele_conflict"] and off_osm.ele_source == "dem" and off_osm.ele_alts[0] == ("osm", 3010)


def test_wikidata_name_prefers_language_order():
    rows = [{"item": {"value": "http://www.wikidata.org/entity/Q5"}, "lat": {"value": "47"}, "lon": {"value": "8"}},
            {"item": {"value": "http://www.wikidata.org/entity/Q5"}, "label": {"value": "蓋斯貝格山"}, "lang": {"value": "zh"}},
            {"item": {"value": "http://www.wikidata.org/entity/Q5"}, "label": {"value": "Geissberg"}, "lang": {"value": "de"}}]
    assert rows_to_peaks(rows)[0].name == "Geissberg"


def test_importance_penalises_conflicts():
    a = Peak(46, 7, name="A", prominence=500)
    b = Peak(46, 7, name="B", prominence=500, qa=["ele_conflict"])
    assert importance(b) < importance(a) / 4


def test_peak_dict_roundtrip():
    p = Peak(45.9, 7.6, name="X", names={"de": "Y"}, ele=4000, ele_alts=[("geonames", 3990.0)], qa=["alt_source"],
             osm_id=1, sources=["osm", "geonames"])
    import json

    assert Peak.from_dict(json.loads(json.dumps(p.to_dict()))) == p


def test_osm_peaks_cached_and_pbf_dropped(tmp_path, monkeypatch):
    import json

    from peaker_pipeline.peaks import osm

    xml = ('<?xml version="1.0"?><osm version="0.6"><node id="7" lat="46" lon="7" version="1">'
           '<tag k="natural" v="peak"/><tag k="name" v="Test"/></node></osm>')
    url = "https://download.geofabrik.de/europe/testland-latest.osm"
    monkeypatch.setattr(osm, "geofabrik_pbf_urls", lambda cc, cache: [url])
    calls = []

    def fake_download(u, dest, **kw):
        calls.append(u)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(xml)
        return dest

    monkeypatch.setattr("peaker_pipeline.http.download", fake_download)
    first = osm.osm_peaks_for_country("TL", tmp_path, keep_pbf=False)
    assert [p.osm_id for p in first] == [7]
    assert not (tmp_path / "geofabrik" / "europe" / "testland-latest.osm").exists()
    cached = tmp_path / "osm-peaks" / "europe_testland-latest.osm.json"
    assert json.loads(cached.read_text())[0]["name"] == "Test"
    assert osm.osm_peaks_for_country("TL", tmp_path) == first and len(calls) == 1  # second call: from cache


def test_peak_db_uses_readable_name(tmp_path):
    db = tmp_path / "n.sqlite"
    write_peak_db(db, [Peak(28.55, 84.56, name="मनास्लु", alt_names=["Manaslu"], ele=8163, osm_id=9, sources=["osm"])],
                  {"country": "NP"})
    con = sqlite3.connect(db)
    name, names = con.execute("SELECT name, names FROM peaks").fetchone()
    assert name == "Manaslu" and '"local": "मनास्लु"' in names
    assert con.execute("SELECT count(*) FROM peaks_fts WHERE peaks_fts MATCH 'manaslu'").fetchone()[0] == 1


def test_peak_db_roundtrip(tmp_path):
    from peaker_pipeline.peaks.db import read_peak_db

    db = tmp_path / "r.sqlite"
    src = [Peak(45.97, 7.65, name="Matterhorn", names={"it": "Cervino"}, ele=4478, ele_source="osm", dem_ele=4330,
                osm_id=1, wikidata="Q1374", sources=["osm", "wikidata"], qa=["alt_source"], prominence=1031)]
    write_peak_db(db, src, {"country": "CH"})
    (p,) = read_peak_db(db)
    assert (p.id, p.name, p.names, p.ele, p.dem_ele, p.qa, p.sources, p.prominence) == \
        ("wd:Q1374", "Matterhorn", {"it": "Cervino"}, 4478, 4330, ["alt_source"], ["osm", "wikidata"], 1031)


def test_geofabrik_lookup_falls_back_to_extract_id(tmp_path):
    import json

    from peaker_pipeline.peaks import osm

    index = tmp_path / "geofabrik" / "index-v1-nogeom.json"
    index.parent.mkdir(parents=True)
    feature = lambda id, parent, iso=None: {"properties": {
        "id": id, "parent": parent, "urls": {"pbf": f"https://download.geofabrik.de/europe/{id}-latest.osm.pbf"},
        **({"iso3166-1:alpha2": iso} if iso else {})}}
    index.write_text(json.dumps({"features": [
        feature("europe", None), feature("guernsey-jersey", "europe"), feature("isle-of-man", "europe"),
        feature("france", "europe", ["FR"])]}))
    assert osm.geofabrik_pbf_urls("je", tmp_path) == ["https://download.geofabrik.de/europe/guernsey-jersey-latest.osm.pbf"]
    assert osm.geofabrik_pbf_urls("IM", tmp_path) == ["https://download.geofabrik.de/europe/isle-of-man-latest.osm.pbf"]
    assert osm.geofabrik_pbf_urls("FR", tmp_path) == ["https://download.geofabrik.de/europe/france-latest.osm.pbf"]
    assert osm.geofabrik_pbf_urls("XK", tmp_path) == []  # id not in this index
    assert osm.geofabrik_pbf_urls("SM", tmp_path) == []
