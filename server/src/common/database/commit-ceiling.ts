import { performance } from 'node:perf_hooks';

/**
 * #213 — the commit guard behind ADR-0010's 30 s `?updatedSince=` rewind. The reasoning
 * and the exact guarantee live in `server/README.md` *The transaction ceiling (#213)*.
 */

/** A transaction older than this (from just before `BEGIN`) is rolled back, not committed. */
export const TX_COMMIT_CEILING_MS = 25_000;

/**
 * What migration `1788652802131` sets on `pos_app`. Checked once at boot, where a mismatch
 * only warns: a `pg_dump` without `--roles`/globals drops role-in-database settings.
 */
export const APP_ROLE_TIMEOUTS = {
  statement_timeout: '25s',
  idle_in_transaction_session_timeout: '5s',
} as const;

/** Thrown before `COMMIT` by a transaction past the ceiling. A 500: its fate is "not committed". */
export class CommitCeilingExceededError extends Error {
  constructor(elapsedMs: number, ceilingMs: number) {
    super(
      `transaction open ${Math.round(elapsedMs)} ms, past the ${ceilingMs} ms commit ceiling; rolled back (#213)`,
    );
    this.name = 'CommitCeilingExceededError';
  }
}

/** A monotonic start mark. Take it BEFORE `startTransaction()`, so Postgres `now()` is later. */
export function commitClockStart(): number {
  return performance.now();
}

/** Throws when the transaction started at `startedAt` is past `ceilingMs`. Call right before `COMMIT`. */
export function assertWithinCommitCeiling(startedAt: number, ceilingMs: number): void {
  const elapsed = performance.now() - startedAt;
  if (elapsed > ceilingMs) throw new CommitCeilingExceededError(elapsed, ceilingMs);
}
