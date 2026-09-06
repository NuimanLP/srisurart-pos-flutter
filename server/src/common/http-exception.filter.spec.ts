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
