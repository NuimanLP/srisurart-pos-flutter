import { readFileSync } from 'node:fs';
import { generateSyntheticSnapshot } from './fixtures/synthetic-snapshot.js';
import { checkSnapshotInvariants } from './support/snapshot-checks.js';

// #185: the synthetic shop snapshot stands in for the real one, so it must be exactly as
// self-consistent as a backup the Drift build writes — or a reconcile failure could be the
// generator's fault instead of the import's.
describe('synthetic shop snapshot (#185)', () => {
  it('is deterministic for a seed', () => {
    expect(JSON.stringify(generateSyntheticSnapshot({ seed: 7 }))).toBe(JSON.stringify(generateSyntheticSnapshot({ seed: 7 })));
    expect(JSON.stringify(generateSyntheticSnapshot({ seed: 7 }))).not.toBe(JSON.stringify(generateSyntheticSnapshot({ seed: 8 })));
  });

  it.each([
    ['small', 'clean'],
    ['full', 'clean'],
    ['full', 'realistic'],
  ] as const)('%s/%s keeps every ledger invariant', (scale, profile) => {
    const report = checkSnapshotInvariants(generateSyntheticSnapshot({ scale, profile }));
    expect(report.violations).toEqual([]);
    const orphanTotal = Object.values(report.orphans).reduce((a, b) => a + b, 0);
    if (profile === 'clean') expect(report.orphans).toEqual(Object.fromEntries(Object.keys(report.orphans).map((k) => [k, 0])));
    else expect(orphanTotal).toBeGreaterThan(0);
  });

  it('covers the cases the §9 checklist is about', () => {
    const s = generateSyntheticSnapshot({ scale: 'full' }) as Record<string, any>;
    expect(s.sa_products.length).toBeGreaterThanOrEqual(300);
    expect(s.sa_products.some((p: any) => p.zone && p.category === undefined)).toBe(true);
    expect(s.sa_products.some((p: any) => p.compat === null)).toBe(true);
    expect(s.sa_sales.some((x: any) => x.paymentMethod === 'เครดิตช่าง')).toBe(true);
    expect(s.sa_sales.some((x: any) => x.voided)).toBe(true);
    expect(s.sa_returns.some((r: any) => r.refundMethod === 'หักจากเครดิต')).toBe(true);
    expect(new Set(s.sa_pos.map((p: any) => p.status))).toEqual(new Set(['received', 'cancelled', 'open']));
    expect(new Set(s.sa_quotes.map((q: any) => q.status))).toEqual(new Set(['open', 'converted']));
    expect(s.sa_mechanics.some((m: any) => m.creditBalance > 0)).toBe(true);
    expect(s.sa_cash_drawer).not.toBeNull();
    expect(s.sa_shift_history.some((h: any) => h.autoArchived)).toBe(true);
    expect(s.sa_parked.length).toBeGreaterThan(0);
    // Several months of trading.
    expect(new Set(s.sa_sales.map((x: any) => x.date.slice(0, 7))).size).toBeGreaterThanOrEqual(4);
  });

  it('matches the sample committed for the Flutter importer test', () => {
    const committed = readFileSync(new URL('../../frontend/test/fixtures/synthetic_snapshot_small.json', import.meta.url), 'utf8');
    expect(committed.trim()).toBe(JSON.stringify(generateSyntheticSnapshot({ scale: 'small', profile: 'realistic' })));
  });
});
