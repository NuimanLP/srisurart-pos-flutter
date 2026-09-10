import { BadRequestException } from '@nestjs/common';
import { toSatang } from '../common/money.js';

/** One cart line as the client sends it, with money already in satang. */
export interface SaleLine {
  lineNo: number;
  productId: string;
  partNo: string | null;
  name: string;
  nameTH: string | null;
  qty: number;
  priceSatang: number;
}

/** A validated `POST /sales` body. Money is satang; ids are the client's. */
export interface CreateSale {
  id: string;
  subtotalSatang: number;
  discountSatang: number;
  totalSatang: number;
  paymentMethod: string;
  customerId: string | null;
  customerName: string | null;
  mechanicId: string | null;
  mechanicName: string | null;
  mechanicDeltaSatang: number | null;
  overrideCreditLimit: boolean;
  items: SaleLine[];
}

/** The most a single bill may carry — a guard against a body that is an attack. */
const MAX_LINES = 200;

/**
 * Validates the body by hand. Nest's `ValidationPipe` wants `class-validator`, which
 * this server does not depend on; the rules here are few and the errors they raise are
 * plain `400`s, which is what a malformed body is.
 *
 * Three fields are **not** read even when present, because a client that could choose
 * them could choose someone else's: `receiptNo` (phase 1 issues it server-side,
 * ADR-0007), `shiftId` (stamped from the device's own open drawer) and anything
 * naming a tenant or a device (ADR-0004).
 */
export function parseCreateSale(body: unknown): CreateSale {
  const b = asObject(body, 'body');
  const items = Array.isArray(b.items) ? b.items : [];
  if (items.length === 0) throw new BadRequestException('items must not be empty');
  if (items.length > MAX_LINES) {
    throw new BadRequestException(`items must hold at most ${MAX_LINES} lines`);
  }

  return {
    id: requiredString(b.id, 'id'),
    subtotalSatang: toSatang(b.subtotal, 'subtotal'),
    discountSatang: toSatang(b.discount ?? 0, 'discount'),
    totalSatang: toSatang(b.total, 'total'),
    paymentMethod: requiredString(b.paymentMethod, 'paymentMethod'),
    customerId: optionalString(b.customerId, 'customerId'),
    customerName: optionalString(b.customerName, 'customerName'),
    mechanicId: optionalString(b.mechanicId, 'mechanicId'),
    mechanicName: optionalString(b.mechanicName, 'mechanicName'),
    mechanicDeltaSatang:
      b.mechanicDelta === undefined || b.mechanicDelta === null
        ? null
        : toSatang(b.mechanicDelta, 'mechanicDelta'),
    overrideCreditLimit: b.overrideCreditLimit === true,
    items: items.map((raw, i) => parseLine(raw, i)),
  };
}

function parseLine(raw: unknown, index: number): SaleLine {
  const l = asObject(raw, `items[${index}]`);
  const qty = l.qty;
  if (typeof qty !== 'number' || !Number.isInteger(qty) || qty <= 0) {
    throw new BadRequestException(`items[${index}].qty must be a positive integer`);
  }
  return {
    lineNo: typeof l.lineNo === 'number' && Number.isInteger(l.lineNo) ? l.lineNo : index + 1,
    productId: requiredString(l.productId, `items[${index}].productId`),
    partNo: optionalString(l.partNo, `items[${index}].partNo`),
    name: requiredString(l.name, `items[${index}].name`),
    nameTH: optionalString(l.nameTH, `items[${index}].nameTH`),
    qty,
    priceSatang: toSatang(l.price, `items[${index}].price`),
  };
}

function asObject(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new BadRequestException(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new BadRequestException(`${field} is required`);
  }
  return value;
}

function optionalString(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string') throw new BadRequestException(`${field} must be a string`);
  return value;
}
