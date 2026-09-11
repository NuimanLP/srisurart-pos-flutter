import {
  Module,
  RequestMethod,
  type DynamicModule,
  type MiddlewareConsumer,
  type NestModule,
} from '@nestjs/common';
import type { Logger } from 'pino';
import { APP_CONFIG, type AppConfig } from './config/config.js';
import { HealthModule } from './health/health.module.js';
import { DbModule } from './infra/db.module.js';
import { LOGGER } from './infra/logger.provider.js';
import { RedisModule } from './infra/redis.module.js';
import { AuditModule } from './audit/audit.module.js';
import { AuthModule } from './auth/auth.module.js';
import { PlatformModule } from './platform/platform.module.js';
import { RateLimitModule } from './rate-limit/rate-limit.module.js';
import { RequestContextMiddleware } from './common/request-context.middleware.js';
import { ReturnsController } from './returns/returns.controller.js';
import { ReturnsModule } from './returns/returns.module.js';
import { SalesController } from './sales/sales.controller.js';
import { SalesModule } from './sales/sales.module.js';
import { ShiftsController } from './shifts/shifts.controller.js';
import { ShiftsModule } from './shifts/shifts.module.js';

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

/**
 * Routes that need the request transaction — exactly those carrying `TenantGuard`,
 * whose `SET LOCAL app.tenant_id` has nowhere else to live.
 *
 * `AuthController` is listed by route, not as a controller: only `GET /auth/me` has
 * the guard. `/auth/token` and `/auth/refresh` would otherwise pin an idle-in-
 * transaction connection across an argon2 verify, on the one endpoint that sees a
 * thundering herd after a restart.
 */
const TENANT_ROUTES = [
  { path: 'auth/me', method: RequestMethod.GET },
  SalesController,
  ReturnsController,
  ShiftsController,
];

/** The HTTP application: core + health + platform. Business modules are added by later tickets. */
@Module({})
export class AppModule implements NestModule {
  /**
   * Every tenant-facing route runs inside a transaction opened before the guards,
   * because `SET LOCAL app.tenant_id` — the guard's job, ADR-0003 — only exists
   * inside one. `/health/*` and `/platform/*` are excluded: they have no tenant,
   * and a transaction per liveness probe is a pool slot spent on nothing.
   */
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(RequestContextMiddleware).forRoutes(...TENANT_ROUTES);
  }

  static forRoot(config: AppConfig, logger: Logger): DynamicModule {
    return {
      module: AppModule,
      imports: [
        CoreModule.forRoot(config, logger),
        DbModule,
        RedisModule,
        HealthModule,
        PlatformModule,
        AuditModule,
        AuthModule,
        RateLimitModule,
        SalesModule,
        ReturnsModule,
        ShiftsModule,
      ],
      providers: [RequestContextMiddleware],
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
