// Shared shard + per-IP rate-limit safety math for the distributed k6 run (#251).
//
// nginx (server/docker/nginx/nginx.conf) admits at most `limit_req zone=perip rate=30r/s
// burst=60 nodelay` PER SOURCE IP on /api/. Every k6 VU on one laptop shares that laptop's
// one IP, so a single k6 process must never plan for more than a safe fraction of that
// bucket — see docs/handoff_log/close3-demo-deploy-2026-09-15.md §4.1 and issue #251. The
// derivation of every constant below, and how each scenario uses this file, is documented
// in server/test/k6/README.md "Per-shard math".
//
// Opt-in only: a script calls into this file only when SHARD is set. With no SHARD env var
// every scenario runs exactly as it did before #251 (single machine, direct-to-app, or any
// other already-working path) — nothing here changes that default behaviour.

// server/docker/nginx/nginx.conf: `limit_req_zone $binary_remote_addr zone=perip:10m rate=30r/s;`
// and `limit_req zone=perip burst=60 nodelay;` on every /api/ location.
export const NGINX_RATE_PER_IP = 30; // r/s
export const NGINX_BURST_PER_IP = 60; // requests

// Margins below the raw nginx numbers. Real timing jitters — network, the VM's own load, a
// laptop's clock drifting under load — so budgeting for the whole bucket leaves zero room for
// that jitter to still read as a clean (zero-429) run. Every per-shard number in this file is
// derived from just these two.
const RATE_SAFETY_MARGIN = 0.8; // 80% of the sustained rate
const BURST_SAFETY_MARGIN = 0.75; // 75% of the burst allowance

export const SAFE_RATE_PER_SHARD = NGINX_RATE_PER_IP * RATE_SAFETY_MARGIN; // 24 r/s
export const SAFE_BURST_PER_SHARD = NGINX_BURST_PER_IP * BURST_SAFETY_MARGIN; // 45 requests

// A burst spread wider than this stops being "a burst" (the scenario is testing contention /
// a near-simultaneous replay, not a slow trickle) — past this, reduce the total or add shards.
const MAX_SPREAD_SECONDS = 5;

// Parses `SHARD=i/N` (1-indexed i, N total shards). Returns null when SHARD is unset — the
// caller's cue to skip every safety check and run its original, non-distributed behaviour.
export function parseShard(raw) {
  if (raw === undefined || raw === null || raw === '') return null;
  const m = /^(\d+)\/(\d+)$/.exec(String(raw).trim());
  if (!m) {
    throw new Error(`SHARD must look like "i/N" (1-indexed), got ${JSON.stringify(raw)}`);
  }
  const index = Number(m[1]);
  const count = Number(m[2]);
  if (count < 1 || index < 1 || index > count) {
    throw new Error(`SHARD "${raw}" is out of range: 1 <= i <= N required (got i=${index}, N=${count})`);
  }
  return { index, count };
}

export function shardFromEnv(env) {
  return parseShard(env.SHARD);
}

// Divides `total` fairly across `count` 1-indexed shards so the parts sum to exactly `total`:
// the low-index shards each absorb one extra unit of the remainder.
export function divideCount(total, index, count) {
  const base = Math.floor(total / count);
  const remainder = total % count;
  return base + (index <= remainder ? 1 : 0);
}

// The smallest jitter window (seconds) over which `count` near-simultaneous requests from one
// shard stay inside nginx's bucket at the safety margin: SAFE_BURST_PER_SHARD instantly, plus
// SAFE_RATE_PER_SHARD refilling every second the window is open. Never returns less than
// `floorSeconds` (the scenario's own original spread, when that's already safe).
// Throws when even MAX_SPREAD_SECONDS isn't enough — at that point the request count needs
// more shards or a lower total, not a wider window.
export function minSafeSpreadSeconds(count, floorSeconds, label) {
  if (count <= SAFE_BURST_PER_SHARD) return floorSeconds;
  const needed = ((count - SAFE_BURST_PER_SHARD) / SAFE_RATE_PER_SHARD) * 1.1; // +10% margin
  const window = Math.max(floorSeconds, needed);
  if (window > MAX_SPREAD_SECONDS) {
    throw new Error(
      `${label}: ${count} requests from one shard need a ${window.toFixed(2)}s spread to stay ` +
        `under nginx's per-IP bucket at the safety margin (burst<=${SAFE_BURST_PER_SHARD}, ` +
        `rate<=${SAFE_RATE_PER_SHARD}r/s) — past ${MAX_SPREAD_SECONDS}s this isn't a burst test ` +
        `any more. Add shards (raise SHARD's N) or lower the total.`,
    );
  }
  return window;
}

// For burst scenarios with no adjustable spread (e.g. 03's fixed 0.05s replay rounds): fail
// fast rather than silently exceed the bucket and have the resulting 429s misread as a stock
// or idempotency bug.
export function assertBurstSafe(count, label) {
  if (count > SAFE_BURST_PER_SHARD) {
    throw new Error(
      `${label}: ${count} near-simultaneous requests from one shard exceeds the safe burst ` +
        `budget of ${SAFE_BURST_PER_SHARD} (${BURST_SAFETY_MARGIN * 100}% of nginx's ` +
        `burst=${NGINX_BURST_PER_IP}). Raise SHARD's N (more machines) or lower the total so ` +
        `ceil(total/N) <= ${SAFE_BURST_PER_SHARD}.`,
    );
  }
}

export function assertRateSafe(ratePerSecond, label) {
  if (ratePerSecond > SAFE_RATE_PER_SHARD) {
    throw new Error(
      `${label}: ${ratePerSecond}r/s exceeds the safe per-shard rate of ${SAFE_RATE_PER_SHARD}r/s ` +
        `(${RATE_SAFETY_MARGIN * 100}% of nginx's rate=${NGINX_RATE_PER_IP}r/s). Lower the rate override.`,
    );
  }
}
