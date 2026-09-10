# ADR-0003 — tenant มีสถานะ และบังคับที่ guard (ไม่ใช่ใน RLS predicate)

* **สถานะ:** Accepted — 2026-09-04 (กลไกบังคับ: เสนอโดย design, รอยืนยัน)
* **ผู้ตัดสิน:** เจ้าของโปรเจกต์
* **เกี่ยวข้อง:** `01_DATABASE.md §8`, `03_ARCHITECTURE.md §5`

## บริบท

`tenants` ยังไม่มีสถานะ และ RLS เช็คแค่ `tenant_id = current_setting('app.tenant_id')`
→ ถ้าร้านหนึ่งเลิกใช้/ไม่จ่ายเงิน/ต้องระงับ **ไม่มีสวิตช์ปิดเลย** ต้องไปลบ user ทีละคน
และต่อให้ลบ user แล้ว access token ที่ออกไปก่อนหน้ายังใช้ได้จนหมดอายุ

## การตัดสินใจ

1. เพิ่ม `tenants.status` — `'active' | 'suspended' | 'closed'`
2. **บังคับที่ `TenantGuard` ไม่ใช่ใน RLS predicate:** guard อ่าน `tid` จาก JWT → เช็คสถานะ →
   **ถ้าไม่ active ให้ปฏิเสธและ *ไม่* `SET LOCAL app.tenant_id`**
3. ผลพลอยได้: connection นั้นไม่มี `app.tenant_id` → RLS คืน 0 แถวอยู่แล้วโดยอัตโนมัติ
   **ได้ defence-in-depth ฟรี โดยไม่ต้องแตะ policy สักตัว** —
   **เงื่อนไข (เพิ่ม 2026-09-04):** ข้อนี้จริงก็ต่อเมื่อ **การเช็คสถานะกับ `SET LOCAL` อยู่ใน component
   เดียวกัน** `01_DATABASE.md §3` ฉบับก่อนให้ `TenantInterceptor` ทำ `SET LOCAL` แยกจาก guard
   → route ที่ลืมใส่ guard จะยังได้ `SET LOCAL` และเห็นข้อมูลร้านที่ถูกระงับ จึงเคาะว่า
   **`TenantGuard` ทำทั้งสองอย่าง** และไม่มี `TenantInterceptor` แยก (`03_ARCHITECTURE.md §5`
   วาดไว้ถูกอยู่แล้ว แก้ `01` ให้ตรง)
4. สถานะร้านเป็นค่าที่อ่านบ่อยมากและแทบไม่เปลี่ยน → cache ใน Redis (`t:{tid}:status`)
   และ **ลบ cache ทันทีที่ platform admin เปลี่ยนสถานะ** ไม่งั้นการระงับจะช้าเท่า TTL
5. **พฤติกรรมตอน cache miss / Redis ล่ม (เพิ่ม 2026-09-04):** อ่าน `tenants.status` จาก Postgres
   ด้วย PK แล้วเติม cache — **ห้าม fail-open** (ตาม ADR-0006) เพราะจะปลดการระงับทุกร้านเงียบ ๆ
   ตอน `redis-cache` ตาย และ **ห้าม fail-closed** เพราะจะดับทุกร้านซึ่ง ADR-0006 ห้ามไว้
   query นี้เบา (1 แถวด้วย PK) จึงรับ Redis ล่มได้โดยไม่ต้องมีทางลัด
6. key `t:{tid}:status` **ต้องมี TTL** (เสนอ 300s + jitter) ตามกฎ `02_API_SCREENS.md §5`
   "ทุก key ต้องมี TTL" — ฉบับก่อนตั้ง "ไม่หมดอายุเอง" ซึ่งขัดกฎนั้น และอยู่ใน `redis-cache`
   แบบ `allkeys-lru` ที่ evict ได้อยู่ดี การล้างตอนเปลี่ยนสถานะยังเป็นทางหลัก TTL เป็นตาข่ายรอง

## เหตุผล — ทำไมไม่ใส่สถานะลงใน RLS policy

ถ้าเขียน policy เป็น `tenant_id = current_setting(...) AND EXISTS (SELECT 1 FROM tenants
WHERE id = tenant_id AND status='active')` จะกลายเป็น **subquery ที่วิ่งต่อแถว ทุกตาราง ทุก query**
— จ่ายค่า performance ตลอดชีพระบบ เพื่อกันเคสที่เกิดปีละครั้ง
เช็คที่ guard = **ครั้งเดียวต่อ request** และให้ผลเหมือนกันเป๊ะ (เพราะ `SET LOCAL` ไม่เกิด)

### ใครตัดสิน กับ ใครลงมือ — เพิ่ม 2026-09-10 หลังวัดต้นทุน connection

**ปัญหาที่พบ:** ข้อ 2 ของ ADR นี้เขียนรวบ *"guard เช็คสถานะ → `SET LOCAL app.tenant_id`"*
ไว้เป็นก้อนเดียว แล้วข้อ 3 (เพิ่ม 2026-09-04) ก็ตอกย้ำว่า **"ต้องอยู่ใน component เดียวกัน"**
ถูกต้องในเจตนา แต่พออิมพลีเมนต์จริงกลับบังคับรูปทรงที่ไม่มีใครตั้งใจเลือก:

`SET LOCAL` มีความหมายเฉพาะ *ภายในทรานแซกชัน* และ `canActivate` **return ก่อน handler รัน**
guard จึงเปิดทรานแซกชันค้างไว้เองไม่ได้ ผลคือ #4 ต้องสร้าง `RequestContextMiddleware`
มาเปิดทรานแซกชัน **ตั้งแต่ก่อน guard ตัวแรก** และ `TransactionInterceptor` มา commit ทีหลัง
พร้อมของแถมที่ตามมาทั้งชุด: รายชื่อ `TENANT_ROUTES` ที่ต้องไล่แก้ด้วยมือทุกครั้งที่เพิ่ม
controller, ธง `OWNED_BY_INTERCEPTOR`, และ backstop บน `res.on('close')` สำหรับทางที่ guard
throw ก่อน interceptor ตัวไหนจะได้รัน

ราคาที่จ่ายไม่ใช่แค่ความซับซ้อน — **วัดออกมาเป็นตัวเลขได้** ทุก request ที่ผูก guard จะ
**ยึด connection จาก pool ไว้ตั้งแต่ก่อน guard จนหลังส่ง response** คือครอบ argon2 (`memoryCost:
65536`), การเช็ค PIN, การ serialise JSON และ client ที่เน็ตช้า วัดบน `POST /sales/{id}/void`
(4 request พร้อมกัน, `DB_POOL_SIZE=2`, Postgres จริง):

| | ทรานแซกชันยาวสุดที่ Postgres เห็น | wall time | latency ราย request |
|---|---|---|---|
| ของเดิม (ทรานแซกชันคลุมทั้ง request) | **112–116 ms** | 226–274 ms | 119 / 126 / 229 / 234 ms — เป็นขั้นบันได |
| แบบใหม่ (ทรานแซกชันอยู่ใน handler) | **18–28 ms** | 146–176 ms | 142 / 143 / 157 / 157 ms — เรียบ |

ขั้นบันไดคือคิว: request ที่ 3 กับ 4 รอ argon2 ของสองตัวแรกจบก่อน ทั้งที่ไม่ได้แย่ง lock อะไรกัน
ที่ `DB_POOL_SIZE=4` วัดได้ว่า **connection ทั้ง pool อยู่ในสถานะ `idle in transaction` พร้อมกันทั้ง 4 ตัว**
— request ที่ 5 ไม่ว่าจะเป็นการค้นสินค้าหรือดูรายงาน ก็ต้องรอ argon2 ของคนอื่น

**การตัดสินใจ:** แยก **"ใครตัดสิน"** ออกจาก **"ใครลงมือ"** — เจตนาของ ADR นี้อยู่ที่ข้อแรก
ไม่ใช่ข้อหลัง

| | ของเดิม | แบบใหม่ |
|---|---|---|
| ตัดสินว่า request นี้เป็นร้านไหน + เช็ค `tenants.status` | `TenantGuard` | **`TenantGuard` (เหมือนเดิม)** |
| เก็บคำตัดสินไว้ที่ไหน | `SET LOCAL` บนทรานแซกชันของ middleware | **request scope (`AsyncLocalStorage`) — `setRequestTenant()`** |
| ลงมือ `set_config('app.tenant_id', …, true)` | `TenantGuard` | **`TenantService.runTx`** ซึ่งอ่านค่าจาก scope ข้างบน |
| เปิด/ปิดทรานแซกชัน | middleware เปิด, interceptor commit | **`TenantService.runTx`** เปิดและ commit เอง ในขอบเขต handler |

**กติกาที่ยังเหมือนเดิมทุกตัวอักษร:**

* **guard เป็น component เดียวที่ตัดสินว่า request เป็นร้านไหน** — `setRequestTenant()` เรียกได้
  จาก `TenantGuard` ที่เดียว เหมือนที่ `SET LOCAL` เคยเรียกได้จากที่เดียว
* **ร้านที่ไม่ `active` ไม่เคยถูกตั้งชื่อลง scope เลย** → `runTx` เปิดทรานแซกชันให้ไม่ได้ →
  ไม่มี `app.tenant_id` → RLS คืน 0 แถวอยู่ดี **defence-in-depth ของข้อ 3 ยังอยู่ครบ** เพียงแต่
  ขยับไปอีกหนึ่งขั้น จาก "ไม่ `SET LOCAL`" เป็น "ไม่มีค่าให้ `set_config` เอาไปใช้"
* **ไม่มี `TenantInterceptor` แยกกลับมา** — สิ่งที่ข้อ 3 ห้ามไว้คือ component ที่ `SET LOCAL`
  โดย**ไม่ผ่านการเช็คสถานะ** `runTx` ไม่ใช่แบบนั้น: มันไม่มีทางรู้จัก tenant ที่ guard ไม่ได้อนุมัติ
* 🔴 **`runTx` ต้อง *ไม่* รับ `tid` เป็นพารามิเตอร์** — คลาส `TenantService` ที่มีอยู่ในโค้ดวันนี้
  (ยังไม่มีใครเรียกสักที่) เขียนเป็น `runTx(tid, fn)` ซึ่ง **ผิดและห้ามใช้รูปนั้น**: call site ไหน
  ก็ส่ง uuid ร้านอื่นเข้าไปได้ แล้วจะได้ข้อมูลข้ามร้านกลับมาแบบ**ที่หน้าโค้ดดูปกติและไม่มี error**
  — ซึ่งคือสิ่งเดียวที่ ADR นี้มีไว้กันโดยแท้ ต้องเป็น `runTx(fn)` ที่อ่าน tenant จาก scope เท่านั้น
* guard ยังอ่าน `tenants.status` จาก Postgres ได้ตอน cache miss ตามข้อ 5 — `tenants` เป็นหนึ่งใน
  `GLOBAL_TABLES` ที่ไม่มี RLS จึงอ่านด้วย pooled connection ธรรมดาโดยไม่ต้องมี `app.tenant_id`
  (**ตรวจกับ Postgres จริงแล้ว ไม่ใช่สมมติ**) และเป็น connection **ตัวแรก** ของ request นั้น
  ไม่ใช่ตัวที่สองที่ขอขณะยังถือตัวแรกอยู่ จึงไม่ใช่รูปทรงที่ทำให้ pool ตัน

**สิ่งที่ตายไปพร้อมกัน:** `RequestContextMiddleware`, `TransactionInterceptor`,
`OWNED_BY_INTERCEPTOR`, backstop บน `res.on('close')` และ **`TENANT_ROUTES`** — โค้ดฝั่ง
production หายไป 3 ไฟล์ (257 บรรทัด) แลกกับของใหม่ 2 ไฟล์ (152 บรรทัด) ที่เข้ามาแทน

**สิ่งที่แลกไป — และวิธีปิด:** footgun เปลี่ยนหน้า จาก *"ลืมใส่ controller ใน `TENANT_ROUTES`"*
เป็น *"ลืมห่อ `runTx`"* ทดสอบกับ Postgres จริงแล้วว่ามันพังคนละแบบ:

| ลืมแบบไหน | ผล | ดังไหม |
|---|---|---|
| ลืม `runTx` แต่ยังขอ manager ผ่าน `currentRequestContext()` | throw → 500 | **ดัง** ปิดตายเหมือนเดิม เพราะประตูเดียวที่ให้ manager ได้คือ `runTx` |
| ฉีด `DataSource` เข้า service แล้ว query ตรง | **200 พร้อม 0 แถว** · UPDATE รายงานสำเร็จแต่ไม่ขยับอะไร | 🔴 **เงียบสนิท** |

แถวที่สองคือแถวที่อันตราย และ **มันมีอยู่แล้ววันนี้** (`AuthService`, `VoidService.auditDenial`
ต่างก็ถือ `DataSource` ของตัวเองด้วยเหตุผลที่เขียนไว้ชัด) ไม่ได้เกิดจากการเปลี่ยนนี้ แต่การเปลี่ยนนี้
ทำให้ `DataSource` เปล่า ๆ เป็นของที่หยิบง่ายขึ้น → **ต้องมี architecture test สแกน source
ห้ามฉีด `DataSource` นอก allowlist ที่มีเหตุผลกำกับทีละบรรทัด** (แบบเดียวกับ
`common/tenant-scope.spec.ts` ที่ดักการเขียน `SET LOCAL … = $1`) ข้อนี้เป็นเงื่อนไข ไม่ใช่ข้อเสนอแนะ

**ไม่ขัดกับ ADR อื่น:** ADR-0004 (`did`/`drole` มาจาก device token ที่ server ตรวจ ไม่ใช่จาก body)
ไม่ถูกแตะเลย — guard ยังอ่าน claim ชุดเดิมจาก JWT ตัวเดิม · ADR-0009 (`/auth/refresh` เช็ค
`users.is_active` + `tenants.status` + `devices.retired_at`) ไม่ถูกแตะ เพราะ `/auth/*` ไม่เคยอยู่ใน
ทรานแซกชันของ request อยู่แล้ว (ADR-0009 บังคับให้ audit ของ login ที่ล้มเหลว **ต้องรอด** จากการ
rollback ซึ่งเป็นเหตุผลเดียวกับที่ `TENANT_ROUTES` ใส่แค่ `GET /auth/me` ไม่ใส่ทั้ง controller) ·
ADR-0010 (client write-through) เป็นเรื่องฝั่ง Flutter ล้วน ไม่มีจุดสัมผัส · ADR-0007 (เลขเอกสาร
ต้องถูกจองใน**ทรานแซกชันเดียวกับบิล**) ยังจริง — `DocNumberService.issue` รับ `manager` มาจาก
`runTx` ตัวเดียวกับที่เขียนบิล บิลที่ rollback ยังพาเลขกลับไปด้วยเหมือนเดิม (มีเคสใน
`test/request-context.e2e-spec.ts` ยืนยัน และผ่านทั้งก่อนและหลัง)

**เงื่อนไขที่ต้องคงไว้ตอนย้าย:** record ของ `Idempotency-Key` **ต้อง commit ในทรานแซกชันเดียว
กับงานที่มันอธิบาย** (`02_API_SCREENS.md §1.4`) — เมื่อไม่มี `IdempotencyInterceptor` แล้ว
มันกลายเป็น `runIdempotent(...)` ที่เรียกอยู่ **ข้างใน** `runTx` บน `manager` ตัวเดียวกัน
กลไก concurrency ไม่เปลี่ยนสักบรรทัด (`INSERT … ON CONFLICT DO NOTHING` + row lock เดิม)
เคส 3-way race และเคส "process ตายหลัง commit ก่อนตอบ" ใน `test/idempotency.e2e-spec.ts`
ผ่านทั้งคู่โดยไม่ต้องแก้ assertion

## ผลที่ตามมา

* ระงับร้านแล้ว **มีผลทันทีในคำขอถัดไป** ไม่ต้องรอ access token 15 นาทีหมดอายุ
* ต้องมี error code + ข้อความไทยใหม่สำหรับ "ร้านถูกระงับ" — **ห้ามแต่งเอง** ตามกติกาใน
  `02_API_SCREENS.md §8.1` ต้องให้คนหน้าร้าน/เจ้าของเลือกคำ
* `/platform/*` ต้องมี endpoint เปลี่ยนสถานะ + เขียน `audit_log` (ADR-0002)
* BullMQ worker ต้องเช็คสถานะด้วย — job ที่ค้างในคิวของร้านที่เพิ่งถูกระงับต้องไม่ถูกรัน

## ขอบเขต — สิ่งที่ *ไม่* ทำในเฟส 1

* **ไม่ทำ** export ข้อมูลคืนทั้ง tenant / hard delete ตามคำขอ (PDPA เต็มรูป)
* **ไม่ทำ** billing / subscription — บันทึกไว้ว่าเป็น out-of-scope ที่ตั้งใจ ไม่ใช่ลืม
* `'closed'` ในเฟส 1 มีค่าเท่ากับ `'suspended'` แต่สื่อเจตนาต่างกัน (เลิกใช้ vs ระงับชั่วคราว)

## ยังไม่เคาะ

* [ ] ร้านที่ `suspended` ควร **อ่านข้อมูลตัวเองได้ไหม** (เช่นดึงรายงานย้อนหลังไปทำบัญชี)
      หรือปิดตายทั้งอ่านและเขียน? — เสนอ: ปิดตาย เพราะง่ายกว่าและอธิบายลูกค้าตรงไปตรงมา
      วิธีถามเจ้าของโปรเจกต์: "ถ้าเราหยุดให้บริการร้านหนึ่ง เจ้าของยังควรดูและ export ข้อมูลเก่าได้ไหม"
* [ ] BullMQ worker เช็คสถานะ (ผลที่ตามมาข้อ 4) ยังไม่มีเคสใน DoD `03_ARCHITECTURE.md §8` —
      DoD ทดสอบแค่ request path
* [ ] `closed` แล้วข้อมูลอยู่ในระบบนานแค่ไหนก่อนลบจริง (PDPA ต้องประกาศระยะเวลาเก็บ)
