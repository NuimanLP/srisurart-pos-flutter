import { BadRequestException } from '@nestjs/common';
import { requiredUuid } from '../common/ids.js';
import {
  BANK_CODES,
  decodeQrImage,
  isBankCode,
  isPaymentAccountKind,
  isPromptPayId,
  NICKNAME_MAX_LENGTH,
  normaliseNickname,
  type ImageMime,
  type PaymentAccountKind,
} from './payment-accounts.rules.js';

/** An account on the wire (contract §2). `imageBase64` is plain base64, no `data:` prefix. */
export interface PaymentAccount {
  id: string;
  nickname: string;
  bankCode: string;
  kind: PaymentAccountKind;
  promptpayId: string | null;
  imageBase64: string | null;
  imageMime: ImageMime | null;
  isDefault: boolean;
  sortOrder: number;
  updatedAt: string;
}

/** A decoded image, ready for the `bytea` column. */
export interface QrImage {
  bytes: Buffer;
  mime: ImageMime;
}

/** A validated `POST /payment-accounts` body. */
export type PaymentAccountCreate = {
  id: string;
  nickname: string;
  bankCode: string;
  isDefault: boolean;
  sortOrder: number;
} & (
  | { kind: 'promptpay'; promptpayId: string; image: null }
  | { kind: 'image'; promptpayId: null; image: QrImage }
);

/**
 * A validated `PATCH /payment-accounts/:id` body. `kind`, when sent, is only checked against
 * the stored row (it can never change — delete and create again); `promptpayId` / `image`
 * are checked against the stored kind by the service, which is the only one that knows it.
 */
export interface PaymentAccountPatch {
  kind?: PaymentAccountKind;
  nickname?: string;
  bankCode?: string;
  promptpayId?: string;
  image?: QrImage;
  isDefault?: boolean;
  sortOrder?: number;
}

/**
 * Hand-written like `settings.dto.ts` (no `class-validator` here). Every refusal is a plain
 * `400` with the field named; the id is `INVALID_ID` like every other client-minted id.
 * Unknown keys (`updatedAt`, a PATCH's `id`) are ignored, as `parseSettingsPatch` does.
 */
export function parsePaymentAccountCreate(body: unknown): PaymentAccountCreate {
  const b = asObject(body);
  const id = requiredUuid(b.id, 'id');
  const nickname = requiredNickname(b.nickname);
  const bankCode = requiredBankCode(b.bankCode);
  const isDefault = optionalBoolean(b.isDefault, 'isDefault') ?? false;
  const sortOrder = optionalSortOrder(b.sortOrder) ?? 0;
  if (!isPaymentAccountKind(b.kind)) {
    throw new BadRequestException(`Field 'kind' must be 'promptpay' or 'image'`);
  }
  const common = { id, nickname, bankCode, isDefault, sortOrder };
  if (b.kind === 'promptpay') {
    refuseIfSet(b, 'imageBase64', `Field 'imageBase64' is only for kind 'image'`);
    refuseIfSet(b, 'imageMime', `Field 'imageMime' is only for kind 'image'`);
    return { ...common, kind: 'promptpay', promptpayId: requiredPromptPayId(b.promptpayId), image: null };
  }
  refuseIfSet(b, 'promptpayId', `Field 'promptpayId' is only for kind 'promptpay'`);
  return { ...common, kind: 'image', promptpayId: null, image: requiredImage(b.imageBase64, b.imageMime) };
}

export function parsePaymentAccountPatch(body: unknown): PaymentAccountPatch {
  const b = asObject(body);
  const patch: PaymentAccountPatch = {};
  if (present(b, 'kind')) {
    if (!isPaymentAccountKind(b.kind)) {
      throw new BadRequestException(`Field 'kind' must be 'promptpay' or 'image'`);
    }
    patch.kind = b.kind;
  }
  if (present(b, 'nickname')) patch.nickname = requiredNickname(b.nickname);
  if (present(b, 'bankCode')) patch.bankCode = requiredBankCode(b.bankCode);
  // `null` on the kind-specific fields reads as "not sent": it is what a client sending the
  // whole wire shape puts in the other kind's fields, and none of them can be nulled anyway.
  if (given(b, 'promptpayId')) patch.promptpayId = requiredPromptPayId(b.promptpayId);
  if (given(b, 'imageBase64') || given(b, 'imageMime')) {
    patch.image = requiredImage(b.imageBase64, b.imageMime);
  }
  if (present(b, 'isDefault')) patch.isDefault = optionalBoolean(b.isDefault, 'isDefault') ?? false;
  if (present(b, 'sortOrder')) patch.sortOrder = optionalSortOrder(b.sortOrder) ?? 0;
  return patch;
}

function asObject(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new BadRequestException('Request body must be a JSON object');
  }
  return value as Record<string, unknown>;
}

function present(obj: Record<string, unknown>, key: string): boolean {
  return key in obj && obj[key] !== undefined;
}

function given(obj: Record<string, unknown>, key: string): boolean {
  return obj[key] !== undefined && obj[key] !== null;
}

/** A field of the other kind is refused, not ignored: the client meant something else. */
function refuseIfSet(obj: Record<string, unknown>, key: string, message: string): void {
  if (given(obj, key)) throw new BadRequestException(message);
}

function requiredNickname(v: unknown): string {
  const nickname = normaliseNickname(v);
  if (nickname === null) {
    throw new BadRequestException(`Field 'nickname' must be 1–${NICKNAME_MAX_LENGTH} characters`);
  }
  return nickname;
}

function requiredBankCode(v: unknown): string {
  if (!isBankCode(v)) {
    throw new BadRequestException(`Field 'bankCode' must be one of ${BANK_CODES.join(', ')}`);
  }
  return v as string;
}

function requiredPromptPayId(v: unknown): string {
  if (!isPromptPayId(v)) {
    throw new BadRequestException(
      `Field 'promptpayId' must be 10 digits starting with 0, 13 digits or 15 digits`,
    );
  }
  return v;
}

function requiredImage(base64: unknown, mime: unknown): QrImage {
  const decoded = decodeQrImage(base64, mime);
  if ('problem' in decoded) throw new BadRequestException(decoded.problem);
  return decoded;
}

function optionalBoolean(v: unknown, name: string): boolean | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'boolean') throw new BadRequestException(`Field '${name}' must be a boolean`);
  return v;
}

/** An INT column: a whole number in 0..10000 — refused, never clamped. */
function optionalSortOrder(v: unknown): number | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'number' || !Number.isInteger(v) || v < 0 || v > 10_000) {
    throw new BadRequestException(`Field 'sortOrder' must be a whole number from 0 to 10000`);
  }
  return v;
}
