import { createHash } from 'node:crypto';

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
 * sha256 of the dummy RS256 pair `server/.env.example` ships (JWT_PRIVATE_KEY / JWT_PUBLIC_KEYS),
 * taken over the PEM with whitespace and literal `\n` / `\r` escapes removed — a hash, so the key
 * material is not copied into src. That private key is public in this repo's history: trusting
 * either half lets anyone forge a tenant token.
 */
const PUBLIC_DUMMY_KEY_SHA256 = new Set([
  'd65b21f4fac0719ba91f5060027add194b90785095c15eb96a13fbf70b890ef6', // JWT_PRIVATE_KEY
  '9de63fe69c04d6eef2bec3fd421384a73c62b9523da916051cf6e15bd8b33e07', // JWT_PUBLIC_KEYS
]);

function isPublicDummyKey(pem: string): boolean {
  const normalized = pem.replace(/\\[rn]/g, '').replace(/\s/g, '');
  return PUBLIC_DUMMY_KEY_SHA256.has(createHash('sha256').update(normalized).digest('hex'));
}

/**
 * #410 (follow-up to #398): `server/.env.example` ships public placeholder secrets
 * (`dev-only-*` values and a dummy RS256 pair) so `cp .env.example .env` boots local dev / CI
 * without setup. They are public in this repo's history, so a process holding one refuses to
 * boot unless `ALLOW_DEV_SECRETS` is exactly `true` — set only by `.env.example` and the e2e
 * vitest config, never on a real host. Deliberately NOT keyed off `NODE_ENV`: the Dockerfile
 * sets `NODE_ENV=production` unconditionally, so the dev compose stack is "production" too.
 *
 * Checked: POSTGRES_PASSWORD (only when it builds `adminDatabaseUrl`), JWT_PLATFORM_SECRET,
 * ETCD_ROOT_PASSWORD / legacy ETCD_PASSWORD, JWT_PRIVATE_KEY / JWT_PUBLIC_KEYS (api instances),
 * BULL_BOARD_PASSWORD (`bull-board.ts`), and the password inside DATABASE_URL /
 * DATABASE_ADMIN_URL / REDIS_CACHE_URL / REDIS_QUEUE_URL (`refusePublicSecretInUrl`) — the only
 * way POS_APP_PASSWORD / REDIS_PASSWORD reach this process. Not checked: GRAFANA_* / K6_* never
 * reach `server/src`. The error names the variable, never the value.
 */
export function refusePublicSecret(
  env: NodeJS.ProcessEnv,
  name: string,
  value: string | undefined,
): void {
  if (value === undefined || env.ALLOW_DEV_SECRETS === 'true') return;
  if (value.startsWith(DEV_ONLY_PREFIX) || isPublicDummyKey(value)) {
    throw new Error(
      `${name} is still the public placeholder from server/.env.example — refusing to boot. ` +
        `Set a real value for ${name} (ALLOW_DEV_SECRETS=true is for a local dev/CI stack only).`,
    );
  }
}

/**
 * `refusePublicSecret` for the password component of a connection URL (`postgres://u:pw@…`,
 * `redis://:pw@…`), percent-decoded. An unparseable URL is left to the driver to reject.
 */
export function refusePublicSecretInUrl(
  env: NodeJS.ProcessEnv,
  name: string,
  url: string | undefined,
): void {
  if (url === undefined || env.ALLOW_DEV_SECRETS === 'true') return;
  let password: string;
  try {
    password = new URL(url).password;
  } catch {
    return;
  }
  try {
    password = decodeURIComponent(password);
  } catch {
    // malformed %-escape: check the raw form
  }
  refusePublicSecret(env, `the password in ${name}`, password);
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
  refusePublicSecretInUrl(env, 'DATABASE_URL', dbUrl);
  let adminDbUrl = env.DATABASE_ADMIN_URL;
  refusePublicSecretInUrl(env, 'DATABASE_ADMIN_URL', adminDbUrl);
  if (adminDbUrl === undefined) {
    const postgresPassword = env.POSTGRES_PASSWORD ?? 'dev-only-postgres';
    refusePublicSecret(env, 'POSTGRES_PASSWORD', postgresPassword);
    adminDbUrl = dbUrl.replace(
      /\/\/[^@]*@/,
      `//${env.POSTGRES_USER ?? 'postgres'}:${postgresPassword}@`,
    );
  }

  const redisCacheUrl = required(env, 'REDIS_CACHE_URL');
  refusePublicSecretInUrl(env, 'REDIS_CACHE_URL', redisCacheUrl);
  const redisQueueUrl = required(env, 'REDIS_QUEUE_URL');
  refusePublicSecretInUrl(env, 'REDIS_QUEUE_URL', redisQueueUrl);

  const jwtPlatformSecret = required(env, 'JWT_PLATFORM_SECRET');
  refusePublicSecret(env, 'JWT_PLATFORM_SECRET', jwtPlatformSecret);

  // Name whichever variable actually supplied the value — ETCD_PASSWORD is the legacy name
  // (etcdPassword falls back to it), so a placeholder reaching config only through ETCD_PASSWORD
  // must not be reported as ETCD_ROOT_PASSWORD, a variable that was never even read.
  if (env.ETCD_ROOT_PASSWORD !== undefined) {
    refusePublicSecret(env, 'ETCD_ROOT_PASSWORD', env.ETCD_ROOT_PASSWORD);
  } else if (env.ETCD_PASSWORD !== undefined) {
    refusePublicSecret(env, 'ETCD_PASSWORD', env.ETCD_PASSWORD);
  }
  const etcdPassword = env.ETCD_ROOT_PASSWORD ?? env.ETCD_PASSWORD;

  const jwtPrivateKey = isApi ? required(env, 'JWT_PRIVATE_KEY') : undefined;
  refusePublicSecret(env, 'JWT_PRIVATE_KEY', jwtPrivateKey);
  const jwtPublicKeys = isApi ? parsePublicKeys(required(env, 'JWT_PUBLIC_KEYS')) : undefined;
  for (const key of jwtPublicKeys ?? []) refusePublicSecret(env, 'JWT_PUBLIC_KEYS', key);

  return {
    port: Number(env.PORT ?? 3000),
    instanceId,
    logLevel: env.LOG_LEVEL ?? 'info',
    databaseUrl: dbUrl,
    adminDatabaseUrl: adminDbUrl,
    dbPoolSize: Number(env.DB_POOL_SIZE ?? 5),
    redisCacheUrl,
    redisQueueUrl,
    redisCommandTimeoutMs: positiveInt(env, 'REDIS_COMMAND_TIMEOUT_MS', 1000),
    jwtPlatformSecret,
    jwtPrivateKey,
    jwtPublicKeys,
    jwtKeyId: env.JWT_KEY_ID ?? 'key-1',
    corsOrigins: csvAllowlist(env, 'CORS_ORIGINS'),
    etcdUrl: env.ETCD_URL,
    etcdPassword,
    platformAdminIps: csvAllowlist(env, 'PLATFORM_ADMIN_IPS'),
    docNumberFallback: env.DOC_NUMBER_FALLBACK !== 'false',
  };
}
