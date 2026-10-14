import { createHash, randomUUID } from 'node:crypto';
import { mkdir, open, rename, rm, stat } from 'node:fs/promises';
import { dirname } from 'node:path';
import { Readable } from 'node:stream';
import { BadRequestException } from '@nestjs/common';
import yauzl from 'yauzl';
import yazl from 'yazl';
import { IMAGE_KEY, imageFilePath } from '../product-images/image-store.js';

/**
 * The shop backup as a ZIP (contract §4):
 *
 *     data.json              — exactly the `sa_*` + `__meta` export JSON, products carrying
 *                              `imageKey` when they have an image
 *     images/<imageKey>.webp — the preview file, one per distinct key
 *
 * Written by the export job and the replace-mode import's pre-import copy; read by both import
 * routes (`POST /backup/import`, `POST /platform/tenants/:id/import`) next to the legacy JSON.
 */

export const ZIP_DATA_JSON = 'data.json';
const ZIP_IMAGE = /^images\/([0-9a-f]{32})\.webp$/;

/**
 * Import-side limits. `maxDataJsonBytes` keeps the legacy JSON's 10 MiB ceiling
 * (`IMPORT_BODY_LIMIT`): data.json is parsed in an api container of 384 MB, exactly as the JSON
 * body always was. Every entry's declared size is checked from the central directory before
 * a byte is inflated, and yauzl's `validateEntrySizes` makes the real size match the declared
 * one — a zip bomb lying about its sizes fails mid-read.
 */
export const ZIP_LIMITS = {
  maxEntries: 20_000,
  maxTotalUncompressedBytes: 1024 * 1024 * 1024,
  maxImageBytes: 3 * 1024 * 1024,
  maxDataJsonBytes: 10 * 1024 * 1024,
} as const;

export function backupZipInvalid(reason: string): BadRequestException {
  return new BadRequestException({
    code: 'BACKUP_ZIP_INVALID',
    message: `ไฟล์สำรอง (.zip) ไม่ถูกต้อง — ${reason}`,
  });
}

// ── write ─────────────────────────────────────────────────────────────────────────────

/** The export JSON one top-level key at a time: the whole document is never one string. */
function* snapshotJson(snapshot: Record<string, unknown>): Generator<Buffer> {
  let first = true;
  yield Buffer.from('{', 'utf8');
  for (const [key, value] of Object.entries(snapshot)) {
    if (value === undefined) continue;
    yield Buffer.from(`${first ? '' : ','}${JSON.stringify(key)}:${JSON.stringify(value)}`, 'utf8');
    first = false;
  }
  yield Buffer.from('}', 'utf8');
}

/** Distinct image keys the snapshot's products name (well-formed ones only). */
export function snapshotImageKeys(snapshot: Record<string, unknown>): string[] {
  const products = Array.isArray(snapshot.sa_products) ? snapshot.sa_products : [];
  const keys = new Set<string>();
  for (const p of products as Array<Record<string, unknown>>) {
    if (typeof p?.imageKey === 'string' && IMAGE_KEY.test(p.imageKey)) keys.add(p.imageKey);
  }
  return [...keys];
}

export interface ExportZipResult {
  sizeBytes: number;
  sha256: string;
  /** Images written into the ZIP. */
  images: number;
  /** Keys the products name whose preview file was not on disk (data.json still names them). */
  missingImages: number;
}

/**
 * Writes the backup ZIP: data.json (deflated) + each image's preview (stored — WebP is already
 * compressed). The output goes to a temp name, is fsync'd, then renamed, and its size on disk
 * is checked: the replace-mode import deletes the shop's data right after this returns,
 * trusting this file to be its way back. `tenantId` locates the images on the volume.
 */
export async function writeExportZip(
  file: string,
  snapshot: Record<string, unknown>,
  tenantId: string,
): Promise<ExportZipResult> {
  await mkdir(dirname(file), { recursive: true });
  const zip = new yazl.ZipFile();
  zip.addReadStream(Readable.from(snapshotJson(snapshot)), ZIP_DATA_JSON);
  let images = 0;
  let missingImages = 0;
  for (const key of snapshotImageKeys(snapshot)) {
    const path = imageFilePath(tenantId, key, 'p');
    try {
      if (!(await stat(path)).isFile()) throw new Error('not a file');
    } catch {
      missingImages++;
      continue;
    }
    zip.addFile(path, `images/${key}.webp`, { compress: false });
    images++;
  }
  zip.end();

  // Unique per attempt: every container is pid 1, and a stalled attempt can overlap its retry.
  const tmp = `${file}.${randomUUID()}.tmp`;
  const hash = createHash('sha256');
  let sizeBytes = 0;
  const fh = await open(tmp, 'w');
  try {
    const failed = new Promise<never>((_, reject) => zip.on('error', reject));
    failed.catch(() => {});
    const copy = (async () => {
      for await (const chunk of zip.outputStream as AsyncIterable<Buffer>) {
        hash.update(chunk);
        sizeBytes += chunk.length;
        // `write` may write less than asked (a full disk does this): finish it, or fail loudly.
        for (let off = 0; off < chunk.length; ) {
          const { bytesWritten } = await fh.write(chunk, off, chunk.length - off);
          if (bytesWritten <= 0) throw new Error(`export file short write: ${off} of ${chunk.length} bytes`);
          off += bytesWritten;
        }
      }
    })();
    await Promise.race([copy, failed]);
    await fh.sync();
  } catch (err) {
    await fh.close();
    await rm(tmp, { force: true });
    throw err;
  }
  await fh.close();
  await rename(tmp, file);
  const onDisk = (await stat(file)).size;
  if (onDisk !== sizeBytes) {
    throw new Error(`export file ${file} is ${onDisk} bytes on disk, expected ${sizeBytes}`);
  }
  return { sizeBytes, sha256: hash.digest('hex'), images, missingImages };
}

// ── read ──────────────────────────────────────────────────────────────────────────────

function openZip(path: string): Promise<yauzl.ZipFile> {
  return new Promise((resolve, reject) =>
    yauzl.open(
      path,
      // strictFileNames: a `\` in a name is refused, not rewritten to `/`. yauzl itself refuses
      // absolute paths and `..` segments (`validateFileName`), and checks each entry's real
      // size against the declared one (`validateEntrySizes`, the default).
      { lazyEntries: true, autoClose: false, strictFileNames: true, validateEntrySizes: true },
      (err, zip) => (err || !zip ? reject(backupZipInvalid('เปิดไฟล์ไม่ได้')) : resolve(zip)),
    ),
  );
}

/** Every entry of the central directory, in order, without inflating anything. */
function readEntries(zip: yauzl.ZipFile): Promise<yauzl.Entry[]> {
  return new Promise((resolve, reject) => {
    const entries: yauzl.Entry[] = [];
    zip.on('entry', (e: yauzl.Entry) => {
      entries.push(e);
      zip.readEntry();
    });
    zip.on('end', () => resolve(entries));
    zip.on('error', () => reject(backupZipInvalid('โครงสร้างไฟล์เสีย')));
    zip.readEntry();
  });
}

/** One entry's bytes, refusing past `limit` even if the declared size lied. */
function readEntry(zip: yauzl.ZipFile, entry: yauzl.Entry, limit: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    zip.openReadStream(entry, (err, stream) => {
      if (err || !stream) return reject(backupZipInvalid(`อ่าน ${entry.fileName} ไม่ได้`));
      const chunks: Buffer[] = [];
      let n = 0;
      stream.on('data', (c: Buffer) => {
        n += c.length;
        if (n > limit) {
          stream.destroy();
          reject(backupZipInvalid(`${entry.fileName} ใหญ่เกินกำหนด`));
          return;
        }
        chunks.push(c);
      });
      stream.on('error', () => reject(backupZipInvalid(`${entry.fileName} เสีย`)));
      stream.on('end', () => resolve(Buffer.concat(chunks)));
    });
  });
}

interface CheckedZip {
  dataJson: yauzl.Entry;
  /** image key → its entry */
  images: Map<string, yauzl.Entry>;
}

/**
 * The structural rules, all decided from the central directory before anything is inflated:
 * at most 20,000 entries; total declared uncompressed size ≤ 1 GB; exactly one `data.json`
 * (≤ 10 MiB); `images/<32 hex>.webp` each ≤ 3 MB; no encrypted entry, no duplicate name.
 * **Any other entry refuses the file** (directory entries excepted) — the format has nothing
 * else in it, and a file carrying extra paths is not one this server wrote.
 */
function checkEntries(entries: yauzl.Entry[]): CheckedZip {
  let total = 0;
  let dataJson: yauzl.Entry | undefined;
  const images = new Map<string, yauzl.Entry>();
  const seen = new Set<string>();
  for (const e of entries) {
    const name = e.fileName;
    if (seen.has(name)) throw backupZipInvalid(`ชื่อไฟล์ซ้ำ: ${name}`);
    seen.add(name);
    if (name.endsWith('/')) continue; // a directory entry carries no data
    if (e.isEncrypted()) throw backupZipInvalid(`${name} ถูกเข้ารหัส`);
    total += e.uncompressedSize;
    if (total > ZIP_LIMITS.maxTotalUncompressedBytes) {
      throw backupZipInvalid('ขนาดรวมหลังแตกไฟล์เกิน 1 GB');
    }
    if (name === ZIP_DATA_JSON) {
      if (e.uncompressedSize > ZIP_LIMITS.maxDataJsonBytes) throw backupZipInvalid('data.json ใหญ่เกิน 10 MB');
      dataJson = e;
      continue;
    }
    const m = ZIP_IMAGE.exec(name);
    if (!m) throw backupZipInvalid(`มีไฟล์ที่ไม่รู้จัก: ${name}`);
    if (e.uncompressedSize > ZIP_LIMITS.maxImageBytes) throw backupZipInvalid(`${name} ใหญ่เกิน 3 MB`);
    images.set(m[1], e);
  }
  if (!dataJson) throw backupZipInvalid('ไม่พบ data.json');
  return { dataJson, images };
}

async function withZip<T>(path: string, fn: (zip: yauzl.ZipFile, checked: CheckedZip) => Promise<T>): Promise<T> {
  const zip = await openZip(path);
  try {
    // From the end-of-central-directory record, before a single entry header is read.
    if (zip.entryCount > ZIP_LIMITS.maxEntries) {
      throw backupZipInvalid(`มีไฟล์ข้างในเกิน ${ZIP_LIMITS.maxEntries} รายการ`);
    }
    const checked = checkEntries(await readEntries(zip));
    return await fn(zip, checked);
  } finally {
    zip.close();
  }
}

/**
 * Checks the ZIP's structure and parses its data.json. Images are not inflated here — only
 * their keys are listed. Runs in the api request, before the job is queued, so a bad file is a
 * `400 BACKUP_ZIP_INVALID` right away.
 */
export function inspectSnapshotZip(
  path: string,
): Promise<{ snapshot: Record<string, unknown>; imageKeys: Set<string> }> {
  return withZip(path, async (zip, checked) => {
    const raw = await readEntry(zip, checked.dataJson, ZIP_LIMITS.maxDataJsonBytes);
    let snapshot: unknown;
    try {
      snapshot = JSON.parse(raw.toString('utf8'));
    } catch {
      throw backupZipInvalid('data.json ไม่ใช่ JSON');
    }
    if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
      throw backupZipInvalid('data.json ไม่ใช่ข้อมูลสำรอง');
    }
    return { snapshot: snapshot as Record<string, unknown>, imageKeys: new Set(checked.images.keys()) };
  });
}

/**
 * Calls `onImage` for each of `wanted` the ZIP holds, one at a time (each ≤ 3 MB in memory).
 * Re-checks the structure first: the worker trusts nothing the api decided earlier.
 */
export function forEachZipImage(
  path: string,
  wanted: Iterable<string>,
  onImage: (key: string, bytes: Buffer) => Promise<void>,
): Promise<void> {
  return withZip(path, async (zip, checked) => {
    for (const key of new Set(wanted)) {
      const entry = checked.images.get(key);
      if (!entry) continue;
      await onImage(key, await readEntry(zip, entry, ZIP_LIMITS.maxImageBytes));
    }
  });
}
