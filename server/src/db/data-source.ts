import { DataSource } from 'typeorm';
import { InitialSchema1788652800000 } from './migrations/1788652800000-InitialSchema.js';
import { RowLevelSecurity1788652800001 } from './migrations/1788652800001-RowLevelSecurity.js';
import { AuthSecurityDefinerAndAuditFix1788652800002 } from './migrations/1788652800002-AuthSecurityDefinerAndAuditFix.js';
import { MovementsVoidType1788652800003 } from './migrations/1788652800003-MovementsVoidType.js';
import { ReturnItemsCostAtSale1788652800004 } from './migrations/1788652800004-ReturnItemsCostAtSale.js';

/** Static list — no glob, so it survives the dist/ build unchanged. Append new migrations here. */
export const MIGRATIONS = [
  InitialSchema1788652800000,
  RowLevelSecurity1788652800001,
  AuthSecurityDefinerAndAuditFix1788652800002,
  MovementsVoidType1788652800003,
  ReturnItemsCostAtSale1788652800004,
];

/**
 * DataSource used only to run migrations. Connect as the table owner (`postgres`),
 * never as `pos_app`. `synchronize` is never true anywhere — the schema exists only
 * through these migrations, in every environment including tests (#15).
 */
export function createMigrationDataSource(url: string): DataSource {
  return new DataSource({
    type: 'postgres',
    url,
    synchronize: false,
    migrationsRun: false,
    migrationsTransactionMode: 'each',
    entities: [],
    migrations: MIGRATIONS,
    poolSize: 1,
  });
}
