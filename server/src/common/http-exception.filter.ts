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
    const { status, body } = toErrorEnvelope(exception);
    if (status >= 500) {
      this.logger.error(
        { correlationId: req.id, err: exception },
        'unhandled exception',
      );
    }
    ctx.getResponse<Response>().status(status).json(body);
  }
}
