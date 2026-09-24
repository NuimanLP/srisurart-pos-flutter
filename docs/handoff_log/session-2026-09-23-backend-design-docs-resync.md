# Handoff — รีวิว `01_DATABASE.md` แล้ว re-sync `docs/Backend_design/` ทั้งชุดให้ตรงของจริง

**Date**: 2026-09-23
**Branch**: `docs/01-database-sync-migrations` → **PR #390**
**Scope**: เอกสารเท่านั้น — ไม่มีไฟล์โค้ดถูกแตะ (`server/`, `frontend/`, `.github/`, `deploy/` ไม่เปลี่ยน)

---

## 1. เกิดอะไรขึ้น

1. **`/code-review` ของ `01_DATABASE.md`** แบบสองแกนขนานกัน (ไม่ใช่ diff — รีวิวไฟล์ทั้งไฟล์):
   - *Standards*: เทียบ checklist PostgreSQL ของผู้ใช้ (snake_case, PK, TIMESTAMPTZ, NUMERIC, CHECK, FK `ON DELETE`, index บน FK ฯลฯ) โดยให้กติกาของ repo ชนะ
   - *Spec*: เทียบ ADR (ADR ชนะ) + migration จริง 14 ไฟล์
2. เจ้าของสั่ง "update ให้ up to date" → แก้ `01_DATABASE.md` เอง (อ่าน migration ทุกไฟล์ก่อน)
3. เจ้าของสั่งให้ส่ง agent ไปไฟล์อื่น → 8 agent ขนานกัน แบ่งไฟล์ไม่ทับกัน:
   `02` · `03` · `07` · `08+09` · `00_BASICS+00_INDEX` · `architecture*` (4) · `checklist` · `04/05/06` (ประวัติ — banner เท่านั้น)
   กติกาที่ให้ทุกตัว: ADR > โค้ด > เอกสาร · ห้าม commit · ห้ามแตะคำตัดสิน owner / สตริงไทยที่ ratify แล้ว ·
   ห้ามติ๊ก AC/DoD โดยไม่มีหลักฐาน · ห้ามอ้าง deploy/k6/backup ว่าเสร็จ · เรื่องที่ต้อง owner ให้รายงานกลับ
4. commit `e51aed3` → PR #390 · รอบนี้ (handoff) อัปเดต `CLAUDE.md` ด้วยข้อเท็จจริงที่ตรวจซ้ำแล้ว

ทุกจุดที่แก้ในเอกสารมีหมายเหตุ "แก้ 2026-09-23" · 16 ไฟล์ +1186/−659

## 2. ข้อเท็จจริงที่ตรวจซ้ำเองแล้ว (ไม่ใช่แค่ agent บอก)

| เรื่อง | หลักฐาน |
|---|---|
| Postgres 29 ตาราง | `InitialSchema` 27 + `…2200-ImportJobs` + `…3002-OwnerReviewItems` · `change_log` ไม่สร้าง |
| RLS บน 26 ตาราง | `TENANT_SCOPED_TABLES` 25 ตัว (`…0001:4-31`) + `owner_review_items` · `import_jobs` ตั้งใจไม่เปิด (platform plane เท่านั้น) |
| 🔴 บั๊ก RLS ไม่มี `NULLIF` | `…3002-OwnerReviewItems.ts:55-56` เทียบ `…0001:62-63` |
| 🔴 บั๊ก FK `SET NULL` | `…3002:34` — nulls `tenant_id` ที่ NOT NULL ด้วย |
| `InitialSchema` ถูกแก้หลังรัน | `git show 225ecf7 -- …InitialSchema.ts` (role CHECK + ลบ `pin_hash`) |
| #272/#266 ปิดแล้ว | `gh issue view` → CLOSED 2026-09-19 · PR #310 / commit `8faebac` |
| #67 ปิดแต่ runner ไม่มี | CLOSED 2026-09-20 · `gh api …/actions/runners` → `total_count: 0` |
| Deploy ค้าง | `gh run list --workflow deploy.yml` → `d3a2801` waiting ตั้งแต่ 22/09, `616c187` pending ข้างหลัง |
| demo env | `protection_rules: [required_reviewers]` · `deployment_branch_policy: null` |
| Drift | 25 ตาราง (`tables.dart`), `schemaVersion => 11` (`database.dart:72`) |

## 3. สิ่งที่ยังไม่ได้ทำ (ตั้งใจ)

- **บั๊ก 2 จุดของ `owner_review_items`** — บันทึกใน `01 §11` + `CLAUDE.md` · ต้องแก้ด้วย **migration ใหม่** (เช่น `DROP POLICY tenant_isolation_policy` → `CREATE POLICY tenant_isolation … NULLIF(...)` + drop/recreate FK เป็น `ON DELETE SET NULL (reviewed_by)`) พร้อมเทสต์ที่พิสูจน์ทั้งสองทาง
- **ข้อเสนอเชิงออกแบบจาก Standards review** ไม่ได้ทำ เพราะเป็นการเปลี่ยน schema ไม่ใช่ re-sync:
  trigger `updated_at`, `ON DELETE RESTRICT` ที่ชัดเจน, FK ที่ขาด (`shift_id`, `sale_items.product_id`, ฯลฯ — บางตัวตั้งใจไม่มี FK ดูเหตุผลใน `01 §5.3/5.4`),
  CHECK `total_spend/total_sales >= 0`, REVOKE DELETE บน ledger, `COLLATE "C"` บน id TEXT
- โค้ด: `void.service.ts` ยังมีคอมเมนต์ "PIN" ค้าง · audit A1–A15 ของ primer ยังไม่รันซ้ำบนฉบับที่แก้

## 4. รอ owner ตัดสิน

1. Deploy คิว: approve `d3a2801` = ส่งเวอร์ชันเก่าก่อน — cancel แล้ว approve `616c187` แทนหรือไม่
2. `demo` env `deployment_branch_policy` เป็น `null` — ตั้งกลับเป็น `main` เท่านั้นหรือไม่ · fork approval ปรับเป็น `all_external_contributors` หรือไม่
3. reopen #67 หรือไม่ (ปิดแล้วแต่ไม่มี runner)
4. สตริงไทย/code `OVERPAYMENT` ใน `sync.service.ts` `mapOpError` ที่ไม่มีใคร ratify · `DEVICE_ROLE_FORBIDDEN` ถูกใช้กับกรณี "ไม่มี `did`" ด้วย ข้อความไม่ตรง
5. `/sync/discards` รับแค่ device token — ขัด 08 §14 ที่ต้องล็อกอินจริง
6. `POST /shifts/open` ออนไลน์อ่าน `openedAt` จาก client — ขัด 08 §10 (online = `now()`)
7. `TODO(owner)` ใน `nginx.conf`: CIDR ของมหาลัยสำหรับ remote-write (ต้องก่อน #380) + admin IP

## 5. คำถามจากอาจารย์ (บันทึกไว้เผื่อถูกถามซ้ำ)

- **"PK มีหลายอัน?"** → มีอันเดียวแต่เป็น composite `(tenant_id, id)` · composite FK ทำให้ฐานข้อมูลปฏิเสธการอ้างข้ามร้านเอง · ทางเลือก PK เดี่ยว `id UUID` + `UNIQUE (tenant_id, id)` ถูกต้องเหมือนกัน แลกกับ index สองตัว
- **"ทำไม id เป็น TEXT จะช้าไหม?"** → เครื่อง `pos` ต้องสร้าง id เองตอนออฟไลน์ (`newId()` = prefix + base36 เวลา + สุ่ม 8 hex + counter ≈ 21 bytes) + retry/replay ปลอดภัย + import id เก่าจาก JS · ยอมรับว่าใหญ่/ช้ากว่า BIGINT แต่ขนาดร้าน (~แสนแถว/ปี) ไม่มีผล และ id ขึ้นต้นด้วยเวลาจึงไม่กระจาย index แบบ UUIDv4 · ทางอัปเกรด: UUIDv7 ในคอลัมน์ `UUID` · จุดอ่อนจริง: ไม่มี `COLLATE "C"`

## 6. กับดักที่เจอ

- agent หลายตัวรายงาน "CLAUDE.md ล้าสมัย" — **ตรวจกับ `gh` เองก่อนแก้ทุกข้อ** (ตรงทุกข้อรอบนี้ แต่อย่าเชื่อต่อโดยไม่ตรวจ — ดู "~30%" ใน handoff 22/09)
- `pnpm test` บนเครื่องนี้พัง 3 suite เพราะ `prom-client` ไม่อยู่ใน local install (install เก่า) — CI ผ่าน อย่าเข้าใจว่าเทสต์พังจริง
