import { describe, expect, it } from 'vitest';
import { AuditService } from '../audit/audit.service.js';
import { runInRequestContext } from '../common/request-context.js';
import {
  changedFieldsOf,
  maskPromptPayId,
  PaymentAccountsService,
  type PaymentAccountRow,
} from './payment-accounts.service.js';

const TID = '00000000-0000-4000-8000-000000000676';
const ID = '01928d3e-0000-7000-8000-000000000001';
const OLD_DEFAULT = '01928d3e-0000-7000-8000-000000000002';
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const ACTOR = { userId: 'u-owner', deviceId: 'd-1', ip: '10.0.0.7' };

function row(over: Partial<PaymentAccountRow> = {}): PaymentAccountRow {
  return {
    id: ID,
    nickname: 'บัญชีร้าน',
    bank_code: 'KBANK',
    kind: 'promptpay',
    promptpay_id: '0812345678',
    image: null,
    image_mime: null,
    is_default: false,
    sort_order: 0,
    updated_at: new Date('2026-10-10T03:00:00Z'),
    deleted_at: null,
    ...over,
  };
}

interface AuditRow {
  action: string;
  entity: string;
  entityId: string;
  userId: string;
  deviceId: string;
  before: Record<string, unknown> | null;
  after: Record<string, unknown>;
}

/**
 * A scripted EntityManager. An `UPDATE … RETURNING` answers as TypeORM's postgres driver
 * does, `[rows, count]`, so a read of it that skips `returning()` fails here.
 */
function harness(opts: { current?: PaymentAccountRow; updated?: PaymentAccountRow; defaultWas?: string }) {
  const audits: AuditRow[] = [];
  const sql: string[] = [];
  const manager = {
    query: async (text: string, params: unknown[] = []) => {
      sql.push(text);
      if (text.includes('pg_advisory_xact_lock')) return [];
      if (text.includes('INSERT INTO audit_log')) {
        audits.push({
          userId: params[1] as string,
          deviceId: params[3] as string,
          action: params[4] as string,
          entity: params[5] as string,
          entityId: params[6] as string,
          before: params[7] === null ? null : JSON.parse(params[7] as string),
          after: JSON.parse(params[8] as string),
        });
        return [];
      }
      if (text.includes('SELECT 1 FROM payment_accounts')) return [];
      if (text.includes('count(*)')) return [{ n: 1 }];
      // clearDefault's `RETURNING id` (the account writes return every column).
      if (/RETURNING id\s*$/.test(text)) {
        const rows = opts.defaultWas ? [{ id: opts.defaultWas }] : [];
        return [rows, rows.length];
      }
      if (text.includes('INSERT INTO payment_accounts')) return [opts.updated];
      if (text.includes('SET deleted_at')) {
        return [[{ ...opts.current!, deleted_at: new Date('2026-10-10T04:00:00Z') }], 1];
      }
      if (text.includes('UPDATE payment_accounts SET')) return [[opts.updated], 1];
      if (text.includes('FROM payment_accounts')) return opts.current ? [opts.current] : [];
      throw new Error(`unscripted query: ${text}`);
    },
  };
  const tenants = { runTx: (fn: (m: unknown) => Promise<unknown>) => fn(manager) };
  const service = new PaymentAccountsService(tenants as never, new AuditService());
  const run = <T>(fn: (s: PaymentAccountsService) => Promise<T>) =>
    runInRequestContext({ tenantId: TID, manager: manager as never }, () => fn(service));
  return { audits, sql, run };
}

/** Neither the image bytes nor the whole PromptPay id may reach `audit_log`. */
function expectNoSecrets(a: AuditRow): void {
  const text = JSON.stringify(a);
  expect(text).not.toContain('0812345678');
  expect(text).not.toContain('1234567890123');
  expect(text).not.toContain(PNG.toString('base64'));
  expect(text).not.toMatch(/"image(Base64)?":/);
}

describe('PaymentAccountsService audit log', () => {
  it('create: one payment_account.created row, PromptPay id masked, old default named', async () => {
    const created = row({ is_default: true });
    const h = harness({ updated: created, defaultWas: OLD_DEFAULT });
    await h.run((s) =>
      s.create(ACTOR, {
        id: ID,
        nickname: 'บัญชีร้าน',
        bankCode: 'KBANK',
        kind: 'promptpay',
        promptpayId: '0812345678',
        image: null,
        isDefault: true,
        sortOrder: 0,
      } as never),
    );
    expect(h.audits).toHaveLength(1);
    const [a] = h.audits;
    expect(a).toMatchObject({
      action: 'payment_account.created',
      entity: 'payment_accounts',
      entityId: ID,
      userId: 'u-owner',
      deviceId: 'd-1',
    });
    expect(a.after).toEqual({
      id: ID,
      nickname: 'บัญชีร้าน',
      bankCode: 'KBANK',
      kind: 'promptpay',
      promptpayId: '******5678',
      isDefault: true,
      previousDefaultId: OLD_DEFAULT,
    });
    expectNoSecrets(a);
  });

  it('update: payment_account.updated with the changed field names, never the image', async () => {
    const current = row({ kind: 'image', promptpay_id: null, image: Buffer.from([1, 2, 3]), image_mime: 'image/png' });
    const updated = { ...current, nickname: 'สาขาสอง', image: PNG };
    const h = harness({ current, updated });
    const res = await h.run((s) =>
      s.update(ACTOR, ID, { nickname: 'สาขาสอง', image: { bytes: PNG, mime: 'image/png' } } as never),
    );
    expect(res.nickname).toBe('สาขาสอง');
    expect(h.audits).toHaveLength(1);
    const [a] = h.audits;
    expect(a.action).toBe('payment_account.updated');
    expect(a.after.changedFields).toEqual(['nickname', 'imageBase64']);
    expect(a.before).toMatchObject({ nickname: 'บัญชีร้าน', kind: 'image' });
    expectNoSecrets(a);
  });

  it('a PATCH that only sets the default is payment_account.default_changed', async () => {
    const current = row();
    const h = harness({ current, updated: { ...current, is_default: true }, defaultWas: OLD_DEFAULT });
    await h.run((s) => s.update(ACTOR, ID, { isDefault: true }));
    expect(h.audits.map((a) => a.action)).toEqual(['payment_account.default_changed']);
    expect(h.audits[0].after).toMatchObject({
      changedFields: ['isDefault'],
      isDefault: true,
      previousDefaultId: OLD_DEFAULT,
      promptpayId: '******5678',
    });
  });

  it('delete: payment_account.deleted with the deletion time', async () => {
    const h = harness({ current: row({ promptpay_id: '1234567890123' }) });
    const res = await h.run((s) => s.remove(ACTOR, ID));
    expect(res.deletedAt).toBe('2026-10-10T04:00:00.000Z');
    expect(h.audits).toHaveLength(1);
    expect(h.audits[0]).toMatchObject({ action: 'payment_account.deleted', entityId: ID });
    expect(h.audits[0].after).toMatchObject({
      promptpayId: '*********0123',
      deletedAt: '2026-10-10T04:00:00.000Z',
    });
    expectNoSecrets(h.audits[0]);
  });

  it('the audit row is written on the same manager, after the account write', async () => {
    const h = harness({ current: row() });
    await h.run((s) => s.remove(ACTOR, ID));
    const write = h.sql.findIndex((q) => q.includes('SET deleted_at'));
    const audit = h.sql.findIndex((q) => q.includes('INSERT INTO audit_log'));
    expect(write).toBeGreaterThanOrEqual(0);
    expect(audit).toBeGreaterThan(write);
  });
});

describe('maskPromptPayId / changedFieldsOf', () => {
  it('keeps only the last 4 digits', () => {
    expect(maskPromptPayId('0812345678')).toBe('******5678');
    expect(maskPromptPayId('123456789012345')).toBe('***********2345');
    expect(maskPromptPayId('123')).toBe('***');
    expect(maskPromptPayId(null)).toBeNull();
  });

  it('names nothing when nothing changed; compares an image by its bytes', () => {
    const a = row({ kind: 'image', promptpay_id: null, image: Buffer.from(PNG), image_mime: 'image/png' });
    expect(changedFieldsOf(a, { ...a, image: Buffer.from(PNG) })).toEqual([]);
    expect(changedFieldsOf(a, { ...a, sort_order: 2, bank_code: 'SCB' })).toEqual(['bankCode', 'sortOrder']);
  });
});
