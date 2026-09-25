# 09 — Data migration: ย้ายข้อมูลร้านจากของเดิม

บทนี้ตอบคำถาม: เอาข้อมูลขายจริงของร้าน (ที่อยู่ในเครื่อง POS เดิม) เข้าไปอยู่ใน PostgreSQL ของระบบใหม่ได้ยังไง โดยไม่ทำเงิน/สต็อกหาย หรือทำบิลปลอมขึ้นมา

## 🧭 ก่อนอ่าน

- อ่านมาก่อน: [07_database.md](07_database.md) (โครง PostgreSQL/RLS — บทนั้นสอน **schema** migration, บทนี้พูดถึง **data** migration ซึ่งเป็นคนละเรื่อง แต่ชื่อพ้องกัน), [03_use_case.md](03_use_case.md)
- เวลาอ่าน: ~35 นาที
- อ่านจบแล้วคุณจะ:
  - แยกออกว่า "data migration" (ย้ายข้อมูล) กับ "schema migration" (เปลี่ยนโครงตาราง) เป็นคนละปัญหา
  - อธิบายได้ว่าทำไม "import แล้วพัง" ถึงอันตรายกว่าโปรแกรมทั่วไปพัง — เพราะมันมีเงินจริงติดอยู่
  - รู้จัก pattern ที่ใช้ทุกครั้งที่ย้ายข้อมูลข้ามระบบ: pre-flight → atomic import → reconcile → เก็บของเดิมไว้กันเผื่อ
  - อ่านโค้ด `exportSnapshot()` / `importLegacyBackup()` และ pre-flight ฝั่ง server ของโปรเจกต์นี้ได้
  - รู้ว่าทำไมทีมนี้ตัดสินใจ **"ไม่ cutover ใน phase 1"** — ร้านยังใช้แอปเดิมขายของจริงต่อไป

---

## 🧱 ปูพื้นฐาน

### 1. "ย้ายข้อมูล" ฟังดูง่าย แต่ทำไมมันน่ากลัว

ลองนึกภาพร้านอะไหล่จริง: มีตู้เก็บใบเสร็จเก่าเป็นปึกๆ, สมุดจดหนี้ช่าง, การ์ดสต็อกแปะข้างชั้น เวลาร้านจะ "ย้ายระบบบัญชีใหม่" เจ้าของร้านไม่ได้แค่โยนกระดาษเก่าทิ้งแล้วเริ่มนับใหม่จากศูนย์ — เขาต้อง **คัดลอกตัวเลขทุกตัวให้ตรงเป๊ะ**: ยอดหนี้ค้างของช่างแต่ละคน, สต็อกที่เหลือจริงของแต่ละชิ้น, แต้มสะสมของลูกค้าประจำ ถ้าคัดลอกผิดแม้แต่แถวเดียว วันรุ่งขึ้นช่างคนหนึ่งอาจถูกทวงหนี้ผิด หรือขายของที่จริงๆ ไม่มีในสต็อกแล้ว

**Data migration** (**การย้ายข้อมูล**) คือการเอาข้อมูลที่มีอยู่แล้วในระบบเก่า มาใส่ในระบบใหม่ โดยที่ "ความหมาย" ของมันต้องเหมือนเดิม ไม่ใช่แค่ก็อปปี้ตัวเลขดิบๆ

ทำไมมันน่ากลัวกว่าโปรแกรมพังทั่วไป:

1. **มันมีของจริงติดอยู่** — สต็อกในฐานข้อมูลไม่ใช่แค่ตัวเลข มันคือของบนชั้นจริงที่ลูกค้าจะมาซื้อ ยอดหนี้ช่างคือเงินที่ร้านจะไปทวงจริง ถ้าเลขในระบบผิด ความเสียหายไม่ได้อยู่แค่ในจอคอมพิวเตอร์
2. **มันเป็นการรันครั้งเดียว (หรือน้อยครั้งมาก)** — โค้ดขายของทุกวันถูกทดสอบซ้ำๆ นับพันครั้งโดยธรรมชาติ (ทุกบิลที่ขาย) แต่โค้ด import รันปีละไม่กี่ครั้ง แปลว่าบั๊กที่ซ่อนอยู่มีโอกาสน้อยมากที่จะถูกเจอก่อนวันจริง
3. **ผิดแล้วรู้ตัวช้า** — ถ้า `stock` เพี้ยนไป 5 ชิ้นตอน import วันนี้ ร้านอาจไม่รู้ตัวจนกว่าจะขายของจนสต็อกติดลบ หรือนับสต็อกจริงตอนสิ้นเดือนแล้วเจอว่าไม่ตรง

### 2. รูปแบบไฟล์ที่ใช้ย้ายข้อมูล: ทำไมต้องมี "รูปแบบ" เลย

สมมติร้านอยากย้ายข้อมูลจากเครื่อง A ไปเครื่อง B โดยตรง — วิธีที่ง่ายที่สุดคือ "เขียนทุกอย่างที่มีลงกระดาษแผ่นเดียว" กระดาษแผ่นนั้นต้องมีโครงสร้างที่แน่นอน ไม่งั้นคนอ่าน (หรือโปรแกรม) จะงงว่าตัวเลขไหนคือยอดขาย ตัวเลขไหนคือสต็อก

ในโลกคอมพิวเตอร์ กระดาษแผ่นนั้นมักเป็นไฟล์ **JSON** (**JavaScript Object Notation** — รูปแบบข้อความที่เก็บข้อมูลเป็น key-value ซ้อนกันได้ อ่านง่ายทั้งคนและโปรแกรม) แนวคิดคือ:

```json
{
  "sa_products": [ { "id": "p1", "name": "หัวเทียน", "stock": 12 }, ... ],
  "sa_sales":    [ { "id": "s1", "total": 350, "items": [...] }, ... ],
  "__meta": { "version": 2, "exportedAt": "2026-09-16T10:00:00Z", "recordCounts": { "products": 10 } }
}
```

สิ่งสำคัญคือไฟล์นี้ต้องมี **"บล็อกอภิพันธุ์" (metadata block)** — ในที่นี้คือ `__meta` — บอกว่าไฟล์นี้ export มาจากที่ไหน เมื่อไหร่ กี่แถว เพราะไฟล์ข้อมูลที่ไม่มี metadata คือ "กระดาษเปล่าไม่มีหัวกระดาษ" เปิดมาแล้วไม่รู้จะเชื่อได้แค่ไหน

### 3. Mapping schema เก่า→ใหม่: คำเดียวกัน ความหมายอาจไม่เหมือนกัน

ระบบเก่ากับระบบใหม่มักไม่ได้ตั้งชื่อฟิลด์เหมือนกันเป๊ะ หรือแม้ชื่อเหมือนกัน ความหมายอาจเปลี่ยนไปตามเวลา ตัวอย่างในร้านจริง: ระบบเก่าเคยแบ่งสินค้าเป็น "โซน" (`zone`: Engine, Electrical, Oils...) แต่ระบบใหม่เปลี่ยนไปใช้ "หมวดหมู่" ภาษาไทย (`category`: เครื่องยนต์, ไฟฟ้า, น้ำมัน...) คนที่เขียนตัว import ต้องรู้ทั้งสองฝั่ง แล้วเขียน **mapping table** (ตารางแปลงค่า) กำกับไว้ชัดๆ ว่า `Engine` แปลว่า `เครื่องยนต์` — ห้ามเดา ห้ามปล่อยว่างแล้วค่อยไปแก้ทีหลัง เพราะถ้าแปลผิดครั้งเดียว สินค้าทั้งหมวดจะหาไม่เจอในหน้าค้นหาใหม่

### 4. ETL: Extract, Transform, Load — สามขั้นที่แยกจากกันเสมอ

**ETL** คือชื่อ pattern มาตรฐานของการย้ายข้อมูล แยกเป็น 3 ขั้นตอนชัดเจน:

- **Extract (ดึงออก)** — อ่านข้อมูลจากระบบเก่า ยังไม่แตะระบบใหม่เลย
- **Transform (แปลง)** — แปลงรูปแบบ/หน่วย/ชื่อฟิลด์ให้ตรงกับระบบใหม่ (เช่น zone→category, string date→DateTime จริง)
- **Load (โหลดเข้า)** — เขียนข้อมูลที่แปลงแล้วลงระบบใหม่

ทำไมต้องแยก 3 ขั้นนี้ให้ชัด ไม่ทำรวดเดียว: เพราะถ้า Extract กับ Transform ปนกัน แล้ว Transform พัง คุณจะไม่รู้ว่าปัญหาอยู่ที่ "ข้อมูลต้นทางเสีย" หรือ "สูตรแปลงผิด" การแยกให้ตรวจสอบทีละขั้นได้ (เช่น dump ผลลัพธ์ของ Transform ออกมาดูก่อน Load) ทำให้หาที่ผิดเจอเร็วกว่ามาก

### 5. Validation & Reconciliation: เชื่อไฟล์ไม่ได้ และเชื่อผลลัพธ์เองก็ไม่ได้

**Validation** (**การตรวจสอบความถูกต้องของข้อมูล**) คือตรวจไฟล์ *ก่อน* เอาเข้า — เช่น ตรวจว่าไม่มีสต็อกติดลบ ไม่มีเลขที่ใบเสร็จซ้ำ

**Reconciliation** (**การกระทบยอด**) คือเทียบผลลัพธ์ *หลัง* import กับต้นฉบับ — เอาผลบวกของไฟล์เดิมมาเทียบกับผลบวกในฐานข้อมูลใหม่ ถ้าไม่ตรง แปลว่ามีอะไรหายหรือถูกนับซ้ำระหว่างทาง

วิธีที่ใช้ได้ผลจริงในโลกบัญชี (ไม่ใช่เฉพาะซอฟต์แวร์): เทียบ **ผลรวม (SUM)** และ **จำนวนแถว (COUNT)** ก่อนกับหลังเสมอ เช่น:
- `SUM(stock)` ของสินค้าทุกชิ้นก่อน import ต้องเท่ากับหลัง import
- `SUM(sales.total)` ยอดขายรวมทุกบิลต้องเท่าเดิม
- `COUNT(*)` ของทุกตารางต้องตรง

ถ้าตัวเลขพวกนี้ตรงหมด ไม่ได้แปลว่าข้อมูลถูก 100% แน่นอน (อาจมีบิลสองใบสลับเลขกันแต่ผลรวมบังเอิญเท่าเดิม) แต่ถ้า**ไม่ตรง** คุณมั่นใจได้ 100% ว่ามีอะไรผิดแล้ว — เป็นเกราะป้องกันชั้นแรกที่ถูกและไวที่สุด

### 6. Atomicity: "เอาเข้าให้ครบ หรือไม่เอาเลย"

จำ transaction จากบท database ได้ไหม (ขายของแล้วไฟดับกลางทาง) — import ก็ต้องมีคุณสมบัติเดียวกัน: **all-or-nothing** ถ้า import ไปได้ครึ่งทางแล้วเจอแถวเสีย ระบบต้อง**ย้อนกลับทั้งหมด** ไม่ใช่ปล่อยให้ร้านมีสินค้า 200 ชิ้นจาก 500 ชิ้น แล้วไม่รู้ว่า 300 ชิ้นที่เหลือหายไปไหน เพราะฐานข้อมูลที่ import ไปครึ่งเดียวคือฐานข้อมูลที่**เชื่อไม่ได้เลย** — ครึ่งหนึ่งเป็นข้อมูลจริง อีกครึ่งเป็นความว่างเปล่าที่ดูเหมือนข้อมูลจริง แยกไม่ออกด้วยตาเปล่า

### 7. Idempotent import: กด import ซ้ำแล้วต้องไม่พัง

**Idempotent** (**ทำซ้ำแล้วผลลัพธ์เหมือนเดิม ไม่ใช่ทำซ้ำสอง**) สำคัญมากสำหรับ import เพราะสถานการณ์จริงคือ: กด import แล้วอินเทอร์เน็ตหลุดกลางทาง ไม่รู้ว่าสำเร็จหรือไม่ พนักงานจึงกดซ้ำ ถ้าระบบไม่ idempotent ผลคือ **ร้านมีสินค้าซ้อนสองชุด ยอดขายเบิ้ลสอง** ระบบที่ดีต้องตรวจให้ได้ว่า "ร้านนี้เพิ่ง import ไปแล้วหรือยัง" แล้วปฏิเสธการ import ซ้ำอย่างชัดเจน (ไม่ใช่ import ซ้ำเงียบๆ)

### 8. Dry-run / Pre-flight: ตรวจก่อนทำจริง

**Dry-run** (**การรันทดสอบแบบไม่บันทึกจริง**) หรือ **pre-flight** (ศัพท์การบิน = ตรวจเครื่องก่อนขึ้นบิน) คือสแกนไฟล์ทั้งหมดก่อน แล้วรายงานปัญหาทั้งหมดที่เจอ **โดยยังไม่เขียนอะไรลงฐานข้อมูลเลย** ประโยชน์คือ: ถ้าไฟล์มี 50 แถวเสีย คุณอยากรู้ทั้ง 50 แถวในครั้งเดียว ไม่ใช่รู้ทีละแถวตอน transaction ล่มกลางทาง (แถวที่ 51 ก็ยังไม่รู้ว่าเสียด้วยหรือเปล่า)

### 9. Rollback plan: ถ้า import ดันไม่ตรงจะทำยังไง

ต่อให้ตรวจสอบดีแค่ไหน ของจริงเสมออาจมีเคสที่คาดไม่ถึง แผนสำรองมาตรฐานคือ **เก็บข้อมูลต้นฉบับไว้เสมอ** (อย่างน้อยไม่กี่สิบวัน) ก่อนจะลบทิ้ง เพื่อให้ย้อนกลับไปเริ่มใหม่ได้ถ้าเจอปัญหาทีหลัง

### 10. Cutover strategies: เปลี่ยนระบบยังไงให้ร้านไม่หยุดขาย

เมื่อข้อมูลย้ายเสร็จแล้ว คำถามต่อไปคือ **จะเปลี่ยนให้ร้านใช้ระบบใหม่จริงๆ ตอนไหน** มี 3 แนวทางหลัก:

| แนวทาง | ทำยังไง | ข้อดี | ข้อเสีย |
|---|---|---|---|
| **Big bang cutover** | เลือกวันเดียว ปิดระบบเก่า เปิดระบบใหม่ทันที | เร็ว จบในวันเดียว | ถ้าระบบใหม่มีบั๊กที่ไม่เคยเจอ ร้านหยุดขายทันที ย้อนกลับยาก |
| **Parallel run** | รันสองระบบพร้อมกันสักพัก เทียบผลลัพธ์ทุกวัน | ปลอดภัยสุด เจอบั๊กก่อนตัดขาด | งานเพิ่มเป็นสองเท่า (พนักงานคีย์ข้อมูลสองที่) พนักงานร้านทำจริงไม่ไหว |
| **Phased cutover** | ย้ายทีละส่วน/ทีละสาขา ไม่ใช่ทีเดียวหมด | ความเสี่ยงกระจาย แก้ทีละจุดได้ | ต้องดูแลทั้งสองระบบพร้อมกันชั่วคราว ซับซ้อนกว่า |

**โปรเจกต์นี้เลือกทางที่สี่ที่ไม่อยู่ในตำราตรงๆ: "ยังไม่ cutover เลย"** — server พัฒนาไปเรื่อยๆ ข้อมูลถูก import เข้าไปเป็น **demo tenant** เพื่อพิสูจน์ว่า pipeline ใช้งานได้จริง แต่ **ร้านจริงยังใช้แอป Drift เดิมขายของทุกวันเหมือนเดิมทุกอย่าง** เหตุผล (จาก `CLAUDE.md`, ตัดสินใจ 2026-09-04): "phase 1 rule — the shop keeps running the Drift build, no cutover" การ cutover ร้านจริงถูกเลื่อนไปเป็น **#231** ในเฟสถัดไป

---

## 🔥 ปัญหาจริงของร้าน

ร้านศรีสุราษฎร์ฯ มีข้อมูลอยู่ในแอป Flutter/Drift ที่รันบนเครื่อง POS ของร้านอยู่แล้ว (ประวัติการย้ายจากเว็บ localStorage เดิมมาเป็น Drift คือเรื่องที่อธิบายไปแล้วใน `CLAUDE.md`) ทีนี้ระบบใหม่ — backend NestJS + PostgreSQL แบบ multi-tenant — ต้องมีทางให้ร้านเอาข้อมูลของตัวเองเข้าไปได้ ไม่งั้นร้านต้องเริ่มนับสต็อกใหม่จากศูนย์ ซึ่งเป็นไปไม่ได้ในทางปฏิบัติ (ร้านมีสินค้าเป็นร้อยรายการ มีช่างติดหนี้อยู่จริง มีลูกค้าสะสมแต้มอยู่จริง)

โจทย์จึงกลายเป็นสองเรื่องที่ต้องตอบพร้อมกัน:
1. **จะเอาข้อมูลจาก Drift เข้า PostgreSQL ได้ยังไง** โดยไม่ทำเงิน/สต็อกของร้านหาย
2. **ร้านจะยังขายของได้ตามปกติระหว่างที่ทีมพัฒนา server อยู่ไหม** — คำตอบคือได้ เพราะ import ไม่ใช่ cutover (ข้อ 10 ด้านบน)

---

## ⚖️ ทางเลือก → ทำไมเลือกอันนี้

### ตัดสินใจที่ 1: export/import ต้องเป็นไฟล์รูปแบบไหน

| ทางเลือก | ข้อดี | ข้อเสีย |
|---|---|---|
| **เขียน exporter/importer ใหม่หมด สำหรับ server โดยเฉพาะ** | ออกแบบได้อิสระ | ต้องเขียนโค้ดแปลงข้อมูลใหม่ทั้งหมด ทั้งที่ Flutter มี `exportSnapshot()` อยู่แล้ว เสี่ยง bug ใหม่ |
| **ใช้โครงเดิมของ `DB.exportSnapshot()` (`sa_*` + `__meta`)** ✅ | โค้ด export มีอยู่แล้วในแอป Flutter (พอร์ตมาจาก `db.js` เดิม), ร้านเอาไฟล์ไปเปิดในแอปเก่าได้จริงถ้าจำเป็น, ไม่ต้องออกแบบ schema ไฟล์ใหม่ | รูปแบบ `sa_*` เป็นภาษาที่ผูกกับ localStorage เดิม ไม่ได้ตั้งชื่อสวยงามสำหรับ server แต่ยอมแลกเพราะ "ใช้ได้จริง" สำคัญกว่า "สวย" |

เพราะ ADR-0005 ต้องมี endpoint export ให้เจ้าของร้านโหลดไฟล์ข้อมูลตัวเองได้อยู่แล้ว (ดูหัวข้อถัดไป) → จึงต้องมีโครงไฟล์ที่นิยามชัดอยู่แล้วในแอป → ทำไมไม่ใช้อันเดียวกันเป็นทางเข้าตอน import ด้วยเลย ราคาที่จ่ายคือชื่อคีย์ `sa_*` ที่ดูเป็นภาษา JS เก่าๆ ติดมาถึง server

### ตัดสินใจที่ 2: import ทำแบบ synchronous ใน request เดียว หรือ background job

| ทางเลือก | ข้อดี | ข้อเสีย |
|---|---|---|
| **Synchronous — `POST .../import` รอจน insert เสร็จค่อยตอบ** | เขียนง่าย, ผลลัพธ์ตอบกลับทันที | วัดจริงแล้วใช้เวลา ~6.4 วินาทีต่อไฟล์ 2 MiB (`server/README.md:530`) — nginx จำกัด `proxy_read_timeout 30s` ไฟล์ร้านที่ใหญ่ขึ้นจะโดน 504 ทั้งที่ transaction สำเร็จจริงแล้ว แล้ว retry จะเจอ 409 งงๆ |
| **Background job (BullMQ)** ✅ | ตอบ `202 Accepted` + `jobId` ทันที, ปลดล็อกจาก timeout ของ nginx, เช็คสถานะทีหลังได้ผ่าน `GET .../import/:jobId` | ต้องมีตาราง `import_jobs` เก็บสถานะ, ต้อง handle เคส worker ตายกลางทาง (stale job) |

เพราะไฟล์ร้านโตขึ้นเรื่อยๆ ตามอายุร้าน → เวลา import ก็โตตาม → ต้องไม่ผูกกับ timeout ของ HTTP request เดียว → จึงแยกงานเขียนจริงไปอยู่ background job (owner ตัดสิน 2026-09-15, #239) ราคาที่จ่ายคือความซับซ้อนของ state machine (`queued`/`running`/`succeeded`/`failed`) และต้องมี Postgres คอยเก็บ payload แทน Redis (เหตุผลข้อ 3)

### ตัดสินใจที่ 3: เก็บ payload ของไฟล์ที่จะ import ไว้ที่ไหนระหว่างรอ worker

| ทางเลือก | ข้อดี | ข้อเสีย |
|---|---|---|
| **เก็บใน Redis (data ของ BullMQ job เอง) พร้อม TTL** | ไม่ต้องเพิ่มตาราง | `redis-queue` ตั้งเป็น `noeviction` (BullMQ ต้องการงานที่ยังไม่เสร็จไม่ถูกเขี่ยทิ้งเด็ดขาด) — ถ้ามีไฟล์ import ใหญ่เข้ามาพร้อมกันหลายไฟล์ memory จะบวมจน OOM ไม่มีอะไรมาช่วย page ลง disk |
| **เก็บใน PostgreSQL (`import_jobs.payload` เป็น `jsonb`)** ✅ | Postgres จัดการ JSON ก้อนใหญ่ด้วย TOAST (ย้ายค่าที่ใหญ่ออกจากแถวหลักอัตโนมัติ) อยู่แล้ว, BullMQ job payload เก็บแค่ id แถวเดียว, เคลียร์ `payload` ทิ้งได้หลัง import เสร็จ (ไม่ถือข้อมูลทั้งร้านค้างไว้ตลอดไป) | ต้องมีตารางเพิ่ม และต้องดูแล `IMPORT_BODY_LIMIT` (10 MiB) เอง |

### ตัดสินใจที่ 4: export รายร้านได้ไหม แล้ว restore รายร้านล่ะ

ADR-0005 (`docs/Backend_design/adr/0005-data-portability.md`) เป็นการตัดสินใจตรงจุดนี้:

- ✅ **รับปาก:** `POST /backup/export` — เจ้าของร้าน (`role='owner'`) ขอไฟล์ข้อมูลร้านตัวเองได้ ใช้โครง `sa_*` เดิม เป็น BullMQ job (export ทั้งร้านใหญ่เกินจะทำใน request เดียว), เขียน `audit_log` ทุกครั้ง (ไฟล์มีชื่อ/เบอร์ลูกค้าทั้งร้าน — PDPA), จำกัดความถี่
- ❌ **ไม่รับปาก:** point-in-time restore รายร้าน ("เมื่อวานพนักงานลบผิด ย้อนกลับให้หน่อย")

เพราะ restore รายร้านบนสถาปัตยกรรมแบบ **T1 (shared database, shared schema)** ต้องมี nightly per-tenant dump แยกทุกร้าน + สคริปต์ลบ-แล้ว-โหลดกลับที่เรียงตาม FK ให้ถูกทั้ง ~28 ตาราง → งานใหญ่ที่ "ถ้าทำครึ่งๆ กลางๆ จะแย่กว่าไม่ทำ" (restore พลาด = ข้อมูลร้านอื่นเสียหายไปด้วย เพราะอยู่ตารางเดียวกัน) → เจ้าของโปรเจกต์เลือก **รับปากแค่สิ่งที่ทำได้จริงและตรงไปตรงมา** (export เป็นไฟล์ให้ร้านถือเอง) แทนการรับปากสิ่งที่ทำได้ครึ่งๆ กลางๆ

`POST .../import` (ของ platform admin) จึงถูกกันไว้เฉพาะ **การ onboard ร้านใหม่ครั้งแรกเท่านั้น** — และ **ต้องปฏิเสธถ้า tenant นั้นมีบิลอยู่แล้ว** (`sales`, `returns`, `purchase_orders`, `credit_payments`, `quotes`, `shifts` แถวใดก็ตาม) มันคือ **เครื่องมือ provisioning ไม่ใช่เครื่องมือ restore**

---

## 🔍 ของจริงใน repo

### 1. `exportSnapshot()` — ดึงทุกตารางเป็น JSON ตาม key เดิมของ `db.js`

`frontend/lib/data/repositories/snapshot_repository.dart:517-537`:

```dart
final data = <String, dynamic>{
  'sa_products': products,
  'sa_customers': customers,
  'sa_sales': sales,
  'sa_pos': purchaseOrders,
  'sa_settings': ?settings,
  'sa_mechanics': mechanics,
  'sa_quotes': quotes,
  'sa_returns': returns,
  'sa_movements': movements,
  'sa_suppliers': suppliers,
  'sa_categories': categories,
  'sa_credit_payments': creditPayments,
  'sa_cash_drawer': cashDrawer,
  'sa_shift_history': history,
  'sa_parked': parked,
  'sa_schema_version': schemaVersionStr,
};
```

แล้วปิดท้ายด้วย `__meta` (`snapshot_repository.dart:575-581`):

```dart
data['__meta'] = <String, dynamic>{
  'version': backupFormatVersion,
  'schemaVersion': schemaVersionInt,
  'exportedAt': DateTime.now().toUtc().toIso8601String(),
  'shopName': settings?['shopName'] ?? 'ศรีสุราษฎร์เจริญยนต์',
  'recordCounts': recordCounts,
};
```

**ทำอะไร:** อ่านทุกตารางใน Drift (products, customers, sales+items, ...) แล้วประกอบเป็น Map เดียวคีย์ตามชื่อ `sa_*` เดิมของ `db.js` — ชื่อเหล่านี้**ต้องคงเดิม**เพราะ pre-flight ฝั่ง server และไฟล์ backup เก่าของร้านผูกกับชื่อนี้

**ทำไมเขียนท่านี้:** `recordCounts` ใน `__meta` คือ**เกราะป้องกันชั้นแรก**ของ reconciliation (หัวข้อปูพื้นฐานข้อ 5) — เขียนไว้ตอน export เพื่อให้เทียบทีหลังได้ว่านับแถวตรงกันไหม โดยไม่ต้องเปิดไฟล์นับเอง

**ถ้าไม่ทำท่านี้จะพังยังไง:** ถ้า export ไม่บอกจำนวนแถวไว้ล่วงหน้า พอ import เสร็จแล้วเจอว่า `sales` หายไป 3 แถว จะไม่มีทางรู้เลยว่า "หายตอน export" หรือ "หายตอน import" — มีแค่ `recordCounts` ในไฟล์ต้นฉบับเทียบกับ `COUNT(*)` ปลายทางเท่านั้นที่แยกได้

**null-as-absent:** ข้อ 522, `'sa_settings': ?settings` — ใช้ null-aware spread ของ Dart คีย์นี้จะไม่ถูกใส่ใน map เลยถ้า `settings == null` แทนที่จะใส่ค่า `null` ลงไปตรงๆ — ฝั่ง importer (ดูข้างล่าง) ก็ปฏิบัติตามกติกาเดียวกัน: ค่า `null` ในไฟล์ = "ไม่มีข้อมูลนี้" ไม่ใช่ "มีข้อมูลแต่เป็นค่าว่าง" การแยกสองอย่างนี้ให้ชัดสำคัญมากตอนแปลงฟิลด์ตัวเลข (0 กับ "ไม่มีค่า" มีความหมายต่างกัน โดยเฉพาะ `costAtSale` ที่ null แปลว่า "ไม่รู้ต้นทุน" ไม่ใช่ "ต้นทุนฟรี" — ADR-0008)

### 2. `importLegacyBackup()` — atomic restore ในทรานแซกชันเดียว

`frontend/lib/data/repositories/snapshot_repository.dart:595-632`:

```dart
Future<void> importLegacyBackup(Map<String, dynamic> data) async {
  if (data['__meta'] == null) {
    throw Exception('ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta');
  }
  ...
  await db.transaction(() async {
    // ── 1. Wipe known tables (children before parents for FK refs) ──
    await db.delete(db.saleItems).go();
    await db.delete(db.poItems).go();
    ...
    await db.delete(db.products).go();
    ...
```

**ทำอะไร:** ตรวจก่อนว่ามี `__meta` ไหม (ไม่มี = ไฟล์นี้ไม่ใช่ backup ที่รู้จัก ปฏิเสธทันที) แล้วเปิด `db.transaction()` หนึ่งก้อน ลบตารางเดิมทั้งหมด (ลูกก่อนแม่ ตามลำดับ FK) แล้วเขียนใหม่จากไฟล์ทีละตาราง

**เชื่อมกับอะไร:** เหมือน `saveSale`/`createReturn` ที่บทอื่นสอนไปแล้ว — ใช้ `db.transaction()` ตัวเดียวกัน เพราะกฎ atomicity (ปูพื้นฐานข้อ 6) เหมือนกันทุกที่ที่แตะเงิน/สต็อก: throw ตรงไหนก็ตาม = ทุกอย่างที่เขียนไปในทรานแซกชันนี้ถูกย้อนกลับหมด

**ทำไมเขียนท่านี้ (ลบทั้งหมดก่อนเขียนใหม่ ไม่ใช่ merge ทีละแถว):** import คือ "แทนที่ทั้งร้าน" ไม่ใช่ "ผสานข้อมูล" — ทำให้ผลลัพธ์คาดเดาได้ ไม่มีเคส "แถวเก่าที่ import ไม่ได้ลบ ค้างปนกับแถวใหม่"

**ถ้าไม่ทำท่านี้จะพังยังไง:** ถ้า import ล้มครึ่งทาง (เช่น แถวที่ 300 จาก 500 พังเพราะ field เพี้ยน) แล้วไม่มี transaction ห่อไว้ ร้านจะเหลือสินค้า 299 ชิ้นจากของเดิม + 0 ชิ้นจากไฟล์ใหม่ — ไม่ตรงกับทั้งข้อมูลเก่าและใหม่ กู้กลับไม่ได้เลยถ้าไม่มีสำเนาไฟล์ต้นฉบับ

### 3. zone → category migration และ null-as-absent ตอนอ่านสินค้า

`frontend/lib/data/repositories/snapshot_repository.dart:612-618, 642-665`:

```dart
const zoneMap = {
  'Engine': 'เครื่องยนต์',
  'Electrical': 'ไฟฟ้า',
  'Oils': 'น้ำมัน',
  'Brakes': 'เบรก',
  'Body': 'ตัวถัง',
};
...
for (final p in asList(data['sa_products'])) {
  final category = p['category'] != null
      ? _asStr(p['category'])
      : (zoneMap[_asStr(p['zone'])] ??
            (p['zone'] != null ? _asStr(p['zone']) : 'เครื่องยนต์'));
  ...
}
```

**ทำอะไร:** ถ้าไฟล์มีฟิลด์ `category` อยู่แล้ว (export จากแอปรุ่นใหม่) ใช้ตรงๆ ถ้าไม่มี (ไฟล์เก่าจากยุคที่ยังใช้ `zone`) แปลผ่าน `zoneMap` — นี่คือ mapping table ตามที่อธิบายในปูพื้นฐานข้อ 3 ตัวจริง

**ทำไมเขียนท่านี้:** ของเดิม (ตาม comment ใน `01_DATABASE.md §9`) เคยทำ mapping นี้ "ตอนอ่าน" (ทุกครั้งที่ query สินค้า) ไม่ใช่ "ตอนเก็บ" — พอย้ายมาเป็น import ต้องทำให้จบตั้งแต่ตอนนี้ ไม่งั้นข้อมูลใน DB จะยังเป็น `zone` แบบอังกฤษ ค้างอยู่ ทั้งที่ทั้งระบบใหม่ query ด้วย `category` ภาษาไทย

### 4. Pre-flight ฝั่ง server: validate-then-clamp (บทเรียนจาก #22/#24)

`server/src/platform/snapshot-preflight.ts:1-13, 138-168`:

```ts
/**
 * #239 — pre-flight checks `tenant-import.service.ts` runs on the JSON alone, before any
 * write: `01_DATABASE.md §9` step 2 says stop and decide, never import and hope.
 *
 * Three gaps `#185`'s real-file run found, all the same shape (read `#22`'s lesson): a
 * value the importer would otherwise clamp or default away silently, corrupting the ledger
 * or moving a bill into the wrong day without raising anything.
 */
...
// ── 3. Validate-then-clamp ──────────────────────────────────────────────
// `#22`'s lesson, restated for import: `tenant-import.service.ts` used to write
// `Math.max(0, …)` / `Math.max(1, …)` straight over unvalidated input — a negative balance,
// a negative point total, a negative `minStock`, or a sale/return/PO/quote line's `qty` of
// zero, negative, non-integer, or missing all silently became 0 or 1. ... refuse here instead

const nonNegative = (table: string, id: string, field: string, v: unknown) => {
  if (v == null) return; // absent → the importer's own default (0), not a clamp on a real value
  const n = asNumber(v);
  if (!Number.isFinite(n) || n < 0) out.push({ table, id, field, value: v, rule: 'must be ≥ 0' });
};
```

**ทำอะไร:** สแกนไฟล์ทั้งก้อน (ยังไม่แตะฐานข้อมูล — เป็น pure function อ่านอย่างเดียว, `snapshot-preflight.ts:11-12`) หาค่าที่ผิดกฎ 3 กลุ่ม: เลขที่เอกสารซ้ำ, วันที่ parse ไม่ได้, และค่าตัวเลขที่ผิดกติกา (ติดลบ/ไม่ใช่จำนวนเต็ม/ไม่ใช่ตัวเลขจริง) แล้วรวบรวมเป็นรายการ "ปฏิเสธพร้อม id" กลับไปเป็น `400 Bad Request`

**ปัญหาที่มันแก้ (บทเรียน #22/#24 — "validate input first, then clamp"):** ของเดิมเคยเขียน `Math.max(0, credit_balance)` ตรงๆ ทับค่าที่ยังไม่ตรวจ ผลคือถ้าไฟล์มี `credit_balance: -500` (บั๊กจากที่ไหนสักที่) ตัว import จะ**เงียบๆ แปลงเป็น 0** — ช่างคนนั้นหนี้หายไปเฉยๆ ไม่มี error อะไรเตือนเลย นี่คือสิ่งที่เอกสารเรียกว่า **"เปลี่ยนความเสียหายที่ดังให้กลายเป็นความเสียหายที่เงียบ"** — ยิ่งอันตรายกว่าการพังแบบมี error เพราะไม่มีใครรู้ตัวจนกว่าจะสายเกินแก้

**ทำไมเลือกท่านี้ (เทียบกับท่าอื่น):** ทางเลือกคือปล่อยให้ Postgres `CHECK` constraint จับ (เช่น `stock >= 0`) แต่นั่นจะพังกลางทรานแซกชันเป็น `500` ที่ไม่มีบริบทว่า "แถวไหนของไฟล์" ทำผิด ในขณะที่ pre-flight รวบรวม**ทุกปัญหาในไฟล์ครั้งเดียว** ก่อนเขียนอะไรเลย ให้ operator แก้ไฟล์ครั้งเดียวจบ ไม่ต้อง retry ทีละแถว

**ดียังไง / ราคาที่จ่าย:** ดี — ปฏิเสธไฟล์เสียตั้งแต่ก่อนเข้าคิว (`202` ไม่ถูกส่งออกไปเลยถ้า pre-flight ไม่ผ่าน) ราคาที่จ่าย — ต้องเขียนกฎ validate ซ้ำสองที่ (pre-flight ที่อ่านอย่างเดียว + `CHECK` ใน Postgres ที่เป็นเกราะสุดท้าย) เผื่อกรณี pre-flight ตกหล่นอะไรไป

**อยู่ตรงไหนใน repo:** `server/src/platform/snapshot-preflight.ts` (ฟังก์ชัน `planDuplicateDocNumbers`, `planUnparseableDates`, `planClampViolations`), เรียกจาก `server/src/platform/tenant-import.controller.ts:33-42` (comment บอกตรงว่า "pre-flight runs here, synchronously, so a bad file still answers 400/409 right away")

### 5. Import เป็น background job (BullMQ) — ทำไมไม่ทำใน request เดียว

`server/src/platform/tenant-import.controller.ts:33-43`:

```ts
// #239: pre-flight runs here, synchronously, so a bad file still answers 400/409 right
// away; the write itself is a BullMQ job (`TenantImportProcessor`) — see
// `tenant-import.service.ts`'s block comment for why a synchronous request stopped being
// safe (nginx's 30 s `proxy_read_timeout` vs. ~6.4 s per 2 MiB locally, growing with a
// shop's history).
@Post(':id/import')
@HttpCode(HttpStatus.ACCEPTED)
async importSnapshot(
  @Param('id') id: string,
  @Body() body: SnapshotPayload,
  @Req() req: AuthenticatedRequest,
) {
  const ip = clientIp(req) ?? undefined;
  return this.importService.createJob(id, body, req.platformAdmin.id, ip);
}
```

**ทำอะไร:** pre-flight รันตรงนี้ (synchronous, ไม่มีการเขียน) ผ่านแล้วค่อย `createJob(...)` ส่งงานเขียนจริงเข้าคิว BullMQ แล้วตอบ `202 Accepted` ทันที ไม่รอ insert เสร็จ

**ทำไมเขียนท่านี้:** วัดจริงว่า import ทั้งก้อนใช้เวลา **6.4 วินาทีต่อไฟล์ 2.0 MiB** (4 เดือน 2,043 บิล, `server/README.md:530-533`) ในขณะที่ nginx จำกัด `proxy_read_timeout 30s` — ไฟล์ร้านที่มีประวัติยาวกว่านี้จะโดน 504 ทั้งที่ฝั่ง server เขียนสำเร็จจริง แล้ว retry จะเจอ `409` เพราะ tenant มีบิลแล้ว (งงว่าเกิดอะไรขึ้น)

**ถ้าไม่ทำท่านี้จะพังยังไง:** operator กด import ไฟล์ใหญ่ รอ 30 วิ เจอ error timeout ทั้งที่จริงๆ สำเร็จไปแล้ว → กด import ซ้ำ → เจอ 409 "ร้านนี้มีบิลอยู่แล้ว" → งงว่าทำไมมันไม่ยอมรับ ทั้งที่ import ครั้งแรกสำเร็จไปแล้วโดยไม่มีใครรู้

**สถานะงาน (state machine):** `server/src/db/migrations/1788652802200-ImportJobs.ts:38-39`:

```sql
status TEXT NOT NULL DEFAULT 'queued'
       CHECK (status IN ('queued','running','succeeded','failed'))
```

payload เก็บใน `import_jobs.payload` (คอลัมน์ `jsonb`) แทน Redis — เพราะ `redis-queue` ตั้งเป็น `noeviction` (BullMQ ต้องการงานที่ยังไม่เสร็จไม่ถูกเขี่ยทิ้ง) ถ้าเก็บไฟล์ใหญ่ในนั้นแล้วมี import พร้อมกันหลายไฟล์ memory จะบวมจน OOM โดยไม่มีอะไรมาช่วย page ลง disk แบบที่ Postgres ทำได้เอง (comment เต็มอยู่ที่ด้านบนของไฟล์ migration เดียวกัน)

### 6. Tombstone: ประวัติอ้างถึงแถวที่ถูกลบไปแล้ว (ADR-0005 แก้ข้อ 3, #238)

`docs/Backend_design/01_DATABASE.md:1284-1299` (สรุปสั้น — โค้ดจริงอยู่ที่ `server/src/platform/snapshot-tombstones.ts`):

Drift ไม่มี FK และลบแบบ hard delete ทุกที่ ไฟล์จริงจากร้านจึงมี `movements` ที่อ้างสินค้าที่ถูกลบไปแล้ว, `sales` ที่อ้างลูกค้า/ช่างที่หายไปแล้ว ถ้าไม่จัดการ Postgres จะชน foreign-key constraint แล้ว `500` ทั้งร้านตอน import วิธีแก้: import สร้าง **แถว soft-deleted** หนึ่งแถวต่อ id ที่หายไป (`deleted_at` = เวลา import, ชื่อเอาจากที่ประวัติคัดลอกเก็บไว้, ยอดเป็นศูนย์, ติดป้าย `import-tombstone`) — **ไม่ใช่การคืนชีพข้อมูลที่ร้านลบ** เพราะยังเป็นแถว soft-deleted อยู่ แค่ทำให้ FK ของประวัติที่ยังเก็บอยู่จริงเป็นจริง ไม่ขัดกับ ADR-0005 ("ไม่มี restore รายร้าน")

ถ้าอ้างถึง id ที่หายไปแต่**ไม่มีชื่อให้ตั้ง tombstone เลย** (เช่น "ใบลดหนี้ที่บิลต้นทางหายไป") pre-flight ปฏิเสธเป็น 400 ทันที — เหตุผล: การสร้างบิลปลอมเท่ากับสร้างเงินขึ้นมาจากอากาศ

### 7. Reconcile 6 ข้อ: ตรวจสอบว่านำเข้าถูกต้องจริง (ของจริง ไม่ใช่ synthetic)

`docs/Backend_design/01_DATABASE.md §9` กำหนด 6 ค่าที่ต้องตรวจหลัง import ทุกครั้ง (`SUM(sales.total)`, `SUM(products.stock)`, `COUNT(*)` ทุกตาราง, แต้ม/ยอดซื้อสะสมลูกค้า, `credit_balance` ช่างทุกคน + `SUM(credit_payments.amount)`, ยอดลิ้นชักกะล่าสุด)

**หลักฐานจริง** — ทีมรัน checklist นี้กับไฟล์จริงของร้าน (`pos-backup-20260916.json`, 14.2 KiB) เมื่อ 2026-09-17 (`docs/handoff_log/close4-real-snapshot-2026-09-17.md`):

| ข้อ | รายการ | ค่าที่คาด | ค่าจริงใน Postgres | สถานะ |
|---|---|---|---|---|
| 5.1 | `SUM(sales.total)` | 33,700.00 บาท | 33,700.00 บาท | ✅ |
| 5.2 | `SUM(products.stock)` | 191 ชิ้น | 191 ชิ้น | ✅ |
| 5.3 | `COUNT(*)` 18 ตาราง (เช่น `sales`=5, `sale_items`=17, `movements`=10) | ตรงทุกตาราง | ตรงทุกตาราง | ✅ |
| 5.4 | แต้ม/ยอดซื้อสะสมลูกค้า | ต่างกัน 0 คน | ต่างกัน 0 คน | ✅ |
| 5.5 | ยอดหนี้ช่างคงเหลือ | ต่างกัน 0 คน | ต่างกัน 0 คน | ✅ |
| 5.6 | เงินสดลิ้นชักกะล่าสุด | 1,000.00 บาท | 1,000.00 บาท | ✅ |

Pre-flight violations = 0, orphans = 0, tombstones = 0, import status = `succeeded` ใน 204 ms — ปิด ticket **#185** ได้จริง (ไม่ใช่แค่ synthetic data — ก่อนหน้านั้นทีมเคยรันกับข้อมูลสังเคราะห์ก่อนเพราะยังไม่ได้รับไฟล์จริงจากร้าน `docs/handoff_log/close4-synthetic-snapshot-2026-09-15.md`)

**ต้องระวังอะไร:** ตัวเลขนี้เป็น **demo tenant** ที่ import เพื่อพิสูจน์ pipeline เท่านั้น — ไม่ใช่ tenant ที่ร้านใช้ขายของจริงบน server (ร้านยังขายผ่านแอป Drift เดิมตาม "no cutover" ด้านล่าง)

### 8. tenant export — ข้อยกเว้นเดียวของ commit-ceiling guard (ADR-0005)

บทเรียนจาก `05_database` (ยังไม่ลงรายละเอียดที่นี่มาก่อน): ทุก transaction ผ่าน `TenantService.runTx` มีเพดานเวลา commit 25 วินาที (`commitCeilingMs`, กันทรานแซกชันค้างยึด pool connection) แต่ export ทั้งร้านต้องอ่านประวัติทั้งหมดโดยไม่แบ่งหน้า ซึ่งอาจเกินเวลานั้นได้

`server/README.md:544-547`:

> The one exemption is the tenant export (`backup.processor.ts`, which passes `exemptFromCommitCeiling: true`; `tenant-job-runner.spec.ts` fails if any other file passes it). It reads a tenant's whole history unpaged, so it also `SET LOCAL`s both role timeouts to `5min`. It used to be unbounded and is now capped at 5 min. The exemption is safe for the rewind only because the export writes nothing a client pulls: its one write is `audit_log`.

`server/src/queue/processors/backup.processor.ts:619-621`:

```ts
return snapshot;
}, { exemptFromCommitCeiling: true });
```

**ทำไมยกเว้นได้เฉพาะจุดนี้:** เพราะ export **ไม่เขียนอะไรที่ client ไปดึงต่อ** (`updated_at` cursor sync) — write เดียวที่มันทำคือ `audit_log` ซึ่งไม่มีใคร pull การขยายเพดานที่ไหนใหม่ต้องมีเหตุผลแบบเดียวกันนี้เท่านั้น (มี unit test — `tenant-job-runner.spec.ts` — คอยล้มถ้ามีไฟล์อื่นแอบใช้ flag นี้)

---

## 🛠️ เทคนิคในบทนี้

### 1. Idempotent import ผ่าน "ปฏิเสธถ้ามีบิลอยู่แล้ว" (ไม่ใช่ upsert)

**คืออะไร:** วิธีทำให้ import "ทำซ้ำแล้วไม่พัง" ในที่นี้ไม่ได้ทำแบบ merge/upsert (เจอ id ซ้ำก็อัปเดตทับ) แต่ทำแบบ **ปฏิเสธการ import ครั้งที่สอง** ถ้า tenant นั้นมีแถวใน `sales`/`returns`/`purchase_orders`/`credit_payments`/`quotes`/`shifts` อยู่แล้ว เหมือนพนักงานไปรษณีย์ที่เห็นพัสดุมีเลขติดตามซ้ำ — ไม่ส่งซ้ำให้ลูกค้าคนเดิม แต่ตีกลับทันที

**ปัญหาที่มันแก้:** ถ้าปล่อยให้ import ครั้งที่สองทำงานเงียบๆ (เช่น insert ซ้ำ หรือ merge ผิดจุด) ร้านจะได้สินค้า/ยอดขายซ้อนสองชุด — พนักงานกด import ไม่มั่นใจว่าสำเร็จ กดซ้ำ (เพราะ UI ไม่ตอบสนองทันที เป็น background job) ผลคือยอดขายเบิ้ลสอง

**ทำไมเลือกท่านี้ (เทียบกับ upsert):** upsert ต้องนิยาม "id เดียวกัน = แถวเดียวกัน" ให้ถูกทุกตาราง ซึ่งซับซ้อนมากเมื่อ id ของบางตาราง (เช่น `shifts`) ไม่มีอยู่ในไฟล์จริงตั้งแต่แรก (ต้องสร้างขึ้นใหม่ทุกครั้ง) — การปฏิเสธเป็น `409` เมื่อ "มีบิลแล้ว" ง่ายกว่ามากและตรงกับความจริงของ business rule: import คือเครื่องมือ**onboard ร้านใหม่ครั้งเดียว** ไม่ใช่เครื่องมือ sync ต่อเนื่อง

**ดียังไง / ราคาที่จ่าย:** ดี — ปลอดภัยแน่นอน ไม่มีทางเบิ้ลข้อมูล ราคาที่จ่าย — ถ้าร้าน import ผิดไฟล์ (เช่น ไฟล์เก่ากว่าที่ควร) แล้วรู้ตัวทีหลัง ต้องลบ tenant ทิ้งแล้วเริ่มใหม่ ไม่มีทาง "import ทับ" ได้เลยตามเจตนา (ตรงกับ ADR-0005 ที่ไม่รับปาก restore)

**อยู่ตรงไหนใน repo:** เงื่อนไข "มีบิลอยู่แล้ว" กำหนดใน ADR-0005 แก้ข้อ 2 (`docs/Backend_design/adr/0005-data-portability.md:64-67`); unique index กันสองงานพร้อมกันต่อ tenant คือ `uq_import_jobs_active` (`server/src/db/migrations/1788652802200-ImportJobs.ts:58-59`, `WHERE status IN ('queued','running')`)

### 2. Pre-flight scan (dry-run แบบไม่แตะ DB)

**คืออะไร:** สแกนไฟล์ทั้งก้อนหาปัญหาทั้งหมดก่อน โดยไม่เขียนอะไรลง DB เลย เหมือนช่างเครื่องบินเดินตรวจรอบเครื่องก่อนขึ้นบิน (ปีก ล้อ น้ำมัน) ไม่ใช่ปล่อยขึ้นบินแล้วค่อยรู้ว่าน้ำมันหมดกลางอากาศ

**ปัญหาที่มันแก้:** ถ้าปล่อยให้ Postgres เจอปัญหาเองกลางทรานแซกชัน (constraint ชน) คุณจะได้ error 1 แถวต่อ 1 รอบ retry — ไฟล์ที่มี 50 แถวเสียต้อง retry 50 รอบ กว่าจะรู้ครบ (ถ้าไม่มี transaction ห่อ อาจจะเสียหายไปก่อนด้วย)

**ทำไมเลือกท่านี้ (เทียบกับ "ลองแล้วดูว่า error อะไร"):** pre-flight เป็น pure function อ่านอย่างเดียว (`snapshot-preflight.ts:11-12` บอกไว้ตรงๆ) เขียน unit test ได้ง่ายมากเพราะไม่ต้องมี database จริง — ทดสอบแค่ "ใส่ JSON เข้าไป ต้องได้ list ของปัญหาที่ถูกต้องออกมา"

**ดียังไง / ราคาที่จ่าย:** ดี — operator แก้ไฟล์ครั้งเดียวจบ ราคาที่จ่าย — กฎ validate ต้องเขียนสองรอบ (pre-flight ที่นี่ + `CHECK` constraint ใน Postgres ที่เป็นเกราะสุดท้ายจริงๆ) เผื่อ pre-flight ตกหล่นเคสไหนไป

**อยู่ตรงไหนใน repo:** `server/src/platform/snapshot-preflight.ts` (ทั้งไฟล์), เรียกก่อนเข้าคิวใน `server/src/platform/tenant-import.controller.ts:33-42`

### 3. Reconciliation ด้วย SUM/COUNT ก่อน-หลัง

**คืออะไร:** เทียบผลรวม (เงิน, สต็อก) และจำนวนแถวก่อนกับหลัง import — เหมือนร้านทำบัญชีสิ้นวัน เทียบเงินในลิ้นชักกับยอดขายที่บันทึกไว้ ถ้าไม่ตรง หยุดหาสาเหตุก่อนปิดกะ ไม่ใช่ปล่อยผ่านแล้วค่อยว่ากันพรุ่งนี้

**ปัญหาที่มันแก้:** ถ้าไม่มีขั้นตอนนี้ บั๊กที่ทำให้ข้อมูลหาย/ซ้ำจะไม่มีใครรู้จนกว่าจะเจอปัญหาจริงหน้าร้าน (ขายของที่สต็อกจริงไม่มี, ทวงหนี้ช่างผิดจำนวน) ซึ่งช้าเกินไปมากแล้ว

**ทำไมเลือกท่านี้ (เทียบกับตรวจทีละแถว):** ตรวจทีละแถว (diff เต็มไฟล์) แม่นยำกว่าแต่ทำเป็นกิจวัตรทุกครั้งไม่ไหว ผลรวม/จำนวนนับเป็น**สัญญาณเตือนที่ถูกและไวมาก** — ถ้าผ่านหมด 6 ข้อ ไม่ได้แปลว่าถูก 100% แต่ถ้าข้อใดข้อหนึ่งไม่ผ่าน**รู้แน่นอนว่าผิด** คุ้มที่จะรันทุกครั้ง

**ดียังไง / ราคาที่จ่าย:** ดี — จับความผิดพลาดได้เร็วมาก ก่อนร้านทันสังเกตด้วยตัวเอง ราคาที่จ่าย — เป็นแค่ตัวชี้ว่า "ผิด" ไม่บอกว่า "ผิดตรงไหน" ต้องมีเครื่องมืออื่นช่วยหาแถวที่ผิดจริง

**อยู่ตรงไหนใน repo:** นิยาม 6 ข้อ — `docs/Backend_design/01_DATABASE.md §9` ขั้นตอน 5; ผลจริงที่รันแล้ว — `docs/handoff_log/close4-real-snapshot-2026-09-17.md`; ฟังก์ชันที่รัน 6 ข้อนี้ในเทสต์ — `reconcileImport()` ใน `server/test/support/snapshot-checks.ts` (`docs/handoff_log/close4-synthetic-snapshot-2026-09-15.md`)

### สรุปตาราง

| เทคนิค | แก้ปัญหาอะไร | ราคาที่จ่าย | file |
|---|---|---|---|
| Idempotent import (ปฏิเสธถ้ามีบิลแล้ว) | import ซ้ำทำให้ข้อมูลเบิ้ล | import ทับไม่ได้เลยแม้ตั้งใจ | `docs/Backend_design/adr/0005-data-portability.md` §2, `server/src/db/migrations/1788652802200-ImportJobs.ts:58-59` |
| Pre-flight scan (dry-run) | error 1 แถวต่อ 1 รอบ retry ระหว่าง import | validate ต้องเขียนสองรอบ | `server/src/platform/snapshot-preflight.ts` |
| Reconciliation (SUM/COUNT ก่อน-หลัง) | บั๊กเงียบที่ไม่มีใครรู้จนสาย | บอกแค่ว่าผิด ไม่บอกว่าผิดตรงไหน | `docs/Backend_design/01_DATABASE.md §9` ขั้น 5, `docs/handoff_log/close4-real-snapshot-2026-09-17.md` |
| Atomic transaction (all-or-nothing) | import ครึ่งทางแล้วเชื่อไม่ได้เลย | ต้อง rollback ทั้งก้อนแม้พังแค่แถวเดียว | `frontend/lib/data/repositories/snapshot_repository.dart:620` (`await db.transaction(...)`) |
| Tombstone แทนการ restore | FK ชนตอน import ประวัติที่อ้างแถวถูกลบ | ต้องดูแล id ปลอมที่ไม่ใช่ข้อมูลจริง | `docs/Backend_design/01_DATABASE.md §9`, `server/src/platform/snapshot-tombstones.ts` |
| Background job สำหรับ import | ไฟล์ใหญ่โดน nginx timeout 30s | ต้องมี state machine + ตาราง `import_jobs` | `server/src/db/migrations/1788652802200-ImportJobs.ts` |

---

## ⚠️ บทเรียนจากของจริง

### 1. #22/#24 — clamp บนค่าที่ยังไม่ตรวจ ทำให้หนี้ช่างหายเงียบๆ

ของเดิม `tenant-import.service.ts` เคยเขียน `Math.max(0, credit_balance)`, `Math.max(1, qty)` ตรงๆ ทับค่าที่มาจากไฟล์โดยไม่ตรวจก่อน ถ้าไฟล์มีค่าติดลบ (ไม่ว่าจะเกิดจากบั๊กที่ไหนในระบบเดิม) ค่าจะถูกดันเป็น 0/1 อย่างเงียบๆ — **ไม่มี error ไม่มีคำเตือน** นี่คือที่มาของกฎที่เขียนซ้ำอยู่หลายที่ใน `CLAUDE.md`: **"validate input first, then clamp"** — ตรวจก่อนเสมอ ค่อย clamp ทีหลัง แก้แล้วด้วย pre-flight ในหัวข้อ "ของจริงใน repo" ข้อ 4 ด้านบน

### 2. #238/#252 — ประวัติอ้างถึงแถวที่ถูกลบไปแล้ว ไม่ใช่เคสหายาก แต่เป็นเคสที่เจอทุกไฟล์จริง

รอบตรวจ PR #252 (2026-09-15) พบว่ากฎ tombstone จากข้อ #238 (สร้างแถว soft-deleted แทนทุก id ที่หายไป) มีช่องโหว่: `sa_suppliers.product_id` ที่อ้างสินค้าที่ถูกลบไปแล้ว **โดยไม่เคยมีประวัติอื่น** (ไม่เคยลงสต็อก ไม่เคยขาย) ไม่มีชื่อให้ตั้ง tombstone ได้เลย — ถ้าไม่แก้ ไฟล์จริงทั้งไฟล์จะถูกปฏิเสธด้วยเหตุผลเล็กๆ (ราคาซัพพลายเออร์ตัวเดียวที่ไม่สำคัญ) เจ้าของโปรเจกต์ตัดสินใจ (2026-09-15): แถวแบบนี้**ทิ้งไปเงียบๆ** (นับจำนวนไว้ใน `droppedSuppliers`) แทนที่จะปฏิเสธทั้งไฟล์ — บทเรียน: กฎที่ดูสมบูรณ์ในตอนออกแบบ อาจพังกับข้อมูลจริงที่ไม่เคย "clean" แบบในตำรา ต้องรอไฟล์จริงมาทดสอบก่อนถึงจะเจอมุมที่ลืมคิด

### 3. #239 — synchronous import คือ time bomb ที่รอไฟล์ใหญ่พอ

ตอนแรก endpoint `.../import` เป็น synchronous request เดียว ใช้งานได้ปกติกับไฟล์ทดสอบเล็กๆ จนกระทั่งวัดเวลาจริงกับไฟล์ 2 MiB (4 เดือนของร้าน) แล้วเจอว่าใช้เวลา 6.4 วินาที — ยังไม่เกิน timeout ของ nginx ในตอนนั้น **แต่ร้านที่ใช้งานไปหลายปีจะมีไฟล์ใหญ่กว่านี้มาก** เจ้าของโปรเจกต์ตัดสินใจย้ายไปเป็น background job ก่อนที่จะเจอปัญหาจริงหน้างาน — บทเรียน: เวลาที่วัดได้วันนี้ไม่ใช่เพดานถาวร ต้องคิดถึง "ไฟล์จะโตขึ้นตามอายุร้าน" ตั้งแต่ตอนออกแบบ

---

## ✅ สรุป

- **Data migration** (ย้ายข้อมูลข้ามระบบ) กับ **schema migration** (เปลี่ยนโครงตาราง, สอนในบท [07_database.md](07_database.md)) เป็นคนละเรื่อง แม้ชื่อพ้องกัน
- ย้ายข้อมูลอันตรายเพราะมี**เงิน/สต็อกจริง**ติดอยู่, รันไม่บ่อยจึงบั๊กซ่อนง่าย, และผิดแล้วรู้ตัวช้า
- Pattern มาตรฐาน: **ETL** (Extract/Transform/Load) → **validate ก่อน** (pre-flight) → **atomic** (all-or-nothing) → **idempotent** (ทำซ้ำไม่พัง) → **reconcile** (เทียบ SUM/COUNT ก่อน-หลัง) → เก็บของเดิมไว้กันเผื่อ
- โปรเจกต์นี้ใช้โครง `sa_*` + `__meta` เดิมของ `db.js`/Flutter ทั้งฝั่ง export และ import — ไม่ออกแบบไฟล์ใหม่ เพราะของเดิมพิสูจน์แล้วว่าเปิดกลับในแอปเก่าได้จริง
- Import จริงเป็น background job (BullMQ) เพราะ synchronous request ชนกับ nginx timeout เมื่อไฟล์ร้านโตขึ้น
- Pre-flight (validate-then-clamp) เกิดจากบทเรียน #22/#24 — clamp บนค่าที่ยังไม่ตรวจ ทำให้ความเสียหายเงียบแทนที่จะดัง
- Tombstone แก้ปัญหาประวัติอ้างถึงแถวที่ถูก hard-delete ไปแล้ว โดยไม่ผิดกฎ "ไม่มี restore รายร้าน" ของ ADR-0005
- ไฟล์จริงของร้าน (`pos-backup-20260916.json`) ผ่าน checklist 6 ข้อครบ 100% เมื่อ 2026-09-17 — ปิด #185
- โปรเจกต์เลือก **"ไม่ cutover ใน phase 1"** — ร้านยังขายของผ่านแอป Drift เดิมทุกวัน server พัฒนาคู่ขนานกับ demo tenant, การ cutover ร้านจริงเลื่อนไปเป็น **#231** ในเฟสถัดไป (ยังไม่มีกำหนดวัน)

---

## ❓ Quiz

<details><summary>1. ทำไม `importLegacyBackup()` ถึงต้องลบทุกตารางทิ้งก่อนแล้วค่อยเขียนใหม่ ทำไมไม่ merge แถวที่มี id ซ้ำแทน</summary>

Import คือ "แทนที่ทั้งร้าน" ไม่ใช่ "ผสานข้อมูล" — การลบทิ้งก่อนทำให้ผลลัพธ์คาดเดาได้แน่นอน ไม่มีเคส "แถวเก่าที่ import ไม่ได้แตะ ค้างปนอยู่กับแถวใหม่จนแยกไม่ออก" ถ้าจะ merge ต้องนิยามกฎ "id เดียวกันแปลว่าอะไร" ให้ครบทุกตาราง ซึ่งพังง่ายเพราะบางตาราง (เช่น `shifts`) ไม่มี id ในไฟล์ตั้งแต่แรกอยู่แล้ว

</details>

<details><summary>2. ถ้า pre-flight ผ่านหมด (0 violations) แต่ import กลับล้มเหลวกลางทางเพราะไฟดับ จะเกิดอะไรกับข้อมูลในฐานข้อมูล</summary>

ไม่มีอะไรถูกเขียนเลย เพราะ import ทั้งก้อนอยู่ใน transaction เดียว (`db.transaction()` ฝั่ง Flutter / worker transaction ฝั่ง server) — ไฟดับกลางทางทำให้ transaction ไม่ commit จึงถูก rollback ทั้งหมดโดยอัตโนมัติ ฐานข้อมูลจะยังอยู่ในสภาพก่อน import เป๊ะ (all-or-nothing)

</details>

<details><summary>3. ทำไมทีมถึงเลือกเก็บ payload ของไฟล์ import ไว้ใน Postgres (`import_jobs.payload`) แทนที่จะฝากไว้ใน Redis (data ของ BullMQ job เอง)</summary>

`redis-queue` ตั้งเป็น `noeviction` เพราะ BullMQ ต้องการให้งานที่ยังไม่เสร็จไม่ถูกเขี่ยทิ้งเด็ดขาด — ถ้าเก็บไฟล์ขนาดหลาย MiB ไว้ใน Redis แล้วมีไฟล์ import ใหญ่เข้ามาพร้อมกันหลายไฟล์ memory จะบวมจน OOM โดยไม่มีกลไก page ลง disk แบบที่ Postgres ทำอัตโนมัติผ่าน TOAST Postgres จึงปลอดภัยกว่าสำหรับเก็บก้อน JSON ใหญ่ที่ไม่ได้ต้องอ่านบ่อย

</details>

<details><summary>4. สมมติร้าน A import ไฟล์ backup ไปแล้วสำเร็จ แล้วเจ้าของร้านกดปุ่ม import ไฟล์เดิมซ้ำอีกครั้งเพราะคิดว่าไม่สำเร็จ (เพราะ UI ตอบช้า) จะเกิดอะไรขึ้น</summary>

ระบบจะปฏิเสธด้วย `409` เพราะกฎ "ปฏิเสธถ้า tenant มีบิลอยู่แล้ว" (มีแถวใน `sales`/`returns`/`purchase_orders`/`credit_payments`/`quotes`/`shifts`) — import ครั้งแรกสร้างบิลไว้แล้ว ครั้งที่สองจึงชนกฎนี้ทันที ป้องกันไม่ให้ข้อมูลถูกเบิ้ลสอง (ระบบ idempotent แบบ "ปฏิเสธซ้ำ" ไม่ใช่ "upsert")

</details>

<details><summary>5. ทำไม tombstone ถึงไม่ถือว่าขัดกับ ADR-0005 ที่บอกว่า "ไม่มี restore รายร้าน"</summary>

Tombstone สร้างแถว **soft-deleted** (มี `deleted_at` ตั้งแต่ตอน import) ไม่ใช่แถว live — มันไม่ได้ "คืนชีพ" ข้อมูลที่ร้านเคยลบทิ้งไปจริงๆ ให้กลับมาใช้งานได้ปกติ มันแค่สร้างแถวหลอกที่มี id ตรงกัน เพื่อให้ foreign key ของประวัติ (movements, sales, credit_payments) ที่ยังอ้างถึง id นั้นอยู่จริงมีที่ให้ชี้ ไม่ชนกับ Postgres constraint restore รายร้านที่ ADR-0005 ปฏิเสธ หมายถึงการเอาข้อมูลทั้งร้านที่ถูกลบไปย้อนกลับมาใช้งานปกติ ซึ่งคนละเรื่องกัน

</details>

<details><summary>6. ทำไม tenant export ถึงได้รับการยกเว้นจาก commit-ceiling guard (25 วินาที) แต่การเขียนอื่นๆ ในระบบไม่ได้รับการยกเว้นแบบนี้</summary>

เพราะ commit-ceiling guard มีไว้ป้องกันทรานแซกชันที่เขียนข้อมูลค้างยึด pool connection นานเกินไป แต่ export ทั้งร้าน**ไม่เขียนอะไรที่ client ไปดึงต่อผ่าน cursor sync** (write เดียวที่มันทำคือ `audit_log` ซึ่งไม่มีใคร pull) จึงไม่มีความเสี่ยงเรื่อง stale read จากการอ่านยาวเกินเพดาน ในขณะที่การเขียนอื่นๆ ทุกจุดมีผลต่อข้อมูลที่ client จะ sync กลับไป การขยายเพดานตรงนั้นเสี่ยงกว่ามาก และมี unit test (`tenant-job-runner.spec.ts`) คอยล้มถ้ามีที่อื่นแอบใช้ flag นี้

</details>

---

## ➡️ อ่านต่อ

- บทถัดไป: **offline / phase 2** (`10_offline_phase2.md`) — โครงสร้าง outbox + sync ที่จะมาทำหน้าที่ "ย้ายข้อมูลต่อเนื่อง" แทน import ครั้งเดียวแบบในบทนี้ เมื่อร้านย้ายไปทำงานแบบออฟไลน์-เฟิร์สเต็มรูปแบบ
- อยากเจาะลึกกฎ import ทั้งหมด: `docs/Backend_design/01_DATABASE.md §9` (แผนย้ายข้อมูลจากของเดิม), `docs/Backend_design/adr/0005-data-portability.md` (ADR-0005 — ทำไม export ได้แต่ restore รายร้านไม่ได้)
- อยากดูหลักฐานการรันจริงกับไฟล์ร้าน: `docs/handoff_log/close4-real-snapshot-2026-09-17.md` (ไฟล์จริง, ปิด #185), `docs/handoff_log/close4-synthetic-snapshot-2026-09-15.md` (ที่มาของ synthetic data ที่ใช้ทดสอบ pipeline ก่อนไฟล์จริงมาถึง)
- สถานะ cutover ร้านจริง: `docs/Backend_design/08_PHASE2_SPEC.md` (#231, ยังเป็นเฟสถัดไป ไม่มีกำหนดวัน)
