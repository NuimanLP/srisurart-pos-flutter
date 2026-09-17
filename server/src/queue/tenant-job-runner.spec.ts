import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Job } from 'bullmq';
import { describe, expect, it, vi } from 'vitest';
import { CommitCeilingExceededError } from '../common/database/commit-ceiling.js';
import { TenantJobRunner } from './tenant-job-runner.js';

const TID = '00000000-0000-4000-8000-000000000213';

function fakeRunner(opts: { rollbackThrows?: boolean } = {}) {
  const events: string[] = [];
  const qr: Record<string, any> = {
    isTransactionActive: false,
    isReleased: false,
    manager: {},
    connect: vi.fn(async () => events.push('connect')),
    startTransaction: vi.fn(async () => {
      qr.isTransactionActive = true;
      events.push('begin');
    }),
    query: vi.fn(async () => []),
    commitTransaction: vi.fn(async () => {
      qr.isTransactionActive = false;
      events.push('commit');
    }),
    rollbackTransaction: vi.fn(async () => {
      events.push('rollback');
      if (opts.rollbackThrows) {
        throw new Error('Query runner already released. Cannot run queries anymore.');
      }
      qr.isTransactionActive = false;
    }),
    release: vi.fn(async () => {
      qr.isReleased = true;
      events.push('release');
    }),
  };
  const ds = {
    query: vi.fn(async () => [{ status: 'active' }]),
    createQueryRunner: vi.fn(() => qr),
  };
  const logger = { warn: vi.fn(), error: vi.fn(), info: vi.fn() };
  const dlq = { add: vi.fn(async () => undefined) };
  const runner = new TenantJobRunner(ds as any, logger as any, dlq as any);
  return { runner, events, dlq, qr };
}

const job = (attemptsMade: number) =>
  ({
    id: 'j1',
    name: 'test.job',
    queueName: 'test',
    data: { tenantId: TID, correlationId: 'c1' },
    opts: { attempts: 3 },
    attemptsMade,
  }) as unknown as Job<any>;

describe('TenantJobRunner (#213)', () => {
  it('a rollback that throws (session already ended by Postgres) keeps the original error and still routes to the DLQ', async () => {
    const { runner, dlq, events } = fakeRunner({ rollbackThrows: true });
    const original = new Error('terminating connection due to idle-in-transaction timeout');
    await expect(
      runner.runWithTenantContext(job(2), async () => {
        throw original;
      }),
    ).rejects.toBe(original);
    expect(events).toContain('rollback');
    expect(dlq.add).toHaveBeenCalledTimes(1);
    expect(events.at(-1)).toBe('release');
  });

  it('a failed BEGIN releases the runner and still rethrows', async () => {
    const { runner, events, qr } = fakeRunner();
    const refused = new Error('BEGIN refused');
    qr.startTransaction.mockRejectedValueOnce(refused);
    await expect(runner.runWithTenantContext(job(0), async () => 'never')).rejects.toBe(refused);
    expect(events).toEqual(['connect', 'release']);
  });

  it('rolls back instead of committing a job transaction older than the ceiling', async () => {
    const { runner, events } = fakeRunner();
    runner.commitCeilingMs = 10;
    await expect(
      runner.runWithTenantContext(job(0), () => new Promise((r) => setTimeout(r, 30))),
    ).rejects.toThrow(CommitCeilingExceededError);
    expect(events).not.toContain('commit');
    expect(events).toContain('rollback');
  });

  it('commits a job that opted out of the ceiling', async () => {
    const { runner, events } = fakeRunner();
    runner.commitCeilingMs = 10;
    const res = await runner.runWithTenantContext(
      job(0),
      () => new Promise((r) => setTimeout(() => r('ok'), 30)),
      { exemptFromCommitCeiling: true },
    );
    expect(res).toEqual({ skipped: false, result: 'ok' });
    expect(events).toContain('commit');
  });

  // The opt-out is safe only for a job that writes no row a client pulls by `updated_at`.
  // A new caller is a deliberate change: justify it in README *The transaction ceiling*.
  it('only the tenant export opts out of the commit ceiling', () => {
    const src = join(dirname(fileURLToPath(import.meta.url)), '..');
    const files: string[] = [];
    const walk = (dir: string) => {
      for (const name of readdirSync(dir)) {
        const path = join(dir, name);
        if (statSync(path).isDirectory()) walk(path);
        else if (path.endsWith('.ts') && !path.endsWith('.spec.ts')) files.push(path);
      }
    };
    walk(src);
    const users = files
      .filter((f) => readFileSync(f, 'utf8').includes('exemptFromCommitCeiling: true'))
      .map((f) => relative(src, f).split(sep).join('/'));
    expect(users).toEqual(['queue/processors/backup.processor.ts']);
  });
});
