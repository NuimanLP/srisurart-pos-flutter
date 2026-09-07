# ADR — บันทึกการตัดสินใจเชิงสถาปัตยกรรม

ไฟล์ใน `01_`–`04_` บอกว่า **ระบบเป็นยังไง** โฟลเดอร์นี้บอกว่า **ทำไมถึงเป็นแบบนั้น**
1 ไฟล์ = 1 การตัดสินใจ เขียนตอนตัดสินใจ ไม่ใช่เขียนย้อนหลัง — ของที่ยังไม่เคาะอยู่ในหัวข้อ
"ยังไม่เคาะ" ท้ายไฟล์ ไม่ใช่หายไปเฉย ๆ

| # | เรื่อง | ข้อสรุปสั้น ๆ | สถานะ |
|---|---|---|---|
| [0001](0001-tenant-provisioning.md) | ร้านใหม่เข้าระบบยังไง | platform admin สร้างให้ผ่าน `POST /platform/tenants` (ทรานแซกชันเดียว ได้ tenant+owner+settings+seed) — ยังไม่ทำ self-service signup | Accepted |
| [0002](0002-platform-admin-plane.md) | platform admin อยู่ตรงไหน | ตาราง `platform_admins` แยก + JWT คนละ `aud` + DataSource ที่ `BYPASSRLS` แยก + audit ทุกครั้ง | Accepted |
| [0003](0003-tenant-lifecycle.md) | ร้านถูกระงับ/เลิกใช้ | `tenants.status` และบังคับที่ **guard** (ไม่ `SET LOCAL` → RLS คืน 0 แถวเอง) ไม่ใส่ใน RLS predicate | Accepted |
| [0004](0004-device-roles.md) | กี่เครื่องต่อร้าน | ไม่นับจำนวนเครื่อง แต่แบ่ง `role`: `pos` **1 เครื่อง** (แตะลิ้นชัก+ออกเลข+เขียน offline), `backoffice` กี่เครื่องก็ได้ (สต็อก/รายงาน, ออนไลน์เท่านั้น) · **เครื่อง = device token ที่ owner enrol ให้** (`/devices`, `/auth/device`) ไม่ใช่ id จาก client | Accepted |
| [0005](0005-data-portability.md) | export / restore รายร้าน | export ได้ (async job, โครง `sa_*` เดิม, audit) — **ไม่รับปาก restore รายร้าน** | Accepted |
| [0006](0006-per-tenant-rate-limit.md) | noisy neighbor | Nginx จำกัดต่อ **IP**, guard+Redis จำกัดต่อ **tenant** (Nginx ฟรีอ่าน JWT ไม่ได้) | Accepted |
| [0007](0007-receipt-numbering.md) | รูปแบบเลขที่ใบเสร็จ | `RC01-2569-08-0042` เรียงต่อเครื่อง รีเซ็ตรายเดือน · **เฟส 1 server ออกทุกเลข** เฟส 2 เครื่อง `pos` ออก RC/CN เอง ส่วน PO/QT/CP server ออกตลอด | Accepted |
| [0008](0008-cost-at-sale.md) | ต้นทุน ณ วันที่ขาย | `sale_items.cost_at_sale` — บิลเก่า `NULL` ห้าม backfill · **ลงมือใน Drift แล้ว** (schema v2) | Accepted ✅ |
| [0009](0009-jwt-session-lifetime.md) | อายุ JWT | ล็อกอินใหม่ทุกวัน — access 15 นาที + refresh หมดอายุ **ตี 4** ไม่ใช่ 24 ชม.นับจากล็อกอิน | Accepted |
| [0010](0010-client-write-through-cache.md) | client ใช้ Drift ยังไง | `ApiRepository` = implementation ใหม่ของ interface เดิม เขียนผลลง Drift (**write-through**) และ **map ที่ชั้น repository** ไม่ regenerate schema ตาม Postgres | Accepted |
| [0011](0011-monorepo.md) | `server/` อยู่ที่ไหน | repo เดียวกับ client — 1 commit แก้ API ได้ทั้งสองฝั่ง, CI ใช้ `paths:` filter | Accepted |

## สถานะการนำไปลงเอกสารหลัก

* **รอบ 1 (2026-09-04):** ADR-0001…0007 propagate ลง `01`/`02`/`03`/`00_INDEX` — ตารางด้านล่าง
* **รอบ 2 (2026-09-04, scrutinize รอบ 3):** ADR-0008…0011 และ addendum ของรอบ 3 — ดูหัวข้อ
  "รอบ scrutinize 2026-09-04 (ครั้งที่ 3)" ด้านล่าง
  ⚠️ ฉบับก่อนของไฟล์นี้เขียนว่า *"เอกสารทั้งชุดไม่ขัดกันเองแล้ว"* ทั้งที่ตรวจแค่ 7 ฉบับแรก —
  ประโยคนั้นผิด และเป็นเหตุให้ 0008/0009 ค้างอยู่ฝั่ง ADR โดยที่ DDL/API ไม่ตาม

| เอกสาร | แก้อะไรไป | ADR |
|---|---|---|
| `01_DATABASE.md` | `tenants.is_active` → `status` + `timezone` + คอมเมนต์ `plan`; `devices` เพิ่ม `role`/`retired_at` + index `one_pos_per_tenant`; ตาราง `platform_admins` ใหม่ (27 → **28 ตาราง**); §7.2 `RC01-…` + หัวข้อ counter หาย; §8 RLS เช็คสถานะที่ guard; §10 soft delete คือทางกู้เดียว | 0002–0007 |
| `02_API_SCREENS.md` | §4 แยก **§4.1 admin plane** / **§4.2 tenant plane** + คอลัมน์ *device role* ทุกแถว; `GET /doc-counters` ใหม่; §5.1 rate limit; §6 job `tenant-export`/`tenant-import`; §8.1 error ใหม่ 3 ตัว; §9 คำเตือน k6 | 0001–0007 |
| `03_ARCHITECTURE.md` | §5 แก้กล่องยืนยันโมเดล + กติกาข้อ 6 + กับดัก BYPASSRLS + 2 แถวในตาราง T1/T2/T3; §7 เขียนกล่องข้อสรุปใหญ่ใหม่ทั้งกล่อง; §8 เพิ่มงาน 4 ตัว + DoD 3 ข้อ + ข้อห้ามลืมตอน deploy | 0001–0006 |
| `00_INDEX.md`, `CLAUDE.md` | ชี้มาที่ `adr/`, ปิดข้อค้าง 3 ข้อ, ประกาศกติกา **"เอกสารขัดกับ ADR → ยึด ADR"** | ทั้งหมด |

## สิ่งที่พบระหว่าง propagate แล้วแก้ตามไปด้วย

* **ADR-0005 มี endpoint ซ้ำ** — `POST /tenant/export` ที่เสนอไว้ ซ้ำกับ `POST /backup/export`
  ที่มีอยู่แล้ว → ยุบใช้ของเดิม และ `POST /backup/import` ที่เดิมให้ `owner` ทับข้อมูลทั้งร้านได้
  (= restore รายร้าน ซึ่งขัด ADR-0005 ตรง ๆ) → ย้ายเป็น `POST /platform/tenants/{id}/import`
  ของ admin plane ที่ **ปฏิเสธถ้า tenant มีบิลแล้ว** ดูหัวข้อ "🔧 แก้ ADR นี้" ใน ADR-0005
* **ADR-0004 ตีความผิดได้** — "เปิด-ปิดกะ = `pos` เท่านั้น" ถูกอ่านเป็น "อ่านกะก็ต้องเป็น `pos`"
  ทั้งที่การอ่านไม่แตะลิ้นชัก → แยกแถวเขียน/อ่านในตารางความสามารถแล้ว
* ตัวเลขตารางทั้ง repo 27 → 28, index `one_pos_per_tenant` เข้าตารางสรุป §6,
  และ `03_ARCHITECTURE §5` ที่เขียน "ครบ 5 ข้อ" แต่มี 6 ข้อ (typo เดิม ไม่เกี่ยวกับ ADR)

## งานที่ลงมือไปแล้วใน Flutter (2026-09-04) — ADR-0008

Drift `schemaVersion` 1 → **2** (`build_runner` รันบน path ASCII นี้ได้ ข้อจำกัดใน `CLAUDE.md`
เป็นเรื่องโฟลเดอร์ไทยบน Windows เท่านั้น) เพิ่ม 7 คอลัมน์ nullable + `onUpgrade`,
ต่อสาย `updatedAt` 8 จุด, `saveSale` เขียน `costAtSale`, และแก้ snapshot import/export
ที่ **เคยทิ้งค่า `cost` จากไฟล์ backup ของแอป JS** — `dart analyze` สะอาด, `flutter test` 123 ผ่าน

→ ปลดล็อกเงื่อนไขของเฟส 2 ที่ `CLAUDE.md` ระบุไว้ (`updatedAt` บน customers/mechanics/settings)

## รอบ grill 2026-09-04 (ครั้งที่ 2) — ปิดอะไรไปบ้าง

| เรื่อง | ผล |
|---|---|
| scope | **ไม่ตัด** ทำครบถึง cutover (เฟส 1 + เฟส 2) |
| กำหนดส่ง | **ไม่ผูกกับวัน** ใช้ checklist เรียงลำดับแทน |
| `server/` อยู่ไหน | repo นี้ — ADR-0011 |
| client ↔ Drift | write-through + map ที่ repository — ADR-0010 |
| เลขที่ใบเสร็จ | ✅ อนุมัติ `RC01-2569-08-0042` ตาม ADR-0007 |
| ข้อความไทย 7 ตัว | ร่างแล้วใน `02_API_SCREENS §8.1` — **agent ร่าง เจ้าของโปรเจกต์รับไว้ ยังไม่ผ่านคนหน้าร้าน** |
| host เฟส 1 | VM คณะ + Docker — **สาธิตเท่านั้น** production host เคาะก่อน `q4` |
| CI/CD | ระดับ 3 (gate + integration + artifact) — deploy step ยังไม่ต่อสาย |

## รอบ scrutinize 2026-09-04 (ครั้งที่ 3) — 3 agent ถกกันแล้วแก้ตามจุดที่ลงตัว

ผู้เข้าร่วม: scrutinize (โจมตี) · grill-with-docs (ไล่ decision tree) · ฝ่ายผู้ออกแบบ (แก้ต่าง+ตีราคา)
ผลรวม: finding 8 ข้อยืนครบ + พบเพิ่ม 3 major + เถียงกันจริง 2 เรื่อง (ใครออกเลขในเฟส 1, ความร้ายแรง
ของ retired-device) ซึ่งจบด้วย addendum ทั้งคู่

| ADR | แก้อะไร |
|---|---|
| 0004 | เพิ่มหัวข้อ **"การผูกเครื่อง"** (device token, `POST /devices`, `POST /auth/device`, `/retire`, `did` มาจาก server เท่านั้น); ย้ายเครื่องกลางกะต้องปิดกะเก่าก่อน; ถอนการอ้าง "200 ครั้งพร้อมกัน" เป็นหลักฐานหลายเครื่อง |
| 0007 | แยกใครออกเลข **ตามเฟสและบทบาท** (เฟส 1 server ทั้งหมด; เฟส 2 pos ออก RC/CN, backoffice ใช้ server); เพิ่ม **CP**; ใบเสร็จที่พิมพ์แล้วห้ามเปลี่ยนเลข → reconciliation; ห้ามออกเลขออฟไลน์ถ้า period ยังไม่ได้ seed |
| 0009 | refresh เช็ค `devices.retired_at`; ตี 4 ตาม `tenants.timezone`; refresh ที่ออกหลัง 03:00 หมดอายุตี 4 วันถัดไป; บันทึกสมมติฐานเวลาเปิดร้าน |
| 0003 | guard ทำทั้ง status check และ `SET LOCAL` (ไม่มี interceptor แยก); cache miss/Redis ล่ม → อ่าน Postgres ห้าม fail-open/closed; key status ต้องมี TTL |
| 0010 | เพิ่ม **"ใครเป็นเจ้าของ invariant"** (`ApiRepository` patch แถวเท่านั้น ห้ามเรียก transactional service ของ Drift + ตารางว่าแต่ละ write patch อะไร); ยอมรับว่าต้องมี **schema v3** (`Sales.shiftId`, `Shifts.id` TEXT, `Products.offlineOk`); "ใช้ต่อได้ตอนเน็ตหลุด" เหลือแค่ฝั่งอ่าน |
| 0001 / 0006 | ยุบ `is_demo` + `plan='loadtest'` เหลือ **`tenants.plan`** ตัวเดียว (`basic`/`demo`/`loadtest`); seed = 5 หมวดหมู่เท่านั้น ไม่มีสินค้าเดโม ไม่มี "หน่วยนับ"; fail-open ใช้กับ rate limit เท่านั้น |
| 0002 | `audit_log.platform_admin_id` เพราะ `user_id` ใส่ admin ไม่ได้; ปิดข้อ "endpoint เฟส 1 มีกี่ตัว" (5 ตัวใน `02 §4.1`) |
| 0005 | นิยาม "tenant มีบิลแล้ว" สำหรับ import; 27 → 28 |
| 0008 | propagate ลง `01` (DDL + §7.1 + §11) ที่รอบก่อนตกไป |
| เอกสาร 01/02/03/04 | DDL `cost_at_sale`, `doc_counters` รับ `cp`, `devices.token_hash`, `audit_log.platform_admin_id`; `02 §1.1` อายุ token + device; `02 §4.2` แถว `/devices/*`; `02 §8` `RECEIPT_NO_CONFLICT`; `02 §3.1` ตัวอย่าง `RC01-…`; `03 §8` ลบข้อเสนอ rotation, แก้ `p9b`, ปิดงาน updatedAt, DoD เพิ่มเคส pos×backoffice; `04` หมายเหตุ ADR-0007; path import ให้ตรงกัน |

## ยังค้างอยู่ — ต้องให้คนเคาะ

**คำถามที่เรียบเรียงให้เจ้าของร้าน/เจ้าของโปรเจกต์ตอบได้ (แต่ละข้อมีที่มาใน ADR นั้น):**

* **ADR-0004:** เครื่องไหนที่เคาน์เตอร์คือ "เครื่องขาย" และใครมีสิทธิ์ย้ายสถานะนั้นตอนเครื่องพัง
* **ADR-0009:** มีวันไหนที่ร้านยังขายอยู่ตอนตี 4 ไหม และรับได้ไหมกับการล็อกอินใหม่ทุกเช้า
* **ADR-0007:** ดูใบเสร็จตัวอย่าง `RC01-2569-09-0042` เทียบ `RC12345678ABCD` บัญชีอยากได้แบบไหน
  และเลขเริ่มใหม่ทุกเดือนหรือทุกปี
* **ADR-0008:** "ต้นทุน" บนบรรทัดบิล รวมค่าส่งด้วยไหม
* **ADR-0003:** หยุดให้บริการร้านแล้ว เจ้าของยังควรดู/export ข้อมูลเก่าได้ไหม
* **ADR-0005:** ยอมรับได้ไหมที่จะบอกร้านเป็นลายลักษณ์อักษรว่า "ย้อนข้อมูลของเมื่อวานให้ไม่ได้"
* **ADR-0001:** owner ได้รหัสครั้งแรกจากทีมตัวต่อตัว หรือลิงก์ตั้งรหัสเอง
* **ADR-0002:** ยอมรับได้ไหมที่บัญชี admin ซึ่งเห็นทุกร้านมีแค่รหัสผ่านชั้นเดียว

**ค้างเดิม:**

* **เกณฑ์ `offlineOk`** — ต้องคำนวณจากข้อมูลขายจริง (ไฟล์ backup `sa_*`) ก่อนงาน `q2`
* **คำไทย 3 ตัวที่ขึ้นหน้าร้าน** — `DEVICE_ROLE_FORBIDDEN` / `TENANT_SUSPENDED` /
  `OFFLINE_NOT_ALLOWED` ต้องให้คนขายอ่านแล้วเลือกคำเอง
* **production host** — ก่อนงาน `q4`
* ~~**แบ่ง Lane B / Lane C** ให้อีกสองคนในทีม~~ — **เลิกใช้ 2026-09-05** อาจารย์กำหนดว่า
  **ทั้ง 3 คนต้องแตะทั้ง frontend / backend / CI-CD** การแบ่งแบบ "คนละ lane" จึงใช้ไม่ได้
  เพราะ lane ทั้งสามเป็น backend ล้วน → แบ่งใหม่เป็น 3 กลุ่มตัดขวาง ดูหัวข้อถัดไป
* **Drift schema v3** (ADR-0010) — ทำก่อน `q1` เสร็จ ไม่ใช่ตอนนี้

---

## แตกงานเป็น ticket แล้ว (2026-09-05)

เอกสารชุดนี้บอกว่า **จะสร้างอะไร** — **GitHub issues บอกว่า ใครทำอันไหน ลำดับไหน**
(`github.com/NuimanLP/srisurart-pos-flutter/issues`) ถ้าสองที่ขัดกันเรื่อง *เนื้องาน* ให้ยึด ADR
ถ้าขัดกันเรื่อง *ใครทำ / ลำดับ* ให้ยึด issue

| issue | คืออะไร |
|---|---|
| **#2** | program brief เฟส 1 — ต้นไม้งานทั้งหมด + ตารางแบ่งคน **อ่านก่อน** |
| **#3 / #7 / #8 / #9 / #10** | **parent** เก็บบริบทร่วม ไม่มีป้าย `ready-for-agent` **ห้ามลงมือที่ issue พวกนี้ตรง ๆ** |
| **#14–#40** | งานจริง 27 ชิ้น ชิ้นละ 1 PR มีเกณฑ์รับงานของตัวเอง และ "Blocked by" ที่อ้างเลข issue จริง |
| **#11–#13** | **การตัดสินใจที่ต้องให้คนตอบ** (ป้าย `question`) — ห้าม agent ตอบเองใน PR |

**#11–#13 มาจากข้อค้างในไฟล์นี้เอง** ทำเป็น ticket เพื่อให้เห็นว่ามันบล็อกงานอะไรอยู่จริง ๆ:

* **#11 `mechanics.total_credit`** — `01_DATABASE §7.1` สั่งให้ `+= total` แต่โค้ด Dart **ไม่เคยเขียนค่านี้เลย**
  อ่านฝั่งเดียวแล้วลงมือ = เปลี่ยนตัวเลขที่ร้านเห็นทุกวันโดยไม่ตั้งใจ · บล็อก #21
* **#12 คำไทย 3 ตัวที่ขึ้นหน้าร้าน** — บล็อกส่วนข้อความของ #4 / #6 (งานอื่นใน 2 issue นั้นเดินต่อได้)
* **#13 รายการ endpoint ที่จำกัดเฉพาะ `pos`** — ADR-0004 เขียนเองว่า "รอยืนยัน" และ `02 §4.2` เติมโดย
  **ตีความ** ว่า "อะไรที่เกี่ยวกับบิล ทำที่เครื่องขาย" · บล็อก #6 / #24 / #28

## แบ่งงาน 3 คน (2026-09-05) — แทนที่การแบ่งแบบ lane

อาจารย์กำหนดว่า **ทุกคนต้องแตะทั้ง frontend / backend / CI-CD** แผนเดิม "คนละ lane"
(Lane A/B/C) ใช้ไม่ได้ เพราะทั้งสาม lane เป็น backend ล้วน — คนหนึ่งจะไม่ได้แตะ frontend หรือ CI เลย

แบ่งใหม่เป็น **3 กลุ่มตัดขวาง** กลุ่มละ **backend 9 ชิ้น + CI 1 ชิ้น + frontend 1 ชิ้น**
ใช้ป้าย `team/1` `team/2` `team/3` — **ผูกกับคนจริงแล้ว (2026-09-07)**: `team/1` = `NuimanLP`,
`team/2` = `LomerAlloys`, `team/3` = `PattaraponKitcharoen` (ตั้งเป็น assignee ของแต่ละ issue
ใน GitHub แล้ว ป้าย label เดิมไม่เปลี่ยน)

| | `team/1` เส้นทางเงิน — `NuimanLP` | `team/2` schema + แคตตาล็อก + รายงาน — `LomerAlloys` | `team/3` แพลตฟอร์ม + โครงสร้างพื้นฐาน — `PattaraponKitcharoen` |
|---|---|---|---|
| **backend** | #18 #19 #20 #21 #22 #23 #24 #28 #30 | #15 #5 #16 #17 #25 #26 #27 #29 #32 | #14 #4 #6 #31 #33 #34 #35 #36 #37 |
| **CI/CD** | #40 image artefact | #39 path filter + isolation check | #38 backend workflow |
| **frontend** | Checkout / Returns / Cash Drawer (ฝั่งเขียน) | Products / Customers / PO / Quotes / Reports (ฝั่งอ่าน) + Drift schema v3 | auth + device token, หน้า login, ข้อความ error ใหม่ 7 ตัว |
| **ตามการตัดสินใจ** | #11 | — | #12 #13 |

**หมายเหตุที่ต้องรู้ 3 ข้อ:**

1. **คอลัมน์ frontend ยังไม่มี ticket** — เป็นงาน `q1` (ADR-0010) + Drift schema v3 ที่ยังอยู่ในรูปข้อความ
   ใน `03_ARCHITECTURE §8` เท่านั้น **ต้องตัด ticket ก่อนที่ใครสักคนจะทำ backend ของตัวเองเสร็จ**
   ไม่งั้นพื้นที่ที่สามจะถูกเร่งทำตอนท้าย
2. **คอลัมน์ frontend จับคู่กับคอลัมน์ backend โดยตั้งใจ** — คนที่เขียน `POST /sales` เป็นคนต่อหน้า Checkout
   เข้ากับมัน ทำให้งาน client เป็นงานจริง ไม่ใช่งานที่แถมมาเพื่อให้ครบเกณฑ์
3. **`team/1` เริ่มได้ช้าที่สุด และเป็นเรื่องเชิงโครงสร้าง** — เส้นทางเงินต้องรอ device role (#6 ของ `team/3`)
   ซึ่งรอ schema (#15 ของ `team/2`) ซึ่งรอ stack (#14 ของ `team/3`) · ลำดับ **#14 → #15 → #6 คือเส้นวิกฤต**
   ไม่ว่าจะแบ่งงานยังไงก็หนีไม่พ้น

## ลงมือแล้ว (2026-09-06) — #14 `p1` stack + health probes

`server/` เกิดขึ้นแล้วตาม ADR-0011 (branch `feat/p1-compose-stack`) — รายละเอียดใน
[`handoff_log/p1-compose-stack.md`](../../../handoff_log/p1-compose-stack.md) และ `server/README.md`
เกณฑ์ปิดเฟส 1 ข้อ 1 / 5 / 7 ใน `03_ARCHITECTURE §8` ติ๊กแล้ว

สิ่งที่ p1 ตัดสินใจไปและ ticket ถัดไปต้องรู้:

* **แอปต่อ Postgres ด้วย role `pos_app`** (`NOSUPERUSER NOBYPASSRLS` ไม่ใช่เจ้าของตาราง) สร้างตอน init
  volume — #15 ต้องรัน migration ในฐานะ `postgres` แล้ว `GRANT` ให้ `pos_app` เอง ไม่งั้น RLS ถูกข้ามเงียบ ๆ
* **Nginx fail over เฉพาะ `error timeout`** (ระดับ connection) ไม่รวม `http_5xx` — เพราะ `/health/ready`
  ตอบ 503 โดยตั้งใจตอน dependency ล่ม ถ้านับเป็น upstream failure จะเตะทั้ง 3 instance ทิ้งพร้อมกัน
* **api-1..3 ใช้ IP คงที่** (`172.30.0.11–13`) แทน DNS `resolve` — รอบทดสอบ drain เจอ 502
  "no live upstreams" จาก DNS ที่หายตอน container หยุด
* **Envelope `{status, data}` / `{status, error}`** และ JSON 404 ใช้กับทุก path แล้ว (Nest 12 ติด 404 handler
  ของตัวเองไว้ใต้ global prefix เท่านั้น จึงมี fallback ระดับ Express เพิ่ม)
* worker กับ Bull-Board **มี process แล้วแต่ยังไม่มี queue** — #34/#35 เป็นคนลงทะเบียน

## ลงมือแล้ว (2026-09-06) — #15 `p2` schema + RLS + seed, #38 backend CI

schema ทั้ง 27 ตารางของ `01_DATABASE.md §5` เป็น TypeORM migration แล้ว (branch `feat/p2-schema`
ต่อจาก `feat/p1-compose-stack`) — รายละเอียดใน [`handoff_log/p2-schema.md`](../../../handoff_log/p2-schema.md)
และ `server/README.md` § *Schema and migrations*

สิ่งที่ p2 ตัดสินใจไปและ ticket ถัดไปต้องรู้:

* **RLS เปิด + FORCE ทั้ง 25 ตารางที่มี `tenant_id`** ด้วย policy fail-closed ตาม #2 — ไม่ตั้ง GUC ได้ 0 แถว
  ไม่ error และ INSERT ถูกปฏิเสธ · #4 (`TenantGuard`) ต้อง `SET LOCAL app.tenant_id` ใน transaction
  ของ request เท่านั้น ทดสอบแล้วว่าค่าหายหลัง COMMIT และ `pos_app` สั่ง `SET row_security = off` ไม่ได้
* **ยังไม่มี role `BYPASSRLS`** — #5 (platform plane, ADR-0002) ต้องสร้างเองพร้อม DataSource แยก
  และการ provisioning ต้องตั้ง GUC หรือใช้ role นั้นก่อนเรียก `seedCategories()` ไม่งั้น WITH CHECK ปัด
* **migration รันเป็น job `migrate` ใน compose ครั้งเดียวก่อน `api-*` ขึ้น** (role `postgres`) ไม่รันตอน boot ·
  เพิ่ม migration = เพิ่มไฟล์ + ต่อท้าย `MIGRATIONS` ใน `data-source.ts` + ถ้ามีตารางใหม่ต้องใส่ใน
  `TENANT_SCOPED_TABLES` (test ตรวจ RLS/grant ทุกตาราง ลืมแล้ว suite แดง)
* **`movements` ให้ `pos_app` แค่ SELECT/INSERT** — ledger append-only บังคับที่ DB · ตารางอื่น DML ครบ
* **seed = 5 หมวดเท่านั้น** (ADR-0001) เป็นฟังก์ชัน `seedCategories(db, tenantId)` ให้ #5 เรียกใน
  transaction เดียวกับการสร้างร้าน ไม่ใช่ script ที่รันตอน migrate
* ที่ต่างจาก DDL ในเอกสาร (บันทึกไว้ในหัวไฟล์ migration): `audit_log` PK เป็น `(tenant_id, id)`,
  เพิ่ม CHECK ให้ `tenants.plan` / `devices.device_no` / `drawer_entries.type` / `movements.type`
* **CI ฝั่ง server ใช้ `docker compose up postgres redis-cache redis-queue` แทน service container**
  เพราะ service container ของ GitHub ตั้ง `command` ของ Redis ไม่ได้ → policy `allkeys-lru`/`noeviction`
  จะไม่ตรงกับของจริง

**สถานะ merge (2026-09-07):** #14 (`feat/p1-compose-stack`, PR #41) และ #15 (`feat/p2-schema`,
PR #42) merge เข้า `main` แล้วทั้งคู่ — ติดปัญหา stacked PR + squash merge ระหว่างทาง (history ชนกัน
ต้อง force-push branch ที่ rebase ใหม่) รายละเอียดเต็มใน
[`handoff_log/merge-p1-p2-lane-assignments.md`](../../../handoff_log/merge-p1-p2-lane-assignments.md)

