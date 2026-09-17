import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

const TENANT_A = '28128128-1111-4281-8281-281281281111';
const TENANT_B = '28128128-2222-4281-8281-281281282222';

describe('owner review items (e2e) — Slice 6 (#281 review.1)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixtureA: TenantFixture;
  let fixtureB: TenantFixture;
  let keySeq = 0;

  const tokenA = () =>
    accessToken({
      tenantId: TENANT_A,
      userId: fixtureA.userId,
      role: 'owner',
    });

  const tokenB = () =>
    accessToken({
      tenantId: TENANT_B,
      userId: fixtureB.userId,
      role: 'owner',
    });

  const nextKey = () => `k-rev-${++keySeq}-${Date.now()}`;

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
    fixtureA = await resetTenant(admin, TENANT_A, { cache });
    fixtureB = await resetTenant(admin, TENANT_B, { cache });
  });

  afterAll(async () => {
    await app?.close();
  });

  beforeEach(async () => {
    await admin.query(`DELETE FROM owner_review_items WHERE tenant_id IN ($1, $2)`, [
      TENANT_A,
      TENANT_B,
    ]);
  });

  describe('GET /api/v1/review-items', () => {
    it('returns empty paginated list when no items exist', async () => {
      const res = await request(app.getHttpServer())
        .get('/api/v1/review-items')
        .set('Authorization', `Bearer ${tokenA()}`);

      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        status: 'success',
        data: [],
        meta: {
          total: 0,
          page: 1,
          limit: 50,
          totalPages: 1,
        },
      });
    });

    it('filters by status=pending by default, and supports status=reviewed and status=all', async () => {
      // Seed 2 pending, 1 reviewed in Tenant A
      await admin.query(
        `INSERT INTO owner_review_items (tenant_id, id, kind, ref_id, details, created_at, reviewed_at, reviewed_by)
         VALUES
           ($1, 'rev_1', 'void_offline', 'sale_101', '{"amount": 500}', now() - interval '2 minutes', NULL, NULL),
           ($1, 'rev_2', 'credit_override', 'sale_102', '{"limit": 2000}', now() - interval '1 minute', NULL, NULL),
           ($1, 'rev_3', 'shift_uncounted', 'shift_1', '{"uncounted": true}', now() - interval '3 minutes', now(), $2)`,
        [TENANT_A, fixtureA.userId],
      );

      // Default (status=pending)
      const resDefault = await request(app.getHttpServer())
        .get('/api/v1/review-items')
        .set('Authorization', `Bearer ${tokenA()}`);

      expect(resDefault.status).toBe(200);
      expect(resDefault.body.status).toBe('success');
      expect(resDefault.body.data).toHaveLength(2);
      expect(resDefault.body.data.map((x: { id: string }) => x.id)).toEqual(['rev_2', 'rev_1']);
      expect(resDefault.body.meta.total).toBe(2);

      // Explicit status=pending
      const resPending = await request(app.getHttpServer())
        .get('/api/v1/review-items?status=pending')
        .set('Authorization', `Bearer ${tokenA()}`);
      expect(resPending.status).toBe(200);
      expect(resPending.body.data).toHaveLength(2);

      // status=reviewed
      const resReviewed = await request(app.getHttpServer())
        .get('/api/v1/review-items?status=reviewed')
        .set('Authorization', `Bearer ${tokenA()}`);
      expect(resReviewed.status).toBe(200);
      expect(resReviewed.body.data).toHaveLength(1);
      expect(resReviewed.body.data[0].id).toBe('rev_3');
      expect(resReviewed.body.data[0].reviewedAt).not.toBeNull();
      expect(resReviewed.body.data[0].reviewedBy).toBe(fixtureA.userId);

      // status=all
      const resAll = await request(app.getHttpServer())
        .get('/api/v1/review-items?status=all')
        .set('Authorization', `Bearer ${tokenA()}`);
      expect(resAll.status).toBe(200);
      expect(resAll.body.data).toHaveLength(3);
      expect(resAll.body.meta.total).toBe(3);
    });

    it('rejects invalid status with 400', async () => {
      const res = await request(app.getHttpServer())
        .get('/api/v1/review-items?status=unknown')
        .set('Authorization', `Bearer ${tokenA()}`);

      expect(res.status).toBe(400);
      expect(res.body.error.message).toContain('status must be one of: pending, reviewed, all');
    });

    it('paginates results with page and limit parameters', async () => {
      await admin.query(
        `INSERT INTO owner_review_items (tenant_id, id, kind, ref_id, created_at)
         VALUES
           ($1, 'rev_p1', 'date_flag', 'sale_201', now() - interval '3 minutes'),
           ($1, 'rev_p2', 'date_flag', 'sale_202', now() - interval '2 minutes'),
           ($1, 'rev_p3', 'device_force_retired', 'dev_1', now() - interval '1 minute')`,
        [TENANT_A],
      );

      const resPage1 = await request(app.getHttpServer())
        .get('/api/v1/review-items?page=1&limit=2')
        .set('Authorization', `Bearer ${tokenA()}`);

      expect(resPage1.status).toBe(200);
      expect(resPage1.body.data).toHaveLength(2);
      expect(resPage1.body.data.map((x: { id: string }) => x.id)).toEqual(['rev_p3', 'rev_p2']);
      expect(resPage1.body.meta).toEqual({
        total: 3,
        page: 1,
        limit: 2,
        totalPages: 2,
      });

      const resPage2 = await request(app.getHttpServer())
        .get('/api/v1/review-items?page=2&limit=2')
        .set('Authorization', `Bearer ${tokenA()}`);

      expect(resPage2.status).toBe(200);
      expect(resPage2.body.data).toHaveLength(1);
      expect(resPage2.body.data[0].id).toBe('rev_p1');
    });
  });

  describe('POST /api/v1/review-items/:id/reviewed', () => {
    it('requires Idempotency-Key header', async () => {
      const res = await request(app.getHttpServer())
        .post('/api/v1/review-items/rev_1/reviewed')
        .set('Authorization', `Bearer ${tokenA()}`);

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_INVALID');
    });

    it('returns 404 when item does not exist', async () => {
      const res = await request(app.getHttpServer())
        .post('/api/v1/review-items/non_existent/reviewed')
        .set('Authorization', `Bearer ${tokenA()}`)
        .set('Idempotency-Key', nextKey());

      expect(res.status).toBe(404);
      expect(res.body.error.message).toContain('Review item not found');
    });

    it('marks pending item as reviewed, writes audit log, and does not touch money or stock', async () => {
      await admin.query(
        `INSERT INTO owner_review_items (tenant_id, id, kind, ref_id, details, created_at)
         VALUES ($1, 'rev_act', 'void_offline', 'sale_999', '{"reason": "wrong item"}', now())`,
        [TENANT_A],
      );

      const movementsBefore = await admin.query(
        `SELECT count(*)::int as n FROM movements WHERE tenant_id = $1`,
        [TENANT_A],
      );
      const drawerBefore = await admin.query(
        `SELECT count(*)::int as n FROM drawer_entries WHERE tenant_id = $1`,
        [TENANT_A],
      );

      const key = nextKey();
      const res = await request(app.getHttpServer())
        .post('/api/v1/review-items/rev_act/reviewed')
        .set('Authorization', `Bearer ${tokenA()}`)
        .set('Idempotency-Key', key);

      expect(res.status).toBe(200);
      expect(res.body.status).toBe('success');
      expect(res.body.data.id).toBe('rev_act');
      expect(res.body.data.kind).toBe('void_offline');
      expect(res.body.data.refId).toBe('sale_999');
      expect(res.body.data.details).toEqual({ reason: 'wrong item' });
      expect(res.body.data.reviewedAt).not.toBeNull();
      expect(res.body.data.reviewedBy).toBe(fixtureA.userId);

      // Verify DB row
      const dbRow = await admin.query(
        `SELECT reviewed_at, reviewed_by FROM owner_review_items WHERE tenant_id = $1 AND id = 'rev_act'`,
        [TENANT_A],
      );
      expect(dbRow[0].reviewed_at).not.toBeNull();
      expect(dbRow[0].reviewed_by).toBe(fixtureA.userId);

      // Verify audit log
      const audit = await admin.query(
        `SELECT action, entity, entity_id, user_id, after
           FROM audit_log
          WHERE tenant_id = $1 AND entity = 'owner_review_items' AND entity_id = 'rev_act'`,
        [TENANT_A],
      );
      expect(audit).toHaveLength(1);
      expect(audit[0].action).toBe('review_item.reviewed');
      expect(audit[0].user_id).toBe(fixtureA.userId);
      expect(audit[0].after).toMatchObject({ reviewedBy: fixtureA.userId });

      // Invariant: stock & money NOT touched
      const movementsAfter = await admin.query(
        `SELECT count(*)::int as n FROM movements WHERE tenant_id = $1`,
        [TENANT_A],
      );
      const drawerAfter = await admin.query(
        `SELECT count(*)::int as n FROM drawer_entries WHERE tenant_id = $1`,
        [TENANT_A],
      );
      expect(movementsAfter[0].n).toBe(movementsBefore[0].n);
      expect(drawerAfter[0].n).toBe(drawerBefore[0].n);

      // Idempotency: replay with same key returns cached response
      const resReplay = await request(app.getHttpServer())
        .post('/api/v1/review-items/rev_act/reviewed')
        .set('Authorization', `Bearer ${tokenA()}`)
        .set('Idempotency-Key', key);

      expect(resReplay.status).toBe(200);
      expect(resReplay.body.data.reviewedAt).toBe(res.body.data.reviewedAt);

      // Call with NEW key on already reviewed item returns 200 without extra audit log
      const resNewKey = await request(app.getHttpServer())
        .post('/api/v1/review-items/rev_act/reviewed')
        .set('Authorization', `Bearer ${tokenA()}`)
        .set('Idempotency-Key', nextKey());

      expect(resNewKey.status).toBe(200);
      expect(resNewKey.body.data.id).toBe('rev_act');
      expect(resNewKey.body.data.reviewedBy).toBe(fixtureA.userId);

      const auditCount = await admin.query(
        `SELECT count(*)::int as n FROM audit_log WHERE tenant_id = $1 AND entity_id = 'rev_act'`,
        [TENANT_A],
      );
      expect(auditCount[0].n).toBe(1);
    });
  });

  describe('tenant isolation (RLS)', () => {
    it('prevents tenant A from seeing or reviewing tenant B review items', async () => {
      // Seed an item in Tenant B
      await admin.query(
        `INSERT INTO owner_review_items (tenant_id, id, kind, ref_id, details)
         VALUES ($1, 'rev_tenant_b', 'void_offline', 'sale_b_1', '{"shop": "B"}')`,
        [TENANT_B],
      );

      // Tenant A listing pending items should NOT see rev_tenant_b
      const listResA = await request(app.getHttpServer())
        .get('/api/v1/review-items?status=pending')
        .set('Authorization', `Bearer ${tokenA()}`);

      expect(listResA.status).toBe(200);
      expect(listResA.body.data.map((x: { id: string }) => x.id)).not.toContain('rev_tenant_b');

      // Tenant A trying to mark Tenant B's item as reviewed gets 404
      const reviewResA = await request(app.getHttpServer())
        .post('/api/v1/review-items/rev_tenant_b/reviewed')
        .set('Authorization', `Bearer ${tokenA()}`)
        .set('Idempotency-Key', nextKey());

      expect(reviewResA.status).toBe(404);

      // Tenant B can mark its own item as reviewed
      const reviewResB = await request(app.getHttpServer())
        .post('/api/v1/review-items/rev_tenant_b/reviewed')
        .set('Authorization', `Bearer ${tokenB()}`)
        .set('Idempotency-Key', nextKey());

      expect(reviewResB.status).toBe(200);
      expect(reviewResB.body.data.id).toBe('rev_tenant_b');
      expect(reviewResB.body.data.reviewedBy).toBe(fixtureB.userId);
    });
  });
});
