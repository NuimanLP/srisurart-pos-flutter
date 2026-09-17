# Handoff: owner's answers to #187 and #191 (reconciled)

**Date:** 2026-09-15 · **Follows:** `owner-decisions-145-163.md` · **Issues:** #187, #191 · **Supersedes:** PR #206 (closed), corrects PR #210

Two sessions recorded the owner's answers in parallel and disagreed (PR #206 open, PR #210 merged). The owner
chose #206's answers with three changes. The binding text is in the ADRs; this file only records what was chosen.

| Topic | #210 | #206 | **Final** |
|---|---|---|---|
| Who may use the offline PIN | any user | cashier only, never owner | **`cashier` only** (no owner/manager) |
| Offline PIN validity | 7 days | until 04:00 next day | **3 days** since last online login on that device |
| Partial push: stock of products with pending ops | server − pending | don't overwrite until pushed | **don't overwrite until pushed** |
| `offlineOk` | from server | computed on client | **computed on client** (03 §4 threshold vs local stock) |
| Cursor rewind | 5 s | 60 s | **30 s** (keyset + tombstones) |
| No void offline | – | forbid | **not adopted** — left open (ADR-0009 *ยังไม่เคาะ*) |
| Bind refresh to `deviceToken` | – | yes | **not adopted** — stays open |

Unchanged from both: separate offline PIN (never `users.pin_hash`), Degraded mode only, `/sync/push` re-checks every
`offline_pin` op, push outbox before pull, server is the source of truth once it accepts a bill, no `change_log`.

## Open, recorded in ADR-0009
- must the offline PIN differ from the online credential (a device-bound salt does not stop recovering the digits)
- after reconnect: re-login vs background JWT exchange (#206's proposal has no user credential to exchange)
- void while offline

## Tickets
- #211 offline PIN sign-in, #212 reconnect pull, #213 transaction ceiling (now < 30 s)
