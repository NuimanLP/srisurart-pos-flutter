import { BadRequestException } from '@nestjs/common';
import { randomBytes } from 'node:crypto';

/** Canonical lowercase 8-4-4-4-12 hex, any version — the only id form the API accepts (#616). */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

let lastMs = 0;
let seq = 0;

/**
 * A lowercase UUIDv7 (RFC 9562 §5.7): 48-bit Unix ms, version 7, a 12-bit counter in
 * `rand_a` (§6.2 method 1), variant `10`, 62 random bits. Ids from this process sort in
 * mint order even within one ms or when the clock steps back; a counter overflow borrows
 * the next ms.
 */
export function newUuid(): string {
  const now = Date.now();
  if (now > lastMs) {
    lastMs = now;
    seq = randomBytes(2).readUInt16BE(0) & 0x7ff; // random start, half the space left to count
  } else if (++seq > 0xfff) {
    lastMs++;
    seq = 0;
  }
  const b = randomBytes(16);
  b.writeUIntBE(lastMs, 0, 6);
  b[6] = 0x70 | (seq >> 8);
  b[7] = seq & 0xff;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/**
 * `400 INVALID_ID` unless `value` is a canonical lowercase UUID. Never normalises
 * (uppercase is refused, not lower-cased — owner decision #616), so the value stored is
 * byte-equal to what Postgres hands back and JS `===` / `Map` lookups stay sound. Run it
 * before any SQL: a non-UUID reaching a `uuid` column is a 22P02 → 500.
 */
export function parseUuid(value: unknown, field: string): string {
  if (!isUuid(value)) {
    throw new BadRequestException({
      code: 'INVALID_ID',
      message: `${field} must be a lowercase UUID`,
      details: { field },
    });
  }
  return value;
}

/** `parseUuid`'s test without the throw — for a caller that treats a non-UUID as "no such row". */
export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_RE.test(value);
}

/**
 * `400 INVALID_TENANT_ID` unless a platform route's tenant `:id` is a canonical lowercase
 * UUID (#443 PR2, #621). Without it a non-UUID reached Postgres and came back as a
 * driver-level 22P02 — a 500. Run before any query (validate first, then use).
 */
export function assertValidTenantId(tenantId: string): void {
  if (!isUuid(tenantId)) {
    throw new BadRequestException({
      code: 'INVALID_TENANT_ID',
      message: 'tenantId must be a lowercase UUID',
    });
  }
}

/** Like `optionalString` in `sales.dto.ts`: absent / `null` / `''` → `null`, else `parseUuid`. */
export function optionalUuid(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === '') return null;
  return parseUuid(value, field);
}

/**
 * A required id: absent / not a string / blank → `400 "<field> is required"` (the
 * `requiredString` message the DTOs used before #616), else `parseUuid`'s `INVALID_ID`.
 */
export function requiredUuid(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new BadRequestException(`${field} is required`);
  }
  return parseUuid(value, field);
}

/**
 * #616 backstop: Postgres refusing a non-UUID for a `uuid` value (22P02 with the
 * `type uuid` message) → `400 INVALID_ID`. Every id is meant to pass `parseUuid` before
 * any SQL; this only catches one that slipped past, so it reads as the client's bad id
 * rather than a 500. Scoped to the uuid message on purpose: 22P02 is also a bad
 * integer, numeric, boolean, json or enum literal, and those stay 500s (server bugs —
 * every such value is validated or produced by the server). `null` when not that error.
 */
export function invalidUuidInput(exception: unknown): BadRequestException | null {
  const e = exception as { code?: unknown; message?: unknown } | null;
  if (
    e?.code === '22P02' &&
    typeof e.message === 'string' &&
    e.message.includes('invalid input syntax for type uuid')
  ) {
    return new BadRequestException({
      code: 'INVALID_ID',
      message: 'An id must be a lowercase UUID',
    });
  }
  return null;
}
