import { describe, it, expect, vi, afterEach } from 'vitest';
import { AuthService } from './auth.service.js';

describe('AuthService', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  describe('calculateRefreshExpiry (ADR-0009)', () => {
    const authService = new AuthService(
      {} as any,
      {} as any,
      {} as any,
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
      const authService = new AuthService({} as any, {} as any, {} as any);
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

      const authService = new AuthService(dsMock as any, signerMock as any, auditMock as any);

      const res = await authService.refreshTokenPayload({
        aud: 'tenant',
        typ: 'refresh',
        sub: 'u1',
        tid: 't1',
        role: 'cashier',
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

      const authService = new AuthService(dsMock as any, {} as any, auditMock as any);

      const res = await authService.enrolDevice('code-12345');

      // Assert unwrapped return shape
      expect(res).toHaveProperty('deviceToken');
      expect((res as any).status).toBeUndefined();
      expect((res as any).data).toBeUndefined();
    });
  });
});
