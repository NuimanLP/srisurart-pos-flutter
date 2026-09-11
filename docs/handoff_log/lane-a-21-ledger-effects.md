# Handoff — #11 ตัดสิน `total_credit` → #21 ledger effects (customer/mechanic/credit override) + sync board กับ commit (2026-09-11)

**วันที่:** 2026-09-11 · **ผู้บันทึก:** เจ้าของโปรเจกต์ (NuiGates) สั่งงาน · Claude Fable 5.1 เป็น orchestrator ส่ง agent 3 ตัว (implement ×1, Standards ×1, Spec ×1) · scrutinize ทำเองใน session หลัก · **สถานะ:** ปิดแล้ว (PR #76 merge)
**ขอบเขต:** (1) ทำให้ GitHub issues + Project board "Mobile Srisurat-POS" ตรงกับสิ่งที่ merge ไปแล้วจริง (2) ตอบ decision #11 (3) ทำ #21 `p5.4` จนถึง PR ผ่าน 3 รอบตรวจ + CI เขียว
**ต่อจาก:** [`branch-cleanup-merge-73-74-75.md`](branch-cleanup-merge-73-74-75.md) (ก้าวถัดไปข้อ 2 ของรอบนั้นคือ #11 → #21)

## 1. ตอนนี้อยู่ตรงไหน

- **#11 ตัดสินแล้ว (parity):** `mechanics.total_credit` **server ไม่เขียน** — มันคือชื่อเก่าของ `total_discount` จาก JS ไม่ใช่ "ยอดขายเครดิตสะสม" (หลักฐานอยู่ใน comment บน #11) · `01_DATABASE.md §7.1` ตัด `total_credit += total` แล้ว · #11 ปิดพร้อม PR #76
- **#21 merge เข้า `main` แล้ว (PR #76)** — ledger effects ของ `POST /sales` ครบ: customer points/spend · mechanic total_sales/discount/markup/credit_balance · `409 CREDIT_LIMIT_EXCEEDED` + `overrideCreditLimit` + audit row · response มี `customerAfter` / `mechanicCreditBalanceAfter`
- 🔴 **lock order ใหม่: mechanic → products → `doc_counters`** — #22 (returns) และ #23 (void reverse ledger) ต้องตามลำดับนี้ ไม่งั้น deadlock กับบิลขาย
- 🔴 **สัญญาใหม่ที่ `tx.3` ต้องรักษา:** client ส่งบิลเดิม + `Idempotency-Key` เดิม + `overrideCreditLimit: true` หลังโดน 409 ต้องได้ 201 — ใช้ได้เพราะ idempotency claim rollback ไปพร้อม transaction ที่ถูกปฏิเสธ · มี e2e pin ไว้ (`sales-ledger.e2e-spec.ts` "the counter path")
- #23 #28 ยังเปิด (In progress บน board) — #23 รอแค่ต่อยอดจาก #21 แล้ว, #28 รอ #22
- ของ `team/1` ที่เหลือ: **#22** (ปลดล็อกแล้ว) → ปิด #23 #28 → #30 (รอ #29 ของ team/2) → #56 (รอ #54 #24) · #24 รอ #17 ของ team/2

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

0. **sync board/issues กับ commit จริง** — #15 `p2` และ #38 `ci.1` assign ผิดคน (ทำจริงโดย `NuimanLP` ใน PR #42) → ย้าย assignee + label `team/1`, แก้ตาราง "Who does what" ใน #2 · ติ๊ก `[x]` ให้ child ที่ปิดแล้วใน #2 #3 #7 #10 #52 · #10 เพิ่ม #61–#67 ที่ไม่เคยอยู่ใน list · ปิด #3 (child ครบ) · board: closed ทุกตัวเป็น Done อยู่แล้ว (workflow), ย้าย #23 #28 → In progress, PR ที่ merge แล้ว 13 ใบไม่มี assignee → assign ตาม author (`gh pr edit` ตายเพราะ classic-Projects deprecation → ใช้ REST `POST /issues/:n/assignees`)
1. **#11** — อ่านโค้ดแล้วพบ `mechanics_screen.dart:686` แสดง `totalCredit` ใต้ป้าย **"ลดให้ช่าง"** และไม่มีที่ไหนแสดง `totalDiscount` เลย ขณะที่ `saveSale` เขียนแต่ `totalDiscount` → field ถูก rename ใน JS แล้ว fallback `(totalDiscount || totalCredit)` ใน returns คือของเก่า → ร่างคำตอบ เจ้าของโปรเจกต์อนุมัติ โพสต์ลง #11 + ติ๊ก AC 2 ข้อ
2. **#21** — agent implement บน `feat/p5.4-ledger-effects` (`fc1c8f1`): `lockMechanicAndCheckLimit` ก่อน `lockProducts` · `applyCustomer`/`applyMechanic` เป็น `UPDATE … GREATEST(0, …) RETURNING` · audit `sale.credit_limit_override` บน request manager · DTO `booleanOrFalse` · e2e ใหม่ 10 เคส (ตัวเลขตรง Dart test) + `seedCustomer`/`seedMechanic` ใน fixture · docs 3 ไฟล์ (`01_DATABASE.md` CRLF คงไว้ ตรวจแล้ว)
3. **scrutinize (ใน session หลัก)** — trace ครบ ยืนยัน: ledger อยู่หลัง movements ใน tx เดียว, `total_credit` ไม่อยู่ใน UPDATE ไหนเลย, replay ไม่ lock, audit rollback ไปกับบิล · เจอ 2 อย่างแก้ใน `1a8ffa4`: (ก) ไม่มีอะไร pin ว่า resend key เดิมพร้อม flag ผ่าน — เพิ่ม e2e (ข) README lock order ไม่ได้พูดถึง void ของ #23
4. **code-review 2 แกนขนาน** — Spec: AC ครบ 6 ข้อ, nit 3 (fixture m2 limit 5000 ≠ Dart seed 3000, comment อ้างว่า Dart มี clamp ทั้งที่ไม่มี, หัวข้อ §8.2 "ไม่ใช่ error" ขัดกับ code ใหม่) · Standards: ย้าย `satangOf` ไป `money.ts`, rename 2 ฟังก์ชัน · แก้หมดใน `9769061`
5. **ตรวจ:** lint · typecheck · unit 85 · e2e 11 ไฟล์ 120 passed + 1 todo บน compose จริง (รัน 3 รอบ) · CI บน PR #76: lint+typecheck · unit · integration · audit เขียวหมด

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

- **#11 = parity** ไม่ใช่เพราะ "โค้ดชนะเอกสาร" แต่เพราะหลักฐานบนหน้าจอ (ป้าย "ลดให้ช่าง") ชี้ว่าเอกสารตีความ field ผิดตั้งแต่ต้น · ไม่ backfill เพราะไม่มีอะไรจะ backfill · คอลัมน์คงไว้ (read-only legacy) เพราะ tenant import และ returns fallback ยังอ่าน
- **เกินวงเงินโดยไม่มี flag = `409 CREDIT_LIMIT_EXCEEDED` ข้อความอังกฤษ** — AC ของ #21 บอกชัด "without the flag it is refused" ส่วน §8.2 บอก "ไม่ใช่ error" หมายถึงไม่ปฏิเสธการขาย ไม่ใช่ห้ามตอบ 409 · ไม่แต่งไทยเพราะ CLAUDE.md ห้าม และ dialog ไทยของเดิมอยู่ฝั่ง client อยู่แล้ว · เพิ่ม clarifier ใต้หัวข้อ §8.2 ให้หายขัดกัน
- **เงื่อนไข `newBalance > creditLimit` ไม่มีกรณีพิเศษ limit = 0** — ลอกจาก `checkout_screen.dart:561` ตรง ๆ (ช่างที่ limit 0 จะโดน dialog/409 ทุกบิลเครดิต เหมือนแอปเดิม)
- **lock mechanic ก่อน products สำหรับ "ทุกบิลที่มีช่าง" ไม่ใช่แค่บิลเครดิต** — agent เบี่ยงจาก brief ด้วยเหตุผลถูก: บิลเงินสด (products → UPDATE mechanic) ชนกับบิลเครดิต (mechanic → products) ที่ช่างเดียวกัน + สินค้าร่วมกัน = deadlock · ต้นทุนคือบิลของช่างเดียวกัน serialize กัน ซึ่ง UPDATE ก็ทำอยู่แล้ว
- **คง `GREATEST(0, …)` ทั้งที่ Standards agent ให้ถอด** — #21 สั่งไว้ตรงตัว ("the `>= 0` CHECK constraints are assertions that our clamping is present") → spec ชนะ parity argument · แก้แค่ comment ที่อ้างผิด
- **audit เฉพาะเมื่อเกินวงเงินจริง** — flag บนบิลที่ไม่เกินไม่มีอะไรให้บันทึก (§8.2 "บันทึกว่า override ตอนไหน")
- **ไม่แตะ `void.service.ts`** — reverse ledger ตอน void เป็น AC ของ #23 · note "#21" ในไฟล์นั้นคงไว้ให้คนทำ #23 เห็น
- **ไม่ de-dup helper e2e (`bill`/`post`/`stockOf`) ข้าม 3 suite** — pattern เดิมของ repo ไม่ใช่ของ PR นี้

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- `gh pr edit N --add-assignee` บน repo นี้ตาย: `Projects (classic) is being deprecated … (repository.pullRequest.projectCards)` → ใช้ `gh api -X POST repos/…/issues/N/assignees`
- `gh project …` ต้อง scope `project` — token เดิมมีแค่ `repo workflow read:org gist` → เจ้าของโปรเจกต์รัน `gh auth refresh -s project` แล้วถึงอ่าน/แก้ board ได้ (ก่อนหน้านั้นแก้ผ่าน browser)
- `docker compose … up` ด้วย `.env` เดิมของเครื่องตาย `JWT_PUBLIC_KEYS is required` → ใช้ `--env-file .env.example` (ไม่ทับ `.env` ของเครื่อง)
- `corepack pnpm format` reformat ~40 ไฟล์ที่ repo ไม่เคย prettier — agent revert หมดก่อน commit · **repo นี้ไม่ได้ format ก่อน commit** อย่ารัน `format` ทั้ง tree

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

- **ยืนยันแล้ว:** ตัวเลขทุกเคส customer/mechanic ตรง Dart test (450/4500 → 462/4620 บน 120 · m1 350/−50 → balance 350 discount 50 · m2 350/+30 → markup 30) · resend key เดิม + flag = 201 (e2e จริง) · `01_DATABASE.md` ยัง CRLF (`file` + diff 2 บรรทัด)
- **สมมติฐาน (ยังไม่ถามร้าน):** ช่อง "ลดให้ช่าง" บนหน้าจอช่างที่อ่าน `totalCredit` เป็น 0 ตลอดสำหรับช่างที่สร้างใน Flutter น่าจะเป็น bug ที่ port มาจาก JS (ควรอ่าน `totalDiscount != 0 ? totalDiscount : totalCredit`) — บันทึกไว้ใน #11 เป็น follow-up ยังไม่มี ticket
- **ไม่ได้วัด:** ผลของการ lock mechanic ทุกบิลต่อ throughput ตอน k6 (#37) — คาดว่าไม่มีนัยเพราะบิลเดียวกันไม่ได้ชนช่างเดียวกันใน scenario ของ §9

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **#22 `POST /returns`** (`team/1`, ปลดล็อกแล้ว) — lock order mechanic → products, `cost_at_sale` จาก line เดิม, ฐานส่วนลดใช้ `CASE WHEN total_discount <> 0 THEN total_discount ELSE total_credit END`, `shift_id` บน return → ปิด AC ของ #28
2. **#23 ต่อยอด** — void reverse ledger (customer/mechanic) ตามลำดับ lock ใหม่ · ถ้าบิลนั้นเคย override วงเงิน ไม่ต้อง audit ซ้ำ (audit ของ void มีอยู่แล้ว)
3. เปิด ticket follow-up จาก #11: หน้าจอช่อง "ลดให้ช่าง" (Drift build, frontend)
4. เตือน `LomerAlloys` เริ่ม #17 — #24 และ #56 ของ team/1 รออยู่
5. ยังค้างจากรอบก่อน: ticket e2e-ทน-2-runner-ไม่ได้ · ลำดับ `tx.0`–`tx.5` (ถ้าทำ `tx.3` ต้องผ่าน e2e "the counter path")

## 7. ข้อควรระวัง

- **ห้าม `pnpm format` ทั้ง tree** (ดูข้อ 4) — format เฉพาะไฟล์ที่แตะ หรือไม่ format เลย
- **`01_DATABASE.md` เป็น CRLF** — Python ต้อง `newline=''` (รอบนี้ agent ทำถูก)
- `overrideCreditLimit` รับเฉพาะ boolean แท้ — `"false"` เป็น 400 ไม่ใช่ false
- `dto.mechanicId` ที่ไม่มีแถว: `lockMechanicAndCheckLimit` ปล่อยผ่านให้ FK ของ `insertSale` ตอบ 400 เหมือนเดิม — อย่าเพิ่ม 404 ซ้ำ
- e2e suite ทั้งชุดยังห้ามรัน 2 runner บน DB เดียว

## 8. อ้างอิง

- PR: https://github.com/NuimanLP/srisurart-pos-flutter/pull/76 · commits `fc1c8f1` (feat) · `1a8ffa4` (scrutinize fixes) · `9769061` (review fixes)
- Issues: #21 (ปิดผ่าน PR) · #11 (คำตอบ = comment 2026-09-11) · #23 #28 (In progress) · #22 (ถัดไป)
- `server/src/sales/sales.service.ts` (`lockMechanicAndCheckLimit`, `applyCustomer`, `applyMechanic`) · `server/src/sales/sales.dto.ts` (`booleanOrFalse`) · `server/src/common/money.ts` (`satangOf`) · `server/test/sales-ledger.e2e-spec.ts` · `server/test/support/fixture.ts` (`seedCustomer`, `seedMechanic`)
- docs: `02_API_SCREENS.md` §3.1 / §8 / §8.1 / §8.2 · `01_DATABASE.md` §7.1 + DDL comment · `server/README.md` lock order + ลำดับ 10 ขั้น
- อ้างอิงพฤติกรรม: `frontend/lib/data/repositories/sales_repository.dart:70-108` · `frontend/lib/presentation/screens/checkout_screen.dart:561-567` · `frontend/lib/presentation/screens/mechanics_screen.dart:686`
- คนที่ต้องถาม: **เจ้าของร้าน** (ช่อง "ลดให้ช่าง" เคยขยับไหม · Thai string ของ `CREDIT_LIMIT_EXCEEDED` ถ้าอยากให้ server ตอบไทย)
