import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Slice 1 (#278 `role.1`, 08_PHASE2_SPEC §3, 09_PHASE2_LANES §3):
 *
 * Single owner role per tenant:
 * 1. Migrate all existing users to role = 'owner'.
 * 2. Enforce only one active user per tenant: keep the oldest active user (created_at ASC, id ASC)
 *    and set any other active users to is_active = false.
 * 3. Create unique partial index `uq_users_one_active` ON users (tenant_id) WHERE is_active.
 * 4. Update check constraint on `role` to CHECK (role = 'owner').
 * 5. Drop `pin_hash` column from `users` (manager PIN removed; online void requires reason instead).
 */
export class SingleOwnerRole1788652803001 implements MigrationInterface {
  name = 'SingleOwnerRole1788652803001';

  async up(q: QueryRunner): Promise<void> {
    // 1. All users become owner
    await q.query(`UPDATE users SET role = 'owner'`);

    // 2. Keep only the oldest active user per tenant active
    await q.query(`
      WITH ranked AS (
        SELECT tenant_id, id,
               ROW_NUMBER() OVER (PARTITION BY tenant_id ORDER BY created_at ASC, id ASC) as rn
        FROM users
        WHERE is_active = true
      )
      UPDATE users
      SET is_active = false
      WHERE (tenant_id, id) IN (
        SELECT tenant_id, id FROM ranked WHERE rn > 1
      )
    `);

    // 3. Unique index: one active user per tenant
    await q.query(
      `CREATE UNIQUE INDEX uq_users_one_active ON users (tenant_id) WHERE is_active`,
    );

    // 4. Update role check constraint
    await q.query(`ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check`);
    await q.query(`ALTER TABLE users ADD CONSTRAINT users_role_check CHECK (role = 'owner')`);

    // 5. Drop pin_hash column
    await q.query(`ALTER TABLE users DROP COLUMN IF EXISTS pin_hash`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS pin_hash TEXT`);
    await q.query(`ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check`);
    await q.query(
      `ALTER TABLE users ADD CONSTRAINT users_role_check CHECK (role IN ('owner','manager','cashier'))`,
    );
    await q.query(`DROP INDEX IF EXISTS uq_users_one_active`);
  }
}
