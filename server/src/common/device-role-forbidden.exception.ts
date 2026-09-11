import { HttpException, HttpStatus } from '@nestjs/common';

/**
 * ADR-0004: a `backoffice` device (or token with no device at all) may not touch
 * money/stock. `เครื่องนี้ขายของไม่ได้` is behaviour-parity Thai (CLAUDE.md) — copied
 * exactly, never translated — so it gets one home instead of four hand-typed copies.
 *
 * `HttpException(body, HttpStatus.FORBIDDEN)` and `ForbiddenException(body)` render
 * identically through `HttpExceptionFilter` (`ForbiddenException` is just
 * `HttpException` pinned to 403), so this single class is a safe drop-in for both.
 */
export class DeviceRoleForbiddenException extends HttpException {
  constructor() {
    super(
      { code: 'DEVICE_ROLE_FORBIDDEN', message: 'เครื่องนี้ขายของไม่ได้' },
      HttpStatus.FORBIDDEN,
    );
  }
}
