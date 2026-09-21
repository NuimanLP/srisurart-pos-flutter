import {
  Module,
  type DynamicModule,
  type MiddlewareConsumer,
  type NestModule,
} from '@nestjs/common';
import type { Logger } from 'pino';
import { APP_CONFIG, type AppConfig } from './config/config.js';
import { HealthModule } from './health/health.module.js';
import { MetricsModule } from './metrics/metrics.module.js';
import { DbModule } from './infra/db.module.js';
import { LOGGER } from './infra/logger.provider.js';
import { RedisModule } from './infra/redis.module.js';
import { TenantCacheModule } from './infra/tenant-cache.module.js';
import { AuditModule } from './audit/audit.module.js';
import { AuthModule } from './auth/auth.module.js';
import { PlatformModule } from './platform/platform.module.js';
import { RateLimitModule } from './rate-limit/rate-limit.module.js';
import { TenantScopeMiddleware } from './common/tenant-scope.middleware.js';
import { ReturnsModule } from './returns/returns.module.js';
import { SalesModule } from './sales/sales.module.js';
import { ShiftsModule } from './shifts/shifts.module.js';
import { CustomersModule } from './customers/customers.module.js';
import { MechanicsModule } from './mechanics/mechanics.module.js';
import { SettingsModule } from './settings/settings.module.js';
import { ReportsModule } from './reports/reports.module.js';
import {
  QueueModule,
  QueueProcessorsModule,
  QueueSchedulerModule,
} from './queue/queue.module.js';
import { QuotesModule } from './quotes/quotes.module.js';
import { ParkedSalesModule } from './parked-sales/parked-sales.module.js';
import { BackupModule } from './backup/backup.module.js';
import { ProductsModule } from './products/products.module.js';
import { PurchasingModule } from './purchasing/purchasing.module.js';
import { DevicesModule } from './devices/devices.module.js';
import { ReviewItemsModule } from './review-items/review-items.module.js';
import { SyncModule } from './sync/sync.module.js';

import { RuntimeConfigService } from './config/runtime-config.service.js';

/** Shared infrastructure (config, logger, Postgres, both Redis, runtime config) — no HTTP. */
@Module({})
export class CoreModule {
  static forRoot(config: AppConfig, logger: Logger): DynamicModule {
    return {
      module: CoreModule,
      global: true,
      providers: [
        { provide: APP_CONFIG, useValue: config },
        { provide: LOGGER, useValue: logger },
        RuntimeConfigService,
      ],
      exports: [APP_CONFIG, LOGGER, RuntimeConfigService],
    };
  }
}

/** The HTTP application: core + health + platform. Business modules are added by later tickets. */
@Module({})
export class AppModule implements NestModule {
  /**
   * Every route gets a request scope, and nothing more: `TenantScopeMiddleware` opens no
   * transaction and touches no database (ADR-0003 addendum, tx.4 #153). `TenantGuard`
   * names the tenant on the scope and each handler's `TenantService.runTx` opens its own
   * transaction, so a new controller needs no entry here.
   */
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(TenantScopeMiddleware).forRoutes('*');
  }

  static forRoot(config: AppConfig, logger: Logger): DynamicModule {
    return {
      module: AppModule,
      imports: [
        CoreModule.forRoot(config, logger),
        DbModule,
        RedisModule,
        TenantCacheModule,
        HealthModule,
        MetricsModule,
        PlatformModule,
        AuditModule,
        AuthModule,
        RateLimitModule,
        SalesModule,
        ReturnsModule,
        ShiftsModule,
        CustomersModule,
        MechanicsModule,
        SettingsModule,
        ReportsModule,
        QueueModule,
        QuotesModule,
        ParkedSalesModule,
        BackupModule,
        ProductsModule,
        PurchasingModule,
        DevicesModule,
        ReviewItemsModule,
        SyncModule,
      ],
    };
  }
}

/** The BullMQ worker process: core + db + redis + queue. Processors arrive with #35. */
@Module({})
export class WorkerModule {
  static forRoot(config: AppConfig, logger: Logger): DynamicModule {
    return {
      module: WorkerModule,
      imports: [
        CoreModule.forRoot(config, logger),
        DbModule,
        RedisModule,
        // #239: TenantImportProcessor's TenantImportService invalidates the products/
        // categories/customers/mechanics/settings cache after a committed import, exactly
        // like the synchronous endpoint always did.
        TenantCacheModule,
        QueueModule,
        QueueProcessorsModule,
        QueueSchedulerModule,
      ],
    };
  }
}
