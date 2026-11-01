"""Tile encodings.

Every codec here can be decoded on iOS without third-party code: PNG via
ImageIO, zlib/LZMA/Brotli via Apple's ``Compression`` framework. The
benchmark (``peaker-pipeline bench-encoding``) picked the default; see
``docs/decisions.md`` and ``docs/tile-format.md``.

Heights are quantised as ``q = round((h - OFFSET) / scale)`` into uint16, so
``h = q * scale + OFFSET``. With ``OFFSET = -500`` and ``scale = 1`` the range
is -500..65035 m; with ``scale = 0.25`` it is -500..15883 m.
"""

from __future__ import annotations

import io
import lzma
import struct
import zlib
from dataclasses import dataclass
from typing import Callable

import numpy as np

OFFSET = -500.0


def quantise(h: np.ndarray, scale: float) -> np.ndarray:
    q = np.round((h.astype(np.float64) - OFFSET) / scale)
    return np.clip(q, 0, 65535).astype(np.uint16)


def dequantise(q: np.ndarray, scale: float) -> np.ndarray:
    return (q.astype(np.float32) * np.float32(scale) + np.float32(OFFSET)).astype(np.float32)


# --- predictors ---------------------------------------------------------------


def predict_2d(q: np.ndarray) -> np.ndarray:
    """Residual of the planar predictor ``left + up - upleft`` (mod 2^16).

    First row uses ``left``, first column uses ``up``. Mountains are locally
    close to planar, so residuals are small and compress well.
    """
    q = q.astype(np.int32)
    p = np.zeros_like(q)
    p[0, 1:] = q[0, :-1]
    p[1:, 0] = q[:-1, 0]
    p[1:, 1:] = q[1:, :-1] + q[:-1, 1:] - q[:-1, :-1]
    return ((q - p) & 0xFFFF).astype(np.uint16)


def unpredict_2d(r: np.ndarray) -> np.ndarray:
    r = r.astype(np.int64)
    rows, cols = r.shape
    q = np.zeros_like(r)
    q[0] = np.cumsum(r[0]) & 0xFFFF
    q[1:, 0] = (q[0, 0] + np.cumsum(r[1:, 0])) & 0xFFFF
    # Row by row: q[i, j] = r + q[i, j-1] + q[i-1, j] - q[i-1, j-1]
    # ⇔ q[i] - q[i-1] = cumsum(r[i]) (with col 0 fixed), so each row is a cumsum.
    for i in range(1, rows):
        d = np.cumsum(r[i, 1:]) + (q[i, 0] - q[i - 1, 0])
        q[i, 1:] = (q[i - 1, 1:] + d) & 0xFFFF
    return q.astype(np.uint16)


def split_bytes(r: np.ndarray) -> bytes:
    """High bytes then low bytes: residuals are small, so the high-byte plane is mostly 0/255."""
    be = r.astype(">u2").tobytes()
    arr = np.frombuffer(be, dtype=np.uint8)
    return arr[0::2].tobytes() + arr[1::2].tobytes()


def join_bytes(b: bytes, shape: tuple[int, int]) -> np.ndarray:
    n = shape[0] * shape[1]
    arr = np.frombuffer(b, dtype=np.uint8)
    out = np.empty(2 * n, dtype=np.uint8)
    out[0::2] = arr[:n]
    out[1::2] = arr[n:]
    return out.view(">u2").reshape(shape).astype(np.uint16)


# --- codecs -------------------------------------------------------------------


@dataclass(frozen=True)
class Codec:
    name: str
    ext: str
    encode: Callable[[np.ndarray], bytes]  # float32 heights -> bytes
    decode: Callable[[bytes, tuple[int, int]], np.ndarray]  # -> float32 heights
    scale: float
    ios_decoder: str


def _png16(scale: float) -> Codec:
    from PIL import Image

    def enc(h: np.ndarray) -> bytes:
        q = quantise(h, scale)
        img = Image.fromarray(q.astype("<u2"))
        buf = io.BytesIO()
        img.save(buf, format="PNG", optimize=True, compress_level=9)
        return buf.getvalue()

    def dec(b: bytes, shape: tuple[int, int]) -> np.ndarray:
        img = Image.open(io.BytesIO(b))
        q = np.array(img, dtype=np.uint16)
        return dequantise(q, scale)

    return Codec(f"png16@{scale:g}m", "png", enc, dec, scale, "ImageIO (16-bit grayscale)")


def _terrarium() -> Codec:
    """Mapzen/AWS Terrarium: h = R*256 + G + B/256 - 32768 (quantised to whole metres here)."""
    from PIL import Image

    def enc(h: np.ndarray) -> bytes:
        v = np.clip(np.round(h.astype(np.float64)) + 32768, 0, 65535).astype(np.uint32)
        rgb = np.stack([(v >> 8) & 255, v & 255, np.zeros_like(v)], axis=-1).astype(np.uint8)
        buf = io.BytesIO()
        Image.fromarray(rgb).save(buf, format="PNG", optimize=True, compress_level=9)
        return buf.getvalue()

    def dec(b: bytes, shape: tuple[int, int]) -> np.ndarray:
        rgb = np.array(Image.open(io.BytesIO(b)).convert("RGB")).astype(np.float32)
        return rgb[..., 0] * 256 + rgb[..., 1] + rgb[..., 2] / 256 - 32768

    return Codec("terrarium-png@1m", "png", enc, dec, 1.0, "ImageIO (RGB8)")


def _raw(name: str, compress: Callable[[bytes], bytes], decompress: Callable[[bytes], bytes],
         scale: float, ios: str) -> Codec:
    def enc(h: np.ndarray) -> bytes:
        return compress(split_bytes(predict_2d(quantise(h, scale))))

    def dec(b: bytes, shape: tuple[int, int]) -> np.ndarray:
        return dequantise(unpredict_2d(join_bytes(decompress(b), shape)), scale)

    return Codec(f"{name}@{scale:g}m", "bin", enc, dec, scale, ios)


def _deflate(b: bytes) -> bytes:
    c = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw deflate = COMPRESSION_ZLIB on iOS
    return c.compress(b) + c.flush()


def _inflate(b: bytes) -> bytes:
    return zlib.decompress(b, -15)


def _lzma(b: bytes) -> bytes:
    return lzma.compress(b, format=lzma.FORMAT_XZ, preset=9 | lzma.PRESET_EXTREME)


def all_codecs() -> list[Codec]:
    codecs = [
        _png16(1.0),
        _png16(0.25),
        _terrarium(),
        _raw("pred2d-deflate", _deflate, _inflate, 1.0, "Compression: COMPRESSION_ZLIB"),
        _raw("pred2d-deflate", _deflate, _inflate, 0.25, "Compression: COMPRESSION_ZLIB"),
        _raw("pred2d-lzma", _lzma, lzma.decompress, 1.0, "Compression: COMPRESSION_LZMA"),
    ]
    try:
        import brotli

        codecs.append(_raw("pred2d-brotli", lambda b: brotli.compress(b, quality=11), brotli.decompress,
                           1.0, "Compression: COMPRESSION_BROTLI (iOS 15+)"))
    except ImportError:
        pass
    return codecs


def codec_by_name(name: str) -> Codec:
    for c in all_codecs():
        if c.name == name:
            return c
    raise KeyError(f"unknown codec {name!r}; known: {[c.name for c in all_codecs()]}")


# --- Peaker tile container (.pkt) ----------------------------------------------
#
# Fixed 32-byte little-endian header followed by the codec payload, so a tile is
# self-describing without its JSON sidecar:
#   0  4s  magic  b"PKT1"
#   4  h   south latitude (deg)
#   6  h   west longitude (deg)
#   8  H   rows
#  10  H   cols
#  12  f   scale (m per step)
#  16  f   offset (m)
#  20  B   codec id (1 = pred2d-deflate, 2 = pred2d-lzma, 3 = png16, 4 = pred2d-brotli)
#  21  B   predictor (0 = none, 1 = planar 2D)
#  22  B   byte layout (0 = interleaved, 1 = high-bytes plane then low-bytes plane)
#  23  B   reserved
#  24  h   min height (m, rounded down)
#  26  h   max height (m, rounded up)
#  28  I   payload length
HEADER = struct.Struct("<4shhHHffBBBBhhI")
MAGIC = b"PKT1"
CODEC_IDS = {"pred2d-deflate": 1, "pred2d-lzma": 2, "png16": 3, "pred2d-brotli": 4}

# Decision F-3 (docs/decisions.md): ~14% smaller than 16-bit PNG, zlib is native on iOS and Android.
DEFAULT_CODEC = "pred2d-deflate@1m"


def pack_tile(lat: int, lon: int, heights: np.ndarray, codec: Codec) -> bytes:
    base = codec.name.split("@")[0]
    if base not in CODEC_IDS:
        raise ValueError(f"codec {codec.name} cannot be stored in a .pkt container")
    payload = codec.encode(heights)
    is_raw = base.startswith("pred2d")
    header = HEADER.pack(
        MAGIC, lat, lon, heights.shape[0], heights.shape[1], codec.scale, OFFSET, CODEC_IDS[base],
        1 if is_raw else 0, 1 if is_raw else 0, 0,
        int(np.floor(np.nanmin(heights))), int(np.ceil(np.nanmax(heights))), len(payload),
    )
    return header + payload


def unpack_tile(data: bytes) -> tuple[dict, np.ndarray]:
    (magic, lat, lon, rows, cols, scale, offset, codec_id, pred, layout, _r, hmin, hmax,
     n) = HEADER.unpack_from(data)
    if magic != MAGIC:
        raise ValueError("not a Peaker tile")
    if offset != OFFSET:
        raise ValueError(f"unsupported offset {offset}")
    base = {v: k for k, v in CODEC_IDS.items()}[codec_id]
    codec = codec_by_name(f"{base}@{scale:g}m")
    payload = data[HEADER.size : HEADER.size + n]
    meta = dict(lat=lat, lon=lon, rows=rows, cols=cols, scale=scale, offset=offset, codec=codec.name,
                min=hmin, max=hmax)
    return meta, codec.decode(payload, (rows, cols))
