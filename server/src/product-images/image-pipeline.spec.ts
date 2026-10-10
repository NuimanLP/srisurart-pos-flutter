import sharp from 'sharp';
import { describe, expect, it } from 'vitest';
import {
  imageKeyOf,
  INPUT_PIXEL_LIMIT,
  PREVIEW_SIZE,
  PRODUCT_IMAGE_MAX_BYTES,
  processProductImage,
  sniffImageType,
  THUMB_SIZE,
} from './image-pipeline.js';

const solid = (width: number, height: number) =>
  sharp({ create: { width, height, channels: 3, background: { r: 200, g: 40, b: 40 } } });

async function codeOf(p: Promise<unknown>): Promise<string> {
  const err = (await p.then(
    () => null,
    (e: unknown) => e,
  )) as { getResponse?: () => { code: string } } | null;
  return err?.getResponse?.().code ?? 'no error';
}

describe('processProductImage (contract §3)', () => {
  it('accepts JPEG, PNG and WebP and gives both variants as WebP within their bounds', async () => {
    for (const input of [
      await solid(2000, 1000).jpeg().toBuffer(),
      await solid(2000, 1000).png().toBuffer(),
      await solid(2000, 1000).webp().toBuffer(),
    ]) {
      const out = await processProductImage(input);
      expect(out.key).toMatch(/^[0-9a-f]{32}$/);
      expect(out.key).toBe(imageKeyOf(out.preview));
      const p = await sharp(out.preview).metadata();
      const t = await sharp(out.thumb).metadata();
      expect([p.format, t.format]).toEqual(['webp', 'webp']);
      expect([p.width, p.height]).toEqual([PREVIEW_SIZE, PREVIEW_SIZE / 2]);
      expect([t.width, t.height]).toEqual([THUMB_SIZE, THUMB_SIZE / 2]);
    }
  });

  it('never enlarges a small image', async () => {
    const out = await processProductImage(await solid(100, 80).png().toBuffer());
    expect((await sharp(out.preview).metadata()).width).toBe(100);
    expect((await sharp(out.thumb).metadata()).width).toBe(100);
  });

  it('applies the EXIF orientation, then strips every piece of metadata (GPS included)', async () => {
    // 300×100 stored, orientation 6 = "rotate 90° to display" → displays as 100×300.
    const phone = await solid(300, 100).jpeg().withMetadata({ orientation: 6 }).toBuffer();
    expect((await sharp(phone).metadata()).orientation).toBe(6);
    const out = await processProductImage(phone);
    const meta = await sharp(out.preview).metadata();
    expect([meta.width, meta.height]).toEqual([100, 300]);
    expect(meta.orientation).toBeUndefined();
    expect(meta.exif).toBeUndefined();
    expect(meta.icc).toBeUndefined();
    expect(meta.xmp).toBeUndefined();
  });

  it('is deterministic: the same bytes give the same key (a replay writes the same files)', async () => {
    const input = await solid(640, 480).jpeg().toBuffer();
    expect((await processProductImage(input)).key).toBe((await processProductImage(input)).key);
  });

  it('refuses anything that is not a JPEG/PNG/WebP by its bytes — SVG and GIF included', async () => {
    const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>');
    const gif = await solid(10, 10).gif().toBuffer();
    expect(await codeOf(processProductImage(svg))).toBe('PRODUCT_IMAGE_INVALID');
    expect(await codeOf(processProductImage(gif))).toBe('PRODUCT_IMAGE_INVALID');
    expect(await codeOf(processProductImage(Buffer.from('not an image at all')))).toBe('PRODUCT_IMAGE_INVALID');
    expect(await codeOf(processProductImage(Buffer.alloc(0)))).toBe('PRODUCT_IMAGE_INVALID');
  });

  it('refuses a truncated file (failOn) instead of half-decoding it', async () => {
    const jpeg = await solid(800, 600).jpeg().toBuffer();
    expect(await codeOf(processProductImage(jpeg.subarray(0, Math.floor(jpeg.length / 2))))).toBe(
      'PRODUCT_IMAGE_INVALID',
    );
  });

  it('accepts a JPEG libjpeg only warns about (extraneous bytes before a marker, as some cameras write)', async () => {
    const jpeg = await solid(800, 600).jpeg().toBuffer();
    // "Corrupt JPEG data: 4 extraneous bytes before marker" — a warning, not an error.
    // Inserted after the first segment, so the file still starts FF D8 FF (the sniff).
    const at = 4 + jpeg.readUInt16BE(4);
    const quirky = Buffer.concat([jpeg.subarray(0, at), Buffer.alloc(4), jpeg.subarray(at)]);
    expect((await processProductImage(quirky)).key).toMatch(/^[0-9a-f]{32}$/);
  });

  it('takes exactly the pixel limit (6000 × 4000 = 24 MP) and refuses one column more', async () => {
    expect(INPUT_PIXEL_LIMIT).toBe(6000 * 4000);
    const atLimit = await solid(6000, 4000).png({ compressionLevel: 9 }).toBuffer();
    expect((await processProductImage(atLimit)).key).toMatch(/^[0-9a-f]{32}$/);
    const over = await solid(6001, 4000).png({ compressionLevel: 9 }).toBuffer();
    expect(await codeOf(processProductImage(over))).toBe('PRODUCT_IMAGE_INVALID');
  }, 30_000);

  it('refuses a decompression bomb past the pixel limit', async () => {
    // ~45 MP of one colour compresses to a few KB of PNG.
    const bomb = await solid(9000, 5000).png({ compressionLevel: 9 }).toBuffer();
    expect(bomb.length).toBeLessThan(PRODUCT_IMAGE_MAX_BYTES);
    expect(await codeOf(processProductImage(bomb))).toBe('PRODUCT_IMAGE_INVALID');
  });

  it('refuses more than 3 MB with 413 PRODUCT_IMAGE_TOO_LARGE', async () => {
    const big = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(PRODUCT_IMAGE_MAX_BYTES)]);
    expect(await codeOf(processProductImage(big))).toBe('PRODUCT_IMAGE_TOO_LARGE');
  });
});

describe('sniffImageType', () => {
  it('reads the magic numbers, nothing else', () => {
    expect(sniffImageType(Buffer.from([0xff, 0xd8, 0xff, 0xe0]))).toBe('jpeg');
    expect(sniffImageType(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))).toBe('png');
    expect(sniffImageType(Buffer.from('RIFF\0\0\0\0WEBPVP8 ', 'latin1'))).toBe('webp');
    expect(sniffImageType(Buffer.from('RIFF\0\0\0\0WAVEfmt ', 'latin1'))).toBeNull();
    expect(sniffImageType(Buffer.from('GIF89a'))).toBeNull();
  });
});
