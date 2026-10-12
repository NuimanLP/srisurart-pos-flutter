import { HttpException, HttpStatus, Injectable, NotFoundException } from '@nestjs/common';
import { ClientIdReusedException } from '../common/client-id-reused.exception.js';
import { TenantService } from '../common/database/tenant.service.js';
import { authorisedTenantId, currentRequestContext } from '../common/request-context.js';
import { salePhotos } from '../product-images/image-store.js';

/** At most this many photos per bill (10_SALE_PHOTO_EVIDENCE.md §0). */
export const MAX_SALE_PHOTOS = 5;

/** The wire shape (§4.2). No `imageKey`, `uploadedBy` or `deviceId` — they stay in the row. */
export interface SalePhoto {
  id: string;
  saleId: string;
  sortOrder: number;
  width: number;
  height: number;
  takenAt: string;
  createdAt: string;
}

/** Everything the controller prepared before the claim (§4.3 rows 5–8). */
export interface PreparedSalePhoto {
  key: string;
  sourceSha256: string;
  width: number;
  height: number;
  takenAt: string;
  sortOrder: number;
  userId: string;
  deviceId: string;
}

interface SalePhotoRow {
  id: string;
  sale_id: string;
  image_key: string;
  source_sha256: string;
  sort_order: number;
  width: number;
  height: number;
  taken_at: Date;
  created_at: Date;
}

const COLUMNS = `id, sale_id, image_key, source_sha256, sort_order, width, height, taken_at, created_at`;

export function salePhotoLimit(): HttpException {
  return new HttpException(
    { code: 'SALE_PHOTO_LIMIT', message: 'บิลนี้มีรูปหลักฐานครบ 5 รูปแล้ว' },
    HttpStatus.CONFLICT,
  );
}

function saleNotFound(): NotFoundException {
  return new NotFoundException({ code: 'SALE_NOT_FOUND', message: 'Sale not found' });
}

function toSalePhoto(r: SalePhotoRow): SalePhoto {
  return {
    id: r.id,
    saleId: r.sale_id,
    sortOrder: Number(r.sort_order),
    width: Number(r.width),
    height: Number(r.height),
    takenAt: r.taken_at.toISOString(),
    createdAt: r.created_at.toISOString(),
  };
}

/**
 * Sale photo evidence (10_SALE_PHOTO_EVIDENCE.md §4). Append-only: `pos_app` has `SELECT, INSERT`
 * on `sale_photos` and nothing else, so there is no update or delete path here at all.
 */
@Injectable()
export class SalePhotosService {
  constructor(private readonly tenants: TenantService) {}

  /**
   * §4.3 rows 10–13, inside the route's `runIdempotent` transaction (this `runTx` joins it).
   * The bill's row is locked first (lock order: `sales` before anything else), which also
   * serialises every upload to one bill — so the five-per-bill count cannot be raced.
   */
  attach(saleId: string, photoId: string, photo: PreparedSalePhoto): Promise<SalePhoto> {
    return this.tenants.runTx(() => this.attachIn(saleId, photoId, photo));
  }

  /** `GET /sales/:saleId/photos` — no check that the bill exists (§4.4: no FK, RLS scopes it). */
  list(saleId: string): Promise<SalePhoto[]> {
    return this.tenants.runTx(() => this.listIn(saleId));
  }

  /** The stored `image_key` of one photo of one bill, or null. */
  imageKeyOf(saleId: string, photoId: string): Promise<string | null> {
    return this.tenants.runTx(() => this.imageKeyOfIn(saleId, photoId));
  }

  /**
   * After the upload's transaction is over: removes `key`'s files from the `sale-photos` volume
   * when no photo of the shop references them. Files written within `ORPHAN_GRACE_MS` are
   * spared (a concurrent upload of the identical image may not have committed yet) unless
   * `evenIfFresh` — this very request created them and its write did not stick.
   */
  async removeIfUnreferenced(key: string, { evenIfFresh = false } = {}): Promise<void> {
    const tenantId = authorisedTenantId();
    if (await this.isReferenced(key)) return;
    if (evenIfFresh) await salePhotos.removeImageFiles(tenantId, key);
    else await salePhotos.removeImageFilesIfStale(tenantId, key);
  }

  isReferenced(key: string): Promise<boolean> {
    return this.tenants.runTx(() => this.isReferencedIn(key));
  }

  private async attachIn(saleId: string, photoId: string, photo: PreparedSalePhoto): Promise<SalePhoto> {
    const { tenantId, manager } = currentRequestContext();
    const sale = (await manager.query(
      `SELECT 1 FROM sales WHERE tenant_id = $1::uuid AND id = $2::uuid FOR UPDATE`,
      [tenantId, saleId],
    )) as unknown[];
    if (sale.length === 0) throw saleNotFound();

    // A permanent replay by photoId (§3.2): same bill + same source bytes = the stored row,
    // whatever Idempotency-Key carried it. Judged on the bytes the client sent, never on
    // `image_key` (a libvips upgrade may re-encode the same input differently).
    const existing = (await manager.query(
      `SELECT ${COLUMNS} FROM sale_photos WHERE tenant_id = $1::uuid AND id = $2::uuid`,
      [tenantId, photoId],
    )) as SalePhotoRow[];
    if (existing.length > 0) {
      const row = existing[0];
      if (row.sale_id === saleId && row.source_sha256 === photo.sourceSha256) return toSalePhoto(row);
      throw new ClientIdReusedException('sale_photo', photoId);
    }

    const count = (await manager.query(
      `SELECT count(*)::int AS n FROM sale_photos WHERE tenant_id = $1::uuid AND sale_id = $2::uuid`,
      [tenantId, saleId],
    )) as { n: number }[];
    if (count[0].n >= MAX_SALE_PHOTOS) throw salePhotoLimit();

    let inserted: SalePhotoRow[];
    try {
      inserted = (await manager.query(
        `INSERT INTO sale_photos (tenant_id, id, sale_id, image_key, source_sha256, width, height,
                                  sort_order, taken_at, uploaded_by, device_id)
              VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, $7, $8, $9::timestamptz, $10::uuid, $11::uuid)
           RETURNING ${COLUMNS}`,
        [
          tenantId,
          photoId,
          saleId,
          photo.key,
          photo.sourceSha256,
          photo.width,
          photo.height,
          photo.sortOrder,
          photo.takenAt,
          photo.userId,
          photo.deviceId,
        ],
      )) as SalePhotoRow[];
    } catch (err) {
      // The same photoId sent to another bill at the same moment: that bill's lock did not
      // serialise us, the primary key did. Not a replay — the id names another photo.
      if ((err as { constraint?: string }).constraint === 'pk_sale_photos') {
        throw new ClientIdReusedException('sale_photo', photoId);
      }
      throw err;
    }
    return toSalePhoto(inserted[0]);
  }

  private async listIn(saleId: string): Promise<SalePhoto[]> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM sale_photos
        WHERE tenant_id = $1::uuid AND sale_id = $2::uuid
        ORDER BY sort_order, created_at, id`,
      [tenantId, saleId],
    )) as SalePhotoRow[];
    return rows.map(toSalePhoto);
  }

  private async imageKeyOfIn(saleId: string, photoId: string): Promise<string | null> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT image_key FROM sale_photos WHERE tenant_id = $1::uuid AND sale_id = $2::uuid AND id = $3::uuid`,
      [tenantId, saleId, photoId],
    )) as { image_key: string }[];
    return rows[0]?.image_key ?? null;
  }

  private async isReferencedIn(key: string): Promise<boolean> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT 1 FROM sale_photos WHERE tenant_id = $1::uuid AND image_key = $2 LIMIT 1`,
      [tenantId, key],
    )) as unknown[];
    return rows.length > 0;
  }
}
