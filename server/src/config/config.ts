export interface AppConfig {
  port: number;
  instanceId: string;
  logLevel: string;
  databaseUrl: string;
  /** Per-process pool size. instances × poolSize must stay ≤ 80% of max_connections. */
  dbPoolSize: number;
  redisCacheUrl: string;
  redisQueueUrl: string;
  /** Required only for API instances handling /auth/* (ADR-0009). */
  jwtPrivateKey?: string;
  /** Required only for API instances handling /auth/* and API validation. */
  jwtPublicKeys?: string[];
  /** Optional active signing key ID (defaults to 'key-1'). */
  jwtKeyId?: string;
}

export const APP_CONFIG = Symbol('APP_CONFIG');

function required(env: NodeJS.ProcessEnv, name: string): string {
  const v = env[name];
  if (!v) throw new Error(`Missing required environment variable ${name}`);
  return v;
}

export function loadConfig(env = process.env): AppConfig {
  const instanceId = env.INSTANCE_ID ?? 'local';
  const isApi = instanceId.startsWith('api') || instanceId === 'local';

  return {
    port: Number(env.PORT ?? 3000),
    instanceId,
    logLevel: env.LOG_LEVEL ?? 'info',
    databaseUrl: required(env, 'DATABASE_URL'),
    dbPoolSize: Number(env.DB_POOL_SIZE ?? 5),
    redisCacheUrl: required(env, 'REDIS_CACHE_URL'),
    redisQueueUrl: required(env, 'REDIS_QUEUE_URL'),
    jwtPrivateKey: isApi ? required(env, 'JWT_PRIVATE_KEY') : undefined,
    jwtPublicKeys: isApi ? required(env, 'JWT_PUBLIC_KEYS').split(',').map(k => k.trim()) : undefined,
    jwtKeyId: env.JWT_KEY_ID ?? 'key-1',
  };
}
