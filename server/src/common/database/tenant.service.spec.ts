import { describe, expect, it, vi } from 'vitest';
import {
  currentRequestContext,
  currentTransaction,
  onTransactionCommit,
  runInRequestContext,
  runInTenantScope,
  setRequestTenant,
} from '../request-context.js';
import { TenantService } from './tenant.service.js';
import { CommitCeilingExceededError } from './commit-ceiling.js';

const TID = '00000000-0000-4000-8000-000000000150';

/** A pool whose query runners record what happened to them, in order. */
function fakePool() {
  const events: string[] = [];
  const runners: Array<Record<string, any>> = [];
  const ds = {
    createQueryRunner: vi.fn(() => {
      const qr: Record<string, any> = {
        isTransactionActive: false,
        isReleased: false,
        connect: vi.fn(async () => events.push('connect')),
        startTransaction: vi.fn(async () => {
          qr.isTransactionActive = true;
          events.push('begin');
        }),
        query: vi.fn(async (sql: string, params: unknown[]) => {
          events.push(`query ${sql} ${JSON.stringify(params)}`);
          return [];
        }),
        commitTransaction: vi.fn(async () => {
          qr.isTransactionActive = false;
          events.push('commit');
        }),
        rollbackTransaction: vi.fn(async () => {
          qr.isTransactionActive = false;
          events.push('rollback');
        }),
        release: vi.fn(async () => {
          qr.isReleased = true;
          events.push('release');
        }),
      };
      qr.manager = {
        queryRunner: qr,
        name: `manager-${runners.length}`,
        query: (sql: string, params: unknown[]) => qr.query(sql, params),
      };
      runners.push(qr);
      return qr;
    }),
  };
  const logger = { warn: vi.fn() };
  return {
    tenants: new TenantService(ds as any, logger as any),
    ds,
    runners,
    events,
    logger,
  };
}

/** A scope the way TenantGuard leaves it in `tx.4`: tenant named, no transaction open. */
function authorised<T>(fn: () => Promise<T>): Promise<T> {
  return runInTenantScope(async () => {
    setRequestTenant(TID);
    return fn();
  });
}

describe('TenantService.runTx (tx.1, #150)', () => {
  it('throws when the scope has no tenant, before touching the pool', async () => {
    const { tenants, ds } = fakePool();
    const work = vi.fn();

    // No scope at all.
    await expect(tenants.runTx(work)).rejects.toThrow(/No request context/);
    // A scope the guard never named a tenant on.
    await expect(runInTenantScope(() => tenants.runTx(work))).rejects.toThrow(
      /No tenant on this request/,
    );
    // A transaction already in scope but no tenant named: still no tenant, still no join.
    await expect(
      runInRequestContext({ manager: {} as any }, () => tenants.runTx(work)),
    ).rejects.toThrow(/No tenant on this request/);

    expect(work).not.toHaveBeenCalled();
    expect(ds.createQueryRunner).not.toHaveBeenCalled();
  });

  it('nested runTx joins: the same manager, one query runner, one BEGIN and one COMMIT', async () => {
    const { tenants, ds, runners, events } = fakePool();
    let outer: unknown;
    let inner: unknown;

    await authorised(() =>
      tenants.runTx(async (m1) => {
        outer = m1;
        await tenants.runTx(async (m2) => {
          inner = m2;
        });
      }),
    );

    expect(inner).toBe(outer);
    expect(ds.createQueryRunner).toHaveBeenCalledTimes(1);
    expect(outer).toBe(runners[0].manager);
    expect(events).toEqual([
      'connect',
      'begin',
      `query SELECT set_config('app.tenant_id', $1, true) ${JSON.stringify([TID])}`,
      'commit',
      'release',
    ]);
  });

  it('joins a transaction already published on the scope instead of taking a connection', async () => {
    const { tenants, ds } = fakePool();
    const requestManager = { name: 'request-manager' } as any;
    let seen: unknown;
    let ctx: unknown;

    await runInRequestContext({ manager: requestManager }, async () => {
      setRequestTenant(TID); // what TenantGuard does
      await tenants.runTx(async (m) => {
        seen = m;
        ctx = currentRequestContext();
      });
    });

    expect(seen).toBe(requestManager);
    expect(ctx).toEqual({ tenantId: TID, manager: requestManager });
    expect(ds.createQueryRunner).not.toHaveBeenCalled();
  });

  it('publishes the tenant and manager, so currentRequestContext() works inside a joined runTx', async () => {
    const { tenants, runners } = fakePool();
    const seen: unknown[] = [];

    await authorised(() =>
      tenants.runTx(async () => {
        seen.push(currentRequestContext());
        await tenants.runTx(async () => {
          seen.push(currentRequestContext());
        });
      }),
    );

    const expected = { tenantId: TID, manager: runners[0].manager };
    expect(seen).toEqual([expected, expected]);
  });

  it('rolls back, releases and rethrows when the work throws — and drops its post-commit hooks', async () => {
    const { tenants, runners, events } = fakePool();
    const hook = vi.fn();
    const boom = new Error('boom');

    await expect(
      authorised(() =>
        tenants.runTx(async () => {
          onTransactionCommit(hook);
          await tenants.runTx(async () => {
            throw boom;
          });
        }),
      ),
    ).rejects.toBe(boom);

    expect(runners).toHaveLength(1);
    expect(events.slice(-2)).toEqual(['rollback', 'release']);
    expect(runners[0].commitTransaction).not.toHaveBeenCalled();
    expect(hook).not.toHaveBeenCalled();
  });

  it('runs post-commit hooks registered inside (joined calls included) only after commit and release', async () => {
    const { tenants, events } = fakePool();

    await authorised(() =>
      tenants.runTx(async () => {
        onTransactionCommit(() => {
          events.push('outer hook');
        });
        await tenants.runTx(async () => {
          onTransactionCommit(() => {
            events.push('inner hook');
          });
        });
        expect(events).not.toContain('outer hook');
      }),
    );

    expect(events.slice(-4)).toEqual([
      'commit',
      'release',
      'outer hook',
      'inner hook',
    ]);
  });

  it('a joined runTx that throws never rolls back: the owner catches, and the inner writes commit', async () => {
    const { tenants, runners, events } = fakePool();

    await authorised(() =>
      tenants.runTx(async (m) => {
        try {
          await tenants.runTx(async (inner) => {
            await inner.query('INSERT inner', []);
            throw new Error('inner refused');
          });
        } catch {
          /* the owner swallows it */
        }
        await m.query('INSERT outer', []);
      }),
    );

    expect(runners).toHaveLength(1);
    expect(runners[0].rollbackTransaction).not.toHaveBeenCalled();
    expect(events.slice(-4)).toEqual([
      'query INSERT inner []',
      'query INSERT outer []',
      'commit',
      'release',
    ]);
  });

  it('runs hooks outside the transaction scope, so a hook never sees or joins the released manager', async () => {
    const { tenants, runners, logger } = fakePool();
    const err = new Error('hook down');
    let seenByHook: unknown = 'unset';

    await authorised(() =>
      tenants.runTx(async () => {
        onTransactionCommit(async () => {
          seenByHook = currentTransaction();
          await tenants.runTx(async () => undefined);
        });
        onTransactionCommit(() => {
          throw err;
        });
      }),
    );

    expect(seenByHook).toBeNull();
    // The hook's own runTx opened a fresh runner instead of joining the released one.
    expect(runners).toHaveLength(2);
    expect(runners[0].isReleased).toBe(true);
    expect(runners[1].commitTransaction).toHaveBeenCalledTimes(1);
    expect(logger.warn).toHaveBeenCalledWith(
      { err },
      'post-commit hook failed',
    );
  });

  it('a failed COMMIT releases the connection, rethrows and runs no hooks', async () => {
    const { tenants, ds, runners } = fakePool();
    const hook = vi.fn();
    const boom = new Error('commit failed');
    const make = ds.createQueryRunner.getMockImplementation() as () => any;
    ds.createQueryRunner.mockImplementationOnce(() => {
      const qr = make();
      qr.commitTransaction = vi.fn(async () => {
        throw boom;
      });
      return qr;
    });

    await expect(
      authorised(() =>
        tenants.runTx(async () => {
          onTransactionCommit(hook);
        }),
      ),
    ).rejects.toBe(boom);

    expect(runners[0].rollbackTransaction).toHaveBeenCalledTimes(1);
    expect(runners[0].release).toHaveBeenCalledTimes(1);
    expect(hook).not.toHaveBeenCalled();
  });

  it('a failed connect releases the runner, rethrows and never runs the work', async () => {
    const { tenants, ds, runners } = fakePool();
    const work = vi.fn();
    const boom = new Error('pool exhausted');
    const make = ds.createQueryRunner.getMockImplementation() as () => any;
    ds.createQueryRunner.mockImplementationOnce(() => {
      const qr = make();
      qr.connect = vi.fn(async () => {
        throw boom;
      });
      return qr;
    });

    await expect(authorised(() => tenants.runTx(work))).rejects.toBe(boom);

    expect(work).not.toHaveBeenCalled();
    expect(runners[0].release).toHaveBeenCalledTimes(1);
  });

  it("a joined runTx leaves the owner's hooks to the owner", async () => {
    const { tenants } = fakePool();
    const hook = vi.fn();

    await runInRequestContext({ manager: {} as any }, async () => {
      setRequestTenant(TID);
      await tenants.runTx(async () => {
        onTransactionCommit(hook);
      });
      // Whoever published the manager owns its commit and its hooks, not the joined runTx.
      expect(hook).not.toHaveBeenCalled();
    });
  });
});

describe('onTransactionCommit with no open transaction (tx.4, #153)', () => {
  // With the request-wide transaction gone, a request scope outside `runTx` has no commit
  // to wait for. The hook must neither run early nor sit on a scope nobody ends.
  it('throws in a request scope outside runTx, and the hook never runs', async () => {
    const hook = vi.fn();
    await authorised(async () => {
      expect(() => onTransactionCommit(hook)).toThrow(/needs an open transaction/);
    });
    expect(hook).not.toHaveBeenCalled();
  });

  it('throws outside any scope instead of running the hook at once', () => {
    const hook = vi.fn();
    expect(() => onTransactionCommit(hook)).toThrow(/needs an open transaction/);
    expect(hook).not.toHaveBeenCalled();
  });

  it('a hook registered inside runTx, in a scope that outlives it, runs once after that commit', async () => {
    const { tenants, events } = fakePool();
    await authorised(async () => {
      await tenants.runTx(async () => {
        onTransactionCommit(() => {
          events.push('hook');
        });
      });
      expect(events.slice(-3)).toEqual(['commit', 'release', 'hook']);
      // Back in the request scope: no transaction, so a late registration is refused.
      expect(() => onTransactionCommit(() => undefined)).toThrow(/needs an open transaction/);
    });
    expect(events.filter((e) => e === 'hook')).toHaveLength(1);
  });
});

describe('TenantService.runTx commit guard (#213)', () => {
  it('rolls back instead of committing a transaction older than the ceiling', async () => {
    const { tenants, events } = fakePool();
    tenants.commitCeilingMs = 10;
    const hook = vi.fn();
    await authorised(async () => {
      await expect(
        tenants.runTx(async () => {
          onTransactionCommit(hook);
          await new Promise((r) => setTimeout(r, 30));
        }),
      ).rejects.toThrow(CommitCeilingExceededError);
    });
    expect(events).not.toContain('commit');
    expect(events.slice(-2)).toEqual(['rollback', 'release']);
    expect(hook).not.toHaveBeenCalled();
  });

  it('commits a transaction under the ceiling', async () => {
    const { tenants, events } = fakePool();
    await authorised(() => tenants.runTx(async () => undefined));
    expect(events.slice(-2)).toEqual(['commit', 'release']);
  });
});
