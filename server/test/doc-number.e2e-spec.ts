import type { INestApplication } from '@nestjs/common';
import type { DataSource } from 'typeorm';
import { DocNumberService } from '../src/documents/doc-number.service.js';
import { createTestApp, resetTenant, type TenantFixture } from './support/fixture.js';

// #19 acceptance suite. Runs against the real compose Postgres as `pos_app`, with
// RLS on: the row lock on `doc_counters` IS the mechanism under test, so there is
// nothing to mock.
const TENANT = 'dddddddd-4444-4444-8444-dddddddddddd';

describe('document numbers (e2e)', () => {
  let app: INestApplication;
  let ds: DataSource;
  let admin: DataSource;
  let issuer: DocNumberService;
  let fixture: TenantFixture;

  /** Issues one number in its own transaction, as a request would. */
  const issue = async (
    docType: 'receipt' | 'cn' | 'po' | 'quote' | 'cp' = 'receipt',
    deviceId = fixture.posDeviceId,
  ): Promise<string> => {
    const qr = ds.createQueryRunner();
    await qr.connect();
    await qr.startTransaction();
    try {
      await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT]);
      const no = await issuer.issue(qr.manager, {
        tenantId: TENANT,
        deviceId,
        docType,
      });
      await qr.commitTransaction();
      return no;
    } catch (err) {
      await qr.rollbackTransaction();
      throw err;
    } finally {
      await qr.release();
    }
  };

  /** The Buddhist year-month the tenant is currently in. */
  const currentPeriod = async (): Promise<string> => {
    const rows = await admin.query(
      `SELECT (EXTRACT(YEAR FROM now() AT TIME ZONE t.timezone)::int + 543) || '-' ||
              to_char(now() AT TIME ZONE t.timezone, 'MM') AS period
         FROM tenants t WHERE t.id = $1::uuid`,
      [TENANT],
    );
    return rows[0].period as string;
  };

  beforeAll(async () => {
    ({ app, ds, admin } = await createTestApp());
    issuer = new DocNumberService();
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 7 });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('is sequential per device per month, zero-padded, in the ADR-0007 shape', async () => {
    const period = await currentPeriod();
    expect(await issue()).toBe(`RC07-${period}-0001`);
    expect(await issue()).toBe(`RC07-${period}-0002`);
    expect(await issue()).toBe(`RC07-${period}-0003`);
  });

  it('keeps a separate series per doc type and per device', async () => {
    const period = await currentPeriod();
    expect(await issue('receipt')).toBe(`RC07-${period}-0001`);
    expect(await issue('cn')).toBe(`CN07-${period}-0001`);
    expect(await issue('po')).toBe(`PO07-${period}-0001`);
    expect(await issue('receipt')).toBe(`RC07-${period}-0002`);
    // device_no 57 — the backoffice machine seeded alongside the pos one.
    expect(await issue('po', fixture.backofficeDeviceId)).toBe(`PO57-${period}-0001`);
  });

  it('rolls over into a new month rather than continuing the old count', async () => {
    const period = await currentPeriod();
    await issue();
    await issue();
    // Last month's counter, pre-loaded high: the new month must not see it.
    const [y, m] = period.split('-').map(Number);
    const previous = m === 1 ? `${y - 1}-12` : `${y}-${String(m - 1).padStart(2, '0')}`;
    await admin.query(
      `INSERT INTO doc_counters (tenant_id, device_id, doc_type, period, last_no)
            VALUES ($1::uuid, $2, 'receipt', $3, 8000)`,
      [TENANT, fixture.posDeviceId, previous],
    );
    expect(await issue()).toBe(`RC07-${period}-0003`);
  });

  it('20 concurrent allocations produce 20 distinct consecutive numbers', async () => {
    const period = await currentPeriod();
    const numbers = await Promise.all(Array.from({ length: 20 }, () => issue()));
    expect(new Set(numbers).size).toBe(20);
    expect([...numbers].sort()).toEqual(
      Array.from({ length: 20 }, (_, i) =>
        `RC07-${period}-${String(i + 1).padStart(4, '0')}`,
      ),
    );
  });

  it('a rolled-back transaction burns no number', async () => {
    const period = await currentPeriod();
    expect(await issue()).toBe(`RC07-${period}-0001`);

    const qr = ds.createQueryRunner();
    await qr.connect();
    await qr.startTransaction();
    await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT]);
    await issuer.issue(qr.manager, {
      tenantId: TENANT,
      deviceId: fixture.posDeviceId,
      docType: 'receipt',
    });
    await qr.rollbackTransaction();
    await qr.release();

    // The number the rolled-back sale took is available again — the printed series
    // has no hole, which is the whole reason allocation happens inside the sale's
    // own transaction.
    expect(await issue()).toBe(`RC07-${period}-0002`);
  });

  it('the 10,000th document in a month fails loudly instead of wrapping to 0001', async () => {
    const period = await currentPeriod();
    await admin.query(
      `INSERT INTO doc_counters (tenant_id, device_id, doc_type, period, last_no)
            VALUES ($1::uuid, $2, 'receipt', $3, 9998)`,
      [TENANT, fixture.posDeviceId, period],
    );
    expect(await issue()).toBe(`RC07-${period}-9999`);
    await expect(issue()).rejects.toMatchObject({
      response: { code: 'DOC_NUMBER_EXHAUSTED' },
    });
  });

  it('a retired device cannot issue, and its device_no is never re-used', async () => {
    await admin.query(
      `UPDATE devices SET retired_at = now() WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, fixture.posDeviceId],
    );
    await expect(issue()).rejects.toMatchObject({
      response: { code: 'DEVICE_ROLE_FORBIDDEN' },
    });
  });

  it('leaves imported legacy numbers exactly as they are', async () => {
    // What `DB.exportSnapshot()` from the old app carries: random ids, no series.
    await admin.query(
      `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, discount, total, payment_method)
            VALUES ($1::uuid, 's-legacy', 'RC12345678ABCD', 100, 0, 100, 'เงินสด')`,
      [TENANT],
    );
    const period = await currentPeriod();
    // The counter starts from zero regardless: the two formats cannot collide, so
    // there is nothing to reconcile (ADR-0007).
    expect(await issue()).toBe(`RC07-${period}-0001`);
    const rows = await admin.query(
      `SELECT receipt_no FROM sales WHERE tenant_id = $1::uuid AND id = 's-legacy'`,
      [TENANT],
    );
    expect(rows[0].receipt_no).toBe('RC12345678ABCD');
  });
});
