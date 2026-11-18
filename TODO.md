# Peaker — Roadmap & TODO

Peaker is an iOS app that shows the names of the mountains you are looking at. It uses
GPS, the compass/gyro (or a manual touch mode) and offline elevation data to draw the
visible ridge lines and label the peaks.

Each item has an ID (e.g. `D-3`) so it can be turned into a GitHub issue later.
Decisions and measurements: [`docs/decisions.md`](docs/decisions.md). Data formats:
[`docs/tile-format.md`](docs/tile-format.md), [`docs/pack-format.md`](docs/pack-format.md). Pipeline: [`pipeline/`](pipeline/README.md).
Milestones are listed roughly in order, but the **data pipeline (D, P, K)** and the
**iOS app (A, T, R, M)** can be worked on in parallel once milestone 0 is done.

---

## Milestone 0 — Foundations & key decisions

These choices affect everything after them, so settle them first.

- [x] **F-1** Choose the elevation source(s) (see the source table below). Proposal: **Copernicus GLO-90**
      as the base layer everywhere, **Copernicus GLO-30** as an optional high-detail layer.
- [x] **F-2** Choose the tiling scheme. Proposal: **1°×1° lat/lon tiles** (same as Copernicus/SRTM), named
      `N46E007`. A country pack is then a *list of tiles*, and tiles shared by neighbouring
      countries are stored only once on the device.
- [x] **F-3** Choose the tile encoding. Benchmark size and decode speed on ~20 mountain tiles:
  - 16-bit grayscale PNG (metres + offset), decoded with ImageIO
  - Terrarium RGB PNG: `h = (R·256 + G + B/256) − 32768`
  - Raw int16 + LZFSE/zstd (Apple `Compression` framework)
  - Lossless WebP / LERC
- [x] **F-4** Set the maximum view distance (proposal: 250 km) and the **border buffer** for country packs.
      Ridges are often visible across borders (e.g. the Alps from southern Germany), so a pack should
      include tiles within X km of the border, or the app should suggest neighbouring packs.
- [x] **F-5** Define a **stable peak ID** (needed by the v0.2 peak book). OSM node IDs can change when a node is
      deleted and recreated. Proposal: `wd:Q1374` if a Wikidata ID exists, else `osm:n123456`. Keep an
      alias table across dataset versions, and use coordinates as a fallback when matching.
- [x] **F-6** Review licenses and write `ATTRIBUTION.md` (Copernicus, OSM ODbL share-alike for the peak DB,
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

- [x] **D-1** Set up `pipeline/` (uv/poetry, rasterio, numpy, shapely, pyproj, osmium) with a Dockerfile so GDAL versions match everywhere.
- [x] **D-2** Download/mirror the Copernicus GLO-90 (and GLO-30) tiles from `s3://copernicus-dem-90m` / `-30m`.
- [x] **D-3** Normalise tiles: one CRS (EPSG:4326), integer metres, sea/no-data → 0, fill voids (interpolate or use another source).
- [x] **D-4** Encode tiles in the format chosen in F-3 and write a per-tile JSON sidecar (bounds, resolution, min/max height, SHA-256, size).
- [ ] **D-5** Optional: build multi-resolution levels (e.g. 30 m / 90 m / 270 m) so far-away terrain loads cheaply.
- [x] **D-6** *(QA report in `reports/<CC>.json` + automatic fixes, see decisions.md; visual hillshade check still open)* Validate: spot-check known summits (tile height vs official height), check tile seams, plot hillshades.
- [x] **D-7** Size report: MB per country at each resolution, to decide whether GLO-30 is affordable for large countries (RU, CA, US, CN…).

## Milestone 2 — Peak data pipeline

- [x] **P-1** *(code + tests done; not yet run on a real Geofabrik extract, which was unreachable from the dev container)* Extract `natural=peak`, `natural=volcano` (optionally `mountain_pass`, `saddle`) from the OSM planet or Geofabrik extracts.
- [x] **P-2** Join with Wikidata (multilingual names, prominence, Wikipedia URL, image).
- [x] **P-3** Merge GeoNames peaks that are missing from OSM (deduplicate by distance + name similarity).
- [x] **P-4** Fill in missing `ele` from the DEM. Flag large mismatches between tagged and DEM height.
- [ ] **P-5** *(partly: isolation + `importance` score done; prominence only where OSM/Wikidata tag it)* Compute
      **prominence** from the DEM, used to decide which labels to show when there are too many.
- [x] **P-6** Assign stable IDs (F-5) and keep the alias table between dataset versions.
- [x] **P-7** Write a per-country SQLite DB: `peaks(id, name, names_json, lat, lon, ele, prominence, wikidata, osm_id)`
      + R-tree spatial index + FTS5 for name search.

## Milestone 3 — Country packs & hosting

- [x] **K-1** For each country: tiles = tiles intersecting (country polygon + buffer from F-4).
- [x] **K-2** Write `catalog.json`: dataset version, and per country the ISO 3166-1 code, localised name,
      bbox, tile list, peak DB URL, total size and checksums.
- [x] **K-3** *(published to mowolf/height-data: Europe (50 countries, 1,199 tiles 90 m + 379 tiles 30 m, ~2.4 GB) + Nepal)* Upload to hosting (F-7) with immutable versioned paths and correct cache headers.
- [ ] **K-4** CI job (GitHub Actions) to rebuild the peak DBs on a schedule (OSM changes often; the DEM rarely does).
- [ ] **K-6** *(Russia/large countries still open; Europe done without RU)* Regions for large countries (US ≈ 1.5 GB, RU, CA, CN, BR, AU at 90 m): split by admin-1
      (Natural Earth states/provinces) or named mountain regions. The format already supports this.
- [x] **K-7** *(done in the app at tile load: SummitBurnIn + labels snapped to the drawn summit)* Summit burn-in: raise the DEM around each peak to its official height (the DEM cuts sharp summits
      100–150 m too low, e.g. Matterhorn).
- [x] **K-5** ~~Bundled demo pack~~ *(removed in November 2026: it was for testing; the app ships without data and
      countries are downloaded)*.

## Milestone 4 — iOS app skeleton

- [x] **A-1** Xcode project + SPM packages:
  - `GeoKit` — coordinates, geodesy, earth curvature/refraction math
  - `TerrainKit` — tile loading and caching, height sampling, horizon computation
  - `PeakStore` — SQLite access (e.g. GRDB), spatial queries
  - `PeakerApp` — SwiftUI UI
- [x] **A-2** *(ios.yml: package tests + simulator build on macos-26, TestFlight upload; no SwiftLint yet.
      Paused: the private repo's Actions minutes are used up — build locally or on a self-hosted runner)* CI: build + unit tests on GitHub Actions macOS runners; SwiftLint/SwiftFormat.
- [x] **A-3** App navigation: Viewer (main), Map/Location, Downloads, Settings/Attribution.
- [x] **A-4** Permissions with clear usage texts: location (when in use), camera, motion.
- [x] **A-5** Settings: units (m/ft), label density, max distance, eye height, language for peak names.

## Milestone 5 — Terrain engine: ridge lines (V1 core)

- [x] **T-1** Tile reader: decode tiles, memory-map/cache them (LRU), bilinear height sampling across tile borders.
- [x] **T-2** Observer height: DEM height at the GPS position + eye height (GPS altitude is too inaccurate).
      Optionally refine with `CMAltimeter` (barometer).
- [x] **T-3** Geometry: account for earth curvature and atmospheric refraction,
      `drop = d² / (2R) · (1 − k)`, with k ≈ 0.13.
- [x] **T-4** **Horizon / ridge algorithm**. Start with a CPU radial sweep:
  - cast rays every ~0.1° of azimuth, sampling more coarsely the further out you go (use the coarser levels from D-5)
  - track the running max elevation angle along each ray. Points above it are visible; the point where a visible
    stretch ends behind closer terrain is a **ridge point**
  - join ridge points of neighbouring azimuths into polylines (by distance continuity) → skyline + inner ridges
  - use SIMD/Accelerate and run it on a background task. Target < 1 s on an iPhone 12 for 250 km.
- [ ] **T-5** Alternative/spike: render the terrain mesh into a panoramic depth buffer with **Metal** and find edges
      in the depth buffer. Compare quality and speed with T-4.
- [x] **T-6** Peak visibility: a peak is visible if its elevation angle ≥ the horizon angle at its azimuth/distance
      (with a tolerance). Compute screen position, distance and bearing for each.
- [x] **T-7** Label layout: no overlaps, ranked by prominence/elevation/distance, leader lines to the summit.
- [x] **T-8** Recompute when the user moves more than ~50–100 m, and cache results.
- [ ] **T-9** Golden tests: compare computed skylines from known viewpoints against reference panoramas
      (e.g. the udeuschle.de panorama generator or your own photos).

## Milestone 6 — AR viewer: camera + sensors (V1)

- [x] **R-1** Camera preview (AVFoundation) with the ridge/label overlay drawn in SwiftUI `Canvas` or Metal.
- [x] **R-2** Device orientation from `CMMotionManager` deviceMotion with the `.xTrueNorthZVertical` reference frame
      → camera azimuth, pitch, roll. Low-pass filter to remove jitter.
- [x] **R-3** Camera field of view from `AVCaptureDevice.activeFormat.videoFieldOfView` (+ zoom factor) → projection.
- [x] **R-4** **Compass calibration**: the user drags the overlay to line it up with the real horizon. Store the offset for
      the session. Show a hint when heading accuracy is poor.
- [x] **R-5** *(portrait + landscape panorama)* Handle portrait/landscape orientation.
- [ ] **R-6** Freeze/snapshot: capture a photo with the overlay and save it to Photos.

## Milestone 7 — Manual / touch mode (V1)

- [x] **M-1** Toggle between sensor and manual mode (works without camera, e.g. indoors or for planning).
- [x] **M-2** Drag horizontally to rotate the azimuth (with inertia), drag vertically to change pitch, pinch to zoom (FOV).
- [x] **M-3** Rendered background instead of the camera: sky gradient, ridge lines, optional shaded terrain.
- [x] **M-4** Compass ribbon with N/E/S/W and degree ticks. Tap a peak for details (name, height, distance, bearing).
- [ ] **M-5** Pick any viewpoint on a map ("virtual standpoint") instead of GPS.

## Milestone 8 — Offline downloads by country (V1)

- [x] **O-1** Fetch and cache `catalog.json`, and show a country list with sizes and search.
- [x] **O-2** *(reverse geocoding via MapKit, offline fallback: smallest catalog box; neighbours within the view
      distance; also for fixed viewpoints)* Suggest the current country (reverse geocode the GPS position) and
      neighbouring countries for views across borders.
- [x] **O-3** *(foreground downloads with progress, cancel, free-space check, extra background time when
      switching apps, size confirmation, Wi-Fi only by default with a one-time mobile-data exception; true
      background session still open)* Background `URLSession` downloads: resumable, progress per country, Wi-Fi-only option / cellular warning.
- [x] **O-4** Verify SHA-256, then move tiles into Application Support (`isExcludedFromBackup = true`).
- [x] **O-5** *(TileLedger: also protects tiles of running downloads; unused tiles removed at launch)* Shared tile
      store with reference counting, so deleting a country only removes tiles no other installed pack uses.
- [x] **O-6** Storage overview (used space per country) and delete.
- [ ] **O-7** *(partly: stored tiles have recorded checksums, so a changed tile is downloaded again when a pack
      is installed; no update check for installed packs / peak DBs yet)* Dataset updates: compare versions and
      download only changed files (mostly the peak DBs).
- [x] **O-8** Handle a missing pack gracefully: show "download Switzerland to see peaks here" instead of an empty screen.

## Milestone 9 — V1 polish & release

- [ ] **V-1** Onboarding (permissions, first download).
- [x] **V-2** Attribution/licenses screen (required by Copernicus and OSM).
- [ ] **V-3** *(partly: 30 m decode memory −35 %, label data built once per result, no redraws from unchanged
      sensor values; still to measure on a device with Instruments)* Performance: battery use, thermals, memory
      with large packs.
- [x] **V-7** *(the first Xcode build with complete checking had no concurrency warnings)* Switch the app to
      Swift 6 language mode.
- [x] **V-8** Peak search: find a peak visible from here by name (any language, accents ignored); it is highlighted
      in the view, an edge marker and a "Turn 42° right" chip show the way while it is off screen.
- [ ] **V-4** Accessibility (Dynamic Type for labels, VoiceOver for the peak list).
- [ ] **V-5** Localisation (at least EN + DE).
- [ ] **V-6** *(icon done)* App icon, screenshots, privacy policy, TestFlight beta, App Store submission.

---

# V0.2 — Peak book: climbed peaks and diary entries

**Design (decided before starting):**
- **The Markdown files are the only source of truth.** Marking a peak as climbed writes an entry file
  (front matter only, empty body); writing a diary is the same file with text. There is no database to keep in sync;
  the app's index is a cache that can be rebuilt from the files at any time.
- **One file per outing, flat folder, linked to peaks by front matter, not by path.** Renaming or moving files in
  the Files app never breaks the link, and a tour over several summits is one entry.
- **Each entry stores a snapshot of its peaks** (ID, name, elevation, coordinates), so the peak book works without
  the country's data on the phone and survives peak data rebuilds.
- **Local first, iCloud second.** Milestones 10–11 store files in the app's Documents folder (visible in Files ›
  On My iPhone › Peaker); milestone 12 moves them to iCloud Drive. Each step is usable on its own.
- **No third-party dependencies:** a small front matter reader/writer in PeakerKit (tested on Linux), SwiftUI
  `TextEditor` for editing, `AttributedString(markdown:)` for the preview.
- **Wishlist = entries with `status: planned`.** No date needed; the body holds plans (route, huts, notes). "Mark as
  climbed" turns the same file into the diary entry, so the plans become the start of the story.
- The peak book is a list in v0.2; the map for browsing entries follows in v0.3.

## Milestone 10 — Entry files and climbed peaks

- [x] **B-1** Entry format (PeakerKit `PeakEntry`): YAML front matter + free Markdown body. File name
      `2026-08-14 Matterhorn.md` (date, first peak; a number is added on clashes); wishlist entries
      `Matterhorn.md`, renamed with the date once climbed. Only the keys below are read;
      unknown keys and comments are kept unchanged when the app saves, so hand edits survive:
      ```markdown
      ---
      date: 2026-08-14
      status: summited        # or: attempted, planned (wishlist; date optional)
      peaks:
        - id: wd:Q1374        # stable ID (F-5)
          name: Matterhorn
          elevation: 4478
          lat: 45.9763
          lon: 7.6586
      companions: [Anna]
      ---
      # Matterhorn via the Hörnli ridge
      Text …
      ```
- [x] **B-2** Reader/writer with unit tests: round trip, missing or misspelt fields, extra keys, Windows line endings,
      files without front matter (shown as "unlinked", not dropped).
- [x] **B-3** Peak matching: `id` → `peak_aliases` → nearest peak within 200 m of the snapshot coordinates
      (`PeakDatabase.peak(id:)` and `peak(near:)`); no match keeps the snapshot.
- [x] **B-4** `PeakBook` store (main actor): reads the folder at launch, when the app returns to the foreground and
      when the installed peak data changes; matches entries to peaks off the main thread; writes files atomically.
      No on-disk index: a scan of a few hundred small files takes milliseconds (add one if that changes).
- [x] **B-5** Peak detail: "Mark as climbed" (today's date, can be changed), "Add to wishlist", and the list of this
      peak's entries. Climbing a wishlist peak updates its planned entry instead of adding a second file.
- [x] **B-6** Viewer: climbed peaks get a ✓, wishlist peaks a ☆ on their label (cached in `LabelMemory`, no cost per frame).
- [x] **B-7** On a summit (`isOnSummit`, already in the viewer), offer "Mark <peak> as climbed"; once per peak per day.

## Milestone 11 — Peak book and diary

- [x] **B-8** Peak book screen (from Settings or the chip menu): tabs Climbed / Wishlist, climbed entries grouped by
      year, search by peak name.
- [x] **B-9** Editor: date, status and peaks at the top, Markdown body with a small toolbar (heading, bold, list),
      Edit/Preview toggle. Autosaves.
- [x] **B-10** Add or remove peaks of an entry (search the installed peak databases with FTS).
- [x] **B-11** Statistics: peaks climbed, summits, highest peak, this year (`PeakBookStats`).
- [ ] **B-11b** Per country: needs the peak's country in the peak database (a pipeline column); the pack a peak
      came from is ambiguous in the 50 km border buffer.
- [x] **B-12** Delete an entry (with confirmation); the file goes, the index follows.

## Milestone 12 — iCloud Drive

- [ ] **B-13** iCloud container (`NSUbiquitousContainers`, `NSUbiquitousContainerIsDocumentScopePublic = YES`), so
      the files appear as **iCloud Drive › Peaker**. Needs the iCloud capability on the App ID (Apple Developer
      portal) before TestFlight builds can use it.
- [ ] **B-14** File access through `NSFileCoordinator`; changes from other devices via `NSMetadataQuery`; download
      evicted files on demand (`startDownloadingUbiquitousItem`).
- [ ] **B-15** Conflicts (`NSFileVersion`): keep both as separate files and show a badge. No merge UI in v0.2.
- [ ] **B-16** Move local entries to iCloud when it becomes available; keep working locally when it is off.

# V0.3 — Map and photos

## Milestone 13 — Peak map (3D)

Our own map from the elevation tiles: a 3D terrain model (RealityKit, no camera image) styled with height
tints, hill shading and contour lines; no roads or towns. Flat map = the same scene seen from straight above.

- [x] **M-1** Style texture (`MapStyle`: Dusk default, Alpine), height exaggeration 1–2× (Settings › Map).
- [x] **M-2** Terrain mesh and camera (`TerrainMesh`, `MapCamera`, `MapFrame`); 40 km areas, rebuilt around the view
      when it leaves the middle (`MapModel`).
- [x] **M-3** Map screen: drag, pinch, twist; 2D/3D, north up, my position.
- [x] **M-4** Peak labels thinned by importance, hidden behind ridges (line of sight), ✓ / ★, tap → peak details.
- [x] **M-5** Peak search that flies to the peak (highlighted).
- [x] **M-6** Peak book on the map: filter "Peak book only", "Map" in peak details and as a swipe action in the
      peak book.
- [x] **M-7** Zoom out to whole countries: an overview layer (160–2,400 km, from ~1 km overview tiles cached per
      downloaded tile) under the detailed 40 km layer, which cuts a hole into it; country outlines (Natural Earth,
      shipped with the app) with land of countries without data in black, sea and borders.
- [x] **M-7b** Globe: zooming out past the flat map's 400 km shows the whole Earth (downloaded countries in colour,
      others black, borders); zooming in below 350 km returns to the flat map there.
- [x] **M-7d** Water clearly apart from land (teal sea in Dusk, coastline, Natural Earth lakes); a regional layer
      (up to 240 km from the 90 m tiles) between detail and overview; peak book markers on the map and the globe.
- [x] **M-7e** Two layers only (the ~700 m overview looked rough): detail + regional (80–320 km from the 90 m
      tiles); the globe from 160 km.
- [ ] **M-7c** Measure on a device: build times, memory, frame rate.
- [ ] **M-8** Map polish: two-finger tilt, smooth camera moves, a base/skirt under the area's edges, fog.

## Milestone 14 — Photos in entries

- [ ] **I-1** Add photos with `PhotosPicker` or the camera, including the AR snapshot (R-6).
- [ ] **I-2** Store them next to the entries in `images/` (HEIC, max size setting) and insert a relative Markdown link.
- [ ] **I-3** Privacy: remove EXIF location by default, with a setting to keep it.
- [ ] **I-4** Local thumbnail cache (not in iCloud) and a gallery per peak.
- [ ] **I-5** Delete photos with their entry; find unused photos.

---

## Later ideas (V3+)

- [x] Sun path overlay with real sunrise/sunset over the terrain *(done in V1)*; moon still open
- Additional POIs: huts, passes, lakes, towns
- Apple Watch / widget showing the current direction
- Share a panorama as an image/link
- [x] 30 m packs near the viewer *(done: Copernicus GLO-30)*; even higher-resolution packs (lidar DEMs like swissALTI3D, Austrian/German state DEMs) for selected countries
- Android version (the data pipeline and pack format stay the same)
- Map extras: hiking routes or GPX tracks of entries, huts and passes

## Open questions

- Should GLO-30 be the default for small mountainous countries and GLO-90 for large ones?
- Should packs be by country only, or also offer custom regions (e.g. "Alps") made from the same tiles?
- How to handle disputed borders and how countries are named in the catalogue?
- Free app vs. paid / in-app purchase for downloads? This affects hosting cost planning.
