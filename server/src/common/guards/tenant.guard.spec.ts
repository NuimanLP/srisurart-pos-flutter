import { describe, it, expect, vi, beforeEach } from 'vitest';
import { HttpException, HttpStatus, UnauthorizedException } from '@nestjs/common';
import { TenantGuard } from './tenant.guard.js';
import {
  authorisedTenantId,
  currentTransaction,
  runInTenantScope,
} from '../request-context.js';

describe('TenantGuard', () => {
  let guard: TenantGuard;
  let jwtVerifierMock: any;
  let reflectorMock: any;
  let redisCacheMock: any;
  let dsMock: any;

  /**
   * The guard runs inside the scope `TenantScopeMiddleware` opens for every request (tx.4
   * #153): no tenant, no transaction. `after` runs inside the same scope once the guard has
   * returned, so a test can see what the guard left on it.
   */
  const activate = (ctx: any, after?: () => void) =>
    runInTenantScope(async () => {
      const result = await guard.canActivate(ctx);
      after?.();
      return result;
    });

  beforeEach(() => {
    jwtVerifierMock = {
      verify: vi.fn(),
    };
    reflectorMock = {
      getAllAndOverride: vi.fn(),
    };
    redisCacheMock = {
      get: vi.fn(),
      set: vi.fn(),
    };
    dsMock = {
      query: vi.fn().mockResolvedValue([]),
      createQueryRunner: vi.fn(),
    };

    guard = new TenantGuard(jwtVerifierMock, reflectorMock, redisCacheMock, dsMock);
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
    await expect(activate(ctxNoHeader)).rejects.toThrow(UnauthorizedException);

    const ctxBadPrefix = createMockContext('Basic 12345');
    await expect(activate(ctxBadPrefix)).rejects.toThrow(UnauthorizedException);
  });

  it('allows access and attaches user when token is valid, active, and cache hits', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
      role: 'owner',
      drole: 'pos',
    });
    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    redisCacheMock.get.mockResolvedValue('active');

    const result = await activate(ctx);
    expect(result).toBe(true);
    expect(ctx.switchToHttp().getRequest().user).toEqual({
      userId: 'u1',
      tenantId: 't1',
      role: 'owner',
      deviceId: undefined,
      deviceRole: 'pos',
    });
    // On a cache hit the guard touches the database not at all.
    expect(dsMock.query).not.toHaveBeenCalled();
    expect(dsMock.createQueryRunner).not.toHaveBeenCalled();
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

    const result = await activate(ctx);
    expect(result).toBe(true);
    // A plain pool read with no transaction: `tenants` has no RLS, and nothing else in the
    // request holds a connection yet (tx.4 #153).
    expect(dsMock.query).toHaveBeenCalledWith(
      expect.stringContaining('SELECT status FROM tenants'),
      ['t1'],
    );
    expect(dsMock.createQueryRunner).not.toHaveBeenCalled();
    expect(redisCacheMock.set).toHaveBeenCalledWith(
      't:t1:status',
      'active',
      'EX',
      expect.any(Number),
    );
  });

  it('names the tenant on the request scope, opens no transaction and sets no GUC', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({ aud: 'tenant', sub: 'u1', tid: 't1' });
    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    redisCacheMock.get.mockResolvedValue(null);
    dsMock.query.mockResolvedValue([{ status: 'active' }]);

    let named: string | undefined;
    let open: unknown = 'unset';
    await activate(ctx, () => {
      named = authorisedTenantId();
      open = currentTransaction();
    });

    expect(named).toBe('t1');
    expect(open).toBeNull();
    // `set_config` is `TenantService.runTx`'s job now (ADR-0003 addendum).
    expect(dsMock.query).not.toHaveBeenCalledWith(
      expect.stringContaining('set_config'),
      expect.anything(),
    );
  });

  it('never names a suspended tenant on the scope', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({ aud: 'tenant', sub: 'u1', tid: 't1' });
    reflectorMock.getAllAndOverride.mockReturnValue(undefined);
    redisCacheMock.get.mockResolvedValue('suspended');

    let unnamed: unknown;
    await runInTenantScope(async () => {
      await expect(guard.canActivate(ctx)).rejects.toThrow(HttpException);
      try {
        authorisedTenantId();
      } catch (err) {
        unnamed = err;
      }
    });
    expect(String(unnamed)).toMatch(/No tenant on this request/);
    expect(dsMock.query).not.toHaveBeenCalled();
  });

  // tx.4 (#153) moved the cold-cache status read to the pool. Every way that read can refuse
  // must still leave the scope unnamed, so no `runTx` can open a transaction for the shop.
  describe('cold cache: the pool read fails closed', () => {
    const coldCtx = () => {
      jwtVerifierMock.verify.mockReturnValue({ aud: 'tenant', sub: 'u1', tid: 't1' });
      reflectorMock.getAllAndOverride.mockReturnValue(undefined);
      redisCacheMock.get.mockResolvedValue(null);
      return createMockContext('Bearer valid-token');
    };

    /** Runs the guard in a scope; returns what it threw and why the scope refused a tenant. */
    const refused = async () => {
      const ctx = coldCtx();
      let thrown: any;
      let unnamed: unknown;
      await runInTenantScope(async () => {
        try {
          await guard.canActivate(ctx);
        } catch (err) {
          thrown = err;
        }
        try {
          authorisedTenantId();
        } catch (err) {
          unnamed = err;
        }
      });
      return { thrown, unnamed: String(unnamed) };
    };

    it.each(['suspended', 'archived'])('status %s → 403 TENANT_SUSPENDED, tenant not named', async (s) => {
      dsMock.query.mockResolvedValue([{ status: s }]);
      const { thrown, unnamed } = await refused();
      expect(thrown).toBeInstanceOf(HttpException);
      expect(thrown.getStatus()).toBe(HttpStatus.FORBIDDEN);
      expect(thrown.getResponse().code).toBe('TENANT_SUSPENDED');
      expect(unnamed).toMatch(/No tenant on this request/);
    });

    it('no tenants row → 403 Tenant not found, tenant not named', async () => {
      dsMock.query.mockResolvedValue([]);
      const { thrown, unnamed } = await refused();
      expect(thrown).toBeInstanceOf(HttpException);
      expect(thrown.getStatus()).toBe(HttpStatus.FORBIDDEN);
      expect(thrown.getResponse()).toEqual({ code: 'FORBIDDEN', message: 'Tenant not found' });
      expect(redisCacheMock.set).not.toHaveBeenCalled();
      expect(unnamed).toMatch(/No tenant on this request/);
    });

    it('the pool read rejects → the error propagates, tenant not named', async () => {
      const boom = new Error('connection terminated');
      dsMock.query.mockRejectedValue(boom);
      const { thrown, unnamed } = await refused();
      expect(thrown).toBe(boom);
      expect(unnamed).toMatch(/No tenant on this request/);
    });
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
      await activate(ctx);
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
      await activate(ctx);
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

    const result = await activate(ctx);
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

    const result = await activate(ctx);
    expect(result).toBe(true);
  });

  it('allows pos device to access backoffice endpoint per ADR-0004', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
      drole: 'pos',
    });
    reflectorMock.getAllAndOverride.mockReturnValue('backoffice');
    redisCacheMock.get.mockResolvedValue('active');

    const result = await activate(ctx);
    expect(result).toBe(true);
  });

  it('allows backoffice device to access backoffice endpoint', async () => {
    const ctx = createMockContext('Bearer valid-token');
    jwtVerifierMock.verify.mockReturnValue({
      aud: 'tenant',
      sub: 'u1',
      tid: 't1',
      drole: 'backoffice',
    });
    reflectorMock.getAllAndOverride.mockReturnValue('backoffice');
    redisCacheMock.get.mockResolvedValue('active');

    const result = await activate(ctx);
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

    await expect(activate(ctx)).rejects.toThrow('Postgres connection timeout');
  });
});
