import { NestFactory } from '@nestjs/core';
import type { Server } from 'node:http';
import { AppModule } from './app.module.js';
import { configureApp } from './app.setup.js';
import { createLogger, PinoNestLogger } from './common/logger.js';
import { loadConfig } from './config/config.js';
import type { Redis } from 'ioredis';
import { REDIS_CACHE } from './infra/redis.module.js';
import {
  describeSyncError,
  parsePlatformAdmins,
  syncPlatformAdmins,
  type PlatformAdminSyncResult,
} from './db/platform-admins-env.js';

const config = loadConfig();
const logger = createLogger({
  level: config.logLevel,
  instanceId: config.instanceId,
});

// PLATFORM_ADMINS (#443): upsert env-listed platform admins before anything listens. Only
// this entry point runs it — worker.ts / bull-board.ts never do. Parsed here, not in
// AppConfig, so the plaintext never sits in APP_CONFIG, and dropped from process.env once
// used. Any failure — a bad entry, Postgres down — logs only the message/code
// (`describeSyncError`: never the hash-bearing query parameters) and exits 1, so compose's
// restart policy retries the boot.
let platformAdminResults: PlatformAdminSyncResult[] = [];
try {
  const admins = parsePlatformAdmins(process.env.PLATFORM_ADMINS);
  if (admins) {
    platformAdminResults = await syncPlatformAdmins(config.adminDatabaseUrl, admins);
    logger.info({ platformAdmins: platformAdminResults }, 'PLATFORM_ADMINS synced');
  }
} catch (err) {
  logger.fatal({ err: describeSyncError(err) }, 'PLATFORM_ADMINS sync failed — refusing to boot');
  process.exit(1);
}
delete process.env.PLATFORM_ADMINS;

const app = await NestFactory.create(AppModule.forRoot(config, logger), {
  logger: new PinoNestLogger(logger),
});
await configureApp(app, logger);

// A re-hashed admin's cached "exists" verdict carries no password cutoff: drop it so
// PlatformAuthGuard re-reads password_changed_at on the next request (fail-open like every
// other use of redis-cache — at worst the old verdict lives out its 60 s TTL).
for (const r of platformAdminResults.filter((x) => x.action === 'updated')) {
  await app
    .get<Redis>(REDIS_CACHE)
    .del(`pa:${r.id}:exists`)
    .catch((err: Error) => logger.warn({ err: err.message }, 'could not drop pa:*:exists cache'));
}

// Keep-alive must outlive Nginx's upstream keepalive (60s) or Nginx reuses a
// socket Node just closed and answers 502.
const server = app.getHttpServer() as Server;
server.keepAliveTimeout = 65_000;
server.headersTimeout = 66_000;

await app.listen(config.port, '0.0.0.0');
logger.info({ port: config.port }, 'api listening');
