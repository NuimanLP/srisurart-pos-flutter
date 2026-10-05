import { BadRequestException } from '@nestjs/common';
import { isUuid, optionalUuid, parseUuid } from '../common/ids.js';

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

/**
 * #616: every id an op's payload names, checked before any SQL. A bad one is a 400
 * `INVALID_ID`, which `SyncService.mapOpError` turns into this op's `rejected` result
 * (08 §10: a field that cannot be parsed rejects the op) — never a 22P02, which is not
 * an `HttpException` and would read as `retry`, coming back forever. An absent optional
 * id is left to the op's own rules.
 */
export function assertOpIds(op: SyncOpDto): void {
  const p = op.payload;
  const req = (field: string) => parseUuid(p[field], `payload.${field}`);
  const opt = (...fields: string[]) => {
    for (const f of fields) optionalUuid(p[f], `payload.${f}`);
  };
  const lines = () => {
    if (!Array.isArray(p.items)) return;
    p.items.forEach((l: unknown, i: number) => {
      if (typeof l === 'object' && l !== null) {
        parseUuid(
          (l as Record<string, unknown>).productId,
          `payload.items[${i}].productId`,
        );
      }
    });
  };
  switch (op.type as SyncOpType) {
    case 'sale.create':
      req('id');
      opt('customerId', 'mechanicId', 'quoteId');
      lines();
      return;
    case 'return.create':
      opt('id');
      req('saleId');
      lines();
      return;
    case 'credit_payment.create':
      opt('id');
      req('mechanicId');
      return;
    case 'customer.update':
      req('id');
      return;
    case 'sale.void_offline':
      req('saleId');
      return;
    case 'shift.open':
    case 'drawer.entry':
    case 'customer.create':
      opt('id');
      return;
  }
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

