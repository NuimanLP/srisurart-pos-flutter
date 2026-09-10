import { describe, it, expect, beforeEach, vi } from 'vitest';
import { BadRequestException, ConflictException, ForbiddenException, UnauthorizedException } from '@nestjs/common';
import { signJwt } from '../src/common/jwt.js';
import { hashPassword } from '../src/common/password.js';
import { PlatformAuthGuard } from '../src/platform/platform-auth.guard.js';
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
  jwtPlatformSecret: 'test-platform-secret',
  jwtTenantSecret: 'test-tenant-secret',
};

describe('Platform Realm & Tenant Provisioning (#5)', () => {
  let auditService: AuditService;
  let mockAdminDs: any;
  let mockRedisCache: any;

  beforeEach(() => {
    mockAdminDs = {
      query: vi.fn(),
      transaction: vi.fn(async (cb) => cb(mockAdminDs)),
    };
    mockRedisCache = {
      get: vi.fn(),
      setex: vi.fn(),
      del: vi.fn(),
    };
    auditService = new AuditService(mockAdminDs);
  });

  describe('PlatformAuthGuard', () => {
    const guard = new PlatformAuthGuard(mockConfig);

    it('rejects missing Authorization header', () => {
      const context = {
        switchToHttp: () => ({
          getRequest: () => ({ headers: {} }),
        }),
      } as any;

      expect(() => guard.canActivate(context)).toThrow(UnauthorizedException);
    });

    it('rejects tenant JWT token with aud != platform', () => {
      const tenantToken = signJwt(
        { aud: 'tenant', tid: 't1', sub: 'u1' },
        mockConfig.jwtPlatformSecret,
      );
      const context = {
        switchToHttp: () => ({
          getRequest: () => ({
            headers: { authorization: `Bearer ${tenantToken}` },
          }),
        }),
      } as any;

      expect(() => guard.canActivate(context)).toThrow(ForbiddenException);
    });

    it('allows valid platform JWT with aud == platform', () => {
      const platformToken = signJwt(
        { aud: 'platform', sub: 'adm1', username: 'admin' },
        mockConfig.jwtPlatformSecret,
      );
      const req = {
        headers: { authorization: `Bearer ${platformToken}` },
      } as any;
      const context = {
        switchToHttp: () => ({ getRequest: () => req }),
      } as any;

      expect(guard.canActivate(context)).toBe(true);
      expect(req.platformAdmin).toEqual({ id: 'adm1', username: 'admin' });
    });
  });

  describe('PlatformAuthService', () => {
    it('authenticates admin, returns token, and writes audit log', async () => {
      const passHash = hashPassword('secret123');
      mockAdminDs.query.mockResolvedValueOnce([
        { id: 'adm1', username: 'superadmin', password_hash: passHash, display_name: 'Admin', is_active: true },
      ]);

      const authService = new PlatformAuthService(mockAdminDs, mockConfig, auditService);
      const result = await authService.login('superadmin', 'secret123', '127.0.0.1');

      expect(result.token).toBeDefined();
      expect(result.admin.username).toBe('superadmin');
      expect(mockAdminDs.query).toHaveBeenCalledWith(
        expect.stringContaining('INSERT INTO audit_log'),
        expect.arrayContaining(['00000000-0000-0000-0000-000000000000', 'adm1', null, null, 'platform.auth.login']),
      );
    });

    it('rejects invalid password', async () => {
      const passHash = hashPassword('secret123');
      mockAdminDs.query.mockResolvedValueOnce([
        { id: 'adm1', username: 'superadmin', password_hash: passHash, display_name: 'Admin', is_active: true },
      ]);

      const authService = new PlatformAuthService(mockAdminDs, mockConfig, auditService);
      await expect(authService.login('superadmin', 'wrongpass')).rejects.toThrow(UnauthorizedException);
    });
  });

  describe('PlatformTenantsService', () => {
    it('creates tenant in 1 transaction with 5 seed categories and initial POS device', async () => {
      mockAdminDs.query
        .mockResolvedValueOnce([{ id: 'tenant-123' }]) // INSERT INTO tenants
        .mockResolvedValueOnce([]) // INSERT INTO users
        .mockResolvedValueOnce([]) // INSERT INTO settings
        .mockResolvedValue([]) // INSERT INTO categories (5x)
        .mockResolvedValueOnce([]); // INSERT INTO devices

      const service = new PlatformTenantsService(mockAdminDs, mockRedisCache, auditService);
      const result = await service.createTenant(
        {
          code: 'shop01',
          shopName: 'ร้านอะไหล่ 1',
          ownerUsername: 'owner1',
          ownerPassword: 'pass123',
          ownerDisplayName: 'เจ้าของร้าน',
        },
        'adm1',
      );

      expect(result.tenantId).toBe('tenant-123');
      expect(result.enrolCode).toBeDefined();
      expect(mockAdminDs.transaction).toHaveBeenCalled();

      // Verify seed categories were inserted
      const categoryCalls = mockAdminDs.query.mock.calls.filter((c: any) =>
        c[0].includes('INSERT INTO categories'),
      );
      expect(categoryCalls).toHaveLength(5);
      expect(categoryCalls.map((c: any) => c[1][1])).toEqual([...SEED_CATEGORIES]);
    });

    it('updates tenant status and immediately purges Redis cache key', async () => {
      mockAdminDs.query.mockResolvedValueOnce([{ id: 't1', status: 'suspended' }]);

      const service = new PlatformTenantsService(mockAdminDs, mockRedisCache, auditService);
      const res = await service.updateStatus('t1', 'suspended', 'adm1');

      expect(res).toEqual({ tenantId: 't1', status: 'suspended' });
      expect(mockRedisCache.del).toHaveBeenCalledWith('t:t1:status');
    });
  });

  describe('TenantImportService', () => {
    it('rejects import if tenant already has sales or transactional data', async () => {
      // Mock sales query returning 1 row
      mockAdminDs.query.mockResolvedValueOnce([{ n: 1 }]);

      const importService = new TenantImportService(mockAdminDs, auditService);
      await expect(
        importService.importSnapshot(
          't1',
          { __meta: { version: 2 }, sa_products: [] },
          'adm1',
        ),
      ).rejects.toThrow(ConflictException);
    });

    it('pre-flight scan rejects negative product stock', async () => {
      // Check tables return 0
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService);
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

    it('imports snapshot cleanly when valid and tenant is empty', async () => {
      mockAdminDs.query.mockResolvedValue([{ n: 0 }]);

      const importService = new TenantImportService(mockAdminDs, auditService);
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
    });
  });
});
