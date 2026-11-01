# Peaker for iOS

SwiftUI app for iOS 26 (Liquid Glass). The project file is generated from `project.yml` by XcodeGen.

```sh
brew install xcodegen
cd ios && xcodegen          # creates Peaker.xcodeproj
open Peaker.xcodeproj       # set your team under Signing & Capabilities to run on a device
```

Without a data server the app uses the bundled demo pack (Zermatt / Bernese Alps, ~7 MB). To try
downloads locally, set the build setting `PEAKER_DATA_URL` (see `docs/ci-setup.md`).

| path | what |
|---|---|
| `PeakerKit/` | Swift package with the platform-independent core: geo maths, `.pkt` tile decoder, horizon/ridge engine, camera projection, label layout, catalog models. `swift test` runs on macOS and Linux. |
| `Peaker/App` | app entry, `AppModel` (state, horizon computation), settings |
| `Peaker/Services` | GPS, Core Motion attitude, camera, tile loader, SQLite peak queries, pack downloads |
| `Peaker/Views` | viewer (camera / touch mode), panorama canvas, compass, sheets |
| `Peaker/Resources/DemoPack` | bundled tiles + peaks around Zermatt (built by `pipeline/`) |

CI: `.github/workflows/ios.yml` builds and tests every change on macOS and uploads `master` to TestFlight.
