/**
 * The field rules for a QR payment account (contract `qr-accounts-contract.md` §2/§4), in one
 * place: the HTTP parser (`payment-accounts.dto.ts`) and the import pre-flight
 * (`snapshot-preflight.ts`) both judge a row by these, so a file can never carry an account
 * the API would have refused. Pure — no Nest, no DB.
 */

/** Bank codes (§4). Text plus a neutral colour dot on the client — no logos. */
export const BANK_CODES = [
  'SCB',
  'KBANK',
  'BBL',
  'KTB',
  'BAY',
  'TTB',
  'GSB',
  'BAAC',
  'GHB',
  'KKP',
  'CIMBT',
  'UOBT',
  'LHB',
  'TISCO',
  'ICBCT',
  'OTHER',
] as const;

export const PAYMENT_ACCOUNT_KINDS = ['promptpay', 'image'] as const;
export type PaymentAccountKind = (typeof PAYMENT_ACCOUNT_KINDS)[number];

export const IMAGE_MIMES = ['image/png', 'image/jpeg'] as const;
export type ImageMime = (typeof IMAGE_MIMES)[number];

/** Owner decision: at most 5 active (not soft-deleted) accounts per shop. */
export const MAX_ACTIVE_PAYMENT_ACCOUNTS = 5;

/** `nickname` is 1–40 characters after trim. */
export const NICKNAME_MAX_LENGTH = 40;

/**
 * The decoded image may be at most 300 KB. Read as 300 × 1024 bytes — the generous reading,
 * so a client that keeps to 300 000 bytes is always accepted.
 */
export const MAX_IMAGE_BYTES = 300 * 1024;

/** The one payment method a bill may name an account on. */
export const QR_PAYMENT_METHOD = 'โอน/QR';

/**
 * A PromptPay id: a phone number (10 digits starting with 0), a national/tax id (13 digits)
 * or an e-wallet id (15 digits). Digits only — the client strips dashes and spaces.
 */
const PROMPTPAY_ID_RE = /^(0[0-9]{9}|[0-9]{13}|[0-9]{15})$/;

/** Plain base64 (no `data:` prefix, no whitespace), padded to a multiple of 4. */
const BASE64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const JPEG_MAGIC = [0xff, 0xd8, 0xff];

export function isBankCode(v: unknown): boolean {
  return typeof v === 'string' && (BANK_CODES as readonly string[]).includes(v);
}

export function isPaymentAccountKind(v: unknown): v is PaymentAccountKind {
  return typeof v === 'string' && (PAYMENT_ACCOUNT_KINDS as readonly string[]).includes(v);
}

export function isPromptPayId(v: unknown): v is string {
  return typeof v === 'string' && PROMPTPAY_ID_RE.test(v);
}

/** The trimmed nickname, or null when it is not a 1–40 character string. */
export function normaliseNickname(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const trimmed = v.trim();
  if (trimmed.length < 1 || [...trimmed].length > NICKNAME_MAX_LENGTH) return null;
  return trimmed;
}

/**
 * Decodes and checks an uploaded QR image. Returns the bytes, or the reason it is refused:
 * not base64, empty, over {@link MAX_IMAGE_BYTES}, an unknown mime, or magic bytes that do
 * not match the mime (a JPEG labelled `image/png` is refused — the client renders by mime).
 */
export function decodeQrImage(
  base64: unknown,
  mime: unknown,
): { bytes: Buffer; mime: ImageMime } | { problem: string } {
  if (typeof mime !== 'string' || !(IMAGE_MIMES as readonly string[]).includes(mime)) {
    return { problem: `imageMime must be one of ${IMAGE_MIMES.join(', ')}` };
  }
  if (typeof base64 !== 'string' || base64.length === 0 || !BASE64_RE.test(base64)) {
    return { problem: 'imageBase64 must be plain base64 (no data: prefix)' };
  }
  // Checked on the encoded length first, so an oversized string is never decoded.
  if (Math.floor(base64.length / 4) * 3 > MAX_IMAGE_BYTES + 2) {
    return { problem: `image must be at most ${MAX_IMAGE_BYTES} bytes` };
  }
  const bytes = Buffer.from(base64, 'base64');
  if (bytes.length > MAX_IMAGE_BYTES) {
    return { problem: `image must be at most ${MAX_IMAGE_BYTES} bytes` };
  }
  const magic = mime === 'image/png' ? PNG_MAGIC : JPEG_MAGIC;
  if (bytes.length < magic.length || magic.some((b, i) => bytes[i] !== b)) {
    return { problem: `image bytes are not a ${mime}` };
  }
  return { bytes, mime: mime as ImageMime };
}
