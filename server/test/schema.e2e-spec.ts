import { Client } from 'pg';
import {
  createMigrationDataSource,
  MIGRATIONS,
} from '../src/db/data-source.js';
import {
  ALL_TABLES,
  APP_ROLE,
  TENANT_SCOPED_TABLES,
} from '../src/db/migrations/1788652800001-RowLevelSecurity.js';
import { SEED_CATEGORIES, seedCategories } from '../src/db/seed.js';

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
    await owner.query(
      `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock)
       VALUES ($1, 'p1', 'BP-100', 'Front brake pad', 'ผ้าเบรกหน้า', 'เบรก', 'TRW', 450, 300, 5),
              ($2, 'p1', 'OF-200', 'Oil filter',      'กรองน้ำมัน',  'น้ำมัน', 'Bosch', 120, 80, 9)`,
      [TENANT_A, TENANT_B],
    );
  }, 60_000);

  afterAll(async () => {
    await app?.end();
    await owner?.end();
    await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
    await admin.end();
  });

  it('runs from an empty database to exactly 27 tables, without change_log', async () => {
    const tables = await tableNames(owner);
    expect(tables).toHaveLength(27);
    expect(tables).toEqual([...ALL_TABLES].sort());
    expect(tables).not.toContain('change_log');
  });

  it('every tenant-scoped table carries tenant_id in its primary key', async () => {
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
    expect(pk.get('tenants')).toEqual(['id']);
    expect(pk.get('platform_admins')).toEqual(['id']);
  });

  it('RLS is enabled and forced on every tenant-scoped table, with one policy each', async () => {
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
         VALUES ($1, 'p9', 'X', 'x', 'x', 'x', 'x', 1, 1, 1)`,
        [TENANT_A],
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
         VALUES ($1, $2, 'p1', 'BP-100', 'Front brake pad', 1, 'adjustment-in', 6)`,
        [TENANT_A, id],
      );
    await adj('m1');
    await adj('m2'); // same (type, product), both ref_id NULL → allowed
    const sale = (id: string) =>
      app.query(
        `INSERT INTO movements (tenant_id, id, product_id, part_no, name, delta, type, stock_after, ref_id)
         VALUES ($1, $2, 'p1', 'BP-100', 'Front brake pad', -1, 'sale', 5, 's1')`,
        [TENANT_A, id],
      );
    await sale('m3');
    await app.query('SAVEPOINT replay');
    await expect(sale('m4')).rejects.toMatchObject({
      code: '23505',
      constraint: 'uq_movements_ref',
    });
    await app.query('ROLLBACK TO SAVEPOINT replay');
    await expect(
      app.query(`DELETE FROM movements WHERE id = 'm1'`),
    ).rejects.toMatchObject({
      code: '42501',
    });
    await app.query('ROLLBACK');
  });

  it(`${APP_ROLE} has DML on every table (movements insert-only) and none on the migrations table`, async () => {
    for (const t of ALL_TABLES) {
      const r = await owner.query(
        `SELECT has_table_privilege($1, $2, 'SELECT') AS s, has_table_privilege($1, $2, 'INSERT') AS i,
                has_table_privilege($1, $2, 'UPDATE') AS u, has_table_privilege($1, $2, 'DELETE') AS d`,
        [APP_ROLE, t],
      );
      const expected =
        t === 'movements'
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
      expect(await tableNames(owner)).toHaveLength(27);
    } finally {
      await ds.destroy();
    }
    app = await connect(APP_URL);
  }, 60_000);
});
