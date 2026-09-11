# Handoff — เคลียร์ branch ทั้งหมดเข้า `main`: merge #74 #75 #73 + รอบตรวจก่อน merge (2026-09-11)

**วันที่:** 2026-09-11 · **ผู้บันทึก:** เจ้าของโปรเจกต์ (NuiGates) สั่งงาน · Claude Fable 5.1 เป็น orchestrator ส่ง agent Opus ×5 / Sonnet ×1 · **สถานะ:** ปิดแล้ว
**ขอบเขต:** ทำให้ repo เหลือ branch เดียวที่มีชีวิต (`main`) โดย review แล้ว merge PR ที่ค้างทั้ง 3 ใบ และลบ branch ที่ merge ไปแล้วทุกอัน
**ต่อจาก:** [`lane-a-review-and-adr0003.md`](lane-a-review-and-adr0003.md) (รอบตรวจแรกของ #75) · [`review-merge-schema-v3.md`](review-merge-schema-v3.md) (#73)

## 1. ตอนนี้อยู่ตรงไหน

- `origin` เหลือ **2 branch**: `main` และ `POC_sample_offline_first` (แช่แข็งตามนโยบาย ห้ามลบ) · **open PR = 0**
- merge เข้า `main` วันนี้ตามลำดับ: **#74** (`f7d2265`) → **#75** (`a5d12e8`) → **#73** (`9636311`) · ทุกใบ merge commit ไม่ squash
- #19 #20 ปิดอัตโนมัติจาก #75 · **#23 #28 ยังเปิด** โดยตั้งใจ (รอ #21/#22)
- `main` มี 4 migration แล้ว: ตัวใหม่คือ `1788652800003-MovementsVoidType` (เพิ่ม `'void'` ใน `movements.type`)
- `CLAUDE.md` ย่อหน้า *Lane A* กับ *ADR-0003* อัปเดตแล้ว (`4736888`) · `AGENTS.md` sync ตามในคอมมิตนี้

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

1. **สำรวจสภาพก่อนทำ** — local 9 branch / remote 9 branch / open PR 3 ใบ · หา "0 commit ahead of `main`" ด้วย `git rev-list --left-right --count` แล้วลบ:
   remote `feat/fe0-drift-schema-v3` (#58) `feat/p5.1-idempotency` (#51) `lane2` (#59) · local `backend-design-adr` `docs/cicd-design-adr-0013` (#68) `docs/ghcr-visibility-correction` (#71) `feat/fe0-drift-schema-v3`
2. **ตรวจ 3 PR แบบขนาน** (Opus: scrutinize + code-review 2 แกน บน #75 · Sonnet: #73 #74)
   - **#74** ลบ fallback `NODE_ENV==='test' ? 'dummy'` ของ JWT keys — trace แล้ว e2e spec ทั้งสองใส่ค่า inline อยู่แล้ว, compose บังคับ `${VAR:?required}` → fallback ตายอยู่แล้วและ fail-open → **ship**
   - **#75** unit 81 · e2e 109 + 1 todo รันจริงบน compose · ยืนยันคำอ้างในตัว PR ได้หมด (pool-deadlock fix จริง, 200 บิลชน 50 ชิ้นวิ่งบน Postgres จริงไม่ mock, `SET LOCAL $1` เป็น syntax error จริง, ไม่มี Thai string ประดิษฐ์) แต่เจอ **4 อย่างต้องแก้ก่อน merge** (ดู 3.)
   - **#73** docs อย่างเดียว fact ตรง repo ทั้งหมด แต่ **ชน #75 ใน `INDEX.md`** (test-merge ทั้งสองทิศแล้วชนจริง) → merge เป็นใบสุดท้าย
3. **แก้ #75 รอบ 2** (agent Opus 2 ตัว · commit `ff8c304` `5e9519d` `bef5bfa` `ca99494`)
   - `items[].price` ติดลบผ่านทุก check ระดับ total (`assertMoneyMakesSense` ดูแค่ subtotal/discount/total, `sale_items` มีแค่ `CHECK (qty > 0)`) → บิล `+1000 / -1000` เขียน total 0 ตัดสต็อก 2 ชิ้น price ติดลบ → ตอนนี้ 400 + unit + e2e (unit 81 → 83)
   - **ADR-0003 addendum ห้ามโค้ดที่ PR เดียวกันส่งมอบ** (ลิสต์ "สิ่งที่ตายไปพร้อมกัน" มี `RequestContextMiddleware` `TransactionInterceptor` ที่ PR เพิ่ม) → ใส่สถานะ **เสนอ (Proposed)** มีผลเมื่อ `tx.4` ลง + แก้แถว 0003 ใน `adr/README.md` 2 จุด + 1 ประโยคใน `server/README.md`
   - void เขียน `movements.type='return'` (ref `void:<id>`) → รายงานที่ group ตาม type นับ void เป็นคืนของ → migration `1788652800003` เพิ่ม `'void'` (constraint ชื่อ `movements_type_check` ยืนยันจาก `pg_get_constraintdef`), `ref_id` เป็น sale id เปล่า, ลบ `VOID_REF_PREFIX` (grep แล้วไม่มี read path ใช้)
   - `server/docker/postgres/init/01-app-role.sh` mode `100644` → Docker Desktop macOS exec แล้ว `bad interpreter` → `pos_app` ไม่ถูกสร้าง (Linux/CI source ไฟล์แทนเลยไม่เจอ) → `100755` ทดสอบบน volume ใหม่ role ขึ้นจริง
   - nit: cap `?page=` ≤ 10 000 (`pageParams()` ใช้ร่วม sales/shifts), เพิ่ม `## 8. อ้างอิง` ใน handoff ที่ขาด, ย้าย `//` comment ออกจาก JSON ใน `02_API_SCREENS.md` §3.1
   - CI บน head สุดท้าย `ca99494`: lint · unit · integration · audit เขียวหมด
4. **แก้ conflict #73** — merge `origin/main` เข้า branch ใน worktree เก็บ bullet ทั้ง 3 บรรทัด (`9b8a867`) แล้ว merge
5. ลบ `laneC` (tip `d1ca397` diff ว่างเทียบกับ #74) และ branch ของ 3 PR หลัง merge

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

- **ลำดับ merge #74 → #75 → #73** — #74 ไม่แตะไฟล์ร่วมกับใคร · #75 เป็นโค้ดใหญ่ควร merge สะอาด · #73 เป็น docs รับ conflict ใน `INDEX.md` แทน — Sonnet เสนอ, orchestrator เลือก
- **ADR-0003 addendum → "เสนอ" ไม่ใช่แยก PR** — Spec agent เสนอให้ดึงออกเป็น PR ต่างหาก, Standards agent เสนอ mark Proposed · เลือกอย่างหลังเพราะ scrutinize ยืนยันว่า addendum มีเหตุผลจริง (วัด 112 → 18–28 ms) ไม่ใช่ doc ที่แต่งให้เข้ากับโค้ด และการแยก PR แค่ย้ายปัญหา "ADR ห้ามโค้ดบน main" ไปอีกใบ
- **void ได้ type ของตัวเองเลย ไม่รอ schema lane** — เจ้าของโปรเจกต์สั่ง "fix ให้เลย" · ต้นทุนคือ migration 32 บรรทัด · ทางเลือกคือปล่อยรายงานผิดจนกว่า `LomerAlloys` จะว่าง
- **`/sales/:id/void` เปิดให้ `owner` ด้วย** (นอกจาก manager+PIN) — ถูกขยายใน #75 แล้วแก้ spec §4.2 ตาม · เจ้าของโปรเจกต์ acknowledge ผ่านคำสั่ง "merge ทั้งหมด" หลังถูกชี้ให้เห็น
- **แก้ line-ending พังด้วย commit ใหม่ ไม่ force-push** — agent ตัวหนึ่งเผลอ push `bef5bfa` ที่ rewrite `01_DATABASE.md` CRLF → LF (2243 บรรทัด) · classifier ปฏิเสธ `--force-with-lease` · เลือก fix-forward `ca99494` (net diff ต่อไฟล์นั้น = +1 บรรทัด) เพราะ branch ยังมีคนดูอยู่และ history ไม่ต้องสวย
- **commit `CLAUDE.md`/`AGENTS.md` ตรงเข้า `main`** — `main` ไม่มี branch protection (`gh api …/protection` → 404) และเจ้าของโปรเจกต์ต้องการให้เหลือ branch เดียว ไม่เปิด PR ใหม่เพิ่มอีก

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- `gh pr review --approve` บน PR ตัวเอง — GitHub ปฏิเสธ (`Can not approve your own pull request`) · `gh pr comment` และ `gh pr merge` ถูก auto-mode classifier บล็อกในรอบแรก (merge ผ่านหลังเจ้าของโปรเจกต์สั่งชัดเจน, comment ไม่ผ่านเลย) → **บันทึกรีวิวจึงอยู่ใน handoff นี้ ไม่อยู่บน PR**
- `git worktree add -b <ชื่อ>` ทั้งที่ local branch ชื่อนั้นมีอยู่แล้ว → fatal แล้วคำสั่งถัดไปใน chain วิ่งบน checkout หลัก (โชคดีเป็นแค่ ff ของ `main`) → ใช้ `git branch -f` + `worktree add` แยกบรรทัด

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

- **ยืนยันแล้ว:** ทุก branch ที่ลบมี 0 commit ahead ของ `main` (หรือ diff ว่างกับ PR ที่ merge แล้ว) · `movements_type_check` คือชื่อ constraint จริง · init script ทำงานบน Docker Desktop macOS หลังแก้
- **ยังไม่ได้ตรวจ:** e2e บน `main` หลัง merge ครบ 3 ใบ — เชื่อจาก CI ของ #75 head สุดท้าย + #73 เป็น docs ล้วน · ไม่มี CI run บน `main` ที่ตรวจดูหลัง `9636311`
- **เดา:** `01_DATABASE.md` เดิมเป็น CRLF โดยตั้งใจ (ไฟล์อื่นใน docs เป็น LF) — ไม่ได้หาสาเหตุ แค่คงของเดิม

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **เจ้าของโปรเจกต์** ตัดสินบน #2 ว่า `tx.0`–`tx.5` (ADR-0003 handler-scoped) วิ่งก่อนหรือหลัง #21 #22 #32 #35 — `tx.3` (idempotency) คือ slice ที่ "พังเงียบและพังเป็นเงิน"
2. **#11** (`mechanics.total_credit`) ยังเป็นคำถามมนุษย์ → ปลดล็อก #21 → ปิด AC ที่ค้างของ #23 (void reverse ledger)
3. **#22** returns → ปิด AC ที่ค้างของ #28 (return ต้องมี `shift_id`)
4. เปิด ticket: e2e suite ทนคนรันพร้อมกันบน DB เดียวไม่ได้ (`schema.e2e-spec.ts` rebuild schema) — ยังไม่มีเลข
5. ทางเลือก: ตั้ง branch protection บน `main` ให้ต้องผ่าน `server-ci-status`/`flutter-ci-status` (ตอนนี้ push ตรงได้) — รอ #39 ก่อน ไม่งั้น PR ที่แตะฝั่งเดียวจะค้าง

## 7. ข้อควรระวัง

- **agent แก้ไฟล์ CRLF ด้วย Python ต้องเปิดด้วย `newline=''`** ไม่งั้น rewrite ทั้งไฟล์ — `docs/Backend_design/01_DATABASE.md` เป็น CRLF
- worktree ที่ agent สร้างใน scratchpad ต้อง `git worktree remove` + `git branch -D` เสมอ ไม่งั้น checkout หลักหลุดจาก `main` โดยไม่รู้ตัว (เจอครั้งหนึ่งในรอบนี้)
- `POC_sample_offline_first` ห้ามลบ (CLAUDE.md *Branch strategy*)
- ADR-0003 addendum เป็น **เสนอ** — อย่าเขียนโค้ดใหม่ตาม `runTx(fn)` จนกว่า `tx.1` ลง และอย่าเพิ่ม call site ของ `runTx(tid, fn)`

## 8. อ้างอิง

- PR: https://github.com/NuimanLP/srisurart-pos-flutter/pull/73 · /pull/74 · /pull/75
- merge commits บน `main`: `f7d2265` (#74) · `a5d12e8` (#75) · `9636311` (#73) · `4736888` (CLAUDE.md)
- แก้รอบ 2 ของ #75: `ff8c304` `5e9519d` `bef5bfa` `ca99494`
- [`../Backend_design/adr/0003-tenant-lifecycle.md`](../Backend_design/adr/0003-tenant-lifecycle.md) หัวข้อ *"ใครตัดสิน กับ ใครลงมือ"* (เสนอ) · [`0003-handler-scoped-migration-plan.md`](../Backend_design/adr/0003-handler-scoped-migration-plan.md)
- `server/src/db/migrations/1788652800003-MovementsVoidType.ts` · `server/src/sales/void.service.ts` · `server/src/sales/sales.dto.ts` (`parseLine`) · `server/src/common/paginated.ts` (`pageParams`)
- `server/docker/postgres/init/01-app-role.sh` (mode 100755)
- คนที่ต้องถาม: **เจ้าของโปรเจกต์** (#2 ลำดับ `tx.*`, #11) · **เจ้าของร้าน** (Thai string 3 ตัวหน้าเคาน์เตอร์ยังเป็น placeholder)
