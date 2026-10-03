import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { TenantService } from '../common/database/tenant.service.js';
import { currentRequestContext } from '../common/request-context.js';
import {
  quoteAlreadyConverted,
  quoteExpired,
  quoteNotFound,
} from '../quotes/quote-errors.js';
import type { SaleWrite } from './sales.dto.js';
import {
  SalesService,
  type CreateSaleResult,
  type SaleActor,
} from './sales.service.js';

/**
 * Where a quote stands for the bill about to be sold from it:
 * - `fresh`   — open and in date; this bill converts it.
 * - `replay`  — already converted into THIS bill id; the sale path replays it.
 * - `missing` — no such quote (purged, or never existed).
 */
export type QuoteSaleState = 'fresh' | 'replay' | 'missing';

/** `lockAndClassify`: the states `lockForSale` refuses are facts here, not errors. */
export type QuoteLockResult =
  | { state: QuoteSaleState }
  | { state: 'converted'; convertedSaleId: string | null }
  | { state: 'expired'; validUntil: Date }
  | { state: 'sale_id_taken' };

/** The quote as `POST /sales` with a `quoteId` answers it, so the client can patch its row. */
export interface SoldQuote {
  id: string;
  status: string;
  convertedAt: string | null;
  convertedSaleId: string | null;
}

export type QuoteSaleResult = CreateSaleResult & { quote: SoldQuote | null };

/**
 * Selling a bill against a quote (#27, owner decision 2026-10-03, option (ข)):
 * `POST /sales` takes an optional `quoteId` and marks that quote converted in the
 * same transaction as the bill. The cart may differ from the quote freely — the
 * bill's lines and money are the body's, checked by the sale path as any bill is.
 *
 * 🔴 Lock order: the quote row `FOR UPDATE` first, then the sale path's own order
 * (sale → shift `FOR SHARE` → mechanic → products → `doc_counters` → customer).
 * `POST /quotes/:id/convert` takes the same prefix through `lockForSale`; nothing
 * else locks a quote after any of those, so the prefix cannot form a cycle.
 */
@Injectable()
export class QuoteSaleService {
  constructor(
    private readonly sales: SalesService,
    private readonly tenants: TenantService,
  ) {}

  /**
   * Locks the quote and decides whether `saleId` may be sold against it. Two bills
   * can never come from one quote: a second request waits on the row lock, then
   * finds it converted — into its own bill id (a retry: `replay`) or another one
   * (`409 QUOTE_ALREADY_CONVERTED`). The replay check runs before the expiry
   * check, so a quote converted on its last day still replays the next morning.
   *
   * Eligibility is `!converted && !expired` (`QuoteRowStatus`), not the status
   * string: an imported row stored as, say, `'cancelled'` but in date still sells.
   */
  async lockForSale(
    manager: EntityManager,
    tenantId: string,
    quoteId: string,
    saleId: string,
  ): Promise<QuoteSaleState> {
    const found = await this.lockAndClassify(manager, tenantId, quoteId, saleId);
    switch (found.state) {
      case 'converted':
        throw quoteAlreadyConverted(found.convertedSaleId);
      case 'expired':
        throw quoteExpired(found.validUntil);
      case 'sale_id_taken':
        throw new HttpException(
          {
            code: 'SALE_ID_REUSED',
            message: 'A different sale already exists under this id.',
          },
          HttpStatus.CONFLICT,
        );
      default:
        return found.state;
    }
  }

  /**
   * The lock and the classification `lockForSale` refuses on, without refusing — the
   * `/sync/push` replay of an offline `sale.create` needs them as facts, because by
   * then the customer has paid and the bill is accepted whatever the quote says
   * (owner, 2026-10-03; 08 §6.1).
   *
   * `soldAt` is when the bill is dated. Expiry is judged against it (owner,
   * 2026-10-03): an offline bill stores its device date (clamped, 08 §10), and a
   * quote valid at that moment was sold in time even if it lapsed before the sync.
   * Null is `now()` — exactly what `insertSale` stores for a bill with no date.
   */
  async lockAndClassify(
    manager: EntityManager,
    tenantId: string,
    quoteId: string,
    saleId: string,
    soldAt: Date | null = null,
  ): Promise<QuoteLockResult> {
    const rows = (await manager.query(
      `SELECT status, converted_sale_id, valid_until,
              (valid_until < COALESCE($3::timestamptz, now())) AS expired
         FROM quotes WHERE tenant_id = $1::uuid AND id = $2 FOR UPDATE`,
      [tenantId, quoteId, soldAt],
    )) as {
      status: string;
      converted_sale_id: string | null;
      valid_until: Date;
      expired: boolean;
    }[];
    if (rows.length === 0) return { state: 'missing' };
    const q = rows[0];

    if (q.status === 'converted') {
      return q.converted_sale_id === saleId
        ? { state: 'replay' }
        : { state: 'converted', convertedSaleId: q.converted_sale_id };
    }
    if (q.expired) return { state: 'expired', validUntil: q.valid_until };

    // The quote is still open, so no bill was ever committed from it: a sale already
    // under this id is a different bill. Without this, `existingSale` would replay
    // that bill and the quote would be marked converted into a sale it never was.
    const taken = (await manager.query(
      `SELECT 1 FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, saleId],
    )) as unknown[];
    return taken.length > 0 ? { state: 'sale_id_taken' } : { state: 'fresh' };
  }

  async markConverted(
    manager: EntityManager,
    tenantId: string,
    quoteId: string,
    saleId: string,
  ): Promise<void> {
    await manager.query(
      `UPDATE quotes SET status = 'converted', converted_at = now(), converted_sale_id = $3
        WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, quoteId, saleId],
    );
  }

  /** `POST /sales` with a `quoteId`: the body's own bill, and the quote marked converted. */
  sell(
    quoteId: string,
    dto: SaleWrite,
    actor: SaleActor,
  ): Promise<QuoteSaleResult> {
    return this.tenants.runTx(() => this.sellIn(quoteId, dto, actor));
  }

  private async sellIn(
    quoteId: string,
    dto: SaleWrite,
    actor: SaleActor,
  ): Promise<QuoteSaleResult> {
    const { tenantId, manager } = currentRequestContext();
    const state = await this.lockForSale(manager, tenantId, quoteId, dto.id);

    if (state === 'missing') {
      // A retry that lost its Idempotency-Key, after the converted quote was purged
      // (`POST /quotes/purge` may remove converted quotes): the bill stands, so it is
      // replayed rather than answered 404 — a 404 is a verdict, and the counter would
      // ring the bill up a second time.
      const existing = await this.sales.existingSale(manager, tenantId, dto);
      if (existing) return { ...existing, quote: null };
      throw quoteNotFound();
    }

    const sale = await this.sales.create(dto, actor);
    if (state === 'fresh') {
      await this.markConverted(manager, tenantId, quoteId, sale.id);
    }
    const rows = (await manager.query(
      `SELECT id, status, converted_at, converted_sale_id FROM quotes
        WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, quoteId],
    )) as {
      id: string;
      status: string;
      converted_at: Date | null;
      converted_sale_id: string | null;
    }[];
    const q = rows[0];
    return {
      ...sale,
      quote: {
        id: q.id,
        status: q.status,
        convertedAt: q.converted_at ? q.converted_at.toISOString() : null,
        convertedSaleId: q.converted_sale_id,
      },
    };
  }
}
