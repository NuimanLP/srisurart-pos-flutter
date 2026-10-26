# Session 2026-10-26 — k6 load test on the Raspberry Pi 5 (light, one machine)

Owner choice (2026-10-26): a light single-machine run, not the three-machine #380 method. **This ticks nothing in #380**
and does not replace the `02_API_SCREENS.md §9` evidence; it shows how the Pi itself behaves under a shop-sized load.

## Setup

- Host `pi5-pos` running release `8713c9f`; k6 `grafana/k6:2.3.0` (the digest pinned in `run-shard-test.sh`), scripts
  `server/test/k6/0*.js` from `develop` @ `3fd38b5`, `SHARD=1/1` (24 r/s budget, `lib/shard.js`).
- `loadtest-tenant` (`00000000-0000-4000-8000-000000000001`, plan `loadtest`) seeded **on the Pi** by running
  `test/k6/setup.ts` with Node 24 (type stripping) inside a throw-away container from the api image on the compose
  network: superuser URL, `REDIS_CACHE_URL` and `JWT_PRIVATE_KEY` read from the running containers, never leaving the
  Pi. Tenant `001` has a different id (checked first) and was not touched.
- A sampler on the Pi every 3 s: load, `vcgencmd` temperature + `get_throttled`, used RAM, `docker stats` per container.

## First finding — from the PC the run measures the Wi-Fi, not the Pi

`01-read-products.js` from the PC over Tailscale: p95 **34.5 s**, avg 7 s, 181 dropped iterations, 0 errors, while the
Pi's containers used 12% CPU (of 400%). On the Pi the same request took 13 ms and nginx logged `request_time` 3–4 ms.
The Pi's temporary Wi-Fi uplink delivered ~37 KB/s to the PC (2.9 MB `canvaskit.wasm` in 79 s; ping 35–65 ms). Every
counted run below therefore ran **on the Pi** (`docker run --network host`), still through nginx, TLS and the real
`perip` limiter; k6 itself used ~5% CPU at this rate.

## Results (on the Pi)

| Scenario | Load | Latency | Correctness | Pi peak |
|---|---|---|---|---|
| `01` read products | 24 r/s ramp, 35 s, 599 req | p95 **7.3 ms**, avg 5 ms ✅ (< 200 ms) | 0% errors, cache hit 99.8% ✅ | CPU 33% of 400%, 51.6 °C |
| `02` sale contention | `TOTAL_CONTENDERS=100` on 50 stock, ~2.5 s spread | p95 **933 ms** ❌ (> 500 ms), median 143 ms | 50 × 201 + 50 × 409 `INSUFFICIENT_STOCK`, stock 0, never negative, 50 distinct receipts, 0 × 5xx ✅ | CPU 58%, 54.9 °C |
| `03` idempotent replay | 9 VUs × 5 sends | p95 232 ms ✅ | 9 sales for 45 requests, replays return the same receipt ✅ | CPU 10% |
| `04` mixed 80/20 | 24 r/s, `DURATION=5m`, 5,490 req | p95 **16.5 ms**, max 61 ms ✅ (< 500 ms) | 0% errors; 1,119 sales, receipts distinct, stock never negative ✅ | CPU avg 29% / max 53%, RAM 1.8 GB of 8, 52.1 °C |

`throttled=0x0` in every sample. After all four: 1,178 sales = 1,178 distinct receipts = 1,178 movements, 0 negative
stock rows; tenant `001` sales still 0.

Reading `02`: 100 requests queue on one product row's lock by design (lock order in
`docs/rules/server-transactions-tenancy.md`), so latency grows with the queue; `mob04` showed p95 ≈ 3 s at 200
contenders (2026-10-05). A shop never has 100 buyers on one part number inside 2.5 s.

## Live re-run (owner watching, ~18:05 ICT)

Re-seeded, then `02` (`TOTAL_CONTENDERS=100`) and `04` (`DURATION=3m`) on the Pi with k6's live output in the owner's
terminal and `btop` beside it:

- `02`: 50 × 201 + 50 × 409, 0 × 5xx, p95 **67 ms** ✅ (median 13 ms). The first run's 933 ms came from a cold start
  (the first writes after an idle stack: connection pools and caches not warm) — the queue on one row lock is the same.
- `04`: 3,329 requests, p95 **16.7 ms**, 0% errors, 0 pool-exhaustion errors — matching the first run's 16.5 ms.
- Integrity: 711 sales = 50 + 661, 711 distinct receipts, 711 movements, 0 negative stock; tenant `001` untouched.
  Cleaned up the same way (below).

## Cleanup

- One transaction deleted every row with the loadtest `tenant_id` (all tables with that column, FK-safe passes) and the
  tenant; it refused unless the tenant's code was `loadtest-tenant`. After: `tenants` = `001` only, its user intact.
- Redis `redis-cache`: 805 `t:<loadtest id>:*` keys deleted, 0 left. k6 image removed from the Pi; `k6-env.json`
  (24 h tokens) deleted on the PC. `/health/ready` 200.

## Conclusion

The Pi has wide headroom for one shop: under the per-IP rate a whole shop shares, it stays at a third of its CPU and a
quarter of its RAM, with no thermal or power throttling. The limit that users will feel is the network: on the
temporary Wi-Fi, a device reaching the Pi over Tailscale from outside waits seconds per request. Shop devices on the
same LAN as the Pi do not cross that link. Check the shop's uplink on move day if remote access matters.
