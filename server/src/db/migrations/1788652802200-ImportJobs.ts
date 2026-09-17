import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * #239 — the tenant import becomes a background job (owner decision, 2026-09-15): a
 * synchronous `POST /platform/tenants/:id/import` took ~6.4 s per 2 MiB locally and can hit
 * nginx's `proxy_read_timeout 30s` on a bigger file while the transaction goes on to commit,
 * leaving the operator with a 504 and a retry that reads back as a confusing 409. The route
 * now runs pre-flight synchronously (fast: no write) and hands the write to a BullMQ worker.
 *
 * `import_jobs` holds what the worker needs that a BullMQ job's own Redis-backed `data`
 * should not: the snapshot itself, up to 10 MiB (`IMPORT_BODY_LIMIT`). Redis with a TTL was
 * considered and rejected — `redis-queue` runs `noeviction` (BullMQ needs jobs it hasn't
 * finished to never be evicted), so a burst of large imports would grow unbounded until OOM,
 * and unlike Postgres nothing here would page it to disk. Postgres already holds every other
 * large JSON blob this server handles (`sales.date`-keyed history, the tenant export's own
 * in-flight rows), and `jsonb` TOASTs a big value out of the row automatically. The BullMQ
 * job payload (`TenantImportJobPayload`) therefore carries only this row's id; the worker
 * loads `payload`, then clears it (`markSucceeded`/`markFailed` on the final attempt) so a
 * completed job does not hold a whole shop's data at rest indefinitely — see
 * `tenant-import.service.ts`.
 *
 * No RLS, unlike every other table with a `tenant_id` column: this one is never read or
 * written by `pos_app` (RLS's whole purpose), only by `ADMIN_DATA_SOURCE` (the owner role,
 * which bypasses RLS regardless) from the platform plane — `platform/tenant-import.service.ts`
 * and `queue/processors/tenant-import.processor.ts`, both already on `tenant-door.spec.ts`'s
 * allowlist for that data source. Deliberately NOT added to `RowLevelSecurity1788652800001`'s
 * `TENANT_SCOPED_TABLES`/`ALL_TABLES`: that migration's `up()`/`down()` iterate those same
 * exported arrays, and this table does not exist yet when migration 1 runs from empty (the
 * schema e2e test rebuilds the whole database on every run) — appending here would make
 * migration 1 try to `ALTER TABLE import_jobs …` before `CREATE TABLE` ever ran.
 * `test/schema.e2e-spec.ts` asserts the no-RLS, no-`pos_app`-grant shape explicitly instead.
 */
export class ImportJobs1788652802200 implements MigrationInterface {
  name = 'ImportJobs1788652802200';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`
      CREATE TABLE import_jobs (
        tenant_id    UUID NOT NULL,
        id           TEXT NOT NULL,
        status       TEXT NOT NULL DEFAULT 'queued'
                     CHECK (status IN ('queued','running','succeeded','failed')),
        payload      JSONB,
        result       JSONB,
        error        TEXT,
        requested_by UUID,
        ip           INET,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        started_at   TIMESTAMPTZ,
        finished_at  TIMESTAMPTZ,
        PRIMARY KEY (tenant_id, id),
        FOREIGN KEY (tenant_id) REFERENCES tenants (id),
        FOREIGN KEY (requested_by) REFERENCES platform_admins (id)
      )`);
    // One import at a time per tenant: `createJob`'s INSERT hits this on a second attempt
    // while one is still queued/running and answers 409, instead of two workers racing the
    // same tenant's "already has bills" check.
    await q.query(`
      CREATE UNIQUE INDEX uq_import_jobs_active ON import_jobs (tenant_id)
        WHERE status IN ('queued', 'running')`);
    await q.query(`CREATE INDEX idx_import_jobs_tenant ON import_jobs (tenant_id, created_at DESC)`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP TABLE import_jobs`);
  }
}
