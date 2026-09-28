import { NestFactory } from '@nestjs/core';
import type { Server } from 'node:http';
import { AppModule } from './app.module.js';
import { configureApp } from './app.setup.js';
import { createLogger, PinoNestLogger } from './common/logger.js';
import { loadConfig } from './config/config.js';
import { syncPlatformAdmins } from './db/platform-admins-env.js';

const config = loadConfig();
const logger = createLogger({
  level: config.logLevel,
  instanceId: config.instanceId,
});

// PLATFORM_ADMINS (#443): upsert env-listed platform admins before anything listens. Only
// this entry point runs it — worker.ts / bull-board.ts never do. A failure fails the boot.
if (config.platformAdmins) {
  const results = await syncPlatformAdmins(config.adminDatabaseUrl, config.platformAdmins);
  logger.info({ platformAdmins: results }, 'PLATFORM_ADMINS synced');
}

const app = await NestFactory.create(AppModule.forRoot(config, logger), {
  logger: new PinoNestLogger(logger),
});
await configureApp(app, logger);

// Keep-alive must outlive Nginx's upstream keepalive (60s) or Nginx reuses a
// socket Node just closed and answers 502.
const server = app.getHttpServer() as Server;
server.keepAliveTimeout = 65_000;
server.headersTimeout = 66_000;

await app.listen(config.port, '0.0.0.0');
logger.info({ port: config.port }, 'api listening');
