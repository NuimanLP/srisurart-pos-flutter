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
  receiptNo?: string | null;
  subtotalSatang: number;
  discountSatang: number;
  totalSatang: number;
  paymentMethod: string;
  customerId: string | null;
  customerName: string | null;
  mechanicId: string | null;
  mechanicName: string | null;
  mechanicDeltaSatang: number | null;
  /** The counter confirmed 'ยืนยันขายเครดิต?' — the bill may push the mechanic past the limit. */
  overrideCreditLimit: boolean;
  items: SaleLine[];
  /**
   * Set ONLY by `/sync/push` (`SyncService`), never parsed from a body: an online
   * bill is `sold_offline = false` and dated by the server's `now()` (08 §10/§12, #411).
   */
  soldOffline?: boolean;
  /** The device-recorded (clamped) date — `/sync/push` only, same rule as `soldOffline`. */
  date?: Date | string | null;
}

/**
 * The most a single bill may carry — a guard against a body that is an attack. Shared
 * with quotes (#27), which convert into a bill.
 */
export const MAX_LINES = 200;

/**
 * The exact three literals a sale can ever be created with. `checkout_screen.dart:2355`
 * is the only code that creates one, so — per CLAUDE.md, "Thai UI strings = behaviour
 * parity" — it is the source, not `01_DATABASE.md`'s DDL comment (which listed a fourth,
 * `'บัตร'`, that no screen has ever offered; that comment has been corrected). Rejecting
 * anything outside this set at the boundary is what stops a typo on `'เครดิตช่าง'` (a
 * trailing space, one dropped character) from silently landing as an unrecognised cash
 * sale that #21's mechanic-credit math and the cash/credit closing report never catch.
 */
const PAYMENT_METHODS = ['เงินสด', 'โอน/QR', 'เครดิตช่าง'] as const;

/**
 * Validates the body by hand. Nest's `ValidationPipe` wants `class-validator`, which
 * this server does not depend on; the rules here are few and the errors they raise are
 * plain `400`s, which is what a malformed body is.
 *
 * Two fields are **not** read even when present, because a client that could choose
 * them could choose someone else's: `shiftId` (stamped from the device's own open drawer)
 * and anything naming a tenant or a device (ADR-0004). Nor are `date` and `soldOffline`
 * (#411): an online bill is dated by the server's `now()` and is never an offline bill
 * (08 §10/§12) — only `/sync/push` sets them, after parsing. They are dropped rather than
 * refused because they are harmless once ignored, like `shiftId`.
 * `receiptNo` is optional (Phase 2):
 * when present, the server validates it against the caller's device token and records
 * the high-water mark; when omitted, the server falls back to issuing one (C16).
 */
export function parseCreateSale(body: unknown): CreateSale {
  const b = asObject(body, 'body');
  const items = parseItemsArray(b.items);

  const sale: CreateSale = {
    subtotalSatang: toSatang(b.subtotal, 'subtotal'),
    discountSatang: toSatang(b.discount ?? 0, 'discount'),
    totalSatang: toSatang(b.total, 'total'),
    ...parseSaleParty(b),
    items: parseLines(items),
  };
  assertMoneyMakesSense(sale);
  return sale;
}

/** Everything on a sale that is not its lines or its money. */
export type SaleParty = Omit<
  CreateSale,
  'subtotalSatang' | 'discountSatang' | 'totalSatang' | 'items'
>;

/**
 * The bill's id, payment method, customer, mechanic and override flag — shared by
 * `POST /sales` and `POST /quotes/:id/convert` (#27), whose lines and money come from
 * the saved quote instead of the body.
 */
export function parseSaleParty(b: Record<string, unknown>): SaleParty {
  return {
    id: requiredString(b.id, 'id'),
    receiptNo: optionalString(b.receiptNo, 'receiptNo'),
    paymentMethod: requiredPaymentMethod(b.paymentMethod),
    customerId: optionalString(b.customerId, 'customerId'),
    customerName: optionalString(b.customerName, 'customerName'),
    mechanicId: optionalString(b.mechanicId, 'mechanicId'),
    mechanicName: optionalString(b.mechanicName, 'mechanicName'),
    mechanicDeltaSatang:
      b.mechanicDelta === undefined || b.mechanicDelta === null
        ? null
        : toSatang(b.mechanicDelta, 'mechanicDelta'),
    // Strictly a boolean: `"false"` is truthy in JS, and a client sending the string
    // would confirm an override it never showed the dialog for.
    overrideCreditLimit: booleanOrFalse(
      b.overrideCreditLimit,
      'overrideCreditLimit',
    ),
  };
}

/**
 * The money has to be internally coherent before it is stored, because within the
 * tolerance `SalesService` stores the client's own numbers verbatim.
 *
 * A negative discount is the sharp one: nothing else rejects it, it inflates the
 * total, and `pointsGranted` is computed from the total that gets persisted.
 */
export function assertMoneyMakesSense(sale: {
  subtotalSatang: number;
  discountSatang: number;
  totalSatang: number;
}): void {
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

/** `items` as an array of 1..MAX_LINES entries — the same bound on a bill and a quote. */
export function parseItemsArray(value: unknown): unknown[] {
  const items = Array.isArray(value) ? value : [];
  if (items.length === 0)
    throw new BadRequestException('items must not be empty');
  if (items.length > MAX_LINES) {
    throw new BadRequestException(`items must hold at most ${MAX_LINES} lines`);
  }
  return items;
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
  const qty = parseLineQty(l.qty, index);
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
  const priceSatang = parseLinePrice(l.price, index);
  return {
    lineNo: (l.lineNo as number | undefined) ?? index + 1,
    productId: requiredString(l.productId, `items[${index}].productId`),
    partNo: optionalString(l.partNo, `items[${index}].partNo`),
    name: requiredString(l.name, `items[${index}].name`),
    nameTH: optionalString(l.nameTH, `items[${index}].nameTH`),
    qty,
    priceSatang,
  };
}

/**
 * `products.stock` is an INT, so a qty past that range can only ever be refused —
 * bounding it here makes it a 400 rather than an overflow deeper in.
 */
export function parseLineQty(qty: unknown, index: number): number {
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
  return qty;
}

/**
 * The same trap as a negative discount, one level down: `assertMoneyMakesSense` only
 * ever sees the three totals and `sale_items` only CHECKs `qty > 0`, so a line priced
 * at -1000 nets a total of 0 while still deducting that line's stock (#75). Shared with
 * quotes (#27), which become bills.
 */
export function parseLinePrice(price: unknown, index: number): number {
  const priceSatang = toSatang(price, `items[${index}].price`);
  if (priceSatang < 0) {
    throw new BadRequestException(`items[${index}].price must not be negative`);
  }
  return priceSatang;
}

export function asObject(
  value: unknown,
  field: string,
): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new BadRequestException(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

export function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new BadRequestException(`${field} is required`);
  }
  return value;
}

function requiredPaymentMethod(value: unknown): string {
  const method = requiredString(value, 'paymentMethod');
  if (!(PAYMENT_METHODS as readonly string[]).includes(method)) {
    throw new BadRequestException(
      `paymentMethod must be one of ${PAYMENT_METHODS.join(', ')}, got ${JSON.stringify(value)}`,
    );
  }
  return method;
}

function booleanOrFalse(value: unknown, field: string): boolean {
  if (value === undefined || value === null) return false;
  if (typeof value !== 'boolean')
    throw new BadRequestException(`${field} must be a boolean`);
  return value;
}

export function optionalString(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string')
    throw new BadRequestException(`${field} must be a string`);
  return value;
}
