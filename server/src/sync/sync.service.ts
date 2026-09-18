import {
  ConflictException,
  HttpException,
  HttpStatus,
  Injectable,
  Logger,
} from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { TenantService } from '../common/database/tenant.service.js';
import { fromSatang, satangOf, toSatang } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { CustomersService } from '../customers/customers.service.js';
import { parseCustomerPatch } from '../people/people.dto.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { CreditPaymentsService } from '../mechanics/credit-payments.service.js';
import { ReviewItemsService } from '../review-items/review-items.service.js';
import { ReturnsService } from '../returns/returns.service.js';
import { parseCreateReturn } from '../returns/returns.dto.js';
import { SalesService } from '../sales/sales.service.js';
import { parseCreateSale } from '../sales/sales.dto.js';
import { VoidService } from '../sales/void.service.js';
import { ShiftsService } from '../shifts/shifts.service.js';
import {
  type SyncOpDto,
  type SyncOpResult,
  type SyncPushDto,
  type SyncPushResponse,
} from './sync.dto.js';

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
        const mapped = this.mapOpError(op, err);
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
    op: SyncOpDto,
  ): Promise<SyncOpResult> {
    return this.tenants.runTx(() => this.processSingleOpIn(actor, device, op));
  }

  private async processSingleOpIn(
    actor: PushActor,
    device: PushDevice,
    op: SyncOpDto,
  ): Promise<SyncOpResult> {
    const { tenantId, manager } = currentRequestContext();
    const ep = this.endpointForOp(op);
    const requestHash = IdempotencyService.requestHash(op.payload);

    // Step 1: Idempotency claim & replay check (08 §8.3 step 1)
    const claim = await this.idempotency.claim(manager, {
      tenantId,
      key: op.idempotencyKey,
      endpoint: ep.endpoint,
      requestHash,
    });

    if (claim.outcome === 'replay') {
      return {
        opId: op.opId,
        status: 'applied',
        response: claim.response.body,
      };
    }

    if (claim.outcome === 'reused') {
      throw new ConflictException({
        code: 'IDEMPOTENCY_KEY_REUSED',
        message: 'Idempotency-Key already used for a different request',
      });
    }

    // Step 2: Client ID replay check (08 §8.3 step 2, §6.1)
    const clientReplay = await this.checkClientIdReplay(manager, tenantId, op);
    if (clientReplay !== null) {
      // Complete idempotency claim with the existing response
      await this.idempotency.complete(manager, {
        tenantId,
        key: op.idempotencyKey,
        response: { code: ep.successCode, body: clientReplay },
      });
      return {
        opId: op.opId,
        status: 'applied',
        response: clientReplay,
      };
    }

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

  private endpointForOp(op: SyncOpDto): { endpoint: string; successCode: number } {
    switch (op.type) {
      case 'sale.create':
        return { endpoint: 'POST /sales', successCode: 201 };
      case 'return.create':
        return { endpoint: 'POST /returns', successCode: 201 };
      case 'shift.open':
        return { endpoint: 'POST /shifts/open', successCode: 201 };
      case 'drawer.entry':
        return { endpoint: 'POST /shifts/current/entries', successCode: 201 };
      case 'credit_payment.create':
        return {
          endpoint: `POST /mechanics/${op.payload.mechanicId}/credit-payments`,
          successCode: 201,
        };
      case 'customer.create':
        return { endpoint: 'POST /customers', successCode: 201 };
      case 'customer.update':
        return {
          endpoint: `PATCH /customers/${op.payload.id}`,
          successCode: 200,
        };
      case 'sale.void_offline':
        return {
          endpoint: `POST /sales/${op.payload.saleId}/void-offline`,
          successCode: 200,
        };
      default:
        return { endpoint: `POST /sync/${op.type}`, successCode: 200 };
    }
  }

  private async checkClientIdReplay(
    manager: EntityManager,
    tenantId: string,
    op: SyncOpDto,
  ): Promise<any | null> {
    switch (op.type) {
      case 'shift.open': {
        if (!op.payload.id) return null;
        const rows = (await manager.query(
          `SELECT id, starting_cash, opened_at, auto_archived FROM shifts WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, String(op.payload.id).trim()],
        )) as {
          id: string;
          starting_cash: string;
          opened_at: Date;
          auto_archived: boolean;
        }[];
        if (rows.length === 0) return null;
        const row = rows[0];
        if (satangOf(row.starting_cash) !== toSatang(op.payload.startingCash, 'startingCash')) {
          throw this.clientIdReused(op.type, op.payload.id);
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
        if (!op.payload.id) return null;
        const rows = (await manager.query(
          `SELECT id, receipt_no, total, points_granted, voided, shift_id FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, String(op.payload.id).trim()],
        )) as {
          id: string;
          receipt_no: string;
          total: string;
          points_granted: number;
          voided: boolean;
          shift_id: string | null;
        }[];
        if (rows.length === 0) return null;
        const row = rows[0];
        if (satangOf(row.total) !== toSatang(op.payload.total, 'total')) {
          throw this.clientIdReused(op.type, op.payload.id);
        }

        const items = Array.isArray(op.payload.items) ? op.payload.items : [];
        const productIds = items.map((it: any) => it.productId).filter(Boolean);
        const products =
          productIds.length > 0
            ? ((await manager.query(
                `SELECT id, stock FROM products WHERE tenant_id = $1::uuid AND id = ANY($2::text[])`,
                [tenantId, productIds],
              )) as { id: string; stock: number }[])
            : [];

        return {
          id: row.id,
          receiptNo: row.receipt_no,
          total: fromSatang(satangOf(row.total)),
          pointsGranted: row.points_granted,
          products,
        };
      }

      case 'return.create': {
        if (!op.payload.id) return null;
        const rows = (await manager.query(
          `SELECT id, cn_no, sale_id, refund_total, refund_method FROM returns WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, String(op.payload.id).trim()],
        )) as {
          id: string;
          cn_no: string;
          sale_id: string;
          refund_total: string;
          refund_method: string;
        }[];
        if (rows.length === 0) return null;
        const row = rows[0];
        if (row.sale_id !== op.payload.saleId) {
          throw this.clientIdReused(op.type, op.payload.id);
        }

        // Compare items
        const lineRows = (await manager.query(
          `SELECT product_id, qty, price FROM return_items WHERE tenant_id = $1::uuid AND return_id = $2 ORDER BY line_no ASC`,
          [tenantId, row.id],
        )) as { product_id: string; qty: number; price: string }[];
        const opItems = Array.isArray(op.payload.items) ? op.payload.items : [];
        if (lineRows.length !== opItems.length) {
          throw this.clientIdReused(op.type, op.payload.id);
        }
        for (let i = 0; i < lineRows.length; i++) {
          const lr = lineRows[i];
          const oi = opItems[i];
          if (
            lr.product_id !== oi.productId ||
            lr.qty !== oi.qty ||
            satangOf(lr.price) !== toSatang(oi.price, 'price')
          ) {
            throw this.clientIdReused(op.type, op.payload.id);
          }
        }

        const productIds = lineRows.map((it) => it.product_id);
        const products =
          productIds.length > 0
            ? ((await manager.query(
                `SELECT id, stock FROM products WHERE tenant_id = $1::uuid AND id = ANY($2::text[])`,
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
        if (!op.payload.id) return null;
        const rows = (await manager.query(
          `SELECT id, type, amount, note, shift_id FROM drawer_entries WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, String(op.payload.id).trim()],
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
          row.type !== op.payload.type ||
          satangOf(row.amount) !== toSatang(op.payload.amount, 'amount')
        ) {
          throw this.clientIdReused(op.type, op.payload.id);
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
        if (!op.payload.id) return null;
        const rows = (await manager.query(
          `SELECT id, mechanic_id, amount, payment_method FROM credit_payments WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, String(op.payload.id).trim()],
        )) as {
          id: string;
          mechanic_id: string;
          amount: string;
          payment_method: string;
        }[];
        if (rows.length === 0) return null;
        const row = rows[0];
        if (
          row.mechanic_id !== op.payload.mechanicId ||
          satangOf(row.amount) !== toSatang(op.payload.amount, 'amount') ||
          row.payment_method !== op.payload.paymentMethod
        ) {
          throw this.clientIdReused(op.type, op.payload.id);
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
        if (!op.payload.id) return null;
        const rows = (await manager.query(
          `SELECT id, name, phone, address, total_spend, points FROM customers WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL`,
          [tenantId, String(op.payload.id).trim()],
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
        const saleId = op.payload.saleId;
        if (!saleId) return null;
        const rows = (await manager.query(
          `SELECT id, voided, void_reason, sold_offline FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
          [tenantId, String(saleId).trim()],
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
                  `SELECT id AS "productId", stock FROM products WHERE tenant_id = $1::uuid AND id = ANY($2::text[])`,
                  [tenantId, productIds],
                )) as { productId: string; stock: number }[])
              : [];
          return {
            saleId: rows[0].id,
            status: 'voided',
            voidReason: rows[0].void_reason ?? op.payload.reason ?? '',
            stockRestored: products,
          };
        }
        return null;
      }

      default:
        return null;
    }
  }

  private async executeOp(
    manager: EntityManager,
    tenantId: string,
    actor: PushActor,
    device: PushDevice,
    op: SyncOpDto,
  ): Promise<any> {
    switch (op.type) {
      case 'shift.open': {
        const previousActive = (await manager.query(
          `SELECT id FROM shifts WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active LIMIT 1`,
          [tenantId, device.id],
        )) as { id: string }[];

        const opened = await this.shifts.open(
          { userId: actor.userId, deviceId: device.id },
          {
            id: op.payload.id,
            startingCashSatang: toSatang(op.payload.startingCash, 'startingCash'),
            openedAt: op.payload.openedAt ? new Date(op.payload.openedAt) : undefined,
          },
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

        const saleInput = parseCreateSale({
          ...op.payload,
          soldOffline: true,
          date: clampedDate ? clampedDate.toISOString() : undefined,
        });

        const created = await this.sales.create(saleInput, {
          userId: actor.userId,
          deviceId: device.id,
        });

        return {
          id: created.id,
          receiptNo: created.receiptNo,
          total: created.total,
          pointsGranted: created.pointsGranted,
          products: created.products,
        };
      }

      case 'return.create': {
        const clampedDate = await this.clampOpDate(
          manager,
          tenantId,
          device.id,
          op,
        );

        const returnInput = parseCreateReturn({
          ...op.payload,
          date: clampedDate ? clampedDate.toISOString() : undefined,
        });

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
          {
            id: op.payload.id,
            type: op.payload.type,
            amountSatang: toSatang(op.payload.amount, 'amount'),
            note: op.payload.note ?? null,
            createdAt: clampedDate,
          },
        );

        const balanceAfter = await this.computeShiftBalance(
          manager,
          tenantId,
          entry.shiftId,
        );

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
          op.payload.mechanicId,
          {
            id: op.payload.id,
            amountSatang: toSatang(op.payload.amount, 'amount'),
            paymentMethod: op.payload.paymentMethod,
            note: op.payload.note ?? null,
            allowOverpayment: false,
          },
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
        const created = await this.customers.create({
          id: op.payload.id,
          name: op.payload.name,
          nameTH: op.payload.nameTH ?? op.payload.name,
          phone: op.payload.phone ?? null,
          address: op.payload.address ?? null,
        });

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
        const patch = parseCustomerPatch(op.payload);
        const updated = await this.customers.update(op.payload.id, patch);

        return {
          id: updated.id,
          phone: updated.phone,
        };
      }

      case 'sale.void_offline': {
        const saleId = String(op.payload.saleId).trim();
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

        const voidReason = op.payload.reason ?? '';
        await this.voids.void(saleId, {
          userId: actor.userId,
          role: 'owner',
          deviceId: device.id,
          reason: voidReason,
        });

        await manager.query(
          `UPDATE sales SET void_reason = $1 WHERE tenant_id = $2::uuid AND id = $3`,
          [voidReason, tenantId, saleId],
        );

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
                `SELECT id AS "productId", stock FROM products WHERE tenant_id = $1::uuid AND id = ANY($2::text[])`,
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

      default:
        throw new HttpException(
          { code: 'UNKNOWN_OP_TYPE', message: `Unknown operation type ${op.type}` },
          HttpStatus.BAD_REQUEST,
        );
    }
  }

  private async clampOpDate(
    manager: EntityManager,
    tenantId: string,
    deviceId: string,
    op: SyncOpDto,
  ): Promise<Date | null> {
    const rawDateStr = op.payload.date || op.payload.createdAt;
    if (!rawDateStr) return null;

    const opDate = new Date(rawDateStr);
    if (isNaN(opDate.getTime())) return null;

    const shiftRows = (await manager.query(
      `SELECT opened_at FROM shifts WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active ORDER BY opened_at DESC LIMIT 1`,
      [tenantId, deviceId],
    )) as { opened_at: Date }[];

    if (shiftRows.length === 0) return opDate;

    const openedAt = new Date(shiftRows[0].opened_at);
    const now = new Date();
    const minWindow = new Date(openedAt.getTime() - 5 * 60 * 1000);
    const maxWindow = new Date(now.getTime() + 5 * 60 * 1000);

    if (opDate >= minWindow && opDate <= maxWindow) {
      return opDate;
    }

    const clampedDate = opDate < openedAt ? openedAt : now;

    await ReviewItemsService.insertIn(manager, tenantId, {
      kind: 'date_flag',
      refId: op.payload.id || op.opId,
      details: {
        opId: op.opId,
        type: op.type,
        originalDate: opDate.toISOString(),
        clampedDate: clampedDate.toISOString(),
        openedAt: openedAt.toISOString(),
      },
    });

    return clampedDate;
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

  private clientIdReused(type: string, id: string): HttpException {
    return new HttpException(
      {
        code: 'CLIENT_ID_REUSED',
        message: 'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ',
        details: { type, id },
      },
      HttpStatus.CONFLICT,
    );
  }

  private mapOpError(op: SyncOpDto, err: any): SyncOpResult {
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
        return {
          opId: op.opId,
          status: 'rejected',
          code: 'OVERPAYMENT',
          message: 'ยอดชำระเกินยอดหนี้คงค้าง',
          details: {
            mechanicId: op.payload.mechanicId,
            outstandingBalance:
              details?.creditBalance ?? details?.outstandingBalance,
            attemptedAmount:
              details?.amount ?? details?.attemptedAmount ?? op.payload.amount,
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
            id: op.payload.id,
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
            saleId: op.payload.saleId,
          },
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
}
