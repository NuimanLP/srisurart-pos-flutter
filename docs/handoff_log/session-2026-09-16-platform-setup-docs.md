# Session: local platform setup docs + windows/macos dev targets (2026-09-16)

**Scope:** local dev tooling and documentation only. No app code, no backend code, no CI
changes, no CLAUDE.md target-list change.

## What happened

Was trying to launch the Flutter app locally to generate a demo snapshot for #185 rehearsal
(see `docs/handoff_log/manual-launch-frontend-for-demo-snapshot.md`). Hit two real, worth-
recording findings along the way, then wrote setup docs for all five platforms as requested.

### 1. `flutter run -d chrome` reproduces #266 live

Confirmed the exact failure `CLAUDE.md` already documents under the open bug #266:
```
RethrownDartError: LinkError: WebAssembly.instantiate(): Import #10 "dart" "xFileControl":
function import requires a callable
Using WasmStorageImplementation.sharedIndexedDb due to missing browser features:
{MissingBrowserFeature.dedicatedWorkersInSharedWorkers, MissingBrowserFeature.sharedArrayBuffers}
```
This Chrome install (152.0.7977.84, this sandboxed dev environment) lacks
`dedicatedWorkersInSharedWorkers`, so drift's web-worker storage path never links. Not a new
finding — corroborates #266's existing description that this reproduces "identically with both
the old and new asset pairs" and is a drift/sqlite3 compatibility gap, not an asset-sync bug.
No action taken here; #266 is owned by LomerAlloys and already tracked.

### 2. Windows desktop wasn't a configured target

The repo's committed platform folders were Android/iOS/Web only (`CLAUDE.md`: "Targets
Android/iOS + Web"). To unblock local testing, added `windows/` and (while at it, since the
same gap exists) `macos/` via:
```bash
flutter create --platforms=android,ios,web,windows,macos .
```
run **once, listing every platform together** — running it once per platform (`--platforms=windows`
then separately `--platforms=macos`) overwrites `.metadata`'s `migration.platforms` list each
time, dropping the previously-tracked platforms from Flutter's own migration bookkeeping. Doing
it in one call keeps `.metadata` tracking all five correctly. If a real platform needs adding
later, follow the same pattern (list every existing platform folder + the new one in one command).

Also needed Windows **Developer Mode** enabled on this machine (`start ms-settings:developers`)
for the plugin build's symlinks — a one-time local machine setting, not a repo change.

**Reverted, not committed:** `flutter create`/`flutter pub get` bumped `frontend/pubspec.lock`
with unrelated transitive dependency upgrades as a side effect (`analyzer` 12.1.0→13.0.0 etc.) —
reverted with `git checkout -- frontend/pubspec.lock` each time. `CLAUDE.md` is explicit that
routine dependency bumps are human-timed, not an incidental side effect of an unrelated task
(`.github/dependabot.yml` is security-updates-only by the same reasoning). Also deleted the
generic `frontend/.gitignore` flutter create regenerated each run — fully redundant with the
root `.gitignore`'s `**/build/`, `**/.dart_tool/` etc. (verified by diff); kept the real, non-
redundant `windows/.gitignore` and `macos/.gitignore` (platform-specific: `flutter/ephemeral/`,
Xcode user files).

## What's committed

- `frontend/windows/`, `frontend/macos/` — new platform scaffolding (Runner project files,
  standard `flutter create` output, untouched beyond that).
- `frontend/.metadata` — now tracks all five platforms.
- `frontend/README.md` — was Flutter's default boilerplate (never customized); replaced with a
  real per-platform setup guide (prerequisites, run command, known caveats per platform,
  including the #266 Chrome failure and the Developer Mode requirement).
- `docs/handoff_log/manual-launch-frontend-for-demo-snapshot.md` — walkthrough for generating a
  demo snapshot locally (written earlier this session, kept as-is).
- This file.

**Not changed:** root `CLAUDE.md`'s "Targets Android/iOS + Web" line. Windows/macOS are
documented in `frontend/README.md` explicitly as local dev conveniences, not shipped targets —
if the project ever wants desktop as a real target, that's a separate decision for the project
owner, not implied by these docs existing.

## Follow-up if picked up later

- macOS platform folder is untested from this session (added from Windows; nobody has actually
  run `flutter run -d macos` against it yet).
- #266 (web DB boot failure without `dedicatedWorkersInSharedWorkers`) is unaffected by anything
  here — still open, still LomerAlloys, still blocking #241 (PWA precache).
