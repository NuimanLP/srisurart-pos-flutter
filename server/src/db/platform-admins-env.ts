import { createMigrationDataSource } from './data-source.js';
import { assertOwnerOfPlatformAdmins } from './bootstrap-admin.js';
import {
  hashPassword,
  passwordPolicyMessage,
  passwordPolicyViolation,
  verifyPassword,
} from '../common/password.js';

/**
 * `PLATFORM_ADMINS` boot sync (#443, owner decisions 2026-09-28). `main.ts` — the api entry
 * point only, never worker/bull-board — parses the variable and upserts the admins it lists
 * before it listens:
 * - missing → created (`display_name` = username: the column is NOT NULL, the env has none);
 * - present, active, password no longer verifies → re-hashed, `password_changed_at = now()`, so
 *   `PlatformAuthGuard` refuses every older platform token (ADR-0009 addendum 2026-09-26 rule);
 * - present, active, verifies → untouched;
 * - present but disabled → untouched and reported `inactive`: a disabled admin is a revocation,
 *   and re-enabling one is an explicit UPDATE, never a boot side effect (same as
 *   `bootstrap-admin.ts`).
 * An admin removed from the env is NOT deleted or disabled (owner, 2026-09-28).
 *
 * Shaped like `bootstrap-admin.ts`: a short-lived owner-role pool of one via
 * `createMigrationDataSource`, opened and closed before Nest builds its own pools, so it is never
 * a second connection inside a request and needs no `tenant-door.spec.ts` entry.
 *
 * api-1..3 boot together: one transaction under a transaction-scoped advisory lock serialises
 * them — the first writes, the others see a hash that verifies and write nothing. argon2 runs
 * inside the lock on purpose: only this sync takes it and nothing listens yet, so the cost is a
 * few hundred ms of boot per changed admin, and the alternative (verify/hash outside, then a
 * compare-and-set) makes every replica hash and needs retry logic for no real gain.
 *
 * Hashing is `hashPassword` over the raw (trimmed) string with no NFC, because platform login
 * (`platform-auth.service.ts`) verifies the raw form — exactly like `bootstrap-admin.ts`.
 */
export interface PlatformAdminEntry {
  username: string;
  password: string;
}

export interface PlatformAdminSyncResult {
  id: string;
  username: string;
  action: 'created' | 'updated' | 'unchanged' | 'inactive';
}

/**
 * `PLATFORM_ADMINS=user:password,user:password`. Entries are split on `,`, each entry on its
 * FIRST `:` (so a password may contain `:` but never `,`), and both halves are trimmed.
 *
 * 🔴 Trimming the password is the ONE deliberate exception to "a password's spaces are part of
 * it" (`common/password.ts`, `bootstrap-admin.ts`) — owner-ratified 2026-09-28, together with
 * "no `,` in a password". Nowhere else may trim a password.
 *
 * Blank/absent = `undefined` (nothing to sync). Anything else that is not a clean list — an empty
 * entry, no `:`, an empty username, a duplicate username, or a password `passwordPolicyViolation`
 * refuses (the 12-character floor) — throws, so a typo fails the boot instead of silently
 * skipping an admin (CLAUDE.md: validate first). Errors name the entry's position ONLY: a
 * mistyped separator can put part of a password where the username belongs.
 */
export function parsePlatformAdmins(raw: string | undefined): PlatformAdminEntry[] | undefined {
  if (raw === undefined || raw.trim() === '') return undefined;
  const firstSeen = new Map<string, number>();
  return raw.split(',').map((entry, i) => {
    const where = `PLATFORM_ADMINS entry #${i + 1}`;
    const colon = entry.indexOf(':');
    if (colon === -1) {
      throw new Error(`${where} is malformed: expected user:password`);
    }
    const username = entry.slice(0, colon).trim();
    const password = entry.slice(colon + 1).trim();
    if (!username) throw new Error(`${where} has an empty username`);
    const earlier = firstSeen.get(username);
    if (earlier !== undefined) {
      throw new Error(`${where} repeats the username of entry #${earlier}`);
    }
    firstSeen.set(username, i + 1);
    const violation = passwordPolicyViolation(password);
    if (violation) {
      throw new Error(passwordPolicyMessage(violation, `${where}'s password`));
    }
    return { username, password };
  });
}

export async function syncPlatformAdmins(
  url: string,
  admins: PlatformAdminEntry[],
): Promise<PlatformAdminSyncResult[]> {
  const ds = createMigrationDataSource(url);
  try {
    await ds.initialize();
    await assertOwnerOfPlatformAdmins(ds, 'DATABASE_ADMIN_URL / POSTGRES_PASSWORD');
    return await ds.transaction(async (m) => {
      await m.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [
        'platform_admins:env-sync',
      ]);
      const results: PlatformAdminSyncResult[] = [];
      for (const { username, password } of admins) {
        const [row] = await m.query(
          `SELECT id, password_hash, is_active FROM platform_admins WHERE username = $1`,
          [username],
        );
        if (!row) {
          const [inserted] = await m.query(
            `INSERT INTO platform_admins (username, password_hash, display_name)
             VALUES ($1, $2, $1)
             RETURNING id`,
            [username, await hashPassword(password)],
          );
          results.push({ id: inserted.id, username, action: 'created' });
        } else if (!row.is_active) {
          results.push({ id: row.id, username, action: 'inactive' });
        } else if (await verifyPassword(password, row.password_hash)) {
          results.push({ id: row.id, username, action: 'unchanged' });
        } else {
          await m.query(
            `UPDATE platform_admins SET password_hash = $2, password_changed_at = now()
              WHERE username = $1`,
            [username, await hashPassword(password)],
          );
          results.push({ id: row.id, username, action: 'updated' });
        }
      }
      return results;
    });
  } finally {
    if (ds.isInitialized) await ds.destroy();
  }
}

/**
 * What `main.ts` may log about a failed sync: the message and the pg code, nothing else. A
 * TypeORM `QueryFailedError` also carries `.parameters` (a password hash) and `.query`, which a
 * logger serialising the whole error would print.
 */
export function describeSyncError(err: unknown): { message: string; code?: string } {
  if (!(err instanceof Error)) return { message: 'PLATFORM_ADMINS sync failed' };
  const code = (err as { code?: unknown }).code;
  return typeof code === 'string' ? { message: err.message, code } : { message: err.message };
}
