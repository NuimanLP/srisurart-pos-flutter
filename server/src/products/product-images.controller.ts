import {
  Controller,
  Delete,
  HttpException,
  HttpStatus,
  Inject,
  Param,
  Put,
  Req,
  Res,
  ServiceUnavailableException,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import type { Logger } from 'pino';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { ParseUuidPipe } from '../common/parse-uuid.pipe.js';
import { authorisedTenantId } from '../common/request-context.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { LOGGER } from '../infra/logger.provider.js';
import { processProductImage, productImageInvalid } from '../product-images/image-pipeline.js';
import { writeImageFiles } from '../product-images/image-store.js';
import { ProductsService, type Product } from './products.service.js';

/** `PUT /products/:id/image` as Express sees it under the global prefix (`app.setup.ts`). */
export const PRODUCT_IMAGE_ROUTE = '/api/v1/products/:id/image';

interface OwnerRequest extends Request {
  user?: { userId?: string; role?: string; deviceId?: string };
}

/**
 * One image per product (contract §3). Only `role = 'owner'` writes; no enrolled device is
 * needed (a catalogue edit, like `PATCH /settings`). Reading the image needs no API at all:
 * nginx serves `/img/<tenantId>/<imageKey>_{t,p}.webp` straight from the volume.
 *
 * `PUT`: the raw body (≤ 3 MB, `image/jpeg|png|webp`) is parsed only for a verified owner
 * token (`app.setup.ts`, `ownerTokenFromHeader`) — anyone else's body is never read. The slow part — sharp, then writing both files — runs BEFORE the
 * claim, like the void's PIN check (tx.5 #154), so no pooled connection is held across it;
 * the claim is still the first statement of the only transaction, and the fingerprint covers
 * the body bytes (`IdempotencyService.requestHash`). Files are content-addressed, so a replay
 * that re-writes them writes the same bytes.
 */
@Controller('products')
@UseGuards(TenantGuard)
export class ProductImagesController {
  constructor(
    private readonly products: ProductsService,
    private readonly idempotency: IdempotencyService,
    @Inject(LOGGER) private readonly logger: Logger,
  ) {}

  @Put(':id/image')
  async putImage(
    @Param('id', ParseUuidPipe) id: string,
    @Req() req: OwnerRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Product> {
    const params = idempotencyParamsOf(req, 200);
    const image = await this.prepareImage(req);
    return this.settleImage(image, () =>
      this.idempotency.runIdempotent(params, res, () => this.products.setImage(id, image)),
    );
  }

  @Delete(':id/image')
  removeImage(
    @Param('id', ParseUuidPipe) id: string,
    @Req() req: OwnerRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Product> {
    return this.idempotency.runIdempotent(idempotencyParamsOf(req, 200), res, () => {
      requireOwner(req);
      return this.products.clearImage(id);
    });
  }

  /** Owner check, then validate + re-encode the body and write both files. Returns the key. */
  private async prepareImage(req: OwnerRequest): Promise<string> {
    requireOwner(req);
    // A Buffer only when the raw parser ran, i.e. a verified owner token AND an accepted
    // Content-Type; JSON, a form, or no body at all is not an image.
    if (!Buffer.isBuffer(req.body) || req.body.length === 0) throw productImageInvalid();
    const image = await processProductImage(req.body);
    await writeImageFiles(authorisedTenantId(), image.key, image);
    return image.key;
  }

  /**
   * Runs the claimed write, then removes this upload's files again if, once it is over, no
   * product references them: the product was unknown (404), the key was refused (409), or a
   * stale replay answered for an image the product no longer has. Skipped while the original
   * request with this key is still in flight (503) — its files are the same files, and it has
   * not committed yet. Two products given the identical image at the same instant can still
   * race this check; the cost is a placeholder until that image is uploaded again.
   */
  private async settleImage<T>(key: string, write: () => Promise<T>): Promise<T> {
    let inFlight = false;
    try {
      return await write();
    } catch (err) {
      inFlight = err instanceof ServiceUnavailableException;
      throw err;
    } finally {
      if (!inFlight) await this.dropIfUnreferenced(key);
    }
  }

  private async dropIfUnreferenced(key: string): Promise<void> {
    try {
      await this.products.removeImageIfUnreferenced(key);
    } catch (err) {
      this.logger.warn({ err, imageKey: key }, 'product image cleanup failed');
    }
  }
}

/** `403 OWNER_ONLY` — the code `PaymentAccountsController` introduced (02 §8.1). */
function requireOwner(req: OwnerRequest): void {
  if (req.user?.role !== 'owner') {
    throw new HttpException(
      { code: 'OWNER_ONLY', message: 'เฉพาะเจ้าของร้านเท่านั้นที่เปลี่ยนรูปสินค้าได้' },
      HttpStatus.FORBIDDEN,
    );
  }
}

