"""Common peak record shared by all sources."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field


@dataclass
class Peak:
    lat: float
    lon: float
    name: str | None = None
    names: dict[str, str] = field(default_factory=dict)  # language → name
    alt_names: list[str] = field(default_factory=list)  # searchable, language unknown
    ele: float | None = None  # metres, from a tagged/official source
    ele_source: str | None = None  # "osm" | "wikidata" | "geonames" | "dem"
    ele_alts: list[tuple[str, float]] = field(default_factory=list)  # other sources' values, for QA
    dem_ele: float | None = None  # highest DEM value near the summit (DEM underestimates sharp peaks)
    qa: list[str] = field(default_factory=list)  # e.g. "unit_fixed", "snapped", "ele_conflict"
    prominence: float | None = None
    isolation_km: float | None = None
    kind: str = "peak"  # peak | volcano | hill | mountain
    osm_id: int | None = None  # node id
    wikidata: str | None = None  # e.g. "Q1374"
    geonames_id: int | None = None
    wikipedia: str | None = None  # "en:Matterhorn"
    sources: list[str] = field(default_factory=list)

    @property
    def id(self) -> str:
        """Stable ID (decision F-5): Wikidata first, then OSM, then GeoNames."""
        if self.wikidata:
            return f"wd:{self.wikidata}"
        if self.osm_id is not None:
            return f"osm:n{self.osm_id}"
        if self.geonames_id is not None:
            return f"gn:{self.geonames_id}"
        return f"ll:{self.lat:.5f},{self.lon:.5f}"

    @property
    def all_ids(self) -> list[str]:
        ids = []
        if self.wikidata:
            ids.append(f"wd:{self.wikidata}")
        if self.osm_id is not None:
            ids.append(f"osm:n{self.osm_id}")
        if self.geonames_id is not None:
            ids.append(f"gn:{self.geonames_id}")
        return ids

    def display_name(self, lang: str | None = None) -> str | None:
        if lang and lang in self.names:
            return self.names[lang]
        return self.name or self.names.get("en") or next(iter(self.names.values()), None)


_ELE_RE = re.compile(r"^\s*~?\s*(-?\d+(?:[.,]\d+)?)\s*(m|meters?|metres?|ft|feet|')?\s*$", re.IGNORECASE)


def parse_ele(value: str | None) -> float | None:
    """Parse OSM ``ele`` values: "4478", "4478 m", "4478.5", "14505 ft".

    A comma is read as a decimal separator only if it's followed by 1–2 digits
    ("4478,5"); "4,478" is ambiguous and rejected.
    """
    if not value:
        return None
    m = _ELE_RE.match(value)
    if not m:
        return None
    num = m.group(1)
    if "," in num:
        whole, frac = num.split(",")
        if len(frac) > 2:
            return None
        num = f"{whole}.{frac}"
    v = float(num)
    if (m.group(2) or "").lower() in ("ft", "feet", "'"):
        v *= 0.3048
    if not -500 <= v <= 9000:
        return None
    return v


def normalise_name(name: str) -> str:
    s = unicodedata.normalize("NFKD", name.casefold())
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = re.sub(r"[^\w\s]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def names_match(a: str | None, b: str | None) -> bool:
    if not a or not b:
        return False
    na, nb = normalise_name(a), normalise_name(b)
    if not na or not nb:
        return False
    if na == nb or na in nb or nb in na:
        return True
    from difflib import SequenceMatcher

    return SequenceMatcher(None, na, nb).ratio() >= 0.85
