import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DB_URL =
  process.env.DATABASE_ADMIN_URL ??
  process.env.DATABASE_URL ??
  'postgres://postgres:dev-only-postgres@127.0.0.1:5432/pos';

export interface IntegritySnapshot {
  tenantId: string;
  productId: string;
  initialStock: number;
  currentStock: number;
  soldQty: number;
  totalBills: number;
  totalLines: number;
  movementDelta: number;
  totalSales: number;
  distinctReceipts: number;
}

export interface IntegrityCheck {
  name: string;
  passed: boolean;
  detail: string;
}

export interface IntegrityResult {
  checks: IntegrityCheck[];
  allPassed: boolean;
}

export interface EvaluateIntegrityOptions {
  /**
   * Require the contention target to be fully sold out: soldQty === initialStock,
   * stock === 0, sale_items qty sums to soldQty with one unit per line, movements
   * delta === -soldQty. This is the 200-on-50 scenario's whole point — 200 buyers
   * against 50 units of stock should end with nothing left — so a soldQty of 0
   * under this option is not a quiet "nothing happened yet", it means the
   * contention run never reached the server. Off by default so a caller checking
   * an in-flight/partial state (e.g. one sale out of many seeded units, see
   * k6.e2e-spec.ts) isn't forced into an end state it never claimed to reach.
   */
  expectFullDepletion?: boolean;
}

/**
 * Pure assertion logic — no I/O — so it can be unit-tested against a fake
 * snapshot instead of a live Postgres.
 */
export function evaluateIntegrity(
  s: IntegritySnapshot,
  options: EvaluateIntegrityOptions = {},
): IntegrityResult {
  const expectedStock = s.initialStock - s.soldQty;
  const checks: IntegrityCheck[] = [
    {
      name: 'Stock invariant (stock == initial - sold)',
      passed: s.currentStock === expectedStock,
      detail: `${s.currentStock} == ${s.initialStock} - ${s.soldQty} (${expectedStock})`,
    },
    {
      name: 'Stock non-negative (stock >= 0)',
      passed: s.currentStock >= 0,
      detail: `${s.currentStock} >= 0`,
    },
    {
      name: 'Receipt uniqueness (no duplicates, tenant-wide)',
      passed: s.totalSales === s.distinctReceipts,
      detail: `${s.totalSales} sales / ${s.distinctReceipts} distinct receipts`,
    },
  ];

  if (options.expectFullDepletion) {
    checks.push(
      {
        // The bug this catches: an all-429/all-500 contention run leaves
        // soldQty at 0, which trivially satisfies every check above.
        name: 'Contention target fully sold (sold == seeded stock)',
        passed: s.soldQty === s.initialStock,
        detail: `sold ${s.soldQty} units, seeded ${s.initialStock}`,
      },
      {
        name: 'Contention target fully depleted (stock == 0)',
        passed: s.currentStock === 0,
        detail: `stock ${s.currentStock}`,
      },
      {
        // Reads straight off sale_items rather than assuming a fixed quantity
        // per bill: soldQty is SUM(qty) and totalLines is COUNT(*) over the
        // same rows, so equality means every recorded line sold exactly 1 unit
        // — the actual qty the contention scenario's payload sends — without
        // hard-coding that "1" anywhere or inferring it from the bill count.
        name: 'sale_items qty sums to units sold (1 unit per line)',
        passed: s.totalLines === s.soldQty,
        detail: `${s.totalLines} sale_item lines, ${s.soldQty} units sold`,
      },
      {
        name: 'Stock movements balance (delta == -sold)',
        passed: s.movementDelta === -s.soldQty,
        detail: `${s.movementDelta} == -${s.soldQty}`,
      },
    );
  }

  return { checks, allPassed: checks.every((c) => c.passed) };
}

function printResult(s: IntegritySnapshot, result: IntegrityResult): void {
  console.log('\n================================================================');
  console.log('🔍 DATA INTEGRITY PROOF (Assignment & Rubric Verification)');
  console.log('================================================================');
  console.log(`Tenant ID:      ${s.tenantId}`);
  console.log(`Target Product: ${s.productId}`);
  console.log(`Initial Stock:  ${s.initialStock}`);
  console.log(`Timestamp:      ${new Date().toISOString()}`);
  console.log('----------------------------------------------------------------');
  console.log(`Current Stock in DB:              ${s.currentStock}`);
  console.log(`Total Units Sold (sale_items):     ${s.soldQty} (across ${s.totalBills} bills)`);
  console.log(`Stock Movements Balance (delta):   ${s.movementDelta}`);
  console.log(`Total Sales / Unique Receipts:      ${s.totalSales} / ${s.distinctReceipts}`);
  console.log('----------------------------------------------------------------');
  console.log('RESULTS & INVARIANT VERIFICATION:');
  for (const [i, c] of result.checks.entries()) {
    console.log(`${i + 1}. ${c.name}: ${c.passed ? '✅ PASS' : '❌ FAIL'} (${c.detail})`);
  }
  console.log('================================================================');
  if (result.allPassed) {
    console.log('🎉 ALL INTEGRITY CHECKS PASSED PERFECTLY!\n');
  } else {
    console.error('❌ INTEGRITY CHECK FAILED!\n');
  }
}

export async function verifyIntegrity(options: EvaluateIntegrityOptions = {}) {
  const envPath = path.resolve(__dirname, 'k6-env.json');
  if (!fs.existsSync(envPath)) {
    console.error('❌ k6-env.json not found. Run "pnpm k6:setup" first.');
    process.exit(1);
  }

  const envData = JSON.parse(fs.readFileSync(envPath, 'utf8'));
  const tenantId = envData.tenantId;
  const productId = envData.productId ?? 'p12';
  const initialStock = Number(envData.initialStock ?? 50);

  const pool = new pg.Pool({ connectionString: DB_URL });
  const client = await pool.connect();

  try {
    // 1. Current stock of the contention target
    const productRes = await client.query(
      `SELECT id, part_no, name, stock FROM products WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, productId],
    );
    if (productRes.rows.length === 0) {
      throw new Error(`Product ${productId} not found in database!`);
    }
    const currentStock = Number(productRes.rows[0].stock);

    // 2. Total sold quantity in sale_items
    const soldRes = await client.query(
      `SELECT COALESCE(SUM(si.qty), 0)::int as sold_qty,
              COUNT(DISTINCT si.sale_id)::int as total_bills,
              COUNT(*)::int as total_lines
       FROM sale_items si
       JOIN sales s ON s.tenant_id = si.tenant_id AND s.id = si.sale_id
       WHERE si.tenant_id = $1::uuid AND si.product_id = $2 AND s.voided_at IS NULL`,
      [tenantId, productId],
    );
    const soldQty = Number(soldRes.rows[0].sold_qty);
    const totalBills = Number(soldRes.rows[0].total_bills);
    const totalLines = Number(soldRes.rows[0].total_lines);

    // 3. Movement deltas
    const movRes = await client.query(
      `SELECT COALESCE(SUM(delta), 0)::int as movement_delta
       FROM movements
       WHERE tenant_id = $1::uuid AND product_id = $2`,
      [tenantId, productId],
    );
    const movementDelta = Number(movRes.rows[0].movement_delta);

    // 4. Check duplicate receipt numbers across tenant
    const receiptsRes = await client.query(
      `SELECT COUNT(*)::int as total_sales,
              COUNT(DISTINCT receipt_no)::int as distinct_receipts
       FROM sales
       WHERE tenant_id = $1::uuid`,
      [tenantId],
    );
    const totalSales = Number(receiptsRes.rows[0].total_sales);
    const distinctReceipts = Number(receiptsRes.rows[0].distinct_receipts);

    const snapshot: IntegritySnapshot = {
      tenantId,
      productId,
      initialStock,
      currentStock,
      soldQty,
      totalBills,
      totalLines,
      movementDelta,
      totalSales,
      distinctReceipts,
    };
    const result = evaluateIntegrity(snapshot, options);
    printResult(snapshot, result);

    if (!result.allPassed) {
      process.exitCode = 1;
    }

    return { ...snapshot, allPassed: result.allPassed };
  } finally {
    client.release();
    await pool.end();
  }
}

if (process.argv[1] && process.argv[1].endsWith('verify-integrity.ts')) {
  // `pnpm k6:verify` always runs against the 200-on-50 contention target, whose only
  // writer is 02-write-sales-contention.js — so it always checks for full depletion.
  verifyIntegrity({ expectFullDepletion: true })
    .then((res) => {
      if (!res.allPassed) process.exit(1);
    })
    .catch((err) => {
      console.error('Error during verification:', err);
      process.exit(1);
    });
}
