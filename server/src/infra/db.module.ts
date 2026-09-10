import { Global, Module } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { TenantService } from '../common/database/tenant.service.js';

/**
 * One TypeORM DataSource per process, connected as the non-superuser
 * `pos_app` role. `synchronize` is never true — schema comes only from
 * migrations (#15), run as a separate compose job.
 */
@Global()
@Module({
  providers: [
    {
      provide: DataSource,
      inject: [APP_CONFIG],
      useFactory: async (cfg: AppConfig) => {
        const ds = new DataSource({
          type: 'postgres',
          url: cfg.databaseUrl,
          synchronize: false,
          migrationsRun: false,
          entities: [],
          poolSize: cfg.dbPoolSize,
          extra: { connectionTimeoutMillis: 5000, idleTimeoutMillis: 30000 },
        });
        return ds.initialize();
      },
    },
    TenantService,
  ],
  exports: [DataSource, TenantService],
})
export class DbModule {
  constructor(private readonly ds: DataSource) {}
  async onModuleDestroy() {
    if (this.ds.isInitialized) await this.ds.destroy();
  }
}
