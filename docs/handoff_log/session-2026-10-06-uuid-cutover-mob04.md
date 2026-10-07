# Handoff — #616 cutover: `develop` → `main`, ล้าง DB `mob04`, deploy id แบบ UUID `65861ea` (2026-10-06)

**วันที่:** 2026-10-06 · **สถานะ:** deploy แล้ว ยืนยันบน VM · DB ว่าง (ยังไม่มี tenant) · `develop` ถูกลบ
**ต่อจาก:** [`session-2026-10-05-demo344-retired-device.md`](session-2026-10-05-demo344-retired-device.md) · ขั้นตอนที่ทำตาม: [`runbook-616-uuid-cutover-mob04.md`](runbook-616-uuid-cutover-mob04.md)

## 1. สรุปสั้น
- `main` = `65861ea` (PR #628, **merge commit**) — รวม #617 (#616 TEXT → UUIDv7), #618, #622–#626, #629, #630
- `mob04` ถูก backup แล้วล้างข้อมูลทั้งหมด (10 tenant) → migration `EntityIdsToUuid1788652804900` รันผ่าน → `.current_sha` = `65861ea`
- issue #612 #616 #619 #620 #621 ปิดโดย PR #628 · branch `develop` ลบแล้ว (tip `7faa117` อยู่ใน `main` — เช็กด้วย `merge-base --is-ancestor` ก่อนลบ)
- กลับมาเหลือ long-lived branch แค่ `main` + `POC_sample_offline_first` ตามกติกา CLAUDE.md
- **แก้ 2026-10-06 (ภายหลังในวันเดียวกัน, แทนสองบรรทัดบนเรื่อง branch):** owner เลือกเก็บ `develop` เป็น long-lived — สร้างใหม่ที่ `1974d60` (= `main`) · ลบ branch ที่ merge แล้ว 87 ตัวหลังเช็กทีละตัว → เหลือ `main`, `develop`, `POC_sample_offline_first` · `develop` → `main` = merge commit/fast-forward เท่านั้น (CLAUDE.md *Branch strategy*)

## 2. PR ที่ merge วันนี้ (ทุกตัว update กับ base ก่อน แล้ว merge เมื่อ CI เขียวบน head นั้น · `--match-head-commit`)
| PR | base | งาน | merge |
|---|---|---|---|
| #623 | develop | #621 tenant id ตัวพิมพ์เล็กเท่านั้น (`INVALID_TENANT_ID`, ลบ `UUID_ANY_CASE_RE`) + pnpm override `proxy-addr`/`source-map-js` | `3e2f9c8` |
| #624 | develop | #619 `parseOpPayload` ตัวเดียวแทน `assertOpIds` | `5814214` |
| #622 | develop | #620 `newId` → `newIdempotencyKey` (format key ไม่เปลี่ยน) | `7a62b71` |
| #625 | develop | #612 dialog ตั้ง PIN ออฟไลน์: token ตาย → เหมือน #609, เฉพาะ 401 `UNAUTHORIZED` = รหัสผ่านผิด | `64686fe` |
| #626 | develop | `ROLLBACK_FLOOR` → `bedd328` + runbook cutover | `7b33452` |
| #627 | **main** | cherry-pick override audit (advisory ใหม่ 2026-10-06 ทำ `pnpm audit` แดงบน `main` ด้วย) | `e78bb38` |
| #629 | develop | review fix: `ApiException` ไม่ถึง widget แล้ว — `OfflinePinRepository.setPin` แปลงเอง | `bfd2da9` |
| #630 | develop | review fix: `/sync/push` replay ด้วย key **ก่อน** parse (กติกา B1) + แก้ comment discard + runbook | `7faa117` |
| #628 | **main** | `develop` → `main` | `65861ea` |

**รีวิวก่อนเข้า main:** `/scrutinize` + `/code-review` 2 รอบ (รอบแรกหา blocker ฝั่ง deploy, รอบสุดท้ายบน develop รวม) · รอบสุดท้ายเจอ hard violation 2 ข้อ → #629, #630 · CI ของ #628 เขียวบน `7faa117` (integration/e2e + migration จริง, unit, audit, gitleaks, drift codegen, Flutter analyze+test)

## 3. ทำอะไรบน `mob04` (ตาม runbook §3–§7)
1. **inventory ก่อนล้าง:** 10 tenant — `1234`, `12345`, `123`, `test01`, `TEST001` (closed) · `Srisurat #1`, `ABCD`, `Fiattest`, `demo-344-20261005`, `loadtest-tenant` (active) · sales 3776, movements 3784, idempotency_keys 3752, products 63, devices 18, users 10
2. **backup:** `/opt/pos/backups/pos_backup_20261006_035714Z.sql.gz` (845K) · `gzip -t` ok · sha256 OK · 30 `COPY` · **สำเนาออกนอก VM:** เครื่อง owner `~/Downloads/srisurart-mob04-backups/` (sha256 ตรง) — 🔴 **แก้ 2026-10-07: โฟลเดอร์นี้ไม่มีแล้ว ไม่มีสำเนานอก VM** (ดู `session-2026-10-07-final-release.md`) — offsite จริงยังไม่มี (#363 parked)
3. **ล้าง:** `TRUNCATE … RESTART IDENTITY` 28 ตาราง (เว้น `platform_admins`, `migrations`) ใน transaction เดียว ไม่มี `CASCADE`, ไม่แตะ volume · guard ของ migration → `NOTICE: ok` · tenants 0 / users 0 / platform_admins 3
4. **ลง `pos-deploy` ใหม่ก่อน approve:** clone `main@65861ea` → `ROLLBACK_FLOOR="bedd328…"` → `install` → sha256 repo = `/usr/local/bin/pos-deploy` (`f8b0ae73…`) · ตัวเก่าเก็บไว้ที่ `/usr/local/bin/.pos-deploy.prev-616`
5. **deploy:**
   - run `37413912676` (จาก Server CI) — **skip แต่ขึ้น success** เพราะ image web ยังไม่มี (Flutter CI ยังไม่จบ) → ตรงกับกติกา "green ไม่ใช่หลักฐาน"
   - run `37412192726` (`e78bb38`, #627) ค้าง waiting ถือ slot `deploy-demo` → **cancel**
   - run `37414027567` (`65861ea`) → approve (comment บันทึกเหตุผล) → Ansible `ok=51 changed=16 failed=0`
6. **ยืนยันบน VM:** `.current_sha` = `65861ea878077466cb1c6cc5ff0e59bbe14521cc` · `/health/ready` 200 · migration ล่าสุด `EntityIdsToUuid1788652804900` · `id` ของ sales/devices/products/shifts/tenants = `uuid` · api-1..3 healthy · CORS preflight `x-device-token` → 204 · login ผิด → 401 `UNAUTHORIZED`
7. **APK:** `android-apk.yml` บน `main@65861ea` run `37416623383` success

## 4. ยังไม่ได้ทำ — ต้องทำก่อนใช้งาน
1. **สร้าง tenant ใหม่ผ่าน platform-ui** (ไม่ได้สร้างให้ เพราะรหัสชั่วคราวหมดอายุใน 10 นาที) → login owner → เปลี่ยนรหัส → ผูกเครื่องด้วย `enrolCode` · tenant ใหม่ไม่มีสินค้า (เพิ่มเอง)
2. **ล้างทุก client ก่อนใช้:** เบราว์เซอร์ = Incognito หรือ Clear site data · Android = ล้าง storage แอปแล้วลง APK ใหม่ · outbox เก่า (opId ไม่ใช่ UUID) ส่งไม่ได้และ discard ไม่ได้ (`sync.dto.ts` comment ที่ #630 แก้)
3. **#344 ต้องเริ่มใหม่ทั้งหมด** — tenant `demo-344-20261005` ถูกลบแล้ว (AC1/AC2 ของวันที่ 05 เป็นแค่ประวัติ)
4. ข้อมูลเก่ากู้ได้เฉพาะ restore dump ข้างบน + โค้ดก่อน floor ด้วยมือ = การตัดสินใจของ owner ไม่ใช่ rollback · ตอนนี้ rollback ต่ำกว่า `bedd328` ถูกปฏิเสธทั้ง runner และทางมือ

## 5. งานค้าง / ข้อสังเกต
- **replay ทางที่ 2 (client id) ยัง parse ก่อน:** ถ้า key หมดอายุ (24 ชม. / B2 delete) บิลที่ server มีแล้วแต่ body ไม่ผ่าน parser วันนี้ → `rejected` แทน `applied` — เหมือนก่อน #624 · ปิดได้ด้วยการให้ step 2 สร้างคำตอบจากแถวที่เก็บไว้ (refactor `SalesService`) · รายละเอียดใน PR #630
- #624 เข้มขึ้นกว่าที่ #619 ขอ (drawer type/amount, `paymentMethod`, ชื่อลูกค้า, เหตุผล void) — ตั้งใจให้ sync ตอบเหมือน online
- ~~ข้อความไทยรอ owner ratify: `INVALID_ID` = `รหัสรายการไม่ถูกต้อง` · `deviceEnrolmentGone` (ทั้งคู่ agent ร่าง)~~ — **แก้ 2026-10-07:** owner รับรองแล้ว ("l approved all") ทั้ง `INVALID_ID` และ `deviceEnrolmentGone` (รวมทุกข้อความ agent ร่างอื่นด้วย — ดู §8.1/§8.1.1 ของ `02_API_SCREENS.md`)
- `presentation/` อีก 7 ไฟล์ยัง import `api_exception.dart` (บางไฟล์แค่ `PosException`) — ยังไม่มี guard ทั้งแอปว่า `ApiException` ห้ามถึง widget
- `assertValidTenantId` ยังอยู่ใน `platform-tenants.service.ts` (ควรย้ายไป `common/ids.ts`) · import สองทาง `offline_pin_repository.dart` ↔ `auth_repository.dart`
- `pos_trust_test.dart` 2 เทสต์ตกบน macOS (ข้อความ TLS error ต่าง) — Linux CI ผ่าน · ยังไม่ได้เทียบกับ `main` บน macOS
- ~~`main` ไม่ได้บังคับวิธี merge~~ — **แก้ 2026-10-06 (ภายหลัง):** ตอนนี้บังคับแล้วด้วย ruleset `24564072` "main: merge commit only" (ปฏิเสธ squash/rebase บน PR เข้า `main`, ไม่มี bypass actor) และ `develop` มี branch protection เหมือน `main` · floor ใหม่รอดเพราะ #628 ใช้ merge commit

## 6. บทเรียน
- advisory ใหม่โผล่ระหว่างวันทำ `pnpm audit` แดงทุก PR **และ `main`** → ไม่มี image → Deploy skip แบบเขียว · แก้บน `main` แยก PR ก่อน (#627) แล้วค่อยรวม
- PR ที่แยกกันรีวิวผ่านทีละตัว ยังมีปัญหาเมื่อรวมกัน — รีวิว develop รวมอีกรอบก่อนเข้า `main` เจอ 2 ข้อ (#629/#630)
- หลัง merge เข้า `main` Deploy จะยิง 2 รอบ (จาก Server CI และ Flutter CI) · รอบแรกมัก skip เพราะ image web ยังไม่มี — รอรอบที่สอง
