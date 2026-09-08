# ADR-0012 — เปลี่ยนฐานข้อมูลตัวจริงจาก PostgreSQL เป็น CouchDB

* **สถานะ:** 🟡 **Proposed — 2026-09-08** รอเจ้าของโปรเจกต์ + อาจารย์เคาะ (ยังไม่ Accepted)
* **ผู้ตัดสิน:** เจ้าของโปรเจกต์ (หลังได้คำตอบ 5 ข้อจากอาจารย์ — ดูท้ายไฟล์)
* **ที่มา:** อาจารย์แจ้ง (2026-09-08, ปากเปล่า ผ่านเจ้าของโปรเจกต์) ว่า *"POS ควรใช้ CouchDB
  ไม่ใช่ PostgreSQL"* — ยังไม่มีข้อความเป็นลายลักษณ์อักษร และยังไม่รู้ว่าหมายถึงแบบไหนใน 2 แบบด้านล่าง
* **แทนที่ (ถ้า Accepted):** `01_DATABASE.md` ทั้ง §2 §5 §6 §8 (DDL, index, RLS), ADR-0010,
  ข้อสรุป `03_ARCHITECTURE.md §7` (ปัจจุบันเขียนว่า *"เลือก C (Hybrid) + T1"* — ข้อเสนอรอบ 3 ที่จะแก้เป็น
  *"A + T1"* ก็ยัง 🟡 ไม่ได้ลงเอกสาร `04` ข้อ 23), และงาน #15 ที่ merge แล้ว
* **เกี่ยวข้อง:** ADR-0004 (เหตุผลที่ CouchDB ใช้กับ POS นี้ได้เลย), ADR-0007, ADR-0005,
  [`06_COUCHDB_REVISION.md`](../06_COUCHDB_REVISION.md) (แผนที่แก้แล้วทั้งชุด)

## บริบท — ทำไมอาจารย์ถึงพูดแบบนี้ และมันจริงแค่ไหน

แอปนี้ **เกิดมาเป็น offline-first** (`03 §1`) และเอกสารทั้งชุดใช้เวลา 3 รอบ scrutinize ไปกับคำถามเดียว:
*"เน็ตล่มแล้วขายยังไง"* คำตอบที่ได้คือ Architecture C (outbox + `offlineOk` + reconciliation) ซึ่งรอบ 3
สรุปเองว่า **ยังไม่มี DDL, ยังไม่มีเจ้าของ offline write path, และ B ตายเพราะต้องสร้าง sync engine เอง**
(`04 §รอบ 3`)

CouchDB คือฐานข้อมูลที่ **sync engine เป็นของที่มากับตัว** — replication protocol, `_changes` feed,
revision tree, tombstone, checkpoint, conflict flag ทั้งหมดที่ `01 §5.1` ต้องออกแบบเองใน `change_log`
(และเจอบั๊ก `BIGSERIAL` gap) มีให้แล้ว นี่คือเหตุผลเดียวที่ "CouchDB เหมาะกับ POS": **มันแก้ปัญหาที่ทีมยัง
แก้ไม่จบ** ไม่ใช่เพราะมันเป็น document store

**แต่ราคาที่ต้องจ่าย (ตรวจกับเอกสาร CouchDB แล้ว 2026-09-08):**

| สิ่งที่ design ปัจจุบันพึ่ง | CouchDB ให้ไหม | ที่มา |
|---|---|---|
| transaction ข้าม 5 ตาราง (`01 §7.1`) | ❌ **ไม่มี** — `_bulk_docs` เป็น non-atomic, `all_or_nothing` ถูกถอดตั้งแต่ 2.x · "the only transaction boundary is a single update to a single document" | docs `api/database/bulk-api` |
| `SELECT … FOR UPDATE`, row lock, `UPDATE … WHERE stock >= qty` | ❌ มีแค่ MVCC ต่อ document (`_rev` ไม่ตรง → 409) | docs `intro/overview` |
| FK / CHECK / UNIQUE | ❌ มีแค่ `_id` ที่ unique และ `validate_doc_update` (ตรวจ doc เดียว ไม่เห็น doc อื่น) | docs |
| RLS / แยกร้านระดับแถว (T1) | ❌ สิทธิ์อ่านมีแค่ระดับ **database** (`_security.members` อ่านได้ทุก doc) → **T1 ใช้ไม่ได้ ต้อง database-per-tenant (T3)** | docs `intro/security` |
| auto-increment / counter (ADR-0007) | ❌ เอกสารบอกตรง ๆ ว่า "not practical" — ต้อง CAS บน counter doc หรือให้เครื่องออกเอง | docs `best-practices/documents` |
| `NUMERIC(12,2)` | ❌ JSON number = double | — |
| `pg_trgm` ค้นไทย | ❌ Mango `$regex` ไม่ใช้ index — ค้นต้องอยู่ฝั่ง client (ซึ่งวันนี้ก็เป็นแบบนั้นอยู่แล้ว) | — |
| JWT stateless (โจทย์อาจารย์) | ✅ CouchDB 3.x มี `jwt_authentication_handler` (HMAC/RSA, `_couchdb.roles`) — **แต่ revoke ก่อนหมดอายุไม่ได้** (สอดคล้อง ADR-0009 ที่ไม่มี denylist อยู่แล้ว) | docs `api/server/authn` |
| replication ลงเครื่อง Flutter | 🟡 **จุดเสี่ยงที่สุด** — ไม่มี PouchDB สำหรับ Flutter; `foodb` (pub.dev, 9 likes, v0.13.6, มี replicate + ObjectBox adapter) รองรับ Android/iOS/desktop **ไม่รองรับ Web** — แต่ร้านรันแอปเป็น **Flutter Web** | pub.dev |

## สองความหมายของ "ใช้ CouchDB" — ต้องรู้ก่อนว่าอาจารย์หมายถึงแบบไหน

| | **แบบ ก — สลับ DB หลัง server** | **แบบ ข — CouchDB-native (เครื่องขาย replicate ตรง)** |
|---|---|---|
| ใครถือข้อมูลตัวจริง | CouchDB บน server, NestJS เขียนคนเดียว (Architecture A เดิม) | CouchDB บน server **และ** replica ในเครื่อง `pos` (Architecture B ที่ sync engine มากับ DB) |
| client เปลี่ยนไหม | ไม่ — ยังยิง REST ผ่าน `ApiRepository` (ADR-0010) | **เปลี่ยน data layer ทั้งชั้น** — Drift → doc store ที่ replicate ได้ |
| ตัดสต็อกยังไง | server อ่าน product doc → เช็ค → เขียนด้วย `_rev` (CAS) ทีละตัว, ชนแล้ว retry, **บิลหลายบรรทัดไม่ atomic** ต้องเขียน compensation เอง | **ledger**: sale doc เป็น append-only, `stock` = `_sum(delta)` จาก view ไม่ใช่ field บน product · เครื่อง `pos` เช็คสต็อกจาก replica ในเครื่อง (single writer ตาม ADR-0004) |
| เน็ตล่มขายได้ไหม | ❌ ไม่ได้ (เหมือน A) | ✅ ได้ทุกอย่างที่ `pos` ทำได้ (ขาย/คืน/กะ/พักบิล) |
| ได้อะไรจาก CouchDB | **แทบไม่ได้อะไร** — เสีย ACID/RLS/FK ไปโดยไม่ได้ replication กลับมา แย่กว่า Postgres ในทุกข้อที่ `01 §7` ต้องการ | ได้สิ่งเดียวที่ทีมยังไม่มี: offline-first + sync ที่ไม่ต้องเขียนเอง |
| ตรงกับที่อาจารย์น่าจะหมายถึง | ไม่น่าใช่ — ไม่มีเหตุผลทางเทคนิคให้แนะนำ | **น่าจะใช่** — เป็นเหตุผลเดียวที่คนพูดว่า "CouchDB เหมาะกับ POS" |

**ข้อเสนอของ ADR นี้: ถ้าจะใช้ CouchDB ต้องเป็นแบบ ข เท่านั้น** — และถ้าอาจารย์หมายถึงแบบ ก
ทีมควรกลับไปอธิบายว่ามันแย่กว่าของเดิมในทุกมิติ แล้วขอคง PostgreSQL

## การตัดสินใจ (Proposed — แบบ ข)

1. **CouchDB 3.x เป็นข้อมูลตัวจริง, database-per-tenant (`t_<code>`)** — `_security.members.roles =
   ["tenant:<tid>"]`, JWT ที่ NestJS ออกใส่ claim `_couchdb.roles` ตัวเดียวกัน CouchDB ตรวจเองด้วย
   HMAC secret ร่วม → T1 + RLS + `BYPASSRLS` trap ทั้งชุดหายไป, ADR-0002 เหลือแค่ "server admin
   credential ห้ามอยู่ใน path ของร้าน"
2. **เครื่อง `pos` (ADR-0004) replicate สองทางกับ db ของร้านโดยตรง** และเป็น **writer เดียว** ของ
   doc ประเภท `sale` / `return` / `credit_payment` / `shift` / `drawer_entry` / `parked` —
   เขียนออฟไลน์ได้ทั้งหมด เช็ค invariant (`สต็อกไม่พอ`, คืนเกิน, ลิ้นชักปิดแล้ว) จาก replica ในเครื่อง
   **โค้ด Dart ใน `frontend/lib/data/repositories/` คือตัว port ไม่ใช่แค่ reference อีกต่อไป**
3. **เครื่อง `backoffice` ไม่ replicate — ยิง NestJS เท่านั้น** (ออนไลน์เสมออยู่แล้ว ADR-0004) และ NestJS
   เป็น writer เดียวของ `product` / `category` / `supplier` / `purchase_order` / `quote` /
   `movement(opening|receive|adjustment-*)` / `settings` · `customer` / `mechanic` เขียนได้ทั้งสองฝั่ง
   (ไม่ถือเงิน — ยอดสะสมอยู่ใน view) → doc เงินมี writer เดียว · conflict เชิงธุรกิจที่เหลือมีจุดเดียวคือ
   **adjustment-out / receive ระหว่าง pos ออฟไลน์** → `409 POS_OFFLINE` โดยวัด liveness จาก Nginx
   `auth_request` → NestJS ทุก request บน `/couch/*` (ซึ่งทำให้ revoke เครื่องมีผลทันที ไม่ต้องรอ JWT หมดอายุ)
   (ดู `06 §4.3`, `§5`)
4. **สต็อก = ledger ไม่ใช่ field** — `stock(product)` = `_sum(effectiveDelta)` ของ `movement`
   (รวม `opening` ที่ import สร้าง) + `sale` **ทุกใบรวม voided** + `return` (view `stock/by_product`),
   product doc ไม่มี `stock` · ยอดสะสม `customers.points/totalSpend` และ `mechanics.credit_balance/total_*`
   = `_sum` ของ **ค่าที่มีผลจริงซึ่ง `pos` คำนวณด้วยสูตร Dart เดิมแล้ว persist ลง doc ตอนเขียน**
   (`creditApplied`, `pointsReversed`, …) — **ไม่ใช่** `_sum` ของยอดดิบแล้ว clamp ตอนอ่าน (scrutinize รอบ 4
   พิสูจน์ว่าให้ผลต่างจาก Dart: `06 §4.4`) → doc ธุรกรรม **append-only** = ไม่มี replication conflict บน
   path เงิน ยกเว้น `shift` กรณี retire กลางกะ (มีกติกาใน `06 §3`)
5. **เลขเอกสาร (ADR-0007) กติกา "เฟส 2" กลายเป็นกติกาตั้งแต่วันแรก + amend 1 ข้อ** — `pos` ออก RC/CN
   **และ CP** เองจาก counter ในเครื่อง (ADR-0007 ปัจจุบันให้ server ออก CP — ต้องแก้ เพราะ CP เป็น `pos`-only
   และต้องทำออฟไลน์ได้), uniqueness บังคับด้วย `_id = "sale:RC01-2569-09-0042"`; server ออก PO/QT ด้วย
   CAS บน counter doc (`counter:po:2569-09`) retry เมื่อ 409
6. **เงินเก็บเป็นสตางค์ integer ในเอกสาร** (`totalSatang`) แปลงเป็น double ที่ชั้น repository —
   `_sum` บน double สะสม error, และ `round2` parity กับใบเสร็จเก่ายังทำที่ชั้น repository ได้เหมือนเดิม
   *(ข้อนี้ต่อรองได้ — ดู `06 §4.6`)*
7. **NestJS + Nginx + Redis ×2 + BullMQ + Bull-Board ยังอยู่ครบ** แต่เปลี่ยนบทบาท: NestJS = auth +
   backoffice API + provisioning + `_changes` consumer (reconciliation, รายงาน, export) · Redis-cache =
   รายงาน/`bootstrap` · BullMQ = export/import/reconcile · Nginx = LB NestJS ×3 **และ** reverse proxy
   `/couch/*` ไปยัง CouchDB (ห้ามเปิด CouchDB ตรงออกอินเทอร์เน็ต)
8. **TypeORM ออก** — ใช้ `nano` (official client) · migration = **design document versioning**
   (`_design/stock`, `_design/reports`, `_design/validate`) apply ทุก db ตอน deploy ผ่าน job `migrate`
   เดิมของ compose (#14) ไม่ใช่ตอน boot

## ทางเลือกที่ไม่เอา

| | ทำไมไม่เอา |
|---|---|
| **แบบ ก (สลับ DB เฉย ๆ)** | เสีย transaction/RLS/FK แล้วไม่ได้ replication กลับมา — บิลหลายบรรทัดต้องเขียน saga/compensation เอง ซึ่ง `01 §7.1` ทำได้ใน `BEGIN…COMMIT` บรรทัดเดียว |
| **Postgres ตัวจริง + CouchDB เป็นชั้น sync** | 2 source of truth = ต้องเขียน reconciler สองทาง — ซับซ้อนกว่าทั้ง B และ C รวมกัน |
| **CouchDB partitioned db เดียวทุกร้าน (`<tid>:<id>`)** | สิทธิ์อ่านเป็นระดับ db — ร้านหนึ่ง replicate ได้ทั้ง db = เห็นทุกร้าน ผิด PDPA ทันที |
| **ให้ `pos` ก็ยิง NestJS (เก็บ replication ไว้แค่ pull)** | ก็คือ Architecture C ที่ replication ใช้แทน `?updatedSince=` — offline write ยังไม่มีเจ้าของเหมือนเดิม (`04` ข้อ 26) |

## ผลที่ตามมา (ถ้า Accepted)

* งานที่ **ทิ้ง**: #15 (migration 27 ตาราง + RLS + test 305 บรรทัด — merge แล้ว), `01 §5/§6/§8` ทั้งหมด,
  `q1` ApiRepository (ADR-0010) สำหรับเครื่อง `pos`
* งานที่ **เก็บได้**: #14 compose stack (สลับ service `postgres` → `couchdb`), #38 CI (สลับ service เดียวกัน),
  Nginx/health/envelope/logger ทั้งหมด, seed 5 หมวด (กลายเป็น 5 docs), `02` ฝั่ง backoffice + admin plane,
  ADR-0001/0003/0004/0006/0008/0009/0011 (แก้ถ้อยคำ), **ADR-0005 ดีขึ้น** — restore รายร้าน =
  replicate db กลับ ทำได้จริงแล้ว ข้อ "ไม่รับปาก restore" ควรถอน
* งานที่ **เกิดใหม่**: spike replication client บน Flutter Web (🔴 ต้องผ่านก่อนทุกอย่าง), design docs +
  views, provisioning db-per-tenant, `_changes` consumer, ledger model ฝั่ง client, reconciliation queue
  — รายการเต็มใน `06 §6`
* **เกณฑ์ปิดเฟส 1 ต้องเขียนใหม่** — *"ยิง `POST /sales` 200 ครั้งพร้อมกันบนสินค้า 50 ชิ้น → 50 บิล"*
  พิสูจน์ไม่ได้อีกต่อไป เพราะ `POST /sales` ไม่มีแล้ว (pos เขียน local) — แทนด้วย ledger proof ใน `06 §7`
* ข้อกำหนดคอร์สที่หายไปและต้องให้อาจารย์ยืนยันว่ายอม: TypeORM, connection pooling, PG streaming replication,
  `SELECT FOR UPDATE` demo — แทนด้วย CouchDB cluster (`n=3`) + replication + `_changes`

## ยังไม่เคาะ — ต้องถามอาจารย์ (5 ข้อ) และเจ้าของโปรเจกต์

**ถามอาจารย์ (ควรได้คำตอบเป็นข้อความ ไม่ใช่ปากเปล่า):**

1. หมายถึง **แบบ ก หรือ ข** — เครื่องหน้าร้าน replicate กับ CouchDB ตรง (offline-first) หรือแค่ server เก็บลง CouchDB
2. requirement เดิม **TypeORM / PostgreSQL / connection pooling / PG replication** ยังนับคะแนนไหม ถ้าไม่ อะไรมาแทน
3. เกณฑ์ **k6 "200 คนแย่งซื้อ 50 ชิ้น"** ยังต้องส่งแบบเดิมไหม หรือรับ ledger proof (`06 §7`) แทนได้
4. **database-per-tenant** ยอมรับได้ไหม (เป็นทางเดียวเมื่อ client replicate ตรง) — โจทย์ "หลายร้านบน database ชุดเดียว" เปลี่ยนเป็น "หลายร้านบน CouchDB cluster เดียว"
5. ยังต้องรองรับ **Flutter Web** ที่ร้านใช้อยู่ไหม — ถ้าใช่ต้องยอมรับผล spike (`06 §6` งาน `c0`) ว่าอาจต้องใช้ PouchDB ผ่าน JS interop

**ถามเจ้าของโปรเจกต์:**

* [ ] ยอมทิ้ง #15 (merge แล้ว 2026-09-07) ไหม — หรือรอคำตอบข้อ 1 ก่อน (แนะนำ: **รอ** ห้ามแตะ `server/` จนกว่าจะได้ข้อความจากอาจารย์)
* [ ] เงินเป็นสตางค์ integer (ข้อ 6) หรือคง double + `round2` เหมือน Drift
* [ ] ADR-0005 จะถอนข้อ "ไม่รับปาก restore รายร้าน" ไหม (CouchDB ทำให้ทำได้ถูก)
