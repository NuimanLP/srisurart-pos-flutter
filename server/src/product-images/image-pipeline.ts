import { createHash } from 'node:crypto';
import { HttpException, HttpStatus } from '@nestjs/common';
import sharp from 'sharp';

/**
 * The one image pipeline (contract §3), shared by `PUT /products/:id/image` and every image a
 * backup ZIP brings in (§4): sniff → decode with the guards on → orient → strip → resize →
 * WebP → hash the preview. Pure: no file, no database.
 */

/** Largest upload, and largest image inside a backup ZIP: 3 MB (3 × 1024 × 1024 bytes). */
export const PRODUCT_IMAGE_MAX_BYTES = 3 * 1024 * 1024;

/** The `Content-Type`s `PUT /products/:id/image` accepts (the raw body parser's `type`). */
export const PRODUCT_IMAGE_CONTENT_TYPES = ['image/jpeg', 'image/png', 'image/webp'] as const;

/**
 * Decoded-size ceiling. sharp's default is ~268 MP; a 3 MB JPEG can claim far more pixels than
 * the api (384 MB) or worker (256 MB) container could decode — 24 MP × 3 channels is ~72 MB of
 * pixels, plus libvips' working copies. 24 MP (6000 × 4000) still takes a 24 MP camera photo,
 * and the client already downscales to ≤ 1600 px (contract §5).
 */
export const INPUT_PIXEL_LIMIT = 24_000_000;

export const THUMB_SIZE = 256;
export const PREVIEW_SIZE = 1024;
const THUMB_QUALITY = 75;
const PREVIEW_QUALITY = 80;

// One image at a time per process, and no libvips operation cache: the api container is
// 384 MB and the worker 256 MB, and an upload is a rare owner action, not a hot path.
sharp.cache(false);
sharp.concurrency(1);

export interface ProcessedImage {
  /** First 32 hex chars of sha256(preview) — `products.image_key`. */
  key: string;
  thumb: Buffer;
  preview: Buffer;
}

export function productImageInvalid(): HttpException {
  return new HttpException(
    { code: 'PRODUCT_IMAGE_INVALID', message: 'ไฟล์รูปไม่ถูกต้อง กรุณาใช้รูป JPG, PNG หรือ WebP' },
    HttpStatus.BAD_REQUEST,
  );
}

export function productImageTooLarge(): HttpException {
  return new HttpException(
    { code: 'PRODUCT_IMAGE_TOO_LARGE', message: 'รูปใหญ่เกิน 3 MB' },
    HttpStatus.PAYLOAD_TOO_LARGE,
  );
}

/**
 * The format the bytes actually are, from their magic numbers — never from `Content-Type`.
 * Checked BEFORE sharp sees the bytes, so libvips never picks its SVG (librsvg), GIF, TIFF,
 * HEIF or PDF loader for an upload: only these three loaders are ever reachable.
 */
export function sniffImageType(buf: Buffer): 'jpeg' | 'png' | 'webp' | null {
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'jpeg';
  if (
    buf.length >= 8 &&
    buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
  ) {
    return 'png';
  }
  if (
    buf.length >= 12 &&
    buf.toString('latin1', 0, 4) === 'RIFF' &&
    buf.toString('latin1', 8, 12) === 'WEBP'
  ) {
    return 'webp';
  }
  return null;
}

/** sha256 of the preview bytes, first 32 hex chars (128 bits — the URL's unguessable part). */
export function imageKeyOf(preview: Buffer): string {
  return createHash('sha256').update(preview).digest('hex').slice(0, 32);
}

/**
 * Validates and re-encodes one image. Throws `PRODUCT_IMAGE_INVALID` (400) for anything that is
 * not a JPEG/PNG/WebP sharp decodes cleanly within the pixel limit, and
 * `PRODUCT_IMAGE_TOO_LARGE` (413) past 3 MB.
 *
 * - `failOn: 'error'` (implies 'truncated'): a truncated or corrupt file is refused, not
 *   half-decoded; a mere warning — e.g. a camera JPEG with bytes after its end marker — passes.
 * - `.rotate()` with no angle = auto-orient from EXIF, BEFORE the metadata is dropped — a
 *   phone photo would otherwise come out sideways.
 * - No `withMetadata`/`keepExif`: sharp's output carries no EXIF/GPS/ICC (its default).
 * - Animated input: the first frame only.
 * - The thumbnail is made from the preview (already oriented and stripped), not the original.
 */
export async function processProductImage(input: Buffer): Promise<ProcessedImage> {
  if (input.length > PRODUCT_IMAGE_MAX_BYTES) throw productImageTooLarge();
  if (sniffImageType(input) === null) throw productImageInvalid();
  let preview: Buffer;
  let thumb: Buffer;
  try {
    preview = await sharp(input, {
      failOn: 'error',
      limitInputPixels: INPUT_PIXEL_LIMIT,
      animated: false,
    })
      .rotate()
      .resize(PREVIEW_SIZE, PREVIEW_SIZE, { fit: 'inside', withoutEnlargement: true })
      .webp({ quality: PREVIEW_QUALITY })
      .toBuffer();
    thumb = await sharp(preview, { failOn: 'error' })
      .resize(THUMB_SIZE, THUMB_SIZE, { fit: 'inside', withoutEnlargement: true })
      .webp({ quality: THUMB_QUALITY })
      .toBuffer();
  } catch {
    throw productImageInvalid();
  }
  return { key: imageKeyOf(preview), thumb, preview };
}
