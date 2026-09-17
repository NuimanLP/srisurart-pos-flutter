# Handoff: Web DB asset/version skew (Ticket #245)

**Date:** 2026-09-16 · **Issue:** #245 · **Follow-up filed:** #266

## 1. What was actually wrong

`frontend/pubspec.lock` resolves `sqlite3` to `3.4.0` and `drift` to `2.34.1`. The committed
`frontend/web/sqlite3.wasm` and `frontend/web/drift_worker.js` were **byte-identical** to the
`3.3.3` / `2.34.0` release assets — confirmed by downloading both release assets from
`github.com/simolus3/sqlite3.dart/releases/tag/sqlite3-3.3.3` and
`github.com/simolus3/drift/releases/tag/drift-2.34.0` and comparing sha256:

| File | Committed sha256 | Matches |
|---|---|---|
| `sqlite3.wasm` | `cfab48c6...58304d3` | `sqlite3-3.3.3` release asset, exactly |
| `drift_worker.js` | `b8b9f88c...9976a7a8` | `drift-2.34.0` release asset, exactly |

This is a real skew, not a cosmetic one. The two packages' changelogs show real content changed
between the locked and the committed versions:
- **sqlite3 3.3.3 → 3.4.0:** bumped the bundled SQLite core to 3.53.3, added
  `VirtualFileSystemFileV1` (`xFileControl`/`xSectorSize` VFS hooks), enabled
  `SQLITE_ENABLE_BATCH_ATOMIC_WRITE`, restructured the IndexedDB filesystem code, and now resets
  statements after `execute`/`select`. The 3.4.0 release's `sqlite3.wasm` asset is 748,424 bytes
  vs 747,018 for 3.3.3 — a different binary, not a relabeled one.
- **drift 2.34.0 → 2.34.1:** fixed reads queued in a `MultiExecutor` connection pool being
  resumed in the wrong zone once an executor became available, which could cancel or misroute a
  query in the wrong `Zone` — a real bug fix inside the compiled worker bundle itself. The
  2.34.1 release's `drift_worker.js` is 349,292 bytes vs 351,218 for 2.34.0.

## 2. Fix

- Replaced `frontend/web/sqlite3.wasm` and `frontend/web/drift_worker.js` with the exact assets
  from `github.com/simolus3/sqlite3.dart/releases/tag/sqlite3-3.4.0` and
  `github.com/simolus3/drift/releases/tag/drift-2.34.1` — sha256-verified against those release
  downloads (`41cf9689...af84143` and `7d4c84af...11ee5739f` respectively), so the committed
  files are provably the same bytes GitHub serves for those tags, not a rebuild or a guess.
- Added `frontend/web/WEB_DB_ASSET_VERSIONS.txt`, a small tracked marker recording which
  `sqlite3`/`drift` pub versions the committed assets match. It is the source CI reads.
- Added a step to `.github/workflows/flutter.yml`'s `analyze-and-test` job (right after
  `flutter pub get`) that reads the locked `sqlite3`/`drift` versions out of `pubspec.lock` and
  fails the build if they diverge from `WEB_DB_ASSET_VERSIONS.txt`. It parses the version from
  inside each package's own `  <name>:` block (stopping at the next top-level key) rather than a
  fixed line count, so it doesn't silently read the wrong package's version if a field is ever
  added or reordered.
- Updated CLAUDE.md's "Web DB" paragraph to state the true versions and point at this file.

## 3. Verification

From `frontend/`:
- `flutter pub get` — clean; `pubspec.lock` unchanged (sqlite3 stayed at 3.4.0, nothing new was
  pulled in by this change).
- `dart analyze` — `No issues found!`
- `flutter test` — all 344 tests passed.
- `flutter build web --no-tree-shake-icons` — succeeded; `build/web/sqlite3.wasm` and
  `build/web/drift_worker.js` are byte-identical (sha256) to the two assets committed in `web/`,
  confirming the build copies them through unmodified.
- The new CI check was sanity-tested standalone (both the match and mismatch branches) against
  the real `pubspec.lock` before being trusted in the workflow.

**Booted the actual build in a real Chrome tab** (claude-in-chrome, serving `build/web` locally,
tested both with and without `Cross-Origin-Opener-Policy`/`Cross-Origin-Embedder-Policy`
headers). This is the AC's "boot `flutter run -d chrome` once" step, done via a served build
instead since a real `flutter run` GUI session isn't available in this environment:
- With a **mismatched** pair (old 3.3.3 wasm served against the new-3.4.0-compiled
  `main.dart.js`, or vice versa) the app hangs on the loading spinner indefinitely — never
  throws, never loads. This is the actual symptom the skew causes, and it reproduces.
- With the **correctly matched** new pair (3.4.0/2.34.1, sha256-verified as in §2), the hang is
  gone — WebAssembly instantiation of `sqlite3.wasm` no longer fails on a version mismatch.

## 4. A separate, pre-existing bug found during boot verification — filed as #266

With the matched pair, the app still doesn't render the product list. The console shows:

```
Using WasmStorageImplementation.opfsLocks due to missing browser features: {MissingBrowserFeature.dedicatedWorkersInSharedWorkers}
LinkError: WebAssembly.instantiate(): Import #10 "dart" "xFileControl": function import requires a callable
```

This reproduces **identically with the old (3.3.3/2.34.0) self-matched pair too** — tested by
swapping just the served asset files back, without rebuilding `main.dart.js` first, then
confirming with a hard reload on a fresh port/tab that it's not a caching artifact. Same error,
same import name, in both storage fallback modes (`sharedIndexedDb` without COOP/COEP headers,
`opfsLocks` with them). That rules out #245's asset skew as the cause: a version-matched pair
still hits it, and pubspec.yaml's dependency constraints were not touched by this fix.

The likely mechanism: sqlite3 3.4.0 added the `xFileControl` VFS hook (`VirtualFileSystemFileV1`
in the sqlite3.dart changelog); drift 2.34.1's fallback storage implementations — used whenever
the browser is missing `dedicatedWorkersInSharedWorkers`, which is what selects
`sharedIndexedDb`/`opfsLocks` over full OPFS — don't appear to wire up a callable for it. Drift's
own changelog fixes OPFS locking shortly after, in 2.34.3 ("Use navigator locks around OPFS
access to avoid file locking issues"), which may or may not be the same bug.

Not fixed here: bumping `drift` past 2.34.1 is a materially bigger change than this ticket asked
for (new committed worker asset, full test re-run against different transitive deps, and #245's
AC only asked to match what's *already* locked, not to change the lock). Filed as **#266**,
which also flags that `dedicatedWorkersInSharedWorkers` may be missing on real Chrome/Edge
installs too, not just this sandboxed browser, since it's a long-standing nested-worker gap — so
**#241 (PWA precache manifest) should wait on #266, not just #245.**

## 5. What was not verified

No access to a real desktop Chrome/Edge with full OPFS (`dedicatedWorkersInSharedWorkers`)
support in this environment — every boot test fell back to `sharedIndexedDb` or `opfsLocks`.
Whether the full-OPFS path is also affected by #266's LinkError, or is clean, is unknown and is
exactly what #266 asks the next person to check.
