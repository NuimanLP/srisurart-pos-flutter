# Session 2026-10-21 → 2026-10-22 — 10-angle review, fixes round 2, release #756

## Release
`develop` → `main` PR #756 (merge commit) = `main` `4b45093`, deployed to `mob04` (Deploy run `39774975792`, Ansible `failed=0`).
Verified over SSH: `.current_sha` = `4b45093…`, `/health/ready` 200, migration `RefreshFamilies1788652805300` applied (32 tables),
Prometheus targets `api-metrics`/`gatus`/`node` up (no `api-readiness`), 10 Grafana rules `inactive/ok`,
`POST /api/v1/auth/refresh` and `/auth/device` with junk → 401 (not 500).
**First real pre-migrate dump:** `/opt/pos/backups-pre-migrate/pos_backup_20261022_120235Z.sql.gz` (160 KB), `gzip -t` ok, sha256 ok.
The release also carried PO print (#747/#748), which another session had released as `8a7b350` earlier the same day.

## What changed (each PR had /code-review; review findings fixed before merge)
| PR | Change |
|---|---|
| #755 | `/auth/device` throttle: 10/IP/60 s + 100 failures/600 s global, counted before any DB connection, success refunds its own attempts; 429 `RATE_LIMITED` (ratified string). Fails open when redis-cache is down (like login). Enrol code format unchanged (8 chars, ratified wording). |
| #755 | Single-use refresh tokens: `refresh_families` (one row per login chain, RLS FORCE + NULLIF), `fid` claim. Current token rotates; the just-replaced token gets the current one back **once**, only while current is unpresented, within 24 h; anything else revokes the chain (401 + audit `refresh_reused`). Pre-deploy tokens are covered only from their first post-deploy refresh. **ADR-0009 addendum 2026-10-22 is `agent ร่าง` — owner must ratify (it reverses "no rotation").** |
| #753 | Returns / drawer-entry id reuse → replay (same content) or 409 `CLIENT_ID_REUSED`, never 500. `quotes/purge` enqueues after commit (reply still waits for Redis when redis-queue is down — same as sales/returns; timeout = follow-up). Image queue capped at 4 waiters → 503 `IMAGE_BUSY` + `Retry-After` (string `agent ร่าง`, copied from ratified `RATE_LIMITED`). `/sync/push` drawer balance via `expectedCashSatangOf`. |
| #754 | `10_SALE_PHOTO_EVIDENCE.md §4` contract row for `IMAGE_BUSY` (merged before #753). |
| #752 | PO save/receive/cancel/delete + quote save/duplicate parked in `PendingWrites`; no invented id/PO/QT numbers (`UNREADABLE_RESPONSE`); `PO_ALREADY_RECEIVED` after an unknown-fate receive = success after re-read; a parked sale counts in `outboxRemaining` (close button disabled) and blocks `closeShift` while < 10 min old. |
| #751 | `api-readiness` scrape job removed (Prometheus 3 refused its JSON; always down, unused). |

## Corrections / verified claims from the 10-angle review
- The "production JWT key leaked" CRITICAL was **false**: normalized key bodies differ (agent hashed only the BEGIN line).
- `http_requests_total` empty after the upgrade = no traffic since restart, not broken names (series appear after one request).

## Still open
- Owner: ratify ADR-0009 addendum (refresh rotation) and the `IMAGE_BUSY` Thai string.
- Not fixed (LOW / follow-ups): `updateQuote`/`deleteQuote`/`purgeOldQuotes` still mint a key per call; an unsent return does not block shift close; post-commit enqueue has no timeout; `PATCH /settings` lost-update; migration `1788652804600` edited after reaching main (likely never on mob04); import image sweep without grace on failure.
- Owner decisions from round 1 still pending: rotate the k6 remote-write password, read-only `backup-ro` key for the PC pull, encrypt dumps before they leave the VM (`age`), `certs-ca` backup, second nightly backup, team-owned dead-man's switch, fresh-host DR rehearsal (#363 AC3).
- UX (R10): degraded banner 12 px, price-override button 28 px, compact segmented/ icon buttons < 48 px, camera button without label.
- Docs (R9): CLAUDE.md is ~1200 lines; proposed split into `docs/rules/*.md` + `docs/status.md`.
- Upgrades (R8): Node 22 → 24 before 2027-04; pin `grafana/k6`; Flutter 3.47; go_router 18.
