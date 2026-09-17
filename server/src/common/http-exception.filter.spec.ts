import {
  HttpException,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { toErrorEnvelope } from './http-exception.filter.js';

describe('toErrorEnvelope', () => {
  it('uses the explicit code/message/details when provided', () => {
    const ex = new HttpException(
      {
        code: 'NOT_READY',
        message: 'dependencies down',
        details: { postgres: 'down' },
      },
      503,
    );
    expect(toErrorEnvelope(ex)).toEqual({
      status: 503,
      body: {
        status: 'error',
        error: {
          code: 'NOT_READY',
          message: 'dependencies down',
          details: { postgres: 'down' },
        },
      },
    });
  });

  it('falls back to the HTTP status name as the code', () => {
    expect(toErrorEnvelope(new NotFoundException()).body.error.code).toBe(
      'NOT_FOUND',
    );
    expect(
      toErrorEnvelope(new ServiceUnavailableException()).body.error.code,
    ).toBe('SERVICE_UNAVAILABLE');
  });

  it('answers a body-parser error with its own 4xx, and only when it looks like one (#239)', () => {
    const tooLarge = Object.assign(new Error('request entity too large'), { status: 413, statusCode: 413, expose: true, type: 'entity.too.large' });
    expect(toErrorEnvelope(tooLarge)).toEqual({
      status: 413,
      body: { status: 'error', error: { code: 'PAYLOAD_TOO_LARGE', message: 'request entity too large' } },
    });
    const untyped = Object.assign(new Error('internal detail'), { status: 400, expose: true });
    expect(toErrorEnvelope(untyped).status).toBe(500);
  });

  it('hides internals for unknown errors', () => {
    const out = toErrorEnvelope(
      new Error('pg: password authentication failed'),
    );
    expect(out.status).toBe(500);
    expect(out.body.error).toEqual({
      code: 'INTERNAL_ERROR',
      message: 'Internal server error',
    });
  });
});
