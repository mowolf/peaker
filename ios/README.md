# Peaker for iOS

SwiftUI app for iOS 26 (Liquid Glass). The project file is generated from `project.yml` by XcodeGen.

Features (V1): ridge lines and peak labels from offline elevation data; direction from gyro + compass or by
dragging; pinch zoom shared between the drawn view and the live camera (with hand alignment for compass
error); landscape panorama; sun path with real sunrise/sunset over the terrain; GPS with accuracy-aware updates;
fixed viewpoints (Gornergrat, Kala Patthar, Poon Hill); country downloads from
[mowolf/height-data](https://github.com/mowolf/height-data) with 30 m terrain near the viewer.

```sh
brew install xcodegen
cd ios && xcodegen          # creates Peaker.xcodeproj
open Peaker.xcodeproj       # set your team under Signing & Capabilities to run on a device
```

Without a data server the app uses the packs bundled in `Peaker/Resources/BundledPacks/` (Zermatt demo, Nepal).
Fixed viewpoints (Gornergrat, Kala Patthar, Poon Hill) let you try them anywhere. To try downloads, set the build
setting `PEAKER_DATA_URL` (see `docs/ci-setup.md`).

Bundled packs are exported by the pipeline:

```sh
cd pipeline
peaker-pipeline pack NP                       # build into ./out
peaker-pipeline bundle NP --dest ../ios/Peaker/Resources/BundledPacks/NP
peaker-pipeline bundle CH --dest ../ios/Peaker/Resources/BundledPacks/DEMO --bbox 7,45,9,47 --code DEMO \
    --name "Matterhorn & Bernese Alps (demo)"
```

| path | what |
|---|---|
| `PeakerKit/` | Swift package with the platform-independent core: geo maths, `.pkt` tile decoder, horizon/ridge engine, camera projection, label layout, catalog models. `swift test` runs on macOS and Linux. |
| `Peaker/App` | app entry, `AppModel` (view state, sensors, modes), `HorizonStore` (background horizon computation, visible peaks, sun), settings, fixed viewpoints |
| `Peaker/Services` | GPS, Core Motion attitude, camera, tile loader, SQLite peak queries, `PackStore` (installed packs, tile bookkeeping) and `PackDownloader` (networking, checksums) |
| `Peaker/Views` | viewer (camera / touch mode), panorama canvas, compass, sheets |
| `Peaker/Resources/BundledPacks` | packs shipped in the app, one folder each (built by `pipeline/`, `bundle` command) |

Concurrency: UI state is on the main actor (`AppModel`, `AppSettings`, `PackStore`, `HorizonStore` and the
sensor services). Heavy work runs off it: the horizon sweep and tile decoding in a detached task and the
`TileLoader` actor, downloads and checksums in `PackDownloader`, and the capture session on the camera's own
queue. Sensor callbacks arrive on the main queue and enter the main actor with `MainActor.assumeIsolated`
(Core Location through a `@MainActor` delegate conformance).

CI: `.github/workflows/ios.yml` builds and tests every change on macOS and uploads `master` to TestFlight.
