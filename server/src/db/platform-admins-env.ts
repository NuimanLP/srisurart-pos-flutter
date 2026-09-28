import { createMigrationDataSource } from './data-source.js';
import { hashPassword, verifyPassword } from '../common/password.js';
import type { PlatformAdminEntry } from '../config/config.js';

/**
 * `PLATFORM_ADMINS` boot sync (#443, owner decision 2026-09-28): every api instance upserts the
 * admins its env lists before it listens. Missing → created; present but the password no longer
 * verifies → re-hashed; present and verifying → untouched. An admin removed from the env is NOT
 * deleted or disabled, and `is_active` is never written — same rule as `bootstrap-admin.ts`: a
 * disabled admin is a revocation, and re-enabling one is an explicit UPDATE, not a boot side effect.
 *
 * Shaped like `bootstrap-admin.ts`: a short-lived owner-role pool of one via
 * `createMigrationDataSource`, opened and closed before Nest builds its own pools, so it is never
 * a second connection inside a request and needs no `tenant-door.spec.ts` entry.
 *
 * api-1..3 boot together: one transaction under a transaction-scoped advisory lock serialises
 * them, so the first creates/re-hashes and the others then see a hash that verifies and write
 * nothing. Hashing is `hashPassword` over the raw (trimmed) string with no NFC, because platform
 * login (`platform-auth.service.ts`) verifies the raw form — exactly like `bootstrap-admin.ts`.
 */
export interface PlatformAdminSyncResult {
  username: string;
  action: 'created' | 'updated' | 'unchanged';
}

export async function syncPlatformAdmins(
  url: string,
  admins: PlatformAdminEntry[],
): Promise<PlatformAdminSyncResult[]> {
  const ds = createMigrationDataSource(url);
  try {
    await ds.initialize();
    return await ds.transaction(async (m) => {
      await m.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [
        'platform_admins:env-sync',
      ]);
      const results: PlatformAdminSyncResult[] = [];
      for (const { username, password } of admins) {
        const [row] = await m.query(
          `SELECT password_hash FROM platform_admins WHERE username = $1`,
          [username],
        );
        if (!row) {
          // display_name is NOT NULL and the env carries none: the username stands in.
          await m.query(
            `INSERT INTO platform_admins (username, password_hash, display_name)
             VALUES ($1, $2, $1)`,
            [username, await hashPassword(password)],
          );
          results.push({ username, action: 'created' });
        } else if (await verifyPassword(password, row.password_hash)) {
          results.push({ username, action: 'unchanged' });
        } else {
          await m.query(`UPDATE platform_admins SET password_hash = $2 WHERE username = $1`, [
            username,
            await hashPassword(password),
          ]);
          results.push({ username, action: 'updated' });
        }
      }
      return results;
    });
  } finally {
    if (ds.isInitialized) await ds.destroy();
  }
}
