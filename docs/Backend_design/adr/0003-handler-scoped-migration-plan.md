# แผนย้ายไป handler-scoped transaction (ตาม addendum ของ ADR-0003)

> เอกสารนี้**ไม่ใช่ ADR** — การตัดสินใจอยู่ใน
> [ADR-0003 หัวข้อ *"ใครตัดสิน กับ ใครลงมือ"*](0003-tenant-lifecycle.md) นี่คือแผนลงมือ
> แบ่งเป็นสไลซ์ที่ merge แยกกันได้ สไลซ์ละ 1 PR **เอกสารนี้ขัดกับ ADR เมื่อไร ยึด ADR**
>
> สถานะ 2026-09-10: **มี prototype ที่รันได้ทั้งระบบแล้ว** (ทำบน worktree แยก ยังไม่ commit)
> — typecheck + lint สะอาด, unit 77 ผ่าน, e2e 105 ผ่าน, full-suite รันซ้ำ 8 รอบติดไม่แดง

---

## 1. ทำไมต้องมีแผน ไม่ใช่ PR เดียว

`feat/laneA-sales` (#75) เป็น PR เขียวที่มีอีก 4 ticket ต่อคิวอยู่ข้างหลัง และความนิ่งของมัน
มาจากการรัน full suite ซ้ำหลายรอบ การเปลี่ยนรูปทรงทรานแซกชันทั้งระบบใน PR เดียว
= ยึดคิวนั้นไว้ทั้งก้อนและรีวิวไม่ไหว

**กุญแจที่ทำให้แบ่งได้จริง:** `TenantService.runTx` ถูกออกแบบให้ **join ทรานแซกชันที่เปิดอยู่แล้ว
แทนที่จะเปิดใบที่สอง** (ดู `currentTransaction()`) ระหว่างทาง `RequestContextMiddleware`
ยังเปิดทรานแซกชันของ request อยู่ตามเดิม service ที่แปลงแล้วจะ **join ใบนั้น** →
**พฤติกรรมไม่เปลี่ยนแม้แต่นิดเดียว และไม่มีการขอ connection ใบที่สอง**
จนกว่าจะถึงสไลซ์สุดท้ายที่ถอด middleware ออก ซึ่งเป็นจังหวะเดียวที่พฤติกรรมเปลี่ยนจริง

ถ้าไม่มี join semantics แผนนี้แบ่งไม่ได้ — ครึ่งทางจะกลายเป็น "หนึ่ง request ถือสอง connection"
ซึ่งคือ pool deadlock ที่ดีไซน์เดิมสร้างขึ้นมาเพื่อกัน

---

## 2. สไลซ์

| # | ชื่อ | แตะอะไร | พฤติกรรมเปลี่ยนไหม | ความเสี่ยง |
|---|---|---|---|---|
| `tx.0` | เอกสาร | `adr/`, `adr/README.md`, `server/README.md` | ไม่ | ต่ำ |
| `tx.1` | seam | `common/request-context.ts`, `common/database/tenant.service.ts`, `common/tenant-door.spec.ts` | **ไม่** | ต่ำ |
| `tx.2` | service เรียก `runTx` | 4 service + 2 controller | **ไม่** (join อยู่) | กลาง — diff ใหญ่สุด |
| `tx.3` | idempotency เป็น explicit | `idempotency/*`, controller ทุกตัวที่เขียนเงิน | ไม่ (ควรจะ) | 🔴 **สูงสุด — ดู §3** |
| `tx.4` | ถอดทรานแซกชันระดับ request | `app.module.ts`, `app.setup.ts`, `tenant.guard.ts`, ลบ 3 ไฟล์ | **ใช่ — จุดพลิก** | กลาง-สูง (availability) |
| `tx.5` | ย้าย argon2 ออกนอกทรานแซกชัน | `sales/void.service.ts` | ใช่ (เร็วขึ้น) | ต่ำ |

---

### `tx.0` — ลงเอกสารก่อนลงโค้ด

**ทำ:** addendum ของ ADR-0003 (เขียนแล้ว) · แถว ADR-0003 ใน `adr/README.md` ให้พูดถึง
addendum แบบเดียวกับที่แถว ADR-0009 พูดถึง addendum 2026-09-09 · หัวข้อ
*"The request-context seam"* ใน `server/README.md` ต้องเขียนใหม่ทั้งหัวข้อ เพราะมันอธิบาย
กลไกที่กำลังจะไม่มีอยู่ · `CLAUDE.md` ย่อหน้าที่ขึ้นต้น *"🔴 ADR-0003 says `TenantGuard` alone
may check tenant status and `SET LOCAL`"* ต้องแก้ตาม

**AC**
1. `adr/README.md` แถว 0003 อ้าง addendum พร้อมวันที่
2. `server/README.md` ไม่มีคำว่า `TENANT_ROUTES`, `OWNED_BY_INTERCEPTOR` หรือ
   `TransactionInterceptor` เหลืออยู่ในฐานะ "กลไกปัจจุบัน" อีก
3. ไม่มีไฟล์ใน `server/src/**` ถูกแตะ

---

### `tx.1` — seam (ไม่เปลี่ยนพฤติกรรม)

**ทำ:**
* `request-context.ts` เพิ่ม `runInTenantScope()`, `runInTransaction()`,
  `authorisedTenantId()`, `currentTransaction()` — และให้ `manager` ใน store เป็น
  `EntityManager | null`
* `tenant.service.ts` เขียน `runTx` ใหม่เป็น **`runTx(fn)`** (ไม่รับ `tid`) + join
  ทรานแซกชันที่เปิดอยู่ · **ลบ `run(tid, fn)` และ `runTx(tid, fn)` ทิ้ง** — วันนี้ไม่มี call site
  สักที่ จึงลบได้ฟรี และเป็นรูปที่ ADR ห้ามไว้ตรง ๆ
* `RequestContextMiddleware` เปลี่ยนไปเรียก `runInTransaction({tenantId: null, manager})`
  หรือคงเดิมก็ได้ ขอแค่ `currentTransaction()` มองเห็น manager ของมัน
* เพิ่ม `common/tenant-door.spec.ts` — allowlist ของไฟล์ที่ฉีด `DataSource` ได้ พร้อมเหตุผล
  รายบรรทัด (ตอนนี้ 12 ไฟล์ ทุกไฟล์มีเหตุผลอยู่แล้ว)

**AC**
1. ไม่มีไฟล์ใน `sales/`, `shifts/`, `documents/` ถูกแตะ
2. unit + e2e ผ่านครบเท่าเดิม โดย **ไม่ต้องแก้ assertion ของ suite ไหนเลย**
3. unit test ใหม่พิสูจน์ว่า `runTx` ซ้อนกัน 2 ชั้นได้ `manager` ตัวเดียวกัน (join ไม่ใช่ nest)
4. unit test ใหม่พิสูจน์ว่า `runTx` โยน error เมื่อ scope ไม่มี tenant
5. `tenant-door.spec.ts` แดงจริงเมื่อลองฉีด `DataSource` เข้า service ที่ไม่อยู่ใน allowlist

---

### `tx.2` — service เปิดทรานแซกชันของตัวเอง (ยังคง join อยู่)

**ทำ:** ห่อ public method ของ `SalesService`, `SaleReadsService`, `VoidService`,
`ShiftsService` ด้วย `this.tenants.runTx(...)` โดยเนื้อในไม่แตะ — ใช้แพตเทิร์น
"public wrapper + private `*In`" เพื่อให้ diff อ่านง่ายและ `git diff -w` เห็นว่าเนื้อโค้ดไม่ขยับ

* `currentRequestContext()` **ยังใช้ได้เหมือนเดิมทุกจุด** เพราะ `runTx` publish
  `{tenantId, manager}` ลง scope ให้ — นี่คือเหตุผลที่ 12 call site ไม่ต้องแก้มือทีละอัน
* `ShiftsService.closeForRetirement` เรียก `close()` ต่อ → กลายเป็น `runTx` ซ้อน `runTx`
  ซึ่ง **join** ตาม `tx.1` · `VoidService` จบด้วย `SaleReadsService.byId()` เช่นกัน
  🔴 สองจุดนี้คือจุดที่ join semantics ถูกใช้จริง ถ้า `tx.1` ทำผิด สองจุดนี้จะขอ connection
  ใบที่สองขณะยังถือใบแรก — ต้องมีเคสยืนยัน

**AC**
1. e2e ทั้งชุดผ่านโดยไม่แก้ assertion
2. เคสใหม่: ระหว่าง `POST /sales/{id}/void` หนึ่งใบ `pg_stat_activity` ของ `pos_app`
   **ต้องไม่เกิน 1 connection ที่มี `xact_start`** — พิสูจน์ว่าไม่มีใบที่สอง
3. `git diff -w` ของแต่ละ service แสดงว่ามีแต่ signature/wrapper ที่เปลี่ยน

---

### `tx.3` — idempotency เป็น explicit 🔴 **สไลซ์ที่แบกความเสี่ยง**

**ทำ:** เพิ่ม `idempotency/idempotency.runner.ts` (`idempotencyParamsOf`, `runIdempotent`) ·
ย้าย claim/complete เข้าไปอยู่ใน `runTx` ของแต่ละ write path · ลบ `IdempotencyInterceptor` ·
controller รับ `@Res({passthrough: true})` เพื่อ set status ตอน replay

**ทำไมสไลซ์นี้เสี่ยงที่สุด:** อีก 5 สไลซ์ถ้าพลาดจะพังแบบ**ดัง** — 500, connection leak,
test แดง สไลซ์นี้ถ้าพลาดจะพังแบบ**เงียบและเป็นเงิน**: record ที่ commit คนละทรานแซกชันกับงาน
แปลว่า **บิลถูกตัดเงินสองรอบ** โดยที่ทุกอย่างตอบ 200 และไม่มี log ผิดปกติ
ความถูกต้องของมันมองจาก diff ไม่เห็น ต้องดูจาก e2e ที่ยิงของจริงพร้อมกันเท่านั้น

**สิ่งที่ *ห้าม* เปลี่ยนในสไลซ์นี้:** ตัว SQL ของ `claim`/`complete`, `SET LOCAL lock_timeout`,
ลำดับ `INSERT … ON CONFLICT DO NOTHING` → งาน → `UPDATE … status='done'`
กลไก concurrency ต้องเป็นตัวเดิมทุกบรรทัด ที่ย้ายคือ *ใครถือทรานแซกชัน* เท่านั้น

**AC**
1. `test/idempotency.e2e-spec.ts` ผ่านครบ 10 เคส โดย **assertion ทุกข้อเหมือนเดิม** —
   แก้ได้เฉพาะส่วนที่ประกอบ controller ตัวอย่างขึ้นมา ห้ามแก้ `expect(...)`
2. เคส *"three genuinely concurrent requests with one key"* ยังยิงพร้อมกันจริง
   (handler ถือ row lock 400ms) และได้ **1 effect + 3 response เท่ากัน**
3. เคส *"a record committed by a process that never answered"* ยัง replay ไม่ใช่ re-run
4. เคส *"a failed request keeps no key"* — claim ต้อง rollback ไปพร้อมงาน
5. `POST /shifts/current/entries` (201) และ `POST /shifts/open|close` (200) ยังตอบ status เดิม
6. 🔴 เคสใหม่: ยิง `POST /sales` ด้วย key เดิม 5 ครั้ง **แล้วเช็คที่ตาราง** ว่ามี `sales` 1 แถว,
   `movements` 1 แถวต่อสินค้า และ `products.stock` ถูกหักครั้งเดียว — ไม่ใช่แค่ดู response
7. รัน full suite ซ้ำ **อย่างน้อย 5 รอบติด** ก่อนขอ review

**ข้อที่ถอยหลังนิดหนึ่ง — ต้องเขียนไว้ใน PR:** ของเดิม interceptor เก็บ status ที่
*ตอบไปจริง* แล้ว replay ค่านั้น ของใหม่ controller เป็นคนบอก `successCode` ต่อ route
ผลต่างเห็นได้เฉพาะกรณี **deploy ที่เปลี่ยน `@HttpCode` ของ route คั่นระหว่าง request แรกกับ retry**
ซึ่งของเดิมทำได้ถูกกว่า ยอมรับข้อนี้อย่างเปิดเผย ไม่ต้องแกล้งว่าเท่ากัน

---

### `tx.4` — จุดพลิก: ถอดทรานแซกชันระดับ request

**ทำ:** `TenantGuard` เปลี่ยน status probe ไปใช้ `ds.query` (`tenants` ไม่มี RLS) และ
**เลิกทำ `set_config`** เหลือแค่ `setRequestTenant()` · เพิ่ม `TenantScopeMiddleware`
(global, `forRoutes('*')`, ไม่แตะ DB) · **ลบ** `RequestContextMiddleware`,
`TransactionInterceptor`, `OWNED_BY_INTERCEPTOR`, `TENANT_ROUTES` และ
`app.useGlobalInterceptors` เหลือแค่ `EnvelopeInterceptor`

**AC**
1. `test/request-context.e2e-spec.ts` ผ่านทั้งไฟล์ (เปลี่ยนได้เฉพาะคอมเมนต์ที่อธิบาย
   กลไกเก่า) — โดยเฉพาะ 3 เคสนี้ ซึ่งเป็นเคสที่ทั้ง seam ยืนอยู่บนมัน:
   * `GET /auth/me` ยังตอบ 200
   * 36 request รวมทางที่ guard throw **ไม่ทิ้ง connection ค้าง**
   * ร้าน `suspended` ได้ 403 `TENANT_SUSPENDED`
   * บิลที่ตาย FK ยัง rollback ทั้งสต็อก เลขใบเสร็จ และ idempotency key
2. 🔴 **วัดซ้ำแล้วต้องได้ผลนี้** (4 void พร้อมกัน, `DB_POOL_SIZE=2`, Postgres จริง):
   ทรานแซกชันยาวสุดที่ `pg_stat_activity` เห็น **ลดจาก ~112 ms เหลือ ≲ 30 ms**
   ตัวเลข before/after ต้องแปะใน PR ไม่ใช่แค่บอกว่า "เร็วขึ้น"
3. เพิ่ม controller ใหม่ที่มี `TenantGuard` **โดยไม่แตะไฟล์ config ใด ๆ** แล้วมันต้องทำงานได้
   — นี่คือข้อพิสูจน์ว่า `TENANT_ROUTES` ตายจริง
4. `/health/live` และ `/health/ready` ต้องไม่แตะ Postgres เพิ่มขึ้นจากเดิม

---

### `tx.5` — ย้าย argon2 ออกนอกทรานแซกชัน

**ทำ:** `VoidService.assertManagerPin` แยกเป็นสองท่อน — `runTx` สั้น ๆ อ่าน `pin_hash`
(ตาราง `users` มี RLS จึงยังต้องมี tenant scope) แล้ว `verifyPassword` **นอกทรานแซกชัน**
จากนั้นค่อย `runTx` ใบจริงสำหรับการ void

ปลอดภัยเพราะ PIN คือ **การอนุญาต ไม่ใช่ invariant** — ไม่มีอะไรของบิลถูกอ่านหรือเขียนคร่อม
ช่องว่างนั้น และผู้จัดการที่เปลี่ยน PIN ระหว่างสองท่อนก็ยังอนุญาตการ void นี้ด้วย PIN ที่พิมพ์จริง

**AC**
1. เคสเดิมใน `sale-reads.e2e-spec.ts` (ไม่มี PIN / PIN ผิด / cashier / void ซ้ำ / มีใบลดหนี้แล้ว)
   ผ่านครบโดยไม่แก้ assertion
2. `audit_log` แถว `sale.void.denied` ยังถูกเขียนตอนปฏิเสธ และยังรอดจากการ rollback
3. วัดซ้ำ: latency ของ 4 void พร้อมกันที่ pool 2 **เลิกเป็นขั้นบันได** (ของเดิม
   119/126/229/234 ms → ของใหม่ 142/143/157/157 ms)

---

## 3. ของที่แผนนี้ *ไม่* แตะ

* `AuthService` — ADR-0009 บังคับให้ audit ของ login ที่ล้มเหลวรอดจาก rollback มันจึงถือ
  `DataSource` ของตัวเองอย่างตั้งใจ **ห้ามย้ายเข้า `runTx`**
* `platform/*` — คนละ plane คนละ pool (`ADMIN_DATA_SOURCE`, BYPASSRLS) ตาม ADR-0002
* `VoidService.auditDenial` — เหตุผลเดียวกับ `AuthService` เขียนไว้ในโค้ดแล้ว
* `DocNumberService` — รับ `manager` มาเป็นพารามิเตอร์อยู่แล้ว ไม่ต้องรู้จัก `runTx` เลย

## 4. ความเสี่ยงที่ยังเปิดอยู่

* 🔴 **full suite บนเครื่อง dev ที่ใช้ Postgres ร่วมกันมี flake อยู่ก่อนแล้ว** — ทั้งก่อนและหลัง
  การเปลี่ยนนี้ วัดได้ประมาณ 1–2 ใน 10 รอบ ของ baseline มีอย่างน้อยหนึ่งครั้งที่เป็น
  *"Worker exited unexpectedly"* ซึ่ง `test/support/fixture.ts` บันทึกไว้เองว่าเคยเจอ
  suite ทุกไฟล์ใช้ tenant UUID ตายตัว → agent สองตัวที่รันพร้อมกันจะ `resetTenant`
  ทับกัน **นี่เป็นปัญหาที่มีอยู่ก่อน ไม่ใช่ของแผนนี้ แต่จะทำให้แต่ละสไลซ์ตรวจยากขึ้น**
  ทางแก้ที่ถูกคือให้ fixture สุ่ม tenant UUID ต่อรอบ — ควรเป็น ticket แยก และถ้าทำก่อน
  `tx.3` จะคุ้มที่สุด เพราะ `tx.3` คือสไลซ์ที่ต้องเชื่อผลรันซ้ำมากที่สุด
* `tx.4` เป็นสไลซ์เดียวที่ rollback ไม่ได้ด้วยการ revert service ทีละตัว — ถ้าต้องถอย
  ต้อง revert ทั้ง PR ให้ merge ตอนที่ไม่มีใครกำลังจะ deploy
