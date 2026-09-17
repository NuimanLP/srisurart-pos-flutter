import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedMechanic,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// #30 acceptance suite: `GET /reports/closing?shiftId=` and gross profit (ADR-0008).
// Rows are seeded rather than posted, because the point of AC2 is timestamps on both
// sides of midnight, which a live request cannot choose.
const TENANT = 'c3030303-3030-4030-8030-c30303030303';
const OTHER = 'c3131313-3131-4131-8131-c31313131313';

describe('closing report and gross profit (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let token: string;

  const get = (path: string) =>
    request(app.getHttpServer())
      .get(`/api/v1/reports${path}`)
      .set({ Authorization: `Bearer ${token}` });

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
    fixture = await resetTenant(admin, TENANT, { cache });
    await resetTenant(admin, OTHER, { cache });
    // A backoffice machine: the report is a read, and reading does not touch the drawer.
    token = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
    await seed();
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await resetTenant(admin, OTHER);
    await admin.query(`DELETE FROM tenants WHERE id IN ($1::uuid, $2::uuid)`, [
      TENANT,
      OTHER,
    ]);
    await app.close();
  });

  /*
   * Hand computation for shift `sh-night` (22:00 on 10 Sep → 02:00 on 11 Sep, Bangkok):
   *
   *   starting cash                                          1000.00
   *   + cash sales      S1 200 + S3 330 + S6 100             + 630.00
   *                     (S2 is โอน/QR, S5 เครดิตช่าง, S4 manually voided,
   *                      D1 is inside the time window but on another shift)
   *   + cash repayments CP1 300 (CP2 500 is โอน/QR)          + 300.00
   *   − cash refunds    R1 94.29 + R2 100 (R3 100 is โอน)    − 194.29
   *   + drawer in                                            +  50.00
   *   − drawer out                                           − 120.00
   *   = expected                                             1665.71
   *   physical 1660.00 − expected 1665.71 = variance           −5.71
   *
   * Without CP1 the expected figure would be 1365.71 and the variance +294.29. AC1 was
   * falsified that way: removing `c.cash_credit_payments` from the SQL turns this test
   * red with expectedCash 1665.71 → 1365.71.
   * S6 was auto-voided by R2 (a full return): the bill stays counted and the refund
   * subtracts, so it nets to zero rather than being taken off twice.
   */
  it('balances a shift that spans midnight, repayments included, by shift_id alone', async () => {
    const res = await get('/closing?shiftId=sh-night');
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({
      shiftId: 'sh-night',
      dateStr: '2026-09-10',
      deviceId: fixture.posDeviceId,
      openedAt: '2026-09-10T15:00:00.000Z',
      closedAt: '2026-09-10T19:00:00.000Z',
      startingCash: '1000.00',
      cashSales: '630.00',
      cashCreditPayments: '300.00',
      cashRefunds: '194.29',
      drawerIn: '50.00',
      drawerOut: '120.00',
      expectedCash: '1665.71',
      physicalCash: '1660.00',
      variance: '-5.71',
      // Every counted bill, whatever it was paid with — S1 200 + S2 250 + S3 330
      // + S5 250 + S6 100 = 1130 — less every credit note, 294.29 = 835.71;
      // ÷ 1.07 = 781.0374
      // − (sale-line cost 120 + 150 + 210 + 150 + 60 = 690 − return-line cost 180 = 510)
      // = 271.04
      grossProfit: '271.04',
      estimatedCostRows: 0,
      unknownCostRows: 0,
    });
  });

  it('leaves variance null while the shift is still open', async () => {
    const res = await get('/closing?shiftId=sh-open');
    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({
      closedAt: null,
      startingCash: '500.00',
      cashSales: '0.00',
      expectedCash: '500.00',
      physicalCash: null,
      variance: null,
      grossProfit: '0.00',
    });
  });

  it('reports estimated rows where cost_at_sale is null, and unknown ones where no cost exists', async () => {
    // `sh-legacy`: one cash bill of 400 — pA@100 costed 60 at sale, pB@250 with no
    // snapshot (today's cost 150), and a line for a product that no longer exists.
    // 400 ÷ 1.07 = 373.8318 − (60 + 150 + 0) = 163.83
    const res = await get('/closing?shiftId=sh-legacy');
    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({
      cashSales: '400.00',
      grossProfit: '163.83',
      estimatedCostRows: 1,
      unknownCostRows: 1,
    });
  });

  it('does not move profit on rows with cost_at_sale when products.cost changes afterwards', async () => {
    // New stock received at a different cost: the weighted average rewrites products.cost.
    await admin.query(
      `UPDATE products SET cost = 999 WHERE tenant_id = $1::uuid AND id IN ('pA', 'pB')`,
      [TENANT],
    );

    // Every line of sh-night carries cost_at_sale, so its profit does not move.
    const night = await get('/closing?shiftId=sh-night');
    expect(night.body.data).toMatchObject({
      grossProfit: '271.04',
      estimatedCostRows: 0,
    });

    // sh-legacy moves only by its one estimated line — which is exactly why that line
    // is flagged: 373.8318 − (60 + 999 + 0) = −685.17
    const legacy = await get('/closing?shiftId=sh-legacy');
    expect(legacy.body.data).toMatchObject({
      grossProfit: '-685.17',
      estimatedCostRows: 1,
      unknownCostRows: 1,
    });
  });

  it("answers 404 for another tenant's shift and 400 without a shiftId", async () => {
    const foreign = await get('/closing?shiftId=sh-secret');
    expect(foreign.status).toBe(404);
    expect(foreign.body.error.code).toBe('SHIFT_NOT_FOUND');

    expect((await get('/closing?shiftId=nope')).status).toBe(404);
    expect((await get('/closing')).status).toBe(400);
  });

  async function seed(): Promise<void> {
    const q = (sql: string, params: unknown[] = []) =>
      admin.query(sql, [TENANT, ...params]);
    const device = fixture.posDeviceId;

    await seedProduct(admin, TENANT, {
      id: 'pA',
      partNo: 'PA',
      name: 'Part A',
      price: 100,
      cost: 60,
      stock: 10,
    });
    await seedProduct(admin, TENANT, {
      id: 'pB',
      partNo: 'PB',
      name: 'Part B',
      price: 250,
      cost: 150,
      stock: 10,
    });
    await seedMechanic(admin, TENANT, {
      id: 'm1',
      code: 'M1',
      name: 'ช่างหนึ่ง',
      creditLimit: 10000,
    });

    await q(
      `INSERT INTO shifts (tenant_id, id, date_str, starting_cash, opened_at, closed_at,
                           physical_cash, is_active, archived_at, device_id)
       VALUES ($1::uuid, 'sh-night', '2026-09-10', 1000, '2026-09-10T22:00:00+07',
               '2026-09-11T02:00:00+07', 1660, FALSE, '2026-09-11T08:00:00+07', $2),
              ($1::uuid, 'sh-other', '2026-09-10', 0, '2026-09-10T21:00:00+07',
               '2026-09-11T03:00:00+07', 0, FALSE, '2026-09-11T08:00:00+07', 'another-till'),
              ($1::uuid, 'sh-legacy', '2026-08-05', 0, '2026-08-05T08:00:00+07',
               '2026-08-05T20:00:00+07', 400, FALSE, '2026-08-06T08:00:00+07', $2),
              ($1::uuid, 'sh-open', '2026-09-11', 500, '2026-09-11T08:00:00+07',
               NULL, NULL, TRUE, NULL, $2)`,
      [device],
    );

    await q(
      `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, discount, total,
                          payment_method, mechanic_id, date, voided, voided_at, shift_id)
       VALUES ($1::uuid, 'S1', 'RC-1', 200, 0, 200, 'เงินสด', NULL,
               '2026-09-10T23:30:00+07', FALSE, NULL, 'sh-night'),
              ($1::uuid, 'S2', 'RC-2', 250, 0, 250, 'โอน/QR', NULL,
               '2026-09-10T23:45:00+07', FALSE, NULL, 'sh-night'),
              ($1::uuid, 'S3', 'RC-3', 350, 20, 330, 'เงินสด', NULL,
               '2026-09-11T00:30:00+07', FALSE, NULL, 'sh-night'),
              ($1::uuid, 'S4', 'RC-4', 100, 0, 100, 'เงินสด', NULL,
               '2026-09-11T00:40:00+07', TRUE, '2026-09-11T00:45:00+07', 'sh-night'),
              ($1::uuid, 'S5', 'RC-5', 250, 0, 250, 'เครดิตช่าง', 'm1',
               '2026-09-11T00:55:00+07', FALSE, NULL, 'sh-night'),
              ($1::uuid, 'S6', 'RC-6', 100, 0, 100, 'เงินสด', NULL,
               '2026-09-11T01:00:00+07', TRUE, '2026-09-11T01:20:00+07', 'sh-night'),
              ($1::uuid, 'D1', 'RC-D1', 999, 0, 999, 'เงินสด', NULL,
               '2026-09-10T23:59:00+07', FALSE, NULL, 'sh-other'),
              ($1::uuid, 'I1', 'RC-I1', 400, 0, 400, 'เงินสด', NULL,
               '2026-08-05T10:00:00+07', FALSE, NULL, 'sh-legacy')`,
    );
    await q(
      `INSERT INTO sale_items (tenant_id, sale_id, line_no, product_id, part_no, name,
                               qty, price, cost_at_sale)
       VALUES ($1::uuid, 'S1', 1, 'pA', 'PA', 'Part A', 2, 100, 60),
              ($1::uuid, 'S2', 1, 'pB', 'PB', 'Part B', 1, 250, 150),
              ($1::uuid, 'S3', 1, 'pB', 'PB', 'Part B', 1, 250, 150),
              ($1::uuid, 'S3', 2, 'pA', 'PA', 'Part A', 1, 100, 60),
              ($1::uuid, 'S4', 1, 'pA', 'PA', 'Part A', 1, 100, 60),
              ($1::uuid, 'S5', 1, 'pB', 'PB', 'Part B', 1, 250, 150),
              ($1::uuid, 'S6', 1, 'pA', 'PA', 'Part A', 1, 100, 60),
              ($1::uuid, 'D1', 1, 'pA', 'PA', 'Part A', 1, 999, 60),
              ($1::uuid, 'I1', 1, 'pA', 'PA', 'Part A', 1, 100, 60),
              ($1::uuid, 'I1', 2, 'pB', 'PB', 'Part B', 1, 250, NULL),
              ($1::uuid, 'I1', 3, 'gone', 'GONE', 'Deleted part', 1, 50, NULL)`,
    );

    // R1: one pA back off S3, refunded in cash with its share of the bill discount
    // (20 × 100/350 = 5.71). R2: all of S6, which auto-voided it. R3: one pA off S1,
    // refunded by transfer.
    await q(
      `INSERT INTO returns (tenant_id, id, cn_no, sale_id, receipt_no, refund_subtotal,
                            refund_discount, refund_total, refund_method, date, shift_id)
       VALUES ($1::uuid, 'R1', 'CN-1', 'S3', 'RC-3', 100, 5.71, 94.29, 'เงินสด',
               '2026-09-11T01:10:00+07', 'sh-night'),
              ($1::uuid, 'R2', 'CN-2', 'S6', 'RC-6', 100, 0, 100, 'เงินสด',
               '2026-09-11T01:20:00+07', 'sh-night'),
              ($1::uuid, 'R3', 'CN-3', 'S1', 'RC-1', 100, 0, 100, 'โอน',
               '2026-09-11T01:40:00+07', 'sh-night')`,
    );
    await q(
      `INSERT INTO return_items (tenant_id, return_id, line_no, product_id, name, qty,
                                 price, original_qty, cost_at_sale)
       VALUES ($1::uuid, 'R1', 1, 'pA', 'Part A', 1, 100, 1, 60),
              ($1::uuid, 'R2', 1, 'pA', 'Part A', 1, 100, 1, 60),
              ($1::uuid, 'R3', 1, 'pA', 'Part A', 1, 100, 2, 60)`,
    );

    await q(
      `INSERT INTO credit_payments (tenant_id, id, receipt_no, mechanic_id, amount,
                                    payment_method, date, shift_id)
       VALUES ($1::uuid, 'CP1', 'CP-1', 'm1', 300, 'เงินสด',
               '2026-09-10T23:50:00+07', 'sh-night'),
              ($1::uuid, 'CP2', 'CP-2', 'm1', 500, 'โอน/QR',
               '2026-09-11T00:50:00+07', 'sh-night'),
              ($1::uuid, 'CP3', 'CP-3', 'm1', 700, 'เงินสด',
               '2026-09-11T00:10:00+07', 'sh-other')`,
    );
    await q(
      `INSERT INTO drawer_entries (tenant_id, id, shift_id, type, amount, note, created_at)
       VALUES ($1::uuid, 'de1', 'sh-night', 'in', 50, 'ทอน', '2026-09-10T23:10:00+07'),
              ($1::uuid, 'de2', 'sh-night', 'out', 120, 'ค่าส่ง', '2026-09-11T01:30:00+07'),
              ($1::uuid, 'de3', 'sh-other', 'out', 400, 'x', '2026-09-11T00:00:00+07')`,
    );

    await admin.query(
      `INSERT INTO shifts (tenant_id, id, date_str, starting_cash, opened_at, is_active, device_id)
       VALUES ($1::uuid, 'sh-secret', '2026-09-10', 999999, now(), TRUE, 'pos-secret')`,
      [OTHER],
    );
  }
});
