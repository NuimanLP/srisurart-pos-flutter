# ADR-0010 — client เก็บ Drift เป็น write-through cache และ map ที่ชั้น repository

* **สถานะ:** Accepted — 2026-09-04
* **ผู้ตัดสิน:** เจ้าของโปรเจกต์
* **ปิดข้อค้าง:** ความขัดแย้งระหว่าง `03_ARCHITECTURE §8` (Gantt งาน `q1`) กับ §4 (Architecture C)

## บริบท — เอกสารสองที่ในไฟล์เดียวกันสั่งตรงข้ามกัน

Gantt ใน `§8` เขียนงาน `q1` ว่า **"Flutter ApiRepository (แทน Drift repos)"** — คำว่า *แทน*
อ่านได้อย่างเดียวว่า **ลบ Drift ทิ้งแล้วยิง HTTP แทน**

แต่ `§4` (Architecture C ซึ่งเป็นสถาปัตยกรรมที่เลือก) ระบุว่าตอน **Online** ต้อง
*"cache สินค้า + โควตาสต็อกไว้ในเครื่อง"* และตอน **Degraded** ต้องขายจาก cache นั้นได้

→ ถ้า `q1` ลบ Drift จริงตามที่ Gantt เขียน **งาน `q2` (outbox + offlineOk) จะไม่มีอะไรให้อ่าน**
ต้องสร้าง cache ขึ้นมาใหม่ทั้งชุด = รื้อของที่เพิ่งลบไปเมื่อสองเดือนก่อน

## ทางเลือกที่พิจารณา

| | แนวทาง | ทำไมไม่เอา |
|---|---|---|
| (ก) | **write-through** — `ApiRepository` implement interface เดิม ยิง server แล้วเขียนผลลง Drift | ✅ **เลือกอันนี้** |
| (ข) | **แทนก่อน แล้วค่อยเอา offline กลับมา** (ตาม Gantt เดิม) | ทิ้งชั้น offline ที่ใช้งานได้อยู่แล้ว แล้วสร้างใหม่ — ประมาณการ 20 วันของ `q1` จะกลายเป็นสองเท่า |
| (ค) | **Drift เป็น cache โง่ ๆ เก็บ JSON blob** | `offlineOk` ต้องประเมิน `stock ≥ threshold` ในเครื่อง ซึ่ง query บน blob ไม่ได้ |

## การตัดสินใจ

**1. Drift ยังอยู่ ทำหน้าที่ write-through cache**

`ApiRepository` implement **interface repository เดิม** ยิง server เป็นแหล่งความจริง
แล้วเขียนผลลัพธ์ลง Drift ทุกครั้ง — หน้าจอไม่ต้องแก้แม้แต่ไฟล์เดียว เพราะ `CONTRACT.md`
บังคับไว้แต่ต้นว่า **หน้าจอคุยกับ repository provider ไม่ใช่ `AppDatabase`**
รอยต่อนี้คือสิ่งที่การออกแบบเดิมซื้อไว้ให้แล้ว

**2. schema ทั้งสองฝั่งไม่ต้องเหมือนกัน — แปลงที่ชั้น repository**

Postgres มี 28 ตาราง Drift มี 20 (+ ที่เพิ่มใน schema v2) **ไม่ regenerate Drift ให้ mirror Postgres**
`ApiRepository` แปลง JSON → Drift row ด้วยมือ

* schema ฝั่ง client **ขยับเฉพาะเมื่อ client ต้องใช้ field นั้นจริง** ไม่ใช่ตาม migration ฝั่ง server
  — ⚠️ ฉบับแรกเขียนว่า "หยุดขยับ" ซึ่ง**ผิดตั้งแต่วันแรก** (scrutinize 2026-09-04):
  `POST /sales` ต้องส่ง `shiftId` แต่ตาราง `Sales` ใน Drift ไม่มีคอลัมน์นี้, `Shifts.id` ใน Drift
  เป็น integer autoIncrement (`tables.dart:261`) ขณะที่ server ใช้ TEXT + `device_id`,
  และ `Products` ไม่มี `offlineOk` ที่ `q2` ต้องใช้ → **ต้องมี schema v3** ก่อน `q1` เสร็จ:
  `Sales.shiftId TEXT`, `Shifts.id → TEXT` (พร้อม migration แปลง id เดิม), `Products.offlineOk BOOL`
  รัน `build_runner` บน ASCII path รอบเดียว
* test 123 ตัวที่เขียนไว้กับ schema เดิม **ยังใช้ได้ทั้งหมด** (คอลัมน์ใหม่ nullable/มี default)
* ต้นทุนที่ยอมจ่าย: โค้ด mapping น่าเบื่อและต้องเขียนเอง — แต่มันคือชั้นที่ทำให้เห็นตอน
  field ฝั่ง server ความหมายไม่ตรงกับที่ client สมมติไว้ ซึ่ง mirror อัตโนมัติจะกลืนหายไปเงียบ ๆ

**3. ใครเป็นเจ้าของ invariant — เพิ่ม 2026-09-04 (scrutinize รอบ 3)**

ฉบับแรกไม่ได้บอกว่า `ApiRepository` จะ "เขียนผลลง Drift" ยังไง ซึ่งเป็นคำถามที่อันตรายที่สุดของ ADR นี้:
`SalesRepository.saveSale` ของ Drift (`sales_repository.dart:33-56`) pre-check สต็อกแล้วตัดแบบ
strict ในทรานแซกชันของตัวเอง ถ้า `ApiRepository` เรียกมันหลัง server ตอบ 201 จะได้ (ก) สต็อกใน
เครื่องที่ค้างต่ำกว่าจริงปฏิเสธบิลที่ server รับไปแล้ว หรือ (ข) ตัดสต็อกซ้ำสองรอบ

* **`ApiRepository` ห้ามเรียก transactional service ของ Drift** (`saveSale` / `createReturn` /
  `receivePO` / `openShift` …) — มัน **patch แถว** จาก response ของ server เท่านั้น
  invariant ทุกตัวอยู่ที่ server แห่งเดียว Drift repos เดิมยังอยู่เพื่อ (1) เป็น behavioural
  reference ให้ port และ (2) เป็น implementation ที่ build เดิมของร้านใช้ จนกว่าจะ cutover
* interface ที่ screen ผูกคือ **concrete class** (`RepositoryProvider<SalesRepository>`) — Dart
  ให้ทุก class เป็น implicit interface จึง `class ApiSalesRepository implements SalesRepository`
  ได้โดยไม่ต้องสกัด abstract class แต่ `SalesRepository` รับ `AppDatabase` ใน constructor
  `ApiSalesRepository` ต้องสร้าง `SaleRow`/aggregate เดิมคืนให้ screen จาก JSON เอง
* **แต่ละ write ต้อง patch แถวไหน** (สเปคของ response ใน `02_API_SCREENS.md`):

  | write | server คืน | `ApiRepository` patch ลง Drift |
  |---|---|---|
  | `POST /sales` | บิล + `products[] {id, stock}` + `customerAfter {points,totalSpend}` + `mechanicCreditBalanceAfter` + **`shiftId` + `items[] {lineNo,productId,costAtSale}` + `movements[]` + `mechanicAfter{}`** (#82) | `sales` (รวม `shiftId`), `saleItems` (รวม `costAtSale`), `products.stock`, `customers`, `mechanics` (ทั้งสี่ยอด), `movements` |
  | `POST /returns` | ใบลดหนี้ + `products[] {id, stock}` + `customerAfter` + `mechanicCreditBalanceAfter` + `saleVoided` + **`movements[]` + `mechanicAfter{}`** (#82) | `returns`, `returnItems`, `products.stock`, `customers`, `mechanics` (ทั้งสี่ยอด), `sales.voided`, `movements` |
  | `POST /purchase-orders/:id/receive` | PO + `products[] {stock, cost}` | `purchaseOrders`, `products.stock/cost`, `movements` |
  | `POST /shifts/*` | shift row | `shifts`, `drawerEntries` |
  | ที่เหลือ (CRUD) | แถวที่แก้ | แถวนั้น |

  ถ้า field ไหนไม่อยู่ใน response ให้ **ถือว่า Drift แถวนั้น stale** จนกว่า `/bootstrap` รอบถัดไป
  ห้ามคำนวณเองในเครื่อง (ถึงจะแค่ 6 บรรทัด) เพราะจะกลายเป็น invariant ชุดที่สองที่เพี้ยนได้เงียบ ๆ

**4. แก้ตารางข้างบนตามของจริง + ช่องที่ response ไม่มี — เพิ่ม 2026-09-12 (#56)**

ตารางฉบับแรกเขียนชื่อ field จากที่ตั้งใจไว้ ไม่ใช่จากที่ server ส่งจริง `#56` ไปต่อโค้ดแล้วเจอว่า
**ผิดสามจุด** จึงแก้ไว้ข้างบนแล้ว: `POST /returns` ส่ง `saleVoided` (ไม่ใช่ `parentSaleVoided`) และ
~~`mechanicCreditBalanceAfter` (ไม่ใช่ `mechanicAfter`)~~ — **ข้อนี้หมดอายุแล้วใน PR เดียวกัน: #82
เพิ่ม `mechanicAfter` เข้าทั้งสอง response และเก็บ `mechanicCreditBalanceAfter` ไว้ด้วย (ดูข้อ 6)** — `server/src/returns/returns.service.ts`;
`products[]` มีแค่ `{id, stock}` **ไม่มี `offlineOk`** ซึ่ง `sales.service.ts:217` ตั้งใจไม่ส่ง
เพราะเฟส 1 ยังไม่มีที่เก็บ

~~ช่องที่ response **ไม่มี** และ client จึงต้องปล่อยค้าง (ตามกฎ "ถ้าไม่อยู่ใน response ให้ถือว่า stale"):~~
**ปิดครบทั้งสี่ช่องแล้วโดย `#82`** — ดูข้อ 6 ตารางนี้เก็บไว้เป็นประวัติเท่านั้น

| ~~ช่อง~~ | ~~ทำไมไม่มี~~ | ~~ผลกับ client~~ |
|---|---|---|
| ~~`movements`~~ | ~~server เขียนแถวจริง (`insertMovements`) แต่ไม่ส่งคืน~~ | ~~ตาราง `movements` ในเครื่องมองไม่เห็นบิลที่ขายผ่าน server เลย จนกว่าจะมี read slice~~ |
| ~~`sales.shiftId`~~ | ~~server ประทับลงแถว (`sales.service.ts:155,160`) แต่ `CreateSaleResult` ไม่ส่งกลับ~~ | ~~`Sales.shiftId` ที่ schema v3 เพิ่งเพิ่มมาเป็น null ทุกบิล — **แก้ที่ server บรรทัดเดียว**~~ |
| ~~`saleItems.costAtSale`~~ | ~~response ไม่มีต้นทุน~~ | ~~null = "ประเมิน ห้าม backfill" ตาม `tables.dart`~~ |
| ~~`mechanics.totalSales/totalDiscount/totalMarkup`~~ | ~~response ส่งแค่ยอดเครดิต~~ | ~~หน้าจอช่างเห็นสถิติค้าง~~ |

**5. `updatedAt` ของแถวที่มาจาก server — เพิ่ม 2026-09-12 (#56)**

ข้อ 3 ห้าม "คำนวณเองในเครื่อง" ไว้กว้าง ๆ แต่ไม่เคยพูดถึงกรณี timestamp ซึ่ง `product_stamp.dart`
ขอไว้ให้ `#56` เขียนลงเอกสารให้ชัด — เขียนตรงนี้:

> เมื่อ `ApiRepository` patch แถวจาก response ของ server **ห้ามประทับ `updatedAt` ด้วยนาฬิกาเครื่อง**
> `updatedAt` คือเคอร์เซอร์ที่ `?updatedSince=` ใช้ (งาน `#55`) การประทับเองดันเคอร์เซอร์ **ล้ำหน้า**
> การแก้ที่ server ทำระหว่างนั้น = แถวนั้นหายถาวร ส่วนการปล่อยให้ค้างอยู่ข้างหลัง อย่างแย่ที่สุดคือ
> ดึงซ้ำแล้วได้ค่าที่ถูกต้อง — ผิดทางที่ปลอดภัยกว่าอย่างชัดเจน
>
> กฎของ `product_stamp.dart` ("ทุก write ที่แก้แถวสินค้าต้องขยับ `updatedAt`") ยังใช้กับ **write ที่เกิดในเครื่อง**
> ทั้งหมดเหมือนเดิม ข้อนี้เป็นข้อยกเว้นเฉพาะแถวที่ค่ามาจาก server ซึ่ง server ขยับ `products.updated_at`
> ของตัวเองอยู่แล้ว เคอร์เซอร์ฝั่ง server จึงถูกต้องไม่ว่า client จะประทับหรือไม่

**6. ปิดทั้งสี่ช่องของข้อ 4 — เพิ่ม 2026-09-12 (#82)**

ข้อ 4 บอกว่า client "ต้องปล่อยค้าง" ซึ่งถูกตามกฎข้อ 3 แต่ **ไม่ใช่คำตอบสุดท้าย**: ทั้งสี่ช่องเป็นค่าที่
server ถืออยู่ในมือแล้วตอนเขียน แค่ไม่ได้ส่งกลับ `#82` จึงขยาย response แทนที่จะให้ client เดา —
ซึ่งตรงกับเจตนาข้อ 3 มากกว่า ("ถ้าอยากให้ client มีค่า ให้ server ส่งมา อย่าให้ client คำนวณ")

| ช่อง | อยู่ใน response แล้ว |
|---|---|
| `sales.shiftId` | `CreateSaleResult.shiftId` (และ replay path `existingSale` อ่าน `shift_id` ด้วย) |
| `saleItems.costAtSale` | `CreateSaleResult.items[] { lineNo, productId, costAtSale }` — จาก locked read เดียวกับที่เขียนแถว (ADR-0008) |
| `movements` | `CreateSaleResult.movements[]` (`type: 'sale'`) และ `CreateReturnResult.movements[]` (`type: 'return'`) |
| `mechanics.totalSales/totalDiscount/totalMarkup` | `mechanicAfter { id, totalSales, totalDiscount, totalMarkup, creditBalance }` ทั้งสองฝั่ง — `mechanicCreditBalanceAfter` ยังอยู่เหมือนเดิม |

🔴 **`mechanics.total_credit` ไม่อยู่ใน `mechanicAfter` และห้ามใส่** (ข้อตัดสิน `#11`) — มันคือชื่อเก่าของ
`total_discount` ที่ server ไม่เคยเขียน ถ้าส่งกลับไป client จะไป patch คอลัมน์ที่ไม่มีใครเป็นเจ้าของ

🔴 **`movements.type` ของ void คือ `'void'` ไม่ใช่ `'return'`** (migration `1788652800003`) รายงานทั้งหมด
group ด้วยคอลัมน์นี้ การยุบสองค่านี้เข้าด้วยกัน = นับบิลที่ยกเลิกเป็นการคืนเงิน

## Addendum 2026-09-15 — phase-2 owner session #240

เจ้าของโปรเจกต์ตัดสิน D3, D5, D9 ใน #240 · สเปกเต็ม [`08_PHASE2_SPEC.md §5, §6, §15`](../08_PHASE2_SPEC.md)

| # | ตัดสิน | ผลกับ ADR นี้ |
|---|---|---|
| D3 | **ไม่มี `offlineOk`** — ออฟไลน์ขายได้ถ้าสต็อกในเครื่องพอ | ข้อ 2 เพิ่ม `Products.offlineOk` ใน schema v3 ไว้ให้ `q2` — คอลัมน์นี้**ไม่มีใครใช้แล้ว** ~~(ลบหรือปล่อยไว้ → `08 §15 Q12`)~~ (E10: ลบ) · ทางเลือก (ค) ในตารางด้านบนที่ตกเพราะ "`offlineOk` ต้อง query ในเครื่อง" — เหตุผลนั้นหมดไป แต่ (ก) ยังถูก เพราะการตรวจสต็อกในเครื่องก็ต้อง query เหมือนกัน · pull (#191) ไม่คำนวณ/ไม่อ่าน `offlineOk` |
| D5 | เข้า Degraded เมื่อ health check ล้ม 3 ครั้ง / ช้า > 5 วินาที **หรือ write ที่ server ไม่ตอบ** · ออกด้วย health check เท่านั้น | write ที่ไม่ได้คำตัดสิน (`isVerdict` ไม่นับ) **เข้า outbox ด้วย id + key เดิม** แทนการค้างใน `PendingWrites` · "ฝั่งเขียนเป็น online-only จนกว่า `q2` จะเสร็จ" ในผลที่ตามมาจบลงเมื่อ outbox ลง |
| ~~D9~~ | ~~ลูกค้า / ช่าง / ใบเสนอราคา = **เข้าคิว** · สินค้า / หมวด / ใบสั่งซื้อ (+ `purgeOldQuotes`) = **ออนไลน์เท่านั้น**~~ | ~~fallback `super.<write>()` ที่สร้างแถวอยู่ในเครื่องอย่างเดียว (#229, 18 จุด) ต้องหายหมด — ทุก write เป็น op ในคิวหรือถูกปฏิเสธ~~ **(แทนที่โดย E6 รอบ 2)** |

**กติกาที่ outbox เพิ่มให้ข้อ 3 ("ใครเป็นเจ้าของ invariant")** — ไม่เปลี่ยนหลัก เพิ่มแค่ช่องทาง:

* op ในคิวถูกเขียนลง Drift (แถวที่ op สร้าง + แถว `outbox_ops`) **ใน local transaction เดียว** ตอนกด — นี่คือการเขียน "ในเครื่อง"
  ที่ข้อ 5 อนุญาตให้ประทับ `updatedAt` ได้ **แต่ห้ามเรียก transactional service ของ Drift** เหมือนเดิม (`saveSale` ไม่ถูกเรียกตอนเข้าคิว)
  การตรวจสต็อก/วงเงินในเครื่องก่อนเข้าคิวเป็นการ**ตรวจ** ไม่ใช่ invariant — ผู้ตัดสินจริงยังเป็น server ตอน push
* `/sync/push` ตอบ `applied` พร้อม **response เดียวกับ endpoint ออนไลน์** → patch ตามตารางข้อ 3 ทุกช่องเหมือนเดิม
* outbox **ตารางเดียว** (`outbox_ops`, ~~Drift schema v7~~ เลข schema ใส่ตอน merge) — `pending_credit_payments` ของ #24 ย้ายเข้ามา เพื่อให้ลำดับกับบิลเครดิตถูก
* ตราบใดที่มี op ค้างส่ง write ใหม่ต่อท้ายคิว แม้ออนไลน์แล้ว (รักษาลำดับ) · สินค้าที่มี op ค้างไม่ถูกเขียนทับสต็อกตอน pull (#191 เดิม)
* **ไม่เพิ่ม `sales.sync_status`** — สถานะของบิลอ่านจาก op ของมันใน outbox ที่เดียว

## Addendum 2026-09-15 (รอบ 2) — owner round 2 on #240 (E6, E10) + review PR #254

สเปก [`08_PHASE2_SPEC.md §6, §7, §15`](../08_PHASE2_SPEC.md)

| # | ตัดสิน | ผลกับ ADR นี้ |
|---|---|---|
| E6 | รายการ op เข้าคิว / ออนไลน์เท่านั้น / ในเครื่องอย่างเดียว → **`08 §6`** (ไม่คัดลอกมาที่นี่) | แทน D9 |
| E10 | **ลบ `Products.offlineOk`** (Drift — Postgres ไม่มีคอลัมน์นี้) | ข้อ 2 schema v3 ส่วน `offlineOk` หมดความหมาย |
| 08 B4 🔴 | cursor ของ pull = **`meta.nextCursor` ของ server เก็บใน Drift** · ถอย 30 วินาทีครั้งเดียวต่อรอบ pull **และไม่ส่ง `afterId` ในหน้าแรก** (รอบ 3) · **ห้าม derive จาก `updatedAt` ในเครื่อง** (`api_*_repository.dart` วันนี้ใช้ `MAX(updatedAt)` = นาฬิกาเครื่อง ข้ามการแก้ของ backoffice ถาวรถ้านาฬิกาเร็ว) · customers/mechanics ต้องได้ keyset + `nextCursor` แบบ products | แทนการอ่าน cursor จากแถวในเครื่อง · ข้อ 5 (ประทับ `updatedAt` ในเครื่องได้) ปลอดภัยก็เพราะข้อนี้ |
| 08 B2 🔴 | ทุก op ที่สร้างแถวพก client id และ server replay ด้วย id นั้น (key หมดอายุ 24 ชม. แต่ช่วงออฟไลน์ไม่มีเพดาน) | – |
| 08 §6.4 | **body ออนไลน์ = payload ของ op** ตัวอักษรต่อตัวอักษร ไม่งั้น fingerprint ไม่ตรง → `IDEMPOTENCY_KEY_REUSED` | – |
| 08 §7 (review 🟠8) | patch จาก response ที่ `applied` ห้ามเขียนทับ `stock` ของสินค้าที่ยังมี op ค้าง · discard ลบแถวในเครื่องที่ op สร้าง แล้วให้ pull แก้สต็อก | – |

## Addendum 2026-09-15 (รอบ 3) — owner round 3 on #240 (F1, F2, F8) + review รอบ 2

สเปก [`08_PHASE2_SPEC.md §6–§8, §14, §15`](../08_PHASE2_SPEC.md)

| # | ตัดสิน | ผลกับ ADR นี้ |
|---|---|---|
| F1 | B1–B4 อนุมัติ | cursor = `meta.nextCursor` ของ server เป็นกติกาถาวรของ ADR นี้ |
| F2 | op หัวคิวไม่ได้คำตัดสิน 3 ครั้ง → `stuck` ไปหน้า "รอ owner" · op ที่ aggregate เดียวกันรอ ที่เหลือไปต่อ | outbox มี `status` 3 ค่า (`pending`/`stuck`/`rejected`) + `attempts` + `aggregates` |
| F8 | storage ของ `pos` ถูกล้าง = op ค้างหาย (ยอมรับ) · `storage.persist()` ตอนบูต | cache + outbox อยู่ใน storage เดียว ไม่มีสำเนาที่สอง |
| review | replay by id เทียบเฉพาะฟิลด์ที่ไม่เปลี่ยน · ไม่ตรง → `CLIENT_ID_REUSED` code เดียว · discard ลบแถวในเครื่องเฉพาะเมื่อ server ตอบ `serverHasRow=false` | กันลบแถวที่ server ถืออยู่จริง |

## ผลที่ตามมา

* **`03_ARCHITECTURE §8` ต้องแก้คำ** — `q1` ไม่ใช่ *"แทน Drift repos"* แต่เป็น
  *"เพิ่ม ApiRepository เป็น implementation ใหม่ของ interface เดิม"*
* ทุกวันที่ทำ `q1` **ฝั่งอ่านยังใช้ต่อได้ตอนเน็ตหลุด** (ค้นสินค้า/ลูกค้าจาก Drift) แต่ **ฝั่งเขียน
  เป็น online-only จนกว่า `q2` (outbox) จะเสร็จ** — ฉบับแรกเขียนว่า "ใช้ต่อได้" รวม ๆ ซึ่งเกินจริง
  ข้อนี้ไม่กระทบร้าน เพราะ build ที่ร้านใช้อยู่ไม่มี `ApiRepository` (ไม่ cutover ในเฟส 1)
* 🔴 **`products.updatedAt` ต้องต่อสายให้เขียนจริงก่อนเริ่ม `q2`** — วันนี้แอปไม่เคยเขียนค่านี้
  มันแค่วิ่งผ่าน snapshot ไปกลับ ถ้า sync ใช้ `?updatedSince=` บน products จะพังเงียบ

## ยังไม่เคาะ

* [x] **(#55, เพิ่ม 2026-09-14 จาก #16) read-back window ของ `?updatedSince=`** — write ที่ประทับ `updated_at = now()`
      (เวลาเริ่ม transaction) แล้ว commit ช้า อาจ commit หลังจาก client เลื่อน cursor ผ่านเวลานั้นไปแล้ว → แถวนั้นไม่ถูกดึงเลย
      server แก้เรื่อง tie/ความละเอียดของ cursor แล้ว (keyset `(updated_at, id)` + `meta.nextCursor`) แต่ยังไม่เคาะว่า
      client ต้องถอย cursor ย้อนหลังกี่วินาที หรือ server ต้องเปลี่ยนวิธีประทับเวลา
      → **เคาะแล้ว 2026-09-15 (#191, เจ้าของโปรเจกต์):** cursor ของเฟส 2 = keyset นี้ **ไม่สร้าง `change_log`** ·
      client **ถอย cursor ย้อนหลัง 30 วินาที**ทุกครั้งที่ pull (แถวที่ได้ซ้ำ upsert ซ้ำได้ ไม่เสียหาย) · endpoint ส่งแถวที่ `deleted_at IS NOT NULL` (tombstone) ลงมาด้วย เครื่องซ่อน/ลบตาม
      🔴 ถอย 30 วินาทีปลอดภัยเฉพาะเมื่อ write transaction commit ภายใน 30 วินาที — **บังคับแล้วตั้งแต่ #213 (PR #215):**
      commit guard 25 วินาทีใน `TenantService.runTx` / `TenantJobRunner` + role `pos_app` `statement_timeout=25s`,
      `idle_in_transaction_session_timeout=5s` (Postgres 16 ไม่มี `transaction_timeout`) — กติกาและข้อยกเว้นอยู่ที่
      `server/README.md` *The transaction ceiling* · ช่องที่ยังเปิด: tenant import ประทับ `updated_at` ย้อนหลัง (#217)
* [x] ~~**(2026-09-15, #240 D3)** คอลัมน์ `Products.offlineOk` ใน Drift — ลบใน schema v7 หรือปล่อยไว้ไม่ใช้ → `08 §15 Q12`~~ — **เคาะ (E10): ลบ** (08 slice 16)
* [ ] cache invalidation ฝั่ง client — Drift ที่ค้างอยู่จะถือว่าหมดอายุเมื่อไหร่ (TTL? ตอน login? ตอน sync เสร็จ?)
* [ ] อ่านตอน Online อ่านจาก Drift ก่อนแล้ว refresh (stale-while-revalidate) หรือรอ server เสมอ
* [x] **ถามเจ้าของโปรเจกต์ — เคาะแล้ว 2026-09-15 (#191): ใช่ เชื่อ server เสมอ** เมื่อ server รับบิลแล้ว แอปต้องเชื่อตัวเลขของ server และทับของในเครื่อง
      เสมอไหม แม้เครื่องจะเห็นต่าง (ADR นี้ตั้งไว้ว่า "ใช่" ตามข้อ 3)
