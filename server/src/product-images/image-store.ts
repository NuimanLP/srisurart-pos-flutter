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

/**
 * The `sale-photos` volume (10_SALE_PHOTO_EVIDENCE.md §5.3): the same `<tenantId>/<key>_{t,p}.webp`
 * layout, mounted by api and worker only at `SALE_PHOTOS_DIR` (`/app/sale-photos`). 🔴 nginx
 * never mounts it — a sale photo is never public; it is read through
 * `GET /sales/:saleId/photos/:photoId/:variant`, with a login. The 0755/0644 modes above are
 * shared code, not a need here: inside the container only the `node` user reads this volume.
 */
export function salePhotosDir(env: NodeJS.ProcessEnv = process.env): string {
  return env.SALE_PHOTOS_DIR || join(tmpdir(), 'pos-sale-photos');
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

/** One content-addressed image directory tree; `root` is read on every call (env may change). */
export interface ImageStore {
  imageFilePath(tenantId: string, key: string, variant: ImageVariant): string;
  writeImageFiles(tenantId: string, key: string, files: { thumb: Buffer; preview: Buffer }): Promise<boolean>;
  removeImageFiles(tenantId: string, key: string): Promise<void>;
  removeImageFilesIfStale(tenantId: string, key: string, now?: number): Promise<boolean>;
  listImageKeys(tenantId: string): Promise<Map<string, number>>;
}

export function imageStore(root: () => string): ImageStore {
  /**
   * Both parts are validated, so no value can climb out of `root()`. `isUuid` takes a
   * lowercase UUID only — for the product-images store that keeps every directory inside
   * nginx's lowercase `/img/` regex (nginx serves no other store).
   */
  function imageFilePath(tenantId: string, key: string, variant: ImageVariant): string {
    if (!isUuid(tenantId) || !IMAGE_KEY.test(key)) {
      throw new Error('Invalid tenant id or image key for an image file');
    }
    return join(root(), tenantId, `${key}_${variant}.webp`);
  }

  /**
   * Writes both variants, each to a unique temp name in the same directory and then renamed
   * over the final name (atomic): no reader (nginx for product images, the API for sale photos)
   * ever sees a half-written file. Content-addressed, so
   * rewriting an existing key writes the same bytes and is harmless — and it always rewrites,
   * never skips an existing file, so the mtime is fresh and `removeImageFilesIfStale` spares it.
   * Resolves `true` when this call created the key (no preview existed before it).
   */
  async function writeImageFiles(
    tenantId: string,
    key: string,
    files: { thumb: Buffer; preview: Buffer },
  ): Promise<boolean> {
    const preview = imageFilePath(tenantId, key, 'p');
    const thumb = imageFilePath(tenantId, key, 't');
    await mkdir(join(root(), tenantId), { recursive: true, mode: 0o755 });
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
  async function removeImageFiles(tenantId: string, key: string): Promise<void> {
    await rm(imageFilePath(tenantId, key, 't'), { force: true });
    await rm(imageFilePath(tenantId, key, 'p'), { force: true });
  }

  /**
   * Removes both variants of an unreferenced `key` unless either was written within
   * `ORPHAN_GRACE_MS` of `now` (a concurrent upload of the same image may be about to commit
   * it). Resolves `true` when the files are gone.
   */
  async function removeImageFilesIfStale(
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
   * its files (an orphan sweep must not delete a file a concurrent upload just wrote). Temp
   * files and anything not named like a variant are ignored.
   */
  async function listImageKeys(tenantId: string): Promise<Map<string, number>> {
    if (!isUuid(tenantId)) throw new Error('Invalid tenant id for an image directory');
    const dir = join(root(), tenantId);
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

  return { imageFilePath, writeImageFiles, removeImageFiles, removeImageFilesIfStale, listImageKeys };
}

/** The `product-images` volume — the store every product-image path (and the import sweep) uses. */
export const productImages = imageStore(() => productImagesDir());
/** The `sale-photos` volume — sale photo evidence only; never touched by an import. */
export const salePhotos = imageStore(() => salePhotosDir());

// The product-image functions as they were before the store took a root (callers unchanged).
export const {
  imageFilePath,
  writeImageFiles,
  removeImageFiles,
  removeImageFilesIfStale,
  listImageKeys,
} = productImages;
