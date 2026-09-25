import { describe, it, expect, vi, afterEach } from 'vitest';
import { UnauthorizedException } from '@nestjs/common';
import { AuthService } from './auth.service.js';

// Pass-through, with a hook so a test can look at the pool at the moment argon2 runs.
const argonHook = vi.hoisted(() => ({ onVerify: null as null | (() => void) }));
vi.mock('argon2', async (importOriginal) => {
  const orig = await importOriginal<typeof import('argon2')>();
  return {
    ...orig,
    verify: (...args: Parameters<typeof orig.verify>) => {
      argonHook.onVerify?.();
      return orig.verify(...args);
    },
  };
});

describe('AuthService', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  const rateLimitMock = {
    getFailureStatus: vi.fn().mockResolvedValue({ allowed: true }),
    recordFailure: vi.fn().mockResolvedValue(1),
    consumeAttempt: vi.fn().mockResolvedValue({ allowed: true }),
    refundAttempt: vi.fn().mockResolvedValue(undefined),
    clearKey: vi.fn().mockResolvedValue(undefined),
  };

  describe('calculateRefreshExpiry (ADR-0009)', () => {
    const authService = new AuthService(
      {} as any,
      {} as any,
      {} as any,
      rateLimitMock as any,
    );

    it('expires at 04:00 AM the same day if issued before 03:00 AM (e.g. 02:30 AM)', () => {
      // 2026-09-10 02:30:00 Bangkok (UTC+7) = 2026-09-09 19:30:00 UTC
      const mockNow = new Date('2026-09-09T19:30:00Z');
      vi.useFakeTimers();
      vi.setSystemTime(mockNow);

      const exp = authService.calculateRefreshExpiry('Asia/Bangkok');
      const expDate = new Date(exp * 1000);

      // Target: 2026-09-10 04:00:00 Bangkok = 2026-09-09 21:00:00 UTC
      expect(expDate.toISOString()).toBe('2026-09-09T21:00:00.000Z');
    });

    it('expires at 04:00 AM the NEXT day if issued after 03:00 AM (e.g. 03:30 AM)', () => {
      // 2026-09-10 03:30:00 Bangkok (UTC+7) = 2026-09-09 20:30:00 UTC
      const mockNow = new Date('2026-09-09T20:30:00Z');
      vi.useFakeTimers();
      vi.setSystemTime(mockNow);

      const exp = authService.calculateRefreshExpiry('Asia/Bangkok');
      const expDate = new Date(exp * 1000);

      // Target: 2026-09-11 04:00:00 Bangkok = 2026-09-10 21:00:00 UTC
      expect(expDate.toISOString()).toBe('2026-09-10T21:00:00.000Z');
    });

    it('expires at 04:00 AM the next day when logged in during regular store hours (e.g. 09:00 AM)', () => {
      // 2026-09-10 09:00:00 Bangkok (UTC+7) = 2026-09-10 02:00:00 UTC
      const mockNow = new Date('2026-09-10T02:00:00Z');
      vi.useFakeTimers();
      vi.setSystemTime(mockNow);

      const exp = authService.calculateRefreshExpiry('Asia/Bangkok');
      const expDate = new Date(exp * 1000);

      // Target: 2026-09-11 04:00:00 Bangkok = 2026-09-10 21:00:00 UTC
      expect(expDate.toISOString()).toBe('2026-09-10T21:00:00.000Z');
    });

    it('falls back to Asia/Bangkok without crashing if invalid timezone is passed', () => {
      const mockNow = new Date('2026-09-10T02:00:00Z');
      vi.useFakeTimers();
      vi.setSystemTime(mockNow);

      expect(() => authService.calculateRefreshExpiry('Invalid/Timezone')).not.toThrow();
      const exp = authService.calculateRefreshExpiry('Invalid/Timezone');
      expect(exp).toBeGreaterThan(Math.floor(mockNow.getTime() / 1000));
    });
  });

  describe('refreshTokenPayload', () => {
    it('rejects tokens with aud != "tenant"', async () => {
      const authService = new AuthService({} as any, {} as any, {} as any, rateLimitMock as any);
      await expect(
        authService.refreshTokenPayload({
          aud: 'platform' as any,
          typ: 'refresh',
          sub: 'u1',
          tid: 't1',
          exp: 1234567890,
          iat: 1234567800,
          iss: 'srisurart-pos',
          jti: 'jti-1',
        }),
      ).rejects.toThrow('Invalid token audience');
    });

    it('preserves incoming exp on reissued refresh token and returns unwrapped data', async () => {
      const targetExp = 1789000000;
      const qrMock = {
        connect: vi.fn(),
        startTransaction: vi.fn(),
        commitTransaction: vi.fn(),
        rollbackTransaction: vi.fn(),
        release: vi.fn(),
        query: vi.fn().mockImplementation((sql: string) => {
          if (sql.includes('SELECT u.is_active')) {
            return [{ is_active: true, status: 'active', timezone: 'Asia/Bangkok' }];
          }
          return [];
        }),
        manager: {},
        isTransactionActive: true,
      };

      const dsMock = {
        createQueryRunner: () => qrMock,
      };

      const signerMock = {
        sign: vi.fn().mockImplementation((payload: any, expiresInOrExp: any) => {
          if (payload.typ === 'refresh') {
            expect(expiresInOrExp).toBe(targetExp);
          }
          return `token-${payload.typ}`;
        }),
      };

      const auditMock = {
        log: vi.fn(),
      };

      const authService = new AuthService(dsMock as any, signerMock as any, auditMock as any, rateLimitMock as any);

      const res = await authService.refreshTokenPayload({
        aud: 'tenant',
        typ: 'refresh',
        sub: 'u1',
        tid: 't1',
        role: 'owner',
        exp: targetExp,
        iat: targetExp - 3600,
        iss: 'srisurart-pos',
        jti: 'jti-orig',
      });

      // Assert unwrapped return shape (no double envelope)
      expect(res).toEqual({
        accessToken: 'token-access',
        refreshToken: 'token-refresh',
      });
      expect(signerMock.sign).toHaveBeenCalledWith(
        expect.objectContaining({ typ: 'refresh' }),
        targetExp,
      );
    });

    it('throws TENANT_SUSPENDED (403) with Thai message if tenant is not active on refresh', async () => {
      const qrMock = {
        connect: vi.fn(),
        startTransaction: vi.fn(),
        commitTransaction: vi.fn(),
        rollbackTransaction: vi.fn(),
        release: vi.fn(),
        query: vi.fn().mockReturnValue([
          { is_active: true, status: 'suspended', timezone: 'Asia/Bangkok' },
        ]),
        manager: {},
        isTransactionActive: true,
      };
      const authService = new AuthService(
        { createQueryRunner: () => qrMock } as any,
        {} as any,
        { log: vi.fn() } as any,
        rateLimitMock as any,
      );

      try {
        await authService.refreshTokenPayload({
          aud: 'tenant',
          typ: 'refresh',
          sub: 'u1',
          tid: 't1',
          exp: 1789000000,
          iat: 1788990000,
          iss: 'srisurart-pos',
          jti: 'jti-1',
        });
        expect.unreachable('Should have thrown ForbiddenException');
      } catch (err: any) {
        expect(err.getStatus()).toBe(403);
        expect(err.getResponse()).toEqual({
          code: 'TENANT_SUSPENDED',
          message: 'ร้านนี้ถูกระงับการใช้งาน',
        });
      }
    });

    it('throws UnauthorizedException if user is inactive on refresh', async () => {
      const qrMock = {
        connect: vi.fn(),
        startTransaction: vi.fn(),
        commitTransaction: vi.fn(),
        rollbackTransaction: vi.fn(),
        release: vi.fn(),
        query: vi.fn().mockReturnValue([
          { is_active: false, status: 'active', timezone: 'Asia/Bangkok' },
        ]),
        manager: {},
        isTransactionActive: true,
      };
      const authService = new AuthService(
        { createQueryRunner: () => qrMock } as any,
        {} as any,
        { log: vi.fn() } as any,
        rateLimitMock as any,
      );

      await expect(
        authService.refreshTokenPayload({
          aud: 'tenant',
          typ: 'refresh',
          sub: 'u1',
          tid: 't1',
          exp: 1789000000,
          iat: 1788990000,
          iss: 'srisurart-pos',
          jti: 'jti-1',
        }),
      ).rejects.toThrow('User is inactive');
    });
  });

  describe('enrolDevice', () => {
    it('returns unwrapped deviceToken', async () => {
      const qrMock = {
        connect: vi.fn(),
        startTransaction: vi.fn(),
        commitTransaction: vi.fn(),
        rollbackTransaction: vi.fn(),
        release: vi.fn(),
        query: vi.fn().mockImplementation((sql: string) => {
          if (sql.includes('auth_enrol_device')) {
            return [{ tenant_id: 't1', id: 'dev-1' }];
          }
          return [];
        }),
        manager: {},
        isTransactionActive: false,
      };

      const dsMock = {
        createQueryRunner: () => qrMock,
      };

      const auditMock = {
        log: vi.fn(),
      };

      const authService = new AuthService(dsMock as any, {} as any, auditMock as any, rateLimitMock as any);

      const res = await authService.enrolDevice('code-12345');

      // Assert unwrapped return shape
      expect(res).toHaveProperty('deviceToken');
      expect((res as any).status).toBeUndefined();
      expect((res as any).data).toBeUndefined();
    });

    it('normalizes enrolment code (trims whitespace and converts to uppercase)', async () => {
      let passedCodeHash = '';
      const qrMock = {
        connect: vi.fn(),
        startTransaction: vi.fn(),
        commitTransaction: vi.fn(),
        rollbackTransaction: vi.fn(),
        release: vi.fn(),
        query: vi.fn().mockImplementation((sql: string, params: any[]) => {
          if (sql.includes('auth_enrol_device')) {
            passedCodeHash = params[0];
            return [{ tenant_id: 't1', id: 'dev-1' }];
          }
          return [];
        }),
        manager: {},
        isTransactionActive: false,
      };

      const authService = new AuthService(
        { createQueryRunner: () => qrMock } as any,
        {} as any,
        { log: vi.fn() } as any,
        rateLimitMock as any,
      );

      await authService.enrolDevice('  a1b2c3d4  ');

      // Hash of "A1B2C3D4"
      const expectedHash = (await crypto.subtle.digest('SHA-256', new TextEncoder().encode('A1B2C3D4')));
      const expectedHex = Buffer.from(expectedHash).toString('hex');
      expect(passedCodeHash).toBe(expectedHex);
    });
  });

  describe('login', () => {
    it('authenticates with valid Argon2id password hash and returns access & refresh tokens', async () => {
      const passHash = '$argon2id$v=19$m=65536,p=4,t=3$gJw9MtqrLGeVn4IEjCOu8A$t9z3qf7c29GFn4x8qa9LmO25XCYHm06+MKoB4zGVxEU'; // 'password123'
      const qrMock = {
        connect: vi.fn(),
        startTransaction: vi.fn(),
        commitTransaction: vi.fn(),
        rollbackTransaction: vi.fn(),
        release: vi.fn(),
        query: vi.fn().mockImplementation((sql: string) => {
          if (sql.includes('auth_lookup_user_for_login')) {
            return [
              {
                id: 'u1',
                tenant_id: 't1',
                username: 'owner',
                password_hash: passHash,
                role: 'owner',
                display_name: 'Store Owner',
                is_active: true,
                tenant_status: 'active',
                timezone: 'Asia/Bangkok',
              },
            ];
          }
          return [];
        }),
        manager: {},
        isTransactionActive: false,
      };

      const signerMock = {
        sign: vi.fn().mockImplementation((payload: any) => `token-${payload.typ}`),
      };

      const auditMock = {
        log: vi.fn(),
      };

      const authService = new AuthService(
        { createQueryRunner: () => qrMock, query: qrMock.query } as any,
        signerMock as any,
        auditMock as any,
        rateLimitMock as any,
      );

      const res = await authService.login({
        username: 'owner',
        password: 'password123',
      });

      expect(res.accessToken).toBe('token-access');
      expect(res.refreshToken).toBe('token-refresh');
      expect(res.user.username).toBe('owner');
      expect(res.user.role).toBe('owner');
    });

    it('defensively handles malformed/non-argon2 password hash without throwing 500', async () => {
      const malformedHash = 'not-an-argon2-hash';
      const qrMock = {
        connect: vi.fn(),
        startTransaction: vi.fn(),
        commitTransaction: vi.fn(),
        rollbackTransaction: vi.fn(),
        release: vi.fn(),
        query: vi.fn().mockImplementation((sql: string) => {
          if (sql.includes('auth_lookup_user_for_login')) {
            return [
              {
                id: 'u1',
                tenant_id: 't1',
                username: 'owner',
                password_hash: malformedHash,
                role: 'owner',
                display_name: 'Store Owner',
                is_active: true,
                tenant_status: 'active',
                timezone: 'Asia/Bangkok',
              },
            ];
          }
          return [];
        }),
        manager: {},
        isTransactionActive: false,
      };

      const authService = new AuthService(
        { createQueryRunner: () => qrMock, query: qrMock.query } as any,
        {} as any,
        { log: vi.fn() } as any,
        rateLimitMock as any,
      );

      await expect(
        authService.login({
          username: 'owner',
          password: 'password123',
        }),
      ).rejects.toThrow('Invalid credentials');
    });

    describe('brute-force keys and audit ip', () => {
      const hash = (token: string) =>
        (new AuthService({} as any, {} as any, {} as any, rateLimitMock as any) as any).hashDeviceToken(
          token,
        ) as Promise<string>;

      const build = (
        passHash: string,
        tenantByHash: Record<string, string> = {},
        userOverrides: Record<string, unknown> = {},
        userCount = 1,
      ) => {
        const auditMock = { log: vi.fn() };
        const qrMock = {
          connect: vi.fn(),
          startTransaction: vi.fn(),
          commitTransaction: vi.fn(),
          rollbackTransaction: vi.fn(),
          release: vi.fn(),
          query: vi.fn().mockImplementation((sql: string, params: any[]) => {
            if (sql.includes('auth_lookup_device_by_token')) {
              const tid = tenantByHash[params[0]];
              return tid ? [{ tenant_id: tid, id: `d-${tid}`, role: 'pos', retired_at: null }] : [];
            }
            if (sql.includes('auth_lookup_user_for_login')) {
              return Array.from({ length: userCount }, () => ({
                id: 'u1',
                tenant_id: params[1] ?? 't1',
                username: 'owner',
                password_hash: passHash,
                role: 'owner',
                display_name: 'Store Owner',
                is_active: true,
                tenant_status: 'active',
                timezone: 'Asia/Bangkok',
                ...userOverrides,
              }));
            }
            return [];
          }),
          manager: {},
          isTransactionActive: false,
        };
        const service = new AuthService(
          { createQueryRunner: () => qrMock, query: qrMock.query } as any,
          { sign: vi.fn().mockReturnValue('tok') } as any,
          auditMock as any,
          rateLimitMock as any,
        );
        return { auditMock, service };
      };

      const checkedKeys = (prefix: string) =>
        rateLimitMock.consumeAttempt.mock.calls
          .map((c: any[]) => c[0] as string)
          .filter((k) => k.startsWith(prefix));

      it('scopes the username bucket by the device tenant', async () => {
        const { service } = build('not-an-argon2-hash', {
          [await hash('tokA')]: 'tenant-a',
          [await hash('tokB')]: 'tenant-b',
        });
        rateLimitMock.consumeAttempt.mockClear();

        for (const deviceToken of ['tokA', 'tokB']) {
          await expect(
            service.login({ username: 'owner', password: 'x', deviceToken }, '10.0.0.5'),
          ).rejects.toThrow('Invalid credentials');
        }

        expect(checkedKeys('auth:user:')).toEqual([
          'auth:user:tenant-a:owner',
          'auth:user:tenant-b:owner',
        ]);
      });

      it('keys the ip bucket by the client address it is given', async () => {
        const { service } = build('not-an-argon2-hash');
        rateLimitMock.consumeAttempt.mockClear();

        for (const ip of ['10.0.0.5', '10.0.0.6']) {
          await expect(service.login({ username: 'owner', password: 'x' }, ip)).rejects.toThrow(
            'Invalid credentials',
          );
        }

        expect(checkedKeys('auth:ip:')).toEqual(['auth:ip:10.0.0.5', 'auth:ip:10.0.0.6']);
      });

      it('refuses a locked-out ip before taking a database connection', async () => {
        const createQueryRunner = vi.fn();
        const query = vi.fn();
        const service = new AuthService(
          { createQueryRunner, query } as any,
          {} as any,
          {} as any,
          rateLimitMock as any,
        );
        rateLimitMock.consumeAttempt.mockResolvedValueOnce({ allowed: false, retryAfter: 42 });

        try {
          await expect(
            service.login({ username: 'owner', password: 'x', deviceToken: 'tokA' }, '10.0.0.9'),
          ).rejects.toMatchObject({ status: 429 });
          expect(createQueryRunner).not.toHaveBeenCalled();
          expect(query).not.toHaveBeenCalled();
        } finally {
          // A pre-fix service throws before consuming the Once value; don't leak it into the next test.
          rateLimitMock.consumeAttempt.mockReset();
          rateLimitMock.consumeAttempt.mockResolvedValue({ allowed: true });
        }
      });

      it('counts an invalid device token against the ip bucket', async () => {
        const { service } = build('not-an-argon2-hash');
        rateLimitMock.consumeAttempt.mockClear();
        rateLimitMock.refundAttempt.mockClear();

        await expect(
          service.login({ username: 'owner', password: 'x', deviceToken: 'unknown' }, '10.0.0.10'),
        ).rejects.toThrow('Invalid device token');
        expect(rateLimitMock.consumeAttempt).toHaveBeenCalledWith('auth:ip:10.0.0.10', 10, 60);
        expect(rateLimitMock.refundAttempt).not.toHaveBeenCalled();
      });

      // #138 item 1: a success must not wipe the IP bucket, or one valid account resets it every
      // 9 failures and sprays usernames with no IP limit.
      it('gives back only its own attempt on success and never clears the ip bucket', async () => {
        const argon2 = await import('argon2');
        const { service } = build(await argon2.hash('password123'));
        rateLimitMock.clearKey.mockClear();
        rateLimitMock.refundAttempt.mockClear();

        await service.login({ username: 'owner', password: 'password123' }, '10.0.0.11');

        expect(rateLimitMock.clearKey).not.toHaveBeenCalledWith('auth:ip:10.0.0.11', 60);
        expect(rateLimitMock.refundAttempt).toHaveBeenCalledWith('auth:ip:10.0.0.11', 60);
        expect(rateLimitMock.clearKey).toHaveBeenCalledWith('auth:user:-:owner', 60);
      });

      // #138 item 2: the attempt is counted before the outcome is known, in one atomic call, so
      // there is no separate read that concurrent attempts can all pass.
      it('counts the attempt atomically instead of check-then-increment', async () => {
        const { service } = build('not-an-argon2-hash');
        rateLimitMock.getFailureStatus.mockClear();
        rateLimitMock.recordFailure.mockClear();
        rateLimitMock.consumeAttempt.mockClear();

        await expect(service.login({ username: 'owner', password: 'x' }, '10.0.0.12')).rejects.toThrow(
          'Invalid credentials',
        );

        expect(rateLimitMock.getFailureStatus).not.toHaveBeenCalled();
        expect(rateLimitMock.recordFailure).not.toHaveBeenCalled();
        expect(rateLimitMock.consumeAttempt.mock.calls.map((c: any[]) => c[0])).toEqual([
          'auth:ip:10.0.0.12',
          'auth:user:-:owner',
        ]);
      });

      // #138 item 4: every refusal counts against both buckets; the responses are unchanged.
      it.each([
        ['an ambiguous username', {}, 2, 'Ambiguous username'],
        ['an inactive user', { is_active: false }, 1, 'User is inactive'],
        ['a suspended tenant', { tenant_status: 'suspended' }, 1, 'ร้านนี้ถูกระงับการใช้งาน'],
      ])('counts %s against the ip and username buckets', async (_l, overrides, count, message) => {
        const { service } = build('not-an-argon2-hash', {}, overrides, count as number);
        rateLimitMock.consumeAttempt.mockClear();
        rateLimitMock.recordFailure.mockClear();
        rateLimitMock.refundAttempt.mockClear();
        rateLimitMock.clearKey.mockClear();

        await expect(service.login({ username: 'owner', password: 'x' }, '10.0.0.13')).rejects.toThrow(
          message as string,
        );

        const counted = [
          ...rateLimitMock.consumeAttempt.mock.calls,
          ...rateLimitMock.recordFailure.mock.calls,
        ].map((c: any[]) => c[0]);
        expect(counted).toEqual(expect.arrayContaining(['auth:ip:10.0.0.13', 'auth:user:-:owner']));
        expect(rateLimitMock.refundAttempt).not.toHaveBeenCalled();
        expect(rateLimitMock.clearKey).not.toHaveBeenCalled();
      });

      // A burst of logins used to pin every pool slot through argon2 (the connection was taken
      // before the lookup and released only at the end), starving sales on the same pool.
      it.each([
        ['a successful login', 'password123', undefined],
        ['a wrong password', 'wrong', 'Invalid credentials'],
      ])('holds no connection during argon2 and never two at once: %s', async (_l, password, error) => {
        const argon2 = await import('argon2');
        const passHash = await argon2.hash('password123');
        let held = 0;
        let maxHeld = 0;
        const heldAtVerify: number[] = [];
        const take = () => {
          held++;
          maxHeld = Math.max(maxHeld, held);
        };
        const lookup = vi.fn().mockImplementation(async (sql: string) => {
          take();
          await Promise.resolve();
          held--;
          return sql.includes('auth_lookup_user_for_login')
            ? [{ id: 'u1', tenant_id: 't1', username: 'owner', password_hash: passHash, role: 'owner',
                 display_name: 'O', is_active: true, tenant_status: 'active', timezone: 'Asia/Bangkok' }]
            : [{ tenant_id: 't1', id: 'd1', role: 'pos', retired_at: null }];
        });
        const auditMock = { log: vi.fn() };
        const service = new AuthService(
          {
            query: lookup,
            createQueryRunner: () => ({
              connect: vi.fn().mockImplementation(async () => take()),
              release: vi.fn().mockImplementation(async () => { held--; }),
              startTransaction: vi.fn(),
              commitTransaction: vi.fn(),
              rollbackTransaction: vi.fn(),
              // Lookups answer here too, so a service that reads through its own runner
              // still gets rows and fails on the connection count, not on a missing mock.
              query: vi.fn().mockImplementation((sql: string) =>
                sql.includes('auth_lookup_') ? lookup(sql) : [],
              ),
              manager: {},
              isTransactionActive: false,
            }),
          } as any,
          { sign: vi.fn().mockReturnValue('tok') } as any,
          auditMock as any,
          rateLimitMock as any,
        );
        argonHook.onVerify = () => heldAtVerify.push(held);
        try {
          const attempt = service.login({ username: 'owner', password, deviceToken: 'tok' }, '10.0.0.20');
          if (error) await expect(attempt).rejects.toThrow(error);
          else await attempt;
        } finally {
          argonHook.onVerify = null;
        }

        expect(heldAtVerify).toEqual([0]);
        expect(maxHeld).toBe(1);
        expect(held).toBe(0);
        expect(auditMock.log).toHaveBeenCalledTimes(1);
      });

      // #425: an unknown username must cost the same one argon2 verify as a wrong password,
      // and answer with the same error, so neither latency nor body reveals which names exist.
      it.each([
        ['an unknown username', 0],
        ['a wrong password', 1],
      ])('runs argon2 verify exactly once and says Invalid credentials for %s', async (_l, count) => {
        const argon2 = await import('argon2');
        const { service, auditMock } = build(await argon2.hash('password123'), {}, {}, count as number);
        let verifies = 0;
        argonHook.onVerify = () => verifies++;
        let caught: unknown;
        try {
          await service.login({ username: 'owner', password: 'wrong' }, '10.0.0.30');
        } catch (err) {
          caught = err;
        } finally {
          argonHook.onVerify = null;
        }

        expect(verifies).toBe(1);
        expect(caught).toBeInstanceOf(UnauthorizedException);
        expect((caught as UnauthorizedException).getResponse()).toMatchObject({
          statusCode: 401,
          message: 'Invalid credentials',
        });
        // Unchanged: an unknown user has no tenant to audit under; a wrong password is audited.
        expect(auditMock.log).toHaveBeenCalledTimes(count === 0 ? 0 : 1);
      });

      it('records the client ip on auth.login_failed and auth.login', async () => {
        const argon2 = await import('argon2');
        const good = await argon2.hash('password123');

        const failed = build(good);
        await expect(
          failed.service.login({ username: 'owner', password: 'wrong' }, '10.0.0.7'),
        ).rejects.toThrow('Invalid credentials');
        expect(failed.auditMock.log.mock.calls[0][1]).toMatchObject({
          action: 'auth.login_failed',
          ip: '10.0.0.7',
        });

        const ok = build(good);
        await ok.service.login({ username: 'owner', password: 'password123' }, '10.0.0.8');
        expect(ok.auditMock.log.mock.calls[0][1]).toMatchObject({
          action: 'auth.login',
          ip: '10.0.0.8',
        });
      });
    });
  });
});

