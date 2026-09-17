import { describe, it, expect } from 'vitest';
import { evaluateIntegrity, type IntegritySnapshot } from './verify-integrity.js';

const TENANT_ID = '00000000-0000-4000-8000-000000000001';

// The exact end state `pnpm k6:setup` + a successful 02-write-sales-contention.js
// run should leave behind for the 200-on-50 scenario: 200 buyers against 50
// seeded units of the contention target sell it out completely, each buying 1 unit.
const FULL_DEPLETION_SNAPSHOT: IntegritySnapshot = {
  tenantId: TENANT_ID,
  productId: 'p12',
  initialStock: 50,
  currentStock: 0,
  soldQty: 50,
  totalBills: 50,
  totalLines: 50,
  movementDelta: -50,
  totalSales: 50,
  distinctReceipts: 50,
};

// What `pnpm k6:setup` alone leaves behind — no k6 scenario has run against
// the server at all, e.g. because every request 429'd or 500'd. Every
// pre-existing check (stock == initial - sold, stock >= 0, no duplicate
// receipts) is trivially true here, which is exactly the bug: this snapshot
// used to read as "ALL PASS".
const EMPTY_RUN_SNAPSHOT: IntegritySnapshot = {
  tenantId: TENANT_ID,
  productId: 'p12',
  initialStock: 50,
  currentStock: 50,
  soldQty: 0,
  totalBills: 0,
  totalLines: 0,
  movementDelta: 0,
  totalSales: 0,
  distinctReceipts: 0,
};

describe('evaluateIntegrity — expectFullDepletion (pnpm k6:verify default)', () => {
  it('fails loudly on an empty run (nothing reached the server)', () => {
    const result = evaluateIntegrity(EMPTY_RUN_SNAPSHOT, { expectFullDepletion: true });

    expect(result.allPassed).toBe(false);
    const failed = result.checks.filter((c) => !c.passed).map((c) => c.name);
    expect(failed).toContain('Contention target fully sold (sold == seeded stock)');
    expect(failed).toContain('Contention target fully depleted (stock == 0)');
  });

  it('fails when the contention run sold a count that does not match the seeded stock', () => {
    // Some requests reached the server but the run was cut short — 30 of 50 sold.
    const partial: IntegritySnapshot = {
      ...FULL_DEPLETION_SNAPSHOT,
      currentStock: 20,
      soldQty: 30,
      totalBills: 30,
      totalLines: 30,
      movementDelta: -30,
      totalSales: 30,
      distinctReceipts: 30,
    };

    const result = evaluateIntegrity(partial, { expectFullDepletion: true });

    expect(result.allPassed).toBe(false);
    const failed = result.checks.filter((c) => !c.passed).map((c) => c.name);
    expect(failed).toContain('Contention target fully sold (sold == seeded stock)');
  });

  it('fails when sale_items lines and units sold diverge (e.g. a qty != 1 line, or a duplicate line)', () => {
    // 50 units sold across only 49 sale_item rows — one line recorded qty=2 (or a
    // row is missing), either way the "1 unit per line" invariant does not hold,
    // and it's read straight from sale_items rather than assumed from bill count.
    const mismatched: IntegritySnapshot = { ...FULL_DEPLETION_SNAPSHOT, totalLines: 49 };

    const result = evaluateIntegrity(mismatched, { expectFullDepletion: true });

    expect(result.allPassed).toBe(false);
    expect(result.checks.find((c) => c.name.startsWith('sale_items qty sums'))?.passed).toBe(
      false,
    );
  });

  it('fails when the movements ledger does not balance against units sold', () => {
    const mismatched: IntegritySnapshot = { ...FULL_DEPLETION_SNAPSHOT, movementDelta: -49 };

    const result = evaluateIntegrity(mismatched, { expectFullDepletion: true });

    expect(result.allPassed).toBe(false);
    expect(result.checks.find((c) => c.name.startsWith('Stock movements balance'))?.passed).toBe(
      false,
    );
  });

  it('passes on the full expected dataset for the 200-on-50 scenario', () => {
    const result = evaluateIntegrity(FULL_DEPLETION_SNAPSHOT, { expectFullDepletion: true });

    expect(result.allPassed).toBe(true);
    expect(result.checks.every((c) => c.passed)).toBe(true);
  });
});

describe('evaluateIntegrity — default (no expectFullDepletion)', () => {
  it('still passes on an in-flight partial state (k6.e2e-spec.ts: 1 of 50 sold)', () => {
    const partial: IntegritySnapshot = {
      tenantId: TENANT_ID,
      productId: 'p12',
      initialStock: 50,
      currentStock: 49,
      soldQty: 1,
      totalBills: 1,
      totalLines: 1,
      movementDelta: -1,
      totalSales: 1,
      distinctReceipts: 1,
    };

    const result = evaluateIntegrity(partial);

    expect(result.allPassed).toBe(true);
  });

  it('does NOT catch an empty run — full depletion must be requested explicitly', () => {
    // Documents the boundary: only the CLI's expectFullDepletion:true mode is
    // strict enough to catch a zero-sold contention run.
    const result = evaluateIntegrity(EMPTY_RUN_SNAPSHOT);

    expect(result.allPassed).toBe(true);
  });

  it('still catches a broken stock accounting invariant regardless of mode', () => {
    const corrupted: IntegritySnapshot = { ...FULL_DEPLETION_SNAPSHOT, currentStock: 5 };

    const result = evaluateIntegrity(corrupted);

    expect(result.allPassed).toBe(false);
  });
});
