import { Injectable, Logger } from '@nestjs/common';
import { DataSource, EntityManager } from 'typeorm';

/**
 * Handles executing database operations within a Postgres RLS context (app.tenant_id).
 * This ensures that a connection pool connection is properly scoped to the tenant
 * and reset afterwards, preventing data leaks across tenants.
 */
@Injectable()
export class TenantService {
  private readonly logger = new Logger(TenantService.name);

  constructor(private readonly ds: DataSource) {}

  /**
   * Runs a function with `app.tenant_id` set for the duration of one transaction.
   * Postgres clears a transaction-scoped setting on completion, ensuring no
   * connection pool contamination.
   */
  async run<T>(tid: string, fn: (manager: EntityManager) => Promise<T>): Promise<T> {
    return this.runTx(tid, fn);
  }

  /**
   * Runs a function inside a Postgres transaction scoped to `tid`.
   * `set_config(..., true)` is the transaction-local form, cleared by Postgres when
   * the transaction ends (commit/rollback). It is deliberately not the `SET LOCAL
   * app.tenant_id = $1` spelling: SET is a utility statement, takes no bind
   * parameter, and that form fails with 42601 on every call.
   */
  async runTx<T>(tid: string, fn: (manager: EntityManager) => Promise<T>): Promise<T> {
    return this.ds.transaction(async (manager) => {
      await manager.query(`SELECT set_config('app.tenant_id', $1, true)`, [tid]);
      return fn(manager);
    });
  }
}
