# Handoff — #344 รันบางส่วน (AC1/AC2), device token ที่ถูกปลด → #609, deploy `32979f0` (2026-10-05)

**วันที่:** 2026-10-05 · **สถานะ:** #344 ยังไม่จบ (AC3–AC6 ค้าง) · #609/#610 merged + deploy แล้ว
**ต่อจาก:** [`session-2026-10-04-night-review-600-604-deploy.md`](session-2026-10-04-night-review-600-604-deploy.md) · เช็กลิสต์: [`demo-344-checklist-2026-09-30.md`](demo-344-checklist-2026-09-30.md)

## 1. #344 — ทำไปถึงไหน (ห้ามนับเป็น AC ผ่าน)
- สร้าง tenant `demo-344-20261005` ผ่าน **platform-ui** — เป็นการ login platform-ui ด้วยมือคนครั้งแรกบน `mob04` (หลักฐานให้ #443)
- **AC1 (ตรวจใน DB):** tenant `active` · owner `must_change_password` = t · device `pos1` ยังไม่ผูก มี enrol code · 5 หมวด · audit `platform.tenant.create` · `tenants` 8→9 · plan ออกเป็น `basic` เพราะฟอร์ม platform-ui ไม่มีช่อง plan
- **AC2:** pos1 ผูกแล้ว + code ถูกเผา · `must_change_password` = f · temp expiry ล้าง · `password_changed_at` มีค่า
- **ยังไม่ทำ:** เปิดกะ/ขาย (AC3), ส่งซ้ำ key (AC4), Grafana (AC5), ตาราง B (AC6) — ตารางในเช็กลิสต์ลงว่า "บางส่วน" เฉพาะ AC1/AC2

## 2. บั๊กที่เจอระหว่างรัน → #609
เบราว์เซอร์ที่ถือ device token ของ tenant อื่น (ถูกปลดไปแล้ว) ขึ้นป้าย `เครื่อง POS` และซ่อนลิงก์ผูกเครื่อง ทำให้ผูกเครื่องของ tenant ใหม่ไม่ได้ · ทางเลี่ยง: Incognito/โปรไฟล์ใหม่

**แก้แล้ว (PR #611 `08cd5c2` + PR #613 `32979f0`):**
- server: `POST /auth/token` ที่แนบ token ที่ถูกปลด/ไม่รู้จัก → `401 DEVICE_RETIRED` / `401 DEVICE_TOKEN_INVALID` ก่อนตรวจรหัสผ่าน (`server/src/auth/auth.service.ts:103-128`) · `DeviceTokenGuard` ของ `/sync/push` ไม่เปลี่ยน
- client: `AuthRepository.login` ลบ device token + PIN แบบ compare-and-clear (เฉพาะเมื่อ token ที่เก็บยังเป็นตัวที่ส่งไป) แล้วโยน `DeviceEnrolmentGoneException` (`auth_repository.dart:19,103`) · เจ้าของยืนยันให้ลบ PIN ด้วย (#609 comment 5987543993)
- `AuthCubit` (`auth_cubit.dart:352`) ขึ้น Backoffice + ข้อความไทย `deviceEnrolmentGone` (**agent ร่าง**, `02 §8.1.1` รอเจ้าของ) · `init`/`_logout` ไม่โชว์ role pos ที่จำไว้ถ้าไม่มี device token
- Drift/outbox ไม่ถูกแตะ · `ENROL_UNSENT_WORK` ยังกันการผูกใหม่ที่มีงานค้าง
- **ยังไม่สร้าง:** ชื่อร้านบนป้าย + เช็กสถานะเครื่องตอนเปิดแอป (ต้องมี API ใหม่) · **#612** ช่อง setup PIN ออฟไลน์อ่านทุก 401 เป็นรหัสผ่านผิด

## 3. #610 — เปิดกะซ้ำ id
`POST /shifts/open` id เดิมแต่ `startingCash` ต่าง → `409 CLIENT_ID_REUSED` (`shifts.service.ts:202`, `server/src/common/client-id-reused.exception.ts`) เหมือน `/sync/push` · cash เท่ากันแต่เขียนต่างรูป (`"2000"`/`"2000.00"`) ยัง 200 · `08 §6.1` ระบุเป็นข้อยกเว้น "ออนไลน์คง code เดิม" — **เจ้าของยังไม่ยืนยัน**

## 4. บทเรียน merge
#611 ถูก auto-squash ที่ head `03eb17a` ส่วน review fix `49cd4c0` ถูก push ตามหลัง 12 นาที → ไม่เข้า `main` → กู้ด้วย cherry-pick เป็น PR #613 · อย่าเปิด auto-merge ตอนที่ agent ยัง push แก้รีวิวอยู่ · เช็ก `gh pr view N --json headRefOid` ตอน merge (กติกาเดิมใน CLAUDE.md)

## 5. Deploy + ตรวจจริง
- deploy run `37260574722` → `/opt/pos/.current_sha` = `32979f0658b66ff68b04ed91ec663ed3ce6abe7e` · `/health/ready` 200 · bundle `main.32979f0658b6.dart.js`
- ตรวจสด: device token ปลอม → `401 DEVICE_TOKEN_INVALID` · เจ้าของยืนยันว่าป้ายเปลี่ยนเป็น Backoffice บนเบราว์เซอร์ที่ถือ token ที่ถูกปลด

## 6. ต่อไป
1. ทำ #344 ขั้นเปิดกะ + ขาย + ส่งซ้ำ key + Grafana (tenant `demo-344-20261005` พร้อมใช้) 2. เจ้าของ ratify ข้อความไทย `deviceEnrolmentGone` และข้อยกเว้น `08 §6.1` 3. #612
