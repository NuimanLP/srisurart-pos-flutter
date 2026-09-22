# Ticket #384 — `test.retire-replace-enrol`: enrol เครื่องแทนที่ผ่าน `POST /auth/device` จริง

**Date**: 2026-09-22
**Lane**: C (`team/3`, `PattaraponKitcharoen`)
**Branch**: `feat/384-retire-replace-enrol`
**Base**: `origin/main`
**Spec references**: [`03_ARCHITECTURE.md §8`](../Backend_design/03_ARCHITECTURE.md) (DoD line 12), [`ADR-0004`](../Backend_design/adr/0004-device-roles.md) ("การผูกเครื่อง"), [`ADR-0009`](../Backend_design/adr/0009-jwt-session-lifetime.md), [`session-2026-09-22-196-reaudit.md`](session-2026-09-22-196-reaudit.md) (the re-audit that untucked this DoD box and opened #384)

---

## Root cause

The `§8` DoD line *"owner กด `POST /devices/{id}/retire` เครื่อง `pos` ที่มีกะเปิดอยู่ → … enrol เครื่องใหม่ได้ `device_no` ใหม่ และขายได้"* was ticked on 2026-09-17 citing `server/test/shifts.e2e-spec.ts`, but the 2026-09-22 re-audit (#345→#196 follow-up) found the test never exercised enrolment:

```ts
// before — shifts.e2e-spec.ts:575
const replacementToken = accessToken({
  tenantId: TENANT, userId: fixture.userId, role: 'owner',
  deviceId: replacementId, deviceRole: 'pos',
});
```

It created the replacement device via `POST /devices`, then **minted a JWT by hand** instead of exchanging the `enrolCode` the API returned through `POST /auth/device`. Not one line called that route, and the `enrolCode` field in the response was read out of the body and never used. The comment in the test still claimed to cover the DoD line it did not test. What the test *did* prove (and still proves): retire closes the shift in the same transaction, the old token is refused with `DEVICE_ROLE_FORBIDDEN`, the old shift is intact in history, and the replacement device gets a new `device_no` and can sell. The one thing missing was the enrol path itself.

`server/test/devices.e2e-spec.ts:206` already covers "old token stops refreshing within 15 minutes" through the real enrol path, so that half of the DoD line did not need to be re-proven here — only the retire → replace → enrol → sell chain inside `shifts.e2e-spec.ts`.

## What changed

`server/test/shifts.e2e-spec.ts`, test `'a replacement pos device starts clean after the old one is retired'`:

1. Added `PASSWORD` constant and a `password_hash` update in `beforeEach` (same pattern as `devices.e2e-spec.ts`) — the replacement device now needs a real login, which needs a real password on the fixture user.
2. Replaced the `accessToken({...})` mint with the real chain:
   - `POST /api/v1/auth/device` with the `enrolCode` from `POST /devices` → `deviceToken` (`:588`)
   - Replay the same code → asserts `401` (single-use, `:594-597`)
   - `POST /api/v1/auth/token` with `{username, password, deviceToken}` → `replacementToken` (`:599-603`)
3. Added a stock-before/after assertion around the replacement device's sale (`10 → 9`) so the DoD phrase "ขายได้" is backed by a state change, not just a `201`.

No production code changed — this is a test-only fix. The gap was in what the test proved, not in the enrol/retire implementation itself.

## Falsification

Per the lane's working agreement (`09_PHASE2_LANES.md §10`), sabotaged the enrol call before restoring it, to confirm the new assertions actually catch a broken path rather than passing vacuously:

```diff
- .send({ code: enrolCode });
+ .send({ code: 'DEADBEEF' });
```

Result: `AssertionError: expected 401 to be 200` at the `enrol.status` assertion — the test goes red exactly where expected. Reverted before running the real suite.

## Verification results

- `vitest run --config ./vitest.config.e2e.ts test/shifts.e2e-spec.ts` — **25/25 passed**
- `vitest run --config ./vitest.config.e2e.ts test/devices.e2e-spec.ts` — **12/12 passed** (regression check; both files touch `POST /auth/device`)
- `pnpm lint` — clean (oxlint, exit 0)
- `pnpm typecheck` — clean (`tsc --noEmit`, exit 0)

## Docs updated in the same PR

- `docs/Backend_design/03_ARCHITECTURE.md §8` — DoD line 12 ticked back to `[x]`, citing `shifts.e2e-spec.ts:562` and the specific line numbers of the new assertions.
- `CLAUDE.md` — DoD count corrected from "17 boxes, 14 ticked, 3 open" to "17 boxes, 15 ticked, 2 open"; the two still open are `#380` (k6) and `#383` (redis-cache outage). `#384` is no longer listed as open.

## Not in scope

`#383` (`test.redis-cache-outage`, the other box the same re-audit opened) is a separate ticket — not touched here.
