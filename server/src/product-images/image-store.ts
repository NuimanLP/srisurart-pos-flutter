import { randomUUID } from 'node:crypto';
import { mkdir, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isUuid } from '../common/ids.js';

/**
 * The `product-images` volume (contract §2): `<tenantId>/<imageKey>_t.webp` (thumbnail) and
 * `<tenantId>/<imageKey>_p.webp` (preview). api and worker mount it read-write at
 * `PRODUCT_IMAGES_DIR` (`/app/product-images`); nginx serves it read-only at `/img/`.
 *
 * Nginx reads these files as its own user, so directories are 0755 and files 0644 — the
 * volume holds nothing secret (the URL is public-but-unguessable by design).
 *
 * The tmpdir fallback only suits a single process (tests, a local `pnpm start`).
 */
export function productImagesDir(env: NodeJS.ProcessEnv = process.env): string {
  return env.PRODUCT_IMAGES_DIR || join(tmpdir(), 'pos-product-images');
}

export const IMAGE_KEY = /^[0-9a-f]{32}$/;
export type ImageVariant = 't' | 'p';

const FILE_NAME = /^([0-9a-f]{32})_([tp])\.webp$/;

/**
 * A file sitting unreferenced is removed only once it is older than this. A cleanup reads "no
 * product references key X" and then deletes X's files; an upload of the identical image may
 * have just (re)written X and not yet committed, and would then point a product at a missing
 * file. Every write refreshes the mtime (`writeImageFiles`), so a fresh file is spared.
 */
export const ORPHAN_GRACE_MS = 10 * 60_000;

/**
 * Both parts are validated, so no value can climb out of `productImagesDir()`. `isUuid` takes
 * a lowercase UUID only, so every directory matches nginx's lowercase `/img/` regex.
 */
export function imageFilePath(tenantId: string, key: string, variant: ImageVariant): string {
  if (!isUuid(tenantId) || !IMAGE_KEY.test(key)) {
    throw new Error('Invalid tenant id or image key for a product image file');
  }
  return join(productImagesDir(), tenantId, `${key}_${variant}.webp`);
}

/**
 * Writes both variants, each to a unique temp name in the same directory and then renamed over
 * the final name (atomic): nginx never serves a half-written file. Content-addressed, so
 * rewriting an existing key writes the same bytes and is harmless — and it always rewrites,
 * never skips an existing file, so the mtime is fresh and `removeImageFilesIfStale` spares it.
 * Resolves `true` when this call created the key (no preview existed before it).
 */
export async function writeImageFiles(
  tenantId: string,
  key: string,
  files: { thumb: Buffer; preview: Buffer },
): Promise<boolean> {
  const preview = imageFilePath(tenantId, key, 'p');
  const thumb = imageFilePath(tenantId, key, 't');
  await mkdir(join(productImagesDir(), tenantId), { recursive: true, mode: 0o755 });
  const created = await stat(preview).then(
    () => false,
    () => true,
  );
  // Preview first: the thumbnail is what a card asks for, so it appears only once both exist.
  for (const [path, bytes] of [
    [preview, files.preview],
    [thumb, files.thumb],
  ] as const) {
    const tmp = `${path}.${randomUUID()}.tmp`;
    try {
      await writeFile(tmp, bytes, { mode: 0o644 });
      await rename(tmp, path);
    } catch (err) {
      await rm(tmp, { force: true });
      throw err;
    }
  }
  return created;
}

/** Removes both variants of `key`. Missing files are not an error. */
export async function removeImageFiles(tenantId: string, key: string): Promise<void> {
  await rm(imageFilePath(tenantId, key, 't'), { force: true });
  await rm(imageFilePath(tenantId, key, 'p'), { force: true });
}

/**
 * Removes both variants of an unreferenced `key` unless either was written within
 * `ORPHAN_GRACE_MS` of `now` (a concurrent upload of the same image may be about to commit
 * it). Resolves `true` when the files are gone.
 */
export async function removeImageFilesIfStale(
  tenantId: string,
  key: string,
  now: number = Date.now(),
): Promise<boolean> {
  for (const variant of ['t', 'p'] as const) {
    try {
      if ((await stat(imageFilePath(tenantId, key, variant))).mtimeMs > now - ORPHAN_GRACE_MS) return false;
    } catch {
      // missing: nothing to spare
    }
  }
  await removeImageFiles(tenantId, key);
  return true;
}

/**
 * Every image key with at least one file in the tenant's directory, with the newest mtime of
 * its files (an orphan sweep must not delete a file a concurrent upload just wrote). Temp files
 * and anything not named like a variant are ignored.
 */
export async function listImageKeys(tenantId: string): Promise<Map<string, number>> {
  if (!isUuid(tenantId)) throw new Error('Invalid tenant id for a product image directory');
  const dir = join(productImagesDir(), tenantId);
  const keys = new Map<string, number>();
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return keys;
  }
  for (const name of names) {
    const m = FILE_NAME.exec(name);
    if (!m) continue;
    try {
      const { mtimeMs } = await stat(join(dir, name));
      keys.set(m[1], Math.max(keys.get(m[1]) ?? 0, mtimeMs));
    } catch {
      // removed meanwhile — nothing to report
    }
  }
  return keys;
}
