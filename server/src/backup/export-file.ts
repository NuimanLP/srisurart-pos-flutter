import { createHash } from 'node:crypto';
import { mkdir, open, readdir, rename, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

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

/** Same as `DEFAULT_JOB_OPTIONS.removeOnComplete.age`: the file lives as long as its job. */
export const EXPORT_TTL_MS = 60 * 60 * 1000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const JOB_ID = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * The file for one tenant's export job. Both parts come from the server (the token's tenant,
 * the BullMQ job's own id), never from the request path — and are still validated, so no
 * value can climb out of `exportDir()`.
 */
export function exportFilePath(tenantId: string, jobId: string): string {
  if (!UUID.test(tenantId) || !JOB_ID.test(jobId)) {
    throw new Error('Invalid tenant or job id for an export file');
  }
  return join(exportDir(), tenantId, `${jobId}.json`);
}

export interface ExportDescriptor {
  sizeBytes: number;
  sha256: string;
  exportedAt: string;
  recordCounts: Record<string, number>;
}

/**
 * Writes `snapshot` as one JSON object, one top-level key at a time, so the process never
 * holds the whole document as a single string next to the object (~halves the worker's peak).
 * Written to a temp name and renamed, so a reader never sees a half-written file.
 */
export async function writeExportFile(
  file: string,
  snapshot: Record<string, unknown>,
): Promise<{ sizeBytes: number; sha256: string }> {
  await mkdir(dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  const hash = createHash('sha256');
  let sizeBytes = 0;
  const fh = await open(tmp, 'w');
  try {
    const write = async (s: string) => {
      const buf = Buffer.from(s, 'utf8');
      hash.update(buf);
      sizeBytes += buf.length;
      await fh.write(buf);
    };
    let first = true;
    await write('{');
    for (const [key, value] of Object.entries(snapshot)) {
      if (value === undefined) continue;
      await write(`${first ? '' : ','}${JSON.stringify(key)}:${JSON.stringify(value)}`);
      first = false;
    }
    await write('}');
  } catch (err) {
    await fh.close();
    await rm(tmp, { force: true });
    throw err;
  }
  await fh.close();
  await rename(tmp, file);
  return { sizeBytes, sha256: hash.digest('hex') };
}

/** Deletes every export (any tenant) older than `EXPORT_TTL_MS`. Best effort. */
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
        if (now - (await stat(p)).mtimeMs > EXPORT_TTL_MS) {
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
