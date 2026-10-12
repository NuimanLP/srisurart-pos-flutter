import { createHash } from 'node:crypto';
import { open } from 'node:fs/promises';
import {
  BadRequestException,
  Controller,
  Get,
  Header,
  HttpStatus,
  Inject,
  NotFoundException,
  Param,
  Put,
  Query,
  Req,
  Res,
  ServiceUnavailableException,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import type { Logger } from 'pino';
import type { JwtVerifier } from '../auth/jwt-keys.service.js';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { ParseUuidPipe } from '../common/parse-uuid.pipe.js';
import { authorisedTenantId } from '../common/request-context.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { LOGGER } from '../infra/logger.provider.js';
import { processSalePhoto, productImageInvalid } from '../product-images/image-pipeline.js';
import { salePhotos } from '../product-images/image-store.js';
import { SalePhotosService, type PreparedSalePhoto, type SalePhoto } from './sale-photos.service.js';

/** `PUT /sales/:saleId/photos/:photoId` as Express sees it under the global prefix (`app.setup.ts`). */
export const SALE_PHOTO_ROUTE = '/api/v1/sales/:saleId/photos/:photoId';

/** How far ahead of the server's clock a device may stamp `takenAt` (§4.3 row 5). */
const TAKEN_AT_MAX_AHEAD_MS = 10 * 60_000;
const ISO_8601 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;

interface AuthenticatedRequest extends Request {
  user?: { userId?: string; role?: string; deviceId?: string; deviceRole?: string };
}

/**
 * §4.3 row 0: the raw image body (≤ 3 MB) is parsed only for a verified tenant access token
 * that carries a device (`did`) — nobody else makes the API buffer 3 MB before the guard.
 * Any other request falls through unparsed, and `TenantGuard` + `@RequireDeviceRole('pos')`
 * answer it (401 / 403) before the handler ever looks at the body.
 */
export function deviceTokenFromHeader(header: unknown, verifier: JwtVerifier): boolean {
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return false;
  try {
    const p = verifier.verify(header.substring(7), 'access');
    return p.aud === 'tenant' && !!p.tid && !!p.did;
  } catch {
    return false;
  }
}

/**
 * Sale photo evidence (10_SALE_PHOTO_EVIDENCE.md §4). Upload from the `pos` device only, any
 * role of the shop; read from any device. The files live in the `sale-photos` volume, which
 * nginx never mounts: the only way to a photo is the byte route below, behind a login.
 *
 * `PUT`: like `PUT /products/:id/image`, sharp (in the one-slot `withImageSlot`) and both file
 * writes run BEFORE the claim, so no pooled connection is held across seconds of CPU; the claim
 * is the first statement of the only transaction, and the fingerprint is the concrete path +
 * the hash of the body bytes. Always `200` — a first upload and every replay alike.
 */
@Controller('sales')
@UseGuards(TenantGuard)
export class SalePhotosController {
  constructor(
    private readonly photos: SalePhotosService,
    private readonly idempotency: IdempotencyService,
    @Inject(LOGGER) private readonly logger: Logger,
  ) {}

  @Put(':saleId/photos/:photoId')
  @RequireDeviceRole('pos')
  async putPhoto(
    @Param('saleId', ParseUuidPipe) saleId: string,
    @Param('photoId', ParseUuidPipe) photoId: string,
    @Query('takenAt') takenAt: unknown,
    @Query('sortOrder') sortOrder: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<SalePhoto> {
    const params = idempotencyParamsOf(req, 200);
    const photo = await this.preparePhoto(req, takenAt, sortOrder);
    return this.settlePhoto(photo, () =>
      this.idempotency.runIdempotent(params, res, () => this.photos.attach(saleId, photoId, photo)),
    );
  }

  @Get(':saleId/photos')
  @Header('Cache-Control', 'no-store')
  list(@Param('saleId', ParseUuidPipe) saleId: string): Promise<SalePhoto[]> {
    return this.photos.list(saleId);
  }

  /**
   * The bytes of one variant (§4.5). The row is read in a short transaction that is over before
   * the file is opened — no pooled connection is held while streaming — and the path is built
   * from the token's tenant and the STORED `image_key` only, never from the request.
   * Library-mode `@Res()`: the envelope must not wrap a file body (`backup.controller.ts`).
   */
  @Get(':saleId/photos/:photoId/:variant')
  async bytes(
    @Param('saleId', ParseUuidPipe) saleId: string,
    @Param('photoId', ParseUuidPipe) photoId: string,
    @Param('variant') variant: string,
    @Res() res: Response,
  ): Promise<void> {
    if (variant !== 't' && variant !== 'p') throw notFound();
    const key = await this.photos.imageKeyOf(saleId, photoId);
    if (key === null) throw notFound();

    let fh;
    try {
      fh = await open(salePhotos.imageFilePath(authorisedTenantId(), key, variant), 'r');
    } catch {
      throw notFound();
    }
    let size: number;
    try {
      ({ size } = await fh.stat());
    } catch (err) {
      await fh.close();
      throw err;
    }
    res.status(HttpStatus.OK);
    res.setHeader('Content-Type', 'image/webp');
    res.setHeader('Content-Length', String(size));
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const stream = fh.createReadStream();
    stream.on('error', () => res.destroy());
    // A client that disconnects mid-download must not leave the file handle open.
    res.on('close', () => stream.destroy());
    stream.pipe(res);
  }

  /**
   * §4.3 rows 5–8: the query, then the body, then sharp, then both files. Returns what the
   * transaction needs, plus whether this request created the files.
   */
  private async preparePhoto(
    req: AuthenticatedRequest,
    takenAt: unknown,
    sortOrder: unknown,
  ): Promise<PreparedSalePhoto & { created: boolean }> {
    const userId = req.user?.userId;
    const deviceId = req.user?.deviceId;
    // A `pos` token always carries both — the guard refuses this route otherwise — but the
    // row records them, so they are checked rather than asserted.
    if (!userId || !deviceId) throw new DeviceRoleForbiddenException();
    const query = { takenAt: parseTakenAt(takenAt), sortOrder: parseSortOrder(sortOrder) };
    // A Buffer only when the raw parser ran (a verified device token AND an accepted
    // Content-Type); JSON, a form, or no body at all is not an image.
    if (!Buffer.isBuffer(req.body) || req.body.length === 0) throw productImageInvalid();
    const sourceSha256 = createHash('sha256').update(req.body).digest('hex');
    const image = await processSalePhoto(req.body);
    const created = await salePhotos.writeImageFiles(authorisedTenantId(), image.key, image);
    return {
      ...query,
      key: image.key,
      sourceSha256,
      width: image.width,
      height: image.height,
      userId,
      deviceId,
      created,
    };
  }

  /**
   * Runs the claimed write, then — once it is over, outside any transaction — removes this
   * upload's files if no photo references them (404, 409, a replay whose stored photo has
   * another key). Skipped while the original request with this key is still in flight (503):
   * its files are these files and it has not committed yet. Files this request created go at
   * once; files that were already there are kept while fresh (`ORPHAN_GRACE_MS`).
   */
  private async settlePhoto<T>(
    photo: { key: string; created: boolean },
    write: () => Promise<T>,
  ): Promise<T> {
    let inFlight = false;
    try {
      return await write();
    } catch (err) {
      inFlight = err instanceof ServiceUnavailableException;
      throw err;
    } finally {
      if (!inFlight) await this.dropIfUnreferenced(photo.key, photo.created);
    }
  }

  private async dropIfUnreferenced(key: string, evenIfFresh: boolean): Promise<void> {
    try {
      await this.photos.removeIfUnreferenced(key, { evenIfFresh });
    } catch (err) {
      this.logger.warn({ err, imageKey: key }, 'sale photo cleanup failed');
    }
  }
}

function notFound(): NotFoundException {
  return new NotFoundException({ code: 'NOT_FOUND', message: 'Photo not found' });
}

function badRequest(message: string): BadRequestException {
  return new BadRequestException({ code: 'BAD_REQUEST', message });
}

/** ISO-8601 with a zone, and not more than 10 minutes ahead of the server — validated, never clamped. */
export function parseTakenAt(value: unknown, now: number = Date.now()): string {
  if (typeof value !== 'string' || !ISO_8601.test(value)) {
    throw badRequest('takenAt must be an ISO-8601 timestamp with a zone');
  }
  const ms = Date.parse(value);
  if (Number.isNaN(ms)) throw badRequest('takenAt must be an ISO-8601 timestamp with a zone');
  if (ms > now + TAKEN_AT_MAX_AHEAD_MS) throw badRequest('takenAt is in the future');
  return new Date(ms).toISOString();
}

/** An integer 0–4 — validated, never clamped. */
export function parseSortOrder(value: unknown): number {
  if (typeof value !== 'string' || !/^[0-9]+$/.test(value)) {
    throw badRequest('sortOrder must be an integer from 0 to 4');
  }
  const n = Number(value);
  if (n > 4) throw badRequest('sortOrder must be an integer from 0 to 4');
  return n;
}
