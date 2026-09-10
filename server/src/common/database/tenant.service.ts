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
   * Runs a function with a QueryRunner that has `app.tenant_id` set.
   * Useful for reads or non-transactional writes.
   */
  async run<T>(tid: string, fn: (manager: EntityManager) => Promise<T>): Promise<T> {
    const qr = this.ds.createQueryRunner();
    await qr.connect();
    try {
      await qr.query(`SET app.tenant_id = $1`, [tid]);
      return await fn(qr.manager);
    } finally {
      try {
        await qr.query(`RESET app.tenant_id`);
      } catch (err) {
        this.logger.error(`Failed to reset app.tenant_id: ${err}`);
      }
      await qr.release();
    }
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
