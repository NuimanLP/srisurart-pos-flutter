import type { MigrationInterface, QueryRunner } from 'typeorm';
import { APP_ROLE } from './1788652800001-RowLevelSecurity.js';

/**
 * #399 — `audit_log` is append-only for `pos_app`, the same way `movements` is a ledger.
 *
 * `RowLevelSecurity1788652800001` granted `SELECT, INSERT, UPDATE, DELETE` on every table
 * except `movements`, so a compromised or buggy api/worker could rewrite or erase its own
 * audit trail. No `pos_app` code path updates or deletes `audit_log` (both `AuditService`s
 * only INSERT); the only deletes are test cleanups run as the owner (`postgres`), which
 * this REVOKE does not touch. FK referential actions run as the table owner, so they are
 * unaffected too. `TRUNCATE` was never granted to `pos_app` and stays absent.
 */
export class AuditLogAppendOnly1788652804100 implements MigrationInterface {
  name = 'AuditLogAppendOnly1788652804100';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`REVOKE UPDATE, DELETE ON audit_log FROM ${APP_ROLE}`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`GRANT UPDATE, DELETE ON audit_log TO ${APP_ROLE}`);
  }
}
