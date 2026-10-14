import { randomUUID } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { HttpException, HttpStatus } from '@nestjs/common';
import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { toErrorEnvelope } from '../common/http-exception.filter.js';
import { importUploadDir } from './export-file.js';

/**
 * A backup ZIP on the import routes (contract §4): at most 200 MB, earned only by a verified
 * token (`app.setup.ts` decides who reaches this; nginx raises `client_max_body_size` on the
 * same two locations only). The body is streamed straight to a file on the `exports` volume —
 * never buffered: the api container is 384 MB.
 */
export const IMPORT_ZIP_LIMIT_BYTES = 200 * 1024 * 1024;

/**
 * Node's `server.requestTimeout` for the api (`main.ts`). Its default, 300 s, would cut off a
 * 200 MB ZIP uploaded at under ~5.6 Mbit/s — nginx streams the body through unbuffered, so the
 * API sees the client's own pace. 15 min covers `IMPORT_ZIP_LIMIT_BYTES` down to ~1.9 Mbit/s;
 * nginx still drops a client that stalls (`client_body_timeout`, 60 s between reads).
 */
export const IMPORT_REQUEST_TIMEOUT_MS = 15 * 60_000;

/** `application/x-zip-compressed` is what Windows browsers label a `.zip` with. */
const ZIP_TYPES = ['application/zip', 'application/x-zip-compressed'];

export interface ZipUploadRequest extends Request {
  /** Set by `streamZipUpload` once the whole body is on disk. */
  importZipFile?: string;
}

export function isZipUpload(req: Request): boolean {
  const type = req.is(ZIP_TYPES);
  return typeof type === 'string';
}

/** The uploaded ZIP's path, when the body was a ZIP. */
export function zipUploadOf(req: Request): string | undefined {
  return (req as ZipUploadRequest).importZipFile;
}

function tooLarge(res: Response, limit: number): void {
  const { status, body } = toErrorEnvelope(
    new HttpException(
      { code: 'PAYLOAD_TOO_LARGE', message: `Backup ZIP exceeds ${limit} bytes` },
      HttpStatus.PAYLOAD_TOO_LARGE,
    ),
  );
  res.status(status).json(body);
}

/**
 * Streams the request body into `importUploadDir()/<uuid>.zip` and records the path on the
 * request (`zipUploadOf`). Past `limit` bytes — declared or actually received — answers 413 and
 * removes the partial file. The import service moves the file to its job or deletes it;
 * anything a dead request leaves behind is pruned with the export files (`pruneExportFiles`).
 */
export function streamZipUpload(limit = IMPORT_ZIP_LIMIT_BYTES): RequestHandler {
  return (req: Request, res: Response, next: NextFunction): void => {
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > limit) {
      tooLarge(res, limit);
      return;
    }
    const dir = importUploadDir();
    const file = join(dir, `${randomUUID()}.zip`);
    let settled = false;
    const fail = (err: unknown, overLimit = false) => {
      if (settled) return;
      settled = true;
      void rm(file, { force: true });
      if (!overLimit) return next(err);
      // Answer once the client has finished sending: answering mid-upload makes Node close the
      // socket under a client that is still writing, which it sees as a reset, not a 413. The
      // rest is read and discarded — bounded by nginx's `client_max_body_size` on the location.
      req.resume();
      if (req.complete) tooLarge(res, limit);
      else req.once('end', () => tooLarge(res, limit));
    };
    mkdir(dir, { recursive: true }).then(
      () => {
        const out = createWriteStream(file, { flags: 'wx', mode: 0o600 });
        let received = 0;
        req.on('data', (chunk: Buffer) => {
          received += chunk.length;
          if (received > limit && !settled) {
            req.unpipe(out);
            out.destroy();
            fail(null, true);
          }
        });
        req.on('aborted', () => {
          out.destroy();
          fail(new Error('import upload aborted'));
        });
        out.on('error', (err) => fail(err));
        out.on('finish', () => {
          if (settled) return;
          settled = true;
          (req as ZipUploadRequest).importZipFile = file;
          next();
        });
        req.pipe(out);
      },
      (err) => fail(err),
    );
  };
}
