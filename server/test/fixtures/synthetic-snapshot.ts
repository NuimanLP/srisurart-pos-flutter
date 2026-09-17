/**
 * #185 — a synthetic shop snapshot, generated deterministically, in the exact shape the
 * shop's backup file has: the `sa_*` stores + `__meta` that `SnapshotRepository.exportSnapshot()`
 * (frontend/lib/data/repositories/snapshot_repository.dart, a port of db.js) writes.
 *
 * It is not a table of random rows. It **simulates the shop** day by day and applies the
 * Drift repositories' own rules to every event — `saveSale`, `createReturn`, `receivePO`,
 * `adjustStock`, `addCreditPayment`, `openShift` / `addDrawerEntry` / `closeShift`,
 * `parkSale`, quotes — so the ledgers agree with each other the way a real backup's do,
 * including the float artefacts the app's `double` arithmetic leaves behind.
 * `test/support/snapshot-checks.ts` then verifies that from the JSON alone.
 *
 * Every name, phone number, tax id and address is invented and visibly so
 * (`ลูกค้าทดสอบ`, `099-000-xxxx`). No real personal data — it stands in for the shop's
 * snapshot until the owner obtains one (which is never committed, PDPA).
 *
 * Profiles:
 *   - `clean`     — only what the import is designed to accept.
 *   - `realistic` — adds what the Drift build really produces and `clean` avoids: hard-
 *     deleted products / customers / mechanics that history still references (Drift has
 *     no foreign keys and every delete is a hard delete), and a deleted category that
 *     products still name (`01_DATABASE.md §9`, §10). The import turns those references into
 *     soft-deleted tombstones (#238).
 *
 * CLI:  corepack pnpm exec tsx test/fixtures/synthetic-snapshot.ts \
 *         [--scale small|full] [--profile clean|realistic] [--seed 185] [--out file.json]
 */
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { ZONE_TO_CATEGORY } from '../../src/platform/snapshot-category.js';

export type Scale = 'small' | 'full';
export type Profile = 'clean' | 'realistic';

export interface SyntheticOptions {
  seed?: number;
  scale?: Scale;
  profile?: Profile;
}

type Json = Record<string, unknown>;

const SCALES: Record<Scale, { products: number; customers: number; mechanics: number; days: number; salesPerDay: [number, number] }> = {
  small: { products: 40, customers: 12, mechanics: 4, days: 21, salesPerDay: [5, 10] },
  full: { products: 320, customers: 90, mechanics: 14, days: 120, salesPerDay: [12, 24] },
};

/** db.js getProducts() zone → category map — the import's own copy, never a second one. */
const ZONE_MAP = ZONE_TO_CATEGORY;

const CATEGORIES = ['เครื่องยนต์', 'ไฟฟ้า', 'น้ำมัน', 'เบรก', 'ตัวถัง', 'ช่วงล่าง', 'ยาง'];

// [nameTH, name, minPrice, maxPrice] per category.
const TEMPLATES: Record<string, Array<[string, string, number, number]>> = {
  เครื่องยนต์: [
    ['กรองน้ำมันเครื่อง', 'Oil Filter', 60, 180],
    ['กรองอากาศ', 'Air Filter', 150, 450],
    ['สายพานไทม์มิ่ง', 'Timing Belt', 450, 1400],
    ['ปะเก็นฝาสูบ', 'Head Gasket', 350, 1200],
    ['ปั๊มน้ำ', 'Water Pump', 600, 2200],
  ],
  ไฟฟ้า: [
    ['หัวเทียน', 'Spark Plug', 80, 260],
    ['แบตเตอรี่', 'Battery', 1400, 3600],
    ['หลอดไฟหน้า', 'Headlight Bulb', 90, 450],
    ['ฟิวส์', 'Fuse Set', 25, 120],
    ['รีเลย์', 'Relay', 90, 320],
  ],
  น้ำมัน: [
    ['น้ำมันเครื่อง 4 ลิตร', 'Engine Oil 4L', 650, 1650],
    ['น้ำมันเกียร์', 'Gear Oil', 180, 480],
    ['น้ำมันเบรก', 'Brake Fluid', 90, 260],
    ['น้ำยาหม้อน้ำ', 'Coolant', 120, 350],
  ],
  เบรก: [
    ['ผ้าเบรกหน้า', 'Front Brake Pad', 350, 1500],
    ['ผ้าเบรกหลัง', 'Rear Brake Shoe', 300, 1100],
    ['จานเบรก', 'Brake Disc', 700, 2400],
    ['แม่ปั๊มเบรก', 'Brake Master Cylinder', 900, 2800],
  ],
  ตัวถัง: [
    ['ใบปัดน้ำฝน', 'Wiper Blade', 120, 420],
    ['กระจกมองข้าง', 'Side Mirror', 450, 1800],
    ['มือเปิดประตู', 'Door Handle', 150, 600],
  ],
  ช่วงล่าง: [
    ['โช้คอัพหน้า', 'Front Shock Absorber', 900, 3200],
    ['ลูกหมากกันโคลง', 'Stabilizer Link', 250, 850],
    ['บูชปีกนก', 'Control Arm Bushing', 120, 480],
  ],
  ยาง: [
    ['ยางใน', 'Inner Tube', 90, 260],
    ['ยางนอก', 'Tyre', 700, 3400],
  ],
};

const BRANDS: Array<[string, string]> = [
  ['DENSO', 'DN'], ['NGK', 'NG'], ['Bosch', 'BS'], ['Aisin', 'AS'], ['Bendix', 'BD'],
  ['Castrol', 'CT'], ['PTT', 'PT'], ['Kayaba', 'KY'], ['333', 'TT'], ['Honda OEM', 'HN'],
  ['Toyota OEM', 'TY'], ['GS', 'GS'],
];
const VEHICLES = [
  'Toyota Vios', 'Honda City', 'Isuzu D-Max', 'Toyota Hilux Revo', 'Honda Wave 110i',
  'Yamaha Fino', 'Mitsubishi Triton', 'Nissan Almera',
];
const THAI_FIRST = ['สมชาย', 'สมหญิง', 'ประยุทธ', 'มานี', 'ปิติ', 'ชูใจ', 'วีระ', 'สุดา', 'อนันต์', 'กมล'];
const SUPPLIERS = [
  'บริษัท ทดสอบอะไหล่ยนต์ จำกัด',
  'หจก. ตัวอย่างออโต้พาร์ท',
  'ร้านส่งอะไหล่สมมติ',
];
const RETURN_REASONS = ['ใส่ไม่ได้', 'ลูกค้าเปลี่ยนใจ', 'สินค้าชำรุด', 'สั่งผิดรุ่น'];

// ── deterministic helpers ─────────────────────────────────────────────────────

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Dart `round2` / db.js: `(v * 100).round() / 100` (Dart rounds half away from zero). */
export function round2(v: number): number {
  return (Math.sign(v) * Math.round(Math.abs(v) * 100)) / 100;
}

const pad = (n: number, w: number) => String(n).padStart(w, '0');

/** Bangkok midnight of 2026-05-01 + `day` days, as a UTC epoch ms. */
const START_UTC = Date.UTC(2026, 4, 1) - 7 * 3600_000;
const bkkDate = (ms: number) => new Date(ms + 7 * 3600_000).toISOString().slice(0, 10);
const iso = (ms: number | null | undefined) => (ms == null ? null : new Date(ms).toISOString());

// ── in-memory model (mirrors the Drift rows) ─────────────────────────────────

interface Product { id: string; partNo: string; name: string; nameTH: string; category: string; zone?: string; brand: string; price: number; cost: number; stock: number; minStock: number; compat?: string | null; updatedAt: number; deleted?: boolean }
interface Customer { id: string; code: string; name: string; nameTH: string; phone?: string | null; address?: string; points: number; totalSpend: number; createdAt: string; updatedAt?: number; deleted?: boolean; deletedAt?: number }
interface Mechanic { id: string; code: string; name: string; nameTH: string; nickname?: string | null; shopName: string; phone: string; note?: string; creditLimit: number; creditBalance: number; totalSales: number; totalCredit: number; totalDiscount: number; totalMarkup: number; createdAt: string; updatedAt?: number; deleted?: boolean; deletedAt?: number }
interface SaleItem { productId: string; partNo: string; name: string; nameTH: string; qty: number; price: number; cost: number }
interface Sale { id: string; receiptNo: string; subtotal: number; discount: number; total: number; paymentMethod: string; customerId?: string; customerName?: string; mechanicId?: string; mechanicName?: string; mechanicDelta?: number; pointsGranted: number; date: number; voided: boolean; voidedAt?: number; items: SaleItem[] }
interface Shift { date: string; startingCash: number; openedAt: number; closedAt: number | null; physicalCash: number | null; isActive: boolean; autoArchived: boolean; archivedAt?: number; entries: Array<{ id: string; type: 'in' | 'out'; amount: number; note: string; createdAt: number }> }

export function generateSyntheticSnapshot(options: SyntheticOptions = {}): Json {
  const seed = options.seed ?? 185;
  const scale = SCALES[options.scale ?? 'small'];
  const profile = options.profile ?? 'clean';
  const rnd = mulberry32(seed);
  const int = (lo: number, hi: number) => lo + Math.floor(rnd() * (hi - lo + 1));
  const chance = (p: number) => rnd() < p;
  const pick = <T>(xs: readonly T[]): T => xs[Math.floor(rnd() * xs.length)];
  const hex = (n: number) => Array.from({ length: n }, () => Math.floor(rnd() * 16).toString(16)).join('');

  let lastMs = START_UTC;
  let idCounter = 0;
  /** Advance the clock to `target` (never backwards, never the same millisecond). */
  const tick = (target: number) => (lastMs = Math.max(target, lastMs + 1 + int(0, 900)));
  // ids.dart newId / docNo, with the simulated clock in place of DateTime.now().
  const newId = (prefix: string) => `${prefix}${lastMs.toString(36)}_${hex(8)}_${(++idCounter).toString(36)}`;
  const issued = new Set<string>();
  const docNo = (prefix: string) => {
    for (;;) {
      const no = `${prefix}${String(lastMs).slice(-8)}${hex(4).toUpperCase()}`;
      if (!issued.has(no)) return issued.add(no), no;
    }
  };

  // ── catalogue ──
  const products: Product[] = [];
  const movements: Json[] = [];
  const partNos = new Set<string>();
  const addMovement = (p: Product, delta: number, type: string, note: string | null) =>
    movements.push({ id: newId('mv'), productId: p.id, partNo: p.partNo, name: p.name, delta, type, ...(note != null ? { note } : {}), stockAfter: p.stock, date: lastMs });

  tick(START_UTC + 7 * 3600_000);
  for (let i = 0; i < scale.products; i++) {
    const category = pick(CATEGORIES);
    const [nameTH, name, lo, hi] = pick(TEMPLATES[category]);
    const [brand, code] = pick(BRANDS);
    const vehicle = pick(VEHICLES);
    let partNo: string;
    do partNo = `${code}-${int(10000, 99999)}-${String.fromCharCode(65 + int(0, 25), 65 + int(0, 25), 65 + int(0, 25))}`;
    while (partNos.has(partNo.toLowerCase()));
    partNos.add(partNo.toLowerCase());
    const price = Math.round(int(lo, hi) / 5) * 5;
    const p: Product = {
      id: newId('p'), partNo, name: `${name} ${brand}`, nameTH: `${nameTH} ${vehicle}`, category, brand, price,
      cost: round2(price * (0.55 + rnd() * 0.2)), stock: 0, minStock: int(2, 10), updatedAt: lastMs,
    };
    // A legacy product from the JS app carries `zone` and no `category` (db.js migrated it on read).
    const zone = Object.keys(ZONE_MAP).find((z) => ZONE_MAP[z] === category);
    if (zone && chance(0.12)) p.zone = zone;
    if (chance(0.5)) p.compat = vehicle;
    else if (chance(0.2)) p.compat = null; // an explicit null the importers must read as absent
    products.push(p);
    // Opening stock is logged as a manual adjustment, so stock = Σ movements − sold + returned.
    const opening = int(6, 60);
    p.stock = opening;
    tick(lastMs);
    addMovement(p, opening, 'adjustment-in', 'ยอดยกมา (ข้อมูลสังเคราะห์)');
  }

  const suppliers: Json[] = [];
  for (const p of products) {
    if (!chance(0.35)) continue;
    for (let k = int(1, 2); k > 0; k--) {
      suppliers.push({ id: newId('sp'), productId: p.id, name: pick(SUPPLIERS), unitCost: round2(p.cost * (0.9 + rnd() * 0.1)), freight: pick([0, 0, 20, 50]) });
    }
  }

  // A product can be added with a supplier price and hard-deleted before it is ever stocked
  // or sold — no movement, no sale/return/quote line, nothing else in history names it. Only
  // a supplier row is left pointing at a product id the file no longer has. The `realistic`
  // profile carries one, so the import's "drop the orphaned supplier row" path (#252, owner
  // 2026-09-15) is exercised the way a real shop's file can trigger it.
  if (profile === 'realistic') {
    const category = pick(CATEGORIES);
    const [nameTH, name, lo, hi] = pick(TEMPLATES[category]);
    const [brand, code] = pick(BRANDS);
    let partNo: string;
    do partNo = `${code}-${int(10000, 99999)}-ORP`;
    while (partNos.has(partNo.toLowerCase()));
    partNos.add(partNo.toLowerCase());
    const price = Math.round(int(lo, hi) / 5) * 5;
    const orphan: Product = {
      id: newId('p'), partNo, name: `${name} ${brand} (ไม่เคยลงสต็อก)`, nameTH: `${nameTH} (ไม่เคยลงสต็อก)`,
      category, brand, price, cost: round2(price * 0.65), stock: 0, minStock: 0, updatedAt: lastMs, deleted: true,
    };
    products.push(orphan);
    suppliers.push({ id: newId('sp'), productId: orphan.id, name: pick(SUPPLIERS), unitCost: round2(orphan.cost * 0.95), freight: 0 });
  }

  const customers: Customer[] = Array.from({ length: scale.customers }, (_, i) => ({
    id: newId('c'), code: `CUS${pad(i + 1, 3)}`, name: `Test Customer ${pad(i + 1, 3)}`,
    nameTH: `ลูกค้าทดสอบ ${pick(THAI_FIRST)} ${pad(i + 1, 3)}`,
    phone: chance(0.8) ? `099-000-${pad(i + 1, 4)}` : chance(0.5) ? null : undefined,
    ...(chance(0.4) ? { address: `ที่อยู่สมมติ ${i + 1} ถนนทดสอบ` } : {}),
    points: 0, totalSpend: 0, createdAt: `2025-${pad(int(1, 12), 2)}-${pad(int(1, 28), 2)}`,
  }));

  const mechanics: Mechanic[] = Array.from({ length: scale.mechanics }, (_, i) => ({
    id: newId('m'), code: `M${pad(i + 1, 3)}`, name: `Test Mechanic ${pad(i + 1, 3)}`,
    nameTH: `ช่างทดสอบ ${pick(THAI_FIRST)}`, nickname: chance(0.6) ? `ช่าง${i + 1}` : null,
    shopName: `อู่ทดสอบ ${pad(i + 1, 2)}`, phone: `098-000-${pad(i + 1, 4)}`,
    ...(chance(0.3) ? { note: 'ข้อมูลสังเคราะห์' } : {}),
    creditLimit: pick([5000, 10000, 20000, 30000]), creditBalance: 0, totalSales: 0, totalCredit: 0,
    totalDiscount: 0, totalMarkup: 0, createdAt: `2025-${pad(int(1, 12), 2)}-${pad(int(1, 28), 2)}`,
  }));

  const live = <T extends { deleted?: boolean }>(xs: T[]) => xs.filter((x) => !x.deleted);

  const sales: Sale[] = [];
  const returns: Json[] = [];
  const creditPayments: Json[] = [];
  const pos: Json[] = [];
  const quotes: Json[] = [];
  const shifts: Shift[] = [];
  const refunded = new Map<string, Map<string, number>>(); // saleId → productId → qty

  // ── SalesRepository.saveSale ──
  const saveSale = (lines: SaleItem[], opts: { discount: number; customer?: Customer; mechanic?: Mechanic; mechanicDelta?: number; paymentMethod: string }) => {
    const subtotal = lines.reduce((s, l) => s + l.price * l.qty, 0);
    const total = subtotal - opts.discount < 0 ? 0 : subtotal - opts.discount;
    const pointsGranted = Math.floor(total / 10);
    const sale: Sale = {
      id: newId('s'), receiptNo: docNo('RC'), subtotal, discount: opts.discount, total, paymentMethod: opts.paymentMethod,
      pointsGranted, date: lastMs, voided: false, items: lines,
    };
    for (const l of lines) {
      const p = products.find((x) => x.id === l.productId)!;
      p.stock -= l.qty;
      if (p.stock < 0) throw new Error(`generator bug: stock underflow on ${p.partNo}`);
      p.updatedAt = lastMs;
    }
    if (opts.customer) {
      Object.assign(sale, { customerId: opts.customer.id, customerName: opts.customer.name });
      opts.customer.totalSpend += total;
      opts.customer.points += pointsGranted;
      opts.customer.updatedAt = lastMs;
    }
    if (opts.mechanic) {
      const m = opts.mechanic;
      const delta = opts.mechanicDelta ?? 0;
      Object.assign(sale, { mechanicId: m.id, mechanicName: m.name, mechanicDelta: opts.mechanicDelta });
      m.totalSales += total;
      m.totalDiscount += delta < 0 ? -delta : 0;
      m.totalMarkup += delta > 0 ? delta : 0;
      m.creditBalance += opts.paymentMethod === 'เครดิตช่าง' ? total : 0;
      m.updatedAt = lastMs;
    }
    sales.push(sale);
    return sale;
  };

  const cartFrom = (count: number, mechanic?: Mechanic): { lines: SaleItem[]; delta: number } | null => {
    const stocked = live(products).filter((p) => p.stock > 0);
    if (stocked.length === 0) return null;
    const chosen = new Set<Product>();
    while (chosen.size < Math.min(count, stocked.length)) chosen.add(pick(stocked));
    let delta = 0;
    const lines = [...chosen].map((p) => {
      const qty = int(1, Math.min(3, p.stock));
      let price = p.price;
      if (mechanic) {
        if (chance(0.7)) price = Math.round(p.price * (1 - pick([0.05, 0.1])));
        else if (chance(0.15)) price = p.price + pick([20, 50]);
      }
      delta += (price - p.price) * qty; // CartCubit.mechanicDelta
      return { productId: p.id, partNo: p.partNo, name: p.name, nameTH: p.nameTH, qty, price, cost: p.cost };
    });
    return { lines, delta };
  };

  // ── ReturnsRepository.createReturn ──
  const createReturn = (sale: Sale, items: Array<{ item: SaleItem; qty: number }>, refundMethod: string) => {
    const refundSubtotal = items.reduce((s, i) => s + i.item.price * i.qty, 0);
    const discountRatio = sale.subtotal > 0 ? sale.discount / sale.subtotal : 0;
    const refundDiscount = round2(refundSubtotal * discountRatio);
    const refundTotal = round2(refundSubtotal - refundDiscount);
    returns.push({
      id: newId('r'), cnNo: docNo('CN'), saleId: sale.id, receiptNo: sale.receiptNo, refundSubtotal, refundDiscount,
      refundTotal, refundMethod, reason: pick(RETURN_REASONS),
      ...(sale.customerId ? { customerId: sale.customerId } : {}),
      ...(sale.mechanicId ? { mechanicId: sale.mechanicId, mechanicName: sale.mechanicName } : {}),
      date: lastMs,
      items: items.map((i) => ({ productId: i.item.productId, name: i.item.name, qty: i.qty, price: i.item.price, originalQty: i.item.qty })),
    });
    const done = refunded.get(sale.id) ?? new Map<string, number>();
    refunded.set(sale.id, done);
    for (const i of items) {
      done.set(i.item.productId, (done.get(i.item.productId) ?? 0) + i.qty);
      const p = products.find((x) => x.id === i.item.productId && !x.deleted);
      if (p) { p.stock += i.qty; p.updatedAt = lastMs; }
    }
    const cust = customers.find((c) => c.id === sale.customerId && !c.deleted);
    if (cust) {
      const ratio = sale.total > 0 ? refundTotal / sale.total : 0;
      const basePoints = sale.pointsGranted > 0 ? sale.pointsGranted : Math.floor(sale.total / 10);
      cust.totalSpend = Math.max(0, cust.totalSpend - refundTotal);
      cust.points = Math.max(0, cust.points - Math.floor(basePoints * ratio));
      cust.updatedAt = lastMs;
    }
    const mech = mechanics.find((m) => m.id === sale.mechanicId && !m.deleted);
    if (mech) {
      const ratio = sale.total > 0 ? refundTotal / sale.total : 0;
      const origDelta = sale.mechanicDelta ?? 0;
      const discountBase = mech.totalDiscount !== 0 ? mech.totalDiscount : mech.totalCredit;
      mech.totalSales = Math.max(0, mech.totalSales - refundTotal);
      mech.totalDiscount = Math.max(0, discountBase - (origDelta < 0 ? -origDelta * ratio : 0));
      mech.totalMarkup = Math.max(0, mech.totalMarkup - (origDelta > 0 ? origDelta * ratio : 0));
      mech.creditBalance = Math.max(0, mech.creditBalance - (refundMethod === 'หักจากเครดิต' ? refundTotal : 0));
      mech.updatedAt = lastMs;
    }
    const sold = sale.items.reduce((s, i) => s + i.qty, 0);
    if ([...done.values()].reduce((s, q) => s + q, 0) >= sold) {
      sale.voided = true;
      sale.voidedAt = lastMs;
    }
  };

  // ── PurchaseOrdersRepository.receivePO ──
  const receivePO = (po: Json) => {
    for (const item of po.items as Array<{ partNo: string; qty: number; cost: number }>) {
      const p = live(products).find((x) => x.partNo.toLowerCase() === item.partNo.toLowerCase());
      if (!p) continue; // unmatched line: Drift reports it and moves on
      const newCost = item.cost > 0 ? item.cost : p.cost;
      const totalQty = p.stock + item.qty;
      const wac = totalQty > 0 ? round2((p.stock * p.cost + item.qty * newCost) / totalQty) : newCost;
      p.stock = totalQty;
      p.cost = wac;
      p.updatedAt = lastMs;
      addMovement(p, item.qty, 'receive', `PO ${po.poNo} จาก ${po.supplier} · ทุนใหม่ ฿${wac}`);
    }
    po.status = 'received';
    po.receivedAt = lastMs;
  };

  const pendingPos: Array<{ po: Json; day: number; cancel: boolean }> = [];
  const pendingQuotes: Array<{ quote: Json; day: number }> = [];
  const deleteDay = profile === 'realistic' ? Math.floor(scale.days * 0.6) : -1;

  for (let day = 0; day < scale.days; day++) {
    const midnight = START_UTC + day * 86400_000;
    const at = (h: number, m = 0) => tick(midnight + (h * 60 + m) * 60_000);
    const isSunday = new Date(midnight + 7 * 3600_000).getUTCDay() === 0;
    const last = day === scale.days - 1;

    // ShiftsRepository.openShift archives yesterday's drawer, auto-archiving one left open.
    at(8, int(0, 15));
    const prev = shifts.find((s) => s.isActive);
    if (prev) {
      prev.isActive = false;
      if (prev.closedAt == null) { prev.autoArchived = true; prev.archivedAt = lastMs; }
    }
    const shift: Shift = { date: bkkDate(lastMs), startingCash: pick([1000, 1500, 2000]), openedAt: lastMs, closedAt: null, physicalCash: null, isActive: true, autoArchived: false, entries: [] };
    shifts.push(shift);

    if (day === deleteDay) {
      // A hard delete in Drift leaves every row that referenced the entity in place.
      const soldIds = new Set(sales.flatMap((s) => s.items.map((i) => i.productId)));
      live(products).filter((p) => soldIds.has(p.id)).slice(0, 2).forEach((p) => (p.deleted = true));
      const withSales = new Set(sales.map((s) => s.customerId));
      const c = live(customers).find((x) => withSales.has(x.id));
      if (c) c.deleted = true;
      const m = live(mechanics).find((x) => x.creditBalance < 0.005 &&sales.some((s) => s.mechanicId === x.id));
      if (m) m.deleted = true;
    }

    // POs due today: receive or cancel.
    for (const due of pendingPos.filter((d) => d.day === day)) {
      at(10, int(0, 50));
      if (due.cancel) { due.po.status = 'cancelled'; due.po.cancelledAt = lastMs; } else receivePO(due.po);
    }

    let n = int(scale.salesPerDay[0], scale.salesPerDay[1]);
    if (isSunday) n = Math.ceil(n / 2);
    for (let k = 0; k < n; k++) {
      at(8, 30 + Math.floor(((k + rnd()) * 540) / n));
      const mechanic = chance(0.28) ? pick(live(mechanics)) : undefined;
      const customer = !mechanic && chance(0.35) ? pick(live(customers)) : undefined;
      const cart = cartFrom(int(1, 4), mechanic);
      if (!cart) continue;
      const subtotal = cart.lines.reduce((s, l) => s + l.price * l.qty, 0);
      const discount = !mechanic && chance(0.15) ? Math.min(pick([5, 10, 20, 50]), subtotal) : 0;
      let paymentMethod = chance(0.3) ? 'โอน/QR' : 'เงินสด';
      if (mechanic && chance(0.55) && mechanic.creditBalance + subtotal <= mechanic.creditLimit) paymentMethod = 'เครดิตช่าง';
      saveSale(cart.lines, { discount, customer, mechanic, mechanicDelta: mechanic ? round2(cart.delta) : undefined, paymentMethod });

      // A drawer entry now and then, between bills.
      if (chance(0.06)) {
        const out = chance(0.8);
        shift.entries.push({
          id: newId('de'), type: out ? 'out' : 'in',
          amount: out ? pick([35, 60, 120, 150, 200]) : pick([500, 1000]),
          // exportSnapshot() writes `note ?? ''`, so a note nobody typed is an empty string.
          note: out ? pick(['ค่าส่งของ', 'ค่าน้ำแข็ง/น้ำดื่ม', 'ซื้ออุปกรณ์ทำความสะอาด', '']) : 'เติมเงินทอน',
          createdAt: lastMs,
        });
      }
    }

    // Returns against the last week's bills.
    const recent = sales.filter((s) => !s.voided && s.date >= midnight - 7 * 86400_000 && s.date < lastMs);
    for (let r = scale.salesPerDay[1] > 12 ? int(0, 2) : int(0, 1); r > 0 && recent.length > 0; r--) {
      const sale = pick(recent);
      if (sale.voided) continue;
      const done = refunded.get(sale.id);
      const open = sale.items.map((item) => ({ item, left: item.qty - (done?.get(item.productId) ?? 0) })).filter((x) => x.left > 0);
      if (open.length === 0) continue;
      const full = chance(0.3);
      const chosen = full ? open : open.slice(0, int(1, open.length));
      const items = chosen.map((x) => ({ item: x.item, qty: full ? x.left : int(1, x.left) }));
      const refundTotalEstimate = items.reduce((s, i) => s + i.item.price * i.qty, 0);
      const mech = mechanics.find((m) => m.id === sale.mechanicId && !m.deleted);
      let method = pick(['เงินสด', 'โอน']);
      if (sale.paymentMethod === 'เครดิตช่าง') method = mech && mech.creditBalance >= refundTotalEstimate ? 'หักจากเครดิต' : 'โอน';
      else if (mech && chance(0.2) && mech.creditBalance >= refundTotalEstimate) method = 'หักจากเครดิต';
      at(15, int(0, 120));
      createReturn(sale, items, method);
    }

    // Mechanics settling their tab (MechanicsRepository.addCreditPayment).
    for (const m of live(mechanics)) {
      if (m.creditBalance < 100 || !chance(0.12)) continue;
      at(16, int(0, 90));
      const amount = chance(0.4) ? round2(m.creditBalance) : Math.max(100, Math.round((m.creditBalance * (0.3 + rnd() * 0.4)) / 100) * 100);
      if (amount > m.creditBalance) continue; // never let Drift's clamp at 0 hide an overpayment
      creditPayments.push({ id: newId('cp'), receiptNo: docNo('CP'), mechanicId: m.id, amount, date: lastMs, ...(chance(0.7) ? { note: pick(['จ่ายเงินสด', 'โอนเข้าบัญชี']) } : {}) });
      m.creditBalance = Math.max(0, m.creditBalance - amount);
      m.updatedAt = lastMs;
    }

    // ProductsRepository.adjustStock — kept inside [0, stock] so its clamp never fires.
    if (chance(0.3)) {
      at(17, int(0, 20));
      const p = pick(live(products));
      const out = p.stock > 0 && chance(0.6);
      const delta = out ? -int(1, Math.min(2, p.stock)) : int(1, 3);
      p.stock += delta;
      p.updatedAt = lastMs;
      addMovement(p, delta, out ? 'adjustment-out' : 'adjustment-in', out ? 'ของเสีย/ชำรุด' : 'นับสต็อกเจอเพิ่ม');
    }

    // A purchase order every few days, received (or cancelled) one to three days later.
    if (day % 3 === 1) {
      at(9, int(0, 40));
      const low = [...live(products)].sort((a, b) => a.stock - b.stock).slice(0, Math.ceil(scale.products / 8));
      const lines = new Set<Product>();
      const want = Math.min(low.length, int(4, Math.max(4, Math.ceil(scale.products / 30))));
      while (lines.size < want) lines.add(pick(low));
      const po: Json = {
        id: newId('po'), poNo: docNo('PO'), supplier: pick(SUPPLIERS), status: 'open', createdAt: lastMs,
        items: [...lines].map((p) => ({ partNo: p.partNo, name: p.name, qty: int(10, 40), cost: round2(p.cost * (0.95 + rnd() * 0.13)) })),
      };
      if (chance(0.15)) (po.items as Json[]).push({ partNo: 'XX-00000-TYPO', name: 'รายการพิมพ์รหัสผิด', qty: 2, cost: 100 });
      pos.push(po);
      pendingPos.push({ po, day: day + int(1, 3), cancel: pos.length % 9 === 4 });
    }

    // Quotes; some are converted into a bill a few days later, the rest expire open.
    if (chance(0.35)) {
      at(11, int(0, 50));
      const cart = cartFrom(int(1, 4));
      if (cart) {
        const subtotal = cart.lines.reduce((s, l) => s + l.price * l.qty, 0);
        const discount = chance(0.3) ? Math.min(50, subtotal) : 0;
        const validDays = pick([7, 15, 30]);
        const quote: Json = {
          id: newId('q'), quoteNo: docNo('QT'), status: 'open', date: lastMs, validUntil: lastMs + validDays * 86400_000,
          subtotal, discount, total: subtotal - discount, customerName: `ลูกค้าทดสอบใบเสนอราคา ${quotes.length + 1}`,
          ...(chance(0.6) ? { customerPhone: `097-000-${pad(quotes.length + 1, 4)}` } : {}),
          ...(chance(0.3) ? { notes: 'ราคานี้รวมค่าแรงแล้ว (ตัวอย่าง)' } : {}), validDays,
          items: cart.lines.map((l) => ({ productId: l.productId, name: l.name, qty: l.qty, price: l.price })),
        };
        quotes.push(quote);
        if (chance(0.4)) pendingQuotes.push({ quote, day: day + int(1, 5) });
      }
    }
    for (const due of pendingQuotes.filter((d) => d.day === day)) {
      const q = due.quote;
      const lines = (q.items as Array<{ productId: string; qty: number; price: number }>).map((it) => {
        const p = live(products).find((x) => x.id === it.productId);
        return p && p.stock >= it.qty ? { productId: p.id, partNo: p.partNo, name: p.name, nameTH: p.nameTH, qty: it.qty, price: it.price, cost: p.cost } : null;
      });
      if (lines.some((l) => l === null)) continue; // not enough stock: the quote stays open
      at(13, int(0, 50));
      saveSale(lines as SaleItem[], { discount: q.discount as number, paymentMethod: 'เงินสด' });
      q.status = 'converted';
      q.convertedAt = lastMs;
    }

    // Close the drawer; one day in twenty it is left open and auto-archived next morning.
    if (!last && chance(0.95)) {
      at(18, int(0, 20));
      const cash = sales.filter((s) => s.date >= shift.openedAt && s.paymentMethod === 'เงินสด').reduce((t, s) => t + s.total, 0);
      const flow = shift.entries.reduce((t, e) => t + (e.type === 'in' ? e.amount : -e.amount), 0);
      shift.closedAt = lastMs;
      shift.physicalCash = round2(shift.startingCash + cash + flow + pick([0, 0, 0, 0, -20, 10, -5]));
    }
  }

  // #239 item 4: a customer/mechanic can be *soft*-deleted in Drift (schema v2's `deletedAt`)
  // while still present in the file — a different shape from the hard-delete-and-vanish
  // scenario above (`deleteDay`), which the import turns into a tombstone. This one must
  // import as a soft-deleted row carrying its real ledger values, not a zeroed placeholder.
  // Picked after the day loop so it never interferes with the day-by-day simulation, and from
  // customers/mechanics still `live()` (never the one hard-deleted at `deleteDay`).
  if (profile === 'realistic') {
    const softDeletedCustomer = live(customers).find((c) => sales.some((s) => s.customerId === c.id));
    if (softDeletedCustomer) softDeletedCustomer.deletedAt = lastMs;
    const softDeletedMechanic = live(mechanics).find((m) => sales.some((s) => s.mechanicId === m.id));
    if (softDeletedMechanic) softDeletedMechanic.deletedAt = lastMs;
  }

  // Bills parked at the counter when the backup was taken (ParkedRepository.parkSale).
  const parked: Json[] = [];
  for (let k = 0; k < (scale.days > 30 ? 3 : 2); k++) {
    tick(lastMs + 60_000);
    const cart = cartFrom(int(1, 3))!;
    const id = newId('pk');
    const customer = chance(0.5) ? pick(live(customers)) : undefined;
    parked.push({
      items: cart.lines.map((l) => ({ productId: l.productId, name: l.name, qty: l.qty, price: l.price, partNo: l.partNo, nameTH: l.nameTH })),
      customerId: customer?.id ?? null, customerName: customer?.name ?? null, mechanicId: null, mechanicName: null,
      discount: 0, id, parkedAt: iso(lastMs),
    });
  }

  // ── export, in SnapshotRepository.exportSnapshot()'s shape and order ──
  const byDateDesc = <T>(key: (x: T) => number) => (a: T, b: T) => key(b) - key(a);
  const exportedAt = lastMs + 60_000;
  const saProducts = live(products).map((p) => ({
    // exportSnapshot() writes `category` always and `zone` when set; a file from the old JS
    // app carries `zone` alone. Half of the zoned products take each shape.
    id: p.id, partNo: p.partNo, name: p.name, nameTH: p.nameTH,
    ...(p.zone && p.partNo.charCodeAt(p.partNo.length - 1) % 2 === 0 ? {} : { category: p.category }),
    ...(p.zone ? { zone: p.zone } : {}),
    brand: p.brand, price: p.price, cost: p.cost, stock: p.stock, minStock: p.minStock,
    ...(p.compat !== undefined ? { compat: p.compat } : {}), updatedAt: iso(p.updatedAt),
  }));
  const saCategories = profile === 'realistic' ? CATEGORIES.filter((c) => c !== 'ยาง') : CATEGORIES;
  const settings = {
    shopName: 'ร้านอะไหล่ตัวอย่าง (ข้อมูลสังเคราะห์)', shopNameEN: 'Synthetic Demo Autoparts', taxRate: 7, quoteValidDays: 30,
    address: 'เลขที่ 0 ถนนสมมติ ตำบลทดสอบ', phone: '02-000-0000', cashierName: 'แคชเชียร์ทดสอบ', taxId: '0000000000000',
    branchNo: null, updatedAt: iso(START_UTC),
  };
  const shiftJson = (s: Shift) => ({
    date: s.date, startingCash: s.startingCash, openedAt: iso(s.openedAt), closedAt: iso(s.closedAt), physicalCash: s.physicalCash,
    ...(s.autoArchived ? { autoArchived: true } : {}), ...(s.archivedAt != null ? { archivedAt: iso(s.archivedAt) } : {}),
    entries: [...s.entries].sort(byDateDesc((e) => e.createdAt)).map((e) => ({ ...e, createdAt: iso(e.createdAt) })),
  });
  const active = shifts.find((s) => s.isActive);
  const history = shifts.filter((s) => !s.isActive).sort(byDateDesc((s) => s.openedAt)).map(shiftJson);

  const data: Json = {
    sa_products: saProducts,
    sa_customers: live(customers).map(({ deleted: _d, updatedAt, deletedAt, ...c }) => ({
      ...c, ...(updatedAt ? { updatedAt: iso(updatedAt) } : {}), ...(deletedAt ? { deletedAt: iso(deletedAt) } : {}),
    })),
    sa_sales: [...sales].sort(byDateDesc((s) => s.date)).map((s) => ({
      ...s, date: iso(s.date), ...(s.voidedAt != null ? { voidedAt: iso(s.voidedAt) } : {}),
      // Bills from the first five days predate Drift schema v2's `costAtSale`: the export
      // omits `cost`, and the server must cost them later (ADR-0008 estimated/unknown rows).
      ...(s.date < START_UTC + 5 * 86400_000 ? { items: s.items.map(({ cost: _c, ...i }) => i) } : {}),
      // JS bills often carry an explicit null rather than omitting the key.
      ...(s.customerId == null && s.mechanicId == null && s.receiptNo.endsWith('0') ? { customerId: null } : {}),
    })),
    sa_pos: [...pos].sort(byDateDesc((p) => p.createdAt as number)).map((p) => ({
      ...p, createdAt: iso(p.createdAt as number),
      ...(p.receivedAt != null ? { receivedAt: iso(p.receivedAt as number) } : {}),
      ...(p.cancelledAt != null ? { cancelledAt: iso(p.cancelledAt as number) } : {}),
    })),
    sa_settings: settings,
    sa_mechanics: live(mechanics).map(({ deleted: _d, updatedAt, deletedAt, ...m }) => ({
      ...m, ...(updatedAt ? { updatedAt: iso(updatedAt) } : {}), ...(deletedAt ? { deletedAt: iso(deletedAt) } : {}),
    })),
    sa_quotes: [...quotes].sort(byDateDesc((q) => q.date as number)).map((q) => ({
      ...q, date: iso(q.date as number), validUntil: iso(q.validUntil as number),
      ...(q.convertedAt != null ? { convertedAt: iso(q.convertedAt as number) } : {}),
    })),
    sa_returns: [...returns].sort(byDateDesc((r) => r.date as number)).map((r) => ({ ...r, date: iso(r.date as number) })),
    sa_movements: [...movements].sort(byDateDesc((m) => m.date as number)).map((m) => ({ ...m, date: iso(m.date as number) })),
    sa_suppliers: suppliers,
    sa_categories: saCategories,
    sa_credit_payments: [...creditPayments].sort(byDateDesc((p) => p.date as number)).map((p) => ({ ...p, date: iso(p.date as number) })),
    sa_cash_drawer: active ? shiftJson(active) : null,
    sa_shift_history: history,
    sa_parked: [...parked].reverse(),
    sa_schema_version: '6', // the Drift schema version the shop's build is on
  };
  const len = (k: string) => (data[k] as unknown[]).length;
  data.__meta = {
    version: 2, schemaVersion: 6, exportedAt: iso(exportedAt), shopName: settings.shopName,
    synthetic: { generator: 'server/test/fixtures/synthetic-snapshot.ts', seed, scale: options.scale ?? 'small', profile },
    recordCounts: {
      products: len('sa_products'), customers: len('sa_customers'), sales: len('sa_sales'), purchaseOrders: len('sa_pos'),
      movements: len('sa_movements'), suppliers: len('sa_suppliers'), mechanics: len('sa_mechanics'), quotes: len('sa_quotes'),
      returns: len('sa_returns'), creditPayments: len('sa_credit_payments'), shiftHistory: len('sa_shift_history'),
      parked: len('sa_parked'), categories: len('sa_categories'), cashDrawer: active ? 1 : 0,
    },
  };
  return data;
}

// ── CLI ────────────────────────────────────────────────────────────────────────
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const arg = (name: string) => {
    const i = process.argv.indexOf(`--${name}`);
    return i > 0 ? process.argv[i + 1] : undefined;
  };
  const snapshot = generateSyntheticSnapshot({
    seed: arg('seed') ? Number(arg('seed')) : undefined,
    scale: arg('scale') as Scale | undefined,
    profile: arg('profile') as Profile | undefined,
  });
  const json = JSON.stringify(snapshot);
  const out = arg('out');
  if (out) {
    writeFileSync(out, `${json}\n`);
    process.stderr.write(`wrote ${out} (${(json.length / 1024).toFixed(0)} KiB) ${JSON.stringify((snapshot.__meta as Json).recordCounts)}\n`);
  } else {
    process.stdout.write(`${json}\n`);
  }
}
