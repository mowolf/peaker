"""1°×1° tile naming and Copernicus DEM source locations.

A tile is named after its south-west corner, e.g. ``N45E007`` covers
lat 45..46, lon 7..8. Copernicus DEM is point-registered: pixel centres lie
exactly on whole degrees, row 0 is the northern edge (lat+1) and column 0
the western edge (lon). Peaker tiles keep this grid and add the southern row
and eastern column from the neighbouring tiles, so a tile with ``n`` source
rows becomes ``n + 1`` rows and covers both edges ("SRTM style").
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum

_NAME_RE = re.compile(r"^([NS])(\d{2})([EW])(\d{3})$")


class Resolution(str, Enum):
    """Supported source resolutions. Value = Copernicus arc-second code."""

    GLO90 = "90"
    GLO30 = "30"

    @property
    def arcsec_code(self) -> str:
        return {"90": "30", "30": "10"}[self.value]

    @property
    def bucket(self) -> str:
        return f"copernicus-dem-{self.value}m"

    @property
    def rows(self) -> int:
        """Rows per source tile (constant; columns shrink with latitude)."""
        return {"90": 1200, "30": 3600}[self.value]


@dataclass(frozen=True, order=True)
class TileId:
    lat: int  # south edge, -90..89
    lon: int  # west edge, -180..179

    def __post_init__(self) -> None:
        if not (-90 <= self.lat <= 89 and -180 <= self.lon <= 179):
            raise ValueError(f"tile out of range: {self.lat},{self.lon}")

    @property
    def name(self) -> str:
        ns = "N" if self.lat >= 0 else "S"
        ew = "E" if self.lon >= 0 else "W"
        return f"{ns}{abs(self.lat):02d}{ew}{abs(self.lon):03d}"

    def __str__(self) -> str:
        return self.name

    @classmethod
    def parse(cls, name: str) -> TileId:
        m = _NAME_RE.match(name)
        if not m:
            raise ValueError(f"bad tile name: {name!r}")
        lat = int(m.group(2)) * (1 if m.group(1) == "N" else -1)
        lon = int(m.group(4)) * (1 if m.group(3) == "E" else -1)
        return cls(lat, lon)

    @classmethod
    def containing(cls, lat: float, lon: float) -> TileId:
        import math

        lon = ((lon + 180.0) % 360.0) - 180.0
        return cls(min(int(math.floor(lat)), 89), min(int(math.floor(lon)), 179))

    @property
    def bounds(self) -> tuple[float, float, float, float]:
        """(west, south, east, north)."""
        return (float(self.lon), float(self.lat), float(self.lon + 1), float(self.lat + 1))

    def neighbour(self, dlat: int, dlon: int) -> TileId | None:
        lat = self.lat + dlat
        if not -90 <= lat <= 89:
            return None
        lon = ((self.lon + dlon + 180) % 360) - 180
        return TileId(lat, lon)

    # --- Copernicus naming -------------------------------------------------
    def copernicus_name(self, res: Resolution) -> str:
        ns = "N" if self.lat >= 0 else "S"
        ew = "E" if self.lon >= 0 else "W"
        return f"Copernicus_DSM_COG_{res.arcsec_code}_{ns}{abs(self.lat):02d}_00_{ew}{abs(self.lon):03d}_00_DEM"

    def copernicus_url(self, res: Resolution) -> str:
        n = self.copernicus_name(res)
        return f"https://{res.bucket}.s3.amazonaws.com/{n}/{n}.tif"

    @classmethod
    def from_copernicus_name(cls, name: str) -> TileId:
        m = re.match(r"^Copernicus_DSM_COG_\d+_([NS])(\d{2})_00_([EW])(\d{3})_00_DEM$", name.strip())
        if not m:
            raise ValueError(f"bad Copernicus name: {name!r}")
        return cls.parse(f"{m.group(1)}{m.group(2)}{m.group(3)}{m.group(4)}")


def copernicus_cols(lat: int, res: Resolution) -> int:
    """Columns of a Copernicus tile at this latitude (spec: longitude spacing grows towards the poles)."""
    a = abs(lat + 0.5)  # band is decided by the tile's position, not its south edge sign
    if a < 50:
        factor = 1.0
    elif a < 60:
        factor = 1.5
    elif a < 70:
        factor = 2.0
    elif a < 80:
        factor = 3.0
    elif a < 85:
        factor = 5.0
    else:
        factor = 10.0
    return int(round(res.rows / factor))


def tiles_in_bbox(west: float, south: float, east: float, north: float) -> list[TileId]:
    """All tiles touching the bbox. ``east < west`` means the bbox crosses the antimeridian."""
    import math

    lats = range(max(-90, math.floor(south)), min(90, math.ceil(north)))
    if east < west:
        lons = list(range(math.floor(west), 180)) + list(range(-180, math.ceil(east)))
    else:
        lons = list(range(max(-180, math.floor(west)), min(180, math.ceil(east))))
    return [TileId(la, lo) for la in lats for lo in lons]
