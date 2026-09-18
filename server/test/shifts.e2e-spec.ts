import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

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
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 5, cache });
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
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('opens a drawer, and opening again with the same id returns the same shift untouched', async () => {
    const first = await post('/open', { id: 'sh_custom_1', startingCash: '2000.00' });
    expect(first.status).toBe(200);
    expect(first.body.data.id).toBe('sh_custom_1');
    expect(first.body.data.startingCash).toBe('2000.00');
    expect(first.body.data.isActive).toBe(true);
    expect(first.body.data.entries).toEqual([]);

    // Replay with the same id returns the existing shift untouched.
    const again = await post('/open', { id: 'sh_custom_1', startingCash: '9999.00' });
    expect(again.status).toBe(200);
    expect(again.body.data.id).toBe('sh_custom_1');
    expect(again.body.data.startingCash).toBe('2000.00');

    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(rows[0].n).toBe(1);

    const revs = await admin.query(
      `SELECT count(*)::int AS n FROM owner_review_items WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(revs[0].n).toBe(0);
  });

  it('opening a new shift while previous shift is still open archives it and records shift_uncounted', async () => {
    const first = await post('/open', { startingCash: '2000.00' });
    expect(first.status).toBe(200);
    expect(first.body.data.isActive).toBe(true);

    const second = await post('/open', { startingCash: '3000.00' });
    expect(second.status).toBe(200);
    expect(second.body.data.id).not.toBe(first.body.data.id);
    expect(second.body.data.startingCash).toBe('3000.00');
    expect(second.body.data.isActive).toBe(true);

    const archivedFirst = await shiftRow(first.body.data.id);
    expect(archivedFirst.is_active).toBe(false);
    expect(archivedFirst.auto_archived).toBe(true);
    expect(archivedFirst.closed_at).toBeNull();

    const revs = await admin.query(
      `SELECT id, kind, ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(revs).toHaveLength(1);
    expect(revs[0].kind).toBe('shift_uncounted');
    expect(revs[0].ref_id).toBe(first.body.data.id);
    expect(revs[0].details.shiftId).toBe(first.body.data.id);
    expect(revs[0].details.deviceId).toBe(fixture.posDeviceId);
  });

  it('allows opening a new shift on the same day after closing without creating shift_uncounted', async () => {
    const shift1 = await post('/open', { startingCash: '1000.00' });
    await post('/close', { physicalCash: '1500.00' });

    // Open second shift on the same day right after close (#100)
    const shift2 = await post('/open', { startingCash: '2000.00' });
    expect(shift2.body.data.id).not.toBe(shift1.body.data.id);
    expect(shift2.body.data.isActive).toBe(true);

    const archived1 = await shiftRow(shift1.body.data.id);
    expect(archived1.is_active).toBe(false);
    expect(archived1.auto_archived).toBe(false); // closed properly
    expect(archived1.closed_at).not.toBeNull();

    const revs = await admin.query(
      `SELECT count(*)::int AS n FROM owner_review_items WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(revs[0].n).toBe(0);
  });

  it('e2e multi-shift: A date_str = 15, B = 16, no bills rejected and both stamped correctly', async () => {
    await seedProduct(admin, TENANT, {
      id: 'p1',
      partNo: 'OF-1',
      name: 'Oil Filter',
      price: 85,
      cost: 50,
      stock: 100,
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

    // Open shift A on day 15 (openedAt 2026-09-15T08:00:00Z)
    const shiftA = await post('/open', {
      id: 'sh_A',
      startingCash: '1000.00',
      openedAt: '2026-09-15T08:00:00.000Z',
    });
    expect(shiftA.status).toBe(200);
    expect(shiftA.body.data.id).toBe('sh_A');
    expect(shiftA.body.data.dateStr).toBe('2026-09-15');

    // Sell in shift A
    const saleA = await sell('s-shift-A-1');
    expect(saleA.status).toBe(201);
    expect(saleA.body.data.shiftId).toBe('sh_A');

    // Open shift B on day 16 (openedAt 2026-09-16T08:00:00Z) without closing A
    const shiftB = await post('/open', {
      id: 'sh_B',
      startingCash: '1500.00',
      openedAt: '2026-09-16T08:00:00.000Z',
    });
    expect(shiftB.status).toBe(200);
    expect(shiftB.body.data.id).toBe('sh_B');
    expect(shiftB.body.data.dateStr).toBe('2026-09-16');

    // Shift A is archived with auto_archived = true and shift_uncounted item
    const rowA = await shiftRow('sh_A');
    expect(rowA.is_active).toBe(false);
    expect(rowA.auto_archived).toBe(true);

    const revs = await admin.query(
      `SELECT kind, ref_id FROM owner_review_items WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(revs).toContainEqual({ kind: 'shift_uncounted', ref_id: 'sh_A' });

    // Sell in shift B
    const saleB = await sell('s-shift-B-1');
    expect(saleB.status).toBe(201);
    expect(saleB.body.data.shiftId).toBe('sh_B');
  });

  it('date_str formats correctly according to tenant timezone across UTC midnight', async () => {
    // 2026-09-15 23:30:00 UTC = 2026-09-16 06:30:00 in Asia/Bangkok (+07:00)
    const late = await post('/open', {
      id: 'sh_late_utc',
      startingCash: '500.00',
      openedAt: '2026-09-15T23:30:00.000Z',
    });
    expect(late.status).toBe(200);
    expect(late.body.data.dateStr).toBe('2026-09-16');
  });

  it('validates id and openedAt input formats', async () => {
    const badId = await post('/open', { id: '   ', startingCash: '100.00' });
    expect(badId.status).toBe(400);

    const badDate = await post('/open', { startingCash: '100.00', openedAt: 'not-a-date' });
    expect(badDate.status).toBe(400);
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

    const fresh = await post('/open', { startingCash: '2000.00' });

    const archived = await shiftRow(forgotten.body.data.id);
    expect(archived.is_active).toBe(false);
    expect(archived.auto_archived).toBe(true);
    expect(archived.archived_at).not.toBeNull();
    // The day's takings are still there to report on.
    expect(archived.closed_at).toBeNull();

    // The forgotten shift moved to history, not the void — and the active drawer is the new one.
    const current = await get('/current');
    expect(current.body.data.id).toBe(fresh.body.data.id);
    const history = await get('/history');
    expect(history.body.data.map((sh: { id: string }) => sh.id)).toContain(
      forgotten.body.data.id,
    );
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

    // Before the drawer is opened the bill is refused (owner's decision, 2026-09-13):
    // a bill with no shift is money no closing report counts.
    const before = await sell(`s-noshift-${Date.now()}`);
    expect(before.status).toBe(409);
    expect(before.body.error.code).toBe('NO_OPEN_SHIFT');

    const shift = await post('/open', { startingCash: '1000.00' });
    const during = await sell(`s-shift-${Date.now()}`);
    expect(during.status).toBe(201);
    expect(during.body.data.shiftId).toBe(shift.body.data.id);

    const rows = await admin.query(
      `SELECT id, shift_id FROM sales WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(rows).toEqual([{ id: during.body.data.id, shift_id: shift.body.data.id }]);
  });

  it('refuses a bill once the drawer is closed', async () => {
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
    // A closed drawer takes no more money: the bill must neither join the closed shift
    // and skew its counted report nor slip in with no shift at all. "Open" is
    // `closed_at IS NULL`, so the still-`is_active` closed row does not count.
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('NO_OPEN_SHIFT');

    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(rows[0].n).toBe(0);
    const stock = await admin.query(
      `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p2'`,
      [TENANT],
    );
    expect(stock[0].stock).toBe(10);
  });

  // #144: through the real `POST /devices/:id/retire`, which replaced the probe controller
  // #28 mounted here. `test/devices.e2e-spec.ts` covers the endpoint itself; these cases
  // pin what retirement does to the drawer.
  const ownerToken = () =>
    accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.backofficeDeviceId,
      deviceRole: 'backoffice',
    });

  const retire = (deviceId: string, body: Record<string, unknown>) =>
    request(app.getHttpServer())
      .post(`/api/v1/devices/${deviceId}/retire`)
      .set('Authorization', `Bearer ${ownerToken()}`)
      .set('Idempotency-Key', `k-retire-${++keySeq}-${Date.now()}`)
      .send(body);

  it('retiring a device closes the shift it left open, and is a no-op otherwise', async () => {
    // Nothing open on the backoffice machine: nothing to close, and not an error.
    const nothing = await retire(fixture.backofficeDeviceId, {});
    expect(nothing.status).toBe(200);
    expect(nothing.body.data.shift).toBeNull();
    expect(nothing.body.data.device.retiredAt).not.toBeNull();

    const opened = await post('/open', { startingCash: '1000.00' });
    const closed = await retire(fixture.posDeviceId, { physicalCash: '1750.25' });
    expect(closed.status).toBe(200);
    expect(closed.body.data.shift.id).toBe(opened.body.data.id);
    expect(closed.body.data.shift.physicalCash).toBe('1750.25');

    const row = await shiftRow(opened.body.data.id);
    expect(row.closed_at).not.toBeNull();
    // 🔴 Archived, not left active. Normally the device's NEXT open archives its
    // drawer — but a retired device never opens again, so an active row here would be
    // stranded: `history()` (`NOT is_active`) would hide that day's takings forever
    // while `current()` showed a drawer nothing could close. That is exactly the day
    // ADR-0004 wants preserved.
    expect(row.is_active).toBe(false);
    expect(row.auto_archived).toBe(false);
    expect(closed.body.data.shift.isActive).toBe(false);

    // The device row and the drawer moved in the same transaction.
    const device = await admin.query(
      `SELECT retired_at FROM devices WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, fixture.posDeviceId],
    );
    expect(device[0].retired_at).not.toBeNull();

    const history = await get('/history');
    expect(history.body.data.map((sh: { id: string }) => sh.id)).toContain(
      opened.body.data.id,
    );
  });

  it('a drawer closed but not yet archived is archived by retirement, its count kept', async () => {
    const opened = await post('/open', { startingCash: '1000.00' });
    await post('/close', { physicalCash: '1300.00' });

    // Closed tonight, retired before tomorrow's open: nothing would ever archive it.
    const res = await retire(fixture.posDeviceId, { physicalCash: '9999.00' });
    expect(res.status).toBe(200);
    expect(res.body.data.shift.id).toBe(opened.body.data.id);
    // The counted cash is the close's, not the retirement body's.
    expect(res.body.data.shift.physicalCash).toBe('1300.00');

    const row = await shiftRow(opened.body.data.id);
    expect(row.is_active).toBe(false);
    expect(row.auto_archived).toBe(false);
  });

  it('a replacement pos device starts clean after the old one is retired', async () => {
    const oldDrawer = await post('/open', { startingCash: '1000.00' });
    await post('/current/entries', { type: 'in', amount: '250.00', note: 'ช่างจ่ายหนี้' });
    const retired = await retire(fixture.posDeviceId, { physicalCash: '1250.00' });
    expect(retired.status).toBe(200);

    // A stale access token from the retired till (ADR-0009 keeps it alive up to 15
    // minutes) cannot open a new drawer on it — that drawer would be stranded again.
    const stale = await post('/open', { startingCash: '0.00' });
    expect(stale.status).toBe(403);
    expect(stale.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');

    // The shop buys a new till: the server gives it a new id and a new device_no.
    const created = await request(app.getHttpServer())
      .post('/api/v1/devices')
      .set('Authorization', `Bearer ${ownerToken()}`)
      .set('Idempotency-Key', `k-dev-${++keySeq}-${Date.now()}`)
      .send({ label: 'เครื่องขายใหม่', role: 'pos' });
    expect(created.status).toBe(201);
    const replacementId: string = created.body.data.device.id;
    expect(created.body.data.device.deviceNo).not.toBe(fixture.posDeviceNo);
    const replacementToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
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

    // DoD line 12 (03_ARCHITECTURE.md §8): "enrol เครื่องใหม่ได้ device_no ใหม่ และขายได้"
    await seedProduct(admin, TENANT, {
      id: 'p-repl-sell',
      partNo: 'RP-01',
      name: 'Replacement Part',
      price: 150,
      cost: 100,
      stock: 10,
    });
    const sale = await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${replacementToken}`)
      .set('Idempotency-Key', `k-repl-sale-${Date.now()}`)
      .send({
        id: `s-repl-${Date.now()}`,
        subtotal: '150.00',
        discount: '0.00',
        total: '150.00',
        paymentMethod: 'เงินสด',
        items: [
          {
            lineNo: 1,
            productId: 'p-repl-sell',
            name: 'Replacement Part',
            qty: 1,
            price: '150.00',
          },
        ],
      });
    expect(sale.status).toBe(201);
    expect(sale.body.status).toBe('success');
    expect(sale.body.data.shiftId).toBe(fresh.body.data.id);
    const padNo = String(created.body.data.device.deviceNo).padStart(2, '0');
    expect(sale.body.data.receiptNo).toMatch(
      new RegExp(`^RC${padNo}-\\d{4}-\\d{2}-\\d{4}$`),
    );
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
    // Its own code and message: `DRAWER_CLOSED`'s Thai sentence is about refusing a
    // cash *entry*, and the Dart reference never refuses a second close, so there is
    // no Thai to copy — English until the shop words it (§8.1).
    const twice = await post('/close', { physicalCash: '1.00' });
    expect(twice.status).toBe(409);
    expect(twice.body.error.code).toBe('SHIFT_ALREADY_CLOSED');
    expect(twice.body.error.message).toBe('This shift is already closed.');
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

  it('ten simultaneous opens with the same id produce exactly one drawer', async () => {
    const shiftId = 'sh-race-1';
    const send = () =>
      request(app.getHttpServer())
        .post('/api/v1/shifts/open')
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', `k-race-${Math.random()}`)
        .send({ id: shiftId, startingCash: '1000.00' });

    // Different keys, so idempotency does not answer this: the client id replay
    // and `ON CONFLICT … WHERE is_active DO NOTHING` and the re-read behind it
    // are what has to hold in Phase 2.
    const results = await Promise.all(Array.from({ length: 10 }, send));
    for (const r of results) expect(r.status).toBe(200);
    expect(new Set(results.map((r) => r.body.data.id)).size).toBe(1);
    expect(results[0].body.data.id).toBe(shiftId);

    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(rows[0].n).toBe(1);
  });
});
