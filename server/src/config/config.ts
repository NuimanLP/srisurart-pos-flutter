export interface AppConfig {
  port: number;
  instanceId: string;
  logLevel: string;
  databaseUrl: string;
  adminDatabaseUrl: string;
  /** Per-process pool size. instances × poolSize must stay ≤ 80% of max_connections. */
  dbPoolSize: number;
  redisCacheUrl: string;
  redisQueueUrl: string;
  /**
   * ioredis `commandTimeout` for the app's own Redis clients (#140). A timed-out command
   * fails open exactly like a dropped connection. Not applied to BullMQ's connections.
   */
  redisCommandTimeoutMs: number;
  jwtPlatformSecret: string;
  /** Required only for API instances handling /auth/* (ADR-0009). */
  jwtPrivateKey?: string;
  /** Required only for API instances handling /auth/* and API validation. */
  jwtPublicKeys?: string[];
  /** Optional active signing key ID (defaults to 'key-1'). */
  jwtKeyId?: string;
  /** Allowed CORS origins (defaults to '*' or localhost in dev). */
  corsOrigins?: string[];
  /** Optional etcd URL for dynamic runtime config (ADR-0013, 07_CICD_DEPLOY §8). */
  etcdUrl?: string;
  /** Optional etcd root password. */
  etcdPassword?: string;
  /** Optional allowlist of admin IPs allowed to access /api/v1/platform (slice 24 / #270). */
  platformAdminIps?: string[];
  /** Whether the server falls back to issuing RC/CN when omitted by client (C16, default: true). */
  docNumberFallback?: boolean;
}

export const APP_CONFIG = Symbol('APP_CONFIG');

function required(env: NodeJS.ProcessEnv, name: string): string {
  const v = env[name];
  if (!v) throw new Error(`Missing required environment variable ${name}`);
  return v;
}

const DEV_ONLY_PREFIX = 'dev-only-';

/**
 * #410 (follow-up to #398): `server/.env.example` ships public `dev-only-*` placeholder
 * secrets so `cp .env.example .env` boots local dev / CI without any setup. That is fine on
 * a laptop or in CI, but the exact same placeholder is public in this repo's history, so it
 * must never be trusted on a real deployment. Dockerfile's runtime stage sets
 * `NODE_ENV=production` unconditionally — that is the only boot-time signal this repo already
 * has for "this is a real deployment, not a test run" (vitest sets `NODE_ENV=test`; nothing
 * sets `development`). Refuses only when both the value looks like a shipped placeholder AND
 * we're in that production boot — local dev / CI (`NODE_ENV` unset or `test`) is unaffected.
 *
 * Decision, per `dev-only-*` value `server/.env.example` ships (full table in #410's PR):
 * checked here — JWT_PLATFORM_SECRET, POSTGRES_PASSWORD (builds `adminDatabaseUrl`),
 * ETCD_ROOT_PASSWORD / the legacy ETCD_PASSWORD — because these are the only ones this file
 * reads as a named scalar env var. Not checked: POS_APP_PASSWORD and REDIS_PASSWORD are
 * compose-only — `docker-compose.yml`'s `x-app-env` bakes them into `DATABASE_URL` /
 * `REDIS_CACHE_URL` / `REDIS_QUEUE_URL` before this process ever starts, so this file never
 * sees either name, only the already-built URL (parsing a password substring out of a
 * connection URI is a different, riskier check, deferred); BULL_BOARD_PASSWORD is read by
 * `bull-board.ts`, not this file; GRAFANA_ADMIN_PASSWORD and K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD
 * are consumed only by compose/Nginx, never by any `server/src` code.
 */
function refuseDevOnlyValue(env: NodeJS.ProcessEnv, name: string, value: string | undefined): void {
  if (value !== undefined && value.startsWith(DEV_ONLY_PREFIX) && env.NODE_ENV === 'production') {
    throw new Error(
      `${name} is still the placeholder value from server/.env.example — refusing to boot ` +
        `with NODE_ENV=production. Set a real value for ${name}.`,
    );
  }
}

/**
 * A positive integer, or `fallback` when unset. Refuses `0` and garbage outright: ioredis
 * takes any number as a timeout, so `0` or `NaN` would time every command out at once.
 */
function positiveInt(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    throw new Error(`${name} must be a positive integer (milliseconds), got '${raw}'`);
  }
  return n;
}

/**
 * A comma-separated allowlist, or `undefined` when the variable is absent or blank.
 *
 * Compose always *sets* these (`${KEY:-}` in docker-compose.yml's `x-app-env`, #367), so blank
 * has to mean "unset" — that is what keeps the historical default (CORS `'*'`, platform
 * allowlist = loopback only). But a value with content that yields no entry — `","`, `";"`,
 * `",,"` — is a typo, and silently degrading it to `undefined` would reopen CORS to `'*'` with
 * nothing in the log to say so. Validate first, then fall back (CLAUDE.md, learned at #22/#24).
 */
function csvAllowlist(env: NodeJS.ProcessEnv, name: string): string[] | undefined {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return undefined;
  const items = raw
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean);
  if (items.length === 0) {
    throw new Error(`${name} is set but lists no entry (got '${raw}') — leave it empty to disable`);
  }
  return items;
}

function parsePublicKeys(raw: string): string[] {
  const trimmed = raw.trim();
  if (trimmed.startsWith('{')) {
    try {
      const parsed = JSON.parse(trimmed) as Record<string, string>;
      return Object.values(parsed);
    } catch {
      // fallback to split
    }
  }
  return trimmed.split(',').map((k) => k.trim());
}

export function loadConfig(env = process.env): AppConfig {
  const instanceId = env.INSTANCE_ID ?? 'local';
  const isApi = instanceId.startsWith('api') || instanceId === 'local';
  const dbUrl = required(env, 'DATABASE_URL');
  let adminDbUrl = env.DATABASE_ADMIN_URL;
  if (adminDbUrl === undefined) {
    const postgresPassword = env.POSTGRES_PASSWORD ?? 'dev-only-postgres';
    refuseDevOnlyValue(env, 'POSTGRES_PASSWORD', postgresPassword);
    adminDbUrl = dbUrl.replace(
      /\/\/[^@]*@/,
      `//${env.POSTGRES_USER ?? 'postgres'}:${postgresPassword}@`,
    );
  }

  const jwtPlatformSecret = required(env, 'JWT_PLATFORM_SECRET');
  refuseDevOnlyValue(env, 'JWT_PLATFORM_SECRET', jwtPlatformSecret);

  // Name whichever variable actually supplied the value — ETCD_PASSWORD is the legacy name
  // (etcdPassword falls back to it), so a placeholder reaching config only through ETCD_PASSWORD
  // must not be reported as ETCD_ROOT_PASSWORD, a variable that was never even read.
  if (env.ETCD_ROOT_PASSWORD !== undefined) {
    refuseDevOnlyValue(env, 'ETCD_ROOT_PASSWORD', env.ETCD_ROOT_PASSWORD);
  } else if (env.ETCD_PASSWORD !== undefined) {
    refuseDevOnlyValue(env, 'ETCD_PASSWORD', env.ETCD_PASSWORD);
  }
  const etcdPassword = env.ETCD_ROOT_PASSWORD ?? env.ETCD_PASSWORD;

  return {
    port: Number(env.PORT ?? 3000),
    instanceId,
    logLevel: env.LOG_LEVEL ?? 'info',
    databaseUrl: dbUrl,
    adminDatabaseUrl: adminDbUrl,
    dbPoolSize: Number(env.DB_POOL_SIZE ?? 5),
    redisCacheUrl: required(env, 'REDIS_CACHE_URL'),
    redisQueueUrl: required(env, 'REDIS_QUEUE_URL'),
    redisCommandTimeoutMs: positiveInt(env, 'REDIS_COMMAND_TIMEOUT_MS', 1000),
    jwtPlatformSecret,
    jwtPrivateKey: isApi ? required(env, 'JWT_PRIVATE_KEY') : undefined,
    jwtPublicKeys: isApi ? parsePublicKeys(required(env, 'JWT_PUBLIC_KEYS')) : undefined,
    jwtKeyId: env.JWT_KEY_ID ?? 'key-1',
    corsOrigins: csvAllowlist(env, 'CORS_ORIGINS'),
    etcdUrl: env.ETCD_URL,
    etcdPassword,
    platformAdminIps: csvAllowlist(env, 'PLATFORM_ADMIN_IPS'),
    docNumberFallback: env.DOC_NUMBER_FALLBACK !== 'false',
  };
}
