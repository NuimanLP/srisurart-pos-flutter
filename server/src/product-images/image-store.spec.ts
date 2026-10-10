import { mkdtemp, readdir, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { imageFilePath, listImageKeys, removeImageFiles, writeImageFiles } from './image-store.js';

const TENANT = '0192f000-0000-7000-8000-000000000001';
const KEY = 'aaaaaaaabbbbbbbbccccccccdddddddd';

describe('product image store (contract §2)', () => {
  let root: string;
  const prev = process.env.PRODUCT_IMAGES_DIR;
  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'img-store-'));
    process.env.PRODUCT_IMAGES_DIR = root;
  });
  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
    if (prev === undefined) delete process.env.PRODUCT_IMAGES_DIR;
    else process.env.PRODUCT_IMAGES_DIR = prev;
  });

  it('lays files out as <tenantId>/<key>_t.webp and _p.webp', () => {
    expect(imageFilePath(TENANT, KEY, 't')).toBe(join(root, TENANT, `${KEY}_t.webp`));
    expect(imageFilePath(TENANT, KEY, 'p')).toBe(join(root, TENANT, `${KEY}_p.webp`));
  });

  it('refuses any tenant or key that could climb out of the volume', () => {
    expect(() => imageFilePath('../x', KEY, 't')).toThrow();
    expect(() => imageFilePath(TENANT, '../../etc/passwd', 't')).toThrow();
    expect(() => imageFilePath(TENANT, KEY.toUpperCase(), 't')).toThrow();
    expect(() => imageFilePath(TENANT, `${KEY}0`, 't')).toThrow();
  });

  it('writes both variants (no temp file left, world-readable for nginx) and removes them', async () => {
    await writeImageFiles(TENANT, KEY, { thumb: Buffer.from('t'), preview: Buffer.from('p') });
    expect((await readdir(join(root, TENANT))).sort()).toEqual([`${KEY}_p.webp`, `${KEY}_t.webp`]);
    if (process.platform !== 'win32') {
      expect((await stat(imageFilePath(TENANT, KEY, 't'))).mode & 0o777).toBe(0o644);
    }
    await removeImageFiles(TENANT, KEY);
    expect(await readdir(join(root, TENANT))).toEqual([]);
    await removeImageFiles(TENANT, KEY); // already gone: not an error
  });

  it('lists the keys on disk with their newest mtime, ignoring anything else', async () => {
    const other = 'f'.repeat(32);
    await writeImageFiles(TENANT, KEY, { thumb: Buffer.from('t'), preview: Buffer.from('p') });
    await writeImageFiles(TENANT, other, { thumb: Buffer.from('t'), preview: Buffer.from('p') });
    await writeFile(join(root, TENANT, `${KEY}_p.webp.123.tmp`), 'x');
    await writeFile(join(root, TENANT, 'notes.txt'), 'x');
    const old = new Date('2020-01-01T00:00:00Z');
    await utimes(imageFilePath(TENANT, other, 't'), old, old);
    await utimes(imageFilePath(TENANT, other, 'p'), old, old);
    const keys = await listImageKeys(TENANT);
    expect([...keys.keys()].sort()).toEqual([KEY, other].sort());
    expect(keys.get(other)).toBe(old.getTime());
    expect(keys.get(KEY)!).toBeGreaterThan(old.getTime());
    expect((await listImageKeys('0192f000-0000-7000-8000-0000000000ff')).size).toBe(0);
  });
});
