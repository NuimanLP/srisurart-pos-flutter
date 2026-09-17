import {
  Catch,
  HttpException,
  HttpStatus,
  type ArgumentsHost,
  type ExceptionFilter,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import type { Logger } from 'pino';

export interface ErrorEnvelope {
  status: 'error';
  error: { code: string; message: string; details?: unknown };
}

/**
 * Error envelope per 02_API_SCREENS.md §1.2.
 * Throw `new HttpException({ code, message, details }, status)` to control the
 * code; a plain HttpException falls back to the HTTP status name.
 */
export function toErrorEnvelope(exception: unknown): {
  status: number;
  body: ErrorEnvelope;
} {
  if (exception instanceof HttpException) {
    const status = exception.getStatus();
    const res = exception.getResponse();
    const obj =
      typeof res === 'object' && res !== null
        ? (res as Record<string, unknown>)
        : {};
    return {
      status,
      body: {
        status: 'error',
        error: {
          code: typeof obj.code === 'string' ? obj.code : HttpStatus[status],
          message:
            typeof obj.message === 'string' ? obj.message : exception.message,
          ...(obj.details !== undefined ? { details: obj.details } : {}),
        },
      },
    };
  }
  // Express middleware errors follow the `http-errors` convention: body-parser's
  // `PayloadTooLargeError` (413) or malformed JSON (400) carry `status` + `expose: true`.
  // They are the client's fault and must not read as a server crash (#239). body-parser
  // also sets `type` (`entity.too.large`, `entity.parse.failed`); requiring it keeps some
  // other library's error that happens to carry `status`/`expose` from leaking its message.
  const httpError = exception as { status?: unknown; expose?: unknown; message?: unknown; type?: unknown } | null;
  if (
    httpError &&
    httpError.expose === true &&
    typeof httpError.type === 'string' &&
    typeof httpError.status === 'number' &&
    httpError.status >= 400 &&
    httpError.status < 500
  ) {
    return {
      status: httpError.status,
      body: {
        status: 'error',
        error: {
          code: HttpStatus[httpError.status] ?? 'BAD_REQUEST',
          message: typeof httpError.message === 'string' ? httpError.message : 'Bad request',
        },
      },
    };
  }
  return {
    status: HttpStatus.INTERNAL_SERVER_ERROR,
    body: {
      status: 'error',
      error: { code: 'INTERNAL_ERROR', message: 'Internal server error' },
    },
  };
}

@Catch()
export class HttpExceptionFilter implements ExceptionFilter {
  constructor(private readonly logger: Logger) {}

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const req = ctx.getRequest<Request & { id?: string }>();
    const res = ctx.getResponse<Response>();
    const { status, body } = toErrorEnvelope(exception);

    if (exception instanceof HttpException) {
      const resp = exception.getResponse();
      if (typeof resp === 'object' && resp !== null) {
        const retryAfter = (resp as Record<string, unknown>).retryAfter;
        if (retryAfter !== undefined) {
          res.setHeader('Retry-After', String(retryAfter));
        }
      }
    }

    if (status >= 500) {
      this.logger.error(
        { correlationId: req.id, err: exception },
        'unhandled exception',
      );
    }
    res.status(status).json(body);
  }
}
