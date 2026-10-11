# UI/UX audit B — POS checkout (2026-10-11)

Scope: `frontend/lib/presentation/screens/checkout_screen.dart`,
`widgets/receipt_view.dart`, `widgets/qr_payment_panel.dart`. Presentation only:
no change to what is saved, computed, validated, or to which repository /
`CartCubit` calls happen, or to how the bill id / Idempotency-Key /
`PendingWrites` are minted. File:line refers to `main` @ `2dabbcf`.

Users walked through: counter clerk on a 390 px phone (products and cart are
two tabs), a tablet / 1366–1920 px desktop with a mouse and a barcode scanner
(a keyboard that types the code + Enter), and the elderly owner at 2x–3x
whole-screen zoom and large text.

## Problems found → fix (priority order)

| # | Where (HEAD) | Problem for the user | Fix |
|---|---|---|---|
| P1 | `checkout_screen.dart:393` `_warn`, shown only at `:2469` (cart section) | On a phone the cart is the other tab. A card tap refused by stock (`สต็อกไม่พอ…`) shows its warning on the hidden tab: the clerk sees nothing happen. | The same warning box is also shown above the grid at phone width (height-capped and scrollable so it cannot push the grid off a zoomed screen). |
| P1 | `:1088` TabBar, `:1497` card `onTap` | Phone: no visible result of tapping a product — no count, no total, the cart is out of sight. | Count badge on the `ตะกร้า` tab; a navy bar under the grid with `N รายการ ฿total` and `ดูตะกร้า` (opens the cart tab). The bar is hidden on very short screens (3x zoom) where the grid needs the room — the badge stays. |
| P1 | `:1477` product card | Nothing on the card says it is already in the cart, at any width. | Orange `🛒 N` pill on the picture of every card already in the cart (clear of the star, the preview button and the price line). |
| P1 | `:1252` barcode field, `textInputAction: done` | Enter unfocuses the field, so with a barcode scanner the second scan types into nothing. | Two-pane: the field takes focus back on Enter (before a not-found dialog, which hands focus back on close) and again after the receipt closes. |
| P2 | `:2562` qty `-` / `+` | Typing a quantity of 12 means 11 taps on `+`; at qty 1 the `-` silently deletes the line. | Tap the number to type a quantity (dialog → the same `CartCubit.setQty`, so the stock check and "0 removes" are unchanged). At qty 1 the minus is a red bin icon. |
| P2 | `:3284` `_changeRow` | Short cash shows nothing until pay, then a modal `รับเงินไม่ครบ`. | Shows `ยังขาด ฿X` in red as soon as the typed cash is short; change shown bigger. The pay-time check and dialog are unchanged. |
| P2 | receipt dialog (`receipt_view.dart:72`) | After paying, the change to hand back is an 11 px line on the receipt; closing needs the mouse. | Green banner above the receipt: `เงินทอน ฿X` in 34 px (or `ขายสำเร็จ ฿total` when there is no change). `ปิด` is focused, so Enter closes it and the scan field is ready. 48 px buttons, theme colours. |
| P2 | `:1048` build | Desktop: no keyboard way to pay or get back to the scan field. | Two-pane only: F2 = scan field, F9 = the pay button (same handler and guards; it does nothing while a dialog is open). An `F9` key cap on the pay button. |
| P2 | `:1941` parked-bill ✕ | 14 px ✕ inside the resume chip: a near miss resumes the bill instead of deleting it. | 36 px target with tooltip `ลบบิลที่พัก`; the existing confirm dialog is unchanged. |
| P2 | `:3078` payment method buttons | Bare `GestureDetector`: no touch feedback, not reachable with Tab; 11 px labels. | `InkWell` (ripple, keyboard focus), 13 px labels with ellipsis. Same `setState` and account refresh. |
| P3 | `:2484` warning text `#FF8B7A`, `:3289` change green `#2ECC71` | Both are dark-theme colours: pale red / bright green on the light cream background are hard to read. | Light theme uses `AppColors.error` / `AppColors.success`; dark theme keeps the old colours. `_orange` / `_warnOrange` now alias `AppColors.orange` / `.warning` (same hex). |
| P3 | `:1525`, `:1838`, `:2921` | At 320 px with 1.3x text three rows overflowed (yellow stripes): the card's part-no/stock row, the section labels, and the grand total. | Stock label ellipsizes (part number 2:1), labels wrap (and lose `letterSpacing: 1`, which pulls Thai tone marks off their letters), grand total scales down — and is now 30 px. Pay button label scales down too. |
| P3 | `:2343`, `qr_payment_panel.dart:75`, `:238` | Small close targets (28 px customer/mechanic ✕, the QR fullscreen ✕ the clerk reaches over to); `ขยาย` looked like a link. | 36 px ✕; 32 px QR close on a light disc; `ขยาย` is a tonal filled button. |

Considered and **not** done: Enter in the cash field to pay (a tablet's on-screen
"done" key would pay by accident — F9 covers the keyboard case); a SnackBar on
every add (stacks up at counter speed; the badges do the job).

## For the shared-widget owner (not edited here)

- `widgets/low_stock_alert.dart` `LowStockBanner`: on a 390x844 phone with one
  low-stock product it pushes the product grid down to y ≈ 790 — the grid is
  almost hidden until it is dismissed. Consider a collapsed one-line form on
  phone width.
- `widgets/tap_target.dart` is good; a `tooltip` parameter would save the
  `Tooltip(child: TapTarget(...))` wrapping used here.

## New Thai strings (agent ร่าง — owner to ratify)

| String | Where |
|---|---|
| `ดูตะกร้า` | phone cart bar button |
| `N รายการ` (with the total) | phone cart bar |
| `ลบบิลที่พัก` | tooltip on the parked-bill ✕ |
| `แตะเพื่อพิมพ์จำนวน` | tooltip on the cart qty number |
| `จำนวน` | label in the qty dialog (its helper reuses `คงเหลือ N`) |
| `ยังขาด` | cash row when the cash typed is short |
| `ขายสำเร็จ` | receipt banner when there is no change |

No existing Thai string was changed. New test:
`frontend/test/checkout_ux_polish_test.dart`.
