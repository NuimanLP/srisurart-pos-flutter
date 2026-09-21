import { pathToFileURL } from 'node:url';
import { createMigrationDataSource } from './data-source.js';
import { hashPassword } from '../common/password.js';

/**
 * Platform-admin bootstrap (#337, D2 of #335) — the one supported way to get the first
 * `platform_admins` row, so nobody has to open psql and hash a password by hand.
 * Usage: node dist/db/bootstrap-admin.js [--force]
 *
 * Shaped exactly like `migrate.ts`: it builds its pool through `createMigrationDataSource`
 * and never names `DataSource` itself, so `common/tenant-door.spec.ts` keeps passing with
 * no new allowlist entry (the allowlist is keyed by the scanned file, and does not carry
 * over to files that import an allowed one).
 *
 * DATABASE_URL must be the owner role (`postgres`), not `pos_app` — `pos_app` holds
 * INSERT on `platform_admins` too (RowLevelSecurity migration grants DML on every table),
 * so the role is checked explicitly below rather than assumed.
 *
 * ADR-0001 is unchanged: admins are created out of band by the team. No API creates one.
 */

/**
 * Minimum length for a platform-admin password. This account can create and suspend every
 * tenant, so the floor is deliberately above the 8-ish habit; there is no upper structure
 * requirement because length is what a generated secret has.
 */
export const MIN_PASSWORD_LENGTH = 12;

export interface BootstrapAdminOptions {
  /** Owner-role connection string. Defaults to `DATABASE_URL`. */
  url?: string;
  username?: string;
  password?: string;
  displayName?: string;
  /** Overwrite the password of an existing admin. Off by default. */
  force?: boolean;
}

export interface BootstrapAdminResult {
  /** `created` = new row · `unchanged` = existed, left alone · `updated` = password reset by --force */
  action: 'created' | 'unchanged' | 'updated';
  username: string;
  /** The row's id, except on `unchanged` where nothing was read back. */
  id: string | null;
}

function requireValue(value: string | undefined, name: string): string {
  const trimmed = (value ?? '').trim();
  if (!trimmed) throw new Error(`${name} is required`);
  return trimmed;
}

/**
 * Creates (or, with `force`, re-passwords) one platform admin and reports what it did.
 *
 * `is_active` is never written — not on create (the column defaults to TRUE) and not on
 * `--force`. So re-running this against an admin somebody disabled does NOT bring them
 * back: that is deliberate, because a disabled admin is a revocation and a bootstrap
 * script is not the place to undo one. Re-enable with an explicit UPDATE if you mean it.
 *
 * Exported as a function because the e2e suites run vitest over `src/` and never build
 * `dist/`; the CLI below is a thin entry point over this.
 */
export async function bootstrapAdmin(
  opts: BootstrapAdminOptions = {},
): Promise<BootstrapAdminResult> {
  // Validate before connecting, and before hashing: a bad input should fail loudly and
  // instantly, never half-way through a write (CLAUDE.md — validate first, then clamp).
  const url = requireValue(
    opts.url ?? process.env.DATABASE_URL,
    'DATABASE_URL (owner role, e.g. postgres://postgres:…/pos)',
  );
  const username = requireValue(
    opts.username ?? process.env.BOOTSTRAP_ADMIN_USERNAME,
    'BOOTSTRAP_ADMIN_USERNAME',
  );
  const displayName = requireValue(
    opts.displayName ?? process.env.BOOTSTRAP_ADMIN_DISPLAY_NAME,
    'BOOTSTRAP_ADMIN_DISPLAY_NAME',
  );
  // Not trimmed: a password's spaces are part of it. Only its emptiness is rejected.
  const password = opts.password ?? process.env.BOOTSTRAP_ADMIN_PASSWORD ?? '';
  if (!password.trim()) throw new Error('BOOTSTRAP_ADMIN_PASSWORD is required');
  if (password.length < MIN_PASSWORD_LENGTH) {
    throw new Error(
      `BOOTSTRAP_ADMIN_PASSWORD is too weak: at least ${MIN_PASSWORD_LENGTH} characters required`,
    );
  }

  const ds = createMigrationDataSource(url);
  try {
    await ds.initialize();

    // Ask Postgres who we are rather than parsing the URL: a URL can say `postgres` and
    // still land on a role that only inherits `pos_app`'s rights.
    const [role] = await ds.query(
      `SELECT current_user AS current_role_name,
              pg_get_userbyid(c.relowner) AS table_owner,
              pg_has_role(current_user, c.relowner, 'MEMBER') AS is_owner
         FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'platform_admins'`,
    );
    if (!role) {
      throw new Error(
        'platform_admins does not exist — run the migrations first (node dist/db/migrate.js up)',
      );
    }
    if (!role.is_owner) {
      throw new Error(
        `DATABASE_URL must be the owner role: connected as "${role.current_role_name}", ` +
          `but platform_admins is owned by "${role.table_owner}"`,
      );
    }

    const passwordHash = await hashPassword(password);
    if (opts.force) {
      // `xmax = 0` is the documented way to tell an ON CONFLICT insert from its update:
      // a freshly inserted row has no updating transaction id.
      const [row] = await ds.query(
        `INSERT INTO platform_admins (username, password_hash, display_name)
         VALUES ($1, $2, $3)
         ON CONFLICT (username) DO UPDATE SET password_hash = EXCLUDED.password_hash
         RETURNING id, (xmax = 0) AS inserted`,
        [username, passwordHash, displayName],
      );
      return {
        action: row.inserted ? 'created' : 'updated',
        username,
        id: row.id,
      };
    }

    const rows = await ds.query(
      `INSERT INTO platform_admins (username, password_hash, display_name)
       VALUES ($1, $2, $3)
       ON CONFLICT (username) DO NOTHING
       RETURNING id`,
      [username, passwordHash, displayName],
    );
    return rows.length
      ? { action: 'created', username, id: rows[0].id }
      : { action: 'unchanged', username, id: null };
  } finally {
    if (ds.isInitialized) await ds.destroy();
  }
}

const MESSAGES: Record<BootstrapAdminResult['action'], string> = {
  created: 'created',
  unchanged: 'already exists — password left alone (pass --force to reset it)',
  updated: 'password reset',
};

// Entry guard: this module is imported by the e2e suite, so the CLI must only run when
// node was pointed at this file. `require.main` does not exist — the package is ESM.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const result = await bootstrapAdmin({
      force: process.argv.includes('--force'),
    });
    console.log(`platform admin "${result.username}": ${MESSAGES[result.action]}`);
  } catch (err) {
    console.error(err instanceof Error ? err.message : err);
    process.exitCode = 1;
  }
}
