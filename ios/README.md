# Peaker for iOS

SwiftUI app for iOS 26 (Liquid Glass). The project file is generated from `project.yml` by XcodeGen.

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
| `Peaker/App` | app entry, `AppModel` (state, horizon computation), settings |
| `Peaker/Services` | GPS, Core Motion attitude, camera, tile loader, SQLite peak queries, pack downloads |
| `Peaker/Views` | viewer (camera / touch mode), panorama canvas, compass, sheets |
| `Peaker/Resources/BundledPacks` | packs shipped in the app, one folder each (built by `pipeline/`, `bundle` command) |

CI: `.github/workflows/ios.yml` builds and tests every change on macOS and uploads `master` to TestFlight.
