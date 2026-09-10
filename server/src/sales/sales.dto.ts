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
  if (items.length === 0)
    throw new BadRequestException('items must not be empty');
  if (items.length > MAX_LINES) {
    throw new BadRequestException(`items must hold at most ${MAX_LINES} lines`);
  }

  const sale: CreateSale = {
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
    // `overrideCreditLimit` is deliberately NOT read. §8.2 requires an `audit_log`
    // row naming who overrode a credit limit and by how much, and the credit balance
    // it would override is #21's to write — accepting the flag now would let a client
    // believe an override was recorded when nothing was.
    items: parseLines(items),
  };
  assertMoneyMakesSense(sale);
  return sale;
}

/**
 * The money has to be internally coherent before it is stored, because within the
 * tolerance `SalesService` stores the client's own numbers verbatim.
 *
 * A negative discount is the sharp one: nothing else rejects it, it inflates the
 * total, and `pointsGranted` is computed from the total that gets persisted.
 */
function assertMoneyMakesSense(sale: CreateSale): void {
  if (sale.discountSatang < 0)
    throw new BadRequestException('discount must not be negative');
  if (sale.subtotalSatang < 0)
    throw new BadRequestException('subtotal must not be negative');
  if (sale.totalSatang < 0)
    throw new BadRequestException('total must not be negative');
  if (sale.discountSatang > sale.subtotalSatang) {
    throw new BadRequestException('discount must not exceed subtotal');
  }
  // Whether the three numbers add up is NOT checked here: that is arithmetic the
  // server redoes from the lines, and §1.3 gives it its own status and its own Thai
  // message (`409 TOTAL_MISMATCH`, in `SalesService.assertTotals`). Only values that
  // are malformed on their face belong in a 400.
}

/**
 * `lineNo` is the primary key of a line and the order the receipt prints in, so the
 * client's own numbering is kept — but two lines carrying the same number would
 * collide on `(tenant_id, sale_id, line_no)` as a 500. Reject the ambiguity instead
 * of quietly renumbering: what the receipt in the customer's hand says matters.
 */
function parseLines(items: unknown[]): SaleLine[] {
  const lines = items.map((raw, i) => parseLine(raw, i));
  const seen = new Set<number>();
  for (const line of lines) {
    if (seen.has(line.lineNo)) {
      throw new BadRequestException(
        `items[].lineNo must be unique (${line.lineNo} repeats)`,
      );
    }
    seen.add(line.lineNo);
  }
  return lines;
}

function parseLine(raw: unknown, index: number): SaleLine {
  const l = asObject(raw, `items[${index}]`);
  const qty = l.qty;
  // `products.stock` is an INT, so a qty past that range can only ever be refused —
  // bounding it here makes it a 400 rather than an overflow deeper in.
  if (
    typeof qty !== 'number' ||
    !Number.isInteger(qty) ||
    qty <= 0 ||
    qty > 1_000_000
  ) {
    throw new BadRequestException(
      `items[${index}].qty must be a positive integer`,
    );
  }
  if (
    l.lineNo !== undefined &&
    (typeof l.lineNo !== 'number' ||
      !Number.isInteger(l.lineNo) ||
      l.lineNo < 1)
  ) {
    throw new BadRequestException(
      `items[${index}].lineNo must be a positive integer`,
    );
  }
  return {
    lineNo: (l.lineNo as number | undefined) ?? index + 1,
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
  if (typeof value !== 'string')
    throw new BadRequestException(`${field} must be a string`);
  return value;
}
