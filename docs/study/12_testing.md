# 12 — Testing Strategy: ทำไม repo นี้มี test เกือบ 160 ไฟล์

> บทนี้ตอบคำถาม: **"test คืออะไรกันแน่ ทำไมต้องมีหลายชนิด (unit/integration/e2e) และของจริงในร้านนี้ — ใครทดสอบอะไร ที่ไหน ป้องกัน bug อะไรจริงๆ"**

---

## 🧭 ก่อนอ่าน

- **ต้องอ่านก่อน:** [00_index.md](00_index.md) (terminal เบื้องต้น, Git), [04_frontend.md](04_frontend.md) (Drift repository), [06_backend.md](06_backend.md) (transaction/tenancy, ADR-0003)
- **ควรอ่านคู่กัน:** `docs/tutorial/testing-tutorial.md` — คู่มือ**คำสั่ง**รัน test ทั้งหมด (บทนี้จะไม่พิมพ์คำสั่งซ้ำ จะลิงก์ไปแทน)
- **เวลาที่ใช้:** ~75–100 นาที
- **อ่านจบแล้วคุณจะ…**
  - อธิบาย test pyramid vs testing trophy ได้ และบอกได้ว่า repo นี้เอียงไปทางไหน
  - แยก fake / stub / mock / spy ออกจากกันได้ และรู้ว่าทำไม "mock ผิดที่ผิดทาง" เคยซ่อน bug จริงในร้านนี้ (#383)
  - อ่าน architecture test (fitness function) 3 ไฟล์ของ repo นี้ออก และรู้ว่ามันปกป้อง invariant อะไร
  - อธิบายได้ว่าทำไม "ผ่าน 100% coverage" ไม่ได้แปลว่าโค้ดถูก
  - หา concurrency test ที่พิสูจน์ "ขาย 200 บิลพร้อมกัน บนสต็อก 50 → ได้ 50 บิลเป๊ะ" เจอ และอธิบายว่ามันพิสูจน์อะไร

---

## 🧱 ปูพื้นฐาน

### 1. ทำไมต้อง test — ต้นทุนของ bug แพงขึ้นตามเวลาที่เจอ

> **Analogy — ร้านอะไหล่ตรวจของก่อนส่ง:** อะไหล่ผิดรุ่นที่เจอ**ตอนแพ็ก** (5 นาทีแก้) ถูกกว่าเจอ**ตอนลูกค้าใส่รถแล้วน็อตไม่เข้า** (ลูกค้าโมโห + ค่าส่งของใหม่ + เสียชื่อร้าน) มหาศาล

ในซอฟต์แวร์ก็เหมือนกัน bug ตัวเดียวกัน ถ้าเจอ:
- **ตอนเขียนโค้ด** (IDE ขีดเส้นแดง) — แก้ใน 1 นาที
- **ตอน test อัตโนมัติรันตอน commit** — แก้ใน 5–30 นาที ยังไม่มีใครเดือดร้อน
- **ตอน code review** — แก้ใน 1 ชั่วโมง + เสียเวลาคนรีวิว
- **ตอน production (ลูกค้าใช้จริง)** — อาจแปลว่า**ขายของผิดราคา**, **สต็อกติดลบ**, **เงินหาย** — แก้ยากกว่าเดิม 10–100 เท่า เพราะต้อง debug บนข้อมูลจริง, อาจต้อง rollback, อาจต้องคืนเงินลูกค้า

Test อัตโนมัติคือการ "จ่ายเวลาน้อยๆ ตอนเขียนโค้ด" เพื่อ "ไม่ต้องจ่ายเวลามหาศาลตอนของพัง production" — มันไม่ได้ทำให้เขียนโค้ดเร็วขึ้นในวันแรก แต่ทำให้ **แก้ของเดิมได้โดยไม่กลัวว่าจะพังจุดอื่น** (นี่คือเหตุผลที่ repo อายุมากขึ้นยิ่งต้องมี test มากขึ้น ไม่ใช่น้อยลง)

### 2. test คืออะไรกันแน่ — Arrange / Act / Assert

test หนึ่งตัวคือฟังก์ชันเล็กๆ ที่ทำ 3 ขั้นเสมอ:

1. **Arrange** (จัดฉาก) — เตรียมข้อมูล/สถานะเริ่มต้น
2. **Act** (ลงมือทำ) — เรียกฟังก์ชัน/endpoint ที่จะทดสอบ
3. **Assert** (ยืนยัน) — เช็คว่าผลลัพธ์ตรงกับที่คาดไว้ ถ้าไม่ตรง test ล้ม (fail) ทันที

ตัวอย่างสมมติ (Dart):

```dart
test('บวกเงิน 2 จำนวนได้ผลถูกต้อง', () {
  // Arrange
  final a = 10.0;
  final b = 5.5;

  // Act
  final result = a + b;

  // Assert
  expect(result, 15.5);
});
```

ตัวอย่างสมมติ (TypeScript, ใช้ vitest — เครื่องมือที่ backend ของร้านนี้ใช้จริง):

```ts
it('คำนวณส่วนลด 10% ถูกต้อง', () => {
  // Arrange
  const price = 100;

  // Act
  const discounted = price * 0.9;

  // Assert
  expect(discounted).toBe(90);
});
```

โครง 3 ขั้นนี้เหมือนกันไม่ว่าจะทดสอบอะไร — ต่างกันแค่ "Act" ซับซ้อนแค่ไหน (เรียกฟังก์ชันตรงๆ vs ยิง HTTP request จริงเข้า server)

### 3. Test Pyramid vs Testing Trophy

**Test pyramid** (แนวคิดดั้งเดิม) บอกว่า: มี **unit test** (ทดสอบฟังก์ชัน/class เดียว แยกขาดจากส่วนอื่น) เยอะที่สุดเพราะเร็วและถูก, มี **integration test** (ทดสอบหลายชิ้นทำงานร่วมกัน เช่น repository จริงคุยกับฐานข้อมูลจริง) ปานกลาง, มี **e2e test** ("end-to-end" — ทดสอบทั้งระบบเหมือนผู้ใช้จริงใช้งาน ผ่าน HTTP จริง) น้อยที่สุดเพราะช้าและเปราะ (แก้อะไรนิดเดียว test อาจพังทั้งไฟล์)

```
        /\
       /e2e\        ← น้อย, ช้า, สมจริงที่สุด
      /------\
     /integr. \      ← ปานกลาง
    /----------\
   /   unit     \    ← เยอะ, เร็ว, แยกขาด
  /--------------\
```

**Testing trophy** (แนวคิดใหม่กว่า จาก Kent C. Dodds) เถียงว่า unit test เดี่ยวๆ เยอะเกินไปมักไม่คุ้ม เพราะโค้ดจริงพังที่ "รอยต่อ" ระหว่างชิ้นส่วนบ่อยกว่าในตัวฟังก์ชันเดียว จึงเสนอให้เน้น **integration test** เป็นก้อนใหญ่สุดแทน (รูปทรงเหมือนถ้วยรางวัล — คอคอดล่างสุดคือ static check เช่น type-checker/linter)

```
   /------------\
  /     e2e      \   ← น้อยสุด
 /----------------\
/   integration    \  ← ก้อนใหญ่สุด (รอยต่อจริง)
\------------------/
 \      unit       /
  \----------------/
   \--------------/
    \   static   /    ← type check, lint (เร็วสุด, ล่างสุด)
     \----------/
```

repo นี้**เอียงไปทาง trophy**: ตัวเลขจริง (ยืนยันด้วย `find`, 2026-09-25) —

| ระดับ | frontend (Flutter) | server (NestJS) |
|---|---|---|
| unit/repository (colocated หรือแยกโฟลเดอร์ทดสอบ class เดี่ยว) | ส่วนใหญ่ของ 65 ไฟล์ใน `frontend/test/` | 40 ไฟล์ `*.spec.ts` ใน `server/src/**` |
| integration/e2e (จริงผ่าน HTTP + Postgres จริง) | route smoke test, sync test | **53 ไฟล์** `*.e2e-spec.ts` ใน `server/test/` |

ฝั่ง server มี e2e (53 ไฟล์) มากกว่า unit spec (40 ไฟล์) เสียอีก — เพราะ invariant สำคัญที่สุดของร้าน (ล็อกสต็อก, RLS แยก tenant, idempotency กันบิลซ้ำ) เกิดที่ "รอยต่อ" ระหว่าง HTTP → transaction → Postgres จริง ทดสอบแยก class เดียวไม่พิสูจน์อะไรเลย ตรงกับเหตุผลของ testing trophy ไม่ใช่ pyramid ล้วนๆ

### 4. Test doubles — fake, stub, mock, spy ต่างกันยังไง

> **Analogy — ซ้อมละครก่อนเปิดจริง:** จะซ้อมฉาก "ลูกค้าโทรมาต่อว่า" ไม่มีใครอยากรบกวนลูกค้าจริงทุกรอบซ้อม เลยใช้ **คนแสดงแทน** — แต่คนแสดงแทนแต่ละแบบให้ประโยชน์ต่างกัน

เวลา test เรียกฟังก์ชันที่พึ่งพา "ของข้างนอก" (ฐานข้อมูล, network, เวลาปัจจุบัน) เรามักไม่อยากใช้ของจริง (ช้า/ไม่แน่นอน) เลยใช้ **test double** (ตัวปลอมแทนของจริง) — มี 4 แบบหลัก ต่างกันตรง "ปลอมแค่ไหน":

| แบบ | ทำอะไร | ใช้ตอนไหน |
|---|---|---|
| **Dummy** | ส่งเข้าไปเฉยๆ ไม่ถูกเรียกใช้จริง (แค่ให้ compile ผ่าน) | พารามิเตอร์ที่ test ไม่สนใจ |
| **Stub** | ตอบค่าคงที่ตามที่ตั้งไว้ล่วงหน้า ไม่มี logic | "ถ้าถาม getPrice() ให้ตอบ 100 เสมอ" |
| **Fake** | ทำงานได้จริงแบบง่ายกว่าของจริง (เช่น เก็บใน memory แทนดิสก์) | ฐานข้อมูลจำลอง (ดูข้อ 5 ด้านล่าง) |
| **Mock** | เหมือน stub แต่ test **เช็คด้วยว่าถูกเรียกยังไง** (กี่ครั้ง, พารามิเตอร์อะไร) | ยืนยันว่า "ฟังก์ชัน sendEmail ถูกเรียก 1 ครั้ง" |
| **Spy** | ของจริง (หรือเกือบจริง) ที่ "แอบจด" ว่าถูกเรียกยังไง โดยยังทำงานจริงอยู่ | อยากรู้ว่าเรียกกี่ครั้ง แต่ยังอยากให้ผลลัพธ์จริงเกิดขึ้น |

**บทเรียนสำคัญที่สุดของข้อนี้: mock ผิดที่ผิดทางสามารถซ่อน bug จริงได้** — และร้านนี้เจอเองมาแล้วกับ issue **#383**

เดิมมี test ใน `tenant-scope.e2e-spec.ts` (ไฟล์นี้ถูกลบไปแล้ว) ที่อ้างว่าพิสูจน์ "ถ้า redis-cache ล่ม ร้านที่ `suspended` (ถูกระงับ) ต้องยังถูกปฏิเสธ และร้านปกติต้องยังขายได้" — แต่วิธีทำคือ `vi.spyOn` (mock) ไปที่ **method ของ cache client เอง** แล้วสั่งให้มัน throw error ปลอมๆ

ปัญหาคือ: การ mock แบบนี้พิสูจน์แค่ **"โค้ด catch ทำงานเมื่อถูกเรียก"** — ไม่ได้พิสูจน์ว่า **"แอปยังรอดจริงเมื่อ redis-cache ต่อไม่ติดจริงๆ"** สอง statement นี้ฟังดูเหมือนกันแต่ไม่ใช่: ระหว่างทางอาจมี code path อื่น (เช่น connection pool, retry logic, timeout) ที่ mock ข้ามไปหมด เพราะ mock แทนที่ตัวมันเองไปเลย ไม่ได้ผ่านตัวจริงแม้แต่นิดเดียว — ถ้ามี bug ใน logic เชื่อมต่อ redis จริง test แบบนี้จะยัง**ผ่าน** (เขียว) อยู่ดี เพราะมันไม่เคยแตะโค้ดที่พังจริง

วันที่ 2026-09-22 ทีมแก้เป็น `server/test/redis-cache-outage.e2e-spec.ts` (269 บรรทัด) โดยทำให้ redis-cache **"ต่อไม่ติดจริง"** สองแบบ แทนการ mock (ดูรายละเอียดเต็มในหัวข้อ "ของจริงใน repo" ด้านล่าง) — doc comment ต้นไฟล์ (บรรทัด 17–23) พูดตรงๆ ว่าของเก่า

> "`vi.spyOn`'d the cache client's own methods — proving the guard's `catch` runs, not that the app survives a `redis-cache` that is genuinely unreachable"

**กฎที่ได้จากเรื่องนี้:** mock ที่จุด "ขอบเขตของระบบที่กำลังทดสอบ invariant นั้นพอดี" มักจะซ่อน bug ตรงขอบเขตนั้นเอง — ยิ่งอยาก test พฤติกรรมตอนของพัง ยิ่งต้องทำให้มันพังจริง (ปิด port จริง, ตัดสาย TCP จริง) ไม่ใช่บอกโค้ดว่า "แกล้งทำเป็นพัง"

### 5. Determinism และ flakiness

**Deterministic** (กำหนดผลได้แน่นอน) แปลว่า รันกี่รอบก็ได้ผลเหมือนเดิมทุกครั้ง ถ้าไม่แก้โค้ด — นี่คือคุณสมบัติที่ test **ต้องมี**

**Flaky test** (test เดี๋ยวผ่านเดี๋ยวไม่ผ่าน โดยไม่ได้แก้โค้ดอะไรเลย) เป็นศัตรูตัวฉกาจของทีม เพราะพอ test แดงบ่อยๆ โดยไม่ใช่เพราะ bug จริง คนจะเริ่ม "เพิกเฉย" ต่อสีแดง (กด rerun เฉยๆ) — แล้ววันหนึ่งที่มันแดงเพราะ bug จริง ก็ไม่มีใครสังเกต

สาเหตุทั่วไปของ flakiness: เวลาจริง (`DateTime.now()` เปลี่ยนทุก run), ลำดับการทำงานแบบขนานที่ไม่ควบคุม (race condition), เครือข่ายจริง, หรือ test สองตัวใช้ข้อมูลร่วมกันแล้วรบกวนกัน

repo นี้มีตัวอย่างการ "จ่ายต้นทุนเพื่อกัน flaky" ที่เห็นชัดคือ `server/vitest.config.e2e.ts` — comment บรรทัด 10–12 บอกว่า (#141) e2e ทุกไฟล์ต้องรันทีละไฟล์ต่อ Postgres หนึ่งชุด โดยถือ session advisory lock ก่อนเริ่ม ถ้ามี `pnpm test:e2e` อีกตัวถือ lock อยู่ จะปฏิเสธและบอกชื่อคนถือ — เพราะถ้าปล่อยให้ e2e หลายไฟล์แชร์ Postgres ชุดเดียวกันพร้อมกัน ผลจะไม่ deterministic (ไฟล์หนึ่งลบ tenant ตอนอีกไฟล์กำลังเขียนอยู่)

### 6. In-memory database — ทดสอบเร็วโดยไม่ต้องมีฐานข้อมูลจริง

**In-memory database** (ฐานข้อมูลที่อยู่ใน RAM ไม่เขียนลงดิสก์) คือฐานข้อมูลจริง (SQL ใช้งานได้ครบ) แต่พอโปรแกรมจบ ข้อมูลหายหมด — เหมาะกับ test เพราะ: เร็วมาก (ไม่ต้องรอดิสก์), แต่ละ test สร้างฐานข้อมูลใหม่เอี่ยมได้ในไม่กี่ ms (ไม่ต้องกลัว test ก่อนหน้าทิ้งข้อมูลค้าง)

ฝั่ง Flutter ของร้านนี้ใช้ Drift's `NativeDatabase.memory()` แทน `AppDatabase.open()` (ที่เขียนไฟล์จริงตอนแอปรันจริง) — repository test ทุกไฟล์ใน `frontend/test/*_repository_test.dart` ทำแบบนี้ (ดูตัวอย่างจริงในหัวข้อถัดไป) มันคือ **fake** ตามนิยามข้อ 4 ไม่ใช่ mock: มัน "ทำงานจริง" (SQL จริง, constraint จริง, transaction จริง) แค่เก็บข้อมูลคนละที่กับของจริง

### 7. Testcontainers / service container — เมื่อ in-memory ไม่พอ

ฝั่ง backend มี logic ที่พึ่งพาความสามารถเฉพาะของ **Postgres จริง** (Row-Level Security, advisory lock, `SELECT ... FOR UPDATE` ที่ล็อกแถวจริงข้าม connection) — SQLite ใน memory จำลองพฤติกรรมพวกนี้ไม่ได้เป๊ะ จึงต้องมี **service container** (คอนเทนเนอร์ Docker ที่รันฐานข้อมูล/redis จริงชั่วคราวเฉพาะตอน test) — แนวคิดที่เรียกกันทั่วไปว่า **testcontainers**

`server/test/*.e2e-spec.ts` ทั้ง 53 ไฟล์คุยกับ Postgres+Redis จริง (ผ่าน docker compose ตาม `docs/tutorial/testing-tutorial.md` ข้อ 2.3) ไม่ใช่ของปลอม — เพราะ invariant ที่ทดสอบ (RLS แยก tenant, row lock กันขายเกินสต็อกตอนขายพร้อมกัน) **มีอยู่แค่ในพฤติกรรมจริงของ Postgres เท่านั้น** ทดสอบด้วยของปลอมจะไม่มีทางจับ bug พวกนี้ได้เลย

### 8. Concurrency test — ทดสอบเมื่อหลายคนทำพร้อมกัน

**Concurrency** (การทำงานพร้อมกัน) เป็นเรื่องทดสอบยากที่สุดอย่างหนึ่ง เพราะ bug จากมันมักไม่โผล่ทุกครั้ง (ขึ้นกับจังหวะเวลา) — วิธีทดสอบคือ **บังคับยิงคำขอจำนวนมากพร้อมกันจริงๆ** แล้วเช็คผลรวมสุดท้าย (ไม่ใช่เช็คทีละคำขอ) ร้านนี้มีตัวอย่างที่ชัดเจนมาก ดูหัวข้อ "ของจริงใน repo" ข้อ 8

### 9. Property-based / invariant test

**Property-based test** (ทดสอบด้วยคุณสมบัติ ไม่ใช่ตัวอย่างเดียว) คือแทนที่จะเขียน `expect(f(2,3), 5)` ตัวเดียว เราบอกกฎ (property) ที่ต้องเป็นจริง**เสมอ**ไม่ว่า input จะเป็นอะไร แล้วให้เครื่องมือสุ่ม input จำนวนมากมาทดสอบกฎนั้น เช่น "ผลรวม refund ต้องไม่เกินยอดขายเดิม ไม่ว่าจะคืนกี่ครั้งกี่ลำดับก็ตาม" repo นี้ไม่ได้ใช้ library property-testing โดยตรง (เช่น fast-check/QuickCheck) แต่ **การไล่ทดสอบ edge case ของ invariant ทีละเคส** (เช่น over-refund guard ในข้อ 7 ของ "ของจริงใน repo") ก็คือการพิสูจน์ property เดียวกันแบบ manual — ครอบคลุมน้อยกว่าของสุ่มจริง แต่ตรงเป้ากว่าเพราะเขียนจากเคสที่เคยพังจริง

### 10. Architecture test (fitness function)

**Fitness function** คือ test ที่ไม่ได้เช็ค "ผลลัพธ์ของฟังก์ชัน" แต่เช็ค **"โครงสร้างโค้ด"** เอง — เช่น "ห้ามไฟล์ controller เรียก DataSource ตรงๆ" มันสแกนซอร์สโค้ด (บางทีอ่านเป็น AST — "ต้นไม้โครงสร้างไวยากรณ์" ของโค้ด แทนที่จะรันโค้ดจริง) แล้ว fail ถ้าเจอ pattern ต้องห้าม

ทำไมต้องมี: กฎบางข้อ (เช่น "ทุก endpoint ที่แก้เงิน/สต็อกต้องเปิด transaction ในตัว handler เท่านั้น") ไม่มีทาง**พิสูจน์ด้วย unit test ปกติ**ได้ครบ เพราะ dev คนใหม่เพิ่ม endpoint ใหม่พรุ่งนี้อาจไม่รู้กฎนี้เลย ต้องมีเครื่องช่วยเตือนตอน CI ก่อนจะ merge — repo นี้มี fitness function 3 ไฟล์ (ดูหัวข้อ "ของจริงใน repo" ข้อ 5) ป้องกัน ADR-0003 (การจัดการ transaction/tenancy) ไม่ให้ dev คนไหนแอบทำผิดโดยไม่รู้ตัว

### 11. Contract test

**Contract test** (ทดสอบสัญญาระหว่างสองฝั่ง) คือทดสอบว่า **"ฝั่งหนึ่งใช้งานอีกฝั่งตามกติกาที่ตกลงกันไว้"** โดยไม่ต้องรันทั้งสองฝั่งจริงพร้อมกัน — ร้านนี้มี `frontend/test/api_repository_contract_test.dart` ที่ตรวจว่า "ฝั่ง Flutter ที่คุยกับ server (`ApiRepository`) ต้องไม่แอบเรียกฟังก์ชัน transactional ของ Drift เอง" (ดูรายละเอียดข้อ 6)

### 12. TDD — Red, Green, Refactor

**Test-Driven Development (TDD)** คือลำดับการเขียนโค้ด: **1) เขียน test ที่ล้มก่อน** (Red — เพราะยังไม่มีโค้ดจริง) **2) เขียนโค้ดน้อยที่สุดให้ test ผ่าน** (Green) **3) ปรับโครงโค้ดให้สะอาดขึ้นโดยไม่เปลี่ยนพฤติกรรม** (Refactor — test ยังเขียวตลอด) แล้ววนซ้ำ ข้อดีคือบังคับให้คิด "ต้องการอะไร" ก่อนคิด "เขียนยังไง" repo นี้มี skill `tdd` แยกไว้สำหรับงานใหม่ที่อยากทำแบบนี้ (ดู `.claude/`)

### 13. Coverage — ทำไม 100% ไม่เท่ากับถูก

**Code coverage** (ความครอบคลุม) คือ % ของบรรทัดโค้ดที่ test เคย "รัน" ผ่าน — มันวัดแค่ว่า **บรรทัดถูกรัน** ไม่ได้วัดว่า **ผลลัพธ์ถูกเช็คถูกต้อง**

ตัวอย่างสมมติที่ coverage 100% แต่ไม่มีประโยชน์:

```dart
test('คำนวณราคาหลังลด', () {
  final result = calculateDiscount(100, 0.1);
  // ไม่มี expect() เลย! บรรทัดถูกรันครบ 100% แต่ไม่ได้พิสูจน์อะไร
});
```

coverage สูงบอกได้แค่ "ไม่มีโค้ดที่ไม่เคยถูกแตะเลย" — ไม่บอกว่า assert ที่เขียนไว้ตรงจุดหรือครบ edge case หรือเปล่า repo นี้ไม่ได้บังคับ coverage % ขั้นต่ำ (`docs/tutorial/testing-tutorial.md` ก็ไม่ได้พูดถึงเกณฑ์ coverage) — เน้นที่ "test ตรง invariant ที่เคยพังจริง" (ดูข้อ 14) มากกว่าตัวเลข coverage

### 14. Regression test ต่อทุก bug

**Regression** (การถอยหลังกลับไปเป็นเหมือนเดิม) ในความหมายนี้คือ "bug ที่เคยแก้แล้ว กลับมาอีกครั้งเพราะมีคนแก้โค้ดจุดอื่นโดยไม่รู้ว่ามันกระทบ" — วิธีป้องกันมาตรฐานคือ: **ทุกครั้งที่เจอ bug ให้เขียน test ที่จำลอง bug นั้นก่อน (ต้องเห็นมันแดงจริง) แล้วค่อยแก้ให้เขียว** แล้วเก็บ test นั้นไว้ตลอดไป

repo นี้ทำแบบนี้ชัดมาก — test จำนวนมากมีเลข issue กำกับตรงชื่อ (`#383`, `#384`) หรือใน doc comment เพราะมันคือ **regression test ของ bug ที่เคยเกิดจริง** ไม่ใช่ test ที่เขียนไว้ล่วงหน้าเผื่ออนาคต

---

## 🔥 ปัญหาจริงของร้าน

ร้านนี้ไม่ได้มีนักพัฒนาคนเดียว — มี 3 คน (`NuimanLP`, `LomerAlloys`, `PattaraponKitcharoen`) แก้โค้ดคนละส่วนพร้อมกัน (ดู [13_team_workflow.md](13_team_workflow.md)) และระบบมี invariant ที่ถ้าพัง **เสียเงินจริง**: ขายของเกินสต็อก, คืนเงินเกินยอดขาย, ร้าน tenant หนึ่งเห็นข้อมูลอีก tenant, บิลถูกสร้างซ้ำเพราะเน็ตกระตุก

ถ้าไม่มี test อัตโนมัติ: ทุกครั้งที่มีคนแก้โค้ด ต้องมีคนนั่งเทสมือ (เปิดแอป, ล็อกอิน, ขายของ, เช็คสต็อก) ทุก flow ที่อาจกระทบ — ช้ามาก และคนเทสมือพลาดง่าย (ไม่มีทางจำลอง "200 คนกดขายพร้อมกัน" ด้วยมือได้เลย) นี่คือเหตุผลที่ CI ([15_cicd.md](15_cicd.md)) รัน test พวกนี้อัตโนมัติทุก push/PR — และทำไม `analyze-and-test`/`unit`/`integration` เป็น required check ก่อน merge เข้า `main`

---

## ⚖️ ทางเลือก → ทำไมเลือกอันนี้

| ทางเลือก | ข้อดี | ข้อเสีย | ร้านนี้เลือกอะไร |
|---|---|---|---|
| Unit test ล้วน + mock ทุกอย่างที่ไม่ใช่ตัวเอง | เร็วมาก, isolate ชัด | ไม่จับ bug ที่รอยต่อจริง (กรณี #383 พิสูจน์แล้ว) | ใช้เฉพาะจุดที่ logic แยกขาดจริง (เช่น `weighted-average.spec.ts` คำนวณเลขล้วน) |
| In-memory DB (SQLite/Drift memory) สำหรับทุก test รวม backend | เร็ว, ไม่ต้องมี Docker | ไม่มี RLS/advisory lock/row lock จริงแบบ Postgres | ใช้ฝั่ง Flutter (Drift เป็น SQLite อยู่แล้ว) แต่ **ไม่ใช้ฝั่ง backend** สำหรับ invariant ที่ต้องพึ่ง Postgres จริง |
| Service container (Postgres+Redis จริงชั่วคราว) สำหรับ e2e | จับ bug จริงของ Postgres/Redis ได้ (RLS, lock, timeout) | ช้ากว่า, ต้องมี Docker, ต้อง serialize (ดู #141) | ใช้กับทุกไฟล์ `*.e2e-spec.ts` (53 ไฟล์) เพราะ invariant เงิน/สต็อก/tenant ต้องพิสูจน์กับของจริง |
| Mock cache client เพื่อจำลอง redis ล่ม | เขียนง่าย, เร็ว | ซ่อน bug จริงได้ (ดู #383) | **เลิกใช้** — เปลี่ยนเป็นตัดการเชื่อมต่อจริง (`redis-cache-outage.e2e-spec.ts`) |
| Architecture test (AST scan) สำหรับกฎ tenancy/idempotency | จับ dev คนใหม่ทำผิดกฎโดยไม่รู้ตัว ก่อน merge | เขียนยาก, ต้อง maintain allowlist | ใช้ 3 ไฟล์ (`tenant-door`/`tenant-wrapper`/`idempotency-routes`) เพราะกฎพวกนี้ "unit test ปกติ" จับไม่ได้ |

เหตุผลรวม: **เพราะ invariant ที่แพงที่สุดของร้าน (เงิน, สต็อก, ความเป็นส่วนตัวข้าม tenant) เกิดที่รอยต่อระหว่างชิ้นส่วน → จึงต้องทดสอบที่รอยต่อด้วยของจริงหรือใกล้เคียงของจริงที่สุด → ราคาที่จ่ายคือ e2e ช้ากว่า unit และต้องมี Docker/Postgres ตอน test** (ไม่ใช่แค่ IDE เปล่าๆ)

---

## 🔍 ของจริงใน repo

### 1. Inventory จริง (ตรวจด้วย `find`, 2026-09-25)

```
frontend/test/*.dart          → 65 ไฟล์
server/src/**/*.spec.ts       → 40 ไฟล์ (unit, colocate กับโค้ด)
server/test/*.e2e-spec.ts     → 53 ไฟล์ (integration/e2e, Postgres+Redis จริง)
```

frontend/test/ แบ่งกลุ่มคร่าวๆ:
- **Repository/transactional unit test** (in-memory Drift) — เช่น `sales_repository_test.dart`, `returns_repository_test.dart`, `shifts_repository_test.dart`, `purchase_orders_repository_test.dart` ฯลฯ — ตรง 1:1 กับ invariant ใน `pos/db.js` เดิม (ดู [06_backend.md](06_backend.md))
- **API repository test** (`api_*_repository_test.dart`) — ทดสอบชั้น #56 ที่คุยกับ server แล้ว patch แถว Drift
- **Contract test** — `api_repository_contract_test.dart`, `sync/sync_service_contract_test.dart`
- **Route/widget smoke test** — `route_smoke_test.dart`, `widget_test.dart`, `devices_screen_test.dart` ฯลฯ
- **Schema migration test** — `schema_v1_to_v3_migration_test.dart` ถึง `schema_v7_migration_test.dart`
- **Auth/security/sync/offline** — ที่เหลือ

server/src/**/*.spec.ts (40 ไฟล์) คือ unit spec ที่**อยู่ข้างไฟล์โค้ดจริงในโฟลเดอร์เดียวกัน** (เช่น `server/src/purchasing/weighted-average.spec.ts` อยู่ข้าง `weighted-average.ts`) — สะดวกต่อการหาว่าไฟล์ไหนมี test คู่ ส่วน `server/test/*.e2e-spec.ts` (53 ไฟล์) แยกโฟลเดอร์ต่างหากเพราะต้องใช้ Postgres+Redis จริง

### 2. Vitest configs — สอง config คนละหน้าที่

`server/vitest.config.ts` — `include: ['**/*.spec.ts']`, `globals: true` (ใช้กับ unit spec ใน `src/`)

`server/vitest.config.e2e.ts` — `include: ['**/*.e2e-spec.ts']`, `fileParallelism: false` (ห้ามรันหลายไฟล์พร้อมกัน), `testTimeout: 60_000` — comment ในไฟล์ (บรรทัด 10–12) อธิบายว่า:

> "#141: one run per Postgres. Takes a session advisory lock before any file starts and refuses to start, naming the holder, if another `pnpm test:e2e` has it."

และ (บรรทัด 19): "The sale-concurrency case fires 200 requests at once and is slow by design." — ยืนยันว่า timeout 60 วิ ตั้งใจให้พอสำหรับ test concurrency ในข้อ 8 ด้านล่าง

### 3. Architecture test 3 ไฟล์ — ปกป้อง ADR-0003 (transaction/tenancy)

**`server/src/common/tenant-door.spec.ts:185`**

```ts
describe('the tenant door (ADR-0003, tx.1 #150)', () => {
```

ไฟล์นี้**ไม่ได้รันโค้ด backend เลย** — มันอ่านซอร์สโค้ด `.ts` ทุกไฟล์ใน production แล้วเช็คว่า **มีแค่ไฟล์ที่อยู่ใน allowlist เท่านั้นที่จับ `DataSource`/pool มาใช้เองตรงๆ** (`tenant-door.spec.ts:257`, `it('only allowlisted files reach for a DataSource of their own')`) เหตุผล (doc comment บรรทัด 21–34): การ query DataSource ตรงๆ โดยไม่ผ่านกลไก tenant ที่ถูกต้อง จะได้ผลลัพธ์ **"200 กับแถวว่างเปล่า"** ภายใต้ RLS (Row-Level Security) — คือแอปดูเหมือนทำงานปกติ (status 200) แต่ข้อมูลหายไปเงียบๆ ไม่มี test endpoint ไหนจับได้เลยเพราะมันไม่ error

**`server/src/common/tenant-wrapper.spec.ts:75`**

```ts
describe('every request-context reader opens its own runTx (tx.2 #151)', () => {
```

ใช้ TypeScript compiler API สแกน AST เช็คว่า **ทุก method ที่แตะ `currentRequestContext()`** (ทั้งเรียกตรงหรือผ่าน private helper) ต้องมีรูปแบบ `return this.tenants.runTx(() => this.<name>In(...))` เท่านั้น — assertion จริง (บรรทัด 103–114):

```ts
it('finds no unwrapped reader outside the allowlist, and no stale allowlist entry', () => {
  ...
  expect(found.filter((m) => !(m in UNWRAPPED_ALLOWED))).toEqual([]);
```

**`server/src/idempotency/idempotency-routes.spec.ts:129`**

```ts
describe('idempotent routes claim first, with the status they send (tx.3 #152)', () => {
```

สแกน controller ทุกตัวเช็คว่า route ที่ควรกัน "บิลซ้ำ" (idempotent route) ต้องมี handler ทั้งก้อนเป็น `return this.idempotency.runIdempotent(idempotencyParamsOf(req, <code>), res, ...)` เท่านั้น — test ที่ใหญ่สุด (บรรทัด 214, `it('every idempotent route claims first and stores the status it declares')`) ตรึงจำนวนไว้ **38 routes** (comment บรรทัด 225–226 บอกว่า 37 ตัว live จริง อีก 1 ตัว `PurchasingController` ไม่ได้ถูก register ใน module ไหนเลย — dead code ที่รอตามแก้) ยังมี test แยก (บรรทัด 274) เช็คว่า `POST /sync/push` map แต่ละ op type ไปยัง endpoint จริงถูกต้อง

**ทำไมทั้ง 3 ไฟล์นี้สำคัญมาก:** กฎแบบ "ต้องเปิด transaction ในตัว handler เท่านั้น" (CLAUDE.md หัวข้อ "Transactions & tenancy") เป็นกฎที่ **compiler ปกติเช็คให้ไม่ได้** — dev คนใหม่เพิ่ม endpoint พรุ่งนี้อาจลืมกฎนี้โดยไม่มีเจตนา ถ้าไม่มี architecture test คอย fail CI ตอน merge กฎนี้จะถูกละเมิดแบบเงียบๆ ทีละนิด CLAUDE.md เขียนไว้ตรงๆ ว่า **"change them deliberately, never just to turn them green"** — ถ้า test พวกนี้แดง ห้ามแก้ test ให้ผ่านง่ายๆ โดยไม่เข้าใจว่าทำไมมันแดง เพราะนั่นคือสัญญาณว่ากฎ tenancy กำลังถูกละเมิด

### 4. `api_repository_contract_test.dart` — contract test ฝั่ง Flutter

Path: `frontend/test/api_repository_contract_test.dart` — doc comment ต้นไฟล์ (บรรทัด 1–13):

> "#56 AC6: 'No ApiRepository in this slice calls a Drift transactional service — enforced by a test.' ... ADR-0010 §3's rule is that an ApiRepository hits the server and then patches Drift rows from the response; it must NEVER also call one of the Drift *transactional services* (`saveSale`, `createReturn`, `openShift`, `addDrawerEntry`, `closeShift`, `receivePO`) ... the concrete failure mode is a DOUBLE STOCK DECREMENT"

**bug ที่มันป้องกัน อธิบายง่ายๆ:** ถ้า `ApiRepository` (ชั้นที่คุยกับ server) แอบเรียก Drift transactional service ของตัวเองด้วย จะเกิด "ลดสต็อก 2 รอบ" (รอบที่ server ลด + รอบที่ Drift local ลดเอง) — ขายไป 1 ชิ้น สต็อกลด 2 test นี้สแกนซอร์สโค้ดหา pattern การเรียกที่ต้องห้าม มี self-check ของตัวเองด้วย (เช่น `self-check: the matcher actually catches a violation` บรรทัด 252) เพื่อพิสูจน์ว่า matcher เองไม่ใช่แค่ผ่านมั่วๆ

### 5. Drift repository unit test — สต็อกไม่พอ / คืนเกิน

**`frontend/test/sales_repository_test.dart:62`** — `test('insufficient stock throws Thai message and leaves data unchanged', ...)`:

```dart
await expectLater(
  repo.saveSale(input),
  throwsA(
    predicate(
      (e) =>
          e.toString().contains('สต็อกไม่พอ:\n') &&
          e.toString().contains('Piston Kit STD: สต็อก 5 แต่ต้องการ 6'),
    ),
  ),
);
// Stock unchanged, no sale recorded (transaction never started — but assert anyway).
final after = await product('p8');
expect(after.stock, 5);
final sales = await repo.getSales();
expect(sales, isEmpty);
```

จุดสำคัญ: assert ไม่ได้เช็คแค่ "throw error" — เช็คด้วยว่า **สต็อกไม่ถูกแก้เลย** (`after.stock, 5` เท่าเดิม) และ **ไม่มีบิลถูกบันทึก** — เพราะกฎของ `saveSale` คือ pre-validate ก่อนเข้า transaction เลย (ดู [06_backend.md](06_backend.md)/[07_database.md](07_database.md)) ถ้าแค่เช็คว่า throw error แต่ไม่เช็คว่าไม่มี side-effect ค้าง จะพลาด bug แบบ "throw หลังเขียนไปแล้วครึ่งหนึ่ง" ได้

**`frontend/test/returns_repository_test.dart:122`** — `test('over-refund throws with Thai message (qty exceeds sold)', ...)`:

```dart
expect(
  () => repo.createReturn(
    const ReturnInput(
      saleId: 's_over',
      items: [ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 5, price: 85)],
      refundMethod: 'เงินสด',
    ),
  ),
  throwsA(
    predicate(
      (e) =>
          e.toString().contains('คืนเกินจำนวนที่ขาย:') &&
          e.toString().contains('Oil Filter: คืนได้อีก 2 แต่ขอคืน 5'),
    ),
  ),
);
// No partial write — stock unchanged, no return persisted.
final after = await (db.select(db.products)..where((p) => p.id.equals('p1'))).getSingle();
expect(after.stock, before.stock);
expect(await repo.getReturns(), isEmpty);
```

เคสนี้คือกฎ "over-refund guard" จาก CLAUDE.md (`qty ≤ sold − already-refunded`) — ลูกค้าซื้อไป 5 ชิ้น คืนไปแล้ว 3 ชิ้น เหลือคืนได้อีกแค่ 2 ถ้าขอคืน 5 ต้องถูกปฏิเสธพร้อมข้อความไทยที่บอกจำนวนที่คืนได้จริง ("คืนได้อีก 2 แต่ขอคืน 5") — และเหมือนเคสก่อนหน้า assert เช็คด้วยว่าไม่มี partial write ค้างอยู่

ทั้งสอง test นี้ใช้ Drift `NativeDatabase.memory()` (ข้อ 6 ในปูพื้นฐาน) — ฐานข้อมูลใหม่เอี่ยมทุก test, ไม่มี test ก่อนหน้าทิ้งข้อมูลค้างมากวนกัน

### 6. Concurrency DoD — "200 บิลพร้อมกัน บนสต็อก 50 → ได้ 50 บิลเป๊ะ"

**`server/test/sales.e2e-spec.ts:581`**:

```ts
it('200 concurrent bills against 50 units yield exactly 50 bills and zero stock', async () => {
  await seedProduct(admin, TENANT, {
    id: 'hot', partNo: 'HOT-1', name: 'Hot Part', price: 100, cost: 60, stock: 50,
  });

  const attempts = Array.from({ length: 200 }, () =>
    post(bill([{ productId: 'hot', name: 'Hot Part', qty: 1, price: '100.00' }])),
  );
  // `allSettled`, not `all`: a rejection would leave the other 199 requests still in
  // flight, writing rows into a tenant the next test's `resetTenant` is already
  // deleting — a foreign-key error in the fixture, pointing nowhere near the cause.
  const settled = await Promise.allSettled(attempts);
  const failed = settled.filter((r) => r.status === 'rejected');
  expect(failed).toEqual([]);
  const results = settled.map((r) => (r as PromiseFulfilledResult<Response>).value);

  const created = results.filter((r) => r.status === 201);
  const refused = results.filter((r) => r.status === 409);
  expect(created).toHaveLength(50);
  expect(refused).toHaveLength(150);
  for (const r of refused) expect(r.body.error.code).toBe('INSUFFICIENT_STOCK');

  expect(await stockOf('hot')).toBe(0);
  const rows = await admin.query(
    `SELECT count(*)::int AS n FROM sale_items WHERE tenant_id = $1::uuid AND product_id = 'hot'`,
    [TENANT],
  );
  expect(rows[0].n).toBe(50);

  const numbers = created.map((r) => r.body.data.receiptNo);
  expect(new Set(numbers).size).toBe(50);
}, 60_000);
```

**อธิบาย:** ยิง `POST /sales` 200 ครั้ง**พร้อมกันจริง** (ไม่ใช่ทีละคำขอ) เข้าสินค้าที่มีสต็อกแค่ 50 ชิ้น ถ้าระบบล็อกแถวไม่ถูกต้อง (เช่น อ่านสต็อกแล้วค่อยลด โดยไม่ล็อก) จะเกิด **race condition**: หลายคำขออ่านสต็อกเห็นค่าเดิมพร้อมกัน แล้วต่างก็คิดว่า "ยังพอ" → ขายเกิน 50 บิลได้ (สต็อกติดลบ) test นี้พิสูจน์ว่า**ไม่เกิด** — assert สำคัญ 3 จุด: ได้ 201 (สำเร็จ) เป๊ะ 50 ครั้ง, ได้ 409 (ปฏิเสธ `INSUFFICIENT_STOCK`) เป๊ะ 150 ครั้ง, และนับแถวจริงใน `sale_items` ได้ 50 แถวเป๊ะ (ไม่ใช่แค่เชื่อค่าที่ response ตอบ — เผื่อ response โกหก) ใช้ `Promise.allSettled` ไม่ใช่ `Promise.all` เพราะ comment ในโค้ดอธิบายไว้ตรงๆ ว่าอยากเห็น**ทุกคำขอ**เสร็จก่อน (ไม่ใช่ล้มเลิกตั้งแต่ตัวแรก reject) ไม่งั้น 199 ตัวที่เหลือจะยังค้างเขียนข้อมูลตอน test ถัดไปเริ่มลบ tenant — กลายเป็น flaky test ที่ error ผิดจุด

ยังมี test เล็กกว่าที่วัดจังหวะ pool แยกต่างหาก: `server/test/tx-hold-measure.e2e-spec.ts:189` — `it('4 concurrent POST /sales at DB_POOL_SIZE=2 (no argon2 on the path)', ...)` — คนละจุดประสงค์ (วัดว่า pool ไม่ deadlock ที่ concurrency น้อยกว่านี้) ไม่ใช่ตัวเดียวกับ DoD 200/50

### 7. `redis-cache-outage.e2e-spec.ts` (#383) — สองแบบของ "ต่อไม่ติด"

Doc comment ต้นไฟล์ (`server/test/redis-cache-outage.e2e-spec.ts:16-29`) อธิบายที่มาตรงกับหัวข้อปูพื้นฐานข้อ 4 (mock ซ่อน bug):

> "Two real failure shapes, both without touching a line of `cache`/`TenantCache`: 'refused': `REDIS_CACHE_URL` points at a port nothing listens on. 'hung': a real TCP server that finishes the ioredis handshake ... and then answers nothing — the #140 case"

**โหมด 1 — connection refused** (`redis-cache-outage.e2e-spec.ts:137`):

```ts
describe('redis-cache unreachable: connection refused (e2e, #383)', () => {
```

ตั้ง `REDIS_CACHE_URL` ชี้ไป port ที่**ไม่มีอะไรฟังอยู่จริง** (`closedPort()` เปิด port ชั่วคราวแล้วปิดทันที รับประกันว่าไม่มีใครใช้) → ทุกคำสั่งที่ ioredis ยิงจะ reject ด้วย `ECONNREFUSED` ทันที (`enableOfflineQueue: false` ทำให้ไม่รอ queue)

**โหมด 2 — ต่อติดแต่เงียบจนกว่าจะ timeout** (`redis-cache-outage.e2e-spec.ts:201`):

```ts
describe('redis-cache unreachable: connected but silent until timeout (e2e, #140/#383)', () => {
```

สร้าง TCP server จริง (`fakeRedis()`) ที่ตอบ handshake ของ ioredis จนไคลเอนต์เชื่อว่า **"ready"** แล้ว**เงียบไปเลย** — จำลอง redis ที่ "ค้าง" ไม่ใช่ "ตายทันที" (ต่างจากโหมด 1) และตั้ง `REDIS_COMMAND_TIMEOUT_MS = '300'` ให้สั้นลง (ปกติ default 1000ms) เพื่อไม่ให้ test ทั้งไฟล์ช้าเกิน

ทั้งสองโหมดเรียก assertion เดียวกัน (`it('an active tenant still sells for real, and a suspended tenant is rejected at once', ...)` ที่บรรทัด 191 กับ 261) — เช็คว่า `GET /products` + `POST /sales` (ลดสต็อกจริง) ยังทำงานได้สำหรับ tenant ปกติ ขณะที่ tenant ที่ `suspended` ยังถูกปฏิเสธทันที **แม้ redis-cache ต่อไม่ติดจริงทั้งสองแบบ**

### 8. `shifts.e2e-spec.ts:562` (#384) — retire/enrol ของจริง

`server/test/shifts.e2e-spec.ts` มี 752 บรรทัด — บรรทัด 562 อยู่ใน `it('a replacement pos device starts clean after the old one is retired', ...)` (เริ่มบรรทัด 559) ก่อนหน้านี้ (ก่อนแก้ #384) test เคยข้ามขั้น "enrol" ไปเลยด้วยการ `mint` accessToken ปลอมตรงๆ — ของจริงตอนนี้ (บรรทัด 583–590):

```ts
// #384: the real enrol path — exchange the code for a device token, then log in
// with it, instead of minting an accessToken({...}) that skips enrol entirely.
const enrol = await request(app.getHttpServer())
  .post('/api/v1/auth/device')
  .send({ code: enrolCode });
expect(enrol.status).toBe(200);
const deviceToken: string = enrol.body.data.deviceToken;

// enrolCode is single-use: replaying it must be refused, not silently accepted.
const replay = await request(app.getHttpServer())
  .post('/api/v1/auth/device')
  .send({ code: enrolCode });
expect(replay.status).toBe(401);
```

**บทเรียน:** test เดิมที่ "mint token ปลอมตรงๆ" ก็เป็นตัวอย่างของ "mock ผิดที่" อีกแบบหนึ่ง (คล้าย #383) — มันข้ามขั้น `/auth/device` ทั้งหมด ทำให้ไม่เคยพิสูจน์ว่า enrol code ใช้ครั้งเดียวจริง (`replay` ต้องได้ 401) ของจริงตอนนี้เดินผ่าน endpoint จริงทุกขั้น ก่อนหน้านั้นในเทสเดียวกัน (บรรทัด 546–556) ยังพิสูจน์ว่า access token เก่าของเครื่องที่ถูก retire ไปแล้ว **เปิดลิ้นชักเงินใหม่ไม่ได้** (403 `DEVICE_ROLE_FORBIDDEN`)

### 9. CI รันตรงไหนบ้าง

CI/CD เต็มๆ อยู่ที่ [15_cicd.md](15_cicd.md) บทนี้แค่สรุปว่า test ที่พูดถึงในบทนี้ตกไปอยู่ job ไหน:

| ไฟล์ทดสอบ | job ใน workflow | เชื่อมกับอะไร |
|---|---|---|
| `frontend/test/*.dart` | `analyze-and-test` (flutter.yml) | ไม่ต้องมี Docker |
| `server/src/**/*.spec.ts` (รวม 3 architecture spec) | `unit` (server.yml) | ไม่ต้องมี Postgres จริง |
| `server/test/*.e2e-spec.ts` | `integration` (server.yml) — [15_cicd.md](15_cicd.md) เรียกว่า "ด่านที่แพงที่สุด และไม่มีวันถูกข้าม" | ต้องมี Postgres+Redis จริง (docker compose) |

---

## 🛠️ เทคนิคในบทนี้

### เทคนิค: In-memory database ทดสอบ transactional repository

**คืออะไร:** ใช้ Drift's `NativeDatabase.memory()` แทนไฟล์ SQLite จริง — ฐานข้อมูล SQL ที่ทำงานได้จริงทุกอย่างแต่เก็บใน RAM (analogy: กระดานไวท์บอร์ดที่ลบง่าย แทนสมุดบันทึกถาวร)

**ปัญหาที่มันแก้:** ถ้า test ต้องเขียนไฟล์ SQLite จริงทุกครั้ง จะช้า (I/O ดิสก์) และต้องคอยลบไฟล์ทิ้งหลัง test ไม่งั้น test ถัดไปเห็นข้อมูลเก่าค้าง (ไม่ deterministic) — 65 ไฟล์ test ของ Flutter จะรันช้าลงมากถ้าทุกไฟล์ต้องแตะดิสก์จริง

**ทำไมเลือกท่านี้:** เทียบกับการ mock ทุก method ของ database (stub การอ่าน/เขียนทีละฟังก์ชัน) — in-memory DB ให้ผลตรงกว่าเพราะ SQL constraint จริง (foreign key, unique) ยังทำงาน จับ bug เรื่อง schema ได้ ในขณะที่ mock ทีละ method ต้องคอยเดาว่า "ฐานข้อมูลจริงจะตอบยังไง" เอง

**ดียังไง / ราคาที่จ่าย:** เร็ว, isolate ทุก test 100% (ไม่มีทางรั่วข้ามไฟล์) — ราคาคือมันยังเป็น SQLite ไม่ใช่ Postgres ดังนั้นพฤติกรรมเฉพาะของ Postgres (RLS, advisory lock) ทดสอบด้วยวิธีนี้ไม่ได้ ต้องใช้ e2e กับ Postgres จริงแทน (ดูข้อถัดไป)

**อยู่ตรงไหนใน repo:** ทุกไฟล์ `frontend/test/*_repository_test.dart` (เช่น `sales_repository_test.dart:1-30` ช่วง setup เรียก `NativeDatabase.memory()`)

### เทคนิค: Testcontainers/service container สำหรับ e2e

**คืออะไร:** รัน Postgres+Redis จริงในคอนเทนเนอร์ Docker ชั่วคราวเฉพาะตอน test (analogy: เช่าร้านจำลองเปิดวันเดียวเพื่อซ้อมพนักงานใหม่ แทนที่จะฝึกในร้านจริงที่มีลูกค้าอยู่)

**ปัญหาที่มันแก้:** RLS, advisory lock, `SELECT FOR UPDATE`, connection pool behavior — พฤติกรรมพวกนี้มีเฉพาะใน Postgres จริง ไม่มีทางจำลองด้วย in-memory DB ธรรมดา ถ้าทดสอบด้วยของปลอม test ที่บอกว่า "RLS กันข้าม tenant ได้" จะไม่มีความหมายอะไรเลย

**ทำไมเลือกท่านี้:** เทียบกับการ mock query layer ทั้งชั้น — service container พิสูจน์ SQL จริงที่รันจริง ไม่ใช่แค่ "โค้ดเรียก query ที่คาดว่าจะถูก"

**ดียังไง / ราคาที่จ่าย:** จับ bug ที่รอยต่อจริงได้ (เช่น 200-concurrent test ในข้อ 6) — ราคาคือช้ากว่า unit มาก และต้อง serialize การรัน (ดู #141 — `fileParallelism: false`) เพราะสอง e2e-file รัน Postgres ชุดเดียวกันพร้อมกันจะชนกันเอง

**อยู่ตรงไหนใน repo:** `server/vitest.config.e2e.ts` (ทั้งไฟล์), ทุกไฟล์ `server/test/*.e2e-spec.ts` (53 ไฟล์)

### เทคนิค: Architecture test / fitness function ด้วย AST scan

**คืออะไร:** test ที่อ่านซอร์สโค้ดเป็น**โครงสร้าง** (AST — ต้นไม้ที่ตัวแปลภาษาใช้ก่อนรันจริง) แล้วเช็ค pattern ต้องห้าม/ต้องมี แทนที่จะรันโค้ดแล้วเช็คผลลัพธ์ (analogy: ตรวจแบบแปลนบ้านก่อนสร้าง แทนที่จะรอบ้านสร้างเสร็จแล้วค่อยดูว่าท่อน้ำเดินผิด)

**ปัญหาที่มันแก้:** กฎ "ทุก handler ที่แตะ tenant context ต้องห่อด้วย `runTx` แบบนี้เท่านั้น" เป็นกฎเชิงโครงสร้าง ไม่ใช่กฎเชิงผลลัพธ์ — รัน handler ผิดกฎอาจยัง**ตอบถูก**ในเคสทดสอบทั่วไป (เพราะ tenant เดียวในฐานข้อมูล test) แต่พังจริงเมื่อมีหลาย tenant พร้อมกันใน production unit test ปกติจับไม่ได้เพราะมันเช็คแค่ input→output ไม่เช็คว่า "เขียนโค้ดแบบไหน"

**ทำไมเลือกท่านี้:** เทียบกับการพึ่ง code review อย่างเดียว — คนรีวิวอาจพลาด (โดยเฉพาะกฎที่ subtle อย่าง "second pool connection ทำให้ deadlock" #162) AST scan ไม่มีวันลืมเช็ค เพราะมันรันทุกครั้งใน CI

**ดียังไง / ราคาที่จ่าย:** ป้องกัน bug เชิงโครงสร้างที่แพงมากถ้าเกิด (deadlock ทั้ง pool, ข้อมูลรั่วข้าม tenant) แบบอัตโนมัติ 100% — ราคาคือเขียนยาก (ต้องรู้ TypeScript compiler API), ต้อง maintain allowlist เอง และถ้า refactor โครงสร้างไฟล์ใหญ่ๆ architecture test มักพังก่อนเสมอ (แต่นั่นคือจุดประสงค์ของมัน)

**อยู่ตรงไหนใน repo:** `server/src/common/tenant-door.spec.ts`, `server/src/common/tenant-wrapper.spec.ts`, `server/src/idempotency/idempotency-routes.spec.ts`

### เทคนิค: Concurrency test ด้วย `Promise.allSettled`

**คืออะไร:** ยิง request จำนวนมาก "พร้อมกันจริง" ในโค้ดเดียวกัน (ไม่ใช่ loop แบบ await ทีละตัว) แล้วรอให้**ทุกตัว**เสร็จก่อนเช็คผลรวม

**ปัญหาที่มันแก้:** ถ้า test แค่ยิงทีละคำขอ (sequential) จะไม่มีทางเห็น race condition เลย เพราะแต่ละคำขอเสร็จสมบูรณ์ก่อนคำขอถัดไปเริ่ม — race condition เกิดเฉพาะตอนสองคำขอ**ทับเวลากันจริง**

**ทำไมเลือกท่านี้:** เทียบกับ `Promise.all` (ถ้าตัวใดตัวหนึ่ง reject จะโยน error ทันทีโดยไม่รอตัวอื่น) — `allSettled` รอทุกตัวจบก่อนเสมอ ป้องกัน test ถัดไปเจอข้อมูลเขียนค้างจากคำขอที่ "ยังลอยอยู่" (ตามที่ comment ในโค้ดอธิบายไว้ตรงๆ)

**ดียังไง / ราคาที่จ่าย:** พิสูจน์ concurrency invariant ได้จริง — ราคาคือ test ช้า (ต้องรอ 200 request จริงตอบกลับ, ตั้ง timeout 60 วิ) และ debug ยากกว่าปกติถ้าแดง (ต้องดูว่า assertion ไหนใน 6 จุดพัง)

**อยู่ตรงไหนใน repo:** `server/test/sales.e2e-spec.ts:581-616`

### สรุปตาราง

| เทคนิค | แก้ปัญหาอะไร | ราคาที่จ่าย | file |
|---|---|---|---|
| In-memory DB (`NativeDatabase.memory()`) | test ช้า/ไม่ deterministic เพราะแตะดิสก์จริง | ไม่มี RLS/lock จริงแบบ Postgres | `frontend/test/*_repository_test.dart` |
| Service container (Postgres+Redis จริง) | in-memory จำลองพฤติกรรม Postgres เฉพาะทางไม่ได้ | ช้า, ต้อง Docker, ต้อง serialize | `server/test/*.e2e-spec.ts`, `server/vitest.config.e2e.ts` |
| Architecture test (AST scan) | กฎเชิงโครงสร้างที่ unit test ธรรมดาจับไม่ได้ | เขียนยาก, ต้อง maintain allowlist | `tenant-door.spec.ts`, `tenant-wrapper.spec.ts`, `idempotency-routes.spec.ts` |
| Concurrency test (`Promise.allSettled`) | race condition โผล่เฉพาะตอนคำขอทับเวลากันจริง | ช้า, debug ยากตอนแดง | `server/test/sales.e2e-spec.ts:581` |
| ตัดการเชื่อมต่อจริงแทน mock | mock ที่ขอบเขตทดสอบซ่อน bug จริง (#383) | ต้องเขียน fake TCP server เอง | `server/test/redis-cache-outage.e2e-spec.ts` |

---

## 📚 Tech stack ของบทนี้

| เครื่องมือ | version จริงจาก repo | หน้าที่ | ทำไมเลือก | ทางเลือกที่ไม่เลือก |
|---|---|---|---|---|
| `flutter_test` (built-in) | Flutter 3.44.3 / Dart 3.12.2 (ตรวจจริงด้วย `flutter --version`) | รัน 65 ไฟล์ test ฝั่ง Flutter | มากับ Flutter SDK อยู่แล้ว ไม่ต้องติดตั้งเพิ่ม | — |
| Drift `NativeDatabase.memory()` | ตาม `drift` ที่ pub-lock (ดู [04_frontend.md](04_frontend.md)) | ฐานข้อมูล in-memory สำหรับ repository test | เร็ว, deterministic, SQL จริง | mock query layer ทีละ method |
| Vitest | ตาม `server/package.json` (ดู [06_backend.md](06_backend.md) สำหรับ version เต็ม) | runner ของ 40 unit spec + 53 e2e spec | เร็วกว่า Jest บน ESM/TypeScript, config แยก unit/e2e ได้ง่าย | Jest |
| supertest | ใช้ใน `*.e2e-spec.ts` (เช่น `shifts.e2e-spec.ts`) | ยิง HTTP request จริงเข้า NestJS app ที่รันในหน่วยความจำ | ทดสอบผ่าน HTTP layer จริง ไม่ข้าม middleware/guard | เรียก controller method ตรงๆ (ข้าม HTTP layer ไปเลย ไม่สมจริง) |
| TypeScript compiler API | ใช้ตรงใน `tenant-wrapper.spec.ts`/`idempotency-routes.spec.ts` | parse โค้ดจริงเป็น AST เพื่อสแกน pattern | แม่นกว่า regex เพราะเข้าใจโครงสร้างไวยากรณ์จริง | regex string matching (เปราะ, false positive/negative ง่าย) |
| docker compose (Postgres+Redis) | ตาม `docs/tutorial/testing-tutorial.md` ข้อ 2.3 | service container สำหรับ e2e | ใกล้เคียง production จริงที่สุด | Postgres แบบ mock/in-memory (ไม่มีจริงสำหรับ Postgres) |

---

## ⚠️ บทเรียนจากของจริง

**#383 — mock ที่ผิดที่ซ่อน bug** (อธิบายละเอียดในปูพื้นฐานข้อ 4 และของจริงข้อ 7): test เดิมใน `tenant-scope.e2e-spec.ts` mock method ของ cache client เอง พิสูจน์ได้แค่ "catch ทำงาน" ไม่ใช่ "แอปรอดจาก redis จริงล่ม" แก้เป็นตัดการเชื่อมต่อจริง 2 แบบใน `redis-cache-outage.e2e-spec.ts` (2026-09-22)

**#384 — test ที่ข้ามขั้นตอนจริงไปเลย**: test เดิมของ retire/enrol เคย mint accessToken ตรงๆ ข้ามขั้น `/auth/device` ทั้งหมด → ไม่เคยพิสูจน์ว่า enrol code ใช้ครั้งเดียวจริง (replay ต้องโดน 401) แก้ให้เดินผ่าน endpoint จริงทุกขั้นที่ `shifts.e2e-spec.ts:562`

**"ใช้ fake เฉพาะของฝั่งตัวเอง" (09 §10, phase-2 lane split):** เมื่อ lane B กับ lane C พัฒนา on-device engine กับ server แยกกันคนละสัปดาห์ กติกาคือแต่ละฝั่ง **ทดสอบกับ fake ของตัวเอง** (`FakeSyncFacade`, fixture JSON ใน `docs/Backend_design/fixtures/sync-push/`) ไม่ใช่รอให้อีกฝั่งพร้อมค่อยทดสอบจริง — เหตุผลคือถ้ารอ integration จริงก่อน ทั้งสอง lane จะบล็อกกันเอง (blocked-by ข้ามเลนเป็นเรื่องต้องห้ามตาม CLAUDE.md) สัญญา (contract) ระหว่างสองฝั่งต้องตกลงไว้ก่อนล่วงหน้าเป็น fixture ที่ทั้งคู่เห็นตรงกัน — แต่นี่หมายความว่า **AC ของ ticket ห้ามอ้างว่า "ทำงานกับของจริงแล้ว" ตราบใดที่อีกฝั่งยังไม่ merge** (กฎจาก CLAUDE.md หัวข้อ Phase 2)

**"ห้ามอ้าง `--check` เป็นหลักฐาน":** ไม่เกี่ยวกับ test โดยตรง แต่หลักการเดียวกัน — CLAUDE.md เตือนว่า `ansible-playbook deploy.yml --check` "พิสูจน์ได้แทบไม่มีอะไรเลย" เพราะ `ansible.builtin.command` ไม่มี check mode เลยถูกข้าม แล้ว pre-flight assertion ถัดไปก็ fail บน output ว่างเปล่า — อ่านเผินๆ เหมือนภัยพิบัติทั้งที่ยังไม่ได้รันจริงด้วยซ้ำ นี่คือรูปแบบเดียวกับ #383: **การรันแบบ "จำลอง" ที่ดูเหมือนพิสูจน์อะไรบางอย่าง แต่จริงๆ ข้ามจุดสำคัญไปหมด** — ไม่ว่าจะเป็น test mock ผิดที่ หรือ deploy dry-run ที่ไม่ได้ dry-run จริง บทเรียนเดียวกัน: ถ้าอยากพิสูจน์ว่า "ของจริงทำงาน" ต้องทำให้มันเกิดขึ้นจริง ไม่ใช่จำลองเฉพาะผิวๆ

---

## รันจริงให้ดู (subset เล็กๆ)

Toolchain ที่มีในเครื่องนี้ (ตรวจ 2026-09-25): `flutter --version` ใช้ได้ (Flutter 3.44.3, Dart 3.12.2) — `pnpm --version` ใช้ได้ (10.34.5) **แต่** `server/node_modules` ไม่มีอยู่ในเครื่องนี้ (ต้อง `pnpm install` ก่อนถึงจะรัน vitest ได้) เพื่อไม่ให้ต้องติดตั้งอะไรเพิ่มระหว่างเขียนบทนี้ จึงรันแค่ฝั่ง Flutter (มี toolchain ครบอยู่แล้ว) และ**ไม่รัน server e2e เลย** (ต้องมี Docker + Postgres จริง อยู่นอกขอบเขตของบทนี้)

รันจริง:

```
cd frontend && flutter test test/sales_repository_test.dart
```

ผลลัพธ์จริง (ตัดส่วน "resolving dependencies" ยาวๆ ออก):

```
00:00 +0: loading .../frontend/test/sales_repository_test.dart
00:00 +0: costAtSale snapshots product cost and survives a later cost change
00:00 +1: insufficient stock throws Thai message and leaves data unchanged
00:00 +2: missing product throws ไม่พบในสต็อก and records nothing
00:00 +3: good sale decrements stock exactly and sets points/receiptNo
00:00 +4: customer sale increases points + totalSpend
00:00 +5: mechanic credit sale increases creditBalance by total
00:00 +6: mechanic non-credit sale with markup: no creditBalance, markup added
00:00 +7: getSales returns newest first
00:02 +8: getRefundedQty sums ReturnItems across returns for a sale
00:02 +9: All tests passed!
```

9 test ผ่านหมดใน ~2 วินาที (ไม่รวมเวลา resolve dependency ตอนแรก) — สังเกตว่า test #1 ("insufficient stock throws Thai message and leaves data unchanged") คือ test เดียวกับที่ยกมาอธิบายในข้อ 5 ของ "ของจริงใน repo" ด้านบน

สำหรับคำสั่งรัน server unit/e2e เต็มรูปแบบ (ต้อง `pnpm install` + docker compose ก่อน) ดู `docs/tutorial/testing-tutorial.md` ข้อ 2.2–2.3 — บทนี้ไม่ขอพิมพ์ซ้ำ

---

## ✅ สรุป

- Test คือ Arrange/Act/Assert — เช็คว่าโค้ดทำงานตามที่คาด และจับ bug ให้เจอเร็วที่สุดเท่าที่จะเป็นไปได้ (ยิ่งเจอช้า ยิ่งแก้แพง)
- Test pyramid เน้น unit เยอะสุด, testing trophy เน้น integration เยอะสุด — repo นี้เอียงไปทาง trophy (e2e 53 ไฟล์ > unit spec 40 ไฟล์ฝั่ง server) เพราะ invariant สำคัญอยู่ที่รอยต่อกับ Postgres จริง
- test double มี 5 แบบ (dummy/stub/fake/mock/spy) — mock ที่ mock "ผิดขอบเขต" (ตรงจุดที่กำลังทดสอบ invariant พอดี) ซ่อน bug ได้ ดังที่เกิดจริงกับ #383 (redis-cache mock) และ #384 (accessToken mint ข้ามขั้น enrol)
- In-memory DB (Drift `NativeDatabase.memory()`) ใช้กับ repository test ฝั่ง Flutter — เร็วและ deterministic แต่ไม่ทดแทน Postgres จริงสำหรับ RLS/lock
- Service container (Postgres+Redis จริงใน Docker) ใช้กับ e2e ฝั่ง server ทั้ง 53 ไฟล์ เพราะ invariant เงิน/สต็อก/tenant พิสูจน์ด้วยของปลอมไม่ได้
- Architecture test (fitness function) 3 ไฟล์สแกน AST ปกป้องกฎ ADR-0003 ที่ unit test ปกติจับไม่ได้ — "เปลี่ยนอย่างตั้งใจ ห้ามแก้แค่ให้ผ่าน"
- Concurrency test จริง (200 บิลพร้อมกันบนสต็อก 50 → ได้ 50 บิลเป๊ะ) พิสูจน์ row lock ทำงานถูกต้องภายใต้แรงกดดันจริง ไม่ใช่แค่เคสเดียว
- Coverage สูงไม่เท่ากับถูก — วัดแค่บรรทัดถูกรัน ไม่ได้วัดว่า assert ตรงจุด
- ทุก bug ที่เจอจริง (มี issue number กำกับ) ควรมี regression test คู่กันตลอดไป — repo นี้ทำแบบนี้จริงกับ #383/#384

---

## ❓ Quiz

<details><summary>1. ทำไม server มี e2e test (53 ไฟล์) มากกว่า unit spec (40 ไฟล์) ทั้งที่ปกติ unit ควรเยอะกว่าตาม test pyramid?</summary>

เพราะ invariant สำคัญที่สุดของร้าน (RLS แยก tenant, row lock กันขายเกินสต็อกตอน concurrent, idempotency กันบิลซ้ำ) เกิดที่รอยต่อระหว่าง HTTP → transaction → Postgres จริง — unit test แยก class เดียวพิสูจน์ invariant พวกนี้ไม่ได้เลย ต้องพิสูจน์กับของจริง สอดคล้องกับแนวคิด testing trophy มากกว่า pyramid

</details>

<details><summary>2. ถ้า `redis-cache-outage.e2e-spec.ts` ใช้ `vi.spyOn` mock method ของ cache client แทนการตัดการเชื่อมต่อจริง จะพิสูจน์อะไรได้บ้าง และพิสูจน์อะไรไม่ได้?</summary>

พิสูจน์ได้แค่ว่า "โค้ด catch/guard ทำงานเมื่อถูกเรียก" (เพราะ mock บังคับให้ throw error ตามที่สั่ง) — พิสูจน์ไม่ได้ว่า "แอปยังรอดจริง" เพราะ mock ข้าม logic การเชื่อมต่อ/timeout/retry จริงทั้งหมด ถ้ามี bug อยู่ในโค้ดส่วนนั้น test แบบ mock จะยังผ่านอยู่ดี (นี่คือสิ่งที่เกิดขึ้นจริงกับ #383)

</details>

<details><summary>3. ทำไม concurrency test ที่ `sales.e2e-spec.ts:581` ใช้ `Promise.allSettled` แทน `Promise.all`?</summary>

`Promise.all` จะโยน error ทันทีเมื่อ request แรก reject โดยไม่รอ 199 request ที่เหลือให้เสร็จ — request ที่ "ลอยค้าง" อยู่จะยังเขียนข้อมูลเข้า tenant ต่อไป พอดีกับตอนที่ test ถัดไปเริ่มลบ tenant นั้น (`resetTenant`) กลายเป็น foreign-key error ที่ดูเหมือนบั๊กจุดอื่นทั้งที่ต้นเหตุคือ request ค้าง `allSettled` รอทุกตัวเสร็จก่อนเสมอ จึงไม่มี request ไหนหลงเหลือ

</details>

<details><summary>4. ถ้า coverage ของไฟล์หนึ่งขึ้น 100% แปลว่าโค้ดไฟล์นั้นไม่มี bug แน่นอนหรือไม่? ทำไม</summary>

ไม่แน่นอน coverage วัดแค่ "บรรทัดถูกรันผ่าน" ไม่ได้วัดว่า test เช็คผลลัพธ์ถูกต้องหรือครบทุก edge case — test ที่เรียกฟังก์ชันแล้วไม่มี `expect()` เลยก็ทำให้ coverage ขึ้น 100% ได้ทั้งที่ไม่ได้พิสูจน์อะไรเลย

</details>

<details><summary>5. `tenant-wrapper.spec.ts` และเพื่อนอีก 2 ไฟล์ ไม่ได้รันโค้ด backend จริงเลย แต่สแกนซอร์สโค้ดเป็น AST แทน — เพราะอะไรถึงต้องทำแบบนี้ แทนที่จะเขียน unit test ปกติ?</summary>

เพราะกฎที่มันปกป้อง ("ทุก method ที่แตะ tenant context ต้องห่อด้วย `runTx` รูปแบบนี้เท่านั้น") เป็นกฎเชิงโครงสร้างของโค้ด ไม่ใช่กฎเชิงผลลัพธ์ — handler ที่เขียนผิดกฎอาจยังตอบผลถูกในเคส test ทั่วไป (มี tenant เดียว) แต่พังจริงเมื่อมีหลาย tenant ใน production unit test แบบ input→output ธรรมดาจับไม่ได้ ต้องเช็คที่ "เขียนโค้ดแบบไหน" โดยตรงผ่าน AST

</details>

<details><summary>6. ทำไม CLAUDE.md ถึงห้ามแก้ 3 architecture spec ให้ "ผ่านง่ายๆ" เวลามันแดง โดยไม่เข้าใจสาเหตุก่อน?</summary>

เพราะถ้ามันแดง แปลว่ามีโค้ดใหม่ละเมิดกฎ tenancy/idempotency ที่ ADR-0003 วางไว้ (เช่น เปิด pool connection ที่สอง หรือลืมห่อ `runTx`) — การแก้ allowlist หรือ matcher ให้ผ่านโดยไม่เข้าใจ เท่ากับปิดกั้นเครื่องเตือนที่มีไว้ป้องกัน deadlock/data leak ข้าม tenant ซึ่งเคยเกิดจริงมาแล้ว (#162) การแก้ต้อง "ตั้งใจ" คือเข้าใจก่อนว่าทำไมกฎเปลี่ยน ไม่ใช่แค่ทำให้สีเขียว

</details>

---

## ➡️ อ่านต่อ

- บทถัดไป: team workflow + Git/PR ([13_team_workflow.md](13_team_workflow.md)) — จะพูดถึงว่า 3 คนในทีมทำงานพร้อมกันยังไงโดยไม่ชนกัน, PR review, branch protection ที่อ้างถึงในบทนี้
- อยากเจาะลึกกว่านี้: `docs/tutorial/testing-tutorial.md` (คำสั่งรัน test ทั้งหมดแบบละเอียด), `docs/Backend_design/adr/README.md` (ADR-0003 เต็มๆ ที่ 3 architecture spec ปกป้องอยู่), `docs/Backend_design/09_PHASE2_LANES.md §10` (working agreement "test only against your own side's fake")
