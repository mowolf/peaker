# Peaker — Roadmap & TODO

Peaker is an iOS app that shows the names of the mountains you are looking at. It uses
GPS, the compass/gyro (or a manual touch mode) and offline elevation data to draw the
visible ridge lines and label the peaks.

Each item has an ID (e.g. `D-3`) so it can be turned into a GitHub issue later.
Milestones are listed roughly in order, but the **data pipeline (D, P, K)** and the
**iOS app (A, T, R, M)** can be worked on in parallel once milestone 0 is done.

---

## Milestone 0 — Foundations & key decisions

These choices affect everything after them, so settle them first.

- [ ] **F-1** Choose the elevation source(s) (see the source table below). Proposal: **Copernicus GLO-90**
      as the base layer everywhere, **Copernicus GLO-30** as an optional high-detail layer.
- [ ] **F-2** Choose the tiling scheme. Proposal: **1°×1° lat/lon tiles** (same as Copernicus/SRTM), named
      `N46E007`. A country pack is then a *list of tiles*, and tiles shared by neighbouring
      countries are stored only once on the device.
- [ ] **F-3** Choose the tile encoding. Benchmark size and decode speed on ~20 mountain tiles:
  - 16-bit grayscale PNG (metres + offset), decoded with ImageIO
  - Terrarium RGB PNG: `h = (R·256 + G + B/256) − 32768`
  - Raw int16 + LZFSE/zstd (Apple `Compression` framework)
  - Lossless WebP / LERC
- [ ] **F-4** Set the maximum view distance (proposal: 250 km) and the **border buffer** for country packs.
      Ridges are often visible across borders (e.g. the Alps from southern Germany), so a pack should
      include tiles within X km of the border, or the app should suggest neighbouring packs.
- [ ] **F-5** Define a **stable peak ID** (needed by the V2 diary). OSM node IDs can change when a node is
      deleted and recreated. Proposal: `wd:Q1374` if a Wikidata ID exists, else `osm:n123456`. Keep an
      alias table across dataset versions, and use coordinates as a fallback when matching.
- [ ] **F-6** Review licenses and write `ATTRIBUTION.md` (Copernicus, OSM ODbL share-alike for the peak DB,
      GeoNames CC BY, Natural Earth public domain).
- [ ] **F-7** Choose hosting for data packs. Proposal: Cloudflare R2 (no egress fees) behind a custom domain,
      with versioned paths `/v1/...`.
- [ ] **F-8** Set the minimum iOS version (proposal: iOS 17, Swift 6, SwiftUI) and check that the name
      "Peaker" is free on the App Store and as a trademark.

### Candidate data sources

| Data | Source | Coverage / resolution | License | Notes |
|---|---|---|---|---|
| Elevation | Copernicus DEM GLO-30 / GLO-90 (AWS Open Data, COG) | Global, 30 m / 90 m | Free incl. commercial, attribution | DSM (includes trees/buildings); a few tiles withheld → fill from GLO-90 / SRTM |
| Elevation | NASADEM / SRTM | 60°N–56°S, 30 m | Public domain | No coverage in the far north (Scandinavia, Alaska…) |
| Elevation | AWS Terrain Tiles (Terrarium PNG) | Global, web-mercator z0–15 | Mixed sources, attribution list | Already PNG-encoded, but mercator tiles are awkward for this use |
| Elevation | Viewfinder Panoramas (de Ferranti) | Mountains, void-filled | **Check commercial terms** | Very good quality in the Alps/Himalaya |
| Elevation | ArcticDEM / REMA | Polar regions | Free, attribution | Only needed for high latitudes |
| Peaks | OpenStreetMap `natural=peak\|volcano` (+ `name:*`, `ele`, `wikidata`, `prominence`) | Global | ODbL | Main source. Geofabrik country extracts + `osmium tags-filter` |
| Peaks | Wikidata | Global | CC0 | Multilingual names, prominence, Wikipedia links |
| Peaks | GeoNames (feature codes `MT`, `PK`, `VLC`…) | Global | CC BY 4.0 | Fills gaps where OSM has few peaks |
| Borders | Natural Earth 1:10m admin-0 / geoBoundaries | Global | PD / CC BY | Country polygons for selecting tiles |

---

## Milestone 1 — Elevation data pipeline (`pipeline/`)

Python, GDAL/rasterio, runs locally and in CI or as a batch job.

- [ ] **D-1** Set up `pipeline/` (uv/poetry, rasterio, numpy, shapely, pyproj, osmium) with a Dockerfile so GDAL versions match everywhere.
- [ ] **D-2** Download/mirror the Copernicus GLO-90 (and GLO-30) tiles from `s3://copernicus-dem-90m` / `-30m`.
- [ ] **D-3** Normalise tiles: one CRS (EPSG:4326), integer metres, sea/no-data → 0, fill voids (interpolate or use another source).
- [ ] **D-4** Encode tiles in the format chosen in F-3 and write a per-tile JSON sidecar (bounds, resolution, min/max height, SHA-256, size).
- [ ] **D-5** Optional: build multi-resolution levels (e.g. 30 m / 90 m / 270 m) so far-away terrain loads cheaply.
- [ ] **D-6** Validate: spot-check known summits (tile height vs official height), check tile seams, plot hillshades.
- [ ] **D-7** Size report: MB per country at each resolution, to decide whether GLO-30 is affordable for large countries (RU, CA, US, CN…).

## Milestone 2 — Peak data pipeline

- [ ] **P-1** Extract `natural=peak`, `natural=volcano` (optionally `mountain_pass`, `saddle`) from the OSM planet or Geofabrik extracts.
- [ ] **P-2** Join with Wikidata (multilingual names, prominence, Wikipedia URL, image).
- [ ] **P-3** Merge GeoNames peaks that are missing from OSM (deduplicate by distance + name similarity).
- [ ] **P-4** Fill in missing `ele` from the DEM. Flag large mismatches between tagged and DEM height.
- [ ] **P-5** Compute or estimate **prominence**, used to decide which labels to show when there are too many.
- [ ] **P-6** Assign stable IDs (F-5) and keep the alias table between dataset versions.
- [ ] **P-7** Write a per-country SQLite DB: `peaks(id, name, names_json, lat, lon, ele, prominence, wikidata, osm_id)`
      + R-tree spatial index + FTS5 for name search.

## Milestone 3 — Country packs & hosting

- [ ] **K-1** For each country: tiles = tiles intersecting (country polygon + buffer from F-4).
- [ ] **K-2** Write `catalog.json`: dataset version, and per country the ISO 3166-1 code, localised name,
      bbox, tile list, peak DB URL, total size and checksums.
- [ ] **K-3** Upload to hosting (F-7) with immutable versioned paths and correct cache headers.
- [ ] **K-4** CI job (GitHub Actions) to rebuild the peak DBs on a schedule (OSM changes often; the DEM rarely does).
- [ ] **K-5** Small **bundled demo pack** (e.g. one Alps tile set + peaks) so the app works on first launch and in tests.

## Milestone 4 — iOS app skeleton

- [ ] **A-1** Xcode project + SPM packages:
  - `GeoKit` — coordinates, geodesy, earth curvature/refraction math
  - `TerrainKit` — tile loading and caching, height sampling, horizon computation
  - `PeakStore` — SQLite access (e.g. GRDB), spatial queries
  - `PeakerApp` — SwiftUI UI
- [ ] **A-2** CI: build + unit tests on GitHub Actions macOS runners; SwiftLint/SwiftFormat.
- [ ] **A-3** App navigation: Viewer (main), Map/Location, Downloads, Settings/Attribution.
- [ ] **A-4** Permissions with clear usage texts: location (when in use), camera, motion.
- [ ] **A-5** Settings: units (m/ft), label density, max distance, eye height, language for peak names.

## Milestone 5 — Terrain engine: ridge lines (V1 core)

- [ ] **T-1** Tile reader: decode tiles, memory-map/cache them (LRU), bilinear height sampling across tile borders.
- [ ] **T-2** Observer height: DEM height at the GPS position + eye height (GPS altitude is too inaccurate).
      Optionally refine with `CMAltimeter` (barometer).
- [ ] **T-3** Geometry: account for earth curvature and atmospheric refraction,
      `drop = d² / (2R) · (1 − k)`, with k ≈ 0.13.
- [ ] **T-4** **Horizon / ridge algorithm**. Start with a CPU radial sweep:
  - cast rays every ~0.1° of azimuth, sampling more coarsely the further out you go (use the coarser levels from D-5)
  - track the running max elevation angle along each ray. Points above it are visible; the point where a visible
    stretch ends behind closer terrain is a **ridge point**
  - join ridge points of neighbouring azimuths into polylines (by distance continuity) → skyline + inner ridges
  - use SIMD/Accelerate and run it on a background task. Target < 1 s on an iPhone 12 for 250 km.
- [ ] **T-5** Alternative/spike: render the terrain mesh into a panoramic depth buffer with **Metal** and find edges
      in the depth buffer. Compare quality and speed with T-4.
- [ ] **T-6** Peak visibility: a peak is visible if its elevation angle ≥ the horizon angle at its azimuth/distance
      (with a tolerance). Compute screen position, distance and bearing for each.
- [ ] **T-7** Label layout: no overlaps, ranked by prominence/elevation/distance, leader lines to the summit.
- [ ] **T-8** Recompute when the user moves more than ~50–100 m, and cache results.
- [ ] **T-9** Golden tests: compare computed skylines from known viewpoints against reference panoramas
      (e.g. the udeuschle.de panorama generator or your own photos).

## Milestone 6 — AR viewer: camera + sensors (V1)

- [ ] **R-1** Camera preview (AVFoundation) with the ridge/label overlay drawn in SwiftUI `Canvas` or Metal.
- [ ] **R-2** Device orientation from `CMMotionManager` deviceMotion with the `.xTrueNorthZVertical` reference frame
      → camera azimuth, pitch, roll. Low-pass filter to remove jitter.
- [ ] **R-3** Camera field of view from `AVCaptureDevice.activeFormat.videoFieldOfView` (+ zoom factor) → projection.
- [ ] **R-4** **Compass calibration**: the user drags the overlay to line it up with the real horizon. Store the offset for
      the session. Show a hint when heading accuracy is poor.
- [ ] **R-5** Handle portrait/landscape orientation.
- [ ] **R-6** Freeze/snapshot: capture a photo with the overlay and save it to Photos.

## Milestone 7 — Manual / touch mode (V1)

- [ ] **M-1** Toggle between sensor and manual mode (works without camera, e.g. indoors or for planning).
- [ ] **M-2** Drag horizontally to rotate the azimuth (with inertia), drag vertically to change pitch, pinch to zoom (FOV).
- [ ] **M-3** Rendered background instead of the camera: sky gradient, ridge lines, optional shaded terrain.
- [ ] **M-4** Compass ribbon with N/E/S/W and degree ticks. Tap a peak for details (name, height, distance, bearing).
- [ ] **M-5** Pick any viewpoint on a map ("virtual standpoint") instead of GPS.

## Milestone 8 — Offline downloads by country (V1)

- [ ] **O-1** Fetch and cache `catalog.json`, and show a country list with sizes and search.
- [ ] **O-2** Suggest the current country (reverse geocode the GPS position) and neighbouring countries for views across borders.
- [ ] **O-3** Background `URLSession` downloads: resumable, progress per country, Wi-Fi-only option / cellular warning.
- [ ] **O-4** Verify SHA-256, then move tiles into Application Support (`isExcludedFromBackup = true`).
- [ ] **O-5** Shared tile store with reference counting, so deleting a country only removes tiles no other installed pack uses.
- [ ] **O-6** Storage overview (used space per country) and delete.
- [ ] **O-7** Dataset updates: compare versions and download only changed files (mostly the peak DBs).
- [ ] **O-8** Handle a missing pack gracefully: show "download Switzerland to see peaks here" instead of an empty screen.

## Milestone 9 — V1 polish & release

- [ ] **V-1** Onboarding (permissions, first download).
- [ ] **V-2** Attribution/licenses screen (required by Copernicus and OSM).
- [ ] **V-3** Performance: battery use, thermals, memory with large packs.
- [ ] **V-4** Accessibility (Dynamic Type for labels, VoiceOver for the peak list).
- [ ] **V-5** Localisation (at least EN + DE).
- [ ] **V-6** App icon, screenshots, privacy policy, TestFlight beta, App Store submission.

---

# V2 — Peak book / peak diary

## Milestone 10 — Diary entries as Markdown in iCloud

- [ ] **B-1** iCloud Drive container (`NSUbiquitousContainers`, `NSUbiquitousContainerIsDocumentScopePublic = YES`)
      so the files show up in the Files app as **iCloud Drive › Peaker**.
- [ ] **B-2** Folder layout (proposal):
      ```
      Peaker/
        Peaks/
          matterhorn--wd-Q1374/
            2026-08-14.md
            images/
              2026-08-14-01.heic
      ```
- [ ] **B-3** Markdown format with YAML front matter. The body is free Markdown that the user can also edit outside the app:
      ```markdown
      ---
      peak_id: wd:Q1374
      osm_id: n123456
      name: Matterhorn
      elevation: 4478
      lat: 45.9763
      lon: 7.6586
      date: 2026-08-14
      summited: true
      companions: [Anna]
      ---
      # Matterhorn via Hörnli ridge
      Text …
      ![Summit](images/2026-08-14-01.heic)
      ```
- [ ] **B-4** File handling with `NSFileCoordinator`/`NSFilePresenter`. Watch for remote changes with `NSMetadataQuery`
      and download evicted files on demand (`startDownloadingUbiquitousItem`).
- [ ] **B-5** Conflicts: detect `NSFileVersion` conflicts and let the user choose or merge.
- [ ] **B-6** Fallback when iCloud is off: store locally and migrate once iCloud becomes available.
- [ ] **B-7** Editor: Markdown text editor with a small toolbar + preview (e.g. swift-markdown / MarkdownUI).
- [ ] **B-8** Entry points: tap a peak in the viewer/map → "Add entry". List of all entries per peak and overall.
- [ ] **B-9** Robust parsing: entries edited outside the app (missing fields, renamed folders) still work.
      Match to peaks by `peak_id` → `osm_id` → coordinates.

## Milestone 11 — Images in entries

- [ ] **I-1** Add photos with `PhotosPicker` and the camera, including the AR snapshot from R-6.
- [ ] **I-2** Copy into the entry's `images/` folder (HEIC/JPEG, configurable max size) and insert a relative Markdown link.
- [ ] **I-3** Privacy toggle: keep or strip EXIF GPS data.
- [ ] **I-4** Thumbnail cache (local, not in iCloud) and a gallery view per peak.
- [ ] **I-5** Delete images along with their entry. Find orphaned images.

## Milestone 12 — Visited peaks

- [ ] **X-1** Build a local index of visited peaks by scanning the front matter of all entries; update it on file changes.
- [ ] **X-2** Draw visited peaks differently in the viewer and on the map (colour/icon, e.g. ✓ marker).
- [ ] **X-3** Filters: show only visited / not visited.
- [ ] **X-4** Statistics: number of peaks, highest peak, per country / per year.
- [ ] **X-5** "Summit detection": when the user is within ~X m horizontally and vertically of a peak, suggest creating an entry.

---

## Later ideas (V3+)

- Sun/moon path overlay (sunrise/sunset behind specific peaks)
- Additional POIs: huts, passes, lakes, towns
- Apple Watch / widget showing the current direction
- Share a panorama as an image/link
- Higher-resolution packs (lidar DEMs like swissALTI3D, Austrian/German state DEMs) for selected countries
- Android version (the data pipeline and pack format stay the same)

## Open questions

- Should GLO-30 be the default for small mountainous countries and GLO-90 for large ones?
- Should packs be by country only, or also offer custom regions (e.g. "Alps") made from the same tiles?
- How to handle disputed borders and how countries are named in the catalogue?
- Free app vs. paid / in-app purchase for downloads? This affects hosting cost planning.
