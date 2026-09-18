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
