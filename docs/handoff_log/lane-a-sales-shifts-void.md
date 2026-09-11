# Handoff — Lane A: #19 เลขเอกสาร · #20 POST /sales · #23 อ่านบิล+void · #28 ลิ้นชัก (2026-09-10)

**วันที่:** 2026-09-10 · **ผู้บันทึก:** NuimanLP (team/1, Lane A ทั้งเลน) · **สถานะ:** รอ merge (PR #75 เขียวครบ)
**ขอบเขต:** ticket ที่ปลดล็อกได้ทั้งหมดของ `team/1` ในรอบเดียว + seam ที่ #4 ทิ้งไว้
**ต่อจาก:** [`lane-a-ci3-idempotency.md`](lane-a-ci3-idempotency.md) (#18) · [`ticket-4-6-43-auth-jwt-roles.md`](ticket-4-6-43-auth-jwt-roles.md) (#4/#6/#43)

---

## 1. ตอนนี้อยู่ตรงไหน

- **PR #75** (`feat/laneA-sales` → `main`) 7 commit · CI เขียวทุก job (lint+typecheck / unit 73 / integration 96 e2e / audit)
- **`Closes #19` `Closes #20` เท่านั้น** — #23 กับ #28 **จงใจไม่ปิด** (เหตุผลใน §3)
- โน้ตส่งต่อคอมเมนต์ไว้ที่ **#21** และ **#30** แล้ว
- หลัง merge lane `team/1` **หมดของที่หยิบได้จริง** — ที่เหลือติด #11 (คนตอบ) หรือติด #16/#17 ของ `team/2`

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

รายละเอียดสเปคอยู่ใน PR #75 + `server/README.md` แล้ว ที่จดตรงนี้คือของที่ไม่มีในนั้น

- **seam ต้องสร้างก่อน ไม่งั้นเริ่ม #19 ไม่ได้เลย** — #4 merge ไปแล้วแต่ `TenantGuard` **ไม่เคยทำ `SET LOCAL app.tenant_id`** และไม่มีอะไรใน `src/` เรียก `runInRequestContext` → `currentRequestContext()` ที่ `IdempotencyInterceptor` (#18) ใช้ throw ทุกครั้ง เขียน endpoint อะไรไม่ได้สักเส้น
- `TenantService.runTx` ที่ #4 ทิ้งไว้ **ไม่มีใครเรียกเลย** — ยังอยู่ใน `db.module.ts` เป็น dead provider (ไม่ได้ลบ ไม่ใช่ของเลนนี้)
- **200 บิลพร้อมกันบนสินค้า 50 ชิ้น → 50 บิลเป๊ะ สต็อก 0 เลขใบเสร็จไม่ซ้ำ 50 เลข** (done-criterion 3 ของ #2 ผ่านจริง)

**ตรวจสอบด้วยอะไร:** unit 73 · e2e 96 ยิง compose Postgres+Redis จริงไม่มี mock · รัน e2e ครบชุดซ้ำ **12 รอบติด** ก่อน push (เพราะเคยพังแบบสุ่ม §4) · CI integration 47s เขียว

### บั๊กที่เจอระหว่างทาง (ไม่ใช่ของเลนนี้ แต่แก้ไปแล้ว)

🔴 **`AuthService.logAuthEventWithRls` ใช้ `SET LOCAL app.tenant_id = $1`** — `SET LOCAL` **รับ bind parameter ไม่ได้** เป็น syntax error ที่ถูก `catch` แล้ว log ทิ้ง แปลว่า **auth audit log ไม่เคยเขียนสำเร็จเลยตั้งแต่ #4 merge** (`SELECT count(*) FROM audit_log WHERE action LIKE 'auth.%'` = **0**) ขัด ADR-0009 ตรง ๆ · แก้เป็น `set_config('app.tenant_id', $1, true)` + มี test แล้ว

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

| เรื่อง | ทางเลือก | เลือก | เหตุผล |
|---|---|---|---|
| **บิล `id` ซ้ำ** (client ยิงซ้ำหลัง reload, Idempotency-Key ใหม่) | 500 (ของเดิม) / 409 / replay บิลเดิม | **replay** | §3.1 บอกว่า client `id` คือ natural idempotency key · ที่สำคัญกว่า: **409 อันตรายกว่า 500** เพราะพนักงานอ่านว่า "ไม่ผ่าน" แล้วตีบิลใหม่ = ขายซ้ำจริง · ถ้า `id` เดิมแต่ยอดต่าง → `409 SALE_ID_REUSED` (คนละบิลใส่ id ชนกัน เงียบไว้ = เงินบิลใหม่หาย) |
| **บิลมีสินค้าตัวเดียวกัน 2 บรรทัด** | ตาม Dart (เช็คทีละบรรทัดกับ stock เต็ม) | **รวม qty ก่อนเช็ค** | Dart เช็คทีละบรรทัด → 3+3 บนสต็อก 5 ผ่าน แล้วไป underflow ตอนตัด = 500 · รวมก่อนได้ข้อความไทยปกติแทน และ UI จริงรวมบรรทัดอยู่แล้ว จึงไม่เปลี่ยนพฤติกรรมที่ใช้จริง |
| **ข้อความไทยของ error ใหม่ 3 ตัว** | แต่งเอง / อังกฤษไปก่อน | **อังกฤษ + ลง §8.1 รอเจ้าของร้าน** | `CLAUDE.md` ห้ามคิดข้อความไทยใหม่ · §8.1 มี precedent ว่าต้องผ่านคนหน้าร้าน |
| **`movements.note` ตอน void** | `'ยกเลิกบิล'` / NULL | **NULL** | รอบแรกผมแต่งไทยเอง reviewer จับได้ — คำนี้มีในแอปแค่เป็น label ของ status pill ไม่ใช่ note ของ movement และ `db.js` ไม่เคยเขียน movements ตอนขาย/คืนเลย จึงไม่มีต้นฉบับให้ลอก |
| **void ชน `uq_movements_ref`** | เพิ่ม `'void'` ใน CHECK (ต้อง migration) / prefix ref_id | **`ref_id = 'void:' + saleId`** | migration เป็นของเลน schema · ถ้าไม่กัน #22 ที่ใช้ `sale_id` เป็น ref จะชนเป็น 500 |
| **`owner` void ได้ไหม** | ตาม §4.2 เป๊ะ (`manager`) / รวม `owner` | **รวม `owner`** + จดลง §4.2 | `users.role` เป็น flat list ไม่ได้บอกลำดับ เจ้าของร้านไม่ควรต่ำกว่า manager — แต่เป็นการ**ตีความ** จึงเขียนลงเอกสารไม่ปล่อยให้ implicit |
| **ปิด #23 / #28 ไหม** | ปิดตาม PR / ปล่อยค้าง | **ปล่อยค้าง** | #23 AC "void reverses ledger effects" ตอนนี้จริงแบบ **vacuous** (ยังไม่มีอะไรเขียน ledger) · #28 AC "ทุก sale **และ return** มี shift_id" — return คือ #22 ยังไม่มี · ปิดไปเท่ากับบอกว่าทำครบ ทั้งที่ไม่ |
| **ไม่แตะ ledger effect เลย** | ทำเลย / รอ #21 | **รอ** | #21 ติด **#11** ซึ่งเอกสารกับ Dart ขัดกัน — ทำไปเท่ากับตัดสิน #11 แทนเจ้าของโปรเจกต์ |

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- **keep-alive `http.Agent` ร่วมกันเพื่อกัน ECONNRESET ตอนยิง 200 request** → **แย่ลง** เจ๊ง 132/200 (`ECONNRESET`/`ECONNREFUSED`) เพราะ `request(app.getHttpServer())` ของ supertest **เปิด-ปิด server ใหม่ทุก request** socket ที่ keep-alive ไว้จึงชี้ไปที่ server ที่ปิดไปแล้ว · แถม process ค้างไม่จบเพราะ socket ไม่ถูกปล่อย
  → **ทางที่ใช้จริง:** `await app.listen(0)` ครั้งเดียวใน fixture (เลิกวนเปิด-ปิด 200 รอบ) + `Promise.allSettled` และ **ไม่ใช้ agent**
- **เช็ค `subtotal - discount == total` ใน DTO เป็น 400** → ไปชน `TOTAL_MISMATCH` (409) ของ §1.3 ที่มีข้อความไทยของตัวเอง · ย้ายไปรวมใน `assertTotals` เป็น 409 แทน · **DTO เก็บไว้แค่ค่าที่ผิดรูปหน้าตา** (ติดลบ/เกินขนาด)
- **ลด `DB_POOL_SIZE` ใน test จาก 20 → 8 เพื่อกัน worker ตาย** → ไม่ใช่สาเหตุ ยังตายอยู่ (สาเหตุจริงคือ `SET LOCAL $1` ใน §2)

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

**ยืนยันแล้ว (มี test / รันจริง):**
- ลำดับ interceptor Envelope → Transaction → Idempotency → handler · idempotency record commit พร้อมบิลจริง
- `ORDER BY id … FOR UPDATE` ล็อกตามลำดับ id จริง (reviewer ยืนยันด้วย `EXPLAIN` บน DB จริง — `LockRows` อยู่เหนือ `Sort`)
- `period` ของเลขเอกสารขยับกลาง transaction ไม่ได้ (`now()` = `transaction_timestamp()`)
- 3 write path ที่มีตอนนี้ไม่มี lock cycle

**แค่เดา / ยังไม่ได้ตรวจ:**
- 🔴 **เจ้าของร้านอยากได้ปุ่ม void ไหม ยังไม่รู้** — `02_API_SCREENS.md §2` ระบุว่า endpoint นี้ "ของใหม่ ต้องคุยก่อน" แอปเดิม void เกิดอัตโนมัติตอนคืนครบบิลเท่านั้น **ไม่เคยมีปุ่มนี้** · #23 สั่งให้ทำก็เลยทำ แต่ยังไม่มีใครถามร้าน
- 🔴 **บิลที่ขายตอนลิ้นชักปิดแล้ว ควรมี `shift_id` ไหม** — ตอนนี้เป็น NULL ตามถ้อยคำ #28 แต่รายงานปิดร้านของแอปจริงนับ**ตามวัน** ไม่ใช่ตามกะ (`closing_report.dart:141`) → รายงานที่คิดจาก `shift_id` ล้วนจะขาดยอดหลังปิดกะ **ยังไม่มีใครตัดสิน** (คอมเมนต์ไว้ที่ #30)
- ไม่รู้ว่า `owner` ควร void ได้จริงไหม (ดู §3)
- ไม่ได้ทดสอบกับ client Flutter จริงเลย — ทั้งเลนนี้ทดสอบที่ HTTP seam อย่างเดียว

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **merge PR #75** — เขียวครบ รอ review
2. **ตอบ #11 (`mechanics.total_credit`)** — 🔴 **นี่คือสิ่งเดียวที่ปลดล็อกงานต่อของ `team/1`** · ต้องเป็นเจ้าของโปรเจกต์ตอบ อ่านเอกสารฝั่งเดียวแล้วมั่นใจผิดได้ · ปลด #21 → #22 → #24 → #56
3. **ตัดสิน 2 ข้อใน §5** (ปุ่ม void / shift_id หลังปิดกะ) — ถามร้าน ไม่ใช่ถาม agent
4. **เติม AC ของ #21** ให้ครอบ `customerAfter` + `mechanicCreditBalanceAfter` และการ reverse ledger ใน void (คอมเมนต์ไว้แล้ว รอคนแก้ตัว issue)
5. รอ `team/2` ทำ **#16 / #17** — #24 #27 #29 ติดอยู่ตรงนี้ทั้งหมด
6. รอ `team/3` ทำ **#54** — #55/#56 ฝั่ง client ติดอยู่
7. เอา `.github/workflows/server.yml` ไป pin third-party action เป็น 40-char SHA (security review อัตโนมัติจับได้) — เป็นของ **#44** ไม่ใช่เลนนี้

## 7. ข้อควรระวัง

🔴 **กับดักที่ทำให้พังจริงมาแล้ว — อ่านก่อนเขียน endpoint ใหม่**

1. **ห้ามขอ pooled connection ตัวที่สองใน request** — request ถือไว้ 1 ตัวแล้ว ถ้าไปขออีก พอโหลดสูงทุก request จะถือ 1 รออีก 1 = pool deadlock ทั้งชุด 500 พร้อมกัน · อ่านผ่าน `currentRequestContext().manager` เสมอ (`tenants`/`platform_admins` ไม่มี RLS อ่านได้) · ข้อยกเว้นเดียวคือ audit ตอน void ถูกปฏิเสธ ที่ต้องรอด rollback
2. **async Express middleware ห้าม reject** — Express ไม่ await มัน rejection = unhandled rejection = **Node ฆ่า worker ทิ้ง**
3. **`returning()` (`src/common/sql.ts`) ไม่ใช่ของเลือกใช้** — TypeORM คืน rows ตรง ๆ สำหรับ SELECT/INSERT แต่คืน `[rows, affected]` สำหรับ UPDATE/DELETE → `result[0].stock` ได้ `undefined` แล้วไปโผล่เป็น NULL อีกหลาย statement ถัดไป
4. **ลำดับล็อก: products → `doc_counters` เสมอ** — #26 (PO receive) กับ #22 ถ้าออกเลขเอกสารก่อนแตะ products = lock inversion เจอตอนวันเสาร์ที่ร้านยุ่ง
5. **`shifts.is_active` ≠ "เปิดอยู่"** แปลว่า "ลิ้นชักปัจจุบันของเครื่องนี้" · ปิดกะแล้วยัง true จนกว่าเปิดกะครั้งหน้าจะ archive · `uq_shift_active` พึ่งความหมายนี้ ห้ามเอาไปใช้อย่างอื่น
6. **`resetTenant` ใน e2e ต้องล้าง Redis ด้วย** ไม่ใช่แค่ตาราง — `t:{tid}:status` cache 5 นาที ทำให้ test ร้านถูกระงับผ่านทั้งที่ guard พัง (ของเดิมเขียน `expect([403,201])` ซึ่งเท่ากับไม่ได้ทดสอบอะไรเลย)
7. **`vitest.config.e2e.ts` ตั้ง `fileParallelism: false`** — แต่ละไฟล์ boot ทั้งแอป ถ้าขนานกัน pool รวมทะลุ `max_connections=100` แล้วตายแบบ "worker exited unexpectedly" ซึ่งไม่บอกอะไรเลย
8. **debug e2e ที่ได้ 500:** `TEST_LOG_LEVEL=error pnpm test:e2e`

## 8. อ้างอิง

- **PR #75** https://github.com/NuimanLP/srisurart-pos-flutter/pull/75 — เหตุผลรายสไลซ์อยู่ในนั้น อ่าน commit เรียงตามลำดับ
- `server/README.md` — *The request-context seam* · *Document numbers (#19)* · *The sale transaction (#20)* · *The cash drawer (#28)* · *Sale reads and the void (#23)* · *Conventions these slices set* · *The e2e suite*
- `docs/Backend_design/02_API_SCREENS.md` §1.2 §1.3 §3.1 §3.11 §4.2 §8/§8.1 (แก้ในรอบนี้: error code ใหม่ 3 ตัว, `shiftId` ใน §3.1, `owner` ใน §4.2)
- ADR-0003 (tenant lifecycle) · ADR-0004 (device roles) · ADR-0007 (เลขเอกสาร) · ADR-0008 (cost at sale) · ADR-0010 (write-through cache)
- reference พฤติกรรม: `frontend/lib/data/repositories/sales_repository.dart` · `shifts_repository.dart` · `frontend/test/sales_repository_test.dart` · `frontend/lib/presentation/widgets/closing_report.dart`
- คนที่ต้องถาม: **เจ้าของร้าน** (ปุ่ม void, ข้อความไทย 3 ตัว, shift_id หลังปิดกะ) · **เจ้าของโปรเจกต์** (#11) · `LomerAlloys` (#16/#17) · `PattaraponKitcharoen` (#54, #44)

## Suggested skills (สำหรับ agent ที่มารับต่อ)

- `/scrutinize` — **ใช้ทุกครั้งก่อน push งาน server** รอบนี้ 3 agent เจอ blocker 4 ตัวที่ test เขียวหมดแล้วยังจับไม่ได้ (2 ตัวเจอตรงกันโดยอิสระ)
- `andrej-karpathy-skills:karpathy-guidelines` — กัน over-engineering ตอนพอร์ตจาก Dart
- `/debug-mantra` — ตอนไล่ worker crash / flaky e2e
- `/code-review` — ตอนรีวิว PR ของเพื่อนในเลนอื่น
