# Handoff: owner's answers to #187 and #191

**Date:** 2026-09-15 · **Follows:** `docs/handoff_log/owner-decisions-145-163.md` · **Issues:** #187, #191

The project owner answered both phase-2 architecture `question` issues in one session.
The agent scrutinized the options, trade-offs, and failure modes; the owner selected the binding policies.

---

## 1. Decisions

### #191 — POS offline while backoffice receives stock: pull on reconnect (ADR-0004 / ADR-0010)

| # | Question | Decision |
|---|---|---|
| 1 | Order on reconnect | **Push outbox first, then pull.** Server is the source of truth; once offline sales are applied on Postgres, pulled product stock reflects net inventory and directly overwrites Drift without client-side 3-way merge. |
| 2 | Partial push in progress | **Suppress stock pull/overwrite for products with pending writes in the outbox.** Prevents stock from bouncing upward falsely while remaining bills are pending. |
| 3 | `offlineOk` calculation | **Client computes `Products.offlineOk` from local threshold dynamically.** Allows cutting off offline sales immediately as local stock decrements during prolonged disconnects. |
| 4 | Sync cursor & read-back window | **Keyset pagination `(updated_at, id)` + 60-second read-back window.** Overcomes out-of-order transaction commits and clock skew (ADR-0009 30s allowance). Writing to Drift is idempotent. |
| 5 | Deletions | **Server returns tombstones (`deleted_at IS NOT NULL`) during sync pull.** Client marks/hides soft-deleted products in Drift accordingly. |

### #187 — Offline login/shift-open with PIN when token died overnight (ADR-0009)

| # | Question | Decision |
|---|---|---|
| 1 | Cached PIN material | **Cashier role on the `pos` device only.** **Owner/Admin PIN is NEVER cached** in browser storage, eliminating privilege escalation risk from client credential dumping. |
| 2 | Anti-brute force / Offline credential | **Device-bound PIN derivation + local throttling.** PIN is hashed using a client/device-specific salt (`deviceToken`), so a dumped IndexedDB hash cannot be used to attack the server PIN. Local rate limiting (e.g. 5 failed attempts locks with exponential backoff). |
| 3 | Offline shift permissions | **Sell `offlineOk` goods only; VOID is strictly forbidden.** Drawer cash counting is allowed locally; formal closing report and totals are confirmed upon reconnect and sync. |
| 4 | Offline session validity | **Expires at 04:00 next day (`tenants.timezone`).** The instant network restores, the app exchanges the offline state for a valid JWT session in the background. |
| 5 | Bind refresh token to device | **Yes, bind refresh token to `deviceToken`.** `/auth/refresh` on a `pos` device must present both tokens, neutralizing stolen tokens on different devices. |

---

## 2. What changed

- `docs/Backend_design/adr/0004-device-roles.md` — marked the open bullet on POS offline vs backoffice receiving stock as resolved (#191).
- `docs/Backend_design/adr/0009-jwt-session-lifetime.md` — amended phase-2 conflict section with the agreed threat model, cashier-only caching, device-bound offline PIN, and ticked the device token binding bullet (#187).
- `docs/Backend_design/adr/0010-client-write-through-cache.md` — added section 7 covering reconnect sync rules, cursor read-back window (60s), client `offlineOk` calculation, and tombstones; ticked read-back window and owner authority questions (#191).
