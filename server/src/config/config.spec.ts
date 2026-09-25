import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, it, expect } from 'vitest';
import { loadConfig, refusePublicSecret, refusePublicSecretInUrl } from './config.js';

/**
 * #367: compose passes `CORS_ORIGINS` / `PLATFORM_ADMIN_IPS` into every api container as
 * `${KEY:-}`, so the variable is always *present* and blank has to mean "unset". These cases
 * pin that blank keeps the historical default while a typo that lists no entry fails loudly
 * instead of quietly reopening CORS to '*'.
 */
describe('loadConfig — CORS_ORIGINS / PLATFORM_ADMIN_IPS (#367)', () => {
  const base: NodeJS.ProcessEnv = {
    INSTANCE_ID: 'worker', // skips the RS256 key requirements (config.ts `isApi`)
    DATABASE_URL: 'postgres://pos_app:pw@localhost:5432/pos',
    REDIS_CACHE_URL: 'redis://localhost:6379',
    REDIS_QUEUE_URL: 'redis://localhost:6380',
    JWT_PLATFORM_SECRET: 'test-only-platform-secret', // #398: required unconditionally
    POSTGRES_PASSWORD: 'test-only-postgres', // #410: the dev-only fallback is refused
  };

  it('treats an absent variable as unset', () => {
    const cfg = loadConfig({ ...base });
    expect(cfg.corsOrigins).toBeUndefined();
    expect(cfg.platformAdminIps).toBeUndefined();
  });

  it('treats the blank value compose ships as unset (keeps CORS `*`)', () => {
    const cfg = loadConfig({ ...base, CORS_ORIGINS: '', PLATFORM_ADMIN_IPS: '  ' });
    expect(cfg.corsOrigins).toBeUndefined();
    expect(cfg.platformAdminIps).toBeUndefined();
  });

  it('splits and trims a real list', () => {
    const cfg = loadConfig({
      ...base,
      CORS_ORIGINS: 'https://a.example , https://b.example',
      PLATFORM_ADMIN_IPS: '198.51.100.50,203.0.113.7',
    });
    expect(cfg.corsOrigins).toEqual(['https://a.example', 'https://b.example']);
    expect(cfg.platformAdminIps).toEqual(['198.51.100.50', '203.0.113.7']);
  });

  it('refuses a value that lists no entry instead of silently reopening CORS', () => {
    expect(() => loadConfig({ ...base, CORS_ORIGINS: ',' })).toThrow(/CORS_ORIGINS is set/);
    expect(() => loadConfig({ ...base, PLATFORM_ADMIN_IPS: ',,' })).toThrow(
      /PLATFORM_ADMIN_IPS is set/,
    );
  });
});

/**
 * #398: `JWT_PLATFORM_SECRET` used to fall back to the public constant
 * `'dev-only-platform-secret'` when unset, so any deployment that didn't happen to go through
 * `docker-compose.yml`'s `${JWT_PLATFORM_SECRET:?...}` guard (a bare `node dist/main.js`, a
 * different compose file, a test harness) could boot with a secret anyone can read in this
 * repo's history — enough to forge a platform-admin (HS256) token. It is now required the same
 * way `DATABASE_URL` / `REDIS_CACHE_URL` are: unconditionally, for every instance, matching how
 * `docker-compose.yml`'s shared `x-app-env` already treats it (unlike `JWT_PRIVATE_KEY`, which
 * is api-instance-only there).
 */
describe('loadConfig — JWT_PLATFORM_SECRET is required (#398)', () => {
  const base: NodeJS.ProcessEnv = {
    INSTANCE_ID: 'worker',
    DATABASE_URL: 'postgres://pos_app:pw@localhost:5432/pos',
    REDIS_CACHE_URL: 'redis://localhost:6379',
    REDIS_QUEUE_URL: 'redis://localhost:6380',
    POSTGRES_PASSWORD: 'test-only-postgres', // #410: the dev-only fallback is refused
  };

  it('throws a clear error when JWT_PLATFORM_SECRET is missing', () => {
    expect(() => loadConfig({ ...base })).toThrow(
      /Missing required environment variable JWT_PLATFORM_SECRET/,
    );
  });

  it('throws when JWT_PLATFORM_SECRET is blank', () => {
    expect(() => loadConfig({ ...base, JWT_PLATFORM_SECRET: '' })).toThrow(
      /Missing required environment variable JWT_PLATFORM_SECRET/,
    );
  });

  it('accepts a real value, on a worker instance too (no isApi gate)', () => {
    const cfg = loadConfig({ ...base, JWT_PLATFORM_SECRET: 'a-real-secret' });
    expect(cfg.jwtPlatformSecret).toBe('a-real-secret');
  });
});

/**
 * #410 (follow-up to #398): `server/.env.example` ships public placeholders — `dev-only-*`
 * values and a dummy RS256 pair. They are refused on EVERY boot unless ALLOW_DEV_SECRETS is
 * exactly `true`, independent of NODE_ENV (the Dockerfile sets NODE_ENV=production for the
 * dev compose stack too, so a NODE_ENV gate crash-looped the documented quickstart).
 */
describe('loadConfig — refuses public placeholder secrets unless ALLOW_DEV_SECRETS=true (#410)', () => {
  const envExample = readFileSync(fileURLToPath(new URL('../../.env.example', import.meta.url)), 'utf8');
  const dummy = (name: string): string => {
    const m = envExample.match(new RegExp(`^${name}="([^"]+)"`, 'ms'));
    if (!m) throw new Error(`${name} not found in .env.example`);
    return m[1];
  };
  const base: NodeJS.ProcessEnv = {
    INSTANCE_ID: 'worker',
    DATABASE_URL: 'postgres://pos_app:pw@localhost:5432/pos',
    // Set explicitly so each case isolates one variable — otherwise the POSTGRES_PASSWORD
    // fallback (dev-only-postgres) would fire first.
    DATABASE_ADMIN_URL: 'postgres://postgres:a-real-secret@localhost:5432/pos',
    REDIS_CACHE_URL: 'redis://localhost:6379',
    REDIS_QUEUE_URL: 'redis://localhost:6380',
    JWT_PLATFORM_SECRET: 'a-real-secret',
  };
  const api: NodeJS.ProcessEnv = {
    ...base,
    INSTANCE_ID: 'api-1',
    JWT_PRIVATE_KEY: 'a-real-private-key',
    JWT_PUBLIC_KEYS: 'a-real-public-key',
  };

  it('refuses JWT_PLATFORM_SECRET=dev-only-* whatever NODE_ENV is (unset, test, production)', () => {
    for (const NODE_ENV of [undefined, 'test', 'production']) {
      expect(() =>
        loadConfig({ ...base, NODE_ENV, JWT_PLATFORM_SECRET: 'dev-only-platform-secret' }),
      ).toThrow(/JWT_PLATFORM_SECRET is still the public placeholder/);
    }
  });

  it('refuses the POSTGRES_PASSWORD fallback when DATABASE_ADMIN_URL is unset', () => {
    const { DATABASE_ADMIN_URL: _omit, ...withoutAdminUrl } = base;
    expect(() => loadConfig(withoutAdminUrl)).toThrow(/POSTGRES_PASSWORD is still the public placeholder/);
    expect(() => loadConfig({ ...withoutAdminUrl, POSTGRES_PASSWORD: 'dev-only-postgres' })).toThrow(
      /POSTGRES_PASSWORD/,
    );
  });

  it('does not check POSTGRES_PASSWORD when DATABASE_ADMIN_URL is set (never used)', () => {
    const cfg = loadConfig({ ...base, POSTGRES_PASSWORD: 'dev-only-postgres' });
    expect(cfg.adminDatabaseUrl).toBe('postgres://postgres:a-real-secret@localhost:5432/pos');
  });

  it('refuses ETCD_ROOT_PASSWORD, and names the legacy ETCD_PASSWORD when only that is set', () => {
    expect(() => loadConfig({ ...base, ETCD_ROOT_PASSWORD: 'dev-only-etcd' })).toThrow(
      /ETCD_ROOT_PASSWORD is still the public placeholder/,
    );
    expect(() => loadConfig({ ...base, ETCD_PASSWORD: 'dev-only-etcd' })).toThrow(
      /^ETCD_PASSWORD is still the public placeholder/,
    );
  });

  it('refuses the dummy JWT_PRIVATE_KEY from .env.example, multi-line or \\n-escaped', () => {
    const pem = dummy('JWT_PRIVATE_KEY');
    expect(() => loadConfig({ ...api, JWT_PRIVATE_KEY: pem })).toThrow(/JWT_PRIVATE_KEY is still/);
    expect(() => loadConfig({ ...api, JWT_PRIVATE_KEY: pem.replace(/\n/g, '\\n') })).toThrow(
      /JWT_PRIVATE_KEY is still/,
    );
  });

  it('refuses the dummy public key anywhere in JWT_PUBLIC_KEYS', () => {
    const pem = dummy('JWT_PUBLIC_KEYS');
    expect(() => loadConfig({ ...api, JWT_PUBLIC_KEYS: pem })).toThrow(/JWT_PUBLIC_KEYS is still/);
    const json = JSON.stringify({ 'key-1': 'a-real-public-key', 'key-0': pem.replace(/\n/g, '\\n') });
    expect(() => loadConfig({ ...api, JWT_PUBLIC_KEYS: json })).toThrow(/JWT_PUBLIC_KEYS is still/);
  });

  it('does not read (or check) the JWT keys on a worker instance', () => {
    const cfg = loadConfig({ ...base, JWT_PRIVATE_KEY: dummy('JWT_PRIVATE_KEY') });
    expect(cfg.jwtPrivateKey).toBeUndefined();
  });

  it('never names the value in the error, only the variable', () => {
    let message = '';
    try {
      loadConfig({ ...base, JWT_PLATFORM_SECRET: 'dev-only-platform-secret' });
    } catch (err) {
      message = (err as Error).message;
    }
    expect(message).toMatch(/JWT_PLATFORM_SECRET/);
    expect(message).not.toContain('dev-only-platform-secret');
  });

  it('allows every placeholder when ALLOW_DEV_SECRETS is exactly "true" (local dev / CI)', () => {
    const cfg = loadConfig({
      ...api,
      NODE_ENV: 'production', // what the Dockerfile sets for the dev compose stack too
      ALLOW_DEV_SECRETS: 'true',
      DATABASE_ADMIN_URL: undefined,
      JWT_PLATFORM_SECRET: 'dev-only-platform-secret',
      ETCD_ROOT_PASSWORD: 'dev-only-etcd',
      JWT_PRIVATE_KEY: dummy('JWT_PRIVATE_KEY'),
      JWT_PUBLIC_KEYS: dummy('JWT_PUBLIC_KEYS'),
    });
    expect(cfg.jwtPlatformSecret).toBe('dev-only-platform-secret');
    expect(cfg.adminDatabaseUrl).toContain(':dev-only-postgres@');
  });

  it('treats any other ALLOW_DEV_SECRETS value as not allowed', () => {
    for (const ALLOW_DEV_SECRETS of ['', 'TRUE', '1', 'yes', ' true']) {
      expect(() =>
        loadConfig({ ...base, ALLOW_DEV_SECRETS, JWT_PLATFORM_SECRET: 'dev-only-platform-secret' }),
      ).toThrow(/JWT_PLATFORM_SECRET/);
    }
  });

  it('refuses a dev-only-* password inside each connection URL, naming the variable only', () => {
    const cases: [string, string][] = [
      ['DATABASE_URL', 'postgres://pos_app:dev-only-pos-app@localhost:5432/pos'],
      ['DATABASE_ADMIN_URL', 'postgres://postgres:dev-only-postgres@localhost:5432/pos'],
      ['REDIS_CACHE_URL', 'redis://:dev-only-redis@localhost:6379'],
      ['REDIS_QUEUE_URL', 'redis://:dev-only-redis@localhost:6380'],
    ];
    for (const [name, url] of cases) {
      let message = '';
      try {
        loadConfig({ ...base, [name]: url });
      } catch (err) {
        message = (err as Error).message;
      }
      expect(message).toMatch(new RegExp(`the password in ${name} is still the public placeholder`));
      expect(message).not.toContain('dev-only-');
      expect(() => loadConfig({ ...base, ALLOW_DEV_SECRETS: 'true', [name]: url })).not.toThrow();
    }
  });

  it('percent-decodes the URL password and ignores dev-only- outside the password', () => {
    expect(() =>
      loadConfig({ ...base, REDIS_CACHE_URL: 'redis://:dev%2Donly-redis@localhost:6379' }),
    ).toThrow(/the password in REDIS_CACHE_URL/);
    expect(() =>
      loadConfig({ ...base, DATABASE_URL: 'postgres://dev-only-user:pw@dev-only-host:5432/dev-only-db' }),
    ).not.toThrow();
    // Malformed %-escape: checked raw, not crashed on.
    expect(() => refusePublicSecretInUrl({}, 'REDIS_QUEUE_URL', 'redis://:dev-only-%zz@h:1')).toThrow(
      /REDIS_QUEUE_URL/,
    );
    // Unparseable URL is left to the driver.
    expect(() => refusePublicSecretInUrl({}, 'DATABASE_URL', 'not a url')).not.toThrow();
  });

  it('refuses via the exported helper too (bull-board.ts BULL_BOARD_PASSWORD)', () => {
    expect(() => refusePublicSecret({}, 'BULL_BOARD_PASSWORD', 'dev-only-bull-board')).toThrow(
      /BULL_BOARD_PASSWORD is still the public placeholder/,
    );
    expect(() =>
      refusePublicSecret({ ALLOW_DEV_SECRETS: 'true' }, 'BULL_BOARD_PASSWORD', 'dev-only-bull-board'),
    ).not.toThrow();
    expect(() => refusePublicSecret({}, 'BULL_BOARD_PASSWORD', 'a-real-password')).not.toThrow();
  });
});
