import { BadRequestException } from '@nestjs/common';
import type { Request } from 'express';
import { fromSatang, toSatang } from '../common/money.js';

/**
 * Hand-validated bodies for the catalogue writes (#16), like `people.dto.ts` —
 * Nest's `ValidationPipe` wants `class-validator`, which this server does not use.
 *
 * Fields the server owns are not read even when a client sends them: `id` (minted
 * as `newId('p')` / `newId('sup')`, as the Dart repositories do), `updatedAt`,
 * `deletedAt`, and — on a product PATCH — `stock`. Stock moves only through
 * `adjust-stock`, sales, returns and PO receipts, each of which writes `movements`;
 * the Products screen already strips `stock` from its edit patch
 * (`products_screen.dart`, "Strip stock + partNo from the patch").
 */

export interface ProductCreate {
  partNo: string;
  name: string;
  nameTH: string;
  category: string;
  brand: string;
  price: string;
  cost: string;
  stock: number;
  minStock: number;
  compat: string | null;
}

export type ProductPatch = Partial<Omit<ProductCreate, 'stock'>>;

/** The two manual types `products_screen.dart` sends; the ledger CHECK allows no others. */
export const ADJUSTMENT_TYPES = ['adjustment-in', 'adjustment-out'] as const;

export interface StockAdjustment {
  delta: number;
  type: (typeof ADJUSTMENT_TYPES)[number];
  note: string | null;
}

export interface SupplierCreate {
  productId: string;
  name: string;
  unitCost: string;
  freight: string;
}

export type SupplierPatch = Partial<SupplierCreate>;

const INT4_MAX = 2_147_483_647;

export function parseProductCreate(body: unknown): ProductCreate {
  const b = asObject(body);
  return {
    partNo: partNo(b.partNo),
    name: requiredString(b.name, 'name'),
    nameTH: stringOrEmpty(b.nameTH, 'nameTH'),
    category: stringOrEmpty(b.category, 'category'),
    brand: stringOrEmpty(b.brand, 'brand'),
    price: nonNegativeMoney(b.price ?? '0.00', 'price'),
    cost: nonNegativeMoney(b.cost ?? '0.00', 'cost'),
    // `products.stock` is `CHECK (stock >= 0)`; a negative one is a 400 here rather
    // than a `23514` surfacing as a 500.
    stock: integer(b.stock ?? 0, 'stock', 0),
    minStock: integer(b.minStock ?? 0, 'minStock'),
    compat: optionalString(b.compat, 'compat'),
  };
}

export function parseProductPatch(body: unknown): ProductPatch {
  const b = asObject(body);
  const out: ProductPatch = {};
  if (has(b, 'partNo')) out.partNo = partNo(b.partNo);
  if (has(b, 'name')) out.name = requiredString(b.name, 'name');
  if (has(b, 'nameTH')) out.nameTH = stringOrEmpty(b.nameTH, 'nameTH');
  if (has(b, 'category')) out.category = stringOrEmpty(b.category, 'category');
  if (has(b, 'brand')) out.brand = stringOrEmpty(b.brand, 'brand');
  if (has(b, 'price')) out.price = nonNegativeMoney(b.price, 'price');
  if (has(b, 'cost')) out.cost = nonNegativeMoney(b.cost, 'cost');
  if (has(b, 'minStock')) out.minStock = integer(b.minStock, 'minStock');
  if (has(b, 'compat')) out.compat = optionalString(b.compat, 'compat');
  return out;
}

/**
 * `{ delta, type, note }` (02_API_SCREENS.md §3.2). Validated before anything is
 * clamped: the clamp at zero is the documented rule for a *valid* manual correction
 * (01_DATABASE.md §7.6), and a clamp applied to unchecked input turns a bad request
 * into a silent stock of 0.
 *
 * A type whose direction contradicts the sign of `delta` is refused: the screen
 * always derives it (`d > 0 ? 'adjustment-in' : 'adjustment-out'`), and a ledger row
 * labelled "in" that removed stock would mislead every reader of `movements.type`.
 * A zero delta is accepted with either type, as the screen can send one.
 */
export function parseStockAdjustment(body: unknown): StockAdjustment {
  const b = asObject(body);
  if (b.delta === undefined || b.delta === null) {
    throw new BadRequestException('delta is required');
  }
  const delta = integer(b.delta, 'delta', -INT4_MAX);
  if (!(ADJUSTMENT_TYPES as readonly unknown[]).includes(b.type)) {
    throw new BadRequestException(
      `type must be one of ${ADJUSTMENT_TYPES.join(', ')}`,
    );
  }
  const type = b.type as StockAdjustment['type'];
  if (
    (delta > 0 && type === 'adjustment-out') ||
    (delta < 0 && type === 'adjustment-in')
  ) {
    throw new BadRequestException(
      `type ${type} does not match the sign of delta ${delta}`,
    );
  }
  return { delta, type, note: optionalString(b.note, 'note') };
}

/** `db.js addCategory`: the name is trimmed; a blank one is not a category. */
export function parseCategoryCreate(body: unknown): { name: string } {
  const b = asObject(body);
  return { name: requiredString(b.name, 'name').trim() };
}

export function parseSupplierCreate(body: unknown): SupplierCreate {
  const b = asObject(body);
  return {
    productId: requiredString(b.productId, 'productId'),
    name: requiredString(b.name, 'name'),
    unitCost: nonNegativeMoney(b.unitCost, 'unitCost'),
    freight: nonNegativeMoney(b.freight ?? '0.00', 'freight'),
  };
}

export function parseSupplierPatch(body: unknown): SupplierPatch {
  const b = asObject(body);
  const out: SupplierPatch = {};
  if (has(b, 'productId'))
    out.productId = requiredString(b.productId, 'productId');
  if (has(b, 'name')) out.name = requiredString(b.name, 'name');
  if (has(b, 'unitCost'))
    out.unitCost = nonNegativeMoney(b.unitCost, 'unitCost');
  if (has(b, 'freight')) out.freight = nonNegativeMoney(b.freight, 'freight');
  return out;
}

export interface AuthenticatedRequest extends Request {
  user: { userId: string; role?: string; deviceId?: string };
}

/** `db.js addProduct`: the part number is trimmed, and a blank one is refused. */
function partNo(value: unknown): string {
  return requiredString(value, 'partNo').trim();
}

export function asObject(body: unknown): Record<string, unknown> {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new BadRequestException('body must be an object');
  }
  return body as Record<string, unknown>;
}

function has(value: Record<string, unknown>, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, key);
}

export function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new BadRequestException(`${field} is required`);
  }
  return value;
}

/** `nameTH` and `brand` are NOT NULL but may be empty — the screen trims and sends ''. */
export function stringOrEmpty(value: unknown, field: string): string {
  if (value === undefined || value === null) return '';
  if (typeof value !== 'string') {
    throw new BadRequestException(`${field} must be a string`);
  }
  return value;
}

function optionalString(value: unknown, field: string): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') {
    throw new BadRequestException(`${field} must be a string`);
  }
  return value;
}

export function integer(value: unknown, field: string, min = -INT4_MAX): number {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new BadRequestException(`${field} must be an integer`);
  }
  if (value < min || value > INT4_MAX) {
    throw new BadRequestException(
      `${field} must be between ${min} and ${INT4_MAX}`,
    );
  }
  return value;
}

export function nonNegativeMoney(value: unknown, field: string): string {
  const amount = toSatang(value, field);
  if (amount < 0) {
    throw new BadRequestException(`${field} must not be negative`);
  }
  return fromSatang(amount);
}
