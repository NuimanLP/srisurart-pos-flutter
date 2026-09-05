# Handoff: backend design → 30 GitHub issues + the three-way team split

**Date:** 2026-09-05
**Project path:** `D:\Beestation\Sri_POS\Flutter`
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch `main`
**Previous handoff:** [`grill-round2-ci.md`](grill-round2-ci.md)

## What this session was

Two things, in order:

1. **`/to-tickets backend`** — turn the backend design package into work an agent or a person
   can actually pick up. The three lane issues from the previous session (#7/#8/#9) were
   multi-week; nobody can grab one and merge it.
2. **A constraint arrived mid-session:** the professor requires **all three team members to
   touch frontend, backend and CI/CD.** That killed the one-lane-per-person plan recorded in
   `adr/README.md`, because all three lanes are backend. Everything was re-cut.

No code was written. This session produced issues and doc repairs only.

## Issue tracker — the shape it is now in

| | |
|---|---|
| **#2** | phase-1 program brief — full child tree + ownership table |
| **#3 #7 #8 #9 #10** | **parents.** Shared context only, `ready-for-agent` removed, retitled `(parent)` |
| **#11 #12 #13** | decisions a human must make, labelled `question` — deliberately **not** `ready-for-agent` |
| **#14–#40** | 27 implementable slices, one PR each |

Every "Blocked by" cites a real issue number, because issues were published in dependency
order and each body was substituted with the numbers already assigned.

### What was split, and why

| Was | Became | Reason |
|---|---|---|
| #3 `p1`+`p2` | #14 stack, #15 schema | Largest ticket in the set. `docker compose up` + a green `/health/live` is a demoable slice on its own |
| #7 Lane A | #18–#24 | Idempotency and document numbering are **deep modules** used by everything; building them inside `POST /sales` means inventing them under pressure |
| #8 Lane B | #16 #17 #25 #26 #27 #28 #29 #30 | Split by module, plus the closing report pulled out of reports (below) |
| #9 Lane C | #31–#37 | Cache module separated from its application, queue substrate from its handlers |
| #10 CI | #38 #39 #40 | One CI ticket meant one person owned CI — impossible under the new course rule |

### Two judgment calls worth re-reading before they surprise someone

1. **`POST /mechanics/:id/credit-payments` moved Lane B → Lane A** (now #24). It takes cash,
   issues a **CP** document number, and has to land in the shift's takings. Leaving it with
   mechanic CRUD would have put a money path in a lane with no transaction discipline. #8's
   header records the move.
2. **The closing report was pulled out of reports** (#30, separate from #29). Both of its
   formulas are wrong in ways that look right: expected cash silently omits **mechanics' cash
   repayments** (the drawer then shows a shortfall *every day* and staff stop trusting it),
   and gross profit must report **how many rows were estimated** from current cost rather than
   `cost_at_sale`. Riding along with six aggregation endpoints, both would get a cursory test.

### The three decision tickets

These are lifted from the "ยังค้างอยู่" list in `adr/README.md`. Making them issues shows what
they block instead of leaving them in a document nobody re-reads.

* **#11 `mechanics.total_credit`** — `01_DATABASE §7.1` requires `+= total` on a credit sale;
  the Dart reference **never writes the field at all**. An agent reading only the design doc
  will implement it and silently change a number the shop looks at. **Blocks #21.**
* **#12** — counter-facing Thai wording for `DEVICE_ROLE_FORBIDDEN` / `TENANT_SUSPENDED` /
  `OFFLINE_NOT_ALLOWED`. Blocks the string half of #4 and #6; the rest of both proceeds.
* **#13** — the pos-only endpoint list. ADR-0004 marks it "รอยืนยัน" and `02 §4.2` filled it in
  by **interpretation**. The guard returns `403` off this list, so wrong in either direction
  hurts. **Blocks #6, #24, #28.**

## The team split — replaces the lane split

**Course rule: every member touches frontend, backend and CI/CD.** Three cross-cutting bundles
of **9 backend + 1 CI + 1 frontend** each. Labels `team/1` `team/2` `team/3` are placeholders
for names.

| | `team/1` transaction path | `team/2` schema, catalogue, reports | `team/3` platform, infra, ops |
|---|---|---|---|
| Backend | #18 #19 #20 #21 #22 #23 #24 #28 #30 | #15 #5 #16 #17 #25 #26 #27 #29 #32 | #14 #4 #6 #31 #33 #34 #35 #36 #37 |
| CI/CD | #40 image artefact | #39 path filters + isolation check | #38 backend workflow |
| Frontend | Checkout / Returns / Cash Drawer (writes) | Products / Customers / PO / Quotes / Reports (reads) + Drift schema v3 | auth + device token, login, the 7 new error strings |
| Decisions to chase | #11 | — | #12 #13 |

* **The frontend column mirrors the backend column deliberately** — whoever built `POST /sales`
  wires Checkout to it. That is the cheapest way to make the client work real rather than
  commits added to satisfy a rubric.
* **`team/1` starts last, structurally.** The money path needs device roles (#6, `team/3`),
  which need the schema (#15, `team/2`), which needs the stack (#14, `team/3`).
  **#14 → #15 → #6 is the critical path** however the work is divided.

## Still open

| | |
|---|---|
| **Frontend tickets** | 🔴 **Do not exist.** The column above reserves the split; the work is task `q1` (ADR-0010) + Drift schema v3, prose in `03_ARCHITECTURE §8` only. Cut them **before** anyone finishes their backend bundle |
| Team labels | `team/1|2|3` are placeholders — remap to GitHub handles and set assignees |
| #11 #12 #13 | Need a human. #11 is on the critical path for `team/1` |
| Carried from before | `offlineOk` threshold (needs a real `sa_*` backup), production host (before `q4`), the 3 live agent-written report strings the parents have not read |

## State

Docs updated in this commit: `CLAUDE.md` (CI section was stale — it still claimed no
`workflows/` directory exists; plus a new "where the work lives" section) and
`docs/Backend_design/adr/README.md` (lane-split item struck, ticket map and team table added).

No server code exists. `server/` has not been created. The Flutter build is untouched by this
session, so the existing gate (`dart analyze` clean, `flutter test` 123/123) still stands.
