import { Global, Module, Inject } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { TenantService } from '../common/database/tenant.service.js';

export const ADMIN_DATA_SOURCE = Symbol('ADMIN_DATA_SOURCE');
export const AUDIT_DATA_SOURCE = Symbol('AUDIT_DATA_SOURCE');

/**
 * Three TypeORM DataSources per process:
 * 1. Default `DataSource` connects as the non-superuser `pos_app` role (RLS enabled/forced).
 * 2. `ADMIN_DATA_SOURCE` connects as admin/owner (`postgres`) for platform operations (bypasses RLS).
 * 3. `AUDIT_DATA_SOURCE` connects as `pos_app` too, on a tiny pool of its own, for the
 *    audit rows that have to outlive the rollback of the request that produced them.
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
    {
      provide: AUDIT_DATA_SOURCE,
      inject: [APP_CONFIG],
      useFactory: async (cfg: AppConfig) => {
        const ds = new DataSource({
          type: 'postgres',
          // `pos_app`, NOT the admin URL. An audit row is tenant data: written as the
          // owner it would be a row RLS never checked, and a wrong `tenant_id` would
          // land silently in another shop's log instead of being refused.
          url: cfg.databaseUrl,
          synchronize: false,
          migrationsRun: false,
          entities: [],
          // Two, not `cfg.dbPoolSize`. Nothing here is on the path a request follows —
          // it exists so a refusal audit never queues for a connection the request pool
          // owns. The writes are single INSERTs, and the pool opens nothing until the
          // first one, so a process that never refuses a void never connects at all.
          poolSize: 2,
          // Half the request pool's, deliberately: the caller is still holding its own
          // request connection while it waits here, so a saturated audit pool must give
          // up quickly rather than pin that connection for the full 5 s.
          extra: { connectionTimeoutMillis: 2000, idleTimeoutMillis: 30000 },
        });
        return ds.initialize();
      },
    },
    TenantService,
  ],
  exports: [DataSource, ADMIN_DATA_SOURCE, AUDIT_DATA_SOURCE, TenantService],
})
export class DbModule {
  constructor(
    private readonly ds: DataSource,
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
    @Inject(AUDIT_DATA_SOURCE) private readonly auditDs: DataSource,
  ) {}

  async onModuleDestroy() {
    if (this.ds.isInitialized) await this.ds.destroy();
    if (this.adminDs.isInitialized) await this.adminDs.destroy();
    if (this.auditDs.isInitialized) await this.auditDs.destroy();
  }
}
