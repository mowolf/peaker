"""Benchmark tile encodings on representative terrain (decision F-3)."""

from __future__ import annotations

import time
from dataclasses import dataclass

import numpy as np

from .dem import TileSource, fill_voids
from .encode import all_codecs
from .tiles import Resolution, TileId

# Mix of terrain: high alpine, Himalaya, Andes, rolling hills, flat land, coast with sea, high latitude.
BENCH_TILES = {
    "N45E007": "Alps (Matterhorn/Monte Rosa)",
    "N27E086": "Himalaya (Everest)",
    "S33W070": "Andes (Aconcagua)",
    "N47E011": "Alps north edge + Bavarian foreland",
    "N52E010": "North German plain (flat)",
    "N43E007": "Côte d'Azur (coast + sea)",
    "N61E007": "Norway fjords (60–70° band)",
    "N36W119": "Sierra Nevada, USA",
}


@dataclass
class Result:
    tile: str
    codec: str
    bytes: int
    max_err: float
    enc_s: float
    dec_s: float


def run(res: Resolution, source: TileSource, tiles: list[str] | None = None) -> list[Result]:
    out: list[Result] = []
    for name in tiles or list(BENCH_TILES):
        a = source.read_source(TileId.parse(name))
        if a is None:
            continue
        h = fill_voids(a)
        raw = Result(name, "raw-int16", h.size * 2, 0.0, 0.0, 0.0)
        out.append(raw)
        for c in all_codecs():
            t0 = time.perf_counter()
            b = c.encode(h)
            t1 = time.perf_counter()
            d = c.decode(b, h.shape)
            t2 = time.perf_counter()
            out.append(Result(name, c.name, len(b), float(np.abs(d - h).max()), t1 - t0, t2 - t1))
    return out


def report(results: list[Result], res: Resolution) -> str:
    codecs = list(dict.fromkeys(r.codec for r in results))
    tiles = list(dict.fromkeys(r.tile for r in results))
    by = {(r.tile, r.codec): r for r in results}
    lines = [f"### GLO-{res.value} — size per tile (MB)", "",
             "| tile | terrain | " + " | ".join(codecs) + " |",
             "|---|---|" + "---:|" * len(codecs)]
    for t in tiles:
        lines.append(f"| {t} | {BENCH_TILES.get(t, '')} | "
                     + " | ".join(f"{by[(t, c)].bytes / 1e6:.2f}" for c in codecs) + " |")
    totals = {c: sum(by[(t, c)].bytes for t in tiles) for c in codecs}
    base = totals.get("png16@1m") or 1
    lines.append("| **total** | | " + " | ".join(f"**{totals[c] / 1e6:.2f}**" for c in codecs) + " |")
    lines.append("| vs png16@1m | | " + " | ".join(f"{totals[c] / base * 100:.0f}%" for c in codecs) + " |")
    lines.append("| max error (m) | | " + " | ".join(
        f"{max(by[(t, c)].max_err for t in tiles):.3f}" for c in codecs) + " |")
    lines.append("| decode s (Python, total) | | " + " | ".join(
        f"{sum(by[(t, c)].dec_s for t in tiles):.2f}" for c in codecs) + " |")
    return "\n".join(lines)
