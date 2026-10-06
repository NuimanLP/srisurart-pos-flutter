import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import type { AddressInfo } from 'node:net';
import type { INestApplication } from '@nestjs/common';
import type { DataSource } from 'typeorm';
import { bootstrapAdmin } from '../src/db/bootstrap-admin.js';
import { APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { createTestApp } from './support/fixture.js';
import { UUID_V7 } from './support/test-ids.js';

// `tsx`'s own bin script, not `npx tsx` — a devDependency already installed for
// `pnpm k6:setup`/`k6:verify`. Running the TypeScript source directly means this suite
// needs no `pnpm build` first, same as every other e2e suite here (see the comment on
// `bootstrap-admin.e2e-spec.ts`: "vitest runs over `src/`, and nothing in the test run
// builds `dist/`").
const TSX_BIN = fileURLToPath(new URL('../node_modules/.bin/tsx', import.meta.url));
const CLI_PATH = fileURLToPath(new URL('../src/cli/platform.ts', import.meta.url));

interface CliResult {
  stdout: string;
  stderr: string;
  exitCode: number | null;
}

/**
 * Spawns the real CLI as its own OS process (never `runPlatformCli()` called in-process —
 * that path, including the two-secrets-in-one-chunk stdin race, is covered by the mocked-
 * `fetch` unit tests in `src/cli/platform.spec.ts`). What only a real process boundary can
 * prove: the exit code the shell would actually see, and that a password typed on stdin
 * never reaches the CLI's own stdout — no amount of mocking `fetch` demonstrates either.
 */
function runCli(args: string[], stdinLines: string[]): Promise<CliResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(TSX_BIN, [CLI_PATH, ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk: Buffer) => (stdout += chunk.toString('utf8')));
    child.stderr.on('data', (chunk: Buffer) => (stderr += chunk.toString('utf8')));
    child.on('error', reject);
    child.on('close', (exitCode) => resolve({ stdout, stderr, exitCode }));
    child.stdin.end(stdinLines.map((line) => `${line}\n`).join(''));
  });
}

describe('platform CLI (e2e, #443 PR1)', () => {
  let app: INestApplication;
  let adminDs: DataSource;
  let baseUrl: string;
  let adminUsername: string;
  const ADMIN_PASSWORD = 'cli-e2e-admin-secret-1';
  const tenantsToClean: string[] = [];

  async function cleanupTenant(tenantId: string) {
    await adminDs.query(`DELETE FROM audit_log WHERE tenant_id = $1`, [tenantId]);
    await adminDs.query(`DELETE FROM devices WHERE tenant_id = $1`, [tenantId]);
    await adminDs.query(`DELETE FROM categories WHERE tenant_id = $1`, [tenantId]);
    await adminDs.query(`DELETE FROM settings WHERE tenant_id = $1`, [tenantId]);
    await adminDs.query(`DELETE FROM users WHERE tenant_id = $1`, [tenantId]);
    await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
  }

  beforeAll(async () => {
    ({ app, admin: adminDs } = await createTestApp());
    const config = app.get<AppConfig>(APP_CONFIG);
    const port = (app.getHttpServer().address() as AddressInfo).port;
    baseUrl = `http://127.0.0.1:${port}`;

    adminUsername = `cli-e2e-${randomUUID().slice(0, 8)}`;
    await bootstrapAdmin({
      url: config.adminDatabaseUrl,
      username: adminUsername,
      password: ADMIN_PASSWORD,
      displayName: 'CLI E2E Admin',
    });
  }, 30_000);

  afterAll(async () => {
    for (const tenantId of tenantsToClean) {
      await cleanupTenant(tenantId);
    }
    await adminDs.query(
      `DELETE FROM audit_log WHERE platform_admin_id IN (SELECT id FROM platform_admins WHERE username = $1)`,
      [adminUsername],
    );
    await adminDs.query(`DELETE FROM platform_admins WHERE username = $1`, [adminUsername]);
    await app?.close();
  });

  it('login: exits non-zero on a wrong password and never echoes it', async () => {
    const result = await runCli(['login', '--user', adminUsername, '--base-url', baseUrl], [
      'definitely-the-wrong-password',
    ]);

    expect(result.exitCode).not.toBe(0);
    expect(result.stdout).not.toContain('definitely-the-wrong-password');
    expect(result.stderr).not.toContain('definitely-the-wrong-password');
    expect(result.stderr).toContain('UNAUTHORIZED');
  }, 30_000);

  it('login: exits 0 and prints only the username/id on the right password', async () => {
    const result = await runCli(['login', '--user', adminUsername, '--base-url', baseUrl], [
      ADMIN_PASSWORD,
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain(`logged in as ${adminUsername}`);
    expect(result.stdout).not.toContain(ADMIN_PASSWORD);
    expect(result.stderr).not.toContain(ADMIN_PASSWORD);
  }, 30_000);

  it('tenants:create: provisions a real tenant with a server-generated temp password (#443 PR3), never echoing the admin password', async () => {
    const code = `cli-${randomUUID().slice(0, 8)}`;

    const result = await runCli(
      [
        'tenants:create',
        '--user', adminUsername,
        '--base-url', baseUrl,
        '--code', code,
        '--shop-name', 'ร้านทดสอบ CLI',
        '--owner-username', `owner_${code}`,
      ],
      [ADMIN_PASSWORD],
    );

    expect(result.exitCode).toBe(0);
    expect(result.stdout).not.toContain(ADMIN_PASSWORD);
    expect(result.stderr).not.toContain(ADMIN_PASSWORD);
    expect(result.stderr).toContain('shown once');

    const parsed = JSON.parse(result.stdout);
    expect(parsed.code).toBe(code);
    expect(parsed.enrolCode).toEqual(expect.any(String));
    expect(parsed.tempPassword).toMatch(/^[A-HJ-NP-Za-km-z2-9]{16}$/);
    // The temp password appears once in stdout (the JSON result) and nowhere else.
    expect(result.stdout.split(parsed.tempPassword).length - 1).toBe(1);
    expect(result.stderr).not.toContain(parsed.tempPassword);
    tenantsToClean.push(parsed.tenantId);

    const rows = await adminDs.query(`SELECT status FROM tenants WHERE id = $1`, [parsed.tenantId]);
    expect(rows).toEqual([{ status: 'active' }]);
  }, 30_000);

  it('tenants:list: includes a tenant created moments before', async () => {
    const code = `cli-list-${randomUUID().slice(0, 8)}`;
    const created = await runCli(
      [
        'tenants:create',
        '--user', adminUsername,
        '--base-url', baseUrl,
        '--code', code,
        '--shop-name', 'ร้านทดสอบ CLI list',
        '--owner-username', `owner_${code}`,
      ],
      [ADMIN_PASSWORD],
    );
    expect(created.exitCode).toBe(0);
    const tenantId = JSON.parse(created.stdout).tenantId;
    tenantsToClean.push(tenantId);

    const listed = await runCli(['tenants:list', '--user', adminUsername, '--base-url', baseUrl], [
      ADMIN_PASSWORD,
    ]);

    expect(listed.exitCode).toBe(0);
    const tenants = JSON.parse(listed.stdout) as Array<{ id: string; code: string }>;
    expect(tenants.some((t) => t.id === tenantId && t.code === code)).toBe(true);
  }, 30_000);

  it('tenants:status: flips a real tenant to suspended', async () => {
    const code = `cli-status-${randomUUID().slice(0, 8)}`;
    const created = await runCli(
      [
        'tenants:create',
        '--user', adminUsername,
        '--base-url', baseUrl,
        '--code', code,
        '--shop-name', 'ร้านทดสอบ CLI status',
        '--owner-username', `owner_${code}`,
      ],
      [ADMIN_PASSWORD],
    );
    const tenantId = JSON.parse(created.stdout).tenantId;
    tenantsToClean.push(tenantId);

    const result = await runCli(
      ['tenants:status', tenantId, 'suspended', '--user', adminUsername, '--base-url', baseUrl],
      [ADMIN_PASSWORD],
    );

    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({ tenantId, status: 'suspended' });
    const rows = await adminDs.query(`SELECT status FROM tenants WHERE id = $1`, [tenantId]);
    expect(rows).toEqual([{ status: 'suspended' }]);
  }, 30_000);

  it('tenants:show: returns the tenant, its seed device, and no import jobs yet', async () => {
    const code = `cli-show-${randomUUID().slice(0, 8)}`;
    const created = await runCli(
      [
        'tenants:create',
        '--user', adminUsername,
        '--base-url', baseUrl,
        '--code', code,
        '--shop-name', 'ร้านทดสอบ CLI show',
        '--owner-username', `owner_${code}`,
      ],
      [ADMIN_PASSWORD],
    );
    const tenantId = JSON.parse(created.stdout).tenantId;
    tenantsToClean.push(tenantId);

    const result = await runCli(
      ['tenants:show', tenantId, '--user', adminUsername, '--base-url', baseUrl],
      [ADMIN_PASSWORD],
    );

    expect(result.exitCode).toBe(0);
    const detail = JSON.parse(result.stdout);
    expect(detail.tenant.id).toBe(tenantId);
    expect(detail.devices).toEqual([
      expect.objectContaining({ id: expect.stringMatching(UUID_V7), role: 'pos', enrolled: false }),
    ]);
    expect(detail.importJobs).toEqual([]);
  }, 30_000);

  it('devices:reissue-code: issues a fresh code that enrols after the tenant is created', async () => {
    const code = `cli-reissue-${randomUUID().slice(0, 8)}`;
    const created = await runCli(
      [
        'tenants:create',
        '--user', adminUsername,
        '--base-url', baseUrl,
        '--code', code,
        '--shop-name', 'ร้านทดสอบ CLI reissue',
        '--owner-username', `owner_${code}`,
      ],
      [ADMIN_PASSWORD],
    );
    const tenantId = JSON.parse(created.stdout).tenantId;
    tenantsToClean.push(tenantId);
    // The first device's id is a server UUID (#616; it was the literal 'pos1').
    const [{ id: pos1 }] = (await adminDs.query(
      `SELECT id FROM devices WHERE tenant_id = $1 AND device_no = 1`,
      [tenantId],
    )) as { id: string }[];

    const result = await runCli(
      ['devices:reissue-code', tenantId, pos1, '--user', adminUsername, '--base-url', baseUrl],
      [ADMIN_PASSWORD],
    );

    expect(result.exitCode).toBe(0);
    expect(result.stderr).toContain('shown once');
    const parsed = JSON.parse(result.stdout);
    expect(parsed.deviceId).toBe(pos1);
    expect(parsed.enrolCode).toMatch(/^[0-9A-F]{8}$/);

    const enrolRes = await fetch(`${baseUrl}/api/v1/auth/device`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: parsed.enrolCode }),
    });
    expect(enrolRes.status).toBe(200);
  }, 30_000);

  it('owner:temp-password: issues a new temp password, and the old one stops working', async () => {
    const code = `cli-reset-${randomUUID().slice(0, 8)}`;
    const ownerUsername = `owner_${code}`;
    const created = await runCli(
      [
        'tenants:create',
        '--user', adminUsername,
        '--base-url', baseUrl,
        '--code', code,
        '--shop-name', 'ร้านทดสอบ CLI reset',
        '--owner-username', ownerUsername,
      ],
      [ADMIN_PASSWORD],
    );
    const { tenantId, tempPassword: firstTemp } = JSON.parse(created.stdout);
    tenantsToClean.push(tenantId);

    const result = await runCli(
      ['owner:temp-password', tenantId, '--user', adminUsername, '--base-url', baseUrl],
      [ADMIN_PASSWORD],
    );

    expect(result.exitCode).toBe(0);
    const parsed = JSON.parse(result.stdout);
    expect(parsed.ownerUsername).toBe(ownerUsername);
    expect(parsed.tempPassword).toMatch(/^[A-HJ-NP-Za-km-z2-9]{16}$/);
    expect(parsed.tempPassword).not.toBe(firstTemp);

    const oldLogin = await fetch(`${baseUrl}/api/v1/auth/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: ownerUsername, password: firstTemp }),
    });
    expect(oldLogin.status).toBe(401);
  }, 30_000);

  it('owner:set-password: logs in the owner with the temp password and sets a real one', async () => {
    const code = `cli-setpw-${randomUUID().slice(0, 8)}`;
    const ownerUsername = `owner_${code}`;
    const created = await runCli(
      [
        'tenants:create',
        '--user', adminUsername,
        '--base-url', baseUrl,
        '--code', code,
        '--shop-name', 'ร้านทดสอบ CLI setpw',
        '--owner-username', ownerUsername,
      ],
      [ADMIN_PASSWORD],
    );
    const { tenantId, tempPassword } = JSON.parse(created.stdout);
    tenantsToClean.push(tenantId);
    const newPassword = 'cli-e2e-real-owner-password-1';

    const result = await runCli(['owner:set-password', ownerUsername, '--base-url', baseUrl], [
      tempPassword,
      newPassword,
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).not.toContain(tempPassword);
    expect(result.stdout).not.toContain(newPassword);
    expect(result.stderr).not.toContain(tempPassword);
    expect(result.stderr).not.toContain(newPassword);
    expect(JSON.parse(result.stdout)).toEqual({ username: ownerUsername, passwordChanged: true });

    const loggedIn = await fetch(`${baseUrl}/api/v1/auth/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: ownerUsername, password: newPassword }),
    });
    expect(loggedIn.status).toBe(200);
    const body = (await loggedIn.json()) as { data: { passwordChangeRequired?: boolean } };
    expect(body.data.passwordChangeRequired).toBeUndefined();
  }, 30_000);

  it('rejects a password passed on argv before ever dialling the network', async () => {
    const result = await runCli(
      ['login', '--user', adminUsername, '--password', 'x', '--base-url', baseUrl],
      [],
    );

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain('not accepted');
  }, 30_000);
});
