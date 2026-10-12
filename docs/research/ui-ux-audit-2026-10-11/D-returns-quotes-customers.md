# UI/UX audit — group D: returns, quotes, customers (2026-10-11)

Scope: `returns_screen.dart`, `quotes_screen.dart`, `customers_screen.dart`,
`widgets/quote_a4_view.dart`. Presentation only — no change to what is saved,
computed, validated, or which repository calls happen.

Users: counter staff on a 390 px phone, tablet, and 1366–1920 desktop (touch + mouse);
an elderly owner on 2x–3x whole-screen zoom (1366x768 at 3x is a ~455x256 logical screen).

## Problems found, by priority (P1 = can cause a mistake or a broken screen)

### Returns (`returns_screen.dart`)

| # | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| R1 P1 | `_RefundDetail.build` ~1017–1118 | Header + `Expanded` item list + a fixed ~330 px summary box (totals, method, reason, buttons) in one non-scrolling `Column`. | On a phone in landscape, with the soft keyboard up (reason field), or under 2x–3x zoom the column runs out of height: the item list collapses to 0 px or the box overflows, so staff cannot see what they are refunding. | When the pane is shorter than 640 px, the whole pane scrolls as one list (items laid out inline). Tall panes keep the current pinned summary. |
| R2 P1 | `_SummaryBox` ~1498–1513 | A credit bill (`เครดิตช่าง`) defaults to `หักจากเครดิต`, but if staff tap `เงินสด` nothing says it is a problem until after the submit button. | The warning arrives at the last moment, inside a dialog. Staff learn to click through it. | Inline amber note under the method buttons while a credit bill has `เงินสด` selected. The existing confirm dialog stays as it is. |
| R3 P2 | `_SummaryBox` | The summary shows money only. It does not say that the stock goes back. | "What will happen" is only in the final confirm text. | One line above the button: how many pieces go back into stock. |
| R4 P2 | `_ItemRow` ~1156 | The returnable quantity shows only as `/ N` beside the stepper. | Staff miss it and type a larger number. The number is clamped silently, which is confusing. | An explicit `คืนได้อีก N` label in the item's info line. |
| R5 P2 | `_QtyStepper` ~1326 | Tapping the qty field leaves the cursor after `0`, so typing `2` gives `02`→2, or `12` when it was `1`. | Wrong quantity on touch. | Select all of the field's text when it is tapped or focused. |
| R6 P2 | `_SearchTab` ~617 | With no search, only the 50 newest bills are listed, and nothing says so. | Staff think an older bill "is missing". | A small line `แสดง N จาก M บิล — พิมพ์เพื่อค้นบิลที่เก่ากว่า` when the list is truncated. |
| R7 P3 | `_TabButton` ~567 | The tab is about 38 px tall, below the 44 px touch target. | Mis-taps on a phone. | `minHeight: 44`. |
| R8 P3 | detail header ~1057 | On a phone the detail replaces the list, but the way back is an `×`. | An `×` reads as "cancel the return", not "back to the list". | Back arrow below 900 px, `×` on wide. Same tooltip and same callback. |
| R9 P3 | `build` ~386 | A load error is a dead end: the text has no retry. | The only escape is to leave the screen. | A `ลองใหม่` button that re-runs the same load (`_refreshAll`). |
| R10 P3 | ~1069, ~1624 | `letterSpacing` on Thai labels (`เลือกรายการที่จะคืน`, `_FieldLabel`). | It detaches Thai tone marks (same issue as #479). | Remove it. |

### Quotes (`quotes_screen.dart`)

| # | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| Q1 P1 | `_QuoteRow` ~606–653 | The right column holds an unbounded `Wrap` of up to 5 buttons. Inside a `Row` it lays out on one line (~230 px) and starves the customer/number column. The buttons are ~28 px tall. | At 390 px or under zoom the quote number and customer get cut to a few characters, and the buttons are too small to hit. | Below 560 px: info and amount on top, actions on a full-width row below. All action buttons get a 40 px minimum height. |
| Q2 P2 | `_tag`/`_pill` ~660–686 | The status pill uses 10 px text. "Still valid" is a faint 25 % tint and looks the same whether 30 days or 1 day remain. | Status is not readable "at a glance", especially at zoom. | 12 px text with an icon per status. Validity of 3 days or less uses the warning tone (colour only, same label). |
| Q3 P2 | `_FilterBar` | The filter chips give no counts. | Staff tap each filter to find out whether anything is there. | Each chip shows its count next to the label (same predicates as the filter, ignoring search). |
| Q4 P3 | `_Header` | On a phone the title and two tool buttons share one row. | The title wraps awkwardly. | Below 480 px the tool buttons go under the title. |
| Q5 P3 | `build` ~336 | Load error with no retry. | Same as R9. | `ลองใหม่` → `_refresh`. |

### Customers (`customers_screen.dart`)

| # | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| C1 P1 | `build` ~152 | A search with no match shows `ยังไม่มีลูกค้า` ("no customers yet"). | It reads as if the data were lost. | When customers exist but the search matches none, show `ไม่พบลูกค้าที่ค้นหา`. |
| C2 P2 | `_CustomerEditorDialog` ~647–675 | Two fields per row even on a phone (~140 px each). The phone field gets a text keyboard. Enter does nothing. Nobody is told that one name is enough. | The fields are cramped, the keyboard is wrong, and staff fill both names because they are unsure. | Stack the fields below 520 px. Phone keypad for the phone field, Next between fields, Enter on the last field saves (same `_save`). A hint that one name is enough. |
| C3 P3 | card list ~447–461 | `แก้ไข`/`ลบ` are text-only buttons. | They are small and easy to miss on touch. | Add icons. Labels unchanged. |
| C4 P3 | ~274, 318, 371 | `letterSpacing` on Thai labels. | Same as R10. | Remove it. |
| C5 P3 | `build` ~134 | Load error with no retry. | Same as R9. | `ลองใหม่` → `_refresh`. |

### A4 quote (`quote_a4_view.dart`)

| # | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| A1 P1 | `buildPdf` ~113 | Single `pw.Page`: a quote longer than about 20 lines cannot fit one A4 page and the PDF layout fails. | Large quotes for a garage cannot be printed. | `pw.MultiPage` with the same widgets in the same order. The table rows flow onto the next page. Page 1 looks the same as before. |

### Found while verifying (a throwaway widget test at 390x800, 455x256, 640x360, 683x384 and 1366x768)
- R11 P1 — `_SummaryBox` total row and `_SummaryRow` overflowed horizontally at 390 px (two large
  texts in a `Row`). The label is now `Flexible` and the amount uses `FittedBox(scaleDown)`.
- R1 revised after review — the detail pane is now **one tree at every size**: a
  `SingleChildScrollView` holding `minHeight` plus `spaceBetween`. The summary sits at the bottom when
  everything fits and scrolls with the items when it does not. The first version switched tree shape
  at 600 dp, so a soft keyboard could flip the mode and drop focus from the reason/qty field. Trade-off:
  a bill with many lines on desktop no longer keeps the summary pinned while the items scroll.
- `คืนได้อีก N` stays hidden until the already-refunded qty has loaded, so the full qty never flashes.
  `คืนเข้าสต็อก N ชิ้น` sits only with the return (คืน) button, never above the whole-bill void, and
  never on a voided bill.
- Q6 P1 — at 455x256 (1366x768 at 3x) the quotes header and filters left a negative height for the
  list. Below 520 dp tall the page is a `CustomScrollView`, so the header and filters scroll away
  with the list. Taller screens keep them pinned.
- C6 P2 — on narrow widths the customers stat row (`Row(children: stats)`) overflowed with a large
  spend figure. It is now a `Wrap`.

## Not changed (needs a shared-widget owner or the product owner)
- `StatusChip` has no `dense`/icon variant. The quotes pill stays local to its screen.
- The credit-note print (`_printCreditNote`) is a thermal layout and is unchanged.
- The return confirm text is not changed (Thai strings are behaviour parity). A richer
  confirm sheet would need the owner's approval of new copy.

## New Thai strings (agent ร่าง — owner to ratify)
- `คืนได้อีก N` — returns, item row: how many units can still be returned.
- `คืนเข้าสต็อก N ชิ้น` — returns summary: what the return does to stock.
- `บิลเครดิต: คืนเป็นเงินสดจะไม่ลดยอดค้างของช่าง แนะนำ "หักจากเครดิต"` — returns, inline warning.
- `แสดง N จาก M บิล — พิมพ์เพื่อค้นบิลที่เก่ากว่า` — returns search, truncated list.
- `ไม่พบลูกค้าที่ค้นหา` — customers, search with no match.
- `กรอกชื่อไทยหรืออังกฤษอย่างน้อย 1 ช่อง` — customer editor hint.
- (reused, not new: `ลองใหม่` from `owner_review_screen.dart`.)
