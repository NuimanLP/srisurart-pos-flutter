import { describe, it, expect } from 'vitest';
import { loadConfig } from './config.js';

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
