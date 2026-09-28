import { describe, expect, it } from 'vitest';
import { describeSyncError, parsePlatformAdmins } from './platform-admins-env.js';

/** #443: `PLATFORM_ADMINS=user:password,…` — validated first, a bad entry fails the boot. */
describe('parsePlatformAdmins (PLATFORM_ADMINS, #443)', () => {
  const PW = 'twelve-chars-ok';

  /** The thrown message, for asserting what it must not contain. */
  function errorOf(raw: string): string {
    try {
      parsePlatformAdmins(raw);
    } catch (e) {
      return (e as Error).message;
    }
    throw new Error('expected a throw');
  }

  it('treats absent and blank as unset', () => {
    expect(parsePlatformAdmins(undefined)).toBeUndefined();
    expect(parsePlatformAdmins('')).toBeUndefined();
    expect(parsePlatformAdmins('   ')).toBeUndefined();
  });

  it('parses a list and trims whitespace around names and passwords', () => {
    expect(parsePlatformAdmins(` alice : ${PW} ,bob:${PW}2`)).toEqual([
      { username: 'alice', password: PW },
      { username: 'bob', password: `${PW}2` },
    ]);
  });

  it('splits on the first colon only, so a password may contain `:`', () => {
    expect(parsePlatformAdmins('root:a:b:c:dddddddddd')).toEqual([
      { username: 'root', password: 'a:b:c:dddddddddd' },
    ]);
  });

  it('refuses a duplicate username, naming positions only', () => {
    const msg = errorOf(`secret-ish:${PW},secret-ish:${PW}x`);
    expect(msg).toBe('PLATFORM_ADMINS entry #2 repeats the username of entry #1');
  });

  it('refuses a password under the 12-character floor without echoing it or the username', () => {
    const msg = errorOf('alice:short-pw');
    expect(msg).toMatch(/entry #1's password is too weak: at least 12/);
    expect(msg).not.toContain('short-pw');
    expect(msg).not.toContain('alice');
    expect(errorOf('alice:   ')).toMatch(/entry #1's password is required/);
  });

  it('refuses a malformed entry, an empty entry and an empty username', () => {
    expect(errorOf('alice-no-colon')).toMatch(/entry #1 is malformed/);
    expect(errorOf('alice-no-colon')).not.toContain('alice');
    expect(errorOf(`a:${PW},`)).toMatch(/entry #2 is malformed/);
    expect(errorOf(`a:${PW},,b:${PW}`)).toMatch(/entry #2 is malformed/);
    expect(errorOf(` :${PW}`)).toMatch(/entry #1 has an empty username/);
  });
});

describe('describeSyncError (#443)', () => {
  it('keeps message and code, drops the query and its hash-bearing parameters', () => {
    const err = Object.assign(new Error('duplicate key value violates unique constraint'), {
      code: '23505',
      query: 'UPDATE platform_admins SET password_hash = $2 …',
      parameters: ['alice', '$argon2id$v=19$m=65536,p=1,t=3$c2FsdA$aGFzaA'],
    });
    const out = describeSyncError(err);
    expect(out).toEqual({ message: err.message, code: '23505' });
    expect(JSON.stringify(out)).not.toContain('argon2');
    expect(JSON.stringify(out)).not.toContain('alice');
  });

  it('never stringifies a non-Error', () => {
    expect(describeSyncError({ password: 'x' })).toEqual({ message: 'PLATFORM_ADMINS sync failed' });
  });
});
