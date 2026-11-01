import numpy as np
import pytest

from peaker_pipeline import encode


def terrain(rows=201, cols=181, seed=0):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:rows, 0:cols]
    h = 2000 + 1500 * np.sin(x / 17.0) * np.cos(y / 23.0) + rng.normal(0, 30, (rows, cols))
    h[:20, :30] = 0  # sea
    h[-1, -1] = 8848.9
    h[0, 0] = -420  # Dead Sea
    return h.astype(np.float32)


@pytest.mark.parametrize("codec", encode.all_codecs(), ids=lambda c: c.name)
def test_roundtrip_within_quantisation(codec):
    h = terrain()
    d = codec.decode(codec.encode(h), h.shape)
    assert d.shape == h.shape
    assert np.abs(d - h).max() <= codec.scale / 2 + 1e-3


def test_predictor_roundtrip_with_wraparound():
    rng = np.random.default_rng(1)
    q = rng.integers(0, 65536, size=(50, 70), dtype=np.uint16)  # worst case: big jumps wrap mod 2^16
    assert np.array_equal(encode.unpredict_2d(encode.predict_2d(q)), q)


def test_split_join_bytes():
    q = np.arange(12, dtype=np.uint16).reshape(3, 4) * 1000
    assert np.array_equal(encode.join_bytes(encode.split_bytes(q), q.shape), q)


def test_pkt_container():
    h = terrain()
    data = encode.pack_tile(45, 7, h, encode.codec_by_name(encode.DEFAULT_CODEC))
    assert data[:4] == b"PKT1" and encode.HEADER.size == 32
    meta, d = encode.unpack_tile(data)
    assert (meta["lat"], meta["lon"], meta["rows"], meta["cols"]) == (45, 7, 201, 181)
    assert meta["min"] == -420 and meta["max"] == 8849
    assert np.abs(d - h).max() <= 0.5 + 1e-3


def test_pkt_rejects_garbage():
    with pytest.raises(ValueError):
        encode.unpack_tile(b"\0" * 64)
