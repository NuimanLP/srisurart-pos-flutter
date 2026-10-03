#!/usr/bin/env node
// Coverage ratchet (CI job "unit"): fails when unit-test LINE coverage of src/ drops below the
// committed floor in coverage-baseline.json. Run after `pnpm test:coverage`.
//
// The floor only ever goes up: when a PR raises coverage, raise "lines" in the same PR (the
// summary below prints the value to use). Lowering it to get a PR green defeats the point —
// add the missing tests instead.
import { appendFileSync, readFileSync } from 'node:fs';

const summary = JSON.parse(readFileSync('coverage/coverage-summary.json', 'utf8'));
const baseline = JSON.parse(readFileSync('coverage-baseline.json', 'utf8'));
const { pct, covered, total } = summary.total.lines;
const floor = Number(baseline.lines);
if (!Number.isFinite(floor) || typeof pct !== 'number') {
  console.error('::error::coverage-baseline.json "lines" or coverage-summary.json total.lines.pct is not a number');
  process.exit(1);
}
const ok = pct >= floor;
const suggested = Math.floor(pct);

const lines = [
  '### Server unit coverage (src/, lines)',
  '',
  '| measured | floor | result |',
  '|---|---|---|',
  `| ${pct.toFixed(2)}% (${covered}/${total}) | ${floor}% | ${ok ? 'pass' : '**below floor**'} |`,
  '',
  suggested > floor
    ? `Coverage rose: set \`"lines": ${suggested}\` in \`server/coverage-baseline.json\` to lock it in.`
    : '',
];
console.log(lines.join('\n'));
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${lines.join('\n')}\n`);

if (!ok) {
  console.error(
    `::error::server unit line coverage ${pct.toFixed(2)}% is below the committed floor ${floor}% (server/coverage-baseline.json) — add tests for the code this change adds`,
  );
  process.exit(1);
}
