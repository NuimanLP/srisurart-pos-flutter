import { readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isUuid } from '../common/ids.js';
import { DEFAULT_JOB_OPTIONS } from '../queue/queue.constants.js';

/**
 * Where a finished tenant export lives. The snapshot used to
 * be the BullMQ job's `returnvalue`, i.e. a whole shop's history stored in `redis-queue`
 * (192 MB, `noeviction`) for an hour — a few exports filled it and every BullMQ write for
 * every tenant then failed. Now the worker writes the file here and the job keeps only a
 * small `ExportDescriptor`.
 *
 * The worker and all three api instances must see the same directory: compose mounts the
 * `exports` volume and sets `EXPORT_DIR` for them. The tmpdir fallback only suits a single
 * process (tests, local `pnpm start` with the worker in-process).
 */
export function exportDir(env: NodeJS.ProcessEnv = process.env): string {
  return env.EXPORT_DIR || join(tmpdir(), 'pos-exports');
}

const JOB_AGE_S =
  (DEFAULT_JOB_OPTIONS.removeOnComplete as { age: number }).age;

/**
 * The file outlives its job's `removeOnComplete.age` by a margin: the file is written before the
 * job commits and finishes, so pruning at exactly the job's age could delete a file whose job
 * still advertises `downloadPath`. Once the job is gone the download 404s anyway.
 */
export const EXPORT_TTL_MS = (JOB_AGE_S + 15 * 60) * 1000;

const JOB_ID = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * The file for one tenant's export job. Both parts come from the server (the token's tenant,
 * the BullMQ job's own id), never from the request path — and are still validated, so no
 * value can climb out of `exportDir()`.
 */
export function exportFilePath(tenantId: string, jobId: string): string {
  if (!isUuid(tenantId) || !JOB_ID.test(jobId)) {
    throw new Error('Invalid tenant or job id for an export file');
  }
  return join(exportDir(), tenantId, `${jobId}.zip`);
}

/**
 * The copy of a shop's data a replace-mode import writes before it deletes anything
 * (`TenantImportService`). In the same `exports` volume as the exports, but in its own
 * `pre-import/` directory, which `pruneExportFiles` never deletes (it removes files only):
 * this file is the shop's way back if the replacement was a mistake.
 */
export function preImportExportPath(tenantId: string, importJobId: string): string {
  if (!isUuid(tenantId) || !JOB_ID.test(importJobId)) {
    throw new Error('Invalid tenant or job id for a pre-import export file');
  }
  return join(exportDir(), tenantId, 'pre-import', `${importJobId}.zip`);
}

/**
 * A ZIP the shop uploaded for import (`POST /backup/import`, `POST /platform/tenants/:id/import`
 * with `Content-Type: application/zip`), kept for the worker until the job ends. In its own
 * `import/` directory, which `pruneExportFiles` does not descend into; the worker removes it.
 */
export function importZipPath(tenantId: string, importJobId: string): string {
  if (!isUuid(tenantId) || !JOB_ID.test(importJobId)) {
    throw new Error('Invalid tenant or job id for an import ZIP');
  }
  return join(exportDir(), tenantId, 'import', `${importJobId}.zip`);
}

/**
 * Where the api streams an uploaded import ZIP before it knows the job id (`zip-upload.ts`).
 * `pruneExportFiles` treats this directory like a tenant's and removes anything left in it past
 * `EXPORT_TTL_MS` (an upload whose request died before the job took it over).
 */
export function importUploadDir(): string {
  return join(exportDir(), 'import-uploads');
}

export interface ExportDescriptor {
  sizeBytes: number;
  sha256: string;
  exportedAt: string;
  recordCounts: Record<string, number>;
}

/**
 * Deletes every export (any tenant) older than `EXPORT_TTL_MS`. Best effort. Runs at each
 * export and on the worker's hourly `idem.cleanup` sweep, so a shop's file (customer names and
 * phones — PDPA) does not sit on the volume waiting for somebody's next export.
 */
export async function pruneExportFiles(now = Date.now()): Promise<number> {
  const root = exportDir();
  let removed = 0;
  let tenants: string[];
  try {
    tenants = await readdir(root);
  } catch {
    return 0;
  }
  for (const t of tenants) {
    let files: string[];
    try {
      files = await readdir(join(root, t));
    } catch {
      continue;
    }
    for (const f of files) {
      const p = join(root, t, f);
      try {
        const st = await stat(p);
        // Files only: `pre-import/` (preImportExportPath) and `import/` (importZipPath) are kept.
        if (st.isFile() && now - st.mtimeMs > EXPORT_TTL_MS) {
          await rm(p, { force: true });
          removed++;
        }
      } catch {
        // raced with another prune or a rename — nothing to do
      }
    }
  }
  return removed;
}
