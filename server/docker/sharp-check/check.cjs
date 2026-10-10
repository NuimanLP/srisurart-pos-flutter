// Runs INSIDE the server image (mounted, not copied in) — see server.yml build-image and the
// runtime-stage comment in server/Dockerfile. Exits non-zero unless the image's sharp loads the
// libvips it was compiled against and the real product-image pipeline (dist/) works end to end.
// Run it under `qemu-x86_64 -cpu qemu64` to prove it on a CPU below x86-64-v2 (mob04, 2026-10-10).
'use strict';
const fs = require('node:fs');
const assert = require('node:assert/strict');

const sharp = require('/app/node_modules/sharp');
const { processProductImage } = require('/app/dist/product-images/image-pipeline.js');

(async () => {
  // A prebuilt @img/sharp-* binary needs x86-64-v2; none may be in the image at all.
  const store = fs.readdirSync('/app/node_modules/.pnpm');
  const prebuilt = store.filter((d) => d.startsWith('@img+sharp-'));
  assert.deepEqual(prebuilt, [], `prebuilt sharp packages in the image: ${prebuilt.join(', ')}`);
  console.log('sharp', sharp.versions.sharp, 'libvips', sharp.versions.vips);

  const solid = (w, h) =>
    sharp({ create: { width: w, height: h, channels: 3, background: { r: 200, g: 40, b: 40 } } });
  // 300×100 stored, EXIF orientation 6 → displays as 100×300 once auto-oriented.
  const phone = await solid(300, 100).jpeg().withMetadata({ orientation: 6 }).toBuffer();
  const inputs = {
    jpeg: phone,
    png: await solid(2000, 1000).png().toBuffer(),
    webp: await solid(2000, 1000).webp().toBuffer(),
  };
  for (const [kind, buf] of Object.entries(inputs)) {
    const out = await processProductImage(buf);
    const p = await sharp(out.preview).metadata();
    const t = await sharp(out.thumb).metadata();
    assert.equal(p.format, 'webp', `${kind} preview format`);
    assert.equal(t.format, 'webp', `${kind} thumb format`);
    assert.equal(p.exif, undefined, `${kind} preview kept EXIF`);
    if (kind === 'jpeg') assert.deepEqual([p.width, p.height], [100, 300], 'autoOrient');
    else assert.deepEqual([p.width, p.height, t.width], [1024, 512, 256], `${kind} resize`);
  }
  // failOn: a truncated JPEG is refused, not half-decoded.
  const jpeg = await solid(800, 600).jpeg().toBuffer();
  await assert.rejects(processProductImage(jpeg.subarray(0, jpeg.length >> 1)), 'truncated JPEG');
  // limitInputPixels: 6001×4000 is past the 24 MP ceiling.
  await assert.rejects(processProductImage(await solid(6001, 4000).png({ compressionLevel: 9 }).toBuffer()));
  console.log('sharp check OK');
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
