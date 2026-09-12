import { NestFactory } from '@nestjs/core';
import { WorkerModule } from './app.module.js';
import { createLogger, PinoNestLogger } from './common/logger.js';
import { loadConfig } from './config/config.js';

const config = loadConfig();
const logger = createLogger({
  level: config.logLevel,
  instanceId: config.instanceId,
});

const app = await NestFactory.createApplicationContext(
  WorkerModule.forRoot(config, logger),
  {
    logger: new PinoNestLogger(logger),
  },
);
app.enableShutdownHooks();
logger.info('worker ready (BullMQ queues registered: sale-post, inventory, maintenance, backup, dlq)');
