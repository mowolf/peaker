# Decisions (Milestone 0)

Each entry: the decision, why, and what would make us revisit it. IDs match `TODO.md`.

## F-1 Elevation source: Copernicus DEM GLO-90 by default, GLO-30 optional

- **Global coverage**, including above 60°N where SRTM/NASADEM has nothing (Norway, Alaska, Iceland).
- **Free for commercial use** with attribution, and mirrored on AWS Open Data as 1°×1°
  COGs (`s3://copernicus-dem-90m`, `-30m`). No account is needed and egress from the bucket is free.
- GLO-90 has 26,475 tiles. GLO-30 has 26,450: 25 tiles are withheld, so fall back to GLO-90 there.
- **Known weakness:** it is a radar *surface* model, and sharp summits come out too low. Measured:
  Matterhorn 4,478 m → 4,330 m (GLO-30) / 4,317 m (GLO-90); Dufourspitze 4,634 m → 4,542 / 4,534 m.
  Effect on the app: the skyline near steep peaks sits slightly low. Mitigations:
  1. Label positions use the official `ele` from the peak DB, not the DEM.
  2. Optional, later: "burn in" known summit heights into the tile around each peak at build time (T-4 follow-up).
- GLO-90 is the default because 30 m is about 9× the size (Switzerland about 200 MB instead of about 25 MB) and
  90 m is enough for ridges more than ~2 km away. 30 m is offered as an optional "high detail" download.
- Revisit if Viewfinder Panoramas' licence allows redistribution (better summits in the Alps and Himalaya), or
  for national lidar DEMs (swissALTI3D etc.) in V3.

## F-2 Tiling: 1°×1° tiles, packs are lists of tiles

- Same grid as the source, so no resampling or reprojection is needed. Pixel centres sit on the tile edges
  (point-registered), and each Peaker tile repeats its neighbours' edge row/column (1201×1201 at 90 m).
- A country pack is the set of tiles within the buffer (F-4) of the country, so tiles shared between
  countries are downloaded once. Format: `docs/pack-format.md`.

## F-3 Tile encoding: `.pkt` = planar predictor + byte planes + raw DEFLATE, 1 m steps

Benchmark (`peaker-pipeline bench-encoding`), 8 GLO-90 tiles from Alps, Himalaya, Andes, Sierra Nevada,
North German plain, Côte d'Azur and Norway; sizes are totals:

| codec | total MB | vs PNG16 | iOS decoder |
|---|---:|---:|---|
| raw int16 | 20.64 | 234% | — |
| 16-bit grayscale PNG, 1 m | 8.84 | 100% | ImageIO |
| 16-bit PNG, 0.25 m | 11.78 | 133% | ImageIO |
| Terrarium RGB PNG | 9.44 | 107% | ImageIO |
| **predictor + DEFLATE, 1 m** | **7.62** | **86%** | Compression `COMPRESSION_ZLIB` |
| predictor + DEFLATE, 0.25 m | 9.57 | 108% | Compression |
| predictor + LZMA, 1 m | 7.13 | 81% | Compression `COMPRESSION_LZMA` |
| predictor + Brotli, 1 m | 7.09 | 80% | Compression `COMPRESSION_BROTLI` |

Per tile: about 1.2–1.3 MB for high mountains, 0.3–0.6 MB for flat land and coast.

Why DEFLATE rather than Brotli/LZMA: they save only another 7%, while zlib is native everywhere
(iOS, Android `Inflater`, browsers), which keeps an Android or web viewer cheap later.
The container has a codec byte, so switching to Brotli later needs no format change.
Why 1 m: the DEM's own vertical error is several metres. 0.25 m costs a third more for nothing.
PNG remains available (`png16` codec) for debugging, since PNGs open in any image viewer.

GLO-30 (4 tiles: Alps, Himalaya, flat, coast), totals: PNG16 25.4 MB, **predictor + DEFLATE 24.1 MB (95%)**,
LZMA 21.9 MB (86%), Brotli 21.1 MB (83%). At 30 m the predictor gains less over PNG (and loses on flat
land), and Brotli's advantage grows to 13%. If 30 m packs become popular, switch 30 m tiles to codec 4
(Brotli). That needs no format change, only Android/web support for Brotli.
Mountain tiles at 30 m are 8–9 MB each.

## F-4 View distance and border buffer

- Max view distance in the app: **250 km** (setting). Ridges further away are rare and need perfect weather.
- Pack buffer: **50 km** around the country. This covers the large majority of cross-border
  views without making packs much larger (Switzerland: 14 tiles → 23). For longer views, the
  app suggests the neighbouring packs (`neighbours` in the manifest).
- Peaks in the buffer come from the neighbouring countries' sources, so a CH pack labels
  Mont Blanc (FR/IT) and the Zugspitze (DE/AT).

## F-5 Stable peak IDs

`wd:Q…` (Wikidata) → `osm:n…` (OSM node) → `gn:…` (GeoNames). Every other known ID goes into
`peak_aliases`. Diary entries store the ID **and** the coordinates; resolution order is ID →
alias → nearest peak within ~200 m. Wikidata QIDs are the most stable (they survive OSM node
re-creation and are shared across languages).

## Peak sources: OSM primary, Wikidata and GeoNames to enrich and fill gaps

- **OSM** (`natural=peak|volcano`) has the best positions and local names. It is read from Geofabrik country
  extracts with pyosmium. Geofabrik and Overpass were unreachable from the dev container, so the first
  test pack was built with `--no-osm`. Run the full pipeline somewhere with access (CI or a laptop).
- **Wikidata** adds names in ~25 languages, prominence, Wikipedia links, and stable IDs. Query shape matters
  (measured Nov 2026):
  - "items in country X" (`wdt:P17`) times out for big countries (France), because the service scans
    every geotagged French item;
  - "items of class X, filtered by lat/lon" times out;
  - the spatial index `wikibase:box` per 1°×1° tile works: 10–16 s per alpine tile, 850–2,800 items. Dense
    urban tiles (Paris) time out, so those are split into quarters (up to 3 levels) and finally skipped.
  So Wikidata is fetched **per tile**, cached per tile and shared between packs. Details (labels etc.) are
  fetched in batches of 300 IDs. A full world run is about 26k tile queries, so run it on a schedule
  with caching, and be polite to the endpoint (User-Agent set, retries with backoff).
- **GeoNames** country dumps fill gaps where OSM is sparse. Their positions are often rounded, so they
  only become new peaks when nothing else is nearby.
- Merge rules: `pipeline/peaker_pipeline/peaks/merge.py` (by ID, then name + 600 m, then 150 m when unnamed).

## F-6 Licences (summary; full text goes into the app's Licenses screen)

| data | licence | obligation |
|---|---|---|
| Copernicus DEM | Copernicus licence | attribution string (in `catalog.json`) |
| OpenStreetMap | ODbL 1.0 | attribution; the peak DBs are a derivative database → offer them under ODbL |
| Wikidata | CC0 | none (credit anyway) |
| GeoNames | CC BY 4.0 | attribution |
| Natural Earth | public domain | none |

## F-7 Hosting

Static files: `catalog.json`, manifests, tiles, peak DBs. Proposal: **Cloudflare R2** behind a custom domain
(no egress fees). Even 10k downloads of a 25 MB pack would cost a lot of egress on S3/CloudFront.
Tiles are immutable (long cache). Catalog and manifests use short caching.
Not yet set up. This needs an account decision from the project owner.

## Large countries

90 m estimates (`peaker-pipeline tiles`): CH ≈ 23 MB, AT ≈ 35 MB, NP ≈ 41 MB, NO ≈ 250 MB, US ≈ 1.5 GB.
The US, Canada, Russia, China, Brazil, Australia etc. must be offered as **regions** (states/provinces,
or mountain regions like "Rockies") rather than one pack. The format already supports this, since a pack is
just a list of tiles. The pipeline needs a region source (e.g. Natural Earth admin-1) → new TODO item K-6.
