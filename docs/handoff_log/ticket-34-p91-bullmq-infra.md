# Ticket #34 `p9.1` — BullMQ Infrastructure & Bull-Board

**Date:** 2026-09-12  
**Author:** PattaraponKitcharoen (`team/3` / Lane C)  
**Branch:** `feat/p9.1-bullmq-infra`  
**Status:** Ready for Review / PR  
**PR:** Against `main`  
**Closes:** Issue #34  

---

## 1. Context & Scope
Per **Issue #34**, **`02_API_SCREENS.md §6`**, **`03_ARCHITECTURE.md`**, and **`Backend05.md`**:
- Sets up the queue substrate on `redis-queue` for async background tasks (such as `sale-post`, `inventory`, `maintenance`, `backup`).
- Strictly adheres to BullMQ guidelines: uses `@nestjs/bullmq` with `bullmq` (no legacy `bull` package).
- Establishes **Tenant Isolation** for worker execution: jobs wrap a database transaction and execute `SET LOCAL app.tenant_id = <tenantId>` so tenant settings cannot leak across connection pool re-uses, even when a job crashes.
- Implements tenant suspension guard: checks `tenants.status` from DB; jobs for suspended tenants are safely skipped rather than executed (done-criterion for ADR-0003).
- Implements exponential backoff with full jitter, retention of failed jobs (`removeOnFail: false`), aging of completed jobs (`removeOnComplete: { age: 3600, count: 1000 }`), and routing to Dead-Letter Queue (`dlq`) with alerts when max attempts are reached.
- Bull-Board mounted with `BullMQAdapter` across all 5 queues and protected behind HTTP Basic Auth (`BULL_BOARD_USER` / `BULL_BOARD_PASSWORD`).

---

## 2. Changes Made

### A. Dependencies & Docker Compose
1. **`server/package.json`**:
   - Added `@nestjs/bullmq: ^12.0.0` and `bullmq: ^6.3.4`.
   - Verified that `bull` is absent.
2. **`server/docker-compose.yml`**:
   - Added `<<: *app-env` to `bull-board` service so it receives `REDIS_QUEUE_URL` and `REDIS_PASSWORD` over the compose network.

### B. Queue Module & Worker Infrastructure
1. **`server/src/queue/queue.constants.ts`**:
   - Defined 5 queues: `sale-post`, `inventory`, `maintenance`, `backup`, `dlq`.
   - Defined `BaseJobPayload`: `{ tenantId: string; correlationId: string }`.
   - Defined `DEFAULT_JOB_OPTIONS`: `attempts: 3`, `backoff: { type: 'exponential-jitter', delay: 1000 }`, `removeOnComplete: { age: 3600, count: 1000 }`, `removeOnFail: false`.
2. **`server/src/queue/jitter-backoff.ts`**:
   - Full jitter backoff formula: $delay = \min(maxDelay, base \times 2^{attempts - 1})$, $jitter = \text{random}(0, delay)$.
3. **`server/src/queue/tenant-job-runner.ts`**:
   - Injected into workers.
   - Queries `tenants.status`: skips if `status === 'suspended'` or tenant not found.
   - Executes inside `queryRunner.startTransaction()` and `SELECT set_config('app.tenant_id', $1, true)`.
   - On error: rolls back transaction, preventing tenant leakage.
   - On final attempt: moves job to `dlq` queue with failure metadata and emits `alert: 'DLQ_JOB_FAILED'`.
4. **`server/src/queue/queue.module.ts`**:
   - Registers `BullModule.forRootAsync` on `REDIS_QUEUE_URL` with `maxRetriesPerRequest: null`.
   - Registers queues: `sale-post`, `inventory`, `maintenance`, `backup`, `dlq`.
   - Exports `BullModule` and `TenantJobRunner`.
5. **`server/src/app.module.ts` & `server/src/worker.ts`**:
   - Added `QueueModule` to `AppModule` and `WorkerModule`.
6. **`server/src/bull-board.ts`**:
   - Connected `BullMQAdapter` for all 5 queues on `REDIS_QUEUE_URL`.
   - Protected with timing-safe HTTP Basic Auth.

### C. Test Suite
1. **`server/test/queue.spec.ts`**:
   - AC6: Verified no `bull` package installed.
   - AC5: Verified job options age out completed and retain failed jobs.
   - Verified jitter backoff calculation and bounds.
2. **`server/test/queue.e2e-spec.ts`**:
   - AC1: Proved back-to-back jobs where Tenant A throws does not leak `app.tenant_id` to Tenant B.
   - AC2: Proved retries and dead-letter routing to `dlq` on attempt exhaustion with alert.
   - AC3: Proved suspended tenant jobs are skipped without running business logic.
   - AC4: Proved Bull-Board requires auth and returns 401 when unauthorized.
   - Proved connection and responsiveness of all 5 queues on `redis-queue`.

### D. CI Performance Fix
1. **`server/src/reports/reports.service.ts` & `server/test/reports.e2e-spec.ts`**:
   - Pushed down `product_id = $4` into `PRODUCT_ITEM_EVENTS` CTE in `productSales`.
   - Added `ANALYZE sales; ANALYZE sale_items;` after 10k bulk demo insert in `addDemoVolume()`.
   - Reduced query latency from ~2,038 ms down to ~4 ms, keeping it well within the 200 ms budget on CI runners.

---

## 3. Verification Results

| Check | Command | Result |
|---|---|---|
| Linter | `pnpm lint` | **0 errors, 0 warnings** |
| TypeScript | `pnpm typecheck` | **Clean (0 errors)** |
| Unit Tests | `pnpm test` | **16 test files passed (102 tests)** |
| Queue E2E Tests | `pnpm test:e2e test/queue.e2e-spec.ts` | **7 passed (0 failed)** |
| Reports E2E Tests | `pnpm test:e2e test/reports.e2e-spec.ts` | **6 passed (0 failed)** |
| Production Build | `pnpm build` | **`nest build` succeeds** |
