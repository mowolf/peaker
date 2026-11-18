"""Country outlines for the app's map (Natural Earth admin-0, public domain), simplified to ~2 km.

Binary, little-endian::

    b"PKOL"  u16 version (1)  u16 country count
    per country:  2 bytes ISO alpha-2  u32 ring count
        per ring:  u32 point count  then (f32 lon, f32 lat) per point

Rings are outer boundaries and holes alike: the app fills them with the even-odd rule (Lesotho stays a hole
in South Africa, Vatican City in Italy). The app ships the file and draws the world from it: every country,
whether its terrain is downloaded or not.
"""

from __future__ import annotations

import struct
from pathlib import Path

from shapely.geometry import MultiPolygon, Polygon

from .countries import Country

MAGIC = b"PKOL"
VERSION = 1


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


def encode(countries: dict[str, Country], tolerance: float = 0.02) -> bytes:
    body = bytearray()
    count = 0
    for code in sorted(countries):
        if len(code) != 2 or not code.isalpha():
            continue
        rs = rings(countries[code].geometry, tolerance)
        if not rs:
            continue
        count += 1
        body += code.encode("ascii") + struct.pack("<I", len(rs))
        for ring in rs:
            body += struct.pack("<I", len(ring))
            body += struct.pack(f"<{2 * len(ring)}f", *[v for p in ring for v in p])
    return MAGIC + struct.pack("<HH", VERSION, count) + bytes(body)


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


def write_outlines(countries: dict[str, Country], dest: Path, tolerance: float = 0.02) -> dict:
    data = encode(countries, tolerance)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    decoded = decode(data)
    return {"countries": len(decoded), "points": sum(len(r) for rs in decoded.values() for r in rs),
            "bytes": len(data), "path": str(dest)}
