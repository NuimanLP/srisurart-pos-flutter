# Feature rules

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: product images, sale photo evidence, camera barcode scan, supplier-first tab, PO print, VAT report, owner backup import.

**Client-side Flutter (feature rules):**
- **PO print (owner request 2026-10-22, PR #747):** `พิมพ์` (outlined `Icons.print`) on **open + received** PO cards only (cancelled = no button, agent default, owner informed) -> A4 PDF via the same `PdfPreview` print/share bar as the A4 quote; widget `presentation/widgets/purchase_order_a4.dart` (owned by `purchase_orders_screen.dart`). 🔴 Owner decisions: **no prices/costs/line totals/grand total anywhere** (PDF, preview, file name `poNo.pdf`, PDF metadata) and **no internal PO status / received / cancelled date on the paper** — the sheet goes to the supplier's sales rep; never add cost, total or status to it (`_total()` prints counts only: `รวม N รายการ · M ชิ้น`). Guards: `frontend/test/purchase_order_a4_pdf_test.dart` reads real PDF text with distinctive costs and fails on any cost/total in any format (keep it reading real text, never a mocked widget tree) + a source tripwire against `.cost`/money helpers; `frontend/test/purchase_order_print_button_test.dart` (open+received only, busy guard, 390 px + 3x zoom). `_printing` guard = double tap, one preview; lines sorted by rowId in the print path only. Local read, same on Drift/API builds, works offline. New Thai strings `agent ร่าง` (`02 §8.1.1`). Not verified: real print/share on a device or the shop PC browser. Follow-up: header/brand colours duplicated with `quote_a4_view.dart`.
- **VAT: tax id/branch + sales-tax report (owner approved 2026-10-23, `feat/vat-sales-report`; spec
  `docs/research/thai-vat-abbreviated-invoice-2026-10-23.md`):** Settings → ทั่วไป edits `taxId` (13 digits, no check digit —
  the doc gives none) and `branchNo` (5 digits, agent assumption) via `core/utils/tax_identity.dart`, validated before the
  existing `updateSettings` path. Settings → ส่งออก CSV → รายงานภาษีขาย (`widgets/sales_tax_report_section.dart`, figures in
  `domain/reports/sales_tax_report.dart`): one line per day **per RC series** (`RCnn` prefix = one POS machine) + one
  negative line per credit note by its own date. A "first–last" range is printed only for sequential `RCnn-YYYY-MM-nnnn`
  numbers; the Drift build's `docNo('RC')` (epoch digits + hex, wraps every ~27.8 h) shows first / last **by time** with the
  remark `เลขไม่ต่อเนื่อง`. Voids read **as of the month's end** (`toReportLites(asOf:)` rule): a manual void inside the month is
  out (named in the remark), one made after the month ended still counts there so a filed month never changes — and it
  shows in no later month (open accountant question, not built); auto-void stays with its CN. Rate = today's setting for
  every month (no history; note on screen + CSV). Integer satang, VAT rounded **per line** (agent pick, `[ยังไม่ยืนยัน]` O5);
  CSV negatives `csvMoney` → `(107.00)` because `csvSafe` escapes a leading `-`. An untouched legacy tax id/branch is not
  validated or sent, so it never blocks saving other fields. 🔴 Never print
  "ใบกำกับภาษีอย่างย่อ" or change the receipt until the owner confirms ภ.พ.06 (doc O1). Thai strings `agent ร่าง` (`02 §8.1.1`).
- **Product images (owner request 2026-10-10, PR #680; 02 §3.2/§3.10, 07 §9):** one picture per product, **owner-only**
  (`403 OWNER_ONLY`) and online-only (`PUT`/`DELETE /products/:id/image`, raw jpeg/png/webp ≤ 3 MB, idempotent over the body
  bytes). `products.image_key` is **content-addressed** — first 32 hex of the sha256 of the stored preview — so a new image is
  a new immutable URL; sharp writes `<tenantId>/<key>_t.webp` (256) and `_p.webp` (1024) to the `product-images` volume,
  nginx serves them read-only at `/img/` (public, `immutable`, no login: the UUID + 128-bit key is the secret).
  🔴 Removing an old key's files is **after commit, best-effort, never inside the transaction**, and only when no product of
  that tenant still references the key **and the files are older than `ORPHAN_GRACE_MS` (10 min)** — a concurrent upload of
  the same bytes may be about to commit them (`image-store.ts`; only a refused upload deletes its own just-created files at
  once; the import sweep also skips files newer than the job). Decode is capped at 24 MP (`INPUT_PIXEL_LIMIT`, api 384 MB /
  worker 256 MB) with `failOn: 'error'`; Node `requestTimeout` = `IMPORT_REQUEST_TIMEOUT_MS` (15 min) so a slow 200 MB import
  is not cut at the 300 s default. Drift v15 deletes the `products` sync cursor so upgraded clients re-pull existing keys.
  🔴 **`mob04` is a `QEMU Virtual CPU version 2.5+` (= `qemu64`: no SSSE3/SSE4/POPCNT, below x86-64-v2)** — never ship a
  prebuilt native binary that assumes v2. `server/Dockerfile` builds **libvips 8.18.7** (sha256-pinned tarball, only
  jpeg/png/webp/exif/lcms/zlib) and compiles sharp against it, and deletes every prebuilt `@img/sharp-*`; `server.yml`
  `build-image` runs `server/docker/sharp-check/check.cjs` under `qemu-x86_64 -cpu qemu64` before Trivy/push (PR #682,
  after `ac9d4dd` rolled back on 2026-10-10). Trivy does not track the self-built libvips — bump it by hand for CVEs
  (sharp's `src/common.h` sets the minimum libvips). 🔴 **Image bytes never go into Drift or `audit_log`** — Drift keeps `Products.imageKey` only. 🔴 **Android loads
  images through the same private-CA trust as `ApiClient`** (`installPosTrust` / `HttpOverrides`) — never a
  `badCertificateCallback`. Owner backup is now a **ZIP** (`data.json` + `images/<key>.webp`; import takes `.zip` ≤ 200 MB or
  legacy `.json` ≤ 10 MB, the nginx limit is raised only on the two import locations; ZIP entries are whitelisted and capped).
  🔴 **`backup-db.sh` also archives the volume as `pos_images_<ts>.tar.gz`, but a CD deploy does not update
  `/opt/pos/scripts`** — install it by hand (`sudo install -o deploy -g deploy -m 0755`) or via `provision.yml`, else backups
  silently omit images; **`restore-db.sh` does not restore images yet**. Never `down -v` (the images are not in `pg_dump`).
- **Sale photo evidence (owner request 2026-10-12, PR #698; design + API contract `docs/Backend_design/10_SALE_PHOTO_EVIDENCE.md`
  §4, which binds both sides — change §4 first, in its own PR):** optional, **after payment** (receipt button
  `ถ่ายรูปหลักฐานสินค้า`), ≤ 5 photos per bill, **online-only v1** (photos live in memory while the sheet is open; a failed
  upload keeps the sheet open and `ลองอีกครั้ง` resends the **same photoId + `Idempotency-Key`**; the button is disabled
  while Degraded or while the bill's `sale.create` is still in `outbox_ops`). Viewing is **same-device only** (Returns /
  Reports read sales from Drift; no server bill lookup). `sale_photos` (migration `1788652805200`, Postgres 31 tables) is
  **append-only** for `pos_app` (no DELETE route), has **no FK to `sales`** and is **not in `REPLACED_TABLES`**, so a replace-
  import keeps the photos; the import's file sweep stays bound to `productImages`. 🔴 Sale photos are **not** public like
  product images: separate volume `sale-photos` mounted on api + worker only (**never nginx** — `nginx-img.test.sh` proves
  `/img/` 404s), read through `GET /sales/:id/photos/:photoId/{t|p}` with `Cache-Control: no-store`; the file path comes only
  from the token's tenant + the stored `image_key`. The PUT always answers **200**; replay is by key **and** permanently by
  `photoId` + `source_sha256`; the 5-limit is counted under the `sales` row `FOR UPDATE`. The raw body is buffered only for
  `drole === 'pos'` tokens. The query (`takenAt`/`sortOrder`) is deliberately outside the fingerprint — so the client freezes a
  photo's `sortOrder` at its **first send attempt** (the lowest slot 0–4 not held by a saved/retryable/uploading photo — never
  max+1, which reached 5 and was refused) and resends it on every retry; staff may reorder tiles only before the first
  `บันทึก` (owner 2026-10-12). Capture = in-app camera (`camera` package, `sale_photo_camera.dart`, all platforms incl. the PC
  webcam; `image_picker` removed; the camera counts only shots the sheet accepted) + `file_picker`. 🔴 The Android manifest
  strips `RECORD_AUDIO`/`WRITE_EXTERNAL_STORAGE` that `camera_android_camerax` merges in (`tools:node="remove"`) — keep it. `withImageSlot` serialises sharp per process (product images and sale photos share it; since #753 at most 4 uploads
  wait — the 5th gets 503 `IMAGE_BUSY` + `Retry-After`, the backup import is never refused); sale photos cap input at 2048² and preview at 1600 px. 🔴 `backup-db.sh` writes
  `pos_sale_photos_<ts>.tar.gz` **through the worker container** (a failed exec = `::error::` + non-zero exit) — install it on
  the VM only **after** the deploy that ships a worker with `/app/sale-photos`; installed on `mob04` 2026-10-12 (sha256
  `e70debda…`, previous copy `.backup-db.sh.prev-ec31121`). Not in the owner backup ZIP; `restore-db.sh` does not restore
  them. Open owner items: PDPA customer notice, the `agent ร่าง` strings, the X1 real-device trial.
- **Camera barcode scan (owner request 2026-10-12, PR #697):** one shared `BarcodeScanButton` (`mobile_scanner` 7.4.2) on
  products search, the checkout scan field (goes through `_submitBarcode` → `_handleBarcode`, the same path as typing / a USB
  scanner) and the create-PO search (adds a line only on an exact part number). Matches `partNo` only — there is no barcode
  column; PO receiving has no search, so no button. 🔴 **Web never fetches a decoder from a CDN:** native `BarcodeDetector`
  where present, else **zxing-wasm 3.1.3 bundled in `frontend/web/zxing/`** (`VERSION.txt` holds npm integrity + sha256;
  precached by `sw.js`) — Windows desktop Chrome/Edge have no `BarcodeDetector`, so the bundle is what makes the shop PC
  work. Bumping `mobile_scanner` = re-check the zxing version it pins and update the bundle. Support is checked **before**
  any camera permission prompt. The iOS `NSCameraUsageDescription` is one key shared with sale photos
  (`ใช้กล้องเพื่อสแกนบาร์โค้ดและถ่ายรูปหลักฐานสินค้า`, `agent ร่าง`).
- **Supplier-first tab (owner request 2026-10-12, PR #703; plan + as-built `docs/research/supplier-first-plan-2026-10-12.md`):**
  Products → `ซัพพลายเออร์` opens on `ตามซัพฯ` (supplier list → that supplier's products); the old per-product view stays behind
  `ตามสินค้า`. Code lives in `products_suppliers_tab.part.dart` (a `part` of `products_screen.dart`). A "supplier" is the group
  of `Suppliers` quote rows by `supplierKey()` (`core/utils/supplier_name.dart`, trim + lower-case) — the **same key** the
  create-PO dialog uses; no supplier entity, no schema change (rename/merge and contact details are "later"). Cheapest =
  integer-satang `cost + freight`, compared only against **other** suppliers. 🔴 **One stock rule: `stockLevel()`**
  (`low_stock_alert.dart`; out = `stock <= 0`, low = `stock <= minStock`) — the Stock tab, `lowStockBuckets` and the PO
  dialog's low-stock list all use it; never inline `stock <= minStock` in new code. `สร้างใบสั่งซื้อ (n)` passes a `PoPrefill`
  **class** via go_router `extra` (never a String/Map — it would be serialised into history and reopen on back). Writes keep
  the API-build rules (Degraded refused at press, `_busy`, no local write, dialog keeps values on error, add body byte-stable
  for `PendingWrites`). Owner question open: supplier routes have no role check (any role can edit costs).

## Owner backup import (from the phase-1 "Still open" log)

- **Owner backup import (2026-10-08, PR #664/#665, `847e7ef`, deployed; `docs/handoff_log/session-2026-10-08-owner-import.md`).**
  The shop owner imports a backup from Settings → สำรอง/กู้คืน → กู้คืนข้อมูล: `POST /backup/import`
  (+ `GET /backup/import/:jobId`), role `owner` + enrolled device, same `TenantImportService` as the platform
  import (ADR-0005 amendment 5). `?mode=replace&confirmShopName=` replaces the whole shop's data in one
  REPEATABLE READ tx; users/devices/audit_log/tenants/idempotency_keys/`doc_counters` stay.
  🔴 **Every import (platform + owner) must raise `doc_counters` from the imported RC/CN/PO/QT/CP numbers**
  (`GREATEST`; legacy-random numbers skipped; a `device_no` the tenant lacks is skipped and reported as
  `docCounterSkippedDevices`) — without it the first new sale collides (`409 RECEIPT_NO_CONFLICT`).
  🔴 The pre-import copy (`/app/exports/<tenant>/pre-import/<jobId>.json`, `exports` volume) is **never
  auto-deleted** (PDPA — retention is the owner's call) and lives only on the VM disk (outside `/opt/pos/backups`, so the PC backup pull, #363, does not copy it).
  Known limits: other devices keep stale rows after a replace (clear site data); shifts, drawer entries,
  movements, suppliers, credit-payment history and parked bills in the file are not pulled into the app.
  The real import on `mob04` has not been run yet; the Thai strings and amendment 5 are `agent ร่าง`, unratified.
