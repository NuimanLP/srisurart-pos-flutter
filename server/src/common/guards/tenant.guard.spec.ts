import { describe, it, expect, vi, beforeEach } from 'vitest';
import { HttpException, HttpStatus, UnauthorizedException } from '@nestjs/common';
import { TenantGuard } from './tenant.guard.js';

describe('TenantGuard', () => {
  let guard: TenantGuard;
  let jwtVerifierMock: any;
  let reflectorMock: any;
  let dsMock: any;
  let redisCacheMock: any;

  beforeEach(() => {
    jwtVerifierMock = {
      verify: vi.fn(),
    };
    reflectorMock = {
      getAllAndOverride: vi.fn(),
    };
    dsMock = {
      query: vi.fn(),
    };
    redisCacheMock = {
      get: vi.fn(),
      set: vi.fn(),
    };

    guard = new TenantGuard(
      jwtVerifierMock,
      reflectorMock,
      dsMock,
      redisCacheMock,
    );
  });

  function createMockContext(authHeader?: string, reqAttrs: Record<string, any> = {}) {
    const request = {
      headers: {
        authorization: authHeader,
      },
      ...reqAttrs,
    };
    return {
      switchToHttp: () => ({
        getRequest: () => request,
      }),
      getHandler: () => ({}),
      getClass: () => ({}),
    } as any;
  }

  it('throws UnauthorizedException when Authorization header is missing or malformed', async () => {
    const ctxNoHeader = createMockContext(undefined);
    await expect(guard.canActivate(ctxNoHeader)).rejects.toThrow(UnauthorizedException);

    const ctxBadPrefix = createMockContext('Basic 12345');
    await expect(guard.canActivate(ctxBadPrefix)).rejects.toThrow(UnauthorizedException);
  });

  it('allows access and attaches user when token is valid, active, and cache hits', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
      role: 'cashier',
      drole: 'pos',
    });
    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    redisCacheMock.get.mockResolvedValue('active');

    const result = await guard.canActivate(ctx);
    expect(result).toBe(true);
    expect(ctx.switchToHttp().getRequest().user).toEqual({
      userId: 'u1',
      tenantId: 't1',
      role: 'cashier',
      deviceId: undefined,
      deviceRole: 'pos',
    });
    expect(dsMock.query).not.toHaveBeenCalled();
  });

  it('queries database on cache miss and caches result in Redis', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
    });
    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    redisCacheMock.get.mockResolvedValue(null); // cache miss
    dsMock.query.mockResolvedValue([{ status: 'active' }]);

    const result = await guard.canActivate(ctx);
    expect(result).toBe(true);
    expect(dsMock.query).toHaveBeenCalledWith(
      expect.stringContaining('SELECT status FROM tenants'),
      ['t1'],
    );
    expect(redisCacheMock.set).toHaveBeenCalledWith(
      't:t1:status',
      'active',
      'EX',
      expect.any(Number),
    );
  });

  it('throws TENANT_SUSPENDED (403) with Thai message if tenant is not active', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
    });
    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    redisCacheMock.get.mockResolvedValue('suspended');

    try {
      await guard.canActivate(ctx);
      expect.unreachable('Should have thrown');
    } catch (err: any) {
      expect(err).toBeInstanceOf(HttpException);
      expect(err.getStatus()).toBe(HttpStatus.FORBIDDEN);
      const res = err.getResponse();
      expect(res).toEqual({
        code: 'TENANT_SUSPENDED',
        message: 'ร้านนี้ถูกระงับการใช้งาน',
      });
    }
  });

  it('throws DEVICE_ROLE_FORBIDDEN (403) with Thai message if non-pos device accesses pos endpoint', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
      drole: 'backoffice', // backoffice trying to access pos endpoint
    });
    reflectorMock.getAllAndOverride.mockReturnValue('pos'); // requires pos
    redisCacheMock.get.mockResolvedValue('active');

    try {
      await guard.canActivate(ctx);
      expect.unreachable('Should have thrown');
    } catch (err: any) {
      expect(err).toBeInstanceOf(HttpException);
      expect(err.getStatus()).toBe(HttpStatus.FORBIDDEN);
      const res = err.getResponse();
      expect(res).toEqual({
        code: 'DEVICE_ROLE_FORBIDDEN',
        message: 'เครื่องนี้ขายของไม่ได้',
      });
    }
  });

  it('allows access to pos endpoint if drole is pos', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
      drole: 'pos',
    });
    reflectorMock.getAllAndOverride.mockReturnValue('pos');
    redisCacheMock.get.mockResolvedValue('active');

    const result = await guard.canActivate(ctx);
    expect(result).toBe(true);
  });

  it('allows access to backoffice endpoint if user logged in without device token (drole undefined)', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
      drole: undefined, // web user without device token
    });
    reflectorMock.getAllAndOverride.mockReturnValue('backoffice');
    redisCacheMock.get.mockResolvedValue('active');

    const result = await guard.canActivate(ctx);
    expect(result).toBe(true);
  });

  it('lets database error bubble up on cache miss without converting to 401', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
    });
    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    redisCacheMock.get.mockResolvedValue(null);
    dsMock.query.mockRejectedValue(new Error('Postgres connection timeout'));

    await expect(guard.canActivate(ctx)).rejects.toThrow('Postgres connection timeout');
  });
});
