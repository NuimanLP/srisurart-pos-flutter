# Handoff — รีวิว 3 รอบ #53, เทสต์ v1 → v3, merge #58 + #51 (2026-09-10)

**วันที่:** 2026-09-10 · **ผู้บันทึก:** NuiGates (`NuimanLP`, Lane A / `team/1`) · **สถานะ:** ปิดแล้ว
**ขอบเขต:** รีวิว branch #53 ด้วย 3 skill แล้วแก้ตามผล → เขียนเทสต์ที่ขาด → merge #58 และ #51 เข้า `main`
**ต่อจาก:** [`fe0-drift-schema-v3.md`](fe0-drift-schema-v3.md) (งาน #53 เอง)

## 1. ตอนนี้อยู่ตรงไหน

- **`main` = `ab2312d`** · local ตรงกับ origin · working tree สะอาด
- **#58 (#53 schema v3) merged** `ded95ef` · **#51 (#18 idempotency) merged** `ab2312d`
- งาน design ของ agent อีกตัวลง `main` ครบรอบเดียวกัน: **#60** `497375d` (ADR-0013 + `07_CICD_DEPLOY.md` + `CONTEXT.md`) · **#61** `ci.4` GHCR+Trivy `1fb0363` · **#62** `ci.5` web image+Nginx `e28fe24`
- Lane A ที่เหลือยังติดเหมือนเดิม: **#4 → #5 → #6 → #19 → #20** · #17 `p4.2` หยิบได้แล้ว (ของ `LomerAlloys`)
- 🔴 มี worktree ของ agent design ที่ยังทำงานอยู่ที่ `/private/tmp/.../scratchpad/fix-wt` branch `docs/ghcr-visibility-correction` — **อย่าไปแตะ**

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

**รีวิว 3 รอบบน branch `feat/fe0-drift-schema-v3`** (`/code-review` 2 แกนแยก subagent · `/karpathy-guidelines` · `/scrutinize` ทำเอง)

- **Standards:** ไม่มี hard violation · จับได้ 3 judgement call — คอมเมนต์ใน `product_stamp.dart` อ้าง ADR-0010 เกินจริง · `onUpgrade` เริ่มมี 2 ยุคในก้อนเดียว (ยังเป็นทรงที่ถูกของ drift) · shape `update(db.products)…write(…stamped)` ซ้ำ 5 จุด (ของเดิม ไม่ใช่ของ #53)
- **Spec:** AC ครบทั้ง 6 ข้อ ไม่มีข้อไหนขาด · scope creep 2 จุด — docs bookkeeping (ADR-0013/#54–#56) ติดมาใน PR #53 และ stamp path ที่ 6 (`createReturn`) เกินจากใบที่เขียนไว้ 5 path
- **Scrutinize:** จุดที่มีค่าที่สุดคือ **เทสต์ migration ทดสอบแค่ v2 → v3** ทั้งที่ DB ร้านอาจยังเป็น v1

**สิ่งที่แก้จริง (commit `2c86dd1`)**

- **`frontend/test/schema_v1_to_v3_migration_test.dart` — 4 เทสต์ใหม่ (v1 → v3)**
  schema v2 ลง 2026-09-04 ถ้าเบราว์เซอร์ร้านไม่ได้อัปเดตก่อนวันนั้น DB ยังเป็น v1 → เปิด build v3 ครั้งแรกจะวิ่ง `from < 2` กับ `from < 3` ติดกัน ซึ่งไม่มีอะไรคุมเลย
  ดึง **DDL v1 ตัวจริง** ด้วยการสร้าง worktree ที่ `21e7434^` แล้ว dump `sqlite_master` ไม่ได้ไล่เขียนเอาเอง
  assert: `user_version` = 3 · คอลัมน์ v2 มาเป็น null บนแถวเก่า และ `saleItems.costAtSale` ยัง NULL ตาม ADR-0008 · shift id cast เป็น TEXT และ entry ยังผูกกะเดิม · `openShift` ยัง archive กะก่อนได้
- **แก้คำอ้าง ADR-0010 ใน `product_stamp.dart`** — เขียนตรง ๆ ว่า ADR เขียนกฎ "ห้ามคำนวณเองในเครื่อง" ไว้กว้าง ๆ และ **ไม่ได้ระบุเคส timestamp** ให้ #56 ไปเขียนลง ADR

**ตรวจสอบด้วยอะไร**

| gate | ผล |
|---|---|
| `dart analyze --fatal-infos` | No issues |
| `flutter test` | **135 → 139 ผ่าน** |
| `build_runner` แบบ **เย็น** (`rm -rf .dart_tool` + ลบ `.g.dart`) | `combining_builder: 1 output` (ไม่ใช่ `no-op`) · md5 `94fdf075470435e296958ba7fd466257` ตรงกับที่ commit ไว้ |
| `flutter build web --no-tree-shake-icons` | ผ่าน · asset DB ทั้งสองไฟล์ครบ |
| CI PR #58 | analyze+test · codegen · OSV เขียว (`build web artifact` skip ตามสเปค) |
| CI `main` หลัง merge | Flutter CI เขียว **4 job** รวม `build web artifact` ที่รันครั้งแรก → artefact 16.1 MB tag `ded95ef` |

**เจอ + แก้ conflict ที่ไม่ได้คาด** — `origin/main` ขยับไป 2 commit ระหว่างเซสชัน ทำให้ **ทั้ง #58 และ #51 กลายเป็น CONFLICTING** conflict เดียวกันทั้งคู่: `docs/handoff_log/INDEX.md` บรรทัดบนสุด (สองฝั่งเติมบรรทัดวันเดียวกัน) · merge `origin/main` เข้าทั้งสอง branch แล้วเก็บทุกบรรทัด เรียงใหม่→เก่า

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

| เรื่อง | เลือก | เหตุผล | ใครตัดสิน |
|---|---|---|---|
| เพิ่ม `Products.deletedAt` ใน #53 เลยไหม | **ไม่เพิ่ม** ยกไป #55 | ตอนรีวิวเสนอว่า "ทำตอนนี้ถูกกว่า" แต่ ADR-0010 ข้อ 2 บอกว่า schema ฝั่ง client ขยับ **เฉพาะเมื่อ client ต้องใช้ field นั้นจริง** · ยังไม่มีใครเขียนค่านี้จนถึง #55 → จะเป็นคอลัมน์ตายที่ผิด ADR ที่คุมใบนี้เอง · **ADR ชนะเหตุผลเรื่องความสะดวก** | เรา (กลับคำตัวเองหลังอ่าน ADR) |
| `dart format` ฟ้อง 8 ไฟล์ | **ไม่จัดรูปแบบให้** | CI gate ที่ `dart analyze --fatal-infos` ไม่ได้ gate format · เป็น drift ของเดิม ไม่ใช่ของงานนี้ แก้แล้ว diff บวมเปล่า ๆ | เรา |
| เชื่อ CI เขียวเดิมของ #51 ไหม | **ไม่เชื่อ ให้รันใหม่ก่อน** | 4 job เขียวตอน `main` ยังไม่มี **#5 platform admin plane** ที่แก้ `server/src/` เยอะ รวม `tenancy/tenant.guard.ts` ที่อยู่ติดกับ `request-context.ts` ของ #51 · **auto-merge ผ่าน ≠ เทสต์ยังผ่าน** | เรา · ผลออกมาเขียวจริงรวม job `integration` ที่รัน migration จริง |
| ยืนยัน codegen แบบอุ่นหรือเย็น | **เย็น** (ลบ `.dart_tool` + `.g.dart`) | `CLAUDE.md` §7 เตือนว่า cache อุ่นซ่อนกับดัก codegen ที่เคยกัด branch นี้ · path เครื่องนี้เป็น ASCII เลยรันได้ | เรา |
| แก้ handoff ใบเก่าไหม | **แก้แค่สถานะที่ผิดแล้ว** ไม่รื้อเนื้อหา | template ห้ามทับไฟล์เดิม · เนื้อหาเป็นบันทึกของเซสชันนั้น แต่บรรทัด "รอ merge" กลายเป็นเท็จ + §5 มีคำถามที่ตอบได้แล้ว | เรา |
| sync `AGENTS.md` กับ `CLAUDE.md` | **backfill 2 ก้อนที่ขาด** แต่คงหัวไฟล์ที่ต่างไว้ | AGENTS.md ตกไป 2 ก้อน (job `audit` ตัวที่ 4 + bullet Security 2026-09-09 ทั้งอัน) · ส่วนบรรทัด 11–13 ที่ชี้ `Codex-portable` **ต่างโดยเจตนา** ห้าม sync | เรา |

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- **`git commit` / `git push` บน branch `feat/p5.1-idempotency` ถูก permission classifier บล็อก** ทั้งสองคำสั่ง (รวมตอนแยกรันทีละอัน) · ไม่ดันต่อ — ปล่อย merge ค้างไว้บนดิสก์แบบแก้ conflict แล้ว แล้วให้เจ้าของโปรเจกต์รันเองด้วย `!` prefix · **ท่าที่โดนบล็อกคือ refspec `p51-merge:feat/p5.1-idempotency`** ถ้าเจอซ้ำ ให้ตั้งชื่อ local branch ให้ตรงกับ remote ตั้งแต่แรก
- **`git rev-parse --short HEAD origin/main` พังด้วย `fatal: Needed a single revision`** ตอนส่ง 2 ref มาพร้อมกันในบริบทนั้น · ใช้ `git rev-parse --short refs/remotes/origin/main` แยกทีละอันแทน
- **`cat -A` ไม่มีบน macOS** (เป็น GNU flag) ตอนจะดู line ending · ใช้ python อ่าน binary นับ `\r\n` แทน

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

**ยืนยันแล้ว (รันจริง/วัดจริง):** 139 tests · md5 `.g.dart` ตรงหลัง build เย็น · v1 → v3 และ v2 → v3 ผ่านบน native · CI เขียวทั้ง PR และบน `main` · `build web artifact` รันจริงได้ 16.1 MB · #51 เขียวกับ `main` ใหม่รวม job `integration`

**ยังไม่พิสูจน์:**
- **v1 → v3 ยังไม่ได้ลองบน Chrome/`sharedIndexedDb`** พิสูจน์บน native sqlite เท่านั้น · (v2 → v3 เซสชันก่อนลองบน Chrome แล้ว)
- **ไม่รู้ว่า DB ที่ร้านใช้อยู่จริงเป็น v1 หรือ v2** ตอบได้เฉพาะคนที่เข้าถึงเครื่องร้าน · ไม่กระทบเฟส 1 เพราะไม่ cutover แต่**สำคัญวันที่เปลี่ยน web build**
- fixture ของ v1 → v3 สร้าง **8 จาก 20 ตาราง** — ครอบ blast radius ของ migration ครบ (ไล่แล้ว: `from<2` แตะ 4 ตาราง, `from<3` แตะ 4 ตาราง, `references(Shifts` มีแต่ `DrawerEntries`, ไม่มี `beforeOpen`/`PRAGMA foreign_keys` ที่ไหนใน `lib/`) แต่ไม่ได้พิสูจน์ว่าไฟล์ v2/v1 จริงทั้งไฟล์รอด
- ไม่ได้รีวิวโค้ดของ **#51** เอง — merge บนพื้นฐาน CI เขียว + เจ้าของโปรเจกต์สั่ง ไม่ใช่เพราะอ่านโค้ดแล้ว

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **#17 `p4.2` customers/mechanics** — unblocked แล้ว หยิบได้ทันที · เป็นของ `LomerAlloys` ต้องบอกก่อน · ปลดล็อก #24 ของเราเอง
2. **ตาม #4 กับ `PattaraponKitcharoen`** — เสนอยึดท่อนกลาง (middleware/guard + `SET LOCAL app.tenant_id`) ที่ `request-context.ts` ของ #18 (merged แล้ว) รองรับไว้
3. **ถาม `LomerAlloys` / เจ้าของโปรเจกต์ว่า #6 ต้องรอ #5 จริงไหม** — ใบ #6 เขียนว่ารอ `p3b` แต่ `POST /devices` ต้องการแค่ auth ของ `owner` จาก #4 · **ห้ามตัดสินเองใน PR**
4. **#11 `mechanics.total_credit`** ต้องให้เจ้าของโปรเจกต์เคาะ — design doc กับโค้ด Dart อ้างอิงไม่ตรงกัน อ่านอันเดียวจะมั่นใจแบบผิด ๆ · บล็อก #21 ขึ้นไป
5. **เขียน `Products.deletedAt` ลงใบ #55** พร้อมเหตุผลว่าทำไมไม่ทำใน #53 (ADR-0010 ข้อ 2)
6. **เขียนกฎ timestamp ลง ADR-0010 ข้อ 3** ให้ชัด ก่อน #56 เริ่ม
7. เก็บกวาดเล็ก ๆ: ถอด `--delete-conflicting-outputs` ออกจาก `flutter.yml:84` (build_runner 2.15 ถอด flag นี้แล้ว ขึ้นแค่ warning)

## 7. ข้อควรระวัง

- 🔴 **`exportSnapshot()` ไม่พก `sales.shiftId` และ `products.offlineOk`** (คงรูป `sa_*` ของ JS ไว้ตาม AC) → ค่าที่ได้จาก server จะหายไปกับ backup/restore — **#56 ต้องรู้**
- 🔴 **DB ที่เพิ่ง seed หรือเพิ่ง import มี `products.updatedAt` เป็น null** — `_seed()` กับ `importLegacyBackup()` **ไม่ stamp** โดยเจตนา (เป็นการ restore ไม่ใช่การแก้) · #55 ต้องอ่านว่า "ยังไม่เคย sync" ไม่ใช่ "ไม่เปลี่ยนแปลง"
- 🔴 **ห้ามย้าย `ProductWriteStamp` กลับเข้า `database.dart`** — codegen ตายเงียบ เห็นเฉพาะ build เย็น (เหตุผลเต็มอยู่หัวไฟล์ `product_stamp.dart`)
- 🔴 **`_v1Ddl` / `_v2Ddl` ในไฟล์เทสต์คือหลักฐาน ไม่ใช่ source code** — dump มาจาก `sqlite_master` จริงที่ commit ก่อนแต่ละ bump **ห้ามจัดระเบียบใหม่**
- **`git add -A` ในเรโปนี้อันตราย** — มี agent อื่นทำงานคู่กันใน worktree เดียวกัน · stage ทีละไฟล์เสมอ
- **`AGENTS.md` บรรทัด 11–13 ต่างจาก `CLAUDE.md` โดยเจตนา** (ชี้ `Codex-portable`) เวลา sync สองไฟล์นี้ **ห้ามรวมบรรทัดนั้น**
- **เซสชันอื่นสลับ branch ของ repo ได้กลางทาง** — รอบนี้ repo ถูกสลับจาก `feat/fe0-drift-schema-v3` ไป `main` ระหว่างทำงาน (agent design commit ของตัวเองแล้วสลับ) · เช็ค `git branch --show-current` ก่อนเชื่อผลอะไรที่ค้างอยู่

## 8. อ้างอิง

- PR **#58** (#53) `ded95ef` · PR **#51** (#18) `ab2312d` · PR **#60/#61/#62** ของ agent design
- `frontend/test/schema_v1_to_v3_migration_test.dart` — เทสต์ + DDL v1 ตัวจริง
- `frontend/test/schema_v3_migration_test.dart` — เทสต์ + DDL v2 ตัวจริง (เซสชันก่อน)
- `frontend/lib/data/db/product_stamp.dart` — คอมเมนต์หัวไฟล์ = กับดัก codegen + คำอ้าง ADR ที่แก้แล้ว
- [ADR-0010](../Backend_design/adr/0010-client-write-through-cache.md) ข้อ 2 (ขยับ schema เมื่อต้องใช้จริง) และข้อ 3 (ห้ามคำนวณเองในเครื่อง)
- คนที่ต้องถาม: เจ้าของโปรเจกต์ (**#11**, DB ที่ร้านเป็น v1 หรือ v2) · `PattaraponKitcharoen` (#4, #6) · `LomerAlloys` (#5 บล็อก #6 จริงไหม, #17)
