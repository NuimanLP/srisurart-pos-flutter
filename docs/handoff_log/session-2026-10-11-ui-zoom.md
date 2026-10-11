# Handoff — whole-screen zoom for elderly users: `main` = `bf02582` deployed to `mob04` + APK (2026-10-11)

**Date:** 2026-10-11 · **Status:** deployed (`.current_sha` checked over SSH) · no server change, no migration
**Follows:** [`session-2026-10-10-product-images.md`](session-2026-10-10-product-images.md)
**How verified:** SHA/PR/run ids from `gh`; VM side checked over `ssh mob04`. **Not yet hand-tested in a real browser** (Thai IME under zoom) — only widget/smoke tests.

## 1. Summary
- Owner request (2026-10-11, Thai): a version elderly people can read, about 2-3x, after looking at Settings → ธีม → Font Size (presets 0.85-1.25x).
- PR #686 (`develop`, squash) = `1a2cd93` — 5 commits: feature, code-review (two-axis), Opus `/scrutinize`, Sonnet docs pass, Opus fixes.
- PR #687 (`develop` → `main`, merge commit) = **`bf02582`**.
- Flutter tests **1805** pass, `dart analyze` clean, CI green.

## 2. Decision: whole-screen zoom, not a text-only scale
Text scale past 1.25x overflows fixed-height cards (the sell-screen product cards are 288 px). So the whole UI is scaled instead.
- `UiZoomCubit` + cap rule: `frontend/lib/presentation/blocs/ui_zoom_cubit.dart`. Pref key `sa_pos_ui_zoom`; levels 1 / 1.5 / 2 / 2.5 / 3; the cap keeps the logical screen at least 360x320; `readStored()` runs before `runApp` and never throws.
- `UiZoom` widget: `frontend/lib/presentation/widgets/ui_zoom.dart` — MediaQuery size divided by zoom + `FittedBox`; the same widget tree at every zoom level (no remount on change). Installed in `MaterialApp.builder`.
- Settings card `_UiZoomSection` greys out levels above the cap and shows `จอนี้ขยายได้สูงสุด N เท่า`.

## 3. Layout fixes found by zoomed smoke tests
- Customers top bar is single-row only from `AppBreakpoints.customersTopBarRow` = 900 dp (was 600). **Visible change for unzoomed 600-900 dp widths** — it overflowed on a 768 dp portrait tablet.
- Products toolbar scrolls when it would leave the list under 160 px.
- `EmptyState` scrolls.
- Route smoke test now runs every screen at 3x on 1920x1080, and 2x and 3x on 1366x768.

## 4. Deploy
- Run `38100697523` approved on the owner's instruction; `deploy to demo` success. The earlier twin run `38100675075` skipped (images not on GHCR yet — normal).
- On `mob04`: `/opt/pos/.current_sha` = `bf0258286fe5c0efc29d2249a10b2aadb419f28e`, `/health/ready` 200, api-1/2/3 healthy, served bundle `main.bf0258286fe5.dart.js` contains `sa_pos_ui_zoom`.
- APK: `android-apk.yml` run `38100596895` success → prerelease `apk-bf02582`.

## 5. Known limits
- Phone at 390 dp caps at about 1.08x — only the font size (up to 1.25x) helps there.
- 1366x768 laptop browser caps at about 2x (2.4x full-screen with F11); Full HD about 3x.
- The cap ignores the on-screen keyboard: a landscape-tablet form dialog at the cap may overflow while typing.
- Not hand-tested in a real browser (Thai IME under zoom). Owner should try Settings → ธีม → ขยายทั้งหน้าจอ on the shop PC. Chrome's own Ctrl + "+" remains an alternative on the PC.

## 6. New Thai strings — `agent ร่าง`, awaiting owner ratification
- `ขยายทั้งหน้าจอ · Zoom`
- `ขยายทุกอย่างบนจอ ทั้งตัวอักษร ปุ่ม และรูป ให้ผู้สูงอายุอ่านง่าย`
- `ปกติ`
- `1.5 เท่า` … `3 เท่า`
- `จอนี้ขยายได้สูงสุด N เท่า`

## 7. Still open (carried over from the 2026-10-10 handoff)
- Thai strings from the product-images release (its §6) are still `agent ร่าง`, awaiting owner ratification.
- `restore-db.sh` does not restore `pos_images_*.tar.gz`; all backups still live on the one VM (#363 parked).
- Image editor resolves the URL once per open; a session from before AppMeta `tenant_id` needs a fresh login to see images (fix = take tenant id from the token — owner decides).
- No client-request fixture for the byte `PUT`; replaying an old `PUT` after a newer image may return the old key (next pull fixes it).
- Product list cache may lack `imageKey` for up to 5 minutes after a deploy.
- Nobody has uploaded a real image through the app or imported a real ZIP on `mob04` yet.
- Raspberry Pi 5 move is a plan only (`docs/research/pi5-migration-plan.md`, 11 open questions in its §7) — owner undecided.
- Leftover worktree folders on disk that could not be deleted ("Directory not empty"): `agent-a05cc7211d87708d7`, `pi-combine`, `agent-a5c18f90cf27c2e6e`, plus ~60 older `agent-*` folders.
- Bank API / slip verification questions from an earlier handoff remain open.

---

# Release 2 — create-PO supplier search (PR #690/#691)

**Status:** deployed run green, **VM not verified** · no schema/server change · `main` = **`2dabbcf`**

## 8. Owner report and cause
- Owner report 2026-10-11 (Thai): searching a supplier name in สั่งซื้อ → สร้างใบสั่งซื้อ shows nothing; asked to improve the dialog's UX.
- Cause: `_CreatePoDialog` in `frontend/lib/presentation/screens/purchase_orders_screen.dart` used a plain text field — no search at all.

## 9. Change (dialog only; `PoInput`/`savePO` unchanged)
- Supplier suggestions from past PO suppliers (newest first) + `Suppliers` table names, case/space-insensitive dedupe. Works for Thai and English names ('จิ้น' finds 'จิ้นเซ่งฮวดอะไหล่ยนต์'). The owner's Suppliers data holds Thai names, past POs English ones — no cross-language matching. Free text still allowed.
- The picked supplier's products show as one-tap add with that supplier's lowest `unitCost` (freight not included, as before). Changing supplier re-prices lines whose cost the user did not edit.
- Enter adds the exact partNo match first. Product rows show stock + a `สต็อกต่ำ` flag.
- Add-low-stock button: known supplier only, its products only, qty `max(1, minStock − stock)`.
- Disabled-save hint; Cancel/Save row wraps at 390 px; suppliers load lazily when the dialog opens, with a double-tap guard.
- Process: Opus agent implemented, Opus `/scrutinize` (ship-with-fixes) → fixes applied. Flutter tests 1813 pass, `dart analyze` clean, CI green.

## 10. Release and deploy
- PR #690 (squash into `develop`) = `09820ab`; release PR #691 (`develop` → `main`, merge commit) = **`2dabbcf`**.
- Deploy run `38103562796` approved on the owner's instruction; `deploy to demo` success (twin run `38103468772` skipped — normal).
- 🔴 **NOT verified on the VM:** SSH and HTTPS to 172.30.58.20 timed out right after (owner's VPN likely off). Check `ssh mob04 cat /opt/pos/.current_sha` = `2dabbcf55e896705a600301608e1cad2901b99c6` before claiming it deployed (a green Deploy run is not evidence).
- APK: `android-apk.yml` run `38103153683` success → prerelease `apk-2dabbcf`.

## 11. Known gap
- At 360 px logical width (possible under whole-screen zoom) the PO list's top stat bar overflows ~13 px (pre-existing; list screen not touched).

## 12. New Thai strings — `agent ร่าง`, awaiting owner ratification
- `ไม่พบซัพพลายเออร์นี้ — จะบันทึกเป็นซัพพลายเออร์ใหม่`
- `สินค้าของซัพพลายเออร์นี้`
- `เพิ่มสินค้าสต็อกต่ำ (N รายการ)`
- `เลือกซัพพลายเออร์และเพิ่มสินค้าอย่างน้อย 1 รายการ`

## 13. Owner Q&A this session
- **Barcode:** only one kind exists — Code128 of `partNo`, printed on shelf labels (`label_printer.dart`). A scan matches `partNo` exactly, case-insensitive (`checkout_screen.dart` `_handleBarcode`; server `lower(part_no)`). A factory EAN works only if `partNo` equals it. A separate barcode column would need Drift v16 + a server migration — not started, owner has not decided.
- **VPN:** a deploy needs no VPN (the runner on `mob04` pulls from GitHub). Using the app at https://172.30.58.20 and verifying over SSH needs the VPN/faculty network.
