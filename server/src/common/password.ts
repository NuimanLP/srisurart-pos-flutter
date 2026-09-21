import * as argon2 from 'argon2';
import { pbkdf2Sync, timingSafeEqual } from 'node:crypto';

export async function hashPassword(password: string): Promise<string> {
  return argon2.hash(password, {
    type: argon2.argon2id,
    memoryCost: 65536, // 64 MiB (ADR-0009)
    timeCost: 3,
    parallelism: 1,
  });
}

export async function verifyPassword(password: string, combinedHash: string): Promise<boolean> {
  if (combinedHash.startsWith('$argon2')) {
    try {
      return await argon2.verify(combinedHash, password);
    } catch {
      return false;
    }
  }

  // Fallback for legacy PBKDF2 hashes
  const parts = combinedHash.split(':');
  if (parts.length !== 2) return false;
  const [salt, hash] = parts;
  const verifyHash = pbkdf2Sync(password, salt, 1000, 64, 'sha512').toString('hex');
  const buf1 = Buffer.from(hash, 'hex');
  const buf2 = Buffer.from(verifyHash, 'hex');
  return buf1.length === buf2.length && timingSafeEqual(buf1, buf2);
}

/**
 * Minimum length for an account that can administer a platform or a whole shop
 * (`platform_admins`, and a tenant's `owner` user). This account can create and suspend
 * every tenant, or run every till in its shop, so the floor is deliberately above the
 * 8-ish habit; there is no upper structure requirement because length is what a
 * generated secret has.
 *
 * Lives here, next to `hashPassword`, so the *one* condition below is shared by both
 * creation paths — `db/bootstrap-admin.ts` (the CLI) and
 * `platform/platform-tenants.service.ts` (`POST /platform/tenants`). #364 existed
 * precisely because those two drifted apart; do not re-inline the comparison.
 */
export const MIN_PASSWORD_LENGTH = 12;

/** Why a password was refused. `required` = absent/blank · `too_short` = under the floor. */
export type PasswordPolicyViolation = 'required' | 'too_short';

/**
 * The shared policy check: returns `null` when `password` is acceptable, otherwise why not.
 *
 * Returns a reason rather than throwing so each caller can raise its own error shape (the
 * CLI throws a plain `Error`; the HTTP path throws a `BadRequestException` carrying the
 * `WEAK_PASSWORD` code from `02_API_SCREENS.md §8.1`) without either owning the condition.
 *
 * The password itself is never trimmed — its spaces are part of it — but a value that is
 * *only* whitespace counts as absent. A non-string (e.g. the JSON number `1234`) is
 * `required`, not a crash: validate the input first, then measure it (CLAUDE.md).
 */
export function passwordPolicyViolation(
  password: unknown,
): PasswordPolicyViolation | null {
  if (typeof password !== 'string' || !password.trim()) return 'required';
  if (password.length < MIN_PASSWORD_LENGTH) return 'too_short';
  return null;
}

/** The English operator-facing sentence for a violation of `field`. */
export function passwordPolicyMessage(
  violation: PasswordPolicyViolation,
  field: string,
): string {
  return violation === 'required'
    ? `${field} is required`
    : `${field} is too weak: at least ${MIN_PASSWORD_LENGTH} characters required`;
}
