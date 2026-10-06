import { BadRequestException } from '@nestjs/common';
import { optionalUuid, parseUuid } from '../common/ids.js';
import { toSatang } from '../common/money.js';

/** A validated `POST /shifts/open` body. */
export interface ShiftOpenBody {
  id?: string;
  startingCashSatang: number;
}

/** A validated `POST /shifts/current/entries` body. */
export interface DrawerEntryBody {
  id: string | null;
  type: 'in' | 'out';
  amountSatang: number;
  note: string | null;
}

/**
 * `POST /shifts/open`, and `/sync/push` `shift.open` (#619). No `openedAt` here: online,
 * the server's `now()` dates the shift; only the push reads a device time (08 §10, #411).
 */
export function parseShiftOpen(body: unknown): ShiftOpenBody {
  const b = asObject(body);
  return {
    id: b.id === undefined || b.id === null ? undefined : parseUuid(b.id, 'id'),
    startingCashSatang: cash(b.startingCash, 'startingCash'),
  };
}

/**
 * `POST /shifts/current/entries`, and `/sync/push` `drawer.entry` (#619). No `createdAt`
 * here, for the same reason as {@link parseShiftOpen}.
 */
export function parseDrawerEntry(body: unknown): DrawerEntryBody {
  const b = asObject(body);
  if (b.type !== 'in' && b.type !== 'out') {
    throw new BadRequestException(`type must be 'in' or 'out'`);
  }
  const amountSatang = toSatang(b.amount, 'amount');
  if (amountSatang <= 0)
    throw new BadRequestException('amount must be greater than zero');
  return {
    id: optionalUuid(b.id, 'id'),
    type: b.type,
    amountSatang,
    note: b.note === undefined || b.note === null ? null : String(b.note),
  };
}

/**
 * Cash counted into or out of the drawer. Required and non-negative, both on purpose:
 * a defaulted `0` closes the day at zero counted cash, and the closing report then
 * shows a shortfall the size of the day's takings — which §3.11 names as the thing
 * that makes staff stop believing the report at all.
 */
export function cash(value: unknown, field: string): number {
  if (value === undefined || value === null || value === '') {
    throw new BadRequestException(`${field} is required`);
  }
  const satang = toSatang(value, field);
  if (satang < 0)
    throw new BadRequestException(`${field} must not be negative`);
  return satang;
}

export function asObject(body: unknown): Record<string, unknown> {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new BadRequestException('body must be an object');
  }
  return body as Record<string, unknown>;
}
