import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { unzipEntries, zipOf, zipWithRawNames } from '../../test/support/zip.js';
import { writeImageFiles } from '../product-images/image-store.js';
import {
  forEachZipImage,
  inspectSnapshotZip,
  snapshotImageKeys,
  writeExportZip,
  ZIP_LIMITS,
} from './snapshot-zip.js';

const TENANT = '0192f000-0000-7000-8000-000000000002';
const K1 = '1'.repeat(32);
const K2 = '2'.repeat(32);
const DATA = JSON.stringify({ __meta: { version: 2 }, sa_products: [] });

describe('backup ZIP (contract §4)', () => {
  let dir: string;
  const prev = process.env.PRODUCT_IMAGES_DIR;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'snapshot-zip-'));
    process.env.PRODUCT_IMAGES_DIR = join(dir, 'images');
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
    if (prev === undefined) delete process.env.PRODUCT_IMAGES_DIR;
    else process.env.PRODUCT_IMAGES_DIR = prev;
  });

  const put = async (bytes: Buffer, name = 'in.zip') => {
    const file = join(dir, name);
    await writeFile(file, bytes);
    return file;
  };
  const codeOf = async (p: Promise<unknown>) =>
    ((await p.then(() => null, (e: unknown) => e)) as { getResponse?: () => { code: string } } | null)
      ?.getResponse?.().code ?? 'no error';

  it('writes data.json + one preview per distinct key, and reads them back', async () => {
    await writeImageFiles(TENANT, K1, { thumb: Buffer.from('t1'), preview: Buffer.from('preview-1') });
    const snapshot = {
      __meta: { version: 2 },
      sa_products: [
        { id: 'a', imageKey: K1 },
        { id: 'b', imageKey: K1 },
        { id: 'c', imageKey: K2 }, // no file on disk
        { id: 'd' },
      ],
    };
    const file = join(dir, 'out.zip');
    const res = await writeExportZip(file, snapshot, TENANT);
    expect(res).toMatchObject({ images: 1, missingImages: 1 });

    const entries = await unzipEntries(await readFile(file));
    expect([...entries.keys()].sort()).toEqual(['data.json', `images/${K1}.webp`]);
    expect(JSON.parse(entries.get('data.json')!.toString('utf8'))).toEqual(snapshot);

    const inspected = await inspectSnapshotZip(file);
    expect(inspected.snapshot).toEqual(snapshot);
    expect([...inspected.imageKeys]).toEqual([K1]);

    const seen: Array<[string, string]> = [];
    await forEachZipImage(file, [K1, K2, K1], async (key, bytes) => {
      seen.push([key, bytes.toString('utf8')]);
    });
    expect(seen).toEqual([[K1, 'preview-1']]);
  });

  it('lists only well-formed image keys', () => {
    expect(snapshotImageKeys({ sa_products: [{ imageKey: K1 }, { imageKey: '../x' }, { imageKey: 7 }, {}] })).toEqual([K1]);
    expect(snapshotImageKeys({})).toEqual([]);
  });

  it('refuses path traversal and absolute paths', async () => {
    for (const name of ['../evil.webp', '/etc/passwd', 'images/../../x']) {
      const zip = await zipWithRawNames([
        ['data.json', DATA],
        [name, 'x'],
      ]);
      expect(await codeOf(inspectSnapshotZip(await put(zip)))).toBe('BACKUP_ZIP_INVALID');
    }
  });

  it('refuses any entry that is not data.json or images/<32 hex>.webp', async () => {
    for (const name of ['notes.txt', 'images/abc.webp', `images/${K1}.png`, `images/sub/${K1}.webp`]) {
      const zip = await zipOf([
        ['data.json', DATA],
        [name, 'x'],
      ]);
      expect(await codeOf(inspectSnapshotZip(await put(zip)))).toBe('BACKUP_ZIP_INVALID');
    }
  });

  it('refuses a ZIP with no data.json, a duplicate name, or data.json that is not an object', async () => {
    expect(await codeOf(inspectSnapshotZip(await put(await zipOf([[`images/${K1}.webp`, 'x']]))))).toBe(
      'BACKUP_ZIP_INVALID',
    );
    const dup = await zipOf([
      ['data.json', DATA],
      ['data.json', DATA],
    ]);
    expect(await codeOf(inspectSnapshotZip(await put(dup)))).toBe('BACKUP_ZIP_INVALID');
    expect(await codeOf(inspectSnapshotZip(await put(await zipOf([['data.json', '[1,2]']]))))).toBe(
      'BACKUP_ZIP_INVALID',
    );
    expect(await codeOf(inspectSnapshotZip(await put(await zipOf([['data.json', '{oops']]))))).toBe(
      'BACKUP_ZIP_INVALID',
    );
  });

  it('refuses a file that is not a ZIP at all', async () => {
    expect(await codeOf(inspectSnapshotZip(await put(Buffer.from('{"__meta":{}}'))))).toBe('BACKUP_ZIP_INVALID');
  });

  it('refuses oversize entries from their declared size — zeros that deflate to a few KB', async () => {
    const bigImage = await zipOf([
      ['data.json', DATA],
      [`images/${K1}.webp`, Buffer.alloc(ZIP_LIMITS.maxImageBytes + 1)],
    ]);
    expect(bigImage.length).toBeLessThan(100_000);
    expect(await codeOf(inspectSnapshotZip(await put(bigImage)))).toBe('BACKUP_ZIP_INVALID');

    const bigJson = await zipOf([['data.json', Buffer.alloc(ZIP_LIMITS.maxDataJsonBytes + 1, 0x20)]]);
    expect(await codeOf(inspectSnapshotZip(await put(bigJson)))).toBe('BACKUP_ZIP_INVALID');
  });

  it('refuses an entry whose real size is larger than the size it declares (zip bomb)', async () => {
    // Declare 1 byte in both headers for an entry that inflates to 2 MB.
    const zip = await zipOf([
      ['data.json', DATA],
      [`images/${K1}.webp`, Buffer.alloc(2 * 1024 * 1024)],
    ]);
    const lie = Buffer.from(zip);
    const real = Buffer.alloc(4);
    real.writeUInt32LE(2 * 1024 * 1024);
    const one = Buffer.alloc(4);
    one.writeUInt32LE(1);
    for (let at = lie.indexOf(real); at !== -1; at = lie.indexOf(real, at + 4)) one.copy(lie, at);
    const file = await put(lie);
    // The central directory now says 1 byte, so the structure check passes…
    await inspectSnapshotZip(file);
    // …and inflating it fails instead of producing 2 MB.
    expect(await codeOf(forEachZipImage(file, [K1], async () => {}))).toBe('BACKUP_ZIP_INVALID');
  });

  it(`refuses more than ${ZIP_LIMITS.maxEntries} entries`, async () => {
    const entries: Array<[string, string]> = [['data.json', DATA]];
    for (let i = 0; i < ZIP_LIMITS.maxEntries; i++) entries.push([`images/${i.toString(16).padStart(32, '0')}.webp`, '']);
    expect(await codeOf(inspectSnapshotZip(await put(await zipOf(entries))))).toBe('BACKUP_ZIP_INVALID');
  }, 60_000);
});
