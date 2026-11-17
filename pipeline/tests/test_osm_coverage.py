import pytest
from shapely.geometry import box

from peaker_pipeline.countries import Country
from peaker_pipeline.packs import MissingOSMPeaks, PackOptions, check_osm_coverage, osm_peaks_inside
from peaker_pipeline.peaks.model import Peak

LATVIA = Country("LV", "Latvia", box(21.0, 55.7, 28.2, 58.1))


def peak(lat, lon, osm_id=None):
    return Peak(name="p", lat=lat, lon=lon, osm_id=osm_id, sources=["osm" if osm_id else "geonames"])


def test_counts_only_osm_peaks_inside_the_country():
    peaks = [peak(56.9, 25.9, osm_id=1),   # inside, OSM
             peak(56.8, 25.0),             # inside, GeoNames only
             peak(59.5, 24.7, osm_id=2)]   # Estonia: border buffer
    assert osm_peaks_inside(LATVIA, peaks) == 1


def test_fails_when_the_country_has_only_neighbours_osm_peaks():
    # The November 2026 build: no own extract, only GeoNames plus the neighbours' buffer.
    peaks = [peak(56.9, 25.9), peak(59.5, 24.7, osm_id=2)]
    with pytest.raises(MissingOSMPeaks, match="LV"):
        check_osm_coverage(LATVIA, peaks, PackOptions())


def test_passes_with_own_osm_peaks_or_when_allowed():
    check_osm_coverage(LATVIA, [peak(56.9, 25.9, osm_id=1)], PackOptions())
    check_osm_coverage(LATVIA, [], PackOptions(allow_missing_osm=True))
    check_osm_coverage(LATVIA, [], PackOptions(use_osm=False))  # --no-osm: nothing expected
