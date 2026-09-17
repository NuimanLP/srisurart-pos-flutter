import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const SRC = join(fileURLToPath(new URL('.', import.meta.url)), '..');

function tsFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return tsFiles(path);
    return path.endsWith('.ts') ? [path] : [];
  });
}

/** Comments are where the reasons for holding a pool are written down. */
function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

/**
 * ADR-0003 addendum *"ใครตัดสิน กับ ใครลงมือ"* makes this scan a condition of the
 * handler-scoped design, not a suggestion. There are two ways for tenant work to land on a
 * connection with no `app.tenant_id`, and they fail very differently:
 *
 *   - forgetting `TenantService.runTx` but asking `currentRequestContext()` for the manager
 *     throws — a loud 500;
 *   - holding a `DataSource` and querying it directly answers **200 with zero rows** under
 *     RLS, and an UPDATE reports success having changed nothing. No endpoint test sees it.
 *
 * So a file may reach a raw pool only if it is on the allowlist below, with its reason.
 * `tenant-scope.spec.ts` is the precedent: a bug a mocked unit test cannot see gets a source
 * scan instead.
 */

/** Every constructor's parameter list — the text between `constructor(` and its matching `)`. */
function constructorParams(source: string): string[] {
  const lists: string[] = [];
  for (
    let i = source.indexOf('constructor(');
    i !== -1;
    i = source.indexOf('constructor(', i + 1)
  ) {
    const start = i + 'constructor('.length;
    let depth = 1;
    let j = start;
    for (; j < source.length && depth > 0; j++) {
      if (source[j] === '(') depth++;
      else if (source[j] === ')') depth--;
    }
    lists.push(source.slice(start, j - 1));
  }
  return lists;
}

/** Names a pool: the `DataSource` type, or one of `db.module.ts`'s named pool tokens. */
const POOL = /\bDataSource\b|\b[A-Z_]*_DATA_SOURCE\b/;

/**
 * A value (not `import type`) import of `DataSource` from typeorm, under any alias, or a
 * namespace import used to reach it. A value import is what lets Nest inject by type.
 */
function importsDataSourceValue(code: string): boolean {
  for (const m of code.matchAll(
    /import\s+(type\s+)?\{([^}]*)\}\s*from\s*['"]typeorm['"]/g,
  )) {
    if (m[1]) continue;
    const entries = m[2].split(',').map((entry) => entry.trim());
    if (entries.some((entry) => /^DataSource(?:\s+as\s+\w+)?$/.test(entry)))
      return true;
  }
  for (const m of code.matchAll(
    /import\s+\*\s+as\s+(\w+)\s+from\s*['"]typeorm['"]/g,
  )) {
    if (new RegExp(`\\b${m[1]}\\.DataSource\\b`).test(code)) return true;
  }
  return false;
}

/**
 * How a file gets hold of a pool: injected (constructor or property), resolved from the
 * container, built, imported as a value, or borrowed from a manager / runner's `.connection`.
 */
function reachesForPool(source: string): boolean {
  const code = stripComments(source);
  return (
    constructorParams(code).some((params) => POOL.test(params)) ||
    /@Inject\(\s*(?:DataSource|[A-Z_]*_DATA_SOURCE)\s*\)/.test(code) ||
    /@InjectDataSource\b/.test(code) ||
    /\.(?:get|resolve)\s*(?:<[^>]*>)?\s*\(\s*(?:DataSource\b|[A-Z_]*_DATA_SOURCE\b)/.test(
      code,
    ) ||
    /\bnew\s+DataSource\s*\(/.test(code) ||
    importsDataSourceValue(code) ||
    /\.connection\b/.test(code)
  );
}

/**
 * Files allowed to hold a pool of their own, and why (`src/`-relative, production code).
 * Built from the tree on 2026-09-14, not from the migration plan's 12-file count. A new
 * entry needs a reason a reviewer can check, not just a line. A pool holder that writes a table
 * clients pull by `updated_at` must commit through the commit guard (`runTx` /
 * `TenantJobRunner`) — README *The transaction ceiling (#213)*.
 */
const ALLOWED: Record<string, string> = {
  'common/database/tenant.service.ts':
    'It IS the door: the one place a pool becomes a transaction scoped to the tenant TenantGuard authorised.',
  'common/guards/tenant.guard.ts':
    'ADR-0003: reads tenants.status (a GLOBAL_TABLE, no RLS) on a cache miss with a plain pool query before it names the tenant — the request holds no other connection yet (tx.4 #153), so this is never a second one. It never sets app.tenant_id.',
  'infra/db.module.ts':
    'Builds and destroys the four pools (default pos_app, ADMIN_DATA_SOURCE, AUDIT_DATA_SOURCE, HEALTH_DATA_SOURCE).',
  'db/data-source.ts':
    'The migration DataSource (#15): connects as the table owner, runs outside the app and any request.',
  'health/health.controller.ts':
    '/health/ready probes Postgres with SELECT 1 on HEALTH_DATA_SOURCE only (pos_app, pool of 1, #248): no tenant, no table, deliberately outside any transaction, and never the request pool, whose saturation would read as a dead database.',
  'auth/auth.service.ts':
    'ADR-0009: a failed login must leave its audit_log row, which a rolled-back request transaction would erase, and /auth/token must not hold an idle transaction across its argon2 verify; so /auth/token and /auth/refresh carry no TenantGuard and set app.tenant_id on their own runners.',
  'rate-limit/rate-limit.service.ts':
    'readPlan reads tenants.plan (no RLS) on the pool from the global rate-limit guard, before any runTx holds a connection — since tx.4 (#153) there is no request transaction to hold one first (#162).',
  'queue/tenant-job-runner.ts':
    'BullMQ jobs have no request: checks tenants.status (ADR-0003 consequence 4), then opens its own transaction with set_config per job. It names its tenant from the job payload (job.data.tenantId), not from a guard — so its callers are policed below (queue/processors/ only).',
  'queue/processors/maintenance.processor.ts':
    'idem.cleanup with no tenant lists tenants (no RLS) on the pool and fans out one tenant-scoped job each; every DELETE runs through runWithTenantContext (#169).',
  'platform/audit.service.ts':
    'Imports DataSource as a value for the type of log(runner) only; the caller passes its own transaction manager (admin plane, #123). Holds no pool itself.',
  'platform/platform-auth.guard.ts':
    'Admin plane (ADR-0002): ADMIN_DATA_SOURCE, checks platform_admins, never a tenant request.',
  'platform/platform-auth.service.ts':
    'Admin plane (ADR-0002): ADMIN_DATA_SOURCE for platform login.',
  'platform/platform-tenants.service.ts':
    'Admin plane (ADR-0002): ADMIN_DATA_SOURCE creates tenants and changes their status across tenants.',
  'platform/tenant-import.service.ts':
    'Admin plane (ADR-0002/0005): ADMIN_DATA_SOURCE imports a whole tenant in one owner transaction.',
};

/**
 * The other doors: functions that name a tenant, or publish a scope `runTx` would join.
 * Any of them called from the wrong place forges what the guard decides. Each may be
 * mentioned only in the file that defines it and in the callers listed here.
 */
const SCOPE_DOORS: Array<{
  name: string;
  definedIn: string;
  callers: (file: string) => boolean;
  why: string;
}> = [
  {
    name: 'runWithTenantContext',
    definedIn: 'queue/tenant-job-runner.ts',
    callers: (file) => file.startsWith('queue/processors/'),
    why: 'names the tenant from a job payload — only BullMQ processors have one; an HTTP service calling it could name any shop',
  },
  {
    name: 'setRequestTenant',
    definedIn: 'common/request-context.ts',
    callers: (file) => file === 'common/guards/tenant.guard.ts',
    why: 'ADR-0003: TenantGuard alone names the tenant, after checking tenants.status',
  },
  {
    name: 'runInTransaction',
    definedIn: 'common/request-context.ts',
    callers: (file) => file === 'common/database/tenant.service.ts',
    why: 'publishes a tenant + manager that runTx would join; only runTx owns such a transaction',
  },
  {
    name: 'runInRequestContext',
    definedIn: 'common/request-context.ts',
    callers: () => false,
    why: 'publishes a tenant + manager nobody authorised or opened; a unit-test seam only since tx.4 (#153) deleted the request-wide transaction',
  },
];

function rel(path: string): string {
  return relative(SRC, path).split(sep).join('/');
}

const productionFiles = () =>
  tsFiles(SRC).filter((path) => !path.endsWith('.spec.ts'));

describe('the tenant door (ADR-0003, tx.1 #150)', () => {
  // The scan is only worth its line count if it still recognises every way in, and still
  // ignores the shapes that hold no pool.
  it('recognises each way of reaching a pool and ignores a passed-in runner', () => {
    expect(
      reachesForPool('constructor(private readonly ds: DataSource) {}'),
    ).toBe(true);
    expect(
      reachesForPool(
        'constructor(\n  @Inject(LOGGER) l: Logger,\n  @Inject(AUDIT_DATA_SOURCE) a: X,\n) {}',
      ),
    ).toBe(true);
    expect(reachesForPool('constructor(@InjectDataSource() ds) {}')).toBe(true);
    expect(reachesForPool('const ds = moduleRef.get(DataSource);')).toBe(true);
    expect(
      reachesForPool('const ds = new DataSource({ type: "postgres" });'),
    ).toBe(true);
    // Review round (#168): the four shapes the first cut let through.
    expect(
      reachesForPool('@Inject(DataSource) private readonly ds!: DataSource;'),
    ).toBe(true);
    expect(
      reachesForPool('@Inject(AUDIT_DATA_SOURCE) private readonly ds!: Pool;'),
    ).toBe(true);
    expect(
      reachesForPool('const ds = moduleRef.get<DataSource>(DataSource);'),
    ).toBe(true);
    expect(
      reachesForPool(
        "import { EntityManager, DataSource as Pool } from 'typeorm';",
      ),
    ).toBe(true);
    expect(
      reachesForPool("import * as orm from 'typeorm';\nlet p: orm.DataSource;"),
    ).toBe(true);
    expect(reachesForPool('const pool = manager.connection;')).toBe(true);
    expect(reachesForPool('qr.connection.query(sql)')).toBe(true);

    expect(
      reachesForPool(
        'async log(runner: EntityManager | DataSource, input: X) {}',
      ),
    ).toBe(false);
    expect(
      reachesForPool('constructor(private readonly tenants: TenantService) {}'),
    ).toBe(false);
    expect(
      reachesForPool('// constructor(private readonly ds: DataSource)'),
    ).toBe(false);
    expect(reachesForPool("import type { DataSource } from 'typeorm';")).toBe(
      false,
    );
    expect(
      reachesForPool("import { type EntityManager } from 'typeorm';"),
    ).toBe(false);
  });

  it('the tenant-naming and scope-publishing functions are called only by their owners', () => {
    const offenders: string[] = [];
    for (const path of productionFiles()) {
      const file = rel(path);
      const code = stripComments(readFileSync(path, 'utf8'));
      for (const door of SCOPE_DOORS) {
        if (file === door.definedIn || door.callers(file)) continue;
        if (new RegExp(`\\b${door.name}\\b`).test(code)) {
          offenders.push(`${file} uses ${door.name} — ${door.why}`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });

  it('only allowlisted files reach for a DataSource of their own', () => {
    const offenders = productionFiles()
      .filter((path) => reachesForPool(readFileSync(path, 'utf8')))
      .map(rel)
      .filter((file) => !(file in ALLOWED));

    expect(offenders).toEqual([]);
  });

  it('every allowlist entry still reaches for a pool, so the list cannot rot into permission', () => {
    const reaching = new Set(
      productionFiles()
        .filter((path) => reachesForPool(readFileSync(path, 'utf8')))
        .map(rel),
    );
    expect(Object.keys(ALLOWED).filter((file) => !reaching.has(file))).toEqual(
      [],
    );
  });
});
