# Handoff — release สุดท้ายก่อนส่งงาน: `main` = `53fdd1b` deploy ขึ้น `mob04` (2026-10-07)

**วันที่:** 2026-10-07 · **สถานะ:** deploy แล้ว · **owner สั่งหยุดพัฒนา** (freeze เพื่อส่งงาน) · เหลือ #344 / #380 / #363
**ต่อจาก:** [`session-2026-10-06-uuid-cutover-mob04.md`](session-2026-10-06-uuid-cutover-mob04.md) · [`session-2026-10-05-k6-capacity-run.md`](session-2026-10-05-k6-capacity-run.md)
**วิธีตรวจ:** SHA/วัน-เวลา merge/run id/ผู้ approve อ่านจาก `gh` ในเซสชันนี้ · ค่าฝั่ง VM (`.current_sha`, `/health/ready`, Ansible recap, โฟลเดอร์ backup) **เป็นผลที่ orchestrator รายงาน — เซสชันนี้ไม่ได้ SSH เข้า VM ตรวจซ้ำ**

## 1. สรุปสั้น
- `main` = `53fdd1b` (PR #658 `develop` → `main`, merge commit) · deploy run `37594471937` approve โดย `NuimanLP` ("final release 53fdd1b") · job `deploy to demo` success 08:33–08:35Z
- VM `/opt/pos/.current_sha` = `53fdd1b137a34a01b37bede78f1953d1c7c037c3`, Ansible `failed=0`, `/health/ready` 200 (รายงานจาก orchestrator)
- run `37594348618` (SHA เดียวกัน) **skip แต่ขึ้น success** — image อีกฝั่งยังไม่มี → ตามกติกา "green ไม่ใช่หลักฐาน"
- APK ของ `53fdd1b`: `android-apk.yml` run `37594750249` **triggered, ตอนเขียนยัง in_progress** — `gh release list` ยังไม่มี `apk-53fdd1b` (มีถึง `apk-dd659e2`) → ดู Releases
- owner: **หยุดพัฒนาตรงนี้เพื่อส่งงาน** (บันทึกใน CLAUDE.md *Branch strategy*)

## 2. PR ที่ merge (ทุกตัวเข้า `develop` ก่อน แล้ว `develop` → `main` ด้วย merge commit)
| PR | base | งาน | merge |
|---|---|---|---|
| #637–#646 | develop / main | **merge เมื่อ 2026-10-06 (ไม่ใช่วันนี้)** — #638 replay by client id ก่อน parse · #640 `assertValidTenantId` → `common/ids.ts` · #641 e2e expired-key replay · #642/#644 `ApiException` ไม่ถึง presentation/ไม่หลุด repository · #643 pos_trust test OS-agnostic · #645 customer/credit-payment non-verdict = park ไม่ queue · #646 ข้อความ IN_FLIGHT ทุกเส้น · #639 = release → `92dcdee` | `4448562`…`105661e` |
| #647 | develop | CI รันทุก push เข้า `develop` | `09b80e0` |
| #648 | **main** | release #640–#647 | `aab58ae` |
| #649 | develop | owner รับรองข้อความไทย agent ร่างทั้งหมด (docs) | `a9c0c91` |
| #650 | **main** | release #649 | `b02224c` |
| #651 | develop | 10 โค้ดที่ไม่มีข้อความไทย (`DOC_NUMBER_EXHAUSTED`, `SALE_HAS_RETURNS`, `SALE_ID_REUSED`, `SHIFT_ALREADY_CLOSED`, `CREDIT_LIMIT_EXCEEDED`, `CREDIT_PAYMENT_EXCEEDS_BALANCE`, `CREDIT_PAYMENT_ID_REUSED`, `RETURN_PRICE_MISMATCH`, `REFUND_METHOD_NOT_ALLOWED`, `PO_CANCELLED`) + ข้อความเฉพาะของ platform-ui (`INVALID_TENANT_ID`, `DEVICE_ALREADY_ENROLLED`, `OWNER_NOT_FOUND`) + ประโยคเดียวสำหรับ overpayment / return-price ทุกเส้น รวม `/sync/push` (`sync.service.ts` + e2e) | `68eebd1` |
| #652 | **main** | release #651 → deploy run `37585778195` (approve: "deploy dd659e2") | `dd659e2` |
| #653 | develop | owner รับรอง 10 ข้อความนั้น (docs + แก้ resolver/doc_number_service/เทสต์ตามให้ตรง) | `5dd5342` |
| #654 | develop | k6: key ไม่ชนข้ามเครื่อง, `to_mib`, `assertBurstSafe` ฯลฯ (#380) | `547e187` |
| #655 | develop | k6: review fix ที่ตกจาก #654 (checks threshold, RSS นับ restart/OOM, บันทึก 27 VU) | `e4b604b` |
| #656 | develop | study pack + `progress-report-P1.docx/.pdf` สำหรับพรีเซนต์ (ใหม่: `docs/study/20_slide_outline.md`) | `2306531` |
| #657 | develop | ปิด 4 เส้น double-write ตอน retry (ข้อ 3) | `f3ef647` |
| #658 | **main** | release สุดท้าย | `53fdd1b` |

## 3. #657 — 4 เส้นที่ retry แล้วเขียนซ้ำ (ทดสอบให้แดงก่อนแก้ — `double_write_retry_paths_test.dart` 16 เทสต์, `flutter test` 1472 ผ่านตามตัว PR)
1. **ชำระเครดิต:** เช็ก overpayment ก่อนหาความพยายามที่จอดไว้ → retry ถูกปฏิเสธหรือออกด้วย key ใหม่ = จ่ายซ้ำ · แก้: `allowOverpayment` ไม่อยู่ใน fingerprint, ความพยายามที่จอดข้ามเช็กในเครื่องและส่ง body เดิม (รวม consent)
2. **ปิดก่อน apply ในเครื่อง:** apply พัง → `UNREADABLE_RESPONSE` แต่ความพยายามถูกปิดแล้ว → กดซ้ำได้ key ใหม่ = สร้างซ้ำ · แก้: ปิดหลัง apply สำเร็จ ใน `addCreditPayment` / `addCustomer` / `updateCustomer` / `addMechanic`
3. **`updateCustomer` A → B → A:** เล่น key เก่าซ้ำ · แก้: `PendingWrites.closeWhere` — แก้ไขใหม่ที่ต่างจากเดิม**ปิดการแก้ไขเก่าที่ยังจอดของระเบียนเดียวกันตอนส่ง** (PATCH แทนค่าทั้งก้อน) · บันทึกใน `api_wire.dart` ข้อ 5 และ `08 §5` (owner 2026-10-07)
4. **`adjustStock`:** ออก key ใหม่ทุกครั้ง · แก้: จอดด้วย `PendingWrites` (fingerprint `[productId, delta, type, note]`) — 2xx/4xx ปิด, 5xx/429/IN_FLIGHT/transport คงจอด; 2xx ที่ไม่ใช่ Map = `UNREADABLE_RESPONSE`
- ไม่มีรูป request เปลี่ยน (`fixtures/client-requests/` ไม่ต่าง) · ไม่แก้ข้อความไทย

## 4. `mob04` backup (ทำโดย orchestrator; ไม่ได้ตรวจซ้ำในเซสชันนี้)
- **ย้าย (ไม่ลบ) 20 ไฟล์ dump+sidecar** ไป `/opt/pos/backups-removed-20261007/`: dump 20 ไบต์ที่ล้ม (2026-09-29/30), dump 0 tenant (09-30/10-01), dump เฉพาะ tenant ทดสอบ (10-02..10-05), ตัวซ้ำ 10-06 03:00
- **เก็บไว้ใน `/opt/pos/backups/`:** `pos_backup_20261006_035714Z.sql.gz` (ทั้ง 10 tenant ก่อนล้าง UUID), nightly ล่าสุด, etcd snapshot, cron log
- 🔴 **แก้ข้อมูลผิดในเอกสารเดิม:** handoff 2026-10-06 บอกว่ามีสำเนาที่เครื่อง owner `~/Downloads/srisurart-mob04-backups/` — โฟลเดอร์นั้น**ไม่มีแล้ว** → **ไม่มีสำเนาออกนอก VM เลย** (#363 ยัง parked) · ดิสก์ `mob04` เสีย = ข้อมูลทั้งหมดหาย · อย่าเขียนว่า "backup พร้อม"

## 5. k6 / #380
- ผลรอบ 2026-10-05 ใช้อ้างติ๊ก DoD ไม่ได้ (tooling บั๊ก) → #654/#655 แก้แล้ว → **ต้องรันใหม่** · ช่อง k6 ของ `03 §8` ยังไม่ติ๊ก (owner ตัดสินหลังอ่านผลรอบใหม่)
- **owner 2026-10-07: replay ที่ 27 VU (3 เครื่อง × 9) ใช้แทน 100 VU ของ `02 §9`** — บันทึกที่แถว replay ใน `02 §9`
- `measure-container-rss.sh` ตัวใหม่ **ยังไม่อยู่บน `mob04`** (มีแต่ `provision.yml` หรือ `install` มือที่อัปเดต `/opt/pos/scripts`) → ก่อนรันรอบหน้าต้องลงเอง
- เอกสารที่ยังเก่า ไม่ได้แก้ (นอกขอบเขต PR นี้): `03_ARCHITECTURE.md` บรรทัด "p10 k6 — ยังไม่มีตัวเลขวัดจริงเลย" ขัดกับรอบ 2026-10-05

## 6. ยังเปิด / ข้อจำกัดที่รู้
- **#344** — เริ่มใหม่จาก AC1 บน tenant `ศรีสุราษฎร์เจริญยนต์` (owner ให้ agent ขับผ่าน Chrome extension) · **ยังไม่ได้เริ่ม** ตอนเขียน · เช็กลิสต์ `demo-344-checklist-2026-09-30.md`
- **#380** — รันใหม่ด้วย tooling ที่แก้แล้ว (ข้อ 5) · **#363/#288** parked (ข้อ 4) · #443 / #231 ยังเปิดตามเดิม
- ข้อสังเกตความเสี่ยงต่ำ ไม่ได้แก้: `/sync/push` replay ของ sales เรียงบรรทัดตาม `line_no` ที่เก็บ (client ส่ง `lineNo` = i+1 เสมอ จึงไม่มีผลวันนี้) · import สองทาง `offline_pin_repository.dart` ↔ `auth_repository.dart`
- ข้อจำกัดที่ออกแบบไว้: `PendingWrites` TTL 10 นาที — เกินแล้วการกดซ้ำนับเป็นรายการใหม่ (ไม่ replay)

## 7. บทเรียน
- **#654 ถูก auto-merge ก่อน commit สุดท้าย** — merge 07:56:32Z ที่ head `3b251a0` (`gh`); ตาม body ของ #655 เปิด auto-merge 07:48Z และ review-fix ที่ push ทีหลังไม่เข้า `develop` · กู้ด้วย #655 (cherry-pick, commit `5faca68`) · เกิดซ้ำของบทเรียนเดิมใน CLAUDE.md (ตรวจ `headRefOid` ตอน merge · ห้าม auto-merge ระหว่างที่ agent ยัง push)
- deploy หลัง merge เข้า `main` ยิง 2 run (Server CI / Flutter CI) · run แรก skip เขียว — approve run ที่สอง แล้วเช็ก `.current_sha` (ครั้งนี้: `37594348618` skip, `37594471937` deploy)
- release 4 รอบในวันเดียว (`aab58ae` → `b02224c` → `dd659e2` → `53fdd1b`) · approval ของ `dd659e2` และ `53fdd1b` มี comment ระบุเหตุผล (เช็กจาก `gh api …/approvals`) · APK ของ `aab58ae` มี 2 run: `37569871698` ผ่าน, `37570126939` ล้ม — release `apk-aab58ae` มีอยู่ (ยังไม่ได้ไล่ว่า asset มาจาก run ไหน)
