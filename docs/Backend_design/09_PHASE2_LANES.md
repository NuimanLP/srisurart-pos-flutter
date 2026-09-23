# 09 — Phase 2: การแบ่ง lane และรายการ ticket

**สถานะ:** เจ้าของเคาะ 2026-09-16 · **ทาง C** (ผ่าฮับตามฝั่ง client/server) + ปรับตามความถนัดของทีม
· ผ่าน `/scrutinize` หนึ่งรอบ (บันทึกที่ §11)
**สถานะ 2026-09-23:** 32 จาก 35 ใบ merge แล้ว (รายใบ + PR ที่ §12) · lane A ครบ 3 ใบ 2026-09-17 · ที่เหลือคือ ops ของ lane C (22/23/25) · map #243 ปิด 2026-09-22 · ส่วนที่เหลือของไฟล์นี้คงไว้ตามที่เจ้าของเคาะ — เป็นบันทึกแผน ไม่ใช่สถานะปัจจุบัน
**ต้นทาง:** [`08_PHASE2_SPEC.md`](08_PHASE2_SPEC.md) §16 · [`handoff_log/phase2-wayfinder-spec-2026-09-15.md`](../handoff_log/phase2-wayfinder-spec-2026-09-15.md) §5 · map [#243](https://github.com/NuimanLP/srisurart-pos-flutter/issues/243) · decisions [#240](https://github.com/NuimanLP/srisurart-pos-flutter/issues/240)

> ไฟล์นี้บอก **ใครทำอะไร ลำดับไหน และเส้นแบ่งอยู่ตรงไหน** · *อะไร* อยู่ที่ `08`
> **08 ชนะไฟล์นี้** ถ้าเนื้องานขัดกัน · ADR ชนะ 08

---

## 1. หลักการแบ่ง

| ข้อ | |
|---|---|
| **ไม่มีlaneรอlaneอื่น** | blocked-by ทุกเส้นอยู่ **ภายในlaneเดียวกัน** · ของข้ามlaneเป็น *contract* ไม่ใช่ *คิว* |
| **ผ่าฮับตามฝั่ง** | slice 8 (#228) เป็นศูนย์กลาง — ผ่าเป็น `8-client` / `8-server` แต่ละฝั่งสร้างของตัวเองเทียบ contract พร้อม fake ของอีกฝั่ง |
| **B = เครื่องยนต์ · C = server + หน้าจอที่ไม่มี engine** | Lomer ถนัด code → outbox / SyncService / SW / เลข / PIN + **Drift schema ทั้งหมด** · Pattarapon ถนัด UI → server + ops + **หน้าจอใหม่ที่อ่านแค่ `SyncFacade` หรือ API** (เจ้าของระบุ 2026-09-16) |
| หน้าจอใหม่ที่**ผูกกับ engine** | อยู่กับ B (หน้า "เปิดอยู่แล้ว" ของ slice 3, หน้าตั้ง PIN ของ slice 10, ปุ่ม void ออฟไลน์ของ 11-c) — ย้ายไป C ไม่ได้เพราะแยกจาก engine ไม่ออก |
| **ไม่แก้ไฟล์เดียวกัน** | §6 กำหนดเจ้าของไฟล์ + กติกาของไฟล์ที่เลี่ยงการใช้ร่วมไม่ได้ (Drift schema, migration id, workflow, `customers.service.ts`) |
| **กติกาคอร์ส** | ทุกคนต้องแตะ frontend + backend + CI/CD → §2 |
| **integration ไม่ใช่ ticket ของใคร** | เกิดเองบน `main` เมื่อสองครึ่ง merge · พัง → เปิด bug ให้ฝั่งที่ผิด contract |

---

## 2. สรุป lane

| lane | คน | ถืออะไร | FE | BE | CI | ใบ |
|---|---|---|---|---|---|---|
| **A** `team/1` | NuimanLP | **contract ทั้งสองเส้น** (seam + fixture) + ข้อความไทย + platform allowlist | 0d, 0c | 24 | 24, fixture | **3** |
| **B** `team/2` | LomerAlloys | **ฝั่งเครื่องทั้งหมด** — PWA/SW, outbox, SyncService, เลข RC/CN, PIN, pull, **Drift schema** | ส่วนใหญ่ | 13a | 0a, 18, 20-c | **15** |
| **C** `team/3` | PattaraponKitcharoen | **server + หน้าจอใหม่ + ops** | 16, 19, 21 | ส่วนใหญ่ | 20-s, 22, 23, 25 | **17** |

A เบาโดยตั้งใจ (เจ้าของสั่ง) แต่ของ A **ปลดล็อกคนอื่น** จึงต้องลงก่อน · ops อยู่กับ `team/3` ตามเดิม (เจ้าของยืนยัน 2026-09-16 — Pattarapon ตั้ง VM/runner มาตั้งแต่เฟส 1)

---

## 3. ตาราง ticket

`NEW` = ยังไม่มี issue · `แก้ AC` = issue เดิมมีเนื้อหา**ก่อน** spec ต้องเขียนใหม่ก่อนลงมือ
`บล็อกโดย` = **ในlaneเดียวกันเท่านั้น**

### lane A — `team/1` NuimanLP

| slice | ticket | เนื้อใน | บล็อกโดย |
|---|---|---|---|
| 0c | #268 `copy.phase2` (F10) ✅ **merge แล้ว** (PR #305, 2026-09-17) | **ใบแรกของ A** — เป็นคิวเดียวในแผนที่รอ *คน* · ร่างข้อความไทย 2–3 แบบต่อข้อ (รายการใน `08 §18 Q1`) → เจ้าของเลือก (Option A, 2026-09-17) → ลง `02 §8.1` · เพิ่ม mapping ของ 5 code ใหม่ใน `frontend/lib/core/network/server_error_resolver.dart` (`DOC_NUMBER_REQUIRED` `DOC_NUMBER_INVALID` `VOID_NEEDS_ONLINE` `CLIENT_ID_REUSED` `DEVICE_HAS_UNSYNCED_OPS`) · **ห้ามคิดคำเอง** ต้องให้เจ้าของเลือก | – |
| 0d | #269 `sync.seam` ✅ **merge แล้ว** (PR #307, 2026-09-17 — 18 fixture) | **contract ทั้งสองเส้น** ในใบเดียว: (1) `frontend/lib/data/sync/sync_facade.dart` ตาม §4.2 — abstract + โมเดล (**มี `payload`**) + **`NullSyncFacade` ใช้จริงตอนรันไทม์** + ลงทะเบียนใน `repository_providers.dart` (2) `frontend/test/support/fake_sync_facade.dart` (3) **`docs/Backend_design/fixtures/sync-push/*.json`** ตาม §4.1 · ไม่มี logic ทั้งใบ | – |
| 24 | #270 `sec.platform-allowlist` ✅ **merge แล้ว** (PR #308, 2026-09-17 — + job `nginx-check`) | `nginx.conf`: `/api/v1/platform/` เหลือ loopback + IP admin · เช็ค IP ซ้ำใน `PlatformAuthGuard` (กันคนที่ข้าม nginx) · **+ `location = /sw.js` ใส่ `Cache-Control: no-cache`** (`08 §4` ข้อ 8 — B ต้องใช้ใน slice 3 แต่ไฟล์นี้เป็นของ A) · `nginx -t` + e2e ใน `server.yml` | – |

### lane B — `team/2` LomerAlloys · ฝั่งเครื่อง

| slice | ticket | เนื้อใน | บล็อกโดย |
|---|---|---|---|
| 0a | #245 ✅ **เสร็จแล้ว** (PR #267, 2026-09-16) | asset skew: `sqlite3.wasm` 3.3.3 → 3.4.0, `drift_worker.js` 2.34.0 → 2.34.1 ให้ตรง `pubspec.lock` + assertion ใน `flutter.yml` | – |
| 0a′ | #266 — เจอตอนตรวจ 0a · ✅ แก้ใน PR #310 (2026-09-17, stub `xFileControl`) · issue ปิด 2026-09-19 | **web DB ไม่บูตเลย** ในเบราว์เซอร์ที่ไม่มี `dedicatedWorkersInSharedWorkers`: `LinkError … "xFileControl": function import requires a callable` กับคู่ asset ที่ตรงเวอร์ชันแล้ว (ไม่ใช่ปัญหา skew) · ต้องแก้ก่อน PWA เพราะ offline shell ต้องเปิด DB ได้ | 0a |
| 0b | **NEW** `fe.fonts` | bundle Sarabun/Barlow เป็น asset · `GoogleFonts.config.allowRuntimeFetching = false` (flutter#163554) | – |
| 18 | #272 `fe.drop-offlineok` ✅ **merge แล้ว** (PR #310, 2026-09-17 · Drift v7) | ลบ `Products.offlineOk` (`tables.dart:33`) → **Drift schema v7** + `onUpgrade` · แก้ `api_products_repository.dart:37,55`, `bootstrap_service.dart:188` · Postgres ไม่มีคอลัมน์นี้ (X1) · CI `build_runner` no-diff คือตัวตรวจ · **ทำก่อน PR อื่นที่แตะ schema** (§6 กติกา schema) | – |
| 3 | **NEW** `pwa.1` | ⚠️ ต้องแก้ #266 (0a′) ก่อน ไม่งั้น DB ไม่บูตอยู่ดี · SW เขียนเอง (Workbox) · precache shell + `sqlite3.wasm` + `drift_worker.js` + CanvasKit ในเครื่อง · build `--no-web-resources-cdn` · cache = `github.sha` ลบของเก่าตอน activate · **ถามก่อนโหลดรุ่นใหม่ ห้าม `skipWaiting` อัตโนมัติ** · `storage.persist()` + บันทึก `persisted()` · Web Locks แท็บเดียว + หน้า "เปิดอยู่แล้ว" (`08 §4`) · header `no-cache` ของ `/sw.js` มากับ A/24 — ถ้ายังไม่ลง ให้ทดสอบด้วย nginx ในเครื่อง อย่าแก้ `nginx.conf` | 0a′, 0b |
| 4-c | **NEW** `num.1-client` | เครื่อง `pos` ออก RC/CN จาก `DocCounters` (key `deviceId`, #188) · period = **นาฬิกาเครื่องเท่านั้น** · ขึ้นเดือนใหม่ออฟไลน์ = `0001` · `9999` → `DOC_NUMBER_EXHAUSTED` ไม่วนกลับ · เลขถูกใช้เมื่อ 2xx หรือเข้าคิว (C8) · migration ล้าง `doc_counter_seeds` ตอนอัปเกรด (C16) | 18 |
| 5 | #189 **แก้ AC** | ไม่มี seed marker (เพิ่ง enrol หรือเพิ่งอัปเกรด) → **ห้ามออกเลขออฟไลน์** ปฏิเสธก่อนเขียน/ก่อนพิมพ์ | 4-c |
| 8-c | #228 **แก้ AC** (ครึ่ง client) | ตาราง `outbox_ops` (`08 §7`) · **แถวธุรกิจ + แถว outbox ใน local transaction เดียว** ห้ามเรียก transactional service ของ Drift · `SyncService` single-flight ส่งทีละคำขอ ≤50 op · state machine `08 §5` · นับ `attempts` เฉพาะผลที่ไม่ใช่คำตัดสิน → 3 = `stuck` · โซ่ `aggregates` (`08 §8.4`) · `outboxRemaining` ทุกคำขอ + push ว่างเมื่อค่าเปลี่ยน (C12) · **`implements SyncFacade` แล้วสลับ `NullSyncFacade` ออกใน `repository_providers.dart`** | 3, **4-c** (payload พก `receiptNo`/`cnNo`) |
| 9 | **NEW** `q2.cp` | ย้าย `pending_credit_payments` (#24) เข้า `outbox_ops` — ไม่มีแถวหาย, กติกาเดิมของ #24 ยังอยู่ | 8-c |
| 10 | #211 **แก้ AC** | PIN ออฟไลน์ 1 อันต่อเครื่อง `pos` · hash ช้าผูกเครื่องใน Drift **ไม่ส่งขึ้น server** · อายุ **3 วัน** นับจาก `iat` ของ `/auth/token` ครั้งล่าสุด (refresh ไม่นับ) **ตรวจที่เครื่องเท่านั้น** · Degraded เท่านั้น · ผิด 5 ครั้งล็อกในแอป · หน้าตั้ง PIN พิมพ์รหัสผ่านซ้ำ เทียบในหน่วยความจำแล้วล้าง (C4) · ⚠️ ticket เดิมเขียน 7 วัน + `cashier` — ผิด | 8-c |
| 11-c | **NEW** `q2.void-client` | ปุ่ม void ออฟไลน์ขึ้น**เฉพาะบิล `soldOffline`** + ช่องเหตุผลบังคับ → op `sale.void_offline` · Drift `Sales.soldOffline` | 8-c |
| 12 | #229 **แก้ AC** | `customer.create` / `customer.update` เข้าคิว · ปุ่มของ `08 §6.2` ปิดตอน Degraded · พักบิลอยู่ในเครื่องไม่ sync · **ลบ fallback `super.<write>()` ให้หมด** — AC คือ *`frontend/test/api_repository_contract_test.dart` หาไม่เจออีกแล้ว* ไม่ใช่ตัวเลข (วันนี้ `rethrowServerRefusal` มี **22** จุดใน `api_*.dart` ไม่ใช่ 16 ที่ `CLAUDE.md` เขียนไว้) | 8-c |
| 13a | #212 (ส่วน A) **แก้ AC** | **BE:** keyset + `meta.nextCursor` ให้ `customers` / `mechanics` (วันนี้ `updated_at > $x` ที่ `customers.service.ts:95` + `OFFSET` ที่ `:107`, `mechanics.service.ts:113`) — แบบเดียวกับ products #16 · ⚠️ ไฟล์นี้ lane C ก็แก้ใน 8-s → **§6 กติกา `customers.service.ts`** | – |
| 13b | #212 (ส่วน B) **แก้ AC** | `sync_cursors` ต่อ entity เก็บ cursor **ของ server** (ห้ามคำนวณจาก `MAX(updatedAt)` ในเครื่อง) · หน้าแรกของรอบถอย **30 วินาที** และ **ไม่ส่ง `afterId`** · pull ไม่เขียนทับ stock ของสินค้าที่ยังมี op ค้าง · tombstone รวม `import-tombstone` ห้ามโผล่ในรายการเลือก · ⚠️ ticket เดิมเขียน 5 วินาที — ผิด | 8-c, 13a |
| 14-c | #194 (ครึ่ง client) **แก้ AC** | override วงเงินตอนออฟไลน์ = `overrideCreditLimit` ใน payload ของ `sale.create` (ไม่มี dialog ใหม่ ไม่เดาความยินยอม — กติกา #84) | 8-c |
| 20-c | #193 (ครึ่ง client) **แก้ AC** | contract test ใน `flutter.yml`: รัน `SyncService` กับ **fake server ที่อ่าน fixture §4.1** ครบทุกผล (`applied` / `rejected` / `retry` / หัวคิวติด → `stuck`) | 8-c |

### lane C — `team/3` PattaraponKitcharoen · server + หน้าจอ + ops

| slice | ticket | เนื้อใน | บล็อกโดย |
|---|---|---|---|
| 1 | **NEW** `role.1` | migration ทุกแถว → `owner` + CHECK (แก้ `InitialSchema.ts:57` ด้วย) · `uq_users_one_active` (เก็บ owner แถวเก่าสุด active) · **ลบ role ของคนออกให้หมด**: `requireManager` **20 จุดเรียก + 4 ตัวนิยาม + import** (`settings` 1, `products` 4, `catalogue.controllers` 5, `purchase-orders` 4, `purchasing` 3, `mechanics` 3 · นิยามที่ `catalogue.dto.ts`, `settings.controller.ts`, `purchasing.controller.ts`, `mechanics.controller.ts`) **และ `quotes.controller.ts:114` ที่เขียน `role !== 'manager'` มือ — grep `requireManager` อย่างเดียวจะเดินผ่าน** · `void.service.ts` `ROLES_THAT_MAY_VOID` + `authorise` + argon2 + `consumeAttempt` → รับ `reason` · ลบ `users.pin_hash` · **`idempotency-routes.spec.ts` มี regex ปักรูป `authorise` ของ void — ต้องแก้อย่างตั้งใจ ไม่ใช่แก้ให้เขียว** (🔴 `CLAUDE.md`) · fixture ~46 ไฟล์ · **AC = grep `'manager'` / `'cashier'` ใน `server/src` + `frontend/lib` ได้ 0** | – |
| 2 | **NEW** `sec.device-gate` | retire / enrol / export ต้องมี `did` ใน JWT → ไม่มี = `403 DEVICE_ROLE_FORBIDDEN` · จุดที่แก้: `devices.controller.ts:116` · `backup.controller.ts:54` (**`POST /backup/export`**) · `backup.controller.ts:91` (**`GET /backup/jobs/:id`** — คนละ route อย่านับเป็นใบเดียว) | 1 |
| 4-s | **NEW** `num.1-server` | รับเลขจาก client · ตรวจ prefix ตรง type + `device_no` ตรง `did` + ช่วง 0001–9999 → `400 DOC_NUMBER_INVALID` · **ไม่ตรวจ period** · upsert high-water `GREATEST` · flag `DOC_NUMBER_FALLBACK` + header `X-Client-Version` (C16) · ปิด fallback = body ไม่มีเลข → `400 DOC_NUMBER_REQUIRED` | – |
| 6 | **NEW** `review.1` | ตาราง `owner_review_items` (`kind`, `ref_id`, `details`, `reviewed_at`) · `GET /review-items?status=pending` · `POST /review-items/:id/reviewed` (idempotent, เขียน `audit_log`, **ไม่แตะเงิน/สต็อก**) · 5 kind: `void_offline` `credit_override` `shift_uncounted` `date_flag` `device_force_retired` · 🔴 **เป็นตาราง tenant-scoped**: RLS enabled + forced + policy เดียว, grant ให้ `pos_app`, `tenant_id` อยู่ใน PK, **และเพิ่มชื่อใน `TENANT_SCOPED_TABLES`** (`server/test/schema.e2e-spec.ts:9,113,134` วนเฉพาะรายชื่อในลิสต์ — ตารางที่ลืมใส่ไม่มีใครตรวจ RLS ให้) | – |
| 7 | **NEW** `shift.multi` | หลายกะต่อวัน · `POST /shifts/open` รับ `{id, startingCash, openedAt}` · id เดิม = คืนกะเดิมไม่ archive · มี active อื่น → archive (`auto_archived`) + `shift_uncounted` · `date_str` จาก `opened_at` ตาม `tenants.timezone` · **ลบ "active วันเดียวกัน → คืนกะเดิม" + `today()`** (`shifts.service.ts:160-176`) · กะ import ไม่สร้างรายการตรวจ | 6 |
| 8-s | #228 **แก้ AC** (ครึ่ง server) | `POST /sync/push` (`08 §8`): `X-Device-Token` (`drole=pos`) เป็น endpoint เดียวที่รับ device token · **ผู้กระทำ = user `is_active` คนเดียวของ tenant** ไม่เจอ = 403 ทั้งคำขอ · ขั้น replay key → replay client id → `CLIENT_ID_REUSED` → service ตัวเดิม · **`runTx` ทีละ op ห้าม `Promise.all` (#162) ห้ามรวมทั้ง batch** · หยุดที่ผลแรกที่ไม่ใช่คำตัดสิน (B3) · lock order เดิม บิล → `shifts FOR SHARE` → ช่าง → สินค้า → `doc_counters` → ลูกค้า · `sold_offline` (C3) + วันที่ `08 §10` + `date_flag` · `devices.unsynced_ops` + `unsynced_reported_at` · **เพิ่ม client id ให้ `shifts` / `returns` / `drawer_entries` / `customers`** (`customers.service.ts:150` → §6 กติกาไฟล์ร่วม) · log redact `X-Device-Token` | 4-s, 6, 7 |
| 11-s | **NEW** `q2.void-server` | `sales.void_reason TEXT` + `sales.sold_offline BOOLEAN NOT NULL DEFAULT false` · op `sale.void_offline` (บิลในกะที่เปิดอยู่ ณ ลำดับนั้น) · บิลออนไลน์ → `rejected VOID_NEEDS_ONLINE` · void สำเร็จ → รายการตรวจ | 1, 8-s |
| 14-s | #194 (ครึ่ง server) **แก้ AC** | override มาทาง push → รายการตรวจ `credit_override` + `audit_log` **แถวเดียว** | 6, 8-s |
| 15 | #190 **แก้ AC** | เลขชน UNIQUE บน push → `rejected RECEIPT_NO_CONFLICT` **ห้ามขยับเลข** (ทางออนไลน์ที่ยังไม่พิมพ์ยังขยับได้) · ตรวจ **หลัง** replay (B1/B2) | 4-s, 8-s |
| 17 | **NEW** `dev.retire-guard` | `devices.unsynced_ops > 0` → `409 DEVICE_HAS_UNSYNCED_OPS` `details {unsyncedOps, reportedAt}` · `{force:true, note}` → retire + รายการตรวจ `device_force_retired` · ไม่มี note = 400 | 2, 6, 8-s |
| 16 | #230 **แก้ AC** (FE) | **หน้า "รอ owner" ทั้งหน้า** 2 แท็บ (`08 §14`) — แท็บ "ถูกปฏิเสธ/ค้าง" อ่านผ่าน **`SyncFacade` (§4.2) ห้ามแตะ `outbox_ops` ตรง ๆ** (code / ข้อความ / **payload** / เลขที่พิมพ์ มาครบจาก `OutboxOpView`) · แท็บ "รอตรวจ" อ่าน `GET /review-items` ผ่าน client ใหม่ `frontend/lib/data/repositories/review_items_repository.dart` (**ไฟล์ใหม่ = ของ C ตาม §6**) · ปุ่มส่งใหม่ (key เดิม **ห้ามเปลี่ยนเลข**) · ทิ้ง = ออนไลน์ + หมายเหตุบังคับ → `POST /sync/discards` + `serverHasRow` · ป้ายนับใน `app_shell.dart` · **ทดสอบกับ `FakeSyncFacade`** | 6, 8-s |
| 19 | #195 **แก้ AC** (FE) | แถบสถานะ Online / Degraded / Syncing (อ่านจาก `SyncFacade`) + ป้าย "มีรายการรอ owner" · คู่มือร้าน รวมวิธีคีย์บิลใหม่มือเมื่อ storage หาย — **ได้เลขใหม่ ไม่ใช่เลขบนใบเดิม เขียนเลขเดิมในหมายเหตุ** (X7) · ⚠️ ticket เดิมเขียน "ป้ายเทาขายออฟไลน์ไม่ได้" — **ตัดทิ้ง** (ไม่มี `offlineOk` แล้ว) | 16, **0c ของ lane A (soft)** |
| 21 | #192 **แก้ AC** (FE) | หน้าจัดการเครื่อง (รายการ, enrol, retire, สถานะ op ค้าง) · ใช้/ขยาย `widgets/device_enrolment_dialog.dart` ที่มีอยู่แล้ว · **re-enrol = `device_no` ใหม่เสมอ** · ⚠️ ticket เดิมเสนอ "ออกโค้ดใหม่คงเลขเดิม" ขัด F8 — ตัดทิ้ง · แก้ป้ายชื่อเครื่อง = เฟสถัดไป | 2, 4-s |
| 20-s | #193 (ครึ่ง server) **แก้ AC** | e2e `/sync/push` จาก fixture §4.1 ใน `server.yml`: B1 (บิล commit แล้วตอบหาย → `applied` + `audit_log` แถวเดียว) · B2 (ลบ `idempotency_keys` แล้ว push **ทุก type** → `applied` เงิน/สต็อกไม่ขยับซ้ำ) · B3 (op N ติด → N+1 `retry` ไม่ประมวลผล) · ไม่มี user active = 403 · `idempotency-routes.spec.ts` ครอบ `/sync/push` | 8-s, **11-s** (`sale.void_offline` อยู่ใน "ทุก type") |
| 22 | #184 | deploy `mob04` + วัด RSS ต่อ container **ขณะมีโหลด** (เพดาน 6 GB) · k6 หลายเครื่อง `SHARD=i/N` ตาม #257 · 🔴 **2026-09-23:** #184 ถูกเจ้าของปิด 2026-09-21 โดยไม่มี AC ติ๊ก (ห้ามเปิดใหม่) → การวัดย้ายไป **#380** · deploy จริง #343/#344 · วิธีวัดยืนยันใน #251 (`03 §8.1`) | – |
| 23 | #288 `ops.backup` · 🔴 **2026-09-23: เปิดอยู่** (reopen 2026-09-21) · offsite แยกไป #363 — **พักไว้หลังเดโม `mob04`** (เจ้าของ 2026-09-22) ยังไม่มี backup ออกนอก VM | `pg_dump --create` รายวันส่งออกนอก VM + ซ้อม restore 1 ครั้ง · `--create` พา `ALTER ROLE pos_app IN DATABASE … SET` (#213) มาด้วย — `pg_dumpall --roles-only` ไม่พา · หลัง restore `DbModule` ต้องไม่เตือน | 22 |
| 25 | #67 (ใบใหม่ `cd.2-run`) · 🔴 **2026-09-23:** issue ปิดแล้ว (PR #348) แต่ runner ยังไม่ได้ติดตั้งบน `mob04` — AC run จริงยังไม่พิสูจน์ · ติด FortiGate ของคณะตัด `ghcr.io` | ติดตั้ง self-hosted runner + job-started hook + `pos-deploy` wrapper บน `mob04` ตาม `07 §6.2` แล้ว**พิสูจน์ AC ด้วย run จริง** (push `main` → `.current_sha` ใหม่ · job จาก branch อื่น/fork ถูกปฏิเสธ · playbook fail → rollback อัตโนมัติ run ยังแดง) | 22 |

---

## 4. Contract ระหว่าง lane

มี **2 เส้น** เท่านั้น และ **lane A ส่งทั้งคู่ใน `0d`** เพื่อให้ B กับ C ไม่ต้องรอกันเอง

### 4.1 เส้น wire ของ `/sync/push` (B ↔ C)

- **ข้อกำหนด:** `08 §6` (op catalogue), `§7` (outbox), `§8` (รูปคำขอ/คำตอบ), `§9` (เลข), `§10` (วันที่)
- **fixture:** `docs/Backend_design/fixtures/sync-push/` — **lane A เขียนใน `0d`** (คัดจากตัวอย่างใน `08` ไม่ต้องรันเซิร์ฟเวอร์)

| ไฟล์ | มีอะไร |
|---|---|
| `sale-create.applied.json` · `sale-create.rejected-stock.json` · `sale-create.replay-by-key.json` · `sale-create.replay-by-id.json` · `sale-create.client-id-reused.json` | `sale.create` |
| `return-create.applied.json` · `return-create.rejected-price.json` | `return.create` |
| `drawer-entry.applied.json` · `shift-open.applied.json` · `shift-open.archived-previous.json` | ลิ้นชัก + กะ |
| `credit-payment.applied.json` · `credit-payment.rejected-overpayment.json` | ชำระเครดิต |
| `customer-create.applied.json` · `customer-update.applied.json` | ลูกค้า |
| `sale-void-offline.applied.json` · `sale-void-offline.rejected-online-bill.json` | void ออฟไลน์ |
| `batch.stop-at-retry.json` · `batch.no-active-user-403.json` | ระดับ batch (B3, C13) |

- 🔴 **20-c และ 20-s ต้องอ่านไฟล์ชุดเดียวกัน** — นี่คือเหตุผลเดียวที่ contract test สองฝั่งมีความหมาย
- 🔴 **ใครแก้ fixture ต้องแก้ `08` ใน PR เดียวกัน** · ถ้า `0d` ยังไม่ลง ให้ทำงานกับตัวอย่างใน `08 §8.2` ไปก่อนแล้วสลับมาอ่านไฟล์ (soft) แต่ **AC ของ 20-c/20-s ผ่านไม่ได้จนกว่าจะอ่าน fixture จริง**

### 4.2 เส้น `SyncFacade` (ในเครื่อง)

lane C เขียนหน้าจอ **ห้ามแตะ `outbox_ops` หรือ `SyncService` ตรง ๆ** — คุยผ่าน interface นี้เท่านั้น
ไฟล์ `frontend/lib/data/sync/sync_facade.dart` · **lane A ส่งใน `0d`** (abstract + `NullSyncFacade` + fake) · lane B `implements` ของจริงใน `8-c`

```dart
enum SyncStatus { online, degraded, syncing }

enum OutboxOpStatus { pending, stuck, rejected }

class OutboxOpView {
  final String opId;
  final String type;                    // 'sale.create' …
  final OutboxOpStatus status;
  final int attempts;
  final String? lastCode;               // 'INSUFFICIENT_STOCK' …
  final String? lastMessage;            // ข้อความไทยที่ผ่าน ServerErrorResolver แล้ว
  final Map<String, dynamic>? lastDetails;
  final Map<String, dynamic> payload;   // 08 §14 สั่งให้แท็บนี้โชว์ payload
  final String? docNo;                  // เลขที่พิมพ์ไปแล้ว (ถ้ามี)
  final DateTime createdAt;
}

class DiscardResult {
  final bool serverHasRow;              // true = client ไม่ลบแถว ดึงของ server มาทับ (C15)
}

abstract class SyncFacade {
  Stream<SyncStatus> get status;
  Stream<List<OutboxOpView>> get needsOwner;   // rejected + stuck
  Stream<int> get outboxRemaining;
  Future<void> resend(String opId);            // attempts = 0, key เดิม, ห้ามเปลี่ยนเลข
  Future<DiscardResult> discard(String opId, String note);
}
```

- 🔴 **`0d` ต้องส่ง `NullSyncFacade` ที่ใช้จริงตอนรันไทม์ด้วย** (status `online`, stream ว่าง, `resend`/`discard` โยนข้อความไทย "ยังไม่พร้อม") **และลงทะเบียนใน `repository_providers.dart`** — ไม่งั้นหน้าจอของ C merge เข้า `main` แล้วเปิดไม่ได้จนกว่า `8-c` จะลง ซึ่งคือการรอข้ามlaneที่แผนนี้บอกว่าไม่มี
- 🔴 เพิ่ม/แก้ method = แก้ไฟล์นี้ + §4.2 ใน PR เดียวกัน · lane B สลับ `NullSyncFacade` เป็นของจริงใน `8-c` (บรรทัดเดียว)

---

## 5. slice ที่ถูกผ่า — เส้นแบ่ง

| slice | ครึ่ง client (B) | ครึ่ง server (C) | ทดสอบกับอะไร |
|---|---|---|---|
| 4 `num.1` | ออกเลข, period จากนาฬิกาเครื่อง, marker, `9999` | ตรวจรูปเลข + `device_no`, upsert high-water, `DOC_NUMBER_FALLBACK` | B: unit + fake server · C: e2e ยิงเลขที่ client จะส่ง |
| 8 `#228` | `outbox_ops`, `SyncService`, สถานะ, `stuck`, `outboxRemaining` | `/sync/push`, replay, ผู้กระทำ, วันที่, `sold_offline`, `unsynced_ops` | B: fake server จาก fixture · C: e2e จาก fixture |
| 11 `q2.void` | ปุ่ม + เหตุผล + op | คอลัมน์, `VOID_NEEDS_ONLINE`, รายการตรวจ | เหมือนกัน |
| 14 `#194` | `overrideCreditLimit` ใน payload | `credit_override` + `audit_log` | เหมือนกัน |
| 20 `#193` | contract test ใน `flutter.yml` | e2e push ใน `server.yml` | fixture ชุดเดียวกัน (§4.1) |

🔴 **AC ของทุกใบทดสอบกับ fake/fixture เท่านั้น** — ห้ามเขียน AC ว่า "ใช้ได้กับของจริง" เพราะอีกครึ่งยังไม่ merge

---

## 6. เจ้าของไฟล์ (กันตีกัน)

| lane | แตะได้ |
|---|---|
| **A** | `frontend/lib/data/sync/sync_facade.dart` · `frontend/test/support/fake_sync_facade.dart` · `frontend/lib/core/network/server_error_resolver.dart` · `frontend/lib/presentation/repositories/repository_providers.dart` (ลงทะเบียน `NullSyncFacade` ครั้งเดียว) · `docs/Backend_design/fixtures/**` · `docs/Backend_design/02_API_SCREENS.md §8.1` · `server/docker/nginx/nginx.conf` · `server/src/platform/**` (guard) |
| **B** | `frontend/lib/data/**` (Drift schema, outbox, cursor, repositories, services) · `frontend/lib/core/**` (ยกเว้น `server_error_resolver.dart`) · `frontend/web/**` · `frontend/pubspec.yaml` · หน้าจอ**เดิม**ที่ผูก engine: `checkout_` `returns_` `cash_drawer_` `mechanics_` `login_screen.dart` + หน้าใหม่ของ slice 3/10 · `server/src/customers`, `server/src/mechanics` (13a เท่านั้น) |
| **C** | `server/src/**` (ยกเว้นของ A/B) · `server/test/**` · `frontend/lib/presentation/screens/` **หน้าใหม่** (`owner_review_screen.dart`, `devices_screen.dart`) · `frontend/lib/data/repositories/review_items_repository.dart` (**ไฟล์ใหม่ ยกเว้นจากโซนของ B**) · `frontend/lib/presentation/widgets/app_shell.dart`, `device_enrolment_dialog.dart` · `deploy/**` · `.github/workflows/deploy.yml` |

**ไฟล์ที่เลี่ยงการใช้ร่วมไม่ได้ — กติกา**

| ไฟล์ | กติกา |
|---|---|
| `frontend/lib/data/db/database.dart` + `database.g.dart` + `tables.dart` | **lane B เจ้าเดียว** · ทุก schema bump อยู่ในlaneเดียว (v7 = 18, แล้ว 8-c / 4-c / 10 / 11-c / 13b เรียงกันไป — 2026-09-23: `main` อยู่ที่ **v11**) · **หนึ่ง PR หนึ่งเวอร์ชัน rebase ก่อน merge** · CI `build_runner` no-diff จะจับถ้าลืม regenerate |
| `server/src/db/migrations/` | **จองเลขต่อ lane**: C = `1788652803xxx` · B = `1788652804xxx` (13a) · ห้ามใช้เลขซ้ำข้าม branch (🔴 `CLAUDE.md` Lane B) · ใช้จริง (2026-09-23): C = `…3001-SingleOwnerRole` (1) · `…3002-OwnerReviewItems` (6) · `…3003-SyncPushColumns` (8-s/11-s/17) · B = `…4000-CustomersMechanicsSyncIndex` (13a) |
| `server/src/customers/customers.service.ts` | สองครึ่งคนละ hunk: **B/13a** = keyset + `nextCursor` (บรรทัด ~95, ~107) · **C/8-s** = client id ของ `customer.create` (~150) · ใครลงก่อน rebase ให้คนหลัง |
| `.github/workflows/server.yml` | A (24: `nginx -t` + e2e) และ C (20-s) — **เพิ่ม job ของตัวเอง ห้ามจัดโครงใหม่** · 🔴 job ใหม่ต้องถูกใส่ใน `needs` ของ `server-ci-status` ด้วย ไม่งั้นได้เขียวปลอม |
| `.github/workflows/flutter.yml` | B เท่านั้น (0a asset assertion, 18 `build_runner` no-diff, 20-c contract test) — กติกา `flutter-ci-status` เดียวกัน |
| `frontend/lib/core/router/app_router.dart` | C เพิ่ม 2 route ใหม่ (เพิ่มบรรทัด ไม่แก้ของเดิม) |
| `frontend/lib/presentation/repositories/repository_providers.dart` | A ลงทะเบียน `NullSyncFacade` (0d) → B สลับเป็นของจริง (8-c) → ไม่มีใครแตะอีก |

---

## 7. ลำดับที่แนะนำ (เส้นทางวิกฤต)

```
A:  0c ──► 0d ──► 24
    (0c ก่อน เพราะเป็นคิวเดียวที่รอ "คน" · 0d ปลดล็อก contract ของ B และ C)

B:  18 ──► 4-c ──► 5                       (18 ก่อน: schema bump ใบแรก)
    0a,0b ──► 3 ──┐
                  ├─► 8-c ──┬─► 9
    4-c ──────────┘         ├─► 10
                            ├─► 11-c
                            ├─► 12
                            ├─► 14-c
                            ├─► 20-c
                            └─► 13b        (13a ขนานได้ตั้งแต่วันแรก)

C:  1 ──► 2 ──┐
    4-s ──────┼─► 8-s ──┬─► 11-s ──► 20-s
    6 ──► 7 ──┘         ├─► 14-s
                        ├─► 15
                        ├─► 17
                        └─► 16 ──► 19
    21 (หลัง 2, 4-s)
    22 ──► 23, 25                          (ops ขนานได้ตั้งแต่วันแรก)
```

**เริ่มพร้อมกันได้วันแรก:** A `0c`+`0d` · B `18`+`0a`+`0b`+`13a` · C `1`+`4-s`+`6`+`22`

---

## 8. พิมพ์ `/to-tickets` ยังไง

`/to-tickets` เป็น skill ที่ **เจ้าของต้องพิมพ์เอง** (ตั้ง `disable-model-invocation`) ข้อความที่แนะนำ:

```
/to-tickets  ใช้ docs/Backend_design/09_PHASE2_LANES.md §3 เป็นรายการ ticket
  - ticket NEW: เปิดใหม่ตามชื่อใน §3
  - ticket เดิมที่ทำเครื่องหมาย "แก้ AC": #189 #190 #192 #193 #194 #195 #211 #212 #228 #229 #230 #245
    เขียน AC ใหม่ให้ตรง 08 ก่อน (ของเดิมเป็นเนื้อหาก่อน spec)
  - #212 และ #228 ผ่าเป็นสองใบ (-client / -server) คนละ lane
  - ทุกใบเป็น sub-issue ของ #243 · blocked-by เฉพาะภายใน lane ตาม §3
  - ป้าย team/1 = lane A, team/2 = lane B, team/3 = lane C
  - #67 เปิดใบใหม่ (ของเดิมปิดไปแล้วตอน merge PR #237)
  - 🔴 ทุกใบต้องมีบล็อก §10 "วิธีทำงานกับใบนี้" ต่อท้าย issue body ตามเดิมทุกตัวอักษร
```

**ticket เดิมที่ต้องเขียน AC ใหม่ก่อนลงมือ** (เนื้อหาก่อน spec — ผิดจริง ไม่ใช่แค่เก่า):

| # | ของเดิมผิดตรงไหน |
|---|---|
| #211 | PIN 7 วัน + role `cashier` + server ตรวจซ้ำ → 3 วัน, บัญชีร้าน, **เครื่องตรวจเท่านั้น** |
| #212 | rewind 5 วินาที + `offlineOk` → **30 วินาที** + ไม่มี `offlineOk` + ผ่าเป็น 13a/13b |
| #195 | ป้ายเทา "ขายออฟไลน์ไม่ได้" → ตัดทิ้ง เหลือแถบสถานะ + คู่มือ |
| #192 | "ออกโค้ดใหม่คงเลข `device_no` เดิม" → **`device_no` ใหม่เสมอ** |
| #228 | ไม่มี F2/F3/C12/C13 → เพิ่ม stuck head, ผู้กระทำ, `outboxRemaining` |
| #229 #230 #189 #190 #193 #194 | ตรวจคำต่อคำกับ `08` ก่อนลงมือ |

---

## 9. ความเสี่ยงที่ยอมรับ

| | |
|---|---|
| contract drift ระหว่างสองครึ่ง | กันด้วย fixture ชุดเดียว (§4.1) + `SyncFacade` (§4.2) + contract test ทั้งสองฝั่ง (20-c / 20-s) |
| A เบาที่สุด (3 ใบ) แต่ **ของ A ปลดล็อกคนอื่น** | `0c` (ข้อความ) และ `0d` (seam + fixture) ต้องลงก่อน — ถ้า A ช้า ทุกคนทำงานกับสำเนาชั่วคราว (soft) ได้ แต่ AC ปิดไม่ได้ |
| **`0c` บล็อก UI มากกว่าที่คิด** | ข้อความไทยใหม่อยู่ใน slice **3, 10, 11-c, 12, 16, 19, 21** + 5 error code · เขียนหน้าด้วย placeholder ไปก่อนได้ แต่ **ห้าม ship คำที่คิดเอง** (🔴 `CLAUDE.md`) |
| C หนักสุด (17 ใบ) | ~4 ใบเป็น ops ที่เดินขนานได้ และ 3 ใบเป็น UI ที่ถนัด · เจ้าของยืนยันไม่ย้าย ops ออกจาก `team/3` |
| Drift schema เรียงกันในlane B | ห้าม 2 PR ของ B เปิดพร้อมกันบน `database.dart` — rebase ก่อน merge |

---

## 10. วิธีทำงานกับใบนี้ (บล็อกที่ต้องแปะท้าย **ทุก** ticket)

> `/to-tickets` ก๊อปบล็อกนี้ลงท้าย issue ทุกใบตามเดิม — agent ที่มารับงานอ่านตรงนี้

```markdown
## วิธีทำงานกับใบนี้ (agent ที่มารับอ่านตรงนี้)

1. **อ่านก่อนลงมือ** — `08_PHASE2_SPEC.md` หัวข้อที่ใบนี้อ้าง · `09_PHASE2_LANES.md` §3 แถวของใบนี้ + §4 contract + §6 เจ้าของไฟล์ · 🔴 ใน `CLAUDE.md` ที่เกี่ยวข้อง
   ใบนี้ **ไม่ใช่ spec** — ถ้าใบนี้ขัดกับ `08` ให้ `08` ชนะ · ถ้า `08` ขัดกับ ADR ให้ ADR ชนะ

2. **`/scrutinize` ก่อนเขียนโค้ด** — เอาแนวทางที่คิดไว้เข้าสกิลนี้ก่อน: มีทางที่เล็กกว่า/ใช้ของที่มีอยู่แล้วไหม · แผนชนของจริงตรงไหน · สิ่งที่ใบนี้สมมติแต่ไม่จริงคืออะไร
   เจอทางที่ง่ายกว่าให้พูดก่อนลงมือ อย่าเพิ่งเขียน

3. **เขียนโค้ดตาม `karpathy-guidelines`** — แก้เท่าที่จำเป็น ไม่เพิ่ม abstraction ให้ของที่ใช้ที่เดียว ไม่ทำเผื่ออนาคต ไม่ใส่ error handling ให้เคสที่เกิดไม่ได้ · บอกสมมติฐานออกมาเป็นข้อความ · ไม่ชัด = หยุดถาม ห้ามเดาเงียบ ๆ

4. **ทดสอบกับของฝั่งตัวเองเท่านั้น** — fake/fixture ตาม `09 §4`–`§5` · ห้ามเขียน AC หรือคำอธิบาย PR ว่า "ใช้ได้กับของจริง" ตราบที่อีกครึ่งยังไม่ merge

5. **จบด้วย `/code-review`** — ชี้ที่ merge-base ของ `main` · สกิลจะส่ง **sub-agent สองตัวรีวิวคู่ขนาน** (Standards = มาตรฐานโค้ดของ repo นี้ · Spec = ตรงกับ issue/08 ไหม) · แก้ทุกข้อ 🔴 ให้จบ **ก่อน** ขอคนรีวิว

6. **ปิดงาน** — ถ้าใบนี้ตั้งกติกาใหม่ที่ใบอื่นต้องรู้ เขียน `docs/handoff_log/<ชื่อ>.md` + เพิ่มบรรทัด 🔴 ใน `CLAUDE.md` ใน PR เดียวกัน
   ⛔ ห้ามตัดสินคำถามที่ติดป้าย `question` ของเจ้าของใน PR · ⛔ ห้าม `docker compose down -v` บน daemon ที่ใช้ร่วมกัน
```

---

## 11. รอบ `/scrutinize` (2026-09-16)

รีวิวฉบับแรกของไฟล์นี้ก่อนออก ticket · แก้แล้วทั้งหมด เก็บไว้เพื่อให้รู้ว่าอะไรถูกตรวจไปแล้ว

| พบ | แก้ |
|---|---|
| **Drift schema มีสองเจ้าของ** (A/18 กับ B/8-c,10,11-c,13b ชน `database.dart` + `.g.dart` ไฟล์เดียว) | ย้าย **18 → lane B** (เจ้าของเคาะ) + กติกา schema ใน §6 |
| **AC ของ 20-c รอ PR ของ lane C** (fixture เคยเป็นของ C ลึกสามใบ) | fixture ย้ายเป็น **lane A / `0d`** |
| `OutboxOpView` ไม่มี `payload` แต่ `08 §14` สั่งให้แท็บนั้นโชว์ payload | เพิ่มฟิลด์ใน §4.2 |
| `0d` ส่งแต่ abstract + fake → หน้าจอของ C merge แล้วรันไม่ได้ | `0d` ส่ง **`NullSyncFacade` + ลงทะเบียนใน `repository_providers.dart`** ด้วย |
| client ของ `GET /review-items` ตกอยู่ในโฟลเดอร์ของ B | ยกเว้นไฟล์ `review_items_repository.dart` ให้ C ใน §6 |
| `nginx.conf` (`/sw.js`) และ `customers.service.ts` ถูกสองlaneแก้ | ใส่ `/sw.js` เข้า A/24 · กติกาสอง hunk ของ `customers.service.ts` ใน §6 |
| ไม่มีการจองเลข migration ต่อ lane | §6 จองบล็อกเลข |
| `requireManager` **20 จุด ไม่ใช่ 21** + 4 ตัวนิยาม และ `quotes.controller.ts:114` เป็น `role !== 'manager'` เขียนมือ (grep เดินผ่าน) | เขียนใหม่ในใบ 1 + AC เป็น grep = 0 |
| slice 12 อ้าง "16 จุด" (เลขเก่าใน `CLAUDE.md`) ของจริง **22** | AC เปลี่ยนเป็น contract test หาไม่เจอ ไม่ใช่ตัวเลข |
| ใบ 1 ตกหล่น `idempotency-routes.spec.ts`, `ROLES_THAT_MAY_VOID`, `InitialSchema.ts:57` | ใส่ครบ + ธง 🔴 ว่าแก้ spec อย่างตั้งใจ |
| ใบ 6 ไม่มี AC เรื่อง RLS (`TENANT_SCOPED_TABLES` วนเฉพาะรายชื่อในลิสต์) | ใส่ AC RLS + เพิ่มชื่อในลิสต์ |
| `backup.controller.ts:91` เป็น `GET /backup/jobs/:id` คนละ route กับ export | ใบ 2 ระบุสอง route |
| §7 ของ lane C ลากเส้นตรงทั้งที่ §3 บอกว่าแตกขนานได้ | วาดใหม่เป็น fan-out จาก 8-s |
| 8-c ไม่ได้บล็อกโดย 4-c (payload พกเลข) · 20-s ไม่ได้บล็อกโดย 11-s (`sale.void_offline`) | เพิ่มทั้งสองเส้น (ในlaneเดียวกัน) |
| §1 บอก "หน้าใหม่ทั้งหน้า = C" แต่ slice 3/10 ของ B ก็มีหน้าใหม่ | เขียนกติกาใหม่: หน้าใหม่ที่อ่านแค่ `SyncFacade`/API = C |

**ที่รีวิวเสนอแต่เจ้าของไม่เอา:** ย้าย ops (22/23/25) ไป lane A เพื่อลด C เหลือ 14 ใบ — ops อยู่กับ `team/3` ตามเดิม

---

## 12. เลข issue (ออกแล้ว 2026-09-16)

35 ใบ เป็น sub-issue ของ [#243](https://github.com/NuimanLP/srisurart-pos-flutter/issues/243) ทุกใบ · ป้าย `team/N` + ผู้รับ + `ready-for-agent` ครบ · body ทุกใบมีบล็อก §10

| lane | slice → issue |
|---|---|
| **A** NuimanLP | 0c **#268** · 0d **#269** · 24 **#270** |
| **B** LomerAlloys | 0a #245 ✅ (PR #267) · **0a′ #266** 🔴 · 0b **#271** · 18 **#272** · 3 **#273** · 4-c **#274** · 5 #189 · 8-c #228 · 9 **#275** · 10 #211 · 11-c **#276** · 12 #229 · 13a **#277** · 13b #212 · 14-c #194 · 20-c #193 |
| **C** PattaraponKitcharoen | 1 **#278** · 2 **#279** · 4-s **#280** · 6 **#281** · 7 **#282** · 8-s **#283** · 11-s **#284** · 14-s **#285** · 15 #190 · 17 **#286** · 16 #230 · 19 #195 · 21 #192 · 20-s **#287** · 22 #184 · 23 **#288** · 25 **#67** |

ใบที่เป็นตัวหนา = เปิดใหม่ · ที่เหลือ = ใบเดิมที่เขียน AC ใหม่ตาม `08`/`09` แล้ว
🔴 **slice 25 ใช้ #67** (ถูกเปิดใหม่โดยอีก session วันเดียวกัน) — #289 ที่ผมเปิดไว้ถูกปิดและย้ายเนื้อไปต่อท้าย #67 แล้ว
~~🔴 **0a ปิดแล้ว แต่ 0a′ #266 เพิ่งเปิด**: คู่ asset ที่ตรงเวอร์ชันแล้วยังทำให้ web DB ไม่บูตในเบราว์เซอร์ที่ไม่มี `dedicatedWorkersInSharedWorkers` — บล็อก #273 (PWA)~~ · 2026-09-23: #266 แก้ใน PR #310 (issue ปิด 2026-09-19) · #273 merge แล้ว PR #322
**ใบที่ถูกผ่าครึ่ง:** #228 = 8-client (ครึ่ง server = #283) · #212 = 13b (keyset server = #277) · #194 = 14-client (ครึ่ง server = #285) · #193 = 20-client (ครึ่ง server = #287)

**สถานะ 2026-09-23** — เทียบ `gh issue view` + `git log --grep` / merge บน `main` (ไม่เชื่อ `closedByPullRequestsReferences` อย่างเดียว — หลาย PR ไม่มี closing keyword) · merge = มี PR บน `main` ไม่ได้แปลว่า AC ใน `08` ติ๊กแล้ว

| lane | merge แล้ว (issue → PR) | ยังไม่จบ |
|---|---|---|
| **A** | #268 → #305 · #269 → #307 · #270 → #308 (ทั้งหมด 2026-09-17) | – |
| **B** | #245 → #267 · #266 → #310 · #271 → #299 · #272 → #310 · #273, #274, #189 → #322 · #228 → #324 · #275 → #329 · #211 → #332 · #276 → #334 · #229 → #330 · #277 → #309 · #212 → #347 · #194 → #328 · #193 → #331 | – |
| **C** | #278 → #300 · #279 → #301 · #280 → #312 · #281 → #303 · #282 → #311 · #283 → #313 · #284 → #316 · #285 → #317 · #190 → #315 · #286 → #314 · #230 → #318 · #195 → #321 · #192 → #326 · #287 → #323 | 🔴 #184 (22) ปิดโดยไม่มีการวัด → #380 · 🔴 #288 (23) เปิดอยู่ + #363 พักหลังเดโม · 🔴 #67 (25) ปิดแล้วแต่ run จริงบน `mob04` ยังไม่พิสูจน์ |

ทั้งสี่ใบที่ถูกผ่าครึ่ง merge ครบทั้งสองครึ่งแล้ว — แต่เกณฑ์ข้อ "ใช้ได้กับของจริง" ต้องพิสูจน์ด้วย integration บน `main` ไม่ใช่อนุมานจากการที่ทั้งสองครึ่งปิด (§1 "integration ไม่ใช่ ticket ของใคร")

---

**ก่อนหน้า:** [`08_PHASE2_SPEC.md`](08_PHASE2_SPEC.md) · **map:** [#243](https://github.com/NuimanLP/srisurart-pos-flutter/issues/243)
