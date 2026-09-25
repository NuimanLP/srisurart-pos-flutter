import { BadRequestException } from '@nestjs/common';
import type { Request } from 'express';
import {
  IdempotencyService,
  IDEMPOTENCY_KEY_HEADER,
  IDEMPOTENCY_KEY_MAX_LENGTH,
  type IdempotencyParams,
} from './idempotency.service.js';

/**
 * Reads the `Idempotency-Key` header and fingerprints the request, exactly as
 * `IdempotencyInterceptor` did. Call it as the argument of
 * `IdempotencyService.runIdempotent`, so an unusable key is refused before any work.
 */
export function idempotencyParamsOf(
  req: Request,
  successCode: number,
): IdempotencyParams {
  // The docs make the header mandatory here (02_API_SCREENS.md §1.4) but never say
  // what an unusable one returns. Refusing is the only safe reading — a write that
  // silently ran without a key cannot be retried without double-charging — and the
  // length bound keeps an oversized key a 400 rather than a btree failure at 500.
  const key = req.header(IDEMPOTENCY_KEY_HEADER)?.trim();
  if (!key || key.length > IDEMPOTENCY_KEY_MAX_LENGTH) {
    throw new BadRequestException({
      code: 'IDEMPOTENCY_KEY_INVALID',
      message: key
        ? `Header ${IDEMPOTENCY_KEY_HEADER} must be at most ${IDEMPOTENCY_KEY_MAX_LENGTH} characters`
        : `Header ${IDEMPOTENCY_KEY_HEADER} is required on this endpoint`,
    });
  }
  return {
    key,
    // The CONCRETE target, not `req.route.path`: that is the route pattern, so every
    // bill sent to `POST /sales/:id/void` — whose whole body is `{reason}` (phase 2
    // dropped the PIN, 08_PHASE2_SPEC) — would share one fingerprint whenever the
    // reason text matched, and a reused key would replay the first bill's receipt while
    // the bill the clerk meant to void stayed live. The path parameter identifies
    // what is being written, so it belongs in `endpoint` (what was addressed) rather
    // than in `request_hash`, which `01_DATABASE.md` defines as the hash of the body.
    endpoint: `${req.method} ${req.baseUrl}${req.path}`,
    requestHash: IdempotencyService.requestHash(req.body),
    successCode,
  };
}
