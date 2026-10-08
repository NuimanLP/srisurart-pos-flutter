import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { newUuid } from '../common/ids.js';
import { fromSatang, satangOf } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { returning } from '../common/sql.js';
import type { SupplierCreate, SupplierPatch } from './catalogue.dto.js';
import { productNotFound } from './products.service.js';

export interface Supplier {
  id: string;
  productId: string;
  name: string;
  unitCost: string;
  freight: string;
}

interface SupplierRow {
  id: string;
  product_id: string;
  name: string;
  unit_cost: string;
  freight: string;
}

const COLUMNS = 'id, product_id, name, unit_cost, freight';

/** `suppliers_repository.dart`: per-product suppliers, hard-deleted (01_DATABASE.md §10). */
@Injectable()
export class SuppliersService {
  constructor(private readonly tenants: TenantService) {}

  /**
   * Every supplier of the tenant's live products — what the till pulls whole into its
   * cache (`GET /suppliers`). Suppliers are hard-deleted and carry no `updated_at`, so
   * there is no cursor: the reply is the full set and the client replaces its copy.
   */
  list(): Promise<Supplier[]> {
    return this.tenants.runTx(() => this.listIn());
  }

  private async listIn(): Promise<Supplier[]> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT s.id, s.product_id, s.name, s.unit_cost, s.freight
         FROM suppliers s
         JOIN products p ON p.tenant_id = s.tenant_id AND p.id = s.product_id
        WHERE s.tenant_id = $1::uuid AND p.deleted_at IS NULL
        ORDER BY s.product_id ASC, s.id ASC`,
      [tenantId],
    )) as SupplierRow[];
    return rows.map(toSupplier);
  }

  /** A deleted product's suppliers are hidden with it; an unknown product has none. */
  listForProduct(productId: string): Promise<Supplier[]> {
    return this.tenants.runTx(() => this.listForProductIn(productId));
  }

  private async listForProductIn(productId: string): Promise<Supplier[]> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT s.id, s.product_id, s.name, s.unit_cost, s.freight
         FROM suppliers s
         JOIN products p ON p.tenant_id = s.tenant_id AND p.id = s.product_id
        WHERE s.tenant_id = $1::uuid AND s.product_id = $2 AND p.deleted_at IS NULL
        ORDER BY s.id ASC`,
      [tenantId, productId],
    )) as SupplierRow[];
    return rows.map(toSupplier);
  }

  create(input: SupplierCreate): Promise<Supplier> {
    return this.tenants.runTx(() => this.createIn(input));
  }

  private async createIn(input: SupplierCreate): Promise<Supplier> {
    const { tenantId, manager } = currentRequestContext();
    await this.assertProductLive(input.productId);
    const rows = (await manager.query(
      `INSERT INTO suppliers (tenant_id, id, product_id, name, unit_cost, freight)
            VALUES ($1::uuid, $2, $3, $4, $5, $6)
         RETURNING ${COLUMNS}`,
      [
        tenantId,
        newUuid(),
        input.productId,
        input.name,
        input.unitCost,
        input.freight,
      ],
    )) as SupplierRow[];
    return toSupplier(rows[0]);
  }

  update(id: string, patch: SupplierPatch): Promise<Supplier> {
    return this.tenants.runTx(() => this.updateIn(id, patch));
  }

  private async updateIn(id: string, patch: SupplierPatch): Promise<Supplier> {
    const { tenantId, manager } = currentRequestContext();
    if (patch.productId !== undefined)
      await this.assertProductLive(patch.productId);
    const columns: Record<keyof SupplierPatch, string> = {
      productId: 'product_id',
      name: 'name',
      unitCost: 'unit_cost',
      freight: 'freight',
    };
    const values: unknown[] = [tenantId, id];
    const sets: string[] = [];
    for (const [field, value] of Object.entries(patch)) {
      values.push(value);
      sets.push(`${columns[field as keyof SupplierPatch]} = $${values.length}`);
    }
    // An empty patch still answers the row (or 404), like a PATCH that changed nothing.
    const sql =
      sets.length === 0
        ? `SELECT ${COLUMNS} FROM suppliers WHERE tenant_id = $1::uuid AND id = $2`
        : `UPDATE suppliers SET ${sets.join(', ')}
            WHERE tenant_id = $1::uuid AND id = $2
        RETURNING ${COLUMNS}`;
    const rows = returning<SupplierRow>(await manager.query(sql, values));
    if (rows.length === 0) {
      throw new HttpException(
        { code: 'SUPPLIER_NOT_FOUND', message: 'Supplier not found' },
        HttpStatus.NOT_FOUND,
      );
    }
    return toSupplier(rows[0]);
  }

  /** Hard delete; `200` whether or not the row existed, as the Dart delete answered. */
  delete(id: string): Promise<{ id: string; deleted: true }> {
    return this.tenants.runTx(() => this.deleteIn(id));
  }

  private async deleteIn(id: string): Promise<{ id: string; deleted: true }> {
    const { tenantId, manager } = currentRequestContext();
    await manager.query(
      `DELETE FROM suppliers WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, id],
    );
    return { id, deleted: true };
  }

  /**
   * The composite foreign key would refuse an unknown product as a `23503` — a 500 —
   * and would accept a soft-deleted one, attaching a supplier to a tombstone.
   */
  private async assertProductLive(productId: string): Promise<void> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT 1 FROM products
        WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL`,
      [tenantId, productId],
    )) as unknown[];
    if (rows.length === 0) throw productNotFound();
  }
}

function toSupplier(row: SupplierRow): Supplier {
  return {
    id: row.id,
    productId: row.product_id,
    name: row.name,
    unitCost: fromSatang(satangOf(row.unit_cost)),
    freight: fromSatang(satangOf(row.freight)),
  };
}
