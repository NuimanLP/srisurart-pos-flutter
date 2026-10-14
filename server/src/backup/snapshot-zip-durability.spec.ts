import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * The replace-mode import deletes a shop's data right after `writeExportZip` returns the
 * pre-import copy, so a copy that is short on disk must throw — never return.
 */
const fault = vi.hoisted(() => ({ shortWrite: false, statDelta: 0 }));

vi.mock('node:fs/promises', async (importOriginal) => {
  const real = await importOriginal<typeof import('node:fs/promises')>();
  return {
    ...real,
    open: async (...args: Parameters<typeof real.open>) => {
      const fh = await real.open(...args);
      if (!fault.shortWrite) return fh;
      return new Proxy(fh, {
        get(target, prop) {
          if (prop === 'write') return async () => ({ bytesWritten: 0, buffer: Buffer.alloc(0) });
          const v = Reflect.get(target, prop);
          return typeof v === 'function' ? v.bind(target) : v;
        },
      });
    },
    stat: async (...args: Parameters<typeof real.stat>) => {
      const st = await real.stat(...args);
      if (fault.statDelta) Object.defineProperty(st, 'size', { value: Number(st.size) + fault.statDelta });
      return st;
    },
  };
});

const { writeExportZip } = await import('./snapshot-zip.js');
const TENANT = '0192f000-0000-7000-8000-00000000abcd';

describe('writeExportZip durability', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'export-file-'));
    fault.shortWrite = false;
    fault.statDelta = 0;
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it('writes the whole file and returns its size', async () => {
    const file = join(dir, 'ok.zip');
    const res = await writeExportZip(file, { a: 1, b: 'ข' }, TENANT);
    expect(res.sizeBytes).toBe((await readFile(file)).length);
  });

  it('throws on a write that makes no progress, and leaves no file behind', async () => {
    fault.shortWrite = true;
    await expect(writeExportZip(join(dir, 'short.zip'), { a: 1 }, TENANT)).rejects.toThrow(/short write/);
    expect(await readdir(dir)).toEqual([]);
  });

  it('throws when the file on disk is not the size it wrote', async () => {
    fault.statDelta = -1;
    await expect(writeExportZip(join(dir, 'size.zip'), { a: 1 }, TENANT)).rejects.toThrow(/bytes on disk, expected/);
  });
});
