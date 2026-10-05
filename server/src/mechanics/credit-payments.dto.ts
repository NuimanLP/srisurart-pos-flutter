import { BadRequestException } from '@nestjs/common';
import { parseUuid } from '../common/ids.js';
import { toSatang } from '../common/money.js';

/** A validated `POST /mechanics/:id/credit-payments` body. */
export interface CreateCreditPayment {
  /**
   * The client's own id for this payment, when it sent one — the second defence
   * against a duplicate, after the `Idempotency-Key`. See `CreditPaymentsService`.
   */
  id: string | null;
  amountSatang: number;
  paymentMethod: string;
  note: string | null;
  /** The counter confirmed 'ยืนยันรับเงิน?' — this payment is more than the tab. */
  allowOverpayment: boolean;
}

/**
 * The two ways a mechanic settles his tab, copied from the intake dialog
 * (`mechanics_screen.dart:1470`) rather than from the sale's list: `'เครดิตช่าง'` is
 * not among them, because paying a tab with the tab is nothing at all.
 *
 * Required, not defaulted. A payment whose method the server guessed is a payment the
 * closing report counts wrong in one direction or the other, and the shortfall it
 * produces is the exact failure this endpoint exists to avoid.
 */
const PAYMENT_METHODS = ['เงินสด', 'โอน/QR'] as const;

/**
 * Validates the body by hand, like `sales.dto.ts` and `returns.dto.ts` — Nest's
 * `ValidationPipe` wants `class-validator`, which this server does not depend on.
 *
 * Four things are deliberately not read even when present: `receiptNo` (phase 1 issues
 * every document number server-side, ADR-0007), `shiftId` (stamped from the device's
 * own open drawer), `mechanicId` (the path names it) and anything naming a tenant or a
 * device (ADR-0004).
 *
 * `id` IS read, and optional. The Dart repository already mints the id (a UUIDv7) before
 * it writes, exactly as the sale path mints the bill id, and a retry that lost its
 * `Idempotency-Key` — an app restart after a dropped reply — is otherwise a second
 * payment: a partial one is not caught by the overpayment check, and the intake
 * dialog's quick-amount chips make partial the common case.
 */
export function parseCreateCreditPayment(body: unknown): CreateCreditPayment {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new BadRequestException('body must be an object');
  }
  const b = body as Record<string, unknown>;

  if (b.amount === undefined || b.amount === null || b.amount === '') {
    throw new BadRequestException('amount is required');
  }
  const amountSatang = toSatang(b.amount, 'amount');
  // `credit_payments.amount` is `CHECK (amount > 0)`; without this the zero or the
  // negative reaches Postgres as a `23514` and surfaces as a 500 rather than as the
  // 400 a nonsense amount has earned. A negative one would also *raise* the tab.
  if (amountSatang <= 0) {
    throw new BadRequestException('amount must be greater than zero');
  }

  return {
    id: optionalId(b.id),
    amountSatang,
    paymentMethod: requiredPaymentMethod(b.paymentMethod),
    note:
      b.note === undefined || b.note === null || b.note === ''
        ? null
        : String(b.note),
    // Strictly a boolean: `"false"` is truthy in JS, and a client sending the string
    // would confirm an overpayment it never showed the dialog for.
    allowOverpayment: booleanOrFalse(b.allowOverpayment, 'allowOverpayment'),
  };
}

function optionalId(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  return parseUuid(value, 'id');
}

function requiredPaymentMethod(value: unknown): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new BadRequestException('paymentMethod is required');
  }
  if (!(PAYMENT_METHODS as readonly string[]).includes(value)) {
    throw new BadRequestException(
      `paymentMethod must be one of ${PAYMENT_METHODS.join(', ')}, got ${JSON.stringify(value)}`,
    );
  }
  return value;
}

function booleanOrFalse(value: unknown, field: string): boolean {
  if (value === undefined || value === null) return false;
  if (typeof value !== 'boolean')
    throw new BadRequestException(`${field} must be a boolean`);
  return value;
}
