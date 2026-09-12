import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { newId } from '../common/ids.js';
import { currentRequestContext } from '../common/request-context.js';
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

@Injectable()
export class MechanicsService {
  constructor(private readonly saleReads: SaleReadsService) {}

  async list(query: {
    search?: string;
    updatedSince?: string;
    page: number;
    limit: number;
  }): Promise<{ items: Mechanic[]; total: number }> {
    const { tenantId, manager } = currentRequestContext();
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
    if (query.updatedSince) {
      params.push(query.updatedSince);
      where.push(`updated_at > $${params.length}::timestamptz`);
    }
    const clause = where.join(' AND ');
    const totals = (await manager.query(
      `SELECT count(*)::int AS n FROM mechanics WHERE ${clause}`,
      params,
    )) as { n: number }[];
    params.push(query.limit, (query.page - 1) * query.limit);
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM mechanics
        WHERE ${clause}
        ORDER BY updated_at DESC, id DESC
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    )) as MechanicRow[];
    return { items: rows.map(toMechanic), total: totals[0].n };
  }

  async byId(id: string): Promise<Mechanic> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM mechanics
        WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL`,
      [tenantId, id],
    )) as MechanicRow[];
    if (rows.length === 0) throw mechanicNotFound();
    return toMechanic(rows[0]);
  }

  async create(input: MechanicCreate): Promise<Mechanic> {
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
    return toMechanic(rows[0]);
  }

  async update(id: string, patch: MechanicPatch): Promise<Mechanic> {
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
    return toMechanic(rows[0]);
  }

  async delete(id: string): Promise<{ id: string; deleted: true }> {
    const { tenantId, manager } = currentRequestContext();
    await manager.query(
      `UPDATE mechanics
          SET deleted_at = COALESCE(deleted_at, clock_timestamp()),
              updated_at = CASE WHEN deleted_at IS NULL THEN clock_timestamp() ELSE updated_at END
        WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, id],
    );
    return { id, deleted: true };
  }

  async sales(
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
