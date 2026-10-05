import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { newUuid } from '../common/ids.js';
import { fromSatang, satangOf } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { returning } from '../common/sql.js';
import { DocNumberService } from '../documents/doc-number.service.js';
import { TenantCache } from '../infra/tenant-cache.service.js';
import { ShiftsService } from '../shifts/shifts.service.js';
import type { CreateCreditPayment } from './credit-payments.dto.js';

/** Who took the money — from the token, never from the body (ADR-0004). */
export interface CreditPaymentActor {
  userId: string;
  deviceId: string;
}

/** One settlement as the API hands it back. Money is the wire format, `"1234.50"`. */
export interface CreditPayment {
  id: string;
  receiptNo: string;
  mechanicId: string;
  amount: string;
  paymentMethod: string;
  note: string | null;
  date: string;
  /** Always set on a new payment (no open shift is `409 NO_OPEN_SHIFT`); a replay of an older one may be null. */
  shiftId: string | null;
}

/** `POST /mechanics/:id/credit-payments` — the payment plus the row it moved. */
export interface CreateCreditPaymentResult extends CreditPayment {
  /**
   * The mechanic's tab after the payment. The only other column this transaction
   * touches is `mechanics.updated_at`, so there is no `mechanicAfter` here: #82's
   * rule is that a write returns every row it changes, and returning three running
   * totals it did not move would invite the client to patch them from a stale read.
   */
  mechanicCreditBalanceAfter: string;
}

/**
 * The mechanic-credit-settlement transaction (#24) — the server side of
 * `mechanics_repository.dart` `addCreditPayment`, itself the port of `db.js`.
 *
 * Everything runs inside the request's transaction, in this order:
 *
 *   1. the idempotency claim (the interceptor, before this method is called)
 *   2. `SELECT … FROM mechanics … FOR UPDATE` — the 404 comes off this row
 *   3. a payment already recorded under the client's `id` is answered, not repeated
 *   4. the device's open drawer `FOR SHARE`, for `shift_id` — `409 NO_OPEN_SHIFT`
 *      when there is none (owner's decision, 2026-09-13)
 *   5. the overpayment check, from the locked balance
 *   6. issue the CP number
 *   7. insert the payment
 *   8. reduce the tab, clamped at zero
 *   9. the audit row, when the counter overpaid on purpose
 *
 * **Lock order: mechanic → `doc_counters`**, the same relative order as the rest of
 * the money path (sale → mechanic → products → `doc_counters` → customer). Today the
 * two cannot actually contend with a sale or a credit note beyond the mechanic row —
 * `doc_counters` is keyed by `doc_type`, so a CP number never touches the RC or CN
 * row — and one shared resource cannot deadlock. The order is kept anyway because it
 * costs nothing and stays correct if the series ever share a counter. The shift row in
 * step 4 is taken `FOR SHARE` and sits outside that order on purpose: `POST /sales`
 * takes it before the mechanic, and shared locks cannot deadlock against each other
 * (`ShiftsService.requireOpenShiftIdFor`).
 *
 * 🔴 **The lock is also what makes step 5 mean anything.** Two tills settling the same
 * tab at once would otherwise both read the same balance, both pass the check and both
 * clamp — the shop would have taken twice the debt in cash with nothing recording that
 * the second payment was an overpayment. The Dart reference cannot expose that race:
 * it is single-process, and there the counter is the only authority.
 */
@Injectable()
export class CreditPaymentsService {
  constructor(
    private readonly docNumbers: DocNumberService,
    private readonly shifts: ShiftsService,
    private readonly audit: AuditService,
    private readonly cache: TenantCache,
    private readonly tenants: TenantService,
  ) {}

  create(
    mechanicId: string,
    dto: CreateCreditPayment,
    actor: CreditPaymentActor,
  ): Promise<CreateCreditPaymentResult> {
    return this.tenants.runTx(() => this.createIn(mechanicId, dto, actor));
  }

  private async createIn(
    mechanicId: string,
    dto: CreateCreditPayment,
    actor: CreditPaymentActor,
  ): Promise<CreateCreditPaymentResult> {
    const { tenantId, manager } = currentRequestContext();

    const balanceBefore = await this.lockBalance(manager, tenantId, mechanicId);

    // Before the overpayment check, on purpose: a replayed full settlement would
    // otherwise meet a tab that the first attempt already brought to zero and be
    // refused as an overpayment — a 409 the counter reads as "it did not go through".
    if (dto.id !== null) {
      const existing = await this.existingPayment(
        manager,
        tenantId,
        mechanicId,
        dto,
        balanceBefore,
      );
      if (existing) return existing;
    }

    // No open drawer, no payment — cash or transfer alike (owner's decision,
    // 2026-09-13): a settlement stamped with no shift is money no closing report
    // counts. After the replay, so a payment committed while the drawer was open is
    // still answered once it has closed; before the overpayment check and the CP
    // number, so a refusal leaves no hole in the series. Stamped from the device's own
    // drawer, never from the body (#28).
    const shiftId = await this.shifts.requireOpenShiftIdFor(
      manager,
      tenantId,
      actor.deviceId,
    );

    const overpaid = dto.amountSatang > balanceBefore;
    if (overpaid && !dto.allowOverpayment) {
      // 🔴 Validate first, then clamp. `GREATEST(0, …)` below is what keeps the tab
      // off negative, but a clamp applied to an amount nobody checked turns a typo —
      // 100,000 keyed for 1,000 — into a wiped debt and a receipt for cash that was
      // never handed over, with nothing in the data saying which of the two happened.
      // The counter's own dialog is the real check (`mechanics_screen.dart:1331`);
      // this is how that decision is *carried*, because consent is never inferred (#56).
      throw new HttpException(
        {
          code: 'CREDIT_PAYMENT_EXCEEDS_BALANCE',
          message:
            'Payment is more than the outstanding balance; resend with allowOverpayment to confirm.',
          details: {
            creditBalance: fromSatang(balanceBefore),
            amount: fromSatang(dto.amountSatang),
            overpayBy: fromSatang(dto.amountSatang - balanceBefore),
          },
        },
        HttpStatus.CONFLICT,
      );
    }

    const receiptNo = await this.docNumbers.issue(manager, {
      tenantId,
      deviceId: actor.deviceId,
      docType: 'cp',
    });

    const id = dto.id ?? newUuid();
    const inserted = (await manager.query(
      `INSERT INTO credit_payments
              (tenant_id, id, receipt_no, mechanic_id, amount, payment_method, note, shift_id)
            VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8)
         RETURNING amount, date`,
      [
        tenantId,
        id,
        receiptNo,
        mechanicId,
        fromSatang(dto.amountSatang),
        dto.paymentMethod,
        dto.note,
        shiftId,
      ],
    )) as { amount: string; date: Date }[];

    const balanceAfter = await this.reduceBalance(
      manager,
      tenantId,
      mechanicId,
      dto.amountSatang,
    );
    // #32: the tab moved — `GET /mechanics` is stale once this commits.
    this.cache.invalidateAfterCommit(tenantId, 'mechanics');

    if (overpaid) {
      // §8.2: who took more than the tab, and how much more. On the request
      // transaction on purpose — an override recorded for a payment that rolled back
      // would be a lie.
      await this.audit.log(manager, {
        tenantId,
        userId: actor.userId,
        deviceId: actor.deviceId,
        action: 'mechanic.credit_payment_overpayment',
        entity: 'mechanic',
        entityId: mechanicId,
        after: {
          creditPaymentId: id,
          receiptNo,
          amount: fromSatang(dto.amountSatang),
          creditBalanceBefore: fromSatang(balanceBefore),
          creditBalanceAfter: balanceAfter,
        },
      });
    }

    return {
      id,
      receiptNo,
      mechanicId,
      amount: inserted[0].amount,
      paymentMethod: dto.paymentMethod,
      note: dto.note,
      date: inserted[0].date.toISOString(),
      shiftId,
      mechanicCreditBalanceAfter: balanceAfter,
    };
  }

  /**
   * The payment already stored under the client's `id`, answered as the original
   * was — or null when there is none.
   *
   * Runs under the mechanic's lock, so two replays of one payment serialise on it.
   * The balance answered is the tab as it stands now, which is the one honest figure:
   * the original reply's number may already have been moved by a later sale.
   *
   * An id that names a different payment (another mechanic, amount or method) is
   * `409 CREDIT_PAYMENT_ID_REUSED`: a UUIDv7 makes that a client bug, and answering
   * with the old payment would lose the new one's money.
   */
  private async existingPayment(
    manager: EntityManager,
    tenantId: string,
    mechanicId: string,
    dto: CreateCreditPayment,
    balanceSatang: number,
  ): Promise<CreateCreditPaymentResult | null> {
    const rows = (await manager.query(
      `SELECT receipt_no, mechanic_id, amount, payment_method, note, date, shift_id
         FROM credit_payments WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, dto.id],
    )) as {
      receipt_no: string;
      mechanic_id: string;
      amount: string;
      payment_method: string | null;
      note: string | null;
      date: Date;
      shift_id: string | null;
    }[];
    if (rows.length === 0) return null;
    const row = rows[0];
    if (
      row.mechanic_id !== mechanicId ||
      satangOf(row.amount) !== dto.amountSatang ||
      row.payment_method !== dto.paymentMethod
    ) {
      throw new HttpException(
        {
          code: 'CREDIT_PAYMENT_ID_REUSED',
          message: 'A different credit payment already exists under this id.',
        },
        HttpStatus.CONFLICT,
      );
    }
    return {
      id: dto.id!,
      receiptNo: row.receipt_no,
      mechanicId,
      amount: row.amount,
      paymentMethod: dto.paymentMethod,
      note: row.note,
      date: row.date.toISOString(),
      shiftId: row.shift_id,
      mechanicCreditBalanceAfter: fromSatang(balanceSatang),
    };
  }

  /**
   * The mechanic's tab, locked for the rest of the transaction.
   *
   * `deleted_at` is not filtered, exactly as `POST /sales` does not filter it: a
   * mechanic can be taken off the list while still owing money, and refusing the cash
   * he came in to pay would lose the shop both the money and the record of it. The 404
   * is for a mechanic that never existed — without it the insert's foreign key raises
   * a `23503` several statements later and surfaces as a 500.
   */
  private async lockBalance(
    manager: EntityManager,
    tenantId: string,
    mechanicId: string,
  ): Promise<number> {
    const rows = (await manager.query(
      `SELECT credit_balance FROM mechanics
        WHERE tenant_id = $1::uuid AND id = $2 FOR UPDATE`,
      [tenantId, mechanicId],
    )) as { credit_balance: string }[];
    if (rows.length === 0) {
      throw new HttpException(
        { code: 'MECHANIC_NOT_FOUND', message: 'Mechanic not found' },
        HttpStatus.NOT_FOUND,
      );
    }
    return satangOf(rows[0].credit_balance);
  }

  /**
   * `credit_balance = max(0, balance - amount)` — `addCreditPayment`'s rule, and the
   * clamp the ticket asks for. The row has been locked since `lockBalance`, so the
   * balance this subtracts from is the one the overpayment check read.
   */
  private async reduceBalance(
    manager: EntityManager,
    tenantId: string,
    mechanicId: string,
    amountSatang: number,
  ): Promise<string> {
    const rows = returning<{ credit_balance: string }>(
      await manager.query(
        `UPDATE mechanics
            SET credit_balance = GREATEST(0, credit_balance - $3),
                updated_at = now()
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING credit_balance`,
        [tenantId, mechanicId, fromSatang(amountSatang)],
      ),
    );
    if (rows.length === 0) {
      // `lockBalance` holds this row; it cannot vanish underneath us.
      throw new Error(`Mechanic ${mechanicId} vanished mid-transaction.`);
    }
    return rows[0].credit_balance;
  }
}
