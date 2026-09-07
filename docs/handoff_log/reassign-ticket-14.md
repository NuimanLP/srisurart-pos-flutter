# Handoff: Reassign Ticket #14 to Team 1 based on Commit Author

**Date:** 2026-09-07  
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch `main`  
**Previous handoff:** [`lane-primer-breakdown.md`](lane-primer-breakdown.md)

---

## 1. Context & Rationale

During verification of commit history against assigned ticket ownership:
- Commit `c47c74e` (#14 `p1` compose stack) was authored and committed by `NuimanLP` (`NuiGates_2456`) in PR #41.
- However, Issue #14 was originally labelled `team/3` in the initial 3-way split planning document.
- The user requested: *"งั้นคุณปรับ อิงตามคนที่commit ticket 14"* (reassign ticket #14 to match the person who actually committed the work).

---

## 2. Changes Made

### A. GitHub Issues
- Ran `gh issue edit 14 --remove-label "team/3" --add-label "team/1"`.
- Issue #14 is now formally tagged `team/1` with Assignee `NuimanLP`.

### B. Documentation Updates
1. **[`docs/00_LANE_PRIMER.md`](../00_LANE_PRIMER.md):**
   - Added #14 to Lane A (`team/1` — NuimanLP) table.
   - Removed #14 from Lane C (`team/3` — PattaraponKitcharoen) table.
   - Updated the Critical Path diagram to `#14 (Team 1) ── สตาร์ทตู้คอนเทนเนอร์`.
   - Updated the One-page Cheat Sheet table to allocate #14 to Team 1.
2. **[`docs/Backend_design/adr/README.md`](../Backend_design/adr/README.md):**
   - Updated the 3-team bundle table: `team/1` now holds 10 backend tickets (#14, #18, #19, #20, #21, #22, #23, #24, #28, #30) and `team/3` holds 8 backend tickets (#4, #6, #31, #33, #34, #35, #36, #37).
   - Updated the critical path explanation.
3. **[`docs/Backend_design/05_HOW_WE_GOT_HERE.md`](../Backend_design/05_HOW_WE_GOT_HERE.md):**
   - Updated §8, §9, and §10 to reflect #14 under `team/1` (`NuimanLP`).
   - Updated notes to confirm `team/1`, `team/2`, and `team/3` handles are mapped.
4. **[`AGENTS.md`](../../AGENTS.md) & [`CLAUDE.md`](../../CLAUDE.md):**
   - Updated team description: `NuimanLP` (`team/1`, transaction path + #14 compose stack).
5. **[`HANDOFF.md`](../../HANDOFF.md):**
   - Logged the re-attribution of Issue #14 and doc sync.

---

## 3. Current Team Slices Distribution

| Team / Assignee | Backend Slices | CI/CD | Frontend | Decisions |
|---|---|---|---|---|
| **`team/1` (`NuimanLP`)** | #14, #18, #19, #20, #21, #22, #23, #24, #28, #30 *(10)* | #40 | Checkout, Returns, Drawer | #11 |
| **`team/2` (`LomerAlloys`)** | #15, #5, #16, #17, #25, #26, #27, #29, #32 *(9)* | #39 | Catalogue, Customers, Reports | — |
| **`team/3` (`PattaraponKitcharoen`)** | #4, #6, #31, #33, #34, #35, #36, #37 *(8)* | #38 | Auth, Device Token, Errors | #12, #13 |

The critical path dependency remains unchanged: `#14 ➡️ #15 ➡️ #4 ➡️ #6`.
