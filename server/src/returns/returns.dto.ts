import { BadRequestException } from '@nestjs/common';
import { toSatang } from '../common/money.js';

/** One line of a credit note as the client sends it, with money already in satang. */
export interface ReturnLine {
  productId: string;
  name: string;
  qty: number;
  priceSatang: number;
  /** How many of this product the original bill carried — the old app stores it. */
  originalQty: number | null;
}

/** A validated `POST /returns` body. */
export interface CreateReturn {
  saleId: string;
  refundMethod: string;
  reason: string;
  items: ReturnLine[];
}

/** The most one credit note may carry — the same bound `POST /sales` puts on a bill. */
const MAX_LINES = 200;

/**
 * The three refund methods the Returns screen offers (`returns_screen.dart:902`):
 * cash, transfer, and — only when the bill named a mechanic — deduct from his tab.
 *
 * Note these are NOT the sale's payment methods: a sale's transfer option is
 * `'โอน/QR'`, a refund's is plain `'โอน'`. They are copied from the screen rather
 * than harmonised, because CLAUDE.md makes the Thai strings behaviour parity.
 *
 * The whitelist is what stops a typo on `'หักจากเครดิต'` — a trailing space, one
 * dropped character — from silently becoming a refund that never reduces the
 * mechanic's balance, which is the same trap `parseCreateSale` guards for
 * `'เครดิตช่าง'`.
 */
const REFUND_METHODS = ['เงินสด', 'โอน', 'หักจากเครดิต'] as const;

/**
 * Validates the body by hand, like `sales.dto.ts` — Nest's `ValidationPipe` wants
 * `class-validator`, which this server does not depend on.
 *
 * Three things are deliberately not read even when present: `cnNo` (phase 1 issues
 * every document number server-side, ADR-0007), `shiftId` (stamped from the device's
 * own open drawer) and anything naming a tenant or a device (ADR-0004). The credit
 * note's `id` is the server's too — unlike a sale, the client does not create one
 * ahead of the request, so there is nothing to echo back.
 */
export function parseCreateReturn(body: unknown): CreateReturn {
  const b = asObject(body, 'body');
  const items = Array.isArray(b.items) ? b.items : [];
  if (items.length === 0)
    throw new BadRequestException('items must not be empty');
  if (items.length > MAX_LINES) {
    throw new BadRequestException(`items must hold at most ${MAX_LINES} lines`);
  }

  return {
    saleId: requiredString(b.saleId, 'saleId'),
    refundMethod: requiredRefundMethod(b.refundMethod),
    // `returns.reason` is NOT NULL DEFAULT '' and the old app stores '' when staff
    // typed nothing (`input.reason ?? ''`).
    reason: b.reason === undefined || b.reason === null ? '' : String(b.reason),
    items: items.map((raw, i) => parseLine(raw, i)),
  };
}

function parseLine(raw: unknown, index: number): ReturnLine {
  const l = asObject(raw, `items[${index}]`);
  const qty = l.qty;
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
  // `toSatang` accepts negatives by design (a sale's `mechanicDelta` may be one), and
  // nothing downstream would catch this: the refund total is computed FROM the lines,
  // so a line priced at -1000 nets a smaller refund while still putting that line's
  // stock back on the shelf. The same bug was found and fixed in `sales.dto.ts`.
  const priceSatang = toSatang(l.price, `items[${index}].price`);
  if (priceSatang < 0) {
    throw new BadRequestException(`items[${index}].price must not be negative`);
  }
  return {
    productId: requiredString(l.productId, `items[${index}].productId`),
    name: requiredString(l.name, `items[${index}].name`),
    qty,
    priceSatang,
    originalQty: optionalCount(l.originalQty, `items[${index}].originalQty`),
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

function requiredRefundMethod(value: unknown): string {
  const method = requiredString(value, 'refundMethod');
  if (!(REFUND_METHODS as readonly string[]).includes(method)) {
    throw new BadRequestException(
      `refundMethod must be one of ${REFUND_METHODS.join(', ')}, got ${JSON.stringify(value)}`,
    );
  }
  return method;
}

function optionalCount(value: unknown, field: string): number | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw new BadRequestException(`${field} must be a non-negative integer`);
  }
  return value;
}
