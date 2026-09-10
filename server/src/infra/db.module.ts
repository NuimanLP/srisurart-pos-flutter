import { Global, Module, Inject } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { APP_CONFIG, type AppConfig } from '../config/config.js';

export const ADMIN_DATA_SOURCE = Symbol('ADMIN_DATA_SOURCE');

/**
 * Two TypeORM DataSources per process:
 * 1. Default `DataSource` connects as the non-superuser `pos_app` role (RLS enabled/forced).
 * 2. `ADMIN_DATA_SOURCE` connects as admin/owner (`postgres`) for platform operations (bypasses RLS).
 * `synchronize` is never true — schema comes only from migrations (#15).
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
    {
      provide: ADMIN_DATA_SOURCE,
      inject: [APP_CONFIG],
      useFactory: async (cfg: AppConfig) => {
        const ds = new DataSource({
          type: 'postgres',
          url: cfg.adminDatabaseUrl,
          synchronize: false,
          migrationsRun: false,
          entities: [],
          poolSize: cfg.dbPoolSize,
          extra: { connectionTimeoutMillis: 5000, idleTimeoutMillis: 30000 },
        });
        return ds.initialize();
      },
    },
  ],
  exports: [DataSource, ADMIN_DATA_SOURCE],
})
export class DbModule {
  constructor(
    private readonly ds: DataSource,
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
  ) {}

  async onModuleDestroy() {
    if (this.ds.isInitialized) await this.ds.destroy();
    if (this.adminDs.isInitialized) await this.adminDs.destroy();
  }
}

