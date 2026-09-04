# ADR-0002 — platform admin อยู่ในตารางแยก คนละ auth realm กับผู้ใช้ของร้าน

* **สถานะ:** Accepted — 2026-09-04
* **ผู้ตัดสิน:** เจ้าของโปรเจกต์
* **เกี่ยวข้อง:** `03_ARCHITECTURE.md §5` (กติกาข้อ 6 + กับดักที่ 1), `01_DATABASE.md §8`

## บริบท

เอกสารเดิม **ขัดกันเอง**:

* `03_ARCHITECTURE.md §5` กติกาข้อ 6 — *"1 user = 1 tenant เท่านั้น ห้ามมี user ที่มีสิทธิ์มากกว่า 1 ร้าน"*
* แต่กับดักข้อ 1 ในหน้าเดียวกัน — *"endpoint ข้ามร้านมีไว้ให้ทีม platform ops"*
* และ `users.tenant_id` เป็น `NOT NULL` ทุกแถว

→ **คนที่ควรเห็นทุกร้าน ใส่ลงตาราง `users` ไม่ได้** ตามกติกาที่เขียนไว้เอง

## การตัดสินใจ

แยก **admin plane** ออกจาก **tenant plane** ให้ขาดจากกัน 4 ชั้น:

| ชั้น | ผู้ใช้ของร้าน | platform admin |
|---|---|---|
| ตาราง | `users` (มี `tenant_id NOT NULL`) | `platform_admins` (ไม่มี `tenant_id` เลย) |
| login | `POST /auth/token` | `POST /platform/auth/token` |
| JWT | `aud: "tenant"`, มี `tid` | `aud: "platform"`, **ไม่มี `tid`** |
| DB connection | role ที่ **โดน RLS** (ไม่ใช่ owner) | role แยกที่ `BYPASSRLS` |
| เส้นทาง | `/api/*` ทั้งหมด | `/platform/*` เท่านั้น |

**กติกาที่ห้ามละเมิด:**

1. guard ของ `/api/*` **ปฏิเสธ token ที่ `aud != "tenant"`** และ guard ของ `/platform/*`
   ปฏิเสธ `aud != "platform"` — token ข้ามฝั่งกันไม่ได้แม้แต่กรณีเดียว
2. **ไม่มี role ของร้านไหนเรียก `/platform/*` ได้ แม้แต่ `owner`** — เพราะร้านแต่ละ tenant
   เป็นคนละเจ้าของกันจริง ข้อมูลรั่วข้ามร้าน = รั่วให้คู่แข่งของลูกค้าอีกราย
3. ทุกครั้งที่ `/platform/*` ถูกเรียก **เขียน `audit_log` เสมอ** (ใคร, endpoint ไหน, แตะ tenant ใด)
4. connection ที่ใช้ `BYPASSRLS` **ต้องเป็น DataSource คนละตัว** ไม่ใช่ตัวเดียวกับ traffic ปกติ
   — ถ้าใช้ pool เดียวกัน โค้ดของร้านมีสิทธิ์หลุดไปวิ่งบน connection ที่ไม่มี RLS

## เหตุผล

* กติกา "1 user = 1 tenant" ยังจริง 100% ในตาราง `users` — ไม่ต้องเจาะรูให้ตัวเอง
* ทางเลือกที่ให้ `users.tenant_id` เป็น NULL ได้ แปลว่า **ทุก RLS policy และทุก query
  ต้องรับมือกับ NULL** ซึ่งเป็นช่องพลาดที่ลืมง่ายที่สุด และพลาดครั้งเดียว = รั่วทั้งระบบ
* `BYPASSRLS` เป็นช่องโหว่ที่ใหญ่ที่สุดในระบบที่เราสร้างเอง (เอกสารระบุไว้เอง) —
  ยิ่งขังไว้ในตาราง/พอร์ต/pool/audience ที่แยกขาด ยิ่งตรวจสอบง่าย

## ผลที่ตามมา

* ต้องเพิ่มตาราง `platform_admins` + `audit_log` เข้า `01_DATABASE.md` (audit_log มีแล้ว ตรวจว่า
  รองรับ actor ที่ไม่ใช่ user ของ tenant ได้)
* NestJS ต้องมี **2 DataSource** และ `TenantInterceptor` ต้องไม่ทำงานบนเส้น `/platform/*`
* Nginx ควรกัน `/platform/*` ไม่ให้ออกอินเทอร์เน็ต (internal network / allowlist IP)
  — แนวเดียวกับที่เอกสารสั่งไว้กับ Bull-Board

## ยังไม่เคาะ

* [ ] platform admin ต้องมี MFA ไหม (บัญชีนี้เห็นข้อมูลทุกร้าน — พลาดครั้งเดียวคือทั้งแพลตฟอร์ม)
* [ ] `/platform/*` มีกี่ endpoint จริง ๆ ในเฟส 1 (เสนอขั้นต่ำ: สร้าง tenant, ระงับ/คืนสถานะ,
      ดูรายชื่อร้าน, สถิติรวมของแพลตฟอร์ม) — ยังไม่มีใน API catalogue เลยสักตัว
