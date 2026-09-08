# Handoff — แผนฉบับ CouchDB แทน PostgreSQL (2026-09-08)

**วันที่:** 2026-09-08 · **ผู้บันทึก:** agent (session เจ้าของโปรเจกต์) · **สถานะ:** รอคนอื่น — รออาจารย์ตอบ 5 ข้อ
**ขอบเขต:** แปลงคำสั่งปากเปล่าของอาจารย์ *"POS ควรใช้ CouchDB ไม่ใช่ Postgres"* เป็นข้อเสนอที่ตรวจแล้ว ไม่ได้แก้ `01`–`03` และไม่ได้แตะ `server/`
**ต่อจาก:** [`merge-p1-p2-lane-assignments.md`](merge-p1-p2-lane-assignments.md), [`reassign-ticket-14.md`](reassign-ticket-14.md)

## 1. ตอนนี้อยู่ตรงไหน

* commit แรก `8320299` (2026-09-08): ไฟล์ใหม่ 2 ไฟล์ + banner 3 จุด
  * `docs/Backend_design/adr/0012-couchdb-replaces-postgres.md` — สถานะ **Proposed**
  * `docs/Backend_design/06_COUCHDB_REVISION.md` — แผนทั้งชุดถ้า ADR-0012 ผ่าน (ผ่าน scrutinize รอบ 4 แล้ว)
  * banner ใน `00_INDEX.md`, `adr/README.md` (แถว 0012), `CLAUDE.md` (ย่อหน้าใหม่บน "Backend direction changed")
* commit ที่สอง (2026-09-08): banner ชี้ไป ADR-0012 ใน `00_BASICS` `01` `02` `03` `05` `00_LANE_PRIMER` `server/README`,
  แถวรอบ 4 ในตาราง `04_QA_SCRUTINY`, คำถาม 5 ข้อไว้บนสุดของ "ยังค้างอยู่" ใน `adr/README`, และ `handoff_log/INDEX.md`
* เอกสาร `01`–`03` และ `server/` **ยังเป็นฉบับ Postgres ทั้งหมด** โดยตั้งใจ — แค่มี banner
* ticket #4–#37 ทุกใบยังเขียนบนสมมติฐาน Postgres — **ประกาศ freeze ไว้ใน banner ทุกไฟล์แล้ว** แต่ยังไม่ได้ comment ใน GitHub

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

1. อ่าน design package ทั้งชุด (00–05, ADR 11 ฉบับ, issue #2–#40, `server/` ที่ merge แล้ว) — ไม่มีที่ไหนเคยพูดถึง CouchDB
2. ตรวจข้อเท็จจริง CouchDB กับเอกสารทางการ: `_bulk_docs` non-atomic (ไม่มี `all_or_nothing`), สิทธิ์อ่านระดับ db เท่านั้น,
   counter "not practical", JWT auth มีในตัว (stateless, revoke ไม่ได้), `foodb` (pub.dev) มี replicate แต่ **ไม่รองรับ Web**
3. เขียน ADR-0012 แยก "ใช้ CouchDB" เป็น 2 ความหมาย (ก สลับ DB / ข เครื่องขาย replicate ตรง) และเสนอว่า **ทำเฉพาะ ข**
4. เขียน `06` — ADR ทีละฉบับเปลี่ยนยังไง, document model, ledger, ticket ทีละใบ, งานใหม่ `c0`–`c5`, DoD ใหม่
5. scrutinize รอบ 4 ด้วย agent 2 ตัว (opus = DB/invariant, sonnet = client/ticket): ได้ blocker 5 + major 7 + minor ~8
   **ตรวจซ้ำกับโค้ด Dart ก่อนรับทุกข้อ** แล้วแก้เข้าไป — บันทึกใน `06 §9`
   * ที่ agent ตรวจว่า **ถูกอยู่แล้ว**: เลข ticket/ทีม/assignee ใน `06 §6.2` ตรง GitHub ทุกแถว

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

| ทางเลือก | เลือก | เหตุผล | ใครตัดสิน |
|---|---|---|---|
| แก้ `01`–`03` เลย vs เขียนแยกเป็น `06` + ADR Proposed | **แยก** | ยังไม่รู้ว่าอาจารย์หมายถึงแบบไหน แก้ก่อนแล้วผิดความหมาย = รื้อสองรอบ | agent (ตาม karpathy: อย่าเดาเงียบ ๆ) |
| CouchDB แบบ ก vs ข | **เสนอ ข เท่านั้น** ถ้าอาจารย์หมายถึง ก → ขอคง Postgres | ก เสีย ACID/RLS/FK แล้วไม่ได้ replication กลับมา แย่กว่า Postgres ทุกข้อ | agent เสนอ — **เจ้าของโปรเจกต์ยังไม่เคาะ** |
| สต็อก/ยอดสะสม = `_sum` view ดิบ vs persist ค่าที่มีผลจริงตอนเขียน | **persist ตอนเขียน** | รอบ 4 พิสูจน์ว่า `_sum`+clamp ตอนอ่าน ≠ Dart (หนี้ ฿500 หาย, บิลคืนครบบวมเท่าตัว) | agent หลัง scrutinize |
| liveness ของ `pos` วัดจาก `_local` checkpoint / heartbeat / Nginx `auth_request` | **`auth_request`** | ตัวเดียวที่ NestJS เห็นทุก request และปิดช่อง "retire แล้วยังเขียนได้ 15 นาที" ไปด้วย | agent หลัง scrutinize |
| CP ให้ใครออกเลข | **`pos`** (amend ADR-0007) | CP เป็น `pos`-only และต้องทำออฟไลน์ได้ | agent เสนอ — ต้องแก้ ADR-0007 ถ้ารับ |
| `customer`/`mechanic` ให้ `pos` เขียนได้ไหม | **ได้** (2 writer, LWW by `updatedAt`) | เพิ่มลูกค้าหน้าเคาน์เตอร์ตอนออฟไลน์เป็นงานประจำวัน | agent หลัง scrutinize |

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

* **"invariant ทุกตัวทำเป็น reduce view ได้"** — ผิด 3 จุด (B1/B2/B4 ใน `06 §9.1`) เพราะ Dart clamp ต่อ operation
  และ reversal ของช่างอ่านยอดสะสม ณ เวลาคืน · อย่ากลับไปเสนอแบบนั้นอีก
* **heartbeat `POST /devices/me/seen`** (แก้ครั้งแรก) — ยังหลวม (เครื่องยิง heartbeat ได้แต่ replicate ไม่ได้)
  ถูกแทนด้วย `auth_request`
* **`_local/<replid>` เป็น liveness signal** — ไม่ขยับตอน idle, ไม่โผล่ใน `_changes`
* **import snapshot 1:1** — ต้องมี opening balance + คำนวณ delta ใหม่จาก `stockAfter` + replay สูตร Dart ตามเวลา

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

* ❌ อาจารย์หมายถึงแบบ ข (สมมติฐาน S1 ใน `06 §0`) — **ไม่มีข้อความยืนยัน**
* ❌ Flutter **Web** replicate กับ CouchDB ได้ — ยังไม่มีใครลอง (`c0` คือการพิสูจน์ · `foodb` ไม่รองรับ Web)
* ❌ ข้อกำหนดคอร์ส TypeORM/pooling/PG replication ถูกยกเลิก
* ❌ initial replication ยาวกว่า 15 นาทีชน token หมดอายุ (m3) — ยังไม่วัด
* ✅ ยืนยันแล้ว: CouchDB ไม่มี multi-doc transaction, สิทธิ์อ่านระดับ db, JWT handler มีจริง (เอกสารทางการ)
* ✅ ยืนยันแล้ว: blocker B1/B2/B4/B5 ตรงกับโค้ด Dart จริง (`returns_repository.dart:123,167-169,197`,
  `products_repository.dart:138-149`, `mechanics_repository.dart:105`)

## 6. ก้าวถัดไป (เรียงลำดับ)

1. เจ้าของโปรเจกต์อ่าน ADR-0012 แล้ว **ส่งคำถาม 5 ข้อท้าย ADR ให้อาจารย์เป็นข้อความ** — รอคำตอบ
2. ระหว่างรอ: comment ใน issue #2 ว่า #4–#37 freeze ชั่วคราว + ลิงก์ ADR-0012 (ยังไม่ได้ทำ)
3. ถ้าอาจารย์ตอบ **ข**: เปิด ticket `c0` (spike, 2 สัปดาห์ hard cap, team/1+2) — ก่อนอย่างอื่นทั้งหมด
4. `c0` ผ่าน → ADR-0012 เป็น Accepted, amend ADR-0007 (CP) + ADR-0005 (restore ทำได้), เขียน `01`/`02`/`03` ใหม่ตาม `06`,
   ตัด ticket `c1`–`c5` + `c3.1`–`c3.3`, re-scope #4–#37 ตามตาราง `06 §6.2`, ปิด #11 ก่อน `c3.1`
5. `c0` ไม่ผ่าน / อาจารย์ตอบ **ก**: กลับไปเสนอ Postgres พร้อมตาราง "ราคาที่ต้องจ่าย" ใน ADR-0012
6. ~~commit งานรอบนี้~~ — ทำแล้ว (`8320299` + commit banner) · ยังไม่ push

## 7. ข้อควรระวัง

* **ห้ามแตะ `server/` และห้ามหยิบ #4–#37** จนกว่า ADR-0012 จะเคาะทางใดทางหนึ่ง — ทุกบรรทัดที่เขียนตอนนี้เสี่ยงเป็นงานทิ้ง
* แผน ข **พึ่ง ADR-0004 หนักมาก** (writer เดียว = ยอดสะสมถูก) — ถ้าใครเสนอให้มี `pos` 2 เครื่อง แผนนี้ล้มทั้งแผน
* "ledger proof" **พิสูจน์น้อยกว่า** "200 แย่ง 50" — ห้ามเขียนในรายงานส่งอาจารย์ว่าเทียบเท่า (`06 §7` บรรทัดแรก)
* `06 §6.1` งาน `c0` ทาง (ค) เคยประเมิน "600–900 บรรทัด" — **ต่ำเกินจริง** อย่าเอาตัวเลขนั้นไปวางแผน

## 8. อ้างอิง

* `docs/Backend_design/adr/0012-couchdb-replaces-postgres.md` · `docs/Backend_design/06_COUCHDB_REVISION.md`
* เอกสาร CouchDB ที่ใช้ตรวจ: `docs.couchdb.org/en/stable/` → `api/database/bulk-api`, `intro/security`,
  `best-practices/documents`, `api/server/authn` · `pub.dev/packages/foodb`
* โค้ด Dart ที่ใช้พิสูจน์ blocker: `frontend/lib/data/repositories/{returns,products,mechanics,purchase_orders,quotes}_repository.dart`
* คนที่ต้องถาม: อาจารย์ (5 ข้อ), เจ้าของร้าน (รูปแบบใบเสร็จ — ADR-0007 ยังรอ)
