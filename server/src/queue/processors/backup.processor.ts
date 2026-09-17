import { Inject, Injectable } from '@nestjs/common';
import { Processor, WorkerHost } from '@nestjs/bullmq';
import type { Job } from 'bullmq';
import type { Logger } from 'pino';
import { EntityManager } from 'typeorm';
import { LOGGER } from '../../infra/logger.provider.js';
import { AuditService } from '../../audit/audit.service.js';
import {
  JOB_TENANT_EXPORT,
  QUEUE_BACKUP,
  type TenantExportJobPayload,
} from '../queue.constants.js';
import { TenantJobRunner } from '../tenant-job-runner.js';

function iso(d: Date | string | null | undefined): string | null {
  if (!d) return null;
  const date = d instanceof Date ? d : new Date(d);
  return isNaN(date.getTime()) ? null : date.toISOString();
}

function round2(v: unknown): number {
  const num = typeof v === 'number' ? v : parseFloat(String(v ?? '0'));
  return isNaN(num) ? 0 : Math.round(num * 100) / 100;
}

function num(v: unknown, fallback = 0): number {
  if (v == null) return fallback;
  const n = Number(v);
  return isNaN(n) ? fallback : n;
}

export interface ExportSnapshotData {
  sa_products: Array<Record<string, unknown>>;
  sa_customers: Array<Record<string, unknown>>;
  sa_sales: Array<Record<string, unknown>>;
  sa_pos: Array<Record<string, unknown>>;
  sa_settings: Record<string, unknown> | null;
  sa_mechanics: Array<Record<string, unknown>>;
  sa_quotes: Array<Record<string, unknown>>;
  sa_returns: Array<Record<string, unknown>>;
  sa_movements: Array<Record<string, unknown>>;
  sa_suppliers: Array<Record<string, unknown>>;
  sa_categories: string[];
  sa_credit_payments: Array<Record<string, unknown>>;
  sa_cash_drawer: Record<string, unknown> | null;
  sa_shift_history: Array<Record<string, unknown>>;
  sa_parked: Array<Record<string, unknown>>;
  sa_schema_version: string;
  __meta: {
    version: number;
    schemaVersion: number;
    exportedAt: string;
    shopName: string;
    recordCounts: Record<string, number>;
  };
  [key: string]: unknown;
}

@Injectable()
@Processor(QUEUE_BACKUP)
export class BackupProcessor extends WorkerHost {
  constructor(
    private readonly tenantJobRunner: TenantJobRunner,
    private readonly auditService: AuditService,
    @Inject(LOGGER) private readonly logger: Logger,
  ) {
    super();
  }

  async process(job: Job<TenantExportJobPayload>): Promise<unknown> {
    const { name, data } = job;
    this.logger.info(
      { jobId: job.id, jobName: name, tenantId: data.tenantId, correlationId: data.correlationId },
      'Processing backup job',
    );

    if (name !== JOB_TENANT_EXPORT) {
      this.logger.warn({ jobName: name, jobId: job.id }, 'Unknown job name in backup queue');
      return { skipped: true, reason: 'UNKNOWN_JOB' };
    }

    return this.tenantJobRunner.runWithTenantContext(job, async (em: EntityManager) => {
      const tenantId = data.tenantId;

      // The one `pos_app` transaction whose statements scale with a tenant's whole history
      // (every sale, every movement, unpaged), so it is exempt from the role's timeouts and
      // the commit guard (#213) and capped at 5 min instead — it used to be unbounded. Safe
      // for ADR-0010's 30 s cursor rewind only because it writes no row a client pulls: its
      // one write is `audit_log`. `SET LOCAL` ends with this transaction, so the pooled
      // connection goes back with the role's settings. README *The transaction ceiling*.
      await em.query(`SET LOCAL statement_timeout = '5min'`);
      await em.query(`SET LOCAL idle_in_transaction_session_timeout = '5min'`);

      // 1. Settings
      const settingsRows: Array<Record<string, any>> = await em.query(
        `SELECT shop_name, shop_name_en, tax_rate, quote_valid_days, address, phone, cashier_name, tax_id, branch_no, updated_at
           FROM settings
          WHERE tenant_id = $1::uuid
          LIMIT 1`,
        [tenantId],
      );
      const set = settingsRows[0] ?? null;
      const saSettings: Record<string, unknown> | null = set
        ? {
            shopName: set.shop_name,
            shopNameEN: set.shop_name_en,
            taxRate: round2(set.tax_rate),
            quoteValidDays: num(set.quote_valid_days, 30),
            ...(set.address != null ? { address: set.address } : {}),
            ...(set.phone != null ? { phone: set.phone } : {}),
            ...(set.cashier_name != null ? { cashierName: set.cashier_name } : {}),
            ...(set.tax_id != null ? { taxId: set.tax_id } : {}),
            ...(set.branch_no != null ? { branchNo: set.branch_no } : {}),
            ...(set.updated_at != null ? { updatedAt: iso(set.updated_at) } : {}),
          }
        : null;

      // 2. Categories
      const categoryRows: Array<{ name: string; position: number }> = await em.query(
        `SELECT name, position FROM categories WHERE tenant_id = $1::uuid ORDER BY position ASC`,
        [tenantId],
      );
      const saCategories = categoryRows.map((c) => c.name);

      // 3. Products
      const productRows: Array<Record<string, any>> = await em.query(
        `SELECT id, part_no, name, name_th, category, brand, price, cost, stock, min_stock, compat, updated_at
           FROM products
          WHERE tenant_id = $1::uuid
          ORDER BY id ASC`,
        [tenantId],
      );
      const saProducts = productRows.map((p) => ({
        id: p.id,
        partNo: p.part_no,
        name: p.name,
        nameTH: p.name_th,
        category: p.category,
        brand: p.brand,
        price: round2(p.price),
        cost: round2(p.cost),
        stock: num(p.stock),
        minStock: num(p.min_stock),
        ...(p.compat != null ? { compat: p.compat } : {}),
        ...(p.updated_at != null ? { updatedAt: iso(p.updated_at) } : {}),
      }));

      // 4. Customers
      const customerRows: Array<Record<string, any>> = await em.query(
        `SELECT id, code, name, name_th, phone, address, points, total_spend, created_at, updated_at, deleted_at
           FROM customers
          WHERE tenant_id = $1::uuid
          ORDER BY id ASC`,
        [tenantId],
      );
      const saCustomers = customerRows.map((c) => ({
        id: c.id,
        code: c.code,
        name: c.name,
        nameTH: c.name_th,
        ...(c.phone != null ? { phone: c.phone } : {}),
        ...(c.address != null ? { address: c.address } : {}),
        points: num(c.points),
        totalSpend: round2(c.total_spend),
        createdAt: iso(c.created_at) ?? c.created_at,
        ...(c.updated_at != null ? { updatedAt: iso(c.updated_at) } : {}),
        ...(c.deleted_at != null ? { deletedAt: iso(c.deleted_at) } : {}),
      }));

      // 5. Mechanics
      const mechanicRows: Array<Record<string, any>> = await em.query(
        `SELECT id, code, name, name_th, nickname, shop_name, phone, note,
                credit_limit, credit_balance, total_sales, total_credit, total_discount, total_markup,
                created_at, updated_at, deleted_at
           FROM mechanics
          WHERE tenant_id = $1::uuid
          ORDER BY id ASC`,
        [tenantId],
      );
      const saMechanics = mechanicRows.map((m) => ({
        id: m.id,
        code: m.code,
        name: m.name,
        ...(m.name_th != null ? { nameTH: m.name_th } : {}),
        ...(m.nickname != null ? { nickname: m.nickname } : {}),
        ...(m.shop_name != null ? { shopName: m.shop_name } : {}),
        ...(m.phone != null ? { phone: m.phone } : {}),
        ...(m.note != null ? { note: m.note } : {}),
        creditLimit: round2(m.credit_limit),
        creditBalance: round2(m.credit_balance),
        totalSales: round2(m.total_sales),
        totalCredit: round2(m.total_credit),
        totalDiscount: round2(m.total_discount),
        totalMarkup: round2(m.total_markup),
        createdAt: iso(m.created_at) ?? m.created_at,
        ...(m.updated_at != null ? { updatedAt: iso(m.updated_at) } : {}),
        ...(m.deleted_at != null ? { deletedAt: iso(m.deleted_at) } : {}),
      }));

      // 6. Sales & Sale Items
      const saleRows: Array<Record<string, any>> = await em.query(
        `SELECT id, receipt_no, subtotal, discount, total, payment_method,
                customer_id, customer_name, mechanic_id, mechanic_name, mechanic_delta,
                points_granted, date, voided, voided_at
           FROM sales
          WHERE tenant_id = $1::uuid
          ORDER BY date DESC`,
        [tenantId],
      );
      const saleItemRows: Array<Record<string, any>> = await em.query(
        `SELECT sale_id, line_no, product_id, part_no, name, name_th, qty, price, cost_at_sale
           FROM sale_items
          WHERE tenant_id = $1::uuid
          ORDER BY sale_id ASC, line_no ASC`,
        [tenantId],
      );
      const saleItemsBySale = new Map<string, Array<Record<string, any>>>();
      for (const item of saleItemRows) {
        let list = saleItemsBySale.get(item.sale_id);
        if (!list) {
          list = [];
          saleItemsBySale.set(item.sale_id, list);
        }
        list.push(item);
      }
      const saSales = saleRows.map((s) => {
        const items = saleItemsBySale.get(s.id) ?? [];
        return {
          id: s.id,
          receiptNo: s.receipt_no,
          subtotal: round2(s.subtotal),
          discount: round2(s.discount),
          total: round2(s.total),
          paymentMethod: s.payment_method,
          ...(s.customer_id != null ? { customerId: s.customer_id } : {}),
          ...(s.customer_name != null ? { customerName: s.customer_name } : {}),
          ...(s.mechanic_id != null ? { mechanicId: s.mechanic_id } : {}),
          ...(s.mechanic_name != null ? { mechanicName: s.mechanic_name } : {}),
          ...(s.mechanic_delta != null ? { mechanicDelta: round2(s.mechanic_delta) } : {}),
          pointsGranted: num(s.points_granted),
          date: iso(s.date),
          voided: Boolean(s.voided),
          ...(s.voided_at != null ? { voidedAt: iso(s.voided_at) } : {}),
          items: items.map((it) => ({
            productId: it.product_id,
            ...(it.part_no != null ? { partNo: it.part_no } : {}),
            name: it.name,
            ...(it.name_th != null ? { nameTH: it.name_th } : {}),
            qty: num(it.qty),
            price: round2(it.price),
            ...(it.cost_at_sale != null ? { cost: round2(it.cost_at_sale) } : {}),
          })),
        };
      });

      // 7. Returns & Return Items
      const returnRows: Array<Record<string, any>> = await em.query(
        `SELECT id, cn_no, sale_id, receipt_no, refund_subtotal, refund_discount, refund_total,
                refund_method, reason, customer_id, mechanic_id, mechanic_name, date
           FROM returns
          WHERE tenant_id = $1::uuid
          ORDER BY date DESC`,
        [tenantId],
      );
      const returnItemRows: Array<Record<string, any>> = await em.query(
        `SELECT return_id, line_no, product_id, name, qty, price, original_qty
           FROM return_items
          WHERE tenant_id = $1::uuid
          ORDER BY return_id ASC, line_no ASC`,
        [tenantId],
      );
      const returnItemsByReturn = new Map<string, Array<Record<string, any>>>();
      for (const item of returnItemRows) {
        let list = returnItemsByReturn.get(item.return_id);
        if (!list) {
          list = [];
          returnItemsByReturn.set(item.return_id, list);
        }
        list.push(item);
      }
      const saReturns = returnRows.map((r) => {
        const items = returnItemsByReturn.get(r.id) ?? [];
        return {
          id: r.id,
          cnNo: r.cn_no,
          saleId: r.sale_id,
          receiptNo: r.receipt_no,
          refundSubtotal: round2(r.refund_subtotal),
          refundDiscount: round2(r.refund_discount),
          refundTotal: round2(r.refund_total),
          refundMethod: r.refund_method,
          reason: r.reason,
          ...(r.customer_id != null ? { customerId: r.customer_id } : {}),
          ...(r.mechanic_id != null ? { mechanicId: r.mechanic_id } : {}),
          ...(r.mechanic_name != null ? { mechanicName: r.mechanic_name } : {}),
          date: iso(r.date),
          items: items.map((it) => ({
            productId: it.product_id,
            name: it.name,
            qty: num(it.qty),
            price: round2(it.price),
            ...(it.original_qty != null ? { originalQty: num(it.original_qty) } : {}),
          })),
        };
      });

      // 8. Purchase Orders & PO Items
      const poRows: Array<Record<string, any>> = await em.query(
        `SELECT id, po_no, supplier, status, created_at, received_at, cancelled_at
           FROM purchase_orders
          WHERE tenant_id = $1::uuid
          ORDER BY created_at DESC`,
        [tenantId],
      );
      const poItemRows: Array<Record<string, any>> = await em.query(
        `SELECT po_id, line_no, part_no, name, qty, cost
           FROM po_items
          WHERE tenant_id = $1::uuid
          ORDER BY po_id ASC, line_no ASC`,
        [tenantId],
      );
      const poItemsByPo = new Map<string, Array<Record<string, any>>>();
      for (const item of poItemRows) {
        let list = poItemsByPo.get(item.po_id);
        if (!list) {
          list = [];
          poItemsByPo.set(item.po_id, list);
        }
        list.push(item);
      }
      const saPos = poRows.map((po) => {
        const items = poItemsByPo.get(po.id) ?? [];
        return {
          id: po.id,
          poNo: po.po_no,
          supplier: po.supplier,
          status: po.status,
          createdAt: iso(po.created_at),
          ...(po.received_at != null ? { receivedAt: iso(po.received_at) } : {}),
          ...(po.cancelled_at != null ? { cancelledAt: iso(po.cancelled_at) } : {}),
          items: items.map((it) => ({
            partNo: it.part_no,
            name: it.name,
            qty: num(it.qty),
            cost: round2(it.cost),
          })),
        };
      });

      // 9. Quotes & Quote Items
      const quoteRows: Array<Record<string, any>> = await em.query(
        `SELECT id, quote_no, status, date, valid_until, converted_at,
                subtotal, discount, total, customer_name, customer_phone, notes, valid_days
           FROM quotes
          WHERE tenant_id = $1::uuid
          ORDER BY date DESC`,
        [tenantId],
      );
      const quoteItemRows: Array<Record<string, any>> = await em.query(
        `SELECT quote_id, line_no, product_id, name, qty, price
           FROM quote_items
          WHERE tenant_id = $1::uuid
          ORDER BY quote_id ASC, line_no ASC`,
        [tenantId],
      );
      const quoteItemsByQuote = new Map<string, Array<Record<string, any>>>();
      for (const item of quoteItemRows) {
        let list = quoteItemsByQuote.get(item.quote_id);
        if (!list) {
          list = [];
          quoteItemsByQuote.set(item.quote_id, list);
        }
        list.push(item);
      }
      const saQuotes = quoteRows.map((q) => {
        const items = quoteItemsByQuote.get(q.id) ?? [];
        return {
          id: q.id,
          quoteNo: q.quote_no,
          status: q.status,
          date: iso(q.date),
          validUntil: iso(q.valid_until),
          ...(q.converted_at != null ? { convertedAt: iso(q.converted_at) } : {}),
          ...(q.subtotal != null ? { subtotal: round2(q.subtotal) } : {}),
          ...(q.discount != null ? { discount: round2(q.discount) } : {}),
          ...(q.total != null ? { total: round2(q.total) } : {}),
          ...(q.customer_name != null ? { customerName: q.customer_name } : {}),
          ...(q.customer_phone != null ? { customerPhone: q.customer_phone } : {}),
          ...(q.notes != null ? { notes: q.notes } : {}),
          ...(q.valid_days != null ? { validDays: num(q.valid_days) } : {}),
          items: items.map((it) => ({
            ...(it.product_id != null ? { productId: it.product_id } : {}),
            name: it.name,
            qty: num(it.qty),
            price: round2(it.price),
          })),
        };
      });

      // 10. Movements
      const movementRows: Array<Record<string, any>> = await em.query(
        `SELECT id, product_id, part_no, name, delta, type, note, stock_after, date
           FROM movements
          WHERE tenant_id = $1::uuid
          ORDER BY date DESC`,
        [tenantId],
      );
      const saMovements = movementRows.map((m) => ({
        id: m.id,
        productId: m.product_id,
        partNo: m.part_no,
        name: m.name,
        delta: num(m.delta),
        type: m.type,
        ...(m.note != null ? { note: m.note } : {}),
        stockAfter: num(m.stock_after),
        date: iso(m.date),
      }));

      // 11. Suppliers
      const supplierRows: Array<Record<string, any>> = await em.query(
        `SELECT id, product_id, name, unit_cost, freight
           FROM suppliers
          WHERE tenant_id = $1::uuid
          ORDER BY id ASC`,
        [tenantId],
      );
      const saSuppliers = supplierRows.map((s) => ({
        id: s.id,
        productId: s.product_id,
        name: s.name,
        unitCost: round2(s.unit_cost),
        freight: round2(s.freight),
      }));

      // 12. Credit Payments
      const cpRows: Array<Record<string, any>> = await em.query(
        `SELECT id, receipt_no, mechanic_id, amount, date, note
           FROM credit_payments
          WHERE tenant_id = $1::uuid
          ORDER BY date DESC`,
        [tenantId],
      );
      const saCreditPayments = cpRows.map((cp) => ({
        id: cp.id,
        receiptNo: cp.receipt_no,
        mechanicId: cp.mechanic_id,
        amount: round2(cp.amount),
        date: iso(cp.date),
        ...(cp.note != null ? { note: cp.note } : {}),
      }));

      // 13. Shifts & Drawer Entries
      const shiftRows: Array<Record<string, any>> = await em.query(
        `SELECT id, date_str, starting_cash, opened_at, closed_at, physical_cash, is_active, auto_archived, archived_at
           FROM shifts
          WHERE tenant_id = $1::uuid
          ORDER BY opened_at DESC`,
        [tenantId],
      );
      const entryRows: Array<Record<string, any>> = await em.query(
        `SELECT id, shift_id, type, amount, note, created_at
           FROM drawer_entries
          WHERE tenant_id = $1::uuid
          ORDER BY created_at DESC`,
        [tenantId],
      );
      const entriesByShift = new Map<string, Array<Record<string, any>>>();
      for (const entry of entryRows) {
        let list = entriesByShift.get(entry.shift_id);
        if (!list) {
          list = [];
          entriesByShift.set(entry.shift_id, list);
        }
        list.push(entry);
      }

      const shiftToJson = (s: Record<string, any>) => {
        const entries = entriesByShift.get(s.id) ?? [];
        return {
          id: s.id,
          date: s.date_str,
          startingCash: round2(s.starting_cash),
          openedAt: iso(s.opened_at),
          closedAt: iso(s.closed_at),
          physicalCash: s.physical_cash != null ? round2(s.physical_cash) : null,
          ...(s.auto_archived ? { autoArchived: true } : {}),
          ...(s.archived_at != null ? { archivedAt: iso(s.archived_at) } : {}),
          entries: entries.map((e) => ({
            id: e.id,
            type: e.type,
            amount: round2(e.amount),
            note: e.note ?? '',
            createdAt: iso(e.created_at),
          })),
        };
      };

      let cashDrawer: Record<string, unknown> | null = null;
      const history: Array<Record<string, unknown>> = [];
      for (const s of shiftRows) {
        if (s.is_active && cashDrawer === null) {
          cashDrawer = shiftToJson(s);
        } else {
          history.push(shiftToJson(s));
        }
      }

      // 14. Parked Sales
      const parkedRows: Array<Record<string, any>> = await em.query(
        `SELECT id, parked_at, payload
           FROM parked_sales
          WHERE tenant_id = $1::uuid
          ORDER BY parked_at DESC`,
        [tenantId],
      );
      const saParked = parkedRows.map((p) => {
        let parsed = p.payload;
        if (typeof parsed === 'string') {
          try {
            parsed = JSON.parse(parsed);
          } catch {
            // keep as string
          }
        }
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
          return parsed;
        }
        return {
          id: p.id,
          parkedAt: iso(p.parked_at),
          payload: parsed,
        };
      });

      // 15. Record counts & metadata
      const recordCounts = {
        products: saProducts.length,
        customers: saCustomers.length,
        sales: saSales.length,
        purchaseOrders: saPos.length,
        movements: saMovements.length,
        suppliers: saSuppliers.length,
        mechanics: saMechanics.length,
        quotes: saQuotes.length,
        returns: saReturns.length,
        creditPayments: saCreditPayments.length,
        shiftHistory: history.length,
        parked: saParked.length,
        categories: saCategories.length,
        cashDrawer: cashDrawer !== null ? 1 : 0,
      };

      const exportedAt = new Date().toISOString();
      const shopName = (saSettings?.shopName as string) || 'ศรีสุราษฎร์เจริญยนต์';

      const snapshot: ExportSnapshotData = {
        sa_products: saProducts,
        sa_customers: saCustomers,
        sa_sales: saSales,
        sa_pos: saPos,
        sa_settings: saSettings,
        sa_mechanics: saMechanics,
        sa_quotes: saQuotes,
        sa_returns: saReturns,
        sa_movements: saMovements,
        sa_suppliers: saSuppliers,
        sa_categories: saCategories,
        sa_credit_payments: saCreditPayments,
        sa_cash_drawer: cashDrawer,
        sa_shift_history: history,
        sa_parked: saParked,
        sa_schema_version: '2',
        __meta: {
          version: 2,
          schemaVersion: 2,
          exportedAt,
          shopName,
          recordCounts,
        },
      };

      // 16. Carry-forward unknown stores from tenant_meta if present
      const metaRows: Array<{ key: string; value: string }> = await em.query(
        `SELECT key, value FROM tenant_meta WHERE tenant_id = $1::uuid`,
        [tenantId],
      );
      for (const row of metaRows) {
        if (row.key.startsWith('unknownstore:')) {
          const saKey = row.key.slice('unknownstore:'.length);
          if (saKey && !(saKey in snapshot)) {
            try {
              snapshot[saKey] = JSON.parse(row.value);
            } catch {
              snapshot[saKey] = row.value;
            }
          }
        }
      }

      // 17. AC3: Write audit_log entry
      await this.auditService.log(em, {
        tenantId,
        userId: data.requestedByUserId || undefined,
        action: 'backup.exported',
        entity: 'tenants',
        entityId: tenantId,
        ip: data.ip,
        after: {
          recordCounts,
          exportedAt,
        },
      });

      this.logger.info(
        { tenantId, recordCounts },
        'Tenant data export completed successfully',
      );

      return snapshot;
    }, { exemptFromCommitCeiling: true });
  }
}
