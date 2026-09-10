# Handoff — รอบตรวจ Lane A: blocker idempotency · audit ทำ pool แตก · ADR-0003 เปลี่ยนเป็น handler-scoped (2026-09-10)

**วันที่:** 2026-09-10 · **ผู้บันทึก:** NuimanLP (team/1) · **สถานะ:** รอ merge (PR #75 + คอมมิตรอบนี้)
**ขอบเขต:** ตรวจ PR #75 สามแกนขนานกัน แล้วแก้ทุกอย่างที่แก้ได้โดยไม่ตัดสินใจแทนคน
**ต่อจาก:** [`lane-a-sales-shifts-void.md`](lane-a-sales-shifts-void.md) (#19 #20 #23 #28)

---

## 1. ตอนนี้อยู่ตรงไหน

- PR #75 เพิ่ม **7 คอมมิตของรอบตรวจ** · `lint 0 · tsc 0 · unit 81 · e2e 109 + 1 todo` รัน 4 รอบติดสะอาด
- **ADR-0003 ถูกแก้แล้ว** — เพิ่มหัวข้อ *"ใครตัดสิน กับ ใครลงมือ"* (+90 บรรทัด ไม่ลบของเดิมสักบรรทัด)
  พร้อมแผนย้าย [`0003-handler-scoped-migration-plan.md`](../Backend_design/adr/0003-handler-scoped-migration-plan.md) 6 slice (`tx.0`–`tx.5`)
- **ยังไม่ลงมือ `tx.*`** — จงใจ ดู §3
- prototype ที่ใช้ตัดสิน เก็บเป็น commit `0feaf94` บน branch `worktree-agent-a1756ff02f223b4eb` (ไม่ merge)

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

ตรวจ 3 แกนขนานกัน — Standards (repo convention + Fowler smell), Spec (#19 #20 #23 #28 เทียบ Dart reference),
Scrutinize (ไล่ call graph จริงข้าม seam) — แล้วแตก agent แก้ 8 ตัว แบ่งไฟล์ไม่ให้ชนกัน

**ของที่ไม่มีใครเห็นมาก่อนและร้ายที่สุด — Scrutinize เจอ:**

🔴 **`POST /sales/:id/void` ใช้ `Idempotency-Key` ซ้ำ แล้วได้บิลผิดพร้อมสถานะ 200**
`idempotency.interceptor.ts` ประกอบ fingerprint จาก `req.route?.path` ซึ่งเป็น **pattern** (`/sales/:id/void`)
ไม่ใช่ URL จริง และ `requestHash` แฮชแค่ body ซึ่ง void มีแค่ `{pin}` → void คนละบิลได้ลายนิ้วมือเดียวกัน
วัดจริง: `void s2` ตอบ 200 พร้อม payload ของ s1 · s2 ยังไม่ถูกยกเลิก · สต็อกไม่คืน
ชั้นที่มีไว้ทำให้ key ซ้ำปลอดภัย กลับทำให้มันผิดแบบเงียบ · route นี้เป็น**เส้นแรกในรีโป**ที่เอา
`IdempotencyInterceptor` มาคู่กับ path parameter ช่องโหว่จึงมากับ PR นี้แม้ interceptor จะมาจาก #18
→ แก้ให้ `endpoint` มาจาก path จริง (`${req.method} ${req.baseUrl}${req.path}`)

🟠 **audit ตอน void ถูกปฏิเสธ ขอ connection ตัวที่สองจาก pool เดียวกัน → 500 ใส่ request อื่น**
`README.md` เขียนว่านี่คือ "ข้อยกเว้นเดียวที่ตั้งใจ" ของกฎห้ามขอ connection ที่สอง — เหตุผลถูก
(403 ต้อง rollback แต่ audit ต้องรอด) แต่ **การหยิบจาก pool เดียวกันไม่ปลอดภัย** และ branch แรกของ
การปฏิเสธคือ `role` แปลว่า **cashier คนไหนก็ทริกได้ ไม่ต้องรู้ PIN**

| `DB_POOL_SIZE=2` | ก่อน | หลัง |
|---|---|---|
| denial 4 ตัวพร้อมกัน | `403,403,500,500` — 5013 ms | `403,403,403,403` — 47 ms |
| request อื่นที่วิ่งพร้อมกัน | `500,500,500,500` | `200,200,200,200` |

→ แยก `AUDIT_DATA_SOURCE` (pool 2, timeout 2s, role `pos_app` เดิมเพื่อให้ RLS ยังบังคับ)

**ที่เหลือ:** replay บิลที่ void แล้วตอบเป็นสำเร็จ → `409 SALE_VOIDED` · ปิดกะซ้ำได้ข้อความของ `addEntry`
→ `SHIFT_ALREADY_CLOSED` · `paymentMethod` เป็น free text → whitelist 3 ค่า · fixture ตั้ง username ซ้ำทุก tenant
→ ผูกกับ tenant id · dedup 3 จุด

**ตรวจสอบด้วยอะไร:** ทุก agent ถูกบังคับให้ **เขียนเทสให้แดงก่อน** แล้วค่อยแก้ และแปะผลทั้งก่อน/หลัง —
ทุกตัวทำได้จริง (`expected 201 to be 409`, `expected 200 to be 409`, `expected 0 to be greater than 0`)

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

| เรื่อง | ทางเลือก | เลือก | เหตุผล |
|---|---|---|---|
| **ADR-0003: transaction อยู่ที่ไหน** | request-wide (ของเดิม) / handler-scoped | **handler-scoped + แก้ ADR** | request-wide **ไม่เคยถูกเลือก** — ถูกบังคับให้เกิดเพราะอ่าน ADR ข้อ 3 ("เช็คสถานะกับ `SET LOCAL` ต้อง component เดียวกัน") แล้วตีความว่าผูก *ที่อยู่ของ transaction* ไปด้วย · แยก "ใครตัดสิน" (guard) ออกจาก "ใครลงมือ" (`runTx`) แล้วการรับประกันของ ADR อยู่ครบ แต่ลบ middleware + `TENANT_ROUTES` + backstop + global interceptor ได้ · transaction เปิดค้าง **112 ms → 18–28 ms** |
| **ลงมือ `tx.*` ใน PR นี้เลยไหม** | ทำเลย / แยก PR | **แยก 6 slice** | 18 ไฟล์ ±577 บรรทัด บน PR ที่เขียวแล้วและมี 4 ticket ต่อคิวอยู่ · `tx.3` (idempotency) **ล้มแบบเงียบและล้มเป็นเงิน** ต่างจาก slice อื่นที่ล้มดัง |
| **`paymentMethod` ยึดอะไร** | เอกสาร 4 ค่า / หน้าจอ 3 ค่า | **หน้าจอ 3 ค่า + แก้เอกสาร** | **เจ้าของโปรเจกต์ตัดสิน** — `01_DATABASE.md:578` เขียน 4 ค่ารวม `'บัตร'` แต่ `checkout_screen.dart:2355` สร้างได้แค่ 3 และ **`'บัตร'` ไม่มีใน `frontend/lib` เลยสักที่** (grep ได้ศูนย์) · `'โอน'` ก็ผิด ของจริงคือ `'โอน/QR'` |
| **alias เก่า (`PromptPay`, `โอนเงิน`)** | รับด้วย / ไม่รับ | **ไม่รับตอนเขียน** | `closing_report.dart:248` ทนค่าเหล่านี้ตอน **อ่าน** ประวัติที่ import มา คนละเรื่องกับการให้ `POST /sales` สร้างแถวใหม่ด้วยสะกดที่ UI ทำไม่ได้ |
| **ปิดกะซ้ำ: code เดิมหรือใหม่** | `DRAWER_CLOSED` / code ใหม่ | **`SHIFT_ALREADY_CLOSED`** | §8 ผูก `DRAWER_CLOSED` ไว้กับข้อความไทยหนึ่งประโยค ถ้าใช้ code เดิม client #55/#56 ที่ render ไทยตาม code จะสร้างบั๊กเดิมจากอีกฝั่ง |
| **ข้อความไทยของ error ใหม่** | แต่งเอง / อังกฤษ + §8.1 | **หาของจริงก่อน แล้วอังกฤษ** | `shifts_repository.dart` ไม่เคยปฏิเสธการปิดซ้ำเลย จึงไม่มีต้นฉบับให้ลอก · ส่วน replay บิล void เจอว่า `SALE_VOIDED` **มีอยู่แล้ว** ใน §8 จึงไม่เพิ่ม code ใหม่ให้ร้านต้องตั้งชื่อ |
| **global teardown ของ e2e** | ทำ / ไม่ทำ | **ไม่ทำ** | ระบุ tenant ได้แค่ด้วย pattern `code LIKE 'test-%'` และ DB แชร์กัน → จะลบ fixture ของ run ที่กำลังวิ่ง **เป็นกับดักที่แย่กว่าอันที่กำลังแก้** · username ผูก tenant id พอแล้ว |
| **CHECK constraint ของ `payment_method`** | ใส่เลย / ไม่ | **ไม่ใส่** | migration เป็นของเลน schema (`team/2`) — DTO คือขอบเขตของเลนนี้ |

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- **ให้ agent ตัดสิน `paymentMethod` เอง** → มันหยุดแล้วรายงานว่าแหล่งข้อมูลขัดกัน **ซึ่งถูกแล้ว** ถ้าปล่อยให้เดา
  whitelist ผิด = บิลจริงถูกปฏิเสธหน้าเคาน์เตอร์ แย่กว่าบั๊กที่กำลังแก้ → ต้องให้เจ้าของโปรเจกต์ชี้ขาด
- **worktree แยกกัน แต่ DB ไม่แยก** → agent ที่ prototype อยู่คนละ worktree รัน e2e ชนกับ tree หลัก
  `schema.e2e-spec.ts` มีเคส `down()` **รื้อ schema ทั้งชุด** อาการที่ได้คือ
  `Migration "InitialSchema…" failed: terminating connection due to administrator command`
  และ `expected 'RC07-2569-09-0004' to be '…-0001'` — ล้ม 17/9/13/6 ครั้งไม่ซ้ำที่
  **ไม่ใช่บั๊กของโค้ด** พอไม่มีใครแตะ DB รัน 4 รอบเขียวสนิท
- **แก้ argon2-in-transaction กับ `TENANT_ROUTES` แยกเป็นใบ ๆ** → **ยกเลิก** ทั้งคู่หายไปเองใน `tx.*`
  ถ้าทำตอนนี้คือจ่ายเงินเขียนของที่จะถูกลบ

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

**ยืนยันแล้ว (วัดจริงบน Postgres จริง):** fingerprint ซ้ำ · pool แตกจาก audit · connection hold 112→18 ms ·
`endpoint` format เปลี่ยนแค่ route เดียว (อีก 4 เป็น static) · leftover tenant ทำ suite อื่นล้มจริง

**แค่เดา / ยังไม่ได้ตรวจ:**
- 🔴 **`runTx(tid, fn)` คือช่องกว้างเท่าการพิมพ์ผิดครั้งเดียว** — ADR ฉบับแก้รอดได้เพราะ `runTx(fn)`
  **ไม่รับ `tid`** แต่ `TenantService` ที่อยู่ในรีโปวันนี้คือ `runTx(tid, fn)` ถ้าใครทำตามลายเซ็นที่เห็น
  การแก้ ADR จะกลายเป็นสิ่งที่ ADR เดิมห้ามไว้ **และล้มแบบเงียบ คืนแถวข้ามร้านโดยไม่มี error**
  → `tenant-door.spec.ts` เป็น **เงื่อนไขของการเปลี่ยน ไม่ใช่ของแถม**
- e2e ทน runner ตัวที่สองบน DB เดียวกันไม่ได้ — CI ไม่เจอเพราะแต่ละ job มี Postgres ของตัวเอง
  แต่วันที่เพื่อนสองคนรัน `test:e2e` พร้อมกันจะได้ build แดงที่หาสาเหตุไม่เจอ **ยังไม่มี ticket**
- ไม่ได้ทดสอบกับ client Flutter จริงเลย เหมือนรอบก่อน

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **merge PR #75**
2. **ตอบ #11** — ยังเป็นสิ่งเดียวที่ปลดล็อก #21 → #22 → #24 → #56 เหมือนเดิม
3. **ตัด ticket `tx.0`–`tx.5`** ตามแผน · `tx.3` คือใบที่ต้องรีวิวหนักที่สุด
4. **ticket ใหม่ 2 ใบที่รอบนี้พบแต่ไม่ได้แก้:**
   - `movements.type = 'void'` — ตอนนี้ void เขียน `'return'` (`void.service.ts:155`) รายงาน #30 ที่
     `GROUP BY type` จะนับ void เป็นการคืนสินค้า · ต้องแก้ CHECK constraint = migration = เลน `team/2`
   - e2e ทน runner ที่สองไม่ได้ (ดู §5)
5. ตัดสิน 2 ข้อที่ค้างจากรอบก่อน (ปุ่ม void / `shift_id` หลังปิดกะ) — ถามร้าน

## 7. ข้อควรระวัง

🔴 **อ่านก่อนแตะของพวกนี้**

1. **`req.route.path` คือ pattern ไม่ใช่ URL** — endpoint ไหนก็ตามที่มี path parameter แล้วใช้
   `IdempotencyInterceptor` ต้องคิดเรื่องนี้ · ตอนนี้แก้ที่ `endpoint` ไม่ใช่ `request_hash` **โดยตั้งใจ**
   เพราะ `01_DATABASE.md:334` นิยาม `request_hash` ว่า "sha256 ของ body" ไว้เป็นลายลักษณ์อักษร
   ยัด `req.params` เข้าไปจะทำให้นิยามนั้นเป็นเท็จทั้งที่ชื่อคอลัมน์เหมือนเดิม
2. **ห้ามขอ connection ที่สองจาก request pool — ไม่มีข้อยกเว้นแล้ว** งาน out-of-band ไปที่
   `AUDIT_DATA_SOURCE` · **ห้ามใช้ `ADMIN_DATA_SOURCE`** เพราะต่อในฐานะ owner แปลว่า RLS ไม่ตรวจ
   → `tenantId` ผิดจะลงล็อกร้านอื่นเงียบ ๆ แทนที่จะถูกปฏิเสธ ซึ่งเป็นความล้มเหลวที่ audit trail ห้ามมี
3. **ก๊อปข้อความไทยไปใช้บริบทใหม่ ผิดกฎเดียวกับแต่งใหม่** — `CLAUDE.md` เขียน "copy exactly … never
   translate" การยืมประโยคของ `addEntry` มาใช้ตอนปิดกะซ้ำ คือการบอกพนักงานผิดเรื่อง
4. **fixture ไม่ใช้ `tester` แล้ว** — `resetTenant` สร้าง `tester-<tenantId>` และ `TenantFixture` มี `username`
   ให้ใช้ค่านั้น อย่า hard-code
