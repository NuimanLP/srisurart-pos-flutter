import { randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import { parsePlatformAdmins, syncPlatformAdmins } from '../src/db/platform-admins-env.js';
import { APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { REDIS_CACHE } from '../src/infra/redis.module.js';
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
  let appUrl: string;
  let cache: Redis;
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

  /** The sync, reduced to `[username, action]` pairs (ids are random). */
  const sync = async (raw: string) =>
    (await syncPlatformAdmins(ownerUrl, parsePlatformAdmins(raw)!)).map((r) => [
      r.username,
      r.action,
    ]);

  const tenants = (token: string) =>
    request(app.getHttpServer())
      .get('/api/v1/platform/tenants')
      .set('Authorization', `Bearer ${token}`);

  beforeAll(async () => {
    ({ app, admin: adminDs } = await createTestApp());
    const config = app.get<AppConfig>(APP_CONFIG);
    ownerUrl = config.adminDatabaseUrl;
    appUrl = config.databaseUrl;
    cache = app.get<Redis>(REDIS_CACHE);
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
      [a, 'created'],
      [b, 'created'],
    ]);
    const first = await login(a, 'first-password-1');
    expect(first.status).toBe(200);
    const oldToken: string = first.body.data.token;
    expect((await tenants(oldToken)).status).toBe(200); // also caches the guard's verdict

    // Re-run with the same value: nothing is written, the hash is the same row value.
    const [before] = await adminDs.query(
      `SELECT password_hash FROM platform_admins WHERE username = $1`,
      [a],
    );
    expect(await sync(`${a}:first-password-1,${b}:other-password-1`)).toEqual([
      [a, 'unchanged'],
      [b, 'unchanged'],
    ]);
    const [after] = await adminDs.query(
      `SELECT password_hash FROM platform_admins WHERE username = $1`,
      [a],
    );
    expect(after.password_hash).toBe(before.password_hash);

    // Password changed in the env, and `b` removed from it. `iat` is whole seconds and the
    // cutoff is strict `<` (ADR-0009 addendum), so let the old token's second pass first.
    await new Promise((r) => setTimeout(r, 1100));
    const [{ id: aId }] = await adminDs.query(
      `SELECT id FROM platform_admins WHERE username = $1`,
      [a],
    );
    expect(await sync(`${a}:second-password-2`)).toEqual([[a, 'updated']]);
    await cache.del(`pa:${aId}:exists`); // what main.ts does after an `updated` result
    expect((await tenants(oldToken)).status).toBe(401);
    expect((await login(a, 'first-password-1')).status).toBe(401);
    const second = await login(a, 'second-password-2');
    expect(second.status).toBe(200);
    expect((await tenants(second.body.data.token)).status).toBe(200);

    // `b` is neither deleted nor disabled.
    const [kept] = await adminDs.query(
      `SELECT is_active FROM platform_admins WHERE username = $1`,
      [b],
    );
    expect(kept).toEqual({ is_active: true });
    expect((await login(b, 'other-password-1')).status).toBe(200);
  });

  it('leaves a disabled admin alone and reports it `inactive`', async () => {
    const d = newUsername();
    await sync(`${d}:disabled-password-1`);
    await adminDs.query(`UPDATE platform_admins SET is_active = false WHERE username = $1`, [d]);
    expect(await sync(`${d}:a-new-password-9`)).toEqual([[d, 'inactive']]);
    const [row] = await adminDs.query(
      `SELECT is_active, password_changed_at FROM platform_admins WHERE username = $1`,
      [d],
    );
    expect(row).toEqual({ is_active: false, password_changed_at: null });
  });

  it('refuses a non-owner connection with the friendly error, never echoing a password', async () => {
    const e = newUsername();
    const err = await syncPlatformAdmins(appUrl, [
      { username: e, password: 'never-in-a-message-1' },
    ]).catch((x: Error) => x);
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).toMatch(/must be the owner role/);
    expect((err as Error).message).not.toContain('never-in-a-message-1');
  });

  it('survives three replicas booting at once', async () => {
    const c = newUsername();
    const results = await Promise.all([1, 2, 3].map(() => sync(`${c}:replica-password-1`)));
    const actions = results.map(([[, action]]) => action).sort();
    expect(actions).toEqual(['created', 'unchanged', 'unchanged']);
    const rows = await adminDs.query(`SELECT 1 FROM platform_admins WHERE username = $1`, [c]);
    expect(rows).toHaveLength(1);
  });
});
