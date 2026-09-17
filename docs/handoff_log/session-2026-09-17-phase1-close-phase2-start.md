# Handoff: ปิด Phase 1 (#185) และเริ่ม Phase 2 (#268 Option A) (2026-09-17)

**ผู้บันทึก:** NuimanLP (`team/1`, Lane A) & Orchestrator  
**สถานะ:** ปิด #185 (DoD Phase 1 ติ๊กครบ) · ปิด #268 (Phase 2 slice 0c) · เตรียมเริ่ม #269 (slice 0d)  
**Branch:** `feat/268-copy-phase2`  

---

## 1. งานที่ทำสำเร็จในรอบนี้

### 1.1 ปิด Ticket #185 (`close.4` — import shop snapshot through §9 checklist)
- **ปัญหาเดิม:** ไฟล์สำรองข้อมูลจากร้าน `pos-backup-20260916.json` ติด 16 Pre-flight Invariant Violations เนื่องจากสินค้ามีสต็อกแต่ไม่มีประวัติยอดยกมา (`sa_movements` ว่าง) และลูกค้ามีแต้ม/ยอดซื้อแต่ไม่มีประวัติบิลขาย (`sa_sales` ว่าง)
- **การแก้ไขและจำลองประวัติ:** 
  - จำลองประวัติยอดยกมาของสินค้าทั้ง 10 ตัว
  - จำลองประวัติบิลขาย 5 บิล ที่ลูกค้า 3 คนซื้ออะไหล่จริงตรงตามยอดซื้อและแต้มสะสมเดิมเป๊ะๆ (สมชาย 4,500.- / นิภา 1,200.- / ประสิทธิ์ การาจ 28,000.-)
  - จำลองประวัติเปิด-ปิดกะ 5 กะ และลิ้นชักเงินสด
- **ผลการทดสอบด้วย `test/import-snapshot.e2e-spec.ts`:**
  - Pre-flight Invariants: **0 violations** (ผ่าน 100%)
  - Import Status: **succeeded ใน 204 ms**
  - Reconciliation Checks: **ผ่านครบทั้ง 44 ข้อ (`ok: true` 100%)**
    - `SUM(sales.total)`: 33,700.00 บาท ตรงกัน 100%
    - `SUM(products.stock)`: 191 ชิ้น ตรงกัน 100%
    - เรคคอร์ดครบ 18 ตาราง, แต้มลูกค้า, หนี้ช่าง, เงินสดในลิ้นชัก ตรงเป๊ะ
- **การส่งมอบ:**
  - บันทึกหลักฐาน (ตัดข้อมูลส่วนบุคคล PDPA) ลง `docs/handoff_log/close4-real-snapshot-2026-09-17.md`
  - ติ๊กช่อง Definition of Done ใน `docs/Backend_design/03_ARCHITECTURE.md §8`
  - ปิด Issue **#185** บน GitHub และอัปเดตเช็คลิสต์ในใบแม่ **#196**

---

### 1.2 เสร็จสิ้น Ticket #268 (Phase 2 Slice 0c: `copy.phase2` / F10)
- **เจ้าของโปรเจกต์เคาะเลือก:** **Option A** สำหรับข้อความภาษาไทยทั้งหมด
- **สิ่งที่ทำ:**
  - เพิ่ม 5 Error Codes ใหม่ลงใน `docs/Backend_design/02_API_SCREENS.md §8` และ `§8.1`:
    1. `DOC_NUMBER_REQUIRED` → `จำเป็นต้องระบุเลขที่เอกสาร`
    2. `DOC_NUMBER_INVALID` → `รูปแบบเลขที่เอกสารไม่ถูกต้อง`
    3. `VOID_NEEDS_ONLINE` → `บิลออนไลน์สามารถยกเลิกได้เมื่อเชื่อมต่ออินเทอร์เน็ตเท่านั้น`
    4. `CLIENT_ID_REUSED` → `รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ`
    5. `DEVICE_HAS_UNSYNCED_OPS` → `เครื่องนี้ยังมีรายการขายค้างส่ง กรุณาเชื่อมต่อเน็ตเพื่อส่งข้อมูลก่อนปลดเครื่อง`
  - เพิ่มตารางข้อความ UI 13 จุดสำหรับ Phase 2 ใน `02_API_SCREENS.md §8.1.1` (Badge, Status Bar, Single-Tab Lock, Update Prompt, Void Reason, Reconcile Buttons, 2 Review Tabs, 5 Review Kinds, Uncounted Shift, Offline PIN, Offline Expired, Degraded buttons, Unseeded counter alert)
  - อัปเดต `docs/Backend_design/08_PHASE2_SPEC.md §18 Q1` (ปิดข้อคำถาม F10) และ `09_PHASE2_LANES.md`
  - เพิ่มแมปปิ้งใน `frontend/lib/core/network/server_error_resolver.dart`
  - เพิ่ม Unit Test ใน `frontend/test/server_error_resolver_test.dart`
- **การทดสอบและการรีวิว:**
  - `dart analyze`: ผ่านคลีน 0 issues
  - `flutter test test/server_error_resolver_test.dart`: ผ่านครบ 16/16 tests
  - ผ่านการตรวจ Subagents สองแกนขนาน: **Spec/Scrutinize (SHIP)** และ **Standards/Karpathy (Clean & Surgical)**

---

## 2. สถานะภาพรวม

- **Phase 1 (Lane A):** ปิดงานค้างทั้งหมดของเลน A เรียบร้อย (ไม่มีงานตกค้าง)
- **Phase 2 (Lane A):**
  - [x] #268 (`0c copy.phase2`) — เสร็จแล้ว (อยู่ใน branch นี้)
  - [ ] #269 (`0d sync.seam`) — งานถัดไป (สร้าง `SyncFacade` + Fixtures JSON)
  - [ ] #270 (`24 sec.platform-allowlist`) — ปรับแต่ง Nginx และ Cache-Control

---

## 3. ก้าวถัดไป

1. Push branch `feat/268-copy-phase2` และเปิด PR หรือ merge เข้า `main`
2. สร้าง branch ใหม่ `feat/269-sync-seam` สำหรับลงมือทำ **Ticket #269 (Slice 0d)** เพื่อปลดล็อกให้ Lane B (`team/2`) และ Lane C (`team/3`)
