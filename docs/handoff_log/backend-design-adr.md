# Handoff: backend design grill → ADR record + schema v2 (Srisurart POS Flutter)

**Date:** 2026-09-04
**Project path:** `/Users/chav_sir/Downloads/srisurart-pos-flutter`
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch `main`
**Commits:** `3bcc146` (docs/ADR) → `21e7434` (schema v2) → `92bd3bf` (reports fix)

## State: merged to local `main`, NOT pushed

All three commits are on local `main` (fast-forwarded from branch `backend-design-adr`,
which still exists). `dart analyze` clean, `flutter test` 123/123. **Not pushed to origin.**

## What this session was

A `/grill-with-docs` interview on the multi-tenant backend design — 4 rounds of
questions, 11 decisions taken, each written up as an ADR in
**`docs/Backend_design/adr/`** (start at its `README.md`). Two of those decisions
turned out to be implementable in Flutter immediately, so they were.

**Read `docs/Backend_design/adr/README.md` first** — it is the index, it lists what
each ADR changed in the main design docs, and it records the two places where an ADR
had to be corrected after contact with the existing docs. Do not re-derive that here.

## The rule that now governs the package

`CLAUDE.md` states: **where a doc contradicts an ADR, the ADR wins.** Docs 01–03 were
propagated to match, so there should be no live contradictions — but that rule is what
to fall back on if one is found.

## Contradictions that were in the design docs (all fixed — don't reintroduce)

1. `03_ARCHITECTURE §5` required "1 user = 1 tenant" while also describing platform ops
   that see every shop, with `users.tenant_id NOT NULL` — the platform operator could
   not be represented at all. Fixed by ADR-0002 (separate `platform_admins` table).
2. `devices.device_no (1..99)` and `doc_counters.device_id` were designed for several
   machines per shop, while §5/§7 argued from "the shop has one machine". Fixed by
   ADR-0004 (device *roles*, not a device count).
3. §7's claim that "conflict is structurally impossible because the shop has one
   machine" was wrong twice: nothing enforced one machine (it is a Flutter Web app —
   a second tab breaks it), and the claim is unnecessary anyway, because the phase-1
   acceptance test (200 concurrent sales against 50 stock → exactly 50) already proves
   concurrent machines are safe online. The genuine constraint is physical: **one cash
   drawer, one receipt-number series** — and unlike the stock argument, that one still
   holds at 100% online. Enforced by a partial unique index, not by assumption.

## Decisions a human still owes an answer on

From `00_INDEX.md` ("ตัดสินใจแทนไม่ได้") plus what this session added:

| | |
|---|---|
| `offlineOk` threshold | `stock ≥ max(5, 3×avg per bill)` is a guess; needs real sales data |
| **Thai error strings ×7** | `02_API_SCREENS §8.1` — the rule is that these are never invented by us. Still blank. |
| **Thai strings ×3 in the reports fix** | 🔴 **these WERE written from scratch this session** (no `db.js` original exists) — against the parity rule in `CLAUDE.md`. Listed at the end of ADR-0008. The shop owner should reword them. |
| Cutover timing | a business decision |
| Receipt format sign-off | ADR-0007 is decided, but the owner has not seen a printed sample |

Each ADR also carries its own "ยังไม่เคาะ" section — those are open too.

## Flutter work that landed (ADR-0008)

Drift `schemaVersion` 1 → 2, `onUpgrade` adds seven nullable columns:
`SaleItems.costAtSale`, and `updatedAt`/`deletedAt` on `Customers`/`Mechanics`/
`SettingsRow`. `updatedAt` is wired at all 8 mutation sites; `deletedAt` is a
tombstone slot that **nothing writes yet** — deletes are still hard deletes.

This clears the Phase-7b prerequisite CLAUDE.md had been tracking.

### Two things worth knowing before touching this area

* **`build_runner` ran fine here.** The `CLAUDE.md` warning is specifically about the
  Thai folder path on Windows; this checkout is on an ASCII path, so codegen works
  normally. Don't copy the repo elsewhere to run it.
* **`snapshot_repository` had been silently dropping `cost` from JS backups** even
  though the JS app recorded a cost per sale line. Import now keeps it, export emits
  it. Consequence: importing the shop's real backup **recovers historical cost**, so
  old bills are not uniformly `NULL` the way ADR-0008 first assumed.
* `products.updatedAt` is still never written by the app (pre-existing, not introduced
  here) — it only round-trips through snapshots. If phase-2 sync uses `?updatedSince=`
  on products, that must be wired first.

## Reports fix (`92bd3bf`) — this one changed what the shop sees

Monthly profit was computed against `products.cost`, which moves on every
weighted-average PO receive, so **last month's profit changed whenever new stock was
bought in**. And `costByPart[i.partNo] ?? 0` gave a deleted or renumbered product a
cost of 0 — which reads as 100% profit, so the number was *overstated*, not merely
approximate.

The CSV export had disclosed the limitation since it was written. The on-screen KPI
never did, and that is where people actually look.

Both now read `costAtSale` first. The JS `?? 0` tail is deliberately not reproduced.
The CSV gained a trailing `ที่มาของต้นทุน` column (`ณ วันที่ขาย` / `ต้นทุนปัจจุบัน` /
`ไม่มีข้อมูล`) — appended, so existing column positions are unchanged.

## Next actions, in order

1. **Push `main`** (nothing is on origin yet).
2. Get the Thai strings decided — it blocks nothing technically, but every one of them
   is user-facing text currently written by an agent or left blank.
3. **CI/CD**, which is what the user originally wanted after the design work.
   Inputs already exist: `docs/BACKEND_DEPLOYMENT.md §3` (Flutter Web → shop PC,
   Android/iOS), a `.github/` directory, and the course requirements (1-click
   `docker-compose`, Nginx + NestJS ×3, k6) which are themselves a CI/CD brief.
4. Backend implementation has not started. Nothing is built. The design is the
   deliverable so far.
