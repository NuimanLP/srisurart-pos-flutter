# Handoff — ตัด issue ฝั่ง frontend (`q1`) + ทำ #53 Drift schema v3 (2026-09-10)

**วันที่:** 2026-09-10 · **ผู้บันทึก:** NuiGates (`NuimanLP`, Lane A / `team/1`) · **สถานะ:** รอ merge
**ขอบเขต:** ตัดงาน `q1` เป็น issue จริง แล้วทำใบแรก (#53) จบทั้งใบ — schema + migration + เทสต์ + รีวิว
**ต่อจาก:** [`lane-a-ci3-idempotency.md`](lane-a-ci3-idempotency.md) (อยู่บน branch `feat/p5.1-idempotency` ยังไม่ merge)

## 1. ตอนนี้อยู่ตรงไหน

- **#52 parent + #53/#54/#55/#56 ตัดแล้ว** และ assign คนจริงครบ · คอมเมนต์แจ้งไว้ใน #2 แล้วว่าแถวที่จองไว้ในตารางกลายเป็น issue จริงแล้ว
- **PR #58 (#53) CI เขียวครบ รอเจ้าของโปรเจกต์กด merge** — `analyze + test` 1m11s · `drift codegen is up to date` 1m16s · `deps-audit` 14s · `build web artifact` *skipping* ตามสเปค (รันเฉพาะบน `main`)
- **PR #51 (#18 idempotency) ยังค้างตั้งแต่ 2026-09-09** CI เขียวมาแล้ว รอ merge อย่างเดียว
- Lane A ที่เหลือยังติดเหมือนเดิม: **#4 → #5 → #6 → #19 → #20 → …** (สามคน สามต่อ ดู §6)
- 🔴 **working tree มีไฟล์ที่ไม่ใช่ของงานนี้** โผล่มาระหว่างเซสชัน: `CONTEXT.md`, `docs/Backend_design/07_CICD_DEPLOY.md`, `adr/0013-cicd-toolchain.md` (untracked) และ `00_INDEX.md`, `adr/README.md` (modified) · **ไม่ได้ commit เข้า PR #58** — stage แบบระบุชื่อไฟล์ทีละใบ ไม่ใช้ `git add -A`
- เครื่อง dev สะอาดแล้ว: worktree ที่สร้างไว้ทดสอบถูก `git worktree remove` แล้ว, http server พอร์ต 8099 ปิดแล้ว, tab Chrome ปิดแล้ว

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

**ตัด issue (`q1`)**
- #52 parent (ไม่มี `ready-for-agent`) → #53 `fe.0` schema v3 · #54 `fe.1` auth/device token/error strings · #55 `fe.2` ApiRepository reads · #56 `fe.3` ApiRepository writes
- แบ่งตามตารางใน #2 ยกเว้น **schema v3 ที่ย้ายจาก `team/2` มา `team/1`** (เหตุผลใน §3)

**#53 — schema v3** (14 ไฟล์ในคอมมิตแรก + 2 คอมมิตตามผลรีวิว)
- `Sales.shiftId` TEXT nullable · `Shifts.id` integer autoIncrement → **TEXT** (พร้อม `DrawerEntries.shiftId`) · `Products.offlineOk` BOOL default false
- `Shifts`/`DrawerEntries` rebuild ด้วย `TableMigration` + `columnTransformer` ที่ `CAST(id AS TEXT)` — id เดิม `1`,`2` กลายเป็น `'1'`,`'2'` ทั้งสองฝั่ง entry จึงยังผูกกับกะเดิม
- `openShift` และ import ทั้งสองทางใน `SnapshotRepository` ออก id เองด้วย `newId('sh')`
- **`products.updatedAt` ถูกเขียนจริงแล้ว** ผ่านจุดเดียว `ProductsCompanion.stamped` — ครบ 6 path (add / update / adjustStock / saveSale / createReturn / receivePO) ไม่ใช่ 5 ตามที่ใบ issue เขียน (returns restock เป็นใบที่ 6 ที่ตกสำรวจ)

**ตรวจสอบด้วยอะไร**
- **123 → 135 tests** · `dart analyze` clean · `flutter build web` ผ่าน (115.7s)
- `schema_v3_migration_test.dart` อัป **ไฟล์ v2 จริง**: dump DDL ออกจาก `sqlite_master` **ก่อน**แก้โค้ด แล้วฝังเป็นค่าคงที่ในเทสต์ → สร้างไฟล์ด้วย `package:sqlite3` → `PRAGMA user_version = 2` → เปิดด้วย `AppDatabase` · เช็ค 3 กะ/entry/โน้ตไทย/จำนวนเงิน/`user_version = 3`
- **พิสูจน์บน Chrome จริง** เพราะร้านรัน web build ไม่ใช่ native: สร้าง worktree ของ `main` → `flutter build web` → เปิดที่ `localhost:8099` ได้ DB v2 บน backend `WasmStorageImplementation.sharedIndexedDb` → สลับ build v3 บน **origin เดิม** → boot ผ่าน **ไม่มี error ใน console**, สต็อกทุกตัวเลขเท่าเดิม (48/52/14/22/5/19/13/5/7/65/40/6), หน้าลิ้นชักอ่านตาราง shifts/drawer_entries ที่ rebuild แล้วได้
- `database.g.dart` md5 `94fdf075470435e296958ba7fd466257` — ไฟล์ที่ commit ตรงกับผลของ build เย็นแบบไม่มี cache

**รีวิว 2 แกน (`/code-review`) + `/scrutinize`**
- Standards จับ: `CONTRACT.md` ขัดกับโค้ด 4 แถว + `schemaVersion => 1` · stamp กระจาย 5 จุดใน 4 repo (shotgun surgery) · pin `sqlite3` แข็งเกิน
- Spec จับ: `update()` ทับ `updatedAt` ที่ caller ส่งมา (ผิด ADR-0010 ข้อ 3 ตอน #56 patch จาก server) · `_seed()`/`importLegacyBackup()` ไม่ stamp · export ไม่พก `sales.shiftId`
- Scrutinize จับ: migration พิสูจน์แค่บน native sqlite ทั้งที่ร้านรัน web → กลายเป็นงานพิสูจน์บน Chrome ข้างบน

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

| เรื่อง | เลือก | เหตุผล | ใครตัดสิน |
|---|---|---|---|
| #53 ใครถือ | **`team/1` (เรา)** ไม่ใช่ `team/2` ตาม #2 | เป็นใบเดียวในชุดที่ไม่ติด blocker · Lane A ว่างสนิทรอ #4→#5→#6 ส่วน `team/2` ยังมี #16/#17/#25/#26/#27 ค้าง · #55/#56 ติดใบนี้ทั้งคู่ | เจ้าของโปรเจกต์ |
| ตัด `q1` เป็นกี่ใบ | parent + 4 ใบย่อย | ใบเดียว = 20 วันตาม Gantt เกิน "one PR's worth" ที่ทุกใบในทีมยึด และแบ่งให้ 3 คนไม่ได้ | เจ้าของโปรเจกต์ |
| `Sales.shiftId` ผูก FK ไหม | **ไม่ผูก** `references(Shifts, #id)` | บิลที่ patch มาจาก server อาจอ้าง shift ที่ cache เครื่องนี้ไม่เคยเห็น — ADR-0010 บอกให้ถือว่าแถวที่ไม่ครบคือ stale ไม่ใช่ error · (FK ไม่ถูก enforce อยู่แล้วเพราะไม่มีใครตั้ง `PRAGMA foreign_keys`) | เรา |
| `offlineOk` ค่าเริ่มต้น | `false` ไม่ใช่ nullable | ไม่รู้ = ขายออฟไลน์ไม่ได้ คือด้าน fail-safe · nullable จะบังคับให้ทุกที่ที่อ่านต้องตีความ null เอง | เรา |
| id กะเดิมตอน migrate | **CAST เป็น text** (`1` → `'1'`) ไม่ออก `newId` ใหม่ | ทั้ง `shifts.id` และ `drawer_entries.shift_id` cast ด้วยสูตรเดียวกัน ความสัมพันธ์จึงรักษาไว้ได้โดยไม่ต้อง map · ออก id ใหม่ต้องทำตาราง mapping กลางคัน migration | เรา |
| สร้าง DB v2 ในเทสต์ยังไง | เพิ่ม `sqlite3` เป็น **dev-dep** | ทางเลือกคือเขียน `QueryExecutorUser` glue เองเพื่อเลี่ยง dependency ซึ่งอ่านยากกว่ามาก · เวอร์ชันตรงกับที่ drift resolve อยู่แล้ว (sha256 เดิม) web asset จึงไม่ขยับ | เรา |
| `^3.4.0` หรือ `3.4.0` | **caret** | pin แข็งจะบล็อกการอัป `drift` ในอนาคตแทนที่จะเตือนเรื่อง asset skew ตามที่ CLAUDE.md ตั้งใจ | รีวิว Standards เสนอ เรารับ |
| stamp `updatedAt` ยังไง | extension `ProductsCompanion.stamped` ที่ **เคารพค่าที่ caller ส่งมา** | เขียน inline 5 จุดแล้ว path ที่ 6 จะหลุดเงียบ ๆ · และ `.stamped` ทำให้กติกา "ห้ามทับ timestamp ของ server" (ADR-0010 ข้อ 3) มีที่อยู่จริงก่อน #56 มาถึง | รีวิวเสนอ เรารับ |
| `_seed()` / `importLegacyBackup()` | **ไม่ stamp** ปล่อยค่าตามข้อมูลเดิม | สองอันนี้คือ restore ไม่ใช่การแก้ · แต่แปลว่า DB ที่เพิ่ง seed/import มี stamp เป็น null → บันทึกไว้ใน `CONTRACT.md` ว่า #55 ต้องอ่านว่า "ยังไม่เคย sync" ไม่ใช่ "ไม่เปลี่ยน" | เรา |
| `saveSale` เขียน `shiftId` ไหม | **ไม่เขียน** | ใบ #53 ขอแค่ให้มีคอลัมน์ไว้รับค่าจาก server · ให้ build ออฟไลน์ผูกกะเองคือเพิ่ม invariant ชุดที่สองที่ ADR-0010 ห้าม | เรา |

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- 🔴 **วาง extension ที่อ้าง `ProductsCompanion` ไว้ใน `database.dart`** → **codegen ตายเงียบ** `database.dart` ประกาศ `part 'database.g.dart'` ส่วน `ProductsCompanion` อยู่ข้างใน part นั้น · ตอน build เย็น part ยังไม่มี → library วิเคราะห์ไม่ได้ → drift_dev ไม่ปล่อยอะไร → `source_gen:combining_builder … 83 no-op` แล้ว `database.g.dart` เดิม**โดนลบ**แทนที่จะถูกสร้างใหม่ · เครื่องที่มี build cache อุ่นจะไม่เจอเลย — **CI จับได้ที่เดียว** (17,493 deletions) · ทางแก้: ย้ายไป `lib/data/db/product_stamp.dart` ที่ **import** `database.dart` แทนการเป็น part ของมัน
- **`rm -rf .dart_tool` + `build_runner clean` ไม่ช่วย** ตอนไล่บั๊กข้างบน — เพราะสาเหตุจริงไม่ใช่ cache เสียเวลาไปกับทางนี้อยู่นาน
- **`--delete-conflicting-outputs` ถูกถอดออกจาก build_runner 2.15 แล้ว** ขึ้น `W These options have been removed and were ignored` · `.github/workflows/flutter.yml:84` ยังส่ง flag นี้อยู่ — ไม่ใช่สาเหตุของ CI แดงรอบแรก (โค้ดเราเองผิด) ถอดออกได้เมื่อไหร่ก็ได้
- **ขับ UI ของ Flutter web ด้วย synthetic click ไม่ได้** ลอง 4 ทาง (พิกัดจาก screenshot, ชดเชย offset, หารด้วย devicePixelRatio, `type` ลงช่องที่ focus แล้ว) ไม่มีอันไหนกดปุ่ม "เปิดร้าน" ติด · `read_page` คืน accessibility tree เปล่าเพราะ canvas · เปลี่ยนหน้าได้ทางเดียวคือยิง URL hash (`#/cash-drawer`) ตรง ๆ
- **`import 'package:drift/drift.dart'` ชนกับ matcher** — `isNull`/`isNotNull` ซ้ำ ต้อง `hide isNull, isNotNull` เหมือนไฟล์เทสต์เดิมทำไว้
- **เทียบ `updatedAt` กับ `DateTime.now()` ตรง ๆ ในเทสต์ไม่ได้** drift เก็บ DateTime เป็น **unix seconds** เศษมิลลิวินาทีถูกตัด stamp ที่เขียนทีหลังจึงอ่านได้ว่า "ก่อน" baseline · ต้อง floor baseline เป็นวินาทีก่อนเทียบ

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

**ยืนยันแล้ว (รันจริง/วัดจริง):** 135 tests · md5 ของ `database.g.dart` ตรงกับ build เย็น · CI ทั้ง 3 job เขียว · การ CAST id รักษาความสัมพันธ์ entry→กะ บน native · v3 เปิด DB v2 บน `sharedIndexedDb` ใน Chrome ได้โดยไม่มี error และสต็อกเท่าเดิม

**ยังไม่พิสูจน์:**
- **การรักษาแถวใน `shifts`/`drawer_entries` บน web** — ตอนทดสอบใน Chrome สร้างกะไม่ได้ (คลิกไม่ติด ดู §4) ตารางจึงว่าง · ที่พิสูจน์บน web คือ migration *รันผ่าน* เท่านั้น ส่วนการรักษาแถวพิสูจน์บน native อย่างเดียว
- fixture ของ migration test สร้าง **4 จาก 20 ตาราง** — พิสูจน์การ rebuild ไม่ได้พิสูจน์ว่าไฟล์ v2 จริงทั้งไฟล์รอด
- **ไม่รู้ว่า `CONTEXT.md` / `07_CICD_DEPLOY.md` / `adr/0013` มาจากไหน** เดาว่าเป็นอีกเซสชันของเจ้าของโปรเจกต์ที่รันคู่กันอยู่ — ยังไม่ได้ถาม
- ไม่รู้ว่ามี path อื่นที่เขียนแถว `products` นอกจาก 6 อันที่ไล่เจอหรือไม่ (ไล่ด้วย grep `db.products` ทั้ง `lib/`)

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **merge PR #58** แล้ว `git pull --ff-only origin main` **ทันที** (บทเรียนเดิม: `gh pr merge` อัปเดตแค่ remote)
2. **merge PR #51** (#18) ที่ค้างมาตั้งแต่ 2026-09-09 — รอเจ้าของโปรเจกต์กดอย่างเดียว
3. **#17 `p4.2` customers/mechanics** — blocked by แค่ #15 ซึ่งปิดแล้ว **หยิบได้ทันที** และปลดล็อก #24 ของเราเอง · เป็นของ `LomerAlloys` ต้องบอกเจ้าของเดิมก่อน
4. **ตาม #4 กับ `PattaraponKitcharoen`** — เสนอยึด **ท่อนกลาง** (middleware/guard + `SET LOCAL app.tenant_id`) ที่ `request-context.ts` ของ #18 รองรับไว้แล้ว · คอมเมนต์ split 3 ท่อน + คำถาม 2 ข้อ อยู่ในใบ #4 แล้ว
5. **ถาม `LomerAlloys` / เจ้าของโปรเจกต์ว่า #6 ต้องรอ #5 จริงไหม** — ตัวใบ #6 เขียนว่า *"Depends on the platform admin plane issue (p3b)"* แต่ `POST /devices` ต้องการแค่ auth ของ `owner` จาก #4 · ถ้าคลายได้ โซ่หายไปหนึ่งต่อ **ห้ามตัดสินเองใน PR**
6. **#11 `mechanics.total_credit`** ต้องให้เจ้าของโปรเจกต์เคาะ — บล็อก #21 เป็นต้นไป
7. เก็บกวาดเล็ก ๆ: ถอด `--delete-conflicting-outputs` ออกจาก `flutter.yml:84` (ไม่เร่ง เป็นแค่ warning)

## 7. ข้อควรระวัง

- 🔴 **ห้ามย้าย `ProductWriteStamp` กลับเข้า `database.dart`** หรือใส่ declaration ใหม่ที่อ้างชนิดจาก `database.g.dart` ลงในไฟล์นั้น — codegen จะตายแบบเงียบและเห็นเฉพาะตอน build เย็น (เหตุผลเต็ม ๆ อยู่ในคอมเมนต์หัวไฟล์ `product_stamp.dart`)
- 🔴 **อย่าเชื่อ build_runner บนเครื่องตัวเองที่มี cache อุ่น** ถ้าจะยืนยันว่า codegen รอด ต้อง `rm -rf .dart_tool` **และลบ `*.g.dart` ทิ้งก่อน** แล้วดูว่า `combining_builder` รายงาน `1 output` ไม่ใช่ `no-op` · หรือปล่อยให้ job `codegen-check` ตัดสิน
- **`git add -A` ในเรโปนี้อันตราย** — มีไฟล์จากเซสชันอื่นค้างใน working tree รอบนี้เกือบ commit ทับไปแล้วครั้งหนึ่ง stage ทีละไฟล์เสมอ
- **`pubspec.yaml` เป็น CRLF** แก้ด้วยสคริปต์ python แบบ text mode แล้วจะกลายเป็น LF ทั้งไฟล์ → diff บวม 226 บรรทัดแทนที่จะเป็น 4 · ใช้ binary mode หรือเช็ค `git diff --numstat` หลังแก้ทุกครั้ง
- **DB ที่เพิ่ง seed หรือเพิ่ง import มี `products.updatedAt` เป็น null** — #55 ต้องอ่านว่า "ยังไม่เคย sync" ไม่ใช่ "ไม่เปลี่ยนแปลง" (เขียนไว้ใน `CONTRACT.md` แล้ว)
- **`exportSnapshot()` ไม่พก `sales.shiftId` และ `offlineOk`** (คงรูป `sa_*` ของ JS ไว้) → shiftId ที่ได้จาก server จะหายไปกับ backup/restore — #56 ต้องรู้
- **`offlineOk` ห้ามคำนวณเองในเครื่อง** เขียนจาก response ของ server เท่านั้น

## 8. อ้างอิง

- PR **#58** (#53) · issue **#52** parent + **#53–#56** · คอมเมนต์สรุปการตัด issue อยู่ใน **#2**
- `frontend/lib/data/db/product_stamp.dart` — คอมเมนต์หัวไฟล์คือคำอธิบายกับดัก codegen
- `frontend/test/schema_v3_migration_test.dart` — ค่าคงที่ `_v2Ddl` คือ DDL v2 ตัวจริง ห้ามจัดระเบียบใหม่ มันเป็นหลักฐาน
- `CONTRACT.md` §2 (ตาราง + mapping notes) — อัปเดตให้ตรง schema v3 แล้ว
- [ADR-0010](../Backend_design/adr/0010-client-write-through-cache.md) ข้อ 2 (schema v3) และข้อ 3 (ห้าม `ApiRepository` เรียก transactional service / ห้ามทับค่าของ server)
- คนที่ต้องถาม: เจ้าของโปรเจกต์ (merge #58/#51, **#11**) · `PattaraponKitcharoen` (#4, #6) · `LomerAlloys` (#5 บล็อก #6 จริงไหม, #17)
