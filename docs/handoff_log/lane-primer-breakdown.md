# Handoff: Architecture & 40-Ticket 3-Lane Breakdown Primer

**Date:** 2026-09-07
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch `main`
**Previous handoff:** [`monorepo-root-cleanup.md`](monorepo-root-cleanup.md)

## 1. Context & Motivation

Following the reorganization of the repository into `frontend/`, `server/`, and `docs/`, the team needed a plain-language, beginner-friendly primer explaining what the ~40 GitHub issues/tickets do, why they are split into 3 cross-cutting lanes/teams, and how the entire system fits together.

The request: *"สรุปมาซิ เเต่ละ laneของ ticket 40ตัว โดยประมาณ เเต่ละlane ทำอะไร เอาเเบบเด็กกระโปกเข้าใจ ปูพื้นฐานมาก่อนนะ ทำเป็น .md เอาคล้าย architecture-primerก็ได้"*

## 2. Summary of What Was Created

Created [`docs/00_LANE_PRIMER.md`](../00_LANE_PRIMER.md) covering:

1. **Foundational Architecture Primer (The 4 Building Blocks):**
   - **Frontend (Flutter):** The tablet/web UI for the cashier and shop staff.
   - **Backend (NestJS):** The central business rules and transaction manager.
   - **Database (PostgreSQL):** The source-of-truth ledger with 27 tables and Row-Level Security (RLS).
   - **Cache & Queue (Redis + BullMQ):** High-speed read cache and asynchronous background job pipeline.
   - **Multi-tenant concept explained:** Analogy of a 100-room apartment building where each room has its own lock, completely isolated from neighbors.

2. **The 3-Lane Team Division (Mandated by Course Rule):**
   - Every collaborator touches Frontend + Backend + CI/CD.
   - **Lane A (`team/1` — NuimanLP):** The Money & Cashier Path + Compose Stack (#14, #18, #19, #20, #21, #22, #23, #24, #28, #30, #40 + decision #11 + Frontend checkout/returns).
   - **Lane B (`team/2` — LomerAlloys):** The Warehouse, Catalogue & Reporting Path (#15, #5, #16, #17, #25, #26, #27, #29, #32, #39 + Frontend catalogue/PO).
   - **Lane C (`team/3` — PattaraponKitcharoen):** The Security, Infrastructure & Platform Path (#4, #6, #31, #33, #34, #35, #36, #37, #38 + decisions #12, #13 + Frontend auth/login).

3. **Critical Path Domino Sequence:**
   - `#14 (Stack: Docker/Compose)` ➡️ `#15 (DB Schema & RLS)` ➡️ `#4 & #6 (Auth & Device Roles)` ➡️ `#18–#20 (Sales & Transaction Core)`.
   - Explains why `team/1` structurally starts last after infra and schema are established.

4. **The 3 Open Decisions (#11, #12, #13):**
   - Explained why these are question tickets requiring human input from the shop/course rather than agent guesswork.

5. **Cheat Sheet:**
   - Single-page quick lookup table mapping each ticket number, purpose, and assigned team.

## 3. Reference Updates

- Added `docs/00_LANE_PRIMER.md` as the #1 recommended reading item in [`README.md`](../../README.md).
- Updated [`HANDOFF.md`](../../HANDOFF.md) with links to this handoff document and the new primer.
