# Handoff: Reorganize root directory into `frontend/`, `server/`, and `docs/`

**Date:** 2026-09-07
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch `main`
**Previous handoff:** [`merge-p1-p2-lane-assignments.md`](merge-p1-p2-lane-assignments.md)

## 1. Context & Motivation

Before this change, the repo was structured with the Flutter client residing directly in the root folder alongside `server/` (the NestJS backend added in commit `c47c74e` / PR #41), plus several loose documentation and report folders (`PDF_Report/`, `PR/`, `handoff_log/`, `tutorial/`, `docs/`).

This created confusion during local development and builds:
- The Flutter toolchain ran at the repository root, making it unclear which files belonged to the client vs the server.
- Building frontend required running commands at root, while server required `cd server`.
- Root was cluttered with 12+ top-level directories.

The user requested: *"คุณทำ rootfolder ให้มี เเค่2folder fronend,กับ serverพอ เวลาbuildจะได้ง่ายๆ ไม่มั่ว"* (Make the root folder contain only frontend and server folders, so builds are simple and clean).

## 2. Directory Layout Changes

All moves were performed using `git mv` to preserve git commit history and blame tracking.

### A. Flutter Client moved to `frontend/`
- `lib/` → `frontend/lib/`
- `test/` → `frontend/test/`
- `web/` → `frontend/web/`
- `android/` → `frontend/android/`
- `ios/` → `frontend/ios/`
- `pubspec.yaml` → `frontend/pubspec.yaml`
- `pubspec.lock` → `frontend/pubspec.lock`
- `analysis_options.yaml` → `frontend/analysis_options.yaml`
- `.metadata` → `frontend/.metadata`
- `.fvmrc` → `frontend/.fvmrc`
- `.fvm/` → `frontend/.fvm/`

### B. Documentation consolidated into `docs/`
- `PDF_Report/` → `docs/PDF_Report/`
- `PR/` → `docs/PR/`
- `handoff_log/` → `docs/handoff_log/`
- `tutorial/` → `docs/tutorial/`
- Existing `docs/Backend_design/` and `docs/Summary_backend/` remain in `docs/`.

### C. Clean Root Structure
The root folder now contains only:
- `frontend/` (Flutter client)
- `server/` (NestJS backend)
- `docs/` (all documentation, logs, and tutorials)
- Root markdown specifications (`README.md`, `CLAUDE.md`, `CONTRACT.md`, `HANDOFF.md`, `SCRUTINY_REPORT.md`)
- Repository configurations (`.gitignore`, `.github/`, `.vscode/`, `settings.json`)

## 3. Tooling & CI Adjustments

1. **GitHub Actions (`.github/workflows/flutter.yml`)**:
   - Added `defaults.run.working-directory: frontend`.
   - Updated path filters to `paths: ['frontend/**', '.github/workflows/flutter.yml']` matching the symmetric pattern of `server.yml`.
   - Updated artifact upload path to `frontend/build/web`.
2. **VS Code (`.vscode/settings.json` and `settings.json`)**:
   - Added `"dart.projectSearchPaths": ["frontend"]` and `"dart.flutterSdkPath": "frontend/.fvm/flutter_sdk"` so Dart Code extension in VS Code detects the Flutter project in the subfolder.
3. **`.gitignore`**:
   - Updated patterns to use recursive wildcards (`**/build/`, `**/.dart_tool/`, `**/.fvm/`, `**/android/.gradle/`, `**/android/local.properties`) to cover `frontend/` and any nested paths.
4. **Markdown Cross-References**:
   - Updated references to `handoff_log/` → `docs/handoff_log/` in `README.md`, `CLAUDE.md`, `HANDOFF.md`, `docs/Backend_design/adr/README.md`, and `docs/Backend_design/05_HOW_WE_GOT_HERE.md`.

## 4. Verification

All gates verified locally before pushing:
- `frontend`: `dart analyze` — **No issues found** (0 warnings/errors).
- `frontend`: `flutter test` — **123/123 tests passed**.
- `frontend`: `flutter build web --no-tree-shake-icons` — **Built successfully**; verified presence of `sqlite3.wasm` and `drift_worker.js` in `frontend/build/web/`.
- `server`: `npm run typecheck` — **Clean**.
- `server`: `npm run test` — **3/3 tests passed**.
