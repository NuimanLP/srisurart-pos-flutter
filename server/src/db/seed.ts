/**
 * Seed for a new tenant (ADR-0001 step 4): the five categories and nothing else —
 * no demo products, no unit-of-measure entity. Names and order are copied from
 * `lib/data/db/database.dart` (`seedCategories`); `position` is the palette index,
 * so the order must never change or every category colour in the app shifts.
 *
 * Called inside the provisioning transaction (#5). Anything with a
 * `query(sql, params)` method works — a TypeORM QueryRunner/EntityManager or a pg Client.
 */
export const SEED_CATEGORIES = [
  'เครื่องยนต์',
  'ไฟฟ้า',
  'น้ำมัน',
  'เบรก',
  'ตัวถัง',
] as const;

export interface SqlExecutor {
  query(sql: string, parameters?: unknown[]): Promise<unknown>;
}

export async function seedCategories(
  db: SqlExecutor,
  tenantId: string,
): Promise<void> {
  await db.query(
    `INSERT INTO categories (tenant_id, name, position)
       SELECT $1::uuid, name, position - 1
         FROM unnest($2::text[]) WITH ORDINALITY AS c(name, position)`,
    [tenantId, [...SEED_CATEGORIES]],
  );
}
