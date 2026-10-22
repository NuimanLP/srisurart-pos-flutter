import { describe, expect, it, vi } from 'vitest';
import { runInTenantScope, setRequestTenant } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { JOB_QUOTES_PURGE } from '../queue/queue.constants.js';
import { QuotesController } from './quotes.controller.js';

const TID = '00000000-0000-4000-8000-000000000750';

/** Just enough of an Express request for `idempotencyParamsOf`. */
function fakeReq(key: string, body: unknown) {
  const headers = { 'idempotency-key': key };
  return {
    headers,
    header: (name: string) => (headers as Record<string, string>)[name.toLowerCase()],
    method: 'POST',
    baseUrl: '/api/v1/quotes',
    path: '/purge',
    body,
  } as any;
}

/** One pooled connection that logs what happened to it, in order. */
function fakePool(events: string[]) {
  const ds = {
    createQueryRunner: () => {
      const qr: Record<string, any> = {
        isTransactionActive: false,
        isReleased: false,
        connect: async () => events.push('connect'),
        startTransaction: async () => {
          qr.isTransactionActive = true;
          events.push('begin');
        },
        query: async () => [],
        commitTransaction: async () => {
          qr.isTransactionActive = false;
          events.push('commit');
        },
        rollbackTransaction: async () => {
          qr.isTransactionActive = false;
          events.push('rollback');
        },
        release: async () => {
          qr.isReleased = true;
          events.push('release');
        },
      };
      qr.manager = { queryRunner: qr, query: qr.query };
      return qr;
    },
  };
  return new TenantService(ds as any, { warn: vi.fn() } as any);
}

describe('POST /quotes/purge — enqueue after commit (review 2026-10-21)', () => {
  it('adds the job only after the transaction committed and released its connection', async () => {
    const events: string[] = [];
    const queue = {
      add: vi.fn(async () => {
        events.push('queue.add');
        return { id: 'ignored' };
      }),
    };
    // `runIdempotent` reduced to "run the work inside the caller's transaction".
    const idempotency = { runIdempotent: (_p: unknown, _r: unknown, fn: () => unknown) => fn() };
    const controller = new QuotesController(
      queue as any,
      {} as any,
      fakePool(events),
      idempotency as any,
    );
    const req = fakeReq('k-purge-1', { olderThanDays: 90 });

    const reply = await runInTenantScope(async () => {
      setRequestTenant(TID);
      return controller.purgeQuotes(req, { olderThanDays: 90 }, {} as any);
    });

    expect(events).toEqual(['connect', 'begin', 'commit', 'release', 'queue.add']);
    expect(reply).toEqual({
      queued: true,
      jobId: `quotes-purge:${TID}:k-purge-1`,
      olderThanDays: 90,
    });
    expect(queue.add).toHaveBeenCalledWith(
      JOB_QUOTES_PURGE,
      expect.objectContaining({ tenantId: TID, olderThanDays: 90 }),
      { jobId: `quotes-purge:${TID}:k-purge-1` },
    );
  });

  it('never adds the job when the request is refused inside the transaction', async () => {
    const events: string[] = [];
    const queue = { add: vi.fn() };
    const idempotency = { runIdempotent: (_p: unknown, _r: unknown, fn: () => unknown) => fn() };
    const controller = new QuotesController(
      queue as any,
      {} as any,
      fakePool(events),
      idempotency as any,
    );
    const req = fakeReq('k-purge-2', { olderThanDays: -1 });

    await expect(
      runInTenantScope(async () => {
        setRequestTenant(TID);
        return controller.purgeQuotes(req, { olderThanDays: -1 }, {} as any);
      }),
    ).rejects.toThrow();

    expect(events).toContain('rollback');
    expect(queue.add).not.toHaveBeenCalled();
  });
});
