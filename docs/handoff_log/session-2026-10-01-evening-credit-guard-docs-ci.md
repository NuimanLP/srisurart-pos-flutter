# Handoff — 2026-10-01 (เย็น): pull ไม่ทับเครดิตที่ยังไม่ส่ง · docs-only push ข้ามเทสต์/deploy · deploy `531984d`

ต่อจาก [`session-2026-10-01-afternoon-ux-auth-tenant-gitleaks.md`](session-2026-10-01-afternoon-ux-auth-tenant-gitleaks.md).

## สถานะท้ายรอบ
- `main` = `531984d` (merge #544) · Deploy run `36869888336` approve แล้ว → `resolve release` + `deploy to demo` success
- VM `/opt/pos/.current_sha` = `531984de8f54a7399461183232417be0c86bc283` == main · `/health/ready` 200 (orchestrator ตรวจผ่าน SSH)
- #543 (ratify ข้อความไทย 2026-10-01 + Dependabot security updates เปิด) merged ก่อนหน้า (`ce777cc`)
- ไม่มี PR เปิดค้างจากรอบนี้

## ทำอะไรไป — PR #544 (PR เดียว deploy รอบเดียว ตามที่ owner สั่ง)
1. **pull ลูกค้า/ช่างไม่ทับยอดที่ยังไม่ส่ง** (`frontend/lib/data/sync/outbox_ledger_refs.dart` ใหม่, `api_customers_repository.dart`, `api_mechanics_repository.dart`, `sync_service.dart`)
   - row ที่ถูกอ้างโดย money op (`sale.create`, `sale.void_offline`, `return.create`, `credit_payment.create` — ทุกสถานะ รวม `rejected`) หรือ `pending_credit_payments` → เก็บค่าในเครื่อง: ลูกค้า `points`/`totalSpend`, ช่าง `creditBalance`/`totalSales`/`totalDiscount`/`totalMarkup` · field อื่นมาจาก server (เหมือน stock guard ของสินค้า)
   - คำนวณ guard ใหม่ **ทุกหน้า ภายใน txn `writeCacheIfCurrent`** · cursor ที่บันทึกไม่เลย row ที่ถูกกัน (ถูกส่งซ้ำรอบหน้า) — แลกกับการดึง row นั้นซ้ำทุกครั้งระหว่างถูกกัน
   - `customer.update/create` ไม่ล็อกยอดอีก (ไม่ใช่ money op)
   - `_patchAppliedEntity`: `balanceAfter` ของ credit payment ไม่ทับ ถ้ายังมี money op ของช่างคนเดียวกันค้าง (**ไม่มีเทสต์** — ไม่มี harness ของ push-reply path นี้)
   - `rejected` นับด้วยเพราะ discard ลบ delta ที่บันทึกไว้ — ถ้า pull ทับไปก่อนจะลบซ้ำ · stock guard ของสินค้า **ยังนับแค่ pending/stuck** (ไม่ได้แตะ)
   - เทสต์ 820/820, `dart analyze` clean · ถอด fix ออก → keep-tests แดง
   - ⚠️ money-op type ใหม่ในอนาคตต้องเพิ่มใน `_moneyOps` ไม่งั้นไม่ถูกกัน
2. **docs-only push ไป main ข้ามเทสต์หนัก/image → ไม่มี deploy รอ approve** (`deploy/scripts/push-changes-kind.sh` ใหม่, `server.yml`, `flutter.yml`, `deploy.yml`)
   - classifier ใช้ `git diff --no-renames --name-only before..sha` · docs = `*.md` หรือ `docs/**` ยกเว้น `docs/Backend_design/fixtures/**` · `before` เป็นศูนย์/diff ล้ม/ว่าง → `code=true`
   - job `changes` รันทั้ง PR และ push · dorny เฉพาะ PR · status jobs ยัง always-report · `secrets` (gitleaks) ไม่แตะ · `workflow_dispatch` รันทุกอย่าง
   - `deploy.yml` resolve: main เลยไปแค่ docs → ยัง deploy code SHA ของ run · dispatch `image_tag` ว่าง → หา commit code ล่าสุด (first-parent ≤100)
   - review เจอบั๊ก CRITICAL ก่อน merge: dorny รันตอน push แล้วคืน `'false'` ชนะ `||` → push ที่แก้ฝั่งเดียวจะไม่ build อีกฝั่ง → ไม่ deploy เงียบ · แก้แล้ว (dorny `if: pull_request`)
   - ✅ **รอบนี้ (PR handoff นี้) คือการทดสอบจริงครั้งแรกของ docs-only path** — ตรวจว่า required checks เขียว, ไม่มี build-image/integration, ไม่มี deploy รอ approve

## คำถาม owner ในรอบนี้
- ล้าง/รีเซ็ตเพื่อลองใหม่: owner **ไม่ปิด tenant เดิม** · deploy ไม่ล้าง Postgres · ฝั่งเครื่องล้างได้ด้วย Clear site data (ไม่มีงานค้าง) · ล้าง `pgdata` = owner decision + ไม่มี backup นอก VM (#363 parked) — **ไม่ได้ทำ**
- server ไม่มีคำสั่งลบ tenant (platform CLI: `tenants:create/list/show/status`, `owner:temp-password`, `devices:reissue-code`)

## บทเรียน
- 🔴 script รอ CI ต้องรอให้ required checks **ปรากฏ** ก่อน `gh pr checks --watch --required` — ไม่งั้นได้ "no required checks reported" แล้วล้มทันที
- 🔴 `${{ a || b }}` ใน Actions: string `'false'` ไม่ว่าง = truthy → ห้ามให้สอง step คืนค่าใน event เดียวกัน
- `git diff --name-only` ตรวจ rename โดย default → ไฟล์ code ที่ `git mv` เข้า `docs/` ดูเหมือน docs-only · ใช้ `--no-renames`

## ยังค้าง (ไม่เปลี่ยนจากบ่าย)
- รอ owner/ฮาร์ดแวร์: #344 demo, #380 k6, #476, #443 (ยังไม่มีคน login platform-ui), #231, #363/#288 (parked)
- accepted limits: reply ของ online write ที่ค้างตอนสลับร้านไม่ถูก fence · ไม่มี server logout endpoint
