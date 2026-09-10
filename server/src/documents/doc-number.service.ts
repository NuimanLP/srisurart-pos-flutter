import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';

/** `doc_counters.doc_type` — the five series ADR-0007 defines. */
export type DocType = 'receipt' | 'po' | 'quote' | 'cn' | 'cp';

/** The letters printed on the paper, per ADR-0007. */
export const DOC_PREFIX: Record<DocType, string> = {
  receipt: 'RC',
  cn: 'CN',
  po: 'PO',
  quote: 'QT',
  cp: 'CP',
};

/** `last_no` is four digits (`CHECK (last_no <= 9999)`), so this is the last one. */
export const MAX_DOC_NO = 9999;

/** Postgres `check_violation` — what the counter's own CHECK raises past 9999. */
const CHECK_VIOLATION = '23514';

/**
 * `RC01-2569-08-0042` — type, two-digit device, Buddhist year-month, four-digit
 * running number.
 *
 * `device_no` is zero-padded to two digits without exception: `devices.device_no`
 * runs 1..99, and unpadded, machine 1 and machine 12 differ only by a separator
 * (`RC1-` vs `RC12-`), which parses back wrong (ADR-0007 corrects the example in
 * `01_DATABASE.md §7.2`).
 */
export function formatDocNumber(
  docType: DocType,
  deviceNo: number,
  period: string,
  seq: number,
): string {
  return [
    `${DOC_PREFIX[docType]}${String(deviceNo).padStart(2, '0')}`,
    period,
    String(seq).padStart(4, '0'),
  ].join('-');
}

/**
 * Issues document numbers. In phase 1 the server issues **every** series — RC, CN,
 * PO, QT and CP alike (ADR-0007 as amended 2026-09-04); the phase-2 split, where the
 * `pos` device issues RC and CN from its own Drift counter, is not built here and
 * `GET /doc-counters` does not exist yet.
 *
 * Three properties the shop's paperwork depends on:
 *
 * - **The number is allocated inside the caller's transaction.** A sale that rolls
 *   back takes its number with it, so the printed series has no visible hole.
 * - **`device_no` comes from the token's `did`, resolved here.** It is never read
 *   from a request body — a client that could choose it could print into another
 *   machine's series (ADR-0004).
 * - **The 10,000th document in one month on one device fails loudly.** Wrapping to
 *   0001 would re-issue a number already printed on paper a customer is holding.
 *
 * Numbers on documents imported from the old app are never rewritten: those are
 * random ids like `RC12345678ABCD`, they cannot collide with this format, and the
 * counter neither reads them nor reconciles against them (ADR-0007).
 */
@Injectable()
export class DocNumberService {
  /**
   * Allocates the next number for `(device, docType, current period)` under a row
   * lock on `doc_counters`, held to the end of `manager`'s transaction.
   *
   * The period is the Buddhist year and month **in the tenant's own timezone**:
   * a sale rung up at 00:30 in Bangkok belongs to that day's month, not to UTC's.
   */
  async issue(
    manager: EntityManager,
    params: { tenantId: string; deviceId: string; docType: DocType },
  ): Promise<string> {
    const deviceNo = await this.deviceNo(manager, params.tenantId, params.deviceId);

    // One statement: the period is derived from `tenants.timezone` and the counter
    // bumped in the same round trip. `ON CONFLICT DO UPDATE` is what serialises
    // concurrent allocations — the second transaction waits on the first's row lock,
    // then reads the committed value and adds one. No gaps but rolled-back ones.
    let rows: { period: string; last_no: number }[];
    try {
      rows = (await manager.query(
        `WITH p AS (
           SELECT (EXTRACT(YEAR FROM now() AT TIME ZONE t.timezone)::int + 543)
                  || '-' ||
                  to_char(now() AT TIME ZONE t.timezone, 'MM') AS period
             FROM tenants t
            WHERE t.id = $1::uuid
         )
         INSERT INTO doc_counters (tenant_id, device_id, doc_type, period, last_no)
         SELECT $1::uuid, $2, $3, p.period, 1 FROM p
         ON CONFLICT (tenant_id, device_id, doc_type, period)
         DO UPDATE SET last_no = doc_counters.last_no + 1
         RETURNING period, last_no`,
        [params.tenantId, params.deviceId, params.docType],
      )) as { period: string; last_no: number }[];
    } catch (err) {
      if ((err as { code?: string })?.code === CHECK_VIOLATION) {
        throw new HttpException(
          {
            code: 'DOC_NUMBER_EXHAUSTED',
            message: `Document numbers for this device are exhausted for this month (max ${MAX_DOC_NO}).`,
          },
          HttpStatus.CONFLICT,
        );
      }
      throw err;
    }

    // `SELECT … FROM p` inserts nothing when the tenant row is missing, and an
    // `ON CONFLICT` that matched nothing returns nothing either. Both mean no number
    // was allocated, and issuing one anyway would invent a duplicate.
    if (rows.length === 0) {
      throw new Error(
        `No document number allocated for tenant ${params.tenantId} (${params.docType}).`,
      );
    }

    return formatDocNumber(params.docType, deviceNo, rows[0].period, rows[0].last_no);
  }

  /**
   * The device's number, from the id the token carried. A retired device keeps its
   * `device_no` — numbers are never re-used, so its old series stays unambiguous —
   * but it may not issue new ones.
   */
  private async deviceNo(
    manager: EntityManager,
    tenantId: string,
    deviceId: string,
  ): Promise<number> {
    const rows = (await manager.query(
      `SELECT device_no, retired_at FROM devices WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, deviceId],
    )) as { device_no: number; retired_at: Date | null }[];

    if (rows.length === 0 || rows[0].retired_at !== null) {
      throw new HttpException(
        { code: 'DEVICE_ROLE_FORBIDDEN', message: 'เครื่องนี้ขายของไม่ได้' },
        HttpStatus.FORBIDDEN,
      );
    }
    return rows[0].device_no;
  }
}
