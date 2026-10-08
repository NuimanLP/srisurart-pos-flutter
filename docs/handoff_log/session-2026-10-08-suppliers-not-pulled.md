# ทำไมสินค้าไม่มีซัพพลายเออร์หลังนำเข้า (2026-10-08)

**อาการ:** หลังนำเข้า `pos-real-suppliers-20261007-uuid.json` ผ่าน ตั้งค่า → สำรอง/กู้คืน → กู้คืนข้อมูล บน `mob04`
แท็บ **ซัพพลายเออร์ · Suppliers** ของทุกสินค้าขึ้น `0 ซัพฯ` / `ยังไม่มีซัพพลายเออร์สำหรับสินค้านี้`

## 1. ไฟล์สำรองไม่ผิด
ตรวจไฟล์แล้ว (สคริปต์ Python อ่านอย่างเดียว):
- `sa_suppliers` = 51 แถว และ `productId` ทั้ง 51 แถวตรงกับ `id` ใน `sa_products` (51/51)
- `__meta.recordCounts.suppliers` = 51 · `version` 2 · ร้าน `ศรีสุราษฎร์เจริญยนต์`
- ตัวอย่างแถว: `{ productId: f154eecc-…, name: "จิ้นเซ่งฮวดอะไหล่ยนต์", unitCost: 100, freight: 0 }`

## 2. สาเหตุ: แอปไม่ดึงซัพพลายเออร์จากเซิร์ฟเวอร์
- **เซิร์ฟเวอร์ได้ข้อมูลไปแล้ว:** `TenantImportService` เขียนแถวลงตาราง `suppliers` ใน Postgres
  และมี API ให้อ่าน `GET /api/v1/products/:id/suppliers` (`server/src/products/products.controller.ts:91`)
  กับ API เขียน `POST/PATCH/DELETE /api/v1/suppliers` (`server/src/products/catalogue.controllers.ts:76`)
- **แอปอ่านจาก Drift ในเครื่องอย่างเดียว:** `SuppliersRepository` (`frontend/lib/data/repositories/suppliers_repository.dart`)
  อ่านและเขียนแค่ตาราง Drift `suppliers` ส่วน `repository_providers.dart:216` ใช้ตัวนี้ทั้งใน build ปกติและ build API
  และ `database.dart` ก็เขียนกำกับไว้เองว่า *"suppliers (Drift-only on every build, never pulled)"*
- ผลที่ได้คือข้อมูลอยู่ใน Postgres ครบ แต่ไม่มีโค้ดส่วนไหนพามันมาลง Drift ในเครื่อง หน้าจอเลยว่าง
  เรื่องนี้เป็นข้อจำกัดที่บันทึกไว้แล้วใน `session-2026-10-08-owner-import.md` ข้อ 6 (ข)
  ("suppliers … ไม่ถูก pull เข้าแอป")
- ผลข้างเคียงบน build API: ซัพพลายเออร์ที่กด "เพิ่มซัพฯ" ในแอปจะลงแค่ Drift ไม่ถึงเซิร์ฟเวอร์
  และหายไปเมื่อเครื่องล้าง site data

## 3. ทางแก้ (owner สั่งแก้ 2026-10-08)
เฉพาะ build API (`useApiRepositories`) — build Drift-only ยังทำงานเหมือนเดิม
1. **อ่าน:** ให้เซิร์ฟเวอร์เป็นต้นทางจริง โดยดึงซัพพลายเออร์มาเก็บใน Drift ด้วย และหน้าจอยังอ่าน Drift ตามเดิม
   (เครื่องไม่มีเน็ตก็ยังเห็น)
2. **เขียน:** เพิ่ม/แก้/ลบ ส่งไปที่ `POST/PATCH/DELETE /suppliers` พร้อม `Idempotency-Key`
   แล้วเขียน Drift จากคำตอบของเซิร์ฟเวอร์เท่านั้น ใช้แบบเดียวกับ `ApiSettingsRepository`
   คือเขียนได้เฉพาะตอนออนไลน์ ถ้ามี 5xx ห้ามเขียนลงเครื่องเอง
3. ข้อความ error ภาษาไทยที่เพิ่มใหม่ (ถ้ามี) ให้ใส่ป้าย `agent ร่าง` ไว้จนกว่า owner จะรับรอง

สถานะงาน: ส่ง agent ไปทำแล้ว ผลจะต่อท้ายไฟล์นี้

## 4. ผลการแก้ (branch `fix/suppliers-api-pull`, ยังไม่เปิด PR)
**เซิร์ฟเวอร์**
- เพิ่ม `GET /api/v1/suppliers` (`SuppliersController.list` → `SuppliersService.list`) คืนซัพพลายเออร์ทั้งร้าน
  เฉพาะของสินค้าที่ยังไม่ถูกลบ ใช้ `runTx` แบบเดียวกับ route อื่น (ผ่าน RLS) และเป็น GET จึงไม่มี idempotency
- ตาราง `suppliers` ไม่มี `updated_at` และลบแบบ hard delete จึงไม่มี cursor: แอปดึงทั้งชุดแล้วแทนที่ของในเครื่อง
- ไม่มี migration ใหม่

**แอป (เฉพาะ build API, `useApi`) — build Drift-only ไม่เปลี่ยน**
- `ApiSuppliersRepository` (`frontend/lib/data/repositories/api_suppliers_repository.dart`)
  - `pullFromServer()` ดึง `GET /suppliers` มาแทนที่ตาราง Drift `suppliers` ทั้งตาราง ฟังก์ชันนี้ไม่ throw
    เขียนผ่าน `writeCacheIfCurrent` (คำตอบที่มาถึงหลังสลับร้านจะไม่ถูกเขียน) และไม่เขียนทับถ้ามีการเพิ่ม/แก้/ลบ
    ที่ได้คำตอบแล้วระหว่างที่ GET ยังค้างอยู่
  - `getSuppliers()` ดึงจากเซิร์ฟเวอร์ก่อนแล้วจึงอ่าน Drift (หน้าจอเดิมไม่ต้องแก้) ถ้าออฟไลน์ก็ยังเห็นข้อมูลชุดล่าสุดในเครื่อง
  - เพิ่ม/แก้/ลบ ส่ง `POST/PATCH/DELETE /suppliers` พร้อม `Idempotency-Key` เงินส่งเป็น string `"85.00"`
    และเขียน Drift จากคำตอบของเซิร์ฟเวอร์เท่านั้น ถ้าเพิ่มแล้วเจอ 5xx/429 หรือคำตอบหาย ระบบจะเก็บ key เดิมไว้ (`PendingWrites`)
    กดซ้ำจึงไม่ได้ซัพฯ ซ้ำ ข้อผิดพลาดจะเป็น `PosException` ภาษาไทย (ไม่มีข้อความใหม่)
- `triggerEntityPull` (ตอนต่อเน็ตกลับมา, สลับร้าน, หลัง owner import) ดึงซัพพลายเออร์ด้วย
- `resetPulledCache` ล้างตาราง `suppliers` ด้วยแล้ว และลบคอมเมนต์ "never pulled" ออก
- fixture `client-requests/suppliers.{create,update,delete}.json` + `CONTRACT_IDS.supplier` (เซิร์ฟเวอร์ seed แถวไว้ให้)

**ข้อควรรู้**
- รอบ pull แรกบน build API จะ**ลบ**ซัพฯ ที่เคยเพิ่มไว้ใน Drift อย่างเดียว (ก่อนการแก้นี้ ข้อมูลพวกนั้นไม่เคยถึงเซิร์ฟเวอร์)
  บน `mob04` หลังการ import ตาราง Drift ถูกล้างไปแล้ว จึงไม่มีข้อมูลหาย
- ถ้าเครือข่ายค้าง (ไม่ใช่ปฏิเสธการเชื่อมต่อ) การเปิดแท็บซัพฯ อาจรอ GET นานถึง 15 วินาที เหมือนรายการสินค้าที่เป็นอยู่แล้ว
- ยังไม่ได้ทดสอบบน `mob04` จริง ต้อง deploy แล้วเปิดแท็บ ซัพพลายเออร์ หลัง import เพื่อยืนยัน
