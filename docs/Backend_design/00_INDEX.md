# Srisurart POS — Backend Design Package

> ℹ️ **2026-09-08 — CouchDB ถูกเสนอและปฏิเสธในวันเดียวกัน** ([ADR-0012](adr/0012-couchdb-replaces-postgres.md) — Rejected)
> คง PostgreSQL · เอกสาร `01`–`03`, `server/`, ticket #4–#37 เป็นของจริงตามเดิม · เหตุผลอยู่ใน ADR ไม่ต้องคิดซ้ำ

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

> **แก้ 2026-09-23:** ตารางเดิมขาด `07`, `09`, `checklist.md`, `architecture-primer-audit/qa.md`,
> `fixtures/` และแผนย้ายของ ADR-0003 — เติมครบทุกไฟล์ในโฟลเดอร์แล้ว + เพิ่มคอลัมน์ **สถานะ**
> · กติกาเดิมยังใช้: **เอกสารขัดกับ ADR → ยึด ADR** · `08` ชนะ `09` · สถานะ "ของจริงวันนี้" ให้เช็คกับโค้ด/ticket เสมอ

### สเปกหลัก (ยังมีผล)

| ไฟล์ | เนื้อหา | สถานะ | ใครควรอ่าน |
|---|---|---|---|
| ⭐ [`00_BASICS.md`](00_BASICS.md) | **ปูพื้นฐาน — อ่านอันนี้ก่อน** ถ้ายังไม่เคยทำ backend: client/server, API, SQL, transaction, multi-tenant, JWT, cache, queue, scaling, offline sync + glossary อธิบายด้วยตัวอย่างจากร้านเราเอง | ✅ ปูพื้น (ปรับตาม ADR/โค้ด 2026-09-23) | **ทุกคนที่อ่านเอกสารอื่นแล้วงง** |
| [`01_DATABASE.md`](01_DATABASE.md) | ตารางทั้งหมด, ER diagram, DDL, index, constraint, business invariant, RLS, แผน migrate ข้อมูลเดิม · **ฐานข้อมูลจริงมี 29 ตาราง** (27 จาก `InitialSchema` + `import_jobs` + `owner_review_items`; `change_log` ไม่สร้าง) | ✅ มีผล · **ความจริงของ schema = `server/src/db/migrations/`** (ปรับ 2026-09-23) | **คนทำ DB / TypeORM entities** |
| [`02_API_SCREENS.md`](02_API_SCREENS.md) | 11 หน้าจอ → ยิง API อะไรบ้าง, API catalogue, request/response, cache / queue / idempotent, error codes + ข้อความไทย (§8), เกณฑ์ k6 (§9) | ✅ มีผล | **คนทำ NestJS modules + คนทำ Flutter client** |
| [`03_ARCHITECTURE.md`](03_ARCHITECTURE.md) | 3 architecture ให้เลือก + 3 แบบ multi-tenant, ข้อเสนอสุดท้าย (§7), แผนลงมือ + **DoD เฟส 1** (§8), วิธีวัด k6 (§8.1) | ✅ มีผล · DoD §8 = 17 ข้อ ติ๊ก 16 เหลือ k6 (#380) — นับ ณ 2026-09-23 | **ทุกคน + อาจารย์** |
| [`07_CICD_DEPLOY.md`](07_CICD_DEPLOY.md) | **เจ้าของเรื่อง CI/CD + deploy** — pipeline, environment, secret, deploy/rollback ขึ้น VM `mob04` (การตัดสินใจอยู่ใน ADR-0013) | ✅ มีผล · 🔴 CD ขึ้น `mob04` ยังติด FortiGate ของคณะ (ดู `CLAUDE.md` "Still open") | คนแตะ `.github/workflows/`, `deploy/` |
| ⭐ [`08_PHASE2_SPEC.md`](08_PHASE2_SPEC.md) | **สเปกเฟส 2** (#240 D1–D15, E1–E11, F1–F10) — role `owner` เดียว, PWA, Online/Degraded/Syncing, outbox, `POST /sync/push`, เลข RC/CN ที่เครื่อง `pos` ออก, หลายกะ, void, PIN ออฟไลน์, หน้า "รอ owner", production บน `mob04` | ✅ มีผล (ADR ชนะ 08) | **ทุกคนก่อนหยิบ ticket เฟส 2** |
| [`09_PHASE2_LANES.md`](09_PHASE2_LANES.md) | **แบ่ง lane เฟส 2** (เคาะ 2026-09-16) — ใครทำอะไร ลำดับไหน เส้นแบ่ง client/server, ticket 35 ใบใต้ #243, working agreement §10 | ✅ มีผล (08 ชนะ 09) | คนกำลังจะหยิบ ticket เฟส 2 |
| ⭐ [`adr/`](adr/README.md) | **บันทึกการตัดสินใจ (ADR) — 1 ไฟล์ = 1 การตัดสินใจ** 0001–0013: สร้างร้านใหม่, admin plane, สถานะร้าน + ที่อยู่ของ transaction (0003 amendment), บทบาทเครื่อง, export/restore, rate limit, เลขใบเสร็จ, ต้นทุน ณ วันขาย, อายุ JWT, cache ฝั่ง client, monorepo, CouchDB (❌ Rejected), CI/CD toolchain | ✅ **ผูกมัด — ชนะเอกสารอื่นทุกฉบับ** · 0012 = Rejected | ทุกคนก่อนเริ่ม implement |
| [`adr/0003-handler-scoped-migration-plan.md`](adr/0003-handler-scoped-migration-plan.md) | แผนลงมือ (ไม่ใช่ ADR) ย้าย transaction เข้า handler ตาม ADR-0003 amendment — สไลซ์ `tx.0`–`tx.5` (#149–#154) | 🗄️ ประวัติ — ครบ 6 สไลซ์ 2026-09-15 (มีผลตั้งแต่ `tx.4` 2026-09-14) | คนอยากรู้ว่า `runTx` มาจากไหน |
| [`fixtures/sync-push/`](fixtures/sync-push/) | JSON 18 ไฟล์ของ `POST /sync/push` (applied / rejected / replay / batch) — **สัญญากลาง**ระหว่าง lane B (เครื่อง) กับ lane C (server) จาก #269 | ✅ มีผล (สัญญา) | คนเขียน `SyncService` / `/sync/push` และเทสต์ |

### สื่อสอน / อ้างอิงเสริม (ไม่ใช่สเปก — ขัดกับ 01–03/ADR ให้ยึดตัวนั้น)

| ไฟล์ | เนื้อหา | สถานะ | ใครควรอ่าน |
|---|---|---|---|
| ⭐ [`architecture-primer.md`](architecture-primer.md) | **ปูพื้นสถาปัตยกรรม** — concurrency / lock order, RLS + handler-level `runTx`, idempotency, caching, วงจรชีวิตบิล, ตารางความล้มเหลว, self-test | 📚 สื่อสอน (อ้างโค้ด ณ 2026-09-21) | คนที่อ่าน 00_BASICS แล้วอยากลึกขึ้น + สื่อการสอน |
| [`architecture.md`](architecture.md) | blueprint สถาปัตยกรรมรวมเล่ม — Nginx, โมดูล NestJS, auth/device, tenancy (§5), **concurrency & lock order (§6)**, idempotency (§7), **caching (§8)**, BullMQ, กะ, observability, failure matrix | 📚 อ้างอิงเสริม (ไม่ใช่สเปก) | ทีม backend + architecture review |
| [`checklist.md`](checklist.md) | กฎจากคอร์ส Backend01–06 → ใช้จริงที่ไฟล์/บรรทัดไหนในโค้ด | 📚 snapshot — `file:line` และตัวเลขเทสต์เปลี่ยนตามโค้ด ตรวจซ้ำก่อนอ้าง | คนทำรายงาน/สไลด์ส่งอาจารย์ |
| [`architecture-primer-audit.md`](architecture-primer-audit.md) | ผลตรวจโครงสร้างของ `architecture-primer.md` (15 ข้อ A1–A15) | 🗄️ บันทึกการตรวจ | คนแก้ primer |
| [`architecture-primer-qa.md`](architecture-primer-qa.md) | บันทึก adversarial review ของ `architecture-primer.md` | 🗄️ บันทึกการตรวจ | คนแก้ primer |

### ประวัติ (อ่านเพื่อรู้ "ทำไม" — ไม่มีผลบังคับ)

| ไฟล์ | เนื้อหา | สถานะ | ใครควรอ่าน |
|---|---|---|---|
| [`04_QA_SCRUTINY.md`](04_QA_SCRUTINY.md) | บันทึกการถกเถียงของ 3 agent ที่ review design (Q&A) + ข้อสรุปที่แก้เข้าเอกสารแล้ว | 🗄️ ประวัติ (ข้อสรุปถูกย้ายเข้า 01–03/ADR แล้ว) | คนที่อยากรู้ว่า "ทำไมถึงตัดสินใจแบบนี้" |
| [`05_HOW_WE_GOT_HERE.md`](05_HOW_WE_GOT_HERE.md) | **จาก design เป็น ticket** — grill → spec → tickets, ชีวิตของ ticket 1 ใบ, ของที่ห้ามเดา | 🗄️ ประวัติ — สถานะรีโป ณ 2026-09-05 (การแบ่งงานเฟส 2 ใช้ `09`) | คนที่เพิ่งเข้าทีม |
| [`06_COUCHDB_REVISION.md`](06_COUCHDB_REVISION.md) | แผนฉบับ CouchDB ที่เสนอ 2026-09-08 — ADR ทีละฉบับจะเปลี่ยนยังไง, document model, §9 อ้างบรรทัด Dart ของ invariant | ❌ **Rejected** ([ADR-0012](adr/0012-couchdb-replaces-postgres.md)) — เก็บไว้เป็นประวัติ | คนที่สงสัยว่า "ทำไมไม่ใช้ CouchDB" · คนเขียน #20–#24 (§9) |

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
> เป็นส่วนเดียวที่ยังไม่ถูกแทน **แต่ถูกลบไปด้วย** → ช่องว่างนี้**ปิดแล้ว 2026-09-10**: เอกสารเจ้าของ
> เรื่อง CI/CD + deploy คือ [`07_CICD_DEPLOY.md`](07_CICD_DEPLOY.md) (การตัดสินใจใน
> [ADR-0013](adr/0013-cicd-toolchain.md)) · สเปกเครื่องและ "สิ่งที่ห้ามลืมตอน deploy" ยังอยู่ใน
> [`03_ARCHITECTURE.md §8`](03_ARCHITECTURE.md#8-แผนลงมือ) และ 07 อ้างถึง

---

## บริบทที่ใช้ออกแบบ (อ่านมาจากไหน)

1. **แอปปัจจุบัน** — `CONTRACT.md` ของ repo นี้: 20 Drift tables, 13 repositories, 11 screens
   (ทั้งหมดเป็น port ของ `pos/db.js` จากแอป JS เดิม — business rule ทุกข้ออยู่ในนั้น)
   · *หมายเหตุ 2026-09-23: ตัวเลข 20 คือ ณ ตอนออกแบบ — วันนี้ `frontend/lib/data/db/tables.dart` มี 25 ตาราง (Drift `schemaVersion` 11: เพิ่ม `PendingCreditPayments` #24, `DocCounterSeeds`, `OutboxOps`, `SyncCursors` ของเฟส 2 ฯลฯ)*
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
  · *สถานะ 2026-09-23:* backend เฟส 1 + ชั้น API-write ฝั่ง Flutter merge แล้ว · DoD [`03 §8`](03_ARCHITECTURE.md#8-แผนลงมือ)
  ติ๊ก 16/17 (เหลือ k6 #380) · ยังไม่มีการ deploy จริงขึ้น `mob04` (#343) · เฟส 2 กำลังทำตาม [`09`](09_PHASE2_LANES.md)
* **เฟส 1 ไม่ cutover ร้าน** — ส่งอาจารย์บน tenant สาธิต ร้านยังใช้ Drift build เดิมต่อ
  จึงไม่มีใครต้องรับความเสี่ยง "เน็ตล่มขายไม่ได้"
* **ทิ้งกลไก stock lease** ใช้ *scarcity rule* (`offlineOk`) แทน — ไม่เพิ่ม state ฝั่ง server เลย
  ~~(scarcity rule)~~ → **ยกเลิก 2026-09-15 (#240 D3):** ออฟไลน์ขายได้ถ้าสต็อกในเครื่อง `pos` พอ ([`08`](08_PHASE2_SPEC.md))
* **`stock` = ของบนชั้นเท่านั้น** ห้ามมีความหมายที่สอง

## สิ่งที่ยัง "ตัดสินใจแทนไม่ได้" — ต้องให้คนเคาะ

> **อัปเดต 2026-09-04 — ปิดไป 3 ข้อจากการ grill รอบล่าสุด** ดู [`adr/`](adr/README.md)
> ทุกข้อที่ปิดแล้วยังมีหัวข้อ "ยังไม่เคาะ" ของตัวเองใน ADR ที่เกี่ยวข้อง — อย่าอ่านว่าจบสนิท
>
> **แก้ 2026-09-23:** ข้อ 3 (ข้อความไทย) และข้อ 8 (แบ่ง lane) ล้าสมัย — ปรับตาม `02 §8.1`, `adr/README.md`
> และ `09` · เรียงแถวใหม่ตามเลข · ไม่ได้เปลี่ยนการตัดสินใจของเจ้าของข้อใด

| # | เรื่อง | สถานะ |
|---|---|---|
| 1 | **รูปแบบเลขที่ใบเสร็จ** | ✅ ปิด — [ADR-0007](adr/0007-receipt-numbering.md): `RC01-2569-08-0042` เรียงต่อเครื่อง รีเซ็ตรายเดือน<br/>⚠️ ยังต้องให้เจ้าของร้านเห็นใบเสร็จตัวอย่างก่อนพิมพ์ใบแรก |
| 2 | ~~**เกณฑ์ `offlineOk`**~~ | ✅ **ไม่ต้องมีแล้ว 2026-09-15 (#240 D3)** — ยกเลิก scarcity rule · ข้อความเดิม: ~~🔴 ยังค้าง — `stock ≥ max(5, 3×เฉลี่ยต่อบิล)` เป็นแค่ข้อเสนอ **ต้องคำนวณจากไฟล์ backup จริงก่อนงาน `q2`**~~ |
| 3 | **ข้อความไทยของ error ใหม่** (ตาราง [`02_API_SCREENS §8.1`](02_API_SCREENS.md#81-error-ที่เป็น-ของใหม่-ไม่มีใน-dbjs) วันนี้มี 30 ตัว) | 🟡 **บางส่วน** — ✅ เฟส 2: 5 code + 13 จุด UI เจ้าของโปรเจกต์เคาะ 2026-09-17 (#268 Option A, [`08 §18 Q1`](08_PHASE2_SPEC.md#18-คำถามที่เหลือ)) · ✅ `WEAK_PASSWORD` เคาะ 2026-09-21 (#364) · ✅ error จัดการเครื่อง 4 ตัว + `SALE_NOT_IN_OPEN_SHIFT` เคาะ 2026-09-15<br/>🔴 `DEVICE_ROLE_FORBIDDEN` / `TENANT_SUSPENDED` ยังเป็นคำที่ agent ร่าง ต้องให้คนขายเลือกคำ · หลายตัวใน §8.1 ยัง 🔴 **"ยังไม่ร่าง"** (เช่น `DOC_NUMBER_EXHAUSTED`, `SALE_HAS_RETURNS`, `SHIFT_ALREADY_CLOSED`) · ~~`OFFLINE_NOT_ALLOWED`~~ หมดความหมาย (D3) |
| 4 | **จะ cutover ร้านจริงเมื่อไหร่** | ✅ ปิด (2026-09-04) — **หลังเฟส 2 ตามแผน ไม่ตัด scope** และไม่ผูกกับกำหนดส่ง ใช้ checklist เรียงลำดับแทน |
| 5 | **จะ provision tenant ใหม่ยังไง** | ✅ ปิด — [ADR-0001](adr/0001-tenant-provisioning.md): platform admin สร้างให้ ยังไม่ทำ self-service signup |
| 6 | **กี่เครื่องต่อร้าน** | ✅ ปิด — [ADR-0004](adr/0004-device-roles.md): `pos` 1 เครื่อง + `backoffice` กี่เครื่องก็ได้ · **"เครื่อง" = device token ที่ owner enrol ให้** (`/devices`, `/auth/device`) — เพิ่มรอบ scrutinize 3 |
| 7 | **production host** | ✅ ปิด 2026-09-15 (#242, เจ้าของโปรเจกต์) — **`mob04` เป็น production สภาพแวดล้อมเดียว** (ในมหาวิทยาลัย) · cutover ร้านจริงเป็นเฟสถัดไป · ข้อความเดิม: ~~🔴 ใหม่ — เฟส 1 รันบน VM คณะเพื่อ**สาธิตเท่านั้น** ต้องเลือกเครื่องจริงก่อนงาน `q4`~~ |
| 8 | **แบ่ง Lane B / Lane C** | ✅ ปิด — ~~🔴 Lane A รับแล้ว อีกสองคนยังไม่แบ่ง~~ · **เลิกแบ่งแบบ lane-backend 2026-09-05** (อาจารย์กำหนดให้ทั้ง 3 คนแตะ frontend/backend/CI-CD — ดู [`adr/README.md`](adr/README.md)) · เฟส 1 แบ่ง `team/1–3` ตัดขวาง · **เฟส 2 แบ่ง lane A/B/C ใน [`09_PHASE2_LANES.md`](09_PHASE2_LANES.md)** (เคาะ 2026-09-16) |
| 9 | **คำถามที่ต้องให้เจ้าของร้าน/เจ้าของโปรเจกต์ตอบ (8 ข้อ)** | 🟡 ยังค้าง (scrutinize รอบ 3; ตรวจ 2026-09-23 ยังอยู่ในรายการ) — รวมไว้ท้าย [`adr/README.md`](adr/README.md) หัวข้อ "ยังค้างอยู่" เรียบเรียงเป็นภาษาคนหน้าร้านแล้ว |

### ✅ เอกสาร 01–04 ถูก propagate ตาม ADR-0001…0011 แล้ว (รอบ 2: 2026-09-04)
รายการว่าแก้อะไรไปบ้างอยู่ใน [`adr/README.md`](adr/README.md) — และกติกาที่ใช้ตัดสินคือ
**เอกสารขัดกับ ADR → ยึด ADR** (รอบแรกครอบแค่ 0001–0007 และเคยประกาศว่า "ครบ" ซึ่งไม่จริง)

---

*อัปเดตล่าสุด: 2026-09-23 — ตารางเอกสารครบทุกไฟล์ (เพิ่ม 07, 09, fixtures, แผนย้าย ADR-0003, architecture*/checklist) + คอลัมน์สถานะ,
01 = 29 ตารางตาม migration, ปรับข้อค้าง 3/8 ตามสถานะจริง, สถานะเฟส 1 สั้น ๆ
2026-09-04 (scrutinize รอบ 3, 3 agent ถก) — เพิ่ม "การผูกเครื่อง" ใน ADR-0004,
แยกใครออกเลขตามเฟสใน ADR-0007, refresh เช็ค `devices.retired_at` ใน ADR-0009, "ใครเป็นเจ้าของ
invariant" + schema v3 ใน ADR-0010, propagate 0008/0009 ที่ตกค้าง, DoD เพิ่ม 5 ข้อ, รวมคำถาม 8 ข้อให้คนตอบ
2026-09-04 (grill รอบ 2) — ADR-0010 (client write-through cache) + ADR-0011 (monorepo),
ปิดเรื่อง cutover/scope/ข้อความไทย, เปิดข้อค้างใหม่ 2 ข้อ (production host, แบ่ง lane)
2026-09-04 — เพิ่มโฟลเดอร์ `adr/` (ADR-0001…0009) จากการ grill design ปิดข้อค้างไป 3 ข้อ
2026-09-03 — ยืนยันโมเดล multi-tenant: หลายร้าน คนละเจ้าของกันจริง (ไม่ใช่แฟรนไชส์),
~~1 ร้าน = 1 เครื่อง POS~~ → แทนด้วย ADR-0004 (1 เครื่อง `pos` + `backoffice` กี่เครื่องก็ได้)*
