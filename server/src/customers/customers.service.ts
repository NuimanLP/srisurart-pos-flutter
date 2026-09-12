import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { newId } from '../common/ids.js';
import { currentRequestContext } from '../common/request-context.js';
import { returning } from '../common/sql.js';
import type { SaleWithItems } from '../sales/sale-reads.service.js';
import { SaleReadsService } from '../sales/sale-reads.service.js';
import type { CustomerCreate, CustomerPatch } from '../people/people.dto.js';

export interface Customer {
  id: string;
  code: string;
  name: string;
  nameTH: string;
  phone: string | null;
  address: string | null;
  points: number;
  totalSpend: string;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
}

interface CustomerRow {
  id: string;
  code: string;
  name: string;
  name_th: string;
  phone: string | null;
  address: string | null;
  points: number;
  total_spend: string;
  created_at: Date;
  updated_at: Date;
  deleted_at: Date | null;
}

const COLUMNS = `id, code, name, name_th, phone, address, points, total_spend,
                 created_at, updated_at, deleted_at`;

@Injectable()
export class CustomersService {
  constructor(private readonly saleReads: SaleReadsService) {}

  async list(query: {
    search?: string;
    updatedSince?: string;
    page: number;
    limit: number;
  }): Promise<{ items: Customer[]; total: number }> {
    const { tenantId, manager } = currentRequestContext();
    const params: unknown[] = [tenantId];
    // `updatedSince` is the incremental-sync exception from 01_DATABASE.md §10:
    // ordinary lists/searches hide tombstones, while sync must receive deletions.
    const where = [
      'tenant_id = $1::uuid',
      query.updatedSince ? 'TRUE' : 'deleted_at IS NULL',
    ];
    if (query.search) {
      params.push(`%${escapeLike(query.search)}%`);
      where.push(
        `(code ILIKE $${params.length} ESCAPE '\\' OR name ILIKE $${params.length} ESCAPE '\\' OR name_th ILIKE $${params.length} ESCAPE '\\' OR COALESCE(phone, '') ILIKE $${params.length} ESCAPE '\\')`,
      );
    }
    if (query.updatedSince) {
      params.push(query.updatedSince);
      where.push(`updated_at > $${params.length}::timestamptz`);
    }
    const clause = where.join(' AND ');
    const totals = (await manager.query(
      `SELECT count(*)::int AS n FROM customers WHERE ${clause}`,
      params,
    )) as { n: number }[];
    params.push(query.limit, (query.page - 1) * query.limit);
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM customers
        WHERE ${clause}
        ORDER BY updated_at DESC, id DESC
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    )) as CustomerRow[];
    return { items: rows.map(toCustomer), total: totals[0].n };
  }

  async byId(id: string): Promise<Customer> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM customers
        WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL`,
      [tenantId, id],
    )) as CustomerRow[];
    if (rows.length === 0) throw customerNotFound();
    return toCustomer(rows[0]);
  }

  async create(input: CustomerCreate): Promise<Customer> {
    const { tenantId, manager } = currentRequestContext();
    await lockCodeSequence(manager, `${tenantId}:customers:code`);
    const maxRows = (await manager.query(
      `SELECT COALESCE(MAX((substring(code FROM '^CUS([0-9]+)$'))::int), 0)::int AS n
         FROM customers
        WHERE tenant_id = $1::uuid AND code ~ '^CUS[0-9]+$'`,
      [tenantId],
    )) as { n: number }[];
    const code = `CUS${String(maxRows[0].n + 1).padStart(3, '0')}`;
    const rows = (await manager.query(
      `INSERT INTO customers (tenant_id, id, code, name, name_th, phone, address)
            VALUES ($1::uuid, $2, $3, $4, $5, $6, $7)
         RETURNING ${COLUMNS}`,
      [
        tenantId,
        newId('c'),
        code,
        input.name,
        input.nameTH,
        input.phone,
        input.address,
      ],
    )) as CustomerRow[];
    return toCustomer(rows[0]);
  }

  async update(id: string, patch: CustomerPatch): Promise<Customer> {
    const { tenantId, manager } = currentRequestContext();
    const values: unknown[] = [tenantId, id];
    const sets = assignments(patch, values, {
      name: 'name',
      nameTH: 'name_th',
      phone: 'phone',
      address: 'address',
    });
    sets.push('updated_at = clock_timestamp()');
    const rows = returning<CustomerRow>(
      await manager.query(
        `UPDATE customers SET ${sets.join(', ')}
          WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL
      RETURNING ${COLUMNS}`,
        values,
      ),
    );
    if (rows.length === 0) throw customerNotFound();
    return toCustomer(rows[0]);
  }

  /** Hard delete used to succeed even for zero rows; soft delete keeps that HTTP contract. */
  async delete(id: string): Promise<{ id: string; deleted: true }> {
    const { tenantId, manager } = currentRequestContext();
    await manager.query(
      `UPDATE customers
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
    return this.saleReads.list({ customerId: id, page, limit });
  }
}

function toCustomer(row: CustomerRow): Customer {
  return {
    id: row.id,
    code: row.code,
    name: row.name,
    nameTH: row.name_th,
    phone: row.phone,
    address: row.address,
    points: row.points,
    totalSpend: row.total_spend,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
    deletedAt: row.deleted_at?.toISOString() ?? null,
  };
}

function customerNotFound(): HttpException {
  return new HttpException(
    { code: 'CUSTOMER_NOT_FOUND', message: 'Customer not found' },
    HttpStatus.NOT_FOUND,
  );
}

async function lockCodeSequence(
  manager: { query(sql: string, params?: unknown[]): Promise<unknown> },
  key: string,
): Promise<void> {
  await manager.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [
    key,
  ]);
}

function assignments<T extends object>(
  patch: T,
  values: unknown[],
  columns: Record<string, string>,
): string[] {
  const out: string[] = [];
  for (const [field, value] of Object.entries(patch)) {
    values.push(value);
    out.push(`${columns[field]} = $${values.length}`);
  }
  return out;
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (character) => `\\${character}`);
}
