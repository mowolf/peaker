"""Peaks from the GeoNames country dumps (CC BY 4.0).

https://download.geonames.org/export/dump/<CC>.zip — tab separated, see the
readme there for the column list. GeoNames coordinates for mountains are often
rounded, so these records rank below OSM/Wikidata when merging.
"""

from __future__ import annotations

import csv
import io
import zipfile
from pathlib import Path

from ..http import download
from .model import Peak

URL = "https://download.geonames.org/export/dump/{cc}.zip"

# Feature codes (class T = terrain) → kind
FEATURE_CODES = {"PK": "peak", "MT": "mountain", "VLC": "volcano", "HLL": "hill"}


def geonames_path(cc: str, cache_dir: Path) -> Path:
    path = Path(cache_dir) / "geonames" / f"{cc.upper()}.zip"
    if not path.exists():
        download(URL.format(cc=cc.upper()), path)
    return path


def read_geonames_peaks(path: Path, include_hills: bool = False) -> list[Peak]:
    codes = dict(FEATURE_CODES)
    if not include_hills:
        codes.pop("HLL")
    peaks: list[Peak] = []
    with zipfile.ZipFile(path) as z:
        member = next(n for n in z.namelist() if n.endswith(".txt") and not n.startswith("readme"))
        with z.open(member) as f:
            reader = csv.reader(io.TextIOWrapper(f, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE)
            for row in reader:
                if len(row) < 19 or row[6] != "T" or row[7] not in codes:
                    continue
                ele = None
                if row[15]:
                    try:
                        ele = float(row[15])
                    except ValueError:
                        pass
                alt = [a for a in row[3].split(",") if a and a != row[1]] if row[3] else []
                peaks.append(Peak(
                    lat=float(row[4]),
                    lon=float(row[5]),
                    name=row[1] or None,
                    alt_names=alt[:20],
                    ele=ele,
                    ele_source="geonames" if ele is not None else None,
                    kind=codes[row[7]],
                    geonames_id=int(row[0]),
                    sources=["geonames"],
                ))
    return peaks
