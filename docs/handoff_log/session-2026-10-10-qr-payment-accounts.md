# Handoff — บัญชีรับเงิน QR (≤5, เจ้าของร้านแก้เท่านั้น) + QR พร้อมเพย์ใส่ยอดที่หน้าขาย: `main` = `ef07e27` deploy ขึ้น `mob04` + APK `apk-ef07e27` (2026-10-10)

**วันที่:** 2026-10-10 · **สถานะ:** deploy แล้ว (migration ใหม่รันแล้ว) + APK ออกแล้ว · freeze ของ 2026-10-07 ถูก owner ยกเว้นเฉพาะงานนี้ ("approved all the way long")
**ต่อจาก:** [`session-2026-10-08-pos-favorites.md`](session-2026-10-08-pos-favorites.md)
**วิธีตรวจ:** SHA/PR/run id อ่านจาก `gh` · ฝั่ง VM อ่านจาก **log ของ deploy run** (`pos-deploy` running→release, งาน `Apply database schema migrations`, Ansible recap) — **ไม่ได้ SSH เปิด `.current_sha` เอง** · **ยังไม่ได้ลองใช้ฟีเจอร์บน `mob04` จริง** (ยังไม่มีใครสร้างบัญชี QR / สแกนด้วยแอปธนาคารจริง)

## 1. สรุปสั้น
- owner (`NuimanLP`) ขอ: หน้าโอน QR ยังไม่มีภาพ → ตั้งค่าอัปโหลด QR ได้ 5 อัน มีชื่อเล่น + ธนาคาร, ตั้งค่าเริ่มต้นได้, หน้าขายกด QR แล้วขึ้นอันเริ่มต้น เปลี่ยนเป็นอันอื่นได้ · + research QR ใส่ยอด (SCB/KBANK) และ API ตรวจสลิป (**research อย่างเดียว ยังไม่ทำ**)
- owner เลือก: **เก็บบน server** · **owner เท่านั้นแก้** · **บิลบันทึกว่าเข้าบัญชีไหน (ทำเลย)** · ไม่มีขั้น "ได้รับเงินแล้ว" · **ทั้งพร้อมเพย์และรูป**
- orchestrator: เขียนสัญญา API → Opus server lane + Opus client lane (worktree แยก, ทำคู่กัน) + Sonnet research 2 ตัว → รวม branch `feat/qr-accounts` → Sonnet `/scrutinize` + `/code-review` (ไม่มี blocker) → Opus แก้ A–G + e2e ที่ล้ม
- PR #676 (`feat/qr-accounts` → `develop`, squash) = `5f7e979` · head `65b0144` == `headRefOid` (merge ด้วย `--match-head-commit`)
- PR #677 (`develop` → `main`, merge commit) = `ef07e27` · `bedd328` ยังเป็น ancestor · merge base เดียว (ไม่ criss-cross)
- deploy run `38050647954` — approve โดย Claude ตามคำสั่ง owner · log: `running=1d70d1c… release=ef07e27…`, migration task รัน, `failed=0` · run แรก `38050540427` ข้าม (image ยังไม่ขึ้น GHCR)
- 🔴 **deploy ค้าง `pending` เพราะ run เก่า `37786086586` (`1d70d1c`, 2026-10-08) รอ approve ค้างอยู่ 2 วันถือ slot `deploy-demo`** — cancel แล้วจึงเดินต่อ (กฎเดิม "cancel stale waiting Deploy runs" — run คู่ของ SHA เดียวกันที่ไม่ได้ approve ก็ค้างได้ ต้อง cancel ทิ้งหลัง deploy ทุกครั้ง)
- APK: run `38051323127` → prerelease [`apk-ef07e27`](https://github.com/NuimanLP/srisurart-pos-flutter/releases/tag/apk-ef07e27) (`srisurart-pos-ef07e27.apk`, ~77 MB, API build, key เดิม)

## 2. Server
- migration **`1788652805000-PaymentAccounts`** (เพิ่มอย่างเดียว):
  - `payment_accounts (tenant_id, id)` PK ร่วม · `nickname`, `bank_code`, `kind` (`promptpay`|`image`), `promptpay_id`, `image BYTEA`, `image_mime`, `is_default`, `sort_order`, `created_at`/`updated_at`/`deleted_at` (soft delete)
  - RLS `tenant_isolation` แบบ NULLIF · CHECK ตามชนิด · partial unique index `uq_payment_accounts_default` (default ที่ยังไม่ลบได้ 1)
  - `sales.payment_account_id` + FK `fk_sales_payment_account` (**ไม่มี ON DELETE** — ลบแบบ soft เท่านั้น) + CHECK `ck_sales_payment_account_qr` (มีได้เฉพาะ `โอน/QR`)
- `GET/POST/PATCH/DELETE /api/v1/payment-accounts` (`server/src/payment-accounts/`)
  - GET: ทุก user ของร้าน (แถวที่ยังไม่ลบ) · เขียน: idempotent (`runIdempotent`) + **owner เท่านั้น** (`403 OWNER_ONLY`, เช็กเป็นคำสั่งแรกใน claim; ไม่บังคับเครื่อง enrol)
  - เพดาน 5: `409 PAYMENT_ACCOUNT_LIMIT` ภายใต้ **advisory lock ต่อร้าน** (`pg_advisory_xact_lock`) — ร้านที่ยังไม่มีแถวไม่มีอะไรให้ `FOR UPDATE` · ไม่แตะแถว → ขายไม่ต้องรอ lock นี้
  - `isDefault: true` ล้าง default อื่นใน tx เดียว · ลบ default = ร้านไม่มี default (client ใช้บัญชีแรก)
  - รูป: ≤ 300×1024 byte หลัง decode + ตรวจ magic bytes · body limit **1 MB เฉพาะ route นี้ หลังตรวจ token owner แล้ว** (`app.setup.ts`, แบบเดียวกับ import) · คนอื่นได้ 100 KiB
  - **ทุกการเขียนลง `audit_log`** (`payment_account.created`/`.updated`/`.deleted`/`.default_changed`) — เลขพร้อมเพย์ mask เหลือ 4 ตัวท้าย ไม่มี byte รูป
  - `CLIENT_ID_REUSED` เมื่อ id ซ้ำ (แม้แถวที่ลบแล้ว)
- `POST /sales` (+ quote convert) รับ `paymentAccountId` — ไม่ใช่ `โอน/QR` = 400 · id ไม่รู้จัก/ร้านอื่น = `400 PAYMENT_ACCOUNT_NOT_FOUND` · แถวที่ soft-delete ของร้านนี้รับได้ · อ่านบัญชีเป็น plain read ก่อน lock ช่าง/สินค้า → ลำดับ lock เดิมไม่เปลี่ยน
- `/sync/push` `sale.create`: **ไม่ปฏิเสธเพราะบัญชี** — id ไม่รู้จัก / ผิดรูป / บิลไม่ใช่ QR → เก็บ NULL · fixture ใหม่ `sale-create.qr-account.json`
- export/import ร้าน: store `sa_payment_accounts` (รวมรูป + แถวที่ลบ, `__meta.recordCounts.paymentAccounts`) + `paymentAccountId` ของบิล · preflight ใช้กติกาเดียวกับ API (default 1, active ≤ 5) · **import แทนที่บัญชีเฉพาะเมื่อไฟล์มี list ที่ไม่ว่าง** (เหมือน `settings`) — ไฟล์ไม่มี/ว่าง = เก็บบัญชีเดิม · บิลที่ชี้ id ที่ไฟล์ไม่มี = NULL (แม้ร้านยังมีบัญชี id นั้น — "as today" ตามสัญญา; เปลี่ยนได้ถ้า owner ต้องการ)
- **บั๊กที่ e2e จริงจับได้ครั้งแรก:** TypeORM `manager.query` ของ `UPDATE … RETURNING` คืน `[rows, count]` ไม่ใช่ rows → PATCH/DELETE เป็น 500 · แก้ด้วย helper `returning()` (`common/sql.ts`) · unit test ไม่จับเพราะ mock — **ใช้ `returning()` ทุกครั้งที่อ่านผล UPDATE/DELETE … RETURNING**
- `schema.e2e-spec.ts` เทสต์ backfill …4600 เคย undo 4 migration ตายตัว → ตอนนี้คำนวณจาก `MIGRATIONS` (migration ใหม่ไม่ทำให้ล้มอีก)

## 3. Client
- Drift **schema v14**: ตาราง `PaymentAccounts` (cache, รูปเป็น bytes) + `Sales.paymentAccountId` (text, **ไม่ใช่ FK** — บิลเก็บ id ไว้แม้บัญชีถูกลบ) · `from < 14` · `build_runner` รันใน worktree ที่ path เป็น ASCII · reset ทั้ง 3 แบบล้างตาราง
- `promptPayPayload(id, amount)` (`core/utils/promptpay.dart`) — EMVCo/Thai QR, tag 00·01·29·58·53·54·63, CRC16-CCITT-FALSE · ตรง 12 vector ที่เผยแพร่ (dtinth/promptpay-qr `index.test.js`, kittinan/php-promptpay-qr `PromptPayTest.php`) · ยอด = `_total` (หลังส่วนลด) เท่ากับ `total` ที่ส่ง
- รูป: `core/utils/qr_image.dart` ย่อด้วย `instantiateImageCodec` → PNG ≤ 600 px / ≤ 300,000 byte (ลด 20% ต่อรอบถึง 200 px แล้วปฏิเสธ) · **ไม่เพิ่ม package**
- `PaymentAccountsRepository` (Drift build: CRUD ในเครื่อง, ไม่มี login จึงใครก็แก้) / `ApiPaymentAccountsRepository` (เขียนออนไลน์เท่านั้น, ปฏิเสธตอน Degraded, เขียน Drift จากคำตอบ server เท่านั้น, `PendingWrites`, 5xx = ข้อความไทยเรื่องการเชื่อมต่อ ไม่มีข้อยกเว้น `_keepsServerText`) · pull ตอนเปิดแอป/login/reconnect + ตอนเปิดหน้าตั้งค่า · pull แทนที่ทั้ง list (บัญชีที่ลบหายจาก cache)
- **ตั้งค่า → 📱 บัญชีรับเงิน QR** (`payment_accounts_settings.dart`): เพิ่ม/แก้/ลบ/ตั้งค่าเริ่มต้น, ปุ่มเพิ่มปิดที่ 5, ไม่ใช่ owner = ดูอย่างเดียว · เปลี่ยนชนิดไม่ได้ (ลบแล้วเพิ่มใหม่)
- **หน้าขาย → โอน/QR** (`qr_payment_panel.dart`): QR ของบัญชีเริ่มต้น (ไม่มี = บัญชีแรก) + ยอด, ชิปเปลี่ยนบัญชี, ปุ่มขยายเต็มจอ, รูป QR มีพื้นขาว · ไม่มีบัญชี = hint ให้เจ้าของไปเพิ่ม และยังขายเป็น `โอน/QR` (บัญชี NULL) ได้
  - โหลดบัญชีใหม่เมื่อ cache เปลี่ยน / กด โอน/QR / เปิดบิลพักที่เป็น โอน/QR (change signal ของ repo — **ไม่ใช้ Drift `watch()`**: ทำให้ widget test ค้างเพราะ timer)
  - **ปักบัญชีของบิลตั้งแต่ครั้งแรกที่ resolve** · บัญชีหายหลัง refresh → สลับเป็นค่าเริ่มต้นเฉพาะเมื่อไม่มี attempt ค้าง (`SalesRepository.hasParkedAttempt`) — กันรหัสบิล/คีย์ใหม่จากการเปลี่ยน default เงียบ ๆ = ขายซ้ำ
  - บิลพักเก็บบัญชี (เฉพาะบิล QR)
- **รายงานปิดกะ**: ใต้ `📱 โอน/QR` แยกตามชื่อบัญชี · id ที่ไม่อยู่ใน cache = `บัญชีที่ลบแล้ว` (รวมเป็นแถวเดียว) · NULL = `ไม่ระบุบัญชี` · คืนเงินหักจากบัญชีของบิลเดิม · ผลรวมแถว = ยอด โอน/QR

## 4. ข้อความไทย — owner รับรอง 2026-10-10
- error 3 ตัวใน `02 §8.1`: `PAYMENT_ACCOUNT_LIMIT` `บันทึกบัญชีรับเงินได้สูงสุด 5 บัญชี` · `OWNER_ONLY` `เฉพาะเจ้าของร้านเท่านั้นที่แก้ไขบัญชีรับเงินได้` · `PAYMENT_ACCOUNT_NOT_FOUND` `ไม่พบบัญชีรับเงินที่เลือก กรุณาเลือกบัญชีใหม่`
- UI ~46 ข้อความ (ตั้งค่า, dialog, validation, หน้าขาย, รายงาน, `ไม่พบบัญชีรับเงินนี้ อาจถูกลบไปแล้ว`) อยู่ใน `02 §8.1.1` · comment ในโค้ด `// เจ้าของรับรอง 2026-10-10`

## 5. Research (ยังไม่ทำ — owner สั่งแค่คิด)
- [`docs/research/qr-dynamic-amount-bank-api.md`](../research/qr-dynamic-amount-bank-api.md): QR ใส่ยอดทำเองได้ (ทำแล้วในงานนี้) แต่ยืนยันเงินเข้าไม่ได้ · ยืนยันอัตโนมัติต้อง QR ร้านค้า (Tag 30) + merchant API — KBank เฉพาะนิติบุคคล, SCB ไม่บอกเงื่อนไข production · ต้องมี callback HTTPS สาธารณะ — `mob04` อยู่หลัง FortiGate/VPN · **คำถาม owner 4 ข้อ:** ร้านเป็นนิติบุคคลไหม · ธนาคารไหน · เครือข่ายมหาวิทยาลัยเปิดขาเข้าได้ไหม · ธนาคารยอมให้ poll แทน callback ไหม · **ไม่พบเอกสารว่าแอปทุกธนาคารเติมยอดจาก tag 54 — ต้องลองสแกนจริง**
- [`docs/research/slip-verification-api.md`](../research/slip-verification-api.md): mini-QR บนสลิปมีแค่ transRef + รหัสธนาคาร · แนะนำ **EasySlip** (สำรอง Slip2Go) · ทุกเจ้าเป็นขาออก (ต้องขอ FortiGate เปิดโดเมน) · ระบบเราต้อง UNIQUE `(tenant_id, sending_bank, trans_ref)` + เทียบผู้รับกับ `payment_accounts` + เทียบยอด + สถานะรอตรวจ + ปุ่มอนุมัติเองเมื่อ vendor ล่ม

## 6. ทดสอบ
- client: `dart analyze` สะอาด · `flutter test` **1691** ผ่าน (ใหม่: `promptpay_payload_test` 15, `payment_accounts_repository_test`, `payment_accounts_settings_test`, `checkout_qr_payment_test`, `closing_report_qr_accounts_test`, `schema_v14_migration_test`)
- server: lint + typecheck สะอาด · unit **751** ผ่าน · e2e ใหม่ `payment-accounts.e2e-spec.ts`, `payment-accounts-backup.e2e-spec.ts` · agent รัน e2e ใน Docker เครื่อง: ไฟล์ที่เกี่ยวข้อง 112 ผ่าน (ทั้งชุด 873/885 — 12 ที่ล้มเป็นเรื่อง Windows ใน `platform-cli`/`backup-restore`/`stock-race-three-writers` ที่ CI ผ่าน)
- CI #676/#677 เขียวทั้งหมด รวม `integration` (Postgres + migration จริง) และ `drift codegen is up to date`

## 7. ยังค้าง / ข้อควรรู้
- **ยังไม่ได้ลองบนเครื่องจริง** — สร้างบัญชีบน `mob04`, สแกน QR ใส่ยอดด้วยแอป SCB/KBANK/อื่น ๆ ว่ายอดขึ้นเองจริง, ลองรูป QR ร้านค้า · browser อาจเสิร์ฟ build เก่า: Ctrl+Shift+R / Incognito
- เครื่องขายเห็นเลขพร้อมเพย์เต็ม (อาจเป็นเลขบัตรประชาชน) — ปิดบังไม่ได้เพราะต้องใช้สร้าง QR · แถวที่ลบเก็บรูป/เลขไว้ตลอด (PDPA — นโยบายลบจริงเป็นเรื่องของ owner)
- ไม่ได้ทำ: UI จัดลำดับ (`sortOrder` มีแต่ไม่มีที่ตั้ง), pull ดาวน์โหลดรูปทั้งชุดทุก reconnect (ไม่มี `updatedAt` check), ชื่อบัญชีที่ลบในรายงาน (รวมเป็น `บัญชีที่ลบแล้ว`), บัญชีที่เครื่องยัง pull ไม่ถึงก็ขึ้น `บัญชีที่ลบแล้ว`, แถว `ไม่ระบุบัญชี (0 บิล)` ติดลบเมื่อคืนเงินโอนของบิลเงินสด (ยอดรวมยังถูก)
- `TENANT_SCOPED_TABLES` (sweep ข้ามร้านแบบ generic) ยังไม่รวม `payment_accounts` — มีเทสต์ RLS ของตัวเองแทน
- การตัดสินใจ "ตรวจเงินเข้าอัตโนมัติ" / "ตรวจสลิป" รอคำตอบ owner ตามข้อ 5
