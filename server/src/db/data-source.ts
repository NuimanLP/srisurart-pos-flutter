import { DataSource } from 'typeorm';
import { InitialSchema1788652800000 } from './migrations/1788652800000-InitialSchema.js';
import { RowLevelSecurity1788652800001 } from './migrations/1788652800001-RowLevelSecurity.js';
import { AuthSecurityDefinerAndAuditFix1788652800002 } from './migrations/1788652800002-AuthSecurityDefinerAndAuditFix.js';
import { MovementsVoidType1788652800003 } from './migrations/1788652800003-MovementsVoidType.js';
import { ReturnItemsCostAtSale1788652800004 } from './migrations/1788652800004-ReturnItemsCostAtSale.js';
import { CreditPaymentsMethodAndShift1788652800005 } from './migrations/1788652800005-CreditPaymentsMethodAndShift.js';
import { ReturnsShiftIndex1788652800006 } from './migrations/1788652800006-ReturnsShiftIndex.js';
import { ProductsPartNoCaseInsensitive1788652800007 } from './migrations/1788652800007-ProductsPartNoCaseInsensitive.js';
import { AppRoleTransactionCeiling1788652802131 } from './migrations/1788652802131-AppRoleTransactionCeiling.js';
import { ImportJobs1788652802200 } from './migrations/1788652802200-ImportJobs.js';
import { SingleOwnerRole1788652803001 } from './migrations/1788652803001-SingleOwnerRole.js';
import { OwnerReviewItems1788652803002 } from './migrations/1788652803002-OwnerReviewItems.js';
import { SyncPushColumns1788652803003 } from './migrations/1788652803003-SyncPushColumns.js';
import { CustomersMechanicsSyncIndex1788652804000 } from './migrations/1788652804000-CustomersMechanicsSyncIndex.js';

/** Static list — no glob, so it survives the dist/ build unchanged. Append new migrations here. */
export const MIGRATIONS = [
  InitialSchema1788652800000,
  RowLevelSecurity1788652800001,
  AuthSecurityDefinerAndAuditFix1788652800002,
  MovementsVoidType1788652800003,
  ReturnItemsCostAtSale1788652800004,
  CreditPaymentsMethodAndShift1788652800005,
  ReturnsShiftIndex1788652800006,
  ProductsPartNoCaseInsensitive1788652800007,
  AppRoleTransactionCeiling1788652802131,
  ImportJobs1788652802200,
  SingleOwnerRole1788652803001,
  OwnerReviewItems1788652803002,
  SyncPushColumns1788652803003,
  CustomersMechanicsSyncIndex1788652804000,
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
