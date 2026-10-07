import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * The replace-mode import deletes a shop's data right after `writeExportFile` returns the
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

const { writeExportFile } = await import('./export-file.js');

describe('writeExportFile durability', () => {
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
    const res = await writeExportFile(join(dir, 'ok.json'), { a: 1, b: 'ข' });
    expect(res.sizeBytes).toBe(Buffer.byteLength('{"a":1,"b":"ข"}', 'utf8'));
  });

  it('throws on a write that makes no progress, and leaves no file behind', async () => {
    fault.shortWrite = true;
    await expect(writeExportFile(join(dir, 'short.json'), { a: 1 })).rejects.toThrow(/short write/);
    expect(await readdir(dir)).toEqual([]);
  });

  it('throws when the file on disk is not the size it wrote', async () => {
    fault.statDelta = -1;
    await expect(writeExportFile(join(dir, 'size.json'), { a: 1 })).rejects.toThrow(/bytes on disk, expected/);
  });
});
