# Handoff — สแตก local + runbook, แก้ MED ของรีวิว 2026-09-24 (#453/#455, #452 บางส่วน), คู่มือใหม่, issue ที่เจอ (2026-09-27)

**วันที่:** 2026-09-27 · **ผู้บันทึก:** agent (Claude) กับ owner · **สถานะ:** ปิดรอบ — #452 ยังเปิด · issue ใหม่ #460–#465 ยังไม่มีใครแก้
**ขอบเขต:** รันสแตกเต็มบนเครื่อง dev ตาม tutorial, แก้ MED spec gap 3 ข้อจากรีวิวทั้ง codebase, เขียนคู่มือผู้ใช้ชุดใหม่, เปิด issue ของบั๊กที่เจอระหว่างใช้งานจริง, docs-sync หลัง merge
**ต่อจาก:** [`session-2026-09-27-platform-admin-ui-443.md`](session-2026-09-27-platform-admin-ui-443.md) · [`session-2026-09-24-whole-codebase-review.md`](session-2026-09-24-whole-codebase-review.md) (ที่มาของ MED 3–5)

## 1. ตอนนี้อยู่ตรงไหน

| PR | อะไร | สถานะ |
|---|---|---|
| #454 | tutorial: หลุมพราง volume ค้างจากรอบก่อน + stdin บน Windows/PowerShell · `CLAUDE.md` บันทึกว่า #400 ปิดแล้ว (ADR-0009 addendum) | merge |
| #456 | **Closes #453** — Drift `openShift` หลายกะต่อวัน · **Refs #452** — queue `shift.open`/`drawer.entry` ด้วย client id, ปิดกะต้อง outbox ว่างทั้งหมด (`OUTBOX_NOT_EMPTY`) | merge |
| #457 | ลบไฟล์ที่ไม่ใช่ของ repo (`Jenkinsfile` + PDF ของแล็บ, `server/test/smoke.spec.ts`, `android/`/`ios/` ที่ root, `settings.json` ที่ root) | merge |
| #458 | **Closes #455** — reply `applied` ของ `sale.create` บน `/sync/push` = คำตอบของ `POST /sales` · fixture 4 ไฟล์ · client `patchSaleFromPushReply` | merge |
| #459 | คู่มือใหม่ `docs/tutorial/sri-pos-manual/` (5 บท + index, ภาพจริง 41 ภาพ) แทน `docs/tutorial/flutter/` | merge |
| PR นี้ | docs-sync: `CLAUDE.md`, `08` status, `01 §7.5`, review log, tutorial, handoff นี้ | เปิดรอ review |

- **#452 ยังเปิด** — ที่เหลืออยู่ใน [คอมเมนต์ของ #452](https://github.com/NuimanLP/srisurart-pos-flutter/issues/452): `return.create` queueing, replay test ของ op ใหม่, และหน้าลิ้นชักยังเปิดกะที่สองในวันเดียวกันไม่ได้
- **รอ owner:** ข้อความไทย `OUTBOX_NOT_EMPTY` (**agent ร่าง** ใน `02 §8.1.1`) · 5xx ไม่เข้าคิว (เหมือน `ApiSalesRepository`) ต่างจาก `08 §5` — ถ้าจะให้ตรง §5 ต้องแก้ sales กับ shifts พร้อมกัน · #461 / #464 ถามว่า bug หรือ parity
- **ไม่มีอะไรขึ้น `mob04`**

## 2. ทำอะไรไป ได้ผลอะไร

1. **สแตก local:** ยกตาม [`local-full-stack-tutorial.md`](../tutorial/local-full-stack-tutorial.md) แล้วเก็บหลุมพรางที่เจอเข้า tutorial (PR #454): volume `pgdata` จากรอบก่อนทำให้ `bootstrap-admin` บอก `already exists — password left alone` · pipe รหัสจาก PowerShell เข้า stdin ของ CLI ไม่ตรงตัว
2. **MED 3 (#455, PR #458):** owner เลือก spec แทน fixture เดิม 5 ฟิลด์ → บิลออฟไลน์ได้ `costAtSale` (ADR-0008) จาก reply แล้ว กำไรในใบปิดกะถูก · replay ด้วย id ใช้ `SalesService.existingSale` ตัวเดียวกับ route ออนไลน์ จึงไม่มีรูปคำตอบสองแบบให้แยกกันอีก · ผลข้าง: patch ลูกค้าออนไลน์ไม่ throw/ไม่เขียน 0 เมื่อฟิลด์หาย (`patchCustomerAfter`/`patchMechanicAfter` ใน `api_wire.dart` ใช้ร่วม)
3. **MED 5 (#453) + ส่วนหนึ่งของ MED 4 (#452), PR #456:** ดูตารางข้างบน · ไม่มี schema bump (Drift ยัง v12)
4. **คู่มือใหม่ (PR #459):** SOP ภาษาไทยแยกตามบทบาท — พนักงานหน้าร้าน / เจ้าของ / platform admin / IT / dashboards · มีกล่อง "ข้อจำกัดปัจจุบัน" · ภาพ placeholder เหลือ `offline-pin-login` กับ `example`
5. **Issue ที่เปิดจากการใช้งานจริง** (ตรวจในโค้ดทุกข้อก่อนเปิด):

| # | เรื่อง | ทีม |
|---|---|---|
| #460 | `BootstrapService.bootstrap()` ไม่ถูกเรียก → `settings` ของ tenant ไม่ถูก pull (ชื่อร้านยังเป็น seed ของ Drift) · สินค้า/ลูกค้า/ช่างยัง pull ผ่าน `triggerEntityPull` · ทิศเขียน: `SettingsRepository` บน API build ยังเป็น Drift | team/2 |
| #461 | ใบปิดกะไม่มีแถว `เครดิตช่าง` ยอดแถวบวกไม่เท่า `รวมทั้งหมด` — แอป JS ไม่อยู่ใน repo ยืนยัน parity ไม่ได้ → ถาม owner | team/2 |
| #462 | หน้าจัดการเครื่องบอกรหัส 6 หลัก แต่ server ออก 8 ตัวอักษร hex | team/3 |
| #463 | การ์ด KPI หน้ารายงานว่างที่ 390 px (`childAspectRatio: 1.9` เหลือที่ให้ตัวเลข ~3–5 px) | team/1 |
| #464 | checkout ไม่ส่ง `settings.quoteValidDays` → ใบเสนอราคา 30 วันเสมอ — ถาม owner | team/2 |
| #465 | UI เล็ก: Rail ล้น 4 px ที่ 1440×900 · `/devices` ไฮไลต์ "ขายสินค้า" · ป้าย login ยังเป็น Backoffice หลัง enrol | team/3 |

6. **แก้คำผิดของตัวเองใน tutorial:** §5.1 และ §9 บอกให้ดูคำว่า `updated` หลัง `bootstrap-admin --force` แต่สคริปต์พิมพ์ `password reset` (`MESSAGES` ใน `server/src/db/bootstrap-admin.ts`: `created` / `already exists — password left alone (pass --force to reset it)` / `password reset`) — แก้เป็นข้อความตามจริงแล้วใน PR นี้

## 3. บทเรียน

- 🔴 **ห้ามให้ agent สองตัวใช้สแตกเดียวกัน** — agent ที่ค้างจากรอบก่อนยังทำงานกับสแตกเดียวกันและเขียนทับ credential (รหัส admin/owner) ที่อีกตัวเพิ่งตั้ง → login ไม่ผ่านแบบหาสาเหตุยาก · หนึ่งสแตกต่อหนึ่ง agent หรือใช้ `-p` แยกชื่อโปรเจกต์ compose
- 🔴 **Docker ถูกรีเซ็ตกลาง session — volume และ image หายหมด สาเหตุยังไม่รู้** · ต้องยกสแตก + สร้างผู้ใช้แรกใหม่ตั้งแต่ข้อ 3 ของ tutorial · อย่าคิดว่าข้อมูล dev ใน volume จะอยู่ข้ามวัน
- สิ่งที่ "ถูกสร้างแต่ไม่ถูกเรียก" (#460) ผ่าน `dart analyze` และ unit test ได้หมด — เจอได้จากการใช้งานจริงเท่านั้น (ดู network log ว่ามี `GET /api/v1/bootstrap` หรือไม่)

## 4. ต่อจากนี้

- #452 ส่วนที่เหลือ (lane B) · owner เคาะข้อความ `OUTBOX_NOT_EMPTY` และเรื่อง 5xx vs `08 §5`
- owner ตอบ #461 / #464 · #460 ควรมาก่อน #464 (ถึงแก้ #464 แล้ว ค่า `quoteValidDays` บน API build ก็ยังไม่มาจาก server)
- #343 → #344 ยังเป็นงานหลักของเดโม `mob04`
