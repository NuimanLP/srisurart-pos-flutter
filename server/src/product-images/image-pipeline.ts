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

// One libvips thread per operation, and no libvips operation cache: the api container is
// 384 MB and the worker 256 MB. One operation at a time per process is `withImageSlot` below.
sharp.cache(false);
sharp.concurrency(1);

export interface ProcessedImage {
  /** First 32 hex chars of sha256(preview) — `products.image_key`. */
  key: string;
  thumb: Buffer;
  preview: Buffer;
  /** The preview's pixel size (`sale_photos.width`/`height`). */
  width: number;
  height: number;
}

export function productImageInvalid(): HttpException {
  return new HttpException(
    { code: 'PRODUCT_IMAGE_INVALID', message: 'ไฟล์รูปไม่ถูกต้อง กรุณาใช้รูป JPG, PNG หรือ WebP' },
    HttpStatus.BAD_REQUEST,
  );
}

/**
 * How many uploads may wait for the image slot behind the one decoding (review 2026-10-21).
 * Each waiter holds its buffered body (≤ 3 MB) in a 384 MB container; past this the upload
 * is refused at once instead of queueing without bound.
 */
export const IMAGE_SLOT_MAX_WAITING = 4;

/** Seconds a refused upload is told to wait — about one decode ahead of it. */
export const IMAGE_BUSY_RETRY_AFTER_SECONDS = 5;

/**
 * `503 IMAGE_BUSY` + `Retry-After`: the image slot's queue is full. Not a verdict — nothing was
 * written and no idempotency key was claimed (the decode runs before the claim), so the client
 * keeps its parked attempt and resends the same id + key.
 */
export function imageBusy(): HttpException {
  return new HttpException(
    {
      code: 'IMAGE_BUSY',
      message: 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
      retryAfter: IMAGE_BUSY_RETRY_AFTER_SECONDS,
    },
    HttpStatus.SERVICE_UNAVAILABLE,
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
export function processProductImage(
  input: Buffer,
  slot: ImageSlotOptions = {},
): Promise<ProcessedImage> {
  return processImage(input, { previewSize: PREVIEW_SIZE, inputPixelLimit: INPUT_PIXEL_LIMIT }, slot);
}

/**
 * Sale photo evidence (10_SALE_PHOTO_EVIDENCE.md §3.3/§5.3): the same pipeline and the same
 * error codes, with a larger preview (the photo is evidence of a scratch, not a catalogue card)
 * and a far lower pixel ceiling — the client always sends ≤ 1600 px (2.56 MP).
 */
export const SALE_PHOTO_PREVIEW_SIZE = 1600;
export const SALE_PHOTO_INPUT_PIXEL_LIMIT = 2048 * 2048;

export function processSalePhoto(
  input: Buffer,
  slot: ImageSlotOptions = {},
): Promise<ProcessedImage> {
  return processImage(
    input,
    {
      previewSize: SALE_PHOTO_PREVIEW_SIZE,
      inputPixelLimit: SALE_PHOTO_INPUT_PIXEL_LIMIT,
    },
    slot,
  );
}

export interface ImageSlotOptions {
  /**
   * Refuse with `503 IMAGE_BUSY` instead of queueing when this many jobs already wait behind
   * the running one. The HTTP uploads pass `IMAGE_SLOT_MAX_WAITING`; a backup import (one image
   * at a time, and a refusal there would drop the image) passes nothing and always waits.
   */
  maxWaiting?: number;
}

let slotTail: Promise<unknown> = Promise.resolve();
/** Jobs in the slot right now: the running one plus every waiter. */
let slotJobs = 0;

/**
 * One image decode at a time per process (§3.3). `sharp.concurrency(1)` caps libvips' threads
 * per operation, not the number of operations: two uploads arriving together would decode
 * side by side in a 384 MB container. Every caller of `processImage` queues here, in memory —
 * before any idempotency claim and holding no pooled connection. A failed job frees the slot.
 * With `maxWaiting`, a job that would queue behind that many waiters is refused with
 * `503 IMAGE_BUSY` and never enters the queue.
 */
export function withImageSlot<T>(
  work: () => Promise<T>,
  { maxWaiting }: ImageSlotOptions = {},
): Promise<T> {
  // Every job in the slot but the running one is waiting.
  const waiting = Math.max(0, slotJobs - 1);
  if (maxWaiting !== undefined && slotJobs > 0 && waiting >= maxWaiting) {
    return Promise.reject(imageBusy());
  }
  slotJobs++;
  const run = slotTail.then(() => work()).finally(() => {
    slotJobs--;
  });
  slotTail = run.catch(() => undefined);
  return run;
}

function processImage(
  input: Buffer,
  limits: { previewSize: number; inputPixelLimit: number },
  slot: ImageSlotOptions,
): Promise<ProcessedImage> {
  if (input.length > PRODUCT_IMAGE_MAX_BYTES) return Promise.reject(productImageTooLarge());
  if (sniffImageType(input) === null) return Promise.reject(productImageInvalid());
  return withImageSlot(() => encode(input, limits), slot);
}

async function encode(
  input: Buffer,
  { previewSize, inputPixelLimit }: { previewSize: number; inputPixelLimit: number },
): Promise<ProcessedImage> {
  let preview: { data: Buffer; info: { width: number; height: number } };
  let thumb: Buffer;
  try {
    preview = await sharp(input, {
      failOn: 'error',
      limitInputPixels: inputPixelLimit,
      animated: false,
    })
      .rotate()
      .resize(previewSize, previewSize, { fit: 'inside', withoutEnlargement: true })
      .webp({ quality: PREVIEW_QUALITY })
      .toBuffer({ resolveWithObject: true });
    thumb = await sharp(preview.data, { failOn: 'error' })
      .resize(THUMB_SIZE, THUMB_SIZE, { fit: 'inside', withoutEnlargement: true })
      .webp({ quality: THUMB_QUALITY })
      .toBuffer();
  } catch {
    throw productImageInvalid();
  }
  return {
    key: imageKeyOf(preview.data),
    thumb,
    preview: preview.data,
    width: preview.info.width,
    height: preview.info.height,
  };
}
