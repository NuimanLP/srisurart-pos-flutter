import { randomUUID } from 'node:crypto';
import type { LoggerService } from '@nestjs/common';
import { pino, type Logger } from 'pino';
import { pinoHttp } from 'pino-http';

/**
 * Single-line JSON logs. Request bodies are never serialised (pino-http does
 * not include them), so customer names / phone numbers never reach the log
 * through this layer. Business modules must log ids, not names or phones.
 */
export function createLogger(opts: {
  level: string;
  instanceId: string;
}): Logger {
  return pino({
    level: opts.level,
    base: { instance: opts.instanceId },
    redact: {
      paths: ['req.headers.authorization', 'req.headers.cookie'],
      censor: '[redacted]',
    },
  });
}

export const CORRELATION_HEADER = 'x-correlation-id';

/** Correlation id: taken from X-Correlation-ID (set by Nginx), else generated; always echoed. */
export function requestLogger(logger: Logger) {
  return pinoHttp({
    logger,
    genReqId: (req, res) => {
      const incoming = req.headers[CORRELATION_HEADER];
      const id =
        (Array.isArray(incoming) ? incoming[0] : incoming) || randomUUID();
      res.setHeader('X-Correlation-ID', id);
      return id;
    },
    customProps: (req) => ({ correlationId: req.id }),
  });
}

/** Adapts pino to Nest's LoggerService so framework logs share the JSON stream. */
export class PinoNestLogger implements LoggerService {
  constructor(private readonly logger: Logger) {}
  log(message: unknown, context?: string) {
    this.logger.info({ context }, String(message));
  }
  error(message: unknown, trace?: string, context?: string) {
    this.logger.error({ context, trace }, String(message));
  }
  warn(message: unknown, context?: string) {
    this.logger.warn({ context }, String(message));
  }
  debug(message: unknown, context?: string) {
    this.logger.debug({ context }, String(message));
  }
  verbose(message: unknown, context?: string) {
    this.logger.trace({ context }, String(message));
  }
}
