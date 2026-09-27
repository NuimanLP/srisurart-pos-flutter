import { describe, it, expect, vi } from 'vitest';
import { PlatformTenantsController } from './platform-tenants.controller.js';

// #138 item 5: the platform plane records the address nginx appended, not the client-written
// leftmost entry nor nginx's own socket address.
describe('PlatformTenantsController client ip', () => {
  const service = {
    createTenant: vi.fn().mockResolvedValue({}),
    updateStatus: vi.fn().mockResolvedValue({}),
    listTenants: vi.fn().mockResolvedValue([]),
    reissueEnrolCode: vi.fn().mockResolvedValue({}),
    getTenantDetail: vi.fn().mockResolvedValue({}),
  };
  const controller = new PlatformTenantsController(service as any);
  const req = {
    ip: '172.18.0.9',
    headers: { 'x-forwarded-for': '1.1.1.1, 10.0.0.5' },
    platformAdmin: { id: 'admin-1', username: 'root' },
  } as any;

  it('listTenants', async () => {
    await controller.listTenants(req);
    expect(service.listTenants).toHaveBeenCalledWith('admin-1', '10.0.0.5');
  });

  it('createTenant', async () => {
    await controller.createTenant({} as any, req);
    expect(service.createTenant).toHaveBeenCalledWith({}, 'admin-1', '10.0.0.5');
  });

  it('updateStatus', async () => {
    await controller.updateStatus('t1', { status: 'suspended' }, req);
    expect(service.updateStatus).toHaveBeenCalledWith('t1', 'suspended', 'admin-1', '10.0.0.5');
  });

  it('reissueEnrolCode', async () => {
    await controller.reissueEnrolCode('t1', 'dv1', req);
    expect(service.reissueEnrolCode).toHaveBeenCalledWith('t1', 'dv1', 'admin-1', '10.0.0.5');
  });

  it('getTenantDetail', async () => {
    await controller.getTenantDetail('t1', req);
    expect(service.getTenantDetail).toHaveBeenCalledWith('t1', 'admin-1', '10.0.0.5');
  });
});
