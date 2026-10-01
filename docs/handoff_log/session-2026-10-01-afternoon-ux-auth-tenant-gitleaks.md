# Handoff — 2026-10-01 (บ่าย): UX ลบสินค้า/ตะกร้า · auth + session · cache แยกร้าน · gitleaks · deploy `f4c821b`

ต่อจาก [`session-2026-10-01-month-rollover-and-lesson-19.md`](session-2026-10-01-month-rollover-and-lesson-19.md).

## สถานะท้ายรอบ
- `main` = `f4c821b` (merge #541) · Deploy run `36852075891` (`f4c821b`) = success · VM `/opt/pos/.current_sha` = `f4c821b` + `/health/ready` 200 (ตรวจโดย orchestrator) · ก่อนหน้า `6a11ee8` (run `36850286950`)
- VM `.current_sha` ตรวจโดย orchestrator (ไม่ได้ตรวจซ้ำในไฟล์นี้) — green run อย่างเดียวไม่ใช่หลักฐาน
- **PR #541 merged** (`f4c821b`, follow-up ของ #539 — ดูข้อ 7) · review ผ่าน · deploy แล้ว
- GitHub repo security (ตรวจ `gh api repos/…` 2026-10-01): secret scanning **enabled**, push protection **enabled**, Dependabot security updates **disabled**

## ทำอะไรไป (PR merged)
1. **#527** handoff เช้า + แก้ VM tutorial (SHA เก่า, ถ้อยคำ CORS #516, ข้อความ duplicate-deploy)
2. **#528 / #530 — build API ไม่มี demo seed** — `AppDatabase` ไม่ seed ข้อมูลธุรกิจตัวอย่างเมื่อ `USE_API_WRITES` · DB ที่ seed ไปแล้วได้ `purgeDemoSeed()` ครั้งเดียว (marker `demo_seed_purged`) · #530 เพิ่ม guard: ข้ามเมื่อมี outbox/credit payment ค้าง และ **ไม่ลบ row ที่มี record อ้างอิง**
3. **#529** ตา show/hide รหัสผ่าน + checklist เงื่อนไขรหัสผ่านแบบ live (+ review fixes)
4. **#531** ลบสินค้าหลายรายการหน้า stock · **#532** ปุ่มล้างตะกร้า · **#540** ผลตัดสิน owner ของ bulk delete: เตือนสินค้าที่ถูกเอกสารอ้างอิง, ใช้ได้ทุกเครื่อง, ratify ข้อความไทยของวันนี้ (quote filter ผ่าน `QuoteRowStatus`)
5. **Gitleaks (#533 / #535 / #526)** — job `secrets` ใน `server.yml` คุม `server-ci-status` · allowlist อ่านจาก **base sha** บน PR · `--ignore-gitleaks-allow` · `-v --redact` · allowlist ผูกไฟล์ตัวเอง · แยก "ไม่มีไฟล์" ออกจาก git error (รายละเอียด `07_CICD_DEPLOY.md §2a`) · **เปิด GitHub secret scanning + push protection จริง 2026-10-01** (ADR-0013 เขียนว่าเปิดทั้งที่ยังปิดอยู่) · Dependabot security updates **ยังปิด**
6. **Auth/session (#534 / #536 / #537)** — logout พาไปหน้า checkout + ล้างตะกร้า/quote ที่ค้าง · autofill hints ช่อง login · chip ระหว่าง login · `ApiClient` มี **session generation**: refresh/401 ที่มาช้า หรือ token ของ session เก่า ไม่มีทางทำงานแทนคนถัดไป (แนบ token เฉพาะ request ของ session ตัวเอง)
7. **cache แยกร้าน (#539)** — `AppMeta tenant_id` · `resetTenantCache` / `resetPulledCache` · `cacheGeneration` fence กัน pull/seed ที่มาช้าเขียนข้ามร้าน · **ปฏิเสธการสลับร้านถ้ามีงานยังไม่ส่ง** (`TENANT_SWITCH_UNSENT_WORK`) · ผูกเครื่องไม่ได้ถ้ามีงานค้าง (`ENROL_UNSENT_WORK`) · token ไม่มี tenant (`TOKEN_TENANT_MISSING`) · DB เก่าไม่มี marker = adopt ร้านแรก เก็บประวัติบิล
   - **#541 (merged `f4c821b`)**: DB เก่า + device-token login เคยลบ products/customers/mechanics ทั้งที่งานค้าง → ตอนนี้ `resetPulledCache(keepStockAndLedgers: true)` ขณะ `hasUnsentWork()` · เพิ่ม `fenceCacheWrites()` หลัง `beginSession()` · comment ข้อความไทย trimmed
8. **#538** เทสต์ TTL ของ platform flaky (argon2 ข้ามขอบวินาที) → แก้ — **main แดง = ไม่มี image = deploy ข้ามเงียบ**

## สอบสวน: owner login ไม่ได้ 08:00Z
DB ปกติ (ตามที่ orchestrator ตรวจ `audit_log`): เปลี่ยนรหัส 05:45 → `invalid_password` 08:00 ×2 → reissue รหัสชั่วคราว 08:03 · เหตุที่น่าจะเป็น: browser autofill ใส่รหัสชั่วคราวเก่า · แก้ด้วย autofill hints (#534) — **ยังไม่พิสูจน์ใน browser จริง**

## บทเรียน
- 🔴 **PR ถูก merge ด้วยบัญชี NuimanLP ก่อน review fix ลง** — #533, #534, #536, #539 ต้องเปิด PR ตามแก้ (#535, #536, #537, #541) · เช็ค `headRefOid` ตอน merge (กฎเดิมใน CLAUDE.md)
- 🔴 Deploy run ที่รอ approve ถือ slot `deploy-demo` → run ใหม่ค้าง `pending` · **cancel run รอเก่าก่อน approve** · API approve ต้องส่ง `comment`
- 🔴 เทสต์อิงเวลา flaky (argon2/ขอบวินาที, ข้ามเดือนเมื่อเช้า) ทำ `main` แดง → deploy ข้าม
- doc บอก "เปิด" ไม่เท่ากับเปิดจริง (secret scanning) — ตรวจด้วย `gh api` ไม่ใช่เชื่อ ADR

## ยังเปิด — ต้อง owner
- ข้อความไทยยัง **agent ร่าง** (`02_API_SCREENS.md §8.1.1`): `TENANT_SWITCH_UNSENT_WORK` (ฉบับ trim), `ENROL_UNSENT_WORK`, `TOKEN_TENANT_MISSING`, ข้อความเตือน doc-ref ของ #540
- **ขีดจำกัดที่ยอมรับ:** reply ของ write ออนไลน์ที่ค้างระหว่าง logout→login คนละร้านยังไม่ถูก fence (เฉพาะ pull/seed) · ไม่มี server logout endpoint
- full pull ของ customers/mechanics เขียนทับยอดเครดิตที่ยังไม่ส่ง (ไม่มี pending-op guard)
- ~~Dependabot security updates ยังปิด~~ — เปิดแล้ว 2026-10-01 (alerts + security updates) · ข้อความไทยที่ค้าง (ENROL_UNSENT_WORK, TOKEN_TENANT_MISSING, TENANT_SWITCH_UNSENT_WORK ฉบับตัด, คำเตือนเอกสารเปิดของ #540) เจ้าของรับรอง 2026-10-01
- เดิม: #344 เดโม · #380 k6 · #476 · #443 · #231 · #363/#288 พัก · cron 03:00 `backup-db.sh` ยังไม่ตรวจ
