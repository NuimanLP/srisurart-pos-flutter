# Handoff — bug batch #472–#490 merged, docs synced (2026-09-28)

**วันที่:** 2026-09-28 · **ผู้บันทึก:** agent (Claude, docs-sync pass) · **สถานะ:** ทุก PR ในรอบนี้ merge แล้ว
**ต่อจาก:** [`session-2026-09-28-overnight-bug-sweep.md`](session-2026-09-28-overnight-bug-sweep.md) (เปิด #472–#480)

## 1. PR ↔ issue ↔ ที่มา

| PR | ปิด issue | อะไร |
|---|---|---|
| #482 | #479 | ใบเสนอราคา A4: ตัด `letterSpacing` ออกจากข้อความไทย (`latinOnlySpacing`) — วรรณยุกต์/สระบนล่างไม่หลุดจากพยัญชนะอีกต่อไป |
| #483 | #473 | `SyncService.discard` ของ `sale.create`/`return.create` คืนสต็อก/ลูกค้า/ช่างกลับให้อัตโนมัติ (ไม่ใช่แค่ลบแถว) · ปฏิเสธด้วย `DISCARD_HAS_LOCAL_DEPENDENTS` เมื่อบิลมีใบลดหนี้/ถูกยกเลิกในเครื่องแล้ว |
| #484 | #472, #475 | เลข RC ออฟไลน์เลิกเดา `deviceNo ?? 1` และเลิก fallback `docNo('RC')` — ใช้ `DocNumberService.issueOffline` กฎเดียวกับ CN (#469) · เครื่องใหม่ที่ยังไม่มีแถว counter ได้แถว `last_no = 0` จาก seeder |
| #485 | #477, #478, #480 | `_RecentRow` หน้ารายงานล้นที่ 390 px (ห่อด้วย `Wrap`/`Flexible`) · ไฮไลต์คำค้นหน้าค้นรุ่นรถตามธีมสว่าง/มืด · ป้ายชั้นวางอ่าน VAT จาก `settings.taxRate` แทนเลข `7%` ตายตัว |
| #486 | #474 | settings ถูก pull ซ้ำจาก `triggerEntityPull` (`SyncService.onPull`) ทุกครั้งที่เน็ตกลับ ไม่ต้องรอ login/reload รอบถัดไป |
| #487 | – (test-only) | ซ่อม CI แดงบน `main` ที่เกิดจาก #483 × #484 ชนกัน (ดู §2) |
| #491 | #489 | เลข RC/CN ที่ server ออกตอน **ขายออนไลน์ตรง ๆ** ถูก commit เข้า `DocCounters` ในเครื่องแล้ว (`DocNumberService.commitServerIssued`, เรียกจาก `ApiSalesRepository._patchFromResponse` / `ApiReturnsRepository` เทียบเท่า) — แก้เลขซ้ำหลังขายออนไลน์แล้วขายออฟไลน์ต่อ · 🔴 **คำอธิบายใน PR #491 เองอ้างว่าครอบ `/sync/push` replay ด้วย — ไม่จริงเมื่อตรวจโค้ดที่ merge จริง** (ดู §4) |
| #492 | #490 | ขึ้นเดือนใหม่ตอนออฟไลน์เริ่ม `0001` ได้จริงแล้ว (`ensureSeedMarker` รับ marker จาก period ใดก็ได้ ไม่ใช่แค่เดือนปัจจุบัน) — สอดคล้อง `08_PHASE2_SPEC.md §9` E8 ที่เขียนสเปกไว้ถูกอยู่แล้ว แต่โค้ดไม่ทำตามจนถึงตอนนี้ |

**ยังเปิด:** #476 (ทางตันจัดการเครื่อง — owner call, ไม่ใช่ของรอบนี้) · #488 (ตามข้างล่าง)

## 2. บทเรียน: #483 × #484 ชนกันแบบ semantic (ไม่ใช่บั๊กโค้ด)

แต่ละ PR เขียว**บน base ของตัวเอง**: #483 เพิ่ม `sync_discard_reversal_test.dart` ที่ริงบิลออฟไลน์ผ่าน `_saveOffline` โดยไม่ seed device (เพราะตอนเขียน `docNo('RC')` fallback ยังอยู่ — ไม่มี guard) · #484 ลบ fallback นั้นออกและบังคับ `OFFLINE_SEED_REQUIRED` ถ้าไม่มี seed marker ของเครื่องนั้น ทั้งสองรวมเข้า `main` แล้วชนกัน: 6 เทสต์ของ #483 พังด้วยข้อความ
`ต้องเชื่อมต่ออินเทอร์เน็ตหนึ่งครั้งเพื่อเตรียมเลขเอกสารก่อนใช้งานออฟไลน์`
เพราะกลุ่มเทสต์ `discard sale.create` ไม่เคย seed device ให้ตัวเอง (กลุ่ม `return.create` ข้าง ๆ มัน seed ไว้แล้ว ไม่พัง) — **PR #487** เป็น fix ทดสอบล้วน ๆ ไม่มีบั๊กโค้ดจริง

**บทเรียน:** สอง PR ที่แก้คนละไฟล์ แก้คนละบั๊ก และเขียวทั้งคู่บน base ของตัวเอง **ไม่ได้แปลว่าจะเขียวด้วยกันบน `main`** เมื่อ PR หนึ่งเปลี่ยน precondition ที่อีก PR สมมติไว้เงียบ ๆ (ที่นี่คือ "ทดสอบออฟไลน์ไม่ต้อง seed device") — worth ไล่ตรวจ CI ของ `main` ทันทีหลัง merge คู่ที่แก้พื้นที่ใกล้กัน (`sync_service.dart` / `api_sales_repository.dart` ทั้งคู่แตะ path ขายออฟไลน์) แม้ diff จะไม่ทับกันเลยก็ตาม

## 3. บทเรียน: อย่าเทียบเวลาเครื่องกับเวลา server (#486)

`ApiSettingsRepository.pullFromServer()` ไม่เช็คว่า settings "เปลี่ยนจริงไหม" ก่อน patch ทับ Drift — เขียนทับทุกครั้งที่เรียก ไม่มีเงื่อนไข ไม่โยน exception (ยกเว้นเมื่อ parse ไม่ได้ → คืน `false` เฉย ๆ) ทั้ง `pullSettingsOnSignIn` และ `triggerEntityPull` (#474) เรียกมันแบบเดียวกันทุกจุด

**เหตุผลที่การออกแบบเลือกทางนี้ ไม่ใช่ทางลัด:** ถ้าจะทำ "pull เฉพาะตอนเปลี่ยนจริง" วิธีที่ดูง่ายที่สุดคือเก็บ `updatedAt` ที่ server ส่งมาไว้ในเครื่อง แล้วครั้งถัดไปเทียบว่า "เวลาที่ server บอกใหม่กว่าที่เคยเห็นไหม" — **ห้ามทำแบบนี้** เพราะมันเทียบนาฬิกาเครื่อง (device clock ตอนบันทึกไว้ครั้งก่อน) กับนาฬิกา server (ผ่าน `updatedAt`) สองนาฬิกาคนละเรือน คนละที่ตั้ง ไม่มีการซิงค์เวลากันเลย (ธีมเดียวกับที่ `08_PHASE2_SPEC.md §10` ต้อง clamp+ติดธงวันที่บิลเพราะ "นาฬิกาโกหก") — นาฬิกาเครื่องเดินช้า/เร็ว หรือ timezone ผิด จะทำให้ pull ที่ควรเกิดถูกข้ามไปเงียบ ๆ ได้ ถ้าวันหนึ่งต้องทำ "pull เฉพาะตอนเปลี่ยนจริง" จริง ๆ (ลด round-trip) ให้ใช้ **generation/version counter จาก server** (เลขที่เพิ่มทีละ 1 ทุกครั้งที่ settings ถูกแก้ ไม่ใช่ timestamp) เทียบกับเลขที่เก็บไว้ในเครื่อง — ไม่ใช่เทียบเวลา

## 4. ยังเปิดอยู่

- 🔴 **พบระหว่างตรวจเอกสารรอบนี้ (2026-09-28) — PR #491's own body oversells its fix.** ข้อความใน PR อ้างว่า
  "`SyncService._patchDocNo` now also calls `commitServerIssued` inside the push transaction"
  (ครอบ `/sync/push` replay ด้วย) — **ตรวจโค้ดจริงที่ merge แล้วไม่จริง**: `sync_service.dart`
  ไม่มีการอ้างถึง `DocNumberService`/`commitServerIssued` เลยสักจุด, `_patchDocNo` และ
  `patchSaleFromPushReply` (ตัว patch คำตอบ replay จริง) แค่ก็อปปี้ `receiptNo`/`cnNo` ลงแถว
  ไม่ได้ commit เข้า `DocCounters` — เลขที่ server ออกให้ตอน replay บิลที่คิวไว้ผ่าน
  `/sync/push` (เช่น บิลที่ยิงออนไลน์ไม่ผ่านตอนแรก แล้วคิวไปออกทาง `/sync/push` ทีหลัง)
  **ยังไม่มีการป้องกันไม่ให้ออกซ้ำตอนออฟไลน์** เหมือนที่ #489 แก้ให้เส้นทางออนไลน์ตรง ๆ
  แล้ว — ยังไม่มี issue เปิดสำหรับช่องโหว่นี้โดยเฉพาะ ควรเปิดใหม่ (ไม่ใช่งานเอกสาร, ไม่แก้ในรอบนี้)
  · เจอจุดเล็กอีกจุด: คอมเมนต์ในโค้ด `sync_service.dart:924` ("agent ร่าง — Thai copy awaiting
  owner ratification (#473)") ยังไม่ได้อัปเดตให้ตรงกับที่ owner รับรองข้อความแล้ว 2026-09-28 —
  ไม่ใช่ความผิดของเอกสาร แต่ทิ้งไว้เป็น cosmetic follow-up
- **#488** (`sync.discard-exact`) — follow-up ของ #473/PR #483 เอง (ระบุไว้ในตัว PR body แล้ว, ไม่ใช่เพิ่งเจอ):
  1. การคืนค่าตอน discard **ไม่ตรงเป๊ะ** เมื่อ forward write เคย clamp ที่ 0 (เช่น creditBalance เหลือ 50 → คืนหนี้ `หักจากเครดิต` 180 → forward clamp เป็น 0 → discard คืนกลับ 180 — สร้างหนี้ 130 บาทที่ไม่เคยมีจริง) — ทางแก้ต้องเก็บ delta จริงตอนเขียน (Drift schema bump v13, lane B), ไม่ใช่คำนวณใหม่จากสูตร
  2. บิลที่ยกเลิกออฟไลน์แล้ว (`sale.void_offline`) ทิ้งไม่ได้เลย (ติดการ์ด "มี dependent" ของตัวเอง) และการทิ้ง op `sale.void_offline` เองไม่ได้ถูกรองรับ (บั๊กคลาสเดียวกับ #473)
  3. เอกสาร `DISCARD_HAS_LOCAL_DEPENDENTS` — **ปิดแล้วรอบนี้**: เพิ่มแถวใน `02_API_SCREENS.md §8.1` พร้อมข้อความไทยที่ owner รับรอง 2026-09-28 และนโยบาย "ปฏิเสธ" (ไม่ cascade/ไม่หักลบสุทธิ) — ตัด `agent ร่าง` marker ของจุดนี้ออกแล้ว
  - AC ที่เหลือ (ข้อ 1–2 ด้านบน) ต้องใช้ schema bump หรือคำตัดสิน owner เพิ่ม — **ไม่ใช่งานเอกสาร**
- **#346** (`ops.backup-scripts`) และ **#338** (`platform.provision`) — ทั้งคู่ VM-gated เหมือนเดิม ไม่มีความเคลื่อนไหวจากรอบนี้ ไม่เกี่ยวกับ #472–#490
- **#479 ที่มากับ PR #482** — ผู้เขียน PR ยืนยันด้วย `pdftoppm` ก่อน/หลังแก้ (ดู PR body) แต่**ไม่มีภาพแนบเข้า repo** — ถ้าจะเก็บ before/after ไว้เป็นหลักฐานถาวรต้องแนบมือ (`docs/tutorial/sri-pos-manual/img/quote-a4.png` และ `quote-a4-terms.png` อาจต้องถ่ายหน้าจอใหม่ด้วย — ดูภาพที่อาจเก่าใน §5)
- **คิว deploy (จาก `session-2026-09-28-overnight-bug-sweep.md` และ `CLAUDE.md` "Still open")** — ยังไม่มีการ merge ใดในรอบนี้แตะ `server/`, ไม่มี Drift schema bump, ไม่มีอะไรขึ้น `mob04` — คิวอนุมัติ `Deploy (demo)` ที่ค้างอยู่ก่อนหน้ายังเป็นสถานะเดิม ไม่ได้ตรวจซ้ำในรอบนี้

## 5. ภาพหน้าจอที่อาจเก่าแล้ว (ยังไม่ได้ถ่ายใหม่)

ไม่มีการเพิ่ม/แก้ภาพในรอบนี้ (นอกเหนือขอบเขตงานเอกสาร) — รายการที่ underlying UI เปลี่ยนวันนี้ จึงอาจไม่ตรงกับภาพเดิมแล้ว:
- `docs/tutorial/sri-pos-manual/img/vehicle-search.png` — สีไฮไลต์คำค้นเปลี่ยนตามธีม (#478/PR #485)
- `docs/tutorial/sri-pos-manual/img/label-printer.png` — ข้อความ VAT บนป้ายอ่านจากตั้งค่าแล้ว ไม่ใช่ `7%` ตายตัว (#480/PR #485) — ถ้าร้านตั้ง VAT ไว้ 7% เหมือนเดิมภาพอาจยังตรงอยู่โดยบังเอิญ
- `docs/tutorial/sri-pos-manual/img/quote-a4.png`, `img/quote-a4-terms.png` — วรรณยุกต์/สระบนล่างของป้ายไทย (`เลขที่`, `วันที่`, `ใช้ได้ถึง`, `ผู้ออก`, `เสนอแก่`) อาจแสดงหลุดตำแหน่งอยู่ในภาพเดิม (#479/PR #482)
- `docs/tutorial/sri-pos-manual/img/reports-mobile.png` — ภาพนี้โชว์การ์ด KPI 4 ช่อง ไม่ใช่ `รายการล่าสุด` (`_RecentRow`) ที่ #477 แก้ overflow ให้ — **ไม่แน่ใจว่ากระทบภาพนี้หรือไม่** ต้องเลื่อนดูส่วน "รายการล่าสุด" ที่ 390 px จริงถึงจะรู้

แก้ข้อความในตัวคู่มือ (ไม่ใช่ภาพ) ไปแล้วสำหรับ: ป้าย VAT ไดนามิก, การทิ้งรายการคืนสต็อกอัตโนมัติ + ปฏิเสธเมื่อมี dependent, settings pull ซ้ำตอนเน็ตกลับ — ดู `docs/tutorial/sri-pos-manual/02-owner-backoffice.html`

## 6. อ้างอิง

- PR #482 #483 #484 #485 #486 #487 #491 #492 · issues #472 #473 #474 #475 #477 #478 #479 #480 #489 #490 (ปิด) · #476 #488 (เปิด)
- `docs/Backend_design/02_API_SCREENS.md §8.1` (แถวใหม่ `DISCARD_HAS_LOCAL_DEPENDENTS`)
- `docs/Shop_manual/01_offline_sync_and_recovery.md` §2 (ข้อความทิ้งรายการ)
- `docs/tutorial/sri-pos-manual/02-owner-backoffice.html` (ป้าย VAT, ทิ้งรายการ, settings pull)
- `CLAUDE.md` "Still open (phase 1)" (สถานะ #472–#490, กฎ `commitServerIssued`)
- ต่อจาก [`session-2026-09-28-overnight-bug-sweep.md`](session-2026-09-28-overnight-bug-sweep.md)
