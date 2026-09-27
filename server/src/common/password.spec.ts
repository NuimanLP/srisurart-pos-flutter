import { describe, expect, it } from 'vitest';
import {
  chosenPasswordViolation,
  generateTempPassword,
  isCommonPassword,
  MAX_PASSWORD_LENGTH,
  normalizePassword,
  TEMP_PASSWORD_ALPHABET,
  DUMMY_PASSWORD_HASH,
  hashPassword,
  verifyAgainstDummyHash,
  MIN_PASSWORD_LENGTH,
  passwordPolicyMessage,
  passwordPolicyViolation,
} from './password.js';

// #364 — this is the one condition shared by `bootstrap:admin` (the CLI that creates a
// platform admin) and `POST /platform/tenants` (which creates a shop's `owner`). They
// drifted apart once; these cases pin the behaviour both of them now inherit.
describe('passwordPolicyViolation', () => {
  it('accepts a password at or above the floor', () => {
    expect(MIN_PASSWORD_LENGTH).toBe(12);
    // The boundary is inclusive: exactly 12 is acceptable.
    expect(passwordPolicyViolation('a'.repeat(MIN_PASSWORD_LENGTH))).toBeNull();
    expect(passwordPolicyViolation('bootstrap-secret-1')).toBeNull();
  });

  it('reports a password under the floor as too_short', () => {
    expect(passwordPolicyViolation('1234')).toBe('too_short');
    // 11 characters — one short. The old provisioning fixtures used exactly this.
    expect(passwordPolicyViolation('password123')).toBe('too_short');
    expect(passwordPolicyViolation('a'.repeat(MIN_PASSWORD_LENGTH - 1))).toBe('too_short');
  });

  it('reports an absent, blank or non-string password as required', () => {
    for (const bad of ['', '   ', '            ', undefined, null, 1234, {}, []]) {
      expect(passwordPolicyViolation(bad)).toBe('required');
    }
  });

  it('counts a password’s own spaces, and never trims the value it measures', () => {
    // A 12-character passphrase made of words plus spaces is acceptable as it stands…
    expect(passwordPolicyViolation('ab cd ef gh i')).toBeNull();
    // …and the length measured is the UNTRIMMED one, because that is the string that
    // will be hashed: 12 characters of which 4 are padding passes, 8 characters does not.
    expect(passwordPolicyViolation('  short123  ')).toBeNull();
    expect(passwordPolicyViolation('short123')).toBe('too_short');
  });
});

describe('passwordPolicyMessage', () => {
  it('names the field the caller was reading', () => {
    expect(passwordPolicyMessage('required', 'BOOTSTRAP_ADMIN_PASSWORD')).toBe(
      'BOOTSTRAP_ADMIN_PASSWORD is required',
    );
    expect(passwordPolicyMessage('too_short', 'ownerPassword')).toBe(
      'ownerPassword is too weak: at least 12 characters required',
    );
  });
});

// #425 — login verifies unknown usernames against this hash so they cost the same argon2
// time as a wrong password. That only holds while its parameters match `hashPassword`'s.
describe('DUMMY_PASSWORD_HASH', () => {
  const params = (h: string) => h.split('$').slice(1, 4).join('$'); // argon2id$v=19$m=…,p=…,t=…
  const lengths = (h: string) => h.split('$').slice(4).map((p) => p.length); // salt, hash

  it('uses exactly the parameters and sizes hashPassword produces', async () => {
    const real = await hashPassword('any-password-at-all');
    expect(params(DUMMY_PASSWORD_HASH)).toBe(params(real));
    expect(lengths(DUMMY_PASSWORD_HASH)).toEqual(lengths(real));
  });

  it('never accepts a password', async () => {
    expect(await verifyAgainstDummyHash('')).toBe(false);
    expect(await verifyAgainstDummyHash('password123')).toBe(false);
  });
});

// #443 PR3 — the policy for a password an owner chooses, and the generated temporary one.
describe('chosenPasswordViolation', () => {
  it('adds the upper bound and the offline blocklist to the floor', () => {
    expect(chosenPasswordViolation('a perfectly fine passphrase')).toBeNull();
    expect(chosenPasswordViolation('short')).toBe('too_short');
    expect(chosenPasswordViolation('z'.repeat(MAX_PASSWORD_LENGTH))).toBeNull();
    expect(chosenPasswordViolation('z'.repeat(MAX_PASSWORD_LENGTH + 1))).toBe('too_long');
    expect(chosenPasswordViolation('UNBELIEVABLE')).toBe('common');
    expect(chosenPasswordViolation(undefined)).toBe('required');
    expect(chosenPasswordViolation(123456789012)).toBe('required');
  });

  it('blocks the shop name in the spellings people type, anywhere in the password', () => {
    for (const pw of [
      'srisurart2569!!',
      'My-Sri-Surat-Shop',
      'sri_surart_owner',
      'ร้านศรีสุรัตน์อะไหล่',
      'ศรีสุรัต123456789',
    ]) {
      expect(chosenPasswordViolation(pw)).toBe('common');
    }
    expect(isCommonPassword('surat thani road 12')).toBe(false);
  });

  it('measures the NFC form', () => {
    expect(normalizePassword('é')).toBe('é');
  });
});

describe('generateTempPassword', () => {
  it('is 16 characters from the alphabet without 0 O 1 l I, and different every time', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 200; i++) {
      const p = generateTempPassword();
      expect(p).toHaveLength(16);
      expect(p).not.toMatch(/[0O1lI]/);
      for (const ch of p) expect(TEMP_PASSWORD_ALPHABET).toContain(ch);
      seen.add(p);
    }
    expect(seen.size).toBe(200);
    expect(TEMP_PASSWORD_ALPHABET).not.toMatch(/[0O1lI]/);
    // A generated one always passes the floor it will later be replaced under.
    expect(passwordPolicyViolation(generateTempPassword())).toBeNull();
  });
});
