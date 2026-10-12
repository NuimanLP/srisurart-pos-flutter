# 10 — รูปหลักฐานสินค้าตอนขาย (Sale photo evidence) — design

> **สถานะ:** ร่างออกแบบ rev 2 — 2026-10-12 · ผ่าน `/scrutinize` ("go with changes") แล้วแก้ตามครบ · owner ตัดสินข้อเปิดทั้งหมดแล้ว (§0) · ยังไม่มีโค้ด/ticket
> **ใช้ของเดิมซ้ำ:** รูปสินค้า (PR #680/#682) — `02_API_SCREENS.md §3.2/§3.10`, `07_CICD_DEPLOY.md §9`,
> `server/src/product-images/{image-pipeline,image-store}.ts`, `products/product-images.controller.ts`,
> `backup/backup.controller.ts` (stream ไฟล์), `frontend/lib/core/utils/product_photo.dart`
> **ขัดกับ ADR → ยึด ADR** · ขัดกับ `02`/`07` ในเรื่องที่มีอยู่แล้ว → ยึด `02`/`07` แล้วแก้ไฟล์นี้
>
> 🔴 ข้อความไทยทุกคำในไฟล์นี้ที่ไม่ได้มาจาก owner ตรง ๆ เป็น **`agent ร่าง`** (owner 2026-10-12: คงสถานะนี้ไว้ก่อน)

---

## 0. ข้อตัดสินของ owner (2026-10-12 — ผูกมัด ไม่เปิดถกใหม่)

**รอบแรก (ขอบเขตงาน)**

| ข้อ | ตัดสินแล้ว |
|---|---|
| จุดประสงค์ | หลักฐานว่าสินค้า **ใหม่ / ไม่มีรอยขีดข่วน / ไม่ชำรุด** ตอนลูกค้ารับไป |
| เมื่อไหร่ | **ไม่บังคับ หลังจ่ายเงิน** — หน้าใบเสร็จมีปุ่ม `ถ่ายรูปหลักฐานสินค้า` · 1–5 รูป หรือข้าม · **การจ่ายเงินไม่ถูกบล็อกหรือช้าลงเลย** |
| เก็บที่ไหน | **บน server ผูกกับบิล** |
| ดูที่ไหน | หน้า **รับคืน** และ **รายละเอียดบิล** ในรายงาน |
| แพลตฟอร์ม | Android/iOS + Web · PC ไม่มีกล้อง → เลือกไฟล์แทน |

**รอบสอง (หลัง scrutinize)**

| ข้อ | ตัดสินแล้ว |
|---|---|
| A. ดูได้เฉพาะ **เครื่องเดียวกับที่ขาย** ใน v1 | หน้ารับคืนและรายงานอ่านบิลจาก **Drift เท่านั้น** (`ApiSalesRepository.getSales` → `drift.getSales`, `api_sales_repository.dart:695-703`; บิลไม่เคยถูก pull) → เข้าถึงได้แค่บิลที่ขายบนเครื่องนั้น · **v1 ไม่มีการค้นบิลจาก server** · รูปอยู่บน server จริง แต่จะ "เห็นจากเครื่องอื่น" ได้ก็ต่อเมื่อมีงานค้นบิลจาก server (ภายหลัง §6) |
| B. **ไม่มีคิวออฟไลน์ใน v1** — client ออนไลน์เท่านั้น | ไบต์ที่ย่อแล้วอยู่ในหน่วยความจำขณะแผ่นเปิด · กด `บันทึก` = `PUT` ทีละรูป · ล้ม = แผ่นไม่ปิด มีปุ่มลองใหม่ (photoId + key เดิม) · Degraded หรือบิลยังมี `sale.create` ใน `outbox_ops` = ปุ่มถ่าย disabled พร้อมเหตุผล · server ยังทำ photoId replay ถาวร → คิวในอนาคตเป็นงานฝั่ง client ล้วน |
| C. รูป **รอด replace-import** (owner + platform) | ไม่มี FK `sale_photos → sales` (มีแค่ FK tenant; insert ถูกตรวจใต้ล็อกแถว `sales` อยู่แล้ว) · `sale_photos` **ไม่อยู่ใน `REPLACED_TABLES`** → id บิลเดิมกลับมา รูปก็กลับมาผูก · การ sweep ไฟล์ของ import **ห้ามแตะ** volume `sale-photos` |
| D. ข้อเสนอเดิมทั้งหมดรับ | ทุก role ของร้านดูได้ · v1 **ไม่มีใครลบ** · **ไม่ลบอัตโนมัติ** · **ไม่มีเพิ่มรูปทีหลัง** · **ไม่อยู่ใน backup ZIP** · preview **1600 px** · ข้อความไทยคง `agent ร่าง` · ประกาศ PDPA เลื่อนไป — เป็นข้อค้างของ owner (§7) |

---

## 1. สรุปหน้าเดียว

| เรื่อง | v1 |
|---|---|
| ตัวตนของรูป | `photoId` = UUIDv7 ที่เครื่องสร้างตอนได้รูปในแผ่น · ผูกกับ `sale.id` (UUIDv7 ที่เครื่องสร้าง, #616) |
| อัปโหลด | `PUT /sales/:saleId/photos/:photoId` body เป็นไฟล์ดิบ (แบบ `PUT /products/:id/image`) · ตอบ **`200` เสมอ** · ออนไลน์เท่านั้น ทีละรูป |
| ดู | `GET /sales/:saleId/photos` + `GET /sales/:saleId/photos/:photoId/{t\|p}` ผ่าน API ที่ต้อง login · `Cache-Control: no-store` · **ไม่ใช้ `/img/`** |
| ไฟล์ | volume ใหม่ **`sale-photos`** (api/worker เท่านั้น — Nginx ไม่ mount) · ชื่อไฟล์ content-addressed ด้วย `image-store.ts` ตัวเดิม (refactor ให้รับราก) |
| Postgres | ตาราง `sale_photos` (PK `(tenant_id, id)`, FK tenant อย่างเดียว, RLS `NULLIF`) · `pos_app` ได้ `SELECT, INSERT` เท่านั้น (append-only) |
| Drift | **ไม่เปลี่ยน** — ไม่มีอะไรเก็บในเครื่องหลังแผ่นปิด |
| ใครเห็น | ทุก role ของร้าน — แต่ v1 เข้าถึงบิลได้เฉพาะบนเครื่องที่ขาย (A) |
| ลบ / อายุ | ไม่มีใครลบ · ไม่ลบอัตโนมัติ |
| Backup | `pg_dump` มีแถว · `backup-db.sh` tar volume ใหม่ · ไม่อยู่ใน backup ZIP · รอด replace-import |

---

## 2. UX / UI

### 2.1 การไหล

```
ขายสำเร็จ (saveSale คืนค่าแล้ว — ตะกร้าล้างแล้ว)
   │
   ▼
[ใบเสร็จ dialog] ── "ถ่ายรูปหลักฐานสินค้า" ──► [แผ่นถ่ายรูป]  (ไบต์อยู่ในหน่วยความจำ)
   │  (พิมพ์/ปิด ได้ตามเดิม)                    │ ถ่าย / เลือก 1–5 รูป, ✕ ก่อนบันทึก
   │                        "ข้าม" / ปิด ◄──────┤
   │                                             ▼ "บันทึก N รูป"
   │                              PUT รูปที่ 1 → 2 → … (ทีละรูป, แสดงสถานะบน tile)
   │                                    │ ครบ → snackbar "บันทึกรูปแล้ว" → ปิดแผ่น
   │                                    │ ล้ม → แผ่นไม่ปิด · tile ที่ล้มมีป้าย + ปุ่ม "ลองอีกครั้ง"
   ▼
ลูกค้าคนต่อไป
```

- ปุ่มอยู่ใต้แถบ "ขายสำเร็จ/เงินทอน" ใน `showReceiptDialog` (`receipt_view.dart`) — ไม่มี `await` ใหม่ก่อน dialog ขึ้น
- มีเฉพาะ **API build** (Drift-only build ไม่มี server)
- **ปุ่ม disabled + เหตุผลใต้ปุ่ม** เมื่อ (อ่าน ณ ตอนวาดใบเสร็จ และฟัง `SyncStatusBuilder`):
  - แอป Degraded → `ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะถ่ายรูปหลักฐานได้`
  - `outbox_ops` มีแถว `type = 'sale.create'` ที่ `aggregates` มี `sale:<saleId>` (บิลขายออฟไลน์/ยังไม่ถึง server) →
    `บิลนี้ยังไม่ถึงเซิร์ฟเวอร์ — ถ่ายรูปหลักฐานไม่ได้` — ใช้ aggregates ที่ outbox ใส่อยู่แล้ว (`api_sales_repository.dart:527-528`) ไม่แก้ schema
  - (เพิ่มตอน code-review, PR #698) ตรวจ outbox ไม่สำเร็จ → ปุ่ม**ยังกดได้** พร้อมข้อความ
    `ตรวจสถานะบิลไม่ได้ กดอีกครั้งเพื่อลองใหม่` (`agent ร่าง`) — กดแล้วตรวจซ้ำก่อนเปิดแผ่น · ระหว่างรอผลตรวจครั้งแรกปุ่ม disabled ชั่วครู่โดยไม่มีเหตุผล
- เปิดแผ่นแล้วปิด (ไม่บันทึก) = เหมือนข้าม · v1 **ไม่มีทางเพิ่มรูปทีหลัง** (D)

### 2.2 แผ่นถ่ายรูป

จอ ≥ 600 logical px = dialog กว้าง 520 · จอแคบ = full-screen

```
┌──────────────────────────────────────────────┐
│ ←  รูปหลักฐานสินค้า            RC01-2569-10-0042 │
│──────────────────────────────────────────────│
│ ถ่ายให้เห็นสภาพสินค้าก่อนส่งมอบ                     │
│ ไม่ต้องถ่ายหน้าลูกค้าหรือทะเบียนรถ                  │
│                                              │
│ [ 📷 ถ่ายรูป ]        [ 🖼 เลือกรูปจากเครื่อง ]      │
│                                              │
│ ┌────────┐ ┌────────┐ ┌────────┐             │
│ │  รูป 1  ✕│ │  รูป 2  ✕│ │  รูป 3  ✕│             │
│ │◀      ▶│ │◀      ▶│ │◀       │             │
│ └────────┘ └────────┘ └────────┘             │
│ กดค้างที่รูปแล้วลากเพื่อเรียงลำดับ หรือกดลูกศร          │
│                                   3 / 5 รูป   │
│──────────────────────────────────────────────│
│ [ ข้าม ]                       [ บันทึก 3 รูป ] │
└──────────────────────────────────────────────┘
```

(แก้ 2026-10-12 ตามคำติของ owner: เดิมมีช่อง `เพิ่มรูป` กับปุ่ม `เลือกรูป` ที่ทำอย่างเดียวกัน และ PC ถ่ายรูปไม่ได้ —
ตอนนี้เหลือ **สองทางเท่านั้น** วางคู่กัน เท่ากัน, เรียงซ้อนแนวตั้งเมื่อแผ่นกว้าง < 420 px)

- **ถ่ายรูป** = กล้องในแอป (`sale_photo_camera.dart`, package `camera` 0.12 — ภาพสดในแอป ทุกแพลตฟอร์ม: Android/iOS และ web
  รวม webcam ของ PC ร้าน) · **เลือกรูปจากเครื่อง** = `file_picker` ตัวเดิม · `image_picker` ถูกถอดออก (กล้องในแอปแทนได้ทุกที่)
- **จอกล้อง** (full-screen, พื้น navy เข้ม):

  ```
  ┌──────────────────────────────────────────────┐
  │ ✕  ถ่ายรูป                            2 / 5 รูป │
  │┌────────────────────────────────────────────┐│
  ││                ภาพสดจากกล้อง                 ││
  │└────────────────────────────────────────────┘│
  │       ถ่ายต่อได้จนครบ 5 รูป กด ✕ เมื่อเสร็จ        │
  │ [รูปล่าสุด]          ( ◉ )             [⟲ สลับ] │
  └──────────────────────────────────────────────┘
  ```

  - เลือกกล้องหลังก่อน (ไม่มีก็ใช้ตัวที่มี) · ปุ่มสลับกล้องมีเมื่อมี > 1 ตัว · `enableAudio: false` (ไม่ขอสิทธิ์ไมค์) · ความละเอียด `veryHigh` (1080p)
  - **ถ่ายได้หลายรูปต่อการเปิดหนึ่งครั้ง** · กดชัตเตอร์ = ส่งไบต์เข้าแผ่นทันที (ย่อ + photoId + key ตอนนั้น) · ครบ 5 → ปิดกล้องเอง
  - **ไม่มีขั้น "ใช้รูปนี้ / ถ่ายใหม่"**: tile ในแผ่นมี ✕ และแตะดูเต็มจอได้อยู่แล้ว ขั้นยืนยันจะเพิ่มการกดทุกรูปโดยไม่ได้อะไรเพิ่ม
  - ปล่อยกล้องเสมอ: ตอนปิด, ตอนเปิดไม่สำเร็จ, ตอนสลับกล้อง, ตอนแอป `hidden`/`paused` (เปิดใหม่เมื่อ `resumed`) — ไม่ใช้ `inactive`
    เพราะบน web = หน้าต่างเสียโฟกัส (รวมตอน browser ถามสิทธิ์) จะวนปิด-เปิด
  - เปิดกล้องไม่ได้ = ข้อความไทยในจอกล้อง ไม่ crash: web ไม่ใช่ HTTPS (`cameraBlockedReason()` ใน `camera_access*.dart`, ใช้ร่วมกับตัวสแกน
    บาร์โค้ด — ตรวจ **ก่อน** ขอสิทธิ์) · `ไม่พบกล้อง` · `ไม่ได้รับอนุญาตให้ใช้กล้อง` (+ วิธีอนุญาต) · `กล้องถูกใช้อยู่ในโปรแกรมอื่น` ·
    อื่น ๆ (เช่น Windows desktop ที่ไม่มี plugin) `เปิดกล้องไม่ได้` — ทุกข้อความบอกต่อว่าใช้ `เลือกรูปจากเครื่อง` แทนได้ · มีปุ่ม `ลองอีกครั้ง`
    ยกเว้นกรณีไม่พบกล้อง
  - web: `camera_web` ใช้ `getUserMedia` ของ browser อย่างเดียว ไม่โหลดสคริปต์จาก CDN (ตรวจซอร์ส 0.3.5+6 แล้ว)
- ได้รูปมา → `shrinkProductPhoto` (ย่อ ≤ 1600 px, JPEG q85, ≤ 2.9 MB, หมุนตาม EXIF) → สร้าง `photoId` + `Idempotency-Key` ทันที
  เก็บคู่กับไบต์ในหน่วยความจำของแผ่น · thumbnail วาดจากไบต์ที่ย่อแล้ว (เห็น = ส่ง)
  - ⚠️ `shrinkProductPhoto` ถอดรหัสรูปเต็มขนาดหนึ่งรอบแค่เพื่ออ่านขนาด (`product_photo.dart:44`) และบน web เข้ารหัส JPEG
    บน main thread (`compute` ทำงาน inline บน web) — รูปกล้อง 12 MP บนเครื่องถูก/PC เก่าจะกระตุก · กล้องในแอปถ่ายที่ 1080p
    จึงไม่หนักเท่า · อ่านขนาดจาก header (`ui.ImageDescriptor`) แทนการถอดเต็ม เป็นงานเล็กที่คุ้ม;
    ย้ายการเข้ารหัสบน web ไป worker **ไม่ทำ** ใน v1 — แสดง spinner บน tile ระหว่างย่อแทน (ระหว่างนั้น `บันทึก` กดไม่ได้)
- ✕ = ทิ้งรูปที่ **ยังไม่ส่ง** (ไม่ต้องยืนยัน) · ถ่ายใหม่ = ✕ แล้วถ่ายอีกรูป · รูปที่ส่งสำเร็จแล้ว (✓) ไม่มี ✕ (ลบไม่ได้ — D)
- แตะ tile = ดูเต็มจอ (`InteractiveViewer`)
- **เรียงรูป** (owner 2026-10-12): ก่อนกด `บันทึก` ครั้งแรก กดค้างที่รูปแล้วลากไปวางบนรูปอื่น (นิ้วหรือเมาส์) หรือกด ◀ ▶ บน tile
  (ใช้ได้ดีที่ zoom 3x และเมาส์) · ลำดับบนจอ = ลำดับส่ง = `sortOrder` 0..n-1
  - **`sortOrder` ตายตัวตอนส่งรูปนั้นครั้งแรก** (ไม่ใช่ตอนถ่าย): server ไม่มี route แก้ และ query อยู่นอก fingerprint (§4.3) —
    การลองซ้ำต้องส่ง photoId + key + `sortOrder` เดิมทุกครั้ง
  - กด `บันทึก` แล้ว = **ล็อกลำดับ** (ไม่มีลาก/ลูกศร) · รูปที่เพิ่มหลังบันทึกไปบางส่วน ต่อท้าย ได้ `sortOrder` ถัดจากค่าสูงสุดที่ใช้อยู่
    (ค่าที่ใช้อยู่ไม่มีช่องว่างเสมอ เพราะการส่งหยุดที่รูปแรกที่ล้ม และมีแค่รูป 4xx นั้นที่ลบได้ — ไม่มีทางเกิน 4)
- ครบ 5 รูป: ปุ่มถ่าย/เลือกทั้งสอง disabled + `ครบ 5 รูปแล้ว`
- **บันทึก N รูป**: ส่งรูปที่ยังไม่ ✓ ทีละรูปตามลำดับ tile · ระหว่างส่ง ปุ่มทุกปุ่ม disabled, tile แสดง ⟳
  - ทุกรูป ✓ → snackbar `บันทึกรูปแล้ว` → ปิดแผ่น
    - 🔸 client จริง (2026-10-12, ยอมรับแล้ว): แสดง `บันทึกรูปแล้ว` ในใบเสร็จแทน snackbar เพราะ barrier ของ dialog ใบเสร็จบัง snackbar
  - รูปใดล้ม → หยุดที่รูปนั้น · แผ่นไม่ปิด · tile ⚠ + ข้อความไทยของ error + ปุ่ม `ลองอีกครั้ง` (ส่ง **photoId + key เดิม**) ·
    ปุ่มล่างเปลี่ยนเป็น `ลองอีกครั้ง` / `ปิด` · `ปิด` ทั้งที่ยังมีรูปไม่ ✓ → `showConfirm` (`confirm_dialog.dart:15`)
    `ปิดโดยไม่บันทึกรูปที่เหลือ?` / `รูปที่ยังไม่ได้บันทึก {n} รูปจะหายไป` (danger)
  - 4xx ที่เป็นคำตัดสิน (`SALE_PHOTO_LIMIT`, `PRODUCT_IMAGE_INVALID`, …) → tile ⚠ ไม่มีปุ่มลองใหม่ มีแค่ ✕ · 5xx/429/หลุด/timeout → มีปุ่มลองใหม่
  - ระหว่างส่งแอปกลายเป็น Degraded → รูปที่ส่งไม่ได้กลายเป็น ⚠ ลองใหม่ได้
- แอปถูกปิด/รีสตาร์ตขณะแผ่นเปิด = รูปที่ยังไม่ ✓ หาย (ยอมรับ — B)

### 2.3 ตัวดูรูป — หน้ารับคืน

ใน `_RefundDetail` (`returns_screen.dart`) ใต้หัวบิล เหนือรายการสินค้า — `SalePhotoStrip` แถบ thumbnail แนวนอน:

```
┌ บิล RC01-2569-10-0042 ─────────────────────────┐
│ รูปหลักฐานตอนขาย (3)                              │
│ [▣ 72px][▣][▣]   ถ่ายเมื่อ 12 ต.ค. 2569 14:05        │
│────────────────────────────────────────────────│
│ รายการสินค้า …                                     │
```

- โหลดหลังเลือกบิล (`GET /sales/:id/photos`) · ระหว่างโหลด = skeleton · ไม่มีรูป = `บิลนี้ไม่มีรูปหลักฐาน` (สีจาง)
- Degraded = `ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะดูรูปได้` · ล้มอย่างอื่น = `โหลดรูปไม่สำเร็จ` + `ลองอีกครั้ง`
- แตะ = ตัวดูเต็มจอ: ปัด, ซูม, หัว `รูป {i}/{n} · ถ่ายเมื่อ …` (+ `อัปโหลดเมื่อ …` เมื่อห่างจากเวลาถ่าย > 1 ชม.) · preview โหลดเมื่อเปิดเต็มจอเท่านั้น
- บิลที่เข้าถึงได้ = บิลที่หน้ารับคืนแสดงอยู่แล้ว = บิลใน Drift ของเครื่องนี้ (A)

### 2.4 ตัวดูรูป — รายงาน

`_RecentRow` (`reports_screen.dart:1384`) วันนี้แตะไม่ได้ และแอปไม่มีหน้ารายละเอียดบิล · v1 เพิ่ม **แผ่นบิลขั้นต่ำ**: แตะแถว → แผ่นที่มี
หัวบิล (เลขที่ วันที่ วิธีจ่าย ยอด — จาก `SaleWithItems` ที่แถวถืออยู่แล้ว) + `SalePhotoStrip` ตัวเดียวกับ §2.3 · ไม่มีรายการสินค้า ไม่มีปุ่มอื่น ·
**ครอบเฉพาะแถวที่รายงานแสดงอยู่แล้วบนเครื่องนี้** — ไม่มีหน้าประวัติการขาย/ค้นบิลใหม่

### 2.5 จอแคบ (360–390 px) และ zoom ทั้งจอ (#686)

- layout ใช้ `MediaQuery` (จอ logical หลัง zoom) เสมอ — ไม่ใช้ `MediaQueryData.fromView` · zoom 3x บน 1080 = logical 360 → layout จอแคบ
- แผ่นถ่าย: `< 600` = full-screen · tile `SizedBox` 96 px ใน `Wrap` (360 px ได้ 3 ต่อแถว) · ⚠️ บทเรียน #693: อย่าใช้ `Container(alignment:)`
  ใน `Wrap` (กินเต็มแถว) · ปุ่มถ่าย/เลือกเรียงแนวตั้งเมื่อกว้าง < 420 · จอกล้องต้องวางได้ที่ 640×360 และ 569×320 · ปุ่มล่างเต็มความกว้าง · เป้ากด ≥ 48 px (`tap_target.dart`), ✕ 40 px ไม่ล้นทับ tile ข้าง
- แถบรูปเลื่อนแนวนอน ไม่ wrap
- route smoke test (3x บน 1920×1080, 2x บน 1366×768) ต้องครอบแผ่นถ่ายและแผ่นบิล · ดูด้วยตาบน web build จริงตามกติกา #693

### 2.6 ทิศทางภาพ

ระบบเดิมทั้งหมด (navy/orange, Sarabun, `AppButton`, `StatusChip`) · จุดเดียวที่ตั้งใจให้จำ: thumbnail ในตัวดูมี **แถบเวลาถ่าย** มุมล่างแบบตราประทับ
(navy โปร่ง 70%, ตัวขาว `thaiDateTime`) — แคปหน้าจอส่งต่อยังบอกเวลาได้ · **ไม่เขียนเวลาลงพิกเซลของไฟล์**

### 2.7 ข้อความไทย (ทั้งหมด `agent ร่าง` ยกเว้นที่ระบุ)

| ที่ | ข้อความ |
|---|---|
| ปุ่มบนใบเสร็จ | `ถ่ายรูปหลักฐานสินค้า` (**ถ้อยคำ owner**) |
| เหตุผลปุ่ม disabled | `ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะถ่ายรูปหลักฐานได้` · `บิลนี้ยังไม่ถึงเซิร์ฟเวอร์ — ถ่ายรูปหลักฐานไม่ได้` · (ปุ่มยังกดได้) `ตรวจสถานะบิลไม่ได้ กดอีกครั้งเพื่อลองใหม่` |
| หัวแผ่น / คำแนะนำ | `รูปหลักฐานสินค้า` · `ถ่ายให้เห็นสภาพสินค้าก่อนส่งมอบ` / `ไม่ต้องถ่ายหน้าลูกค้าหรือทะเบียนรถ` |
| ปุ่ม | `ถ่ายรูป` · `เลือกรูปจากเครื่อง` · `ข้าม` · `บันทึก {n} รูป` · `ลองอีกครั้ง` · `ปิด` (`เลือกรูป` / `เพิ่มรูป` เลิกใช้ 2026-10-12) |
| เรียงรูป | `กดค้างที่รูปแล้วลากเพื่อเรียงลำดับ หรือกดลูกศร` · tooltip `เลื่อนไปก่อนหน้า` / `เลื่อนไปถัดไป` |
| จอกล้อง | `ถ่ายรูป` · `{n} / 5 รูป` · `ถ่ายต่อได้จนครบ {n} รูป กด ✕ เมื่อเสร็จ` · `กำลังเปิดกล้อง…` · tooltip `ปิดกล้อง` / `ถ่าย` / `สลับกล้อง` · `ถ่ายไม่สำเร็จ ลองกดอีกครั้ง` |
| จอกล้อง — เปิดไม่ได้ | `เบราว์เซอร์นี้ใช้กล้องไม่ได้ (ต้องเปิดผ่าน HTTPS)` (ข้อความเดิมของตัวสแกน) · `ไม่พบกล้อง` · `ไม่ได้รับอนุญาตให้ใช้กล้อง` + `อนุญาตให้แอปหรือเบราว์เซอร์ใช้กล้อง แล้วกด ลองอีกครั้ง` · `กล้องถูกใช้อยู่ในโปรแกรมอื่น` · `เปิดกล้องไม่ได้` · ต่อท้ายทุกข้อ `หรือปิดหน้านี้ แล้วใช้ปุ่ม เลือกรูปจากเครื่อง` |
| ตัวนับ / เต็ม | `{n} / 5 รูป` · `ครบ 5 รูปแล้ว` |
| ผล | `บันทึกรูปแล้ว` · confirm `ปิดโดยไม่บันทึกรูปที่เหลือ?` / `รูปที่ยังไม่ได้บันทึก {n} รูปจะหายไป` |
| ตัวดู | `รูปหลักฐานตอนขาย ({n})` · `บิลนี้ไม่มีรูปหลักฐาน` · `ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะดูรูปได้` · `โหลดรูปไม่สำเร็จ` · `ถ่ายเมื่อ {เวลา}` · `อัปโหลดเมื่อ {เวลา}` · `รูป {i}/{n}` |
| error | `SALE_PHOTO_LIMIT` → `บิลนี้มีรูปหลักฐานครบ 5 รูปแล้ว` · `SALE_NOT_FOUND` บน route นี้ → `ไม่พบบิลนี้บนเซิร์ฟเวอร์` · `PRODUCT_IMAGE_INVALID` / `PRODUCT_IMAGE_TOO_LARGE` → ข้อความเดิม (ถ้อยคำไม่เจาะจงสินค้าอยู่แล้ว) |

---

## 3. กระบวนการ (Process)

### 3.1 สถานะของรูป (ในแผ่นเท่านั้น)

```
 captured ──✕──► ทิ้ง
    │ บันทึก
    ▼
 uploading ── 200 ──► saved ✓ (แสดงจนแผ่นปิด)
    ├── 5xx / 429 / timeout / transport / 503 IN_FLIGHT ──► retryable ⚠ ──ลองอีกครั้ง (key+photoId เดิม)──► uploading
    └── 4xx (คำตัดสิน) ──► rejected ⚠ (✕ ได้อย่างเดียว)
 แผ่นปิด → ทุกอย่างที่ไม่ใช่ ✓ หาย
```

| ผลจาก server | tile | หมายเหตุ |
|---|---|---|
| `200` (ครั้งแรกหรือ replay) | ✓ | |
| `5xx`, `429`, `503 IDEMPOTENCY_KEY_IN_FLIGHT`, timeout, transport | ⚠ ลองใหม่ได้ | ผลไม่แน่นอน (`isVerdict`) — ลองซ้ำด้วยของเดิมเสมอ ห้ามสร้าง key/photoId ใหม่ |
| `401` | ⚠ ลองใหม่ได้ | `ApiClient` refresh ให้ก่อนอยู่แล้ว; ถ้ายังล้ม = session หมด |
| `400`/`413`/`403`/`404`/`409` | ⚠ ตัดสินแล้ว | ลองซ้ำก็ได้ผลเดิม |

### 3.2 ทำไม v1 ไม่มีคิว (และคิวในอนาคตต้องทำอะไร)

owner ตัด (B) · server ออกแบบให้คิวในอนาคตเป็นงาน client ล้วน: photoId replay ถาวรตาม `source_sha256` (§4.3) ไม่พึ่ง idempotency key ที่หมดอายุ 24 ชม.
ส่วนที่ย้ายไป "ภายหลัง" อยู่ที่ §6

### 3.3 หน่วยความจำของ server

- 🔴 `sharp.concurrency(1)` จำกัด **จำนวน thread ของ libvips ต่อการทำงานหนึ่งครั้ง** ไม่ได้จำกัดจำนวน request พร้อมกัน — สองคำขอที่มาพร้อมกัน
  ถอดรูปพร้อมกันได้ · api container มี 384 MB
- v1 จึงมีสองชั้น:
  1. **เพดานพิกเซลของรูปหลักฐาน ~4 MP** (`SALE_PHOTO_INPUT_PIXEL_LIMIT = 2048 × 2048`) — client ส่ง ≤ 1600 px เสมอ (2.56 MP) · รูปสินค้าคง 24 MP
  2. **semaphore ช่องเดียวต่อ process** ครอบ pipeline (ใช้ร่วมกันทั้งรูปสินค้าและรูปหลักฐาน) — คำขอที่สองรอคิวในหน่วยความจำ ไม่ถอดซ้อน ·
     รออยู่ **ก่อน** claim idempotency และไม่ถือ pool connection
- client ส่งทีละรูปอยู่แล้ว · หลายเครื่องพร้อมกันถูกกันโดย semaphore

### 3.4 ใครลบ / อายุ / PDPA

- **ไม่มีใครลบได้** — ไม่มี endpoint · `pos_app` ไม่มี `UPDATE`/`DELETE` (append-only แบบ `audit_log` #399) · **ไม่ลบอัตโนมัติ** (D)
- PDPA ที่ทำใน v1: คำแนะนำบนแผ่น · ดูผ่าน API ที่ login เท่านั้น + `no-store` (PC หน้าร้านใช้ร่วม) · pipeline ตัด EXIF/GPS ทั้งหมด ·
  ไม่มีไบต์รูปใน `audit_log`/log · ไม่อยู่ใน backup ZIP ของเจ้าของร้าน
- ประกาศแจ้งลูกค้า (ป้าย/ใบเสร็จ) = **ข้อค้างของ owner** (§7)
- พื้นที่ดิสก์ (ประมาณ): ~0.27 MB/รูป · 10 บิล/วัน × 3 รูป ≈ **3 GB/ปี** · ไม่ลบอัตโนมัติ → ตรวจ `df` บน `mob04` ก่อนเปิดใช้

---

## 4. สัญญา API (API contract)

ทุก path อยู่ใต้ `/api/v1` · tenant plane · tenant มาจาก JWT เท่านั้น · error ใช้ envelope `02 §1.2`
(`{ "status": "error", "error": { "code", "message", "details"? } }`) · JSON สำเร็จใช้ `{ "status": "success", "data": … }`

### 4.1 ตาราง endpoint

| Method + Path | สิทธิ์ | Idempotency | สำเร็จ |
|---|---|---|---|
| `PUT /sales/:saleId/photos/:photoId?takenAt=&sortOrder=` | access token + `@RequireDeviceRole('pos')` (role คนใดก็ได้ของร้าน) | `Idempotency-Key` บังคับ · fingerprint = `PUT /api/v1/sales/<saleId>/photos/<photoId>` + hash ของไบต์ body · และ replay ถาวรตาม `photoId` | **`200`** + `SalePhoto` (ทั้งครั้งแรกและ replay — `successCode` ตายตัวต่อ route, `idempotency-routes.spec.ts:109-119`) |
| `GET /sales/:saleId/photos` | access token, ทุก role, ทุก device role | — | `200` + `SalePhoto[]` |
| `GET /sales/:saleId/photos/:photoId/:variant` (`t` \| `p`) | เหมือนบน | — | `200` ไบต์ `image/webp` ล้วน (ไม่ห่อ envelope) |

ไม่มี `DELETE` · ไม่มี list ข้ามบิล · ไม่มีการค้นบิล

### 4.2 รูปข้อมูล `SalePhoto`

```jsonc
{
  "id": "0199d4a2-7c1e-7a3b-9c4d-5e6f7a8b9c0d",      // photoId (UUIDv7 ตัวเล็ก ที่เครื่องสร้าง)
  "saleId": "0199d4a2-6b0d-7f2e-8a1b-2c3d4e5f6a7b",
  "sortOrder": 0,                                     // 0–4
  "width": 1600, "height": 1200,                      // ของไฟล์ preview (p)
  "takenAt": "2026-10-12T07:05:11.000Z",              // นาฬิกาเครื่อง (อ้างอิง)
  "createdAt": "2026-10-12T07:05:14.512Z"             // เวลาที่ server รับครั้งแรก
}
```

ไม่มี `imageKey` / `uploadedBy` / `deviceId` ใน response (เปิดเผยน้อยที่สุด; อยู่ในแถว Postgres)

### 4.3 `PUT /sales/:saleId/photos/:photoId`

**Request**

```http
PUT /api/v1/sales/0199d4a2-6b0d-7f2e-8a1b-2c3d4e5f6a7b/photos/0199d4a2-7c1e-7a3b-9c4d-5e6f7a8b9c0d?takenAt=2026-10-12T07:05:11.000Z&sortOrder=0
Authorization: Bearer <access token ที่มี did ของเครื่อง pos>
Idempotency-Key: salephoto-0199d4a2-7c1e-7a3b-9c4d-5e6f7a8b9c0d
Content-Type: image/jpeg            (หรือ image/png | image/webp)
<ไบต์รูปดิบ ≤ 3 MB>
```

**Response `200`**

```json
{ "status": "success",
  "data": { "id": "0199d4a2-7c1e-7a3b-9c4d-5e6f7a8b9c0d", "saleId": "0199d4a2-6b0d-7f2e-8a1b-2c3d4e5f6a7b",
            "sortOrder": 0, "width": 1600, "height": 1200,
            "takenAt": "2026-10-12T07:05:11.000Z", "createdAt": "2026-10-12T07:05:14.512Z" } }
```

**ลำดับการปฏิเสธ (ตัวแรกที่เจอชนะ)**

| # | ชั้น | เงื่อนไข | HTTP + `code` |
|---|---|---|---|
| 0 | raw parser (`app.setup.ts`) | parse body เฉพาะ access token ที่ verify แล้วและ **`drole === 'pos'`** (เครื่อง `pos` เท่านั้น — เข้มกว่า "มี `did`") และ `Content-Type` ที่รับ · body > 3 MB สำหรับ token นั้น | `413 PRODUCT_IMAGE_TOO_LARGE` (ตอบที่ชั้นนี้) · token อื่น = ไม่ parse, ตกไปชั้นถัดไป |
| 1 | `TenantGuard` | ไม่มี/ผิด token | `401 UNAUTHORIZED` · ร้านถูกระงับ `403 TENANT_SUSPENDED` · อื่น ๆ ของ guard ตามเดิม |
| 2 | `@RequireDeviceRole('pos')` | เครื่องไม่ใช่ `pos` / ไม่มี `did` | `403 DEVICE_ROLE_FORBIDDEN` — 🔴 **ก่อน** ตรวจ body เสมอ (ไม่งั้น `backoffice` ได้ `400` เพราะ parser ไม่ได้ parse ให้) |
| 3 | `ParseUuidPipe` | `saleId`/`photoId` ไม่ใช่ UUID ตัวเล็ก | `400 INVALID_ID` |
| 4 | `idempotencyParamsOf` | ไม่มี/ยาวเกิน `Idempotency-Key` | `400 IDEMPOTENCY_KEY_INVALID` |
| 5 | handler | query: `takenAt` ไม่ใช่ ISO-8601 หรือ > `now() + 10 นาที` · `sortOrder` ไม่ใช่จำนวนเต็ม 0–4 (validate ไม่ clamp) | `400 BAD_REQUEST` |
| 6 | handler | body ไม่ใช่ `Buffer` / ว่าง | `400 PRODUCT_IMAGE_INVALID` |
| 7 | pipeline (ใน semaphore, ก่อน claim, ไม่ถือ connection) | magic bytes ไม่ใช่ jpeg/png/webp · ถอดไม่ได้/ตัดครึ่ง (`failOn:'error'`) · > 4 MP | `400 PRODUCT_IMAGE_INVALID` |
| 8 | เขียนไฟล์ | `writeImageFiles(salePhotosRoot, tenantId, key, …)` ล้ม | `500` |
| 9 | `runIdempotent` claim | key เดิม + body อื่น / path อื่น | `409 IDEMPOTENCY_KEY_REUSED` · key เดิมยังทำอยู่ `503 IDEMPOTENCY_KEY_IN_FLIGHT` · key เดิม + เหมือนเดิม = replay `200` |
| 10 | tx | `SELECT … FROM sales WHERE tenant_id AND id FOR UPDATE` ไม่เจอ | `404 SALE_NOT_FOUND` |
| 11 | tx | มีแถว `photoId` อยู่แล้ว: `sale_id` ตรง **และ** `source_sha256` (sha256 ของ body) ตรง → **`200` + แถวเดิม** (replay ถาวร) · ไม่ตรง → | `409 CLIENT_ID_REUSED` |
| 12 | tx | รูปของบิลนี้ ≥ 5 | `409 SALE_PHOTO_LIMIT` |
| 13 | tx | `INSERT` (`uploaded_by` = `userId`, `device_id` = `did`, `created_at` = `now()`) | `200` + `SalePhoto` |

- หลัง handler จบ (นอก tx, ยกเว้นกรณี 503 in-flight): ถ้าไม่มีแถว `sale_photos` ใดของร้านอ้าง `image_key` นั้น → ลบไฟล์ — คือ
  `removeImageIfUnreferenced` เวอร์ชัน `sale_photos` (ตรวจด้วย `idx_sale_photos_key`; ไฟล์ที่คำขอนี้สร้างลบทันที, ที่มีอยู่ก่อนเว้น `ORPHAN_GRACE_MS`) ·
  best effort + log
- `source_sha256` ไม่ใช่ `image_key`: key มาจากผลของ sharp — อัป libvips แล้วไบต์ผลลัพธ์อาจต่าง → replay ของรูปเดิมจะกลายเป็น `409` ปลอม
- query ไม่อยู่ใน fingerprint (`endpoint = method + baseUrl + path`, `idempotency.runner.ts:41-42`) — replay ตอบแถวเดิมเสมอ ค่า query ใหม่ถูกเมิน
- บิล void/คืนครบแล้ว: รับรูป
- `audit_log`: ไม่เขียน (แถว `sale_photos` คือบันทึกเอง) · log: ห้ามพิมพ์ body — พิมพ์ได้แค่ `saleId`/`photoId`

**ตัวอย่าง error**

```json
{ "status": "error", "error": { "code": "SALE_PHOTO_LIMIT", "message": "บิลนี้มีรูปหลักฐานครบ 5 รูปแล้ว" } }
```

### 4.4 `GET /sales/:saleId/photos`

**Response `200`** (ไม่มี `meta` — สูงสุด 5 แถว) เรียง `sort_order, created_at, id`

```json
{ "status": "success",
  "data": [ { "id": "0199d4a2-7c1e-7a3b-9c4d-5e6f7a8b9c0d", "saleId": "0199d4a2-6b0d-7f2e-8a1b-2c3d4e5f6a7b",
              "sortOrder": 0, "width": 1600, "height": 1200,
              "takenAt": "2026-10-12T07:05:11.000Z", "createdAt": "2026-10-12T07:05:14.512Z" } ] }
```

| เงื่อนไข | ผล |
|---|---|
| `saleId` ไม่ใช่ UUID | `400 INVALID_ID` |
| ไม่มีรูป (รวมบิลที่ไม่มีอยู่/ของร้านอื่น) | `200` + `[]` — 🔸 ไม่ตรวจว่าบิลมีอยู่: ไม่มี FK และรูปต้องอ่านได้แม้บิลถูก replace-import ออกไปชั่วคราว (C); RLS กันร้านอื่นอยู่แล้ว |
| ไม่มี token | `401 UNAUTHORIZED` |
| `Cache-Control` | `no-store` |

### 4.5 `GET /sales/:saleId/photos/:photoId/:variant`

**Response `200`** — ไบต์ล้วน

```http
HTTP/1.1 200 OK
Content-Type: image/webp
Content-Length: 251334
Cache-Control: no-store
X-Content-Type-Options: nosniff
```

| เงื่อนไข | ผล |
|---|---|
| `saleId`/`photoId` ไม่ใช่ UUID | `400 INVALID_ID` |
| `variant` ไม่ใช่ `t`/`p` | `404 NOT_FOUND` |
| ไม่มีแถว `WHERE tenant_id AND sale_id = :saleId AND id = :photoId` หรือไฟล์หาย | `404 NOT_FOUND` (envelope JSON) |

- การทำงาน: อ่านแถวใน `runTx` สั้น ๆ (RLS) → **tx จบก่อน** → path ของไฟล์สร้างจาก tenant ใน token + **`image_key` ที่เก็บในแถว**
  ผ่าน `imageFilePath` (validate ทั้งสองส่วน) — ไม่มีค่าจาก request ไปถึง path · ห้ามถือ pool connection ระหว่าง stream
- stream ตามแบบ `backup.controller.ts:107-146`: `@Res()` (library mode — envelope ไม่ห่อ), `open` แล้ว `fh.stat()`, ตั้ง header,
  `stream.on('error', () => res.destroy())`, `res.on('close', () => stream.destroy())`, `pipe` — **ไม่ใช่** แบบ `/metrics`
- `no-store` (ไม่ใช่ `private, immutable`): PC หน้าร้านใช้ร่วมกัน และ logout ต้องไม่เหลือรูปใน cache ของ browser · client เก็บ thumbnail ในหน่วยความจำ
  ของหน้าจอเท่านั้น
- client: `ApiClient.getBytes` → `Image.memory` (ได้ token + CA ของร้านบน Android ทุกแพลตฟอร์ม; ไม่พึ่ง header ของ `Image.network` บน web)

### 4.6 รหัส error ทั้งหมดของฟีเจอร์นี้

| code | HTTP | ใหม่? | ข้อความไทย |
|---|---|---|---|
| `SALE_PHOTO_LIMIT` | 409 | 🆕 | `บิลนี้มีรูปหลักฐานครบ 5 รูปแล้ว` (`agent ร่าง`) |
| `PRODUCT_IMAGE_INVALID` | 400 | ใช้ซ้ำ | เดิม `ไฟล์รูปไม่ถูกต้อง กรุณาใช้รูป JPG, PNG หรือ WebP` |
| `PRODUCT_IMAGE_TOO_LARGE` | 413 | ใช้ซ้ำ | เดิม `รูปใหญ่เกิน 3 MB` |
| `SALE_NOT_FOUND` | 404 | ใช้ซ้ำ | client แสดง `ไม่พบบิลนี้บนเซิร์ฟเวอร์` บน route นี้ (`agent ร่าง`) |
| `CLIENT_ID_REUSED` | 409 | ใช้ซ้ำ | ข้อความเดิม |
| `IDEMPOTENCY_KEY_REUSED` / `IDEMPOTENCY_KEY_IN_FLIGHT` / `IDEMPOTENCY_KEY_INVALID` | 409 / 503 / 400 | ใช้ซ้ำ | ข้อความเดิม |
| `DEVICE_ROLE_FORBIDDEN` / `INVALID_ID` / `BAD_REQUEST` / `NOT_FOUND` / `UNAUTHORIZED` | 403 / 400 / 400 / 404 / 401 | ใช้ซ้ำ | ข้อความเดิม |

---

## 5. ข้อมูล (Data)

### 5.1 Postgres — migration ใหม่ `17886528052xx-SalePhotos.ts` (เลขต่อจากตัวล่าสุดใน `MIGRATIONS`)

```sql
CREATE TABLE sale_photos (
  tenant_id      UUID NOT NULL REFERENCES tenants(id),
  id             UUID NOT NULL,            -- photoId (UUIDv7 ที่เครื่องสร้าง)
  sale_id        UUID NOT NULL,            -- 🔸 ไม่มี FK ไป sales (owner C: รอด replace-import)
  image_key      TEXT NOT NULL,            -- 32 hex ของ sha256(preview) = ชื่อไฟล์ใน volume sale-photos
  source_sha256  TEXT NOT NULL,            -- sha256 ของ body ที่ client ส่ง — ตัดสิน replay ของ photoId
  width          INT  NOT NULL,
  height         INT  NOT NULL,
  sort_order     SMALLINT NOT NULL,
  taken_at       TIMESTAMPTZ NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  uploaded_by    UUID NOT NULL,
  device_id      UUID NOT NULL,
  CONSTRAINT pk_sale_photos PRIMARY KEY (tenant_id, id),
  CONSTRAINT ck_sale_photos_image_key CHECK (image_key ~ '^[0-9a-f]{32}$'),
  CONSTRAINT ck_sale_photos_source CHECK (source_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT ck_sale_photos_sort CHECK (sort_order BETWEEN 0 AND 4)
);
CREATE INDEX idx_sale_photos_sale ON sale_photos (tenant_id, sale_id, sort_order, created_at);
CREATE INDEX idx_sale_photos_key  ON sale_photos (tenant_id, image_key);
ALTER TABLE sale_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE sale_photos FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON sale_photos
  USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
GRANT SELECT, INSERT ON sale_photos TO pos_app;   -- append-only
```

- ไม่มี FK ไป `sales` (C) — ความถูกต้องของ `sale_id` ถูกตรวจตอน insert ใต้ `SELECT … FROM sales … FOR UPDATE` (§4.3 ข้อ 10) ·
  `uploaded_by`/`device_id` ไม่มี FK ด้วยเหตุผลเดียวกัน (replace-import ไม่ลบ users/devices อยู่แล้ว แต่ไม่ต้องผูกเพิ่ม)
- RLS สร้างใน migration นี้ (ไม่แก้ `TENANT_SCOPED_TABLES` ที่ ship แล้ว — แบบ `PaymentAccounts`)
- 5 รูป/บิล บังคับที่ service ใต้ล็อกแถว `sales` (lock order: `sales` ก่อน) ไม่ใช่ constraint
- Postgres = **31 ตาราง** — แก้ตัวเลขใน `CLAUDE.md`/`01_DATABASE.md` ตอน merge

### 5.2 Drift — ไม่เปลี่ยน (v15 คงเดิม)

ไม่มีอะไรเก็บในเครื่องหลังแผ่นปิด · รายการรูปไม่แคชลง Drift · ไม่ต้อง `build_runner`

### 5.3 ไฟล์ — volume `sale-photos`

- `server/docker-compose.yml`: volume `sale-photos` → api-1..3 + worker ที่ `/app/sale-photos` (`SALE_PHOTOS_DIR`) · **Nginx ไม่ mount** ·
  ประกาศใน `docker-compose.yml` (ไม่ใช่ `vm.override.yml`) ให้ถึง `mob04` · `server/Dockerfile` สร้าง `/app/sale-photos` เป็นของ `node`
- `image-store.ts`: refactor ให้รับราก (`imageStore(rootDir)` → `imageFilePath / writeImageFiles / removeImageFiles / removeImageFilesIfStale /
  listImageKeys`) · รูปสินค้าเรียกด้วย `productImagesDir()` พฤติกรรมเดิม · 🔴 import (`tenant-import.service.ts:1444,1463`) ต้องผูกกับราก
  `product-images` อย่างชัดเจน — **sweep ห้ามแตะ `sale-photos`** (มีเทส)
- `image-pipeline.ts`: วันนี้มีแค่ `processProductImage` ที่ `PREVIEW_SIZE` 1024 ตายตัว · refactor เป็นฟังก์ชันที่รับ `{ previewSize, inputPixelLimit }`
  แล้วให้ `processProductImage` = ค่าเดิม (1024 / 24 MP) และ `processSalePhoto` = 1600 / 2048² · semaphore ช่องเดียวครอบทั้งคู่ (§3.3) ·
  ไม่มี native binary ใหม่ (libvips 8.18.7 ที่ build เอง — ไม่แตะข้อจำกัด `qemu64`)
- ทำไมไม่ใช้ `product-images` + โฟลเดอร์ย่อย: regex `/img/` เสิร์ฟ `<uuid>/<32hex>_[tp].webp` — วางผิดชั้นเมื่อไรรูปหลักฐานเป็นสาธารณะทันที

### 5.4 Backup / restore / import

| ส่วน | ผล |
|---|---|
| `pg_dump` | มีแถว `sale_photos` อัตโนมัติ |
| ไฟล์ | `backup-db.sh` เพิ่ม `pos_sale_photos_<ts>.tar.gz` + `.sha256` (`.partial` + `mv`, prune/offsite เดียวกัน) ผ่าน `docker compose exec -T worker tar -cf - -C /app/sale-photos .` (Nginx ไม่ mount — ตรวจว่า image มี `tar`) หรือ `SALE_PHOTOS_DIR` นอก compose · ไม่มี worker/volume = `::warning::` exit 0 · worker มีแต่ `exec` ล้ม = `::error::SALE PHOTOS ARCHIVE FAILED` + exit ≠ 0 (แก้ตอน code-review) · 🔴 CD ไม่อัปเดต `/opt/pos/scripts` → ติดตั้งมือบน `mob04` |
| `restore-db.sh` | ไม่กู้ไฟล์รูป (เหมือนรูปสินค้า) — ข้อจำกัดที่บันทึกไว้ |
| backup ZIP ของเจ้าของร้าน | ไม่มีรูปหลักฐาน/แถว `sale_photos` (D) |
| replace-import (owner/platform) | `sale_photos` **ไม่อยู่ใน `REPLACED_TABLES`** → แถวและไฟล์อยู่ต่อ · บิลที่ไฟล์นำเข้ามี id เดิม = รูปกลับมาผูก · บิลที่ไม่กลับมา = รูปค้างแบบไม่มีบิล (อ่านได้ถ้ารู้ saleId, ไม่มีหน้าไหนชี้ถึง) · ไม่ต้องใช้สิทธิ์ลบ |
| platform import ร้านว่าง | ไม่มีบิล ไม่มีรูป |

---

## 6. ขอบเขต: v1 vs ภายหลัง

### v1 (ทำ)

server: migration + `PUT` + `GET list` + `GET bytes` + volume + refactor store/pipeline + semaphore · client: ปุ่มบนใบเสร็จ + แผ่นถ่าย/เลือก/ส่ง/ลองใหม่ +
`SalePhotoStrip` + ตัวดูเต็มจอ ในหน้ารับคืน + แผ่นบิลขั้นต่ำในรายงาน · ops: `backup-db.sh` + docs

### ภายหลัง (ตัดออกโดยตั้งใจ)

- **คิวออฟไลน์** (ตัดโดย owner B): `PendingSalePhotoStore` (ไฟล์ใน `getApplicationSupportDirectory()` บน Android/iOS, IndexedDB แยก `srisurart_sale_photos`
  บน web — แบบ `token_kv_store`), sidecar ต่อรูป (photoId, saleId, tenantId, key, takenAt, state), ตัวส่งเบื้องหลังพร้อมด่าน outbox + backoff,
  ป้าย `รูปรออัปโหลด N` + แผ่นรายการค้าง, นับรูปค้างใน `TenantCacheGuard` (`TENANT_SWITCH_UNSENT_WORK`/`ENROL_UNSENT_WORK`), เพดาน 200 รูป/เครื่อง ·
  ต้องไม่อยู่ใน Drift และไม่อยู่ใน `outbox_ops` (ไม่บล็อกปิดกะ) · server **ไม่ต้องแก้** — replay ตาม photoId รองรับแล้ว
- **ดูรูปจากเครื่องอื่น**: ต้องมีการค้นบิลจาก server (`GET /sales?search=` + รายละเอียดบิล) ในหน้ารับคืน/รายงาน (A)
- ลบรูป (owner + เหตุผล + audit `sale_photo.deleted` + soft delete) · ลบอัตโนมัติตามอายุ · เพิ่มรูปทีหลัง ·
  รูปใน backup ZIP / `restore-db.sh` · `photoCount` ในรายการบิล · caption/วาดชี้รอย/ลายน้ำ · ผูกรูปกับบรรทัดสินค้า · Drift-only build ·
  รูปในใบเสร็จพิมพ์/PDF · เข้ารหัส JPEG บน web ใน worker

---

## 7. คำถาม/ข้อค้างของ owner

| # | เรื่อง | สถานะ |
|---|---|---|
| O1 | ประกาศแจ้งลูกค้าเรื่องการถ่ายรูป (PDPA) — ป้ายหน้าร้าน / ข้อความบนใบเสร็จ / ถ้อยคำ | **เลื่อนไป** (owner 2026-10-12) — ยังเปิด |
| O2 | ดิสก์ `mob04` รับ ~3 GB/ปี ได้ไหม (ไม่มีลบอัตโนมัติ) | ตรวจ `df` ใน X1 แล้วรายงาน owner |
| O3 | รับรองข้อความไทย §2.7 / §4.6 | คง `agent ร่าง` ตามที่ owner สั่ง |

---

## 8. แผนลงมือ (ticket)

ทุกใบจบด้วยข้อตกลง `09 §10`: `/scrutinize` → เขียนตาม `karpathy-guidelines` → เทสกับ fake ของฝั่งตัวเอง → `/code-review` · PR เข้า `develop` ·
ห้าม auto-merge ขณะ agent ยัง push · **สัญญาร่วมของสองชุดคือ §4 ทั้งหมด** — ห้ามแก้ shape/code ฝ่ายเดียว ถ้าต้องแก้ ให้แก้ §4 ในไฟล์นี้ก่อนใน PR แยก

```
SERVER:  SV1 ──► SV2 ──► SV4 ─┐
              └─► SV3 ────────┤
CLIENT:  CL1 ──► CL2 ─────────┼──► X1 (ลองจริงบน mob04 หลัง release)
              └─► CL3 ────────┘
(สองชุดเริ่มพร้อมกันได้ทันที — client ทดสอบกับ fake ที่สร้างจาก §4)
```

### ชุด SERVER (agent ฝั่ง server)

**SV1 — refactor store/pipeline + migration + volume** *(ไม่มี dependency)*
- `image-store.ts` รับราก · `image-pipeline.ts` รับ `{ previewSize, inputPixelLimit }` + `processSalePhoto` + semaphore ช่องเดียวต่อ process ·
  migration `sale_photos` (§5.1) · volume `sale-photos` (compose + Dockerfile) · import ผูกราก `product-images` อย่างชัดเจน
- AC: เทส `image-store`/`image-pipeline`/`product-images.e2e` เดิมผ่านโดยไม่แก้ assertion · `schema.e2e-spec`: RLS (tenant ว่าง = 0 แถว ไม่ใช่ 22P02),
  `pos_app` `UPDATE`/`DELETE` ถูกปฏิเสธ, ไม่มี FK ไป `sales` · semaphore: สองคำขอพร้อมกันถอดทีละอัน (unit ด้วย pipeline ปลอม) ·
  owner replace-import บนร้านที่มีแถว `sale_photos` + ไฟล์ใน `sale-photos` → แถวและไฟล์ยังอยู่ครบ และ import ซ้ำ id บิลเดิม → `GET` list ได้รูปเดิม
- Test: unit + `schema.e2e-spec.ts` + `owner-import` e2e เพิ่มเคส · ค่า key ทดสอบ entropy ต่ำ (gitleaks)

**SV2 — `PUT /sales/:saleId/photos/:photoId`** *(รอ SV1)*
- raw parser ตาม §4.3 ข้อ 0 · controller/service ตามลำดับ §4.3 · cleanup ไฟล์แบบ `removeImageIfUnreferenced` บน `sale_photos` ·
  route ใน `idempotency-routes.spec.ts` (`successCode` 200) · `SALE_PHOTO_LIMIT` ใน `02 §8.1`
- AC — ทุกแถวของตาราง §4.3 มีเทส อย่างน้อย: `200` ครั้งแรก + ไฟล์อยู่ใน `sale-photos` ไม่อยู่ใน `product-images` · replay key เดิม `200` ·
  **key ใหม่ + photoId เดิม + ไบต์เดิม = `200` แถวเดิม** · photoId เดิม + ไบต์อื่น = `409 CLIENT_ID_REUSED` · รูปที่ 6 = `409 SALE_PHOTO_LIMIT`
  รวมสองคำขอพร้อมกันตอนมี 4 รูป (ได้ 5 ไม่ใช่ 6) · บิลไม่มี/ร้านอื่น = `404 SALE_NOT_FOUND` + ไฟล์ที่เพิ่งเขียนถูกลบ · token `backoffice` ส่ง body รูป =
  `403 DEVICE_ROLE_FORBIDDEN` (ไม่ใช่ 400) · > 3 MB = `413` · PNG ตัดครึ่ง/SVG/> 4 MP = `400 PRODUCT_IMAGE_INVALID` · `takenAt` อนาคต > 10 นาที /
  `sortOrder` 5 = `400 BAD_REQUEST` · ไฟล์ผลลัพธ์ไม่มี EXIF/GPS
- Test: `server/test/sale-photos.e2e-spec.ts` (ล็อกอิน > 10 ครั้งต้องส่ง `X-Forwarded-For` เอง #449)

**SV3 — `GET` list + bytes** *(รอ SV1; ขนานกับ SV2 — seed แถวตรง ๆ ในเทส)*
- AC: list เรียงถูก, ร้านอื่น/ไม่มี = `[]`, `no-store` · bytes: `image/webp`, `no-store`, `nosniff`, ไม่ห่อ envelope · `photoId` ถูกแต่ `saleId` ผิด = `404` ·
  `variant` อื่น = `404` · ไฟล์หาย = `404` · stream ไม่ถือ pool connection (เทส `DB_POOL_SIZE` = 1: โหลดรูปพร้อม `POST /sales` ไม่ deadlock) ·
  ปิด connection กลางทาง = file handle ถูกปิด · `/img/<tenant>/<key>_t.webp` ของรูปหลักฐาน = `404` (เพิ่มเคสใน `nginx-img.test.sh`)

**SV4 — ops + docs** *(รอ SV1; ขนานกับ SV2/SV3)*
- `backup-db.sh` + `backup-db.test.sh` (มี/ไม่มี volume, `.partial` ไม่ค้าง) · `02` (แถว route ใน §3.1/§3.7/§4.2, `SALE_PHOTO_LIMIT` §8.1) ·
  `07 §9` (volume ใหม่, Nginx ไม่ mount, ติดตั้งสคริปต์มือ) · `01_DATABASE.md` (31 ตาราง) · grep ทุก section ที่อ้างก่อนเขียน

### ชุด CLIENT (agent ฝั่ง client)

**CL1 — repository + fake จาก §4** *(ไม่มี dependency)*
- `SalePhotosRepository` (interface) + `ApiSalePhotosRepository`: `upload(saleId, photoId, key, takenAt, sortOrder, jpeg)` → `ApiClient.sendBytes`
  (`PUT`, `Content-Type: image/jpeg`, header `Idempotency-Key` ที่ส่งเข้ามา — **repo ไม่สร้าง key เอง**) · `list(saleId)` · `bytes(saleId, photoId, variant)`
  → `ApiClient.getBytes` · `FakeSalePhotosRepository` ที่ตอบตาม §4.3/§4.4 (รวมเคส error ทุกตัวใน §4.6) · `hasPendingSaleCreate(saleId)` อ่าน `outbox_ops`
  (`type = 'sale.create'` และ aggregates มี `sale:<id>`) · ลงทะเบียนใน `repository_providers.dart` (API build เท่านั้น)
- AC: error ทุกตัวแปลงเป็น `PosException` ไทยใน repo (`posExceptionFromApi`) · `api_exception_never_escapes_test.dart` และ `api_repository_contract_test.dart`
  ครอบ repo ใหม่ · 5xx/429/transport ถูกจัดเป็น "ลองใหม่ได้" ส่วน 4xx เป็น "ตัดสินแล้ว" (ตาม `isVerdict`) · ไม่เขียน Drift
- Test: unit กับ `ApiClient` ปลอม

**CL2 — แผ่นถ่ายรูป** *(รอ CL1)*
- ปุ่มบนใบเสร็จ + เงื่อนไข disabled (§2.1) · แผ่นตาม §2.2/§3.1 · เพิ่ม `image_picker` — 🔴 ตรวจ build Android กับ `android.builtInKotlin=false`
  (เคยทำ `file_picker` พัง) + iOS `NSCameraUsageDescription` · `shrinkProductPhoto` ใช้ซ้ำ (แก้การอ่านขนาดด้วย `ui.ImageDescriptor` ถ้าเล็ก)
- AC: ปุ่มไม่มีบน Drift build · dialog ใบเสร็จขึ้นโดยไม่มี await ใหม่ · Degraded / บิลใน outbox = disabled + เหตุผล · ส่งทีละรูปตามลำดับ ·
  ล้ม 5xx = แผ่นไม่ปิด, `ลองอีกครั้ง` ส่ง photoId + key เดิม (ตรวจจาก fake) · 4xx = ไม่มีปุ่มลองใหม่ · ครบ 5 = เพิ่มไม่ได้ · ✓ ไม่มี ✕ ·
  ปิดทั้งที่ยังมีรูปไม่ ✓ = `showConfirm` · route smoke test 3x/2x · ดูด้วยตาบน web build ที่ 390 px
- Test: widget test กับ fake + smoke test + ลองกล้องบน APK จริงหนึ่งเครื่อง

**CL3 — ตัวดู** *(รอ CL1; ขนานกับ CL2)*
- `SalePhotoStrip` + ตัวดูเต็มจอ ใน `_RefundDetail` · แผ่นบิลขั้นต่ำจาก `_RecentRow` (หัวบิล + strip) — ครอบเฉพาะแถวที่แสดงบนเครื่องนี้
- AC: สถานะโหลด/ว่าง/ออฟไลน์/ล้ม ตาม §2.3 · preview โหลดเมื่อเปิดเต็มจอเท่านั้น · thumbnail ในหน่วยความจำของหน้าจอเท่านั้น (ไม่เขียนดิสก์) ·
  `presentation_no_api_exception_test.dart` ผ่าน · smoke test 3x/2x ครอบแผ่นบิล
- Test: widget test กับ fake

### X1 — ลองจริงบน `mob04` (หลัง release ที่มีทุกใบ)

ติดตั้ง `backup-db.sh` มือ (sha256 = `origin/main`) · ขายจริง 1 บิลออนไลน์ + ถ่าย 2 รูป → เห็นในหน้ารับคืนและรายงานของเครื่องเดิม · บิลออฟไลน์ =
ปุ่ม disabled จนบิลขึ้น · รัน `backup-db.sh` ในสภาพ cron แล้วตรวจ tar · `/img/` กับ key รูปหลักฐาน = 404 · `df -h` ของ volume (O2) · ตรวจ `.current_sha`
