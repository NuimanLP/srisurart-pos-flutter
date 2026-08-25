# Srisurart POS — Backend Design Package

เอกสารชุดนี้เขียนให้ **ทีม backend** ใช้เป็น spec ตั้งต้น สำหรับย้ายแอป POS ร้านอะไหล่
จากเดิมที่เป็น **offline-only (Drift/SQLite บนเครื่อง)** ไปเป็น **client + backend**
และขยาย scope ให้รองรับ **ร้านอะไหล่หลายร้าน (multi-tenant)** ตามที่อาจารย์ต้องการ

> **📚 ยังไม่เคยทำ backend มาก่อน / อ่านแล้วงง → เริ่มที่ [`00_BASICS.md`](00_BASICS.md)**
> อธิบายทุกคำศัพท์ที่ใช้ในเอกสารชุดนี้ โดยยกตัวอย่างจากร้านอะไหล่ของเราเอง
>
> สรุปสั้น ๆ สำหรับคนที่ไม่มีเวลาอ่านหมด: อ่าน [`03_ARCHITECTURE.md` §7 ข้อสรุป](03_ARCHITECTURE.md#7-สรุป--แนะนำอะไร)
> แล้วดู [`01_DATABASE.md` §3 ER Diagram](01_DATABASE.md#3-er-diagram)

---

## เอกสารในชุดนี้

| ไฟล์ | เนื้อหา | ใครควรอ่าน |
|---|---|---|
| ⭐ [`00_BASICS.md`](00_BASICS.md) | **ปูพื้นฐาน — อ่านอันนี้ก่อน** ถ้ายังไม่เคยทำ backend: client/server, API, SQL, transaction, multi-tenant, JWT, cache, queue, scaling, offline sync + glossary ศัพท์ทั้งหมด อธิบายด้วยตัวอย่างจากร้านเราเอง | **ทุกคนที่อ่านเอกสารอื่นแล้วงง** |
| [`01_DATABASE.md`](01_DATABASE.md) | ตารางทั้งหมด (20 เดิม + 7 ใหม่ = 27 ตาราง), ER diagram, DDL เต็ม, index, constraint, business invariant ที่ DB/backend ต้องบังคับ, แผนการ migrate ข้อมูลเดิม | **คนทำ DB / TypeORM entities** |
| [`02_API_SCREENS.md`](02_API_SCREENS.md) | 11 หน้าจอ → ยิง API อะไรบ้าง (ตารางต่อหน้าจอ), API catalogue เต็ม, request/response ตัวอย่าง, จุดที่ต้อง cache / ต้องเข้า queue / ต้อง idempotent | **คนทำ NestJS modules + คนทำ Flutter client** |
| [`03_ARCHITECTURE.md`](03_ARCHITECTURE.md) | 3 architecture ให้เลือก (พร้อม mermaid + ข้อดี/ข้อเสีย/ต้นทุน), 3 ทางเลือกของ multi-tenant model, ตารางเปรียบเทียบ, ข้อเสนอสุดท้าย | **ทุกคน + อาจารย์** |
| [`04_QA_SCRUTINY.md`](04_QA_SCRUTINY.md) | บันทึกการถกเถียงของ 3 agent ที่ review design นี้ (Q&A สั้น ๆ) + ข้อสรุปที่แก้เข้าไปในเอกสารแล้ว | คนที่อยากรู้ว่า "ทำไมถึงตัดสินใจแบบนี้" |

---

## บริบทที่ใช้ออกแบบ (อ่านมาจากไหน)

1. **แอปปัจจุบัน** — `CONTRACT.md` ของ repo นี้: 20 Drift tables, 13 repositories, 11 screens
   (ทั้งหมดเป็น port ของ `pos/db.js` จากแอป JS เดิม — business rule ทุกข้ออยู่ในนั้น)
2. **คอร์ส backend ที่ทีมเรียนมา** — `docs/Summary_backend/` (Backend01–06):
   Docker/monolith-first, NestJS modular + DI, TypeORM migrations/transactions/locking,
   Redis cache-aside + invalidation, BullMQ + idempotency, Nginx LB + PG replication + observability
3. **Assignment ของอาจารย์** — *Flash Sale System*: บังคับ Nginx LB → NestJS ≥3 instances,
   PostgreSQL + TypeORM + connection pooling, Redis caching, BullMQ, **JWT stateless (ห้าม in-memory session)**,
   Bull-Board dashboard, k6 load test, 1-click `docker-compose.yml`
4. **ข้อกำหนดใหม่** — multi-tenant: รองรับร้านอะไหล่หลายร้านบน database ชุดเดียว

---

## ข้อเสนอหลังผ่าน review แล้ว

เอกสาร 01–03 ถูก agent 3 ตัว scrutinize และแก้ตามผลถกเถียงเรียบร้อย
(รายละเอียดใน [`04_QA_SCRUTINY.md`](04_QA_SCRUTINY.md)) ข้อสรุปคือ:

* **Architecture C (Hybrid) + T1 (shared schema + RLS)** ทำ 2 เฟส — เฟส 1 เท่ากับ Architecture A เป๊ะ
* **เฟส 1 ไม่ cutover ร้าน** — ส่งอาจารย์บน tenant สาธิต ร้านยังใช้ Drift build เดิมต่อ
  จึงไม่มีใครต้องรับความเสี่ยง "เน็ตล่มขายไม่ได้"
* **ทิ้งกลไก stock lease** ใช้ *scarcity rule* (`offlineOk`) แทน — ไม่เพิ่ม state ฝั่ง server เลย
* **`stock` = ของบนชั้นเท่านั้น** ห้ามมีความหมายที่สอง

## สิ่งที่ยัง "ตัดสินใจแทนไม่ได้" — ต้องให้คนเคาะ

1. **รูปแบบเลขที่ใบเสร็จ** — คงของเดิม (`RC…`) หรือเปลี่ยนเป็นเลขเรียงต่อเครื่อง?
   *เปลี่ยน = ใบเสร็จหน้าตาเปลี่ยน ต้องถามเจ้าของร้าน*
   (ดู [`01_DATABASE.md` §7.2](01_DATABASE.md#72-เลขเอกสาร-document-numbers))
2. **เกณฑ์ `offlineOk`** — `stock ≥ max(5, 3×เฉลี่ยต่อบิล)` เป็นแค่ข้อเสนอ ต้องดูข้อมูลขายจริงก่อนตั้งค่า
3. **ข้อความไทยของ error ใหม่ 4 ตัว** — ไม่มีใน `db.js` ห้ามแต่งเอง ต้องให้คนหน้าร้านเลือกคำ
   (ดู [`02_API_SCREENS.md` §8.1](02_API_SCREENS.md#81-error-ที่เป็น-ของใหม่-ไม่มีใน-dbjs--ห้ามแต่งข้อความไทยเอง))
4. **จะ cutover ร้านจริงเมื่อไหร่** — ข้อเสนอคือหลังเฟส 2 แต่เป็นการตัดสินใจทางธุรกิจ

---

*อัปเดตล่าสุด: 2026-08-25*
