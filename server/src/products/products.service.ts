import {
  BadRequestException,
  HttpException,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { AuditService } from '../audit/audit.service.js';
import { newId } from '../common/ids.js';
import { fromSatang, satangOf } from '../common/money.js';
import {
  authorisedTenantId,
  currentRequestContext,
} from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { returning } from '../common/sql.js';
import { TenantCache } from '../infra/tenant-cache.service.js';
import {
  MOVEMENT_COLUMNS,
  movementOut,
  type MovementOut,
  type MovementRow,
} from '../sales/sales.service.js';
import type {
  ProductCreate,
  ProductPatch,
  StockAdjustment,
} from './catalogue.dto.js';

export interface Product {
  id: string;
  partNo: string;
  name: string;
  nameTH: string;
  category: string;
  brand: string;
  /** Money is a string on the wire (02_API_SCREENS.md §1.1). */
  price: string;
  cost: string;
  stock: number;
  minStock: number;
  compat: string | null;
  updatedAt: string;
  deletedAt: string | null;
}

interface ProductRow {
  id: string;
  part_no: string;
  name: string;
  name_th: string;
  category: string;
  brand: string;
  price: string;
  cost: string;
  stock: number;
  min_stock: number;
  compat: string | null;
  updated_at: Date;
  deleted_at: Date | null;
}

export interface ListQuery {
  search?: string;
  partNo?: string;
  category?: string;
  updatedSince?: string;
  /** Tie-break for `updatedSince`: the id of the last row already read. */
  afterId?: string;
  page: number;
  limit: number;
}

export interface SyncCursor {
  updatedSince: string;
  afterId: string;
}

/** What `POST /products/:id/adjust-stock` answers. */
export interface StockAdjustmentResult {
  /** The stock after the clamp — top level because that is where the client reads it. */
  stockAfter: number;
  product: Product;
  movement: MovementOut;
}

const COLUMNS = `id, part_no, name, name_th, category, brand, price, cost, stock,
                 min_stock, compat, updated_at, deleted_at`;

/**
 * Exactly the expression `idx_products_search` is built on (migration
 * `1788652800000`). The planner only uses a GIN expression index for a predicate on
 * the identical expression, so this string must not be "tidied".
 */
export const SEARCH_EXPRESSION = `lower(part_no || ' ' || name || ' ' || name_th || ' ' || COALESCE(compat, ''))`;

/** `updated_at` as UTC ISO-8601 with all six fractional digits Postgres stores. */
const CURSOR_TIMESTAMP = `to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

const INT4_MAX = 2_147_483_647;

/** Postgres `unique_violation`. */
const UNIQUE_VIOLATION = '23505';

type CachedList = { items: Product[]; total?: number; nextCursor?: SyncCursor | null };

@Injectable()
export class ProductsService {
  constructor(
    private readonly cache: TenantCache,
    private readonly audit: AuditService,
    private readonly tenants: TenantService,
  ) {}

  /** `prefix` carries the tenant and the current generation (`TenantCache.prefix`). */
  private cacheKey(prefix: string, query: ListQuery): string {
    // Every filter is part of the key: a `?partNo=` lookup sharing a key with the
    // unfiltered page would answer a barcode scan with the whole first page.
    const part = (tag: string, value: string | undefined) =>
      value ? `${tag}:${encodeURIComponent(value)}:` : '';
    return (
      `${prefix}list:` +
      part('s', query.search) +
      part('n', query.partNo) +
      part('c', query.category) +
      part('u', query.updatedSince) +
      part('a', query.afterId) +
      `${query.page}:${query.limit}`
    );
  }

  /**
   * Cache first, and no transaction until Postgres is actually needed (#173): a hit, or a
   * `singleFlight` waiter, holds no pooled connection. The tenant comes from
   * `authorisedTenantId()` — what `TenantGuard` already put in scope, never an argument.
   */
  async list(query: ListQuery): Promise<{
    items: Product[];
    total?: number;
    nextCursor?: SyncCursor | null;
    fromCache: boolean;
  }> {
    const tenantId = authorisedTenantId();
    // Before the query, always — see `TenantCache.prefix`.
    const prefix = await this.cache.prefix(tenantId, 'products');
    const key = prefix === null ? null : this.cacheKey(prefix, query);

    let release = async () => {};
    if (key !== null) {
      const cached = await this.cache.get<CachedList>(key);
      if (cached) return { ...cached, fromCache: true };
      // Only the list is locked (#124): its count + search is milliseconds per miss,
      // while `byId` and the tenant status probe are a single index lookup that costs
      // less than the lock's own Redis round trips.
      const flight = await this.cache.singleFlight<CachedList>(key);
      if ('value' in flight) return { ...flight.value, fromCache: true };
      release = flight.release;
    }

    // `finally`: a loader that throws must free its lock at once, or every concurrent miss
    // waits out `LOCK_WAIT_MS` for a query that failed.
    try {
      const loaded = await this.listUncached(query);
      if (key !== null) {
        await this.cache.set(key, loaded satisfies CachedList, 'products');
      }
      return { ...loaded, fromCache: false };
    } finally {
      await release();
    }
  }

  /** The Postgres read behind `list`, in one transaction (count, when taken, and page share a snapshot). */
  listUncached(query: ListQuery): Promise<CachedList> {
    return this.tenants.runTx(() => this.listUncachedIn(query));
  }

  private async listUncachedIn(query: ListQuery): Promise<CachedList> {
    const { tenantId, manager } = currentRequestContext();
    const params: unknown[] = [tenantId];
    // `updatedSince` is the sync read (01_DATABASE.md §10): it must see tombstones,
    // or a product deleted on one device lives forever in every other device's cache.
    const where = [
      'tenant_id = $1::uuid',
      query.updatedSince ? 'TRUE' : 'deleted_at IS NULL',
    ];

    if (query.search) {
      params.push(`%${escapeLike(query.search)}%`);
      const p = `$${params.length}`;
      // The first test is the trigram index's own expression, so Postgres can answer
      // it from `idx_products_search` — Thai substring, "เบรก" inside "ผ้าเบรกหน้า".
      // The second keeps today's matching exact: the screens search name, nameTH and
      // partNo only (`products_screen.dart`), and the indexed expression also holds
      // `compat` and the spaces joining the fields.
      where.push(
        `${SEARCH_EXPRESSION} LIKE lower(${p}) ESCAPE '\\'`,
        `(part_no ILIKE ${p} ESCAPE '\\' OR name ILIKE ${p} ESCAPE '\\' OR name_th ILIKE ${p} ESCAPE '\\')`,
      );
    }

    if (query.partNo) {
      // A barcode scan: one product, never a ranked list (02_API_SCREENS.md §3.1).
      // Compared the way uniqueness is enforced (`uq_products_partno_ci`), so a scan
      // cannot miss the one live product whose number differs only in case.
      params.push(query.partNo.trim());
      where.push(`lower(part_no) = lower($${params.length})`);
    }

    if (query.category) {
      params.push(query.category);
      where.push(`category = $${params.length}`);
    }

    if (query.updatedSince && query.afterId) {
      // Keyset on (updated_at, id): many rows share one `updated_at` (a sale stamps
      // every line with the transaction's `now()`, an import stamps a whole catalogue),
      // so `updated_at > $ts` alone skips the rest of a tie that a page boundary cut.
      params.push(query.updatedSince, query.afterId);
      where.push(
        `(updated_at, id) > ($${params.length - 1}::timestamptz, $${params.length})`,
      );
    } else if (query.updatedSince) {
      params.push(query.updatedSince);
      where.push(`updated_at > $${params.length}::timestamptz`);
    }

    // A sync reader walks forward in (updated_at, id) order and follows `nextCursor`.
    const order = query.updatedSince ? 'updated_at ASC, id ASC' : 'id ASC';

    const clause = where.join(' AND ');
    // #417: a sync read is keyset-paged and walked until an empty page, so a count
    // would re-scan every remaining row on every page for a number nobody reads.
    const totals = query.updatedSince
      ? null
      : ((await manager.query(
          `SELECT count(*)::int AS n FROM products WHERE ${clause}`,
          params,
        )) as { n: number }[]);

    params.push(query.limit, (query.page - 1) * query.limit);
    const rows = (await manager.query(
      `SELECT ${COLUMNS}, ${CURSOR_TIMESTAMP} AS updated_at_cursor FROM products
        WHERE ${clause}
        ORDER BY ${order}
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    )) as (ProductRow & { updated_at_cursor: string })[];

    const items = rows.map(toProduct);
    const total = totals === null ? undefined : (totals[0]?.n ?? 0);
    // The cursor is the last row's key at full precision. `updatedAt` on the wire is a
    // JS `toISOString()` — milliseconds — and a truncated cursor sits *below* every row
    // in its millisecond, so a tie larger than a page would be served again forever.
    const last = rows[rows.length - 1];
    const nextCursor = query.updatedSince
      ? last
        ? { updatedSince: last.updated_at_cursor, afterId: last.id }
        : null
      : undefined;

    return { items, total, nextCursor };
  }

  /** Cache first, like `list` (#173): a hit opens no transaction. */
  async byId(id: string): Promise<{ product: Product; fromCache: boolean }> {
    const tenantId = authorisedTenantId();
    const prefix = await this.cache.prefix(tenantId, 'products');
    const key = prefix === null ? null : `${prefix}item:${id}`;

    if (key !== null) {
      const cached = await this.cache.get<Product>(key);
      if (cached) return { product: cached, fromCache: true };
    }

    const product = await this.byIdUncached(id);
    if (key !== null) await this.cache.set(key, product, 'products');
    return { product, fromCache: false };
  }

  byIdUncached(id: string): Promise<Product> {
    return this.tenants.runTx(() => this.byIdUncachedIn(id));
  }

  private async byIdUncachedIn(id: string): Promise<Product> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM products
        WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL`,
      [tenantId, id],
    )) as ProductRow[];

    if (!rows || rows.length === 0) throw productNotFound();

    return toProduct(rows[0]);
  }

  /** `db.js addProduct`: a fresh `p` id, and no second live product with this part number. */
  create(input: ProductCreate): Promise<Product> {
    return this.tenants.runTx(() => this.createIn(input));
  }

  private async createIn(input: ProductCreate): Promise<Product> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await mapDuplicatePartNo(
      manager.query(
        `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand,
                             price, cost, stock, min_stock, compat, updated_at)
            VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, clock_timestamp())
         RETURNING ${COLUMNS}`,
        [
          tenantId,
          newId('p'),
          input.partNo,
          input.name,
          input.nameTH,
          input.category,
          input.brand,
          input.price,
          input.cost,
          input.stock,
          input.minStock,
          input.compat,
        ],
      ),
    )) as ProductRow[];
    this.cache.invalidateAfterCommit(tenantId, 'products');
    return toProduct(rows[0]);
  }

  /** `db.js updateProduct`: refused when the new part number belongs to ANOTHER product. */
  update(id: string, patch: ProductPatch): Promise<Product> {
    return this.tenants.runTx(() => this.updateIn(id, patch));
  }

  private async updateIn(id: string, patch: ProductPatch): Promise<Product> {
    const { tenantId, manager } = currentRequestContext();
    const columns: Record<keyof ProductPatch, string> = {
      partNo: 'part_no',
      name: 'name',
      nameTH: 'name_th',
      category: 'category',
      brand: 'brand',
      price: 'price',
      cost: 'cost',
      minStock: 'min_stock',
      compat: 'compat',
    };
    const values: unknown[] = [tenantId, id];
    const sets: string[] = [];
    for (const [field, value] of Object.entries(patch)) {
      values.push(value);
      sets.push(`${columns[field as keyof ProductPatch]} = $${values.length}`);
    }
    sets.push('updated_at = clock_timestamp()');

    const rows = returning<ProductRow>(
      await mapDuplicatePartNo(
        manager.query(
          `UPDATE products SET ${sets.join(', ')}
            WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL
        RETURNING ${COLUMNS}`,
          values,
        ),
      ),
    );
    if (rows.length === 0) throw productNotFound();
    this.cache.invalidateAfterCommit(tenantId, 'products');
    return toProduct(rows[0]);
  }

  /**
   * Soft delete (01_DATABASE.md §10): `sale_items` and `movements` reference the row
   * through composite foreign keys, so a hard `DELETE` fails for any product that was
   * ever sold. `200` for an id that is absent or already deleted, as the hard delete
   * the client was written against answered.
   */
  delete(id: string): Promise<{ id: string; deleted: true }> {
    return this.tenants.runTx(() => this.deleteIn(id));
  }

  private async deleteIn(id: string): Promise<{ id: string; deleted: true }> {
    const { tenantId, manager } = currentRequestContext();
    await manager.query(
      `UPDATE products
          SET deleted_at = clock_timestamp(), updated_at = clock_timestamp()
        WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL`,
      [tenantId, id],
    );
    this.cache.invalidateAfterCommit(tenantId, 'products');
    return { id, deleted: true };
  }

  /**
   * `db.js adjustStock`: a manual correction CLAMPS at zero — deliberately unlike a
   * sale, which refuses (01_DATABASE.md §7.6) — and writes one `movements` row.
   *
   * The row's `delta` is the delta that was asked for and `stock_after` the clamped
   * result, exactly as the Dart repository writes them (its test pins `delta -10`
   * beside `stockAfter 0`), so a clamped row is visible in the ledger as one whose
   * delta and stock do not add up.
   *
   * Locks the one product row and nothing else, so it cannot take part in the sale
   * path's lock order (sale → mechanic → products → doc_counters → customer).
   */
  adjustStock(
    id: string,
    input: StockAdjustment,
    actor: { userId: string; deviceId?: string },
  ): Promise<StockAdjustmentResult> {
    return this.tenants.runTx(() => this.adjustStockIn(id, input, actor));
  }

  private async adjustStockIn(
    id: string,
    input: StockAdjustment,
    actor: { userId: string; deviceId?: string },
  ): Promise<StockAdjustmentResult> {
    const { tenantId, manager } = currentRequestContext();
    const locked = (await manager.query(
      `SELECT stock FROM products
        WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL
          FOR UPDATE`,
      [tenantId, id],
    )) as { stock: number }[];
    if (locked.length === 0) throw productNotFound();

    const before = locked[0].stock;
    const requested = before + input.delta;
    // The clamp covers the floor only. Past the top of `INT` there is nothing sane
    // to clamp to, and letting Postgres raise `22003` would be a 500.
    if (requested > INT4_MAX) {
      throw new BadRequestException(`delta would take stock past ${INT4_MAX}`);
    }
    const stockAfter = Math.max(0, requested);

    const rows = returning<ProductRow>(
      await manager.query(
        `UPDATE products SET stock = $3, updated_at = clock_timestamp()
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING ${COLUMNS}`,
        [tenantId, id, stockAfter],
      ),
    );
    const product = toProduct(rows[0]);

    const movement = (await manager.query(
      `INSERT INTO movements (tenant_id, id, product_id, part_no, name, delta, type, note, stock_after)
            VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9)
         RETURNING ${MOVEMENT_COLUMNS}`,
      [
        tenantId,
        newId('mv'),
        id,
        product.partNo,
        product.name,
        input.delta,
        input.type,
        input.note,
        stockAfter,
      ],
    )) as MovementRow[];

    // #43: `stock.adjust` is this ticket's audit action — who changed the count on a
    // shared counter PC, in the same transaction as the change.
    await this.audit.log(manager, {
      tenantId,
      userId: actor.userId,
      deviceId: actor.deviceId,
      action: 'stock.adjust',
      entity: 'product',
      entityId: id,
      before: { stock: before },
      after: {
        stock: stockAfter,
        delta: input.delta,
        type: input.type,
        note: input.note,
        movementId: movement[0].id,
      },
    });

    this.cache.invalidateAfterCommit(tenantId, 'products');
    return { stockAfter, product, movement: movementOut(movement[0]) };
  }
}

/**
 * `db.js` refuses a part number another live product already has, ignoring case.
 * `uq_products_partno_ci` (migration `1788652800007`) is what enforces it — for every
 * writer, the platform import included — and a concurrent duplicate blocks on the index
 * and then fails here, so no check-then-insert race exists to guard.
 */
async function mapDuplicatePartNo<T>(write: Promise<T>): Promise<T> {
  try {
    return await write;
  } catch (err) {
    const e = err as { code?: string; constraint?: string };
    if (
      e.code === UNIQUE_VIOLATION &&
      (e.constraint === 'uq_products_partno_ci' ||
        e.constraint === 'uq_products_partno')
    ) {
      throw new HttpException(
        { code: 'DUPLICATE_PART_NO', message: 'รหัสอะไหล่นี้มีอยู่แล้ว' },
        HttpStatus.CONFLICT,
      );
    }
    throw err;
  }
}

export function productNotFound(): HttpException {
  return new HttpException(
    { code: 'PRODUCT_NOT_FOUND', message: 'Product not found' },
    HttpStatus.NOT_FOUND,
  );
}

function toProduct(row: ProductRow): Product {
  return {
    id: row.id,
    partNo: row.part_no,
    name: row.name,
    nameTH: row.name_th,
    category: row.category,
    brand: row.brand,
    price: fromSatang(satangOf(String(row.price))),
    cost: fromSatang(satangOf(String(row.cost))),
    stock: row.stock,
    minStock: row.min_stock,
    compat: row.compat,
    updatedAt: row.updated_at.toISOString(),
    deletedAt: row.deleted_at?.toISOString() ?? null,
  };
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (char) => `\\${char}`);
}
