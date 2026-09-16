# Srisurart POS — Flutter client, setup guide

The full project context (architecture, backend, CI/CD, ticket history) is in the repo root's
`CLAUDE.md` and `docs/Backend_design/`. This file is only the **local setup + run instructions**
per platform.

🔴 **Officially shipped targets are Android / iOS / Web** (`CLAUDE.md`, "Targets Android/iOS +
Web"). Windows and macOS desktop are **local dev conveniences only** — useful for quickly
running the app without an emulator/simulator/browser — not part of the shipped product, not
covered by CI, and not something the shop runs. Their platform folders (`windows/`, `macos/`)
were added 2026-09-16 purely so `flutter run -d windows` / `-d macos` work locally.

## Prerequisites (all platforms)

```bash
flutter pub get
```

Non-ASCII paths (e.g. a Thai folder name) break `build_runner` and `flutter analyze` — see the
root `CLAUDE.md` "build path constraint" section before running codegen or `flutter analyze`.
Use `dart analyze`, not `flutter analyze`.

Check what Flutter can see on this machine:
```bash
flutter devices
flutter doctor
```

---

## Android

```bash
flutter run -d <android-device-or-emulator-id>
```
Needs Android SDK + a connected device or a running emulator (`flutter emulators --launch <id>`
if one is configured). Shipped target — this is what the shop's Android hardware runs (or would,
post phase-1-cutover; see root `CLAUDE.md` "Branch strategy").

## iOS

```bash
flutter run -d <ios-device-or-simulator-id>
```
Needs a macOS host with Xcode installed, and (for a physical device) a signing team configured
in `ios/Runner.xcworkspace`. Cannot be built or run from Windows. Shipped target.

## Web

```bash
flutter run -d chrome
```
🔴 **Currently broken on this machine (matches known bug #266, open, owned by LomerAlloys):**
```
RethrownDartError: LinkError: WebAssembly.instantiate(): Import #10 "dart" "xFileControl":
function import requires a callable
Using WasmStorageImplementation.sharedIndexedDb due to missing browser features:
{MissingBrowserFeature.dedicatedWorkersInSharedWorkers, MissingBrowserFeature.sharedArrayBuffers}
```
The web build needs a Chromium browser that supports `dedicatedWorkersInSharedWorkers` for
drift's web-worker storage path; without it the app never boots, even with the web-DB assets
(`web/sqlite3.wasm`, `web/drift_worker.js`) correctly matched to `pubspec.lock` (see
`web/WEB_DB_ASSET_VERSIONS.txt` and root `CLAUDE.md`'s "Web DB" section). This is a drift/sqlite3
compatibility gap, not an asset-sync problem — don't try to fix it by re-syncing assets. If your
browser does support that feature, `flutter run -d chrome` should work normally. Shipped target
regardless of this local gap — production web builds target browsers where this isn't an issue,
and #266 tracks the fix.

`flutter build web --no-tree-shake-icons` is the command that produces the deployed artifact
(`.github/workflows/flutter.yml` runs this in CI); it doesn't require a browser to succeed.

## Windows (desktop, local dev only)

```bash
flutter run -d windows
```
Needs Windows **Developer Mode** enabled once per machine (Flutter's plugin build uses
symlinks):
```
start ms-settings:developers
```
→ turn on **Developer Mode** in the Settings window that opens. Without it:
```
Building with plugins requires symlink support.
Please enable Developer Mode in your system settings.
```
Not affected by the web-DB issue above — uses native SQLite via `drift_flutter`, not the
WASM/worker path.

## macOS (desktop, local dev only)

```bash
flutter run -d macos
```
Needs a macOS host with Xcode command-line tools. Not tested from this session (added on a
Windows machine, so the platform files exist but were never run here) — if you hit a build
issue, it's genuinely unverified territory, not a known/expected failure like the two above.

---

## Generating a demo snapshot for local testing

**Settings → แท็บ สำรอง/กู้คืน → ดาวน์โหลดไฟล์ backup** exports the app's current data as
`pos-backup-YYYYMMDD.json`, the same shape the real shop's backup takes and the same shape
`POST /platform/tenants/{id}/import` on the server expects. See
`docs/handoff_log/manual-launch-frontend-for-demo-snapshot.md` at the repo root for the full
walkthrough (why Chrome doesn't work here, what this file is and isn't good for).

## Codegen (Drift schema changes only)

```bash
dart run build_runner build   # ASCII path only — see root CLAUDE.md
```

## Tests

```bash
flutter test
```
