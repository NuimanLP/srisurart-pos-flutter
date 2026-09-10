import { Module, type DynamicModule } from '@nestjs/common';
import type { Logger } from 'pino';
import { APP_CONFIG, type AppConfig } from './config/config.js';
import { HealthModule } from './health/health.module.js';
import { DbModule } from './infra/db.module.js';
import { LOGGER } from './infra/logger.provider.js';
import { RedisModule } from './infra/redis.module.js';
import { AuditModule } from './audit/audit.module.js';
import { AuthModule } from './auth/auth.module.js';

/** Shared infrastructure (config, logger, Postgres, both Redis) — no HTTP. */
@Module({})
export class CoreModule {
  static forRoot(config: AppConfig, logger: Logger): DynamicModule {
    return {
      module: CoreModule,
      global: true,
      providers: [
        { provide: APP_CONFIG, useValue: config },
        { provide: LOGGER, useValue: logger },
      ],
      exports: [APP_CONFIG, LOGGER],
    };
  }
}

/** The HTTP application: core + health. Business modules are added by later tickets. */
@Module({})
export class AppModule {
  static forRoot(config: AppConfig, logger: Logger): DynamicModule {
    return {
      module: AppModule,
      imports: [
        CoreModule.forRoot(config, logger),
        DbModule,
        RedisModule,
        HealthModule,
        AuditModule,
        AuthModule,
      ],
    };
  }
}

/** The BullMQ worker process: core only. Processors arrive with #35. */
@Module({})
export class WorkerModule {
  static forRoot(config: AppConfig, logger: Logger): DynamicModule {
    return {
      module: WorkerModule,
      imports: [CoreModule.forRoot(config, logger), DbModule, RedisModule],
    };
  }
}
