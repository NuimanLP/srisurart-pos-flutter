import { createHash, randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { newUuid } from '../src/common/ids.js';
import { MAX_IMAGE_BYTES } from '../src/payment-accounts/payment-accounts.rules.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  TENANT_TABLES_DEPTH_FIRST,
  type TenantFixture,
} from './support/fixture.js';
import { testId } from './support/test-ids.js';

/**
 * QR payment accounts (owner request 2026-10-10, contract `qr-accounts-contract.md` §1–§3):
 * `/payment-accounts` CRUD (owner-only writes, idempotent, 5-active limit under a lock,
 * one default, image validation, the 1 MB body limit), RLS isolation, and the bill's
 * `paymentAccountId` on `POST /sales` and on a `/sync/push` replay.
 */
const TENANT = testId('payment-accounts-e2e-a');
const OTHER = testId('payment-accounts-e2e-b');
const POS_DEVICE_TOKEN = 'pos-device-token-payment-accounts';

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46]);
/** A PNG of `size` bytes: real magic bytes, zero padding. */
const pngOf = (size: number) => Buffer.concat([PNG, Buffer.alloc(size - PNG.length)]);

describe('payment accounts (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let shop: TenantFixture;
  let other: TenantFixture;
  let ownerToken: string;
  let posToken: string;
  let otherToken: string;

  const server = () => app.getHttpServer();
  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

  const list = (token = ownerToken) => request(server()).get('/api/v1/payment-accounts').set(auth(token));
  const create = (body: Record<string, unknown>, token = ownerToken, key: string | null = randomUUID()) => {
    const req = request(server()).post('/api/v1/payment-accounts').set(auth(token));
    if (key !== null) req.set('Idempotency-Key', key);
    return req.send(body);
  };
  const patch = (id: string, body: Record<string, unknown>, token = ownerToken) =>
    request(server())
      .patch(`/api/v1/payment-accounts/${id}`)
      .set(auth(token))
      .set('Idempotency-Key', randomUUID())
      .send(body);
  const remove = (id: string, token = ownerToken) =>
    request(server()).delete(`/api/v1/payment-accounts/${id}`).set(auth(token)).set('Idempotency-Key', randomUUID());

  const promptpay = (extra: Record<string, unknown> = {}) => ({
    id: newUuid(),
    nickname: 'บัญชีร้าน',
    bankCode: 'KBANK',
    kind: 'promptpay',
    promptpayId: '0812345678',
    ...extra,
  });
  const imageAccount = (bytes: Buffer, mime = 'image/png', extra: Record<string, unknown> = {}) => ({
    id: newUuid(),
    nickname: 'รูป QR',
    bankCode: 'SCB',
    kind: 'image',
    imageBase64: bytes.toString('base64'),
    imageMime: mime,
    ...extra,
  });

  const defaults = async (tenantId = TENANT) =>
    (
      (await admin.query(
        `SELECT id FROM payment_accounts WHERE tenant_id = $1::uuid AND is_default AND deleted_at IS NULL ORDER BY id`,
        [tenantId],
      )) as { id: string }[]
    ).map((r) => r.id);

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    shop = await resetTenant(admin, TENANT, { cache });
    other = await resetTenant(admin, OTHER, { cache });
    ownerToken = accessToken({ tenantId: TENANT, userId: shop.userId, role: 'owner' });
    posToken = accessToken({
      tenantId: TENANT,
      userId: shop.userId,
      role: 'owner',
      deviceId: shop.posDeviceId,
      deviceRole: 'pos',
    });
    otherToken = accessToken({ tenantId: OTHER, userId: other.userId, role: 'owner' });
  });

  afterAll(async () => {
    for (const tid of [TENANT, OTHER]) {
      for (const table of TENANT_TABLES_DEPTH_FIRST) {
        await admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tid]);
      }
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tid]);
    }
    await app.close();
  });

  describe('CRUD', () => {
    it('creates a PromptPay account and answers the contract wire shape', async () => {
      const body = promptpay({ isDefault: true });
      const res = await create(body);
      expect(res.status, JSON.stringify(res.body)).toBe(201);
      expect(res.body.data).toEqual({
        id: body.id,
        nickname: 'บัญชีร้าน',
        bankCode: 'KBANK',
        kind: 'promptpay',
        promptpayId: '0812345678',
        imageBase64: null,
        imageMime: null,
        isDefault: true,
        sortOrder: 0,
        updatedAt: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T/),
      });
    });

    it('creates an image account; GET answers the image back byte for byte', async () => {
      const body = imageAccount(JPEG, 'image/jpeg');
      expect((await create(body)).status).toBe(201);
      const res = await list();
      expect(res.status).toBe(200);
      expect(res.body.data).toHaveLength(1);
      expect(res.body.data[0]).toMatchObject({ kind: 'image', promptpayId: null, imageMime: 'image/jpeg' });
      expect(Buffer.from(res.body.data[0].imageBase64, 'base64').equals(JPEG)).toBe(true);
    });

    it('GET lists active rows only, by sortOrder then creation', async () => {
      const b = promptpay({ nickname: 'B', sortOrder: 1 });
      const a = promptpay({ nickname: 'A', sortOrder: 0 });
      const c = promptpay({ nickname: 'C', sortOrder: 1 });
      for (const x of [b, a, c]) expect((await create(x)).status).toBe(201);
      expect((await remove(c.id)).status).toBe(200);
      const res = await list();
      expect(res.body.data.map((x: { nickname: string }) => x.nickname)).toEqual(['A', 'B']);
    });

    it('PATCH changes only what is sent; kind cannot change', async () => {
      const body = promptpay();
      await create(body);
      const res = await patch(body.id, { nickname: 'ใหม่', promptpayId: '1234567890123' });
      expect(res.status, JSON.stringify(res.body)).toBe(200);
      expect(res.body.data).toMatchObject({ nickname: 'ใหม่', promptpayId: '1234567890123', bankCode: 'KBANK' });

      const kind = await patch(body.id, { kind: 'image' });
      expect(kind.status).toBe(400);
      expect(kind.body.error.message).toMatch(/cannot change/);
      const image = await patch(body.id, { imageBase64: PNG.toString('base64'), imageMime: 'image/png' });
      expect(image.status).toBe(400);
    });

    it('DELETE is a soft delete; a second DELETE / a PATCH of it is 404', async () => {
      const body = promptpay();
      await create(body);
      const res = await remove(body.id);
      expect(res.status).toBe(200);
      expect(res.body.data).toMatchObject({ id: body.id, deletedAt: expect.any(String) });
      const row = await admin.query(`SELECT deleted_at FROM payment_accounts WHERE tenant_id = $1::uuid AND id = $2`, [
        TENANT,
        body.id,
      ]);
      expect(row[0].deleted_at).not.toBeNull();
      expect((await remove(body.id)).status).toBe(404);
      expect((await patch(body.id, { nickname: 'x' })).status).toBe(404);
    });

    it('a client id already taken (even by a deleted row) is 409 CLIENT_ID_REUSED', async () => {
      const body = promptpay();
      await create(body);
      await remove(body.id);
      const res = await create({ ...body, nickname: 'อีกบัญชี' });
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('CLIENT_ID_REUSED');
    });

    it('every write needs an Idempotency-Key, and a resent key replays without a second row', async () => {
      const missing = await create(promptpay(), ownerToken, null);
      expect(missing.status).toBe(400);
      expect(missing.body.error.code).toBe('IDEMPOTENCY_KEY_INVALID');

      const body = promptpay();
      const key = randomUUID();
      const first = await create(body, ownerToken, key);
      const again = await create(body, ownerToken, key);
      expect(first.status).toBe(201);
      expect(again.status).toBe(201);
      expect(again.body.data).toEqual(first.body.data);
      const n = await admin.query(`SELECT count(*)::int AS n FROM payment_accounts WHERE tenant_id = $1::uuid`, [TENANT]);
      expect(n[0].n).toBe(1);
    });
  });

  describe('owner-only writes', () => {
    it('any shop user reads; a non-owner write is 403 OWNER_ONLY with the Thai message, and writes nothing', async () => {
      const body = promptpay();
      await create(body);
      const cashier = accessToken({ tenantId: TENANT, userId: shop.userId, role: 'cashier' });

      expect((await list(cashier)).status).toBe(200);
      for (const res of [
        await create(promptpay(), cashier),
        await patch(body.id, { nickname: 'x' }, cashier),
        await remove(body.id, cashier),
      ]) {
        expect(res.status).toBe(403);
        expect(res.body.error).toMatchObject({
          code: 'OWNER_ONLY',
          message: 'เฉพาะเจ้าของร้านเท่านั้นที่แก้ไขบัญชีรับเงินได้',
        });
      }
      const rows = await admin.query(`SELECT nickname, deleted_at FROM payment_accounts WHERE tenant_id = $1::uuid`, [TENANT]);
      expect(rows).toEqual([{ nickname: 'บัญชีร้าน', deleted_at: null }]);
    });

    it('needs no enrolled device: an owner session with no device token writes', async () => {
      // `ownerToken` carries no `did` at all.
      expect((await create(promptpay())).status).toBe(201);
    });
  });

  describe('the 5-active limit', () => {
    it('the sixth active account is 409 PAYMENT_ACCOUNT_LIMIT; a deleted one frees a slot', async () => {
      const ids: string[] = [];
      for (let i = 0; i < 5; i++) {
        const body = promptpay({ nickname: `บัญชี ${i}` });
        ids.push(body.id);
        expect((await create(body)).status).toBe(201);
      }
      const sixth = await create(promptpay());
      expect(sixth.status).toBe(409);
      expect(sixth.body.error).toMatchObject({
        code: 'PAYMENT_ACCOUNT_LIMIT',
        message: 'บันทึกบัญชีรับเงินได้สูงสุด 5 บัญชี',
      });
      await remove(ids[0]);
      expect((await create(promptpay())).status).toBe(201);
    });

    it('holds under concurrency: 8 creates at once on an empty shop → exactly 5 rows', async () => {
      const results = await Promise.all(Array.from({ length: 8 }, () => create(promptpay())));
      const statuses = results.map((r) => r.status).sort();
      expect(statuses).toEqual([201, 201, 201, 201, 201, 409, 409, 409]);
      const n = await admin.query(
        `SELECT count(*)::int AS n FROM payment_accounts WHERE tenant_id = $1::uuid AND deleted_at IS NULL`,
        [TENANT],
      );
      expect(n[0].n).toBe(5);
    });
  });

  describe('the default', () => {
    it('isDefault: true on POST or PATCH clears every other default in the same transaction', async () => {
      const a = promptpay({ isDefault: true });
      const b = promptpay({ isDefault: true });
      await create(a);
      expect(await defaults()).toEqual([a.id]);
      await create(b);
      expect(await defaults()).toEqual([b.id]);
      expect((await patch(a.id, { isDefault: true })).status).toBe(200);
      expect(await defaults()).toEqual([a.id]);
      const res = await list();
      expect(res.body.data.find((x: { id: string }) => x.id === b.id).isDefault).toBe(false);
    });

    it('concurrent "make default" requests still leave exactly one default', async () => {
      const accounts = Array.from({ length: 5 }, () => promptpay());
      for (const x of accounts) await create(x);
      const results = await Promise.all(accounts.map((x) => patch(x.id, { isDefault: true })));
      expect(results.every((r) => r.status === 200)).toBe(true);
      expect(await defaults()).toHaveLength(1);
    });

    it('deleting the default leaves the shop with no default', async () => {
      const a = promptpay({ isDefault: true });
      await create(a);
      await create(promptpay());
      await remove(a.id);
      expect(await defaults()).toEqual([]);
    });
  });

  describe('validation', () => {
    it.each([
      ['an unknown bank', { bankCode: 'XBANK' }],
      ['a PromptPay id with dashes', { promptpayId: '081-234-5678' }],
      ['a 9-digit PromptPay id', { promptpayId: '081234567' }],
      ['a 41-character nickname', { nickname: 'x'.repeat(41) }],
      ['an unknown kind', { kind: 'cash' }],
    ])('refuses %s with 400', async (_label, extra) => {
      const res = await create(promptpay(extra));
      expect(res.status).toBe(400);
    });

    it('refuses an image whose magic bytes do not match its mime, or a data: URL', async () => {
      const mismatch = await create(imageAccount(JPEG, 'image/png'));
      expect(mismatch.status).toBe(400);
      expect(mismatch.body.error.message).toBe('image bytes are not a image/png');
      const dataUrl = await create({ ...imageAccount(PNG), imageBase64: `data:image/png;base64,${PNG.toString('base64')}` });
      expect(dataUrl.status).toBe(400);
    });

    it('a malformed :id is 400 INVALID_ID before any SQL', async () => {
      const res = await patch('not-a-uuid', { nickname: 'x' });
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_ID');
    });
  });

  describe('the 1 MB body limit (owner token only)', () => {
    it('takes a 300 KB image (≈ 400 KB of JSON) from an owner, and refuses 1 byte more than 300 KB with 400', async () => {
      const atLimit = await create(imageAccount(pngOf(MAX_IMAGE_BYTES)));
      expect(atLimit.status, JSON.stringify(atLimit.body)).toBe(201);
      const over = await create(imageAccount(pngOf(MAX_IMAGE_BYTES + 1)));
      expect(over.status).toBe(400);
      expect(over.body.error.message).toBe(`image must be at most ${MAX_IMAGE_BYTES} bytes`);
    });

    it('a body over 1 MB is 413; a non-owner never gets past the 100 KiB default (413)', async () => {
      const huge = await create({ ...imageAccount(PNG), imageBase64: 'A'.repeat(1100 * 1024) });
      expect(huge.status).toBe(413);
      const cashier = accessToken({ tenantId: TENANT, userId: shop.userId, role: 'cashier' });
      const big = await create(imageAccount(pngOf(200 * 1024)), cashier);
      expect(big.status).toBe(413);
      const anonymous = await request(server())
        .post('/api/v1/payment-accounts')
        .set('Idempotency-Key', randomUUID())
        .send(imageAccount(pngOf(200 * 1024)));
      expect(anonymous.status).toBe(413);
    });
  });

  describe('tenant isolation (RLS)', () => {
    it("another shop neither sees, edits nor deletes this shop's account (404), and lists only its own", async () => {
      const mine = promptpay();
      await create(mine);
      const theirs = promptpay({ nickname: 'ร้าน B' });
      expect((await create(theirs, otherToken)).status).toBe(201);

      expect((await list(otherToken)).body.data.map((x: { id: string }) => x.id)).toEqual([theirs.id]);
      expect((await patch(mine.id, { nickname: 'ถูกแก้' }, otherToken)).status).toBe(404);
      expect((await remove(mine.id, otherToken)).status).toBe(404);
      const row = await admin.query(`SELECT nickname, deleted_at FROM payment_accounts WHERE id = $1`, [mine.id]);
      expect(row).toEqual([{ nickname: 'บัญชีร้าน', deleted_at: null }]);
    });
  });

  describe('POST /sales paymentAccountId', () => {
    const P = testId('pa-sale-product');
    const saleBody = (extra: Record<string, unknown> = {}) => ({
      id: newUuid(),
      subtotal: '100.00',
      discount: '0.00',
      total: '100.00',
      paymentMethod: 'โอน/QR',
      items: [{ lineNo: 1, productId: P, name: 'Part', qty: 1, price: '100.00' }],
      ...extra,
    });
    const sell = (body: Record<string, unknown>) =>
      request(server()).post('/api/v1/sales').set(auth(posToken)).set('Idempotency-Key', randomUUID()).send(body);
    const stock = async () =>
      Number((await admin.query(`SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`, [TENANT, P]))[0].stock);

    beforeEach(async () => {
      await seedOpenShift(admin, TENANT, shop.posDeviceId);
      await seedProduct(admin, TENANT, { id: P, partNo: 'PA-1', name: 'Part', price: 100, cost: 60, stock: 10 });
    });

    it('stores and answers the account on a โอน/QR bill; GET /sales/:id carries it', async () => {
      const account = promptpay();
      await create(account);
      const body = saleBody({ paymentAccountId: account.id });
      const res = await sell(body);
      expect(res.status, JSON.stringify(res.body)).toBe(201);
      expect(res.body.data.paymentAccountId).toBe(account.id);
      const read = await request(server()).get(`/api/v1/sales/${body.id}`).set(auth(posToken));
      expect(read.body.data.paymentAccountId).toBe(account.id);
    });

    it('a bill with no account stores null', async () => {
      const res = await sell(saleBody());
      expect(res.status).toBe(201);
      expect(res.body.data.paymentAccountId).toBeNull();
      const cash = await sell(saleBody({ paymentMethod: 'เงินสด' }));
      expect(cash.body.data.paymentAccountId).toBeNull();
    });

    it("accepts a soft-deleted account of this shop (chosen before the owner deleted it)", async () => {
      const account = promptpay();
      await create(account);
      await remove(account.id);
      const res = await sell(saleBody({ paymentAccountId: account.id }));
      expect(res.status).toBe(201);
      expect(res.body.data.paymentAccountId).toBe(account.id);
    });

    it("an unknown id, or another shop's, is 400 PAYMENT_ACCOUNT_NOT_FOUND — and no stock moves", async () => {
      const theirs = promptpay();
      await create(theirs, otherToken);
      for (const paymentAccountId of [testId('pa-never'), theirs.id]) {
        const res = await sell(saleBody({ paymentAccountId }));
        expect(res.status).toBe(400);
        expect(res.body.error).toMatchObject({
          code: 'PAYMENT_ACCOUNT_NOT_FOUND',
          message: 'ไม่พบบัญชีรับเงินที่เลือก กรุณาเลือกบัญชีใหม่',
        });
      }
      expect(await stock()).toBe(10);
    });

    it('an account on a non-โอน/QR bill is a 400', async () => {
      const account = promptpay();
      await create(account);
      for (const paymentMethod of ['เงินสด', 'เครดิตช่าง']) {
        const res = await sell(saleBody({ paymentMethod, paymentAccountId: account.id }));
        expect(res.status).toBe(400);
        expect(res.body.error.message).toMatch(/paymentAccountId is only allowed/);
      }
      expect(await stock()).toBe(10);
    });
  });

  describe('/sync/push sale.create paymentAccountId', () => {
    const P = testId('pa-sync-product');
    const push = (ops: unknown[]) =>
      request(server()).post('/api/v1/sync/push').set('X-Device-Token', POS_DEVICE_TOKEN).send({ outboxRemaining: 0, ops });
    const op = (saleId: string, payload: Record<string, unknown>) => ({
      opId: newUuid(),
      idempotencyKey: `k-${saleId}`,
      type: 'sale.create',
      payload: {
        id: saleId,
        date: new Date(Date.now() - 60_000).toISOString(),
        subtotal: '100.00',
        discount: '0.00',
        total: '100.00',
        items: [{ lineNo: 1, productId: P, name: 'Part', qty: 1, price: '100.00' }],
        ...payload,
      },
    });

    beforeEach(async () => {
      await admin.query(`UPDATE devices SET token_hash = $1 WHERE tenant_id = $2::uuid AND id = $3`, [
        createHash('sha256').update(POS_DEVICE_TOKEN).digest('hex'),
        TENANT,
        shop.posDeviceId,
      ]);
      await seedOpenShift(admin, TENANT, shop.posDeviceId);
      await seedProduct(admin, TENANT, { id: P, partNo: 'PA-2', name: 'Part', price: 100, cost: 60, stock: 10 });
    });

    it('never refuses a replay for the account: unknown → NULL, wrong method → dropped, malformed → dropped', async () => {
      const account = promptpay();
      await create(account);
      const theirs = promptpay();
      await create(theirs, otherToken);
      const cases: Array<[string, Record<string, unknown>, string | null]> = [
        [newUuid(), { paymentMethod: 'โอน/QR', paymentAccountId: account.id }, account.id],
        [newUuid(), { paymentMethod: 'โอน/QR', paymentAccountId: testId('pa-gone') }, null],
        [newUuid(), { paymentMethod: 'โอน/QR', paymentAccountId: theirs.id }, null],
        [newUuid(), { paymentMethod: 'เงินสด', paymentAccountId: account.id }, null],
        [newUuid(), { paymentMethod: 'โอน/QR', paymentAccountId: 'not-a-uuid' }, null],
      ];
      const res = await push(cases.map(([id, payload]) => op(id, payload)));
      expect(res.status).toBe(200);
      const results = res.body.data.results as Array<{ status: string; response: { paymentAccountId: string | null } }>;
      expect(results.map((r) => r.status)).toEqual(['applied', 'applied', 'applied', 'applied', 'applied']);
      expect(results.map((r) => r.response.paymentAccountId)).toEqual(cases.map(([, , want]) => want));
      for (const [id, , want] of cases) {
        const row = await admin.query(`SELECT payment_account_id FROM sales WHERE tenant_id = $1::uuid AND id = $2`, [
          TENANT,
          id,
        ]);
        expect(row[0].payment_account_id).toBe(want);
      }
    });
  });
});
