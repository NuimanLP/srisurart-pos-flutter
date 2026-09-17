# Manual: launching the frontend locally to generate a demo snapshot (#185 rehearsal)

**Purpose:** run the Flutter POS app on your own machine, put some data through it, and export
a `pos-backup-*.json` snapshot — the same file format the shop will eventually send, used here
to rehearse the #185 import pipeline before the real shop file exists.

**Repo path used below:** `D:\Beestation\Sri_POS\Flutter\frontend` (ASCII path — `build_runner`
and `dart analyze` work here too, see the root `CLAUDE.md` "build path constraint" section for
why that matters on this project).

---

## 1. Pick a target — **use Windows desktop, not Chrome**

🔴 **`flutter run -d chrome` is currently broken on this machine** (and matches known bug
**#266**, already filed and open):

```
RethrownDartError: LinkError: WebAssembly.instantiate(): Import #10 "dart" "xFileControl":
function import requires a callable
Using WasmStorageImplementation.sharedIndexedDb due to missing browser features:
{MissingBrowserFeature.dedicatedWorkersInSharedWorkers, MissingBrowserFeature.sharedArrayBuffers}
```

This is the exact failure `CLAUDE.md` documents under *"Web DB (#266, open)"*: even with the
web-DB assets correctly matched to `pubspec.lock`, the app's web build never boots in a browser
missing `dedicatedWorkersInSharedWorkers`. It is not something to fix as a side effect of this
task — it blocks #241 (PWA precache) and is owned by `LomerAlloys`.

**Use the Windows desktop target instead** — it uses native SQLite via `drift_flutter`, not the
WASM/web-worker path, so it isn't affected.

Check available targets first:
```bash
flutter devices
```
Expect to see something like:
```
Windows (desktop) • windows • windows-x64    • Microsoft Windows [...]
Chrome (web)       • chrome  • web-javascript • Google Chrome [...]
Edge (web)         • edge    • web-javascript • Microsoft Edge [...]
```

## 2. Install dependencies (once)

```bash
cd frontend
flutter pub get
```

## 2b. Add the Windows platform target (once, local-only)

This project's committed target list is Android/iOS + Web (`CLAUDE.md`) — there is no
`windows/` folder in the repo. Add it locally for this rehearsal only; it's additive (new files
under `frontend/windows/`) and never gets committed unless you explicitly `git add` it:

```bash
cd frontend
flutter create --platforms=windows .
```

🔴 **This needs Windows Developer Mode enabled** (Flutter's plugin build uses symlinks). If you
see:
```
Building with plugins requires symlink support.
Please enable Developer Mode in your system settings.
```
run, in an ordinary terminal (not this agent's shell):
```
start ms-settings:developers
```
and turn on **Developer Mode** in the Settings window that opens. This is a one-time machine
setting.

## 3. Launch on Windows desktop

```bash
flutter run -d windows
```

- First build is slow (native compile) — a few minutes is normal.
- This opens a **native desktop window**, not a browser tab.
- Keep this process running the whole time you're using the app — closing the terminal / stopping
  the process closes the app.
- Hot-reload keys while it's running in an interactive terminal: `r` (hot reload), `R` (hot
  restart), `q` (quit).

If you started it in the background (e.g. via an agent), stop it the same way you'd stop any
background task, and relaunch in the foreground if you want the interactive `r`/`R`/`q` keys.

## 4. Put some data through the app

The app seeds a bit of data on first run (`AppDatabase.open()` seed data in
`frontend/lib/data/db/database.dart`), but for a meaningful export rehearsal, go through a few
real flows first:
- ขายของ 2-3 บิล (Checkout)
- เพิ่มลูกค้า / ช่าง
- เปิดกะ (Cash Drawer → เปิดกะ)
- รับของเข้าคลังสัก 1 PO

This exercises the tables the #185 checklist actually checks (sales, customers/mechanics,
shifts/drawer entries, movements).

## 5. Export the snapshot

In the running app:

**ตั้งค่า (Settings) → แท็บ สำรอง/กู้คืน → ดาวน์โหลดไฟล์ backup**

This calls `SnapshotRepository.exportSnapshot()`
(`frontend/lib/data/repositories/snapshot_repository.dart`), wired to the UI in
`frontend/lib/presentation/screens/settings_screen.dart:1144-1160`. It downloads
`pos-backup-YYYYMMDD.json` — the `sa_*` + `__meta` shape `POST /platform/tenants/{id}/import`
expects, unmodified.

## 6. What this file is (and isn't) good for

- ✅ Rehearsing the whole #185 import pipeline end-to-end: create a demo tenant, `POST
  .../import`, poll the job, run the 6-check comparison — see
  `docs/handoff_log/` for the fuller #185 walkthrough (server setup, platform-admin creation,
  the import calls).
- ❌ **Not a substitute for the real shop file.** #185's AC requires *"a real
  `DB.exportSnapshot()` … from the shop"* — self-generated demo data has none of the messiness
  (negative stock, duplicate doc numbers, orphaned references) that the pre-flight checks and
  tombstoning logic exist for. Run the pipeline against both: this file to rehearse, the shop's
  real file to actually close #185.
- Demo data generated this way is **not** shop data — no PDPA handling required for it, but
  treat it as any other repo output: don't invent fake customer PII, keep sample names generic.

---

## Quick reference

| Step | Command |
|---|---|
| List targets | `flutter devices` |
| Install deps | `flutter pub get` (from `frontend/`) |
| Run (desktop, working) | `flutter run -d windows` |
| Run (web, currently broken — #266) | ~~`flutter run -d chrome`~~ |
| Export snapshot | in-app: Settings → สำรอง/กู้คืน → ดาวน์โหลดไฟล์ backup |
