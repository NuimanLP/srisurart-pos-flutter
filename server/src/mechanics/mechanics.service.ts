import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { newId } from '../common/ids.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { TenantCache } from '../infra/tenant-cache.service.js';
import { returning } from '../common/sql.js';
import type { SaleWithItems } from '../sales/sale-reads.service.js';
import { SaleReadsService } from '../sales/sale-reads.service.js';
import type { MechanicCreate, MechanicPatch } from '../people/people.dto.js';

export interface Mechanic {
  id: string;
  code: string;
  name: string;
  nameTH: string | null;
  nickname: string | null;
  shopName: string | null;
  phone: string | null;
  note: string | null;
  creditLimit: string;
  creditBalance: string;
  totalSales: string;
  totalCredit: string;
  totalDiscount: string;
  totalMarkup: string;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
}

interface MechanicRow {
  id: string;
  code: string;
  name: string;
  name_th: string | null;
  nickname: string | null;
  shop_name: string | null;
  phone: string | null;
  note: string | null;
  credit_limit: string;
  credit_balance: string;
  total_sales: string;
  total_credit: string;
  total_discount: string;
  total_markup: string;
  created_at: Date;
  updated_at: Date;
  deleted_at: Date | null;
}

const COLUMNS = `id, code, name, name_th, nickname, shop_name, phone, note,
                 credit_limit, credit_balance, total_sales, total_credit,
                 total_discount, total_markup, created_at, updated_at, deleted_at`;

const CURSOR_TIMESTAMP = `to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

@Injectable()
export class MechanicsService {
  constructor(
    private readonly saleReads: SaleReadsService,
    private readonly cache: TenantCache,
    private readonly tenants: TenantService,
  ) {}

  list(query: {
    search?: string;
    updatedSince?: string;
    afterId?: string;
    page: number;
    limit: number;
  }): Promise<{
    items: Mechanic[];
    total?: number;
    nextCursor?: { updatedSince: string; afterId: string } | null;
    fromCache: boolean;
  }> {
    return this.tenants.runTx(() => this.listIn(query));
  }

  private async listIn(query: {
    search?: string;
    updatedSince?: string;
    afterId?: string;
    page: number;
    limit: number;
  }): Promise<{
    items: Mechanic[];
    total?: number;
    nextCursor?: { updatedSince: string; afterId: string } | null;
    fromCache: boolean;
  }> {
    const { tenantId, manager } = currentRequestContext();
    // #32: cache-aside on `t:{tid}:mechanics:g:{token}:list:…`. The prefix is taken
    // before the query — see `TenantCache.prefix` for why that order matters.
    const prefix = await this.cache.prefix(tenantId, 'mechanics');
    const key =
      prefix === null || query.updatedSince
        ? null
        : `${prefix}list:` +
          (query.search ? `s:${encodeURIComponent(query.search)}:` : '') +
          `${query.page}:${query.limit}`;
    if (key !== null) {
      const cached = await this.cache.get<{
        items: Mechanic[];
        total: number;
        nextCursor?: { updatedSince: string; afterId: string } | null;
      }>(key);
      if (cached) return { ...cached, fromCache: true };
    }
    const params: unknown[] = [tenantId];
    const where = [
      'tenant_id = $1::uuid',
      query.updatedSince ? 'TRUE' : 'deleted_at IS NULL',
    ];
    if (query.search) {
      params.push(`%${escapeLike(query.search)}%`);
      where.push(
        `(code ILIKE $${params.length} ESCAPE '\\' OR name ILIKE $${params.length} ESCAPE '\\' OR COALESCE(name_th, '') ILIKE $${params.length} ESCAPE '\\' OR COALESCE(nickname, '') ILIKE $${params.length} ESCAPE '\\' OR COALESCE(shop_name, '') ILIKE $${params.length} ESCAPE '\\' OR COALESCE(phone, '') ILIKE $${params.length} ESCAPE '\\')`,
      );
    }
    if (query.updatedSince && query.afterId) {
      params.push(query.updatedSince, query.afterId);
      where.push(
        `(updated_at, id) > ($${params.length - 1}::timestamptz, $${params.length})`,
      );
    } else if (query.updatedSince) {
      params.push(query.updatedSince);
      where.push(`updated_at > $${params.length}::timestamptz`);
    }
    const order = query.updatedSince
      ? 'updated_at ASC, id ASC'
      : 'updated_at DESC, id DESC';
    const clause = where.join(' AND ');
    // #417: no count on a keyset sync read — see ProductsService.listUncachedIn.
    const totals = query.updatedSince
      ? null
      : ((await manager.query(
          `SELECT count(*)::int AS n FROM mechanics WHERE ${clause}`,
          params,
        )) as { n: number }[]);
    params.push(query.limit, (query.page - 1) * query.limit);
    const rows = (await manager.query(
      `SELECT ${COLUMNS}, ${CURSOR_TIMESTAMP} AS updated_at_cursor FROM mechanics
        WHERE ${clause}
        ORDER BY ${order}
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    )) as (MechanicRow & { updated_at_cursor: string })[];
    const items = rows.map(toMechanic);
    const total = totals === null ? undefined : (totals[0]?.n ?? 0);
    const last = rows[rows.length - 1];
    const nextCursor = query.updatedSince
      ? last
        ? { updatedSince: last.updated_at_cursor, afterId: last.id }
        : null
      : undefined;
    const page = { items, total, nextCursor };
    if (key !== null) await this.cache.set(key, page, 'mechanics');
    return { ...page, fromCache: false };
  }

  byId(id: string): Promise<Mechanic> {
    return this.tenants.runTx(() => this.byIdIn(id));
  }

  private async byIdIn(id: string): Promise<Mechanic> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM mechanics
        WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL`,
      [tenantId, id],
    )) as MechanicRow[];
    if (rows.length === 0) throw mechanicNotFound();
    return toMechanic(rows[0]);
  }

  create(input: MechanicCreate): Promise<Mechanic> {
    return this.tenants.runTx(() => this.createIn(input));
  }

  private async createIn(input: MechanicCreate): Promise<Mechanic> {
    const { tenantId, manager } = currentRequestContext();
    await manager.query(
      `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
      [`${tenantId}:mechanics:code`],
    );
    const maxRows = (await manager.query(
      `SELECT COALESCE(MAX((substring(code FROM '^M([0-9]+)$'))::int), 0)::int AS n
         FROM mechanics
        WHERE tenant_id = $1::uuid AND code ~ '^M[0-9]+$'`,
      [tenantId],
    )) as { n: number }[];
    const code = `M${String(maxRows[0].n + 1).padStart(3, '0')}`;
    const rows = (await manager.query(
      `INSERT INTO mechanics
              (tenant_id, id, code, name, name_th, nickname, shop_name, phone, note, credit_limit)
            VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10)
         RETURNING ${COLUMNS}`,
      [
        tenantId,
        newId('m'),
        code,
        input.name,
        input.nameTH,
        input.nickname,
        input.shopName,
        input.phone,
        input.note,
        input.creditLimit,
      ],
    )) as MechanicRow[];
    this.cache.invalidateAfterCommit(tenantId, 'mechanics');
    return toMechanic(rows[0]);
  }

  update(id: string, patch: MechanicPatch): Promise<Mechanic> {
    return this.tenants.runTx(() => this.updateIn(id, patch));
  }

  private async updateIn(id: string, patch: MechanicPatch): Promise<Mechanic> {
    const { tenantId, manager } = currentRequestContext();
    const values: unknown[] = [tenantId, id];
    const columns: Record<string, string> = {
      name: 'name',
      nameTH: 'name_th',
      nickname: 'nickname',
      shopName: 'shop_name',
      phone: 'phone',
      note: 'note',
      creditLimit: 'credit_limit',
    };
    const sets: string[] = [];
    for (const [field, value] of Object.entries(patch)) {
      values.push(value);
      sets.push(`${columns[field]} = $${values.length}`);
    }
    sets.push('updated_at = clock_timestamp()');
    const rows = returning<MechanicRow>(
      await manager.query(
        `UPDATE mechanics SET ${sets.join(', ')}
          WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL
      RETURNING ${COLUMNS}`,
        values,
      ),
    );
    if (rows.length === 0) throw mechanicNotFound();
    this.cache.invalidateAfterCommit(tenantId, 'mechanics');
    return toMechanic(rows[0]);
  }

  delete(id: string): Promise<{ id: string; deleted: true }> {
    return this.tenants.runTx(() => this.deleteIn(id));
  }

  private async deleteIn(id: string): Promise<{ id: string; deleted: true }> {
    const { tenantId, manager } = currentRequestContext();
    await manager.query(
      `UPDATE mechanics
          SET deleted_at = COALESCE(deleted_at, clock_timestamp()),
              updated_at = CASE WHEN deleted_at IS NULL THEN clock_timestamp() ELSE updated_at END
        WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, id],
    );
    this.cache.invalidateAfterCommit(tenantId, 'mechanics');
    return { id, deleted: true };
  }

  sales(
    id: string,
    page: number,
    limit: number,
  ): Promise<{ items: SaleWithItems[]; total: number }> {
    return this.tenants.runTx(() => this.salesIn(id, page, limit));
  }

  private async salesIn(
    id: string,
    page: number,
    limit: number,
  ): Promise<{ items: SaleWithItems[]; total: number }> {
    await this.byId(id);
    return this.saleReads.list({ mechanicId: id, page, limit });
  }
}

function toMechanic(row: MechanicRow): Mechanic {
  return {
    id: row.id,
    code: row.code,
    name: row.name,
    nameTH: row.name_th,
    nickname: row.nickname,
    shopName: row.shop_name,
    phone: row.phone,
    note: row.note,
    creditLimit: row.credit_limit,
    creditBalance: row.credit_balance,
    totalSales: row.total_sales,
    totalCredit: row.total_credit,
    totalDiscount: row.total_discount,
    totalMarkup: row.total_markup,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
    deletedAt: row.deleted_at?.toISOString() ?? null,
  };
}

function mechanicNotFound(): HttpException {
  return new HttpException(
    { code: 'MECHANIC_NOT_FOUND', message: 'Mechanic not found' },
    HttpStatus.NOT_FOUND,
  );
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (character) => `\\${character}`);
}
