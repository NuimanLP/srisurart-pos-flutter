import { randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { bootstrapAdmin } from '../src/db/bootstrap-admin.js';
import { APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { createTestApp } from './support/fixture.js';

/**
 * #337 (D2 of #335): `pnpm bootstrap:admin` has to end in a platform admin that can
 * actually log in — so every case here finishes at `POST /api/v1/platform/auth/token`,
 * the externally visible behaviour, rather than at the row it wrote.
 *
 * The suite calls the exported `bootstrapAdmin()`: vitest runs over `src/`, and nothing
 * in the test run builds `dist/`.
 */
describe('platform admin bootstrap (e2e, #337)', () => {
  let app: INestApplication;
  let adminDs: DataSource;
  /** The owner-role URL — the same one the app's ADMIN_DATA_SOURCE uses. */
  let ownerUrl: string;
  /** `pos_app`: holds INSERT on platform_admins, so it is the real non-owner case. */
  let appUrl: string;
  const created: string[] = [];

  const DISPLAY_NAME = 'ผู้ดูแลระบบ';

  /** A username per case, so one leftover row cannot poison the next test. */
  function newUsername(): string {
    const username = `boot-${randomUUID().slice(0, 8)}`;
    created.push(username);
    return username;
  }

  const login = (username: string, password: string) =>
    request(app.getHttpServer())
      .post('/api/v1/platform/auth/token')
      .send({ username, password });

  beforeAll(async () => {
    ({ app, admin: adminDs } = await createTestApp());
    const config = app.get<AppConfig>(APP_CONFIG);
    ownerUrl = config.adminDatabaseUrl;
    appUrl = config.databaseUrl;
  });

  afterAll(async () => {
    if (adminDs) {
      // audit_log.platform_admin_id is a FK: the login rows go first.
      await adminDs.query(
        `DELETE FROM audit_log WHERE platform_admin_id IN
           (SELECT id FROM platform_admins WHERE username = ANY($1::text[]))`,
        [created],
      );
      await adminDs.query(`DELETE FROM platform_admins WHERE username = ANY($1::text[])`, [
        created,
      ]);
    }
    await app?.close();
  });

  it('creates an admin that can log in', async () => {
    const username = newUsername();
    const result = await bootstrapAdmin({
      url: ownerUrl,
      username,
      password: 'bootstrap-secret-1',
      displayName: DISPLAY_NAME,
    });

    expect(result).toMatchObject({ action: 'created', username });
    expect(result.id).toBeTruthy();

    const res = await login(username, 'bootstrap-secret-1');
    expect(res.status).toBe(200);
    expect(res.body.data.token).toEqual(expect.any(String));
    expect(res.body.data.admin).toMatchObject({
      username,
      displayName: DISPLAY_NAME,
    });
  });

  it('is idempotent: a second run leaves the existing password alone', async () => {
    const username = newUsername();
    await bootstrapAdmin({
      url: ownerUrl,
      username,
      password: 'bootstrap-secret-1',
      displayName: DISPLAY_NAME,
    });

    const again = await bootstrapAdmin({
      url: ownerUrl,
      username,
      password: 'a-different-password-2',
      displayName: 'ชื่ออื่น',
    });
    expect(again).toMatchObject({ action: 'unchanged', username, id: null });

    expect((await login(username, 'bootstrap-secret-1')).status).toBe(200);
    expect((await login(username, 'a-different-password-2')).status).toBe(401);
  });

  it('--force resets the password and the new one logs in', async () => {
    const username = newUsername();
    await bootstrapAdmin({
      url: ownerUrl,
      username,
      password: 'bootstrap-secret-1',
      displayName: DISPLAY_NAME,
    });

    const forced = await bootstrapAdmin({
      url: ownerUrl,
      username,
      password: 'rotated-secret-1234',
      displayName: DISPLAY_NAME,
      force: true,
    });
    expect(forced).toMatchObject({ action: 'updated', username });

    expect((await login(username, 'rotated-secret-1234')).status).toBe(200);
    expect((await login(username, 'bootstrap-secret-1')).status).toBe(401);
  });

  it('rejects an empty or too-short password and writes nothing', async () => {
    const username = newUsername();
    const base = { url: ownerUrl, username, displayName: DISPLAY_NAME };

    await expect(bootstrapAdmin({ ...base, password: '' })).rejects.toThrow(
      /BOOTSTRAP_ADMIN_PASSWORD is required/,
    );
    await expect(bootstrapAdmin({ ...base, password: '   ' })).rejects.toThrow(
      /BOOTSTRAP_ADMIN_PASSWORD is required/,
    );
    await expect(bootstrapAdmin({ ...base, password: 'short1' })).rejects.toThrow(
      /too weak: at least 12 characters/,
    );
    await expect(
      bootstrapAdmin({
        url: ownerUrl,
        username: '',
        password: 'bootstrap-secret-1',
        displayName: DISPLAY_NAME,
      }),
    ).rejects.toThrow(/BOOTSTRAP_ADMIN_USERNAME is required/);
    await expect(
      bootstrapAdmin({
        url: ownerUrl,
        username,
        password: 'bootstrap-secret-1',
        displayName: '',
      }),
    ).rejects.toThrow(/BOOTSTRAP_ADMIN_DISPLAY_NAME is required/);

    const rows = await adminDs.query(
      `SELECT id FROM platform_admins WHERE username = $1`,
      [username],
    );
    expect(rows.length).toBe(0);
  });

  it('refuses to run as a role that does not own platform_admins', async () => {
    const username = newUsername();
    await expect(
      bootstrapAdmin({
        url: appUrl,
        username,
        password: 'bootstrap-secret-1',
        displayName: DISPLAY_NAME,
      }),
    ).rejects.toThrow(/must be the owner role/);

    const rows = await adminDs.query(
      `SELECT id FROM platform_admins WHERE username = $1`,
      [username],
    );
    expect(rows.length).toBe(0);
  });

  it('does not reactivate a disabled admin, even with --force', async () => {
    const username = newUsername();
    await bootstrapAdmin({
      url: ownerUrl,
      username,
      password: 'bootstrap-secret-1',
      displayName: DISPLAY_NAME,
    });
    await adminDs.query(`UPDATE platform_admins SET is_active = false WHERE username = $1`, [
      username,
    ]);

    await bootstrapAdmin({
      url: ownerUrl,
      username,
      password: 'rotated-secret-1234',
      displayName: DISPLAY_NAME,
      force: true,
    });

    expect((await login(username, 'rotated-secret-1234')).status).toBe(401);
    const rows = await adminDs.query(
      `SELECT is_active FROM platform_admins WHERE username = $1`,
      [username],
    );
    expect(rows[0].is_active).toBe(false);
  });
});
