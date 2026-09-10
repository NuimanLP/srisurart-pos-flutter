/**
 * Normalises what `EntityManager.query` hands back for a `RETURNING` clause.
 *
 * TypeORM's Postgres driver returns the rows directly for `SELECT` and `INSERT`,
 * but `[rows, affectedCount]` for `UPDATE` and `DELETE`. Reading `result[0].stock`
 * therefore works on an insert and silently yields `undefined` on an update — which
 * reaches the database as a NULL in a NOT NULL column, several statements later,
 * where nothing points back at the cause.
 */
export function returning<T>(result: unknown): T[] {
  if (!Array.isArray(result)) return [];
  const [first] = result;
  return Array.isArray(first) ? (first as T[]) : (result as T[]);
}
