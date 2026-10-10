import { Injectable } from '@nestjs/common';
import {
  authorisedTenantId,
  currentRequestContext,
} from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { TenantCache } from '../infra/tenant-cache.service.js';
import type { Customer } from '../customers/customers.service.js';
import type { Mechanic } from '../mechanics/mechanics.service.js';
import type { Settings, SettingsPatch } from './settings.dto.js';

export interface ProductBootstrap {
  id: string;
  partNo: string;
  name: string;
  nameTH: string;
  category: string;
  brand: string;
  price: number;
  cost: number;
  stock: number;
  minStock: number;
  compat: string | null;
  imageKey: string | null;
  updatedAt: string;
}

export interface CategoryBootstrap {
  name: string;
  position: number;
}

export interface BootstrapData {
  products: ProductBootstrap[];
  categories: CategoryBootstrap[];
  customers: Customer[];
  mechanics: Mechanic[];
  settings: Settings;
}

interface SettingsRow {
  tenant_id: string;
  shop_name: string;
  shop_name_en: string;
  tax_rate: string | number;
  quote_valid_days: number;
  address: string | null;
  phone: string | null;
  cashier_name: string | null;
  tax_id: string | null;
  branch_no: string | null;
  updated_at: Date;
}

interface ProductRow {
  id: string;
  part_no: string;
  name: string;
  name_th: string;
  category: string;
  brand: string;
  price: string | number;
  cost: string | number;
  stock: number;
  min_stock: number;
  compat: string | null;
  image_key: string | null;
  updated_at: Date;
}

interface CategoryRow {
  name: string;
  position: number;
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
}

@Injectable()
export class SettingsService {
  constructor(
    private readonly cache: TenantCache,
    private readonly tenants: TenantService,
  ) {}

  /**
   * `GET /settings` through `t:{tid}:settings:g:{token}:row` (#32).
   * `getSettings()` stays a plain read: `updateSettings()` reads it inside
   * its write transaction, and `/bootstrap` hashes a fresh body for its ETag,
   * neither of which may touch the cache.
   *
   * No transaction until a miss (#173): a hit holds no pooled connection.
   * `getSettings()` opens its own `runTx`.
   */
  async getSettingsCached(): Promise<{ settings: Settings; fromCache: boolean }> {
    const tenantId = authorisedTenantId();
    const prefix = await this.cache.prefix(tenantId, 'settings');
    const key = prefix === null ? null : `${prefix}row`;
    if (key !== null) {
      const cached = await this.cache.get<Settings>(key);
      if (cached) return { settings: cached, fromCache: true };
    }
    const settings = await this.getSettings();
    if (key !== null) await this.cache.set(key, settings, 'settings');
    return { settings, fromCache: false };
  }

  getSettings(): Promise<Settings> {
    return this.tenants.runTx(() => this.getSettingsIn());
  }

  private async getSettingsIn(): Promise<Settings> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT shop_name, shop_name_en, tax_rate, quote_valid_days, address, phone, cashier_name, tax_id, branch_no, updated_at
         FROM settings
        WHERE tenant_id = $1::uuid`,
      [tenantId],
    )) as SettingsRow[];

    if (rows.length > 0) {
      return toSettings(rows[0]);
    }

    // Fallback: create default settings row if missing
    const tenantRows = (await manager.query(
      `SELECT shop_name, shop_name_en FROM tenants WHERE id = $1::uuid`,
      [tenantId],
    )) as { shop_name: string; shop_name_en: string }[];

    const shopName = tenantRows[0]?.shop_name || 'SriSurart Autopart';
    const shopNameEn = tenantRows[0]?.shop_name_en || '';

    const inserted = (await manager.query(
      `INSERT INTO settings (tenant_id, shop_name, shop_name_en, tax_rate, quote_valid_days)
       VALUES ($1::uuid, $2, $3, 7, 30)
       RETURNING shop_name, shop_name_en, tax_rate, quote_valid_days, address, phone, cashier_name, tax_id, branch_no, updated_at`,
      [tenantId, shopName, shopNameEn],
    )) as SettingsRow[];

    return toSettings(inserted[0]);
  }

  updateSettings(patch: SettingsPatch): Promise<Settings> {
    return this.tenants.runTx(() => this.updateSettingsIn(patch));
  }

  private async updateSettingsIn(patch: SettingsPatch): Promise<Settings> {
    const { tenantId, manager } = currentRequestContext();
    const current = await this.getSettings();

    const shopName = patch.shopName ?? current.shopName;
    const shopNameEn = patch.shopNameEn ?? current.shopNameEn;
    const taxRate = patch.taxRate ?? current.taxRate;
    const quoteValidDays = patch.quoteValidDays ?? current.quoteValidDays;
    const address = patch.address !== undefined ? patch.address : current.address;
    const phone = patch.phone !== undefined ? patch.phone : current.phone;
    const cashierName = patch.cashierName !== undefined ? patch.cashierName : current.cashierName;
    const taxId = patch.taxId !== undefined ? patch.taxId : current.taxId;
    const branchNo = patch.branchNo !== undefined ? patch.branchNo : current.branchNo;

    const rows = (await manager.query(
      `INSERT INTO settings (tenant_id, shop_name, shop_name_en, tax_rate, quote_valid_days, address, phone, cashier_name, tax_id, branch_no, updated_at)
       VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW())
       ON CONFLICT (tenant_id) DO UPDATE SET
         shop_name = EXCLUDED.shop_name,
         shop_name_en = EXCLUDED.shop_name_en,
         tax_rate = EXCLUDED.tax_rate,
         quote_valid_days = EXCLUDED.quote_valid_days,
         address = EXCLUDED.address,
         phone = EXCLUDED.phone,
         cashier_name = EXCLUDED.cashier_name,
         tax_id = EXCLUDED.tax_id,
         branch_no = EXCLUDED.branch_no,
         updated_at = NOW()
       RETURNING shop_name, shop_name_en, tax_rate, quote_valid_days, address, phone, cashier_name, tax_id, branch_no, updated_at`,
      [tenantId, shopName, shopNameEn, taxRate, quoteValidDays, address, phone, cashierName, taxId, branchNo],
    )) as SettingsRow[];

    this.cache.invalidateAfterCommit(tenantId, 'settings');
    return toSettings(rows[0]);
  }

  getBootstrap(): Promise<BootstrapData> {
    return this.tenants.runTx(() => this.getBootstrapIn());
  }

  private async getBootstrapIn(): Promise<BootstrapData> {
    const { tenantId, manager } = currentRequestContext();

    const productRows = (await manager.query(
      `SELECT id, part_no, name, name_th, category, brand, price, cost, stock, min_stock, compat, image_key, updated_at
         FROM products
        WHERE tenant_id = $1::uuid AND deleted_at IS NULL
        ORDER BY part_no ASC, id ASC`,
      [tenantId],
    )) as ProductRow[];

    const categoryRows = (await manager.query(
      `SELECT name, position
         FROM categories
        WHERE tenant_id = $1::uuid
        ORDER BY position ASC, name ASC`,
      [tenantId],
    )) as CategoryRow[];

    const customerRows = (await manager.query(
      `SELECT id, code, name, name_th, phone, address, points, total_spend, created_at, updated_at
         FROM customers
        WHERE tenant_id = $1::uuid AND deleted_at IS NULL
        ORDER BY code ASC, id ASC`,
      [tenantId],
    )) as CustomerRow[];

    const mechanicRows = (await manager.query(
      `SELECT id, code, name, name_th, nickname, shop_name, phone, note, credit_limit, credit_balance, total_sales, total_credit, total_discount, total_markup, created_at, updated_at
         FROM mechanics
        WHERE tenant_id = $1::uuid AND deleted_at IS NULL
        ORDER BY code ASC, id ASC`,
      [tenantId],
    )) as MechanicRow[];

    const settings = await this.getSettings();

    return {
      products: productRows.map(toProductBootstrap),
      categories: categoryRows.map(c => ({ name: c.name, position: Number(c.position) })),
      customers: customerRows.map(toCustomerBootstrap),
      mechanics: mechanicRows.map(toMechanicBootstrap),
      settings,
    };
  }
}

function toSettings(row: SettingsRow): Settings {
  return {
    shopName: row.shop_name,
    shopNameEn: row.shop_name_en,
    taxRate: Number(row.tax_rate),
    quoteValidDays: Number(row.quote_valid_days),
    address: row.address,
    phone: row.phone,
    cashierName: row.cashier_name,
    taxId: row.tax_id,
    branchNo: row.branch_no,
    updatedAt: row.updated_at instanceof Date ? row.updated_at.toISOString() : new Date(row.updated_at).toISOString(),
  };
}

function toProductBootstrap(row: ProductRow): ProductBootstrap {
  return {
    id: row.id,
    partNo: row.part_no,
    name: row.name,
    nameTH: row.name_th,
    category: row.category,
    brand: row.brand,
    price: Number(row.price),
    cost: Number(row.cost),
    stock: Number(row.stock),
    minStock: Number(row.min_stock),
    compat: row.compat,
    imageKey: row.image_key,
    updatedAt: row.updated_at instanceof Date ? row.updated_at.toISOString() : new Date(row.updated_at).toISOString(),
  };
}

function toCustomerBootstrap(row: CustomerRow): Customer {
  return {
    id: row.id,
    code: row.code,
    name: row.name,
    nameTH: row.name_th,
    phone: row.phone,
    address: row.address,
    points: Number(row.points),
    totalSpend: row.total_spend,
    createdAt: row.created_at instanceof Date ? row.created_at.toISOString() : new Date(row.created_at).toISOString(),
    updatedAt: row.updated_at instanceof Date ? row.updated_at.toISOString() : new Date(row.updated_at).toISOString(),
    deletedAt: null,
  };
}

function toMechanicBootstrap(row: MechanicRow): Mechanic {
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
    createdAt: row.created_at instanceof Date ? row.created_at.toISOString() : new Date(row.created_at).toISOString(),
    updatedAt: row.updated_at instanceof Date ? row.updated_at.toISOString() : new Date(row.updated_at).toISOString(),
    deletedAt: null,
  };
}
