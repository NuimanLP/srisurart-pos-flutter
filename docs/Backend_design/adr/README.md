# ADR — บันทึกการตัดสินใจเชิงสถาปัตยกรรม

ไฟล์ใน `01_`–`04_` บอกว่า **ระบบเป็นยังไง** โฟลเดอร์นี้บอกว่า **ทำไมถึงเป็นแบบนั้น**
1 ไฟล์ = 1 การตัดสินใจ เขียนตอนตัดสินใจ ไม่ใช่เขียนย้อนหลัง — ของที่ยังไม่เคาะอยู่ในหัวข้อ
"ยังไม่เคาะ" ท้ายไฟล์ ไม่ใช่หายไปเฉย ๆ

| # | เรื่อง | ข้อสรุปสั้น ๆ | สถานะ |
|---|---|---|---|
| [0001](0001-tenant-provisioning.md) | ร้านใหม่เข้าระบบยังไง | platform admin สร้างให้ผ่าน `POST /platform/tenants` (ทรานแซกชันเดียว ได้ tenant+owner+settings+seed) — ยังไม่ทำ self-service signup | Accepted |
| [0002](0002-platform-admin-plane.md) | platform admin อยู่ตรงไหน | ตาราง `platform_admins` แยก + JWT คนละ `aud` + DataSource ที่ `BYPASSRLS` แยก + audit ทุกครั้ง | Accepted |
| [0003](0003-tenant-lifecycle.md) | ร้านถูกระงับ/เลิกใช้ | `tenants.status` และบังคับที่ **guard** (ไม่ `SET LOCAL` → RLS คืน 0 แถวเอง) ไม่ใส่ใน RLS predicate | Accepted |
| [0004](0004-device-roles.md) | กี่เครื่องต่อร้าน | ไม่นับจำนวนเครื่อง แต่แบ่ง `role`: `pos` **1 เครื่อง** (แตะลิ้นชัก+ออกเลข+เขียน offline), `backoffice` กี่เครื่องก็ได้ (สต็อก/รายงาน, ออนไลน์เท่านั้น) | Accepted |
| [0005](0005-data-portability.md) | export / restore รายร้าน | export ได้ (async job, โครง `sa_*` เดิม, audit) — **ไม่รับปาก restore รายร้าน** | Accepted |
| [0006](0006-per-tenant-rate-limit.md) | noisy neighbor | Nginx จำกัดต่อ **IP**, guard+Redis จำกัดต่อ **tenant** (Nginx ฟรีอ่าน JWT ไม่ได้) | Accepted |
| [0007](0007-receipt-numbering.md) | รูปแบบเลขที่ใบเสร็จ | `RC01-2569-08-0042` เรียงต่อเครื่อง รีเซ็ตรายเดือน + ต้อง seed counter จาก server กัน IndexedDB ถูกล้าง | Accepted |
| [0008](0008-cost-at-sale.md) | ต้นทุน ณ วันที่ขาย | `sale_items.cost_at_sale` — บิลเก่า `NULL` ห้าม backfill · **ลงมือใน Drift แล้ว** (schema v2) | Accepted ✅ |
| [0009](0009-jwt-session-lifetime.md) | อายุ JWT | ล็อกอินใหม่ทุกวัน — access 15 นาที + refresh หมดอายุ **ตี 4** ไม่ใช่ 24 ชม.นับจากล็อกอิน | Accepted |
| [0010](0010-client-write-through-cache.md) | client ใช้ Drift ยังไง | `ApiRepository` = implementation ใหม่ของ interface เดิม เขียนผลลง Drift (**write-through**) และ **map ที่ชั้น repository** ไม่ regenerate schema ตาม Postgres | Accepted |
| [0011](0011-monorepo.md) | `server/` อยู่ที่ไหน | repo เดียวกับ client — 1 commit แก้ API ได้ทั้งสองฝั่ง, CI ใช้ `paths:` filter | Accepted |

## สถานะการนำไปลงเอกสารหลัก — ✅ เสร็จแล้ว (2026-09-04)

ADR ทั้ง 7 ถูก propagate ลง `01_DATABASE.md` / `02_API_SCREENS.md` / `03_ARCHITECTURE.md`
และ `00_INDEX.md` เรียบร้อย เอกสารทั้งชุดไม่ขัดกันเองแล้ว

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

## ยังค้างอยู่ — ต้องให้คนเคาะ

* **เกณฑ์ `offlineOk`** — ต้องคำนวณจากข้อมูลขายจริง (ไฟล์ backup `sa_*`) ก่อนงาน `q2`
* **คำไทย 3 ตัวที่ขึ้นหน้าร้าน** — `DEVICE_ROLE_FORBIDDEN` / `TENANT_SUSPENDED` /
  `OFFLINE_NOT_ALLOWED` ต้องให้คนขายอ่านแล้วเลือกคำเอง
* **production host** — ก่อนงาน `q4`
* **แบ่ง Lane B / Lane C** ให้อีกสองคนในทีม
* บวกหัวข้อ "ยังไม่เคาะ" ท้าย ADR แต่ละฉบับ
