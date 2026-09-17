import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedMechanic,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// #27 acceptance suite: quotes and parked sales. The rule both share — they never
// touch stock — is asserted against the `products` and `movements` tables directly,
// across the whole lifecycle, not inferred from a response.
const TENANT = '27272727-2727-4727-8727-272727272727';
const OTHER = '72727272-2727-4727-8727-727272727272';
const P1 = 'p-quote-1';
const P2 = 'p-quote-2';
const DAY_MS = 86_400_000;

describe('quotes and parked sales (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let posToken: string;
  let backofficeToken: string;
  let otherPosToken: string;
  let keySeq = 0;

  const key = () => `k27-${++keySeq}-${Date.now()}`;
  const http = () => request(app.getHttpServer());

  const quoteBody = (over: Record<string, unknown> = {}) => ({
    subtotal: '250.00',
    discount: '10.00',
    total: '240.00',
    customerName: 'คุณสมศรี',
    customerPhone: '0812345678',
    items: [
      { productId: P1, name: 'ผ้าเบรกหน้า', qty: 2, price: '100.00' },
      { productId: P2, name: 'หัวเทียน', qty: 1, price: '50.00' },
    ],
    ...over,
  });

  const createQuote = (
    body: unknown = quoteBody(),
    opts: { token?: string; key?: string } = {},
  ) =>
    http()
      .post('/api/v1/quotes')
      .set('Authorization', `Bearer ${opts.token ?? posToken}`)
      .set('Idempotency-Key', opts.key ?? key())
      .send(body as object);

  const convert = (
    id: string,
    body: Record<string, unknown>,
    opts: { token?: string; key?: string } = {},
  ) =>
    http()
      .post(`/api/v1/quotes/${id}/convert`)
      .set('Authorization', `Bearer ${opts.token ?? posToken}`)
      .set('Idempotency-Key', opts.key ?? key())
      .send(body);

  const park = (
    payload: unknown,
    opts: { token?: string; key?: string } = {},
  ) =>
    http()
      .post('/api/v1/parked-sales')
      .set('Authorization', `Bearer ${opts.token ?? posToken}`)
      .set('Idempotency-Key', opts.key ?? key())
      .send({ payload });

  const unpark = (id: string, opts: { token?: string; key?: string } = {}) =>
    http()
      .delete(`/api/v1/parked-sales/${id}`)
      .set('Authorization', `Bearer ${opts.token ?? posToken}`)
      .set('Idempotency-Key', opts.key ?? key());

  /** Every product's stock and the ledger's size — what "untouched" means. */
  const stockState = async () => ({
    products: (await admin.query(
      `SELECT id, stock FROM products WHERE tenant_id = $1::uuid ORDER BY id`,
      [TENANT],
    )) as { id: string; stock: number }[],
    movements: Number(
      (
        await admin.query(
          `SELECT count(*)::int AS n FROM movements WHERE tenant_id = $1::uuid`,
          [TENANT],
        )
      )[0].n,
    ),
  });

  const quoteRow = async (id: string) =>
    (
      await admin.query(
        `SELECT status, converted_at, converted_sale_id FROM quotes
          WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT, id],
      )
    )[0] as
      | {
          status: string;
          converted_at: Date | null;
          converted_sale_id: string | null;
        }
      | undefined;

  const saleCount = async () =>
    Number(
      (
        await admin.query(
          `SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid`,
          [TENANT],
        )
      )[0].n,
    );

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 7, cache });
    const other = await resetTenant(admin, OTHER, { posDeviceNo: 3, cache });
    await seedProduct(admin, TENANT, {
      id: P1,
      partNo: 'BRK-27',
      name: 'ผ้าเบรกหน้า',
      price: 100,
      cost: 60,
      stock: 10,
    });
    await seedProduct(admin, TENANT, {
      id: P2,
      partNo: 'SPK-27',
      name: 'หัวเทียน',
      price: 50,
      cost: 30,
      stock: 5,
    });
    await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
      userId: fixture.userId,
    });
    posToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
    backofficeToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
    otherPosToken = accessToken({
      tenantId: OTHER,
      userId: other.userId,
      role: 'owner',
      deviceId: other.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    for (const t of [TENANT, OTHER]) {
      await resetTenant(admin, t);
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [t]);
    }
    await app.close();
  });

  // ── AC1 ─────────────────────────────────────────────────────────────────────
  describe('AC1: create, edit, duplicate and delete leave stock untouched', () => {
    it('runs the whole lifecycle with every product and the ledger unchanged', async () => {
      const before = await stockState();

      const created = await createQuote();
      expect(created.status).toBe(201);
      const q = created.body.data;
      expect(q.id).toMatch(/^q/);
      expect(q.quoteNo).toMatch(/^QT07-\d{4}-\d{2}-0001$/);
      expect(q.status).toBe('open');
      expect(q.isConverted).toBe(false);
      expect(q.isExpired).toBe(false);
      expect(q.total).toBe('240.00');
      expect(q.items).toEqual([
        {
          lineNo: 1,
          productId: P1,
          name: 'ผ้าเบรกหน้า',
          qty: 2,
          price: '100.00',
        },
        { lineNo: 2, productId: P2, name: 'หัวเทียน', qty: 1, price: '50.00' },
      ]);
      // `saveQuote`: `validDays ?? 30`, as milliseconds — not the settings row.
      expect(Date.parse(q.validUntil) - Date.parse(q.date)).toBe(30 * DAY_MS);
      expect(q.validDays).toBeNull();
      expect(await stockState()).toEqual(before);

      const edited = await http()
        .patch(`/api/v1/quotes/${q.id}`)
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', key())
        .send({ notes: 'ส่งภายในสัปดาห์', customerName: 'คุณสมชาย' });
      expect(edited.status).toBe(200);
      expect(edited.body.data.notes).toBe('ส่งภายในสัปดาห์');
      expect(edited.body.data.customerName).toBe('คุณสมชาย');
      expect(await stockState()).toEqual(before);

      const dup = await http()
        .post(`/api/v1/quotes/${q.id}/duplicate`)
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', key());
      expect(dup.status).toBe(201);
      expect(dup.body.data.id).not.toBe(q.id);
      expect(dup.body.data.quoteNo).toMatch(/^QT07-\d{4}-\d{2}-0002$/);
      expect(dup.body.data.status).toBe('open');
      expect(dup.body.data.items).toEqual(q.items);
      expect(dup.body.data.notes).toBe('ส่งภายในสัปดาห์');
      expect(await stockState()).toEqual(before);

      for (const id of [q.id, dup.body.data.id]) {
        const del = await http()
          .delete(`/api/v1/quotes/${id}`)
          .set('Authorization', `Bearer ${posToken}`)
          .set('Idempotency-Key', key());
        expect(del.status).toBe(200);
        expect(del.body.data).toEqual({ id, deleted: true });
      }
      const gone = await http()
        .get(`/api/v1/quotes/${q.id}`)
        .set('Authorization', `Bearer ${posToken}`);
      expect(gone.status).toBe(404);
      expect(gone.body.error.code).toBe('QUOTE_NOT_FOUND');
      expect(
        (
          await admin.query(
            `SELECT 1 FROM quote_items WHERE tenant_id = $1::uuid`,
            [TENANT],
          )
        ).length,
      ).toBe(0);
      expect(await stockState()).toEqual(before);
    });

    it('a quote may name more than the shelf holds — it reserves nothing', async () => {
      const before = await stockState();
      const res = await createQuote(
        quoteBody({
          subtotal: '5000.00',
          discount: '0.00',
          total: '5000.00',
          items: [
            { productId: P1, name: 'ผ้าเบรกหน้า', qty: 50, price: '100.00' },
          ],
        }),
      );
      expect(res.status).toBe(201);
      expect(await stockState()).toEqual(before);
    });

    it('a backoffice device may write quotes (ADR-0004: no stock, no money)', async () => {
      const res = await createQuote(quoteBody(), { token: backofficeToken });
      expect(res.status).toBe(201);
      expect(res.body.data.quoteNo).toMatch(/^QT57-/);
    });

    it('a session with no device token cannot issue a QT number', async () => {
      const token = accessToken({ tenantId: TENANT, userId: fixture.userId });
      const res = await createQuote(quoteBody(), { token });
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
    });

    it('stores validDays and counts validUntil from it; a duplicate keeps it', async () => {
      const res = await createQuote(quoteBody({ validDays: 7 }));
      expect(res.body.data.validDays).toBe(7);
      expect(
        Date.parse(res.body.data.validUntil) - Date.parse(res.body.data.date),
      ).toBe(7 * DAY_MS);
      const dup = await http()
        .post(`/api/v1/quotes/${res.body.data.id}/duplicate`)
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', key());
      expect(
        Date.parse(dup.body.data.validUntil) - Date.parse(dup.body.data.date),
      ).toBe(7 * DAY_MS);
    });

    it('an idempotent replay of POST /quotes answers the same quote and writes one row', async () => {
      const k = key();
      const first = await createQuote(quoteBody(), { key: k });
      const again = await createQuote(quoteBody(), { key: k });
      expect(again.status).toBe(201);
      expect(again.body).toEqual(first.body);
      const rows = await admin.query(
        `SELECT id FROM quotes WHERE tenant_id = $1::uuid`,
        [TENANT],
      );
      expect(rows).toHaveLength(1);
    });

    it('validates before storing: bad money, a converted status, a total that does not add up', async () => {
      expect(
        (
          await createQuote(
            quoteBody({
              items: [{ productId: P1, name: 'x', qty: 1, price: '-5.00' }],
            }),
          )
        ).status,
      ).toBe(400);
      expect(
        (await createQuote(quoteBody({ status: 'converted' }))).status,
      ).toBe(400);
      expect((await createQuote(quoteBody({ items: [] }))).status).toBe(400);
      expect((await createQuote(quoteBody({ validDays: 0 }))).status).toBe(400);
      const mismatch = await createQuote(quoteBody({ total: '999.00' }));
      expect(mismatch.status).toBe(409);
      expect(mismatch.body.error.code).toBe('TOTAL_MISMATCH');
      expect(
        await admin.query(`SELECT 1 FROM quotes WHERE tenant_id = $1::uuid`, [
          TENANT,
        ]),
      ).toHaveLength(0);
    });

    it('PATCH refuses status, lines and money, and any edit to a converted quote', async () => {
      const q = (await createQuote()).body.data;
      for (const body of [
        { status: 'converted' },
        { total: '1.00' },
        { items: [] },
      ]) {
        const res = await http()
          .patch(`/api/v1/quotes/${q.id}`)
          .set('Authorization', `Bearer ${posToken}`)
          .set('Idempotency-Key', key())
          .send(body);
        expect(res.status).toBe(400);
      }
      expect((await quoteRow(q.id))!.status).toBe('open');

      await convert(q.id, { id: 'sale-27-patch', paymentMethod: 'เงินสด' });
      const res = await http()
        .patch(`/api/v1/quotes/${q.id}`)
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', key())
        .send({ notes: 'แก้หลังขาย' });
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('QUOTE_ALREADY_CONVERTED');
      expect(res.body.error.details.convertedSaleId).toBe('sale-27-patch');

      const missing = await http()
        .patch('/api/v1/quotes/q-nope')
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', key())
        .send({ notes: 'x' });
      expect(missing.status).toBe(404);
    });
  });

  // ── AC5 ─────────────────────────────────────────────────────────────────────
  describe('AC5: expiry follows QuoteRowStatus exactly', () => {
    const setValidUntil = (id: string, sql: string) =>
      admin.query(
        `UPDATE quotes SET valid_until = ${sql} WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT, id],
      );
    const list = async (status?: string) =>
      (
        await http()
          .get(`/api/v1/quotes${status ? `?status=${status}` : ''}`)
          .set('Authorization', `Bearer ${backofficeToken}`)
      ).body.data.map((q: { id: string }) => q.id) as string[];

    it('isExpired is validUntil < now, on any status; the filters are _applyFilter', async () => {
      const open = (await createQuote()).body.data.id;
      const expired = (await createQuote()).body.data.id;
      const convertedExpired = (await createQuote()).body.data.id;
      // `isBefore(now)` is strict: a quote valid until a moment from now is still open.
      await setValidUntil(open, `now() + interval '1 minute'`);
      await setValidUntil(expired, `now() - interval '1 second'`);
      expect(
        (
          await convert(convertedExpired, {
            id: 'sale-27-exp',
            paymentMethod: 'เงินสด',
          })
        ).status,
      ).toBe(201);
      await setValidUntil(convertedExpired, `now() - interval '1 day'`);

      const get = async (id: string) =>
        (
          await http()
            .get(`/api/v1/quotes/${id}`)
            .set('Authorization', `Bearer ${posToken}`)
        ).body.data;
      expect((await get(open)).isExpired).toBe(false);
      expect((await get(expired)).isExpired).toBe(true);
      // Stored status is never rewritten: the flag is computed, not persisted.
      expect((await get(expired)).status).toBe('open');
      const ce = await get(convertedExpired);
      expect(ce.isExpired).toBe(true);
      expect(ce.isConverted).toBe(true);

      expect((await list()).sort()).toEqual(
        [open, expired, convertedExpired].sort(),
      );
      expect(await list('open')).toEqual([open]);
      expect(await list('expired')).toEqual([expired]);
      expect(await list('converted')).toEqual([convertedExpired]);
      expect(
        (
          await http()
            .get('/api/v1/quotes?status=bogus')
            .set('Authorization', `Bearer ${posToken}`)
        ).status,
      ).toBe(400);
    });
  });

  // ── AC3 ─────────────────────────────────────────────────────────────────────
  describe('AC3: convert sells through the sale path and marks the quote', () => {
    it('writes a bill with a receipt number, deducts stock, and marks the quote converted', async () => {
      const q = (await createQuote()).body.data;
      const res = await convert(q.id, {
        id: 'sale-27-convert',
        paymentMethod: 'เงินสด',
      });
      expect(res.status).toBe(201);
      const { sale, quote } = res.body.data;
      expect(sale.id).toBe('sale-27-convert');
      expect(sale.receiptNo).toMatch(/^RC07-\d{4}-\d{2}-0001$/);
      expect(sale.total).toBe('240.00');
      expect(sale.pointsGranted).toBe(24);
      expect(sale.products).toEqual([
        { id: P1, stock: 8 },
        { id: P2, stock: 4 },
      ]);
      expect(
        sale.movements.map((m: { type: string; delta: number }) => [
          m.type,
          m.delta,
        ]),
      ).toEqual([
        ['sale', -2],
        ['sale', -1],
      ]);
      expect(quote.status).toBe('converted');
      expect(quote.isConverted).toBe(true);
      expect(quote.convertedSaleId).toBe('sale-27-convert');
      expect(quote.convertedAt).not.toBeNull();

      const stored = await admin.query(
        `SELECT receipt_no, subtotal, discount, total, payment_method, shift_id
           FROM sales WHERE tenant_id = $1::uuid AND id = 'sale-27-convert'`,
        [TENANT],
      );
      expect(stored[0]).toMatchObject({
        receipt_no: sale.receiptNo,
        subtotal: '250.00',
        discount: '10.00',
        total: '240.00',
        payment_method: 'เงินสด',
      });
      expect(stored[0].shift_id).not.toBeNull();
      const row = await quoteRow(q.id);
      expect(row!.status).toBe('converted');
      expect(row!.converted_sale_id).toBe('sale-27-convert');
      expect((await stockState()).products).toEqual([
        { id: P1, stock: 8 },
        { id: P2, stock: 4 },
      ]);
    });

    it('is pos only', async () => {
      const q = (await createQuote()).body.data;
      const res = await convert(
        q.id,
        { id: 'sale-27-bo', paymentMethod: 'เงินสด' },
        { token: backofficeToken },
      );
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
      expect((await quoteRow(q.id))!.status).toBe('open');
    });

    it("refuses lines or money in the body — they are the quote's", async () => {
      const q = (await createQuote()).body.data;
      const res = await convert(q.id, {
        id: 'sale-27-items',
        paymentMethod: 'เงินสด',
        total: '1.00',
      });
      expect(res.status).toBe(400);
      expect(await saleCount()).toBe(0);
    });

    it('a refusal on the sale path leaves the quote open and stock untouched', async () => {
      const short = (
        await createQuote(
          quoteBody({
            subtotal: '2000.00',
            discount: '0.00',
            total: '2000.00',
            items: [
              { productId: P1, name: 'ผ้าเบรกหน้า', qty: 20, price: '100.00' },
            ],
          }),
        )
      ).body.data;
      const before = await stockState();
      const res = await convert(short.id, {
        id: 'sale-27-short',
        paymentMethod: 'เงินสด',
      });
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('INSUFFICIENT_STOCK');
      expect(res.body.error.message).toBe(
        'สต็อกไม่พอ:\nผ้าเบรกหน้า: สต็อก 10 แต่ต้องการ 20',
      );
      expect((await quoteRow(short.id))!.status).toBe('open');
      expect(await stockState()).toEqual(before);

      // A line with no catalogue product reads as the sale path's own "not in stock".
      const loose = (
        await createQuote(
          quoteBody({
            subtotal: '80.00',
            discount: '0.00',
            total: '80.00',
            items: [{ name: 'ของสั่งพิเศษ', qty: 1, price: '80.00' }],
          }),
        )
      ).body.data;
      const res2 = await convert(loose.id, {
        id: 'sale-27-loose',
        paymentMethod: 'เงินสด',
      });
      expect(res2.status).toBe(409);
      expect(res2.body.error.message).toBe(
        'สต็อกไม่พอ:\nของสั่งพิเศษ: ไม่พบในสต็อก',
      );
      expect((await quoteRow(loose.id))!.status).toBe('open');
    });

    it('over the credit limit: 409 with nothing written; the same key with the flag converts once and audits once (#21)', async () => {
      await seedMechanic(admin, TENANT, {
        id: 'm-27',
        code: 'M27',
        name: 'ช่างสมชาย',
        creditLimit: 100,
      });
      const q = (await createQuote()).body.data;
      const party = {
        id: 'sale-27-credit',
        paymentMethod: 'เครดิตช่าง',
        mechanicId: 'm-27',
        mechanicName: 'ช่างสมชาย',
      };
      const before = await stockState();
      const auditRows = () =>
        admin.query(
          `SELECT action, entity_id FROM audit_log
            WHERE tenant_id = $1::uuid AND action = 'sale.credit_limit_override'`,
          [TENANT],
        );
      const k = key();

      const refused = await convert(q.id, party, { key: k });
      expect(refused.status).toBe(409);
      expect(refused.body.error.code).toBe('CREDIT_LIMIT_EXCEEDED');
      expect(await stockState()).toEqual(before);
      expect(await saleCount()).toBe(0);
      expect(await auditRows()).toHaveLength(0);
      expect((await quoteRow(q.id))!.status).toBe('open');

      // The counter resends the SAME key with the confirmation: the refused claim
      // rolled back with its transaction, so the key is free for the new body.
      const confirmed = await convert(
        q.id,
        { ...party, overrideCreditLimit: true },
        { key: k },
      );
      expect(confirmed.status).toBe(201);
      expect(confirmed.body.data.sale.mechanicCreditBalanceAfter).toBe(
        '240.00',
      );
      expect(await saleCount()).toBe(1);
      expect(await auditRows()).toEqual([
        { action: 'sale.credit_limit_override', entity_id: 'm-27' },
      ]);
      const row = await quoteRow(q.id);
      expect(row!.status).toBe('converted');
      expect(row!.converted_sale_id).toBe('sale-27-credit');
    });

    it('eligibility is !converted && !expired, not the status string (quotes_screen.dart:559)', async () => {
      const valid = (await createQuote()).body.data;
      const stale = (await createQuote()).body.data;
      // Imported rows may carry a status the app never writes.
      await admin.query(
        `UPDATE quotes SET status = 'cancelled' WHERE tenant_id = $1::uuid AND id = ANY($2)`,
        [TENANT, [valid.id, stale.id]],
      );
      await admin.query(
        `UPDATE quotes SET valid_until = now() - interval '1 second'
          WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT, stale.id],
      );

      const ok = await convert(valid.id, {
        id: 'sale-27-cancelled',
        paymentMethod: 'เงินสด',
      });
      expect(ok.status).toBe(201);
      expect(ok.body.data.quote.status).toBe('converted');

      const refused = await convert(stale.id, {
        id: 'sale-27-cancelled-stale',
        paymentMethod: 'เงินสด',
      });
      expect(refused.status).toBe(409);
      expect(refused.body.error.code).toBe('QUOTE_EXPIRED');
      expect((await quoteRow(stale.id))!.status).toBe('cancelled');
    });

    it('no open drawer: NO_OPEN_SHIFT, the quote stays open', async () => {
      const q = (await createQuote()).body.data;
      await admin.query(`DELETE FROM shifts WHERE tenant_id = $1::uuid`, [
        TENANT,
      ]);
      const res = await convert(q.id, {
        id: 'sale-27-noshift',
        paymentMethod: 'เงินสด',
      });
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('NO_OPEN_SHIFT');
      expect((await quoteRow(q.id))!.status).toBe('open');
    });

    it('refuses a bill id another sale already holds, rather than claiming that bill', async () => {
      const first = (await createQuote()).body.data;
      const second = (await createQuote()).body.data;
      expect(
        (
          await convert(first.id, {
            id: 'sale-27-taken',
            paymentMethod: 'เงินสด',
          })
        ).status,
      ).toBe(201);
      const res = await convert(second.id, {
        id: 'sale-27-taken',
        paymentMethod: 'เงินสด',
      });
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('SALE_ID_REUSED');
      expect((await quoteRow(second.id))!.status).toBe('open');
    });
  });

  // ── Converting an expired quote ─────────────────────────────────────────────
  it('an expired quote is refused and nothing is written', async () => {
    const q = (await createQuote()).body.data;
    await admin.query(
      `UPDATE quotes SET valid_until = now() - interval '1 second'
        WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, q.id],
    );
    const before = await stockState();
    const res = await convert(q.id, {
      id: 'sale-27-expired',
      paymentMethod: 'เงินสด',
    });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('QUOTE_EXPIRED');
    expect(await stockState()).toEqual(before);
    expect(await saleCount()).toBe(0);
    expect((await quoteRow(q.id))!.status).toBe('open');
    // Refused before the receipt counter: the next bill still takes 0001.
    const ok = await convert((await createQuote()).body.data.id, {
      id: 'sale-27-after-expired',
      paymentMethod: 'เงินสด',
    });
    expect(ok.body.data.sale.receiptNo).toMatch(/-0001$/);
  });

  // ── AC4 ─────────────────────────────────────────────────────────────────────
  describe('AC4: converting the same quote twice does not produce two bills', () => {
    it('the same Idempotency-Key replays the identical body', async () => {
      const q = (await createQuote()).body.data;
      const k = key();
      const first = await convert(
        q.id,
        { id: 'sale-27-k', paymentMethod: 'เงินสด' },
        { key: k },
      );
      const again = await convert(
        q.id,
        { id: 'sale-27-k', paymentMethod: 'เงินสด' },
        { key: k },
      );
      expect(again.status).toBe(201);
      expect(again.body).toEqual(first.body);
      expect(await saleCount()).toBe(1);
    });

    it('a retry with a fresh key and the same bill id answers the original bill and quote', async () => {
      const q = (await createQuote()).body.data;
      const first = await convert(q.id, {
        id: 'sale-27-retry',
        paymentMethod: 'เงินสด',
      });
      const retry = await convert(q.id, {
        id: 'sale-27-retry',
        paymentMethod: 'เงินสด',
      });
      expect(retry.status).toBe(201);
      // The whole body: anything the convert result carries must come back on replay.
      expect(retry.body).toEqual(first.body);
      expect(await saleCount()).toBe(1);
      expect((await stockState()).products).toEqual([
        { id: P1, stock: 8 },
        { id: P2, stock: 4 },
      ]);
    });

    it('a second bill id is QUOTE_ALREADY_CONVERTED — even after the quote expires', async () => {
      const q = (await createQuote()).body.data;
      await convert(q.id, { id: 'sale-27-once', paymentMethod: 'เงินสด' });
      const res = await convert(q.id, {
        id: 'sale-27-twice',
        paymentMethod: 'เงินสด',
      });
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('QUOTE_ALREADY_CONVERTED');
      expect(res.body.error.details.convertedSaleId).toBe('sale-27-once');

      // The retry of the real bill still replays once the validity has passed.
      await admin.query(
        `UPDATE quotes SET valid_until = now() - interval '1 day'
          WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT, q.id],
      );
      const late = await convert(q.id, {
        id: 'sale-27-once',
        paymentMethod: 'เงินสด',
      });
      expect(late.status).toBe(201);
      expect(late.body.data.sale.id).toBe('sale-27-once');
      expect(await saleCount()).toBe(1);
    });

    it('two concurrent converts with different bill ids: one bill, one refusal', async () => {
      const q = (await createQuote()).body.data;
      const [a, b] = await Promise.all([
        convert(q.id, { id: 'sale-27-race-a', paymentMethod: 'เงินสด' }),
        convert(q.id, { id: 'sale-27-race-b', paymentMethod: 'เงินสด' }),
      ]);
      expect([a.status, b.status].sort()).toEqual([201, 409]);
      const refused = a.status === 409 ? a : b;
      expect(refused.body.error.code).toBe('QUOTE_ALREADY_CONVERTED');
      expect(await saleCount()).toBe(1);
      expect((await stockState()).products).toEqual([
        { id: P1, stock: 8 },
        { id: P2, stock: 4 },
      ]);
    });
  });

  // ── AC2 ─────────────────────────────────────────────────────────────────────
  describe('AC2: parking and unparking leaves stock untouched', () => {
    const cart = {
      items: [{ productId: P1, name: 'ผ้าเบรกหน้า', qty: 3, price: 100 }],
      customerId: null,
      mechanicId: null,
      discount: 0,
    };

    it('parks, lists newest first, recalls with the payload, and moves no stock', async () => {
      const before = await stockState();
      const first = await park(cart);
      expect(first.status).toBe(201);
      expect(first.body.data.id).toMatch(/^pk/);
      expect(first.body.data.deviceId).toBe(fixture.posDeviceId);
      expect(first.body.data.payload).toEqual(cart);
      const second = await park({ ...cart, discount: 5 });
      expect(await stockState()).toEqual(before);

      const list = await http()
        .get('/api/v1/parked-sales')
        .set('Authorization', `Bearer ${posToken}`);
      expect(list.status).toBe(200);
      expect(list.body.data.map((p: { id: string }) => p.id)).toEqual([
        second.body.data.id,
        first.body.data.id,
      ]);

      const recalled = await unpark(first.body.data.id);
      expect(recalled.status).toBe(200);
      expect(recalled.body.data).toEqual(first.body.data);
      expect(await stockState()).toEqual(before);
    });

    it('a double recall: the second is 404, a same-key retry replays the first', async () => {
      const parked = (await park(cart)).body.data;
      const k = key();
      const first = await unpark(parked.id, { key: k });
      expect(first.status).toBe(200);
      const retry = await unpark(parked.id, { key: k });
      expect(retry.status).toBe(200);
      expect(retry.body).toEqual(first.body);
      const second = await unpark(parked.id);
      expect(second.status).toBe(404);
      expect(second.body.error.code).toBe('PARKED_SALE_NOT_FOUND');
    });

    it('two tills recalling the same bill at once: exactly one gets it', async () => {
      const parked = (await park(cart)).body.data;
      const [a, b] = await Promise.all([unpark(parked.id), unpark(parked.id)]);
      expect([a.status, b.status].sort()).toEqual([200, 404]);
    });

    it('is pos only, reads included', async () => {
      const parked = (await park(cart)).body.data;
      const denied = [
        await http()
          .get('/api/v1/parked-sales')
          .set('Authorization', `Bearer ${backofficeToken}`),
        await park(cart, { token: backofficeToken }),
        await unpark(parked.id, { token: backofficeToken }),
      ];
      for (const res of denied) {
        expect(res.status).toBe(403);
        expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
      }
    });

    it('refuses a payload that is not an object', async () => {
      for (const payload of [null, [], 'cart']) {
        expect((await park(payload)).status).toBe(400);
      }
    });
  });

  // ── Tenancy ─────────────────────────────────────────────────────────────────
  describe('cross-tenant access', () => {
    it("another shop cannot read, edit, delete, duplicate or convert this shop's quote", async () => {
      const q = (await createQuote()).body.data;
      const auth = `Bearer ${otherPosToken}`;
      const list = await http()
        .get('/api/v1/quotes')
        .set('Authorization', auth);
      expect(list.body.data).toEqual([]);
      const attempts = [
        await http().get(`/api/v1/quotes/${q.id}`).set('Authorization', auth),
        await http()
          .patch(`/api/v1/quotes/${q.id}`)
          .set('Authorization', auth)
          .set('Idempotency-Key', key())
          .send({ notes: 'x' }),
        await http()
          .delete(`/api/v1/quotes/${q.id}`)
          .set('Authorization', auth)
          .set('Idempotency-Key', key()),
        await http()
          .post(`/api/v1/quotes/${q.id}/duplicate`)
          .set('Authorization', auth)
          .set('Idempotency-Key', key()),
        await convert(
          q.id,
          { id: 'sale-27-xt', paymentMethod: 'เงินสด' },
          { token: otherPosToken },
        ),
      ];
      for (const res of attempts) {
        expect(res.status).toBe(404);
        expect(res.body.error.code).toBe('QUOTE_NOT_FOUND');
      }
      expect((await quoteRow(q.id))!.status).toBe('open');
      expect(
        await admin.query(`SELECT 1 FROM quotes WHERE tenant_id = $1::uuid`, [
          OTHER,
        ]),
      ).toHaveLength(0);
    });

    it("another shop cannot see or recall this shop's parked bill", async () => {
      const parked = (await park({ items: [] })).body.data;
      const list = await http()
        .get('/api/v1/parked-sales')
        .set('Authorization', `Bearer ${otherPosToken}`);
      expect(list.body.data).toEqual([]);
      const res = await unpark(parked.id, { token: otherPosToken });
      expect(res.status).toBe(404);
      expect(
        await admin.query(
          `SELECT 1 FROM parked_sales WHERE tenant_id = $1::uuid AND id = $2`,
          [TENANT, parked.id],
        ),
      ).toHaveLength(1);
    });
  });
});
