import { Writable } from 'node:stream';
import { pino } from 'pino';
import { describe, expect, it } from 'vitest';
import { REDACT_PATHS } from './logger.js';

// #443 PR3 (OWASP checklist, ADR-0009 "redact the body of /auth/*"): if anything ever logs a
// request body or a DTO, the secrets in it come out as `[redacted]`.
describe('logger redaction', () => {
  const capture = () => {
    const lines: string[] = [];
    const stream = new Writable({
      write(chunk, _enc, cb) {
        lines.push(chunk.toString());
        cb();
      },
    });
    const logger = pino({ redact: { paths: [...REDACT_PATHS], censor: '[redacted]' } }, stream);
    return { logger, lines };
  };

  it('redacts every secret body field, under req.body and in a logged DTO', () => {
    const { logger, lines } = capture();
    const secrets = {
      password: 'pw-secret-1',
      newPassword: 'pw-secret-2',
      currentPassword: 'pw-secret-3',
      ownerPassword: 'pw-secret-4',
      tempPassword: 'pw-secret-5',
      passwordChangeToken: 'pw-secret-6',
      enrolCode: 'ABCD1234',
    };
    logger.info({ req: { body: { ...secrets, code: 'EF567890', username: 'owner' } } });
    logger.info({ dto: secrets });

    const out = lines.join('\n');
    for (const v of [...Object.values(secrets), 'EF567890']) expect(out).not.toContain(v);
    expect(out).toContain('owner'); // non-secret fields survive
  });

  it('leaves an error code alone (a bare *.code would blank the SQLSTATE in 5xx logs)', () => {
    const { logger, lines } = capture();
    logger.error({ err: { code: '23505', message: 'duplicate key' } });
    expect(lines.join('')).toContain('23505');
  });
});
