import { describe, it, expect, vi, beforeEach } from 'vitest';
import { UnauthorizedException } from '@nestjs/common';
import { AuthService } from './auth.service.js';
import type { JwtPayload } from './jwt-keys.service.js';

// #443 PR3 — spy on the two argon2 entry points so a test can prove a refusal came before
// either of them (the CLAUDE.md "validate first, then argon2, then the transaction" rule).
const pw = vi.hoisted(() => ({ hash: vi.fn(), verify: vi.fn() }));
vi.mock('../common/password.js', async (importOriginal) => {
  const orig = await importOriginal<typeof import('../common/password.js')>();
  return {
    ...orig,
    hashPassword: (p: string) => {
      pw.hash(p);
      return orig.hashPassword(p);
    },
    verifyPassword: (p: string, h: string) => {
      pw.verify(p, h);
      return orig.verifyPassword(p, h);
    },
  };
});

const { hashPassword } = await import('../common/password.js');

const rateLimit = {
  consumeAttempt: vi.fn().mockResolvedValue({ allowed: true }),
  refundAttempt: vi.fn().mockResolvedValue(undefined),
  clearKey: vi.fn().mockResolvedValue(undefined),
};

function queryRunner(onQuery: (sql: string, params?: unknown[]) => unknown) {
  return {
    connect: vi.fn(),
    startTransaction: vi.fn(),
    commitTransaction: vi.fn(),
    rollbackTransaction: vi.fn(),
    release: vi.fn(),
    query: vi.fn().mockImplementation(async (sql: string, params?: unknown[]) => onQuery(sql, params)),
    manager: {},
    isTransactionActive: true,
  };
}

const signer = {
  sign: vi.fn().mockImplementation((payload: { typ: string }, exp: unknown) => `token-${payload.typ}-${String(exp)}`),
};

const pwchangePayload = (over: Partial<JwtPayload> = {}): JwtPayload => ({
  iss: 'srisurart-pos',
  aud: 'tenant',
  sub: 'u1',
  tid: 't1',
  role: 'owner',
  typ: 'pwchange',
  jti: 'j1',
  iat: Math.floor(Date.now() / 1000),
  exp: Math.floor(Date.now() / 1000) + 600,
  ...over,
});

describe('owner password lifecycle v2 (#443 PR3)', () => {
  let tempHash: string;

  beforeEach(async () => {
    tempHash ??= await hashPassword('TempPassw0rdXyz');
    pw.hash.mockClear();
    pw.verify.mockClear();
    signer.sign.mockClear();
  });

  describe('login', () => {
    const loginWith = async (userRow: Record<string, unknown>) => {
      const qr = queryRunner(() => []);
      const audit = { log: vi.fn() };
      const svc = new AuthService(
        {
          createQueryRunner: () => qr,
          query: vi.fn().mockResolvedValue([
            {
              id: 'u1',
              tenant_id: 't1',
              username: 'owner',
              password_hash: tempHash,
              role: 'owner',
              display_name: 'เจ้าของ',
              is_active: true,
              tenant_status: 'active',
              timezone: 'Asia/Bangkok',
              must_change_password: false,
              temp_password_expires_at: null,
              password_changed_at: null,
              ...userRow,
            },
          ]),
        } as any,
        signer as any,
        audit as any,
        rateLimit as any,
      );
      return { svc, audit };
    };

    it('a temporary password yields only a pwchange token: no access token, no refresh token', async () => {
      const { svc, audit } = await loginWith({
        must_change_password: true,
        temp_password_expires_at: new Date(Date.now() + 3600_000),
      });
      const res = await svc.login({ username: 'owner', password: 'TempPassw0rdXyz' });

      expect(res).toEqual({
        passwordChangeRequired: true,
        passwordChangeToken: 'token-pwchange-10m',
        user: { id: 'u1', username: 'owner', role: 'owner', displayName: 'เจ้าของ' },
      });
      expect(signer.sign).toHaveBeenCalledTimes(1);
      expect(signer.sign.mock.calls[0][0].typ).toBe('pwchange');
      expect(audit.log.mock.calls[0][1]).toMatchObject({
        action: 'auth.login',
        after: { passwordChangeRequired: true },
      });
    });

    it('the deviceToken path cannot skip the change either', async () => {
      const qr = queryRunner(() => []);
      const svc = new AuthService(
        {
          createQueryRunner: () => qr,
          query: vi.fn().mockImplementation(async (sql: string) =>
            sql.includes('auth_lookup_device_by_token')
              ? [{ tenant_id: 't1', id: 'pos1', role: 'pos', retired_at: null }]
              : [
                  {
                    id: 'u1',
                    tenant_id: 't1',
                    username: 'owner',
                    password_hash: tempHash,
                    role: 'owner',
                    display_name: 'เจ้าของ',
                    is_active: true,
                    tenant_status: 'active',
                    timezone: 'Asia/Bangkok',
                    must_change_password: true,
                    temp_password_expires_at: new Date(Date.now() + 3600_000),
                    password_changed_at: null,
                  },
                ],
          ),
        } as any,
        signer as any,
        { log: vi.fn() } as any,
        rateLimit as any,
      );
      const res = await svc.login({
        username: 'owner',
        password: 'TempPassw0rdXyz',
        deviceToken: 'dev-token',
      });
      expect(res.passwordChangeRequired).toBe(true);
      expect(res.accessToken).toBeUndefined();
      expect(signer.sign.mock.calls[0][0]).toMatchObject({ typ: 'pwchange', did: 'pos1', drole: 'pos' });
    });

    it('an expired temporary password is refused with TEMP_PASSWORD_EXPIRED, after the password check', async () => {
      const { svc, audit } = await loginWith({
        must_change_password: true,
        temp_password_expires_at: new Date(Date.now() - 1000),
      });
      await expect(
        svc.login({ username: 'owner', password: 'TempPassw0rdXyz' }),
      ).rejects.toMatchObject({ status: 401, response: { code: 'TEMP_PASSWORD_EXPIRED' } });
      expect(signer.sign).not.toHaveBeenCalled();
      expect(audit.log.mock.calls[0][1]).toMatchObject({
        action: 'auth.login_failed',
        before: { reason: 'temp_password_expired' },
      });

      // The wrong password on the same account is still the generic 401 — expiry is not an oracle.
      await expect(
        svc.login({ username: 'owner', password: 'not-the-password' }),
      ).rejects.toMatchObject({ status: 401, response: { message: 'Invalid credentials' } });
    });

    it('a pre-PR3 hash of a non-NFC password still logs in (NFC reorders Thai marks)', async () => {
      // Tone mark (U+0E48) typed before the below-vowel (U+0E39): NFC swaps them.
      const typed = 'รหัสผ่านป\u0e48\u0e39ของร้าน';
      expect(typed.normalize('NFC')).not.toBe(typed);
      const { svc } = await loginWith({ password_hash: await hashPassword(typed) });
      const res = await svc.login({ username: 'owner', password: typed });
      expect(res.accessToken).toBe('token-access-15m');
    });

    it('a normal login carries passwordChangedAt for the banner', async () => {
      const changed = new Date('2026-09-26T03:00:00Z');
      const { svc } = await loginWith({ password_changed_at: changed });
      const res = await svc.login({ username: 'owner', password: 'TempPassw0rdXyz' });
      expect(res.passwordChangedAt).toBe(changed.toISOString());
      expect(res.accessToken).toBe('token-access-15m');
    });
  });

  describe('changePassword', () => {
    const service = (onQuery: (sql: string, params?: unknown[]) => unknown) => {
      const runners: ReturnType<typeof queryRunner>[] = [];
      const audit = { log: vi.fn() };
      const ds = {
        createQueryRunner: vi.fn(() => {
          const qr = queryRunner(onQuery);
          runners.push(qr);
          return qr;
        }),
      };
      const svc = new AuthService(ds as any, signer as any, audit as any, rateLimit as any);
      return { svc, ds, audit, runners };
    };

    const currentRow = (over: Record<string, unknown> = {}) => ({
      password_hash: tempHash,
      must_change_password: true,
      is_active: true,
      username: 'owner',
      role: 'owner',
      display_name: 'เจ้าของ',
      status: 'active',
      timezone: 'Asia/Bangkok',
      password_changed_epoch: null,
      ...over,
    });

    it.each([
      ['too_short', 'short-pw'],
      ['too_long', 'x'.repeat(129)],
      ['common', 'unbelievable'],
      ['common', 'Srisurart-2569!!'],
      ['common', 'ร้านศรีสุรัตน์ของเรา'],
      ['required', '            '],
      ['required', 12345678901234],
    ])('refuses %s (%s) before any connection and before argon2', async (reason, newPassword) => {
      const { svc, ds } = service(() => {
        throw new Error('must not query');
      });
      await expect(svc.changePassword(pwchangePayload(), newPassword)).rejects.toMatchObject({
        status: 400,
        response: { code: 'WEAK_PASSWORD', details: { reason } },
      });
      expect(ds.createQueryRunner).not.toHaveBeenCalled();
      expect(pw.hash).not.toHaveBeenCalled();
      expect(pw.verify).not.toHaveBeenCalled();
    });

    it('accepts exactly 128 characters (the bound is inclusive)', async () => {
      const { svc } = service((sql) => {
        if (sql.includes('SELECT u.password_hash')) return [currentRow()];
        if (sql.includes('UPDATE users')) return [[{ password_changed_at: new Date() }], 1];
        return [];
      });
      await expect(svc.changePassword(pwchangePayload(), 'y'.repeat(128))).resolves.toBeDefined();
    });

    it('refuses the temporary password itself (same_as_temp) without hashing or opening a write', async () => {
      const { svc, runners } = service((sql) =>
        sql.includes('SELECT u.password_hash') ? [currentRow()] : [],
      );
      await expect(svc.changePassword(pwchangePayload(), 'TempPassw0rdXyz')).rejects.toMatchObject({
        status: 400,
        response: { code: 'WEAK_PASSWORD', details: { reason: 'same_as_temp' } },
      });
      expect(pw.hash).not.toHaveBeenCalled();
      expect(runners).toHaveLength(1); // the read only — no write transaction was opened
      expect(runners[0].release).toHaveBeenCalled();
    });

    it('holds no connection while argon2 runs', async () => {
      const { svc, runners } = service((sql) => {
        if (sql.includes('SELECT u.password_hash')) return [currentRow()];
        if (sql.includes('UPDATE users')) return [[{ password_changed_at: new Date() }], 1];
        return [];
      });
      pw.hash.mockImplementationOnce(() => {
        const held = runners.filter((r) => r.connect.mock.calls.length > r.release.mock.calls.length);
        expect(held).toHaveLength(0);
      });
      await svc.changePassword(pwchangePayload(), 'my own long passphrase');
      expect(pw.hash).toHaveBeenCalledTimes(1);
    });

    it('succeeds: one guarded UPDATE, an audit row without the secret, then full tokens', async () => {
      let update: { sql: string; params: unknown[] } | undefined;
      const { svc, audit } = service((sql, params) => {
        if (sql.includes('SELECT u.password_hash')) return [currentRow()];
        if (sql.includes('UPDATE users')) {
          update = { sql, params: params! };
          return [[{ password_changed_at: new Date() }], 1];
        }
        return [];
      });
      const res = await svc.changePassword(pwchangePayload({ did: 'pos1', drole: 'pos' }), 'my own long passphrase', '10.0.0.9');

      expect(update!.sql).toMatch(/must_change_password = FALSE/);
      expect(update!.sql).toMatch(/password_changed_at = now\(\)/);
      expect(update!.sql).toMatch(/AND must_change_password\s+AND password_hash = \$4\s+AND temp_password_expires_at > now\(\)/);
      expect(update!.params[3]).toBe(tempHash);
      expect(String(update!.params[2])).toMatch(/^\$argon2id\$/);

      expect(audit.log).toHaveBeenCalledTimes(1);
      const row = audit.log.mock.calls[0][1];
      expect(row).toMatchObject({ action: 'auth.password_changed', userId: 'u1', deviceId: 'pos1', ip: '10.0.0.9' });
      expect(JSON.stringify(row)).not.toContain('my own long passphrase');

      expect(res.accessToken).toMatch(/^token-access/);
      expect(res.refreshToken).toMatch(/^token-refresh/);
      expect(signer.sign.mock.calls[0][0]).toMatchObject({ typ: 'access', did: 'pos1', drole: 'pos' });
    });

    it('normalises the new password to NFC before hashing', async () => {
      const decomposed = 'café au lait pw'; // é as e + combining acute
      const { svc } = service((sql) => {
        if (sql.includes('SELECT u.password_hash')) return [currentRow()];
        if (sql.includes('UPDATE users')) return [[{ password_changed_at: new Date() }], 1];
        return [];
      });
      await svc.changePassword(pwchangePayload(), decomposed);
      expect(pw.hash).toHaveBeenCalledWith(decomposed.normalize('NFC'));
    });

    it('a second use of the same token is refused (flag already cleared)', async () => {
      const { svc } = service((sql) =>
        sql.includes('SELECT u.password_hash') ? [currentRow({ must_change_password: false })] : [],
      );
      await expect(svc.changePassword(pwchangePayload(), 'my own long passphrase')).rejects.toThrow(
        UnauthorizedException,
      );
      expect(pw.hash).not.toHaveBeenCalled();
    });

    it('a token minted before a reset is refused (iat < password_changed_at)', async () => {
      const now = Math.floor(Date.now() / 1000);
      const { svc } = service((sql) =>
        sql.includes('SELECT u.password_hash')
          ? [currentRow({ password_changed_epoch: String(now) })]
          : [],
      );
      await expect(
        svc.changePassword(pwchangePayload({ iat: now - 5 }), 'my own long passphrase'),
      ).rejects.toThrow('Password change token is no longer valid');
    });

    it('a lost race (0 rows updated) rolls back and is a 401', async () => {
      const { svc, runners, audit } = service((sql) => {
        if (sql.includes('SELECT u.password_hash')) return [currentRow()];
        if (sql.includes('UPDATE users')) return [[], 0];
        return [];
      });
      await expect(svc.changePassword(pwchangePayload(), 'my own long passphrase')).rejects.toThrow(
        UnauthorizedException,
      );
      expect(audit.log).not.toHaveBeenCalled();
      expect(runners[1].rollbackTransaction).toHaveBeenCalled();
      expect(runners[1].commitTransaction).not.toHaveBeenCalled();
    });
  });

  describe('refreshTokenPayload — ADR-0009 addendum 2026-09-26', () => {
    const refreshWith = async (iat: number, epoch: string | null) => {
      const audit = { log: vi.fn() };
      const qr = queryRunner((sql) =>
        sql.includes('SELECT u.is_active')
          ? [{ is_active: true, status: 'active', timezone: 'Asia/Bangkok', password_changed_epoch: epoch }]
          : [],
      );
      const svc = new AuthService({ createQueryRunner: () => qr } as any, signer as any, audit as any, rateLimit as any);
      const run = svc.refreshTokenPayload({
        iss: 'srisurart-pos',
        aud: 'tenant',
        sub: 'u1',
        tid: 't1',
        typ: 'refresh',
        jti: 'r1',
        iat,
        exp: iat + 3600,
      });
      return { run, audit };
    };

    it('rejects a refresh token issued before the password changed, with an audit reason', async () => {
      const { run, audit } = await refreshWith(1_000, '1001');
      await expect(run).rejects.toThrow('Password has been changed');
      expect(audit.log.mock.calls[0][1]).toMatchObject({
        action: 'auth.refresh_rejected',
        before: { reason: 'password_changed' },
      });
    });

    it('keeps a token issued in the same second (strict <), and one with no change at all', async () => {
      await expect((await refreshWith(1_001, '1001')).run).resolves.toBeDefined();
      await expect((await refreshWith(1_000, null)).run).resolves.toBeDefined();
    });
  });
});
