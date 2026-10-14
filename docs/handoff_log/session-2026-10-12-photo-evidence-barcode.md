# Session 2026-10-12 — sale photo evidence + camera barcode scan

**Released:** `main` `c3e33aa` (PR #699, merge commit) = PR #697 (camera barcode scan, squash `35a79cc`) + PR #698
(sale photo evidence, squash `4c992a2`). Deployed to `mob04` by `Deploy (demo)` run `38260777086` (approved
2026-10-12; the twin run `38260594779` skipped as usual — images not ready — and held no slot).

## Owner requests (2026-10-12)
1. Photo evidence that the goods were new / unscratched when the customer took them, taken around payment.
2. A camera button to scan a barcode when searching stock.

## Owner decisions
| Topic | Decision |
|---|---|
| When | Optional, **after** payment (receipt button); payment never blocked |
| Storage | Server, tied to the sale |
| Viewing | Returns screen + sales history (Reports bill sheet) — **same device only** in v1 (sales are not pulled) |
| Offline | **Cut from v1** — online-only; retry inside the open sheet |
| Replace-import | Photos **survive** (no FK to `sales`, not in `REPLACED_TABLES`) |
| Defaults | All roles view · nobody deletes · no auto-delete · no adding later · not in backup ZIP · 1600 px · Thai copy `agent ร่าง` |
| Barcode screens | Products, checkout, PO (create dialog; receiving has no search) |
| Shop PC web scan | **Bundle the zxing decoder locally** (no CDN) |

## How it was built
Design doc `docs/Backend_design/10_SALE_PHOTO_EVIDENCE.md` (Opus) → `/scrutinize` (verdict: go-with-changes; found the
same-device viewing limit and that the offline queue was ~60 % of client work) → owner decisions → doc revised with a
binding §4 API contract and split server/client tickets → server (Opus) and client (Sonnet) built in parallel against §4
→ `/code-review` (standards + spec) on each, fixes applied → integration branch with the barcode PR → full local tests →
browser-pane check of the built web app.

## Evidence
- Integration branch (both features): `dart analyze` clean, `flutter test` **1928** pass; server lint/typecheck clean,
  `pnpm test` **806** pass; e2e `sale-photos`/`schema`/`owner-import`/`product-images`/`idempotency`/`sales` **133** pass.
  Full e2e suite green in CI on #698 and on `main`.
- Browser pane (Windows Chromium = no `BarcodeDetector`, like the shop PC): bundled zxing module initialised from local
  files, no jsdelivr/unpkg request; camera blocked → the scanner dialog shows a camera-off state, no crash.
- `mob04` after deploy: `.current_sha` = `c3e33aa…`, `/health/ready` 200, all containers up (api ×3 healthy), migration
  `SalePhotos1788652805200` applied (`sale_photos` exists; 32 base tables incl. `migrations` = 31 app tables), volume
  `srisurart-pos_sale-photos` present, worker `/app/sale-photos` owned by `node`. Disk 31 GB free (estimate ~3 GB/yr).
- `backup-db.sh` installed by hand as `cloud`: sha256 `e70debda134476c5b835ca367d4e264be62f4e11904630bf00959c0bcc61c524`
  = `c3e33aa`; previous copy `/opt/pos/scripts/.backup-db.sh.prev-ec31121`. One run in cron's env (as `deploy`): rc=0,
  `pos_backup_*.sql.gz` + `pos_images_*.tar.gz` + `pos_sale_photos_20261012_141241Z.tar.gz` (empty — no photos yet),
  `sha256sum -c` OK, no `.partial`, offsite `::warning::` as expected (#363 parked).

## Not verified / open
- No real camera scan or photo on a phone, tablet or the shop PC against `mob04` (X1 trial in the design doc).
- Android release build with `image_picker` not built locally (the `android-apk.yml` workflow is manual).
- Owner: ratify the `agent ร่าง` strings (scanner dialog, photo sheet/viewer, `SALE_PHOTO_LIMIT`, iOS camera text);
  decide the PDPA customer notice.
- `restore-db.sh` restores neither product images nor sale photos.
- Follow-ups: cap the `withImageSlot` queue; shared settle/cleanup module for product images + sale photos; offline photo
  queue; cross-device viewing (server bill lookup); scan-to-verify on PO receiving; a barcode column if EANs differ from
  part numbers.

## Cleanup
Merged branches deleted (remote + local): `feat/camera-barcode-scan` (tip = #697 head), `feat/sale-photos` (tip = #698
head, tree identical to `4c992a2`), `feat/sale-photos-server`, `feat/sale-photos-client`, `docs/sale-photo-evidence-design`
(ancestors of #698 head), local `integration/photos-barcode` (tree identical to develop) and five `worktree-agent-*`
branches. One empty folder `.claude/worktrees/agent-a1904c27f7723a6e9/frontend` is held open by a running process — delete
it after a restart.
