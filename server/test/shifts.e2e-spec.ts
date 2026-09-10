import {
  Body,
  Controller,
  HttpCode,
  Module,
  Post,
  UseGuards,
  type INestApplication,
  type MiddlewareConsumer,
  type NestModule,
} from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { TenantGuard } from '../src/common/guards/tenant.guard.js';
import { toSatang } from '../src/common/money.js';
import { RequestContextMiddleware } from '../src/common/request-context.middleware.js';
import { ShiftsModule } from '../src/shifts/shifts.module.js';
import { ShiftsService } from '../src/shifts/shifts.service.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

/**
 * `POST /devices/:id/retire` belongs to #6 and does not exist yet, but ADR-0004 makes
 * closing that device's open shift part of the same transaction, so #28 owns the
 * operation. This mounts it on a route so the operation is exercised the way the real
 * endpoint will exercise it, rather than shipped untested against a future caller.
 */
@Controller('test-retire')
@UseGuards(TenantGuard)
class RetireProbeController {
  constructor(private readonly shifts: ShiftsService) {}

  @Post()
  @HttpCode(200)
  retire(@Body() body: { deviceId: string; physicalCash: string }) {
    return this.shifts.closeForRetirement(
      body.deviceId,
      toSatang(body.physicalCash, 'physicalCash'),
    );
  }
}

@Module({
  imports: [ShiftsModule],
  controllers: [RetireProbeController],
  providers: [RequestContextMiddleware],
})
class RetireProbeModule implements NestModule {
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(RequestContextMiddleware).forRoutes(RetireProbeController);
  }
}

// #28 acceptance suite. Every case in `frontend/lib/data/repositories/shifts_repository.dart`
// reproduced at the HTTP seam, plus the two rules the Dart version has no concept of:
// device roles, and the `shift_id` stamp on a bill.
const TENANT = 'ffffffff-6666-4666-8666-ffffffffffff';

describe('shifts and the cash drawer (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let posToken: string;
  let backofficeToken: string;
  let keySeq = 0;

  const auth = (token?: string) => token ?? posToken;

  const post = (path: string, body: unknown, token?: string) =>
    request(app.getHttpServer())
      .post(`/api/v1/shifts${path}`)
      .set('Authorization', `Bearer ${auth(token)}`)
      .set('Idempotency-Key', `k-${++keySeq}-${Date.now()}`)
      .send(body as object);

  const get = (path: string, token?: string) =>
    request(app.getHttpServer())
      .get(`/api/v1/shifts${path}`)
      .set('Authorization', `Bearer ${auth(token)}`);

  const shiftRow = async (id: string) => {
    const rows = await admin.query(
      `SELECT is_active, auto_archived, archived_at, closed_at, date_str
         FROM shifts WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    return rows[0];
  };

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp([RetireProbeModule]));
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 5, cache });
    posToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'manager',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
    backofficeToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'manager',
      deviceId: fixture.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('opens a drawer, and opening again the same day returns the same shift', async () => {
    const first = await post('/open', { startingCash: '2000.00' });
    expect(first.status).toBe(200);
    expect(first.body.data.startingCash).toBe('2000.00');
    expect(first.body.data.isActive).toBe(true);
    expect(first.body.data.entries).toEqual([]);

    // Staff press the button twice; the starting cash of the second press is ignored
    // precisely because the drawer already holds today's money.
    const again = await post('/open', { startingCash: '9999.00' });
    expect(again.status).toBe(200);
    expect(again.body.data.id).toBe(first.body.data.id);
    expect(again.body.data.startingCash).toBe('2000.00');

    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(rows[0].n).toBe(1);
  });

  it('opening on a new day archives the previous shift first', async () => {
    const yesterday = await post('/open', { startingCash: '1000.00' });
    await post('/close', { physicalCash: '1500.00' });
    // Backdate it: the rule is "a different date_str", not "24 hours later".
    await admin.query(
      `UPDATE shifts SET date_str = '2000-01-01' WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, yesterday.body.data.id],
    );

    const today = await post('/open', { startingCash: '2000.00' });
    expect(today.body.data.id).not.toBe(yesterday.body.data.id);

    const archived = await shiftRow(yesterday.body.data.id);
    expect(archived.is_active).toBe(false);
    // It was closed properly, so it is archived without the flag.
    expect(archived.auto_archived).toBe(false);
  });

  it('a shift nobody closed is archived with auto_archived, never discarded', async () => {
    const forgotten = await post('/open', { startingCash: '1000.00' });
    await admin.query(
      `UPDATE shifts SET date_str = '2000-01-01' WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, forgotten.body.data.id],
    );

    await post('/open', { startingCash: '2000.00' });

    const archived = await shiftRow(forgotten.body.data.id);
    expect(archived.is_active).toBe(false);
    expect(archived.auto_archived).toBe(true);
    expect(archived.archived_at).not.toBeNull();
    // The day's takings are still there to report on.
    expect(archived.closed_at).toBeNull();
  });

  it('closing leaves the shift active — it is still this device’s drawer', async () => {
    const opened = await post('/open', { startingCash: '1000.00' });
    const closed = await post('/close', { physicalCash: '1234.50' });

    expect(closed.status).toBe(200);
    expect(closed.body.data.physicalCash).toBe('1234.50');
    expect(closed.body.data.closedAt).not.toBeNull();
    // ⚠️ `is_active` means "this device's current drawer", not "open". Repurposing it
    // would break `uq_shift_active`.
    expect(closed.body.data.isActive).toBe(true);

    const current = await get('/current');
    expect(current.body.data.id).toBe(opened.body.data.id);
  });

  it('money in and out lands on the open drawer, newest first', async () => {
    await post('/open', { startingCash: '1000.00' });
    const inEntry = await post('/current/entries', {
      type: 'in',
      amount: '500.00',
      note: 'ช่างจ่ายหนี้',
    });
    expect(inEntry.status).toBe(201);
    await post('/current/entries', { type: 'out', amount: '120.00', note: 'ค่ากาแฟ' });

    const current = await get('/current');
    expect(current.body.data.entries).toHaveLength(2);
    expect(current.body.data.entries[0].type).toBe('out');
    expect(current.body.data.entries[0].amount).toBe('120.00');
    expect(current.body.data.entries[1].note).toBe('ช่างจ่ายหนี้');
  });

  it('an entry after close is refused with the verbatim Thai message', async () => {
    await post('/open', { startingCash: '1000.00' });
    await post('/close', { physicalCash: '1000.00' });

    const res = await post('/current/entries', { type: 'in', amount: '50.00' });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('DRAWER_CLOSED');
    expect(res.body.error.message).toBe(
      'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้',
    );

    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM drawer_entries WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(rows[0].n).toBe(0);
  });

  it('an entry or a close with no drawer open is NO_OPEN_SHIFT', async () => {
    const entry = await post('/current/entries', { type: 'in', amount: '50.00' });
    expect(entry.status).toBe(409);
    expect(entry.body.error.code).toBe('NO_OPEN_SHIFT');
    expect(entry.body.error.message).toBe('No open shift');

    const close = await post('/close', { physicalCash: '0.00' });
    expect(close.status).toBe(409);
    expect(close.body.error.code).toBe('NO_OPEN_SHIFT');
  });

  it('refuses an entry that is not in/out, or an amount of zero', async () => {
    await post('/open', { startingCash: '1000.00' });
    expect((await post('/current/entries', { type: 'sideways', amount: '5.00' })).status).toBe(400);
    expect((await post('/current/entries', { type: 'in', amount: '0.00' })).status).toBe(400);
    expect((await post('/current/entries', { type: 'in', amount: '-5.00' })).status).toBe(400);
  });

  it('a backoffice device may read the drawer but may not touch it', async () => {
    await post('/open', { startingCash: '1000.00' });

    const read = await get('/current', backofficeToken);
    expect(read.status).toBe(200);
    expect(read.body.data.startingCash).toBe('1000.00');
    expect((await get('/history', backofficeToken)).status).toBe(200);


    for (const [path, body] of [
      ['/open', { startingCash: '1.00' }],
      ['/close', { physicalCash: '1.00' }],
      ['/current/entries', { type: 'in', amount: '1.00' }],
    ] as const) {
      const res = await post(path, body, backofficeToken);
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
      expect(res.body.error.message).toBe('เครื่องนี้ขายของไม่ได้');
    }
  });

  it('history is paginated and holds only archived shifts', async () => {
    for (let i = 0; i < 3; i++) {
      const opened = await post('/open', { startingCash: `${100 + i}.00` });
      await admin.query(
        `UPDATE shifts SET date_str = $3 WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT, opened.body.data.id, `2000-01-0${i + 1}`],
      );
    }
    const live = await post('/open', { startingCash: '999.00' });

    const page1 = await get('/history?page=1&limit=2');
    expect(page1.status).toBe(200);
    // §1.2 puts pagination in `meta`, beside `data` — not inside it.
    expect(page1.body.meta).toEqual({ total: 3, page: 1, limit: 2, totalPages: 2 });
    expect(page1.body.data).toHaveLength(2);
    const page2 = await get('/history?page=2&limit=2');
    expect(page2.body.data).toHaveLength(1);

    const ids = [...page1.body.data, ...page2.body.data].map((sh: { id: string }) => sh.id);
    expect(ids).not.toContain(live.body.data.id);
    expect((await get('/history?page=0')).status).toBe(400);
  });

  it('reports no drawer at all before the first open', async () => {
    const res = await get('/current');
    expect(res.status).toBe(200);
    expect(res.body.data).toBeNull();
  });

  it('stamps shift_id on every bill rung up while the drawer is open', async () => {
    await seedProduct(admin, TENANT, {
      id: 'p1',
      partNo: 'OF-1',
      name: 'Oil Filter',
      price: 85,
      cost: 50,
      stock: 10,
    });
    const sell = async (id: string) =>
      request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', `k-sale-${id}`)
        .send({
          id,
          subtotal: '85.00',
          discount: '0.00',
          total: '85.00',
          paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }],
        });

    // Before the drawer is opened: the old app allows this, so the sale goes through
    // with no shift rather than being refused by a rule the shop never had.
    const before = await sell(`s-noshift-${Date.now()}`);
    expect(before.status).toBe(201);

    const shift = await post('/open', { startingCash: '1000.00' });
    const during = await sell(`s-shift-${Date.now()}`);
    expect(during.status).toBe(201);

    const rows = await admin.query(
      `SELECT id, shift_id FROM sales WHERE tenant_id = $1::uuid AND id = ANY($2::text[])`,
      [TENANT, [before.body.data.id, during.body.data.id]],
    );
    const byId = new Map(rows.map((r: { id: string; shift_id: string }) => [r.id, r.shift_id]));
    expect(byId.get(before.body.data.id)).toBeNull();
    expect(byId.get(during.body.data.id)).toBe(shift.body.data.id);
  });

  it('stops stamping once the drawer is closed', async () => {
    await seedProduct(admin, TENANT, {
      id: 'p2',
      partNo: 'BP-2',
      name: 'Brake Pad',
      price: 750,
      cost: 500,
      stock: 10,
    });
    await post('/open', { startingCash: '1000.00' });
    await post('/close', { physicalCash: '1000.00' });

    const id = `s-after-close-${Date.now()}`;
    const res = await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', `k-${id}`)
      .send({
        id,
        subtotal: '750.00',
        discount: '0.00',
        total: '750.00',
        paymentMethod: 'เงินสด',
        items: [{ lineNo: 1, productId: 'p2', name: 'Brake Pad', qty: 1, price: '750.00' }],
      });
    expect(res.status).toBe(201);

    const rows = await admin.query(
      `SELECT shift_id FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    // A closed drawer takes no more money, so a bill after it belongs to no shift —
    // it must not silently join the closed one and skew its report.
    expect(rows[0].shift_id).toBeNull();
  });

  it('retiring a device closes the shift it left open, and is a no-op otherwise', async () => {
    const retire = (deviceId: string, physicalCash: string) =>
      request(app.getHttpServer())
        .post('/api/v1/test-retire')
        .set('Authorization', `Bearer ${posToken}`)
        .send({ deviceId, physicalCash });

    // Nothing open on the backoffice machine: nothing to close, and not an error.
    const nothing = await retire(fixture.backofficeDeviceId, '0.00');
    expect(nothing.status).toBe(200);
    expect(nothing.body.data).toBeNull();

    const opened = await post('/open', { startingCash: '1000.00' });
    const closed = await retire(fixture.posDeviceId, '1750.25');
    expect(closed.status).toBe(200);
    expect(closed.body.data.id).toBe(opened.body.data.id);
    expect(closed.body.data.physicalCash).toBe('1750.25');

    const row = await shiftRow(opened.body.data.id);
    expect(row.closed_at).not.toBeNull();
    // 🔴 Archived, not left active. Normally the device's NEXT open archives its
    // drawer — but a retired device never opens again, so an active row here would be
    // stranded: `history()` (`NOT is_active`) would hide that day's takings forever
    // while `current()` showed a drawer nothing could close. That is exactly the day
    // ADR-0004 wants preserved.
    expect(row.is_active).toBe(false);
    expect(closed.body.data.isActive).toBe(false);

    const history = await get('/history');
    expect(history.body.data.map((sh: { id: string }) => sh.id)).toContain(
      opened.body.data.id,
    );
  });

  it('a replacement pos device starts clean after the old one is retired', async () => {
    const oldDrawer = await post('/open', { startingCash: '1000.00' });
    await post('/current/entries', { type: 'in', amount: '250.00', note: 'ช่างจ่ายหนี้' });
    await request(app.getHttpServer())
      .post('/api/v1/test-retire')
      .set('Authorization', `Bearer ${posToken}`)
      .send({ deviceId: fixture.posDeviceId, physicalCash: '1250.00' });
    await admin.query(
      `UPDATE devices SET retired_at = now() WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, fixture.posDeviceId],
    );

    // The shop buys a new till. It gets a new device_no and its own drawer.
    const replacementId = 'pos-replacement';
    await admin.query(
      `INSERT INTO devices (tenant_id, id, label, device_no, role)
            VALUES ($1::uuid, $2, 'เครื่องขายใหม่', 6, 'pos')`,
      [TENANT, replacementId],
    );
    const replacementToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'manager',
      deviceId: replacementId,
      deviceRole: 'pos',
    });

    // The retired machine's last day is in history, with its entries, and nothing the
    // new machine does can reach it.
    const history = await get('/history', replacementToken);
    const archived = history.body.data.find(
      (sh: { id: string }) => sh.id === oldDrawer.body.data.id,
    );
    expect(archived).toBeDefined();
    expect(archived.physicalCash).toBe('1250.00');
    expect(archived.entries).toHaveLength(1);

    const fresh = await post('/open', { startingCash: '500.00' }, replacementToken);
    expect(fresh.status).toBe(200);
    expect(fresh.body.data.id).not.toBe(oldDrawer.body.data.id);
    expect(fresh.body.data.deviceId).toBe(replacementId);
  });

  it('the idempotency key really guards open, not just the same-day rule', async () => {
    const key = `k-open-once-${Date.now()}`;
    const send = (startingCash: string) =>
      request(app.getHttpServer())
        .post('/api/v1/shifts/open')
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', key)
        .send({ startingCash });

    const first = await send('1000.00');
    expect(first.status).toBe(200);
    expect((await send('1000.00')).body.data.id).toBe(first.body.data.id);

    // Same key, different body. Asserting only that a repeat returns the same shift
    // would pass with the interceptor removed — the same-day rule alone guarantees
    // that. This is the assertion only the interceptor can satisfy.
    const changed = await send('9999.00');
    expect(changed.status).toBe(409);
    expect(changed.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
  });

  it('refuses to close twice, and refuses cash that is missing or negative', async () => {
    await post('/open', { startingCash: '1000.00' });
    expect((await post('/close', { physicalCash: '1500.00' })).status).toBe(200);

    // `physical_cash` is the number the day is reconciled against, and a second press
    // carries a different idempotency key — nothing else would stop it overwriting the
    // counted cash silently.
    const twice = await post('/close', { physicalCash: '1.00' });
    expect(twice.status).toBe(409);
    expect(twice.body.error.code).toBe('DRAWER_CLOSED');
    const rows = await admin.query(
      `SELECT physical_cash FROM shifts WHERE tenant_id = $1::uuid AND is_active`,
      [TENANT],
    );
    expect(rows[0].physical_cash).toBe('1500.00');
  });

  it('will not open or close on a defaulted or negative amount', async () => {
    // A defaulted 0 closes the day at zero counted cash, and the report then shows a
    // shortfall the size of the day's takings (§3.11's own warning).
    expect((await post('/open', {})).status).toBe(400);
    expect((await post('/open', { startingCash: '-1.00' })).status).toBe(400);
    await post('/open', { startingCash: '1000.00' });
    expect((await post('/close', {})).status).toBe(400);
    expect((await post('/close', { physicalCash: '-1.00' })).status).toBe(400);
  });

  it('ten simultaneous opens produce exactly one drawer', async () => {
    const send = () =>
      request(app.getHttpServer())
        .post('/api/v1/shifts/open')
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', `k-race-${Math.random()}`)
        .send({ startingCash: '1000.00' });

    // Different keys, so idempotency does not answer this: the `ON CONFLICT … WHERE
    // is_active DO NOTHING` and the re-read behind it are what has to hold.
    const results = await Promise.all(Array.from({ length: 10 }, send));
    for (const r of results) expect(r.status).toBe(200);
    expect(new Set(results.map((r) => r.body.data.id)).size).toBe(1);

    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(rows[0].n).toBe(1);
  });
});
