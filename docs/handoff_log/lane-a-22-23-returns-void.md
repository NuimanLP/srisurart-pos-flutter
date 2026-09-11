# Handoff — #22 `POST /returns` + #23 void กลับรายการ ledger (2026-09-11)

**วันที่:** 2026-09-11 · **ผู้บันทึก:** เจ้าของโปรเจกต์ (NuiGates) สั่งงาน · Claude Opus 5 (1M) เป็น orchestrator ส่ง agent 7 ตัว (research ×2 · implement ×2 · review ×3) · fix round ทำด้วย agent อีก 1 ตัว · **สถานะ:** PR #78 merge แล้ว
**ขอบเขต:** ปิด ticket ที่เหลือของ `team/1` ที่ปลดล็อกแล้วสองใบ — #22 (`p5.5`) และครึ่งที่ยังค้างของ #23 (`p5.6`)
**ต่อจาก:** [`lane-a-21-ledger-effects.md`](lane-a-21-ledger-effects.md) (ก้าวถัดไปข้อ 1 และ 2 ของรอบนั้น)

## 1. ตอนนี้อยู่ตรงไหน

- **#22 และ #23 ปิดแล้ว** ผ่าน PR #78 (`26cfd07` feat · `6c322a1` feat · `1dbd73e` fix) — `POST /returns`, `GET /returns` และ void ที่กลับรายการ ledger ครบ
- **#28 ปลดล็อกแล้ว** — #22 เขียน `returns.shift_id` ให้ AC ข้อ "ทุก sale **และ return** ถือ `shift_id`" ไปครึ่งหนึ่ง ที่เหลือคือฝั่ง shift เอง
- ของ `team/1` ที่เหลือ: **#28** (ทำได้เลย) → **#30** (รอ #29 ของ team/2) · **#24** รอ #17 ของ team/2 · **#56** รอ #54 ของ team/3
- 🔴 **lock order ยาวขึ้นเป็น sale → mechanic → products → `doc_counters` → customer** — `sales` เป็นทรัพยากรนอกสุด (ทาง sale มีแต่ INSERT) จึงไม่เกิดวง · #28 กับ #30 ต้องตามลำดับนี้
- schema: migration ล่าสุดคือ **`1788652800004`** (`return_items.cost_at_sale`)

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

0. **เตรียมเครื่อง** — Docker Desktop ไม่ได้เปิด · `server/.env` ของเครื่องไม่มี `JWT_PRIVATE_KEY`/`JWT_PUBLIC_KEYS` (compose ตายทันที) เติมจาก `.env.example` · `pnpm` ไม่อยู่ใน PATH ต้องเรียกจาก corepack cache ตรง ๆ · 🔴 **DB ของเครื่องค้างอยู่ที่ migration 3 จาก 4** ไม่มี `1788652800003` (`movements.type='void'`) → e2e แดง 4 เคสที่ดูเหมือนบั๊กโค้ดแต่เป็น DB เก่า
1. **research 2 agent ขนาน (Sonnet, read-only)** — ตัวหนึ่งถอดกฎ + Thai string + เคสเทสต์ทั้งหมดจาก `returns_repository.dart`, อีกตัวทำ gap report ของ #23 เทียบ AC ทีละข้อ → **พบว่า #23 เหลือแค่ AC 3 ข้อเดียว** (1/2/4/5 มาตั้งแต่ PR #75) ประหยัดการ "สร้างใหม่ทั้งใบ"
2. **#22 (Opus)** — `src/returns/` (dto/service/controller/module) + migration `…004` + `returns.e2e-spec.ts` 14 เคส
3. **#23 (Opus)** — `void.service.ts` +103/−11: ขยาย locked read, `lockMechanic` ก่อน `restoreStock`, `reverseLedger`, เขียน comment เก่าที่ตอนนี้ผิดใหม่ · แทน `it.todo` ที่รออยู่ด้วยเทสต์จริง 2 เคส
4. **รอบตรวจ 3 agent ขนาน** — Standards (ไม่มีการละเมิดมาตรฐานที่เขียนไว้ เหลือ judgement call เรื่องโค้ดซ้ำ 2 จุด) · Spec (AC ครบทุกข้อ ตัวเลขตรง seed ของ Dart ไม่มี scope creep) · Scrutinize (**fix-then-ship** — เจอ blocker เรื่องเงิน 1 ตัว + อีก 5)
5. **fix round (Opus)** — แก้ครบ 6 จุด + เพิ่ม e2e 9 เคส
6. **ตรวจ:** lint · typecheck · unit 97 · e2e 149 passed / 13 files (แดง 2 เคสที่แดงอยู่ก่อนแล้ว) รัน 2 รอบ

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

- **ทำ #22 ก่อน #23 แบบเรียงกัน ไม่ขนาน** — ทั้งสองใบต้องรัน e2e และ CLAUDE.md เขียนไว้ว่า suite ทนคนรันสองคนบน DB เดียวไม่ได้ · research กับ review ขนานได้เพราะไม่แตะ DB
- **PR เดียวปิดสองใบ ไม่แยกสอง PR** — commit `1dbd73e` ที่แก้ blocker เรื่องราคาคร่อมทั้ง #22 และ #23 · แยก PR แปลว่า PR ของ #22 จะ merge บั๊กเงินที่รู้อยู่แล้วขึ้น `main` ก่อนแล้วค่อยตามแก้
- **เพิ่ม `return_items.cost_at_sale` เป็น migration ใหม่** — AC ข้อ 5 ของ #22 สั่งตรงตัว แต่คอลัมน์ไม่มีทั้งใน DDL และใน Dart reference · เหตุผลอยู่ในตัว issue เอง ("อ่าน cost ปัจจุบันใหม่ทำให้กำไรหลังคืนของบิลเก่าผิดหมด") = เป็นของใหม่ที่ตั้งใจ ไม่ใช่ parity · เอาค่าจาก `sale_items` ที่ล็อกอยู่แล้ว ไม่อ่าน `products.cost` ใหม่ (ตรรกะเดียวกับ ADR-0008)
- **ให้ #22 เขียน `returns.shift_id`** — handoff รอบก่อน §6 ข้อ 1 สั่งไว้ และ #28 เขียนเองจากนอก transaction ของ return ไม่ได้
- **เพิ่ม `GET /returns`** — AC ข้อ 6 บังคับว่าทุกเคสใน `returns_repository_test.dart` ต้องทำซ้ำได้ที่ HTTP seam และเคสสุดท้ายคือเรียงใหม่→เก่า · รอบ fix เติม `from`/`to` ให้ตรง `02_API_SCREENS.md §314` แทนที่จะปล่อยให้คนทำ returns-history ไปแก้ endpoint ที่ live แล้ว
- **ล็อก `sales` FOR UPDATE หัว transaction ทั้งที่ Dart ไม่มี** — Dart เป็น process เดียว เคสสองคนคืนของบิลเดียวกันพร้อมกันเกิดไม่ได้เลยไม่ใช่บั๊กที่นั่น · บน Postgres เกิดได้ และ guard จะผ่านทั้งคู่ · **พอร์ตพฤติกรรม ไม่ได้พอร์ตข้อจำกัดของ runtime เดิม**
- **ราคาคืน: บิลเป็นคนตัดสิน ไม่ใช่ body** — Dart ให้ client ส่งราคามาได้เพราะที่นั่น client *คือ* ผู้มีอำนาจ · ที่นี่ Postgres คือผู้มีอำนาจ และราคาอยู่ห่างแค่คอลัมน์เดียวใน query ที่รันอยู่แล้ว · ปฏิเสธ (`409 RETURN_PRICE_MISMATCH`) ไม่ใช่แก้ให้เงียบ ๆ เพราะการแก้เงียบแปลว่าหน้าจอกับใบลดหนี้ไม่ตรงกัน
- **ของที่ soft-delete แล้ว: คืนสต็อกให้** — เลือกให้เหมือน void ที่ทำอยู่แล้ว เพราะของมันกลับมาอยู่บนชั้นจริง ๆ · ที่ยอมไม่ได้คือสองทางทำคนละอย่าง และทาง return ไม่เขียน `movements` เลยแปลว่าบัญชีไม่มีร่องรอยว่าของกลับมา
- **ไม่รวมโค้ดที่ Standards agent ชี้ว่าซ้ำ** (`applyLedgerDelta` ร่วมกันของ sale/void และ dto helper) — เป็น fix round และการแตะ sale path ที่ merge ไปแล้วเสี่ยงกว่าประโยชน์ · บันทึกไว้เป็นของที่รู้แล้ว

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- `corepack enable pnpm` ตาย `EPERM` เพราะเขียน `C:\Program Files\nodejs\` ไม่ได้ → เรียก `node "…/corepack/v1/pnpm/10.34.5/bin/pnpm.cjs"` ตรง ๆ
- **ดัน `DB_POOL_SIZE` เพื่อให้เคส `200 concurrent bills` เขียวบนเครื่องนี้ไม่สำเร็จ** — บิลที่สำเร็จเท่ากับขนาด pool เป๊ะ ๆ ทุกครั้ง (8→8, 20→20, 50→50) ที่เหลือตาย `timeout exceeded when trying to connect` · จะเขียวต้อง pool ≥ 200 ซึ่งเกิน `max_connections=100` → **ยอมรับว่าเป็นข้อจำกัดของเครื่อง ไม่ใช่ของโค้ด** (นี่คืออาการของ transaction ที่กว้างเท่า request ที่ ADR-0003 amendment จะแก้)
- `gh pr create` ใช้ `--body` ยาว ๆ บน PowerShell ไม่รอด → เขียนลงไฟล์แล้ว `--body-file`

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

- **ยืนยันแล้ว:** ตัวเลขทุกเคสตรง seed ของ Dart (customer 450/4500 → 442/4415 · mechanic 500/1000/200 → markup 150, balance 200) · blocker เรื่องราคายืนยันด้วยการอ่านโค้ดเองว่า `soldByProduct` ไม่เคย select `price` · เคส 2 ตัวที่แดงเป็นของเดิมจริง (agent `git stash` ทั้ง branch แล้วรันบน tree เปล่า แดงเหมือนกัน)
- **ยังไม่ได้วัด:** deadlock จริงระหว่าง return กับ sale ที่ช่างคนเดียวกัน — เหตุผลมาจากลำดับล็อก ไม่ได้มาจากการวัด · เขียนเทสต์ concurrency ใหม่บนเครื่องนี้อ่านผลไม่ได้เพราะ noise จาก pool
- **สมมติฐาน:** เคส `200 concurrent bills` และ `ten simultaneous opens` ยังเขียวใน CI (เชื่อจากที่ `main` เขียวอยู่ ไม่ได้รันเอง — ดูผล CI ของ PR #78 เป็นหลักฐาน)
- `Worker exited unexpectedly` โผล่ 1 ครั้งจากการรัน e2e 5 รอบ ไม่มีเทสต์ไหนแดงติดมา อาการเดียวกับ pool starvation ไม่ได้ตามต่อ

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **#28 `p6.3` shifts + ลิ้นชัก** (`team/1`, ปลดล็อกแล้ว) — `returns.shift_id` เขียนแล้ว เหลือฝั่ง shift · ตามลำดับล็อกใหม่
2. **#30 `p7.2`** รอ #29 ของ team/2
3. เตือน `LomerAlloys` เรื่อง **#17** (ค้าง #24) และ **#29** · เตือน `PattaraponKitcharoen` เรื่อง **#54** (ค้าง #56)
4. ยังค้างจากรอบก่อน ๆ: ticket "e2e ทน 2 runner ไม่ได้" · ลำดับ `tx.0`–`tx.5` · ticket follow-up ช่อง "ลดให้ช่าง" จาก #11
5. ของที่รู้แล้วแต่จงใจไม่ทำรอบนี้: รวม `applyLedgerDelta` ของ sale/void · แยก dto helper ร่วมกัน

## 7. ข้อควรระวัง

- 🔴 **e2e suite ยังห้ามรัน 2 runner บน DB เดียว** — รอบนี้ orchestrator ถือคิวเอง agent ตรวจทั้ง 3 ตัวถูกสั่งห้ามรัน e2e
- 🔴 **ก่อนรัน e2e บนเครื่องใหม่ ให้เช็ค `select name from migrations`** ว่าครบ ไม่งั้นจะไล่บั๊กที่ไม่มีอยู่จริง
- 🔴 **`GREATEST(0, …)` กลบความเสียหายได้** — clamp ป้องกันยอดติดลบ แต่ถ้า input ไม่ถูกตรวจ มันจะเปลี่ยน "ยอดพัง" เป็น "ยอดเป็น 0 เงียบ ๆ" ซึ่งหาเจอยากกว่า · ตรวจ input ก่อน แล้วค่อย clamp
- `total_discount = GREATEST(0, $4::numeric)` ต้องมี cast เพราะเป็นการ **assign** ไม่มีคอลัมน์ให้ Postgres เดาชนิด (อีกสามตัวเป็น `column - $n` จึงไม่ต้อง)
- `01_DATABASE.md` เป็น CRLF (รอบนี้รักษาไว้ครบ 1123 บรรทัด)
- ห้าม `pnpm format` ทั้ง tree
- `resetTenant` ใช้ uuid เต็มเป็น `tenants.code` แล้ว — suite ใหม่ที่ขึ้นต้น 8 ตัวแรกซ้ำกับของเดิมจะไม่ตายอีก

## 8. อ้างอิง

- PR: https://github.com/NuimanLP/srisurart-pos-flutter/pull/78 · commits `26cfd07` (#22) · `6c322a1` (#23) · `1dbd73e` (fix round)
- Issues: #22 #23 (ปิดผ่าน PR) · #28 (ปลดล็อก) · #11 (มติ `total_credit`)
- `server/src/returns/` (`returns.service.ts` `soldLines`/`assertRefundable`/`aggregate`/`reverseMechanic`) · `server/src/sales/void.service.ts` (`lockMechanic`/`reverseLedger`) · `server/src/db/migrations/1788652800004-ReturnItemsCostAtSale.ts` · `server/test/returns.e2e-spec.ts` · `server/test/support/fixture.ts` (`tenants.code` ใช้ uuid เต็ม)
- docs ที่แก้: `server/README.md` (บล็อก 🔴 void + ledger, `ยกเลิกบิล` ที่ไม่มีจริง, คำว่า "verbatim port") · `01_DATABASE.md` §5.4 · `02_API_SCREENS.md` §3.7 + §8 + §8.1 (error code ใหม่ 2 ตัว)
- อ้างอิงพฤติกรรม: `frontend/lib/data/repositories/returns_repository.dart` · `frontend/test/returns_repository_test.dart` · `frontend/lib/presentation/screens/returns_screen.dart:902-904`
- คนที่ต้องถาม: **เจ้าของร้าน** (ข้อความไทยของ `RETURN_PRICE_MISMATCH` และ `REFUND_METHOD_NOT_ALLOWED` ถ้าอยากให้ขึ้นหน้าจอเป็นไทย ตอนนี้ server ตอบอังกฤษและ client เป็นเจ้าของ dialog)
