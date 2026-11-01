# Peaker elevation tile format (`.pkt`, version 1)

One file per 1°×1° tile, named after its south-west corner: `N45E007.pkt` covers
lat 45–46°N, lon 7–8°E. Files live at `v1/tiles/<res>/<name>.pkt`, where `<res>` is
`90` (Copernicus GLO-90, default) or `30` (GLO-30, optional high detail).

A tile that is **not** in the catalog's land bitset is ocean: treat it as height 0.
A land tile that isn't downloaded is "no data". The app must show this differently
from sea level.

## Grid

- Point-registered: pixel centres lie exactly on the tile edges.
- `rows` × `cols` samples. Row 0 = northern edge (lat + 1), last row = southern edge (lat).
  Column 0 = western edge (lon), last column = eastern edge (lon + 1).
- Neighbouring tiles share their edge row/column, so you can interpolate anywhere
  inside a tile without opening its neighbours.
- GLO-90: `rows = 1201`. `cols` depends on latitude (Copernicus spec), so pixels stay roughly square:

  | abs(latitude) | 0–50° | 50–60° | 60–70° | 70–80° | 80–85° | 85–90° |
  |---|---|---|---|---|---|---|
  | cols (GLO-90) | 1201 | 801 | 601 | 401 | 241 | 121 |
  | cols (GLO-30) | 3601 | 2401 | 1801 | 1201 | 721 | 361 |

```
lat(r) = south + 1 - r / (rows - 1)
lon(c) = west + c / (cols - 1)
r(lat) = (south + 1 - lat) * (rows - 1)
c(lon) = (lon - west) * (cols - 1)
```

Heights are metres above the EGM2008 geoid (≈ mean sea level). Copernicus is a
*surface* model: forests and buildings are included, and sharp summits come out too
low (Matterhorn: 4330 m in GLO-30 vs 4478 m real). For labels, use the peak DB's `ele`.

## File layout (little-endian)

| offset | type | field |
|---:|---|---|
| 0 | 4 bytes | magic `PKT1` |
| 4 | int16 | south latitude (deg) |
| 6 | int16 | west longitude (deg) |
| 8 | uint16 | rows |
| 10 | uint16 | cols |
| 12 | float32 | scale (m per step), currently `1.0` |
| 16 | float32 | offset (m), currently `-500.0` |
| 20 | uint8 | codec: 1 = predictor + raw DEFLATE, 2 = predictor + LZMA (xz), 3 = 16-bit PNG, 4 = predictor + Brotli |
| 21 | uint8 | predictor: 0 = none, 1 = planar 2D |
| 22 | uint8 | byte layout: 0 = interleaved, 1 = byte planes (all high bytes, then all low bytes) |
| 23 | uint8 | reserved (0) |
| 24 | int16 | min height in tile (m, floor) |
| 26 | int16 | max height in tile (m, ceil) |
| 28 | uint32 | payload length (bytes) |
| 32 | … | payload |

The default and only codec in production is **1**. On iOS, decompress with
`COMPRESSION_ZLIB` from the `Compression` framework. That is raw DEFLATE (RFC 1951)
with no zlib header, which is exactly what the payload contains. The min/max heights
let the horizon code skip whole tiles that can't occlude anything.

## Decoding codec 1

1. Inflate the payload → `2 · rows · cols` bytes.
2. Rebuild big-endian `uint16` residuals: `res[i] = plane[i] << 8 | plane[n + i]`, where `n = rows · cols`.
3. Undo the planar predictor (all arithmetic mod 2¹⁶, i.e. with `UInt16` wrapping operators):

   ```
   q[0][0]   = res[0][0]
   q[0][c]   = res[0][c] + q[0][c-1]                         (first row: left)
   q[r][0]   = res[r][0] + q[r-1][0]                         (first column: up)
   q[r][c]   = res[r][c] + q[r][c-1] + q[r-1][c] - q[r-1][c-1]
   ```
4. Height: `h = Float(q) * scale + offset`.

```swift
// Sketch: decode a codec-1 tile into Float heights.
func decodeHeights(residualPlanes p: [UInt8], rows: Int, cols: Int, scale: Float, offset: Float) -> [Float] {
    let n = rows * cols
    var q = [UInt16](repeating: 0, count: n)
    for r in 0..<rows {
        for c in 0..<cols {
            let i = r * cols + c
            let res = UInt16(p[i]) << 8 | UInt16(p[n + i])
            let left = c > 0 ? q[i - 1] : 0
            let up = r > 0 ? q[i - cols] : 0
            let upLeft = (r > 0 && c > 0) ? q[i - cols - 1] : 0
            let pred: UInt16 = (r == 0) ? left : (c == 0 ? up : left &+ up &- upLeft)
            q[i] = res &+ pred
        }
    }
    return q.map { Float($0) * scale + offset }
}
```

The reference implementation is `pipeline/peaker_pipeline/encode.py`. Its tests
cover the round trip and the mod-2¹⁶ wraparound.

## Why this format

See `docs/decisions.md` (F-3). In short: about 14% smaller than 16-bit PNG, and the
decoder is native on iOS and Android with no third-party code.
