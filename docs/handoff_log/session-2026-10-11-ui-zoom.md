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
