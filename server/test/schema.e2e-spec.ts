import { Client } from 'pg';
import {
  createMigrationDataSource,
  MIGRATIONS,
} from '../src/db/data-source.js';
import {
  ALL_TABLES as INITIAL_ALL_TABLES,
  APP_ROLE,
  TENANT_SCOPED_TABLES as INITIAL_TENANT_SCOPED_TABLES,
} from '../src/db/migrations/1788652800001-RowLevelSecurity.js';
import { ENTITY_FKS } from '../src/db/migrations/1788652804900-EntityIdsToUuid.js';
import { SEED_CATEGORIES, seedCategories } from '../src/db/seed.js';
import { testId } from './support/test-ids.js';

const OWNER_REVIEW_ITEMS_TABLE = 'owner_review_items';
const TENANT_SCOPED_TABLES = [
  ...INITIAL_TENANT_SCOPED_TABLES,
  OWNER_REVIEW_ITEMS_TABLE,
] as const;
const ALL_TABLES = [...INITIAL_ALL_TABLES, OWNER_REVIEW_ITEMS_TABLE] as const;

// #15 acceptance suite. Runs the REAL migrations into a throwaway database on the
// compose Postgres (127.0.0.1:5432, published by docker-compose.dev.yml) — never synchronize, never mocks. The owner
// connection is `postgres`; the application connection is `pos_app`, exactly as in prod.
const ADMIN_URL =
  process.env.DATABASE_ADMIN_URL ??
  'postgres://postgres:dev-only-postgres@127.0.0.1:5432/postgres';
const APP_PASSWORD = process.env.POS_APP_PASSWORD ?? 'dev-only-pos-app';
const TEST_DB = 'pos_schema_test';

const withDb = (url: string, db: string) =>
  url.replace(/\/[^/?]*(\?|$)/, `/${db}$1`);
const OWNER_URL = withDb(ADMIN_URL, TEST_DB);
const APP_URL = OWNER_URL.replace(
  /\/\/[^@]*@/,
  `//${APP_ROLE}:${APP_PASSWORD}@`,
);

const TENANT_A = '11111111-1111-4111-8111-111111111111';
const TENANT_B = '22222222-2222-4222-8222-222222222222';

async function connect(url: string): Promise<Client> {
  const c = new Client({ connectionString: url });
  await c.connect();
  return c;
}

async function tableNames(c: Client): Promise<string[]> {
  const r = await c.query<{ tablename: string }>(
    `SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'migrations' ORDER BY 1`,
  );
  return r.rows.map((x) => x.tablename);
}

const P1 = testId('p1');
const S1 = testId('s1');
const RI_NULL = testId('ri-null');
const RI_FK = testId('ri-fk');

/** One product per tenant, inserted as owner (= superuser, which bypasses RLS). */
async function insertFixtureProducts(owner: Client): Promise<void> {
  await owner.query(
    `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock)
     VALUES ($1, $3, 'BP-100', 'Front brake pad', 'ผ้าเบรกหน้า', 'เบรก', 'TRW', 450, 300, 5),
            ($2, $3, 'OF-200', 'Oil filter',      'กรองน้ำมัน',  'น้ำมัน', 'Bosch', 120, 80, 9)`,
    [TENANT_A, TENANT_B, P1],
  );
}

async function migrateUp(): Promise<void> {
  const ds = createMigrationDataSource(OWNER_URL);
  await ds.initialize();
  try {
    await ds.runMigrations({ transaction: 'each' });
  } finally {
    await ds.destroy();
  }
}

describe('schema (e2e) — #15 migrations, RLS, seed', () => {
  let admin: Client;
  let owner: Client;
  let app: Client;

  beforeAll(async () => {
    admin = await connect(ADMIN_URL);
    await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
    await admin.query(`CREATE DATABASE ${TEST_DB}`);
    await migrateUp();
    owner = await connect(OWNER_URL);
    app = await connect(APP_URL);

    // Fixture (as owner = superuser, which bypasses RLS): two tenants, one product each.
    await owner.query(
      `INSERT INTO tenants (id, code, shop_name) VALUES ($1, 'a', 'ร้าน A'), ($2, 'b', 'ร้าน B')`,
      [TENANT_A, TENANT_B],
    );
    await insertFixtureProducts(owner);
  }, 60_000);

  afterAll(async () => {
    await app?.end();
    await owner?.end();
    await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
    await admin.end();
  });

  // #239: `import_jobs` carries a `tenant_id` column (for lookup) but is neither a
  // `GLOBAL_TABLE` (that category means "no tenant_id at all") nor a `TENANT_SCOPED_TABLE`
  // (RLS would be theatre: `pos_app` never touches it, only `ADMIN_DATA_SOURCE`) — its own
  // migration explains why it could not simply be appended to either exported list.
  const IMPORT_JOBS_TABLE = 'import_jobs';

  it('runs from an empty database to exactly 29 tables (27 + import_jobs + owner_review_items), without change_log', async () => {
    const tables = await tableNames(owner);
    expect(tables).toHaveLength(29);
    expect(tables).toEqual([...ALL_TABLES, IMPORT_JOBS_TABLE].sort());
    expect(tables).not.toContain('change_log');
  });

  it('every tenant-scoped table carries tenant_id in its primary key (import_jobs included)', async () => {
    const r = await owner.query<{ table_name: string; columns: string[] }>(
      `SELECT c.conrelid::regclass::text AS table_name,
              array_agg(a.attname::text ORDER BY k.ord) AS columns
         FROM pg_constraint c
         JOIN unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
         JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
        WHERE c.contype = 'p' AND c.connamespace = 'public'::regnamespace
        GROUP BY 1`,
    );
    const pk = new Map(r.rows.map((x) => [x.table_name, x.columns]));
    for (const t of TENANT_SCOPED_TABLES) {
      expect(pk.get(t), `${t} primary key`).toContain('tenant_id');
    }
    expect(pk.get(IMPORT_JOBS_TABLE), `${IMPORT_JOBS_TABLE} primary key`).toContain('tenant_id');
    expect(pk.get('tenants')).toEqual(['id']);
    expect(pk.get('platform_admins')).toEqual(['id']);
  });

  it('RLS is enabled and forced on every tenant-scoped table, with one policy each — import_jobs gets none', async () => {
    const r = await owner.query<{
      relname: string;
      rls: boolean;
      forced: boolean;
      policies: number;
    }>(
      `SELECT c.relname, c.relrowsecurity AS rls, c.relforcerowsecurity AS forced,
              (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid)::int AS policies
         FROM pg_class c
        WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'`,
    );
    const byName = new Map(r.rows.map((x) => [x.relname, x]));
    for (const t of TENANT_SCOPED_TABLES) {
      expect(byName.get(t), t).toMatchObject({
        rls: true,
        forced: true,
        policies: 1,
      });
    }
    expect(byName.get('tenants')).toMatchObject({ rls: false, policies: 0 });
    // #239: no RLS at all — only ADMIN_DATA_SOURCE (which bypasses RLS regardless) ever
    // touches this table, so a policy would guard nothing real.
    expect(byName.get(IMPORT_JOBS_TABLE)).toMatchObject({ rls: false, forced: false, policies: 0 });
  });

  it(`${APP_ROLE} is neither superuser, BYPASSRLS, nor the owner of any table`, async () => {
    const role = await owner.query(
      `SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = $1`,
      [APP_ROLE],
    );
    expect(role.rows[0]).toEqual({ rolsuper: false, rolbypassrls: false });
    const owned = await owner.query(
      `SELECT count(*)::int AS n FROM pg_tables WHERE schemaname = 'public' AND tableowner = $1`,
      [APP_ROLE],
    );
    expect(owned.rows[0].n).toBe(0);
  });

  it('with app.tenant_id unset the app role reads ZERO rows and cannot write — no error on read', async () => {
    const read = await app.query(`SELECT count(*)::int AS n FROM products`);
    expect(read.rows[0].n).toBe(0);

    await expect(
      app.query(
        `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock)
         VALUES ($1, $2, 'X', 'x', 'x', 'x', 'x', 1, 1, 1)`,
        [TENANT_A, testId('p9')],
      ),
    ).rejects.toMatchObject({ code: '42501' }); // new row violates row-level security policy
  });

  it('SET LOCAL app.tenant_id scopes reads to that tenant and does not leak past COMMIT', async () => {
    await app.query('BEGIN');
    await app.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT_A]);
    const inTx = await app.query(`SELECT tenant_id, name_th FROM products`);
    expect(inTx.rows).toEqual([
      { tenant_id: TENANT_A, name_th: 'ผ้าเบรกหน้า' },
    ]);
    await app.query('COMMIT');

    // Same pooled connection, transaction over: the GUC is gone → fail-closed again.
    const after = await app.query(`SELECT count(*)::int AS n FROM products`);
    expect(after.rows[0].n).toBe(0);
  });

  it(`${APP_ROLE} cannot bypass RLS by turning row_security off`, async () => {
    await app.query(`SET row_security = off`);
    try {
      await expect(app.query(`SELECT * FROM products`)).rejects.toMatchObject({
        code: '42501',
      });
    } finally {
      await app.query(`RESET row_security`);
    }
  });

  it('a Thai substring query finds a term in the middle of a product name via the trigram index', async () => {
    const searchable = `lower(part_no || ' ' || name || ' ' || name_th || ' ' || COALESCE(compat, ''))`;
    await app.query('BEGIN');
    await app.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT_A]);
    const hit = await app.query(
      `SELECT name_th FROM products WHERE ${searchable} ILIKE '%' || lower($1) || '%'`,
      ['เบรก'],
    );
    expect(hit.rows).toEqual([{ name_th: 'ผ้าเบรกหน้า' }]);
    await app.query('ROLLBACK');

    // Two rows would be seq-scanned; with seqscan off (and no RLS tenant predicate to
    // tempt the btree) the only index that can serve this shape is the trigram GIN.
    await owner.query('BEGIN');
    await owner.query(`SET LOCAL enable_seqscan = off`);
    const plan = await owner.query(
      `EXPLAIN SELECT name_th FROM products WHERE ${searchable} ILIKE '%' || lower($1) || '%'`,
      ['เบรก'],
    );
    await owner.query('ROLLBACK');
    expect(plan.rows.map((r) => r['QUERY PLAN']).join('\n')).toContain(
      'idx_products_search',
    );
  });

  it('movements: legacy adjustments without ref_id coexist; a replayed ref is rejected; UPDATE/DELETE denied', async () => {
    await app.query('BEGIN');
    await app.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT_A]);
    const adj = (id: string) =>
      app.query(
        `INSERT INTO movements (tenant_id, id, product_id, part_no, name, delta, type, stock_after)
         VALUES ($1, $2, $3, 'BP-100', 'Front brake pad', 1, 'adjustment-in', 6)`,
        [TENANT_A, testId(id), P1],
      );
    await adj('m1');
    await adj('m2'); // same (type, product), both ref_id NULL → allowed
    const sale = (id: string) =>
      app.query(
        `INSERT INTO movements (tenant_id, id, product_id, part_no, name, delta, type, stock_after, ref_id)
         VALUES ($1, $2, $3, 'BP-100', 'Front brake pad', -1, 'sale', 5, $4)`,
        [TENANT_A, testId(id), P1, S1],
      );
    await sale('m3');
    await app.query('SAVEPOINT replay');
    await expect(sale('m4')).rejects.toMatchObject({
      code: '23505',
      constraint: 'uq_movements_ref',
    });
    await app.query('ROLLBACK TO SAVEPOINT replay');
    await expect(
      app.query(`DELETE FROM movements WHERE id = $1`, [testId('m1')]),
    ).rejects.toMatchObject({
      code: '42501',
    });
    await app.query('ROLLBACK');
  });

  it('audit_log is append-only for pos_app: INSERT/SELECT work under RLS, UPDATE/DELETE/TRUNCATE denied (#399)', async () => {
    await app.query('BEGIN');
    await app.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT_A]);
    await app.query(
      `INSERT INTO audit_log (tenant_id, action, entity) VALUES ($1, 'system.test-399', 'audit_log')`,
      [TENANT_A],
    );
    const seen = await app.query(
      `SELECT count(*)::int AS n FROM audit_log WHERE action = 'system.test-399'`,
    );
    expect(seen.rows[0].n).toBe(1);
    // RLS still scopes the read: the same row is invisible under another tenant.
    await app.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT_B]);
    const other = await app.query(
      `SELECT count(*)::int AS n FROM audit_log WHERE action = 'system.test-399'`,
    );
    expect(other.rows[0].n).toBe(0);
    await app.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT_A]);
    for (const sql of [
      `UPDATE audit_log SET action = 'system.tampered' WHERE action = 'system.test-399'`,
      `DELETE FROM audit_log WHERE action = 'system.test-399'`,
      `TRUNCATE audit_log`,
    ]) {
      await app.query('SAVEPOINT denied');
      await expect(app.query(sql), sql).rejects.toMatchObject({ code: '42501' });
      await app.query('ROLLBACK TO SAVEPOINT denied');
    }
    await app.query('ROLLBACK');
  });

  it('owner_review_items: an emptied app.tenant_id fails closed with 0 rows, not 22P02 (…4200)', async () => {
    await owner.query(
      `INSERT INTO owner_review_items (tenant_id, id, kind, ref_id) VALUES ($1, $2, 'date_flag', $3)`,
      [TENANT_A, RI_NULL, S1],
    );
    try {
      // A fresh connection returns NULL for the unset GUC and never exposed the bug;
      // after a SET LOCAL + COMMIT on the same (pooled) connection it reads back '',
      // which is what `''::uuid` choked on.
      await app.query('BEGIN');
      await app.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT_A]);
      const inTx = await app.query(
        `SELECT count(*)::int AS n FROM owner_review_items WHERE id = $1`,
        [RI_NULL],
      );
      expect(inTx.rows[0].n).toBe(1);
      await app.query('COMMIT');
      const guc = await app.query(
        `SELECT current_setting('app.tenant_id', true) AS v`,
      );
      expect(guc.rows[0].v).toBe('');

      const after = await app.query(
        `SELECT count(*)::int AS n FROM owner_review_items`,
      );
      expect(after.rows[0].n).toBe(0);
      await expect(
        app.query(
          `INSERT INTO owner_review_items (tenant_id, id, kind, ref_id) VALUES ($1, $2, 'date_flag', $3)`,
          [TENANT_A, testId('ri-x'), S1],
        ),
      ).rejects.toMatchObject({ code: '42501' });
    } finally {
      await owner.query(`DELETE FROM owner_review_items WHERE id = $1`, [RI_NULL]);
    }
  });

  it('owner_review_items: deleting the reviewer nulls only reviewed_by, the item keeps its tenant (…4200)', async () => {
    const user = await owner.query<{ id: string }>(
      `INSERT INTO users (tenant_id, username, password_hash, display_name, role)
       VALUES ($1, 'reviewer-4200', 'x', 'Reviewer', 'owner') RETURNING id`,
      [TENANT_A],
    );
    const reviewer = user.rows[0].id;
    await owner.query(
      `INSERT INTO owner_review_items (tenant_id, id, kind, ref_id, reviewed_at, reviewed_by)
       VALUES ($1, $3, 'void_offline', $4, now(), $2)`,
      [TENANT_A, reviewer, RI_FK, S1],
    );
    try {
      await owner.query(`DELETE FROM users WHERE tenant_id = $1 AND id = $2`, [
        TENANT_A,
        reviewer,
      ]);
      const r = await owner.query(
        `SELECT tenant_id, reviewed_by, reviewed_at IS NOT NULL AS reviewed
           FROM owner_review_items WHERE id = $1`,
        [RI_FK],
      );
      expect(r.rows).toEqual([
        { tenant_id: TENANT_A, reviewed_by: null, reviewed: true },
      ]);
    } finally {
      await owner.query(`DELETE FROM owner_review_items WHERE id = $1`, [RI_FK]);
      await owner.query(`DELETE FROM users WHERE username = 'reviewer-4200'`);
    }
  });

  it('users: must_change_password and temp_password_expires_at can never disagree (…4500, #443)', async () => {
    // Existing rows default to "no temporary password".
    const def = await owner.query(
      `INSERT INTO users (tenant_id, username, password_hash, display_name, role)
       VALUES ($1, 'ck-4500-default', 'x', 'X', 'owner')
       RETURNING must_change_password, temp_password_expires_at, password_changed_at`,
      [TENANT_A],
    );
    try {
      expect(def.rows).toEqual([
        { must_change_password: false, temp_password_expires_at: null, password_changed_at: null },
      ]);
      for (const [flag, expiry] of [
        ['true', 'NULL'],
        ['false', "now() + interval '1 day'"],
      ]) {
        await expect(
          owner.query(
            `UPDATE users SET must_change_password = ${flag}, temp_password_expires_at = ${expiry}
              WHERE tenant_id = $1 AND username = 'ck-4500-default'`,
            [TENANT_A],
          ),
        ).rejects.toThrow(/ck_users_temp_password_expiry/);
      }
      await owner.query(
        `UPDATE users SET must_change_password = true, temp_password_expires_at = now() + interval '1 day'
          WHERE tenant_id = $1 AND username = 'ck-4500-default'`,
        [TENANT_A],
      );
      // The re-created lookup returns the new columns to the app role.
      const r = await app.query(
        `SELECT must_change_password, temp_password_expires_at IS NOT NULL AS has_expiry
           FROM auth_lookup_user_for_login('ck-4500-default', $1)`,
        [TENANT_A],
      );
      expect(r.rows).toEqual([{ must_change_password: true, has_expiry: true }]);
    } finally {
      await owner.query(`DELETE FROM users WHERE username = 'ck-4500-default'`);
    }
  });

  it('platform_admins: an admin existing before …4600 gets password_changed_at backfilled to now(), not left NULL (#443)', async () => {
    // Roll back down to …4600 (drops password_changed_at) — …4700 (#27 follow-up), …4800
    // (PR #580 follow-up) and …4900 (#616) came after it — insert an admin as if it had existed beforehand, then re-run migrations: a fresh
    // DataSource instance sees the rest as already applied and executes only those four,
    // exactly like a real deploy. …4900 refuses a database with business rows, so the
    // product fixture is taken out for the re-run and put back afterwards.
    await app.end();
    const ds = createMigrationDataSource(OWNER_URL);
    await ds.initialize();
    try {
      await ds.undoLastMigration({ transaction: 'each' }); // …4900
      await ds.undoLastMigration({ transaction: 'each' }); // …4800
      await ds.undoLastMigration({ transaction: 'each' }); // …4700
      await ds.undoLastMigration({ transaction: 'each' }); // …4600
      const inserted = await owner.query(
        `INSERT INTO platform_admins (username, password_hash, display_name)
         VALUES ('pre-4600-admin', 'x', 'X') RETURNING id`,
      );
      const id = inserted.rows[0].id;
      try {
        await owner.query(`DELETE FROM products`);
        const before = Date.now();
        const ran = await ds.runMigrations({ transaction: 'each' });
        await insertFixtureProducts(owner);
        expect(ran.map((m) => m.name)).toEqual([
          'PlatformAdminPasswordChangedAt1788652804600',
          'ReviewItemQuoteConflict1788652804700',
          'ReviewItemDrawerOverdrawnOffline1788652804800',
          'EntityIdsToUuid1788652804900',
        ]);
        const r = await owner.query(
          `SELECT password_changed_at FROM platform_admins WHERE id = $1`,
          [id],
        );
        expect(r.rows[0].password_changed_at).not.toBeNull();
        expect(new Date(r.rows[0].password_changed_at).getTime()).toBeGreaterThanOrEqual(
          before - 5000,
        );
      } finally {
        await owner.query(`DELETE FROM platform_admins WHERE id = $1`, [id]);
      }
    } finally {
      await ds.destroy();
    }
    app = await connect(APP_URL);
  });

  it(`${APP_ROLE} has DML on every table (movements and audit_log insert-only) and none on the migrations table`, async () => {
    const APPEND_ONLY: readonly string[] = ['movements', 'audit_log'];
    for (const t of ALL_TABLES) {
      const r = await owner.query(
        `SELECT has_table_privilege($1, $2, 'SELECT') AS s, has_table_privilege($1, $2, 'INSERT') AS i,
                has_table_privilege($1, $2, 'UPDATE') AS u, has_table_privilege($1, $2, 'DELETE') AS d`,
        [APP_ROLE, t],
      );
      const expected = APPEND_ONLY.includes(t)
        ? { s: true, i: true, u: false, d: false }
        : { s: true, i: true, u: true, d: true };
      expect(r.rows[0], t).toEqual(expected);
    }
    const mig = await owner.query(
      `SELECT has_table_privilege($1, 'migrations', 'SELECT') AS s`,
      [APP_ROLE],
    );
    expect(mig.rows[0].s).toBe(false);
  });

  it(`${APP_ROLE} has no privilege at all on import_jobs (#239 — only ADMIN_DATA_SOURCE touches it)`, async () => {
    const r = await owner.query(
      `SELECT has_table_privilege($1, $2, 'SELECT') AS s, has_table_privilege($1, $2, 'INSERT') AS i,
              has_table_privilege($1, $2, 'UPDATE') AS u, has_table_privilege($1, $2, 'DELETE') AS d`,
      [APP_ROLE, IMPORT_JOBS_TABLE],
    );
    expect(r.rows[0]).toEqual({ s: false, i: false, u: false, d: false });
  });

  it('seedCategories inserts exactly the five categories in palette order (ADR-0001)', async () => {
    await seedCategories(owner, TENANT_B);
    const r = await owner.query(
      `SELECT name, position FROM categories WHERE tenant_id = $1 ORDER BY position`,
      [TENANT_B],
    );
    expect(r.rows).toEqual(
      SEED_CATEGORIES.map((name, position) => ({ name, position })),
    );
    const products = await owner.query(
      `SELECT count(*)::int AS n FROM products WHERE tenant_id = $1`,
      [TENANT_B],
    );
    expect(products.rows[0].n).toBe(1); // only the fixture row — the seed adds no demo products
  });

  it('no id column (id, *_id, ref_id, entity_id) is text — only settings.tax_id, a Thai tax number (…4900, #616)', async () => {
    const r = await owner.query<{ col: string }>(
      `SELECT table_name || '.' || column_name AS col
         FROM information_schema.columns
        WHERE table_schema = 'public'
          AND data_type IN ('text', 'character varying', 'character')
          AND (column_name = 'id' OR column_name LIKE '%\\_id')
        ORDER BY 1`,
    );
    expect(r.rows.map((x) => x.col)).toEqual(['settings.tax_id']);
  });

  it('the 11 composite entity FKs exist with their original names and ON DELETE actions (…4900, #616)', async () => {
    const r = await owner.query<{ name: string; table: string; def: string }>(
      `SELECT conname AS name, conrelid::regclass::text AS table, pg_get_constraintdef(oid) AS def
         FROM pg_constraint
        WHERE contype = 'f' AND connamespace = 'public'::regnamespace
          AND conname = ANY($1::text[])`,
      [ENTITY_FKS.map((fk) => fk.name)],
    );
    const byName = new Map(r.rows.map((x) => [x.name, x]));
    expect(byName.size).toBe(11);
    for (const fk of ENTITY_FKS) {
      const onDelete = fk.onDelete ? ` ON DELETE ${fk.onDelete}` : '';
      expect(byName.get(fk.name), fk.name).toEqual({
        name: fk.name,
        table: fk.table,
        def: `FOREIGN KEY (tenant_id, ${fk.column}) REFERENCES ${fk.parent}(tenant_id, id)${onDelete}`,
      });
    }
  });

  it('the three device auth functions return a uuid id and stay executable by the app role (…4900, #616)', async () => {
    const r = await owner.query<{ fn: string; result: string; definer: boolean; config: string[] }>(
      `SELECT p.proname AS fn, pg_get_function_result(p.oid) AS result,
              p.prosecdef AS definer, p.proconfig AS config
         FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname IN ('auth_lookup_device_by_token', 'auth_enrol_device',
                            'auth_lookup_device_and_active_user')
        ORDER BY 1`,
    );
    expect(r.rows.map((x) => x.fn)).toEqual([
      'auth_enrol_device',
      'auth_lookup_device_and_active_user',
      'auth_lookup_device_by_token',
    ]);
    for (const row of r.rows) {
      expect(row.result, row.fn).toMatch(/^TABLE\(tenant_id uuid, id uuid\b/);
      expect(row.definer, row.fn).toBe(true);
      expect(row.config, row.fn).toEqual(['search_path=public']);
    }

    // End to end through the app role: enrol a device by code, then look it up by token.
    const deviceId = testId('dv-4900');
    await owner.query(
      `INSERT INTO devices (tenant_id, id, label, device_no, enrol_code_hash, enrol_expires_at)
       VALUES ($1, $2, 'till', 1, 'code-4900', now() + interval '1 hour')`,
      [TENANT_A, deviceId],
    );
    try {
      const enrolled = await app.query(
        `SELECT tenant_id, id FROM auth_enrol_device('code-4900', 'token-4900')`,
      );
      expect(enrolled.rows).toEqual([{ tenant_id: TENANT_A, id: deviceId }]);
      const byToken = await app.query(
        `SELECT id FROM auth_lookup_device_by_token('token-4900')`,
      );
      expect(byToken.rows).toEqual([{ id: deviceId }]);
      const withUser = await app.query(
        `SELECT id FROM auth_lookup_device_and_active_user('token-4900')`,
      );
      expect(withUser.rows).toEqual([{ id: deviceId }]);
    } finally {
      await owner.query(`DELETE FROM devices WHERE id = $1`, [deviceId]);
    }
  });

  it('…4900 refuses a database whose business tables hold rows, and changes nothing (#616)', async () => {
    await app.end();
    const down = createMigrationDataSource(OWNER_URL);
    await down.initialize();
    try {
      await down.undoLastMigration({ transaction: 'each' }); // …4900, with the product fixture in place
    } finally {
      await down.destroy();
    }
    const typeOf = async () =>
      (
        await owner.query(
          `SELECT data_type FROM information_schema.columns
            WHERE table_name = 'products' AND column_name = 'id'`,
        )
      ).rows[0].data_type;
    expect(await typeOf()).toBe('text');

    await expect(migrateUp()).rejects.toThrow(
      'EntityIdsToUuid needs an empty database (table products)',
    );
    expect(await typeOf()).toBe('text'); // rolled back whole

    await owner.query(`DELETE FROM products`);
    await migrateUp();
    expect(await typeOf()).toBe('uuid');
    await insertFixtureProducts(owner);
    app = await connect(APP_URL);
  });

  it('down() reverses every migration back to an empty schema, and up() re-applies cleanly', async () => {
    await app.end();
    const ds = createMigrationDataSource(OWNER_URL);
    await ds.initialize();
    try {
      for (let i = 0; i < MIGRATIONS.length; i++) {
        await ds.undoLastMigration({ transaction: 'each' });
      }
      expect(await tableNames(owner)).toEqual([]);
      const ext = await owner.query(
        `SELECT count(*)::int AS n FROM pg_extension WHERE extname = 'pg_trgm'`,
      );
      expect(ext.rows[0].n).toBe(0);

      const ran = await ds.runMigrations({ transaction: 'each' });
      expect(ran.map((m) => m.name)).toEqual(
        MIGRATIONS.map((m) => new m().name),
      );
      expect(await tableNames(owner)).toHaveLength(29);
    } finally {
      await ds.destroy();
    }
    app = await connect(APP_URL);
  }, 60_000);
});
