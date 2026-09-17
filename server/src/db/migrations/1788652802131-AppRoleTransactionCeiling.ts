import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * #213 — timeouts on `pos_app` behind ADR-0010's 30 s `?updatedSince=` rewind:
 * `statement_timeout = 25s` (a runaway-statement net under nginx's 30 s) and
 * `idle_in_transaction_session_timeout = 5s` (a transaction the app stalls with). They are
 * one half of the ceiling; the other is the commit guard in `TenantService.runTx` and
 * `TenantJobRunner`. What each bounds and the exact guarantee: `server/README.md`
 * *The transaction ceiling (#213)*. Keep the values in step with `APP_ROLE_TIMEOUTS`.
 *
 * Set on the role **in this database**, so every `pos_app` connection gets them at session
 * start and the owner (`postgres`: migrations, `ADMIN_DATA_SOURCE`) is untouched. Scoped
 * `IN DATABASE` so `schema.e2e-spec.ts` applying and reverting migrations in
 * `pos_schema_test` never clears them on `pos`.
 *
 * Id `…2131`, not `…2130`: an earlier draft of #215 shipped `5s`/`5s` under `…2130`, and a
 * database that ran it would never run a corrected migration of the same id. The ALTERs are
 * idempotent, so running this one after that one is harmless.
 */
export class AppRoleTransactionCeiling1788652802131 implements MigrationInterface {
  name = 'AppRoleTransactionCeiling1788652802131';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`
      DO $$
      BEGIN
        EXECUTE format('ALTER ROLE pos_app IN DATABASE %I SET statement_timeout = %L',
                       current_database(), '25s');
        EXECUTE format('ALTER ROLE pos_app IN DATABASE %I SET idle_in_transaction_session_timeout = %L',
                       current_database(), '5s');
      END $$`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`
      DO $$
      BEGIN
        EXECUTE format('ALTER ROLE pos_app IN DATABASE %I RESET statement_timeout',
                       current_database());
        EXECUTE format('ALTER ROLE pos_app IN DATABASE %I RESET idle_in_transaction_session_timeout',
                       current_database());
      END $$`);
  }
}
