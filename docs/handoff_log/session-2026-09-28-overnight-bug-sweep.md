# Handoff — bug sweep ข้ามคืน: ปิด #452 และ #460–#465, คำตัดสินของ owner, follow-up #472–#480 (2026-09-27 → 28)

**วันที่:** 2026-09-28 · **ผู้บันทึก:** agent (Claude) — owner หลับอยู่ สั่งไว้ว่า "ทำให้จบ merge แล้วเขียน handoff ของที่เหลือลง main" · **สถานะ:** ปิดรอบ — issue จากรอบ 2026-09-27 ปิดครบ 7 ใบ · ข้อความไทย **agent ร่าง** 3 จุดรอ owner · follow-up 9 ใบเปิดแล้ว (#472–#480) ยังไม่มีใครแก้
**ขอบเขต:** แก้ #460–#465 และส่วนที่เหลือของ #452 · บันทึกคำตัดสินของ owner 2026-09-27 · ตรวจคู่มือให้ครบ (PR #471) · docs-sync + handoff นี้
**ต่อจาก:** [`session-2026-09-27-local-stack-med-fixes-manual.md`](session-2026-09-27-local-stack-med-fixes-manual.md) (ที่มาของ #460–#465 และ #452 ส่วนที่เหลือ)

## 1. ตอนนี้อยู่ตรงไหน

| PR | อะไร | สถานะ |
|---|---|---|
| #466 | docs-sync หลัง merge รอบ 2026-09-27 (#452/#453/#455, คู่มือ, issue ใหม่) | merge |
| #467 | **Closes #460** — `ApiSettingsRepository`: `GET /settings` ตอน sign-in · `PATCH /settings` พร้อม `Idempotency-Key` · ออฟไลน์ปฏิเสธ ไม่เขียนในเครื่อง · `BootstrapService` ไม่ถูกเรียก (มีคอมเมนต์เตือนว่าทำไม) | merge |
| #468 | **Closes #461** แถว `เครดิตช่าง` ในใบปิดกะ (จอ + PDF) · **Closes #464** ใบเสนอราคาใช้ `settings.quoteValidDays` | merge |
| #469 | **Closes #452** — `return.create` เข้าคิวออฟไลน์ผ่าน `planReturn()` (pure) · replay test สาม op · เปิดกะใหม่วันเดียวกัน (`เปิดกะใหม่`) · `ShiftsRepository.cashCountFrom` · รับชำระเครดิตนับเข้าลิ้นชักเฉพาะเงินสด · `08 §5` แก้ตามคำตัดสิน 5xx | merge |
| #470 | **Closes #462** รหัส enrol 8 ตัวอักษร · **#463** KPI หน้ารายงานที่ 390 px · **#465** rail เลื่อนได้ / `/devices` ไม่ไฮไลต์เมนูผิด / ป้ายหลังผูกเครื่อง | merge |
| #471 | คู่มือ `docs/tutorial/sri-pos-manual/` ตรวจความครบ (ภาพ, ช่องว่าง, ตามโค้ดหลัง #467–#470) | **เปิดอยู่ / กำลัง merge — ดู PR** (ตอนเขียน handoff: open, mergeable, `code-review` ของ PR ยังไม่ครบ) |
| docs-sync (branch `docs/2026-09-28-overnight-sweep-handoff`) | `CLAUDE.md`, `02 §8.1.1`, status ใน `08`, review log 2026-09-24, `server/README.md`, handoff นี้ | ดู PR ของ branch นี้ (ยังไม่ merge) |

- issue ที่ปิดรอบนี้: **#452 #460 #461 #462 #463 #464 #465** (ตรวจด้วย `gh issue list` 2026-09-28 — ปิดครบ)
- **ไม่มีอะไรขึ้น `mob04`** · ไม่มี Drift schema bump (ยัง v12) · ไม่มี server code เปลี่ยนตั้งแต่ #466 (มีแค่ `server/README.md`)

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

1. **#460 (PR #467):** ชื่อร้าน/VAT/อายุใบเสนอราคาบน API build มาจาก server แล้ว — `pullSettingsOnSignIn` (`presentation/blocs/settings_pull.dart`) ยิง `pullFromServer()` ทุกครั้งที่ `Authenticated` · key ที่ reply ไม่ส่งไม่แตะคอลัมน์ (ADR-0010) · `shopNameEn` (server) → `shopNameEN` (Drift) · แก้ settings = `PATCH` อย่างเดียว ไม่มี local write
2. **#461 / #464 (PR #468):** `cashSales`/`qrSales`/`creditSales` เป็นฟังก์ชัน pure บวกกันเท่า `รวมทั้งหมด` · `_handleSaveQuote` ส่ง `validDays` แล้ว (ทั้ง Drift และ API build)
3. **#452 (PR #469):** ดูตาราง §1 · ข้อที่ review จับได้และแก้ในตัว: เลข CN ออฟไลน์เลิกเดา `deviceNo ?? 1` (ใช้ seed marker ล่าสุด → แถว counter ของเครื่องนั้น ไม่รู้ = `OFFLINE_SEED_REQUIRED`) — **ทางบิลขาย (RC) ยังมีข้อบกพร่องเดิม → #472**
4. **#462 / #463 / #465 (PR #470):** ตามหัวข้อ · ข้อความไทยใหม่ 2 จุดเป็น **agent ร่าง** (§5)
5. **คู่มือ (PR #471):** เติมช่องว่างครบ 14/14 route, 4/4 บทบาท · เจอบั๊ก 4 จุดระหว่างตรวจ → กลายเป็น #476, #478, #479, #480
6. **Follow-up ที่เปิดคืนนี้** (ตรวจในโค้ดทุกใบก่อนเปิด อ้าง `file:line` บน `main` @ `d27b864` · ค้น `gh issue list --state all --search` แล้วไม่ซ้ำ):

| # | เรื่อง | label | ที่มา |
|---|---|---|---|
| #472 | `ApiSalesRepository._saveOffline` เลข RC: `deviceNo ?? counter?.deviceNo ?? 1` + counter แถวแรกไม่กรองเครื่อง (`api_sales_repository.dart:480-485`) · ถอยไป `docNo('RC')` (`:494-499`) · ออกเลขนอก transaction (`:487` vs `:544`) | bug, team/2 | PR #469 follow-up |
| #473 | `SyncService.discard` ของ `sale.create`/`return.create` ลบแถวแต่ไม่คืนสต็อก/ลูกค้า/ช่าง/สถานะ void (`sync_service.dart:884-901`) · pull ไม่ช่วยเพราะ cursor ส่งแค่แถวที่เปลี่ยนบน server | bug, team/2 | PR #469 follow-up |
| #474 | settings ไม่ถูก pull ใหม่ตอนเน็ตกลับ หลังเปิดแอปออฟไลน์ (`settings_pull.dart:17-23`; `triggerEntityPull` `repository_providers.dart:82-93` ไม่มี settings) | bug, team/2 | PR #467 known limitation |
| #475 | เครื่องใหม่ที่ `GET /doc-counters` ไม่มีแถว ทำ CN ออฟไลน์ไม่ได้จนออกเอกสารใบแรก (`api_returns_repository.dart:391-404`) — ปฏิเสธ ไม่ได้ออกเลขผิด | enhancement, team/2 | PR #469 follow-up |
| #476 | ทางตันการจัดการเครื่อง: `/devices` ทุก route ต้องมี device token (`devices.controller.ts:127-131`) · platform ออกรหัสใหม่ได้เฉพาะแถวที่ไม่เคย enrol (`platform-tenants.service.ts:313-358`) | bug, question, team/3 | PR #471 — **owner ต้องตัดสิน** |
| #477 | `_RecentRow` หน้ารายงาน RenderFlex overflow ที่ 390 px (`reports_screen.dart:1312-1332` — ผู้ต้องสงสัย ยังไม่ trace) | bug, team/1 | bug sweep |
| #478 | หน้าค้นหาตามรุ่นรถ: ไฮไลต์บังคำที่ตรง (`vehicle_search_screen.dart:567-573` ตัวอักษร `0xFFFFCC88` บนพื้นส้มโปร่ง) | bug, team/2 | PR #471 |
| #479 | PDF ใบเสนอราคา A4: ป้ายไทยที่ตั้ง `letterSpacing` วรรณยุกต์หลุด (`quote_a4_view.dart:288-296`, `:310-320`, `:338-348`, `:535-545`) | bug, team/2 | PR #471 |
| #480 | ป้ายชั้นวางพิมพ์ `รวม VAT 7%` ตายตัว (`label_printer.dart:223`, `:692`) ไม่อ่าน `settings.taxRate` | bug, team/2 | PR #471 |

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

**คำตัดสินของ owner (2026-09-27)** — บันทึกที่ `CLAUDE.md` "Still open" และที่นี่:
- **#461:** เพิ่มแถว `เครดิตช่าง` (ไม่ถือ parity กับของเดิม) → PR #468
- **#464:** อายุใบเสนอราคาใช้ค่าจากหน้าตั้งค่า → PR #468
- **ข้อความ `OUTBOX_NOT_EMPTY` รับรองแล้ว** — `02 §8.1.1` แก้ใน PR #469
- **5xx ไม่เข้าคิว** — ทุก write path บน API build (ขาย, กะ, คืนสินค้า) เข้าคิวเฉพาะ transport failure · 5xx/429 จอดความพยายามไว้ (id + key เดิม) · `08 §5` แก้ตามแล้ว (PR #469) — ประเด็น "deviation ที่ยังไม่ตัดสิน" ของ handoff 2026-09-27 จบแล้ว

**ที่ agent ตัดสินเอง (ในกรอบของ ticket):**
- **#460 ไม่ใช้ `BootstrapService.bootstrap()` ตามที่ใบเสนอ** — product upsert ข้าม stock guard ของ outbox (08 §15) + เขียน `zone` เป็น null · settings อ่าน `shopNameEN` แต่ server ส่ง `shopNameEn` (ทุก pull จะรีเซ็ตชื่อ EN) · ไม่อ่าน `quoteValidDays` → ทำ settings-only pull แทน, `BootstrapService` ค้างไว้พร้อมคอมเมนต์เตือน (`bootstrap_service.dart` หัวไฟล์)
- **กฎคืนสินค้าอยู่ที่เดียว (`return_plan.dart`)** ใช้ร่วม Drift/API build — API repo ห้ามเรียก Drift `createReturn` (กฎ double-decrement เดิม)
- **จุดเริ่มนับเงินลิ้นชักจุดเดียว (`cashCountFrom`)** ใช้ทั้งหน้าลิ้นชักและใบปิดกะ — กะแรกของวันนับจากเที่ยงคืน (ทุกกะก่อนมีหลายกะต่อวันจึง reconcile เหมือนเดิม) กะถัดไปนับจากเวลาเปิดของตัวเอง
- **เพิ่มข้อความ agent ร่างของ #462/#465 ลง `02 §8.1.1`** (รอบนี้) — PR #470 ใส่ไว้แค่คอมเมนต์ในโค้ด owner จึงไม่มีที่ให้เคาะ
- **ทีมของ follow-up:** ตาม `09 §6` — outbox/`SyncService`/เลข RC-CN/pull = lane B (`team/2`) · server + หน้าจัดการเครื่อง + platform = lane C (`team/3`) · `reports_screen.dart` ไม่มีเจ้าของ → `team/1` ตาม #463 · ใบเสนอราคา/แคตตาล็อก/ป้าย → `team/2` ตาม #464 (ผลคือ `team/2` ได้ 7/9 ใบ — owner ย้ายได้)

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- **ต่อ `BootstrapService.bootstrap()` ตรง ๆ แก้ #460** — ดู §3 · ถ้าวันหนึ่งจะใช้ ต้องแก้ทั้งสามข้อก่อน ไม่ใช่แค่เรียก

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

- **ข้อความไทย agent ร่าง 3 จุด รอ owner เคาะ** (ทั้งหมดอยู่ใน `02 §8.1.1` แล้ว):
  1. `เปิดกะใหม่` — หัวข้อ + ปุ่ม (#452, PR #469) · `cash_drawer_screen.dart:433`
  2. รหัสผูกเครื่อง: `นำรหัส 8 ตัวอักษรนี้ไปกรอกที่หน้าผูกเครื่องของเบราว์เซอร์เป้าหมาย รหัสนี้มีอายุ 15 นาที` + hint `เช่น 3F9A0C1B (8 ตัวอักษร)` (#462, PR #470) · `devices_screen.dart:867`, `device_enrolment_dialog.dart:95`
  3. ป้ายหลังผูกเครื่อง: `ผูกเครื่องกับร้านแล้ว รอเข้าสู่ระบบเพื่อยืนยันสิทธิ์การใช้งาน` (#465, PR #470) · `login_form.dart:184`
  - `grep -rn "agent ร่าง"` ยังเจอของรอบ #443 PR2/PR3 อีกหลายจุด (`02 §8.1`/`§8.1.1`, `change_password_form.dart`, `password_changed_banner.dart`, `server_error_resolver.dart` ฯลฯ) — ของเก่า ไม่ใช่ของคืนนี้
- #477: Row ที่ล้นจริงยังไม่ได้ trace ด้วย DevTools · #479: สาเหตุ (package `pdf` เว้นระยะ combining mark) เป็นสมมติฐาน · #478/#480: แอป JS เดิมไม่อยู่ใน repo → ยืนยันไม่ได้ว่าของเดิมเป็นแบบเดียวกัน (parity)
- **สแตก local:** container server สร้างเมื่อ 2026-09-27 14:52Z — ไม่ได้ตรวจว่ารวม #458 (merge 14:53Z) หรือเปล่า · #467–#470 ไม่แตะ server code จึงไม่ต้อง rebuild เพื่อพวกนี้ · Flutter web ที่รันอยู่เป็น build **ก่อน** #469/#470 (PR #471 บอกไว้) → จะดู `เปิดกะใหม่`/หน้ารายงาน/รหัส enrol ใหม่ต้อง build ใหม่

## 6. ก้าวถัดไป (เรียงลำดับ)

1. owner เคาะข้อความไทย 3 จุดใน §5 (หรือให้คำใหม่)
2. owner ตัดสิน #476 (ทางเลือก 1–3 ในใบ) — กระทบ ADR-0004
3. merge PR #471 (คู่มือ) เมื่อ `code-review` ของ PR ครบ · แล้ว merge PR docs-sync นี้
4. lane B: **#472 ก่อน** (เลขบิลผิดชุด = server ปฏิเสธหลังพิมพ์ใบเสร็จแล้ว) → #473 (สต็อกในเครื่องเพี้ยนหลัง discard) → #474 → #475
5. UI: #477 #478 #479 #480 (เล็ก ทำขนานได้)
6. ที่ยังค้างจากก่อนหน้า: item 6 (LOW) ของรีวิว 2026-09-24 (`shifts.service.ts:190-198` ไม่เทียบ `startingCash`) ยังไม่มี issue · #343 → #344 ยังเป็นงานหลักของเดโม `mob04`

## 7. ข้อควรระวัง

- 🔴 **credential ของสแตก dev อยู่ใน scratchpad ของ session เท่านั้น — ห้าม commit, ห้ามคัดลอกเข้า repo หรือ handoff** · tenant ที่ใช้คือ `srisurart-demo` · สแตกยังรันอยู่ตอนเขียน (nginx :80/:443, `tlswrap` 127.0.0.1:8081, platform-ui 127.0.0.1:3200, Grafana 127.0.0.1:3000) · scratchpad หายเมื่อ session จบ → รอบหน้าต้องพร้อมสร้างผู้ใช้แรกใหม่ตาม [`local-full-stack-tutorial.md`](../tutorial/local-full-stack-tutorial.md)
- 🔴 หนึ่งสแตกต่อหนึ่ง agent (บทเรียน 2026-09-27 — credential ถูกเขียนทับ)
- ห้ามต่อ `BootstrapService.bootstrap()` ตามสภาพปัจจุบัน (§3) · ห้ามคำนวณเงินที่ควรมีในลิ้นชักทางที่สอง — ใช้ `cashCountFrom` · ห้ามให้ API build เข้าคิว 5xx (คำตัดสิน owner)
- อย่าแก้ `docs/tutorial/sri-pos-manual/` จาก branch อื่นระหว่างที่ PR #471 ยังเปิด

## 8. อ้างอิง

- PR #466 #467 #468 #469 #470 #471 · issues #452 #460–#465 (ปิด) · #472–#480 (เปิด)
- `CLAUDE.md` "Still open" + "Idempotency & the client write path" (กฎใหม่: `cashCountFrom`, `planReturn`, settings online-only, `BootstrapService`)
- `02_API_SCREENS.md §8.1.1` · `08_PHASE2_SPEC.md` §5 / §6.1 / §11 (status 2026-09-27) · `09_PHASE2_LANES.md §6`
- [`session-2026-09-24-whole-codebase-review.md`](session-2026-09-24-whole-codebase-review.md) (status 2026-09-28)
