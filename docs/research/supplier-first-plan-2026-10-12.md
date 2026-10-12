# Supplier-first Suppliers tab — plan (2026-10-12)

Owner feedback (2026-10-12): "The supplier page should treat the SUPPLIER as the main thing,
not the products first." Follow-up from the owner: "make it look good with a good experience."
Branch `feat/supplier-first` (from `origin/develop` `972eeff3`). **Plan only, no code yet.**

## 1. Which page

**Products/Stock screen → tab `ซัพพลายเออร์ · Suppliers`** (`frontend/lib/presentation/screens/products_screen.dart`),
which is the page in the owner's screenshot. It is the only place suppliers are *managed*: add or delete a quote.
The other supplier UIs only read or use the data, so they stay as they are:

| Place | What it does with suppliers | Changed? |
|---|---|---|
| `products_screen.dart:136,199,3294-3883` `_SuppliersTab` | Picks a product first, then manages its supplier quotes | **Yes, this plan** |
| `purchase_orders_screen.dart:67-104,643-655,657-760` create-PO dialog | Supplier name search (#690); a picked supplier's products, quoted costs and low-stock list | Small: accepts a prefilled supplier |
| `settings_screen.dart:2445-2690` | Read-only "ซัพพลายเออร์ถูกที่สุด" column in the product export; backup counts | No |
| `widgets/low_stock_alert.dart` | Prints an 80 mm order slip and links to `/purchase-orders` | No |

## 2. Current flow (file:line, `products_screen.dart` unless named)

- `_load` (3325-3342) reads `ProductsRepository.getAll()` and `SuppliersRepository.getSuppliers()` in parallel and
  selects the first product.
- The left column (3439-3518) is titled `เลือกสินค้า` (3428). It lists every product with name, part no and
  `'$count ซัพฯ'` (3459-3508). The list key is `suppliers-product-list` (3453).
- The right panel (3523-3597) shows the product name and part no, a `เพิ่มซัพฯ` button (3562-3572), and a table
  `_supplierTable` (3606-3759) with columns ชื่อซัพพลายเออร์ · ทุน/ชิ้น · ค่าส่ง · รวม · จัดการ (3643-3647).
  The table is sorted by `unitCost + freight`, and `✓ ราคาถูกสุด` (3686) goes on every row that equals the minimum
  (3414-3418, 3651).
- Writes: `_add` (3350-3372) calls `addSupplier`, and `_delete` (3374-3386) calls `deleteSupplier`. Both are
  refused while Degraded with a snackbar (3395-3401) and show server errors through `ServerErrorResolver.resolveCounterError`.
  **`updateSupplier` has no UI today.**
- Narrow layout (< `AppBreakpoints.compact` = 600): the product list is stacked above the detail (3420-3445).
- Test: `test/products_catalogue_ux_test.dart:140-170` opens this tab at 3x/1920, 2x/1366, 3x/1366 and 390 px and
  expects `suppliers-product-list`. `route_smoke_test.dart` renders only the default Stock tab.

## 3. Data: no schema change

The Drift `Suppliers` table (`tables.dart:277-288`; `id, productId, name, unitCost, freight`) is **one row per
product×supplier quote**. The server `suppliers` table is the same shape (`server/src/products/suppliers.service.ts`).
A "supplier" is therefore a **group of rows by name**. The key is `name.trim().toLowerCase()`, which is exactly the
rule of `_knownSupplierNames` / `_norm` (`purchase_orders_screen.dart:641-655`). The display spelling is the first
one seen. **No Drift, server or migration change is needed.**

Derived per group, all in memory from data the tab already loads, plus one extra read:
- **products** = distinct `productId`s of the group that are in `_products`. `getAll()` already drops soft-deleted
  products on the API build, and the server's `GET /suppliers` hides their quotes too.
- **quotes** = the row count. It differs from products only when a duplicate quote exists.
- **cheapest-for** = the rows whose `unitCost + freight` equals the minimum over *all* suppliers' rows for that
  product. Ties all count, the same rule as today (3414-3418).
- **to reorder** = products with `stock <= minStock`. This is the definition in the Stock tab (`_stockStatus`, 991-995)
  and in the PO dialog's `_lowStock` (724-729).
- **last PO date** = the newest `createdAt` among `PurchaseOrdersRepository.getPOs()` whose `_norm(po.supplier)`
  matches the key. It is cheap: one more parallel read. On the API build that read does `syncFromServer()` first.
  If it throws, the tab still loads and the date is just not shown.

A real supplier entity (contact, phone, rename in one place) goes under **Later** (§10).

## 4. Writes: reuse only, and the API-build behaviour is unchanged

| Action | Repository call | API build (`api_suppliers_repository.dart`) |
|---|---|---|
| Add a product to this supplier / a new supplier | `addSupplier(productId, name, unitCost, freight)` | `POST /suppliers`, **`PendingWrites`** (`_pendingAdds`, 47/140-160): a 5xx/429/lost reply keeps the same key for the same body; a 4xx closes it; Drift is written only from the reply |
| Edit cost / freight | `updateSupplier(id, unitCost:, freight:)` | `PATCH /suppliers/:id`, a fresh `Idempotency-Key` per call (164-193). The body holds absolute values, so pressing again after an unknown outcome is harmless. Drift is written only from the reply |
| Remove a product from this supplier | `deleteSupplier(id)` (unchanged) | `DELETE /suppliers/:id` (196-209). The server answers 200 whether or not the row existed |

The screen keeps today's guards exactly: each write is refused while `context.isDegraded` (snackbar 3398), buttons
are disabled when `isDegraded`, errors go through `ServerErrorResolver.resolveCounterError`, and there is no
`ApiException` in `presentation/`. These are online-only writes with no outbox. After every write the tab re-reads
with `getSuppliers()`, as `_refreshSuppliers` does now. **No repository code changes.**

**Rename a supplier: Later.** It would take N `PATCH name` calls with no transaction, so a failure part-way would
split one supplier into two names. There is no safe existing path. "Delete the whole supplier" is Later for the same
reason; deleting each product row works today.

## 5. Where it lives

**In place: the same tab, no new route.** The tab gets a two-way toggle `ตามซัพฯ | ตามสินค้า`
(`SegmentedButton`), with **`ตามซัพฯ` as the default**. Keeping the old view is almost free: it shares
`_products`, `_suppliers`, `_add` and `_delete`. Today's `build` body moves unchanged into `_byProductView()`.
The toggle is not persisted, so every visit opens supplier-first.

"สร้างใบสั่งซื้อ" crosses to `/purchase-orders`:
- `context.go(AppRoutes.purchaseOrders, extra: PoPrefill(supplier: name, addLowStock: true))`. It uses `extra`, not
  a query string, so a supplier name never sits in the URL. A web refresh drops `extra`, and the screen then just
  opens normally.
- In the router (`app_router.dart:165`): `PurchaseOrdersScreen(prefill: state.extra is PoPrefill ? … : null)`.
- `PurchaseOrdersScreen.initState` calls `_openCreate(prefill)` once in a post-frame callback.
  `_openCreate` passes the prefill to `_CreatePoDialog`, and its `initState` sets `_supplierCtrl.text`, calls
  `_setSupplier(name)` (which re-prices from the quotes), then `_addLowStock()` (783-788). The dialog's own
  low-stock list and supplier pricing do the rest. No new PO logic.
- Degraded: the PO screen's `_openCreate` already refuses with its own warning (68-71).

## 6. UX and visual design

Direction: the shop's working tool, not a dashboard. It stays on the navy/orange theme. **Orange is spent only on
"needs action"**: the selected supplier stripe, the reorder count, and the primary `สร้างใบสั่งซื้อ` button. Green
appears only on the cheapest badge. Everything else stays neutral, so the eye lands on what to reorder and where it
is cheapest. It uses the app's existing type, `baht()`, `StatusChip`, `thaiDate`, and `AppColors`. No new fonts,
no gradients, and no added card shadows beyond what the tab already uses.

**Hierarchy**
- List row: the **supplier name** is w700 and the largest text in the row. The second line is a quiet steel-blue
  `{n} สินค้า`. On the right, an orange `StatusChip(warning)` `ต้องสั่ง {m}` appears only when m > 0.
  A third line `สั่งล่าสุด {thaiDate}` appears only when there is a PO.
- Detail header: the supplier name in `headlineSmall` w800. Below it, a row of three facts as plain text, not cards:
  `{n} สินค้า`, `ถูกสุด {k} รายการ`, `ต้องสั่ง {m}`. When quotes ≠ products, it adds `({q} ราคา)`.
  The actions are on the right: primary orange `สร้างใบสั่งซื้อ`, with the reorder count when m > 0, and secondary
  outlined `เพิ่มสินค้า`.

**Product table for the selected supplier.** Columns: สินค้า (name + orange part no) · สต็อก · ทุน/ชิ้น · ค่าส่ง ·
รวม · จัดการ.
- The rows are sorted by need: **out of stock, then low, then the rest**, and by name within each group. The
  owner reads the top of the table as the order list.
- The stock cell shows `{stock}/{min}`, plus `StatusChip('หมด', danger)` or `StatusChip('ใกล้หมด', warning)`.
  The status function moves out of `_StockTabState` into a file-level `_stockStatus` so that both tabs share one rule.
- **Cheapest meaning, stated once and then shown:** a one-line legend above the table reads
  `✓ ถูกสุด = ราคารวม (ทุน + ค่าส่ง) ต่ำที่สุดในบรรดาซัพฯ ของสินค้านั้น`. A cheapest row gets the green `✓ ถูกสุด`
  pill. A row that is not the cheapest shows a quiet `แพงกว่า ฿x` under its total, with the tooltip
  `ถูกสุด: {otherSupplier} {baht}`. This turns the badge into a decision: the owner can see who to buy from instead.
  When this supplier is the only quote, the row shows no badge, because "cheapest of one" says nothing.
- จัดการ: an edit icon (tooltip `แก้ราคา`) opens a small dialog with ราคาต่อชิ้น ฿ / ค่าส่ง ฿, prefilled, with
  ยกเลิก and บันทึก. The delete icon is unchanged from today. Tapping the product name switches to `ตามสินค้า`
  with that product selected, so the owner can compare all suppliers for it.

**Add product to this supplier.** An inline form like today's `_addForm` (3761-3845). It has a product search field
that matches name or part no and shows 5 matches, the same matching as `_filteredParts` in the PO dialog. **It leaves
out products this supplier already quotes**, so no duplicates are made. It also has ราคาต่อชิ้น ฿ (prefilled with
`product.cost`) and ค่าส่ง ฿. The supplier name is the group's display spelling, so the new row lands in the same
group.

**New supplier.** A `+ ซัพพลายเออร์ใหม่` text button sits under the list search. It opens the same form with a
name field on top. A supplier exists only through a quote, so it needs a first product. The form says this in its
helper text.

**Search (shop PC: keyboard first).**
- The search field sits at the top of the list, with the hint `ค้นหาซัพฯ หรือสินค้า`. It matches the supplier name
  **or any of its products' name or part no**, which answers "who sells this part?".
- It has `autofocus` on the wide layout only; on a phone it does not, so the keyboard does not cover the list.
- `Enter` opens the first match and `Esc` clears the field. Filtering happens on every keystroke, in memory, with
  no debounce needed.
- List order: suppliers with something to reorder first, then by name.

**Empty and edge states** (friendly, and each one says what to do next):
- No suppliers at all: `ยังไม่มีซัพพลายเออร์` with a `+ เพิ่มซัพพลายเออร์แรก` button.
- No search match: `ไม่พบซัพฯ หรือสินค้าที่ตรงกับ "{q}"` with a `ล้างคำค้น` button.
- A supplier with no live products (every product it quoted was deleted). The group disappears from the list, since
  products are counted only from `_products`, so this state cannot appear. Nothing to design.
- Nothing selected (wide): `เลือกซัพพลายเออร์ทางซ้ายเพื่อดูสินค้าและราคา`. The first supplier is selected on load,
  so this shows only after a search hides the selected one.

**Narrow / phone (< 600 logical px, which includes 3x zoom on 1366 and 1920).** List → detail **push inside the
tab**, replacing today's stacked layout:
- The list fills the tab. Tapping a supplier swaps in the detail, which has a top row with a back `IconButton`
  (tooltip `กลับ`) and the supplier name.
- `PopScope(canPop: !_detailOpen)` makes Android back return to the list instead of leaving the screen.
- The table becomes a card list, one card per product: name / part no / stock chip on top, then
  `ทุน ฿ · ค่าส่ง ฿ · รวม ฿` and the cheapest pill, then the edit and delete icons. There is no horizontal scroll.
- The actions sit in a `Wrap` under the header, so at 3x the two buttons fall onto two lines instead of
  overflowing. Every row of text uses `Expanded` / `Flexible` with ellipsis. The #693 lesson applies: no
  `Container(alignment:)` inside a `Wrap`.

**Zoom.** Layout decisions read `LayoutBuilder` constraints (the zoomed logical size), never
`MediaQueryData.fromView`. The list keeps the 260 px width on wide layouts. Nothing has a fixed height except the
min-height rows.

### ASCII wireframes

Wide (≥ 600, e.g. a 1280 tablet):
```
┌ สต็อก | คำนวณราคา | [ซัพพลายเออร์] | รายงานสต็อก ───────────────────────────────────────┐
│ ( ตามซัพฯ ●| ตามสินค้า )                                                               │
├──────────────────────────┬───────────────────────────────────────────────────────────────┤
│ [🔍 ค้นหาซัพฯ หรือสินค้า ] │ Auto Zone TH                  [สร้างใบสั่งซื้อ (2)] [+ เพิ่มสินค้า] │
│ + ซัพพลายเออร์ใหม่          │ 3 สินค้า   ถูกสุด 2 รายการ   ต้องสั่ง 2                         │
│▌Auto Zone TH  [ต้องสั่ง 2] │ ✓ ถูกสุด = ราคารวม (ทุน + ค่าส่ง) ต่ำที่สุดในบรรดาซัพฯ ของสินค้านั้น   │
│  3 สินค้า                  │ ┌────────────────┬──────────────┬──────┬─────┬──────────┬──────┐ │
│  สั่งล่าสุด 2 ต.ค. 2569      │ │สินค้า            │สต็อก          │ทุน/ชิ้น│ค่าส่ง│รวม       │จัดการ│ │
│ Honda Parts Center       │ │ผ้าเบรกหน้า        │0/5  [หมด]     │ ฿38  │ ฿7  │฿45 ✓ถูกสุด│ ✎ 🗑 │ │
│  2 สินค้า                  │ │BP-1234         │              │      │     │          │      │ │
│ NGK Thailand             │ │หัวเทียน NGK      │3/10 [ใกล้หมด] │ ฿62  │ ฿5  │฿67       │ ✎ 🗑 │ │
│  4 สินค้า                  │ │SP-77           │              │      │     │แพงกว่า ฿4 │      │ │
│                          │ │น้ำมันเครื่อง      │24/6          │ ฿150 │ ฿0  │฿150 ✓ถูกสุด│ ✎ 🗑 │ │
│                          │ └────────────────┴──────────────┴──────┴─────┴──────────┴──────┘ │
└──────────────────────────┴───────────────────────────────────────────────────────────────┘
```

Narrow, list (phone, or 3x zoom):
```
┌ ( ตามซัพฯ ●| ตามสินค้า ) ─────┐
│ [🔍 ค้นหาซัพฯ หรือสินค้า     ] │
│ + ซัพพลายเออร์ใหม่              │
│ Auto Zone TH     [ต้องสั่ง 2]  │
│ 3 สินค้า · สั่งล่าสุด 2 ต.ค.     │
│ Honda Parts Center          │
│ 2 สินค้า                      │
└─────────────────────────────┘
```

Narrow, detail (after a tap; back returns to the list):
```
┌ ← Auto Zone TH ─────────────┐
│ 3 สินค้า  ถูกสุด 2  ต้องสั่ง 2   │
│ [ สร้างใบสั่งซื้อ (2)       ]   │
│ [ + เพิ่มสินค้า            ]   │
│ ┌─────────────────────────┐ │
│ │ ผ้าเบรกหน้า        [หมด] │ │
│ │ BP-1234       สต็อก 0/5 │ │
│ │ ทุน ฿38 ค่าส่ง ฿7         │ │
│ │ รวม ฿45   ✓ ถูกสุด  ✎ 🗑  │ │
│ └─────────────────────────┘ │
└─────────────────────────────┘
```

### Thai strings

New strings are **`agent ร่าง`** and wait for the owner's ratification, as `02 §8.1.1` requires:
`ตามซัพฯ`, `ตามสินค้า`, `ค้นหาซัพฯ หรือสินค้า`, `ซัพพลายเออร์ใหม่`, `{n} สินค้า`, `ต้องสั่ง {m}`,
`สั่งล่าสุด {date}`, `ถูกสุด {k} รายการ`, `({q} ราคา)`, `เพิ่มสินค้า`, `ใกล้หมด`, `✓ ถูกสุด`, the cheapest legend,
`แพงกว่า ฿x`, `ถูกสุด: {name} {baht}`, `แก้ราคา`, `แก้ไขราคา`, `ยังไม่มีซัพพลายเออร์`, `เพิ่มซัพพลายเออร์แรก`,
`ไม่พบซัพฯ หรือสินค้าที่ตรงกับ "{q}"`, `ล้างคำค้น`, `เลือกซัพพลายเออร์ทางซ้ายเพื่อดูสินค้าและราคา`, `กลับ`, and the
new-supplier helper text `ซัพพลายเออร์ต้องมีสินค้าอย่างน้อย 1 รายการ`.

These existing strings are reused unchanged: `สร้างใบสั่งซื้อ`, `หมด`, `ทุน/ชิ้น`, `ค่าส่ง`, `รวม`, `จัดการ`,
`ราคาต่อชิ้น ฿`, `ค่าส่ง ฿`, `บันทึก`, `ยกเลิก`, `ลบ`, `เลือกสินค้า`, and the Degraded snackbar.
Each new string gets a `// agent ร่าง` comment in code and a row in the PR body.

## 7. Implementation outline (the next step, not this commit)

1. `products_screen.dart`: add a file-level `_stockStatus` and pure helpers `_supplierKey(name)` and
   `_groupSuppliers(products, quotes, pos) → List<_SupplierGroup>` (key, display name, rows, product count, reorder
   count, cheapest count, last PO). These are pure functions, so they are unit-testable.
2. `_SuppliersTab`: add the `_mode` toggle, move today's body into `_byProductView()` without changing its code,
   and add `_bySupplierView()` (wide = master/detail, narrow = push). Add `_edit(row)` → `updateSupplier`.
3. `purchase_orders_screen.dart` + `app_router.dart`: add `PoPrefill` and the optional `prefill`, which opens the
   dialog once with the supplier set and the low-stock items added.
4. No repository, Drift, server or contract-fixture change. `updateSupplier`'s request is already covered by the
   `suppliers.update` scenario (`test/contract/client_requests_contract_test.dart:340`), so there is nothing to
   regenerate.

## 8. Test plan

- **Unit (pure):** `_groupSuppliers` groups `" Auto Zone TH"` / `"auto zone th"` into one group with the first
  spelling, skips quotes of products not in the list, counts products vs quotes, picks the cheapest across groups
  (ties count for both), counts reorder (`stock <= minStock`), and takes the last PO by normalised name.
- **Widget (in `products_catalogue_ux_test.dart`, seed data):**
  - It opens on `ตามซัพฯ` and lists `Honda Parts Center` / `Auto Zone TH` / `NGK Thailand`.
  - A search for a product part no keeps only its suppliers; Enter opens the first one.
  - Seed p1 is a tie (Honda 42+3 = Auto Zone 38+7 = 45), so both suppliers get `✓ ถูกสุด` and neither gets
    `แพงกว่า`. Add one dearer quote (for example `Test Shop` 50+0) and check that it shows `แพงกว่า ฿5` with the
    cheaper supplier in the tooltip.
  - The edit dialog calls `updateSupplier` and the table shows the new total.
  - Add-product excludes products already quoted by the supplier and writes with the group's display spelling.
  - Delete removes the row. While Degraded, the edit, add, delete and new-supplier buttons are disabled.
  - The toggle to `ตามสินค้า` still finds `suppliers-product-list`. The existing test keeps passing, retargeted to
    tap the toggle first.
  - Narrow: tap a supplier, the detail shows, then back (button and `PopScope`) returns to the list.
- **Zoom/size:** extend the existing loop at 140-170 to both modes plus the narrow detail at 3x/1920, 2x/1366,
  3x/1366 and 390 px with no exception. This loop is the "route smoke at 3x/2x" for this tab, because the route smoke
  test renders only the Stock tab.
- **PO prefill (`purchase_orders_screen_test.dart`):** `PurchaseOrdersScreen(prefill: …)` opens the dialog with the
  supplier filled and low-stock lines added at quoted cost. Without a prefill, nothing opens.
- **API build:** no new repository path. `api_suppliers_repository_test.dart` already covers `updateSupplier`
  (363-390) and `api_exception_never_escapes_test.dart` covers it (510). Run both unchanged.
- `dart analyze` (never `flutter analyze`) and the full `flutter test`.
- **Look at it (#693 rule):** build with `flutter build web --no-tree-shake-icons --no-web-resources-cdn`, serve
  it, clear the service worker and caches, and check the wide layout at 1280, 3x zoom, and 390 px by eye.
  Take screenshots for the PR.

## 9. Assumptions (decided without the owner, asleep, per the brief)

1. "The supplier page" is the Suppliers tab of the Products screen. The coordinator confirmed this from the owner's
   screenshot.
2. A supplier's identity is its trimmed, case-insensitive name. Different spellings ("Auto Zone" vs "AutoZone")
   stay separate until the rename/merge feature in §10.
3. The supplier list shows only suppliers with at least one live quote. Names that appear only on old POs are not
   listed, because they have no products to manage.
4. "Total quotes" is read as the quote-row count. It is shown only when it differs from the product count, to avoid
   repeating the same number.
5. The default mode is always `ตามซัพฯ` and is not persisted.
6. One-click PO also adds the supplier's low-stock items. The dialog stays open for review, so nothing is saved
   without the owner pressing บันทึก.
7. Edit uses `updateSupplier` online-only, with the existing per-call key and no `PendingWrites`. That repository
   design already exists and is tested, and a PATCH of absolute values is safe to repeat.

## 10. Out of scope / Later

- **Rename or merge a supplier**, and **delete a whole supplier**. Each needs a server endpoint that changes every
  row of the group in one transaction (for example `POST /suppliers/rename {from, to}`), plus a Drift cache apply.
  N separate PATCHes or DELETEs can leave a half-renamed group.
- **A real supplier entity** (contact, phone, LINE, payment terms). It needs a new `supplier_entities` table and a
  `suppliers.supplier_id` FK, a Drift schema bump (lane B, ASCII-path `build_runner`), and an import/backup format
  change. Name grouping covers today's request without it.
- Supplier spend history and PO totals per supplier, beyond the last PO date.
- Offline queueing of supplier writes. They stay online-only, as today.
- Changing the create-PO dialog's own UI, the low-stock alert, or the settings export.
