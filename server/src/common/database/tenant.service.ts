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
   * Runs a function with `app.tenant_id` set using transactional `SET LOCAL`.
   * Postgres automatically clears `SET LOCAL` on completion, ensuring no connection pool contamination.
   */
  async run<T>(tid: string, fn: (manager: EntityManager) => Promise<T>): Promise<T> {
    return this.runTx(tid, fn);
  }

  /**
   * Runs a function inside a Postgres transaction with `SET LOCAL app.tenant_id` set.
   * `SET LOCAL` is automatically cleared by Postgres when the transaction ends (commit/rollback).
   */
  async runTx<T>(tid: string, fn: (manager: EntityManager) => Promise<T>): Promise<T> {
    return this.ds.transaction(async (manager) => {
      await manager.query(`SET LOCAL app.tenant_id = $1`, [tid]);
      return fn(manager);
    });
  }
}
