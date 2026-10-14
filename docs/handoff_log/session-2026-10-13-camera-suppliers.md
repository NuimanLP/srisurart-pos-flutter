# Session 2026-10-12/13 — sale-photo built-in camera + reorder, supplier-first tab

**Released:** `main` `8a44a03` (PR #704, merge commit) = PR #702 (squash `849c47d`) + PR #703 (squash `ddd66a4`).
Deployed to `mob04` by `Deploy (demo)` run `38275228902` (approved overnight under the owner's standing approval; the twin
`38275009338` skipped as usual). Client only — no migration, no ops change, `backup-db.sh` unchanged.

## Owner requests (2026-10-12, late evening)
1. Screenshot of the photo sheet on the shop PC: `เพิ่มรูป` and `เลือกรูป` did the same thing and there was no way to take a
   photo on the web → "a built-in camera option, plus an add-photo option".
2. "Make the photos arrangeable."
3. Screenshot of Products → `ซัพพลายเออร์`: "the supplier should be the main thing first, not the product — make it look
   good, good experience".

## What shipped
- **#702** — sheet has two actions: `ถ่ายรูป` (in-app camera, `camera` 0.12.1; webcam on web via `camera_web`, no CDN) and
  `เลือกรูปจากเครื่อง`. Multi-shot until 5; errors shown in the view (HTTPS, no camera, denied, busy). Reorder by long-press drag
  or ◀ ▶; `sortOrder` = lowest free slot 0–4 at first send, locked after `บันทึก`. `image_picker` removed; Android manifest strips
  `RECORD_AUDIO`/`WRITE_EXTERNAL_STORAGE` (merged manifest checked with `processDebugMainManifest`).
- **#703** — Suppliers tab supplier-first (list → detail; push + back below 840 px), cheapest/dearer per product, edit cost /
  add / delete (confirm; warns when the last product removes the supplier), existing-name helper, `สร้างใบสั่งซื้อ (n)` prefilling
  the create-PO dialog. One shared `stockLevel()` rule (negative stock = out). Old view behind `ตามสินค้า`.

## Process
#702: build (Opus) → `/code-review` (found `sortOrder` could reach 5 and be refused; mic permission merged into the APK; a
stuck processing tile; the camera counter drifting) → fixed → PR. #703: plan (Opus) → `/scrutinize` (cut the last-PO-date read
that re-synced all POs; breakpoint 840 for 3x/1920; one stock rule; shared name key; `extra` class prefill) → build →
`/code-review` (negative stock shown "In Stock"; delete without confirm; duplicate-quote "cheaper than itself") → fixed → PR.

## Evidence
- #702: `dart analyze` clean, `flutter test` 1963; #703 after merging develop: 1988. CI green on both PRs and on `main`.
- `mob04`: `.current_sha` = `8a44a031…`, `/health/ready` 200, api ×3 healthy, served `main.8a44a031f039.dart.js`,
  `/zxing/zxing_reader.wasm` 200, latest migration still `SalePhotos1788652805200`.

## Not verified / open (owner)
- Real camera: shop PC webcam over HTTPS on `mob04`, Android/iOS preview/rotation/permission prompts, 1080p quality.
- APK build: `flutter build apk --debug` failed locally on a Kotlin incremental-cache error in `android_file_picker` (unrelated);
  the manifest merge itself passed. Next `android-apk.yml` run will show.
- Supplier writes against the live server were not exercised by eye (tests only).
- Ratify `agent ร่าง` strings: `10_SALE_PHOTO_EVIDENCE.md` §2.7 and `supplier-first-plan-2026-10-12.md` §6.
- Owner question: supplier routes have no role check (any role can edit costs).
- Later: supplier rename/merge, supplier contact details (schema), `withImageSlot` queue cap.
