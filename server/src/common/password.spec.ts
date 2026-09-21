import { describe, expect, it } from 'vitest';
import {
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
