# CI setup: secrets and variables

Add these in GitHub: **Settings → Secrets and variables → Actions**. Secrets go under the *Secrets*
tab, variables under the *Variables* tab.

| name | kind | used by | what |
|---|---|---|---|
| `APP_STORE_CONNECT_KEY_ID` | secret | ios | Key ID of an App Store Connect API key, e.g. `2X9R4HXF34` |
| `APP_STORE_CONNECT_ISSUER_ID` | secret | ios | Issuer ID (UUID shown above the keys list) |
| `APP_STORE_CONNECT_PRIVATE_KEY` | secret | ios | Contents of the downloaded `AuthKey_<KEYID>.p8` (paste the text, or its base64) |
| `APPLE_TEAM_ID` | secret | ios | 10-character Team ID (developer.apple.com → Membership) |
| `IOS_BUNDLE_ID` | variable | ios | Optional. Default `com.moritzwolf.peaker` |
| `HEIGHT_DATA_TOKEN` | secret | build-packs | Fine-grained token, repository `mowolf/height-data`, permission **Contents: Read and write** — lets the weekly job push peak databases |
| `R2_ACCESS_KEY_ID` | secret | (R2 alternative) | R2 API token: Access Key ID |
| `R2_SECRET_ACCESS_KEY` | secret | build-packs | R2 API token: Secret Access Key |
| `R2_ACCOUNT_ID` | variable | build-packs | Cloudflare account ID (R2 overview page, right side) |
| `R2_BUCKET` | variable | build-packs | Bucket name, e.g. `peaker-data` |
| `PEAKER_DATA_URL` | variable | ios, build-packs | Public URL of the bucket, **without** `/v1` and without a trailing slash, e.g. `https://data.peaker.app` or `https://pub-xxxx.r2.dev` |

Missing secrets don't break CI: the app is still built and tested, only the upload is skipped
(with a warning). The same goes for publishing packs.

## TestFlight (`.github/workflows/ios.yml`)

One-time setup in Apple's portals:

1. **App Store Connect API key**: [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
   → *Team Keys* → **+**. Give it the **Admin** role. Admin is needed so Xcode can use Apple's
   cloud-managed distribution certificate and create the provisioning profile. Download the `.p8`
   (you can only download it once). The key ID and issuer ID are shown on the same page.
2. **App record**: [App Store Connect → Apps → + → New App](https://appstoreconnect.apple.com/apps): platform iOS,
   name "Peaker" (or any free name), bundle ID `com.moritzwolf.peaker` (or your `IOS_BUNDLE_ID`), SKU e.g. `peaker`.
   If the bundle ID isn't in the list yet, register it first under
   [Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   (explicit App ID, no capabilities needed).
3. Add the four secrets above.

Then every push to the default branch (`master`) that touches `ios/` uploads a build. You can also
start one by hand: **Actions → ios → Run workflow** (the workflow file must be on the default branch).
The build number is the workflow run number. Builds show up in TestFlight after Apple's processing
(5–30 min). Add yourself as an internal tester in App Store Connect → TestFlight.

How signing works: the archive is built unsigned. `xcodebuild -exportArchive` then signs it with automatic
signing, authenticated by the API key (`-allowProvisioningUpdates`): Apple's cloud-managed distribution
certificate and an App Store provisioning profile are created and used on the fly, and the build is
uploaded. No certificates or profiles are stored in GitHub.

If export fails with a signing error (e.g. the key lacks the Admin role, or the team has cloud-managed
certificates disabled), the fallback is the classic setup: a distribution certificate `.p12` plus an App Store
provisioning profile as secrets, imported into a temporary keychain. Ask and we'll switch the workflow.

## Building without GitHub Actions minutes

The private repo's included macOS minutes run out quickly (macOS minutes count 10×). Options:

- **Make the repository public.** Standard GitHub-hosted runners, macOS included, are free for public
  repositories, so all three workflows run unchanged (TestFlight included). Secrets stay secret: they are not
  shown in logs and not given to pull requests from forks. Before switching, decide on a licence (without a
  `LICENSE` file the code is visible but all rights reserved).
- **Xcode Cloud** (keeps the repo private): 25 compute hours a month are included in the Apple Developer
  Program. It builds, tests and uploads to TestFlight with Apple-managed signing (no API key secrets needed).
- **Self-hosted runner** on your own Mac: jobs there don't use Actions minutes. Register the Mac under
  Settings → Actions → Runners and set `runs-on: self-hosted` in `ios.yml`.

### Xcode Cloud setup

The project file isn't committed (XcodeGen), so `ios/ci_scripts/ci_post_clone.sh` installs XcodeGen and
generates `ios/Peaker.xcodeproj` after every clone, before Xcode Cloud looks for the project.

One-time, on a Mac with Xcode 26 (workflows can only be created from Xcode):

1. `cd ios && xcodegen generate && open Peaker.xcodeproj`, and check it builds locally.
2. Report navigator (⌘9) → **Cloud** → **Get Started** → select the **Peaker** app (the App Store Connect app
   record from the TestFlight setup above) → product **Peaker**, scheme **Peaker**.
3. Grant access to the source code: Xcode opens GitHub to install Apple's Xcode Cloud app on `mowolf/peaker`.
4. Edit the default workflow:
   - **Start condition:** branch changes on `master`, files in `ios/` (optionally also pull requests).
   - **Actions:** *Archive – iOS*, deployment preparation **TestFlight (Internal Testing Only)**;
     optionally *Build – iOS* or *Test* for pull requests.
   - **Post-actions:** *TestFlight Internal Testing* → choose a tester group.
5. Build numbers: Xcode Cloud numbers its builds itself. GitHub Actions already uploaded builds with the run
   number, so in App Store Connect → Xcode Cloud → Settings → *Build Number*, set the next build number above
   the highest one in TestFlight (otherwise uploads of version 0.1.0 are rejected).

After that, every matching push builds in Xcode Cloud; workflows and build logs are also in App Store Connect
→ Xcode Cloud. PeakerKit's tests run in GitHub Actions or with `swift test` (they aren't part of the app
scheme).

## Country packs in mowolf/height-data (`.github/workflows/build-packs.yml`)

Elevation tiles are built once with `peaker-pipeline build-tiles` (hours for a continent; 30 m only for
mountainous tiles) and pushed to the public repo `mowolf/height-data`. The weekly `build-packs` job rebuilds only
the peak databases of the countries in `pipeline/packs.txt` (OSM via Geofabrik + GeoNames, Wikidata where the
line says `--wikidata`), using the published tile index, and pushes them with `HEIGHT_DATA_TOKEN`:
GitHub → Settings → Developer settings → Fine-grained tokens → Generate: repository access *Only select
repositories* → `mowolf/height-data`, Repository permissions → *Contents: Read and write*.

## Alternative: Cloudflare R2

1. Cloudflare dashboard → **R2** → *Create bucket* (e.g. `peaker-data`, location automatic).
2. Make it public. Either bucket → *Settings* → *Public access* → **R2.dev subdomain: Allow** (quick, rate-limited),
   or better **Custom domains → Connect domain** (e.g. `data.peaker.app`, gets Cloudflare caching).
   The resulting URL is `PEAKER_DATA_URL`.
3. R2 → **Manage R2 API tokens** → *Create API token*: permission **Object Read & Write**, limited to this
   bucket. Copy the Access Key ID and Secret Access Key → `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`.
4. Account ID: R2 overview page → `R2_ACCOUNT_ID`. Bucket name → `R2_BUCKET`.

Run **Actions → build-packs → Run workflow** (countries e.g. `CH AT`). Without input it builds the
list in `pipeline/packs.txt`, and it also runs every Monday. The first build of a country takes a while
(Wikidata is queried tile by tile); later runs reuse the cache.

After the first publish, check `https://<PEAKER_DATA_URL>/v1/catalog.json` in a browser. New TestFlight
builds pick up the URL from the `PEAKER_DATA_URL` variable, and the Offline maps screen lists the countries.
