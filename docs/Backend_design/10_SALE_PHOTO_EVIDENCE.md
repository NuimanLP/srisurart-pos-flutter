# 10 — รูปหลักฐานสินค้าตอนขาย (Sale photo evidence) — design

> **สถานะ:** ร่างออกแบบ 2026-10-12 · ยังไม่มีโค้ด · ยังไม่มี ticket
> **ที่มา:** owner ตัดสิน 2026-10-12 (ข้อ 0 ข้างล่าง — **ไม่เปิดถกใหม่**)
> **ใช้ของเดิมซ้ำ:** รูปสินค้า (PR #680/#682) — `02_API_SCREENS.md §3.2/§3.10`, `07_CICD_DEPLOY.md §9`,
> `server/src/product-images/{image-pipeline,image-store}.ts`, `products/product-images.controller.ts`,
> `frontend/lib/core/utils/product_photo.dart`, `data/storage/token_kv_store_web.dart`
> **ขัดกับ ADR → ยึด ADR** · ขัดกับ `02`/`07` ในเรื่องที่มีอยู่แล้ว → ยึด `02`/`07` แล้วแก้ไฟล์นี้
>
> 🔴 ข้อความไทยทุกคำในไฟล์นี้ที่ไม่ได้มาจาก owner ตรง ๆ เป็น **`agent ร่าง`** — รอ owner รับรองก่อนลง `02 §8.1.1`

---

## 0. ข้อตัดสินของ owner (2026-10-12) — กรอบของงานนี้

| ข้อ | ตัดสินแล้ว |
|---|---|
| จุดประสงค์ | หลักฐานว่าสินค้า **ใหม่ / ไม่มีรอยขีดข่วน / ไม่ชำรุด** ตอนลูกค้ารับไป |
| เมื่อไหร่ | **ไม่บังคับ หลังจ่ายเงิน** — ขายสำเร็จแล้ว หน้าใบเสร็จมีปุ่ม `ถ่ายรูปหลักฐานสินค้า` · ถ่าย 1–5 รูป หรือข้าม · **การจ่ายเงินไม่ถูกบล็อกหรือช้าลงเลย** |
| เก็บที่ไหน | **บน server ผูกกับบิล** ดูได้จากทุกเครื่อง · ต้องมีเน็ตตอนอัปโหลด · ออฟไลน์ (หรือบิลเองยังค้างใน outbox) = รูปเข้าคิวแล้วอัปโหลดทีหลัง |
| ดูที่ไหน | หน้า **รับคืน** (เปิดบิลที่จะคืน → เห็นรูปของบิลนั้น) และ **รายละเอียดบิล** ในประวัติการขาย/รายงาน |
| แพลตฟอร์ม | Android/iOS + Web · PC หน้าร้านอาจไม่มีกล้อง → ต้องเลือกไฟล์ได้แทน |

---

## 1. สรุปหน้าเดียว (สิ่งที่ไฟล์นี้เสนอ)

| เรื่อง | ข้อเสนอ | เหตุผลสั้น |
|---|---|---|
| ตัวตนของรูป | `photoId` = UUIDv7 ที่ **เครื่องสร้าง** ตอนถ่าย (เหมือน `sale.id`) | idempotent ข้ามวัน/ข้ามการรีสตาร์ต — ไม่ต้องพึ่ง `Idempotency-Key` ที่หมดอายุ 24 ชม. |
| ผูกกับบิล | `sale.id` (UUIDv7 ที่เครื่องสร้าง, #616) — **รู้ตั้งแต่ก่อนบิลขึ้น server** | รูปเข้าคิวได้ทันทีแม้บิลยังอยู่ใน outbox · ส่งได้เมื่อบิลถึง server แล้ว |
| อัปโหลด | `PUT /sales/:saleId/photos/:photoId` body เป็นไฟล์ดิบ (แบบ `PUT /products/:id/image`) | ใช้ raw parser + pipeline + store เดิม |
| ดู | `GET /sales/:saleId/photos` + `GET /sales/:saleId/photos/:photoId/{t,p}` **ผ่าน API มี login** | รูปหลักฐานอาจมีหน้าคน/ทะเบียนรถ — **ไม่** ใช้ URL สาธารณะแบบ `/img/` |
| ไฟล์ | volume ใหม่ **`sale-photos`** (api/worker เท่านั้น — **Nginx ไม่ mount**) · ชื่อไฟล์ content-addressed แบบเดิม | ไม่มีทางหลุดออก `/img/` แม้ตั้ง Nginx พลาด |
| Postgres | ตารางใหม่ `sale_photos` (PK `(tenant_id, id)`, FK → `sales`, RLS `NULLIF`) · `pos_app` ได้แค่ `SELECT, INSERT` | append-only = หลักฐานแก้ย้อนหลังไม่ได้ |
| Drift | **ไม่เปลี่ยน schema** (ไม่ต้อง build_runner) | ไบต์รูปห้ามลง Drift; คิวเก็บนอก Drift |
| คิวในเครื่อง | ไฟล์ในโฟลเดอร์แอป (Android/iOS) / IndexedDB แยก (Web) — เหมือนแนว `token_kv_store` | รอดการรีสตาร์ต, ไม่แตะ Drift, ไม่อยู่ใน `outbox_ops` |
| ปิดกะ | รูปค้าง **ไม่** บล็อกการปิดกะ | รูปไม่ใช่เงิน/สต็อก — `OUTBOX_NOT_EMPTY` นับแค่ `outbox_ops` |
| ลบรูป | MVP: **ไม่มีใครลบได้ผ่านแอป** (ยกเว้นทิ้งรูปที่ยังไม่ขึ้น server) · ช่องทาง owner ลบ → owner ตัดสิน (Q2) | หลักฐานต้องเชื่อถือได้ |
| เก็บนานแค่ไหน | MVP: เก็บตามบิล ไม่มีลบอัตโนมัติ · ระยะเก็บ + PDPA → owner ตัดสิน (Q3) | |

---

## 2. UX / UI

### 2.1 ภาพรวมการไหล

```
ขายสำเร็จ (saveSale คืนค่าแล้ว — ตะกร้าล้างแล้ว)
   │
   ▼
[ใบเสร็จ dialog] ── ปุ่ม "ถ่ายรูปหลักฐานสินค้า" ──► [แผ่นถ่ายรูป]
   │  (ปิด/พิมพ์ได้ตามเดิม)                         │  ถ่าย / เลือกรูป 1–5 รูป, ลบก่อนบันทึก
   │                                                │
   │                                  "ข้าม" ◄──────┤
   │                                                ▼
   │                                 "บันทึก N รูป" → เขียนลงคิวในเครื่อง (เร็ว, ไม่รอเน็ต) → ปิดแผ่น
   │                                                │
   ▼                                                ▼
ลูกค้าคนต่อไป                         ตัวส่งรูปทำงานเบื้องหลัง: รอบิลถึง server → PUT ทีละรูป
                                      สถานะเห็นได้ที่ป้าย "รูปรออัปโหลด N" บนแถบบน
```

- ปุ่มอยู่ **ใต้แถบ "ขายสำเร็จ/เงินทอน"** ใน `showReceiptDialog` (`receipt_view.dart`) — ไม่แทรกก่อนบิลสำเร็จ
  และไม่เปลี่ยนลำดับปุ่ม พิมพ์ใบเสร็จ / ปิด เดิม → การจ่ายเงินไม่ช้าลงแม้แต่ขั้นเดียว
- ปุ่มนี้มีเฉพาะ **API build** (Drift-only build ไม่มี server เก็บรูป — แนวเดียวกับรูปสินค้า)
- เปิดแผ่นแล้วปิดทิ้ง (ไม่กดบันทึก) = เหมือนข้าม · ไม่มีอะไรถูกเขียน
- **MVP ไม่มีปุ่ม "เพิ่มรูปทีหลัง"** ในหน้าอื่น — owner ระบุว่าถ่ายหลังจ่ายเงิน; การเพิ่มทีหลังทำให้หลักฐานอ่อนลง (Q5)

### 2.2 แผ่นถ่ายรูป (capture sheet)

จอกว้าง (≥ 600 logical px, เช่น PC/แท็บเล็ต) = dialog กว้าง 520 · จอแคบ = full-screen sheet

```
┌──────────────────────────────────────────────┐
│ ←  รูปหลักฐานสินค้า            RC01-2569-10-0042 │
│──────────────────────────────────────────────│
│ ถ่ายให้เห็นสภาพสินค้าก่อนส่งมอบ                     │
│ ไม่ต้องถ่ายหน้าลูกค้าหรือทะเบียนรถ                  │
│                                              │
│ ┌────────┐ ┌────────┐ ┌────────┐ ┌ ─ ─ ─ ─ ┐ │
│ │  รูป 1  │ │  รูป 2  │ │  รูป 3  │ │   ＋    │ │
│ │       ✕│ │       ✕│ │       ✕│ │ เพิ่มรูป │ │
│ └────────┘ └────────┘ └────────┘ └ ─ ─ ─ ─ ┘ │
│                                   3 / 5 รูป   │
│                                              │
│ [ 📷 ถ่ายรูป ]   [ 🖼 เลือกรูป ]                 │
│──────────────────────────────────────────────│
│ [ ข้าม ]                       [ บันทึก 3 รูป ] │
└──────────────────────────────────────────────┘
```

- **ถ่ายรูป**: แสดงเฉพาะเครื่องที่มีกล้องผ่านแอป (Android/iOS — `image_picker`, `ImageSource.camera`,
  `maxWidth: 1600` ให้กล้องย่อเองตั้งแต่ต้น ประหยัดหน่วยความจำเครื่องถูก)
- **เลือกรูป**: ทุกแพลตฟอร์ม (`file_picker` ตัวเดิม, รูปเท่านั้น) · บน Web มือถือ browser เสนอกล้องเองในตัวเลือกไฟล์ ·
  PC ไม่มีกล้อง = เลือกไฟล์ (เช่นรูปที่ถ่ายด้วยมือถือแล้วโอนมา) — **ไม่ทำ webcam capture ใน MVP**
- ทุกรูปผ่าน `shrinkProductPhoto` เดิม (ย่อ ≤ 1600 px, JPEG q85, ≤ 2.9 MB, หมุนตาม EXIF) ทันทีที่ได้มา
  แสดง thumbnail จากไบต์ที่ย่อแล้ว (ไม่ใช่ไฟล์ต้นฉบับ) — สิ่งที่เห็น = สิ่งที่จะส่ง
- ✕ บน thumbnail = ทิ้งรูปนั้น (ยังไม่เคยถูกเขียนที่ไหน ไม่ต้องยืนยัน) · **ถ่ายใหม่ = ✕ แล้วถ่ายอีกรูป** (ไม่มีโหมด retake แยก)
- แตะ thumbnail = ดูเต็มจอ (`InteractiveViewer` ซูมได้) — ตรวจว่าเห็นรอยชัดก่อนบันทึก
- ครบ 5 รูป: ช่อง ＋ หาย ปุ่มถ่าย/เลือกเป็น disabled พร้อมข้อความ `ครบ 5 รูปแล้ว`
- ระหว่างย่อรูป: tile นั้นแสดง spinner · ย่อไม่ได้ = tile หายพร้อม snackbar ข้อความ `IMAGE_UNREADABLE` เดิม
- **บันทึก N รูป**: เขียนทุกรูปลงคิวในเครื่อง (§3) → ปิดแผ่น → snackbar
  - ออนไลน์: `บันทึกรูปแล้ว กำลังอัปโหลด`
  - Degraded หรือบิลยังค้างใน outbox: `บันทึกรูปไว้ในเครื่องแล้ว จะอัปโหลดเมื่อออนไลน์`
- เขียนลงคิวไม่ได้ (ดิสก์เต็ม / IndexedDB ใช้ไม่ได้) → แผ่น **ไม่ปิด** รูปยังอยู่ แสดง `บันทึกรูปไม่สำเร็จ — พื้นที่ในเครื่องไม่พอหรือเบราว์เซอร์ไม่อนุญาต`
  (การขายสำเร็จไปแล้ว ไม่กระทบ)

### 2.3 สถานะการอัปโหลด — ป้ายบนแถบบน + แผ่นรายการ

ไม่แสดงความคืบหน้ารายไบต์ (รูปละ ~300 KB ใช้เวลาไม่กี่วินาที) — แสดง **จำนวน** แทน ติดกับป้าย sync เดิม
(`SyncStatusBuilder` / AppShell):

```
 [● ออนไลน์]  [⬆ รูปรออัปโหลด 3]        ← มีงานค้าง (สีกลาง)
 [● ออนไลน์]  [⚠ รูปอัปโหลดไม่สำเร็จ 1]   ← มีรูป failed (สีส้ม) — ชนะป้ายบน
```

แตะป้าย → แผ่น **รูปหลักฐานรออัปโหลด** จัดกลุ่มตามบิล:

```
┌──────────────────────────────────────────────┐
│ รูปหลักฐานรออัปโหลด                          ✕ │
│──────────────────────────────────────────────│
│ RC01-2569-10-0042 · 12 ต.ค. 2569 14:05          │
│ [▣][▣][▣]  รออัปโหลด — บิลยังไม่ถึงเซิร์ฟเวอร์       │
│                                              │
│ RC01-2569-10-0040 · 12 ต.ค. 2569 13:51          │
│ [▣]  อัปโหลดไม่สำเร็จ: ไม่พบบิลนี้บนเซิร์ฟเวอร์       │
│      [ ลองอีกครั้ง ]  [ ทิ้งรูป ]                  │
└──────────────────────────────────────────────┘
```

- สถานะต่อรูป: `รออัปโหลด` · `กำลังอัปโหลด` · `อัปโหลดไม่สำเร็จ` (+ เหตุผลไทย) — อัปโหลดสำเร็จ = หายจากรายการ
- `ทิ้งรูป` มี confirm (`ทิ้งรูปนี้? รูปยังไม่ได้ขึ้นเซิร์ฟเวอร์ ทิ้งแล้วกู้คืนไม่ได้`) — ใช้ `ConfirmDialog` เดิม
- ไม่มีงานค้าง = ไม่มีป้าย (ไม่เพิ่มของบนจอในวันปกติ)

### 2.4 ตัวดูรูปในหน้ารับคืน

ใน `_RefundDetail` (`returns_screen.dart`) ใต้หัวบิล เหนือรายการสินค้า — แถบ thumbnail แนวนอน:

```
┌ บิล RC01-2569-10-0042 ─────────────────────────┐
│ รูปหลักฐานตอนขาย (3)                              │
│ [▣ 72px][▣][▣]   ถ่ายเมื่อ 12 ต.ค. 2569 14:05        │
│────────────────────────────────────────────────│
│ รายการสินค้า …                                     │
```

- โหลด **หลังเลือกบิล** (lazy, ไม่ดึงตอนค้นหา) · ระหว่างโหลด = skeleton 3 ช่อง
- ไม่มีรูป = บรรทัดเดียวสีจาง `บิลนี้ไม่มีรูปหลักฐาน` (ไม่ใช่ error)
- Degraded = `ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะดูรูปได้`
- รูปที่ **ยังค้างในเครื่องนี้** ของบิลนี้ แสดงต่อท้ายด้วยป้าย `รออัปโหลด` (อ่านจากคิวในเครื่อง — เห็นได้แม้ออฟไลน์)
- แตะ = ตัวดูเต็มจอ: ปัดซ้ายขวา, ซูม, หัวบอก `รูป 2/3 · ถ่ายเมื่อ … · อัปโหลดเมื่อ …` (แสดง "อัปโหลดเมื่อ" เฉพาะเมื่อห่างจากเวลาถ่าย > 1 ชม.
  — ให้คนตัดสินข้อพิพาทเห็นว่ารูปขึ้น server ช้า)
- ไม่ดึงรูป preview จนกว่าจะเปิดตัวดูเต็มจอ (thumbnail 256 px เท่านั้นบนหน้ารับคืน)

### 2.5 ตัวดูรูปในรายละเอียดบิล (รายงาน)

วันนี้ `_RecentRow` ในหน้ารายงาน **แตะไม่ได้ และไม่มีหน้ารายละเอียดบิลในแอปเลย** (ตรวจ 2026-10-12) — MVP จึงเพิ่ม
แผ่น **รายละเอียดบิล** เล็ก ๆ ที่เปิดเมื่อแตะแถวบิล: หัวบิล (เลขที่, วันที่, วิธีจ่าย, ยอด) + รายการสินค้าจาก Drift
(`SaleWithItems` ที่มีอยู่แล้ว) + แถบรูปตัวเดียวกับ §2.4 (widget เดียวกัน `SalePhotoStrip`) — ไม่ทำหน้าประวัติการขายเต็มรูปแบบใน MVP

### 2.6 จอแคบ (360–390 px) และ zoom ทั้งจอ (#686)

- ทุกการตัดสินใจเรื่อง layout ใช้ `MediaQuery` (จอ logical หลัง zoom) — **ไม่** ใช้ `MediaQueryData.fromView`
  เพราะ zoom 3x บนจอ 1080 = logical 360 px ต้องได้ layout จอแคบ
- แผ่นถ่ายรูป: `< 600` = full-screen · tile ใช้ `Wrap` ขนาด 96 px (360 px ได้ 3 ต่อแถว) · ปุ่มถ่าย/เลือกเรียงลง
  แนวตั้งเมื่อกว้าง < 360 · ปุ่มล่าง `ข้าม`/`บันทึก N รูป` เต็มความกว้างสองแถว · ทุกปุ่ม ≥ 48 px (`tap_target.dart`)
- ✕ บน tile เป็นเป้ากด 40 px (ตัวไอคอนเล็กกว่าได้) — อย่าให้เป้าล้นออกนอก tile แล้วทับ tile ข้าง ๆ
- แถบรูปในหน้ารับคืน: เลื่อนแนวนอนได้ ไม่ wrap (ไม่ดันรายการสินค้าลง)
- ⚠️ บทเรียน #693: `Container(alignment:)` ใน `Wrap` กินเต็มแถว — tile ต้องมีขนาดตายตัว (`SizedBox`)
- route smoke test (3x บน 1920×1080, 2x บน 1366×768) ต้องครอบแผ่นถ่ายรูปและแผ่นรายละเอียดบิลด้วย
- ดูด้วยตาบน web build จริงตามกติกา #693 ก่อนปิดงาน UI

### 2.7 ทิศทางภาพ

ใช้ระบบเดิมทั้งหมด (navy/orange, Sarabun, `AppButton`, `StatusChip`) — ไม่สร้างสไตล์ใหม่ · จุดเดียวที่ตั้งใจให้จำได้:
thumbnail ในตัวดูมี **แถบเวลาถ่าย** มุมล่างแบบตราประทับ (พื้น navy โปร่ง 70%, ตัวขาว `thaiDateTime`) — รูปหลักฐาน
ที่ถูกแคปหน้าจอส่งต่อในไลน์ยังบอกเวลาได้ · **ไม่เขียนเวลาลงในพิกเซลของไฟล์** (ไฟล์บน server คือรูปล้วน; เวลาอยู่ในแถว `sale_photos`)

### 2.8 ข้อความไทย (ทั้งหมด `agent ร่าง` ยกเว้นที่ระบุ)

| ที่ | ข้อความ |
|---|---|
| ปุ่มบนใบเสร็จ | `ถ่ายรูปหลักฐานสินค้า` (**ถ้อยคำ owner 2026-10-12**) |
| หัวแผ่น | `รูปหลักฐานสินค้า` |
| คำแนะนำ | `ถ่ายให้เห็นสภาพสินค้าก่อนส่งมอบ` / `ไม่ต้องถ่ายหน้าลูกค้าหรือทะเบียนรถ` |
| ปุ่ม | `ถ่ายรูป` · `เลือกรูป` (ซ้ำกับตัวแก้รูปสินค้า) · `เพิ่มรูป` · `ข้าม` · `บันทึก {n} รูป` |
| ตัวนับ / เต็ม | `{n} / 5 รูป` · `ครบ 5 รูปแล้ว` |
| snackbar | `บันทึกรูปแล้ว กำลังอัปโหลด` · `บันทึกรูปไว้ในเครื่องแล้ว จะอัปโหลดเมื่อออนไลน์` · `บันทึกรูปไม่สำเร็จ — พื้นที่ในเครื่องไม่พอหรือเบราว์เซอร์ไม่อนุญาต` |
| ป้าย | `รูปรออัปโหลด {n}` · `รูปอัปโหลดไม่สำเร็จ {n}` |
| แผ่นรายการ | `รูปหลักฐานรออัปโหลด` · `รออัปโหลด` · `กำลังอัปโหลด` · `อัปโหลดไม่สำเร็จ` · `รออัปโหลด — บิลยังไม่ถึงเซิร์ฟเวอร์` · `ลองอีกครั้ง` · `ทิ้งรูป` |
| confirm ทิ้ง | `ทิ้งรูปนี้?` / `รูปยังไม่ได้ขึ้นเซิร์ฟเวอร์ ทิ้งแล้วกู้คืนไม่ได้` |
| ตัวดู | `รูปหลักฐานตอนขาย ({n})` · `บิลนี้ไม่มีรูปหลักฐาน` · `ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะดูรูปได้` · `ถ่ายเมื่อ {เวลา}` · `อัปโหลดเมื่อ {เวลา}` · `รูป {i}/{n}` |
| error code ใหม่ | `SALE_PHOTO_LIMIT` `บิลนี้มีรูปหลักฐานครบ 5 รูปแล้ว` · `SALE_PHOTO_INVALID` `ไฟล์รูปไม่ถูกต้อง กรุณาใช้รูป JPG, PNG หรือ WebP` (ถ้อยคำเดียวกับ `PRODUCT_IMAGE_INVALID`) · `SALE_PHOTO_TOO_LARGE` `รูปใหญ่เกิน 3 MB` · `SALE_NOT_FOUND` บน route นี้ `ไม่พบบิลนี้บนเซิร์ฟเวอร์` |

---

## 3. กระบวนการ (Process)

### 3.1 สถานะของรูปหนึ่งรูป

```
            (ในแผ่น, หน่วยความจำ)
 captured ──✕──► (ทิ้ง ไม่มีร่องรอย)
    │ บันทึก N รูป
    ▼
 pending ────────────────────────────┐   (ไฟล์ + sidecar ในเครื่อง)
    │ บิลถึง server แล้ว & มีเน็ต          │ รอ: Degraded / บิลยังใน outbox / 5xx / 429 / หลุด
    ▼                                │      (backoff, key เดิม, photoId เดิม)
 uploading ──── 2xx ────► uploaded ──► ลบไฟล์ในเครื่อง (รูปอยู่บน server แล้ว)
    │
    ├── 4xx ที่เป็นคำตัดสิน ─► failed ──ลองอีกครั้ง──► pending
    │                         └──ทิ้งรูป──► ลบไฟล์ในเครื่อง
    └── 401 ─► pending (รอ login ใหม่ — ไม่ใช่ความผิดของรูป)
```

| ผลจาก server | รูปเป็น | ทำไม |
|---|---|---|
| `200`/`201` (รวม replay) | uploaded → ลบในเครื่อง | |
| `5xx`, `429`, timeout, transport | pending, ลองใหม่อัตโนมัติ (30 วิ → 1 → 2 → 5 นาที คงที่) ด้วย **key + photoId เดิม** | ผลไม่แน่นอน (กติกา `isVerdict`) — แต่ต่างจากการเขียนเงิน: ไม่มีคนยืนรอ จึงลองเองได้ |
| `401` | pending, หยุดจน login ใหม่ | |
| `404 SALE_NOT_FOUND` ขณะที่ outbox **ยังมี** `sale.create` ของบิลนี้ | pending (ไม่ควรเกิด เพราะมีด่าน §3.3 — เผื่อแข่งกัน) | |
| `404 SALE_NOT_FOUND` และ outbox ไม่มีบิลนี้แล้ว | failed `ไม่พบบิลนี้บนเซิร์ฟเวอร์` | บิลถูก reject/discard หรือร้านถูก import แทนที่ |
| `409 SALE_PHOTO_LIMIT` | failed | |
| `409 CLIENT_ID_REUSED` | failed (บั๊ก — photoId ชนกับรูปอื่น) | |
| `400`/`413` | failed | ไฟล์เสีย — ลองซ้ำก็เหมือนเดิม |
| `403` (`DEVICE_ROLE_FORBIDDEN`, retired) | failed | เครื่องไม่ใช่ `pos` แล้ว |

### 3.2 รูปเก็บไว้ที่ไหนในเครื่อง (ระหว่าง pending/failed)

🔴 กติกาเดิม: **ไบต์รูปไม่ลง Drift** (product images) — ใช้กับรูปหลักฐานด้วย · และ **ไม่ใส่ใน `outbox_ops`**
เพราะ (1) ปิดกะต้องให้ outbox ว่าง (#456) — รูปจะไปบล็อกการปิดกะ (2) `/sync/push` เป็น JSON batch ไม่ใช่ไฟล์
(3) discard/ledger logic ของ outbox ไม่เกี่ยวกับรูป

จึงเสนอ **`PendingSalePhotoStore`** — interface เดียว สอง implementation ผ่าน conditional import แบบ `token_kv_store`:

| แพลตฟอร์ม | ที่เก็บ | รูปแบบ |
|---|---|---|
| Android / iOS | `getApplicationSupportDirectory()/sale_photos_pending/` (`path_provider` มีอยู่แล้ว) | `<photoId>.jpg` + `<photoId>.json` (sidecar) · เขียนชื่อชั่วคราวแล้ว rename (atomic) · sidecar เขียน **หลัง** jpg — jpg ที่ไม่มี sidecar = เศษ ลบตอนเปิดแอป |
| Web | IndexedDB ฐานใหม่ `srisurart_sale_photos` store `pending` — **แยกจาก Drift และจาก `srisurart_auth`** | ค่า 1 แถว = sidecar + `Uint8Array` ของ JPEG ใน transaction เดียว |

sidecar (JSON):

```jsonc
{ "photoId": "0199…", "saleId": "0199…", "tenantId": "…", "receiptNo": "RC01-2569-10-0042",
  "idempotencyKey": "salephoto-…",   // สร้างครั้งเดียวตอนบันทึก — ไม่สร้างใหม่ตอนลองซ้ำ
  "takenAt": "2026-10-12T07:05:11.000Z", "sortOrder": 0,
  "state": "pending" | "failed", "attempts": 0, "lastCode": null, "lastMessage": null }
```

- `uploading` เป็นสถานะในหน่วยความจำเท่านั้น — แอปตายระหว่างส่ง = กลับมาเป็น `pending` แล้วส่งซ้ำด้วย key/photoId เดิม (server ตอบ replay)
- Web: storage อาจถูก browser ไล่ทิ้งเมื่อพื้นที่ตึง — แอปขอ `navigator.storage.persist()` อยู่แล้ว (08 D2/F8) ·
  ถ้าเปิดฐานไม่ได้ ปุ่ม `บันทึก` แจ้งตาม §2.2 (ไม่หายเงียบ)
- เพดานคิว: ไม่เกิน **200 รูป** ต่อเครื่อง (~60 MB) — เกินแล้วปุ่ม `ถ่ายรูปหลักฐานสินค้า` disabled พร้อมเหตุผล
  (กันเครื่องที่ออฟไลน์นานเป็นสัปดาห์เต็มดิสก์) — ตัวเลขนี้เป็นข้อเสนอ (Q8)

### 3.3 บิลยังอยู่ใน outbox (ขายออฟไลน์)

`sale.id` เป็น UUIDv7 ที่เครื่องสร้าง **ก่อน** ส่ง (ตรวจแล้ว: `api_sales_repository.dart` ใช้ `attempt.id`
ทั้งทางออนไลน์และ `sale.create` ใน outbox, server เก็บ `id` จาก body — `sales.dto.ts requiredUuid(b.id)`) →
รูปผูกกับ `saleId` ได้ทันที แม้บิลยังไม่ถึง server

**ด่านก่อนส่งรูปแต่ละรูป:** ส่งได้ก็ต่อเมื่อ `outbox_ops` **ไม่มี** แถว `type = 'sale.create'` ที่ `aggregates`
มี `sale:<saleId>` (outbox ใส่ `'sale:$saleId'` ใน aggregates อยู่แล้ว) — อ่าน Drift อย่างเดียว ไม่แก้ schema

- op ยัง `pending`/`stuck` → รูปรอ (ข้อความ `รออัปโหลด — บิลยังไม่ถึงเซิร์ฟเวอร์`)
- op `rejected` → รูปรอเหมือนกัน (คนอาจกด "ส่งใหม่"/"ทิ้ง" ใน owner review) — ถ้า op ถูก discard แถวหายไป →
  รอบถัดไปส่ง → `404` → failed (§3.1) · ไม่ต้องผูก discard ของ outbox เข้ากับคิวรูป
- **ตัวกระตุ้นการส่ง:** หลังบันทึกรูป · หลัง `SyncService.push()` จบ (บิลอาจเพิ่งขึ้น) · ตอนกลับมาออนไลน์ · หลัง login ·
  ตอนเปิดแอป · ตัวจับเวลา backoff ขณะยังมีงานค้าง — **ส่งทีละรูป ตามลำดับ** (ไม่ขนาน: api มี RAM 384 MB, sharp `concurrency(1)`)

### 3.4 รีสตาร์ต / logout / เปลี่ยนร้าน

| เหตุการณ์ | ผล |
|---|---|
| ปิดแอป/รีสตาร์ต | รูป `pending`/`failed` อยู่ครบ (ไฟล์/IndexedDB) · ตัวส่งเริ่มเองหลัง login |
| logout แล้ว user อื่นของร้านเดียวกัน login บนเครื่อง `pos` เดิม | ส่งต่อได้ — server บันทึก `uploaded_by` = คนที่ login ตอนส่ง และ `device_id` (เวลาถ่ายอยู่ใน `taken_at`) · *ร้านมี user active คนเดียว (08 D1) จึงไม่ต่างในทางปฏิบัติ* |
| เปลี่ยน tenant / enrol ใหม่ | 🔴 **นับรูปค้างเป็น "งานที่ยังไม่ส่ง"** ใน `TenantCacheGuard` (`TENANT_SWITCH_UNSENT_WORK`, `ENROL_UNSENT_WORK`) — ทางเลือกอื่นคือรูปหลักฐานหายเงียบ · ปลดได้โดย `ทิ้งรูป` ในแผ่นรายการ · ตัวส่งส่งเฉพาะรูปที่ `tenantId` ตรงกับร้านปัจจุบัน (กันพลาด) |
| owner replace-import (`?mode=replace`) | บิลเดิมถูกลบ → รูปค้างได้ `404` → failed → ทิ้ง |
| ล้าง storage ของเครื่อง/ browser | รูปค้างหาย (ยอมรับแบบเดียวกับ op ค้าง — 08 §0 "storage ของเครื่องถูกล้าง") |

### 3.5 ใครลบรูปได้ (ข้อเสนอ — **Q2**)

- **MVP: ไม่มี endpoint ลบ** · `pos_app` ไม่มีสิทธิ์ `UPDATE`/`DELETE` บน `sale_photos` (append-only แบบ `audit_log` #399)
  → หลักฐานแก้ย้อนหลังไม่ได้แม้มีบั๊กในแอป
- ทิ้งรูปได้เฉพาะ **ก่อนขึ้น server** (ในแผ่นถ่าย หรือรูป failed ในคิว)
- ข้อเสนอสำหรับรอบถัดไป (ถ้า owner ต้องการ เช่นรับคำขอลบตาม PDPA): `DELETE /sales/:id/photos/:photoId`
  **owner เท่านั้น + เหตุผลบังคับ** → soft delete (`deleted_at`, `deleted_by`, `delete_reason`) + `audit_log` `sale_photo.deleted`
  → ลบไฟล์หลัง commit ตามกติกา orphan เดิม (`removeImageFilesIfStale`) — ต้องมี migration ให้ `pos_app` `UPDATE` เฉพาะคอลัมน์ลบ

### 3.6 ระยะเก็บ + PDPA (ข้อเสนอ — **Q3, Q4**)

- รูปอาจมีหน้าลูกค้า/ทะเบียนรถ/มือช่าง = ข้อมูลส่วนบุคคล → (1) คำแนะนำบนแผ่นถ่าย "ไม่ต้องถ่ายหน้าลูกค้าหรือทะเบียนรถ"
  (data minimisation ที่ต้นทาง) (2) ดูได้ผ่าน API ที่ต้อง login เท่านั้น (§4.4) (3) pipeline เดิม **ตัด EXIF/GPS ทั้งหมด**
  (ตำแหน่งร้าน/เครื่องไม่หลุด) (4) ไม่อยู่ใน `audit_log`/log ใด ๆ (5) ไม่อยู่ในไฟล์ backup ZIP ของเจ้าของร้าน (§5.4)
- **ระยะเก็บ MVP: ตามอายุบิล ไม่มีลบอัตโนมัติ** — ข้อเสนอให้ owner เลือก: เก็บ **1 ปี** หลังวันขาย แล้ว BullMQ job รายวันลบ
  (ครอบระยะรับประกัน/คืนของอะไหล่ส่วนใหญ่; ต้องรู้นโยบายรับคืนของร้านก่อน) — งานนี้อยู่นอก MVP
- พื้นที่ดิสก์ (ประมาณ): preview 1600 px WebP ~250 KB + thumb ~15 KB ≈ **0.27 MB/รูป** · 10 บิล/วัน × 3 รูป ≈ 8 MB/วัน ≈ **3 GB/ปี**
  → ต้องดูดิสก์ `mob04` ก่อนเปิดใช้ (Q7)

---

## 4. API

### 4.1 สรุป endpoint (tenant plane, prefix `/api/v1`)

| Method + Path | ใคร | Idempotency | ตอบ |
|---|---|---|---|
| `PUT /sales/:saleId/photos/:photoId` | `@RequireDeviceRole('pos')` (เครื่องที่ขาย) — role คนใดก็ได้ของร้าน | `Idempotency-Key` บังคับ · fingerprint = path จริง + sha256 ของไบต์ body (กลไกเดิมของ `PUT /products/:id/image`) · **และ** idempotent ตาม `photoId` ถาวร (§4.2) | `201` + photo (ครั้งแรก) / `200` + photo (ซ้ำ) |
| `GET /sales/:saleId/photos` | ผู้ใช้ทุก role ของร้าน, เครื่องใดก็ได้ | — | `200` `[{ id, saleId, takenAt, createdAt, sortOrder, width, height }]` เรียง `sortOrder, created_at` · บิลไม่มี/ของร้านอื่น = `404 SALE_NOT_FOUND` · ไม่มีรูป = `[]` |
| `GET /sales/:saleId/photos/:photoId/:variant` (`t`\|`p`) | เหมือนบน | — | `200` `image/webp` ไบต์ล้วน (ไม่ห่อ envelope เหมือน `/metrics`) · `Cache-Control: private, max-age=31536000, immutable` · `X-Content-Type-Options: nosniff` · ไม่มี = `404` |

ไม่มี endpoint ลบใน MVP (§3.5) · ไม่มี list รูปข้ามบิล

### 4.2 `PUT /sales/:saleId/photos/:photoId`

- body = ไฟล์ดิบ `image/jpeg|png|webp` ≤ **3 MB** · query `?takenAt=<ISO-8601>&sortOrder=<0-4>`
  (body เป็นไบต์รูป จึงส่ง metadata ทาง query) · ⚠️ fingerprint ของ idempotency = `method + baseUrl + path` + hash ของ body
  (`idempotency.runner.ts:41-42`) — **ไม่รวม query** · ไม่เป็นปัญหาเพราะ client ไม่เปลี่ยน query ของ photoId เดิม (อยู่ใน sidecar);
  replay ตอบแถวเดิมเสมอ ค่า query ของคำขอซ้ำถูกเมิน
- **raw parser** (`app.setup.ts`): แบบเดียวกับรูปสินค้า แต่เงื่อนไขคือ access token ที่ verify แล้ว **มี `did`** และ device role `pos`
  (ไม่ใช่ owner-only) — คนอื่นไม่ทำให้ API บัฟเฟอร์ 3 MB · เกิน = `413 SALE_PHOTO_TOO_LARGE` ตอบที่ชั้นนี้
- ลำดับในตัว handler (เหมือน `ProductImagesController`):
  1. `processImage(body, { preview: 1600 })` — **ก่อน** claim ไม่ถือ connection (sharp ช้า) · sniff magic bytes ก่อน sharp,
     `failOn:'error'`, `INPUT_PIXEL_LIMIT` 24 MP, auto-orient, ตัด metadata, preview ≤ 1600 WebP q80, thumb 256 WebP q75
  2. `writeImageFiles(saleStore, tenantId, key, …)` ลง volume `sale-photos`
  3. `runIdempotent` → `runTx`:
     - `SELECT … FROM sales WHERE tenant_id, id FOR UPDATE` (ล็อกตามลำดับ: `sales` ก่อน — ตรงกฎ lock order) ไม่มี = `404 SALE_NOT_FOUND`
     - มีแถว `photoId` อยู่แล้ว: `sale_id` ตรง **และ** `source_sha256` (sha256 ของ body ที่ส่งมา) ตรง → `200` + แถวเดิม (replay ถาวร
       หลัง idempotency key หมดอายุ 24 ชม.) · ไม่ตรง → `409 CLIENT_ID_REUSED` (exception เดิม `client-id-reused.exception.ts`)
     - นับรูปของบิล ≥ 5 → `409 SALE_PHOTO_LIMIT`
     - `INSERT` แถว (`uploaded_by` = `req.user.userId`, `device_id` = `req.user.deviceId`, `created_at` = `now()`)
  4. `finally` (นอก tx): ถ้าไม่มีแถวใดอ้าง key และไม่ใช่ 503 in-flight → ลบไฟล์ (`settleImage`/`dropIfUnreferenced` แบบเดิม)
- 🔴 **ทำไมเทียบ `source_sha256` ไม่ใช่ `image_key`:** key มาจากผลของ sharp — ถ้าอัป libvips ระหว่างที่รูปค้างในเครื่อง
  ผลเข้ารหัสอาจต่างไบต์ → replay ของรูปเดิมจะถูกมองเป็นรูปอื่น (`409` ปลอม) · ไบต์ที่ client ส่งไม่เปลี่ยน (เก็บในคิวแล้ว)
- `takenAt`: ต้องเป็น ISO-8601 ที่ parse ได้ และ **ไม่เกิน `now() + 10 นาที`** (ผิด = `400 BAD_REQUEST`) — validate ก่อน ไม่ clamp
  (บทเรียน #22/#24) · ไม่บังคับให้อยู่หลังวันขาย (นาฬิกาเครื่องเพี้ยนได้; แสดงทั้งเวลาถ่ายและเวลาอัปโหลด §2.4)
- ไม่มี window เวลาอัปโหลด (รูปค้างออฟไลน์หลายวันต้องขึ้นได้) — ระยะจำกัดเป็น Q5
- ตอบ: `{ id, saleId, takenAt, createdAt, sortOrder, width, height }` — **ไม่มี** `imageKey` ใน response (client ไม่ต้องรู้;
  เปิดเผยน้อยที่สุด) · `width/height` ของ preview ให้ client จองพื้นที่ก่อนโหลด
- บิลที่ void แล้ว/คืนครบแล้ว: **รับรูป** (หลักฐานยังมีค่าตอนพิพาท)

### 4.3 กติกา idempotency (ตามที่ repo บังคับ)

- fingerprint = **path จริง** (`/api/v1/sales/<uuid>/photos/<uuid>`) ไม่ใช่ pattern + hash ของไบต์ — key เดิมกับรูปอื่น = `409 IDEMPOTENCY_KEY_REUSED`
- route ใหม่ต้องขึ้นใน `idempotency-routes.spec.ts` (สเปกสถาปัตยกรรม — แก้โดยตั้งใจ)
- client: key + photoId สร้าง **ครั้งเดียวตอนบันทึก** เก็บใน sidecar · 4xx = คำตัดสิน · 5xx/429/หลุด = ไม่รู้ผล → ลองซ้ำด้วยของเดิม
- `ApiException` ไม่หลุดถึงจอ — แปลงเป็นข้อความไทยใน repository (`posExceptionFromApi`) ตามกติกา #642/#644

### 4.4 URL สาธารณะ (`/img/`) vs ผ่าน API — เลือกผ่าน API

| | `/img/` แบบรูปสินค้า | ผ่าน API ที่ต้อง login (เลือก) |
|---|---|---|
| ใครเปิดได้ | ใครก็ได้ที่มี URL — ตลอดไป เพิกถอนไม่ได้ | ผู้ใช้ของร้านที่ token ยังใช้ได้ |
| URL รั่วทาง | ประวัติ browser, log, แคปหน้าจอ, ส่งต่อในแชต | ไม่มี — URL ไร้ token ใช้ไม่ได้ |
| เหมาะกับ | รูปสินค้า (ไม่ลับ, หน้าขายโหลดถี่) | รูปที่อาจมีหน้าคน/ทะเบียน (PDPA), ดูนาน ๆ ครั้ง |
| ต้นทุน | 0 (nginx) | Node อ่านไฟล์ ~15–250 KB ต่อครั้ง — นาน ๆ ครั้ง (หน้ารับคืน/รายละเอียดบิล) |
| client | `Image.network` | `ApiClient.getBytes` → `Image.memory` (ได้ CA ของร้านบน Android + token ครบทุกแพลตฟอร์มโดยไม่ต้องพึ่ง header ของ `Image.network` บน web) + แคช thumbnail ในหน่วยความจำ |

- 🔴 การเสิร์ฟไฟล์ห้ามถือ pool connection: ตรวจแถว `sale_photos` (RLS) ใน `runTx` สั้น ๆ → ปิด tx → ค่อย stream ไฟล์
- ไม่ใช้ `X-Accel-Redirect`: ต้อง mount volume ให้ Nginx — เสียข้อดี "Nginx มองไม่เห็นไฟล์เลย" (§5.3) เพื่อประหยัดสิ่งที่ไม่แพง

### 4.5 audit_log

- **ไม่เขียน `audit_log` ตอนเพิ่มรูป** — แถว `sale_photos` คือบันทึกเอง (`uploaded_by`, `device_id`, `created_at`, append-only)
- ถ้ามีการลบในอนาคต (§3.5) เขียน `sale_photo.deleted` — `before` = `{ saleId, photoId, takenAt, uploadedBy }` · 🔴 **ไม่มีไบต์รูปหรือ `image_key` ใน audit เลย**
- log ของ pino: ห้ามพิมพ์ body; พิมพ์ได้แค่ `photoId`/`saleId`

---

## 5. ข้อมูล (Data)

### 5.1 Postgres — migration ใหม่ `17886528052xx-SalePhotos.ts` (เลขต่อจากตัวล่าสุดใน `MIGRATIONS`)

```sql
CREATE TABLE sale_photos (
  tenant_id      UUID NOT NULL REFERENCES tenants(id),
  id             UUID NOT NULL,            -- photoId ที่เครื่องสร้าง (UUIDv7)
  sale_id        UUID NOT NULL,
  image_key      TEXT NOT NULL,            -- 32 hex ของ sha256(preview) — ชื่อไฟล์ใน volume sale-photos
  source_sha256  TEXT NOT NULL,            -- sha256 ของ body ที่ client ส่ง — ใช้ตัดสิน replay ของ photoId
  width          INT  NOT NULL,
  height         INT  NOT NULL,
  sort_order     SMALLINT NOT NULL DEFAULT 0,
  taken_at       TIMESTAMPTZ NOT NULL,     -- นาฬิกาเครื่อง (อ้างอิง ไม่ใช่ความจริง)
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),  -- เวลาที่ server รับ
  uploaded_by    UUID NOT NULL,
  device_id      UUID NOT NULL,
  CONSTRAINT pk_sale_photos PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_sale_photos_sale FOREIGN KEY (tenant_id, sale_id) REFERENCES sales (tenant_id, id),
  CONSTRAINT ck_sale_photos_image_key CHECK (image_key ~ '^[0-9a-f]{32}$'),
  CONSTRAINT ck_sale_photos_source CHECK (source_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT ck_sale_photos_sort CHECK (sort_order BETWEEN 0 AND 4)
);
CREATE INDEX idx_sale_photos_sale ON sale_photos (tenant_id, sale_id, sort_order, created_at);
CREATE INDEX idx_sale_photos_key  ON sale_photos (tenant_id, image_key);   -- เช็ก orphan ก่อนลบไฟล์
ALTER TABLE sale_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE sale_photos FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON sale_photos
  USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
GRANT SELECT, INSERT ON sale_photos TO pos_app;   -- ไม่มี UPDATE/DELETE: append-only
```

- FK ไม่มี `ON DELETE` (บิลไม่ถูกลบโดยแอป — void คือสถานะ) · ห้าม `ON DELETE SET NULL` แบบไม่มีรายชื่อคอลัมน์ (บั๊ก `OwnerReviewItems`)
- `uploaded_by`/`device_id`: ใส่ FK `(tenant_id, …)` → `users`/`devices` ถ้าสองตารางนั้นมี PK `(tenant_id, id)` จริง — **ตรวจใน
  migration ก่อนเขียน** (ไม่อ้างจาก DDL ใน `01` — กติกา "migration คือความจริง")
- 5 รูปต่อบิล บังคับที่ service ใต้ล็อกแถว `sales` (§4.2) ไม่ใช่ constraint
- RLS สร้างใน migration นี้เอง (ไม่แก้ `TENANT_SCOPED_TABLES` ของ migration ที่ ship แล้ว — แนวเดียวกับ `PaymentAccounts`)
- Postgres จะเป็น **31 ตาราง** — แก้ตัวเลขใน `CLAUDE.md`/`01_DATABASE.md` ตอน merge

### 5.2 Drift — **ไม่เปลี่ยน** (schema v15 คงเดิม)

- คิวอยู่นอก Drift (§3.2) · รายการรูปบน server ไม่แคชลง Drift (ดึงสดเมื่อเปิดตัวดู — นาน ๆ ครั้ง, ต้องออนไลน์อยู่ดีเพื่อโหลดรูป)
- ไม่ต้องรัน `build_runner` บน path ASCII · ไม่ต้องมี `TableMigration` · ไม่ลบ sync cursor
- ราคาที่จ่าย: หน้ารับคืนออฟไลน์ไม่รู้ว่าบิลมีรูปบน server กี่รูป — ยอมรับ (ดูรูปต้องมีเน็ตอยู่แล้ว)

### 5.3 ไฟล์ — volume ใหม่ `sale-photos`

- `server/docker-compose.yml`: volume `sale-photos` → api-1..3 + worker ที่ `/app/sale-photos` (`SALE_PHOTOS_DIR`) · **Nginx ไม่ mount**
  (ประกาศใน `docker-compose.yml` ไม่ใช่ `vm.override.yml` — ให้ถึง `mob04` ผ่าน compose ที่ `deploy.yml` copy, แบบ `product-images`)
- `server/Dockerfile`: สร้าง `/app/sale-photos` เป็นของ `node` (volume ใหม่รับ ownership จาก image — แบบ `/app/product-images`)
- โครงไฟล์: `<tenantId>/<imageKey>_t.webp`, `_p.webp` — **ใช้ `image-store.ts` ตัวเดิม** โดยเปลี่ยนจาก `productImagesDir()` ตายตัว
  เป็นฟังก์ชันที่รับราก (`imageStore(rootDir)` → `writeImageFiles/removeImageFiles/removeImageFilesIfStale/listImageKeys`) —
  รูปสินค้าเรียกด้วย `productImagesDir()` เหมือนเดิม พฤติกรรมไม่เปลี่ยน
- `image-pipeline.ts`: แยกค่าที่ต่าง (ขนาด preview, ข้อผิดพลาดที่โยน) เป็นพารามิเตอร์ — sniff, เพดานพิกเซล, `failOn`, `sharp.concurrency(1)` ใช้ร่วม ·
  **ไม่มี native binary ใหม่** (sharp + libvips 8.18.7 ที่ build เองตัวเดิม — ไม่แตะข้อจำกัด `qemu64` ของ `mob04`)
- ทำไมไม่ใส่ใน `product-images` ใต้โฟลเดอร์ย่อย: regex ของ `/img/` จับ `<uuid>/<32hex>_[tp].webp` — ถ้าวางผิดชั้นวันใดวันหนึ่ง
  รูปหลักฐานจะกลายเป็นสาธารณะ · volume แยกที่ Nginx มองไม่เห็นตัดความเสี่ยงนี้ทิ้งทั้งหมด

### 5.4 Backup / restore

| ส่วน | ผล | งาน |
|---|---|---|
| `pg_dump` (`backup-db.sh`) | `sale_photos` อยู่ใน dump อัตโนมัติ | — |
| ไฟล์รูป | **ไม่อยู่ใน `pg_dump`** | `backup-db.sh` เพิ่ม `pos_sale_photos_<ts>.tar.gz` + `.sha256` (`.partial` + `mv`, prune/offsite เดียวกัน) · 🔴 Nginx ไม่ mount volume นี้ → `tar` ผ่าน `docker compose exec -T worker tar -cf - -C /app/sale-photos .` (ตรวจว่า image มี `tar` — node alpine มี busybox) หรือ `SALE_PHOTOS_DIR` นอก compose · ไม่มี volume = `::warning::` exit 0 แบบรูปสินค้า · test ใน `backup-db.test.sh` |
| ติดตั้งสคริปต์บน `mob04` | 🔴 **CD ไม่อัปเดต `/opt/pos/scripts`** | ติดตั้งมือ (`sudo install -o deploy -g deploy -m 0755`) หรือ `provision.yml` หลัง merge — ไม่งั้น backup ไม่มีรูปหลักฐานแบบเงียบ |
| `restore-db.sh` | ยังไม่กู้รูปสินค้า → ไม่กู้รูปหลักฐานด้วย | บันทึกเป็นข้อจำกัด (เหมือนรูปสินค้า) |
| backup ZIP ของเจ้าของร้าน (`POST /backup/export`) | **MVP ไม่รวม** รูปหลักฐาน / แถว `sale_photos` | ขนาด: หลาย GB ต่อปี เกินเพดาน import 200 MB · ไฟล์ที่เจ้าของร้านดาวน์โหลดเก็บเองไม่ควรพก PDPA data ติดไปโดยไม่ตั้งใจ — Q6 |
| owner replace-import | 🔴 `REPLACED_TABLES` ต้องมี `'sale_photos'` **ก่อน** `'sales'` (FK — ไม่ใส่ = import แทนที่ล้มทุกครั้งที่ร้านมีรูป) · import รันด้วย `adminDs` จึงลบได้แม้ `pos_app` ไม่มี DELETE | แถวหาย · **ไฟล์ไม่ถูก sweep** (sweep ของ import แตะแค่ `product-images`) → ไฟล์ค้างใน volume (ยังอยู่ใน tar ของ `backup-db.sh`) · pre-import ZIP ไม่มีรูปหลักฐาน → replace = รูปหลักฐานของร้านหายจากแอป (Q6) |
| platform import (ร้านว่าง) | ไม่มีบิล → ไม่มีรูป | — |

---

## 6. ชิ้นที่เล็กที่สุดที่ใช้ได้ (MVP) vs ทีหลัง

### MVP (ทำ)

1. Server: migration `sale_photos` + `PUT` + `GET list` + `GET bytes` + volume `sale-photos` + `REPLACED_TABLES`
2. Client: ปุ่มบนใบเสร็จ → แผ่นถ่าย/เลือกรูป (1–5, ลบก่อนบันทึก) → คิวในเครื่อง (ไฟล์/IndexedDB) → ตัวส่งเบื้องหลังพร้อมด่าน outbox
   → ป้าย + แผ่นรายการค้าง (ลองอีกครั้ง/ทิ้ง)
3. ตัวดู: `SalePhotoStrip` + ตัวดูเต็มจอ ในหน้ารับคืน และแผ่นรายละเอียดบิลใหม่ (แตะแถวบิลในรายงาน)
4. Ops: `backup-db.sh` เก็บ volume ใหม่ + ติดตั้งบน `mob04` · เอกสาร `02`/`07`/`01`

### ตัดออกโดยตั้งใจ (ไม่ทำใน MVP)

- ❌ ลบรูปที่ขึ้น server แล้ว (ทุก role) — §3.5, Q2
- ❌ ลบอัตโนมัติตามอายุ / job ระยะเก็บ — Q3
- ❌ เพิ่มรูปทีหลังจากหน้าอื่น (รับคืน, รายละเอียดบิล) — Q5
- ❌ webcam capture บน PC (`getUserMedia`) — เลือกไฟล์แทน
- ❌ รูปหลักฐานใน backup ZIP ของเจ้าของร้าน + กู้รูปจาก `restore-db.sh` — Q6
- ❌ จำนวนรูปในรายการบิล (`photoCount` ใน `GET /sales`) / ไอคอนกล้องบนแถวบิล — ต้องแก้ shape ของ sales + pull
- ❌ หน้าประวัติการขายเต็มรูปแบบ (ค้น/กรอง) — มีแค่แผ่นรายละเอียดบิลจากแถวในรายงาน
- ❌ คำอธิบายใต้รูป (caption), วาด/ชี้รอยบนรูป, ลายน้ำบนพิกเซล
- ❌ ผูกรูปกับรายการสินค้าทีละบรรทัด (รูปผูกกับทั้งบิล)
- ❌ Drift-only build (ไม่มี server)
- ❌ แสดงรูปในใบเสร็จพิมพ์ / ใบลดหนี้ / PDF

---

## 7. แผนลงมือ (ticket ตามลำดับ)

ทุกใบจบด้วยข้อตกลง `09 §10`: `/scrutinize` แนวทาง → เขียนตาม `karpathy-guidelines` → เทสกับ fake ของฝั่งตัวเอง → `/code-review`
· PR เข้า `develop` · ห้าม auto-merge ขณะ agent ยัง push

```
S1 ──► S2 ──► S3 ─────────────┐
 │                            ├──► X1 (ลองจริงบน mob04)
 └─ fixture/contract ─► C1 ──► C2 ──► C3 ┘
                        O1 (ขนานได้ตั้งแต่ S1 merge) ──┘
```

**S1 — server: เก็บไฟล์ใช้ร่วม + migration** *(ไม่มี dependency)*
- `image-store.ts` รับรากเป็นพารามิเตอร์ · `image-pipeline.ts` รับขนาด preview + ตัวสร้าง error · migration `sale_photos` · volume
  `sale-photos` ใน compose + Dockerfile · `REPLACED_TABLES` += `sale_photos` · contract fixture ใหม่ใน
  `docs/Backend_design/fixtures/` (shape ของ response สาม endpoint) ให้ client ทำขนานได้
- AC: เทส `image-store`/`image-pipeline` เดิมผ่านโดยไม่แก้ assertion (รูปสินค้าไม่เปลี่ยนพฤติกรรม) · `schema.e2e-spec` ยืนยัน RLS
  (tenant ว่าง = 0 แถว ไม่ใช่ 22P02), `pos_app` `UPDATE`/`DELETE` ถูกปฏิเสธ, FK ไปบิลร้านอื่นไม่ได้ · e2e owner replace-import บนร้านที่มีรูปผ่าน
- Test: unit + `schema.e2e-spec.ts` + `owner-import` e2e เพิ่มเคส

**S2 — server: `PUT /sales/:saleId/photos/:photoId`** *(รอ S1)*
- raw parser ที่ verify token + `did` · controller/service ตาม §4.2 · route ใน `idempotency-routes.spec.ts` · error code ใหม่ใน `02 §8.1`
- AC: (1) ครั้งแรก `201` + แถว + ไฟล์ทั้งสองอยู่ใน `sale-photos` ไม่อยู่ใน `product-images` (2) key เดิม+ไบต์เดิม = `200` เดิม
  (3) key ใหม่+photoId เดิม+ไบต์เดิม = `200` (replay ถาวร) (4) photoId เดิม+ไบต์อื่น = `409 CLIENT_ID_REUSED` (5) รูปที่ 6 = `409 SALE_PHOTO_LIMIT`
  รวมกรณีส่ง 2 รูปพร้อมกันตอนมี 4 (ล็อกจริง) (6) บิลร้านอื่น/ไม่มี = `404` และไฟล์ที่เพิ่งเขียนถูกลบ (7) `backoffice` = `403`
  (8) PNG ที่ตัดครึ่ง / SVG / > 24 MP = `400`, > 3 MB = `413` ก่อน guard (9) EXIF GPS ไม่อยู่ในไฟล์ผลลัพธ์ (10) `takenAt` อนาคต > 10 นาที = `400`
- Test: e2e ใหม่ `sale-photos.e2e-spec.ts` (ล็อกอิน > 10 ครั้งต้องส่ง `X-Forwarded-For` เอง #449) · ค่า key ทดสอบ entropy ต่ำ (gitleaks)

**S3 — server: `GET` list + bytes** *(รอ S1; ขนานกับ S2 ได้แต่ทดสอบง่ายกว่าหลัง S2)*
- AC: list เรียงถูก, ร้านอื่น = `404`, ไม่มี token = `401` · bytes: `image/webp`, `private, immutable`, `nosniff`, ไม่ห่อ envelope ·
  การ stream ไม่ถือ pool connection (เทส: `DB_POOL_SIZE` = 1 แล้วโหลดรูปพร้อม `POST /sales` ไม่ deadlock) · `/img/<tenant>/<key>_t.webp`
  ของรูปหลักฐาน = `404` (ใน `nginx-img.test.sh`)
- Test: e2e + `nginx-img.test.sh` เพิ่มเคส

**C1 — client: คิวในเครื่อง + ตัวส่ง** *(ขนานกับ S2/S3 — ทดสอบกับ fake API จาก fixture)*
- `PendingSalePhotoStore` (io + web), `SalePhotoUploader` (ด่าน outbox §3.3, ตาราง §3.1, backoff, ทีละรูป), นับรวมใน `TenantCacheGuard`,
  `ApiSalePhotosRepository` (`sendBytes`/`getBytes`), ข้อความไทยผ่าน `posExceptionFromApi`
- AC: รีสตาร์ตแล้วรูปยังอยู่และส่งต่อด้วย key/photoId เดิม · บิลใน outbox = ไม่ยิง request เลย · 5xx/429/transport = pending · 4xx = failed ·
  401 = หยุดรอ login · jpg ไม่มี sidecar ถูกลบตอนเปิด · เปลี่ยน tenant ถูกปฏิเสธเมื่อมีรูปค้าง · `ApiException` ไม่หลุด
  (`api_exception_never_escapes_test.dart` ครอบ repo ใหม่) · `api_repository_contract_test.dart` ครอบ repo ใหม่
- Test: unit กับ store ปลอม + `fake_async` สำหรับ backoff · web store ทดสอบด้วย `flutter test --platform chrome` ถ้า CI รองรับ ไม่งั้นแยก interface ให้เทส logic ได้

**C2 — client: แผ่นถ่ายรูป + ป้าย + แผ่นรายการค้าง** *(รอ C1)*
- เพิ่ม `image_picker` (กล้อง Android/iOS) — 🔴 ตรวจว่า build ได้กับ `android.builtInKotlin=false` แบบที่ `file_picker` เคยพัง ·
  iOS `NSCameraUsageDescription` · ปุ่มบนใบเสร็จ (API build เท่านั้น) · `shrinkProductPhoto` ใช้ซ้ำ (เปลี่ยนชื่อเป็น `shrinkPhoto` ถ้าแตะอยู่แล้ว)
- AC: ปุ่มไม่โผล่บน Drift build · ขายแล้ว dialog ใบเสร็จขึ้นเร็วเท่าเดิม (ไม่มี await ใหม่ก่อนแสดง) · 5 รูปแล้วเพิ่มไม่ได้ · ✕ ทิ้งได้ ·
  บันทึกออฟไลน์ได้ · เขียนคิวล้ม = แผ่นไม่ปิด · route smoke test 3x/2x ผ่าน · ดูด้วยตาบน web build (`--no-web-resources-cdn`, ล้าง SW) ที่ 390 px
- Test: widget test + smoke test + ลองบน APK จริงหนึ่งเครื่อง (กล้อง)

**C3 — client: ตัวดูรูป** *(รอ C1; ขนานกับ C2)*
- `SalePhotoStrip` + ตัวดูเต็มจอ ใน `_RefundDetail` · แผ่นรายละเอียดบิลจาก `_RecentRow` ในรายงาน
- AC: ไม่มีรูป/ออฟไลน์/กำลังโหลด แสดงตาม §2.4 · รูปค้างในเครื่องของบิลนั้นขึ้นพร้อมป้าย · preview โหลดเมื่อเปิดเต็มจอเท่านั้น ·
  Android โหลดผ่าน CA ของร้าน (ไม่มี `badCertificateCallback`) · `presentation_no_api_exception_test.dart` ผ่าน
- Test: widget test + smoke test 3x/2x

**O1 — ops/docs** *(หลัง S1 merge, ขนานกับที่เหลือ)*
- `backup-db.sh` + test · `02 §3.1/§3.7/§4.2/§8.1/§8.1.1` · `07 §9` (volume ใหม่, Nginx ไม่ mount, สคริปต์ติดตั้งมือ) · `01_DATABASE.md` ตาราง 31 ·
  คู่มือ SOP `docs/tutorial/sri-pos-manual/` หน้าใหม่ "ถ่ายรูปหลักฐาน" · ข้อความไทยรอ owner รับรอง
- AC: `backup-db.test.sh` ครอบ volume ใหม่ (มี/ไม่มี) · `.partial` ไม่ค้าง · เอกสารอ้าง section ที่มีจริง (grep ก่อนเขียน)

**X1 — ลองจริงบน `mob04`** *(หลัง release ที่มีทุกใบ)*
- ติดตั้ง `backup-db.sh` มือ (sha256 = `origin/main`) · ขายจริง 1 บิลออนไลน์ + 1 บิลออฟไลน์พร้อมรูป → รูปขึ้นหลังกลับมาออนไลน์ → เห็นจากอีก
  เครื่องในหน้ารับคืน · รัน `backup-db.sh` ในสภาพ cron แล้วตรวจ tar มีไฟล์ · ตรวจ `.current_sha` · ลอง `/img/` กับ key รูปหลักฐาน = 404
- ดูดิสก์ `mob04` (`df -h` ของ volume) ก่อนเปิดให้ร้านใช้ (Q7)

---

## 8. คำถามถึง owner

| # | คำถาม | ข้อเสนอของไฟล์นี้ |
|---|---|---|
| Q1 | ใครดูรูปได้ — ทุกคนในร้าน หรือ owner เท่านั้น? | ทุก role ของร้าน (พนักงานหน้าร้านต้องใช้ตอนรับคืน) |
| Q2 | ใครลบรูปที่ขึ้น server แล้วได้? | MVP: ไม่มีใคร · รอบหน้า (ถ้าต้องการ): owner เท่านั้น + เหตุผล + audit + soft delete |
| Q3 | เก็บรูปนานแค่ไหน? นโยบายรับคืน/รับประกันของร้านกี่วัน? | MVP: ไม่ลบ · เสนอ 1 ปีหลังวันขายแล้วลบอัตโนมัติ (job แยก) |
| Q4 | ต้องแจ้งลูกค้าก่อนถ่าย (PDPA) ไหม — ป้ายหน้าร้าน/ข้อความบนใบเสร็จ? | คำแนะนำบนแผ่นถ่าย "ไม่ต้องถ่ายหน้าลูกค้าหรือทะเบียนรถ" + ป้ายหน้าร้าน (owner ตัดสินถ้อยคำ) |
| Q5 | ต้องเพิ่มรูปทีหลังได้ไหม (เช่นลืมถ่าย)? ถ้าได้ ภายในกี่ชั่วโมง? | MVP: ไม่ได้ — หลักฐานที่เพิ่มหลังเกิดข้อพิพาทน่าเชื่อถือน้อยลง |
| Q6 | รูปหลักฐานควรอยู่ใน backup ZIP ที่เจ้าของร้านดาวน์โหลด และรอด replace-import ไหม? | MVP: ไม่อยู่ (ขนาด + PDPA) · replace-import ทำให้รูปหายจากแอป (ไฟล์ยังอยู่บน VM) |
| Q7 | ดิสก์ `mob04` รับได้ ~3 GB/ปี ไหม (ประมาณ 10 บิล/วัน × 3 รูป)? | ตรวจ `df` ก่อนเปิดใช้; ถ้าไม่พอ ลด preview เป็น 1280 px หรือเร่ง Q3 |
| Q8 | เพดานรูปค้างต่อเครื่อง 200 รูปพอไหม? | 200 (~60 MB) |
| Q9 | ความละเอียด preview 1600 px พอเห็นรอยขีดข่วนไหม (รูปสินค้าใช้ 1024)? | 1600 — ลองกับรูปจริงของร้านใน X1 |
| Q10 | ข้อความไทยทั้งหมดใน §2.8 | `agent ร่าง` — รอรับรอง |
