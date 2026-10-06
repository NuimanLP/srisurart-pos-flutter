import {
  ConflictException,
  HttpException,
  HttpStatus,
  Injectable,
  Logger,
} from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { ClientIdReusedException } from '../common/client-id-reused.exception.js';
import { TenantService } from '../common/database/tenant.service.js';
import { invalidUuidInput, isUuid } from '../common/ids.js';
import { DOC_NUMBER_REGEX, tenantPeriodSql } from '../documents/doc-number.service.js';
import { fromSatang, satangOf } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { CustomersService } from '../customers/customers.service.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { CreditPaymentsService } from '../mechanics/credit-payments.service.js';
import { expectedCashSatangOf } from '../reports/drawer-cash.sql.js';
import { ReviewItemsService } from '../review-items/review-items.service.js';
import { ReturnsService } from '../returns/returns.service.js';
import { SalesService, type CreateSaleResult } from '../sales/sales.service.js';
import {
  QuoteSaleService,
  type QuoteLockResult,
} from '../sales/quote-sale.service.js';
import type { SaleWrite } from '../sales/sales.dto.js';
import { VoidService } from '../sales/void.service.js';
import { ShiftsService } from '../shifts/shifts.service.js';
import {
  clientIdOf,
  docNoOf,
  parseOpPayload,
  replayProbeOf,
  targetIdOf,
  type ParsedSyncOp,
  type SyncDiscardDto,
  type SyncOpDto,
  type SyncOpResult,
  type SyncPushDto,
  type SyncOpType,
  type SyncPushResponse,
} from './sync.dto.js';

/**
 * The global prefix `app.setup.ts` gives every route (`setGlobalPrefix('api/v1')`).
 * 08 §8.3 step 1 fingerprints an op exactly as its online route does, and the online
 * route records `${req.method} ${req.baseUrl}${req.path}` — prefix included (#409).
 */
const ONLINE_PREFIX = '/api/v1';

export interface PushActor {
  userId: string;
  tenantId: string;
  deviceId: string;
}

export interface PushDevice {
  id: string;
  role: string;
}

@Injectable()
export class SyncService {
  private readonly logger = new Logger(SyncService.name);

  constructor(
    private readonly tenants: TenantService,
    private readonly idempotency: IdempotencyService,
    private readonly sales: SalesService,
    private readonly quoteSales: QuoteSaleService,
    private readonly returns: ReturnsService,
    private readonly shifts: ShiftsService,
    private readonly creditPayments: CreditPaymentsService,
    private readonly customers: CustomersService,
    private readonly voids: VoidService,
    private readonly audit: AuditService,
  ) {}

  async processPush(
    actor: PushActor,
    device: PushDevice,
    dto: SyncPushDto,
  ): Promise<SyncPushResponse> {
    const results: SyncOpResult[] = [];
    let stopAtRetry = false;

    for (let i = 0; i < dto.ops.length; i++) {
      const op = dto.ops[i];

      if (stopAtRetry) {
        // B3: Subsequent ops are not processed and returned as retry
        results.push({ opId: op.opId, status: 'retry' });
        continue;
      }

      try {
        const result = await this.processSingleOp(actor, device, op);
        results.push(result);
        if (result.status === 'retry') {
          stopAtRetry = true;
        }
      } catch (err) {
        const mapped = this.mapOpError(op, tryParseOpPayload(op), err);
        results.push(mapped);
        if (mapped.status === 'retry') {
          stopAtRetry = true;
        }
      }
    }

    // Update devices.unsynced_ops and unsynced_reported_at (08 §8.2 C12)
    try {
      await this.updateUnsyncedOps(actor, dto.outboxRemaining);
    } catch (err) {
      this.logger.warn(`Failed to update devices.unsynced_ops: ${err}`);
    }

    return {
      results,
    };
  }

  updateUnsyncedOps(actor: PushActor, outboxRemaining: number): Promise<void> {
    return this.tenants.runTx(() => this.updateUnsyncedOpsIn(actor, outboxRemaining));
  }

  private async updateUnsyncedOpsIn(
    actor: PushActor,
    outboxRemaining: number,
  ): Promise<void> {
    const { tenantId, manager } = currentRequestContext();
    await manager.query(
      `UPDATE devices SET unsynced_ops = $1, unsynced_reported_at = now() WHERE tenant_id = $2::uuid AND id = $3`,
      [outboxRemaining, tenantId, actor.deviceId],
    );
  }

  processSingleOp(
    actor: PushActor,
    device: PushDevice,
    raw: SyncOpDto,
  ): Promise<SyncOpResult> {
    return this.tenants.runTx(() => this.processSingleOpIn(actor, device, raw));
  }

  private async processSingleOpIn(
    actor: PushActor,
    device: PushDevice,
    raw: SyncOpDto,
  ): Promise<SyncOpResult> {
    const { tenantId, manager } = currentRequestContext();
    // B1 (08 §8.3): replay by key BEFORE any check — the fingerprint and the route come
    // from the payload exactly as sent, so an op committed earlier still replays its
    // stored reply even if today's parser would refuse its body.
    const ep = endpointForOp(raw);
    const requestHash = IdempotencyService.requestHash(raw.payload);

    // Step 1: Idempotency claim & replay check (08 §8.3 step 1)
    const claim = await this.idempotency.claim(manager, {
      tenantId,
      key: raw.idempotencyKey,
      endpoint: ep.endpoint,
      requestHash,
    });

    if (claim.outcome === 'replay') {
      return {
        opId: raw.opId,
        status: 'applied',
        response: claim.response.body,
      };
    }

    if (claim.outcome === 'reused') {
      // #409: the key is already recorded against a different fingerprint. The usual
      // cause is not a misused key: the bill was committed ONLINE, its reply was lost,
      // and the client queued it with the same id and key — adding `receiptNo`/`date`,
      // so the body hash cannot match. 08 §8.3 makes a key miss fall through to the
      // client-id replay (step 2) and §8.4 AC B1 expects `applied` for exactly this.
      // Only when the key was recorded for THIS op's own document, though — the same
      // key on a different bill stays refused.
      const ownReplay = await this.replayKeyOfSameDocument(manager, tenantId, raw, ep.endpoint);
      if (ownReplay !== null) {
        return { opId: raw.opId, status: 'applied', response: ownReplay };
      }
      // A body the parser refuses keeps that refusal, as before the replay moved ahead.
      parseOpPayload(raw);
      throw new ConflictException({
        code: 'IDEMPOTENCY_KEY_REUSED',
        message: 'Idempotency-Key already used for a different request',
      });
    }

    // Step 2: Client ID replay check (08 §8.3 step 2, §6.1) — also before the parser:
    // a document the server already holds replays even when its key row is gone and
    // today's parser would refuse the body (`replayProbeOf`).
    const clientReplay = await this.checkClientIdReplay(manager, tenantId, raw);
    if (clientReplay !== null) {
      // Complete idempotency claim with the existing response
      await this.idempotency.complete(manager, {
        tenantId,
        key: raw.idempotencyKey,
        response: { code: ep.successCode, body: clientReplay },
      });
      return {
        opId: raw.opId,
        status: 'applied',
        response: clientReplay,
      };
    }

    // #619: the one typed parser, only once neither replay answered. A refusal throws
    // inside this transaction, so the claim rolls back and the op is `rejected` per op
    // (`INVALID_ID` for a bad id) — never `retry`.
    const op = parseOpPayload(raw);

    // Step 3: Domain execution with date clamping & side-effects
    const responseBody = await this.executeOp(
      manager,
      tenantId,
      actor,
      device,
      op,
    );

    // Step 4: Complete idempotency key
    await this.idempotency.complete(manager, {
      tenantId,
      key: op.idempotencyKey,
      response: { code: ep.successCode, body: responseBody },
    });

    return {
      opId: op.opId,
      status: 'applied',
      response: responseBody,
    };
  }

  /**
   * The client-id replay (step 2) for an op whose key is recorded under a different
   * fingerprint — but only if that record answered for this op's own document (its
   * stored response names the same id, on this op's own route). Otherwise null, and the
   * caller refuses the key. A mismatch between the op and the stored row still throws
   * `CLIENT_ID_REUSED`.
   *
   * The route is compared with the `/api/v1` prefix stripped, so a key an older push
   * recorded as `POST /sales` (before #409) still replays within its 24 h life.
   */
  private async replayKeyOfSameDocument(
    manager: EntityManager,
    tenantId: string,
    op: SyncOpDto,
    endpoint: string,
  ): Promise<any | null> {
    const idField = op.type === 'sale.void_offline' ? 'saleId' : 'id';
    const clientId = replayProbeOf(op)?.id;
    if (!clientId) return null;
    const rows = (await manager.query(
      `SELECT endpoint, response_body ->> $3 AS stored_id FROM idempotency_keys
        WHERE tenant_id = $1::uuid AND key = $2`,
      [tenantId, op.idempotencyKey, idField],
    )) as { endpoint: string; stored_id: string | null }[];
    const unprefixed = (e: string) => e.replace(` ${ONLINE_PREFIX}/`, ' /');
    const stored = rows[0];
    if (
      !stored ||
      unprefixed(stored.endpoint) !== unprefixed(endpoint) ||
      stored.stored_id !== clientId
    ) {
      return null;
    }
    return this.checkClientIdReplay(manager, tenantId, op);
  }

  private async checkClientIdReplay(
    manager: EntityManager,
    tenantId: string,
    raw: SyncOpDto,
  ): Promise<any | null> {
    // Runs before `parseOpPayload`: reads only what `replayProbeOf` takes from the body.
    const op = replayProbeOf(raw);
    if (op === null) return null;
    const id = op.id;
    switch (op.type) {
      case 'shift.open': {
        const rows = (await manager.query(
          `SELECT id, starting_cash, opened_at, auto_archived FROM shifts WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, id],
        )) as {
          id: string;
          starting_cash: string;
          opened_at: Date;
          auto_archived: boolean;
        }[];
        if (rows.length === 0) return null;
        const row = rows[0];
        if (satangOf(row.starting_cash) !== op.startingCashSatang) {
          throw new ClientIdReusedException(op.type, id);
        }
        return {
          id: row.id,
          startingCash: fromSatang(satangOf(row.starting_cash)),
          openedAt:
            row.opened_at instanceof Date
              ? row.opened_at.toISOString()
              : String(row.opened_at),
          autoArchived: row.auto_archived,
        };
      }

      case 'sale.create': {
        // #455 / 08 §8.2: the reply IS the `POST /sales` reply, so it comes from the
        // very function that route answers a replay-by-id with — never a second
        // hand-built shape. Its `SALE_ID_REUSED` (total differs) maps to
        // `CLIENT_ID_REUSED` in `mapOpError`.
        // A total that does not read (`null`) never matches: `SALE_ID_REUSED`.
        const existing = await this.sales.existingSale(manager, tenantId, {
          id,
          totalSatang: op.totalSatang ?? Number.NaN,
          soldOffline: true,
        });
        if (existing === null) return null;
        await this.flagRenumbered(manager, tenantId, raw, existing.id, op.receiptNo, existing.receiptNo);
        return existing;
      }

      case 'return.create': {
        const rows = (await manager.query(
          `SELECT id, cn_no, sale_id, refund_total, refund_method FROM returns WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, id],
        )) as {
          id: string;
          cn_no: string;
          sale_id: string;
          refund_total: string;
          refund_method: string;
        }[];
        if (rows.length === 0) return null;
        const row = rows[0];
        if (row.sale_id !== op.saleId) {
          throw new ClientIdReusedException(op.type, id);
        }

        // Compare items
        const lineRows = (await manager.query(
          `SELECT product_id, qty, price FROM return_items WHERE tenant_id = $1::uuid AND return_id = $2 ORDER BY line_no ASC`,
          [tenantId, row.id],
        )) as { product_id: string; qty: number; price: string }[];
        const opItems = op.items;
        if (lineRows.length !== opItems.length) {
          throw new ClientIdReusedException(op.type, id);
        }
        for (let i = 0; i < lineRows.length; i++) {
          const lr = lineRows[i];
          const oi = opItems[i];
          if (
            lr.product_id !== oi.productId ||
            lr.qty !== oi.qty ||
            satangOf(lr.price) !== oi.priceSatang
          ) {
            throw new ClientIdReusedException(op.type, id);
          }
        }
        await this.flagRenumbered(manager, tenantId, raw, row.id, op.cnNo, row.cn_no);

        const productIds = lineRows.map((it) => it.product_id);
        const products =
          productIds.length > 0
            ? ((await manager.query(
                `SELECT id, stock FROM products WHERE tenant_id = $1::uuid AND id = ANY($2::uuid[])`,
                [tenantId, productIds],
              )) as { id: string; stock: number }[])
            : [];

        return {
          id: row.id,
          cnNo: row.cn_no,
          saleId: row.sale_id,
          total: fromSatang(satangOf(row.refund_total)),
          refundMethod: row.refund_method,
          stockRestored: products,
        };
      }

      case 'drawer.entry': {
        const rows = (await manager.query(
          `SELECT id, type, amount, note, shift_id FROM drawer_entries WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, id],
        )) as {
          id: string;
          type: string;
          amount: string;
          note: string;
          shift_id: string;
        }[];
        if (rows.length === 0) return null;
        const row = rows[0];
        if (
          row.type !== op.entryType ||
          satangOf(row.amount) !== op.amountSatang
        ) {
          throw new ClientIdReusedException(op.type, id);
        }
        const balanceAfter = await this.computeShiftBalance(
          manager,
          tenantId,
          row.shift_id,
        );
        return {
          id: row.id,
          type: row.type,
          amount: fromSatang(satangOf(row.amount)),
          note: row.note,
          balanceAfter,
        };
      }

      case 'credit_payment.create': {
        const rows = (await manager.query(
          `SELECT id, mechanic_id, amount, payment_method FROM credit_payments WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, id],
        )) as {
          id: string;
          mechanic_id: string;
          amount: string;
          payment_method: string;
        }[];
        if (rows.length === 0) return null;
        const row = rows[0];
        if (
          row.mechanic_id !== op.mechanicId ||
          satangOf(row.amount) !== op.amountSatang ||
          row.payment_method !== op.paymentMethod
        ) {
          throw new ClientIdReusedException(op.type, id);
        }
        const mech = (await manager.query(
          `SELECT credit_balance FROM mechanics WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, row.mechanic_id],
        )) as { credit_balance: string }[];
        return {
          id: row.id,
          mechanicId: row.mechanic_id,
          amount: fromSatang(satangOf(row.amount)),
          paymentMethod: row.payment_method,
          balanceAfter: mech[0] ? fromSatang(satangOf(mech[0].credit_balance)) : '0.00',
        };
      }

      case 'customer.create': {
        const rows = (await manager.query(
          `SELECT id, name, phone, address, total_spend, points FROM customers WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL`,
          [tenantId, id],
        )) as {
          id: string;
          name: string;
          phone: string | null;
          address: string | null;
          total_spend: string;
          points: number;
        }[];
        if (rows.length === 0) return null;
        const row = rows[0];
        // C7: id only, no field comparison
        return {
          id: row.id,
          name: row.name,
          phone: row.phone,
          address: row.address,
          totalSpend: fromSatang(satangOf(row.total_spend)),
          points: row.points,
        };
      }

      case 'sale.void_offline': {
        const saleId = id;
        const rows = (await manager.query(
          `SELECT id, voided, void_reason, sold_offline FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, saleId],
        )) as {
          id: string;
          voided: boolean;
          void_reason: string | null;
          sold_offline: boolean;
        }[];
        if (rows.length === 0) return null;
        if (rows[0].voided) {
          const items = (await manager.query(
            `SELECT product_id FROM sale_items WHERE tenant_id = $1::uuid AND sale_id = $2`,
            [tenantId, saleId],
          )) as { product_id: string }[];
          const productIds = items.map((it) => it.product_id);
          const products =
            productIds.length > 0
              ? ((await manager.query(
                  `SELECT id AS "productId", stock FROM products WHERE tenant_id = $1::uuid AND id = ANY($2::uuid[])`,
                  [tenantId, productIds],
                )) as { productId: string; stock: number }[])
              : [];
          return {
            saleId: rows[0].id,
            status: 'voided',
            voidReason: rows[0].void_reason ?? op.reason,
            stockRestored: products,
          };
        }
        return null;
      }
    }
  }

  private async executeOp(
    manager: EntityManager,
    tenantId: string,
    actor: PushActor,
    device: PushDevice,
    op: ParsedSyncOp,
  ): Promise<any> {
    switch (op.type) {
      case 'shift.open': {
        const previousActive = (await manager.query(
          `SELECT id FROM shifts WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active LIMIT 1`,
          [tenantId, device.id],
        )) as { id: string }[];

        // Refused (400 → `rejected`) when unparseable, instead of an Invalid Date → 500.
        // Not clamped by `clampOpDate`: it measures against the device's *previous* shift,
        // which would pull a legitimate earlier offline open forward. Only the future side
        // is checked (owner 2026-09-25, 08 §10): `> now() + 5 min` → `now()` + `date_flag`,
        // since a future `opened_at` would push every later op of the shift out of its window.
        let openedAt = op.openedAt;
        const now = new Date();
        if (openedAt && openedAt.getTime() > now.getTime() + DATE_TOLERANCE_MS) {
          await insertDateFlag(manager, tenantId, op, openedAt, now, null);
          openedAt = now;
        }

        const opened = await this.shifts.open(
          { userId: actor.userId, deviceId: device.id },
          { ...op.shift, openedAt },
        );

        const autoArchived = previousActive.length > 0;
        return {
          id: opened.id,
          startingCash: opened.startingCash,
          openedAt: opened.openedAt,
          autoArchived,
          ...(autoArchived ? { archivedShiftId: previousActive[0].id } : {}),
        };
      }

      case 'sale.create': {
        const clampedDate = await this.clampOpDate(
          manager,
          tenantId,
          device.id,
          op,
        );

        const saleInput: SaleWrite = {
          ...deviceDated(op.sale, clampedDate),
          soldOffline: true,
        };

        // #27 follow-up (owner, 2026-10-03, 08 §6.1): a cart sold offline from a quote.
        // The quote row is locked FIRST — the same order as `POST /sales` `quoteId`.
        const quoteId = op.quoteId;
        const quote =
          quoteId === null
            ? null
            : await this.quoteSales.lockAndClassify(
                manager,
                tenantId,
                quoteId,
                saleInput.id,
                // The date the bill is stored with (08 §10 clamp) — expiry is judged
                // at the sale, not at the sync (owner, 2026-10-03).
                clampedDate,
              );

        // #455 / 08 §8.2: the whole `POST /sales` reply — `items[].costAtSale`,
        // `movements`, `shiftId`, `date` and the ledgers included.
        const sale = await this.sales.create(saleInput, {
          userId: actor.userId,
          deviceId: device.id,
        });
        if (quote !== null && quoteId !== null) {
          await this.settleOfflineQuote(manager, tenantId, op, quoteId, sale, quote);
        }
        return sale;
      }

      case 'return.create': {
        const clampedDate = await this.clampOpDate(
          manager,
          tenantId,
          device.id,
          op,
        );

        const returnInput = deviceDated(op.ret, clampedDate);

        const created = await this.returns.create(returnInput, {
          userId: actor.userId,
          deviceId: device.id,
        });

        return {
          id: created.id,
          cnNo: created.cnNo,
          saleId: created.saleId,
          total: created.refundTotal,
          refundMethod: created.refundMethod,
          stockRestored: created.products,
        };
      }

      case 'drawer.entry': {
        const clampedDate = await this.clampOpDate(
          manager,
          tenantId,
          device.id,
          op,
        );

        const entry = await this.shifts.addEntry(
          { userId: actor.userId, deviceId: device.id },
          { ...op.entry, createdAt: clampedDate },
          // The cash already left the drawer offline — never refuse the record of it
          // (DRAWER_INSUFFICIENT_CASH is for the online counter only).
          { offlineReplay: true },
        );

        const balanceAfter = await this.computeShiftBalance(
          manager,
          tenantId,
          entry.shiftId,
        );

        if (entry.type === 'out') {
          await this.flagOverdrawnOffline(manager, tenantId, op, entry);
        }

        return {
          id: entry.id,
          type: entry.type,
          amount: entry.amount,
          note: entry.note,
          balanceAfter,
        };
      }

      case 'credit_payment.create': {
        const res = await this.creditPayments.create(
          op.mechanicId,
          op.payment,
          { userId: actor.userId, deviceId: device.id },
        );

        return {
          id: res.id,
          mechanicId: res.mechanicId,
          amount: res.amount,
          paymentMethod: res.paymentMethod,
          balanceAfter: res.mechanicCreditBalanceAfter,
        };
      }

      case 'customer.create': {
        const created = await this.customers.create(op.customer);

        return {
          id: created.id,
          name: created.name,
          phone: created.phone,
          address: created.address,
          totalSpend: created.totalSpend,
          points: created.points,
        };
      }

      case 'customer.update': {
        const updated = await this.customers.update(op.id, op.patch);

        return {
          id: updated.id,
          phone: updated.phone,
        };
      }

      case 'sale.void_offline': {
        const saleId = op.saleId;
        const sales = (await manager.query(
          `SELECT id, sold_offline, shift_id FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, saleId],
        )) as { id: string; sold_offline: boolean; shift_id: string | null }[];

        if (sales.length === 0) {
          throw new HttpException(
            { code: 'SALE_NOT_FOUND', message: 'Sale not found' },
            HttpStatus.NOT_FOUND,
          );
        }

        if (!sales[0].sold_offline) {
          throw new HttpException(
            {
              code: 'VOID_NEEDS_ONLINE',
              message: 'บิลออนไลน์สามารถยกเลิกได้เมื่อเชื่อมต่ออินเทอร์เน็ตเท่านั้น',
              details: { saleId },
            },
            HttpStatus.CONFLICT,
          );
        }

        const voidReason = op.reason;

        await this.voids.void(saleId, {
          userId: actor.userId,
          role: 'owner',
          deviceId: device.id,
          reason: voidReason,
        });

        await ReviewItemsService.insertIn(manager, tenantId, {
          kind: 'void_offline',
          refId: saleId,
          details: {
            saleId,
            reason: voidReason,
          },
        });

        const items = (await manager.query(
          `SELECT product_id FROM sale_items WHERE tenant_id = $1::uuid AND sale_id = $2`,
          [tenantId, saleId],
        )) as { product_id: string }[];
        const productIds = items.map((it) => it.product_id);
        const products =
          productIds.length > 0
            ? ((await manager.query(
                `SELECT id AS "productId", stock FROM products WHERE tenant_id = $1::uuid AND id = ANY($2::uuid[])`,
                [tenantId, productIds],
              )) as { productId: string; stock: number }[])
            : [];

        return {
          saleId,
          status: 'voided',
          voidReason,
          stockRestored: products,
        };
      }
    }
  }

  /**
   * The device's date for a queued write, per 08 §10 (owner 2026-09-25):
   * - field absent (`undefined`/`null`) → null (the service stamps `now()`; §10 does not
   *   refuse a missing date);
   * - present but unparseable — the empty string included → 400 → the op is `rejected`
   *   (never silently `now()`, never a fall-through to the other field);
   * - the device's OPEN shift (`is_active AND closed_at IS NULL` — the only shift a bill or
   *   cash refund can land in, `ShiftsService.requireOpenShiftIdFor`) → window
   *   `[opened_at − 5 min, now() + 5 min]`, outside it clamp into `[opened_at, now()]`;
   * - no open shift → only the future side is checked: `> now() + 5 min` → `now()`; a past
   *   date is kept (nothing to measure it against);
   * - the document number's period (RC/CN, device clock, C2) ≠ the Buddhist year-month of
   *   the stored date in the tenant's timezone → flagged, never refused.
   * Any clamp or period mismatch → ONE `date_flag` for the op.
   */
  private async clampOpDate(
    manager: EntityManager,
    tenantId: string,
    deviceId: string,
    op: Extract<ParsedSyncOp, { deviceDate: Date | undefined }>,
  ): Promise<Date | null> {
    const opDate = op.deviceDate ?? null;

    const shiftRows = (await manager.query(
      `SELECT opened_at FROM shifts
        WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active AND closed_at IS NULL
        ORDER BY opened_at DESC LIMIT 1`,
      [tenantId, deviceId],
    )) as { opened_at: Date }[];
    const openedAt = shiftRows.length > 0 ? new Date(shiftRows[0].opened_at) : null;

    const now = new Date();
    let stored = opDate;
    if (opDate && opDate.getTime() > now.getTime() + DATE_TOLERANCE_MS) {
      stored = now;
    } else if (opDate && openedAt && opDate.getTime() < openedAt.getTime() - DATE_TOLERANCE_MS) {
      stored = openedAt;
    }

    // One clock: a bill with no date is measured at the same `now` the clamp used.
    const periodFlag = await this.periodMismatch(manager, tenantId, op, stored ?? now);
    if (stored !== opDate || periodFlag) {
      await insertDateFlag(manager, tenantId, op, opDate, stored, openedAt, periodFlag);
    }
    return stored;
  }

  /**
   * 08 §10 / C2: the period printed in the op's RC/CN number vs the Buddhist year-month of
   * the date it is stored under, in the tenant's own timezone — the same calendar the
   * issuer numbers into (`tenantPeriodSql`). Null when they agree, or when the op carries
   * no well-formed number (the service validates it later).
   */
  private async periodMismatch(
    manager: EntityManager,
    tenantId: string,
    op: ParsedSyncOp,
    date: Date,
  ): Promise<PeriodFlag | null> {
    const docNo = wellFormedDocNo(docNoOf(op));
    if (!docNo) return null;
    const docPeriod = DOC_NUMBER_REGEX.exec(docNo)![3];
    const rows = (await manager.query(
      `SELECT ${tenantPeriodSql('$2::timestamptz')} AS period FROM tenants t WHERE t.id = $1::uuid`,
      [tenantId, date],
    )) as { period: string }[];
    const datePeriod = rows[0]?.period;
    if (!datePeriod || datePeriod === docPeriod) return null;
    return { docNo, docPeriod, datePeriod };
  }

  /**
   * #27 follow-up (owner, 2026-10-03, 08 §6.1). The money was taken, so the bill always
   * stands. A quote still open is converted into it, as online. A quote converted
   * into another bill, expired, or gone is left exactly as it is, and the owner gets
   * one `quote_conflict` review item for the bill instead.
   */
  private async settleOfflineQuote(
    manager: EntityManager,
    tenantId: string,
    op: ParsedSyncOp,
    quoteId: string,
    sale: CreateSaleResult,
    quote: QuoteLockResult,
  ): Promise<void> {
    let reason: 'already_converted' | 'expired' | 'not_found';
    switch (quote.state) {
      case 'fresh':
        await this.quoteSales.markConverted(manager, tenantId, quoteId, sale.id);
        return;
      case 'replay':
      // Unreachable on a first apply: the client-id replay runs before this op, and
      // `sales.create` would refuse a taken id before we got here.
      case 'sale_id_taken':
        return;
      case 'converted':
        reason = 'already_converted';
        break;
      case 'expired':
        reason = 'expired';
        break;
      case 'missing':
        reason = 'not_found';
        break;
    }
    await ReviewItemsService.insertIn(
      manager,
      tenantId,
      {
        kind: 'quote_conflict',
        refId: sale.id,
        details: {
          opId: op.opId,
          saleId: sale.id,
          receiptNo: sale.receiptNo,
          quoteId,
          reason,
          ...(quote.state === 'converted'
            ? { convertedSaleId: quote.convertedSaleId }
            : {}),
          ...(quote.state === 'expired'
            ? { validUntil: quote.validUntil.toISOString() }
            : {}),
        },
      },
      { onConflictDoNothing: true },
    );
  }

  /**
   * Owner 2026-09-25: a replayed bill (or credit note — "receipt" covers both) whose number
   * on the device's paper differs from the number the server stored — it was committed
   * online, the reply was lost, and the till queued it under a fresh offline number
   * (#409/#413). The customer may hold a paper the system does not know, so the owner gets
   * a review item holding both numbers. The #409 fall-through re-runs this on every
   * re-push (its key row keeps the online fingerprint), so the insert is deduplicated by
   * the partial unique index `uq_owner_review_items_renumbered`. A payload number that is
   * not a well-formed RC/CN number is ignored — junk must not raise an item.
   */
  private async flagRenumbered(
    manager: EntityManager,
    tenantId: string,
    op: SyncOpDto,
    id: string,
    rawOfflineNo: unknown,
    serverNo: string,
  ): Promise<void> {
    const offlineNo = wellFormedDocNo(rawOfflineNo);
    if (!offlineNo || offlineNo === serverNo) return;
    await ReviewItemsService.insertIn(
      manager,
      tenantId,
      {
        kind: 'receipt_renumbered',
        refId: id,
        details: { opId: op.opId, type: op.type, id, offlineNo, serverNo },
      },
      { onConflictDoNothing: true },
    );
  }

  /**
   * Follow-up to PR #580 (owner, 2026-10-03). An offline cash-out is accepted even when
   * it was larger than the drawer held — the cash already left — but the owner gets one
   * `drawer_overdrawn_offline` review item for it. The entry was over the limit exactly
   * when the shift's expected cash (the closing report's own rule,
   * `expectedCashSatangOf`) is now below zero. Same request manager, inside the push's
   * transaction; the partial unique index keeps it to one item per entry.
   */
  private async flagOverdrawnOffline(
    manager: EntityManager,
    tenantId: string,
    op: ParsedSyncOp,
    entry: { id: string; shiftId: string; amount: string },
  ): Promise<void> {
    const afterSatang = await expectedCashSatangOf(manager, tenantId, entry.shiftId);
    if (afterSatang >= 0) return;
    await ReviewItemsService.insertIn(
      manager,
      tenantId,
      {
        kind: 'drawer_overdrawn_offline',
        refId: entry.id,
        details: {
          opId: op.opId,
          entryId: entry.id,
          shiftId: entry.shiftId,
          amount: entry.amount,
          expectedCashBefore: fromSatang(afterSatang + satangOf(entry.amount)),
          expectedCashAfter: fromSatang(afterSatang),
        },
      },
      { onConflictDoNothing: true },
    );
  }

  private async computeShiftBalance(
    manager: EntityManager,
    tenantId: string,
    shiftId: string,
  ): Promise<string> {
    const shiftRows = (await manager.query(
      `SELECT starting_cash FROM shifts WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, shiftId],
    )) as { starting_cash: string }[];
    const startingCashSatang = shiftRows[0]
      ? satangOf(shiftRows[0].starting_cash)
      : 0;

    const entryRows = (await manager.query(
      `SELECT type, amount FROM drawer_entries WHERE tenant_id = $1::uuid AND shift_id = $2`,
      [tenantId, shiftId],
    )) as { type: 'in' | 'out'; amount: string }[];

    let balanceSatang = startingCashSatang;
    for (const e of entryRows) {
      const amountSatang = satangOf(e.amount);
      if (e.type === 'in') balanceSatang += amountSatang;
      else balanceSatang -= amountSatang;
    }

    return fromSatang(balanceSatang);
  }

  /** `parsed` is undefined when `parseOpPayload` itself refused the op. */
  private mapOpError(
    op: SyncOpDto,
    parsed: ParsedSyncOp | undefined,
    err: any,
  ): SyncOpResult {
    // #616: an id `parseOpPayload` missed must not read as `retry` (it would come back forever).
    err = invalidUuidInput(err) ?? err;
    if (err instanceof HttpException) {
      const status = err.getStatus();
      if (status >= 500) {
        return { opId: op.opId, status: 'retry' };
      }

      const res = err.getResponse();
      const obj = typeof res === 'object' && res !== null ? (res as any) : {};
      const rawCode = obj.code ?? HttpStatus[status];
      const rawMessage = obj.message ?? err.message;
      const details = obj.details;

      if (rawCode === 'INSUFFICIENT_STOCK') {
        const d = Array.isArray(details) ? details[0] : details;
        return {
          opId: op.opId,
          status: 'rejected',
          code: 'INSUFFICIENT_STOCK',
          message: 'สต็อกไม่พอ',
          details: d
            ? {
                productId: d.productId,
                requested: d.requested,
                available: d.stock ?? d.available,
              }
            : undefined,
        };
      }

      if (
        rawCode === 'CREDIT_PAYMENT_EXCEEDS_BALANCE' ||
        rawCode === 'OVERPAYMENT'
      ) {
        const payment = parsed?.type === 'credit_payment.create' ? parsed : undefined;
        return {
          opId: op.opId,
          status: 'rejected',
          code: 'OVERPAYMENT',
          message: 'ยอดชำระเกินยอดหนี้คงค้าง',
          details: {
            mechanicId: payment?.mechanicId,
            outstandingBalance:
              details?.creditBalance ?? details?.outstandingBalance,
            attemptedAmount:
              details?.amount ??
              details?.attemptedAmount ??
              (payment ? fromSatang(payment.payment.amountSatang) : undefined),
          },
        };
      }

      if (rawCode === 'RETURN_PRICE_MISMATCH') {
        const line = details?.lines?.[0];
        return {
          opId: op.opId,
          status: 'rejected',
          code: 'RETURN_PRICE_MISMATCH',
          message: 'ราคาคืนไม่ตรงกับราคาที่ขายจริง',
          details: line
            ? {
                productId: line.productId,
                expectedPrice: line.soldAt?.[0],
                actualPrice: line.price,
              }
            : details,
        };
      }

      if (rawCode === 'SALE_ID_REUSED' || rawCode === 'CLIENT_ID_REUSED') {
        return {
          opId: op.opId,
          status: 'rejected',
          code: 'CLIENT_ID_REUSED',
          message: 'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ',
          details: {
            type: op.type,
            id: parsed ? clientIdOf(parsed) : replayProbeOf(op)?.id,
          },
        };
      }

      if (rawCode === 'VOID_NEEDS_ONLINE') {
        return {
          opId: op.opId,
          status: 'rejected',
          code: 'VOID_NEEDS_ONLINE',
          message: 'บิลออนไลน์สามารถยกเลิกได้เมื่อเชื่อมต่ออินเทอร์เน็ตเท่านั้น',
          details: {
            saleId: parsed?.type === 'sale.void_offline' ? parsed.saleId : undefined,
          },
        };
      }

      if (rawCode === 'RECEIPT_NO_CONFLICT') {
        const docNumber = parsed ? docNoOf(parsed) : null;
        return {
          opId: op.opId,
          status: 'rejected',
          code: 'RECEIPT_NO_CONFLICT',
          message: 'เลขที่ใบเสร็จซ้ำ กรุณาทำรายการใหม่',
          details: docNumber ? { docNumber } : details,
        };
      }

      return {
        opId: op.opId,
        status: 'rejected',
        code: rawCode,
        message: rawMessage,
        ...(details !== undefined ? { details } : {}),
      };
    }

    this.logger.warn(`Transient or unhandled error for op ${op.opId}: ${err}`);
    return { opId: op.opId, status: 'retry' };
  }

  discardOp(
    actor: { userId: string; tenantId: string; deviceId?: string; ip?: string },
    dto: SyncDiscardDto,
  ): Promise<{ serverHasRow: boolean }> {
    return this.tenants.runTx(() => this.discardOpIn(actor, dto));
  }

  private async discardOpIn(
    actor: { userId: string; tenantId: string; deviceId?: string; ip?: string },
    dto: SyncDiscardDto,
  ): Promise<{ serverHasRow: boolean }> {
    const { tenantId, manager } = currentRequestContext();
    let serverHasRow = false;

      // #488: a void's payload names its bill as `saleId`, not `id` — the same
      // field the push path's client-id replay reads (`replayKeyOfSameDocument`).
      // #616: a non-UUID names no row, so it is not looked up (and the discard still goes
      // through — see `parseSyncDiscard`).
      const isVoid = dto.type === 'sale.void_offline';
      const targetId = targetIdOf(dto);

      if (targetId) {
        if (isVoid) {
          // "The server has this op" = the bill is already voided: exactly
          // when a push of this op would replay as applied
          // (`checkClientIdReplay`, case 'sale.void_offline').
          const rows = await manager.query(
            `SELECT 1 FROM sales WHERE tenant_id = $1::uuid AND id = $2 AND voided`,
            [tenantId, targetId],
          );
          serverHasRow = rows.length > 0;
        } else if (dto.type.startsWith('sale.')) {
          const rows = await manager.query(
            `SELECT 1 FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
            [tenantId, targetId],
          );
          serverHasRow = rows.length > 0;
        } else if (dto.type.startsWith('return.')) {
          const rows = await manager.query(
            `SELECT 1 FROM returns WHERE tenant_id = $1::uuid AND id = $2`,
            [tenantId, targetId],
          );
          serverHasRow = rows.length > 0;
        } else if (dto.type.startsWith('shift.')) {
          const rows = await manager.query(
            `SELECT 1 FROM shifts WHERE tenant_id = $1::uuid AND id = $2`,
            [tenantId, targetId],
          );
          serverHasRow = rows.length > 0;
        } else if (dto.type.startsWith('drawer.')) {
          const rows = await manager.query(
            `SELECT 1 FROM drawer_entries WHERE tenant_id = $1::uuid AND id = $2`,
            [tenantId, targetId],
          );
          serverHasRow = rows.length > 0;
        } else if (dto.type.startsWith('customer.')) {
          const rows = await manager.query(
            `SELECT 1 FROM customers WHERE tenant_id = $1::uuid AND id = $2`,
            [tenantId, targetId],
          );
          serverHasRow = rows.length > 0;
        } else if (dto.type.startsWith('credit_payment.')) {
          const rows = await manager.query(
            `SELECT 1 FROM credit_payments WHERE tenant_id = $1::uuid AND id = $2`,
            [tenantId, targetId],
          );
          serverHasRow = rows.length > 0;
        }
      }

      await this.audit.log(manager, {
        tenantId,
        userId: actor.userId,
        deviceId: actor.deviceId,
        action: 'sync.op.discarded',
        entity: 'sync',
        entityId: dto.opId,
        after: {
          opId: dto.opId,
          type: dto.type,
          clientId: targetId,
          lastCode: dto.lastCode,
          note: dto.note,
          serverHasRow,
        },
        ip: actor.ip,
      });

      return { serverHasRow };
  }
}

/** 08 §10's tolerance around a shift's `opened_at` and the server's `now()`. */
const DATE_TOLERANCE_MS = 5 * 60 * 1000;

interface PeriodFlag {
  docNo: string;
  docPeriod: string;
  datePeriod: string;
}

/** A `date_flag` review item for a device date the push moved or mis-periodised (08 §10). */
async function insertDateFlag(
  manager: EntityManager,
  tenantId: string,
  op: ParsedSyncOp,
  originalDate: Date | null,
  clampedDate: Date | null,
  openedAt: Date | null,
  periodFlag: PeriodFlag | null = null,
): Promise<void> {
  await ReviewItemsService.insertIn(manager, tenantId, {
    kind: 'date_flag',
    refId: clientIdOf(op) || op.opId,
    details: {
      opId: op.opId,
      type: op.type,
      originalDate: originalDate ? originalDate.toISOString() : null,
      clampedDate: clampedDate ? clampedDate.toISOString() : null,
      openedAt: openedAt ? openedAt.toISOString() : null,
      ...periodFlag,
    },
  });
}

/** A trimmed RC/CN number when it matches `DOC_NUMBER_REGEX`, else null. */
function wellFormedDocNo(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const docNo = raw.trim();
  return DOC_NUMBER_REGEX.test(docNo) ? docNo : null;
}

/**
 * The device's own (clamped) date on a replayed write. The online parsers never read
 * one, so a push is the only way a bill or credit note is dated by the till rather than
 * by the server's `now()` (08 §10/§12, #411).
 */
function deviceDated<T>(input: T, clamped: Date | null): T & { date: string | null } {
  return { ...input, date: clamped ? clamped.toISOString() : null };
}

/**
 * The online route an op stands for, built from the payload as sent (B1: before any
 * parsing). `parseUuid` never normalises, so a valid id yields the same route the
 * parsed op would. A malformed or missing id becomes `-`: no stored key can carry that
 * route (the online `ParseUuidPipe` refuses it), and a raw string — one holding a NUL
 * byte, say — never reaches the claim's INSERT, so the parser after the claim is what
 * refuses the op (`rejected INVALID_ID`, never `retry`).
 */
function endpointForOp(op: SyncOpDto): { endpoint: string; successCode: number } {
  switch (op.type as SyncOpType) {
    case 'sale.create':
      return { endpoint: `POST ${ONLINE_PREFIX}/sales`, successCode: 201 };
    case 'return.create':
      return { endpoint: `POST ${ONLINE_PREFIX}/returns`, successCode: 201 };
    case 'shift.open':
      return { endpoint: `POST ${ONLINE_PREFIX}/shifts/open`, successCode: 200 };
    case 'drawer.entry':
      return { endpoint: `POST ${ONLINE_PREFIX}/shifts/current/entries`, successCode: 201 };
    case 'credit_payment.create':
      return {
        endpoint: `POST ${ONLINE_PREFIX}/mechanics/${routeId(op.payload.mechanicId)}/credit-payments`,
        successCode: 201,
      };
    case 'customer.create':
      return { endpoint: `POST ${ONLINE_PREFIX}/customers`, successCode: 201 };
    case 'customer.update':
      return {
        endpoint: `PATCH ${ONLINE_PREFIX}/customers/${routeId(op.payload.id)}`,
        successCode: 200,
      };
    case 'sale.void_offline':
      return {
        endpoint: `POST /sales/${routeId(op.payload.saleId)}/void-offline`,
        successCode: 200,
      };
  }
}

function routeId(value: unknown): string {
  return isUuid(value) ? value : '-';
}

/** For error mapping only: the parsed op, or `undefined` when the parser refuses it. */
function tryParseOpPayload(op: SyncOpDto): ParsedSyncOp | undefined {
  try {
    return parseOpPayload(op);
  } catch {
    return undefined;
  }
}
