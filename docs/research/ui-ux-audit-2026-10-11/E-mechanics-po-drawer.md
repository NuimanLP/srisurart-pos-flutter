# UI/UX audit E — mechanics, purchase orders, cash drawer, closing report

2026-10-11 · group E of the six-agent polish pass. Presentation only: no change to what is saved,
computed, validated or which repository calls happen. Expected drawer cash is still read only from
`ShiftsRepository.drawerCash`; the close button is disabled under exactly the same three conditions.

Users checked against: counter staff on a 390 px phone, a tablet, and the shop PC (1366–1920 px);
the elderly owner at 2x–3x whole-screen zoom (a 1366x768 screen at 3x is a ~455x256 logical screen).

Line numbers are from `origin/main` `2dabbcf` before this change.

## Cash drawer — `frontend/lib/presentation/screens/cash_drawer_screen.dart`

| Pri | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| P1 | 939–957 | `🔒 ยืนยันปิดลิ้นชัก` is greyed out with no reason (no count typed / offline / outbox not empty). | Staff at closing time see a dead button and do not know what to do; with an unsent outbox they cannot know they must wait. | One line **under** the button names the first blocking reason (same three conditions, same order of checks). Under the button, so the button's position never moves (the #567 rule the stable-button test guards). |
| P1 | 894–938 | The variance box shows colour + sign, but not what it means. | `เงินขาด −฿100` is clear to the owner, less so to a new cashier; "count again" is the action. | A short line under the variance: counted less / more than expected / matches. Inside the space already reserved, so nothing below moves. |
| P2 | 875–892 | The count field does not say whether the starting cash is included. | The commonest counting mistake is to leave the float out, which shows a false shortfall of exactly the starting cash. | Helper text under the field label. |
| P2 | 600–641 | Amount (130 px) + note + `+ เพิ่ม` in one row. | At 390 px the note field is ~110 px wide; at zoom it is unusable. | Below 480 px: amount + button on one row, note full-width under it. |
| P2 | 1055–1080 | Quick-amount chips are ~26 px tall. | Below the 44 px touch minimum — misses on a phone, worse with gloves. | Min height 40 px, larger text. |
| P2 | 1021, 1025 | Entry-type toggle uses one-off colours `0xFFE57373` / `0xFF81C784`. | Off-palette and low contrast on the light theme. | `AppColors.error` / `AppColors.successLight`, plus a check icon on the active choice so it does not rely on colour alone. |
| P3 | 471, 1095 | `letterSpacing` on Thai tab labels and section titles. | Spacing detaches Thai tone marks (the #479 lesson); it is also harder to read at zoom. | Removed on Thai text. |

## Mechanics — `frontend/lib/presentation/screens/mechanics_screen.dart`

| Pri | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| P1 | 706–836 | Each row is 7 columns (code, name, shop, phone, sales, balance, limit) + 2 icons, at every width. | At 390 px each column is ~15 px: names wrap letter by letter, the balance — the number that matters — is unreadable. | Below 640 px a two-line row: name (+nickname) and code · shop · phone on the left; balance with a limit bar on the right. |
| P1 | 282 | The wide list has no column headings. | Two money columns (`ยอดซื้อ`, `ยอดค้าง`) side by side, unlabelled — easy to read the wrong one as the debt. | A heading row above the list on wide layouts. |
| P1 | 1845–1849 | Quick chips read `+฿100`, `+฿500`… but **replace** the amount. | "+" says "add 100"; a cashier tapping +500 then +100 expects 600 and records 100. A money mistake. | Label `฿100` (via `baht()`), same action. |
| P1 | 1804–1823 | Typing more than the balance shows `ยอดค้างหลังรับชำระ ฿0` in green; the warning only comes at submit. | Green "0" says "all good" while the cashier is about to over-collect. | A red line under it: `รับเกินยอดค้าง ฿x` (display only — the confirm on submit is unchanged). |
| P2 | 1065–1072 | Credit card shows the limit, not what is left of it. | "Can he take another ฿3,000 on credit?" needs mental arithmetic. | `ใช้ได้อีก ฿x` (or `เกินวงเงิน ฿x`) next to the limit. |
| P2 | 36–39 | Hard-coded colours; `_green` `0x2ECC71` is off-palette and ~2:1 on the light surface. | Payment amounts (`−฿500`) were hard to read. | Map to `AppColors` (`warning`, `error`, `orange` are the same hex; green → `successLight`). |
| P2 | 1050, 1135, 1210, 1863, 2020 | 11–12 px labels with `letterSpacing` on Thai. | Small and tone marks drift; the owner reads these at 2x–3x. | 12–13 px, no letter spacing on Thai. |
| P3 | 1924 | Pay-dialog chips `minimumSize: Size.zero`. | Tiny touch targets. | Min height 40 px. |
| P2 | 1775–1822 | Pay dialog's balance rows: neither the label nor the amount can shrink. | At 390 px the `ยอดค้างหลังรับชำระ` row overflowed (found by the new phone test). | Label `Flexible`, amount scale-down. Same for the detail panel's three stat boxes. |

## Purchase orders — `frontend/lib/presentation/screens/purchase_orders_screen.dart`

| Pri | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| P1 | 432–475 | A PO card shows only "n รายการ" and the total. `รับสินค้า` receives the whole PO in one press. | The person receiving the delivery cannot check what was ordered (names, quantities) against the boxes before pressing receive. | An expandable `ดูรายการสินค้า` list on each card: name, part no., qty × cost. Collapsed by default. |
| P2 | 422–428 | Every card looks the same whatever its status; the status chip is small, top-right. | Scanning a list for "what is still waiting" is slow. | A coloured left edge by status (waiting = warning, received = success, cancelled = muted). |
| P2 | 1077–1083 | Remove (✕) on a draft line has no tooltip/label. | Screen readers and mouse users get no hint; ✕ next to a price can read as "clear field". | Tooltip `นำออกจากใบสั่งซื้อ`. |
| P3 | 391 | `letterSpacing` on Thai stat labels. | As above. | Removed. |

Not changed (behaviour): receiving is all-or-nothing in `receivePO` — per-line receive quantities
would need a repository/API change. Recorded here for the owner, not built.

## Closing report — `frontend/lib/presentation/widgets/closing_report.dart`

| Pri | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| P1 | 746 | The variance box appears as soon as the field is non-empty; a lone `.` reads as ฿0 and shows a false `เงินขาด`. | Same bug the cash-drawer screen already fixed (`hasPhys`). | Show it only once the text parses as a number. The printed figure is unchanged. |
| P2 | 915–938 | Payment rows: label not flexible. | Overflows at 3x zoom / narrow dialogs. | Label in `Expanded`. |
| P2 | 717–735 | Expected-cash amount unconstrained. | Long amounts overflow at zoom. | `Flexible` + scale-down. |
| P2 | 682 | With no shift open, the drawer section shows "ควรมี ฿0" with no explanation. | Looks like the drawer is empty / money is missing. | One line: no shift open, nothing to count. |
| P2 | 987–1013 | Drawer breakdown rows in `bodySmall`. | The one section the cashier must check line by line is the smallest text. | `bodyMedium`. |
| P3 | 1054 | `letterSpacing` on Thai section titles. | As above. | Removed. |

Noted, not changed: the report's count field has no `moneyInputFormatters` (the drawer screen's
does), and `diff` is not `round2`-ed before the ✓/เกิน/ขาด choice. Both change what is accepted or
computed, so they are out of scope for a presentation pass.

## Verification

`frontend/test/mechanics_po_drawer_ux_test.dart` (new) pumps the three screens at 390x844 (and the
mechanics list at 1600x900) and checks each cue plus no overflow. Existing tests were not changed.

## Shared widgets (owned by another agent — suggestions only)

- `AppButton` has no way to show a reason for being disabled; a `disabledHint` would let every
  screen do what the drawer now does by hand.
- `AppTextFieldLite` in `mechanics_screen.dart` exists because `AppTextField` has no
  `helperText`/`textStyle`; adding them would let it go.

## New Thai strings (owner-ratified 2026-10-12 — see 02_API_SCREENS.md §8.1.1)

| String | Where |
|---|---|
| `กรอกยอดเงินที่นับได้ก่อน จึงจะปิดลิ้นชักได้` | drawer, under close button |
| `ระบบออฟไลน์อยู่ — เชื่อมต่ออินเทอร์เน็ตก่อนจึงจะปิดลิ้นชักได้` | drawer, under close button |
| `มีรายการรอส่งเข้าระบบ {n} รายการ — รอให้ส่งครบก่อนปิดลิ้นชัก` | drawer, under close button |
| `นับเงินทั้งหมดในลิ้นชัก รวมเงินตั้งต้นด้วย` | drawer close tab + closing report, under the count label |
| `นับได้น้อยกว่ายอดที่ควรมี — ลองนับใหม่อีกครั้ง` | drawer variance (short) |
| `นับได้มากกว่ายอดที่ควรมี` | drawer variance (over) |
| `เงินในลิ้นชักตรงกับยอดที่ควรมี` | drawer variance (match) |
| `ใช้ได้อีก {฿}` / `เกินวงเงิน {฿}` | mechanic credit card |
| `รับเกินยอดค้าง {฿}` | pay-credit dialog |
| `รหัส` · `ชื่อช่าง` · `อู่ / ร้าน` · `เบอร์โทร` · `ยอดซื้อ` · `ยอดค้าง` · `วงเงิน` | mechanics list headings |
| `ดูรายการสินค้า` | PO card |
| `นำออกจากใบสั่งซื้อ` | PO draft line tooltip |
| `ยังไม่ได้เปิดกะ — ไม่มีเงินในลิ้นชักให้ตรวจนับ` | closing report |
