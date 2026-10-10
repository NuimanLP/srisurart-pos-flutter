# Handoff — เจ้าของร้านนำเข้าไฟล์สำรองเอง (รวมโหมดแทนที่ทั้งร้าน): `main` = `847e7ef` deploy ขึ้น `mob04` (2026-10-08)

**วันที่:** 2026-10-07 คืน → 2026-10-08 · **สถานะ:** deploy แล้ว · **ยังไม่ได้ลอง import จริงบน `mob04`** (owner จะทำ POC เอง) · freeze ของ 2026-10-07 ถูก owner ยกเว้นเฉพาะงานนี้
**ต่อจาก:** [`session-2026-10-07-final-release.md`](session-2026-10-07-final-release.md)
**วิธีตรวจ:** SHA/PR/run id อ่านจาก `gh` · ค่าฝั่ง VM (`.current_sha`, `/health/ready`, Ansible recap, ภาพ image, route 401, `flutter_bootstrap.js`) **ตรวจโดย orchestrator ในคืนนี้ผ่าน SSH** — เซสชันที่เขียนไฟล์นี้ไม่ได้ SSH ซ้ำ · ผลเทส (server unit/e2e, frontend) เป็นตัวเลขที่ orchestrator รายงาน

## 1. สรุปสั้น
- owner (`NuimanLP`) สั่งคืน 2026-10-07: เจ้าของร้านต้อง import ไฟล์สำรองเองได้จาก **ตั้งค่า → สำรอง/กู้คืน → กู้คืนข้อมูล** บน API build **รวมถึงร้านที่มีข้อมูลอยู่แล้ว** (โหมด replace — owner: "ทำแบบทับเลย") · owner ยก freeze เฉพาะงานนี้ และอนุญาต merge + deploy
- PR #664 (`feat/owner-import` → `develop`, squash) = `5ba90ce` · head ของ branch `9998213` == `headRefOid` ของ PR (ตรวจแล้ว — ไม่ติดบทเรียน "push หลัง merge")
- PR #665 (`develop` → `main`, merge commit) = `847e7ef` · CI เขียวทั้ง #664 และ #665
- deploy run `37660353755` สำหรับ `847e7ef` — approve โดย Claude ตามคำสั่ง owner · VM `/opt/pos/.current_sha` = `847e7ef19b817dd96f816211656e5b7ce4d1c404`
- ADR-0005 แก้ข้อ 5 + ข้อความไทยใหม่ใน `02 §8.1.1` เป็น **`agent ร่าง` — owner ยังไม่ได้รับรอง** (ข้อ 8)

## 2. Endpoint (server)
| | |
|---|---|
| `POST /api/v1/backup/import` | `202` + job · client ส่ง `?jobId=<uuid>` เอง (ซ้ำ = `409 IMPORT_JOB_EXISTS`) เพื่อตามงานต่อเมื่อคำตอบหาย |
| `GET /api/v1/backup/import/:jobId` | สถานะงานของร้านตัวเอง · job ร้านอื่น = `404` |
- สิทธิ์: `role='owner'` **และ** อุปกรณ์ที่ enrol แล้ว (`did`) เหมือน export · tenant มาจาก token เท่านั้น · ใช้ `TenantImportService` ตัวเดียวกับ platform import (`createOwnerJob`/`enqueue`)
- ไม่มี query + ร้านไม่ว่าง = `409 TENANT_NOT_EMPTY` · มีงาน import ค้าง = `409 IMPORT_IN_PROGRESS` (ทีละงาน) · `INVALID_ID` (ไฟล์จากแอปเดิม id ไม่ใช่ UUID) เหมือนเดิม
- **Replace:** `?mode=replace&confirmShopName=<ชื่อร้าน>` — เทียบกับชื่อใน `settings` (NFC + trim) ไม่ตรง = `400 CONFIRM_SHOP_NAME_MISMATCH`
- body JSON สูงสุด 10 MB **เฉพาะ token owner ที่ยืนยันแล้วบน path นี้** (`app.setup.ts`) · nginx ระดับ server 10 MB

## 3. Replace ทำอะไร (transaction เดียว, REPEATABLE READ, `tenants` row `FOR UPDATE`)
ลำดับ: **สำเนาก่อนลบ** (fsync + ตรวจขนาด) → DELETE (ทุกคำสั่ง `WHERE tenant_id=$1`) → insert จากไฟล์ → ยก `doc_counters` → audit `backup.imported` → commit · ล้มตรงไหนย้อนทั้งหมด

| ลบ | เก็บ |
|---|---|
| sales + items, returns + items, POs + items, quotes + items, credit_payments, shifts, drawer_entries, movements, parked_sales, suppliers, products, categories, customers, mechanics, owner_review_items, `tenant_meta` แบบ `unknownstore:*` | tenants, users, devices, audit_log, import_jobs · `settings` (เขียนทับถ้ามีในไฟล์) · `payment_accounts` (2026-10-10: แทนที่เฉพาะเมื่อไฟล์มี `sa_payment_accounts` ที่ไม่ว่าง เหมือน settings) · `doc_counters` (ยกขึ้น ไม่ลดลง) · `idempotency_keys` (ถ้าลบ retry เก่าจะรันซ้ำได้) |

## 4. กติกาใหม่: ทุก import เติม `doc_counters`
ทั้ง platform import และ owner import ยก `doc_counters` ขึ้นถึงเลข RC/CN/PO/QT/CP ในไฟล์ที่ตรง `DOC_NUMBER_REGEX` ด้วย `GREATEST`
- เลขแบบแอปเดิม (สุ่ม เช่น `RC90003021E869`) ข้าม
- เลขของ `device_no` ที่ tenant ไม่มี → ข้ามและรายงานเป็น `docCounterSkippedDevices` · ช่องว่างที่รู้: อุปกรณ์ที่ enrol ทีหลังด้วยเลขนั้นอาจชนเลขในไฟล์
- **ทำไม:** ก่อนหน้านี้ import ไฟล์รูป server แล้วขายบิลแรกใหม่ → เลขชน `409 RECEIPT_NO_CONFLICT`

## 5. สำเนาก่อน import (pre-import copy)
- ไฟล์ `/app/exports/<tenant>/pre-import/<jobId>.json` ใน volume `exports` (worker + api เห็น) · รูปเดียวกับ export
- **ไม่ลบอัตโนมัติ** — มีข้อมูลส่วนบุคคล (PDPA); นโยบายเก็บกี่วันเป็นการตัดสินใจของ owner
- อยู่บนดิสก์ VM เครื่องเดียว — **ไม่ออกนอก VM** (#363 parked) ห้ามเขียนว่า "มี backup"
- ดึงออก (SSH เป็น `cloud`): `docker compose -f /opt/pos/<compose> exec worker ls /app/exports/<tenant>/pre-import/` แล้ว `docker cp` ไฟล์ออก (ชื่อ container/compose ตรวจจาก `docker ps` บน VM — ไม่ได้ลองคำสั่งนี้ในเซสชันนี้)
- audit `backup.imported` เก็บ `preImportExport` (path) ไว้ใช้ตามหา

## 6. Client
- `OwnerImportRepository` · ปฏิเสธเมื่อมีงานค้างส่ง (outbox/credit payment) · ต้องพิมพ์ชื่อร้านยืนยัน · ข้อความผิดพลาดเป็นไทยล้วน (ไม่มี `ApiException` ถึง UI)
- marker `app_meta` `pending_server_import` — ถ้า refresh/ปิดแอปกลางทาง `owner_import_resume.dart` ตามงานต่อตอนเปิดแอป/ล็อกอิน
- สำเร็จแล้ว: `resetAfterServerImport` → pull เต็ม → pull ประวัติ `GET /sales` + `GET /returns` ครั้งเดียว → `DocCounterSeeder`
- **ข้อจำกัดที่รู้:** (ก) อุปกรณ์อื่นยังถือแถวเก่า หลัง replace ต้องล้าง site data/รีเฟรช (ข) ประวัติ shifts, drawer entries, movements, suppliers, ประวัติชำระเครดิต และบิลพักในไฟล์ **ไม่ถูก pull เข้าแอป** (อยู่ใน Postgres แล้ว แต่ UI ยังไม่เห็น)

## 7. เทสต์
- server unit **705 ผ่าน**
- server e2e บน Postgres จริง (stack ทิ้ง `-p ownerimp-e2e`) **76 ผ่าน** รวม `owner-import` 6/6 กับไฟล์ตัวอย่างจริงของ owner (**ไม่ commit** — มี fixture ที่ล้างข้อมูลส่วนบุคคลแล้ว `server/test/fixtures/owner-backup-sanitized.json`)
- e2e เต็มบนเครื่อง Windows มี **12 ล้มเฉพาะ Windows** (tsx ENOENT, file mode bit, ECONNREFUSED ใน stress) — ไม่ใช่โค้ดนี้ · CI integration เขียว
- frontend **1509 ผ่าน**

## 8. Deploy และเหตุการณ์ runner
- run `37660353755` (`847e7ef`) ค้างคิว ~1 ชม.: runner `mob04-demo` ขึ้น **offline** ทั้งที่ systemd service `active` — log มี `BrokerServer` TLS read ล้ม ("Unable to read data from the transport connection: Operation canceled")
- **แก้:** `sudo systemctl restart actions.runner.NuimanLP-srisurart-pos-flutter.mob04-demo.service` (ผู้ใช้ `cloud`) → runner online แล้วรับงานทันที · Ansible `ok=51 changed=15 failed=0`
- หลักฐานบน VM: `.current_sha` = `847e7ef19b817dd96f816211656e5b7ce4d1c404` · `/health/ready` 200 · api-1..3 + worker ใช้ image tag `847e7ef…` · `/app/exports` เขียนได้โดย worker · `POST/GET /api/v1/backup/import` ไม่มี token = 401 (route มีจริง) · `flutter_bootstrap.js` ใน web volume ชี้ `main.847e7ef19b81.dart.js` ซึ่งมี `backup/import`
- บทเรียน: เช็ก `gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners` ก่อน approve — service `active` ไม่ได้แปลว่า runner online

## 9. POC สำหรับ owner (ทำบน `mob04` — ยังไม่เคยรันจริง)
1. เปิดแอปด้วย Incognito/โปรไฟล์ที่สะอาด ล็อกอินเป็นเจ้าของร้านบนเครื่องที่ enrol แล้ว
2. **ตั้งค่า → สำรอง/กู้คืน → กู้คืนข้อมูล** → เลือกไฟล์สำรอง (`.json`, ไม่เกิน 10 MB)
3. ถ้าร้านมีข้อมูลอยู่ → เป็นโหมดแทนที่ → **พิมพ์ชื่อร้านให้ตรง** (ชื่อร้านใน ตั้งค่า) แล้วยืนยัน
4. รอจนขึ้นสำเร็จ (ห้ามปิดแท็บ — ถ้าปิด/รีเฟรช แอปจะตามงานต่อเองตอนเปิดใหม่)
5. ตรวจ: จำนวนสินค้า/ลูกค้า, ประวัติบิลและคืนสินค้า, ขายบิลใหม่ 1 ใบ (เลขใบเสร็จต้องไม่ชน)
6. **เครื่องอื่นของร้านเดียวกัน:** ล้าง site data (หรือติดตั้งใหม่) ก่อนใช้งานต่อ
7. ตรวจสำเนาก่อน import ตามข้อ 5 ว่ามีไฟล์ `<jobId>.json` และขนาดไม่ใช่ศูนย์

## 10. คำถามที่รอ owner
1. รับรอง ADR-0005 แก้ข้อ 5 + ข้อความไทยใหม่ใน `02 §8.1.1` (ปัจจุบัน `agent ร่าง`)
2. สำเนา pre-import เก็บนานเท่าไร / ใครลบ (PDPA) — ตอนนี้ไม่ลบเลย
3. อุปกรณ์อื่นหลัง replace: ให้รีเซ็ตเองอัตโนมัติ (เลข "data version") หรือคงให้ล้างมือ
4. จะ pull ประวัติ shifts / movements / suppliers เข้าแอปหรือไม่
