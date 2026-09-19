import { BadRequestException } from '@nestjs/common';

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
    if (typeof o.opId !== 'string' || !o.opId.trim()) {
      throw new BadRequestException(`ops[${idx}].opId must be a non-empty string`);
    }
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
      opId: o.opId.trim(),
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
  if (typeof b.opId !== 'string' || !b.opId.trim()) {
    throw new BadRequestException('opId must be a non-empty string');
  }
  if (typeof b.type !== 'string' || !b.type.trim()) {
    throw new BadRequestException('type must be a non-empty string');
  }
  if (typeof b.note !== 'string' || !b.note.trim()) {
    throw new BadRequestException('note must be a non-empty string');
  }
  const clientId =
    typeof b.clientId === 'string' && b.clientId.trim() !== ''
      ? b.clientId.trim()
      : undefined;
  const lastCode =
    typeof b.lastCode === 'string' && b.lastCode.trim() !== ''
      ? b.lastCode.trim()
      : undefined;
  const payload =
    typeof b.payload === 'object' && b.payload !== null
      ? (b.payload as Record<string, unknown>)
      : undefined;

  return {
    opId: b.opId.trim(),
    type: b.type.trim(),
    clientId,
    payload,
    lastCode,
    note: b.note.trim(),
  };
}

