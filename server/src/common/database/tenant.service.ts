import { Inject, Injectable } from '@nestjs/common';
import type { Logger } from 'pino';
import { DataSource, EntityManager } from 'typeorm';
import { LOGGER } from '../../infra/logger.provider.js';
import {
  assertWithinCommitCeiling,
  commitClockStart,
  TX_COMMIT_CEILING_MS,
} from './commit-ceiling.js';
import {
  authorisedTenantId,
  currentTransaction,
  executePostCommitHooks,
  runInTransaction,
  takePostCommitHooks,
} from '../request-context.js';

/**
 * The tenant door: the one way code obtains an `EntityManager` that RLS answers for, under
 * the tenant `TenantGuard` authorised (ADR-0003 addendum *"ใครตัดสิน กับ ใครลงมือ"* — the
 * guard decides, this executes).
 */
@Injectable()
export class TenantService {
  /**
   * The commit guard's ceiling (#213). A field only so an e2e can lower it instead of
   * sleeping 25 s; production never assigns it.
   */
  commitCeilingMs = TX_COMMIT_CEILING_MS;

  constructor(
    private readonly ds: DataSource,
    @Inject(LOGGER) private readonly logger: Logger,
  ) {}

  /**
   * Runs `fn` in a transaction scoped to the request's authorised tenant.
   *
   * 🔴 **The tenant is not a parameter, and never will be.** It comes from the request
   * scope, where only `TenantGuard` puts it. A `runTx(tid, fn)` would let any call site
   * pass another shop's uuid and get its rows back with no error. With no tenant on the
   * scope this throws before touching the pool.
   *
   * 🔴 **Joins, never nests.** If this scope already has a transaction open — an outer
   * `runTx` (since tx.4 #153 there is no request-wide one) — `fn` runs on that
   * same manager: no second connection (holding one while waiting for another is the pool
   * deadlock of #162), no savepoint, and the outer owner commits. That scope already names
   * the tenant, so `currentRequestContext()` works inside, and post-commit hooks land on the
   * owner's list.
   *
   * 🔴 **A joined call never rolls back on its own.** Its writes belong to the owner's
   * transaction: catching a joined `runTx`'s error does NOT undo what it already wrote —
   * those rows commit with the owner. And if the error was a Postgres error, the owner's
   * transaction is already aborted, so its next statement fails with 25P02. Let the error
   * propagate to the owner.
   *
   * 🔴 **Calls in parallel do not join each other.** `Promise.all([runTx(a), runTx(b)])`
   * with no transaction open takes two connections at once — the #162 pool-deadlock shape
   * under a burst, and two snapshots instead of one. Run them in one `runTx` instead.
   *
   * 🔴 **The owner refuses to commit past `commitCeilingMs`** (25 s, #213): it rolls back
   * and throws `CommitCeilingExceededError` (a 500) instead. A joined call is covered by
   * its owner's check. See README *The transaction ceiling (#213)*.
   *
   * Otherwise it opens one: `set_config('app.tenant_id', …, true)` (the transaction-local
   * form; `SET LOCAL app.tenant_id = $1` is a 42601 — see `tenant-scope.spec.ts`), runs `fn`
   * with the manager published, commits or rolls back and returns the connection. Only then
   * does it run the hooks registered inside — outside the transaction's scope, so a hook
   * never sees the released manager (a hook's own `runTx` opens a fresh transaction).
   */
  async runTx<T>(fn: (manager: EntityManager) => Promise<T>): Promise<T> {
    const tenantId = authorisedTenantId();
    const open = currentTransaction();
    if (open) return fn(open);

    const qr = this.ds.createQueryRunner();
    let value: T;
    let hooks: ReturnType<typeof takePostCommitHooks> = [];
    try {
      await qr.connect();
      const startedAt = commitClockStart();
      await qr.startTransaction();
      value = await runInTransaction(
        { tenantId, manager: qr.manager },
        async () => {
          await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [
            tenantId,
          ]);
          const result = await fn(qr.manager);
          hooks = takePostCommitHooks();
          return result;
        },
      );
      // #213: never commit a transaction older than the ceiling — its `now()` stamps could
      // land behind a client's rewound cursor. Throwing here rolls it back below.
      assertWithinCommitCeiling(startedAt, this.commitCeilingMs);
      await qr.commitTransaction();
    } catch (err) {
      try {
        if (qr.isTransactionActive) await qr.rollbackTransaction();
      } catch {
        /* the original error is the one worth reporting */
      }
      throw err;
    } finally {
      if (!qr.isReleased) await qr.release();
    }
    await executePostCommitHooks(
      (err) => this.logger.warn({ err }, 'post-commit hook failed'),
      hooks,
    );
    return value;
  }
}
