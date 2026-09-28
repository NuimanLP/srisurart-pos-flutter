import { describe, it, expect, beforeEach, vi } from 'vitest';
import { BadRequestException, ConflictException, ForbiddenException, UnauthorizedException } from '@nestjs/common';
import { signJwt } from '../src/common/jwt.js';
import { hashPassword } from '../src/common/password.js';
import { PlatformAuthGuard, platformAdminCacheKey } from '../src/platform/platform-auth.guard.js';
import { PlatformAuthService } from '../src/platform/platform-auth.service.js';
import { PlatformTenantsService, SEED_CATEGORIES } from '../src/platform/platform-tenants.service.js';
import { TenantImportService } from '../src/platform/tenant-import.service.js';
import { AuditService } from '../src/platform/audit.service.js';

const mockConfig = {
  port: 3000,
  instanceId: 'test',
  logLevel: 'info',
  databaseUrl: 'postgres://localhost:5432/test',
  adminDatabaseUrl: 'postgres://localhost:5432/test',
  dbPoolSize: 5,
  redisCacheUrl: 'redis://localhost:6379',
  redisQueueUrl: 'redis://localhost:6379',
  redisCommandTimeoutMs: 200,
  jwtPlatformSecret: 'test-platform-secret',
};

describe('Platform Realm & Tenant Provisioning (#5, #123)', () => {
  let auditService: AuditService;
  let mockAdminDs: any;
  let mockRedisCache: any;
  let tenantCache: { invalidate: ReturnType<typeof vi.fn> };
  let mockImportQueue: { add: ReturnType<typeof vi.fn> };
  let mockRateLimit: {
    consumeAttempt: ReturnType<typeof vi.fn>;
    clearKey: ReturnType<typeof vi.fn>;
    refundAttempt: ReturnType<typeof vi.fn>;
  };

  beforeEach(() => {
    mockAdminDs = {
      query: vi.fn(),
      transaction: vi.fn(async (cb) => cb(mockAdminDs)),
    };
    mockRedisCache = {
      get: vi.fn().mockResolvedValue(null),
      setex: vi.fn().mockResolvedValue('OK'),
      del: vi.fn().mockResolvedValue(1),
    };
    // Always-allow stand-in for RateLimitService (#443 PR4) — the throttle itself has its own
    // focused unit tests in platform-auth.service.spec.ts.
    mockRateLimit = {
      consumeAttempt: vi.fn().mockResolvedValue({ allowed: true }),
      clearKey: vi.fn().mockResolvedValue(undefined),
      refundAttempt: vi.fn().mockResolvedValue(undefined),
    };
    auditService = new AuditService();
    tenantCache = { invalidate: vi.fn() };
    // #239: TenantImportService.importSnapshot() (pre-flight + write, no job) is exercised
    // here — the queue is never touched by it, so the mock only needs to exist.
    mockImportQueue = { add: vi.fn() };
  });

  describe('AuditService', () => {
    it('executes the insert on the runner it is given', async () => {
      const managerMock = { query: vi.fn().mockResolvedValue([]) };
      await auditService.log(managerMock as any, {
        tenantId: 't1',
        platformAdminId: 'adm1',
        action: 'test.action',
        ip: '192.168.1.1',
      });

      expect(managerMock.query).toHaveBeenCalledWith(
        expect.stringContaining('INSERT INTO audit_log'),
        expect.arrayContaining(['t1', 'adm1', null, null, 'test.action', null, null, null, null, '192.168.1.1']),
      );
      expect(mockAdminDs.query).not.toHaveBeenCalled();
    });

    it('stores null for a raw proxy chain (controllers resolve it with clientIp, #132)', async () => {
      const managerMock = { query: vi.fn().mockResolvedValue([]) };
      await auditService.log(managerMock as any, {
        tenantId: 't1',
        platformAdminId: 'adm1',
        action: 'test.action',
        ip: '203.0.113.195, 70.41.3.18',
      });

      const params = managerMock.query.mock.calls[0][1] as unknown[];
      expect(params[9]).toBeNull();
    });

    it('drops an IPv6 zone id that Postgres inet would reject', async () => {
      const managerMock = { query: vi.fn().mockResolvedValue([]) };
      await auditService.log(managerMock as any, {
        tenantId: 't1',
        platformAdminId: 'adm1',
        action: 'test.action',
        ip: 'fe80::1%eth0',
      });

      const params = managerMock.query.mock.calls[0][1] as unknown[];
      expect(params[9]).toBeNull();
    });
  });

  describe('PlatformAuthGuard', () => {
    let guard: PlatformAuthGuard;

    beforeEach(() => {
      guard = new PlatformAuthGuard(mockConfig, mockAdminDs, mockRedisCache);
    });

    it('rejects missing Authorization header', async () => {
      const context = {
        switchToHttp: () => ({
          getRequest: () => ({ headers: {}, ip: '127.0.0.1' }),
        }),
      } as any;

      await expect(guard.canActivate(context)).rejects.toThrow(UnauthorizedException);
    });

    it('rejects tenant JWT token with aud != platform', async () => {
      const tenantToken = signJwt(
        { aud: 'tenant', tid: 't1', sub: 'u1' },
        mockConfig.jwtPlatformSecret,
      );
      const context = {
        switchToHttp: () => ({
          getRequest: () => ({
            headers: { authorization: `Bearer ${tenantToken}` },
            ip: '127.0.0.1',
          }),
        }),
      } as any;

      await expect(guard.canActivate(context)).rejects.toThrow(ForbiddenException);
    });

    it('allows valid platform JWT when admin exists in Redis cache', async () => {
      mockRedisCache.get.mockResolvedValueOnce('1');
      const platformToken = signJwt(
        { aud: 'platform', sub: 'adm1', username: 'admin' },
        mockConfig.jwtPlatformSecret,
      );
      const req = {
        headers: { authorization: `Bearer ${platformToken}` },
        ip: '127.0.0.1',
      } as any;
      const context = {
        switchToHttp: () => ({ getRequest: () => req }),
      } as any;

      expect(await guard.canActivate(context)).toBe(true);
      expect(req.platformAdmin).toEqual({ id: 'adm1', username: 'admin' });
      expect(mockAdminDs.query).not.toHaveBeenCalled();
    });

    it('rejects with ForbiddenException when client IP is outside allowlist', async () => {
      const platformToken = signJwt(
        { aud: 'platform', sub: 'adm1', username: 'admin' },
        mockConfig.jwtPlatformSecret,
      );
      const req = {
        headers: {
          authorization: `Bearer ${platformToken}`,
          'x-forwarded-for': '203.0.113.195',
        },
      } as any;
      const context = {
        switchToHttp: () => ({ getRequest: () => req }),
      } as any;

      await expect(guard.canActivate(context)).rejects.toThrow(ForbiddenException);
    });

    it('allows request from loopback IP', async () => {
      mockRedisCache.get.mockResolvedValueOnce('1');
      const platformToken = signJwt(
        { aud: 'platform', sub: 'adm1', username: 'admin' },
        mockConfig.jwtPlatformSecret,
      );
      const req = {
        ip: '127.0.0.1',
        headers: { authorization: `Bearer ${platformToken}` },
      } as any;
      const context = {
        switchToHttp: () => ({ getRequest: () => req }),
      } as any;

      expect(await guard.canActivate(context)).toBe(true);
    });

    it('allows request from configured admin IP', async () => {
      mockRedisCache.get.mockResolvedValueOnce('1');
      const platformToken = signJwt(
        { aud: 'platform', sub: 'adm1', username: 'admin' },
        mockConfig.jwtPlatformSecret,
      );
      const guardWithAdminIp = new PlatformAuthGuard(
        { ...mockConfig, platformAdminIps: ['198.51.100.50'] },
        mockAdminDs,
        mockRedisCache,
      );
      const req = {
        headers: {
          authorization: `Bearer ${platformToken}`,
          'x-forwarded-for': '198.51.100.50',
        },
      } as any;
      const context = {
        switchToHttp: () => ({ getRequest: () => req }),
      } as any;

      expect(await guardWithAdminIp.canActivate(context)).toBe(true);
    });

    it('verifies against DB and populates Redis cache (60s TTL) when Redis misses', async () => {
      mockRedisCache.get.mockResolvedValueOnce(null);
      mockAdminDs.query.mockResolvedValueOnce([{ id: 'adm1' }]);

      const platformToken = signJwt(
        { aud: 'platform', sub: 'adm1', username: 'admin' },
        mockConfig.jwtPlatformSecret,
      );
      const req = {
        headers: { authorization: `Bearer ${platformToken}` },
        ip: '127.0.0.1',
      } as any;
      const context = {
        switchToHttp: () => ({ getRequest: () => req }),
      } as any;

      expect(await guard.canActivate(context)).toBe(true);
      expect(mockRedisCache.setex).toHaveBeenCalledWith(platformAdminCacheKey('adm1'), 60, '1');
    });

    it('rejects with UnauthorizedException when admin is cached as inactive or deleted (0)', async () => {
      mockRedisCache.get.mockResolvedValueOnce('0');
      const platformToken = signJwt(
        { aud: 'platform', sub: 'adm1', username: 'admin' },
        mockConfig.jwtPlatformSecret,
      );
      const req = {
        headers: { authorization: `Bearer ${platformToken}` },
        ip: '127.0.0.1',
      } as any;
      const context = {
        switchToHttp: () => ({ getRequest: () => req }),
      } as any;

      await expect(guard.canActivate(context)).rejects.toThrow(UnauthorizedException);
    });

    it('rejects with UnauthorizedException and caches 0 when admin not in DB', async () => {
      mockRedisCache.get.mockResolvedValueOnce(null);
      mockAdminDs.query.mockResolvedValueOnce([]);

      const platformToken = signJwt(
        { aud: 'platform', sub: 'adm1', username: 'admin' },
        mockConfig.jwtPlatformSecret,
      );
      const req = {
        headers: { authorization: `Bearer ${platformToken}` },
        ip: '127.0.0.1',
      } as any;
      const context = {
        switchToHttp: () => ({ getRequest: () => req }),
      } as any;

      await expect(guard.canActivate(context)).rejects.toThrow(UnauthorizedException);
      expect(mockRedisCache.setex).toHaveBeenCalledWith(platformAdminCacheKey('adm1'), 60, '0');
    });

    it('refuses a token older than password_changed_at and caches the cutoff (#443)', async () => {
      const ctxFor = (iat?: number) => {
        const token = signJwt(
          { aud: 'platform', sub: 'adm1', username: 'admin', ...(iat ? { iat } : {}) },
          mockConfig.jwtPlatformSecret,
        );
        const req = { headers: { authorization: `Bearer ${token}` }, ip: '127.0.0.1' } as any;
        return { switchToHttp: () => ({ getRequest: () => req }) } as any;
      };
      mockRedisCache.get.mockResolvedValueOnce(null);
      mockAdminDs.query.mockResolvedValueOnce([{ cutoff: '1000' }]);
      await expect(guard.canActivate(ctxFor(999))).rejects.toThrow(UnauthorizedException);
      expect(mockRedisCache.setex).toHaveBeenCalledWith(platformAdminCacheKey('adm1'), 60, '1000');

      mockRedisCache.get.mockResolvedValueOnce('1000');
      expect(await guard.canActivate(ctxFor(1000))).toBe(true); // same second survives

      mockRedisCache.get.mockResolvedValueOnce('1000');
      await expect(guard.canActivate(ctxFor())).rejects.toThrow(UnauthorizedException); // no iat
    });

    it('never reads the pre-#443-fix-round `:exists` key — a value cached there is a miss, not a hit (#443)', async () => {
      const platformToken = signJwt(
        { aud: 'platform', sub: 'adm1', username: 'admin' }, // no iat, like a pre-deploy token
        mockConfig.jwtPlatformSecret,
      );
      const req = { headers: { authorization: `Bearer ${platformToken}` }, ip: '127.0.0.1' } as any;
      const context = { switchToHttp: () => ({ getRequest: () => req }) } as any;

      // mockRedisCache.get always returns null here (default from beforeEach) regardless of
      // key, standing in for a real Redis where only the OLD key ('pa:adm1:exists') has a
      // value and the new one ('pa:adm1:cutoff') is unset — the guard must ask Redis for the
      // new key, not the old one, or a stale pre-deploy '1' would let this no-iat token through.
      mockAdminDs.query.mockResolvedValueOnce([{ cutoff: '1000' }]);
      expect(mockRedisCache.get).not.toHaveBeenCalled();
      await expect(guard.canActivate(context)).rejects.toThrow(UnauthorizedException);
      expect(mockRedisCache.get).toHaveBeenCalledWith(platformAdminCacheKey('adm1'));
      expect(mockRedisCache.get).not.toHaveBeenCalledWith('pa:adm1:exists');
    });
  });

  describe('PlatformAuthService', () => {
    it('authenticates admin, returns token, and writes audit log', async () => {
      const passHash = await hashPassword('secret123');
      mockAdminDs.query.mockResolvedValueOnce([
        { id: 'adm1', username: 'superadmin', password_hash: passHash, display_name: 'Admin', is_active: true },
      ]);

      const authService = new PlatformAuthService(mockAdminDs, mockConfig, auditService, mockRateLimit as any);
      const result = await authService.login('superadmin', 'secret123', '127.0.0.1');

      expect(result.token).toBeDefined();
      expect(result.admin.username).toBe('superadmin');
      expect(mockAdminDs.query).toHaveBeenCalledWith(
        expect.stringContaining('INSERT INTO audit_log'),
        expect.arrayContaining(['00000000-0000-0000-0000-000000000000', 'adm1', null, null, 'platform.auth.login']),
      );
    }, 15000);

    it('rejects invalid password', async () => {
      const passHash = await hashPassword('secret123');
      mockAdminDs.query.mockResolvedValueOnce([
        { id: 'adm1', username: 'superadmin', password_hash: passHash, display_name: 'Admin', is_active: true },
      ]);

      const authService = new PlatformAuthService(mockAdminDs, mockConfig, auditService, mockRateLimit as any);
      await expect(authService.login('superadmin', 'wrongpass')).rejects.toThrow(UnauthorizedException);
    }, 15000);
  });

  describe('PlatformTenantsService', () => {
    it('creates tenant in 1 transaction including audit log with 5 seed categories and initial POS device', async () => {
      mockAdminDs.query
        .mockResolvedValueOnce([{ id: 'tenant-123' }]) // INSERT INTO tenants
        .mockResolvedValueOnce([{ temp_password_expires_at: new Date() }]) // INSERT INTO users
        .mockResolvedValueOnce([]) // INSERT INTO settings
        .mockResolvedValue([]) // INSERT INTO categories (5x)
        .mockResolvedValueOnce([]) // INSERT INTO devices
        .mockResolvedValueOnce([]); // INSERT INTO audit_log

      const service = new PlatformTenantsService(mockAdminDs, mockRedisCache, auditService);
      const result = await service.createTenant(
        {
          code: 'shop01',
          shopName: 'ร้านอะไหล่ 1',
          ownerUsername: 'owner1',
          ownerDisplayName: 'เจ้าของร้าน',
        },
        'adm1',
      );

      expect(result.tenantId).toBe('tenant-123');
      expect(result.enrolCode).toBeDefined();
      // #443 PR3: a server-generated temporary password, returned once, never sent to SQL raw.
      expect(result.tempPassword).toMatch(/^[A-HJ-NP-Za-km-z2-9]{16}$/);
      expect(result.tempPasswordExpiresAt).toBeDefined();
      const everyParam = JSON.stringify(mockAdminDs.query.mock.calls.map((c: any) => c[1]));
      expect(everyParam).not.toContain(result.tempPassword);
      const userInsert = mockAdminDs.query.mock.calls.find((c: any) =>
        c[0].includes('INSERT INTO users'),
      );
      expect(userInsert[0]).toContain('must_change_password');
      expect(userInsert[1][2]).toMatch(/^\$argon2id\$/);
      expect(mockAdminDs.transaction).toHaveBeenCalled();

      // Verify seed categories were inserted
      const categoryCalls = mockAdminDs.query.mock.calls.filter((c: any) =>
        c[0].includes('INSERT INTO categories'),
      );
      expect(categoryCalls).toHaveLength(5);
      expect(categoryCalls.map((c: any) => c[1][1])).toEqual([...SEED_CATEGORIES]);

      // Verify audit log was executed inside transaction on manager
      const auditCalls = mockAdminDs.query.mock.calls.filter((c: any) =>
        c[0].includes('INSERT INTO audit_log'),
      );
      expect(auditCalls).toHaveLength(1);
      expect(auditCalls[0][1]).toEqual(
        expect.arrayContaining(['tenant-123', 'adm1', null, null, 'platform.tenant.create']),
      );
    });

    // #443 PR3: the admin never chooses the owner's password. A caller still on the old
    // contract is refused before argon2 and before any transaction, so nothing is half-made.
    it.each([
      ['a strong password', 'pass123456789'],
      ['a short password', '1234'],
      ['an empty password', ''],
      ['a non-string password', 1234],
    ])('refuses a body carrying ownerPassword (%s) with 400 before any query', async (_label, ownerPassword) => {
      const service = new PlatformTenantsService(mockAdminDs, mockRedisCache, auditService);

      await expect(
        service.createTenant(
          {
            code: 'shop-legacy',
            shopName: 'ร้านอะไหล่สัญญาเก่า',
            ownerUsername: 'owner-legacy',
            ownerPassword,
            ownerDisplayName: 'เจ้าของร้าน',
          } as any,
          'adm1',
        ),
      ).rejects.toMatchObject({ response: { code: 'OWNER_PASSWORD_NOT_ACCEPTED' } });

      expect(mockAdminDs.transaction).not.toHaveBeenCalled();
      expect(mockAdminDs.query).not.toHaveBeenCalled();
    });

    it('rolls back and propagates error if audit logging fails during tenant creation', async () => {
      mockAdminDs.query
        .mockResolvedValueOnce([{ id: 'tenant-123' }]) // INSERT INTO tenants
        .mockResolvedValueOnce([{ temp_password_expires_at: new Date() }]) // INSERT INTO users
        .mockResolvedValueOnce([]) // INSERT INTO settings
        .mockResolvedValue([]) // INSERT INTO categories
        .mockResolvedValueOnce([]); // INSERT INTO devices

      // Simulate FK violation or DB error during audit logging inside transaction
      vi.spyOn(auditService, 'log').mockRejectedValueOnce(new Error('FK constraint violation on platform_admin_id'));

      const service = new PlatformTenantsService(mockAdminDs, mockRedisCache, auditService);
      await expect(
        service.createTenant(
          {
            code: 'shop02',
            shopName: 'ร้านอะไหล่ 2',
            ownerUsername: 'owner2',
            ownerDisplayName: 'เจ้าของร้าน 2',
          },
          'deleted-adm',
        ),
      ).rejects.toThrow('FK constraint violation');
    });

    it('updates tenant status inside transaction and immediately purges Redis cache key', async () => {
      const tenantId = '11111111-1111-1111-1111-111111111111';
      mockAdminDs.query.mockResolvedValueOnce([{ id: tenantId, status: 'suspended' }]);

      const service = new PlatformTenantsService(mockAdminDs, mockRedisCache, auditService);
      const res = await service.updateStatus(tenantId, 'suspended', 'adm1');

      expect(res).toEqual({ tenantId, status: 'suspended' });
      expect(mockAdminDs.transaction).toHaveBeenCalled();
      expect(mockRedisCache.del).toHaveBeenCalledWith(`t:${tenantId}:status`);
    });

    it('does not purge Redis status cache if updateStatus transaction fails', async () => {
      const tenantId = '11111111-1111-1111-1111-111111111111';
      mockAdminDs.transaction.mockRejectedValueOnce(new Error('Transaction rolled back'));

      const service = new PlatformTenantsService(mockAdminDs, mockRedisCache, auditService);
      await expect(service.updateStatus(tenantId, 'suspended', 'adm1')).rejects.toThrow('Transaction rolled back');
      expect(mockRedisCache.del).not.toHaveBeenCalled();
    });

    it('rejects a non-UUID tenant id with 400 INVALID_TENANT_ID before any query', async () => {
      const service = new PlatformTenantsService(mockAdminDs, mockRedisCache, auditService);
      await expect(service.updateStatus('t1', 'suspended', 'adm1')).rejects.toMatchObject({
        response: { code: 'INVALID_TENANT_ID' },
      });
      expect(mockAdminDs.transaction).not.toHaveBeenCalled();
    });

    it('listTenants returns list even if audit logging fails (AC4)', async () => {
      mockAdminDs.query.mockResolvedValueOnce([
        { id: 't1', code: 'shop1', shop_name: 'Shop 1' },
      ]);
      vi.spyOn(auditService, 'log').mockRejectedValueOnce(new Error('Audit DB write error'));

      const service = new PlatformTenantsService(mockAdminDs, mockRedisCache, auditService);
      const res = await service.listTenants('adm1');

      expect(res).toEqual([{ id: 't1', code: 'shop1', shop_name: 'Shop 1' }]);
    });
  });

  describe('TenantImportService', () => {
    it('rejects import if tenant already has sales or transactional data', async () => {
      mockAdminDs.query.mockResolvedValueOnce([{ n: 1 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      await expect(
        importService.importSnapshot(
          't1',
          { __meta: { version: 2 }, sa_products: [] },
          'adm1',
        ),
      ).rejects.toThrow(ConflictException);
      expect(tenantCache.invalidate).not.toHaveBeenCalled();
    });

    it('pre-flight scan rejects negative product stock', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      await expect(
        importService.importSnapshot(
          't1',
          {
            __meta: { version: 2 },
            sa_products: [{ id: 'p1', stock: -5, name: 'Negative Stock Product' }],
          },
          'adm1',
        ),
      ).rejects.toThrow(BadRequestException);
    });

    it('pre-flight scan rejects part numbers that differ only by case', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      await expect(
        importService.importSnapshot(
          't1',
          {
            __meta: { version: 2 },
            sa_products: [
              { id: 'p1', partNo: 'BP-1', stock: 1 },
              { id: 'p2', partNo: 'bp-1', stock: 1 },
            ],
          },
          'adm1',
        ),
      ).rejects.toThrow("products 'p1', 'p2' share part number 'bp-1'");
      expect(mockAdminDs.transaction).not.toHaveBeenCalled();
    });

    it('imports snapshot cleanly and executes audit log inside transaction', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      const res = await importService.importSnapshot(
        't1',
        {
          __meta: { version: 2 },
          sa_products: [{ id: 'p1', name: 'Brake Pad', stock: 10, price: 500 }],
          sa_categories: [{ name: 'เบรก', position: 0 }],
          sa_customers: [{ id: 'c1', name: 'Customer A' }],
        },
        'adm1',
      );

      expect(res.status).toBe('success');
      expect(mockAdminDs.transaction).toHaveBeenCalled();
      // Audit log was called on transaction manager
      const auditCalls = mockAdminDs.query.mock.calls.filter((c: any) =>
        c[0].includes('INSERT INTO audit_log'),
      );
      expect(auditCalls.length).toBeGreaterThanOrEqual(1);
      // Cache invalidated only after transaction commits
      expect(tenantCache.invalidate).toHaveBeenCalledWith('t1', 'products');
    });

    it('stamps imported products with clock_timestamp() and ignores historic updatedAt (#217)', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      await importService.importSnapshot(
        't1',
        {
          __meta: { version: 2 },
          sa_products: [
            {
              id: 'p1',
              name: 'Brake Pad',
              stock: 10,
              price: 500,
              updatedAt: '2020-01-01T00:00:00.000Z',
            },
          ],
        },
        'adm1',
      );

      const productInserts = mockAdminDs.query.mock.calls.filter((c: any) =>
        c[0].includes('INSERT INTO products'),
      );
      expect(productInserts).toHaveLength(1);
      const [sql, params] = productInserts[0];
      expect(sql).toContain('clock_timestamp()');
      expect(params).not.toContain('2020-01-01T00:00:00.000Z');
      expect(params).not.toContain(new Date('2020-01-01T00:00:00.000Z'));
    });

    // #185: the file's real store keys. The first version read `sa_purchase_orders`,
    // `sa_shifts`, `sa_parked_sales` and `{ name }` categories, so a real backup lost every
    // PO, shift, drawer entry and parked bill and renamed its categories `Cat-<n>`.
    it('reads the store keys exportSnapshot() writes (#185)', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      await importService.importSnapshot(
        't1',
        {
          __meta: { version: 2 },
          sa_categories: ['เบรก', 'ช่วงล่าง'],
          sa_products: [
            { id: 'p1', partNo: 'BP-1', stock: 1, zone: 'Electrical' },
            { id: 'p2', partNo: 'BP-2', stock: 1, category: 'ยาง' },
          ],
          sa_sales: [{ id: 's1', receiptNo: 'RC1', total: 85, items: [{ productId: 'p1', qty: 1, price: 85, cost: 45 }] }],
          sa_pos: [{ id: 'po1', poNo: 'PO1', supplier: 'x', status: 'received', items: [{ partNo: 'BP-1', name: 'n', qty: 2, cost: 40 }] }],
          sa_cash_drawer: { date: '2026-08-28', startingCash: 1000, openedAt: '2026-08-28T01:00:00.000Z', closedAt: null, entries: [{ id: 'de1', type: 'out', amount: 50, createdAt: '2026-08-28T02:00:00.000Z' }] },
          sa_shift_history: [
            { date: '2026-08-27', startingCash: 1000, openedAt: '2026-08-27T01:00:00.000Z', closedAt: '2026-08-27T11:00:00.000Z', physicalCash: 5000, entries: [] },
            { date: '2026-08-27', startingCash: 500, openedAt: '2026-08-27T00:00:00.000Z', autoArchived: true, entries: [] },
          ],
          sa_parked: [{ id: 'pk1', parkedAt: '2026-08-28T03:00:00.000Z', items: [], discount: 0 }],
        },
        'adm1',
      );

      const inserts = (table: string) =>
        mockAdminDs.query.mock.calls.filter((c: any) => c[0].includes(`INSERT INTO ${table} `)).map((c: any) => c[1]);
      expect(inserts('categories').map((p: any) => p[1])).toEqual(['เบรก', 'ช่วงล่าง', 'ไฟฟ้า', 'ยาง']);
      expect(inserts('products').map((p: any) => p[5])).toEqual(['ไฟฟ้า', 'ยาง']);
      expect(inserts('sale_items')[0][9]).toBe(45);
      expect(inserts('purchase_orders')).toHaveLength(1);
      expect(inserts('po_items')).toHaveLength(1);
      // [id, auto_archived, archived-now]. No imported shift is active: an active drawer with
      // no device could never be closed (review of #244). The file's open drawer is archived
      // the way openShift archives yesterday's.
      expect(inserts('shifts').map((p: any) => [p[1], p[7], p[8]])).toEqual([
        ['sh_2026-08-28_1', true, true],
        ['sh_2026-08-27_1', false, false],
        ['sh_2026-08-27_2', true, false],
      ]);
      const shiftSql = mockAdminDs.query.mock.calls.find((c: any) => c[0].includes('INSERT INTO shifts '))[0];
      expect(shiftSql).toMatch(/\$7, FALSE,/);
      // The pulled tables are re-stamped as the last statements before COMMIT.
      const sqls = mockAdminDs.query.mock.calls.map((c: any) => c[0] as string);
      const tail = sqls.slice(-3);
      expect(tail.map((s: string) => s.match(/UPDATE (\w+) SET updated_at = clock_timestamp\(\)/)?.[1])).toEqual(['products', 'customers', 'mechanics']);
      expect(inserts('drawer_entries').map((p: any) => p[2])).toEqual(['sh_2026-08-28_1']);
      expect(inserts('parked_sales').map((p: any) => p[1])).toEqual(['pk1']);
    });

    // #238: history naming hard-deleted rows becomes soft-deleted, marked tombstones.
    it('writes one soft-deleted, marked tombstone per missing reference and audits the counts (#238)', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      const res = await importService.importSnapshot(
        't1',
        {
          __meta: { version: 2 },
          sa_movements: [{ id: 'mv1', productId: 'p-gone', partNo: 'BP-9', name: 'Brake Pad', delta: 1, type: 'adjustment-in', stockAfter: 1 }],
          sa_sales: [{ id: 's1', receiptNo: 'RC1', total: 0, customerId: 'c-gone', customerName: 'Test Customer', mechanicId: 'm-gone', mechanicName: 'Test Mechanic', items: [] }],
        },
        'adm1',
      );

      expect(res.tombstones).toEqual({ products: 1, customers: 1, mechanics: 1 });
      expect(res.droppedSuppliers).toBe(0);
      const insert = (table: string) =>
        mockAdminDs.query.mock.calls.filter((c: any) => c[0].includes(`INSERT INTO ${table} `));
      const [productSql, productParams] = insert('products')[0];
      expect(productSql).toContain('deleted_at');
      expect(productSql).not.toContain('ON CONFLICT');
      expect(productParams).toEqual(expect.arrayContaining(['p-gone', 'BP-9', 'Brake Pad', 'import-tombstone']));
      expect(insert('customers')[0][1]).toEqual(['t1', 'c-gone', 'import-tombstone:c-gone', 'Test Customer']);
      expect(insert('mechanics')[0][1]).toEqual(['t1', 'm-gone', 'import-tombstone:m-gone', 'Test Mechanic']);
      const audit = mockAdminDs.query.mock.calls.find((c: any) => c[0].includes('INSERT INTO audit_log'));
      expect(audit[1]).toContain(JSON.stringify({ tombstones: { products: 1, customers: 1, mechanics: 1 }, droppedSuppliers: 0 }));
    });

    it('refuses in pre-flight a reference no tombstone can be named for, listing the ids (#238)', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      await expect(
        importService.importSnapshot(
          't1',
          { __meta: { version: 2 }, sa_credit_payments: [{ id: 'cp1', receiptNo: 'CP1', mechanicId: 'm-nameless', amount: 100 }] },
          'adm1',
        ),
      ).rejects.toThrow('mechanics:m-nameless');
      expect(mockAdminDs.transaction).not.toHaveBeenCalled();
    });

    // #252 review: a row missing its own required reference id entirely is refused in
    // pre-flight, listing the row id — never `String(undefined)` reaching an INSERT.
    it('refuses in pre-flight a row with no required reference id at all', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      await expect(
        importService.importSnapshot(
          't1',
          { __meta: { version: 2 }, sa_movements: [{ id: 'mv-bad', name: 'x', delta: 1, type: 'adjustment-in', stockAfter: 1 }] },
          'adm1',
        ),
      ).rejects.toThrow('movements:mv-bad');
      expect(mockAdminDs.transaction).not.toHaveBeenCalled();
    });

    // #252 (owner, 2026-09-15): a supplier row for a product that is gone and unreferenced
    // elsewhere is dropped rather than forcing the whole import through the 400 refusal.
    it('drops an orphaned supplier row instead of refusing the import, and counts it', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      const res = await importService.importSnapshot(
        't1',
        {
          __meta: { version: 2 },
          sa_products: [{ id: 'p-live', partNo: 'BP-1', stock: 1 }],
          sa_suppliers: [{ id: 'sp-orphan', productId: 'p-orphan', name: 'Test Supplier', unitCost: 10 }],
        },
        'adm1',
      );

      expect(res.droppedSuppliers).toBe(1);
      expect(res.tombstones).toEqual({ products: 0, customers: 0, mechanics: 0 });
      const insert = (table: string) =>
        mockAdminDs.query.mock.calls.filter((c: any) => c[0].includes(`INSERT INTO ${table} `));
      expect(insert('suppliers')).toHaveLength(0);
      const audit = mockAdminDs.query.mock.calls.find((c: any) => c[0].includes('INSERT INTO audit_log'));
      expect(audit[1]).toContain(JSON.stringify({ tombstones: { products: 0, customers: 0, mechanics: 0 }, droppedSuppliers: 1 }));
    });

    it('rolls back and does not invalidate cache if audit log fails during import', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);
      vi.spyOn(auditService, 'log').mockRejectedValueOnce(new Error('Audit write failed'));

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      await expect(
        importService.importSnapshot(
          't1',
          {
            __meta: { version: 2 },
            sa_products: [{ id: 'p1', name: 'Brake Pad', stock: 10, price: 500 }],
          },
          'adm1',
        ),
      ).rejects.toThrow('Audit write failed');

      expect(tenantCache.invalidate).not.toHaveBeenCalled();
    });

    // #239 review issue 3: `round2()` used to turn a present-but-unparseable money value
    // into a silent 0, with no pre-flight check on any of ~28 money fields. `planClampViolations`
    // now refuses it before the write ever starts (`snapshot-preflight.spec.ts` covers the
    // pure scan directly; this proves it is actually wired into `preflight()`/`importSnapshot`).
    it('pre-flight scan rejects a sale total that does not parse as a number (#239 item 3)', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService, tenantCache as any, mockImportQueue as any);
      await expect(
        importService.importSnapshot(
          't1',
          {
            __meta: { version: 2 },
            sa_sales: [{ id: 's1', total: 'corrupt', items: [] }],
          },
          'adm1',
        ),
      ).rejects.toThrow(BadRequestException);
      expect(mockAdminDs.transaction).not.toHaveBeenCalled();
    });
  });
});
