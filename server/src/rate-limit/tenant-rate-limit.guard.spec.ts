import { describe, it, expect, vi, beforeEach } from 'vitest';
import { HttpException, HttpStatus } from '@nestjs/common';
import { TenantRateLimitGuard } from './tenant-rate-limit.guard.js';

describe('TenantRateLimitGuard (ADR-0006 & Issue #33)', () => {
  let guard: TenantRateLimitGuard;
  let serviceMock: any;
  let reflectorMock: any;

  beforeEach(() => {
    serviceMock = {
      checkRateLimit: vi.fn(),
    };
    reflectorMock = {
      getAllAndOverride: vi.fn(),
    };
    guard = new TenantRateLimitGuard(serviceMock, reflectorMock);
  });

  function createMockContext(reqOverrides: Record<string, any> = {}) {
    const headers: Record<string, string> = {};
    const res = {
      setHeader: vi.fn((key: string, val: string) => {
        headers[key.toLowerCase()] = val;
      }),
      getHeader: (key: string) => headers[key.toLowerCase()],
    };

    const req = {
      url: '/api/v1/sales',
      path: '/api/v1/sales',
      method: 'POST',
      headers: {},
      user: {
        tenantId: 'tenant-1',
        userId: 'user-1',
      },
      ...reqOverrides,
    };

    return {
      switchToHttp: () => ({
        getRequest: () => req,
        getResponse: () => res,
      }),
      getHandler: () => ({}),
      getClass: () => ({}),
    } as any;
  }

  it('allows request when within quota', async () => {
    const ctx = createMockContext();
    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    serviceMock.checkRateLimit.mockResolvedValue({ allowed: true });

    const result = await guard.canActivate(ctx);
    expect(result).toBe(true);
    expect(serviceMock.checkRateLimit).toHaveBeenCalledWith(
      'tenant-1',
      'POST:/api/v1/sales',
      undefined,
    );
  });

  it('throws 429 RATE_LIMITED with Thai message and sets Retry-After header when over quota', async () => {
    const ctx = createMockContext();
    const res = ctx.switchToHttp().getResponse();
    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    serviceMock.checkRateLimit.mockResolvedValue({
      allowed: false,
      retryAfter: 45,
    });

    try {
      await guard.canActivate(ctx);
      expect.unreachable('Should have thrown HttpException');
    } catch (err: any) {
      expect(err).toBeInstanceOf(HttpException);
      expect(err.getStatus()).toBe(HttpStatus.TOO_MANY_REQUESTS);
      expect(err.getResponse()).toEqual({
        code: 'RATE_LIMITED',
        message: 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
      });
      expect(res.setHeader).toHaveBeenCalledWith('Retry-After', '45');
    }
  });

  it('exempts /health endpoints unconditionally (ADR-0006)', async () => {
    const ctx = createMockContext({ url: '/health/live', path: '/health/live' });

    const result = await guard.canActivate(ctx);
    expect(result).toBe(true);
    expect(serviceMock.checkRateLimit).not.toHaveBeenCalled();
  });

  it('exempts routes decorated with @SkipRateLimit()', async () => {
    const ctx = createMockContext();
    reflectorMock.getAllAndOverride.mockImplementation((key: string) => {
      if (key === 'skip_rate_limit') return true;
      return undefined;
    });

    const result = await guard.canActivate(ctx);
    expect(result).toBe(true);
    expect(serviceMock.checkRateLimit).not.toHaveBeenCalled();
  });

  it('ignores forged X-Tenant-Id header and uses token tenantId only', async () => {
    const ctx = createMockContext({
      headers: {
        'x-tenant-id': 'forged-attacker-tenant',
      },
      user: {
        tenantId: 'genuine-token-tenant',
      },
    });

    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    serviceMock.checkRateLimit.mockResolvedValue({ allowed: true });

    await guard.canActivate(ctx);
    expect(serviceMock.checkRateLimit).toHaveBeenCalledWith(
      'genuine-token-tenant',
      expect.any(String),
      undefined,
    );
  });

  it('passes unauthenticated requests through (handled by Nginx per-IP layer)', async () => {
    const ctx = createMockContext({
      user: undefined, // no authenticated tenant
    });

    const result = await guard.canActivate(ctx);
    expect(result).toBe(true);
    expect(serviceMock.checkRateLimit).not.toHaveBeenCalled();
  });
});
