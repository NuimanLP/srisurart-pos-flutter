import { ConflictException, HttpException } from '@nestjs/common';
import { readFileSync } from 'node:fs';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { OwnerImportController } from '../src/backup/owner-import.controller.js';
import { runInRequestContext } from '../src/common/request-context.js';
import { AuditService } from '../src/platform/audit.service.js';
import { TenantImportService } from '../src/platform/tenant-import.service.js';
import { testId } from './support/test-ids.js';

/**
 * The shop owner's own import (`POST /backup/import`, Settings → กู้คืนข้อมูล): the same
 * `TenantImportService` as the platform route, with the owner recorded as the requester.
 */
describe('owner import (POST /backup/import)', () => {
  let mockAdminDs: any;
  let importQueue: { add: ReturnType<typeof vi.fn> };
  let service: TenantImportService;
  const tenantId = testId('owner-import-tenant');
  const ownerId = testId('owner-import-user');

  beforeEach(() => {
    mockAdminDs = {
      query: vi.fn().mockResolvedValue([{ n: 0 }]),
      transaction: vi.fn(async (cb) => cb(mockAdminDs)),
    };
    importQueue = { add: vi.fn() };
    service = new TenantImportService(mockAdminDs, new AuditService(), { invalidate: vi.fn() } as any, importQueue as any);
  });

  const auditInserts = () =>
    mockAdminDs.query.mock.calls.filter((c: any[]) => String(c[0]).includes('INSERT INTO audit_log'));

  // The coordinator's question: is the file the app's own backup button saves importable?
  // `frontend/test/app_export_fixture_test.dart` pins that file (SnapshotRepository
  // .exportSnapshot() of a seed-free Drift database holding a synthetic shop's history).
  const appExport = () =>
    JSON.parse(readFileSync(new URL('../../frontend/test/fixtures/app_export_from_synthetic.json', import.meta.url), 'utf8'));

  it('accepts the file the app\'s backup button saves: pre-flight and the write both pass', async () => {
    const res = await service.importSnapshot(tenantId, appExport(), testId('adm1'));
    expect(res.status).toBe('success');
    // The synthetic shop is the `realistic` profile: history names hard-deleted rows.
    expect(res.tombstones.products + res.tombstones.customers + res.tombstones.mechanics).toBeGreaterThan(0);
  });

  it('createOwnerJob pre-flights, records no platform admin, and hands the owner id to the worker', async () => {
    const { jobId } = await service.createOwnerJob(tenantId, appExport(), ownerId, '10.0.0.5');

    const insert = mockAdminDs.query.mock.calls.find((c: any[]) => String(c[0]).includes('INSERT INTO import_jobs'));
    expect(insert[1][0]).toBe(tenantId);
    expect(insert[1][1]).toBe(jobId);
    expect(insert[1][3]).toBeNull(); // requested_by references platform_admins — never an owner id
    expect(importQueue.add).toHaveBeenCalledWith(
      'tenant.import',
      expect.objectContaining({ tenantId, importJobId: jobId, requestedByUserId: ownerId }),
      expect.anything(),
    );
  });

  it('createOwnerJob keeps the safety rules: a shop with bills is refused 409', async () => {
    mockAdminDs.query.mockResolvedValueOnce([{ n: 3 }]);
    await expect(service.createOwnerJob(tenantId, appExport(), ownerId, undefined)).rejects.toThrow(ConflictException);
    expect(importQueue.add).not.toHaveBeenCalled();
  });

  it('createOwnerJob refuses an old-app file with INVALID_ID', async () => {
    await expect(
      service.createOwnerJob(tenantId, { __meta: { version: 2 }, sa_products: [{ id: 'p1', stock: 1 }] }, ownerId, undefined),
    ).rejects.toMatchObject({ response: expect.objectContaining({ code: 'INVALID_ID' }) });
  });

  it('the worker audits an owner import as backup.imported under the owner\'s user id', async () => {
    const jobId = testId('owner-import-job');
    mockAdminDs.query.mockImplementation(async (sql: string) =>
      sql.includes('FROM import_jobs WHERE id')
        ? [{ tenant_id: tenantId, payload: appExport(), requested_by: null, ip: null, status: 'running', result: null }]
        : [{ n: 0 }],
    );
    await service.processJob(jobId, ownerId);

    const [, params] = auditInserts().at(-1);
    expect(params[0]).toBe(tenantId);
    expect(params[1]).toBeNull(); // platform_admin_id
    expect(params[2]).toBe(ownerId); // user_id
    expect(params[4]).toBe('backup.imported');
  });

  it('a platform admin\'s job is still audited as platform.tenant.import', async () => {
    const adminId = testId('adm1');
    mockAdminDs.query.mockImplementation(async (sql: string) =>
      sql.includes('FROM import_jobs WHERE id')
        ? [{ tenant_id: tenantId, payload: appExport(), requested_by: adminId, ip: null, status: 'running', result: null }]
        : [{ n: 0 }],
    );
    await service.processJob(testId('admin-import-job'));

    const [, params] = auditInserts().at(-1);
    expect(params[1]).toBe(adminId);
    expect(params[2]).toBeNull();
    expect(params[4]).toBe('platform.tenant.import');
  });
});

describe('OwnerImportController', () => {
  const tenantId = testId('owner-import-tenant');
  const importService = {
    createOwnerJob: vi.fn().mockResolvedValue({ jobId: 'j1' }),
    getJob: vi.fn().mockResolvedValue({ jobId: 'j1', status: 'queued' }),
  };
  const controller = new OwnerImportController(importService as any);
  const asTenant = <T>(fn: () => Promise<T>) => runInRequestContext({ tenantId, manager: null as any }, fn);
  const req = (user: Record<string, unknown>) => ({ user, headers: {}, ip: '10.0.0.5' }) as any;
  const owner = { userId: testId('u1'), role: 'owner', deviceId: testId('d1') };

  beforeEach(() => vi.clearAllMocks());

  it('enqueues for the tenant the guard authorised, never one the request names', async () => {
    await asTenant(() => controller.importSnapshot({ __meta: {} } as any, req(owner)));
    expect(importService.createOwnerJob).toHaveBeenCalledWith(tenantId, { __meta: {} }, owner.userId, '10.0.0.5');
  });

  it('refuses a non-owner role with 403 FORBIDDEN', async () => {
    const err = await asTenant(() => controller.importSnapshot({} as any, req({ ...owner, role: 'cashier' }))).catch((e) => e);
    expect(err).toBeInstanceOf(HttpException);
    expect(err.getStatus()).toBe(403);
    expect(err.getResponse().code).toBe('FORBIDDEN');
    expect(importService.createOwnerJob).not.toHaveBeenCalled();
  });

  it('refuses a session with no enrolled device (403 DEVICE_ROLE_FORBIDDEN), like the export', async () => {
    const err = await asTenant(() => controller.importSnapshot({} as any, req({ ...owner, deviceId: undefined }))).catch((e) => e);
    expect(err.getStatus()).toBe(403);
    expect(err.getResponse().code).toBe('DEVICE_ROLE_FORBIDDEN');
  });

  it('reads job status only within the authorised tenant', async () => {
    await asTenant(() => controller.getImportJob('j1', req(owner)));
    expect(importService.getJob).toHaveBeenCalledWith(tenantId, 'j1');
    const err = await asTenant(() => controller.getImportJob('j1', req({ ...owner, role: 'x' }))).catch((e) => e);
    expect(err.getStatus()).toBe(403);
  });
});
