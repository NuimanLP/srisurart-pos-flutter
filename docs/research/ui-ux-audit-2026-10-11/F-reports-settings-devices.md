# UI/UX audit F — Reports, Settings, Devices, Owner review (2026-10-11)

Scope: `reports_screen.dart`, `settings_screen.dart`, `devices_screen.dart`, `owner_review_screen.dart`,
`widgets/{payment_accounts_settings,change_password_form,device_enrolment_dialog,offline_pin_setup_dialog,password_changed_banner}.dart`.
User: the shop owner (often elderly, 2x–3x whole-screen zoom), on a 390 px phone, a tablet, or a 1366–1920 px PC.
Rule for every fix: presentation only — same reads/writes, same validation, same confirmations, no existing Thai string changed.
Line numbers are from `main` `2dabbcf`.

## Reports (`reports_screen.dart`)

| P | Where | Problem (why it hurts) | Fix |
|---|---|---|---|
| 1 | :174-193 | The `FutureBuilder` wraps the whole page, so every range tap blanks the screen to a spinner and the range bar disappears — feels like the app reset. | Range bar sits outside the `FutureBuilder`; only the body below it shows the spinner. Same `_loadData` calls. |
| 1 | :410-489 | On a phone the title and the four range pills share one row; the pills scroll sideways (`reverse: true`), so "วันนี้" can be off-screen with no hint. | Narrow: title on its own line, the four ranges as an equal-width segmented row that always fits. |
| 1 | :410 | Nothing says which dates the numbers cover ("7 วัน" — from when?). | A caption under the title with the actual period from `reportRangeBounds` (display only, numeric `dd/MM/yyyy` BE — needs no intl locale data). |
| 1 | :553-636 | The headline number (รายได้สุทธิ) is one of four equal tiles; on a phone FittedBox shrinks it. Owner wants that number first. | Narrow: รายได้สุทธิ is a full-width hero tile; bills / avg / items follow in a 3-column row. Wide layout unchanged (4 across). |
| 2 | :787, :860 | Cards are capped at 480 px with their own inner scroll — on a phone that is a scroll-inside-a-scroll trap (a finger on a card scrolls the card, not the page). | Narrow: no height cap, no inner scroll (lists are already bounded: top 8, recent 10, low stock 5). Wide keeps the equal-height columns. |
| 2 | :181-183 | Load error shows raw `เกิดข้อผิดพลาด: …` with no way out but leaving the page. | Same text plus a retry button (re-runs the same read). |
| 3 | :269 | 24 px padding on a 390 px phone wastes 12 % of the width. | 16 px when narrow. |
| 3 | :577-602 | KPI icon gradients are hard-coded one-off hex colours. | Brand tokens (`AppColors`). |

## Settings (`settings_screen.dart`)

| P | Where | Problem | Fix |
|---|---|---|---|
| 1 | :145-164 | Six tabs in a sideways-scrolling strip; on a phone only ~2½ show and nothing says more exist — backup/export are effectively hidden. | Narrow: tabs wrap onto two lines as large chips, all visible. Wide: unchanged strip. |
| 1 | :228-260 | No tab says what it is for; "บัญชี / ผูกเครื่อง" vs "จัดการเครื่อง" is confusing. | One short plain-language line under each pane title. |
| 1 | :320-401, :440-537, :542-567, :673-737 | Account tab: text + button share one `Row` (user card, this-device card, device-management link, offline PIN). At 390 px or zoomed the button squeezes the text to a sliver; the name+role `Row` can overflow. | A responsive action row: side by side when wide, button drops below the text when narrow. Name + role chip in a `Wrap`. |
| 1 | :1795-1812 | "กู้คืนข้อมูล" (replaces all shop data) looks exactly like the harmless "สำรองข้อมูล" tab. | Restore sub-tab gets the danger colour + icon so it reads as dangerous before it is opened. Existing confirm steps (confirm box + type-the-shop-name) unchanged. |
| 2 | :947-964, :1835-1841, :1880-1907 | When offline the save / download / pick-file controls are silently disabled — the owner does not know why. | Inline notice under them using the existing refusal strings (`settingsOfflineRefusal`, the two backup snack-bar strings). |
| 2 | :1998-2007 | Import-progress `Row` has a non-flexible `Text` → overflows on a phone. | `Flexible`. |
| 2 | :2543-2566 | Custom export range must be typed as `YYYY-MM-DD` — hard for an elderly owner. | Calendar button next to each field; it writes the same `yyyy-MM-dd` text into the same controller (filter logic untouched). Typing still works. |
| 2 | :2711-2779 | Export row: long description + download button side by side; on a phone the text column becomes very narrow. | Button drops below the text when narrow. |
| 3 | :237 | 28 px side padding on a phone. | 16 px when narrow. |
| 3 | :2133-2137 | Record grid is always 3 columns; at 390 px labels wrap mid-word. | 2 columns when the card is under 360 px. |
| 3 | :1886 | 📁 emoji on the pick-file card triggers the web fallback-font fetch (CLAUDE.md Phase 8a note) and the card has no visible "button" affordance. | Material icon + an outlined border; tap target unchanged. |

## Devices (`devices_screen.dart`)

| P | Where | Problem | Fix |
|---|---|---|---|
| 1 | :151-201 | Title + refresh + "ผูกเครื่องนี้" + "ออกรหัสผูกเครื่องใหม่" in one `Row` → overflows on any phone and at 2x zoom. | Title block on top, actions in a `Wrap` under it. |
| 1 | :456-571 | Device card: the red "ปลดเครื่อง" button sits beside the details and squeezes them; label + two chips in a `Row` can overflow. | Label and chips in a `Wrap`; the retire button moves to its own right-aligned line under the details. |
| 2 | :450-452 | `AppCard` (16 px padding) plus another 16 px `Padding`; cards touch each other with no gap. | Drop the inner padding, add a 12 px gap between cards. |
| 2 | :803-808, :907-913, :1082-1088 | Dialog titles are `Row`s with a non-flexible `Text` → overflow at phone width/zoom. | `Flexible` titles. |
| 2 | :944-959 | Copy-code action is a bare icon with a separate caption; elderly users tap the caption. | One labelled outlined button with the same caption + tooltip. |

## Owner review (`owner_review_screen.dart`)

| P | Where | Problem | Fix |
|---|---|---|---|
| 1 | :309, :661 | A list of cards with no word on what the owner is expected to do. | One short hint line above each list saying what the buttons do. |
| 2 | :377-389, :679-716 | Attempts/date `Row` (spaceBetween) and the review-item header can overflow at phone width/zoom. | `Wrap`. |
| 2 | :283-304, :627-651 | Empty states are a `Column` in a `Center` — overflow on a short zoomed screen. | Shared `EmptyState` (scrolls), same Thai text. |
| 2 | :188-193 | Discard-dialog title `Row` non-flexible. | `Flexible`. |
| 3 | :460-483, :756-767 | Action buttons are default (36 px) height. | 44 px minimum touch height. |
| — | | A count badge on the "รอตรวจ" tab would need the list state lifted out of the tab — a logic move, skipped. | Not done. |

## Found by the new phone-width tests (fixed)

- `settings_screen.dart` theme tab, font-size preview: `Text` + `Spacer` + price `Row` overflowed at 390 px → the name is `Expanded`.
- `devices_screen.dart` `_buildSectionHeader`: non-flexible section title overflowed at 390 px → `Flexible`.

## Tests

- New: `test/widgets/settings_phone_width_test.dart` (all six tabs visible at 390 px without a sideways scroll; general/theme/backup/restore/export + custom-range lay out without overflow; two calendar buttons present), and a 390 px case in `test/devices_screen_test.dart`.
- Changed (pure layout locator only): `reports_net_rule_test.dart` and `reports_kpi_phone_width_test.dart` found the KPI block as "the first `GridView`"; on narrow widths the hero tile now sits outside the 3-column grid, so both find it by `Key('reports-kpis')`. Every asserted value is unchanged.

## Widgets

- `device_enrolment_dialog.dart:86-93`, `offline_pin_setup_dialog.dart:170-179`: dialog title `Row` with a non-flexible `Text` → overflow on a phone. Fix: `Flexible`.
- `payment_accounts_settings.dart`, `change_password_form.dart`, `password_changed_banner.dart`: already `Wrap`-based / column layouts, owner-ratified 2026-10-07/10; no change needed.

## Shared-widget notes (not edited — owned by another agent)

- `AppCard` has no way to switch off its inner padding, which is why screens nest a second `Padding`.
- There is no shared "responsive action row" (text + trailing button that stacks on narrow); settings and devices each needed one.

## New Thai strings (agent ร่าง — owner to ratify)

| Where | String |
|---|---|
| reports, period caption (week) | `{date} – วันนี้` |
| reports, period caption (all) | `ทุกรายการที่บันทึกไว้` |
| settings, general tab | `ชื่อร้าน ที่อยู่ และค่าที่ใช้พิมพ์บนใบเสร็จและใบเสนอราคา` |
| settings, account tab | `ผู้ที่เข้าสู่ระบบ บทบาทของเครื่องนี้ และ PIN สำหรับขายตอนออฟไลน์` |
| settings, QR tab | `บัญชีที่ลูกค้าสแกนจ่ายเงินตอนคิดเงิน` |
| settings, theme tab | `สีพื้นหลัง ขนาดตัวอักษร และการขยายหน้าจอ` |
| settings, backup tab | `เก็บสำเนาข้อมูลร้านไว้เป็นไฟล์ หรือนำไฟล์สำรองกลับมาใช้` |
| settings, export tab | `ดาวน์โหลดยอดขายและสต็อกเป็นไฟล์ CSV เปิดใน Excel ได้` |
| settings, export date picker tooltip | `เลือกจากปฏิทิน` |
| reports, retry button | reuses existing `ลองใหม่อีกครั้ง` (devices screen) — not new |
| owner review, tab 1 hint | `รายการเหล่านี้ส่งเข้าระบบไม่สำเร็จ — กด "ส่งใหม่" เพื่อลองอีกครั้ง หรือ "ทิ้ง" พร้อมหมายเหตุ` |
| owner review, tab 2 hint | `ตรวจดูแต่ละรายการ แล้วกด "ตรวจแล้ว" เพื่อเอาออกจากรายการ` |
