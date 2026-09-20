# Ticket #212 Slice 13b `fe.pull-cursor` — Keyset Pull Sync & Stock Protection

> **วันที่:** 2026-09-20  
> **Ticket / Issue:** #212 (ส่วน B: `fe.pull-cursor`)  
> **Lane:** Lane B (`fe.pull-cursor`)  
> **Branch:** `feat/212-pull-cursor`  
> **อ้างอิง Spec:**
> - `docs/Backend_design/08_PHASE2_SPEC.md §15` (Pull #191, B4)
> - `docs/Backend_design/09_PHASE2_LANES.md §3, §6` (Lane B: `fe.pull-cursor`)
> - `docs/Backend_design/adr/0010-client-write-through-cache.md §D3` (Stock Protection during sync)

---

## 1. บริบทและเป้าหมาย

ในระบบ POS Offline-first ของ Phase 2 ข้อมูลผลิตภัณฑ์ (Products), ลูกค้า (Customers), และช่าง (Mechanics) ต้องซิงค์จาก Server ลงมายัง Drift Cache ในเครื่องอย่างสม่ำเสมอและถูกต้อง โดยก่อนหน้านี้ Drift ใช้ `MAX(updatedAt)` จากข้อมูลในเครื่อง ซึ่งมีความเสี่ยงสูงเมื่อนาฬิกาเครื่องไม่ตรง หรือมีการแก้ไขข้อมูลย้อนหลัง

Ticket #212 ส่วน B (`fe.pull-cursor`) เข้ามาจัดการ requirement ดังต่อไปนี้:
1. **Drift Schema Bump v10 → v11**: เพิ่มตาราง `sync_cursors (entity TEXT PRIMARY KEY, cursor TEXT, updated_at DATETIME)` เพื่อบันทึก server cursor ต่อ entity
2. **Server-Provided Keyset Cursor (`meta.nextCursor`)**: Cursor ต้องมาจาก `meta.nextCursor` ของ Server เท่านั้น ห้ามคำนวณจากแถวในเครื่อง
3. **30-Second Rewind Window**: หน้าแรกของแต่ละรอบการดึง ให้ใช้ `updatedSince = cursor - 30 วินาที` และ **ไม่ส่ง `afterId`**; หน้าต่อไปจึงเดินตาม `nextCursor` (`updatedSince` + `afterId`) จนกว่า `nextCursor == null`
4. **Stock Protection (ADR-0010 §D3 / 08 §15)**: สำหรับสินค้าใดๆ ที่มี operation ค้างอยู่ใน `outbox_ops` (`pending` หรือ `stuck`) การ pull sync ต้อง **ไม่เขียนทับ** `stock` ในเครื่องด้วยค่าสต็อกที่ server ส่งมา
5. **Tombstone Exclusion**: กรองแถวที่ถูกลบ (`deletedAt != null`) และแถว `import-tombstone` (`brand == 'import-tombstone'` สำหรับ products, `code.startsWith('import-tombstone')` สำหรับ customers/mechanics) ออกจากรายการเลือกทั้งหมด
6. **Push-then-Pull Order (08 §15)**: `SyncService` ต้องทริกเกอร์ `pull()` หลังจากที่การ `push()` สำเร็จเสร็จสิ้น เมื่อสถานะเป็น `online`

---

## 2. การเปลี่ยนแปลงที่ทำ

### 2.1 Drift Schema v11
- `frontend/lib/data/db/tables.dart`:
  - สร้าง Table `SyncCursors` มีคอลัมน์ `entity` (PK), `cursor` (nullable TEXT), `updatedAt` (DateTime)
- `frontend/lib/data/db/database.dart`:
  - เพิ่ม `SyncCursors` ใน `@DriftDatabase(tables: [...])`
  - ปรับ `schemaVersion => 11`
  - เพิ่ม migration step `if (from < 11)` รัน `m.createTable(syncCursors);`
- รัน Drift codegen ผ่าน `dart run build_runner build` ได้ `database.g.dart` อัปเดตสมบูรณ์

### 2.2 Repositories: Keyset Pull & Tombstones
- `frontend/lib/data/repositories/api_products_repository.dart`:
  - `syncFromServer({bool forceFull = false})`:
    - อ่าน cursor จาก `sync_cursors` (entity: `'products'`)
    - หน้าแรกของรอบคำนวณ `updatedSince = cursor - 30s` และไม่ส่ง `afterId`
    - อ่านรายการ product IDs จาก `outbox_ops` ที่มีสถานะ `pending` หรือ `stuck`
    - เมื่อ server ส่งรายการสินค้ามา หากสินค้านั้นมี active outbox op จะคงค่า `stock` เดิมในเครื่องไว้ (ไม่เขียนทับ)
    - เดินตาม `res.nextCursor` ทีละหน้าจนหมด พร้อม break guard ป้องกัน infinite loop
    - บันทึก cursor ล่าสุดจาก server ลงใน `sync_cursors`
  - `getAll()`, `watchAll()`, `getById()`:
    - กรองสินค้าที่ไม่ใช่ deleted และ `brand != 'import-tombstone'`
- `frontend/lib/data/repositories/api_customers_repository.dart`:
  - `syncFromServer`: บันทึก cursor ลง `sync_cursors` (entity: `'customers'`) พร้อม 30s rewind
  - `getCustomers()`: กรองแถวที่ไม่ใช่ deleted และ `code NOT LIKE 'import-tombstone%'`
- `frontend/lib/data/repositories/api_mechanics_repository.dart`:
  - `syncFromServer`: บันทึก cursor ลง `sync_cursors` (entity: `'mechanics'`) พร้อม 30s rewind
  - `getMechanics()`: กรองแถวที่ไม่ใช่ deleted และ `code NOT LIKE 'import-tombstone%'`

### 2.3 Sync Service & Push-then-Pull Wiring
- `frontend/lib/data/sync/sync_service.dart`:
  - เพิ่ม `onPull` callback และเมธอด `pull()`
  - ปรับการ handle push batch response ให้รองรับทั้ง `decoded['data']['results']` และ `decoded['results']`
  - ในบล็อก `finally` ของ `push()`: เมื่อสถานะเป็น `SyncStatus.online` ให้เรียก `pull()` ทันทีตาม 08 §15
- `frontend/lib/presentation/repositories/repository_providers.dart`:
  - ส่งฟังก์ชัน `triggerEntityPull` ให้กับ `SyncService(onPull: ...)` เพื่อซิงค์ Products, Customers, Mechanics เมื่อ push เสร็จ

### 2.4 Test Suite & Regression Fixes
- เพิ่มชุดทดสอบใหม่ `frontend/test/pull_sync_test.dart` ครอบคลุม 7 เคส:
  1. `sync_cursors` table exists and supports upsert
  2. `ApiProductsRepository`: หน้าแรก rewind 30s และ omit `afterId`, หน้าถัดไปเดินตาม `nextCursor`
  3. `ApiProductsRepository`: สินค้าที่มี op ค้างใน `outbox_ops` คงสต็อกในเครื่องไว้
  4. `ApiProductsRepository`: ซ่อน deleted rows และ `import-tombstone` จาก `getAll()`
  5. `ApiCustomersRepository`: บันทึก server nextCursor และกรอง `import-tombstone` customers
  6. `ApiMechanicsRepository`: บันทึก server nextCursor และกรอง `import-tombstone` mechanics
  7. `SyncService`: `pull()` ถูกเรียกหลัง `push()` สำเร็จในโหมด online
- ปรับ expectation migration version ใน:
  - `frontend/test/schema_v1_to_v3_migration_test.dart`
  - `frontend/test/schema_v3_migration_test.dart`
  - `frontend/test/schema_v4_migration_test.dart`
  - `frontend/test/schema_v6_migration_test.dart`
  - `frontend/test/schema_v7_migration_test.dart`
  - `frontend/test/doc_number_service_test.dart`
- ปรับปรุงการทดสอบเดิม:
  - `api_products_repository_test.dart`: อัปเดตทดสอบ cursor ให้ใช้ `sync_cursors` พร้อม 30s rewind
  - `route_smoke_test.dart`: ตั้งค่า `useApiRepositories: false` สำหรับการทดสอบเรนเดอร์หน้าจอ UI บน Drift in-memory
  - `offline_credit_override_test.dart`: ส่ง `apiClient` และ `syncFacade` ที่ mock ไว้เข้า `repositoryProviders` เพื่อป้องกัน dangling background I/O บน closed database

---

## 3. ผลการทดสอบและการตรวจสอบคุณภาพ (Quality Gates)

- `dart analyze`: **Clean (No issues found!)**
- `flutter test test/pull_sync_test.dart`: **7/7 tests passed!**
- `flutter test` (Full frontend test suite): **533/533 tests passed! (100% Green)**
- Drift codegen (`database.g.dart`) สร้างเสร็จสมบูรณ์บน ASCII path
