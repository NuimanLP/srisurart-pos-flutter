# Phase 2 — spec, lanes, ticket halves

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: phase-2 tickets, lane ownership, split tickets, the outbox/sync contract.

**Spec:** `docs/Backend_design/08_PHASE2_SPEC.md` (2026-09-15; owner decisions D1–D15,
E1–E11, F1–F10 in #240, map #243; merged as PR #254). Key shape: one `owner` role + one
active shop account per tenant, retire/enrol/export need an enrolled device token, no
`offlineOk` (column dropped), the `pos` device issues RC/CN online *and* offline,
`POST /sync/push` authenticates with the device token and replays by key then client id
before any check, multiple shifts per day, online void = reason only (no PIN), the
offline-PIN window is enforced till-side only, production = department VM `mob04` via
the hardened self-hosted runner. ADR-0004/0007/0009/0010/0013 carry dated phase-2
addenda.

**Lanes:** `docs/Backend_design/09_PHASE2_LANES.md` (2026-09-16, owner-approved; 35
issues under #243). Lane B (`team/2`, `LomerAlloys`) owns the whole on-device engine —
PWA/SW, `outbox_ops`, `SyncService`, RC/CN numbering, offline PIN, pull, and **every
Drift schema bump**. Lane C (`team/3`, `PattaraponKitcharoen`) owns the server + new
screens + ops. Lane A (`team/1`, `NuimanLP`) is 3 unblocking tickets — **all merged
2026-09-17**:
- **#268** (Thai copy, Option A) → PR #305 — 5 new error codes + 13 phase-2 UI strings
  in `02_API_SCREENS.md §8`/`§8.1`/`§8.1.1`, wired into `server_error_resolver.dart`.
- **#269** (`SyncFacade` seam) → PR #307 — `SyncFacade`/`NullSyncFacade`/`FakeSyncFacade`
  (`frontend/lib/data/sync/sync_facade.dart`) + all 18 `/sync/push` fixture JSONs
  (`docs/Backend_design/fixtures/sync-push/`) — the contract lane B/C build against.
- **#270** (platform allowlist) → PR #308 — `/api/v1/platform/` restricted to
  loopback/`PLATFORM_ADMIN_IPS`, `/sw.js` no-cache, `nginx-check` CI job.

🔴 Four issues are **halves** — read both before touching either: #228 ↔ #283,
#212 ↔ #277, #194 ↔ #285, #193 ↔ #287. 🔴 **Blocked-by never crosses a lane** — a
cross-lane need is a contract (fixtures, `SyncFacade`), never a queue. 🔴 An AC may
never claim "works against the real thing" while the other half of a split ticket is
unmerged. Every ticket ends with `09 §10`'s working agreement: `/scrutinize` the
approach → code per `karpathy-guidelines` → test only against your own side's fake →
close with `/code-review`. Read `docs/handoff_log/phase2-lane-split-and-tickets-2026-09-16.md`
for how the split was chosen.
