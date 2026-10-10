import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { request as httpRequest } from 'node:http';
import type { AddressInfo } from 'node:net';
import express from 'express';
import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { importUploadDir } from './export-file.js';
import { isZipUpload, streamZipUpload, zipUploadOf } from './zip-upload.js';

describe('streamZipUpload (contract §4)', () => {
  let dir: string;
  const prev = process.env.EXPORT_DIR;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'zip-upload-'));
    process.env.EXPORT_DIR = dir;
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
    if (prev === undefined) delete process.env.EXPORT_DIR;
    else process.env.EXPORT_DIR = prev;
  });

  const app = (limit: number) => {
    const a = express();
    a.post('/up', (req, res, next) => (isZipUpload(req) ? streamZipUpload(limit)(req, res, next) : next()), async (req, res) => {
      const file = zipUploadOf(req);
      res.json({ file: file ?? null, bytes: file ? (await readFile(file)).length : 0 });
    });
    return a;
  };
  const uploads = async () => readdir(importUploadDir()).catch(() => []);

  it('streams the body to a file under the uploads dir and hands its path on', async () => {
    const body = Buffer.alloc(5000, 7);
    const res = await request(app(10_000)).post('/up').set('Content-Type', 'application/zip').send(body);
    expect(res.status).toBe(200);
    expect(res.body.bytes).toBe(5000);
    expect(res.body.file.startsWith(importUploadDir())).toBe(true);
    expect(await uploads()).toHaveLength(1);
  });

  it('also takes the Windows browser label for a .zip', async () => {
    const res = await request(app(10_000)).post('/up').set('Content-Type', 'application/x-zip-compressed').send(Buffer.alloc(10));
    expect(res.body.bytes).toBe(10);
  });

  it('refuses a declared size past the limit with 413 before reading anything', async () => {
    const res = await request(app(1000)).post('/up').set('Content-Type', 'application/zip').send(Buffer.alloc(5000));
    expect(res.status).toBe(413);
    expect(res.body.error.code).toBe('PAYLOAD_TOO_LARGE');
    expect(await uploads()).toEqual([]);
  });

  it('refuses a body that grows past the limit without declaring it, and leaves no file', async () => {
    // Chunked, no Content-Length: only counting the bytes as they arrive can catch it.
    const server = app(1000).listen(0);
    const { port } = server.address() as AddressInfo;
    const res = await new Promise<{ status: number; body: { error: { code: string } } }>((resolve, reject) => {
      const req = httpRequest(
        { port, method: 'POST', path: '/up', headers: { 'Content-Type': 'application/zip' } },
        (r) => {
          let text = '';
          r.on('data', (c) => (text += c));
          r.on('end', () => resolve({ status: r.statusCode ?? 0, body: JSON.parse(text) }));
        },
      );
      req.on('error', reject);
      for (let i = 0; i < 16; i++) req.write(Buffer.alloc(4096));
      req.end();
    }).finally(() => server.close());
    expect(res.status).toBe(413);
    expect(res.body.error.code).toBe('PAYLOAD_TOO_LARGE');
    // The partial file is removed asynchronously right after the 413.
    await new Promise((r) => setTimeout(r, 50));
    expect(await uploads()).toEqual([]);
  });

  it('leaves a JSON body alone', async () => {
    const res = await request(app(10)).post('/up').send({ a: 1 });
    expect(res.body.file).toBeNull();
  });
});
