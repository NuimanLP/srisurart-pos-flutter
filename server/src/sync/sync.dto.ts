import { BadRequestException } from '@nestjs/common';
import { isUuid, optionalUuid, parseUuid } from '../common/ids.js';
import { toSatang } from '../common/money.js';
import {
  parseCreateCreditPayment,
  type CreateCreditPayment,
} from '../mechanics/credit-payments.dto.js';
import {
  parseCustomerCreate,
  parseCustomerPatch,
  type CustomerCreate,
  type CustomerPatch,
} from '../people/people.dto.js';
import { parseCreateReturn, type CreateReturn } from '../returns/returns.dto.js';
import { parseCreateSale, parseSaleQuoteId, type CreateSale } from '../sales/sales.dto.js';
import {
  parseDrawerEntry,
  parseShiftOpen,
  type DrawerEntryBody,
  type ShiftOpenBody,
} from '../shifts/shifts.dto.js';

export interface SyncOpDto {
  opId: string;
  idempotencyKey: string;
  type: string;
  payload: Record<string, any>;
}

export interface SyncPushDto {
  outboxRemaining: number;
  ops: SyncOpDto[];
}

export type SyncOpResult =
  | {
      opId: string;
      status: 'applied';
      response: any;
    }
  | {
      opId: string;
      status: 'rejected';
      code: string;
      message: string;
      details?: any;
    }
  | {
      opId: string;
      status: 'retry';
    };

export interface SyncPushResponse {
  results: SyncOpResult[];
}

export const MAX_SYNC_OPS = 50;

export const SYNC_OP_TYPES = [
  'sale.create',
  'return.create',
  'shift.open',
  'drawer.entry',
  'credit_payment.create',
  'customer.create',
  'customer.update',
  'sale.void_offline',
] as const;

export type SyncOpType = (typeof SYNC_OP_TYPES)[number];

export function parseSyncPush(body: unknown): SyncPushDto {
  if (typeof body !== 'object' || body === null) {
    throw new BadRequestException('Request body must be an object');
  }
  const b = body as Record<string, unknown>;

  if (
    typeof b.outboxRemaining !== 'number' ||
    !Number.isInteger(b.outboxRemaining) ||
    b.outboxRemaining < 0
  ) {
    throw new BadRequestException('outboxRemaining must be an integer >= 0');
  }
  const outboxRemaining = b.outboxRemaining;

  if (!Array.isArray(b.ops)) {
    throw new BadRequestException('ops must be an array');
  }

  if (b.ops.length === 0) {
    throw new BadRequestException('ops array must not be empty');
  }

  if (b.ops.length > MAX_SYNC_OPS) {
    throw new BadRequestException(
      `OP_BATCH_TOO_LARGE: ops must hold at most ${MAX_SYNC_OPS} operations`,
    );
  }

  const ops: SyncOpDto[] = b.ops.map((raw, idx) => {
    if (typeof raw !== 'object' || raw === null) {
      throw new BadRequestException(`ops[${idx}] must be an object`);
    }
    const o = raw as Record<string, unknown>;
    // #616: a malformed opId refuses the whole envelope — a per-op result is keyed BY
    // its opId, so there is nothing sound to report a rejection under.
    const opId = parseUuid(o.opId, `ops[${idx}].opId`);
    if (typeof o.idempotencyKey !== 'string' || !o.idempotencyKey.trim()) {
      throw new BadRequestException(
        `ops[${idx}].idempotencyKey must be a non-empty string`,
      );
    }
    if (typeof o.type !== 'string' || !o.type.trim()) {
      throw new BadRequestException(`ops[${idx}].type must be a non-empty string`);
    }
    const trimmedType = o.type.trim();
    if (!SYNC_OP_TYPES.includes(trimmedType as any)) {
      throw new BadRequestException(`Unknown operation type: ${trimmedType}`);
    }
    if (typeof o.payload !== 'object' || o.payload === null) {
      throw new BadRequestException(`ops[${idx}].payload must be an object`);
    }
    return {
      opId,
      idempotencyKey: o.idempotencyKey.trim(),
      type: trimmedType,
      payload: o.payload as Record<string, any>,
    };
  });

  return {
    outboxRemaining,
    ops,
  };
}

export interface SyncDiscardDto {
  opId: string;
  type: string;
  clientId?: string;
  payload?: Record<string, unknown>;
  lastCode?: string;
  note: string;
}

export function parseSyncDiscard(body: unknown): SyncDiscardDto {
  if (typeof body !== 'object' || body === null) {
    throw new BadRequestException('Request body must be an object');
  }
  const b = body as Record<string, unknown>;
  const opId = parseUuid(b.opId, 'opId');
  if (typeof b.type !== 'string' || !b.type.trim()) {
    throw new BadRequestException('type must be a non-empty string');
  }
  if (typeof b.note !== 'string' || !b.note.trim()) {
    throw new BadRequestException('note must be a non-empty string');
  }
  // #616: a malformed client id is NOT refused. Discarding is how the owner clears an op
  // that push rejected (`INVALID_ID` included); refusing the discard over the same bad id
  // would leave it in the outbox for good. `targetIdOf` reads it as "no such row".
  // A non-UUID `opId` is different: it is refused here (400, above) AND by `/sync/push`
  // (the whole envelope, `parseSyncPush`), so discard is NOT an escape hatch for an op
  // queued with a legacy opId — the #616 cutover requires wiped client outboxes.
  const clientId =
    typeof b.clientId === 'string' && b.clientId !== '' ? b.clientId : undefined;
  const lastCode =
    typeof b.lastCode === 'string' && b.lastCode.trim() !== ''
      ? b.lastCode.trim()
      : undefined;
  const payload =
    typeof b.payload === 'object' && b.payload !== null
      ? (b.payload as Record<string, unknown>)
      : undefined;

  return {
    opId,
    type: b.type.trim(),
    clientId,
    payload,
    lastCode,
    note: b.note.trim(),
  };
}

/** One op after {@link parseOpPayload}: the envelope plus its typed payload. */
export type ParsedSyncOp = {
  opId: string;
  idempotencyKey: string;
} & (
  | { type: 'sale.create'; sale: CreateSale; quoteId: string | null; deviceDate: Date | undefined }
  | { type: 'return.create'; ret: CreateReturn; deviceDate: Date | undefined }
  | { type: 'shift.open'; shift: ShiftOpenBody; openedAt: Date | undefined }
  | { type: 'drawer.entry'; entry: DrawerEntryBody; deviceDate: Date | undefined }
  | { type: 'credit_payment.create'; mechanicId: string; payment: CreateCreditPayment }
  | { type: 'customer.create'; customer: CustomerCreate }
  | { type: 'customer.update'; id: string; patch: CustomerPatch }
  | { type: 'sale.void_offline'; saleId: string; reason: string }
);

/**
 * #619: the one parser per op type, run after the key replay (B1, 08 §8.3) and before any
 * other SQL — never before the replay. Each reuses its online route's
 * parser, so an op is refused for exactly what the online request would be (an empty id
 * included), and an id the online route takes from its URL (`mechanicId`, the customer's
 * or the bill's id) is checked as `ParseUuidPipe` checks it. A bad id is a 400
 * `INVALID_ID` naming `payload.<field>`, which `SyncService.mapOpError` turns into this
 * op's `rejected` result (08 §10) — never a 22P02, which would read as `retry` and come
 * back forever.
 */
export function parseOpPayload(op: SyncOpDto): ParsedSyncOp {
  const env = { opId: op.opId, idempotencyKey: op.idempotencyKey };
  const p = op.payload;
  try {
    switch (op.type as SyncOpType) {
      case 'sale.create':
        return {
          ...env,
          type: 'sale.create',
          deviceDate: deviceDateOf(p),
          sale: parseCreateSale(p),
          quoteId: parseSaleQuoteId(p),
        };
      case 'return.create':
        return {
          ...env,
          type: 'return.create',
          deviceDate: deviceDateOf(p),
          ret: parseCreateReturn(p),
        };
      case 'shift.open':
        return {
          ...env,
          type: 'shift.open',
          openedAt: deviceIsoDate(p.openedAt, 'openedAt'),
          shift: parseShiftOpen(p),
        };
      case 'drawer.entry':
        return {
          ...env,
          type: 'drawer.entry',
          deviceDate: deviceDateOf(p),
          entry: parseDrawerEntry(p),
        };
      case 'credit_payment.create':
        return {
          ...env,
          type: 'credit_payment.create',
          mechanicId: parseUuid(p.mechanicId, 'mechanicId'),
          // An offline payment never showed the overpayment dialog.
          payment: { ...parseCreateCreditPayment(p), allowOverpayment: false },
        };
      case 'customer.create':
        // Online the server mints the id; a queued customer brings its own.
        return {
          ...env,
          type: 'customer.create',
          customer: { ...parseCustomerCreate(p), id: optionalUuid(p.id, 'id') },
        };
      case 'customer.update':
        return {
          ...env,
          type: 'customer.update',
          id: parseUuid(p.id, 'id'),
          patch: parseCustomerPatch(p),
        };
      case 'sale.void_offline':
        return {
          ...env,
          type: 'sale.void_offline',
          saleId: parseUuid(p.saleId, 'saleId'),
          reason: voidReason(p.reason),
        };
    }
  } catch (err) {
    throw inPayload(err);
  }
  // Unreachable: `parseSyncPush` admits only `SYNC_OP_TYPES`.
  throw new BadRequestException(`Unknown operation type: ${op.type}`);
}

/**
 * What the client-id replay (08 §8.3 step 2) reads of an op — from the payload as sent,
 * BEFORE {@link parseOpPayload}, so a document the server already holds replays even
 * when today's parser would refuse its body (key row gone: 24 h TTL, or B2). Only the
 * client id and the fields step 2 compares with the stored row are read, and nothing
 * here throws: a non-UUID id gives `null` (no replay — the parser then refuses it,
 * `INVALID_ID`); an amount that does not read gives `null`, which never equals a stored
 * amount, so the op is `CLIENT_ID_REUSED` like any other content mismatch.
 * `customer.update` never replays by id.
 */
export type ReplayProbe =
  | { type: 'sale.create'; id: string; totalSatang: number | null; receiptNo: unknown }
  | {
      type: 'return.create';
      id: string;
      saleId: unknown;
      cnNo: unknown;
      items: { productId: unknown; qty: unknown; priceSatang: number | null }[];
    }
  | { type: 'shift.open'; id: string; startingCashSatang: number | null }
  | { type: 'drawer.entry'; id: string; entryType: unknown; amountSatang: number | null }
  | {
      type: 'credit_payment.create';
      id: string;
      mechanicId: unknown;
      amountSatang: number | null;
      paymentMethod: unknown;
    }
  | { type: 'customer.create'; id: string }
  | { type: 'sale.void_offline'; id: string; reason: string | null };

export function replayProbeOf(op: SyncOpDto): ReplayProbe | null {
  const p = op.payload;
  const id = op.type === 'sale.void_offline' ? p.saleId : p.id;
  if (!isUuid(id)) return null;
  const type = op.type as SyncOpType;
  switch (type) {
    case 'sale.create':
      return { type, id, totalSatang: satangOrNull(p.total), receiptNo: p.receiptNo };
    case 'return.create':
      return {
        type,
        id,
        saleId: p.saleId,
        cnNo: p.cnNo,
        items: (Array.isArray(p.items) ? p.items : []).map((raw: unknown) => {
          const l = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>;
          return { productId: l.productId, qty: l.qty, priceSatang: satangOrNull(l.price) };
        }),
      };
    case 'shift.open':
      return { type, id, startingCashSatang: satangOrNull(p.startingCash) };
    case 'drawer.entry':
      return { type, id, entryType: p.type, amountSatang: satangOrNull(p.amount) };
    case 'credit_payment.create':
      return {
        type,
        id,
        mechanicId: p.mechanicId,
        amountSatang: satangOrNull(p.amount),
        paymentMethod: p.paymentMethod,
      };
    case 'customer.create':
      return { type, id };
    case 'sale.void_offline':
      return {
        type,
        id,
        reason: typeof p.reason === 'string' && p.reason.trim() !== '' ? p.reason.trim() : null,
      };
    case 'customer.update':
      return null;
  }
}

/** `toSatang` — the parsers' own money leaf — or null where it would refuse. */
function satangOrNull(value: unknown): number | null {
  try {
    return toSatang(value, 'amount');
  } catch {
    return null;
  }
}

/** The op's own id — for a void, the bill it names (`saleId`, #488). */
export function clientIdOf(op: ParsedSyncOp): string | null {
  switch (op.type) {
    case 'sale.create':
      return op.sale.id;
    case 'return.create':
      return op.ret.id ?? null;
    case 'shift.open':
      return op.shift.id ?? null;
    case 'drawer.entry':
      return op.entry.id;
    case 'credit_payment.create':
      return op.payment.id;
    case 'customer.create':
      return op.customer.id ?? null;
    case 'customer.update':
      return op.id;
    case 'sale.void_offline':
      return op.saleId;
  }
}

/** The RC/CN number the device printed, when the op carries one. */
export function docNoOf(op: ParsedSyncOp): string | null {
  if (op.type === 'sale.create') return op.sale.receiptNo ?? null;
  if (op.type === 'return.create') return op.ret.cnNo ?? null;
  return null;
}

/** As online (`voidActorOf`, `sales.controller.ts`): a non-empty reason, trimmed. */
function voidReason(value: unknown): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new BadRequestException('Void reason is required');
  }
  return value.trim();
}

/**
 * 08 §10: `sale.create`/`return.create` carry `date`, `drawer.entry` carries `createdAt`.
 * Present but unparseable — `''` included — is refused, never a fall-through to the other
 * field or to `now()`.
 */
function deviceDateOf(p: Record<string, unknown>): Date | undefined {
  const field = p.date !== undefined && p.date !== null ? 'date' : 'createdAt';
  return deviceIsoDate(p[field], field);
}

/** An optional ISO timestamp from a push payload — refused (400) when present but unparseable. */
function deviceIsoDate(value: unknown, field: string): Date | undefined {
  if (value === undefined || value === null) return undefined;
  const date = typeof value === 'string' ? new Date(value) : null;
  if (!date || isNaN(date.getTime())) {
    throw new BadRequestException(`${field} must be a valid ISO date string`);
  }
  return date;
}

/** The online parsers name `id`, `items[0].productId`…; inside a push it is `payload.…`. */
function inPayload(err: unknown): unknown {
  if (!(err instanceof BadRequestException)) return err;
  const res = err.getResponse() as {
    code?: unknown;
    message?: unknown;
    details?: { field?: unknown };
  };
  const field = res?.details?.field;
  if (res?.code !== 'INVALID_ID' || typeof field !== 'string') return err;
  return new BadRequestException({
    ...res,
    message: `payload.${String(res.message)}`,
    details: { ...res.details, field: `payload.${field}` },
  });
}

/**
 * The row a discard names (#488: a void names its bill as `saleId`), or `undefined`
 * when there is none to look up — a non-UUID included, since no row can carry one.
 */
export function targetIdOf(dto: SyncDiscardDto): string | undefined {
  const raw =
    dto.type === 'sale.void_offline'
      ? dto.payload?.saleId
      : (dto.clientId ?? dto.payload?.id);
  return isUuid(raw) ? raw : undefined;
}

