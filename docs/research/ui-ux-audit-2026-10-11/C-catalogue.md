# UI/UX audit — Group C: catalogue (2026-10-11)

Scope: `products_screen.dart` (Stock / Price Calc / Suppliers / Reports tabs + add/edit,
adjust-stock and bulk-delete dialogs), `vehicle_search_screen.dart`, `label_printer.dart`,
`product_image.dart`, `product_image_editor.dart`. Presentation only: no change to what is
saved, computed, validated, or which repository calls happen. Line numbers are from
`origin/main` `2dabbcf` (before this change).

Users: counter staff on a phone (390 px) or tablet, the owner on a 1366–1920 px PC, often at
2x–3x whole-screen zoom. Jobs: find a part fast, read stock and price at a glance, edit a
product without mistakes, adjust stock, print shelf labels.

## Findings and fixes (priority order)

| # | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| P1 | `products_screen.dart:752-832` | Stock list is a 9-column `DataTable` on every width; at 390 px only partNo + half a name are visible, stock/price/actions sit behind a sideways scroll. | Staff on a phone cannot see stock or reach ปรับสต็อก/แก้ไข without scrolling sideways on every row. | Below `AppBreakpoints.compact` (600) the list becomes one card per product: partNo, name, TH name, big coloured stock + ขั้นต่ำ, category, status pill, cost, big price, and the same four actions. Selection mode shows a checkbox and the card toggles on tap. Table unchanged at ≥ 600. |
| P1 | `products_screen.dart:964-1037`, `788-798` | On a 1280–1366 px screen the row actions (ปรับสต็อก/แก้ไข/print/delete) are past the right edge of the table. | The two most used actions need a sideways scroll on the owner's laptop. | Tighter `horizontalMargin`/`columnSpacing`, the name cell wraps at 240 px, and below 1500 px of table width the ปรับสต็อก/แก้ไข buttons become icon buttons (same icons, label as tooltip). Labelled buttons stay on wide screens. |
| P1 | `products_screen.dart:1600-1613`, `1791-1819` | Add/edit validation is only a SnackBar (`กรุณากรอกรหัสสินค้า` / `กรุณากรอกชื่อสินค้า`); nothing marks the field, nothing says which fields are required, and "EN or TH name" is a rule nobody can see. | Elderly owner misses the toast, does not know which box is wrong. | After the first บันทึก the missing field shows an error under itself (same checks, toast kept). รหัสสินค้า gets a red `*`; the EN/TH name pair is marked once by a full-width line "* กรอกชื่อ EN หรือ TH อย่างน้อยหนึ่งช่อง" above both (turns red, both borders red, when neither is filled); `ใช้กับรถรุ่น` gets an example (the vehicle search reads it). |
| P1 | `products_screen.dart:1677-1789` | Add/edit dialog is one scroll: title and บันทึก/ยกเลิก scroll away with the form (long form + price box). | At zoom/phone the user must scroll to the bottom to save, and loses the title. | Title row and action row are fixed; only the form scrolls. Section titles ข้อมูลสินค้า / จำนวนในคลัง group the fields. Buttons 48 px tall; บันทึก gets a check icon. Narrower inset on a phone. |
| P1 | `products_screen.dart:2084-2278` | Adjust stock: typing a signed number on a phone keypad is fiddly; บันทึก is enabled with nothing typed (no-op); a cut below 0 silently clamps; the dialog can overflow under zoom. | Most common stock action; mistakes are invisible until the list reloads. | ±1/±5/±10 step buttons write the same signed text (`+5`, `-3`); delta field autofocused on tablet/PC only (on a phone the keyboard would cover the steps); preview shows `เดิม → ใหม่`; a warning when the cut exceeds stock ("ลดได้มากสุด N ชิ้น — สต็อกจะเหลือ 0"); บันทึก disabled until a whole number is typed (`_save` returned early anyway); body scrolls. |
| P2 | `products_screen.dart:601-628` | Search box is a fixed 260 px with no clear (✕) button. | On a phone it is a small box; clearing needs select-all + delete. | Full width on a phone, 300 px otherwise, ✕ button (tooltip ล้างคำค้น), search keyboard action. |
| P2 | `products_screen.dart:575-593`, `697-743` | Status chips, category chips and search all filter, but nothing says a filter is on or how many items are hidden; empty state is a bare "ไม่พบสินค้า". | "Where did my products go?" — the counter thinks stock is missing. | When any filter is on: "แสดง N จาก M รายการ" + a ล้างตัวกรอง button that resets search, category and status. Empty state adds an icon and a hint when filtered. |
| P2 | `products_screen.dart:1046-1126`, `548-554` | In selection mode the bulk bar wraps to ~3 rows on a phone and, with the taller toolbar, pushed the column 23 px past the screen. | Overflow stripe / hidden list on a phone. | Toolbar takes ≤ 55 % and the bulk bar ≤ 45 % of the room while selecting; both scroll when they need more. |
| P2 | `products_screen.dart:137-165` | "ค้นหาตามรุ่นรถ" button with a long label shares the row with the scrollable tab strip. | On a phone the tabs get ~200 px. | Icon-only button (tooltip ค้นหาตามรุ่นรถ) below 600 px; the dialog inset shrinks to 8 px on a phone. |
| P2 | `products_screen.dart:2381-2468` | Price Calc tab: Cost/Freight, Retail/Garage inputs and the two result cards are always side by side; the 42 px price wraps in a half-width card at 390 px. | Unreadable, cramped money boxes on a phone. | Pairs stack vertically below 600 px; page padding 16 on a phone; big price scales down instead of wrapping. |
| P2 | `products_screen.dart:2807-2892` | Suppliers tab: fixed 260 px product list beside the detail — at 390 px the detail is ~130 px wide; with no product selected the detail is blank. | Supplier table unusable on a phone. | Below 600 px the product list sits above the detail (38 % height, at least 120 px or half a very short screen) and its title scrolls with the list, so nothing fixed can overflow at 3x zoom (tested at 3x/1920x1080, 2x and 3x/1366x768, 390 px). Blank detail now says "เลือกสินค้าเพื่อดูและเพิ่มซัพพลายเออร์". Add-supplier title can wrap. |
| P2 | `products_screen.dart:3305-3330`, `3835-3862` | Reports tab: four sub-tab buttons in a plain `Row` (overflows ~390 px); KPI values at 28 px wrap digit-by-line in a third of a phone row; active sub-tab only differs by text colour. | Overflow + unreadable KPI numbers. | Sub-tabs scroll sideways, active one gets a tinted background, 44 px tall; KPI / payment values scale down to fit (FittedBox); padding 16 on a phone. |
| P2 | `vehicle_search_screen.dart:334, 569` | Result count and the compat highlight use `RichText` without a `textScaler`, so they ignore the app's text-size setting. | Exactly the elderly users who raised the text size cannot read the compat line. | Pass `MediaQuery.textScalerOf(context)` (structure kept for the #478 test). |
| P2 | `vehicle_search_screen.dart:100-102` | 📋 คัดลอกรหัส gives no feedback. | User taps again, not sure it worked. | SnackBar "คัดลอกรหัส X แล้ว" (2 s). |
| P3 | `vehicle_search_screen.dart:419-428, 446-466, 497-514` | partNo 11 px grey monospace, stock label 11 px, brand 12 px grey; `letterSpacing: 1.2` on Thai "รุ่นยอดนิยม:" (the #479 tone-mark lesson). | Too small for the owner; partNo is the thing they copy. | partNo 13 px bold orange (same as the stock list), stock label 13, brand/category 13/12, chip text 14; letterSpacing removed; search keyboard action + ✕ tooltip. |
| P2 | `label_printer.dart:349-375` | Footer `Row` (total text + ยกเลิก + พิมพ์ป้ายราคา) squeezes the total to a sliver at 390 px. | The "N สินค้า × M ชุด = K ป้าย" check is unreadable. | Footer is a `Wrap`: total on its own line on a phone, bold. |
| P2 | `label_printer.dart:414-477` | Product picker has no search; the stock tab passes every product. | Finding one product among hundreds means scrolling. | Search box over the list (filters what is shown only; selection, เลือกทั้งหมด and printing unchanged). While a search is on, the quick chips say they still act on every product: "เลือกทั้งหมด (ทั้งหมด N)", "⚠ สต็อกต่ำ (ทั้งหมด N)". Stacked phone layout gives the picker 3/5 of the height. |
| P3 | `label_printer.dart:312-315, 483-503` | Close ✕ has no tooltip; "−" copies button is live at 1 (does nothing). | Unclear affordances. | Tooltips (ปิด, ลด/เพิ่มจำนวนชุด); "−" greyed at 1; partNo 12 px. |
| P3 | `product_image_editor.dart:205-226` | The picture is saved by its own call, but the dialog's ยกเลิก looks like it would undo it. | Owner presses ยกเลิก expecting the photo change to be dropped. | One line under the buttons: "เปลี่ยนรูปแล้วบันทึกทันที ไม่ต้องกด "บันทึก"" (only when the owner can act). |
| P3 | `products_screen.dart:940-963` | Stock status is a dot + coloured text. | Hard to scan down a long table. | Same label in a tinted pill (shared by table and cards). |

`product_image.dart` needed no change.

## Not done (would change behaviour, or outside my files) — for the owner / other agents

- Stock-list thumbnails: `ProductImage` needs `getImageUrls()` — a new repository call on the
  list; not added (rule: no new calls).
- บันทึก in add/edit has no in-flight guard: a double tap on a new product sends `add` twice
  (the second gets the duplicate-part-no toast). A busy flag would change which calls happen.
- Status labels `Out of Stock / Low Stock / In Stock` are English-only on a Thai-first screen;
  changing them changes existing strings (owner call).
- `label_printer.dart` preview hint "เลือกสินค้าด้านซ้ายเพื่อดูตัวอย่าง" says *left*, but on a phone
  the picker is *above* — existing string, left as is.
- The stock tab's search does `p.nameTH.contains(q)` with a lower-cased `q` (data logic, left as is).
- Shared kit: `SearchField` (widgets/search_field.dart) has no tooltip on its ✕ and no way to
  style it like the stock tab's filled search — I kept the screen's own TextField.

## New Thai strings (owner-ratified 2026-10-12 — see 02_API_SCREENS.md §8.1.1)

| String | Where |
|---|---|
| `ล้างคำค้นหา` (tooltip; unified 2026-10-12) | stock search ✕, vehicle search ✕ |
| `เลือกสินค้าที่แสดงอยู่ไว้ให้ (N รายการ)` (tooltip) | stock tab พิมพ์ป้าย button |
| `แสดง N จาก M รายการ` | stock tab, while a filter is on |
| `ล้างตัวกรอง` | stock tab, while a filter is on |
| `ลองค้นด้วยคำอื่น หรือกด "ล้างตัวกรอง"` | stock tab empty state when filtered |
| `ขั้นต่ำ N` | phone product card |
| `ทุน ฿X` | phone product card |
| `ข้อมูลสินค้า` / `จำนวนในคลัง` | add/edit section titles |
| `* กรอกชื่อไทยหรืออังกฤษอย่างน้อย 1 ช่อง` (unified 2026-10-12) | add/edit label over the EN/TH name pair |
| `จำเป็นต้องกรอก` | add/edit part-no error |
| `เช่น Toyota Hilux 2015-2020, Isuzu D-Max` | add/edit ใช้กับรถรุ่น hint |
| `ลดได้มากสุด N ชิ้น — สต็อกจะเหลือ 0` | adjust-stock warning |
| `เลือกสินค้าเพื่อดูและเพิ่มซัพพลายเออร์` | suppliers tab, nothing selected |
| `คัดลอกรหัส X แล้ว` | vehicle search copy SnackBar |
| `ลดจำนวนชุด` / `เพิ่มจำนวนชุด` (tooltips) | label printer copies |
| `เลือกทั้งหมด (ทั้งหมด N)` / `⚠ สต็อกต่ำ (ทั้งหมด N)` | label printer quick chips while searching |
| `เปลี่ยนรูปแล้วบันทึกทันที ไม่ต้องกด "บันทึก"` | product image editor |

Tooltips reusing existing strings: `ค้นหาตามรุ่นรถ`, `ปรับสต็อก`, `แก้ไข`, `ปิด`.
