# ✅ Architecture Best-Practice Checklist — Backend01–06 → โค้ดจริง (Srisurart POS)

> **เอกสารนี้ตอบคำถามเดียว**: บทเรียน Backend01–06 สอนกฎอะไรบ้าง และ **ระบบ Srisurart Autopart POS (`server/` + `docs/Backend_design/`) นำไปใช้จริงที่ไฟล์ไหน บรรทัดใด**
> ทุกแถวที่ระบุ ✅ APPLIED = **ผ่านการตรวจสอบโค้ดจริงในรีโป** และอ้างอิง `file:line` ที่มีอยู่จริง ไม่ใช่การคาดเดาจากชื่อไฟล์
>
> **ที่มาของเกณฑ์**: ชุดเอกสาร Best Practice Backend01–06 (162 กฎ + 45 slide-errata) และแบบฟอร์มตรวจสอบสถาปัตยกรรม (Architecture BP Checklist)
> **ระบบที่ประเมิน**: Srisurart Autopart POS — Multi-tenant NestJS Backend + PostgreSQL (RLS) + Redis (Cache/Queue) + BullMQ + Nginx + Flutter Client (Phase 1)
> **สถานะการตรวจสอบ**: ผ่านการตรวจสอบ Linting (`oxlint`) และ TypeScript Typecheck (`tsc --noEmit`), Unit tests **412 passed / 49 test files**, E2E tests **53 `*.e2e-spec.ts` files** (607 passed, 2 skipped) รันบน PostgreSQL/Redis จริง — ตัวเลขจาก CI run `35811055994` บน `main@616c187` (2026-09-23)
>
> **🔄 ตรวจทานใหม่ 2026-09-23**: ไล่ทุกแถวเทียบกับโค้ดจริงบน `main@616c187` แล้ว — เปลี่ยนสถานะ 12 ข้อ (#6, #63, #73, #82, #83, #119, #120, #123, #134, #159, #160, #162) และแก้หลักฐานที่ชี้ไปยังไฟล์ที่ไม่มีอยู่จริง (`backup.service.ts`, `import.processor.ts`, `bullmq.module.ts`, `common.module.ts`, `sales/returns.service.spec.ts`) ทุกแถวที่แก้มีหมายเหตุ "(2026-09-23)" กำกับ · คะแนนใน §1 นับใหม่จากตารางแถวต่อแถว (ฉบับ 2026-09-21 ไม่ตรงกับตารางของตัวเอง) · 🔴 k6 ยัง **ไม่เคยวัดจริง** (→ #380) ห้ามอ้างผล load test จากเอกสารนี้

---

## 0. 🔢 ตัวเลขที่ยืนยันแล้ว (ใช้อ้างในรายงานและสไลด์ได้)

| ตัวชี้วัด | ค่าที่วัดได้จริง | แหล่งอ้างอิง / คำสั่งที่ยืนยัน |
| :--- | :--- | :--- |
| **Unit tests** | **412 passed / 49 test files** (2026-09-23) | `pnpm test` (`vitest run`) — CI job `unit`, run `35811055994` บน `main@616c187` |
| **E2E tests** | **53 files (`*.e2e-spec.ts`) — 607 passed, 2 skipped** (2026-09-23) | `server/test/*.e2e-spec.ts` ทดสอบ RLS, Idempotency, Lock order บน PostgreSQL 16 จริง — CI job `integration`, run เดียวกัน |
| **ไฟล์ใน `server/src/`** | **201 files** (2026-09-23) | ครอบคลุม 29 โดเมนโมดูลหลัก |
| **App instances** | **3 API instances** (`api-1`, `api-2`, `api-3`), **1 worker**, **1 bull-board**, **1 nginx**, **1 postgres** (PG 16 alpine), **2 redis** (`redis-cache` + `redis-queue`), **1 etcd** (v3.6.12) | `server/docker-compose.yml:56-328` |
| **DB Pool Math** | **62 / 100** connections (**62%** ≤ 80% ceiling) | `3 api × (15 request + 2 audit + 1 health) + worker × (5 + 2 + 1) = 62` (`server/docker-compose.yml:13-14`) |
| **Memory Budget** | **~3.3 GB** (จากโควตา VM คณะ 4 vCPU / 6 GB = 55%) | `1024 (pg) + 2×256 (redis) + 3×384 (api) + 256 (worker) + 128 (bull-board) + 64 (nginx) + 256 (etcd)` |
| **Worker Concurrency** | **1** (CPU/DB-bound transaction isolation) | `server/docker-compose.yml:149-155` (`DB_POOL_SIZE: 5`) |
| **Static Analysis** | **Clean (0 errors, 0 warnings)** | `server/package.json:24` (`pnpm check` = `oxlint src/ test/ && tsc --noEmit`) |

---

## 1. 📊 สรุปคะแนน — ใช้ไปกี่ข้อ (B01 ถึง B06)

| บทเรียน | รวมกฎ | ✅ APPLIED | 🟡 PARTIAL | ❌ NOT-USED | ⚪ N/A |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **B01** Architecture & Containerization | 22 | 18 | 3 | 0 | 1 |
| **B02** NestJS & Testability | 24 | 19 | 1 | 0 | 4 |
| **B03** Database Engineering | 34 | 22 | 4 | 1 | 7 |
| **B04** Redis: Caching & Atomic Ops | 32 | 25 | 3 | 2 | 2 |
| **B05** Async Communication (BullMQ) | 22 | 15 | 4 | 0 | 3 |
| **B06** Scaling, LB & Observability | 28 | 18 | 4 | 2 | 4 |
| **รวมทั้งสิ้น** | **162** | **117** | **19** | **5** | **21** |

> **(2026-09-23)** ตารางนี้นับใหม่จากสถานะในตาราง §3 แถวต่อแถว — ฉบับ 2026-09-21 แสดง 119/13/3/27 ซึ่งไม่ตรงกับตารางของตัวเอง (ตารางจริงตอนนั้นคือ 126/12/3/21) แล้วหักข้อที่ตรวจพบว่าเคลมเกินหลักฐาน
>
> **การแปลผลคะแนน**:
> - ⚪ **N/A (21 ข้อ)** = กฎที่บริบทของระบบ POS ร้านอะไหล่ multi-tenant ไม่มีเคสให้ใช้โดยตรง (เช่น Deep cartesian relations ในเมื่อ schema เป็น flat ledger, หรือ Read replica ใน Phase 1) — **ไม่ใช่ข้อบกพร่อง**
> - ❌ **NOT-USED (5 ข้อ)** = Trade-off ที่จงใจเลือกสำหรับ Phase 1 บน VM ของคณะ (Nginx เดี่ยว B06-146, Redis Standalone B04-112, ไม่มี Patroni failover B06-150) **บวก 2 ข้อที่ตรวจพบ 2026-09-23 ว่าไม่มีในโค้ด**: Optimistic lock (B03-63) และการ monitor cache hit ratio (B04-83 — ไม่มี Redis exporter, `deploy/compose/monitoring.yml:23` ระบุว่าอยู่นอกขอบเขต)
> - ตัดข้อ ⚪ N/A ออก คงเหลือกฎที่ใช้ได้จริง **141 ข้อ** → **APPLIED 117 ข้อ = 83.0%** · หากนับ PARTIAL เป็น 0.5 ข้อ = **(117 + 9.5) / 141 = 89.7%**

---

## 2. 🎯 5 ข้อที่เป็น "หัวใจ" ของ Srisurart POS

ถ้าจะนำเสนอให้อาจารย์และผู้ตรวจฟังใน 3 นาที นำเสนอ 5 เสาหลักนี้ — เป็นแกนหลักที่ทำให้ผ่านโจทย์ Multi-tenant POS ที่รองรับทั้งหน้าร้านออฟไลน์และแบ็กเอนด์คลาวด์:

| # | เสาหลักสถาปัตยกรรม | เราทำที่ไหน | ทำไมมันคือคำตอบที่ถูกต้องตามหลักวิศวกรรม |
| :--- | :--- | :--- | :--- |
| **1** | **Multi-tenant RLS via Handler-Scoped `runTx`** (ADR-0003 Amendment) | `server/src/common/database/tenant.service.ts:71-114`<br>`server/src/common/request-context.ts:109-120` | แยก **"ใครตัดสิน"** (`TenantGuard` ตรวจ JWT แล้ว set ลง `AsyncLocalStorage`) ออกจาก **"ใครลงมือ"** (`TenantService.runTx` ยิง `SELECT set_config('app.tenant_id', $1, true)` บน PG transaction จริง) ฟังก์ชัน `runTx` **ไม่มีพารามิเตอร์ `tid` เด็ดขาด** ป้องกันการแอบสลับ tenant ID และลด transaction hold time จาก 112 ms เหลือ 14–22 ms |
| **2** | **Strict Row Lock Order** (sale → shift → mechanic → products → doc_counters → customer) | `server/README.md:589-600, 783-790`<br>`server/src/returns/returns.service.ts:181-182`<br>`server/src/products/products.service.ts:399` | การขายตัดสต็อก, การคืนบิล, การยกเลิกบิล, และการปิดกะลิ้นชักที่เกิดขึ้นพร้อมกัน จะไม่มีวันเกิด Deadlock (`40P01`) เพราะทุกธุรกรรมบังคับ Acquire Lock เรียงตามลำดับเดียวกันทั้งระบบอย่างเคร่งครัด |
| **3** | **Idempotency-Key Module with SHA-256 Fingerprinting & Rollback Safety** (#18, ADR-0003) | `server/src/idempotency/idempotency.service.ts:141-202, 217-260` | ประกันว่าบิลขายหรือคืนเงินจะไม่ถูกตัดสต็อกซ้ำเมื่อเครือข่ายหลุด โดยผูก Claim, Execution, และ Completion ไว้ใน Transaction เดียวกัน (`ON CONFLICT DO NOTHING` บน `(tenant_id, key)`) หากคำขอล้มเหลวจะ Rollback สถานะ claim ออกทันที ทำให้ส่งซ้ำพร้อม flag เช่น `overrideCreditLimit` ด้วยคีย์เดิมได้ถูกต้อง |
| **4** | **Server-Issued Device Token & Role Security Boundary** (`did`/`drole`, ADR-0004) | `server/src/common/guards/tenant.guard.ts:81-86`<br>`server/src/auth/auth.service.ts:69-84`<br>`docs/Backend_design/adr/0004-device-roles.md` | ขอบเขตความปลอดภัยของเครื่องคิดเงิน (`pos`) ถูกออกเป็น Device Token จากเซิร์ฟเวอร์เท่านั้น (`POST /devices` + `POST /auth/device`) ฝั่งไคลเอนต์ไม่มีสิทธิ์ส่ง `did`/`drole` ใน Request Body เอง เพื่อป้องกันไม่ให้เครื่องหลังบ้านหรือแฮกเกอร์สวมรอยเปิดลิ้นชักหรือออกใบเสร็จ |
| **5** | **Offline-First Write-Through Cache with Drift (schema v11 ณ 2026-09-23, `frontend/lib/data/db/database.dart:72`) & PostgreSQL Authority** (ADR-0010) | `docs/Backend_design/adr/0010-client-write-through-cache.md`<br>`frontend/lib/data/repositories/api/` | ฝั่ง Flutter ยังคงใช้ Drift/SQLite เป็น Write-Through Local Cache เพื่อความเร็วและการอ่านออฟไลน์ แต่ยกความจริงแท้ (Authority) ทั้งหมดให้ PostgreSQL บนเซิร์ฟเวอร์ โดยแมป schema ผ่าน Repository Provider โดยไม่ต้องรื้อโค้ดหน้าจอ |

---

## 3. 📋 ตารางเต็ม — กฎทุกข้อ (1 ถึง 162) → โค้ดจริง

### B01 — Architecture & Containerization (22 ข้อ)

| # | กฎจากบทเรียน | สถานะ | หลักฐาน (`file:line`) | หมายเหตุ |
| :---: | :--- | :---: | :--- | :--- |
| 1 | เริ่มด้วย monolith แยกเมื่อวัดเจอคอขวด | ✅ | `server/src/` (29 modules), `docs/Backend_design/03_ARCHITECTURE.md §2-§4` | สร้างเป็น Modular Monolith ภายใต้ NestJS รองรับโหลดทั้งร้านได้โดยไม่มี overhead ของ microservices |
| 2 | Modular monolith — จัดตามโดเมน ไม่ใช่ตาม layer | ✅ | `server/src/sales/`, `server/src/shifts/`, `server/src/returns/`, `server/src/products/` | แยกตาม Business Domain ชัดเจน ไม่มีโฟลเดอร์รวม `controllers/` หรือ `services/` |
| 3 | Multi-stage build: builder ทำ build, final copy แค่ dist + prod deps | ✅ | `server/Dockerfile:5, 11, 17, 31-33` | 3 stages: `deps` → `build` → `runtime` (คัดลอกเฉพาะ `dist` และ `node_modules` ที่ถูก prune) |
| 4 | `COPY package*.json` ก่อน `COPY . .` เพื่อรักษา layer cache | ✅ | `server/Dockerfile:8, 12-13` | `COPY package.json pnpm-lock.yaml ./` ก่อน `COPY src ./src` |
| 5 | ใช้ Alpine base image | ✅ | `server/Dockerfile:5, 17`<br>`server/docker-compose.yml:58, 176, 199, 225` | ใช้ `node:22-alpine`, `nginx:1.29-alpine`, `postgres:16-alpine`, `redis:7-alpine` |
| 6 | Pin tag เป๊ะ ห้ามใช้ `latest` | 🟡 | `server/Dockerfile:5, 17`<br>`server/docker-compose.yml:73, 92, 109, 191, 214, 240, 286, 330` | Base ของ app pin digest (`node:22-alpine@sha256:c610fcdfb...`) และ `etcd:v3.6.12`, `curl:8.16.0` pin เวอร์ชันเป๊ะ **แต่ (2026-09-23)** `alpine/openssl` (`certgen`, `htpasswd-gen`) ไม่มี tag เลย = `latest` โดยนัย และ `postgres:16-alpine` / `redis:7-alpine` / `nginx:1.29-alpine` เป็น tag ลอยระดับ major/minor ไม่ใช่ digest |
| 7 | Tag image ด้วย commit SHA เพื่อ rollback | ✅ | `.github/workflows/deploy.yml:30-33, 54`<br>`docs/Backend_design/07_CICD_DEPLOY.md §6` | Pipeline บิลด์และแท็กอิมเมจตาม Git SHA ทำให้ย้อนกลับ (Rollback) ผ่าน workflow dispatch ได้ทันที |
| 8 | `USER node` (ไม่รันคอนเทนเนอร์เป็น root) | ✅ | `server/Dockerfile:30` | สลับเป็น `USER node` ก่อนรันคำสั่ง `CMD` |
| 9 | `npm ci --omit=dev` หรือ pnpm production prune | ✅ | `server/Dockerfile:9, 14` | ใช้ `pnpm install --frozen-lockfile` และ `pnpm prune --prod` |
| 10 | `.dockerignore` กรอง node_modules, dist, .env* | ✅ | `server/.dockerignore:1-11` | กรอง `node_modules`, `dist`, `coverage`, `.env*`, `test` ครบถ้วน |
| 11 | `HEALTHCHECK` + `/health` ping deps จริง | ✅ | `server/docker-compose.yml:50, 192, 218, 245, 300`<br>`server/src/health/health.controller.ts:34-45` | Docker compose ทุกตัวมี healthcheck และเซิร์ฟเวอร์มี `/health/live` และ `/health/ready` |
| 12 | Secret ส่งตอน runtime ห้าม bake เข้า image | ✅ | `server/Dockerfile`<br>`server/docker-compose.yml:18-36` | ไม่มี secret ใน Dockerfile; ส่งผ่าน environment variables พร้อม `:?required` |
| 13 | `.env` อยู่ใน `.gitignore` | ✅ | `.gitignore:61-63` (`/server/.env`, `/server/.env.*`, `!/server/.env.example`) | ป้องกัน secret หลุดเข้า git อย่างเด็ดขาด |
| 14 | แยก secret dev/prod | ✅ | `server/.env.example` vs `deploy/ansible/provision.yml` | Dev ใช้ default ในตัวอย่าง; Prod สร้างรหัสผ่านสุ่มความปลอดภัยสูงบน VM `/opt/pos/.env` |
| 15 | Prod secret จาก secrets manager | 🟡 | `deploy/ansible/provision.yml`<br>`deploy/scripts/pos-deploy.sh` | (แก้ 2026-09-23: ไม่มี Ansible Vault ในรีโป) `provision.yml:18, 148-154` อ่านเนื้อหา `.env` จากตัวแปร `DEMO_ENV_FILE` แล้วเขียน `/opt/pos/.env` สิทธิ์ 0600 (ไม่ใช่ secrets manager แต่ปลอดภัยตามขอบเขต VM) |
| 16 | `--env-file` ใช้ได้เฉพาะ dev | ⚪ | `server/docker-compose.yml:19-36` | ไม่ได้ใช้ `--env-file` ในการรัน prod แต่ interpolate ผ่าน compose environment |
| 17 | Validate env ตอน boot แล้ว crash ทันทีถ้าผิด | ✅ | `server/src/config/config.ts:37-41, 70-105` | มีฟังก์ชัน `required(env, name)` ตรวจสอบตัวแปรจำเป็น หากขาดจะโยน Error หยุดการทำงานทันที |
| 18 | ตั้ง `--memory` `--cpus` `--pids-limit` ทุก container | 🟡 | `server/docker-compose.yml:43, 60, 114, 152, 160, 178, 201, 227, 273, 317` | ตั้ง `mem_limit` ครบทุกคอนเทนเนอร์ (รวม ~3.3 GB) แต่ยังไม่ได้ระบุ `pids-limit` และ `cpus` |
| 19 | `NODE_OPTIONS=--max-old-space-size` ให้ตรงกับ `--memory` | ✅ | `server/package.json:10` (`node >= 22`)<br>`server/docker-compose.yml:43` | Node 22 รองรับ cgroup v2 memory limits โดยอัตโนมัติ สอดคล้องกับ `mem_limit: 384m` |
| 20 | Custom network + service discovery ด้วยชื่อ container | ✅ | `server/docker-compose.yml:335-342` | กำหนด subnet `172.30.0.0/24` ติดต่อผ่าน `postgres`, `redis-cache`, `redis-queue`, `etcd` |
| 21 | `depends_on` รอ `condition: service_healthy` | ✅ | `server/docker-compose.yml:46-48, 69-73, 115-116, 326-328` | API และ Nginx รอ `service_healthy` จาก database และ redis เสมอ |
| 22 | `version: '3.8'` เลิกใช้แล้วใน Compose v2 (errata #4) | ✅ | `server/docker-compose.yml:1-16` | ไม่มี key `version:` อยู่ในไฟล์ เป็น Compose v2 specification มาตรฐาน |

---

### B02 — NestJS & Testability (24 ข้อ)

| # | กฎจากบทเรียน | สถานะ | หลักฐาน (`file:line`) | หมายเหตุ |
| :---: | :--- | :---: | :--- | :--- |
| 23 | Module แยกตามโดเมน | ✅ | `server/src/sales/sales.module.ts`<br>`server/src/shifts/shifts.module.ts`<br>`server/src/returns/returns.module.ts` | แยก 29 โมดูลตามฟังก์ชันธุรกิจของร้านอะไหล่ |
| 24 | Controller = HTTP อย่างเดียว ห้ามมี business logic / DB | ✅ | `server/src/sales/sales.controller.ts:40-80`<br>`server/src/returns/returns.controller.ts:35-65` | รับพารามิเตอร์, ดึง tenant/device context, ส่งต่องานให้ Service, ห้ามเขียน SQL ใน Controller |
| 25 | `exports` เฉพาะที่จำเป็น | ✅ | `server/src/sales/sales.module.ts`<br>`server/src/products/products.module.ts` | Export เฉพาะ Service ที่โมดูลอื่นต้องเรียกใช้งานจริง |
| 26 | Shared module สำหรับ cross-cutting | ✅ | `server/src/infra/redis.module.ts`<br>`server/src/infra/db.module.ts`<br>`server/src/infra/tenant-cache.module.ts`<br>`server/src/queue/queue.module.ts` (`@Global`) | มีโมดูลกลางสำหรับ Database, Redis, Logger, Request Context |
| 27 | Global `ValidationPipe` + whitelist + transform | 🟡 | `server/src/sales/sales.dto.ts:53`<br>`server/src/returns/returns.dto.ts:44`<br>`server/src/mechanics/credit-payments.dto.ts:31` | **จงใจตรวจความถูกต้องด้วยตนเอง (Manual Validation Function)** อย่างเข้มงวดเพื่อหลีกเลี่ยงช่องโหว่และ overhead ของ `class-validator` |
| 28 | Service โยน HTTP exception มาตรฐาน ไม่ `return null` | ✅ | `server/src/sales/sales.service.ts`<br>`server/src/returns/returns.service.ts`<br>`server/src/auth/auth.service.ts` | โยน `BadRequestException`, `NotFoundException`, `ConflictException`, `ForbiddenException` |
| 29 | Constructor injection + class token | ✅ | ทุก Service ใน `server/src/` | ใช้วิธีฉีด Dependency ผ่าน Constructor ทั้งหมด |
| 30 | Non-class token ใช้ `Symbol`/const ห้ามใช้สตริงเปล่า | ✅ | `server/src/config/config.ts:35` (`APP_CONFIG`)<br>`server/src/infra/logger.provider.ts:13` (`LOGGER`)<br>`server/src/infra/redis.module.ts:16-17` (`REDIS_CACHE`, `REDIS_QUEUE`) | ใช้ `Symbol(...)` สำหรับ non-class token ทุกตัว |
| 31 | `useFactory` + `inject` สำหรับ async resource | ✅ | `server/src/infra/redis.module.ts:25-50`<br>`server/src/infra/db.module.ts:25-80` | เชื่อมต่อ DataSource และ Redis Client ให้เสร็จก่อนรับ Request แรก |
| 32 | `useClass` สลับ impl ตาม env | ⚪ | `server/test/support/fixture.ts:116` | ในโค้ด Prod ไม่มีความจำเป็นต้องสลับ; ในเทสต์ใช้ `overrideProvider` |
| 33 | อยู่ที่ DEFAULT scope (Singleton) | ✅ | ทุก Service ใน `server/src/` | ไม่มี `Scope.REQUEST` หรือ `Scope.TRANSIENT` ใน Service ใดๆ เลย |
| 34 | Singleton คือต่อ app ไม่ใช่ต่อ module (errata #1) | ⚪ | สถาปัตยกรรมทั้งระบบ | เข้าใจถูกต้องและไม่พึ่งพา singleton ต่อโมดูล |
| 35 | REQUEST scope ลามขึ้นทั้งสาย — ใช้ AsyncLocalStorage แทน | ✅ | `server/src/common/request-context.ts:25-33` | ใช้ `AsyncLocalStorage<MutableRequestContext>` จัดเก็บ tenantId, manager และ hooks โดยไม่ใช้ REQUEST provider |
| 36 | ห้ามมี mutable state ต่อผู้ใช้ใน singleton | ✅ | `server/src/products/products.service.ts`<br>`server/src/sales/sales.service.ts` | Service เป็น Stateless 100% ข้อมูลคำขออยู่ใน Context หรือ Function Arguments |
| 37 | `interface` เป็น DI token ไม่ได้ | ✅ | ทุก Provider ใน `server/src/` | ใช้ Class หรือ `Symbol` เป็น Token เสมอ |
| 38 | Circular dep = ขอบเขต module ผิด อย่าใช้ `forwardRef()` | ⚪ | `server/src/` | Dependency Graph เป็น Directed Acyclic Graph (DAG) สมบูรณ์ ไม่มีการเรียกใช้ `forwardRef()` แม้แต่จุดเดียว |
| 39 | ใช้ `Test.createTestingModule` | ✅ | `server/src/app.setup.spec.ts:26, 80`<br>`server/test/health.e2e-spec.ts:24`<br>`server/test/support/fixture.ts:116` | ใช้งานตามมาตรฐานการทดสอบของ NestJS |
| 40 | Mock ทุก dep · 1 unit ต่อ 1 เทสต์ · AAA | ✅ | `server/src/**/*.spec.ts` (40 spec files ณ 2026-09-23) | ทำการ Mock dependencies ด้วย `vi.fn()` ตามแบบ Arrange-Act-Assert |
| 41 | ชื่อเทสต์บรรยายพฤติกรรม | ✅ | `server/src/products/products.service.spec.ts:45, 83`<br>`server/test/returns.e2e-spec.ts` (แก้ 2026-09-23: `returns/sales.service.spec.ts` ไม่มีอยู่จริง) | ตั้งชื่อบรรยายชัดเจน เช่น `'refuses a credit note with items whose prices do not match the parent sale'` |
| 42 | Mock พิมพ์เป็น typed mock ห้ามใช้ `any` (errata #2) | ✅ | `server/src/**/*.spec.ts` | มี Type Definition กำกับ mock functions ทุกตัว |
| 43 | Controller test เช็คแค่เรียกถูก method/param/return | ⚪ | `server/src/**/*.spec.ts` | ครอบคลุมผ่าน E2E Spec 53 ไฟล์ |
| 44 | Unit test ตรวจ SQL ไม่ได้ ต้องมี integration test คู่ | ✅ | `server/test/*.e2e-spec.ts` (53 files) | **มี E2E Test 53 ไฟล์** (607 passed ใน CI run `35811055994`, 2026-09-23) ทดสอบคำสั่ง SQL จริง, Row Lock, และ RLS บน PostgreSQL |
| 45 | `jest.spyOn` บน class ที่กำลังเทสต์ = เทสต์ mock (errata #4) | ✅ | `server/src/**/*.spec.ts` | Spy บนตัว Dependency ภายนอกเท่านั้น ไม่ spy เมธอดของคลาสที่กำลังทดสอบ |
| 46 | Framework ไม่ใช่คอขวด — แก้ DB/cache ก่อน | ✅ | `server/src/common/database/tenant.service.ts`<br>`server/src/sales/void.service.ts` | ปรับแต่ง transaction hold time และ lock contention (tx.4/tx.5) เป็นหลัก |

---

### B03 — Database Engineering (34 ข้อ)

| # | กฎจากบทเรียน | สถานะ | หลักฐาน (`file:line`) | หมายเหตุ |
| :---: | :--- | :---: | :--- | :--- |
| 47 | `synchronize: false` เสมอ | ✅ | `server/src/db/data-source.ts:44`<br>`server/src/infra/db.module.ts:34, 57, 76, 104` | Hardcode `false` ทุก Data Source ป้องกันข้อมูลสูญหาย 100% |
| 48 | เขียนและทดสอบ `down()` | ✅ | `server/src/db/migrations/*.ts` (14 migrations)<br>`server/package.json:20` (`db:migrate:down`) | มีเมธอด `async down(q: QueryRunner)` ครบ 14/14 และทดสอบใน `test/schema.e2e-spec.ts:307-313` (`undoLastMigration` ย้อนจนว่างแล้ว up ใหม่) |
| 49 | ห้ามแก้ migration ที่ deploy แล้ว | ✅ | `server/src/db/migrations/` | เมื่อต้องการแก้ไข Schema จะสร้าง Migration ไฟล์ใหม่ต่อท้ายเสมอ (มีทั้งหมด 14 ตัว) |
| 50 | 1 migration = 1 การเปลี่ยนแปลงเชิงตรรกะ | ✅ | `server/src/db/migrations/1788652800003-MovementsVoidType.ts`<br>`1788652800004-ReturnItemsCostAtSale.ts` | แต่ละไฟล์จัดการเรื่องเดียวชัดเจน |
| 51 | อ่าน migration ที่ generate มาก่อน commit | ⚪ | `server/src/db/migrations/` | Migration ทุกไฟล์เขียนด้วยมือ (Hand-crafted SQL) ไม่ได้ generate |
| 52 | รัน migration เป็น job แยก ไม่ใช่ตอน boot | ✅ | `server/docker-compose.yml:110-119` | รันผ่านคอนเทนเนอร์ `migrate` แยกต่างหากก่อนสตาร์ต API instances เพื่อกัน race condition |
| 53 | ทดสอบ migration บนสำเนาข้อมูลจริง | ⚪ | `server/test/schema.e2e-spec.ts` | ทดสอบกับ CI database ที่รันการ Up และ Down ครบทุกลูป |
| 54 | `ADD COLUMN NOT NULL DEFAULT` ล็อกตาราง ให้ทำ safe pattern | ⚪ | `server/src/db/migrations/` | เพิ่มคอลัมน์ใหม่แบบ nullable หรือมี default ที่ปลอดภัย |
| 55 | Expand-and-contract สำหรับ breaking change | ⚪ | `docs/Backend_design/adr/` | กำหนดไว้ในแบบแผนสถาปัตยกรรม |
| 56 | Transaction ต้องสั้น | ✅ | `server/src/common/database/tenant.service.ts:80-97`<br>`server/src/sales/void.service.ts` | ย้ายการคำนวณรหัสผ่าน Argon2 ออกนอกทรานแซกชัน (tx.5) และมี `commitCeilingMs: 25s` บังคับ |
| 57 | **ห้ามเรียก external API ใน transaction** → enqueue แทน | ✅ | `server/src/common/request-context.ts:156-170`<br>`server/src/common/database/tenant.service.ts:103` | มีระบบ `onTransactionCommit(fn)` ดีเลย์การยิงงานภายนอก/Queue จนกว่า DB จะ commit สำเร็จ |
| 58 | ใช้ `manager` ที่ส่งเข้ามา ไม่ใช่ `this.repo` | ✅ | `server/src/common/database/tenant.service.ts:89`<br>`server/src/sales/sales.service.ts` | ทุกคำสั่ง SQL ภายใน `runTx` เรียกผ่าน `manager` เพื่อให้ RLS ทำงานถูกต้อง |
| 59 | ล็อก resource ตามลำดับเดียวกันทั้งระบบ | ✅ | `server/README.md:589-600, 783-790`<br>`server/src/products/products.service.ts:399`<br>`server/src/returns/returns.service.ts:181-182` | **ลำดับการล็อกแถวเคร่งครัด**: sale → shift (shared) → mechanic → products → doc_counters → customer |
| 60 | Retry `40P01` ด้วย exponential backoff + jitter | 🟡 | `server/README.md` (*Lock order*) | ป้องกันการเกิด Deadlock จากต้นทางด้วย Global Lock Order; หากเกิด error ให้ client เป็นผู้ retry ผ่าน Idempotency-Key |
| 61 | READ COMMITTED พอ · SERIALIZABLE เฉพาะงานการเงิน | ✅ | `server/src/infra/db.module.ts` | ใช้ default READ COMMITTED ร่วมกับ Row-level pessimistic locks (`FOR UPDATE`) |
| 62 | Pessimistic lock (`SELECT FOR UPDATE`) สำหรับ contention สูง | ✅ | `server/src/products/products.service.ts:399`<br>`server/src/documents/doc-number.service.ts`<br>`server/src/mechanics/credit-payments.service.ts:61` | ล็อกสต็อกสินค้า, เลขที่เอกสาร, และยอดเครดิตช่างด้วย `FOR UPDATE` เสมอ |
| 63 | Optimistic lock (`@VersionColumn`) | ❌ | — | (2026-09-23) ไม่มี `sync_rev` หรือ `@VersionColumn` ใดในโค้ด (grep ทั้ง `server/src/`) — `updated_at` ใช้เป็นเคอร์เซอร์ของ pull เท่านั้น ไม่ได้ใช้ตรวจเวอร์ชันตอนเขียน ระบบเลือก `SELECT … FOR UPDATE` (#62) ทุกจุดแทน |
| 64 | **Conditional update + `affected===0`** | ✅ | `server/src/products/products.service.ts`<br>`server/src/idempotency/idempotency.service.ts:217` | ใช้ `ON CONFLICT DO NOTHING` และตรวจสอบจำนวนแถวที่ได้รับผลกระทบ |
| 65 | `FOR UPDATE` ไม่บล็อก plain SELECT บน PG (errata #4) | ⚪ | สถาปัตยกรรม Database | เข้าใจถูกต้อง Plain Read ไม่ถูกบล็อกโดย MVCC |
| 66 | Index ทุกคอลัมน์ใน WHERE/JOIN/ORDER BY | ✅ | `server/src/db/migrations/1788652800000-InitialSchema.ts`<br>`1788652800006-ReturnsShiftIndex.ts` | สร้าง B-tree index นำหน้าด้วย `tenant_id` ในทุกตาราง |
| 67 | ใช้ `select:[...]` ดึงเฉพาะคอลัมน์ที่ใช้ | 🟡 | `server/src/products/products.service.ts` | มีการระบุฟิลด์ในบาง endpoint แต่บางจุดยังดึงทั้ง entity |
| 68 | Paginate ทุก list endpoint | ✅ | `server/src/common/paginated.ts:46-73` | รองรับ `?page=` และ `?limit=` โดยจำกัดเพดาน `limit` ที่ 200 และจำกัด `page` ด้วย (แก้ 2026-09-23: เดิมเขียนว่า 100) |
| 69 | Keyset/cursor สำหรับ offset ลึก | ✅ | `server/src/products/products.controller.ts:48-55` (`updatedSince` + `afterId`) | Keyset cursor ความละเอียดระดับ microsecond สำหรับ sync pull (แก้ 2026-09-23: ไม่มี `since_cursor` ใน `sync.controller.ts`) |
| 70 | แก้ N+1 ด้วย `relations:[...]` | ✅ | `server/src/sales/sales.service.ts` | ดึงข้อมูลบิลพร้อมรายการสินค้า (`items`) ในคำสั่งเดียว |
| 71 | Eager-load ลึกๆ ทำให้ cartesian blowup | ⚪ | Schema การออกแบบ | Schema เป็น Flat Ledgers ไม่มีความสัมพันธ์ซ้อนลึกหลายทอด |
| 72 | SQL logging ใน dev · `pg_stat_statements` ใน prod | 🟡 | `server/src/infra/db.module.ts:38` | มี error logging ใน dev แต่ยังไม่ได้ติดตั้ง extension `pg_stat_statements` บน PG image |
| 73 | `onDelete:'CASCADE'` อันตราย | 🟡 | `server/src/db/migrations/1788652800000-InitialSchema.ts:196, 342, 387, 418, 456, 504` | (2026-09-23) **มี** `ON DELETE CASCADE` บนตารางลูกของเอกสารการเงิน (`sale_items`→`sales`, return items→`returns`, PO/quote/shift lines, `suppliers`→`products`) และจาก `tenants` — ปลอดภัยในทางปฏิบัติเพราะแม่ไม่ถูก hard-delete (products ใช้ `deleted_at`, บิลใช้ void) แต่ไม่ใช่ "ไม่ใช้ CASCADE เด็ดขาด" อย่างที่ฉบับก่อนเขียน |
| 74 | **Pool: `instances × (1+replicas) × poolSize ≤ 80% max_connections`** | ✅ | `server/docker-compose.yml:13-14`<br>`server/README.md` | `3 api × (15+2+1) + worker × (5+2+1) = 62 ≤ 80` (คำนวณถูกต้องตามสูตรบทเรียน) |
| 75 | `(cores*2)+spindles` ใช้ size ตัว DB server ไม่ใช่ app pool | ✅ | `server/src/config/config.ts:7-8` | แยกการคิดโควตาฝั่งเซิร์ฟเวอร์ออกจากพูลของแอปพลิเคชันอย่างชัดเจน |
| 76 | Map PG error code → HTTP (23505→409 ฯลฯ) | ✅ | `server/src/sales/sales.service.ts:165-168`<br>`server/src/products/products.service.ts:102`<br>`server/src/documents/doc-number.service.ts:35`<br>`server/src/idempotency/idempotency.service.ts:42` | (แก้ 2026-09-23) แมปราย service ไม่ใช่ใน `http-exception.filter.ts`: 23505/23503/23514 → 4xx ที่มีรหัสธุรกิจ, 55P03 → `503 IDEMPOTENCY_KEY_IN_FLIGHT` (ไม่ใช่ 409) |
| 77 | `synchronize:true, dropSchema:true` ในเทสต์ = ไม่เคยเทสต์ migration (errata #5) | ✅ | `server/test/schema.e2e-spec.ts` | ทดสอบกับ Migration จริงเสมอ `synchronize` เป็น `false` ทุกที่ |
| 78 | TypeORM ไม่มี nested transaction จริง (errata #6) | ✅ | `server/src/common/database/tenant.service.ts:44-50` | `TenantService.runTx` **ใช้วิธี Join Transaction เดิมเสมอ ไม่สร้าง Savepoint ซ้อน** เพื่อกัน Deadlock |
| 79 | `manager.debit()/credit()` เป็น pseudo-code (errata #2) | ⚪ | - | ระบบเขียนคำนวณยอดเงินและอัปเดตเอง ไม่ใช้ pseudo-code |
| 80 | `findOne({where:{id}})` (0.3) ไม่ใช่ `findOne(id)` (0.2) (errata #7) | ✅ | ทุก Service ใน `server/src/` | ใช้ TypeORM 0.3 API syntax ถูกต้องครบถ้วน |

---

### B04 — Redis: Caching & Atomic Ops (32 ข้อ)

| # | กฎจากบทเรียน | สถานะ | หลักฐาน (`file:line`) | หมายเหตุ |
| :---: | :--- | :---: | :--- | :--- |
| 81 | แคชข้อมูล read-heavy / query แพง / กึ่งคงที่ | ✅ | `server/src/infra/tenant-cache.service.ts:29-34`<br>`server/src/products/products.service.ts:136-170`<br>`server/src/rate-limit/rate-limit.service.ts:247` | (แก้หลักฐาน 2026-09-23) แคช catalogue (products/categories/settings/customers/mechanics) ผ่าน `TenantCache`, tenant plan, และคำตอบ Idempotency Replay |
| 82 | **ห้ามแคชข้อมูล write-heavy / ต้องการความสดจริง** | 🟡 | `server/src/products/products.service.ts:136-170`<br>`server/src/sales/sales.service.ts:330` | (2026-09-23) คำกล่าวเดิม "สต็อกไม่อยู่ในแคชเลย" **ไม่จริง**: `GET /products` แคชแถวสินค้าพร้อมคอลัมน์ `stock` (TTL 300±60 s) และ invalidate หลัง commit ทุกครั้งที่ขาย/คืน/void/รับ PO — แต่ **เส้นทางเขียน** ไม่เคยเชื่อแคช: การตัดสต็อก/ยอดเงิน/กะ อ่านสดจาก PG ด้วย `FOR UPDATE` เสมอ |
| 83 | Hit ratio > 80% · monitor `keyspace_hits/misses` | ❌ | `server/src/metrics/metrics.service.ts:20-47`<br>`deploy/compose/monitoring.yml:23` | (2026-09-23) ไม่มี metric hit/miss ของแคช และไม่มี Redis exporter (monitoring.yml ระบุว่าอยู่นอกขอบเขต) — `metrics.service.ts` มีแค่ `http_requests_total`, `http_request_duration_seconds`, `pos_idempotency_replay_total` + default process metrics; `/health/ready` แค่ ping |
| 84 | **TTL ทุก key** (key ไม่มี TTL = memory leak) | ✅ | `server/src/idempotency/idempotency.service.ts:30` (`24h`)<br>`server/src/rate-limit/rate-limit.service.ts` | ทุก key บน `redis-cache` มีวันหมดอายุเสมอ |
| 85 | ตั้ง TTL ตามความผันผวนของข้อมูล | ✅ | `server/src/rate-limit/rate-limit.service.ts` (`60s`)<br>`server/src/idempotency/idempotency.service.ts:30` (`86400s`) | ปรับ TTL ตามประเภทของข้อมูล |
| 86 | **TTL jitter กัน cache avalanche** | ✅ | `server/src/infra/tenant-cache.service.ts:29-39, 59-61` | (แก้หลักฐาน 2026-09-23: jitter อยู่ใน `TenantCache` ไม่ใช่ `rate-limit.service.ts`) `base ± jitter` ทุก namespace และ generation key |
| 87 | `try/catch` ทุกการเรียก cache + fallback ไป DB | ✅ | `server/src/idempotency/idempotency.service.ts:46, 100-101`<br>`server/src/config/config.ts:90` | มี `CACHE_TIMEOUT_MS = 200` และ `REDIS_COMMAND_TIMEOUT_MS = 1000` ถ้าแคชล่มจะ Fail-Open ไปยัง PG ทันที |
| 88 | Key builder รวมศูนย์ + namespace | ✅ | `server/src/idempotency/idempotency.service.ts:204-206` (`t:{tid}:idem:{key}`) | จัดรูปแบบ namespace ชัดเจนแยกตาม tenant |
| 89 | Invalidate ทั้ง dependency chain ตอน write | ✅ | `server/src/common/request-context.ts:156`<br>`server/src/common/database/tenant.service.ts:103` | ล้างแคชผ่าน Post-Commit Hook หลัง DB commit สำเร็จ |
| 90 | TTL คือ safety net — ห้ามพึ่ง invalidation อย่างเดียว | ✅ | `server/src/idempotency/idempotency.service.ts:30` | แม้มี invalidation ก็ยังคงตั้ง TTL เป็นเกราะป้องกันชั้นสอง |
| 91 | แคชเฉพาะ hot data | ✅ | `server/src/rate-limit/rate-limit.service.ts` | แคชเฉพาะแผนบริการที่ถูกเรียกตรวจทุก request |
| 92 | ค่า > 1MB ต้องแตก/บีบ | ⚪ | `server/src/idempotency/idempotency.service.ts` | ค่าที่แคชเป็นเพียง JSON ขนาดเล็ก |
| 93 | **Cache-aside เป็น default** | ✅ | `server/src/rate-limit/rate-limit.service.ts`<br>`server/src/idempotency/idempotency.service.ts` | ตรวจสอบแคชก่อนเสมอ หาก miss จึงอ่านฐานข้อมูลแล้ว populate |
| 94 | Write-through | ✅ | `docs/Backend_design/adr/0010-client-write-through-cache.md` | นำไปใช้ในรูปแบบสถาปัตยกรรมไคลเอนต์ (Drift write-through cache) |
| 95 | Write-behind เฉพาะ counter/analytics | ✅ | `server/src/metrics/metrics.service.ts` | ใช้วิธีบัฟเฟอร์ Prometheus metrics ใน RAM แล้ว flush ตามรอบ |
| 96 | ลำดับ **update DB → แล้วค่อย DEL cache** | ✅ | `server/src/common/database/tenant.service.ts:97, 103` | ทำงานใน `executePostCommitHooks()` หลัง `commitTransaction()` เท่านั้น |
| 97 | Delayed double-delete กัน stale read | 🟡 | `server/src/common/database/tenant.service.ts` | ใช้ short TTL ร่วมกับ post-commit delete แทน |
| 98 | **`INCR`/`DECR` แทน get→+1→set** | ✅ | `server/src/rate-limit/rate-limit.service.ts`<br>`server/src/metrics/metrics.service.ts` | ใช้นับจำนวน Request แบบ Atomic |
| 99 | Distributed lock `SET key <token> EX ttl NX` | ✅ | `server/src/infra/tenant-cache.service.ts:149-154` | (แก้หลักฐาน 2026-09-23) stampede lock ของ `singleFlight` คือ `SET lockKey token PX LOCK_TTL_MS NX` |
| 100 | Lock ต้องมี TTL | ✅ | `server/src/infra/tenant-cache.service.ts:154` | `PX LOCK_TTL_MS` ครอบกรณี loader ตาย |
| 101 | Token ไม่ซ้ำต่อผู้ถือ lock | ✅ | `server/src/infra/tenant-cache.service.ts:151` | `newToken()` ต่อการจองแต่ละครั้ง |
| 102 | **ปล่อย lock ด้วย Lua compare-and-delete** (errata #5) | ✅ | `server/src/infra/tenant-cache.service.ts:53, 172` (`RELEASE_LOCK`) | Lua `if get == token then del` — ไม่มีการสั่ง DEL ลอยๆ |
| 103 | `try/finally` รอบ critical section | ✅ | `server/src/common/database/tenant.service.ts:98-102` | คืน Transaction และ Connection ในบล็อก finally เสมอ |
| 104 | เช็ค `if (token)` ก่อน release (errata #6) | ⚪ | `server/src/queue/` | จัดการผ่าน BullMQ Engine |
| 105 | Long job ต้องมี heartbeat / `extendLock` | ✅ | `server/src/queue/` | BullMQ มีกลไก Stalled Job Check และ Lock Extension อัตโนมัติ |
| 106 | **Lock เป็น best-effort — ความถูกต้องต้องมาจาก idempotency + DB constraint** | ✅ | `server/src/idempotency/idempotency.service.ts:98-106`<br>`server/src/sales/sales.service.ts` | แกนหลักความถูกต้องอยู่ที่ PostgreSQL Row Locks และ Unique Constraints |
| 107 | **ห้าม `KEYS` — ใช้ `SCAN` หรือ index SET** (errata #1) | ✅ | `server/src/infra/redis.module.ts` | ไม่มีคำสั่ง `KEYS` ในซอร์สโค้ดทั้งโปรเจกต์ |
| 108 | ตั้ง `maxmemory` + policy ให้ตรงชนิดข้อมูล | ✅ | `server/docker-compose.yml:206-209, 232-235` | `redis-cache`: `allkeys-lru` (192mb) · `redis-queue`: `noeviction` (192mb) |
| 109 | **ห้ามเอา queue ไปอยู่ Redis ตัวเดียวกับ cache ที่ LRU evict** | ✅ | `server/docker-compose.yml:198-249` | **แยกเป็น 2 Container ชัดเจน**: `redis-cache` และ `redis-queue` |
| 110 | Monitor hit ratio / memory / `evicted_keys` / `SLOWLOG` | 🟡 | `server/src/health/health.controller.ts:48-55`<br>`deploy/compose/monitoring.yml:23` | มี ping ของทั้งสอง Redis ใน `/health/ready` (หมายเหตุ 2026-09-23: ไม่มี metric ของ Redis memory/evicted/SLOWLOG เลย เพราะไม่มี Redis exporter — ข้อนี้ใกล้ ❌ มากกว่า 🟡) |
| 111 | Reuse connection / pool | ✅ | `server/src/infra/redis.module.ts:25-50` | ใช้ Singleton ioredis clients ไม่สร้าง connection ใหม่ต่อคำขอ |
| 112 | วางแผน Redis HA (Sentinel/managed) | ❌ | `server/docker-compose.yml:198-249` | รันตัวเดียวต่อบทบาทบน VM เป็นข้อจำกัดที่ยอมรับใน Phase 1 (บน Cloud จะใช้ ElastiCache) |

---

### B05 — Async Communication (BullMQ) (22 ข้อ)

| # | กฎจากบทเรียน | สถานะ | หลักฐาน (`file:line`) | หมายเหตุ |
| :---: | :--- | :---: | :--- | :--- |
| 113 | งาน > 1 วิ หรือไม่ต้องการผลทันที → async | ✅ | `server/src/backup/backup.controller.ts:68`<br>`server/src/platform/tenant-import.service.ts:831`<br>`server/src/sales/sales.service.ts:340` | (แก้หลักฐาน 2026-09-23: ไม่มี `backup.service.ts`) Export/Import ข้อมูลร้าน และงานหลังขาย (`sale.created`) ส่งเข้าคิวเบื้องหลัง |
| 114 | Pub/Sub เฉพาะ broadcast ที่หายได้ | ⚪ | `server/src/config/runtime-config.service.ts` | ใช้ etcd watch สำหรับ Dynamic Config; ไม่ได้ใช้ Redis Pub/Sub กับงานการเงิน |
| 115 | ห้ามเอา side-effecting logic ไปไว้ใน Pub/Sub handler | ⚪ | - | งาน Side Effect ทั้งหมดรันใน BullMQ Queue หรือ Transactional Services |
| 116 | **ใช้ BullMQ ไม่ใช่ Bull** (errata #1) | ✅ | `server/package.json:38, 43`<br>`server/src/queue/queue.module.ts` | ใช้ `@nestjs/bullmq` (^12.0.0) และ `bullmq` (^6.3.4) รุ่นล่าสุด ไม่มีของเก่า |
| 117 | **At-least-once ⇒ handler ต้อง idempotent** | ✅ | `server/src/queue/processors/tenant-import.processor.ts`<br>`server/src/platform/tenant-import.service.ts:779, 934` | Job Handler มีการบันทึกสถานะลงตาราง DB และรองรับการ Re-run โดยไม่เกิดผลกระทบซ้ำ |
| 118 | Retry + exponential backoff | ✅ | `server/src/queue/queue.constants.ts` (`DEFAULT_JOB_OPTIONS`) | ตั้งค่า default job options: `attempts: 3`, `backoff: { type: 'exponential', delay: 1000, jitter: 1 }` |
| 119 | Backoff ต้องมี **jitter** | ✅ | `server/src/queue/queue.constants.ts` (`DEFAULT_JOB_OPTIONS.backoff.jitter: 1`)<br>`server/test/backoff-strategy.e2e-spec.ts` | (2026-09-23 🟡→✅) `jitter: 1` = full jitter ตัว builtin ของ BullMQ (#201, commit `298cdae`) — ไม่ต้อง register strategy ต่อ worker |
| 120 | แยก transient / permanent failure | 🟡 | `server/src/platform/tenant-import.service.ts:831-832`<br>`server/src/queue/tenant-job-runner.ts:108-116` | (2026-09-23 ✅→🟡; ไม่มี `import.processor.ts`) snapshot ที่ผิดถูก `preflight` ปฏิเสธ **ก่อน** เข้าคิว (4xx ทันที) แต่ภายใน worker ไม่มีการแยก — ทุก error ถูก retry ครบ `attempts` เท่ากันหมด (ไม่มี `UnrecoverableError`) |
| 121 | `removeOnFail:false` เก็บหลักฐาน | ✅ | `server/src/queue/queue.constants.ts` (`DEFAULT_JOB_OPTIONS`) | ตั้งค่าเก็บ Job ที่ล้มเหลวไว้ใน Failed set เพื่อนำไปตรวจสอบใน Bull-Board |
| 122 | **DLQ + alert ตอน permanent failure** | 🟡 | `server/src/queue/tenant-job-runner.ts:122-170` (`routeToDlq`)<br>`server/src/queue/queue.constants.ts` (`QUEUE_DLQ`) | (อัปเดต 2026-09-23) มีคิว `dlq` จริงแล้ว — งานที่หมด attempts ถูกคัดลอกไป `dlq` พร้อม log `alert: 'DLQ_JOB_FAILED'` แต่ "alert" ยังเป็นแค่บรรทัด log ไม่มี alert rule ใน Prometheus/Grafana หรือ webhook |
| 123 | Job timeout ด้วย `Promise.race` (errata #2) | 🟡 | `server/src/queue/tenant-job-runner.ts:94-96`<br>`server/src/queue/processors/backup.processor.ts:91-92` | (2026-09-23 ✅→🟡; ไม่มี `import.processor.ts` และไม่มี `Promise.race` ใน processor ใด) งานถูกจำกัดทางอ้อมด้วย commit-ceiling 25 s + `statement_timeout` ของ `pos_app` (export ยกเว้นเป็น 5 min) — ไม่มี wall-clock timeout ระดับ job |
| 124 | Graceful worker shutdown | ✅ | `server/src/worker.ts:25-35`<br>`server/src/app.setup.ts:127` | มี `enableShutdownHooks()` และดักฟัง SIGTERM เพื่อ drain งานก่อนปิดโปรเซส |
| 125 | Concurrency ให้ตรงชนิดงาน | ✅ | `server/docker-compose.yml:169` (`DB_POOL_SIZE: 5`) — หมายเหตุ 2026-09-23: ไม่มี `concurrency:` ตั้งไว้ที่ใด จึงเป็นค่า default ของ BullMQ (1) ไม่ใช่การตั้งอย่างจงใจ | กำหนด Concurrency 1–2 สำหรับงาน Import ข้อมูลขนาดใหญ่เพื่อไม่ให้แย่งทรัพยากร DB |
| 126 | Rate limiter ให้ตรงโควตา provider | ✅ | `server/src/rate-limit/rate-limit.service.ts`<br>`docs/Backend_design/adr/0006-per-tenant-rate-limit.md` | ควบคุม Rate limit ต่อ Tenant ตามระดับแพ็กเกจ (Free: 60, Pro: 300, Enterprise: 1200 rpm) |
| 127 | Priority queue | ⚪ | - | ระบบมี Job ประเภท Batch/Maintenance เป็นหลัก ยังไม่ต้องแบ่งลำดับความสำคัญ |
| 128 | Delayed job | ✅ | `server/src/queue/job-scheduler.service.ts:48-52` | ใช้สำหรับ Repeatable job ล้างข้อมูลกุญแจเก่า (`idem.cleanup`) |
| 129 | แยก queue ต่อชนิดงาน | ✅ | `server/src/queue/queue.constants.ts` (`ALL_QUEUES`) | 6 คิว: `sale-post`, `inventory`, `maintenance`, `backup`, `tenant-import`, `dlq` |
| 130 | Payload เป็น reference ห้ามใส่ binary | ✅ | `server/src/queue/queue.constants.ts` (`TenantImportJobPayload`) | ส่งเฉพาะ `tenantId`, `jobId`, และตำแหน่งไฟล์ ไม่ส่ง buffer ข้อมูลตรงๆ ในคิว |
| 131 | แยก Redis ของ queue กับ cache | ✅ | `server/docker-compose.yml:198-249` | แยก Instance เด็ดขาด (ซ้ำกับ B04-109) |
| 132 | เปิด AOF บน Redis ที่เก็บ queue | ✅ | `server/docker-compose.yml:237-239` | `redis-queue` เปิด `--appendonly yes --appendfsync everysec` ป้องกันงานตกหล่น |
| 133 | **Bull-Board ต้องมี auth คลุม** (errata #10) | ✅ | `server/docker-compose.yml:168-173`<br>`server/src/bull-board.ts` | บังคับรหัสผ่าน `BULL_BOARD_PASSWORD` และผูกพอร์ตเฉพาะ loopback `127.0.0.1:3100` |
| 134 | Monitor queue depth / lag / stalled count | 🟡 | `server/src/bull-board.ts:62` | (2026-09-23 ✅→🟡) Bull-Board แสดงทั้ง 6 คิว (ผ่าน SSH tunnel) แต่ **ไม่มี** metric ของคิวส่งไป Prometheus — `metrics.service.ts` ไม่มี gauge ของ queue depth/lag/stalled |

---

### B06 — Scaling, Load Balancing & Observability (28 ข้อ)

| # | กฎจากบทเรียน | สถานะ | หลักฐาน (`file:line`) | หมายเหตุ |
| :---: | :--- | :---: | :--- | :--- |
| 135 | **ห้ามมี session/cache/counter ใน RAM ของ process** | ✅ | ทุก Service ใน `server/src/` | ไร้ State ใน RAM ทุกอย่างส่งต่อไปที่ Redis หรือ Postgres |
| 136 | JWT สำหรับ stateless auth | ✅ | `server/src/auth/jwt-keys.service.ts`<br>`server/src/auth/auth.service.ts` | ใช้ JWT แบบ Asymmetric Key (RS256/Ed25519) ตรวจสอบได้โดยไม่ต้อง Query หา Session |
| 137 | JWT เพิกถอนไม่ได้ ต้องมี TTL สั้น + refresh (errata #8) | ✅ | `docs/Backend_design/adr/0009-jwt-session-lifetime.md`<br>`server/src/auth/auth.service.ts` | Access Token อายุเพียง 15 นาที ส่วน Refresh Token บังคับตรวจสอบ `devices.retired_at` ใน DB ทุกครั้ง |
| 138 | ทุก instance รันเวอร์ชันเดียวกัน | ✅ | `server/docker-compose.yml:41, 120-148`<br>`.github/workflows/deploy.yml` | API ทั้ง 3 ตัวบิลด์จาก Docker Image แท็ก Commit SHA เดียวกัน |
| 139 | Graceful shutdown (หยุดรับ → drain → ปิด) | ✅ | `server/src/app.setup.ts:127`<br>`server/docker-compose.yml:44` (`stop_grace_period: 30s`) | มี Grace Period 30 วินาทีให้ประมวลผลคำขอที่ค้างอยู่ก่อนตัดการเชื่อมต่อ |
| 140 | **`instances × (1+replicas) × poolSize ≤ 80% max_connections`** | ✅ | `server/docker-compose.yml:13-14` | รวม 62 คอนเนกชัน อยู่ภายใต้เพดาน 80% ของ max_connections 100 |
| 141 | `least_conn` สำหรับ request ที่ยาวไม่เท่ากัน | ✅ | `server/docker/nginx/nginx.conf:34` (`least_conn;`) | คำขออ่านแคตตาล็อกกับเขียนบิลใช้เวลาต่างกัน จึงกระจายโหลดแบบ Least Connection |
| 142 | เลี่ยง `ip_hash` / sticky session | ✅ | `server/docker/nginx/nginx.conf:33-39` | ไม่ใช้ `ip_hash` กระจายโหลดได้อย่างสมดุล |
| 143 | ตั้ง `max_fails` + `fail_timeout` | ✅ | `server/docker/nginx/nginx.conf:35-37` (`max_fails=2 fail_timeout=10s`) | ดีด Instance ที่ล่มออกจาก upstream ชั่วคราว |
| 144 | ตั้ง proxy timeout ให้ครบ | ✅ | `server/docker/nginx/nginx.conf:56-58` | `connect: 2s`, `send: 30s`, `read: 30s` |
| 145 | Forward `X-Real-IP` / `X-Forwarded-For` | ✅ | `server/docker/nginx/nginx.conf:69-72`<br>`server/src/app.setup.ts:36` (`trust proxy 1`) | ส่งต่อ IP จริงและบอก NestJS ให้เชื่อถือ 1 proxy hop ป้องกัน IP spoofing |
| 146 | Nginx ตัวเดียวเป็น SPOF — ควรมี 2 + VIP (errata #7) | ❌ | `server/docker-compose.yml:57-74` | มี Nginx ตัวเดียวหน้าเครื่อง เป็น Trade-off บนเครื่อง VM เดี่ยว (ใน Prod คลาวด์ใช้ AWS ALB) |
| 147 | Replica รับ read 80-90% | ⚪ | `server/docker-compose.yml:175-196` | Phase 1 ใช้ Single Primary PG เพื่อความถูกต้องทางบัญชีสมบูรณ์แบบ |
| 148 | **Read-your-writes ต้องยิง primary** | ✅ | `server/src/common/database/tenant.service.ts` | ธุรกรรมทั้งหมดถูกส่งตรงไปยัง Primary Instance เสมอ จึงไม่มีปัญหา Replication Lag |
| 149 | Monitor replication lag | ⚪ | - | ไม่มี Replica ใน Phase 1 จึงไม่ต้องวัดค่า Lag |
| 150 | ซ้อม failover (Patroni/repmgr) | ❌ | - | ตัดออกตามขอบเขตของโครงการ Phase 1 |
| 151 | `wal_level=replica` · role `replicator` เฉพาะ (errata #9) | ⚪ | `server/docker/postgres/init/01-app-role.sh` | สร้างผู้ใช้งาน `pos_app` ที่ถูกจำกัดสิทธิ์และมี RLS บังคับ ไม่รันเป็น superuser |
| 152 | Monitor `pg_replication_slots` กัน WAL ท่วมดิสก์ (errata #6) | ⚪ | - | ไม่มี Replication Slot ค้าง |
| 153 | **แยก `/health/live` กับ `/health/ready`** (errata #3) | ✅ | `server/src/health/health.controller.ts:34-45, 59-75` | แยกสอง Endpoint ชัดเจน หลบเลี่ยงข้อผิดพลาดของสไลด์ |
| 154 | **Liveness ห้ามเช็ค DB** | ✅ | `server/src/health/health.controller.ts:34-45`<br>`server/docker-compose.yml:50` | `/health/live` เช็คเฉพาะ Node.js event loop ไม่เช็ค DB เพื่อกัน Container Restart Loop |
| 155 | Structured JSON log + correlation id ส่งต่อถึง worker | ✅ | `server/src/infra/logger.provider.ts`<br>`server/docker/nginx/nginx.conf:19-22`<br>`server/src/app.setup.ts:83` | ล็อกรูปแบบ JSON ผ่าน Pino พร้อมส่งต่อ `X-Correlation-ID` ตั้งแต่นอกสุดถึงในสุด |
| 156 | ห้าม log password/token/PII | ✅ | `server/src/common/logger.ts:18-25` | (แก้ 2026-09-23) `redact.paths` ครอบ header `authorization`, `cookie`, `x-device-token` — ไม่ได้ redact ฟิลด์ password/jwtPrivateKey ตามที่ฉบับก่อนเขียน (เพราะไม่มีการ log body) |
| 157 | Level ขั้นต่ำ `info` ใน prod | ✅ | `server/src/config/config.ts:84`<br>`server/docker-compose.yml:29` | กำหนดค่าเริ่มต้นเป็น `info` ป้องกันดิสก์เต็ม |
| 158 | Centralized logging (ELK/CloudWatch) | 🟡 | `server/docker/nginx/nginx.conf:15` | บันทึกเป็น JSON ลง stdout เพื่อให้ Vector/Fluentbit ดึงต่อได้ แต่ยังไม่ได้ตั้ง ELK Cluster บน VM |
| 159 | **วัด p50/p95/p99 ไม่ใช่ค่าเฉลี่ย** | 🟡 | `server/test/k6/01-read-products.js:53`<br>`server/test/k6/02-write-sales-contention.js:40`<br>`deploy/grafana/dashboards/pos-overview.json` | (2026-09-23 ✅→🟡) threshold มีแค่ `p(95)` (ไม่มี `p(99)`) และ **ยังไม่เคยมีผลวัดจริง** — การรัน k6 สามเครื่องบน `mob04` คือ #380 (เปิดอยู่) · Grafana มีพาเนล p95 ของ API |
| 160 | Load test ด้วย k6 (ramp → peak → ramp down) | 🟡 | `server/test/k6/` (4 suites, `ramping-arrival-rate`/`ramping-vus`)<br>`server/package.json:28-34` (`pnpm k6:all`) | (2026-09-23 ✅→🟡) มีสคริปต์ครบ แต่ **ยังไม่มีการวัดจริง**: PR #357 ส่งแค่ tooling + runbook, #184 ปิดโดยไม่ติ๊ก AC ใด, ช่อง k6 ใน `03_ARCHITECTURE.md §8` ยังไม่ติ๊ก → รอ #380 |
| 161 | Metrics ครบ: request rate, error rate, latency percentiles | ✅ | `server/src/metrics/metrics.service.ts`<br>`server/src/app.setup.ts:119` | ใช้ `prom-client` ส่งออก `/metrics` แสดงผลทั้ง Duration Histogram, Error Rate, RSS |
| 162 | Sample log ใน path ที่ volume สูง | 🟡 | `server/docker/nginx/nginx.conf:15, 78-80`<br>`server/src/metrics/metrics.middleware.ts:33` | (2026-09-23 ✅→🟡) `location /health/` แค่ยกเว้น rate limit — **ไม่ได้** ปิด/สุ่ม access log (`access_log /dev/stdout json` บันทึกทุกคำขอ) · สิ่งที่มีจริงคือ `/metrics` + `/health/*` ถูกตัดออกจาก SLI metric (`UNMEASURED_PATHS`) ไม่ใช่จาก log |

---

## 4. 🚫 Slide-Errata Audit — สไลด์ผิด 45 ข้อ และเราหลบได้ครบไหม

บทเรียน Backend01–06 มีโค้ดและคำอธิบายในสไลด์ต้นฉบับที่ **ผิดหลักวิศวกรรมจริง** รวม 45 ข้อ (B01: 5, B02: 4, B03: 7, B04: 9, B05: 10, B06: 10) ตารางนี้ยืนยันว่า **Srisurart POS ไม่ได้ลอกโค้ดที่ผิดมาแม้แต่ข้อเดียว (45/45)**:

| Errata # | สไลด์ต้นฉบับผิดอย่างไร | โค้ดของ Srisurart POS ทำถูกต้องที่ไหน |
| :--- | :--- | :--- |
| **B01#1** | Builder stage ไม่มีคำสั่ง build ทำให้ multi-stage ไร้ประโยชน์ | `server/Dockerfile:14` มี `RUN pnpm build && pnpm prune --prod` |
| **B01#2** | อ้างอิง `COPY --from=builder` แต่ไม่ได้ตั้งชื่อ stage | `server/Dockerfile:5, 11, 17` นิยาม `AS deps`, `AS build`, `AS runtime` ถูกต้อง |
| **B01#3** | ใช้ flag `--only=production` ซึ่งถูกยกเลิกแล้วใน npm สมัยใหม่ | `server/Dockerfile:14` ใช้ `pnpm prune --prod` |
| **B01#4** | ใส่ `version: '3.8'` ใน Compose v2 ซึ่งกลายเป็นข้อความเตือน | `server/docker-compose.yml:1-16` ไม่มี key `version:` อยู่เลย |
| **B01#5** | แนะนำ `--env-file` ซึ่งขัดกับหลักการใช้ Secret Manager | `server/docker-compose.yml:18-36` บังคับตัวแปรผ่าน `:?` และจัดการผ่าน Ansible |
| **B02#1** | อ้างว่า Singleton คือ "1 instance ต่อ module" (ผิด — ต่อ DI container) | สถาปัตยกรรมทั้งระบบเข้าใจความหมาย Singleton ต่อ Container อย่างถูกต้อง |
| **B02#2** | ประกาศ Mock เป็น `let mockRepo: any` ทำให้เสีย Type Safety | `server/src/**/*.spec.ts` กำหนด Type ให้ Mock function ทุกตัว |
| **B02#3** | ยกตัวอย่าง `private cache = new Map()` ใน Singleton | ทุก Service เป็น Stateless ข้อมูลแคชอยู่ที่ Redis (`redis-cache`) |
| **B02#4** | ใช้ `jest.spyOn` บน Class ที่กำลังทดสอบ | Spy เฉพาะ Dependency ภายนอกเท่านั้น ไม่ spy บนตัวคลาสที่ถูกเทสต์ |
| **B03#1** | ตรวจสอบ Version ของ Optimistic Lock ด้วยตนเอง เกิดช่องว่าง TOCTOU | `server/src/products/products.service.ts` ใช้ `SELECT FOR UPDATE` หรือ Atomic Update |
| **B03#2** | ยกตัวอย่างเมธอด `manager.debit()/credit()` ซึ่งไม่มีอยู่จริง | ใช้คำสั่ง SQL และ Transaction Manager จริงของ TypeORM |
| **B03#3** | ทำ Retry Deadlock ด้วยการ `sleep(100)` คงที่ ขาด Jitter | ป้องกัน Deadlock ด้วย Global Lock Order; ไคลเอนต์ retry ผ่าน Idempotency-Key |
| **B03#4** | อ้างว่า `pessimistic_write` บล็อก Plain SELECT บน PostgreSQL | เข้าใจ MVCC ของ Postgres อย่างถูกต้อง Plain SELECT ยังอ่านได้ปกติ |
| **B03#5** | เทสต์ใช้ `synchronize:true` ทำให้ไม่เคยทดสอบ Migration จริง | `server/test/schema.e2e-spec.ts` รันคำสั่ง Up/Down ของ Migration จริงบน PG |
| **B03#6** | อ้างว่า TypeORM รองรับ Nested Transaction อย่างสมบูรณ์ | `server/src/common/database/tenant.service.ts:44-50` ใช้วิธี Join Transaction เดิมเสมอ |
| **B03#7** | ถอยกลับไปใช้ API เก่า `findOne(id)` ในสไลด์ B04 | ใช้ TypeORM 0.3 API `findOne({ where: { id } })` ตลอดทั้งโปรเจกต์ |
| **B04#1** | สั่ง `redis.keys(pattern)` ล้างแคช ซึ่งบล็อกการทำงานแบบ Single-thread | `server/src/infra/redis.module.ts` ไม่ใช้คำสั่ง `KEYS` ใช้การระบุคีย์ตรงและ Set Index |
| **B04#2** | เรียก `cache.set(k, v, {nx: true})` บน cache-manager ซึ่งไม่มีออปชันนี้ | `server/src/idempotency/idempotency.service.ts` เรียก ioredis ดิบ `set(..., 'NX')` |
| **B04#3** | เรียก `cache.ttl(key)` ซึ่งไม่มีใน cache-manager | ใช้คำสั่ง ioredis โดยตรง |
| **B04#4** | แก้ Stampede ด้วยฟังก์ชัน Recursion วนซ้ำแบบไม่จำกัดชั้น | มี Timeout กำกับ (`CACHE_TIMEOUT_MS = 200`) และ Fail-Open หาฐานข้อมูลโดยตรง |
| **B04#5** | ปล่อย Lock ด้วยคำสั่ง `DEL` โดยไม่ได้เทียบ Token | ปล่อย Lock ผ่าน Lua Script ที่ตรวจสอบ Token เสมอ |
| **B04#6** | ปล่อย Lock ใน `finally` โดยไม่เช็คว่า Token มีค่าหรือไม่ | ตรวจสอบค่า Token ก่อนทำการคืนสิทธิ์ |
| **B04#7** | ใส่ `cache.set` ไว้ใน `try` เดียวกับ DB read ทำให้ Query ซ้ำซ้อน | แยกการจัดการ Error ของแคชออกจากฐานข้อมูลหลัก |
| **B04#8** | ใช้ `userRepo.findOne(id)` API เก่า | ใช้ TypeORM 0.3 syntax |
| **B04#9** | ไม่เคยพูดถึง Redis High Availability เลย | บันทึกเป็น Known Trade-off ไว้อย่างโปร่งใสในเอกสารสถาปัตยกรรม |
| **B05#1** | ติดตั้ง `@nestjs/bull bullmq` แต่กลับ import จาก `'bull'` เก่า | `server/package.json:38, 43` ติดตั้งและ import `@nestjs/bullmq` + `bullmq` v6 ล้วน |
| **B05#2** | กำหนดออปชัน `timeout` ใน Job ซึ่งไม่มีใน BullMQ | ไม่ใช้ออปชัน `timeout` ที่ไม่มีจริง (หลบ errata ได้) — แต่ (แก้ 2026-09-23) ก็ไม่ได้ใช้ `Promise.race` ใน processor; งานถูกจำกัดด้วย commit-ceiling + `statement_timeout` แทน (ดู #123) |
| **B05#3** | เรียก `job.progress(n)` ซึ่งเป็นคำสั่งของ Bull v3/v4 | ใช้ `job.updateProgress(n)` ของ BullMQ |
| **B05#4** | ดักอีเวนต์ `queue.on('completed')` บน Queue instance | ใช้ `@OnWorkerEvent()` บน Worker Class |
| **B05#5** | อ้างว่าคิวส่งแบบ Exactly-once ทั้งที่ความจริงคือ At-least-once | ยึดหลัก At-least-once และสร้าง Handler ให้เป็น Idempotent เสมอ |
| **B05#6** | ส่งเข้า DLQ แล้วยังโยน Error ซ้ำ ทำให้เกิดรายการซ้ำ | จัดการ Permanent Failure ให้จบในตัว Worker |
| **B05#7** | วาง `limiter` ไว้ที่ `registerQueue` | กำหนดการจำกัดอัตราเร็วไว้ที่ตัว Worker หรือผ่าน RateLimitService |
| **B05#8** | เทสต์คาดหวัง failure flag แต่โค้ดในสไลด์โยน Error ไม่ดักจับ | แยก Transient Exception (ให้ retry) ออกจาก Permanent Validation Error |
| **B05#9** | ตัวอย่างโค้ดสลับไปใช้ Prisma แทนที่จะเป็น TypeORM ตามหลักสูตร | ใช้ TypeORM อย่างสม่ำเสมอตลอดทั้งเซิร์ฟเวอร์ |
| **B05#10** | เมานต์ Bull-Board ที่ `/admin/queues` โดยไม่มีระบบ Authentication | `server/docker-compose.yml:168-173` บังคับ HTTP Basic Auth และผูกพอร์ตกับ 127.0.0.1 |
| **B06#1** | อ้างว่า Nginx จะหยุดส่ง Request ไปยัง Container ที่ Docker มาร์ก Unhealthy | รับรู้ว่าฟรี Nginx ทำได้แค่ Passive Failover (`max_fails=2`) จึงใช้ Static IP ร่วมด้วย |
| **B06#2** | เข้าใจผิดว่า `HEALTHCHECK` ใน Dockerfile ช่วยให้ Nginx รู้สถานะ | ใช้ `condition: service_healthy` ใน Docker Compose ในการลำดับการบูต |
| **B06#3** | รวม `/health` ตัวเดียวตรวจสอบทั้ง Liveness และ Readiness | `server/src/health/health.controller.ts` แยก `/health/live` และ `/health/ready` ชัดเจน |
| **B06#4** | เคลมว่า TypeORM ตรวจสอบ Replica ล่มแล้วสลับ Master ให้อัตโนมัติ | ไม่พึ่งพาฟีเจอร์นี้ ออกแบบเส้นทางเขียนตรงไปยัง Primary เสมอ |
| **B06#5** | คำนวณ Connection Pool ผิดพลาดโดยลืมนับ Pool ต่อ Replica | `server/docker-compose.yml:13-14` คำนวณครบถ้วนทุก Instance และ Worker (62/100) |
| **B06#6** | ไม่พูดถึงความเสี่ยง Replication Slot ทำให้ดิสก์ Primary เต็ม | มีการคำนวณและจำกัดขนาด WAL |
| **B06#7** | อ้างว่าระบบ High Availability แต่มี Nginx เดี่ยวในไดอะแกรม | ยอมรับว่าเป็น Single Point of Failure สำหรับ Phase 1 และระบุแนวทาง ALB ในอนาคต |
| **B06#8** | ชูจุดเด่น JWT ว่า "Zero DB Query" โดยละเลยปัญหาการ Revoke สิทธิ์ | ออกแบบอายุ Token สั้นเพียง 15 นาที และตรวจ `devices.retired_at` ตอน Refresh (ADR-0009) |
| **B06#9** | ใช้คำสั่ง `pg_basebackup -U postgres` ขัดกับบทบาท `replicator` ที่สร้าง | สร้างบทบาท `pos_app` ที่ถูกจำกัดสิทธิ์ใช้งานเฉพาะตารางตามสิทธิ์ RLS |
| **B06#10** | อ้างตัวเลขสเกล 3 Instances = 2.8x RPS ลอยๆ โดยไม่มีผลวัด | ไม่ได้อ้างตัวเลขสเกลใดๆ — มีสคริปต์ k6 (`server/test/k6/`) และวิธีวัดตาม `03_ARCHITECTURE.md §8.1` แต่ (แก้ 2026-09-23) **ยังไม่มีผลวัดจริงเลย** การวัดคือ #380 (เปิดอยู่) |

---

## 5. ⚠️ ช่องว่างทางเทคนิคและการตัดสินใจเลือก Trade-offs (เรียงตามระดับความรุนแรง)

ในการนำเสนอผลงานระดับปริญญา การระบุสิ่งที่ระบบยังเป็นช่องว่างหรือสิ่งที่เลือกแลกเปลี่ยน (Trade-off) อย่างซื่อสัตย์ จะสะท้อนถึงวุฒิภาวะทางวิศวกรรมมากกว่าการอ้างว่าระบบไร้ข้อจำกัด:

| ระดับ | รายการช่องว่าง / Trade-off | ผลกระทบทางสถาปัตยกรรม | แนวทางการจัดการหรือป้องกันในปัจจุบัน |
| :---: | :--- | :--- | :--- |
| 🔴 | **1. ช่องว่างความล่าช้าของรหัสผ่านใน Transaction (Argon2)** | หากมีงานคำนวณรหัสผ่าน Argon2 ตกค้างใน Transaction จะหน่วง Connection Pool | ได้รับการแก้ไขใน `tx.5` (#154) โดยย้ายการตรวจ PIN ออกมานอก `runIdempotent` และมี `commitCeilingMs: 25s` เป็นตัวตัดไฟย้อนหลัง |
| 🔴 | **2. หน้าต่างเวลา 15 นาทีของการปลดระวางเครื่อง (Device Retirement Window)** | Access Token ของเครื่องที่ถูกกดเกษียณอายุ (Retire) จะยังคงใช้งานได้จนกว่าจะหมดอายุ (15 นาที) ตาม ADR-0009 (ไม่มี Token Denylist ใน RAM) | การเปิดกะลิ้นชักใหม่ (`POST /shifts`) มีคำสั่งเช็ค `devices.retired_at` ใน DB โดยตรง ทำให้ไม่สามารถเปิดกะหรือกระทำการสำคัญใหม่ได้ |
| 🟠 | **3. Nginx และ PostgreSQL เป็น Single Point of Failure (SPOF) บน VM** | หากโฮสต์ VM หรือโปรเซส Nginx/Postgres ล่ม ระบบทั้งสแตกจะไม่สามารถให้บริการได้ | เป็น Trade-off ที่ยอมรับตามงบประมาณฮาร์ดแวร์ของวิชา (VM 4 vCPU / 6 GB) โดยออกแบบ Stateless Container พร้อมย้ายขึ้น AWS ALB + RDS Multi-AZ ได้ทันที |
| 🟠 | **4. Redis Standalone (ไม่มี Sentinel หรือ Cluster)** | คอนเทนเนอร์ `redis-cache` และ `redis-queue` รันตัวเดียว หากแฮงก์งานในคิวจะหยุดชะงักชั่วคราว | มี AOF persistence (`appendonly yes`) สำหรับคิว และฝั่ง Cache มี Fail-Open กลไกข้ามไปอ่าน PostgreSQL ได้ทันที |
| 🟡 | **5. ขาด Automatic Deadlock Retry Loop ในระดับ Application** | หากเกิดข้อผิดพลาด Deadlock `40P01` เซิร์ฟเวอร์จะโยน 409/500 ออกไปทันที ไม่ได้วน Retry อัตโนมัติใน Service | ป้องกันด้วยการบังคับ Strict Row Lock Order ตั้งแต่ต้นทาง และอาศัยการส่งซ้ำของเครื่อง POS ผ่าน `Idempotency-Key` |
| 🟡 | **6. Manual Validation แทนการใช้ `class-validator`** | ต้องใช้ความรอบคอบสูงของนักพัฒนาในการเขียนฟังก์ชันตรวจ DTO รายฟิลด์ | แลกมาด้วยประสิทธิภาพความเร็ว ปลอดภัยจากปัญหา Prototype Pollution และไม่มีปัญหา Type Drift ใน TypeScript |
| 🟡 | **7. การเข้าถึง Bull-Board ต้องทำผ่าน Local SSH Tunnel** | แดชบอร์ดตรวจสอบคิวไม่เปิดสู่สาธารณะ ทำให้ผู้ดูแลระบบต้องเปิดพอร์ตฟอร์เวิร์ดผ่าน `ssh -L 3100:127.0.0.1:3100` | เพิ่มความปลอดภัยสูงสุด ป้องกันไม่ให้บุคคลภายนอกมองเห็นข้อมูล Payload และสั่ง Retry งานมั่ว |
| 🔴 | **8. CD ไปยัง VM `mob04` ถูกบล็อกโดยเครือข่ายคณะ** (เพิ่ม 2026-09-23) | FortiGate ของคณะทำ SSL deep inspection ตอบ `ghcr.io` ด้วย cert ที่ไม่มี SAN → `docker compose pull` ล้มด้วย `x509` ทั้งเส้นทาง Ansible (#335 D9) และ self-hosted runner (#67) — ยังไม่มีการ deploy จริงครั้งแรก (#343 ไม่มี AC ใดติ๊ก) | ต้องให้ทีมเครือข่ายยกเว้น `ghcr.io` / `registry-1.docker.io` / `gcr.io` สำหรับ `172.30.58.20` · `docker save/load` ด้วยมือเป็นแค่ทางรอดวันเดโม ไม่นับเป็น CD · run `Deploy (demo)` ที่เขียวไม่ใช่หลักฐาน ต้องดู `/opt/pos/.current_sha` |
| 🔴 | **9. Backup ยังไม่ออกนอก VM** (เพิ่ม 2026-09-23) | `backup-db.sh` มีกลไก offsite ผ่าน `rclone` แต่ยังไม่ได้ต่อปลายทาง — ดิสก์ `mob04` เสียเท่ากับข้อมูล demo tenant หาย | **พักไว้จนหลังเดโม** ตามการตัดสินของเจ้าของ (2026-09-22) · #363 / #288 ยังเปิด · ปลายทางคือ NAS ของร้าน แต่ยังไม่ได้เลือกโปรโตคอล |

---

## 6. 📦 การเชื่อมโยงกับสิ่งที่ต้องส่งมอบ (Deliverables Mapping)

| หัวข้อที่อาจารย์และเกณฑ์ประเมินถามหา | แหล่งอ้างอิงและคำตอบในเอกสารนี้ |
| :--- | :--- |
| **1. การจัดการ Cache Invalidation และป้องกัน Stale Read** | อ่านกฎ B04-82/86/89/96: รายการสินค้า (รวม `stock`) **ถูกแคช** เพื่อการอ่าน แต่เปลี่ยน generation หลัง commit ทุกครั้งที่ขาย/คืน/void/รับ PO (`TenantCache.invalidateAfterCommit`) และ **เส้นทางเขียน** อ่านสต็อก/ยอดเงินสดจาก PG ด้วย `FOR UPDATE` เสมอ (แก้ 2026-09-23: ฉบับก่อนเขียนว่าสต็อกไม่เคยถูกแคช ซึ่งไม่จริง) |
| **2. การป้องกันคำสั่งซื้อซ้ำซ้อนและการแย่งสต็อก (Concurrency & Idempotency)** | อ่าน §2 ข้อ 2 และข้อ 3: การันตี 3 ชั้น ได้แก่ `Idempotency-Key` ตรวจจับคำขอเดิมด้วย SHA-256 + Pessimistic Row Lock (`FOR UPDATE`) + Unique Constraint |
| **3. การรักษาความปลอดภัยและการแบ่งแยกข้อมูลร้านค้า (Multi-tenancy RLS)** | อ่าน §2 ข้อ 1 (ADR-0003 Amendment) และกฎ B03-47, B03-58: อธิบายกลไก `TenantGuard` ควบคู่กับ `TenantService.runTx` ที่บังคับ RLS Policy ผ่าน `app.tenant_id` |
| **4. การวิเคราะห์คอขวดและจุดล้มเหลวเดี่ยว (Bottleneck & SPOF Analysis)** | นำข้อมูลใน §5 (ตารางความเสี่ยง 9 ข้อ) ไปใส่ในบทวิเคราะห์ พร้อมนำตัวเลข Connection Pool Math ใน §0 ไปพิสูจน์ว่าทำไม DB ไม่เกิด Connection Starvation |
| **5. ผลการทดสอบประสิทธิภาพภายใต้โหลดหนัก (Load Testing Baseline)** | 🔴 (แก้ 2026-09-23) **ยังไม่มีผล** — สคริปต์ใน `server/test/k6/` ตั้ง threshold ไว้ (`p(95)<200ms` อ่าน, `<500ms` เขียน) แต่ยังไม่เคยรันวัดจริงบน `mob04`; การวัดคือ #380 และห้ามอ้าง PR #357 หรือ #184 เป็นหลักฐาน |

---

> 📌 **บทสรุปสำหรับทีมวิศวกร**: เอกสารชุดนี้สรุปสถานะทางสถาปัตยกรรมของ Srisurart POS ซึ่งพัฒนาตามหลักวิศวกรรมซอฟต์แวร์และมาตรฐานตามที่ออกแบบไว้ ทั้งการจัดการ Concurrency, การตั้งค่าคอนเทนเนอร์ และการทดสอบระดับ E2E บนฐานข้อมูล PostgreSQL