# CI ที่ "แดง" แล้วทีมแก้จน "เขียว" — หลักฐานจาก GitHub Actions + git history

**วันที่รวบรวม:** 2026-09-29 · **ใช้สำหรับ:** Real progress #2 — CI/CD & Quality Gate (วิชา DevOps)
**แหล่งข้อมูลหลัก:** `gh run list` ของทุก workflow (ประวัติทั้งหมด), `gh run view --log-failed` ของทุก run ที่ fail,
`git log` ระหว่าง SHA ที่แดงกับ SHA ที่เขียวถัดไปบน branch เดียวกัน, และ `gh pr view` / `gh api`
**งานคู่กัน:** `docs/research/quality-gate-lessons-from-history-2026-09-29.md` (อีก agent หนึ่งเขียน โดยอ่านจากเอกสาร/handoff log
และตั้งใจไม่ดู Actions run) — ไฟล์นี้ใช้ **run history เป็นหลักฐานหลัก**

**กติกาที่ใช้เขียน:** ทุกข้อความอ้างถึง run / commit / PR ที่ตรวจเองแล้ว เวลาเป็น **UTC** (ตามที่ GitHub API ส่งมา)
สิ่งที่ตรวจไม่ได้ติดป้าย **[ยังไม่ได้ตรวจสอบ]** หรือ **[อนุมาน]** และ log ที่หมดอายุ/โหลดไม่ได้จะบอกตรง ๆ

---

## 1. สถิติรวม

ช่วงเวลา: Flutter CI 2026-09-04 → 2026-09-29 · Server CI 2026-09-06 → 2026-09-29 · Deploy (demo) 2026-09-15 → 2026-09-29
(จำนวน run ตรงกับ `total_count` ของ `GET /actions/workflows/{id}/runs` จึงเป็นประวัติทั้งหมด ไม่ใช่แค่ส่วนที่ list ได้)

| Workflow | Runs ทั้งหมด | Completed (success+failure) | Failure | Failure rate | Cancelled | Push บน `main` ที่แดง | Branch/PR ที่เคยแดง | เวลาจากแดง→เขียว บน branch เดิม (median / max) |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Flutter CI (`flutter.yml`) | 667 | 658 | **12** | **1.8%** | 9 | 3 / 265 | 7 (6 branch + `main`) | 10 นาที / 67 นาที (n=11) |
| Server CI (`server.yml`) | 743 | 724 | **37** | **5.1%** | 19 | 9 / 291 | 21 (20 branch + `main`) | 22 นาที / 1,341 นาที (n=35) |
| Deploy (demo) (`deploy.yml`) | 368 | 182 | **1** | — | 176 | — | — | ดูเรื่อง F5 |
| Dependabot Updates | 4 | 4 | 0 | 0% | 0 | — | — | ดูเรื่อง F4 |

> **วิธีวัดคอลัมน์ "แดง→เขียว":** ต่อ run ที่ fail แต่ละตัว = เวลาจาก `createdAt` ของ run แดง ถึง `createdAt` ของ run `success` ถัดไปบน `headBranch`+`event` เดียวกัน
> (ถ้านับถึง `updatedAt` ของ run เขียว จะได้ Flutter median 12.7 / max 68.7, Server median 24.1 / max 1,346 นาที) **ค่า max ของ Server (1,341 นาที ≈ 22 ชม.) ไม่ใช่เวลาแก้บั๊ก** —
> เป็น run flaky F2 บน `main` ที่ "เขียว" เมื่อมี push ถัดไปเข้ามา (ไม่มี fix); อย่าเอา max/median ตัวนี้ขึ้นสไลด์เป็น "MTTR"

**ก่อน vs หลังเปิด branch protection บน `main` (2026-09-15, #186):**

| | ก่อน 2026-09-15 (runs / fail) | ตั้งแต่ 2026-09-15 (runs / fail) |
|---|---|---|
| Flutter CI | 128 / 3 (2.3%) | 530 / 9 (1.7%) |
| Server CI | 206 / 24 (**11.7%**) | 518 / 13 (**2.5%**) |

`main` ที่แดงบน Server CI: **4 ครั้งก่อน 09-15 เป็นโค้ดเสียจริงทั้งหมด** (PR #86 และ #119 ถูก merge ทั้งที่ check แดง, และ push ตรงเข้า `main` 2 ครั้ง)
ส่วน **5 ครั้งหลัง 09-15 ไม่มีครั้งไหนเป็นโค้ด production เสีย** — 1 ครั้งเป็น registry ล่มชั่วคราว, 4 ครั้งเป็น unit test ที่ flaky (เรื่อง F2)
`main` ที่แดงบน Flutter CI: ทั้ง 3 ครั้งเกิดในวันเดียว (2026-09-28) จาก PR สองตัวที่ **เขียวทั้งคู่ตอนแยกกัน** แต่ชนกันหลัง merge (เรื่อง 12)

**แยกตาม stage ของ gate (50 run ที่ fail):**

| Stage | จำนวน run | ตัวอย่าง |
|---|---:|---|
| Integration / e2e (Postgres + Redis จริง, migration จริง) | 28 | เรื่อง 3, 4, 5, 7, 8, 9, 10 |
| Unit / widget test (`flutter test`, `pnpm test`) | 10 | เรื่อง 2, 12, F2 |
| Lint / typecheck / build (`dart analyze`, `tsc`, `nest build`) | 4 | เรื่อง 2, 6 |
| Consistency — Drift codegen ตรงกับที่ commit | 2 | เรื่อง 1 |
| Workflow config / env (`working-directory`, compose `:?` required env) | 2 | เรื่อง 11 (JWT env ที่หายใน e2e นับอยู่ในแถว e2e) |
| Dependency resolution / build ของ Dependabot PR | 2 | เรื่อง F4 |
| Image publish (push GHCR) | 1 | เรื่อง F3 |
| Deploy/CD (reviewer ปฏิเสธ) | 1 | เรื่อง F5 |

ตัวเลขนี้นับจากชื่อ job/step ที่ fail ใน `gh run view --json jobs` — หนึ่ง run นับหนึ่งครั้งตาม job ที่แดงจริง (ไม่นับ status job) รวม 50 = 12 Flutter + 37 Server + 1 Deploy

**สิ่งที่ "ไม่เคยแดง" ในประวัติ (ตรวจจาก job ที่ fail ทั้ง 50 run):** `audit (pnpm audit + Trivy fs)`, `pubspec.lock CVEs (OSV-Scanner)`,
Trivy image gate, `nginx-check`, และ web DB asset-version check ไม่มีครั้งไหนเป็น job ที่ทำให้ run แดง
พูดตรง ๆ: เรา **ไม่มีหลักฐานจาก run history ว่า security gate เคยจับ CVE ได้จริง** — มันยังเขียวมาตลอด
(ข้อความ `::error::pubspec.lock … no longer matches …` ที่เห็นใน log เป็นแค่ตัวสคริปต์ที่ถูก echo ตอน `set -x`/group ไม่ใช่ error ที่เกิดจริง)

---

## 2. เรื่องที่ gate จับของเสียได้จริง (12 เรื่อง)

### 1. codegen check จับ `database.g.dart` ที่หายไปทั้งไฟล์บน runner สะอาด
- **Stage:** Consistency (job `drift codegen is up to date`)
- **แดง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34431242899 · 2026-09-10 02:54 · `42daf807` (PR #58 fe.0)
```
##[error]Generated Drift code is stale. Run 'dart run build_runner build' on an ASCII path and commit the result.
```
- **Root cause (จาก commit message ของผู้แก้):** เพิ่ม extension `ProductWriteStamp` ไว้ใน `database.dart` ซึ่งเป็น library ที่มี `part 'database.g.dart'`
  และมันอ้าง `ProductsCompanion` ที่อยู่ในไฟล์ generated — บน cold build ไฟล์ part ยังไม่มี drift_dev จึงไม่ generate อะไรเลยและ **ลบ `database.g.dart` ทิ้ง (-17,493 บรรทัด)**
  เครื่อง dev มี build cache อุ่นอยู่เลยไม่เห็น
- **Fix:** `2a5c697` — *"fix: move the stamp extension out of the library that owns database.g.dart"* (PR #58)
  ย้าย extension ไป `lib/data/db/product_stamp.dart` (+24 บรรทัด) ที่ *import* แทน *part* · ผู้แก้เขียนไว้ใน commit ว่า
  *"CI's codegen-check caught a real bug of mine … the job is not broken, the code was."*
- **เขียวหลังแก้:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34431666411
- **เกิดซ้ำอีกครั้ง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35430702456 (2026-09-19, `b7c1513a`, PR #324 outbox_ops schema v9 — ลืม regenerate)
  → `f56e904` *"chore(drift): regenerate database.g.dart for schema v9 (outbox_ops)"* → เขียว https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35431173961
- **บทเรียน:** gate ที่รันบน runner สะอาดจับปัญหาที่ "เครื่องเราผ่าน" ได้ — นี่คือเหตุผลที่ต้องมี CI แทนการเชื่อเครื่อง dev

### 2. PR #310 (Drift schema v7) แดง 3 รอบติด — analyze → analyze → test
- **Stage:** Lint (`dart analyze`) แล้วต่อด้วย Unit test (`flutter test`)
- **แดงรอบ 1:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35195765805 · 2026-09-17 07:41 · `8faebacb`
```
error - test/schema_v7_migration_test.dart:69:31 - Undefined name 'OrderingTerm'. - undefined_identifier
```
  → `54e44e2` "fix schema v7": `+import 'package:drift/drift.dart';`
- **แดงรอบ 2:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35196267006 · 07:47 · `54e44e20`
```
error - test/schema_v7_migration_test.dart:87:28 - The name 'isNull' is defined in the libraries
  'package:drift/…/query_builder.dart' and 'package:matcher/src/core_matchers.dart' … - ambiguous_import
```
  → `548aefa` "fix2": `-import 'package:drift/drift.dart';` / `+import 'package:drift/drift.dart' hide isNull;`
- **แดงรอบ 3:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35196448655 · 07:49 · `548aefaa`
```
schema_v6_migration_test.dart: upgrades a v5 file to v6 with empty counter tables [E]
  Expected: <6>
    Actual: <7>
```
  → `1eb2020` "change version": `-    expect(version, 6);` / `+    expect(version, 7);`
- **เขียว:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35196937568 · 07:55 (14 นาทีจากแดงรอบแรก) — PR #310
- **บทเรียน (พูดตรง ๆ):** รอบ 1–2 คือโค้ดที่ไม่ได้รัน `dart analyze` ในเครื่องก่อน push — CI ทำหน้าที่แทน แต่เสียรอบไป
  รอบ 3 เป็นรูปแบบที่ **เกิดซ้ำ**: migration test hardcode เลข schema (`expect(version, N)`) ทุกครั้งที่ bump schema จะแดง
  (เจออีกที่ https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35504913192 `Expected: <9> Actual: <10>` → `8aea5e3` แก้ 6 ไฟล์, PR #334)
  ณ วันนี้ `frontend/test/schema_v6_migration_test.dart:76` ยังเป็น `expect(version, 13);` — ข้อเสนอ: เทียบกับ `db.schemaVersion` แทนตัวเลข **[ข้อเสนอ ยังไม่ได้ทำ]**

### 3. e2e จับ rate limit ที่ "ไม่เคยทำงานเลย" (ได้ 200 แทน 429)
- **Stage:** Integration/e2e (`test/rate-limit.e2e-spec.ts`)
- **แดง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34568405312 · 2026-09-11 06:04 · `d0a8f7c5` (PR #77)
```
FAIL  test/rate-limit.e2e-spec.ts > Per-tenant rate limiting (ADR-0006 e2e) > returns 429 RATE_LIMITED with Retry-After header when quota is exhausted
FAIL  … > isolates tenants: Tenant A exhausted quota does not block Tenant B
AssertionError: expected 200 to be 429 // Object.is equality
```
  (รอบก่อนหน้า https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34568098201 แดงเพราะ test เอง — `duplicate key value violates unique constraint "tenants_code_key"`
  แก้ด้วย `d0a8f7c` *"use unique tenant UUID prefixes in rate-limit e2e to fix code collision"* แล้วจึงเห็นบั๊กจริงข้างล่าง)
- **Root cause:** `TenantRateLimitGuard` เป็น global guard ที่รัน **ก่อน** auth guard ตอนนั้น `req.user` ยังไม่มี → `tenantId` ว่าง → guard `return true`
  กล่าวคือ per-tenant rate limit **ไม่เคยนับ request ไหนเลย** แต่ unit test (ที่ mock `req.user`) ผ่าน
- **Fix:** `114a7e8` *"fix(server): resolve tenantId via JwtVerifier in rate-limit guard and match standard error envelope"* (PR #77)
```diff
-    const tenantId = req.user?.tenantId;
+    let tenantId = req.user?.tenantId;
+    if (!tenantId) {
+      const authHeader = req.headers.authorization;
+      if (authHeader?.startsWith('Bearer ')) {
+          const payload = this.jwtVerifier.verify(token, 'access');
+          if (payload.aud === 'tenant' && payload.tid) { tenantId = payload.tid; }
```
- **เขียว:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34569719570 · 06:23
- **บทเรียน:** unit test ที่ mock context ไม่พิสูจน์ลำดับของ guard — ต้องมี e2e ที่บูต app จริงถึงจะเห็น

### 4. e2e latency budget จับ report ที่ช้า 10 เท่า — และ PR ที่ merge ทั้งที่แดงทำให้ `main` แดง
- **Stage:** Integration/e2e (performance budget ใน `test/reports.e2e-spec.ts`, §9 read budget < 200 ms)
- **แดงบน PR:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34685802650 · 2026-09-12 09:25 · `f0398ee4` (PR #86)
```
FAIL  test/reports.e2e-spec.ts > server-side reports (e2e) > keeps every endpoint below the §9 read latency budget on the demo dataset
AssertionError: /product-sales?productId=p1&from=2026-09&to=2026-09 p95 was 2350.4 ms: expected 2350.351908 to be less than 200
```
- **แล้วเกิดอะไร:** PR #86 ถูก merge เวลา 09:25:24 ทั้งที่ check `integration` = `FAILURE` (ตรวจจาก `gh pr view 86 --json statusCheckRollup`)
  → push บน `main` แดงทันที https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34685807815 (p95 2666.9 ms)
  → PR อื่นที่ rebase บน main ก็แดงตาม: https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34690220740 (p95 2038.5 ms)
  และ https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34688014401 (p95 2577.6 ms — PR #84 ไม่ได้แตะ `reports.e2e-spec.ts` ใน diff ของตัวเองเลย; ไฟล์นี้มีอยู่ใน tree เพราะมาจาก `main`)
- **Root cause:** query `product-sales` กรอง `product_id` หลังจาก join ขายทั้งหมดของเดือน และหลัง bulk-seed 5,000 แถวไม่มี statistics
- **Fix:** `776f05f` *"fix(reports): push down product_id filter and analyze tables after bulk seed"* (ติดมากับ PR #88)
```diff
+    JOIN sale_items si
+      ON si.tenant_id = $1::uuid
+     AND si.product_id = $4
 …
+    await admin.query('ANALYZE sales; ANALYZE sale_items;');
```
- **เขียว:** PR https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34691225573 · `main` https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34691446285 (11:35) — **`main` แดงอยู่ราว 2 ชั่วโมง 10 นาที**
- **บทเรียน:** gate ต้อง "บังคับ" ไม่ใช่ "แนะนำ" — ดูเรื่อง 5

### 5. Push ตรงเข้า `main` → แดง → revert 2 รอบ → เปิด branch protection
- **Stage:** Integration/e2e + process
- **แดง (push ตรง ไม่ผ่าน PR):**
  - https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34802375479 · 2026-09-14 03:22 · `8ceaa775` — 16× `TypeError: Cannot read properties of undefined (reading 'query')` กระจายอยู่ใน 22 จาก 23 ไฟล์ e2e ที่ fail (`Test Files 22 failed | 1 passed`)
  - https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34803288836 · 03:38 · `fc603b8b` (ลองใหม่)
```
FAIL  test/bootstrap.e2e-spec.ts > bootstrap and settings (e2e) > GET /bootstrap returns aggregated lists and supports ETag / If-None-Match 304
AssertionError: expected 500 to be 200 // Object.is equality
 ❯ test/bootstrap.e2e-spec.ts:150:28
```
- **ผลข้างเคียง:** ในช่วง 03:38–03:45 ที่ `main` แดง PR ที่ไม่เกี่ยวข้อง 3 ตัวแดงด้วย error เดียวกัน (ตรวจแล้ว head ของทั้งสามไม่มีไฟล์ `bootstrap.e2e-spec.ts`):
  [34803324340](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34803324340) (PR ci.2),
  [34803327162](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34803327162) (ops.1),
  [34803494999](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34803494999) (ops.2)
- **Fix:** revert ทั้งสองครั้ง — `af7d6b6` → เขียว [34802760708](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34802760708),
  `0d9e17c` → เขียว [34803701924](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34803701924) แล้วงานนี้กลับเข้ามาใหม่เป็น PR #116 (`bd56a9d`)
- **ภายในวันเดียวกัน** PR #119 ถูก merge ทั้งที่ `server-ci-status` = `FAILURE` (05:19:02) → `main` แดง [34809191210](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34809191210)
  (`AssertionError: expected undefined to match object { stockAfter: 15, costAfter: '200.00' }` ใน `purchasing.e2e-spec.ts`)
  → เขียวอีกครั้งที่ [34811186231](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34811186231) (05:52) หลัง merge #125
- **ผลลัพธ์เชิง process:** branch protection บน `main` ถูกตั้ง **2026-09-15 (#186)** — ปัจจุบันตรวจด้วย
  `gh api …/branches/main/protection` ได้ `required_status_checks = ["flutter-ci-status","server-ci-status"]`, force-push ปิด
  หลังวันนั้น **ไม่มี `main` push ครั้งไหนแดงเพราะโค้ดที่ merge ทั้งที่ check แดงอีกเลย** (ดูสถิติ §1)
- **บทเรียน:** "revert ก่อน แก้ทีหลัง" ทำให้ main เขียวใน 7 นาที; และ red main ไม่ได้เสียแค่คนเดียว มันทำให้ทุก PR ที่รันพร้อมกันแดงไปด้วย

### 6. Lint/build/typecheck จับ "semantic merge conflict" สองแบบ
- **Stage:** Lint/typecheck/build
- **(ก) แก้ conflict ผิด — สองเวอร์ชันของไฟล์ต่อกัน:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34808127282 · 2026-09-14 05:01 · `c1fde039` (PR #119)
```
src/purchasing/purchasing.module.ts:18:8 - error TS1005: ':' expected.
src/purchasing/purchasing.module.ts:20:1 - error TS1136: Property assignment expected.
```
  (ไฟล์ที่ `c1fde039` มี `exports: [PurchasingService],` แล้วตามด้วย `import { DocumentsModule } …` ต่อท้ายทันที) → `5f59ade` *"resolve module merge conflicts in purchasing and app module"*
- **(ข) สอง PR ที่ต่างคนต่างถูก แต่รวมกันแล้ว compile ไม่ผ่าน:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34809395626 · 05:22 · `7ec3379b` (PR #125, #32 cache invalidation)
```
src/purchasing/purchasing.service.ts(606,33): error TS2339: Property 'invalidateCache' does not exist on type 'ProductsService'.
```
  PR #119 (purchasing) เรียก `productsService.invalidateCache()` ขณะที่ PR #125 ย้ายการ invalidate ไปไว้ที่ `TenantCache`
- **Fix:** `9034111` *"fix(server): adapt purchasing service and controller for cache invalidation and byId query (#32 review)"* (PR #125)
```diff
-    onTransactionCommit(() => {
-      void this.productsService.invalidateCache(tenantId);
-    });
+    this.cache.invalidateAfterCommit(tenantId, 'products');
```
- **เขียว:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34810109309 (branch) และ `main` https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34811186231
- **บทเรียน:** CI รันบน merge ref (PR + main ล่าสุด) จึงเห็นการชนกันระหว่าง PR ที่ reviewer มองไม่เห็นจาก diff ของ PR เดียว

### 7. Schema e2e จับ migration ที่ลงทะเบียนผิดลำดับ
- **Stage:** Integration/e2e (`test/schema.e2e-spec.ts` — `down()` ทุก migration จนว่าง แล้ว `up()` ใหม่)
- **แดง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35187028186 · 2026-09-17 05:45 · `ac3da4fe` (PR #309)
```
FAIL  test/schema.e2e-spec.ts > … > down() reverses every migration back to an empty schema, and up() re-applies cleanly
    "ProductsPartNoCaseInsensitive1788652800007",
-   "CustomersMechanicsSyncIndex1788652804000",
    "AppRoleTransactionCeiling1788652802131",
 …
    "OwnerReviewItems1788652803002",
+   "CustomersMechanicsSyncIndex1788652804000",
```
- **Root cause [อนุมานจาก diff ของ test + commit `merge fix` ที่ไม่มี message อธิบาย]:** หลัง merge migration ใหม่ (timestamp `…804000`) ถูกแทรกกลาง list `MIGRATIONS` แต่ TypeORM รันตาม timestamp — ลำดับที่เขียนไว้กับลำดับที่รันจริงไม่ตรงกัน
- **Fix:** `d8fdea3` "merge fix" — ย้าย `CustomersMechanicsSyncIndex1788652804000` ไปท้าย list ใน `server/src/db/data-source.ts`
- **เขียว:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35187874823 (13 นาทีต่อมา)
- **บทเรียน:** test ที่ "ย้อน migration ทั้งหมดแล้วรันใหม่" ราคาถูกมากเมื่อเทียบกับการเจอบน production DB

### 8. e2e ภายใต้ concurrency จับ race: เปิดกะพร้อมกันได้ 4 กะ
- **Stage:** Integration/e2e (`test/rate-limit-pool.e2e-spec.ts` — burst ใหญ่กว่า DB pool)
- **แดง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35330582864 · 2026-09-18 09:38 · `e7c4b836` (PR #311 multi-shift)
```
FAIL  test/rate-limit-pool.e2e-spec.ts > … > answers a cold-cache burst larger than the pool with no 500 and no connect timeout
AssertionError: expected 4 to be 1 // Object.is equality
 ❯ test/rate-limit-pool.e2e-spec.ts:109:60
    109|     expect(new Set(opens.map((r) => r.body.data.id)).size).toBe(1);
```
- **Root cause:** feature "หลายกะต่อวัน" ทำให้คำขอ open-shift พร้อมกันหลายตัวต่างคนต่างสร้างกะใหม่ — lock บนแถว `devices` เป็นแค่ `FOR SHARE` ไม่ serialize กัน
- **Fix:** `891a886` *"fix(shifts): serialize open on device row and pass id in rate-limit pool test (#282)"* (PR #311)
```diff
-          FOR SHARE`,
+          FOR NO KEY UPDATE`,
 …
-      .send({ startingCash: '1000.00' });
+      .send({ id: 'sh-162-pool', startingCash: '1000.00' });
```
- **เขียว:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35333766495
- **หมายเหตุตรง ๆ:** fix นี้มีสองส่วน — lock จริงในโค้ด **และ** แก้ test ให้ส่ง `id` เดียวกัน (ตาม semantics ใหม่ที่ id ซ้ำ = กะเดิม) จึงควรเล่าว่าเป็นทั้ง bug fix และ test update
- **แก้ไขภายหลัง (2026-09-30, ตรวจซ้ำจาก diff ของ `891a886`):** root cause ข้างบนเล่าเกินหลักฐาน ใน run ที่แดง test ยิงเปิดกะ **โดยไม่ส่ง `id`** และทุก request ได้ 200 — ตามกติกาใหม่ของ #282 การเปิดกะโดยไม่มี `id` = ปิดกะเก่าแล้วเปิดใหม่ ดังนั้น expectation "ได้ 1 กะ" มาจากกติกาเดิม ("วันเดียวกัน = คืนกะเดิม") ไม่ใช่หลักฐานของ race ส่วน lock `FOR NO KEY UPDATE` ปิดช่อง insert ชนกัน (`shifts_pkey` / `uq_shift_active`) ตามที่ commit message บอก แต่การชนนั้นไม่ได้ปรากฏใน run ที่แดง — เรื่องนี้จึงถูกถอดออกจากสไลด์หลัก

### 9. e2e จับ API ที่ยอมรับ `id` จาก client ทั้งที่เป็น server-owned field
- **Stage:** Integration/e2e (`test/people.e2e-spec.ts`)
- **แดง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35348785644 · 2026-09-18 13:11 · `4278293c` (PR #313)
```
FAIL  test/people.e2e-spec.ts > customers and mechanics (e2e) > starts customer codes at CUS001 and forces server-owned fields to zero/new values
AssertionError: expected 'client-id' not to be 'client-id' // Object.is equality
 ❯ test/people.e2e-spec.ts:83:39
```
- **Fix:** `a2735d5` *"fix(people): ignore client id in online POST /customers"*
```diff
   return {
-    id: optionalString(value.id, 'id'),
     name,
```
- **เขียว:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35350928119 (22 นาทีต่อมา)
- **บทเรียน:** negative test ("server ต้องไม่เชื่อ field นี้") คือสิ่งที่กันไม่ให้ client เขียน primary key เองบน API ที่เปิดออนไลน์

### 10. BullMQ backoff: fix รอบแรกแดงใน CI แล้ว reviewer ได้ fix ที่ง่ายกว่า
- **Stage:** Integration/e2e
- **แดง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34929909797 · 2026-09-15 04:43 · `cda510e0` (PR #205, issue #201)
```
FAIL  test/backoff-strategy.e2e-spec.ts [ test/backoff-strategy.e2e-spec.ts ]
Error: Missing required environment variable DATABASE_URL
 ❯ required src/config/config.ts:36:17
```
- **บริบท:** บั๊กต้นทาง (#201) ก่อนหน้านั้นโผล่ใน log ให้เห็นอยู่แล้ว — `Error: Unknown backoff strategy exponential-jitter.` พบใน log ของ 5 run ที่ fail ด้วยสาเหตุอื่น
  (เช่น [34803327162](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34803327162)) แต่ไม่มี test ไหน assert มัน **[ไม่ได้ตรวจ log ของ run ที่เขียว]**
- **Fix:** `298cdae` *"fix(server): use BullMQ's builtin exponential+jitter backoff instead of a custom type"* — ลบ custom strategy ทิ้ง (-173/+56 บรรทัด)
  ใช้ `{ type: 'exponential', delay: 1000, jitter: 1 }` ที่ BullMQ มีอยู่แล้ว และแก้ e2e ให้ `loadConfig()` ใช้ค่า default แบบเดียวกับ e2e อื่น
  commit message ระบุว่ามี "falsification run" — ย้อน fix แล้ว test ต้องแดง
- **เขียว:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34930940551 (16 นาทีต่อมา)
- **บทเรียน:** warning ใน log ที่ไม่มี test จับ = บั๊กที่มองไม่เห็น; และ CI สีแดงบน fix ครั้งแรกเปิดโอกาสให้ review หาทางที่เรียบง่ายกว่า

### 11. Workflow/config errors — gate ที่พังเอง
- **Stage:** Workflow config / env
- **(ก) status job หา directory ไม่เจอ:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34803324403 · 2026-09-14 03:39 · `ab81b73e` (PR #110, ci.2 path filters)
```
##[error]An error occurred trying to start process '/usr/bin/bash' with working directory
  '/home/runner/work/srisurart-pos-flutter/srisurart-pos-flutter/frontend'. No such file or directory
```
  → `3b179ac` *"fix(ci): status jobs run from the workspace root (#39)"* — status job ไม่มี checkout จึงไม่มี `frontend/`
```diff
     if: always()
+    defaults:
+      run:
+        working-directory: .
```
  เขียว: Flutter [34807242347](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34807242347) / Server [34807242350](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34807242350)
- **(ข) secret ที่จำเป็นไม่มีใน CI:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34429654246 · 2026-09-10 02:29 · `ba2ca2c3` (PR #57 JWT auth)
```
error while interpolating services.api-2.environment.JWT_PRIVATE_KEY: required variable JWT_PRIVATE_KEY is missing a value
```
  และรอบถัดมา https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34429953474: `Error: Missing required environment variable JWT_PRIVATE_KEY` ใน `health.e2e-spec.ts`
  → `09a7180` *"fix(test): inject dummy JWT keys to health e2e config"* (`+JWT_PRIVATE_KEY: 'dummy'`) → เขียว [34430298663](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34430298663)
  (อีก run ใน branch เดียวกัน [34436714006](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34436714006) 04:19 — log โหลดได้ (แก้ 2026-09-29): `idempotency.e2e-spec.ts` แดงด้วย `Missing required environment variable JWT_PRIVATE_KEY` — เป็น merge จาก `main` ที่พาไฟล์ e2e ตัวใหม่มา ไม่ได้ถูกแก้ด้วย `09a7180`)
- **บทเรียน:** config ที่ "fail loud" (`:?` ใน compose, `required()` ใน config.ts) ทำให้ลืม secret แล้วแดงทันที แทนที่จะรันด้วยค่าว่าง

### 12. สอง PR เขียวทั้งคู่ แต่ `main` แดงหลัง merge (#483 × #484)
- **Stage:** Unit test (`flutter test`)
- **แดงบน `main`:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36364298501 · 2026-09-28 01:00 · `8c751f9c` (merge #484)
  ตามด้วย [36364375244](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36364375244) (#482), [36364712624](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36364712624) (#485)
  และ PR [36364874265](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36364874265) (#486)
```
sync_discard_reversal_test.dart: discard sale.create serverHasRow=false: stock, customer and mechanic return to before [E]
  ต้องเชื่อมต่ออินเทอร์เน็ตหนึ่งครั้งเพื่อเตรียมเลขเอกสารก่อนใช้งานออฟไลน์
  package:srisurart_pos/data/repositories/api/api_sales_repository.dart 494:28  ApiSalesRepository._saveOffline.<fn>
```
  (6 test แดงด้วยข้อความเดียวกัน)
- **Root cause (จาก commit ที่แก้):** #484 ลบ fallback `docNo('RC')` — offline sale บนเครื่องที่ยังไม่ seed ต้อง throw `OFFLINE_SEED_REQUIRED`
  ส่วน test ของ #483 เขียนโดยพึ่ง fallback เดิมและ merge ไปก่อน ตรวจแล้ว: #483 และ #484 มี `flutter-ci-status = SUCCESS` ทั้งคู่ตอน merge
- **Fix:** `96b9bc7` *"test(sync): seed the device in discard sale.create tests (main red after #483 x #484) (#487)"*
```diff
+    // #472: an offline RC needs a seeded device (no docNo('RC') fallback).
+    setUp(() async {
+      final numbers = DocNumberService(db: db);
+      await numbers.recordSeedMarker(deviceId: 'dev-1', period: period);
```
- **เขียว:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36365376544 · 01:16 — `main` แดง ~16 นาที
- **บทเรียน:** branch protection ของเราบังคับ "check ผ่าน" แต่ **ไม่ได้บังคับ "branch ต้อง up-to-date กับ main"** (`required_status_checks.strict` / merge queue) ช่องนี้ยังเปิดอยู่
  (ตรวจแล้ว: `gh api …/branches/main/protection --jq .required_status_checks.strict` = `false`)

---

## 3. ด้านที่ไม่สวย: flaky, false positive, และ gate ที่แดงโดยไม่ได้แปลว่าโค้ดเสีย

### F1. e2e แดงเพราะ per-IP login rate limit (SHA เดียวกัน แดงหนึ่ง เขียวหนึ่ง)
- **แดง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36307728361 · 2026-09-27 08:55 · `281e92c1` (PR #448)
```
FAIL  test/owner-password.e2e-spec.ts > owner password lifecycle v2 (#443 PR3) > reset: new 24 h temp password, …
AssertionError: expected 429 to be 200 // Object.is equality
```
- **หลักฐานว่า flaky:** SHA เดียวกัน `281e92c1` event เดียวกันอีก run หนึ่ง **เขียว** — https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36307728087
- **Root cause (จาก commit ที่แก้):** ไฟล์นี้ login 13 ครั้งจาก IP เดียว ขณะที่ throttle ต่อ IP คือ 10/60 s และ bucket ใน Redis ใช้ร่วมกับ e2e ทุกไฟล์ → แดงหรือเขียวขึ้นกับลำดับการรัน
- **De-flake:** `7a1f991` *"test(e2e): give owner-password logins their own source IP (#449 CI)"* (commit นี้อยู่ใน branch `feat/443-pr4-platform-ui` ซึ่งเป็น head ของทั้ง PR #448 และ #449)
```diff
+      .set('X-Forwarded-For', `198.18.${Math.floor(Math.random() * 250)}.${(ipSeq++ % 250) + 1}`)
```
  per-username throttle ยังทำงานตามเดิม — แก้ที่ test isolation ไม่ได้ปิด security control; ภายหลังถูกบันทึกเป็นกฎใน CLAUDE.md ("An e2e file that logs in more than 10 times must send its own `X-Forwarded-For`")
- **บทเรียน:** state ที่แชร์ข้าม test (Redis bucket) = ต้นเหตุ flaky อันดับหนึ่ง

### F2. Unit test จับเวลา `ttl ≤ 3600` แดงเป็นระยะบน `main` — **ยังไม่ได้แก้**
- **แดง 4 ครั้งบน `main` push** (ทุกครั้งอยู่ใน PR ที่ไม่เกี่ยวกับ auth เลย):
  [36333500265](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36333500265) (09-27, #467),
  [36365376503](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36365376503) (09-28, #487),
  [36415121261](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36415121261) (09-28, #504),
  [36531369102](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36531369102) (09-29, #505)
```
FAIL  src/platform/platform-auth.service.spec.ts > PlatformAuthService token TTL > issues a token that expires in 1 hour, not 24
AssertionError: expected 3601 to be less than or equal to 3600
```
- **Root cause (อ่านจากโค้ด):** test จด `before = Math.floor(Date.now()/1000)` แล้วเรียก `login()` ซึ่งทำ argon2 verify (ความยาวจริงไม่ได้วัดจาก log — เห็นแค่ `rejects invalid password 335ms` ใน spec อื่น **[ยังไม่ได้ตรวจสอบ]**)
  ส่วน service คำนวณ `exp: Math.floor(Date.now() / 1000) + PLATFORM_TOKEN_TTL_SEC` (`server/src/platform/platform-auth.service.ts:97`) —
  ถ้า argon2 คร่อมขอบวินาที `exp - before` = 3601 เสมอ
- **สถานะ:** `server/src/platform/platform-auth.service.spec.ts:87` บน `origin/main` (`c8383a7`) ยังเป็น `toBeLessThanOrEqual(3600)` — **flake ยังอยู่**
  ข้อเสนอ: เทียบ `exp - iat` ใน payload แทน หรือยอม `≤ 3601` **[ข้อเสนอ ยังไม่ได้ทำ]**
- **บทเรียน:** นี่คือตัวอย่างว่า "เขียวแล้วผ่าน re-run" ไม่ใช่การแก้ — ต้องยอมรับตรง ๆ ว่ายังมี flaky test ค้างอยู่หนึ่งตัว

### F3. Push image เข้า GHCR ล้ม `unknown blob` — ไม่ใช่โค้ด
- **แดง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35566947175 · 2026-09-21 06:05 · `a2fd0052` (merge #368) job `server image → GHCR`, step `push <sha> and main`
```
34884abbe928: Layer already exists
unknown blob
##[error]Process completed with exit code 1.
```
- **ถัดไป:** push บน `main` ถัดมา `f4a488b7` เขียว https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35567503920 — ระหว่างสอง SHA มีแค่ commit เอกสาร (`10c8842`, `3fc3773`)
  จึงสรุปว่าเป็นปัญหาชั่วคราวฝั่ง registry **[อนุมาน — ไม่มี log ฝั่ง GHCR]**
- **ข้อดีของ gate:** status job ถูกออกแบบให้ "release image ที่ไม่ได้ push บน main = แดง" (`::error::build-image did not run on a main push`) จึงไม่มีทางเงียบ

### F4. Dependabot เปิด 4 PR พร้อมกัน — CI แดงทั้ง dependency resolution และ build
- **แดง:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34308952999 (PR #48 Flutter 7 packages)
```
So, because srisurart_pos depends on both flutter_test from sdk and build_runner ^2.16.1, version solving failed.
```
  และ https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/34308879323 (PR #47 server dev-deps)
```
Error  The installed TypeScript version (7.0.2) does not expose the programmatic compiler API that the Nest CLI requires.
```
- **Fix:** ปิด #45–#48 ทั้งหมด (2026-09-09 04:02) และ `ed98cd5` *"ci: dependabot is security-updates-only, not a weekly version-bump bot"* — `open-pull-requests-limit: 0`
  (ปิด version update แต่ security update ยังเปิด) ส่วน CVE gate ที่ทำให้ build แดงจริงคือ `audit` (pnpm audit + Trivy fs) และ `deps-audit` (OSV-Scanner)
- **บทเรียน:** CI ป้องกันไม่ให้ bump ที่พัง merge เข้ามาได้ แต่ bot ที่เปิด PR ไม่หยุดก็เป็น noise — ทีมเลือกให้การ upgrade เป็นงานที่มนุษย์กำหนดเวลาเอง

### F5. Deploy "failure" ครั้งเดียว = reviewer ปฏิเสธโดยตั้งใจ, cancelled 176 ครั้ง = concurrency
- **Run:** https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/35702075158 · สร้าง 2026-09-22 07:55 · `d3a28018` · job `deploy to demo` (runs-on `[self-hosted, srisurart-demo-deploy]`) ไม่มี step รันเลย จบ 2026-09-28 11:00
  log: `log not found` — แต่ `gh api …/runs/35702075158/approvals` ให้:
```
{"state":"rejected","user":"NuimanLP","envs":["demo"],
 "comment":"Superseded by 303bb83; rejecting stale d3a2801 so the older SHA is never shipped first."}
```
  นี่คือ **manual approval gate ของ environment `demo` (#366) ทำงานตามที่ออกแบบ** — กันไม่ให้ SHA เก่าถูก deploy ก่อน SHA ใหม่
- **Cancelled 176 / 368:** ตัวอย่างที่เปิดดู `resolve release` = success, `deploy to demo` = cancelled; job deploy มี `concurrency` กับ `cancel-in-progress: false`
  ตามเอกสาร GitHub งานที่ *pending* ใน concurrency group เดียวกันจะถูก cancel เมื่อมีงานใหม่เข้าคิว **[อนุมานจากพฤติกรรมที่เอกสารระบุ — ไม่ได้เปิดดูทั้ง 176 run]**
- **ข้อควรระวังเวลาพรีเซนต์:** Deploy (demo) ที่ "success" 181 run **ไม่ได้แปลว่า deploy ไป 181 ครั้ง** — job `deploy` ถูก gate ด้วย `images_ready` และถ้า image ยังไม่ครบ run จะจบ success ทั้งที่รันแค่ `resolve release`
  (กฎนี้บันทึกไว้ใน CLAUDE.md) และ self-hosted runner ยังไม่ได้ติดตั้ง (0 runners ตาม CLAUDE.md, verified 2026-09-23) ส่วน CD ไป VM ติดที่ FortiGate ของคณะ

---

## 4. ภาพรวมบทเรียน (สำหรับสไลด์)

1. **e2e กับ DB/Redis จริงจับบั๊กที่สำคัญที่สุด** — 28 จาก 50 run แดงมาจาก integration และหลายเรื่องเป็นบั๊กจริงที่ unit test (mock) ผ่าน: rate limit ไม่ทำงาน (3), race เปิดกะซ้ำ (8), รับ id จาก client (9), migration order (7)
2. **gate ต้องบังคับ** — ก่อน 2026-09-15 มี PR ที่ merge ทั้งที่แดง 2 ตัวและ push ตรง 2 ครั้ง (เรื่อง 4, 5); หลังเปิด branch protection Server CI fail rate ลดจาก 11.7% → 2.5% (สัมพันธ์กันตามเวลา — ไม่ได้พิสูจน์ว่า protection เป็นสาเหตุเดียว ทีมก็เรียนรู้ไปพร้อมกัน) และไม่มี main แดงเพราะโค้ดที่ merge ทั้งที่ check แดงอีก
3. **merge ref ≠ PR head** — CI รัน PR บน merge กับ main จึงจับการชนระหว่าง PR ได้ (6ข) แต่ถ้า main เปลี่ยนหลัง CI ของ PR เสร็จ ยังหลุดได้ (12)
4. **Flaky ต้องแก้ที่ต้นเหตุ** — F1 แก้แล้วด้วย test isolation; F2 **ยังค้างอยู่** และเป็นสาเหตุเดียวของ Server CI บน `main` แดง 4 ครั้งล่าสุด (Flutter CI บน main แดง 3 ครั้งเมื่อ 09-28 01:00 จากเรื่อง 12 อยู่ระหว่างนั้น)
5. **"เขียว" ไม่ได้แปลว่า "พิสูจน์แล้ว"** — Deploy success ≠ deployed (F5), security gate ยังไม่เคยแดงในประวัติ (§1)

---

## 5. แหล่งที่มา (ตรวจซ้ำได้)

- Run history: `gh run list --workflow <id> --limit 2000 --json databaseId,headSha,headBranch,event,createdAt,conclusion,status,displayTitle,url`
  (workflow id: Flutter CI `350023540`, Server CI `351601043`, Deploy (demo) `358758196`, Dependabot Updates `353682745`);
  ยืนยันจำนวนด้วย `gh api repos/NuimanLP/srisurart-pos-flutter/actions/workflows/<id>/runs?per_page=1 --jq .total_count` = 667 / 743 / 368
- Failed jobs/steps: `gh run view <id> --json jobs`; error lines: `gh run view <id> --log-failed` (โหลดได้ 49/50; `35702075158` log not found — ไม่มี step รัน)
- เวลาแดง→เขียว: run `success` ถัดไปบน `headBranch` + `event` เดียวกัน; commit ที่แก้: `git log --no-merges <failSha>..<greenSha>`
- PR ของแต่ละ commit: `gh pr list --state all --search <sha>`; สถานะ check ตอน merge: `gh pr view <n> --json statusCheckRollup,mergedAt`
- Branch protection ปัจจุบัน: `gh api repos/NuimanLP/srisurart-pos-flutter/branches/main/protection`; วันที่เปิด (2026-09-15, #186): `docs/handoff_log/claude-md-full-history-archive-2026-09-17.md:278`
- Deploy approval: `gh api repos/NuimanLP/srisurart-pos-flutter/actions/runs/35702075158/approvals`
- Commit ที่อ้างถึง: `2a5c697`, `f56e904`, `54e44e2`, `548aefa`, `1eb2020`, `8aea5e3`, `d0a8f7c`, `114a7e8`, `776f05f`, `af7d6b6`, `0d9e17c`, `5f59ade`, `9034111`,
  `d8fdea3`, `891a886`, `a2735d5`, `298cdae`, `3b179ac`, `09a7180`, `96b9bc7`, `7a1f991`, `ed98cd5`

---

## 6. Fact-check 2026-09-29

ตรวจซ้ำแบบ adversarial ด้วย `gh run list --json` (คำนวณสถิติใหม่ด้วยสคริปต์), `gh run view --json jobs`, `gh run view --log-failed` + grep, `gh pr view`, `git show` ของ commit ที่อ้างถึง

**ผ่านการตรวจ (verified):**
- สถิติใน §1 ทั้งตาราง: จำนวน run / completed / failure / rate / cancelled (667/743/368 → 12/37/1), แยกก่อน-หลัง 09-15 (Flutter 128/3 → 530/9, Server 206/24 → 518/13), main push แดง 3/265 และ 9/291 (รายชื่อ run ตรงกับที่อ้าง), Dependabot 4 run 0 fail, ช่วงวันที่ของแต่ละ workflow
- ตาราง stage 50 run (28+10+4+2+2+2+1+1) — นับซ้ำจาก job/step ที่ fail ของทั้ง 50 run ได้ตรงกัน
- ทุก run ID ที่อ้าง (61 ตัว): conclusion / SHA / วันที่ตรงกับ `gh run list`; บรรทัด error สำคัญของเรื่อง 1–12 และ F1–F4 ปรากฏจริงใน `--log-failed` ของ run นั้น
- commit แก้ทั้ง 22 ตัวมีอยู่จริงและมี diff ตามที่เล่า (รวมถึง `-FOR SHARE`/`+FOR NO KEY UPDATE`, `+ANALYZE`, `-optionalString(value.id …)`, `+recordSeedMarker`, `open-pull-requests-limit: 0`); PR ↔ SHA ตรงกัน (#58, #77, #88, #125, #205, #309, #310, #311, #313, #334, #86, #119, #483, #484)
- run เขียวหลังแก้ทุกตัวเป็น `success` บน SHA ของ commit แก้ (หรือ merge ของมัน)
- ระยะเวลา: main แดง 2 ชม. 10 นาที (09:25:26 → 11:35:31) ✓; revert เขียวใน 7 นาที ✓; 16 นาที (เรื่อง 10 และ 12) ✓; 14 / 13 / 22 นาที (เรื่อง 2 / 7 / 9) ✓
- #86 และ #119 merge ทั้งที่ check แดง (statusCheckRollup ยืนยัน), #483/#484 merge ตอน `flutter-ci-status` SUCCESS ✓, `strict=false` ✓, F1 SHA เดียวกัน แดง 1 เขียว 1 ✓, F5 approval `rejected` + comment ✓

**แก้ไขแล้วในเอกสาร (corrected):**
1. เรื่อง 5: "16× TypeError ใน 4 ไฟล์ e2e" ผิด — จริงคือ 16 TypeError กระจายใน **22 จาก 23** ไฟล์ e2e ที่ fail
2. เรื่อง 4: "PR นี้ไม่มีไฟล์ `reports.e2e-spec.ts` ใน head" ผิด — ไฟล์มีอยู่ใน tree ของ head (blob เดียวกับ main); ที่ถูกคือ diff ของ PR #84 ไม่แตะไฟล์นี้
3. เรื่อง 2: `8aea5e3` แก้ **6** ไฟล์ (เดิมเขียน 7)
4. เรื่อง 11(ข): log ของ run `34436714006` **โหลดได้** (เดิมเขียนว่าโหลดไม่ได้) — `idempotency.e2e-spec.ts` แดงด้วย `JWT_PRIVATE_KEY` missing และเป็น run หลังจาก merge `main` ไม่ใช่ตัวที่ `09a7180` แก้; อัปเดต §5 เป็น "โหลดได้ 49/50"
5. §1: คอลัมน์ "Branch/PR ที่เคยแดง" 7 / 21 รวม `main` ด้วย (branch อื่นอย่างเดียว = 6 / 20) — ระบุแล้ว
6. §1: เพิ่มหมายเหตุวิธีวัด "แดง→เขียว" — ค่า max Server 1,341 นาทีคือ F2 บน `main` ที่ "เขียว" เพราะ push ถัดไป ไม่ใช่เวลาแก้ (ห้ามอ้างเป็น MTTR); ถ้าวัดถึง `updatedAt` ของ run เขียว ค่าเป็น 12.7/68.7 และ 24.1/1,346
7. F1: commit `7a1f991` อยู่ใน branch `feat/443-pr4-platform-ui` ซึ่งเป็น head ของ PR #448 **และ** #449 (เดิมเขียนแค่ #449)
8. §4 ข้อ 4: "main แดง 4 ครั้งล่าสุด" → "Server CI บน main" (Flutter main แดง 3 ครั้งเมื่อ 09-28 01:00 อยู่คั่นกลาง)
9. เรื่อง 6 หัวข้อ: run `34808127282` ล้มที่ทั้ง `pnpm lint` และ `pnpm build` (บรรทัด TS1005 มาจาก build) ไม่ใช่เฉพาะ `typecheck` — เปลี่ยนหัวข้อเป็น "Lint/build/typecheck"

**ตรวจไม่ได้ / ยังคงเป็นข้อสรุปเชิงอนุมาน (unverifiable):**
- เรื่อง 7: กลไก "TypeORM รันตาม timestamp" — commit `d8fdea3` ("merge fix") ไม่มีคำอธิบาย มีแค่ diff ของ test ที่ยืนยันว่าลำดับใน list ไม่ตรง → ติดป้าย [อนุมาน] แล้ว
- F2: ความยาว argon2 "~100–200 ms" ไม่มีใน log (เห็นแค่ 335 ms ของ test อื่น) → ติดป้าย [ยังไม่ได้ตรวจสอบ]; ตัวกลไก (ข้ามขอบวินาที → 3601) สอดคล้องกับโค้ดและ assertion แต่ไม่ได้ทดลองซ้ำ
- F3: สาเหตุ "registry ชั่วคราว" ยังเป็นอนุมาน (ไม่มี log ฝั่ง GHCR); F5: "176 cancelled มาจาก concurrency" ไม่ได้เปิดดูทั้ง 176 run
- เรื่อง 10/เรื่อง 1: คำอ้าง "falsification run" และ "cold build ลบ database.g.dart" มาจาก commit message ของผู้แก้เท่านั้น ไม่ได้รันซ้ำ
- Deploy (demo) มี run `skipped` 8 และ `in_progress/queued` 2 ที่ไม่อยู่ในตัวเลข "Completed 182" (ไม่กระทบตัวเลขที่อ้าง)
- ไม่ได้ re-run / approve / cancel workflow ใด ๆ
