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
});
