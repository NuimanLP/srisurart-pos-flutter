import {
  BadRequestException,
  ConflictException,
  Inject,
  Injectable,
} from '@nestjs/common';
import { DataSource } from 'typeorm';
import { ADMIN_DATA_SOURCE } from '../infra/db.module.js';
import { AuditService } from './audit.service.js';

export class SnapshotPayload {
  sa_products?: Array<Record<string, unknown>>;
  sa_categories?: Array<Record<string, unknown>>;
  sa_customers?: Array<Record<string, unknown>>;
  sa_mechanics?: Array<Record<string, unknown>>;
  sa_sales?: Array<Record<string, unknown>>;
  sa_returns?: Array<Record<string, unknown>>;
  sa_purchase_orders?: Array<Record<string, unknown>>;
  sa_quotes?: Array<Record<string, unknown>>;
  sa_movements?: Array<Record<string, unknown>>;
  sa_suppliers?: Array<Record<string, unknown>>;
  sa_credit_payments?: Array<Record<string, unknown>>;
  sa_shifts?: Array<Record<string, unknown>>;
  sa_drawer_entries?: Array<Record<string, unknown>>;
  sa_parked_sales?: Array<Record<string, unknown>>;
  sa_settings?: Record<string, unknown>;
  sa_tenant_meta?: Array<Record<string, unknown>>;
  __meta?: Record<string, unknown>;
  [key: string]: unknown;
}


function round2(v: unknown): number {
  const num = typeof v === 'number' ? v : parseFloat(String(v ?? '0'));
  return isNaN(num) ? 0 : Math.round(num * 100) / 100;
}

function parseDate(v: unknown): Date {
  if (!v) return new Date();
  if (v instanceof Date) return v;
  const d = new Date(String(v));
  return isNaN(d.getTime()) ? new Date() : d;
}

@Injectable()
export class TenantImportService {
  constructor(
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
    private readonly auditService: AuditService,
  ) {}

  async importSnapshot(
    tenantId: string,
    snapshot: SnapshotPayload,
    adminId: string,
    ip?: string,
  ) {
    if (!snapshot.__meta) {
      throw new BadRequestException('ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta');
    }

    // 1. Verify tenant already has no transactional rows
    const checkTables = [
      'sales',
      'returns',
      'purchase_orders',
      'credit_payments',
      'quotes',
      'shifts',
    ];

    for (const table of checkTables) {
      const res = await this.adminDs.query(
        `SELECT count(*)::int AS n FROM ${table} WHERE tenant_id = $1`,
        [tenantId],
      );
      if (res[0].n > 0) {
        throw new ConflictException(
          `Tenant already has transaction data in table '${table}' — import rejected`,
        );
      }
    }

    // 2. Pre-flight scan
    const products = snapshot.sa_products || [];
    for (const p of products) {
      const stock = Number(p.stock ?? 0);
      if (stock < 0) {
        throw new BadRequestException(
          `Pre-flight failed: product '${p.name || p.id}' has negative stock (${stock})`,
        );
      }
    }

    // 3. Single-transaction import
    await this.adminDs.transaction(async (manager) => {
      // 3.1 Categories
      const categories = snapshot.sa_categories || [];
      for (let i = 0; i < categories.length; i++) {
        const cat = categories[i];
        const name = String(cat.name || `Cat-${i}`);
        const pos = Number(cat.position ?? i);
        await manager.query(
          `INSERT INTO categories (tenant_id, name, position)
           VALUES ($1, $2, $3)
           ON CONFLICT (tenant_id, name) DO UPDATE SET position = EXCLUDED.position`,
          [tenantId, name, pos],
        );
      }

      // 3.2 Products
      for (const p of products) {
        const id = String(p.id);
        const partNo = String(p.partNo || p.part_no || id);
        const name = String(p.name || '');
        const nameTh = String(p.nameTH || p.name_th || name);
        const category = String(p.category || p.zone || 'ทั่วไป');
        const brand = String(p.brand || 'ทั่วไป');
        const price = round2(p.price);
        const cost = round2(p.cost);
        const stock = Math.max(0, Math.floor(Number(p.stock ?? 0)));
        const minStock = Math.max(0, Math.floor(Number(p.minStock ?? p.min_stock ?? 0)));
        const compat = p.compat ? String(p.compat) : null;
        const updatedAt = parseDate(p.updatedAt || p.updated_at);

        await manager.query(
          `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock, min_stock, compat, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [
            tenantId,
            id,
            partNo,
            name,
            nameTh,
            category,
            brand,
            price,
            cost,
            stock,
            minStock,
            compat,
            updatedAt,
          ],
        );
      }

      // 3.3 Suppliers
      const suppliers = snapshot.sa_suppliers || [];
      for (const sup of suppliers) {
        const id = String(sup.id);
        const productId = String(sup.productId || sup.product_id);
        const name = String(sup.name || '');
        const unitCost = round2(sup.unitCost || sup.unit_cost);
        const freight = round2(sup.freight);
        await manager.query(
          `INSERT INTO suppliers (tenant_id, id, product_id, name, unit_cost, freight)
           VALUES ($1, $2, $3, $4, $5, $6)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, productId, name, unitCost, freight],
        );
      }

      // 3.4 Customers
      const customers = snapshot.sa_customers || [];
      for (const c of customers) {
        const id = String(c.id);
        const code = String(c.code || `CUS-${id}`);
        const name = String(c.name || '');
        const nameTh = String(c.nameTH || c.name_th || name);
        const phone = c.phone ? String(c.phone) : null;
        const address = c.address ? String(c.address) : null;
        const points = Math.max(0, Math.floor(Number(c.points ?? 0)));
        const totalSpend = round2(c.totalSpend || c.total_spend);
        const createdAt = parseDate(c.createdAt || c.created_at);

        await manager.query(
          `INSERT INTO customers (tenant_id, id, code, name, name_th, phone, address, points, total_spend, created_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, code, name, nameTh, phone, address, points, totalSpend, createdAt],
        );
      }

      // 3.5 Mechanics
      const mechanics = snapshot.sa_mechanics || [];
      for (const m of mechanics) {
        const id = String(m.id);
        const code = String(m.code || `M-${id}`);
        const name = String(m.name || '');
        const nameTh = m.nameTH || m.name_th ? String(m.nameTH || m.name_th) : null;
        const nickname = m.nickname ? String(m.nickname) : null;
        const shopName = m.shopName || m.shop_name ? String(m.shopName || m.shop_name) : null;
        const phone = m.phone ? String(m.phone) : null;
        const note = m.note ? String(m.note) : null;
        const creditLimit = round2(m.creditLimit || m.credit_limit);
        const creditBalance = Math.max(0, round2(m.creditBalance || m.credit_balance));
        const totalSales = round2(m.totalSales || m.total_sales);
        const totalCredit = round2(m.totalCredit || m.total_credit);
        const totalDiscount = round2(m.totalDiscount || m.total_discount);
        const totalMarkup = round2(m.totalMarkup || m.total_markup);
        const createdAt = parseDate(m.createdAt || m.created_at);

        await manager.query(
          `INSERT INTO mechanics (tenant_id, id, code, name, name_th, nickname, shop_name, phone, note, credit_limit, credit_balance, total_sales, total_credit, total_discount, total_markup, created_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [
            tenantId, id, code, name, nameTh, nickname, shopName, phone, note,
            creditLimit, creditBalance, totalSales, totalCredit, totalDiscount, totalMarkup, createdAt,
          ],
        );
      }

      // 3.6 Sales & SaleItems
      const sales = snapshot.sa_sales || [];
      for (const s of sales) {
        const id = String(s.id);
        const receiptNo = String(s.receiptNo || s.receipt_no || `RC-${id}`);
        const subtotal = round2(s.subtotal);
        const discount = round2(s.discount);
        const total = round2(s.total);
        const paymentMethod = String(s.paymentMethod || s.payment_method || 'เงินสด');
        const customerId = s.customerId || s.customer_id ? String(s.customerId || s.customer_id) : null;
        const customerName = s.customerName || s.customer_name ? String(s.customerName || s.customer_name) : null;
        const mechanicId = s.mechanicId || s.mechanic_id ? String(s.mechanicId || s.mechanic_id) : null;
        const mechanicName = s.mechanicName || s.mechanic_name ? String(s.mechanicName || s.mechanic_name) : null;
        const mechanicDelta = s.mechanicDelta != null ? round2(s.mechanicDelta) : null;
        const pointsGranted = Math.max(0, Math.floor(Number(s.pointsGranted ?? s.points_granted ?? 0)));
        const date = parseDate(s.date);
        const voided = Boolean(s.voided);
        const voidedAt = s.voidedAt ? parseDate(s.voidedAt) : null;

        await manager.query(
          `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, customer_id, customer_name, mechanic_id, mechanic_name, mechanic_delta, points_granted, date, voided, voided_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [
            tenantId, id, receiptNo, subtotal, discount, total, paymentMethod,
            customerId, customerName, mechanicId, mechanicName, mechanicDelta,
            pointsGranted, date, voided, voidedAt,
          ],
        );

        const items = (s.items as Array<Record<string, unknown>>) || [];
        for (let i = 0; i < items.length; i++) {
          const item = items[i];
          const lineNo = i + 1;
          const productId = String(item.productId || item.product_id || `p_${i}`);
          const partNo = item.partNo || item.part_no ? String(item.partNo || item.part_no) : null;
          const name = String(item.name || '');
          const nameTh = item.nameTH || item.name_th ? String(item.nameTH || item.name_th) : null;
          const qty = Math.max(1, Math.floor(Number(item.qty ?? 1)));
          const price = round2(item.price);
          const costAtSale = item.costAtSale != null ? round2(item.costAtSale) : null;

          await manager.query(
            `INSERT INTO sale_items (tenant_id, sale_id, line_no, product_id, part_no, name, name_th, qty, price, cost_at_sale)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
             ON CONFLICT (tenant_id, sale_id, line_no) DO NOTHING`,
            [tenantId, id, lineNo, productId, partNo, name, nameTh, qty, price, costAtSale],
          );
        }
      }

      // 3.7 Returns & ReturnItems
      const returns = snapshot.sa_returns || [];
      for (const r of returns) {
        const id = String(r.id);
        const cnNo = String(r.cnNo || r.cn_no || `CN-${id}`);
        const saleId = String(r.saleId || r.sale_id);
        const receiptNo = String(r.receiptNo || r.receipt_no || '');
        const refundSubtotal = round2(r.refundSubtotal || r.refund_subtotal);
        const refundDiscount = round2(r.refundDiscount || r.refund_discount);
        const refundTotal = round2(r.refundTotal || r.refund_total);
        const refundMethod = String(r.refundMethod || r.refund_method || 'เงินสด');
        const reason = String(r.reason || '');
        const customerId = r.customerId || r.customer_id ? String(r.customerId || r.customer_id) : null;
        const mechanicId = r.mechanicId || r.mechanic_id ? String(r.mechanicId || r.mechanic_id) : null;
        const mechanicName = r.mechanicName || r.mechanic_name ? String(r.mechanicName || r.mechanic_name) : null;
        const date = parseDate(r.date);

        await manager.query(
          `INSERT INTO returns (tenant_id, id, cn_no, sale_id, receipt_no, refund_subtotal, refund_discount, refund_total, refund_method, reason, customer_id, mechanic_id, mechanic_name, date)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [
            tenantId, id, cnNo, saleId, receiptNo, refundSubtotal, refundDiscount,
            refundTotal, refundMethod, reason, customerId, mechanicId, mechanicName, date,
          ],
        );

        const items = (r.items as Array<Record<string, unknown>>) || [];
        for (let i = 0; i < items.length; i++) {
          const item = items[i];
          const lineNo = i + 1;
          const productId = String(item.productId || item.product_id);
          const name = String(item.name || '');
          const qty = Math.max(1, Math.floor(Number(item.qty ?? 1)));
          const price = round2(item.price);
          const originalQty = item.originalQty != null ? Number(item.originalQty) : null;

          await manager.query(
            `INSERT INTO return_items (tenant_id, return_id, line_no, product_id, name, qty, price, original_qty)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
             ON CONFLICT (tenant_id, return_id, line_no) DO NOTHING`,
            [tenantId, id, lineNo, productId, name, qty, price, originalQty],
          );
        }
      }

      // 3.8 CreditPayments
      const creditPayments = snapshot.sa_credit_payments || [];
      for (const cp of creditPayments) {
        const id = String(cp.id);
        const receiptNo = String(cp.receiptNo || cp.receipt_no || `CP-${id}`);
        const mechanicId = String(cp.mechanicId || cp.mechanic_id);
        const amount = round2(cp.amount);
        const note = cp.note ? String(cp.note) : null;
        const date = parseDate(cp.date);

        await manager.query(
          `INSERT INTO credit_payments (tenant_id, id, receipt_no, mechanic_id, amount, note, date)
           VALUES ($1, $2, $3, $4, $5, $6, $7)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, receiptNo, mechanicId, amount, note, date],
        );
      }

      // 3.9 PurchaseOrders & PoItems
      const pos = snapshot.sa_purchase_orders || [];
      for (const po of pos) {
        const id = String(po.id);
        const poNo = String(po.poNo || po.po_no || `PO-${id}`);
        const supplier = String(po.supplier || '');
        const status = String(po.status || 'open');
        const createdAt = parseDate(po.createdAt || po.created_at);
        const receivedAt = po.receivedAt || po.received_at ? parseDate(po.receivedAt || po.received_at) : null;
        const cancelledAt = po.cancelledAt || po.cancelled_at ? parseDate(po.cancelledAt || po.cancelled_at) : null;

        await manager.query(
          `INSERT INTO purchase_orders (tenant_id, id, po_no, supplier, status, created_at, received_at, cancelled_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, poNo, supplier, status, createdAt, receivedAt, cancelledAt],
        );

        const items = (po.items as Array<Record<string, unknown>>) || [];
        for (let i = 0; i < items.length; i++) {
          const item = items[i];
          const lineNo = i + 1;
          const partNo = String(item.partNo || item.part_no || '');
          const name = String(item.name || '');
          const qty = Math.max(1, Math.floor(Number(item.qty ?? 1)));
          const cost = round2(item.cost);

          await manager.query(
            `INSERT INTO po_items (tenant_id, po_id, line_no, part_no, name, qty, cost)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (tenant_id, po_id, line_no) DO NOTHING`,
            [tenantId, id, lineNo, partNo, name, qty, cost],
          );
        }
      }

      // 3.10 Quotes & QuoteItems
      const quotes = snapshot.sa_quotes || [];
      for (const q of quotes) {
        const id = String(q.id);
        const quoteNo = String(q.quoteNo || q.quote_no || `QT-${id}`);
        const status = String(q.status || 'open');
        const date = parseDate(q.date);
        const validUntil = parseDate(q.validUntil || q.valid_until || new Date(date.getTime() + 30 * 86400 * 1000));
        const convertedAt = q.convertedAt || q.converted_at ? parseDate(q.convertedAt || q.converted_at) : null;
        const convertedSaleId = q.convertedSaleId || q.converted_sale_id ? String(q.convertedSaleId || q.converted_sale_id) : null;
        const subtotal = q.subtotal != null ? round2(q.subtotal) : null;
        const discount = q.discount != null ? round2(q.discount) : null;
        const total = q.total != null ? round2(q.total) : null;
        const customerName = q.customerName || q.customer_name ? String(q.customerName || q.customer_name) : null;
        const customerPhone = q.customerPhone || q.customer_phone ? String(q.customerPhone || q.customer_phone) : null;
        const notes = q.notes ? String(q.notes) : null;
        const validDays = q.validDays != null ? Number(q.validDays) : null;

        await manager.query(
          `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until, converted_at, converted_sale_id, subtotal, discount, total, customer_name, customer_phone, notes, valid_days)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [
            tenantId, id, quoteNo, status, date, validUntil, convertedAt, convertedSaleId,
            subtotal, discount, total, customerName, customerPhone, notes, validDays,
          ],
        );

        const items = (q.items as Array<Record<string, unknown>>) || [];
        for (let i = 0; i < items.length; i++) {
          const item = items[i];
          const lineNo = i + 1;
          const productId = item.productId || item.product_id ? String(item.productId || item.product_id) : null;
          const name = String(item.name || '');
          const qty = Math.max(1, Math.floor(Number(item.qty ?? 1)));
          const price = round2(item.price);

          await manager.query(
            `INSERT INTO quote_items (tenant_id, quote_id, line_no, product_id, name, qty, price)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (tenant_id, quote_id, line_no) DO NOTHING`,
            [tenantId, id, lineNo, productId, name, qty, price],
          );
        }
      }

      // 3.11 Movements
      const movements = snapshot.sa_movements || [];
      for (const m of movements) {
        const id = String(m.id);
        const productId = String(m.productId || m.product_id);
        const partNo = String(m.partNo || m.part_no || '');
        const name = String(m.name || '');
        const delta = Math.floor(Number(m.delta ?? 0));
        const type = String(m.type || 'adjustment-in');
        const note = m.note ? String(m.note) : null;
        const stockAfter = Math.floor(Number(m.stockAfter ?? m.stock_after ?? 0));
        const refId = m.refId || m.ref_id ? String(m.refId || m.ref_id) : null;
        const date = parseDate(m.date);

        await manager.query(
          `INSERT INTO movements (tenant_id, id, product_id, part_no, name, delta, type, note, stock_after, ref_id, date)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, productId, partNo, name, delta, type, note, stockAfter, refId, date],
        );
      }

      // 3.12 Shifts & Nested DrawerEntries
      const shifts = snapshot.sa_shifts || [];
      for (let i = 0; i < shifts.length; i++) {
        const sh = shifts[i];
        const shiftId = String(sh.id || `sh_${i + 1}`);
        const dateStr = String(sh.dateStr || sh.date_str || new Date().toISOString().slice(0, 10));
        const startingCash = round2(sh.startingCash || sh.starting_cash);
        const openedAt = parseDate(sh.openedAt || sh.opened_at);
        const closedAt = sh.closedAt || sh.closed_at ? parseDate(sh.closedAt || sh.closed_at) : null;
        const physicalCash = sh.physicalCash != null || sh.physical_cash != null ? round2(sh.physicalCash ?? sh.physical_cash) : null;
        const isActive = Boolean(sh.isActive ?? sh.is_active);

        await manager.query(
          `INSERT INTO shifts (tenant_id, id, date_str, starting_cash, opened_at, closed_at, physical_cash, is_active)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, shiftId, dateStr, startingCash, openedAt, closedAt, physicalCash, isActive],
        );

        // Nested drawer entries inside shift object or top-level list
        const entries = (sh.entries as Array<Record<string, unknown>>) || [];
        for (let j = 0; j < entries.length; j++) {
          const entry = entries[j];
          const entryId = String(entry.id || `de_${shiftId}_${j + 1}`);
          const type = String(entry.type || 'in');
          const amount = round2(entry.amount);
          const note = entry.note ? String(entry.note) : null;
          const createdAt = parseDate(entry.createdAt || entry.created_at);

          await manager.query(
            `INSERT INTO drawer_entries (tenant_id, id, shift_id, type, amount, note, created_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (tenant_id, id) DO NOTHING`,
            [tenantId, entryId, shiftId, type, amount, note, createdAt],
          );
        }
      }

      // Top-level drawer entries if any
      const topEntries = snapshot.sa_drawer_entries || [];
      for (const entry of topEntries) {
        const entryId = String(entry.id);
        const shiftId = String(entry.shiftId || entry.shift_id);
        const type = String(entry.type || 'in');
        const amount = round2(entry.amount);
        const note = entry.note ? String(entry.note) : null;
        const createdAt = parseDate(entry.createdAt || entry.created_at);

        await manager.query(
          `INSERT INTO drawer_entries (tenant_id, id, shift_id, type, amount, note, created_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, entryId, shiftId, type, amount, note, createdAt],
        );
      }

      // 3.13 Parked Sales
      const parked = snapshot.sa_parked_sales || [];
      for (const ps of parked) {
        const id = String(ps.id);
        const parkedAt = parseDate(ps.parkedAt || ps.parked_at);
        const payload = ps.payload ? (typeof ps.payload === 'string' ? JSON.parse(ps.payload) : ps.payload) : ps;

        await manager.query(
          `INSERT INTO parked_sales (tenant_id, id, parked_at, payload)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, parkedAt, JSON.stringify(payload)],
        );
      }

      // 3.14 Settings
      if (snapshot.sa_settings) {
        const set = snapshot.sa_settings;
        const shopName = String(set.shopName || set.shop_name || 'ร้านอะไหล่');
        const shopNameEn = String(set.shopNameEN || set.shop_name_en || '');
        const taxRate = round2(set.taxRate ?? set.tax_rate ?? 7);
        const quoteValidDays = Math.max(1, Math.floor(Number(set.quoteValidDays ?? set.quote_valid_days ?? 30)));
        const address = set.address ? String(set.address) : null;
        const phone = set.phone ? String(set.phone) : null;
        const cashierName = set.cashierName || set.cashier_name ? String(set.cashierName || set.cashier_name) : null;
        const taxId = set.taxId || set.tax_id ? String(set.taxId || set.tax_id) : null;
        const branchNo = set.branchNo || set.branch_no ? String(set.branchNo || set.branch_no) : null;

        await manager.query(
          `INSERT INTO settings (tenant_id, shop_name, shop_name_en, tax_rate, quote_valid_days, address, phone, cashier_name, tax_id, branch_no)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
           ON CONFLICT (tenant_id) DO UPDATE SET
             shop_name = EXCLUDED.shop_name,
             shop_name_en = EXCLUDED.shop_name_en,
             tax_rate = EXCLUDED.tax_rate,
             quote_valid_days = EXCLUDED.quote_valid_days,
             address = EXCLUDED.address,
             phone = EXCLUDED.phone,
             cashier_name = EXCLUDED.cashier_name,
             tax_id = EXCLUDED.tax_id,
             branch_no = EXCLUDED.branch_no`,
          [tenantId, shopName, shopNameEn, taxRate, quoteValidDays, address, phone, cashierName, taxId, branchNo],
        );
      }
    });

    await this.auditService.log({
      tenantId,
      platformAdminId: adminId,
      action: 'platform.tenant.import',
      ip,
    });

    return { status: 'success', tenantId };
  }
}
