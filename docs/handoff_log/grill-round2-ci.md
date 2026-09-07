# Handoff: grill round 2 → ADR-0010/0011 + first CI (Srisurart POS Flutter)

**Date:** 2026-09-04
**Project path:** `/Users/chav_sir/Downloads/srisurart-pos-flutter`
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch `main`
**Commit:** `946c405`

## What this session was

A second `/grill-with-docs` interview, this time scoped to **the project as a whole**
rather than the backend design. 8 rounds. It produced 11 decisions, 2 ADRs, a set of
doc repairs, and the repo's **first CI workflow**.

The previous session's handoff is [`backend-design-adr.md`](backend-design-adr.md);
this one continues from it and closes three of the four items it left open.

## The decisions

| | |
|---|---|
| Deliverable | **Both** — the shop's real POS *and* the course assignment |
| Scope | **No cuts.** Build through cutover (phase 1 + phase 2, ~100 days of work) |
| Schedule | **No delivery date.** The `§8` Gantt is a dependency checklist, not a calendar |
| `server/` | Lives in this repo — [ADR-0011](../docs/Backend_design/adr/0011-monorepo.md) |
| Client ↔ Drift | Write-through cache, mapped at the repository boundary — [ADR-0010](../docs/Backend_design/adr/0010-client-write-through-cache.md) |
| Receipt format | `RC01-2569-08-0042` **approved as-is** (ADR-0007 sign-off, was open) |
| Thai error strings | 7 agent drafts **accepted** to unblock implementation (see caveat below) |
| Phase-1 host | Faculty VM + Docker — **demo only, unconfirmed** |
| CI | **Level 3** (gate + integration + artifact); deploy step deliberately unwired |
| Deleted plan docs | **Not recovered** |
| Lane assignment | Project owner takes **Lane A** (sales + returns) |

### Context that came out of the interview and is worth knowing

* The project owner is the **shop's successor owner and the developer**. Every ADR that
  ended "the shop owner must decide" was therefore answerable in-session — that is why
  the receipt format, cutover timing and Thai strings all closed at once.
* **The parents run the shop day to day.** They are the people who actually read the Thai
  UI. That distinction matters for the string caveat below.
* `docs/Summary_backend/AGENTS.md` documents a **real working NestJS project** (Assignment
  06: Nginx ×3, Postgres primary/replica, Redis + Lua locks, migrations, e2e). It was
  briefly considered as the base for `server/`. **Rejected — it is a faculty lab, ignore it.**
  `server/` starts clean.

## Contradictions and errors found (all fixed in `946c405`)

1. **`CLAUDE.md` pointed at two deleted files in five places.** `docs/PLAN.md` and
   `docs/BACKEND_DEPLOYMENT.md` were deleted in `ec24f79`. The previous handoff had named
   `BACKEND_DEPLOYMENT §3` as an existing **input for the CI/CD work** — so the brief was
   gone. Decision: do not recover. The references are removed and the loss is now recorded
   explicitly.
   🔴 **Consequence to carry forward: deployment/hosting has no owning document.** §3 was
   the only part of that file never superseded by the backend package. Host notes now live
   temporarily at the end of `03_ARCHITECTURE.md §8`.
2. **The design package contradicted itself about the client.** `§8`'s Gantt described
   task `q1` as *"Flutter ApiRepository (**แทน** Drift repos)"* — replace. But `§4`
   (Architecture C, the chosen architecture) requires the client to *"cache สินค้า +
   โควตาสต็อกไว้ในเครื่อง"* while online and to sell from that cache while degraded.
   Following the Gantt literally would have deleted the working offline layer in `q1` and
   rebuilt it in `q2`. → **ADR-0010**, and the Gantt wording is fixed.
3. **`.github/workflows/` did not exist.** `CLAUDE.md` said it was "still empty". Only
   `.github/modernize/java-upgrade/hooks/` was there.
4. **`00_INDEX.md` still warned that docs 01–03 were un-propagated**, which
   `adr/README.md` explicitly says was completed. Also linked to the deleted file.
5. `main` was already pushed; the previous handoff said it was not.

## The CI workflow — `.github/workflows/flutter.yml`

**Four checks across three jobs** (`analyze-and-test` carries two of them).
**All were run locally before committing; none is speculative.**

| Job | Verified |
|---|---|
| `dart analyze --fatal-infos` | clean, no issues |
| `flutter test` | **123/123 pass** |
| `build_runner` vs the committed `*.g.dart` | **no diff** |
| `flutter build web` + assert `sqlite3.wasm` / `drift_worker.js` reach `build/web` | both present |

Two of these exist for reasons specific to this repo:

* **The codegen job matters more than it looks.** The shop's checkout lives on a Thai
  (non-ASCII) path on Windows where `build_runner` cannot run, so the `*.g.dart` files are
  committed. CI runners are ASCII paths, which makes this **the only place the generated
  code is ever checked against the schema.**
* **The web-asset assertion** guards a silent failure: a version skew between `web/sqlite3.wasm`
  / `web/drift_worker.js` and the `sqlite3` / `drift` pub versions breaks the web DB at boot
  with no build error.

`paths-ignore` keeps these jobs off `server/`-only and docs-only changes (ADR-0011).
**There is no deploy step** — the production host is undecided, by decision, until before `q4`.

## The Thai-string caveat — read this before shipping

`02_API_SCREENS §8.1`'s rule is *ห้ามแต่งข้อความไทยเอง*. The 7 strings there are now filled,
but they were **drafted by an agent and accepted by the project owner to unblock work** —
they are not `db.js` parity. The table and `00_INDEX.md` both say so.

🔴 **Three of them appear at the counter with a customer waiting** and still need the shop's
own wording: `DEVICE_ROLE_FORBIDDEN`, `TENANT_SUSPENDED`, `OFFLINE_NOT_ALLOWED`.

Separately, the **3 strings from the previous session's reports fix are already live** in
`products_screen.dart` / `settings_screen.dart` and were also agent-written. The parents have
not read them.

## The ordered checklist (no dates — this is what replaced the schedule)

**Before any server code**
1. ✅ Flutter CI gate — *done, `946c405`*
2. ✅ Strip dead doc refs from CLAUDE.md — *done*
3. ✅ ADR-0010 + ADR-0011, Gantt wording, Thai strings — *done*
4. ✅ **Confirm the faculty VM accepts inbound connections from outside the university network** — *confirmed by the project owner 2026-09-04 (grill round 3); single VM, 4 vCPU / 6 GB / 30 GB — spec recorded in `03_ARCHITECTURE.md §8`*

**Server foundation — one dependency chain, the project owner's**
5. `p1` compose + Nginx + NestJS skeleton — **two Redis** (`cache` = `allkeys-lru`, `queue` = `noeviction` + AOF)
6. `p2` schema + TypeORM migrations + seed — 28 tables, `platform_admins`, `one_pos_per_tenant`
7. **CI level 2** — Postgres + Redis service containers, as soon as `p2` exists
8. `p3` auth (ADR-0009) + tenancy guard + RLS + cross-tenant → 0 rows test
9. `p3b` admin plane + `POST /platform/tenants` (ADR-0001/0002), one transaction
10. `p3c` device roles + guard (ADR-0004)

**Parallel lanes** (B and C unassigned)
* **A —** `p5` sales + returns: transactional, idempotent, `cost_at_sale`, all 3 stock errors in one response
* **B —** `p4` CRUD → `p6` PO/quotes/shifts → `p7` reports
* **C —** `p8` Redis cache → `p8b` rate limit → `p9` BullMQ + Bull-Board **with auth** → `p9b` export job → `p10` k6

11. Phase 1 closes on the 12 done-criteria in `03_ARCHITECTURE §8`

**Phase 2 — client**
12. Wire `products.updatedAt` (never written today; `?updatedSince=` breaks without it)
13. `q1` `ApiRepository` — write-through, mapped at the repository boundary, screens untouched
14. `q2` outbox + SyncService + `offlineOk` — needs the threshold computed from real sales data
15. `q3` reconciliation screen + shop manual
16. **Decide the production host** — before `q4`, not during
17. `q4` cutover

## Still open — deliberately

| | |
|---|---|
| `offlineOk` threshold | Compute from a real `sa_*` backup JSON before `q2`. None is in the repo. |
| Production host | Due before `q4`. Faculty VM is demo-only. |
| Lane B / Lane C | Unassigned. Note week 1 (`p1`→`p3`) is a single chain nobody can parallelize. |
| Counter-facing Thai wording | 3 server errors + the 3 live report strings |

Plus the "ยังไม่เคาะ" section at the end of each ADR — including two new ones in ADR-0010
(client cache invalidation policy, and whether online reads are stale-while-revalidate).

## State

`946c405` is on local `main`, **not pushed** (1 ahead of `origin/main`).
`dart analyze` clean, `flutter test` 123/123, `flutter build web` ok.
No server code exists. `server/` has not been created.
