"""Country outlines for the app's map (Natural Earth admin-0, public domain), simplified to ~2 km.

Binary, little-endian::

    b"PKOL"  u16 version (1)  u16 country count
    per country:  2 bytes ISO alpha-2  u32 ring count
        per ring:  u32 point count  then (f32 lon, f32 lat) per point

Rings are outer boundaries and holes alike: the app fills them with the even-odd rule (Lesotho stays a hole
in South Africa, Vatican City in Italy). The app ships the file and draws the world from it: every country,
whether its terrain is downloaded or not.

Lakes (Natural Earth 10 m lakes, world and Europe, larger than ~20 km²) follow as one more entry with the code ``~~``; the app
paints them as water, also over downloaded terrain (the elevation data has no water).
"""

from __future__ import annotations

import struct
from pathlib import Path

from shapely.geometry import MultiPolygon, Polygon

from .countries import Country

MAGIC = b"PKOL"
VERSION = 1
LAKES_CODE = "~~"
LAKES_URLS = ["https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes.zip",
              # More European lakes (Lake Zurich, Lago Maggiore's arms, ...), which the world layer leaves out.
              "https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes_europe.zip"]
MIN_LAKE_DEG2 = 0.0025  # ~20 km² at mid latitudes


def rings(geometry, tolerance: float) -> list[list[tuple[float, float]]]:
    simplified = geometry.simplify(tolerance, preserve_topology=True)
    polys = [simplified] if isinstance(simplified, Polygon) else list(getattr(simplified, "geoms", []))
    out: list[list[tuple[float, float]]] = []
    min_area = (tolerance * 3) ** 2  # drop islets smaller than a few pixels at world scale
    for poly in polys:
        if not isinstance(poly, Polygon) or poly.is_empty or poly.area < min_area:
            continue
        for ring in [poly.exterior, *poly.interiors]:
            pts = list(ring.coords)
            if len(pts) >= 4:
                out.append([(float(x), float(y)) for x, y in pts[:-1]])  # closing point is implied
    return out


def encode(countries: dict[str, Country], tolerance: float = 0.02, lakes=None) -> bytes:
    body = bytearray()
    count = 0
    entries = [(code, countries[code].geometry) for code in sorted(countries) if len(code) == 2 and code.isalpha()]
    if lakes is not None:
        entries.append((LAKES_CODE, lakes))
    for code, geometry in entries:
        # Lakes are simplified less: they are small, and a shoreline cut short looks wrong.
        rs = rings(geometry, tolerance / 2 if code == LAKES_CODE else tolerance)
        if not rs:
            continue
        count += 1
        body += code.encode("ascii") + struct.pack("<I", len(rs))
        for ring in rs:
            body += struct.pack("<I", len(ring))
            body += struct.pack(f"<{2 * len(ring)}f", *[v for p in ring for v in p])
    return MAGIC + struct.pack("<HH", VERSION, count) + bytes(body)


def load_lakes(cache_dir: Path):
    """Natural Earth 10 m lakes (world and Europe) larger than MIN_LAKE_DEG2, as one (multi)polygon."""
    import pyogrio
    from shapely import from_wkb
    from shapely.ops import unary_union

    from .http import download

    polys = []
    for url in LAKES_URLS:
        path = Path(cache_dir) / "naturalearth" / url.rsplit("/", 1)[1]
        if not path.exists():
            download(url, path)
        _, _, geoms, _ = pyogrio.raw.read(f"/vsizip/{path}", columns=[])
        polys += [g for g in (from_wkb(w) for w in geoms if w is not None) if g.area >= MIN_LAKE_DEG2]
    return unary_union(polys)


def decode(data: bytes) -> dict[str, list[list[tuple[float, float]]]]:
    assert data[:4] == MAGIC
    version, count = struct.unpack_from("<HH", data, 4)
    assert version == VERSION
    pos, out = 8, {}
    for _ in range(count):
        code = data[pos:pos + 2].decode("ascii")
        (n_rings,) = struct.unpack_from("<I", data, pos + 2)
        pos += 6
        rs = []
        for _ in range(n_rings):
            (n,) = struct.unpack_from("<I", data, pos)
            pos += 4
            vals = struct.unpack_from(f"<{2 * n}f", data, pos)
            pos += 8 * n
            rs.append(list(zip(vals[0::2], vals[1::2])))
        out[code] = rs
    return out


def write_outlines(countries: dict[str, Country], dest: Path, tolerance: float = 0.02, lakes=None) -> dict:
    data = encode(countries, tolerance, lakes)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    decoded = decode(data)
    return {"countries": len(decoded), "points": sum(len(r) for rs in decoded.values() for r in rs),
            "bytes": len(data), "path": str(dest)}
