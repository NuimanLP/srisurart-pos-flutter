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
  jwtPlatformSecret: string;
  jwtTenantSecret: string;
}

export const APP_CONFIG = Symbol('APP_CONFIG');

function required(env: NodeJS.ProcessEnv, name: string): string {
  const v = env[name];
  if (!v) throw new Error(`Missing required environment variable ${name}`);
  return v;
}

export function loadConfig(env = process.env): AppConfig {
  const dbUrl = required(env, 'DATABASE_URL');
  const adminDbUrl =
    env.DATABASE_ADMIN_URL ??
    dbUrl.replace(
      /\/\/[^@]*@/,
      `//${env.POSTGRES_USER ?? 'postgres'}:${env.POSTGRES_PASSWORD ?? 'dev-only-postgres'}@`,
    );

  return {
    port: Number(env.PORT ?? 3000),
    instanceId: env.INSTANCE_ID ?? 'local',
    logLevel: env.LOG_LEVEL ?? 'info',
    databaseUrl: dbUrl,
    adminDatabaseUrl: adminDbUrl,
    dbPoolSize: Number(env.DB_POOL_SIZE ?? 5),
    redisCacheUrl: required(env, 'REDIS_CACHE_URL'),
    redisQueueUrl: required(env, 'REDIS_QUEUE_URL'),
    jwtPlatformSecret: env.JWT_PLATFORM_SECRET ?? 'dev-only-platform-secret',
    jwtTenantSecret: env.JWT_TENANT_SECRET ?? 'dev-only-tenant-secret',
  };
}

