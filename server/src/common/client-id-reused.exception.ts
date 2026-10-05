import { HttpException, HttpStatus } from '@nestjs/common';

/**
 * 409 `CLIENT_ID_REUSED` (08 §10): a client-minted id that already exists for this tenant but
 * carries different content — another drawer/bill collided on the id, not a replay. The Thai
 * text is ratified behaviour-parity copy; one home for `/sync/push` and `POST /shifts/open`.
 */
export class ClientIdReusedException extends HttpException {
  constructor(type: string, id: string) {
    super(
      {
        code: 'CLIENT_ID_REUSED',
        message: 'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ',
        details: { type, id },
      },
      HttpStatus.CONFLICT,
    );
  }
}
