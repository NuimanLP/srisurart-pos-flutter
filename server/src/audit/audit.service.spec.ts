import { describe, it, expect, vi } from 'vitest';
import { AuditService } from './audit.service.js';

describe('AuditService', () => {
  it('writes structured log with valid IPv4', async () => {
    const managerMock = {
      query: vi.fn().mockResolvedValue([]),
    };
    const auditService = new AuditService();

    await auditService.log(managerMock as any, {
      tenantId: 't1',
      userId: 'u1',
      action: 'auth.login',
      ip: '192.168.1.50',
    });

    expect(managerMock.query).toHaveBeenCalledWith(
      expect.stringContaining('INSERT INTO audit_log'),
      expect.arrayContaining(['t1', 'u1', null, null, 'auth.login', null, null, null, null, '192.168.1.50']),
    );
  });

  it('extracts first client IP from proxy chain', async () => {
    const managerMock = {
      query: vi.fn().mockResolvedValue([]),
    };
    const auditService = new AuditService();

    await auditService.log(managerMock as any, {
      tenantId: 't1',
      userId: 'u1',
      action: 'auth.login',
      ip: '203.0.113.195, 70.41.3.18',
    });

    expect(managerMock.query).toHaveBeenCalledWith(
      expect.stringContaining('INSERT INTO audit_log'),
      expect.arrayContaining(['203.0.113.195']),
    );
  });

  it('sets cleanIp to null when IP string is invalid or malformed', async () => {
    const managerMock = {
      query: vi.fn().mockResolvedValue([]),
    };
    const auditService = new AuditService();

    await auditService.log(managerMock as any, {
      tenantId: 't1',
      userId: 'u1',
      action: 'auth.login',
      ip: 'invalid-ip-string',
    });

    expect(managerMock.query).toHaveBeenCalledWith(
      expect.stringContaining('INSERT INTO audit_log'),
      expect.arrayContaining(['t1', 'u1', null, null, 'auth.login', null, null, null, null, null]),
    );
  });
});
