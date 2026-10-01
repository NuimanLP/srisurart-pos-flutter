import * as argon2 from 'argon2';
import { pbkdf2Sync, randomInt, timingSafeEqual } from 'node:crypto';
import { COMMON_PASSWORDS, SHOP_WORDS } from './common-passwords.js';

export async function hashPassword(password: string): Promise<string> {
  return argon2.hash(password, {
    type: argon2.argon2id,
    memoryCost: 65536, // 64 MiB (ADR-0009)
    timeCost: 3,
    parallelism: 1,
  });
}

/**
 * A real argon2id hash of a random, discarded secret, made with exactly `hashPassword`'s
 * parameters (`password.spec.ts` pins that). Login verifies against it when the username
 * does not exist, so an unknown user costs the same argon2 time as a wrong password and
 * response latency does not reveal which usernames exist (#425).
 */
export const DUMMY_PASSWORD_HASH =
  '$argon2id$v=19$m=65536,p=1,t=3$DoqUEQ2wG5VUZO8UBPB2Bg$BX3C6V1Z/PScI3i9qWDn0uzBQtGbQEcK7sjjpGdYH7M';

/** Spend one argon2 verify's worth of time on a login that is already refused. Always false. */
export async function verifyAgainstDummyHash(password: string): Promise<false> {
  await verifyPassword(password, DUMMY_PASSWORD_HASH);
  return false;
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

/**
 * Upper bound for a password a person chooses (#443 PR3). Not a strength rule — it caps the
 * work an attacker can make one change-password request cost before argon2 (OWASP ASVS V2.1.2).
 */
export const MAX_PASSWORD_LENGTH = 128;

/**
 * Why a password was refused. `required` = absent/blank · `too_short` = under the floor ·
 * `too_long` = over `MAX_PASSWORD_LENGTH` · `common` = on the offline blocklist ·
 * `same_as_temp` = the new password is the temporary one it is replacing.
 */
export type PasswordPolicyViolation =
  | 'required'
  | 'too_short'
  | 'too_long'
  | 'common'
  | 'same_as_temp';

/**
 * NFC, applied wherever an owner password is set or checked (#443 PR3), so the same text
 * typed on two keyboards that emit different code-point sequences hashes the same. For Thai
 * it canonically reorders a tone mark (ccc 107) typed before a below-vowel (ccc 103), but not
 * marks of equal class. Login also retries the raw form, for hashes made before PR3.
 */
export function normalizePassword(password: string): string {
  return password.normalize('NFC');
}

/** Offline blocklist check: exact common password, or contains a fixed SHOP_WORDS brand word (common-passwords.ts). */
export function isCommonPassword(password: string): boolean {
  const lower = normalizePassword(password).toLowerCase();
  if (COMMON_PASSWORDS.has(lower)) return true;
  const squashed = lower.replace(/[\s\-_.]/g, '');
  return SHOP_WORDS.some((w) => squashed.includes(w));
}

/**
 * The policy for a password a shop owner *chooses* (`POST /auth/change-password`, #443 PR3):
 * `passwordPolicyViolation`'s floor, plus the upper bound and the blocklist — all pure string
 * checks, so a caller runs them before any argon2 and before any transaction. `same_as_temp`
 * needs an argon2 verify and is therefore the caller's own, later step.
 */
export function chosenPasswordViolation(password: unknown): PasswordPolicyViolation | null {
  if (typeof password !== 'string') return 'required';
  const normalized = normalizePassword(password);
  const base = passwordPolicyViolation(normalized);
  if (base) return base;
  if (normalized.length > MAX_PASSWORD_LENGTH) return 'too_long';
  if (isCommonPassword(normalized)) return 'common';
  return null;
}

/**
 * A server-generated temporary owner password (#443 PR3, v2 condition 1): CSPRNG, 16
 * characters from an alphabet with the confusable `0 O 1 l I` removed (57 symbols — lowercase `o` is kept — ≈ 93 bits),
 * so it survives being read aloud over the phone. The admin never chooses it.
 */
export const TEMP_PASSWORD_ALPHABET =
  'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
export const TEMP_PASSWORD_LENGTH = 16;

export function generateTempPassword(): string {
  let out = '';
  for (let i = 0; i < TEMP_PASSWORD_LENGTH; i++) {
    out += TEMP_PASSWORD_ALPHABET[randomInt(TEMP_PASSWORD_ALPHABET.length)];
  }
  return out;
}

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
 *
 * The one owner-ratified exception (2026-09-28): `PLATFORM_ADMINS` (`db/platform-admins-env.ts`)
 * trims each password before it reaches this check — see that file for why.
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
  switch (violation) {
    case 'required':
      return `${field} is required`;
    case 'too_short':
      return `${field} is too weak: at least ${MIN_PASSWORD_LENGTH} characters required`;
    case 'too_long':
      return `${field} is too long: at most ${MAX_PASSWORD_LENGTH} characters allowed`;
    case 'common':
      return `${field} is too common or contains the shop's name`;
    case 'same_as_temp':
      return `${field} must differ from the temporary password`;
  }
}
