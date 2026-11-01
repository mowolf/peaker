# Peaker data pipeline

Builds the offline data the app downloads, packaged by country:

- **elevation tiles**: Copernicus DEM GLO-90 (optionally GLO-30), 1°×1°, `.pkt` format → [docs/tile-format.md](../docs/tile-format.md)
- **peak databases**: OpenStreetMap + Wikidata + GeoNames, merged, one SQLite per pack → [docs/pack-format.md](../docs/pack-format.md)
- **catalog + manifests** for the app's download manager

Decisions and measurements are in [docs/decisions.md](../docs/decisions.md).

## Setup

```sh
cd pipeline
uv venv && uv pip install -e '.[dev]'     # or: python -m venv .venv && pip install -e '.[dev]'
uv run pytest -q
```

Downloads are cached in `~/.cache/peaker` (override with `PEAKER_CACHE` or `--cache`).

## Commands

```sh
# Which tiles a pack needs, and the estimated size
peaker-pipeline tiles CH AT NP

# Build packs into ./out (tiles are shared, so building AT after CH only adds missing tiles)
peaker-pipeline pack CH AT
peaker-pipeline pack CH --res 90 30            # also build the 30 m high-detail tiles
peaker-pipeline pack CH --no-osm               # Wikidata + GeoNames only (when Geofabrik is unreachable)
peaker-pipeline pack CH --osm-pbf switzerland-latest.osm.pbf

# Compare tile encodings (decision F-3)
peaker-pipeline bench-encoding --res 90
```

Output:

```
out/v1/catalog.json, out/v1/countries/CH.json, out/v1/tiles/90/*.pkt, out/v1/peaks/CH.sqlite.deflate
out/reports/CH.json      QA: peaks per source, official-vs-DEM summit heights, timing
out/build/CH.sqlite      uncompressed peak DB, handy for inspecting with sqlite3
```

## Code map

| module | does |
|---|---|
| `tiles.py` | tile names (`N45E007`), bboxes, Copernicus URLs and grid sizes |
| `dem.py` | download/cache Copernicus tiles, add the shared edge row/column, fill voids, bilinear sampling |
| `encode.py` | codecs, the planar predictor, the `.pkt` container |
| `countries.py` | Natural Earth countries, country (+ buffer) → tiles |
| `peaks/osm.py` | `natural=peak/volcano` from `.osm.pbf` (Geofabrik) |
| `peaks/wikidata.py` | SPARQL: names in ~25 languages, elevation, prominence, Wikipedia |
| `peaks/geonames.py` | GeoNames country dumps (`PK`, `MT`, `VLC`, optionally `HLL`) |
| `peaks/merge.py` | de-duplication, stable IDs, isolation, label importance |
| `peaks/enrich.py` | DEM summit heights + QA report |
| `peaks/db.py` | SQLite writer (R-tree + FTS5) |
| `packs.py` | puts it all together, writes manifests and the catalog |

## Licences of the output

- Tiles: Copernicus DEM, free to redistribute with attribution (see `ATTRIBUTION` in `packs.py`).
- Peak DBs contain OpenStreetMap data, so they are a derivative database under the **ODbL**:
  attribute, and offer the DBs under ODbL. GeoNames requires CC BY attribution.
