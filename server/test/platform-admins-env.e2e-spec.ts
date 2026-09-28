import { randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { syncPlatformAdmins } from '../src/db/platform-admins-env.js';
import { parsePlatformAdmins, APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { createTestApp } from './support/fixture.js';

/**
 * #443: `PLATFORM_ADMINS` boot sync. Each case ends at `POST /api/v1/platform/auth/token`
 * (what an admin actually sees), not only at the row written. Calls the exported
 * `syncPlatformAdmins()` directly, as `main.ts` does before it listens.
 */
describe('PLATFORM_ADMINS boot sync (e2e, #443)', () => {
  let app: INestApplication;
  let adminDs: DataSource;
  let ownerUrl: string;
  const created: string[] = [];

  function newUsername(): string {
    const username = `envadm-${randomUUID().slice(0, 8)}`;
    created.push(username);
    return username;
  }

  const login = (username: string, password: string) =>
    request(app.getHttpServer())
      .post('/api/v1/platform/auth/token')
      .send({ username, password });

  const sync = (raw: string) => syncPlatformAdmins(ownerUrl, parsePlatformAdmins(raw)!);

  beforeAll(async () => {
    ({ app, admin: adminDs } = await createTestApp());
    ownerUrl = app.get<AppConfig>(APP_CONFIG).adminDatabaseUrl;
  });

  afterAll(async () => {
    if (adminDs) {
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

  it('creates, is idempotent, re-hashes a changed password, and keeps a removed name', async () => {
    const a = newUsername();
    const b = newUsername();

    expect(await sync(`${a}:first-password-1, ${b} : other-password-1`)).toEqual([
      { username: a, action: 'created' },
      { username: b, action: 'created' },
    ]);
    expect((await login(a, 'first-password-1')).status).toBe(200);

    // Re-run with the same value: nothing is written, the hash is the same row value.
    const [before] = await adminDs.query(
      `SELECT password_hash FROM platform_admins WHERE username = $1`,
      [a],
    );
    expect(await sync(`${a}:first-password-1,${b}:other-password-1`)).toEqual([
      { username: a, action: 'unchanged' },
      { username: b, action: 'unchanged' },
    ]);
    const [after] = await adminDs.query(
      `SELECT password_hash FROM platform_admins WHERE username = $1`,
      [a],
    );
    expect(after.password_hash).toBe(before.password_hash);

    // Password changed in the env, and `b` removed from it.
    expect(await sync(`${a}:second-password-2`)).toEqual([{ username: a, action: 'updated' }]);
    expect((await login(a, 'first-password-1')).status).toBe(401);
    expect((await login(a, 'second-password-2')).status).toBe(200);

    // `b` is neither deleted nor disabled.
    const [kept] = await adminDs.query(
      `SELECT is_active FROM platform_admins WHERE username = $1`,
      [b],
    );
    expect(kept).toEqual({ is_active: true });
    expect((await login(b, 'other-password-1')).status).toBe(200);
  });

  it('survives three replicas booting at once', async () => {
    const c = newUsername();
    const results = await Promise.all([1, 2, 3].map(() => sync(`${c}:replica-password-1`)));
    const actions = results.map(([r]) => r.action).sort();
    expect(actions).toEqual(['created', 'unchanged', 'unchanged']);
    const rows = await adminDs.query(`SELECT 1 FROM platform_admins WHERE username = $1`, [c]);
    expect(rows).toHaveLength(1);
  });
});
