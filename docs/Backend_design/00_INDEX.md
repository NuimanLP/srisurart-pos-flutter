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
| [`01_DATABASE.md`](01_DATABASE.md) | ตารางทั้งหมด (20 เดิม + 8 ใหม่ = 28 ตาราง), ER diagram, DDL เต็ม, index, constraint, business invariant ที่ DB/backend ต้องบังคับ, แผนการ migrate ข้อมูลเดิม | **คนทำ DB / TypeORM entities** |
| [`02_API_SCREENS.md`](02_API_SCREENS.md) | 11 หน้าจอ → ยิง API อะไรบ้าง (ตารางต่อหน้าจอ), API catalogue เต็ม, request/response ตัวอย่าง, จุดที่ต้อง cache / ต้องเข้า queue / ต้อง idempotent | **คนทำ NestJS modules + คนทำ Flutter client** |
| [`03_ARCHITECTURE.md`](03_ARCHITECTURE.md) | 3 architecture ให้เลือก (พร้อม mermaid + ข้อดี/ข้อเสีย/ต้นทุน), 3 ทางเลือกของ multi-tenant model, ตารางเปรียบเทียบ, ข้อเสนอสุดท้าย | **ทุกคน + อาจารย์** |
| [`04_QA_SCRUTINY.md`](04_QA_SCRUTINY.md) | บันทึกการถกเถียงของ 3 agent ที่ review design นี้ (Q&A สั้น ๆ) + ข้อสรุปที่แก้เข้าไปในเอกสารแล้ว | คนที่อยากรู้ว่า "ทำไมถึงตัดสินใจแบบนี้" |
| ⭐ [`adr/`](adr/README.md) | **บันทึกการตัดสินใจ (ADR) — 1 ไฟล์ = 1 การตัดสินใจ** ครอบคลุมเรื่องที่เอกสาร 01–03 ยังไม่ได้ตอบ: การสร้างร้านใหม่, admin plane, สถานะร้าน, บทบาทเครื่อง, export/restore, rate limit, เลขที่ใบเสร็จ, ต้นทุน ณ วันขาย, อายุ JWT, cache ฝั่ง client, monorepo | ทุกคนก่อนเริ่ม implement |

---

## ⚠️ แผนเดิม (Supabase) — ถูกลบออกจาก repo แล้ว

repo นี้เคยมีแผน backend อีกฉบับ `docs/BACKEND_DEPLOYMENT.md` (2026-07-13) + `docs/PLAN.md`
ซึ่งตัดสินใจ**ตรงข้าม**กับเอกสารชุดนี้ **ทั้งสองไฟล์ถูกลบใน `ec24f79` และไม่เอากลับมา**
(เคาะ 2026-09-04) — ถ้าต้องการอ่านข้อความเดิม ให้ดูจาก git history

| ประเด็น | แผนเดิม (ลบแล้ว) | ชุดนี้ (2026-08-25 →) |
|---|---|---|
| ใครเป็น backend | **Supabase (BaaS)** — ไม่มี server ของตัวเอง | **NestJS ที่เราเขียนเอง** + PostgreSQL + Redis |
| ข้อมูลตัวจริงอยู่ที่ไหน | **Drift ในเครื่อง** (cloud = backup เฉย ๆ) | **PostgreSQL บน server** (เครื่องเก็บเป็น cache — [ADR-0010](adr/0010-client-write-through-cache.md)) |
| กฎธุรกิจอยู่ที่ไหน | **ใน Dart repositories เท่านั้น** | **ย้ายไปฝั่ง server** (transaction + ตัดสต็อก) |
| รองรับหลายร้าน | ไม่ได้ออกแบบไว้ | **multi-tenant ตั้งแต่ schema** |

**ทำไมถึงเปลี่ยน:** ไม่ใช่เพราะแผนเดิมผิด แต่เพราะ**โจทย์เปลี่ยน** — อาจารย์กำหนดสแตก
(NestJS + Postgres + Redis + BullMQ + Nginx) และเพิ่มโจทย์ **multi-tenant** ซึ่งทำบน
Supabase-only ไม่ได้ตามที่แผนเดิมวางไว้ **ถือว่าทิ้ง Supabase แล้ว**

> 🔴 **ผลข้างเคียงที่ต้องรู้:** §3 ของไฟล์เดิม (build Flutter Web ขึ้นเครื่องร้าน, Android/iOS)
> เป็นส่วนเดียวที่ยังไม่ถูกแทน **แต่ถูกลบไปด้วย** → ตอนนี้ **deployment/hosting ไม่มีเอกสารเจ้าของ**
> เรื่อง host อยู่ใน [`03_ARCHITECTURE.md §8`](03_ARCHITECTURE.md#8-แผนลงมือ) ท้ายหัวข้อ
> "สิ่งที่ห้ามลืมตอน deploy" เป็นการชั่วคราว

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

> **อัปเดต 2026-09-04 — ปิดไป 3 ข้อจากการ grill รอบล่าสุด** ดู [`adr/`](adr/README.md)
> ทุกข้อที่ปิดแล้วยังมีหัวข้อ "ยังไม่เคาะ" ของตัวเองใน ADR ที่เกี่ยวข้อง — อย่าอ่านว่าจบสนิท

| # | เรื่อง | สถานะ |
|---|---|---|
| 1 | **รูปแบบเลขที่ใบเสร็จ** | ✅ ปิด — [ADR-0007](adr/0007-receipt-numbering.md): `RC01-2569-08-0042` เรียงต่อเครื่อง รีเซ็ตรายเดือน<br/>⚠️ ยังต้องให้เจ้าของร้านเห็นใบเสร็จตัวอย่างก่อนพิมพ์ใบแรก |
| 2 | **เกณฑ์ `offlineOk`** | 🔴 ยังค้าง — `stock ≥ max(5, 3×เฉลี่ยต่อบิล)` เป็นแค่ข้อเสนอ **ต้องคำนวณจากไฟล์ backup จริงก่อนงาน `q2`** |
| 3 | **ข้อความไทยของ error ใหม่ 7 ตัว** | 🟡 **ร่างแล้ว** ใน [`02_API_SCREENS §8.1`](02_API_SCREENS.md#81-error-ที่เป็น-ของใหม่-ไม่มีใน-dbjs) — agent เป็นคนร่าง เจ้าของโปรเจกต์รับไว้เพื่อไม่ block งาน<br/>🔴 สามตัวที่ขึ้นหน้าร้าน (`DEVICE_ROLE_FORBIDDEN` / `TENANT_SUSPENDED` / `OFFLINE_NOT_ALLOWED`) ยังต้องให้คนขายเลือกคำ |
| 4 | **จะ cutover ร้านจริงเมื่อไหร่** | ✅ ปิด (2026-09-04) — **หลังเฟส 2 ตามแผน ไม่ตัด scope** และไม่ผูกกับกำหนดส่ง ใช้ checklist เรียงลำดับแทน |
| 5 | **จะ provision tenant ใหม่ยังไง** | ✅ ปิด — [ADR-0001](adr/0001-tenant-provisioning.md): platform admin สร้างให้ ยังไม่ทำ self-service signup |
| 6 | **กี่เครื่องต่อร้าน** | ✅ ปิด — [ADR-0004](adr/0004-device-roles.md): `pos` 1 เครื่อง + `backoffice` กี่เครื่องก็ได้ |
| 7 | **production host** | 🔴 ใหม่ — เฟส 1 รันบน VM คณะเพื่อ**สาธิตเท่านั้น** ต้องเลือกเครื่องจริงก่อนงาน `q4` |
| 8 | **แบ่ง Lane B / Lane C** | 🔴 ใหม่ — Lane A (sales+returns) เจ้าของโปรเจกต์รับแล้ว อีกสองคนยังไม่แบ่ง |

### ✅ เอกสาร 01–03 ถูก propagate ตาม ADR แล้ว
รายการว่าแก้อะไรไปบ้างอยู่ใน [`adr/README.md`](adr/README.md) — และกติกาที่ใช้ตัดสินคือ
**เอกสารขัดกับ ADR → ยึด ADR**

---

*อัปเดตล่าสุด: 2026-09-04 (grill รอบ 2) — ADR-0010 (client write-through cache) + ADR-0011 (monorepo),
ปิดเรื่อง cutover/scope/ข้อความไทย, เปิดข้อค้างใหม่ 2 ข้อ (production host, แบ่ง lane)
2026-09-04 — เพิ่มโฟลเดอร์ `adr/` (ADR-0001…0009) จากการ grill design ปิดข้อค้างไป 3 ข้อ
2026-09-03 — ยืนยันโมเดล multi-tenant: หลายร้าน คนละเจ้าของกันจริง (ไม่ใช่แฟรนไชส์),
~~1 ร้าน = 1 เครื่อง POS~~ → แทนด้วย ADR-0004 (1 เครื่อง `pos` + `backoffice` กี่เครื่องก็ได้)*
