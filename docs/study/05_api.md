# 05 — API design + contract: ข้อตกลงระหว่างแอปกับ server

> บทนี้ตอบคำถาม: **"แอป Flutter กับ server คุยกันด้วย 'ภาษา' อะไร ใครเป็นคนกำหนดภาษานั้น
> และทำยังไงให้สองฝั่งที่เขียนโดยคนละคน คนละภาษา ไม่เข้าใจกันผิดจนเงินหาย"**

---

## 🧭 ก่อนอ่าน

- **ต้องอ่านก่อน:** [00_index.md](00_index.md) (หัวข้อ HTTP, JSON, API/REST) · [02_architecture.md](02_architecture.md)
  (ภาพรวมว่ามี client, Nginx, API, Postgres) · [04_frontend.md](04_frontend.md) (โดยเฉพาะ `ApiClient`,
  `rethrowThai`, `PendingWrites`)
- **อ่านต่อจากบทนี้:** บท backend [06_backend.md](06_backend.md) — บทนี้มอง API จาก **"ข้างนอก"**
  (สัญญาที่ตกลงกัน) ส่วนบท backend มองจาก **"ข้างใน"** (guard, `runTx`, lock, idempotency ทำงานยังไงในโค้ด)
- **เวลาที่ใช้:** ~2 ชั่วโมง (ถ้าลองยิง `curl` ตามส่วน hands-on ด้วย บวกอีก ~1 ชั่วโมง)
- **อ่านจบแล้วคุณจะ…**
  - อธิบายได้ว่า **API**, **interface**, **contract** ต่างกันยังไง และทำไม "สัญญา" สำคัญกว่า "โค้ด"
  - อ่าน HTTP request/response หนึ่งตัวออก: method, path, header, status code, body — และรู้ว่าแต่ละส่วนบอกอะไร
  - อธิบายได้ว่าทำไมเงินต้องส่งเป็น string `"1234.50"`, ทำไม error ต้องมีทั้ง `code` และ `message`,
    ทำไมการแบ่งหน้าแบบ keyset ถึงไม่ข้ามแถว
  - เข้าใจ **Idempotency-Key** ในฐานะ "ข้อตกลง" ระหว่าง client กับ server: key เดิม + body เดิม = คำตอบเดิม
  - เห็น bug จริงที่เกิดจาก **contract drift** (สองฝั่งเข้าใจสัญญาไม่ตรงกัน) และรู้ว่า repo นี้ใช้เครื่องมืออะไรกันไว้

---

## 🧱 ปูพื้นฐาน

ส่วนนี้ยังไม่พูดถึงโปรเจกต์ — สอน concept ทั่วไปก่อน

### 1. API คืออะไร — เคาน์เตอร์ร้านอะไหล่

นึกถึงร้านอะไหล่ที่มี **เคาน์เตอร์** กั้นระหว่างลูกค้ากับโกดังหลังร้าน

```
   ลูกค้า                 เคาน์เตอร์                    หลังร้าน (โกดัง)
 ┌────────┐   "ขอผ้าเบรก   ┌───────────┐   เดินไปหยิบ    ┌──────────────┐
 │  คุณ   │ ─ รุ่นนี้ 2 ชุด" ─▶│ พนักงาน   │ ─ เช็คสต็อก ──▶ │ ชั้นวาง, สมุด │
 │        │ ◀── "ได้ครับ     ─│ หน้าร้าน  │ ◀─ ตัดสต็อก ── │ บัญชี, ลิ้นชัก │
 └────────┘   ฿850" ─────  └───────────┘                 └──────────────┘
```

- ลูกค้า **ไม่ต้องรู้** ว่าโกดังจัดชั้นยังไง ใช้สมุดหรือคอมพิวเตอร์
- ลูกค้ารู้แค่ **"พูดอะไรกับเคาน์เตอร์ได้บ้าง"** และ **"จะได้คำตอบแบบไหนกลับมา"**
- ถ้าวันหนึ่งร้านเปลี่ยนจากสมุดเป็นคอมพิวเตอร์ ลูกค้าไม่ต้องเปลี่ยนวิธีพูดเลย — ตราบใดที่เคาน์เตอร์ยังรับคำพูดแบบเดิม

**API** (Application Programming Interface — "ช่องทางที่โปรแกรมหนึ่งเปิดให้โปรแกรมอื่นเรียกใช้") ก็คือเคาน์เตอร์นี้:

| ในร้าน | ในซอฟต์แวร์ |
|---|---|
| ลูกค้า | **client** (แอป Flutter บนเครื่องขาย) |
| เคาน์เตอร์ + รายการสิ่งที่ขอได้ | **API** (รายการ URL + รูปแบบข้อมูลที่รับ/ตอบ) |
| หลังร้าน | **implementation** (โค้ด NestJS + Postgres + Redis) |
| "ขอผ้าเบรก 2 ชุด" | **request** |
| "ได้ครับ ฿850" หรือ "ของหมดครับ" | **response** (สำเร็จ หรือ error) |

### 2. Interface vs implementation vs contract

สามคำนี้คนมักใช้ปนกัน แต่ต่างกันจริง:

- **Interface** (หน้าตาที่เรียกได้) — *"มีปุ่มอะไรบ้าง"* เช่น `POST /api/v1/sales` รับ body แบบนี้ ตอบแบบนี้
- **Implementation** (วิธีทำจริงข้างใน) — *"กดปุ่มแล้วข้างในทำอะไร"* เช่น lock แถวสินค้า, ตัดสต็อก, ออกเลขใบเสร็จ
- **Contract** (สัญญา) — interface **บวก** กติกาที่ทั้งสองฝั่งสัญญาว่าจะรักษา เช่น
  *"ถ้าส่ง `Idempotency-Key` เดิมพร้อม body เดิม server สัญญาว่าจะไม่ตัดสต็อกซ้ำ และตอบคำตอบเดิม"*
  หรือ *"client สัญญาว่าจะส่งเงินเป็น string ทศนิยมไม่เกิน 2 ตำแหน่ง"*

ตัวอย่างในชีวิตจริง: ปลั๊กไฟ 220V
- interface = รูปร่างเต้ารับ (ขาแบน 2 ขา)
- implementation = สายไฟในผนัง, โรงไฟฟ้า
- contract = "ไฟ 220V 50Hz ไม่เกิน 16A" — ถ้าการไฟฟ้าส่ง 380V มาแทน ปลั๊กยังเสียบได้ (interface เหมือนเดิม) แต่ตู้เย็นระเบิด (สัญญาพัง)

**ทำไมเรื่องนี้สำคัญกับโปรเจกต์ทีม:** แอป Flutter (Dart) กับ server (TypeScript) เขียนคนละภาษา คนละคน คนละ lane
compiler ของ Dart ไม่รู้จักโค้ด TypeScript และกลับกัน → **ไม่มีเครื่องมือไหนเช็คให้อัตโนมัติว่าสองฝั่งเข้าใจตรงกัน**
สิ่งเดียวที่ผูกสองฝั่งไว้คือ "สัญญา" ที่เขียนเป็นเอกสาร + test ที่บังคับสัญญานั้น

### 3. REST — resource + verb + status code

**REST** (REpresentational State Transfer — แนวทางออกแบบ API บน HTTP) มีหลักง่ายๆ 3 ข้อ:

**(ก) URL = "สิ่งของ" (resource)** ใช้คำนามพหูพจน์

```
/products          ← สินค้าทั้งหมด (collection)
/products/p12      ← สินค้าชิ้นเดียว id = p12
/customers/c5/sales ← บิลทั้งหมดของลูกค้า c5 (resource ซ้อน)
```

**(ข) HTTP method = "การกระทำ" (verb)**

| Method | ความหมาย | ตัวอย่าง |
|---|---|---|
| `GET` | อ่าน ไม่เปลี่ยนอะไร | `GET /products` |
| `POST` | สร้างใหม่ / สั่งให้ทำบางอย่าง | `POST /sales` (ขาย), `POST /shifts/open` (เปิดกะ) |
| `PUT` | แทนที่ทั้งก้อน | (repo นี้ไม่ใช้) |
| `PATCH` | แก้บางฟิลด์ | `PATCH /products/p12` |
| `DELETE` | ลบ | `DELETE /parked-sales/x1` |

> 💡 บางการกระทำไม่ใช่ "สร้าง/แก้/ลบ" ตรงๆ เช่น "ยกเลิกบิล" หรือ "รับของตามใบสั่งซื้อ" — REST ในทางปฏิบัติ
> มักใช้ `POST /resource/:id/<คำกริยา>` เช่น `POST /sales/:id/void`, `POST /purchase-orders/:id/receive`
> ไม่ต้องเคร่งจนต้องบิดเป็น `PATCH /sales/:id {voided:true}` ซึ่งซ่อนว่ามันมีผลข้างเคียง (คืนสต็อก, เขียน audit)

**(ค) Status code = "ผลลัพธ์แบบย่อ"** — ตัวเลข 3 หลัก หลักแรกบอกหมวด

| หมวด | ความหมาย | ตัวที่ repo นี้ใช้จริง |
|---|---|---|
| **2xx** | สำเร็จ | `200 OK`, `201 Created` (สร้างบิล), `202 Accepted` (รับงานไปทำเบื้องหลัง เช่น export backup), `304 Not Modified` (`/bootstrap` ที่ไม่เปลี่ยน) |
| **4xx** | **client ผิด** — ส่งซ้ำแบบเดิมก็ผิดเหมือนเดิม | `400` ข้อมูลผิดรูป · `401` ไม่ได้ login · `403` login แล้วแต่ไม่มีสิทธิ์ · `404` ไม่พบ · `409` ขัดกับสถานะปัจจุบัน (สต็อกไม่พอ, บิลถูก void แล้ว) · `429` ยิงถี่เกิน |
| **5xx** | **server ผิด / ไม่แน่ใจ** | `500` bug · `502/504` Nginx ติดต่อ API ไม่ได้/รอนานเกิน · `503` ยังไม่พร้อม หรือ "คำขอเดิมยังทำอยู่" |

จำให้ขึ้นใจ: **4xx = "คำตัดสิน"** (server ตอบชัดแล้วว่าไม่ได้) · **5xx = "ไม่รู้"** (อาจทำไปแล้วครึ่งทาง หรือทำเสร็จแล้วแต่ตอบไม่ทัน)
เรื่องนี้จะกลับมาเป็นหัวใจของส่วน "ของจริง" (หัวข้อ 6 ใน "🔍 ของจริงใน repo")

### 4. Safe และ idempotent methods

สองคำนี้เป็นคำจาก **สเปค HTTP เอง** (RFC 9110) ไม่ใช่ของ repo นี้:

- **Safe** (ปลอดภัย) = เรียกกี่ครั้งก็ **ไม่เปลี่ยนข้อมูล** → `GET`, `HEAD`
- **Idempotent** (เรียกซ้ำได้ผลเท่าเดิม) = เรียก 1 ครั้งหรือ 10 ครั้ง **สถานะสุดท้ายเหมือนกัน**

| Method | Safe? | Idempotent ตามสเปค? | ทำไม |
|---|---|---|---|
| `GET` | ✔ | ✔ | แค่อ่าน |
| `PUT` | ✘ | ✔ | "ตั้งค่าเป็น X" สิบครั้ง ก็ยังเป็น X |
| `DELETE` | ✘ | ✔ | ลบของที่ลบแล้ว ก็ยังไม่มีอยู่ (แม้ครั้งที่ 2 อาจตอบ 404) |
| `POST` | ✘ | **✘** | "ขายผ้าเบรก 2 ชุด" สองครั้ง = ขาย 4 ชุด |
| `PATCH` | ✘ | ✘ (ไม่รับประกัน) | "เพิ่มสต็อก +5" สองครั้ง = +10 |

**Analogy — ลิฟต์ vs ส่งพัสดุ:** กดปุ่มเรียกลิฟต์ 5 ครั้ง ลิฟต์ก็มาครั้งเดียว (idempotent)
แต่ถ้ากด "ส่งพัสดุ" 5 ครั้งแล้วบริษัทส่งพัสดุ 5 กล่อง — นั่นคือ `POST`

ปัญหาคือ **การขายของเป็น `POST`** และเน็ตร้านไม่เสถียร: ถ้า request ขายไปถึง server, server ตัดสต็อกเสร็จแล้ว
แต่ **คำตอบหายระหว่างทาง** แอปจะไม่รู้ว่าขายสำเร็จหรือยัง → พนักงานกดซ้ำ → ขายซ้ำ → ลูกค้าโดนคิดเงินสองรอบ
ทางออกคือทำให้ `POST` **กลายเป็น idempotent ด้วยสัญญาเพิ่ม** — นั่นคือ `Idempotency-Key` (อธิบายในส่วนของจริง)

### 5. กายวิภาคของ request / response

HTTP request หนึ่งตัวมี 4 ส่วน:

```http
POST /api/v1/sales HTTP/1.1                     ← (1) method + path + version
Host: localhost                                  ← (2) headers: ข้อมูลกำกับ "ซองจดหมาย"
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
Content-Type: application/json
Idempotency-Key: idem_01J8...
                                                  ← (3) บรรทัดว่างคั่น
{"id":"s_abc","subtotal":"255.00", ...}          ← (4) body: "จดหมาย" ข้างใน
```

Analogy ไปรษณีย์: **header = สิ่งที่เขียนบนหน้าซอง** (ส่งถึงใคร, ใครส่ง, ลงทะเบียนเลขอะไร)
**body = จดหมายข้างใน** ไปรษณีย์ (Nginx, middleware) อ่านหน้าซองได้โดยไม่ต้องแกะจดหมาย

Header สำคัญที่บทนี้จะเจอ:

| Header | ทิศ | หน้าที่ |
|---|---|---|
| `Authorization: Bearer <token>` | client → server | "ผู้ถือบัตรนี้คือใคร" — **Bearer** แปลว่า "ใครถือบัตรก็ใช้ได้" จึงห้ามรั่ว |
| `Content-Type: application/json` | ทั้งสองทิศ | body เป็น JSON |
| `Idempotency-Key: <id>` | client → server | "นี่คือความพยายามครั้งที่ n ของ **คำสั่งเดียวกัน**" |
| `Retry-After: 30` | server → client | "รออีก 30 วินาทีค่อยลองใหม่" (มากับ `429`) |
| `ETag` / `If-None-Match` | ทั้งสองทิศ | "ข้อมูลรุ่นนี้" / "ถ้ายังเป็นรุ่นนี้อยู่ ไม่ต้องส่งมาใหม่" → `304` |
| `X-Correlation-ID` | ทั้งสองทิศ | เลขติดตาม request ข้าม log หลายเครื่อง |

### 6. Response envelope — ซองมาตรฐาน

ถ้าแต่ละ endpoint ตอบรูปร่างต่างกัน (อันหนึ่งตอบ array ตรงๆ อีกอันตอบ `{result: ...}` อีกอันตอบ `{ok: true, item: ...}`)
client ต้องเขียนโค้ดแกะแยกทุกตัว **Envelope** (ซองมาตรฐาน) คือการตกลงว่า *ทุก* คำตอบห่อด้วยรูปร่างเดียวกัน:

```jsonc
// สำเร็จ
{ "status": "success", "data": <อะไรก็ได้>, "meta": { ... } /* มีเฉพาะตอนแบ่งหน้า */ }
// ผิดพลาด
{ "status": "error", "error": { "code": "...", "message": "...", "details": ... } }
```

client จึงเขียนตัวแกะ **ครั้งเดียว** แล้วใช้กับทุก endpoint

### 7. Versioning — ใส่เลขรุ่นใน URL

แอปที่ติดตั้งบนเครื่องลูกค้าแล้ว **อัปเดตไม่พร้อมกัน** ถ้าวันหนึ่ง server เปลี่ยนรูปร่าง body ของ `/sales`
แอปรุ่นเก่าที่ยังไม่อัปเดตจะพังทันที ทางแก้มาตรฐานคือใส่ **version** ไว้ใน path: `/api/v1/...`
วันที่ต้องเปลี่ยนแบบ "ไม่เข้ากันกับของเดิม" (**breaking change**) ก็เปิด `/api/v2/...` คู่กันไป ให้ `v1` อยู่จนแอปเก่าหมด

อีกแบบคือใส่ version ใน header (`Accept: application/vnd.x.v2+json`) — ยืดหยุ่นกว่า แต่มองไม่เห็นใน log/URL และ debug ยากกว่า
repo นี้เลือกใส่ใน path

การเปลี่ยนที่ **ไม่ต้องขึ้น version** (non-breaking): เพิ่มฟิลด์ใหม่ใน response, เพิ่ม endpoint ใหม่, เพิ่มฟิลด์ optional ใน request
— เพราะ client ที่ดีต้อง **เมินฟิลด์ที่ไม่รู้จัก** (และ client ของ repo นี้มีกติกาคู่กันว่า *"ฟิลด์ที่ response ไม่ส่งมา ห้ามไปลบค่าในแถว"*)

### 8. Pagination — offset vs keyset

สินค้าหลายพันชิ้นส่งทีเดียวไม่ไหว ต้องแบ่งหน้า มี 2 แบบหลัก:

**(ก) Offset** — "ข้าม n แถวแรก แล้วเอามา 50" (`?page=3&limit=50` → `OFFSET 100 LIMIT 50`)

ง่าย กระโดดไปหน้า 7 ได้เลย เหมาะกับหน้าจอที่คนกดดูเป็นหน้าๆ แต่ **พังเมื่อข้อมูลเปลี่ยนระหว่างอ่าน**:

```
ตอนอ่านหน้า 1 (เรียงตาม updated_at):    [A B C D E] | F G H I J | ...
                                        ^^^^^^^^^ ได้หน้า 1 = A..E

ระหว่างนั้นมีคนขาย B → B ถูกแก้ updated_at → ย้ายไปท้ายสุด
ตอนอ่านหน้า 2:                          [A C D E F] | G H I J B |
                                                     ^^^^^^^^^ OFFSET 5 → ได้ G..J, B
                                        👉 F หลุดหายไป ไม่เคยถูกส่งเลย
```

แถว **F ถูกข้าม** เพราะทุกอย่างเลื่อนขึ้นหนึ่งช่อง — ถ้านี่คือการ sync ราคาสินค้าลงเครื่องขาย F จะค้างราคาเก่าไปเรื่อยๆ โดยไม่มีใครรู้

**(ข) Keyset (cursor)** — "เอาแถวที่ **อยู่ถัดจาก** แถวสุดท้ายที่ฉันเห็น" (`WHERE (updated_at, id) > (ts_สุดท้าย, id_สุดท้าย)`)

ไม่นับตำแหน่ง แต่จำ "ที่คั่นหนังสือ" ไว้ แถวที่ถูกแก้ระหว่างนั้นจะมี `updated_at` ใหม่ **มากกว่า** ที่คั่น จึงโผล่ในหน้าหลังๆ แน่นอน
ไม่มีแถวไหนหลุด ข้อเสีย: กระโดดไปหน้า 7 ตรงๆ ไม่ได้ ต้องเดินทีละหน้า — ซึ่งการ sync ก็เดินทีละหน้าอยู่แล้ว

> ทำไมต้องมี `id` ต่อท้าย? เพราะหลายแถวอาจมี `updated_at` **เท่ากันเป๊ะ** (บิลเดียวตัดสต็อก 5 สินค้าในทรานแซกชันเดียว
> ได้ `now()` ค่าเดียวกัน) ถ้าที่คั่นเป็นแค่เวลา แถวที่เวลาเท่ากันแต่อยู่ข้ามหน้าจะหาย `id` ทำหน้าที่ตัดสินเสมอ (**tie-breaker**)

### 9. Error design — code สำหรับเครื่อง, message สำหรับคน

error ที่ดีต้องตอบคน **สองกลุ่ม**:

- **โปรแกรม** ต้องการ **ค่าที่ไม่เปลี่ยน** ไว้ `if` — เช่น `"INSUFFICIENT_STOCK"` (ภาษาอังกฤษตัวใหญ่ ไม่เปลี่ยนตามภาษา UI)
- **คน** ต้องการ **ประโยคที่อ่านรู้เรื่อง** — เช่น `"สต็อกไม่พอ:\nผ้าเบรกหน้า: สต็อก 2 แต่ต้องการ 5"`
- บางทีต้องการ **ข้อมูลประกอบ** ให้โปรแกรมเอาไปทำ UI — `details: [{productId, stock, requested}]`

ถ้ามีแค่ message: client ต้อง `if (msg.contains('สต็อก'))` → วันที่แก้คำผิดในข้อความ ฟีเจอร์พังเงียบๆ
ถ้ามีแค่ code: ทุก client ต้องแปลเอง และแปลไม่ตรงกัน

### 10. Rate limit — `429` + `Retry-After`

**Rate limit** (จำกัดความถี่) = "คนหนึ่งยิงได้ไม่เกิน N ครั้งต่อวินาที" กันทั้งคนร้าย (ยิงเดารหัสผ่าน) และ
**noisy neighbor** (ร้านหนึ่งยิงหนักจนร้านอื่นในระบบเดียวกันช้า) เกินแล้วตอบ `429 Too Many Requests`
พร้อม `Retry-After` บอกว่าควรรอกี่วินาที — client ที่ดีต้อง **รอ** ไม่ใช่ยิงซ้ำทันที (ยิงซ้ำทันทียิ่งโดนนับ)

### 11. CORS — ทำไม browser ถึงบล็อก

**Same-origin policy**: browser ไม่ยอมให้ JavaScript จากเว็บ `a.com` อ่านคำตอบจาก `b.com` โดยอัตโนมัติ
(ไม่งั้นเว็บร้ายเปิดอยู่ในแท็บหนึ่ง แอบยิงไปธนาคารของคุณในอีกแท็บ แล้วอ่านยอดเงินได้)

**CORS** (Cross-Origin Resource Sharing) คือกลไกที่ **server** ประกาศว่า "origin ไหนอ่านคำตอบฉันได้"
ผ่าน header `Access-Control-Allow-Origin` ก่อน request จริง browser อาจยิง **preflight** (`OPTIONS`) ไปถามก่อนว่า
"method/header แบบนี้รับไหม" จุดสำคัญ: **CORS บังคับโดย browser เท่านั้น** — `curl` หรือแอป native ไม่สนใจ CORS
ดังนั้น CORS ไม่ใช่ระบบ auth มันแค่กันเว็บอื่นมา "ใช้ browser ของผู้ใช้" ยิงแทน

### 12. REST vs GraphQL vs gRPC vs RPC — เทียบสั้นๆ

| แบบ | หน้าตา | เด่น | ด้อย |
|---|---|---|---|
| **REST + JSON** | `GET /products/p12` | เข้าใจง่าย, ใช้ HTTP cache/status code/Nginx ได้ตรงๆ, debug ด้วย `curl` | ต้องยิงหลายรอบถ้าหน้าจอต้องการข้อมูลหลายชนิด |
| **GraphQL** | `POST /graphql {query: "{ product(id:"p12"){ name stock } }"}` | client เลือกฟิลด์เอง ยิงรอบเดียวได้หลายชนิด | ทุกอย่างเป็น `POST` + `200` → status code/HTTP cache ใช้ไม่ได้ตรงๆ, rate limit ยาก (query หนึ่งหนักเท่าไหร่?) |
| **gRPC** | สร้างโค้ด client จากไฟล์ `.proto` | เร็ว (binary), type ตรงกันสองฝั่งอัตโนมัติ | browser เรียกตรงไม่ได้ (ต้องมี proxy), debug ด้วยตาเปล่าไม่ได้ |
| **RPC แบบ JSON** | `POST /api {method:"createSale", params:{...}}` | ง่ายมาก | ไม่มีมาตรฐาน status/cache, ทุกอย่างผ่าน URL เดียว |

### 13. OpenAPI / Swagger — "สัญญาที่เครื่องอ่านได้"

**OpenAPI** (ชื่อเดิม Swagger) คือไฟล์ YAML/JSON ที่บรรยายทุก endpoint แบบเครื่องอ่านได้ จากไฟล์นี้สร้างได้ทั้ง
หน้าเอกสาร, โค้ด client อัตโนมัติ, และ test ที่ตรวจว่า server ตอบตรงสเปค

> 🔴 **บอกตรงๆ: repo นี้ไม่มี OpenAPI/Swagger** (ตรวจแล้ว: ไม่มี package `@nestjs/swagger` ใน `server/package.json`
> ไม่มีไฟล์ `openapi*`/`swagger*` ใน repo) สัญญาของ repo นี้อยู่ใน **เอกสารมนุษย์อ่าน**
> [`docs/Backend_design/02_API_SCREENS.md`](../Backend_design/02_API_SCREENS.md) + **fixture JSON** + **test**
> ข้อดี-ข้อเสียของการเลือกแบบนี้อยู่ในส่วน ⚖️ ข้างล่าง

---

## 🔥 ปัญหาจริงของร้าน

ร้านอะไหล่เป็นโจทย์ API ที่โหดกว่าที่เห็น:

1. **เน็ตร้านไม่เสถียร** — request ขายไปถึง server แล้ว server commit แล้ว แต่คำตอบหายระหว่างทาง
   แอปเห็นแค่ "timeout" → ถ้าสัญญาไม่ชัด พนักงานกดอีกทีกลายเป็นบิลที่สอง **ลูกค้าจ่ายสองรอบ**
2. **เงินต้องตรงถึงสตางค์** — ใบเสร็จพิมพ์ออกไปก่อน server ตอบ (client เป็นเจ้าของตัวเลข, server เป็นผู้ตรวจ — `02_API_SCREENS.md §1.3`)
   ถ้าสองฝั่งปัดเศษต่างกันแม้ 1 สตางค์ ใบเสร็จในมือลูกค้าไม่ตรงกับยอดในระบบ
3. **พนักงานอ่านภาษาอังกฤษไม่ถนัด** และคุ้นกับข้อความ error ของแอปเดิม (`db.js`) — error ต้องเป็นภาษาไทย **ตรงตัวอักษร** กับของเดิม
4. **ทีม 3 คนเขียนคนละฝั่ง** — lane B เขียน engine ฝั่งแอป, lane C เขียน server (ดู `09_PHASE2_LANES.md`)
   ถ้าต้องรอให้อีกฝั่งเสร็จก่อนถึงจะทดสอบได้ งานจะต่อคิวกันจนไม่ทัน
5. **หลายร้านใช้ server เดียว** (multi-tenant) — ร้านหนึ่งยิงหนักต้องไม่ทำให้ร้านอื่นขายไม่ได้ และห้ามร้านหนึ่งเห็นข้อมูลอีกร้าน

ทุกข้อข้างบนแก้ด้วย **"สัญญา"** มากกว่า "โค้ดเก่ง" — ส่วนที่เหลือของบทคือสัญญาแต่ละข้อ

---

## ⚖️ ทางเลือก → ทำไมเลือกอันนี้

### 1. รูปแบบ API: REST+JSON vs GraphQL vs gRPC

| เกณฑ์ | REST+JSON ✅ | GraphQL | gRPC |
|---|---|---|---|
| Flutter **web** เรียกตรงได้ | ✔ | ✔ | ✘ ต้องมี proxy |
| Nginx rate limit / cache ตาม path ได้ | ✔ | ✘ (ทุกอย่าง `POST /graphql`) | ยาก |
| status code บอก "คำตัดสิน vs ไม่รู้" | ✔ (4xx vs 5xx) | ✘ (ส่วนใหญ่ตอบ 200 + errors) | มี status ของตัวเอง |
| นักศึกษาปี 1 debug ด้วย `curl` | ✔ | พอได้ | ✘ |
| สเปคที่อาจารย์กำหนด (envelope `status/data/error`) | ตรง | ต้องดัดแปลง | ต้องดัดแปลง |

เพราะ **กติกา "4xx = คำตัดสิน, 5xx = ไม่รู้" เป็นหัวใจของการไม่ขายซ้ำ** → จึงต้องใช้ HTTP status code ตามความหมายจริง → REST
→ ราคาที่จ่าย: หน้าจอที่ต้องการข้อมูลหลายชนิดต้องยิงหลายรอบ (repo แก้บางส่วนด้วย `GET /bootstrap` ที่รวม products+categories+customers+mechanics+settings ไว้ในคำตอบเดียว)

### 2. สัญญาเก็บที่ไหน: OpenAPI vs เอกสาร markdown + fixtures + test

| | OpenAPI (ไม่ได้เลือก) | markdown + fixtures + test ✅ |
|---|---|---|
| สร้างโค้ด client อัตโนมัติ | ✔ | ✘ เขียนมือ |
| อธิบาย "ทำไม" + ข้อความไทยที่เจ้าของร้านเคาะ | อึดอัด | ✔ เป็นธรรมชาติ |
| ตรวจว่าโค้ดตรงสัญญาอัตโนมัติ | ✔ (ถ้าตั้ง tooling) | เฉพาะจุดที่มี test |
| ต้องเรียนเครื่องมือเพิ่ม | ✔ | ✘ |

เพราะทีมเป็นนักศึกษาและสัญญาส่วนใหญ่เป็น **"กติกาพฤติกรรม"** (replay, lock order, ข้อความไทย) ที่ OpenAPI บรรยายไม่ได้อยู่แล้ว
→ จึงเก็บใน markdown + fixture JSON + test → ราคาที่จ่าย: **สองฝั่งหลุดจากกันได้โดยไม่มีใครเตือน** ถ้าไม่มี test ครอบจุดนั้น
(bug HIGH ในส่วน ⚠️ คือราคานี้ที่จ่ายจริง)

### 3. เงินบนสาย: number vs string vs integer สตางค์

| แบบ | ตัวอย่าง | ปัญหา |
|---|---|---|
| JSON number | `1234.5` | client/JS แปลงเป็น float → `0.1 + 0.2 = 0.30000000000000004` |
| **string ทศนิยม 2 ตำแหน่ง ✅** | `"1234.50"` | ต้อง parse เอง (แต่ parse แบบแม่นได้) |
| integer สตางค์ | `123450` | ปลอดภัย แต่อ่านยาก พลาดคูณ/หาร 100 ง่าย และไม่ตรงสเปคเดิม |

เพราะ Postgres เก็บเงินเป็น `NUMERIC` (ทศนิยมแม่นยำ) แต่ JSON number ถูกอ่านเป็น float ในเกือบทุกภาษา → จึงส่งเป็น string
→ ราคา: ทุกฝั่งต้องมีฟังก์ชันแปลงของตัวเอง (`wireMoney` ใน Dart, `toSatang` ใน TS) — และ server ภายในก็แปลงเป็น **integer สตางค์** ก่อนคำนวณอยู่ดี

### 4. กันขายซ้ำ: dedupe ด้วย bill id อย่างเดียว vs Idempotency-Key vs ทั้งคู่

repo นี้ใช้ **ทั้งคู่** — `Idempotency-Key` เป็นด่านแรก (replay คำตอบเดิม) และ bill `id` ที่ client สร้าง
เป็นด่านที่สอง (`SALE_ID_REUSED` ถ้า id ซ้ำแต่ยอดไม่ตรง) เพราะ key เป็นกลไกทั่วไปใช้ได้กับ *ทุก* write
ส่วน id ผูกกับบิลจริง ราคาที่จ่าย: client ต้อง **จำ id + key ของความพยายามที่ยังไม่รู้ผล** (`PendingWrites`) — ลืมเมื่อไหร่ ด่านทั้งสองพังพร้อมกัน

### 5. แบ่งหน้า: offset vs keyset

repo ใช้ **ทั้งสอง แยกตามงาน**: หน้าจอรายการทั่วไปใช้ `?page=&limit=` (offset — default 50, max 200)
ส่วนการ sync แคตตาล็อกลงเครื่อง (`GET /products?updatedSince=&afterId=`) ใช้ keyset
เพราะหน้าจอคนดูทนแถวเลื่อนได้ (กดรีเฟรชเอา) แต่การ sync ที่ข้ามแถว = ราคาผิดค้างในเครื่องขาย

---

## 🔍 ของจริงใน repo

### 1. Global prefix `/api/v1` — และ 3 path ที่อยู่นอก prefix

`server/src/app.setup.ts:120-126`

```ts
  app.setGlobalPrefix('api/v1', {
    exclude: [
      { path: 'health/live', method: RequestMethod.GET },
      { path: 'health/ready', method: RequestMethod.GET },
      { path: 'metrics', method: RequestMethod.GET },
    ],
  });
```

- **ทำอะไร:** ทุก controller ได้ `/api/v1` นำหน้าอัตโนมัติ — `@Controller('sales')` กลายเป็น `/api/v1/sales`
  **ยกเว้น** 3 path ที่อยู่ที่ root: `/health/live`, `/health/ready`, `/metrics`
- **ทำไมยกเว้น:** health probe เป็นของ load balancer/Docker ไม่ใช่ของ client ร้าน และ Prometheus เก็บ `/metrics`
  ทั้งสามไม่ควรเปลี่ยนตาม version ของ API ร้าน
- **อีกจุดที่ต้องรู้:** admin plane อยู่ **ใต้** prefix ด้วย คือ `/api/v1/platform/*` (ไม่ใช่ `/platform/*` ที่ root —
  `02_API_SCREENS.md §4.1` เคยเขียนผิด และแก้แล้ว 2026-09-23)

> ⚠️ **แก้ความเข้าใจผิดที่พบบ่อย:** "อยู่นอก prefix" **ไม่ได้แปลว่า** "ไม่ห่อ envelope"
> `/health/live` **ยังห่อ envelope** — `server/README.md` บรรทัด 18 แสดงผลเป็น
> `{"status":"success","data":{"status":"up"}}` และ `server/test/health.e2e-spec.ts:35` ชื่อ test คือ
> *"GET /health/live → 200 success envelope, outside /api/v1"* ตัวที่ **ไม่ห่อ** มีตัวเดียวคือ `/metrics`
> (ดูข้อ 10)

### 2. แผนที่ endpoint ทั้งหมด (สร้างจาก controller จริง)

นับจาก decorator `@Get/@Post/@Patch/@Delete` ใน `server/src/**/*.controller.ts` และ `server/src/products/catalogue.controllers.ts`
ได้ **89 route ที่ลงทะเบียนจริง** (ไม่มี `@Put` เลยแม้แต่ตัวเดียว)

> 🔎 ตอนนับเจอไฟล์ `server/src/purchasing/purchasing.controller.ts` (`PurchasingController`, 6 route) ที่
> **ไม่ถูกลงทะเบียน** — `purchasing.module.ts:9` ลงทะเบียนแค่ `PurchaseOrdersController` จาก
> `purchase-orders.controller.ts` และไม่มีไฟล์ไหน import `purchasing.controller.ts` เลย ไฟล์นี้จึงเป็น dead code
> ที่ยิงไม่ถึง (ตารางข้างล่างใช้ของ `purchase-orders.controller.ts`)

**วิธีอ่านตาราง** (path ทั้งหมดอยู่ใต้ `/api/v1` ยกเว้นระบุ):
- **Guard** = ใครเรียกได้: `Tenant` = ต้องมี JWT ของร้าน (`TenantGuard`) · `pos` = ต้องเป็นเครื่องขายด้วย (`@RequireDeviceRole('pos')`)
  · `Device` = ใช้ `X-Device-Token` แทน JWT · `Platform` = JWT ของผู้ดูแลระบบ + IP allowlist · `–` = ไม่ต้อง login
- **Idem** = ✔ ต้องส่ง `Idempotency-Key` (ผ่าน `runIdempotent`) · `GET` ทุกตัวไม่ต้อง (safe อยู่แล้ว)
- **หน้าจอ** = ตาม `02_API_SCREENS.md §2`

| Resource | Method + path | Guard | Idem | หน้าจอที่ใช้ |
|---|---|---|---|---|
| **auth** | `POST /auth/token` · `POST /auth/refresh` · `POST /auth/device` | – (มี throttle ต่อ IP) | – | `/login`, `/devices` (enrol) |
| | `GET /auth/me` | Tenant | – | |
| **bootstrap** | `GET /bootstrap` (มี `ETag`) | Tenant | – | Checkout (เปิดแอป) |
| **products** | `GET /products` · `GET /products/:id` · `GET /products/:id/suppliers` | Tenant | – | Products, Checkout (สแกนบาร์โค้ด `?partNo=`), Vehicle Search |
| | `POST /products` · `PATCH /products/:id` · `DELETE /products/:id` · `POST /products/:id/adjust-stock` | Tenant | ✔ | Products |
| **categories** | `GET /categories` · `POST /categories` · `DELETE /categories/:name` | Tenant | ✔ (write) | Products |
| **suppliers** | `POST /suppliers` · `PATCH /suppliers/:id` · `DELETE /suppliers/:id` | Tenant | ✔ | Products |
| **movements** | `GET /movements` | Tenant | – | Products |
| **customers** | `GET /customers` · `GET /customers/:id` · `GET /customers/:id/sales` | Tenant | – | Customers |
| | `POST /customers` · `PATCH /customers/:id` · `DELETE /customers/:id` | Tenant | ✔ | Customers, Checkout |
| **mechanics** | `GET /mechanics` · `GET /mechanics/:id` · `GET /mechanics/:id/sales` | Tenant | – | Mechanics |
| | `POST /mechanics` · `PATCH /mechanics/:id` · `DELETE /mechanics/:id` | Tenant | ✔ | Mechanics |
| | `POST /mechanics/:id/credit-payments` | Tenant + **pos** | ✔ | Mechanics |
| **sales** ⭐ | `POST /sales` | Tenant + **pos** | ✔ | **Checkout** |
| | `GET /sales` · `GET /sales/:id` · `GET /sales/:id/refunded-qty` | Tenant | – | Returns |
| | `POST /sales/:id/void` | Tenant + **pos** | ✔ | Returns |
| **returns** ⭐ | `POST /returns` | Tenant + **pos** | ✔ | Returns |
| | `GET /returns` | Tenant | – | Returns |
| **quotes** | `GET /quotes` · `GET /quotes/:id` | Tenant | – | Quotes |
| | `POST /quotes` · `PATCH /quotes/:id` · `DELETE /quotes/:id` · `POST /quotes/:id/duplicate` · `POST /quotes/purge` | Tenant | ✔ | Quotes, Checkout |
| | `POST /quotes/:id/convert` | Tenant + **pos** | ✔ | Quotes |
| **parked-sales** | `GET /parked-sales` · `POST /parked-sales` · `DELETE /parked-sales/:id` | Tenant + **pos** (ทั้ง class) | ✔ (write) | Checkout |
| **purchase-orders** ⭐ | `GET /purchase-orders` · `GET /purchase-orders/:id` | Tenant | – | Purchase Orders |
| | `POST /purchase-orders` · `POST /:id/receive` · `POST /:id/cancel` · `DELETE /:id` | Tenant | ✔ | Purchase Orders |
| **shifts** | `GET /shifts/current` · `GET /shifts/history` | Tenant | – | Cash Drawer |
| | `POST /shifts/open` · `POST /shifts/close` · `POST /shifts/current/entries` | Tenant + **pos** | ✔ | Cash Drawer |
| **reports** | `GET /reports/summary` · `/closing` · `/top-products` · `/by-category` · `/stock-value` · `/low-stock` · `/product-sales` | Tenant | – | Reports, Cash Drawer (closing), Products |
| **settings** | `GET /settings` · `PATCH /settings` | Tenant | ✔ (PATCH) | Settings |
| **backup** | `POST /backup/export` (ตอบ `202`) · `GET /backup/jobs/:id` | Tenant | ✘ | Settings |
| **doc-counters** | `GET /doc-counters` | Tenant + **pos** | – | (เปิดแอป — seed เลขเอกสาร) |
| **devices** | `GET /devices` · `POST /devices` · `POST /devices/:id/retire` | Tenant | ✔ (write) | `/devices` |
| **review-items** | `GET /review-items` · `POST /review-items/:id/reviewed` | Tenant | ✔ (write) | หน้า "รอ owner" (phase 2) |
| **sync** | `POST /sync/push` | **Device** (`X-Device-Token`) | ต่อ op (key อยู่ใน body) | engine sync เบื้องหลัง (phase 2) |
| | `POST /sync/discards` | Tenant **หรือ** Device | ✔ | หน้า "รอ owner" |
| **platform** (admin) | `POST /platform/auth/token` | – (แต่ Nginx กรอง IP) | – | ไม่มีในแอป — ops ใช้ |
| | `POST /platform/tenants` · `PATCH /platform/tenants/:id/status` · `GET /platform/tenants` · `POST /platform/tenants/:id/import` · `GET /platform/tenants/:id/import/:jobId` | Platform | ✘ ไม่มี key | ไม่มีในแอป |
| **root** (นอก `/api/v1`) | `GET /health/live` · `GET /health/ready` · `GET /metrics` | – | – | Docker/LB, Prometheus |

⭐ = 3 endpoint หัวใจที่ต้อง "transaction + idempotent + invalidate cache" (`02_API_SCREENS.md §2`)

ข้อสังเกตที่ได้จากตาราง:
- **ทุก write ที่แตะเงิน/สต็อก มี ✔** — ไม่ใช่บังเอิญ มี architecture spec (`server/src/idempotency/idempotency-routes.spec.ts`)
  อ่าน source ของทุก controller เพื่อบังคับเรื่องนี้ (รายละเอียดในบท backend)
- **ทุกอย่างที่เกี่ยวกับลิ้นชักเงินต้องเป็น `pos`** (ADR-0004: สิ่งที่แตะลิ้นชักเกิดบนเครื่องขายเท่านั้น) — `backoffice` ดูรายงานได้ แต่ขายไม่ได้
- **`POST /backup/export` ไม่มี key** — ส่งซ้ำได้งาน export ซ้ำ ซึ่งไม่เสียหายเรื่องเงิน · platform ก็ไม่มี key เช่นกัน
  (`02_API_SCREENS.md §4.1` ยอมรับตรงๆ ว่าตารางเดิมเขียน ✔ ไว้ แต่โค้ดไม่มี)

### 3. Response envelope — ของจริง

`server/src/common/envelope.interceptor.ts:15-28`

```ts
@Injectable()
export class EnvelopeInterceptor implements NestInterceptor {
  intercept(_ctx: ExecutionContext, next: CallHandler): Observable<unknown> {
    return next
      .handle()
      .pipe(
        map((data) =>
          data instanceof Paginated
            ? { status: 'success', data: data.items, meta: data.meta }
            : { status: 'success', data },
        ),
      );
  }
}
```

- **ทำอะไร:** handler คืนค่าอะไรมา interceptor ห่อเป็น `{status:'success', data}` ให้ ถ้าคืน `Paginated` จะแยก `meta` ออกมาไว้ข้าง `data`
- **ทำไมเช็ค `instanceof Paginated` แทนการดูว่ามี key `items`:** comment ใน `server/src/common/paginated.ts` บอกว่า
  handler ที่ *ตั้งใจ* คืน `{items, total}` เป็น payload จริงต้องไม่ถูกบิดรูปร่างเงียบๆ — ใช้ class เป็นป้ายชัดเจนกว่าเดาจากชื่อ key
- **ฝั่ง error** ทำโดย `HttpExceptionFilter` → `toErrorEnvelope` (`server/src/common/http-exception.filter.ts:21-44`):

```ts
          code: typeof obj.code === 'string' ? obj.code : HttpStatus[status],
          message:
            typeof obj.message === 'string' ? obj.message : exception.message,
          ...(obj.details !== undefined ? { details: obj.details } : {}),
```

  ถ้าโค้ดโยน `HttpException({code, message, details}, status)` จะได้ code ตามนั้น ถ้าโยนแบบธรรมดาไม่ใส่ code
  จะได้ **ชื่อ status** แทน (`401` → `"UNAUTHORIZED"`, `400` → `"BAD_REQUEST"`) error ที่ไม่ใช่ HTTP เลย (bug) จะกลายเป็น
  `500 INTERNAL_ERROR` + ข้อความกลางๆ `"Internal server error"` — **ไม่รั่ว stack trace** ให้ client
- **404 ที่ไม่ผ่าน Nest เลย** ก็ยังได้ envelope: `app.setup.ts` ท้ายไฟล์ต่อ handler สุดท้ายที่แปลงทุก path ที่ไม่รู้จักเป็น envelope
  (comment: *"Keep the envelope everywhere."*)

**ตัวอย่าง JSON จริง** — ขายของที่สต็อกไม่พอ ข้อความสร้างจาก `server/src/sales/sales.service.ts:548-563`:

```json
{
  "status": "error",
  "error": {
    "code": "INSUFFICIENT_STOCK",
    "message": "สต็อกไม่พอ:\nผ้าเบรกหน้า: สต็อก 2 แต่ต้องการ 5",
    "details": [ { "productId": "p12", "stock": 2, "requested": 5 } ]
  }
}
```

(HTTP status `409` — "ขัดกับสถานะปัจจุบัน" ไม่ใช่ `400` เพราะ request รูปแบบถูกต้อง แค่ของไม่พอ ณ ตอนนี้)

**ตัวอย่าง success** — รูปร่างมาจาก fixture `docs/Backend_design/fixtures/sync-push/sale-create.replay-by-key.json`
(ฟิลด์ใน `data` ย่อมาแค่บางส่วน):

```json
{
  "status": "success",
  "data": {
    "id": "s_off_001",
    "receiptNo": "RC01-2569-09-0042",
    "total": "255.00",
    "pointsGranted": 25,
    "products": [ { "id": "p1", "stock": 45 } ]
  }
}
```

สังเกต: `total` เป็น **string**, `pointsGranted` เป็น number (เป็นจำนวนเต็มไม่ใช่เงิน), และ server ส่ง **stock ใหม่** ของสินค้าที่ถูกตัดกลับมาด้วย
เพื่อให้ client เอาไป patch แคชใน Drift ได้เลยไม่ต้องยิง `GET` อีกรอบ (ADR-0010 write-through cache)

### 4. จาก error code → ประโยคภาษาไทยบนจอ

เส้นทางของ error หนึ่งตัว:

```
server โยน HttpException({code:'INSUFFICIENT_STOCK', message:'สต็อกไม่พอ:\n…'}, 409)
   │  HttpExceptionFilter → envelope {status:'error', error:{code,message,details}}
   ▼
ApiClient (frontend/lib/core/network/api_client.dart:491) แกะ error.code / error.message
   │  → throw ApiException(statusCode: 409, code: 'INSUFFICIENT_STOCK', ...)
   ▼
ApiException.thaiMessage → ServerErrorResolver.resolve(code, serverMessage)
   │  (frontend/lib/core/network/server_error_resolver.dart)
   ▼
rethrowThai → PosException(code, "ข้อความไทย")   ← ApiException ห้ามถึงจอ
   ▼
หน้าจอแสดง e.toString() = ข้อความไทยล้วน
```

ลำดับการเลือกข้อความใน `ServerErrorResolver.resolve` (`server_error_resolver.dart:114-150`):

1. ถ้า server ส่ง message ที่ **ขึ้นต้นด้วยอักษรไทย** → ใช้อันนั้น (เพราะมันละเอียดกว่า เช่นบอกชื่อสินค้าที่ขาด)
2. ไม่งั้นดูตาราง `_canonicalMessages` ตาม code (คัดจาก `02_API_SCREENS.md §8`/`§8.1`)
3. ไม่งั้นใช้ message จาก server ตรงๆ
4. ไม่งั้น `เกิดข้อผิดพลาด (<CODE>)`

ตัวอย่างบางแถวจากตาราง (`server_error_resolver.dart:45-104`):

```dart
    'INSUFFICIENT_STOCK': 'สต็อกไม่พอ',
    'OVER_REFUND': 'คืนเกินจำนวนที่ขาย',
    'NO_OPEN_SHIFT': 'กรุณาเปิดกะก่อน',
    'RATE_LIMITED': 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
    'IDEMPOTENCY_KEY_REUSED': 'คีย์การทำรายการซ้ำกับคำขออื่น',
    'IDEMPOTENCY_KEY_IN_FLIGHT': 'คำขอก่อนหน้ากำลังดำเนินการ กรุณารอสักครู่',
```

- **ทำไมเช็ค "ขึ้นต้นด้วยไทย" แทน "มีอักษรไทย":** comment บอกว่า message ภาษาอังกฤษบางอันอ้างคำไทย
  (`"Refund method 'หักจากเครดิต'..."`) ถ้าเช็คแค่ "มีไทย" ข้อความอังกฤษแบบนี้จะแย่งที่ข้อความไทยมาตรฐาน
- **ทำไม 5xx ไม่ใช้ message ของ server:** `resolveCounterError` คืนข้อความเชื่อมต่อกลางๆ สำหรับทุก `>= 500`
  เพราะ 5xx คือ "ไม่รู้ผล" — ข้อความเทคนิคของ server ไม่ช่วยพนักงาน และอาจมี URL/ภาษาอังกฤษหลุด (#199)
- **ใครเคาะข้อความไทย:** เจ้าของโปรเจกต์ ไม่ใช่ developer — `02_API_SCREENS.md §1.2` ห้ามแปลหรือเรียบเรียงใหม่
  เพราะพนักงานคุ้นกับข้อความเดิม และ test ของ client ผูกกับสตริงเหล่านี้

### 5. เงินบนสาย: `wireMoney` (Dart) ↔ `toSatang` (TS)

ฝั่งแอป — `frontend/lib/data/repositories/api/api_wire.dart:50-55`:

```dart
String wireMoney(num baht) {
  final satang = (baht * 100).round();
  final sign = satang < 0 ? '-' : '';
  final abs = satang.abs();
  return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}
```

- **ทำอะไร:** `1250.5` → `"1250.50"` โดยแปลงเป็น **จำนวนเต็มสตางค์** ก่อน แล้วค่อยประกอบ string เอง
- **ทำไมไม่ใช้ `toStringAsFixed(2)`:** comment ในไฟล์บอกว่ามันคือ "การจัดรูปแบบ float ของ float" ซึ่งปัดครึ่งต่างกันได้บาง input
  และ server **ปฏิเสธทศนิยมตำแหน่งที่ 3** → ปัดพลาดนิดเดียว = `400` ที่หน้าเคาน์เตอร์

ฝั่ง server — `server/src/common/money.ts:9-16` แปลงค่าที่รับมาเป็น **integer สตางค์** (`toSatang`)
รับได้ทั้ง string และ number แต่ **ทั้งสองแบบต้องไม่เกิน 2 ตำแหน่ง** (comment: ไม่งั้น `1.005` ปัดเงียบ แต่ `"1.005"` ได้ 400 — สองทางไม่ตรงกัน)
และต้องไม่เกินขนาด `NUMERIC(12,2)` ที่ใหญ่ที่สุดใน schema — เกินแล้วตอบ 400 ทันที แทนที่จะไปพังเป็น 500 ใน Postgres หลายบรรทัดถัดไป

**เวลา:** ISO-8601 UTC ทุกที่ (`2026-08-25T03:12:00Z`, `02_API_SCREENS.md §1.1`) — client แปลงเป็นเวลาท้องถิ่นด้วย `stamp()` ใน `api_wire.dart`
ข้อตกลงนี้ทำให้ไม่ต้องเดาว่า "10:00" คือเวลาไทยหรือ UTC

### 6. Idempotency-Key — สัญญาเรื่องกดซ้ำ

**ฝั่ง server — fingerprint ของ request** · `server/src/idempotency/idempotency.runner.ts:23-43`

```ts
  const key = req.header(IDEMPOTENCY_KEY_HEADER)?.trim();
  if (!key || key.length > IDEMPOTENCY_KEY_MAX_LENGTH) {
    throw new BadRequestException({
      code: 'IDEMPOTENCY_KEY_INVALID',
      ...
  }
  return {
    key,
    // The CONCRETE target, not `req.route.path`: ...
    endpoint: `${req.method} ${req.baseUrl}${req.path}`,
    requestHash: IdempotencyService.requestHash(req.body),
    successCode,
  };
```

server จำ 3 อย่างต่อ key: **key**, **endpoint** (method + path จริง เช่น `POST /api/v1/sales`), **hash ของ body**
แล้วตัดสินใน `decide()` (`server/src/idempotency/idempotency.service.ts:325-345`):

| สถานการณ์ | ผล | HTTP |
|---|---|---|
| key ใหม่ | ทำงานจริง แล้วเก็บคำตอบไว้ใน**ทรานแซกชันเดียวกัน** | 201/200 |
| key เดิม + endpoint เดิม + body เดิม | **replay** คำตอบที่เก็บไว้ ไม่ทำงานซ้ำ | เท่าเดิม (201/200) |
| key เดิม + body **ต่าง** หรือ endpoint **ต่าง** | ปฏิเสธ | `409 IDEMPOTENCY_KEY_REUSED` |
| key เดิม แต่ request แรก **ยังทำไม่เสร็จ** (รอ lock เกิน 5 วินาที) | "ลองใหม่ทีหลัง" | `503 IDEMPOTENCY_KEY_IN_FLIGHT` |
| ไม่มี header หรือยาวเกิน 200 ตัว | ปฏิเสธก่อนทำอะไร | `400 IDEMPOTENCY_KEY_INVALID` |

key ถูกเก็บ 24 ชั่วโมง (`IDEMPOTENCY_TTL_SECONDS = 24 * 60 * 60`, `idempotency.service.ts:29`)

- **ทำไม endpoint ต้องเป็น path จริง ไม่ใช่ pattern:** body ของ void บางแบบเล็กมาก ถ้าใช้ pattern `POST /sales/:id/void`
  การ void บิล A กับบิล B ด้วย key เดิม (bug ฝั่ง client) จะได้ fingerprint เดียวกัน → server replay คำตอบ "void บิล A สำเร็จ"
  ทั้งที่บิล B **ยังไม่ถูก void** — เงียบและอันตราย (CLAUDE.md: *"never `req.route.path`"*)
- **ทำไมต้องเทียบ endpoint ด้วย:** comment ใน `decide()` ยกตัวอย่าง: key+body เดียวกันส่งไป `POST /sales` แล้วไป `POST /returns`
  ถ้าไม่เทียบ endpoint จะ replay "ขายสำเร็จ" และ **ไม่ทำการคืนเลย**

**ฝั่ง client — mint ครั้งเดียวต่อตะกร้า** · `frontend/lib/data/repositories/api/api_wire.dart:196-230`

```dart
  PendingWrite of(String fingerprint) {
    final parked = _open[fingerprint];
    if (parked != null && DateTime.now().difference(parked.at) < _ttl) {
      return parked.write;            // ← ยังไม่รู้ผล: ใช้ id + key ชุดเดิม
    }
    final write = PendingWrite._(
      fingerprint: fingerprint,
      id: newId(_idPrefix),
      headers: idempotencyKey(),      // ← ครั้งแรก: สร้างใหม่
    );
    ...
  void closeIfVerdict(PendingWrite write, ApiException e) {
    if (isVerdict(e)) close(write);
  }
```

- `PendingWrites` จำ "ความพยายามที่ยังไม่รู้ผล" ต่อ **ลายนิ้วมือของตะกร้า** (ของอะไร กี่ชิ้น ราคาเท่าไหร่ จ่ายแบบไหน)
  กดซ้ำด้วยตะกร้าเดิม → ได้ **bill id + key ชุดเดิม** → server replay → ไม่มีบิลที่สอง
- **ทำไมมี TTL 10 นาที:** fingerprint คือ "ค่า" ไม่ใช่ "ตัวตน" — ลูกค้าเดินเข้ามาสองคนซื้อไส้กรองน้ำมัน ฿250 เงินสดเหมือนกันเป๊ะ
  จะได้ fingerprint เดียวกัน ถ้าไม่มีวันหมดอายุ คนที่สองจะถูก replay เป็นบิลของคนแรก (comment ใน `api_wire.dart:185-195`)

**กติกา "4xx เท่านั้นคือคำตัดสิน"** · `api_wire.dart:99`

```dart
bool isVerdict(ApiException e) => e.statusCode < 500 && e.statusCode != 429;
```

- `4xx` (ยกเว้น 429) → server ตอบชัดแล้ว → **ปิด** ความพยายามนี้ กดครั้งต่อไปคือบิลใหม่
- `5xx`, `429`, timeout, socket หลุด → **ไม่รู้ผล** → **เก็บ** id+key ไว้ รอ retry
- `503 IDEMPOTENCY_KEY_IN_FLIGHT` คือกรณีคมที่สุด — แปลว่า "ของเดิมยังวิ่งอยู่" จึงเป็นคำตอบเดียวที่ **ห้าม** ปิดความพยายามเด็ดขาด
- ทำไม timeout ของ client ต้องยาวกว่า Nginx: `ApiClient.defaultWriteTimeout = 40s` (`api_client.dart:45`) ตั้งไว้สูงกว่า timeout ของ Nginx
  comment ใน `isVerdict` บอกว่า "reply หาย" ที่เจอบ่อยสุดจึงออกมาเป็น `502/504` ของ Nginx — ซึ่งเป็น 5xx → ไม่รู้ผล → เก็บไว้ ถูกต้อง

**Sequence: POST /sales ที่คำตอบหาย แล้วกดซ้ำ**

```mermaid
sequenceDiagram
    autonumber
    participant C as "แอปเครื่องขาย (ApiSalesRepository)"
    participant P as "PendingWrites"
    participant N as "Nginx"
    participant A as "API (runIdempotent)"
    participant DB as "Postgres"

    C->>P: of(fingerprint ตะกร้า)
    P-->>C: id=s_abc, key=idem_1 (สร้างใหม่)
    C->>N: POST /api/v1/sales (Idempotency-Key: idem_1, id: s_abc)
    N->>A: ส่งต่อ
    A->>DB: claim idem_1 → ตัดสต็อก → เก็บคำตอบ → COMMIT
    A--xN: คำตอบหาย (เน็ตร้านหลุด / proxy timeout)
    N-->>C: 504 หรือ timeout
    Note over C,P: 5xx/timeout = ไม่ใช่คำตัดสิน → ไม่ close, id+key ยังจอดไว้
    C->>P: พนักงานกดชำระอีกครั้ง → of(fingerprint เดิม)
    P-->>C: id=s_abc, key=idem_1 (ชุดเดิม!)
    C->>N: POST /api/v1/sales (Idempotency-Key: idem_1, body เดิม)
    N->>A: ส่งต่อ
    A->>DB: claim idem_1 → เจอแล้ว, endpoint+hash ตรง
    A-->>C: 201 + คำตอบเดิม (replay) — ไม่ตัดสต็อกซ้ำ
    C->>P: close(attempt)
```

ถ้าขั้นที่ 9 client **สร้าง key ใหม่** (bug ที่ง่ายที่สุดในโลก — แค่เรียก `idempotencyKey()` ในฟังก์ชันส่ง แทนที่จะเรียกตอนเริ่มตะกร้า)
server จะเห็นเป็นคำสั่งใหม่ → ขายรอบที่สอง ด่านสำรองคือ bill `id` — แต่ถ้า id ก็สร้างใหม่ด้วย ด่านทั้งสองพังพร้อมกัน
นี่คือเหตุผลที่ CLAUDE.md เขียนว่า *"The bill id and `Idempotency-Key` are minted once per cart, not once per call"*

> 📌 ใน phase 2 ตอนเน็ตหลุดจริง (transport failure) `ApiSalesRepository.saveSale` จะบันทึกบิลลง outbox แบบออฟไลน์
> **ด้วย id + key ชุดเดิม** (`api_sales_repository.dart:145-160`) แล้วค่อยส่งผ่าน `POST /sync/push` ภายหลัง
> จุดนี้แหละที่ bug contract drift ในส่วน ⚠️ ไปกัด

### 7. Keyset cursor ของ `GET /products?updatedSince=&afterId=`

`server/src/products/products.service.ts:214-225`

```ts
    if (query.updatedSince && query.afterId) {
      // Keyset on (updated_at, id): many rows share one `updated_at` (a sale stamps
      // every line with the transaction's `now()`, an import stamps a whole catalogue),
      // so `updated_at > $ts` alone skips the rest of a tie that a page boundary cut.
      params.push(query.updatedSince, query.afterId);
      where.push(
        `(updated_at, id) > ($${params.length - 1}::timestamptz, $${params.length})`,
      );
    } else if (query.updatedSince) {
      params.push(query.updatedSince);
      where.push(`updated_at > $${params.length}::timestamptz`);
    }
```

และ cursor ที่ส่งกลับใช้เวลาแบบ **microsecond** (`products.service.ts:97`):

```ts
const CURSOR_TIMESTAMP = `to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;
```

- **สัญญา:** client ขอหน้าแรกด้วย `?updatedSince=<เวลาที่ sync ล่าสุด>` แล้ว **ตาม `meta.nextCursor`** ไปเรื่อยๆ
  (`{updatedSince, afterId}` — นิยามใน `server/src/common/paginated.ts`) จน `nextCursor` เป็น `null`
- **ทำไม microsecond:** Postgres เก็บเวลาละเอียดถึง µs แต่ JS `toISOString()` ตัดเหลือ ms (3 หลัก) ถ้า cursor ถูกตัด
  มันจะ **ต่ำกว่า** ทุกแถวใน ms เดียวกัน → แถวที่เวลาเท่ากันแต่ใหญ่กว่า 1 หน้าจะถูกส่งซ้ำ **ไม่รู้จบ** (comment `products.service.ts:246-248`)
- **controller บังคับสัญญาด้วย** (`products.controller.ts:57-66`): ส่ง `afterId` โดยไม่มี `updatedSince` → `400`
  · ส่ง `updatedSince` คู่กับ `page > 1` → `400 "updatedSince is keyset-paged: follow meta.nextCursor instead of page"`
  คือ **ปฏิเสธการผสม offset กับ keyset** แทนที่จะ "รองรับครึ่งๆ" แล้วข้ามแถวเงียบๆ

### 8. Auth endpoints — ได้ token มายังไง

`server/src/auth/auth.controller.ts:15-66` มี 4 route:

| Route | body | ได้อะไร |
|---|---|---|
| `POST /auth/device` | `{code}` — **enrolment code** ที่ owner ออกผ่าน `POST /devices` | `{deviceToken}` เก็บไว้ในเครื่องถาวร ผูกเครื่องนี้กับร้าน |
| `POST /auth/token` | `{username, password, deviceToken?}` | `{accessToken, refreshToken, user}` |
| `POST /auth/refresh` | `{refreshToken}` หรือ `Authorization: Bearer <refresh>` | token ชุดใหม่ |
| `GET /auth/me` | (JWT) | ข้อมูลใน token |

ลำดับที่เครื่องขายใหม่ต้องทำ:

```
owner: POST /devices {role:'pos'}         → ได้ enrolCode (อายุสั้น)
เครื่องใหม่: POST /auth/device {code}      → ได้ deviceToken (เก็บไว้)
เครื่องใหม่: POST /auth/token {username, password, deviceToken}
          → server resolve deviceToken เป็น did + drole เอง แล้วฝังใน JWT
```

- **ทำไม client ห้ามส่ง `deviceId`/`tenantId` ใน body:** ไม่งั้นใครก็ปลอมว่าเป็นเครื่องขายของร้านอื่นได้ ทุกอย่างต้องมาจาก token ที่ server เซ็นเอง
  (มี test ฝั่ง client บังคับ: `api_repository_contract_test.dart` — *"#54 AC6: nothing the client sends carries deviceId or tenantId"*)
- **อายุ token** (ADR-0009, ตาม `02_API_SCREENS.md §1.1`): access 15 นาที, refresh หมดอายุ 04:00 ตามเวลาร้าน
- **throttle ก่อน login:** `auth.service.ts` นับทุกความพยายามต่อ IP (10 ครั้ง/60 วินาที) **ก่อน** รู้ผล — รายละเอียดในบท backend

### 9. Platform plane — `/api/v1/platform/*` สองชั้น

ชั้น Nginx (`server/docker/nginx/nginx.conf:87-95`):

```nginx
    location /api/v1/platform/ {
      allow 127.0.0.1;
      allow ::1;
      # TODO(owner): add specific admin IP(s) here if accessing from outside the server host,
      # e.g. `allow 203.0.113.10;`
      deny  all;
      limit_req zone=perip burst=60 nodelay;
      proxy_pass http://api;
    }
```

ชั้น API (`server/src/platform/platform-auth.guard.ts:56-62`) ตรวจ IP ซ้ำกับ `PLATFORM_ADMIN_IPS` → ไม่ผ่านได้ `403 PLATFORM_IP_FORBIDDEN`
แล้วค่อยตรวจ JWT ที่ต้องเป็น audience `platform` เท่านั้น

- **ทำไมแยก plane:** platform admin สร้าง/ระงับร้านได้ — อำนาจเหนือทุก tenant ADR-0002 จึงบังคับว่า token ของร้าน (แม้แต่ `owner`)
  เรียก `/platform/*` ไม่ได้ และ token ของ platform ไม่มี `tid` จึงเรียก API ร้านไม่ได้เช่นกัน
- **ทำไมกันสองชั้น (defense in depth):** ถ้าวันหนึ่งมีคนแก้ Nginx พลาด ชั้น API ยังกันอยู่

### 10. `/health/*` และ `/metrics` — สัญญากับเครื่อง ไม่ใช่กับคน

`server/src/metrics/metrics.controller.ts:15-19`

```ts
  @Get()
  async getMetrics(@Res() res: Response): Promise<void> {
    res.setHeader('Content-Type', this.metricsService.contentType);
    res.send(await this.metricsService.metrics());
  }
```

- `@Res()` แบบไม่มี `passthrough` = บอก Nest ว่า "ฉันตอบเอง" → `EnvelopeInterceptor` ไม่ได้แตะ → Prometheus ได้ text format ดิบที่มันอ่านได้
  (ถ้าห่อ envelope Prometheus อ่านไม่ออก = กราฟว่างทั้งหมด)
- **จากข้างนอก `/metrics` ตอบ 404** — `nginx.conf:158-160` `location = /metrics { return 404; }` Prometheus เก็บจากในเครือข่าย compose เท่านั้น
- `/health/live` ตอบ `{status:'up'}` โดย **ไม่แตะอะไรเลย** · `/health/ready` เช็ค Postgres + Redis ทั้งสอง ถ้าตัวไหนล่ม →
  `503 NOT_READY` พร้อม `details` บอกว่าตัวไหน (`server/src/health/health.controller.ts:42-68`) — ทั้งสองตัวห่อ envelope ปกติ
- Nginx ไม่ rate limit `/health/` (`nginx.conf:78-80`) — comment: *"never rate limited, or the LB decides the instance is dead"*

### 11. Rate limit สองชั้น

| ชั้น | ที่ไหน | นับด้วย | เกินแล้ว |
|---|---|---|---|
| นอก (หยาบ) | Nginx `limit_req_zone … zone=perip:10m rate=30r/s` + `burst=60` (`nginx.conf:25-26, 98`) | IP | `429` (ไม่มี envelope — Nginx ตอบเอง) |
| ใน (แม่น) | `TenantRateLimitGuard` เป็น global guard (`rate-limit.module.ts:14-16`) + Redis | `tenant_id` จาก JWT | `429 RATE_LIMITED` + `Retry-After` |

ส่วนที่ตอบ `429` ของ guard — `server/src/rate-limit/tenant-rate-limit.guard.ts:87-98`:

```ts
    if (!result.allowed) {
      const retryAfter = result.retryAfter ?? 60;
      res.setHeader('Retry-After', String(retryAfter));
      throw new HttpException(
        {
          code: 'RATE_LIMITED',
          message: 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
        },
        HttpStatus.TOO_MANY_REQUESTS,
      );
    }
```

- **ทำไมต้องสองชั้น:** Nginx ตัวฟรี **อ่าน JWT ไม่ได้** จึงไม่รู้ว่า request เป็นของร้านไหน และจะให้ client ส่ง `X-Tenant-Id` เองก็ปลอมได้ (`02_API_SCREENS.md §5.1`)
- **Redis ล่ม → fail-open** (ปล่อยผ่าน) `rate-limit.service.ts` log `"fail-open"` แล้ว return อนุญาต — เพราะ **POS หยุดขายไม่ได้**
- **ฝั่ง client:** `429` ไม่ใช่คำตัดสิน (`isVerdict` คืน `false`) — ถูกจำกัดความถี่ไม่ได้แปลว่าบิลนั้นผิด
- 🔴 เรื่อง load test: การยกเว้น IP ของเครื่องยิง k6 ออกจาก `perip` **ถูกพิจารณาและปฏิเสธแล้ว** (CLAUDE.md, #251) — ห้ามเพิ่มใน `nginx.conf`

### 12. CORS — ตั้งค่าจริง

`server/src/app.setup.ts:47-81` (ย่อ)

```ts
  let allowedOrigins: string[] = ['*'];
  ...
    allowedHeaders: [
      'Content-Type', 'Authorization', 'Idempotency-Key', 'If-None-Match',
      'X-Device-Id', 'X-Client-Version', 'X-Correlation-ID',
    ],
    exposedHeaders: ['Idempotency-Key', 'Retry-After', 'X-Correlation-ID', 'ETag'],
```

- `allowedHeaders` = header ที่ browser ยอมให้ JS **ส่ง** ข้าม origin — ถ้าลืมใส่ `Idempotency-Key` แอป Flutter **web** จะส่ง key ไม่ได้เลย (preflight ตก)
- `exposedHeaders` = header ที่ JS ฝั่ง browser **อ่านได้** จากคำตอบ — ถ้าไม่ expose `Retry-After` แอป web จะไม่รู้ว่าต้องรอกี่วินาที
- **default คือ `'*'`** ถ้าไม่ได้ตั้ง `CORS_ORIGINS` — #367 (PR #373) ทำให้ค่า set-แต่-ว่าง throw ตอน boot แทน fallback เงียบ
  🔴 แต่ CLAUDE.md บันทึกว่า **`mob04` ยังเป็น `'*'` อยู่** จนกว่า env file จะมี key และรัน `provision.yml` ใหม่ — ห้ามเขียนว่า CORS ปิดแล้วบน VM

### แผนภาพ: ชั้นของสัญญา (contract layers)

```mermaid
flowchart TB
    subgraph DOC["📄 สัญญาที่คนอ่าน"]
        D1["02_API_SCREENS.md<br/>path, envelope, §8 error codes"]
        D2["08_PHASE2_SPEC.md<br/>/sync/push กติกา replay"]
        D3["ADR-0004/0009/0010<br/>device role, token, write-through"]
    end
    subgraph FIX["🧾 สัญญาที่เครื่องอ่าน"]
        F1["fixtures/sync-push/*.json<br/>(18 ไฟล์ request→response)"]
        F2["SyncFacade (Dart interface)<br/>+ NullSyncFacade / FakeSyncFacade"]
    end
    subgraph FE["📱 ฝั่งแอป (Dart)"]
        C1["api_wire.dart<br/>wireMoney, isVerdict, PendingWrites"]
        C2["server_error_resolver.dart<br/>code → ไทย"]
        T1["api_repository_contract_test.dart<br/>sync_fixtures_test.dart"]
    end
    subgraph BE["🖥️ ฝั่ง server (TS)"]
        S1["envelope.interceptor.ts<br/>http-exception.filter.ts"]
        S2["idempotency.runner.ts<br/>money.ts, paginated.ts"]
        T2["idempotency-routes.spec.ts<br/>sync-push-fixtures.e2e-spec.ts"]
    end
    D1 --> C1 & C2 & S1 & S2
    D2 --> F1
    F1 --> T1 & T2
    F2 --> FE
    T1 -. "บังคับ" .-> C1
    T2 -. "บังคับ" .-> S2
```

อ่านภาพนี้ว่า: **เอกสาร** บอกกติกา → **fixture/interface** แปลงกติกาเป็นของที่เครื่องอ่านได้ → **test ทั้งสองฝั่ง** อ่าน fixture ชุดเดียวกัน
จุดไหนที่ไม่มีลูกศร "บังคับ" คือจุดที่สองฝั่งหลุดจากกันได้เงียบๆ

---

## 🤝 วิศวกรรมสัญญา FE↔BE — "contract, not a queue"

### 1. `api_repository_contract_test.dart` — test ที่อ่าน source code

`frontend/test/api_repository_contract_test.dart` (635 บรรทัด) **ไม่รันแอป** แต่อ่านไฟล์ `.dart` ใน
`data/repositories/api/` และ `data/repositories/api_*.dart` แล้วหาแพทเทิร์นต้องห้าม เช่น:

```dart
const _bannedCalls = [
  '.saveSale(',
  '.createReturn(',
  '.openShift(',
  '.addDrawerEntry(',
  '.closeShift(',
  '.receivePO(',
];
```

(`api_repository_contract_test.dart:44-51`)

- **สัญญาที่บังคับ:** ApiRepository ห้ามเรียก Drift transactional service — server ตัดสต็อกไปแล้วใน `POST /sales`
  ถ้า client เรียก `saveSale` ของ Drift อีก = **ตัดสต็อกซ้ำสองครั้ง** (comment หัวไฟล์ บรรทัด 1-14)
- และบังคับอีกหลายข้อ: ห้ามยิง API **ภายใน** `db.transaction` (ทรานแซกชันที่คร่อมเครือข่ายจะล็อกแคชไว้นานเท่าเน็ตช้าที่สุด),
  ห้าม fallback เขียน local เมื่อไม่ใช่ transport failure, และ *"nothing the client sends carries deviceId or tenantId"*
- **ทำไมอ่าน source แทนรัน:** comment บรรทัด 16-18: เป็นวิธีเดียวที่พิสูจน์ได้ว่า *ApiRepository ในอนาคต* จะเผลอเรียกไม่ได้
  ไม่ใช่แค่ "โค้ดวันนี้บังเอิญไม่เรียก"
- test นี้มี **self-check** (`test('self-check: the matcher actually catches a violation'…`, บรรทัด 252) — ทดสอบว่าตัวจับเองจับได้จริง
  ไม่งั้น regex พังแล้ว test เขียวตลอดไปโดยไม่มีใครรู้

### 2. โฟลเดอร์ fixtures — สัญญาที่ทั้งสองฝั่งอ่านไฟล์เดียวกัน

`docs/Backend_design/fixtures/sync-push/` มี **18 ไฟล์** แต่ละไฟล์คือ "request นี้ → ต้องได้ response นี้":

```
sale-create.applied.json            sale-create.replay-by-key.json
sale-create.replay-by-id.json       sale-create.client-id-reused.json
sale-create.rejected-stock.json     return-create.applied.json
return-create.rejected-price.json   credit-payment.applied.json
credit-payment.rejected-overpayment.json   customer-create.applied.json
customer-update.applied.json        drawer-entry.applied.json
shift-open.applied.json             shift-open.archived-previous.json
sale-void-offline.applied.json      sale-void-offline.rejected-online-bill.json
batch.no-active-user-403.json       batch.stop-at-retry.json
```

ผู้ใช้ไฟล์เหล่านี้ (ตรวจด้วย grep):
- ฝั่ง server: `server/test/sync-push-fixtures.e2e-spec.ts`
- ฝั่งแอป: `frontend/test/sync/sync_fixtures_test.dart`, `frontend/test/sync/sync_service_contract_test.dart`, `frontend/test/sync_service_test.dart`

**ทำไมเวิร์ก:** lane B (engine ในแอป) กับ lane C (server) ทดสอบกับ **ไฟล์เดียวกัน** โดยไม่ต้องรอกัน
ถ้าใครจะเปลี่ยนรูปร่าง ต้องแก้ fixture → test อีกฝั่งแดงทันที → ต้องคุยกัน

### 3. `SyncFacade` — seam ระหว่าง lane

`frontend/lib/data/sync/sync_facade.dart:58-64`

```dart
abstract class SyncFacade {
  Stream<SyncStatus> get status;
  Stream<List<OutboxOpView>> get needsOwner; // rejected + stuck
  Stream<int> get outboxRemaining;
  Future<void> resend(String opId); // attempts = 0, same key, never change docNo
  Future<DiscardResult> discard(String opId, String note);
```

- **seam** (รอยต่อ) = จุดที่เปลี่ยนตัวทำงานข้างหลังได้โดยคนเรียกไม่ต้องรู้ หน้าจอ "รอ owner" (lane C) เรียกแค่ `SyncFacade`
  ส่วนตัวจริง (`SyncService`) เป็นของ lane B ระหว่างที่ lane B ยังไม่เสร็จ lane C ใช้ `FakeSyncFacade` ไปก่อน
- สังเกต comment ของ `resend`: *"same key, never change docNo"* — สัญญาเรื่อง idempotency ถูกเขียนไว้ **ที่ interface เลย**

**"Contract, not a queue"** (CLAUDE.md: *"Blocked-by never crosses a lane — a cross-lane need is a contract (fixtures, `SyncFacade`), never a queue"*)
หมายความว่า: ถ้า lane C ต้องการของจาก lane B **ห้าม** เขียนว่า "รอ B เสร็จก่อน" (queue = ต่อคิว) แต่ต้อง **ตกลงสัญญา** (fixture/interface)
แล้วต่างคนต่างทำกับของปลอมที่ทำตามสัญญา — งานขนานกันได้ทั้ง 3 lane
ราคาที่จ่าย: ถ้าสัญญาเขียนไม่ครบ ของปลอมกับของจริงจะต่างกัน และจะรู้ตัวตอนเอามาต่อกันจริงเท่านั้น — ซึ่งคือ bug ข้างล่าง

---

## 🧪 ลองยิงเอง (hands-on)

> ⚠️ **ทุกคำสั่งในส่วนนี้เป็น "ตัวอย่าง"** — path, header และรูปร่าง body ตรวจกับโค้ดแล้ว
> แต่ **ผู้เขียนไม่ได้รันคำสั่งเหล่านี้จริงตอนเขียนบท** ผลลัพธ์ที่แสดงคือ "ควรได้ประมาณนี้" ตามโค้ด
> สิ่งที่ต้องมีก่อน: รัน stack ตาม `server/README.md` หัวข้อ *Run* (`cp .env.example .env && docker compose up -d --build`)
> Nginx ใช้ TLS แบบ self-signed จึงต้องใส่ `-k` เสมอ

**1) health — นอก prefix แต่ยังห่อ envelope**

```bash
curl -k https://localhost/health/live
# → {"status":"success","data":{"status":"up"}}      (ตาม server/README.md)
curl -k -i https://localhost/health/ready             # -i ดู status code ด้วย
```

**2) path ที่ไม่มี → 404 ยังเป็น envelope**

```bash
curl -k https://localhost/api/v1/nope
# ควรได้ {"status":"error","error":{"code":"NOT_FOUND","message":"Cannot GET /api/v1/nope"}}
```

**3) ไม่ส่ง token → 401**

```bash
curl -k -i https://localhost/api/v1/products
# HTTP/1.1 401 ... {"status":"error","error":{"code":"UNAUTHORIZED", ...}}
```

**4) ขอ token** — ต้องมีร้าน (tenant) + enrol code ก่อน ซึ่งสร้างผ่าน platform plane:
`corepack pnpm bootstrap:admin` (สร้าง platform admin คนแรก) → `POST /api/v1/platform/auth/token` →
`POST /api/v1/platform/tenants` (ได้ `enrolCode` ของเครื่อง pos แรก) ตามด้วย:

```bash
curl -k -X POST https://localhost/api/v1/auth/device \
  -H 'Content-Type: application/json' -d '{"code":"A1B2C3D4"}'
# → {"status":"success","data":{"deviceToken":"..."}}

curl -k -X POST https://localhost/api/v1/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"username":"owner","password":"<รหัสผ่าน>","deviceToken":"<จากข้างบน>"}'
# → {"status":"success","data":{"accessToken":"...","refreshToken":"...","user":{...}}}

export TOKEN='<accessToken>'
```

> 🔴 **ยังไม่ได้ตรวจ:** Nginx อนุญาต `/api/v1/platform/` เฉพาะ `127.0.0.1`/`::1` ถ้ายิงจากเครื่อง host เข้า container
> Nginx อาจเห็น IP ของ Docker bridge แทน loopback แล้วตอบ `403` — ถ้าเจอ ให้อ่าน `server/README.md` และ
> `02_API_SCREENS.md §4.1` ก่อน **อย่าแก้ `nginx.conf` ให้ `allow all`**

**5) keyset cursor**

```bash
curl -k -H "Authorization: Bearer $TOKEN" \
  'https://localhost/api/v1/products?updatedSince=2026-01-01T00:00:00Z&limit=2'
# ดู meta.nextCursor → {"updatedSince":"2026-…T…:…:….123456Z","afterId":"p…"}  (6 หลักหลังจุด = µs)

curl -k -H "Authorization: Bearer $TOKEN" \
  'https://localhost/api/v1/products?updatedSince=2026-01-01T00:00:00Z&page=2'
# → 400 "updatedSince is keyset-paged: follow meta.nextCursor instead of page"
```

**6) Idempotency-Key** — ต้องเปิดกะก่อน (`POST /shifts/open` ก็ต้องมี key) และ token ต้องมาจากเครื่อง `pos`

```bash
curl -k -X POST https://localhost/api/v1/shifts/open \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: demo-shift-1' -d '{"startingCash":"1000.00"}'

# ไม่มี key → 400 IDEMPOTENCY_KEY_INVALID
curl -k -X POST https://localhost/api/v1/sales \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'

# มี key — body ตามรูปร่างของ parseCreateSale (server/src/sales/sales.dto.ts)
cat > sale.json <<'EOF'
{"id":"s_demo_1","paymentMethod":"เงินสด",
 "subtotal":"85.00","discount":"0.00","total":"85.00",
 "items":[{"lineNo":1,"productId":"<id สินค้าจริง>","name":"Oil Filter","qty":1,"price":"85.00"}]}
EOF
curl -k -i -X POST https://localhost/api/v1/sales -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: demo-sale-1' -d @sale.json
# ยิงคำสั่งเดิมซ้ำ → ได้ 201 + body เดิมเป๊ะ และสต็อกไม่ลดเพิ่ม (ลอง GET /products/<id> ดู)

# key เดิม แต่แก้ qty เป็น 2 → 409 IDEMPOTENCY_KEY_REUSED
```

`paymentMethod` ต้องเป็นหนึ่งใน `'เงินสด'`, `'โอน/QR'`, `'เครดิตช่าง'` (`sales.dto.ts:50`) — นี่ก็เป็นสัญญาเหมือนกัน

**7) `/metrics` จากข้างนอก**

```bash
curl -k -i https://localhost/metrics      # → 404 จาก Nginx (ตั้งใจ)
```

---

## 🛠️ เทคนิคในบทนี้

### 1. Response envelope

- **คืออะไร:** ห่อทุกคำตอบด้วยรูปร่างเดียว `{status, data, meta?}` / `{status, error:{code,message,details?}}` — เหมือนซองจดหมายมาตรฐานของไปรษณีย์
- **ปัญหาที่มันแก้:** 89 route ถ้าตอบคนละรูปร่าง client ต้องมีตัวแกะ 89 แบบ พลาดตัวเดียว = จอแสดง `null`
- **ทำไมเลือกท่านี้:** เทียบกับ "ใช้ HTTP status อย่างเดียว ไม่ห่อ" — ไม่ห่อทำให้ error ไม่มีที่ใส่ `code`/`details` เป็นมาตรฐาน; สเปคอาจารย์กำหนดรูปร่างนี้ด้วย
- **ดียังไง / ราคา:** client แกะที่เดียว · ราคา: ข้อมูลซ้อนลึกขึ้นหนึ่งชั้น และ endpoint ที่ต้องการรูปร่างอื่น (`/metrics`) ต้องหลบเอง
- **อยู่ตรงไหน:** `server/src/common/envelope.interceptor.ts:15-28`, `server/src/common/http-exception.filter.ts:21-44`

### 2. Machine code + human message

- **คืออะไร:** error มี `code` คงที่ไว้ให้โปรแกรม `if` และ `message` ไว้ให้คนอ่าน — เหมือนรหัสไปรษณีย์ (เครื่องคัดแยก) คู่กับที่อยู่ (คนอ่าน)
- **ปัญหาที่มันแก้:** ถ้าตัดสินจาก message วันที่แก้คำผิด ฟีเจอร์พังเงียบ; ถ้ามีแค่ code พนักงานเห็น `CREDIT_LIMIT_EXCEEDED` บนจอ
- **ทำไมเลือกท่านี้:** เทียบกับ "server ส่งไทยอย่างเดียว" — client ต้องแยกเคส `CREDIT_LIMIT_EXCEEDED` เพื่อเปิด dialog ยืนยัน ต้องมี code
- **ดียังไง / ราคา:** แยกหน้าที่ชัด · ราคา: ต้องดูแลตารางแปลสองที่ (`§8` ในเอกสาร + `_canonicalMessages` ใน Dart) ซึ่งหลุดกันได้ (ดู ⚠️)
- **อยู่ตรงไหน:** `frontend/lib/core/network/server_error_resolver.dart:45-150`, `docs/Backend_design/02_API_SCREENS.md §8`

### 3. Idempotency-Key

- **คืออะไร:** client แนบ "เลขลงทะเบียน" ให้คำสั่ง ส่งซ้ำด้วยเลขเดิม server ตอบคำตอบเดิมโดยไม่ทำซ้ำ — เหมือนเลขพัสดุลงทะเบียน ส่งใบเดิมสองรอบก็เป็นพัสดุชิ้นเดียว
- **ปัญหาที่มันแก้:** คำตอบหาย → กดซ้ำ → ขายสองรอบ ลูกค้าจ่าย ฿850 สองครั้ง สต็อกหาย 4 ชิ้นแทน 2
- **ทำไมเลือกท่านี้:** เทียบกับ "dedupe ด้วย bill id อย่างเดียว" — id ใช้ได้แค่กับ entity ที่มี id, key ใช้ได้กับทุก write (เปิดกะ, ลงรายการลิ้นชัก) และ replay **คำตอบ** ได้ด้วย
- **ดียังไง / ราคา:** retry ปลอดภัย · ราคา: ตาราง `idempotency_keys` + lock + client ต้องจำ key ที่ยังไม่รู้ผล และ **fingerprint ต้องตรงกันทุกเส้นทาง**
- **อยู่ตรงไหน:** `server/src/idempotency/idempotency.runner.ts:15-44`, `idempotency.service.ts:150-185, 325-345`

### 4. Verdict vs unknown (`isVerdict`)

- **คืออะไร:** แยกคำตอบเป็น "คำตัดสิน" (4xx ยกเว้น 429) กับ "ไม่รู้ผล" (5xx, 429, timeout) — เหมือนโทรสั่งของแล้วสายหลุด: ไม่ได้แปลว่าร้านไม่รับออเดอร์
- **ปัญหาที่มันแก้:** ถ้าถือว่า 504 = "ล้มเหลว" แล้วลืม key ครั้งหน้าได้ key ใหม่ → ขายซ้ำ
- **ทำไมเลือกท่านี้:** เทียบกับ "fallback เขียน local ทุกครั้งที่ error" — จะได้บิลซ้อนทั้งบน server และในเครื่อง
- **ดียังไง / ราคา:** ไม่มีบิลผี · ราคา: UI ต้องมีสถานะ "ยังไม่ทราบผลการขาย" (`02 §8.1.1`) ซึ่งพนักงานต้องเข้าใจ
- **อยู่ตรงไหน:** `frontend/lib/data/repositories/api/api_wire.dart:84-99`

### 5. Mint once per cart (`PendingWrites`)

- **คืออะไร:** สร้าง bill id + key **ครั้งเดียวต่อตะกร้า** และใช้ซ้ำจนกว่าจะได้คำตัดสิน
- **ปัญหาที่มันแก้:** สร้างใหม่ทุกครั้งที่กดส่ง = ด่าน key และด่าน id พังพร้อมกัน
- **ทำไมเลือกท่านี้:** เทียบกับ "เก็บ key ใน state ของหน้าจอ" — หน้าจอ rebuild/เปลี่ยนหน้าแล้วหาย; เก็บที่ repository อยู่รอดกว่า
- **ดียังไง / ราคา:** retry ปลอดภัยแม้พนักงานกดรัว · ราคา: fingerprint เป็น "ค่า" → ต้องมี TTL 10 นาที กันลูกค้าสองคนที่ซื้อเหมือนกันเป๊ะ
- **อยู่ตรงไหน:** `frontend/lib/data/repositories/api/api_wire.dart:180-236`, ใช้ที่ `api_sales_repository.dart:118-172`

### 6. Keyset pagination

- **คืออะไร:** แบ่งหน้าด้วย "ที่คั่นหนังสือ" `(updated_at, id)` แทนเลขหน้า
- **ปัญหาที่มันแก้:** offset ข้ามแถวเมื่อมีแถวถูกแก้ระหว่าง sync (ตัวอย่าง F หายในปูพื้นฐาน §8) → ราคาผิดค้างในเครื่องขาย
- **ทำไมเลือกท่านี้:** เทียบกับ offset — offset กระโดดหน้าได้ แต่การ sync ไม่ต้องกระโดด ต้องการแค่ "ครบ ไม่ซ้ำ"
- **ดียังไง / ราคา:** ไม่ข้าม ไม่วนซ้ำ · ราคา: cursor ต้องละเอียดระดับ µs และต้องปฏิเสธการผสมกับ `page`
- **อยู่ตรงไหน:** `server/src/products/products.service.ts:97, 214-257`, `products.controller.ts:57-66`

### 7. Money as string

- **คืออะไร:** ส่งเงินเป็น `"1234.50"` แล้วแต่ละฝั่งแปลงเป็นจำนวนเต็มสตางค์เอง
- **ปัญหาที่มันแก้:** float → `0.1 + 0.2 ≠ 0.3` → ใบเสร็จต่างจากระบบ 1 สตางค์
- **ทำไมเลือกท่านี้:** เทียบกับ integer สตางค์บนสาย — ปลอดภัยพอกัน แต่อ่านยาก และไม่ตรงสเปค `§1.1`
- **ดียังไง / ราคา:** ตรงถึงสตางค์ · ราคา: ต้องมีตัวแปลงสองฝั่ง และต้องตกลงกติกา "ไม่เกิน 2 ตำแหน่ง" ให้ตรงกัน
- **อยู่ตรงไหน:** `frontend/lib/data/repositories/api/api_wire.dart:36-55`, `server/src/common/money.ts:9-30`

### 8. URL versioning + global prefix exclusions

- **คืออะไร:** ใส่ `/api/v1` ทุก route ของร้าน แต่ยกเว้น path ของเครื่องจักร (health, metrics)
- **ปัญหาที่มันแก้:** แอปที่ติดตั้งแล้วอัปเดตไม่พร้อมกัน — breaking change ต้องมีที่ให้ `v1` อยู่ต่อ
- **ทำไมเลือกท่านี้:** เทียบกับ version ใน header — มองเห็นใน log/Nginx `location` ได้ตรงๆ (Nginx แยก `/api/v1/platform/` ได้ก็เพราะอยู่ใน path)
- **ดียังไง / ราคา:** ง่าย ชัด · ราคา: ถ้าวันหนึ่งมี `v2` ต้องดูแลสองชุด (ตอนนี้มีแค่ `v1`)
- **อยู่ตรงไหน:** `server/src/app.setup.ts:120-126`

### 9. Shared fixtures as contract

- **คืออะไร:** ไฟล์ JSON "request → response ที่ต้องได้" ที่ test **ทั้งสองฝั่ง** อ่าน
- **ปัญหาที่มันแก้:** lane B กับ lane C ต้องทำงานขนานกันโดยไม่ต้องรอ และต้องรู้ทันทีเมื่อเข้าใจไม่ตรงกัน
- **ทำไมเลือกท่านี้:** เทียบกับ OpenAPI — fixture บรรยาย **พฤติกรรม** ได้ (replay-by-key, stop-at-retry) ซึ่ง schema บรรยายไม่ได้
- **ดียังไง / ราคา:** เร็ว ถูก · ราคา: ครอบเฉพาะเคสที่มีไฟล์ — เคสที่ไม่มี fixture (online→push) หลุดได้
- **อยู่ตรงไหน:** `docs/Backend_design/fixtures/sync-push/` (18 ไฟล์), `server/test/sync-push-fixtures.e2e-spec.ts`, `frontend/test/sync/sync_fixtures_test.dart`

### 10. Seam / facade (`SyncFacade`)

- **คืออะไร:** interface ที่คนเรียกเห็น ส่วนตัวทำงานจริงสลับได้ (`Null`/`Fake`/ของจริง) — เหมือนเต้ารับไฟ: เสียบได้ทั้งไฟบ้านและเครื่องปั่นไฟ
- **ปัญหาที่มันแก้:** หน้าจอ lane C ต้องสร้างก่อน engine lane B เสร็จ
- **ทำไมเลือกท่านี้:** เทียบกับ "ให้หน้าจออ่านตาราง `outbox_ops` ตรงๆ" — จะผูกหน้าจอกับ schema ของอีก lane ทุกครั้งที่ schema เปลี่ยน หน้าจอพัง
- **ดียังไง / ราคา:** งานขนาน · ราคา: ของปลอมอาจต่างจากของจริง
- **อยู่ตรงไหน:** `frontend/lib/data/sync/sync_facade.dart:58-110`

### 11. Source-level contract test

- **คืออะไร:** test ที่ **อ่านโค้ด** หาแพทเทิร์นต้องห้าม แทนการรันโค้ด
- **ปัญหาที่มันแก้:** กติกาแบบ "ห้ามทำ X ที่ไหนเลย" test ปกติพิสูจน์ไม่ได้ (พิสูจน์ได้แค่ว่าเส้นทางที่ทดสอบไม่ทำ X)
- **ทำไมเลือกท่านี้:** เทียบกับ code review ด้วยตา — คนลืม, test ไม่ลืม
- **ดียังไง / ราคา:** กันอนาคต · ราคา: regex เปราะ จึงต้องมี self-check ว่าตัวจับยังจับได้
- **อยู่ตรงไหน:** `frontend/test/api_repository_contract_test.dart:44-51, 252`, ฝั่ง server `server/src/idempotency/idempotency-routes.spec.ts`

### 12. Two-layer rate limit + `Retry-After`

- **คืออะไร:** Nginx นับต่อ IP (หยาบ) + guard นับต่อร้าน (แม่น) เกินแล้วบอกว่า "รอกี่วินาที"
- **ปัญหาที่มันแก้:** flood จากข้างนอก และร้านหนึ่งกินทรัพยากรจนร้านอื่นขายไม่ได้
- **ทำไมเลือกท่านี้:** เทียบกับ "Nginx ชั้นเดียว" — Nginx ฟรีอ่าน JWT ไม่ได้ จึงไม่รู้จัก tenant
- **ดียังไง / ราคา:** แยกหน้าที่ · ราคา: Redis ล่มต้อง fail-open (ยอมให้ไม่จำกัดชั่วคราว) เพราะร้านหยุดขายไม่ได้
- **อยู่ตรงไหน:** `server/docker/nginx/nginx.conf:25-26, 97-100`, `server/src/rate-limit/tenant-rate-limit.guard.ts:87-98`

### 13. Conditional GET (`ETag` / `304`)

- **คืออะไร:** server ส่ง "ลายนิ้วมือ" ของข้อมูล (`ETag`) client ส่งกลับมาใน `If-None-Match` ถ้ายังเหมือนเดิม server ตอบ `304` ไม่มี body
- **ปัญหาที่มันแก้:** `GET /bootstrap` รวมสินค้า+ลูกค้า+ช่าง+ตั้งค่า — ก้อนใหญ่ ดาวน์โหลดซ้ำทุกครั้งที่เปิดแอปเปลือง
- **ทำไมเลือกท่านี้:** เทียบกับ cache ตามเวลา (`max-age`) — อาจใช้ข้อมูลเก่า; ETag ถามทุกครั้งแต่ส่งเฉพาะเมื่อเปลี่ยน (`Cache-Control: private, no-cache`)
- **ดียังไง / ราคา:** ประหยัด bandwidth · ราคา: server ยังต้องสร้างข้อมูลทั้งก้อนเพื่อ hash อยู่ดี (ประหยัดแค่การส่ง ไม่ประหยัด CPU)
- **อยู่ตรงไหน:** `server/src/settings/bootstrap.controller.ts:12-35`

### 14. CORS allowlist

- **คืออะไร:** server ประกาศว่า origin ไหนอ่านคำตอบได้ และ header ไหนส่ง/อ่านข้าม origin ได้
- **ปัญหาที่มันแก้:** เว็บร้ายใช้ browser ของพนักงานยิง API ร้านแล้วอ่านผล
- **ทำไมเลือกท่านี้:** เป็นกลไกเดียวที่ browser ยอมรับ ไม่มีทางเลือกอื่นสำหรับแอป web
- **ดียังไง / ราคา:** ปิดช่องจาก browser · ราคา: ลืม `allowedHeaders`/`exposedHeaders` ตัวเดียว แอป web พังเฉพาะบน browser (native ปกติ) — debug งง
- **อยู่ตรงไหน:** `server/src/app.setup.ts:47-81`

### ตารางสรุปเทคนิค

| เทคนิค | แก้ปัญหาอะไร | ราคาที่จ่าย | file |
|---|---|---|---|
| Response envelope | client แกะคำตอบที่เดียว | ซ้อนลึกขึ้น, `/metrics` ต้องหลบ | `common/envelope.interceptor.ts` |
| Code + message | โปรแกรมแยกเคส + คนอ่านรู้เรื่อง | ตารางแปลสองที่หลุดกันได้ | `server_error_resolver.dart` |
| Idempotency-Key | กดซ้ำไม่ขายซ้ำ | ตาราง key + lock + fingerprint ต้องตรงทุกเส้นทาง | `idempotency/idempotency.runner.ts` |
| `isVerdict` | ไม่ลืม key ตอนไม่รู้ผล | UI ต้องมีสถานะ "ยังไม่ทราบผล" | `api/api_wire.dart:99` |
| `PendingWrites` | id+key ชุดเดิมตอน retry | ต้องมี TTL | `api/api_wire.dart:196` |
| Keyset pagination | sync ไม่ข้าม/ไม่วนแถว | cursor µs, ห้ามผสม `page` | `products/products.service.ts` |
| Money as string | ไม่เพี้ยนสตางค์ | ตัวแปลงสองฝั่ง | `api_wire.dart`, `common/money.ts` |
| `/api/v1` + exclusions | อัปเดตแอปไม่พร้อมกันได้ | ถ้ามี v2 ต้องดูแลสองชุด | `app.setup.ts:120` |
| Shared fixtures | สอง lane ทำขนานกัน | ครอบเฉพาะเคสที่มีไฟล์ | `fixtures/sync-push/` |
| `SyncFacade` seam | หน้าจอไม่ผูก schema อีก lane | ของปลอม ≠ ของจริง | `data/sync/sync_facade.dart` |
| Source-level test | กันกติกา "ห้ามทั่ว repo" | regex เปราะ ต้อง self-check | `api_repository_contract_test.dart` |
| Rate limit 2 ชั้น | flood + noisy neighbor | fail-open ตอน Redis ล่ม | `nginx.conf`, `tenant-rate-limit.guard.ts` |
| ETag / 304 | ไม่โหลด bootstrap ซ้ำ | ยังคำนวณทั้งก้อน | `settings/bootstrap.controller.ts` |
| CORS allowlist | กันเว็บอื่นใช้ browser ผู้ใช้ | ลืม header = web พังคนเดียว | `app.setup.ts:47` |

---

## 📚 Tech stack ของบทนี้

| เครื่องมือ | version จริงจาก repo | หน้าที่ในบทนี้ | ทำไมเลือก | ทางเลือกที่ไม่เลือก |
|---|---|---|---|---|
| NestJS (`@nestjs/core`, `@nestjs/common`) | `^12.0.1` (`server/package.json`) | decorator route, guard, interceptor (envelope), filter (error) | มีจุดเสียบ envelope/filter/guard เป็นมาตรฐาน | Express เปล่า (ต้องประกอบเอง) |
| Express | `^5.2.1` | HTTP layer ใต้ Nest, `req.baseUrl`/`req.path` ที่ใช้ทำ fingerprint | มากับ Nest | Fastify |
| helmet | `^8.3.0` | security headers | มาตรฐาน OWASP | ตั้ง header เอง |
| Nginx | `nginx:1.29-alpine` (`server/docker-compose.yml`) | TLS, rate limit ต่อ IP, allowlist platform, ซ่อน `/metrics` | ฟรี เร็ว | Traefik, Caddy |
| Dart `http` | `^1.5.0` (`frontend/pubspec.yaml`) | ตัวยิง request ใน `ApiClient` | package ทางการของ Dart | `dio` |
| OpenAPI / Swagger | **ไม่มีใน repo** | – | ทีมเลือกเอกสาร markdown + fixtures | `@nestjs/swagger` |

---

## ⚠️ บทเรียนจากของจริง

### บทเรียน 1 — 🔴 HIGH (ยังไม่แก้): `/sync/push` กับ online route ใช้ fingerprint คนละแบบ

พบใน whole-codebase review 2026-09-24 (`docs/handoff_log/session-2026-09-24-whole-codebase-review.md` §2 ข้อ 1)
และบันทึกใน CLAUDE.md ส่วน "Still open" — **ยังไม่มี issue และยังไม่แก้**

ฝั่ง online เก็บ endpoint เป็น path จริง (`idempotency.runner.ts:40`):

```ts
    endpoint: `${req.method} ${req.baseUrl}${req.path}`,   // → "POST /api/v1/sales"
```

(ยืนยันได้จาก e2e test: `server/test/idempotency-money.e2e-spec.ts:179` คาดว่าแถวมี `endpoint: 'POST /api/v1/sales'`)

ฝั่ง `/sync/push` เขียน endpoint เองแบบ **ไม่มี prefix** (`server/src/sync/sync.service.ts:198-202`):

```ts
  private endpointForOp(op: SyncOpDto): { endpoint: string; successCode: number } {
    switch (op.type) {
      case 'sale.create':
        return { endpoint: 'POST /sales', successCode: 201 };
```

แล้ว `decide()` ถือว่า **endpoint ไม่ตรง = `reused`** ผลคือ:

```
1. เครื่องขายยิง POST /api/v1/sales (key=k1) → server COMMIT, เก็บ endpoint "POST /api/v1/sales"
2. คำตอบหาย (transport failure) → แอปบันทึกบิลลง outbox ด้วย key=k1 เดิม (ถูกต้องตามสัญญา)
3. เน็ตกลับมา → POST /sync/push op{type:'sale.create', idempotencyKey:k1}
4. sync.service สร้าง endpoint "POST /sales" ≠ "POST /api/v1/sales"
5. decide() → reused → ได้ IDEMPOTENCY_KEY_REUSED แทนที่จะเป็น applied (replay)
```

บิลนี้ **commit แล้วจริง** แต่เครื่องขายเห็นว่า "ถูกปฏิเสธ" → เด้งไปหน้า "รอ owner" ทั้งที่ไม่มีอะไรผิด
ขัดกับ `08_PHASE2_SPEC.md` AC **B1** (replay ต้องมาก่อนการตรวจ) — review บันทึกว่า test ที่มีอยู่ (`sync-push.e2e-spec.ts` ~บรรทัด 1238)
ครอบแค่ push→push ไม่ครอบ **online→push**

**บทเรียนเชิงสัญญา:**
- นี่คือ **contract drift** แท้ๆ: สัญญาเขียนไว้ชัด (08 §8.3 ขั้น 1: ต้องใช้ fingerprint เดียวกับ online route) แต่ **ไม่มี fixture/test ข้ามเส้นทาง** บังคับ
  18 fixture ของ sync-push ทุกไฟล์เริ่มจาก push เปล่าๆ ไม่มีไฟล์ไหนจำลอง "มีแถวจาก online อยู่ก่อนแล้ว"
- **กฎเดียวกันเขียนสองที่ → ค่อยๆ ไม่เหมือนกัน** (บทเรียนเดียวกับ #364 ในบท backend) — fingerprint ควรสร้างจากฟังก์ชันเดียว
- ทั้งสองฝั่ง "ถูกตามมุมตัวเอง": runner ใช้ path จริงตามกติกา, sync ใช้ชื่อ route ตามเอกสาร — **ผิดตรงรอยต่อ** ซึ่งไม่มีใครเป็นเจ้าของ

### บทเรียน 2 — `req.route.path` vs path จริง (แก้แล้ว)

fingerprint เคยพิจารณาใช้ route pattern; comment ใน `idempotency.runner.ts:34-39` อธิบายว่าทำไมเปลี่ยนเป็น path จริง:
void บิลคนละใบด้วย key เดิมจะได้ fingerprint เดียวกัน → replay "void บิลแรกสำเร็จ" ขณะบิลที่ตั้งใจ void ยังอยู่
กติกานี้ถูกยกขึ้นเป็น binding rule ใน CLAUDE.md — และเป็นเหตุผลที่บทเรียน 1 เกิดขึ้น (ฝั่ง sync ไม่ได้ทำตาม "path จริง" แบบเดียวกัน)

### บทเรียน 3 — ตาราง error code สองชุดที่ไม่ตรงกัน

- `02_API_SCREENS.md §8` บันทึกเอง (2026-09-23) ว่า `mapOpError` ใน `sync.service.ts` สร้าง code/ข้อความไทยของตัวเอง
  เช่น `OVERPAYMENT`, `UNKNOWN_OP_TYPE` ซึ่ง **ไม่มีในตาราง** และข้อความไทยที่ **ไม่เคยผ่านการเคาะ** — ขัดกติกา "ห้ามแต่งข้อความไทยเอง" (รอเจ้าของโปรเจกต์)
- `INVALID_BACKUP` ในตารางคาดว่าเป็น code แต่จริงๆ โยนเป็น `BadRequestException` ธรรมดา → code ที่ได้คือ `BAD_REQUEST` (`02 §8` บันทึกไว้)
- `ServerErrorResolver` ยังมีแถว `'OFFLINE_NOT_ALLOWED'` (`server_error_resolver.dart:60`) แต่ `offlineOk` ถูกลบไปแล้วตาม #272 และ grep ใน
  `server/src` ไม่พบ code นี้ถูกโยนแล้ว — เป็นแถวค้างที่ไม่เสียหาย แต่แสดงว่าสองฝั่งไม่มีอะไรเช็คให้ตรงกันอัตโนมัติ

### บทเรียน 4 — เอกสารเขียน ✔ แต่โค้ดไม่มี

`02_API_SCREENS.md §4.1` เคยทำเครื่องหมาย platform route ว่า idempotent ✔ ตรวจกับโค้ดเมื่อ 2026-09-23 แล้วพบว่า
**ไม่มี controller platform ตัวไหนเรียก `runIdempotent`** (import กันซ้ำด้วย `409` เมื่อมีงานค้างแทน) —
**สัญญาในเอกสารไม่ได้แปลว่าโค้ดทำตาม** ต้องมี test หรือการตรวจซ้ำ

### บทเรียน 5 — controller ที่ไม่มีใครเรียกได้

`server/src/purchasing/purchasing.controller.ts` ประกาศ `@Controller('purchase-orders')` 6 route ซ้ำกับ `purchase-orders.controller.ts`
แต่ไม่ถูกลงทะเบียนใน module → ยิงไม่ถึง คนอ่านโค้ดอาจแก้ไฟล์ผิดตัวแล้วงงว่าทำไมพฤติกรรมไม่เปลี่ยน
(พบระหว่างเขียนบทนี้ — ยังไม่ได้เปิด issue)

---

## ✅ สรุป

> - **API = เคาน์เตอร์ร้าน**: client รู้แค่ "พูดอะไรได้ ได้อะไรกลับ" ไม่ต้องรู้หลังร้าน · **contract** = interface + กติกาที่สองฝั่งสัญญาว่าจะรักษา
> - repo นี้เป็น **REST+JSON ใต้ `/api/v1`** (89 route) ยกเว้น `/health/live`, `/health/ready`, `/metrics` ที่ root — และมีแค่ `/metrics` ที่ไม่ห่อ envelope
> - ทุกคำตอบห่อ **envelope** `{status, data, meta?}` / `{status, error:{code, message, details?}}` · error มี **code ให้เครื่อง + message ให้คน** → `ServerErrorResolver` แปลงเป็นไทยก่อนถึงจอ
> - **เงินเป็น string `"1234.50"`**, เวลาเป็น ISO-8601 UTC · sync แคตตาล็อกใช้ **keyset cursor ระดับ µs** ไม่ใช่ offset
> - **Idempotency-Key**: key+endpoint+body เดิม = replay · body/endpoint ต่าง = `409 REUSED` · ยังวิ่งอยู่ = `503 IN_FLIGHT` · client **mint ครั้งเดียวต่อตะกร้า**
> - **4xx (ยกเว้น 429) = คำตัดสิน · 5xx/429/timeout = ไม่รู้ผล** → เก็บ id+key ไว้ retry
> - FE↔BE ผูกกันด้วย **เอกสาร + fixtures + source-level test + `SyncFacade`** — "contract, not a queue"
> - จุดที่ไม่มี test ข้ามเส้นทางคือจุดที่พัง: **bug HIGH** `/sync/push` fingerprint `POST /sales` ≠ `POST /api/v1/sales` ยังไม่แก้

---

## ❓ Quiz

**1.** ทำไม `POST /sales` ต้องมี `Idempotency-Key` แต่ `GET /products` ไม่ต้อง?

<details><summary>เฉลย</summary>

`GET` เป็น **safe** (ไม่เปลี่ยนข้อมูล) เรียกซ้ำกี่ครั้งผลต่อระบบก็เท่าเดิม ส่วน `POST /sales` ตามสเปค HTTP **ไม่ idempotent** —
ส่งสองครั้งคือขายสองครั้ง ถ้าคำตอบครั้งแรกหายแล้วแอปส่งซ้ำ จะตัดสต็อกและเก็บเงินซ้ำ `Idempotency-Key` คือ "สัญญาเพิ่ม" ที่ทำให้ `POST`
ตัวนี้มีพฤติกรรมเหมือน idempotent: key เดิม + body เดิม → server replay คำตอบเดิมโดยไม่ทำงานซ้ำ

</details>

**2.** แอปยิง `POST /api/v1/sales` แล้วได้ `504` จาก Nginx ถ้าโปรแกรมเมอร์เขียนให้ "ถือว่าล้มเหลว ล้าง key ทิ้ง" จะเกิดอะไรขึ้น?

<details><summary>เฉลย</summary>

`504` คือ Nginx รอ API นานเกิน — **ไม่ได้แปลว่า API ไม่ได้ทำ** ทรานแซกชันอาจ commit ไปแล้ว ถ้าล้าง key พนักงานกดอีกครั้ง `PendingWrites`
จะสร้าง bill id + key **ใหม่** → server เห็นเป็นคำสั่งใหม่ → ขายรอบสอง ลูกค้าโดนเก็บเงินซ้ำและสต็อกหายเกิน ถูกต้องคือ `isVerdict` คืน `false` สำหรับ 5xx
จึงเก็บ id+key เดิมไว้ ให้ retry ได้ replay

</details>

**3.** ทำไม `GET /products?updatedSince=...&page=2` ถึงถูกตอบ `400` แทนที่ server จะ "ช่วยทำให้" ?

<details><summary>เฉลย</summary>

`updatedSince` คือโหมด keyset (เดินตาม `meta.nextCursor`) ส่วน `page` คือ offset ถ้าผสมกัน ระหว่าง sync มีแถวถูกแก้ แถวจะเลื่อนตำแหน่ง
แล้ว offset จะข้ามบางแถวไปเงียบๆ → สินค้าบางชิ้นในเครื่องขายค้างราคาเก่า การปฏิเสธดังๆ (400) ดีกว่า "รองรับครึ่งๆ" แล้วข้อมูลผิดเงียบๆ
(หลักเดียวกับ "validate ก่อน แล้วค่อย clamp")

</details>

**4.** ถ้าเอา `'Idempotency-Key'` ออกจาก `allowedHeaders` ใน CORS config — แอป Android จะพังไหม? แอป Flutter web จะพังไหม?

<details><summary>เฉลย</summary>

**Android ไม่พัง** — CORS บังคับโดย browser เท่านั้น แอป native ส่ง header อะไรก็ได้ **Flutter web พัง** — browser จะยิง preflight
ถามว่าส่ง header `Idempotency-Key` ข้าม origin ได้ไหม server ไม่อนุญาต → browser บล็อก request ทุกตัวที่มี key → ทุก write ที่แตะเงินล้ม
bug แบบนี้ debug ยากเพราะ "บนมือถือก็ใช้ได้นี่"

</details>

**5.** bug HIGH ของ `/sync/push`: ทั้งฝั่ง runner (`POST /api/v1/sales`) และฝั่ง sync (`POST /sales`) ต่างก็ "ถูก" ตามมุมตัวเอง แล้วผิดตรงไหน และควรกันยังไงในอนาคต?

<details><summary>เฉลย</summary>

ผิดที่ **รอยต่อ**: สัญญา (08 §8.3) บอกว่าสองเส้นทางต้องใช้ fingerprint เดียวกัน แต่โค้ดสร้าง fingerprint **สองที่** ด้วยวิธีต่างกัน
และไม่มี test/fixture ที่จำลอง "บิล commit ทาง online ก่อน แล้ว push ตามมาด้วย key เดิม" ทางกัน: (1) ให้ fingerprint มาจากฟังก์ชันเดียวที่ทั้งสองเส้นทางเรียก
(2) เพิ่ม test ข้ามเส้นทาง online→push (3) พิจารณาเพิ่ม fixture ที่มี "สถานะก่อนหน้า" เพื่อให้สัญญาครอบเคสนี้

</details>

**6.** ทำไมหน้าจอห้ามแสดง `ApiException.toString()` ตรงๆ และทำไม `ServerErrorResolver` เลือกใช้ message ของ server เฉพาะเมื่อ "ขึ้นต้นด้วยอักษรไทย"?

<details><summary>เฉลย</summary>

`ApiException.toString()` ให้ข้อความแบบ `ApiException(status: 409, code: …)` — พนักงานอ่านไม่รู้เรื่อง ทุก ApiRepository จึงห่อด้วย `rethrowThai`
ให้เหลือแค่ประโยคไทย ส่วนเงื่อนไข "ขึ้นต้นด้วยไทย": message ไทยจาก server มักละเอียดกว่า (บอกชื่อสินค้าที่ขาด) จึงควรใช้ แต่ message ภาษาอังกฤษบางอัน
**อ้างคำไทย** ข้างใน (เช่น `Refund method 'หักจากเครดิต'…`) ถ้าเช็คแค่ "มีอักษรไทย" ข้อความอังกฤษจะแย่งที่ข้อความไทยมาตรฐานที่เจ้าของร้านเคาะไว้

</details>

---

## ➡️ อ่านต่อ

- **บทถัดไป — Backend:** [06_backend.md](06_backend.md) — ข้างในของทุกอย่างที่บทนี้มองจากข้างนอก: `TenantGuard`, `runTx`,
  lock order, idempotency ในระดับ SQL (`claim`/`complete`/`lock_timeout`), rate limit แบบ Lua `INCR`, และ architecture spec ที่อ่าน source
- ย้อนดูฝั่งแอป: [04_frontend.md](04_frontend.md) หัวข้อ `ApiClient` + `rethrowThai` และ `PendingWrites`
- เรื่อง outbox / `/sync/push` เต็มๆ: บท offline/phase 2 [10_offline_phase2.md](10_offline_phase2.md)
- **เอกสารลึก:**
  - [`docs/Backend_design/02_API_SCREENS.md`](../Backend_design/02_API_SCREENS.md) — สัญญา API ฉบับเต็ม: §1 กติกากลาง, §2 หน้าจอ→endpoint, §4 catalogue, §5.1 rate limit, §8 error codes
  - [`docs/Backend_design/08_PHASE2_SPEC.md`](../Backend_design/08_PHASE2_SPEC.md) — §8.3/§8.4 กติกา replay ของ `/sync/push` (AC B1)
  - [`docs/Backend_design/09_PHASE2_LANES.md`](../Backend_design/09_PHASE2_LANES.md) — ทำไมแบ่ง lane และทำไม "contract, not a queue"
  - [`docs/Backend_design/adr/0010-client-write-through-cache.md`](../Backend_design/adr/0010-client-write-through-cache.md) — ทำไม ApiRepository ห้ามเรียก Drift transactional service
  - [`docs/Backend_design/adr/0004-device-roles.md`](../Backend_design/adr/0004-device-roles.md) · [`0002-platform-admin-plane.md`](../Backend_design/adr/0002-platform-admin-plane.md) · [`0006-per-tenant-rate-limit.md`](../Backend_design/adr/0006-per-tenant-rate-limit.md) · [`0009-jwt-session-lifetime.md`](../Backend_design/adr/0009-jwt-session-lifetime.md)
  - [`docs/Backend_design/fixtures/sync-push/`](../Backend_design/fixtures/sync-push/) — เปิดอ่านสัก 2-3 ไฟล์ แล้วลองเดาว่า test ฝั่งไหนจะแดงถ้าแก้ฟิลด์ใดฟิลด์หนึ่ง
