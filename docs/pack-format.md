# Country packs: hosting layout and app contract (version 1)

Built by `pipeline/` (`peaker-pipeline pack NP --res 90 30`). Everything is static files. Currently hosted in the
public GitHub repo [mowolf/height-data](https://github.com/mowolf/height-data)
(`https://raw.githubusercontent.com/mowolf/height-data/main`, published with `peaker-pipeline publish --repo`);
Cloudflare R2 via the `build-packs` workflow is the scalable alternative (docs/ci-setup.md).

Packs contain 90 m tiles for the whole area and, optionally, 30 m tiles. The app uses 30 m for tiles within
~35 km of the viewer (26 MB in memory each) and 90 m everywhere else.

```
v1/catalog.json                 all countries + land-tile bitsets          (mutable, short cache)
v1/countries/CH.json            manifest of one pack                       (mutable, short cache)
v1/tiles/90/N45E007.pkt         elevation tile, shared by all packs        (immutable)
v1/tiles/30/N45E007.pkt         optional high-detail tile                  (immutable)
v1/peaks/CH.sqlite.deflate      peak database of one pack                  (mutable, replaced on rebuild)
```

## Why packs are lists of tiles

- **Borders:** you often see mountains in the neighbouring country. A pack contains
  every tile within `buffer_km` (default 50 km) of the country, and its peak DB holds
  all peaks inside those tiles, whatever country they are in.
- **Dedup:** CH and AT share tiles. The app keeps one tile store (`Application Support/Packs/tiles/<res>/`)
  and downloads a tile only once. `TileLedger` (PeakerKit) tracks which installed packs and which running
  downloads need each tile; a tile is deleted only when none do. Files nobody uses (e.g. from a cancelled
  download) are removed at the next launch. `Packs/tile-checksums.json` records the SHA-256 of every stored
  tile, so a tile whose manifest checksum changed (new dataset version) is downloaded again.
- **Regions later:** "Alps" or "Colorado" is just another list of tiles, with no new format.

## `catalog.json`

```jsonc
{
  "format_version": 1,
  "generated_at": "2026-11-01T08:00:00Z",
  "attribution": [{"name": "Copernicus DEM", "text": "…", "url": "…"}, …],  // show in Settings › Licenses
  "land_tiles": {"90": "<base64>", "30": "<base64>"},
  "countries": [
    {"code": "CH", "name": "Switzerland", "bbox": [5.95, 45.82, 10.47, 47.80],
     "manifest": "countries/CH.json", "built_at": "…",
     "bytes": {"90": 25000000}, "tiles": {"90": 23}, "peaks": 9000, "neighbours": ["AT", "DE", "FR", "IT", "LI"]}
  ]
}
```

`land_tiles` is a bitset of the tiles that have elevation data. Bit
`i = (lat + 90) * 360 + (lon + 180)` is `bytes[i / 8] >> (i % 8) & 1`. A tile without
its bit is ocean, so use height 0 and don't try to download it. The app needs this to
tell "sea" apart from "not downloaded".

## `countries/CH.json`

```jsonc
{
  "format_version": 1, "code": "CH", "name": "Switzerland", "built_at": "…",
  "buffer_km": 50, "bbox": […], "tile_codec": "pred2d-deflate@1m",
  "tiles": {"90": [{"name": "N45E007", "bytes": 1203394, "sha256": "…"}, …]},
  "peaks": {"path": "peaks/CH.sqlite.deflate", "bytes": …, "uncompressed_bytes": …, "sha256": "…",
            "count": 9000, "schema_version": 1},
  "neighbours": ["AT", "DE", "FR", "IT", "LI"]
}
```

`sha256` is of the file as downloaded. Tile URL: `v1/tiles/<res>/<name>.pkt`.

## Peak database

`*.sqlite.deflate` is the SQLite file compressed with raw DEFLATE (`COMPRESSION_ZLIB`).
Inflate it to `Application Support/Packs/peaks/CH.sqlite` and open it read-only.

Tables (schema version 1, `PRAGMA user_version = 1`):

| table | purpose |
|---|---|
| `peaks` | one row per peak: `id` (stable, see below), `name`, `names` (JSON lang→name), `lat`, `lon`, `ele`, `ele_source`, `dem_ele`, `prominence`, `isolation_km`, `importance` (0–1 label priority), `kind`, `wikidata`, `osm_id`, `geonames_id`, `wikipedia`, `sources`, `qa` (build-time fixes: `alt_source`, `unit_fixed`, `snapped`, `ele_conflict`) |
| `peaks_rtree` | R-tree on (lat, lon) for "peaks near me" |
| `peaks_fts` | FTS5 over names (contentless, diacritics removed) for search |
| `peak_aliases` | other IDs of the same peak (e.g. `osm:n123` → `wd:Q1374`) |
| `meta` | `schema_version`, `country`, `built_at`, `sources` |

Peaks near the border appear in several packs. The app de-duplicates by `id` when it
queries more than one DB.

```sql
-- peaks within a bbox, most important first
SELECT p.* FROM peaks_rtree r JOIN peaks p ON p.rowid = r.rowid
WHERE r.min_lat <= :north AND r.max_lat >= :south AND r.min_lon <= :east AND r.max_lon >= :west
ORDER BY p.importance DESC;

-- search
SELECT p.* FROM peaks_fts f JOIN peaks p ON p.rowid = f.rowid WHERE peaks_fts MATCH :query || '*' LIMIT 20;
```

### Stable peak IDs (decision F-5)

`wd:Q1374` when the peak has a Wikidata item, else `osm:n<node id>`, else `gn:<geonames id>`.
Peak book entries (v0.2, TODO B-1) store this ID plus a snapshot of name, elevation and coordinates. To resolve one: look up `peaks.id`,
then `peak_aliases`, then the nearest peak within ~200 m.

## App download flow

1. Fetch `catalog.json` (ETag / If-None-Match).
2. The user picks a country. Fetch its manifest and work out which tiles are missing
   from the local tile store.
3. Download the missing tiles and the peak DB with a background `URLSession`. Check
   each file's size and SHA-256, then move it into place.
4. Record the pack as installed: `{code, built_at, tiles}`. Tile refcount = number of installed packs listing it.
5. Updates: when `built_at` changes, diff the manifests. Tiles rarely change; usually only the peak DB does.
