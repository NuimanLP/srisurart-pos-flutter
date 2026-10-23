# Nginx, auth, tokens and rate limiting

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: `nginx.conf`, `auth.service.ts`, login/device tokens, platform allowlist, web token storage.

**Nginx / auth / rate limiting:**
- Nginx must be the only reverse proxy in front of the API — `trust proxy` is exactly
  `1` and `clientIp()` reads the rightmost `X-Forwarded-For` entry; a second proxy or
  CDN in front collapses every client onto one rate-limit bucket.
- Login throttles **before** it spends a DB connection and counts **before** it knows
  the outcome (one atomic Lua `INCR`); every refusal counts, a success only refunds its
  own IP attempt.
- An e2e file that logs in more than 10 times must send its own `X-Forwarded-For` per
  login (as `devices.e2e-spec.ts` does): the per-IP login bucket is 10/60 s and lives in
  the Redis every e2e file shares, so a fixed IP turns red by run order (#449).
- `platform-ui` reaches the API as `172.30.0.20`; that IP, the `allow` line in
  `nginx.conf` and `PLATFORM_ADMIN_IPS` change together or the UI gets a silent 403 —
  `07_CICD_DEPLOY.md` row "ดู platform-ui".
- Password verify is **NFC first, raw form as fallback** (`auth.service.ts`): NFC reorders
  Thai tone/below-vowel marks, and hashes made before #443 are of the raw string —
  dropping the fallback locks those owners out.


## From the phase-1 "Still open" log (binding rules)

- **Retired/unknown device token at login (#609, PR #611 + PR #613, 2026-10-05, deployed).**
  `POST /auth/token` with a `deviceToken` the server retired or does not know is
  `401 DEVICE_RETIRED` / `401 DEVICE_TOKEN_INVALID`, checked **before** the password
  (`auth.service.ts:112-125`); `DeviceTokenGuard` on `/sync/push` is unchanged. Client:
  `AuthRepository.login` clears the device token + offline PIN (compare-and-clear — only if
  the stored token is still the one sent; owner confirmed clearing the PIN, #609 comment
  5987543993) and throws `DeviceEnrolmentGoneException`; `AuthCubit` shows Backoffice plus
  the Thai string `AuthCubit.deviceEnrolmentGone` (ratified by the owner 2026-10-07, `02 §8.1.1`), and
  `init`/`_logout` no longer show a remembered `pos` role without a device token. Drift and
  the outbox are untouched; `ENROL_UNSENT_WORK` still guards a new enrolment. Not built:
  shop name on the badge, device-status check at app open (both need new API). #612
  (offline-PIN setup dialog read any 401 as a wrong password) closed 2026-10-06 (PR #625/#629:
  dead token → same path as #609; only 401 `UNAUTHORIZED` = wrong password). Browser profile
  holding another tenant's retired token showed `เครื่อง POS` and hid the enrol link — the
  bug this fixed; use Incognito for a demo until the build is on the profile.
- **Found by the study-pack review (PR #397), 2026-09-25 — all fixed same day:**
  #398 (`JWT_PLATFORM_SECRET` falls back to a public dev value) by PR #407, #399
  (`pos_app` can UPDATE/DELETE `audit_log` — should be append-only) by PR #406, #401
  (compose images not digest-pinned) by PR #403, #402 (closing report profit uses
  current cost, not `costAtSale` — ADR-0008) by PR #408, and **#400** (Flutter Web kept
  the access token in `localStorage`, against ADR-0009) by PR #404 + commit `68a6c2d`
  (issue closed 2026-09-25, verified 2026-09-27). The owner decision it waited on is
  recorded as the **ADR-0009 addendum 2026-09-25**: web access token in memory only,
  refresh/device token in IndexedDB, **no localStorage fallback** — if IndexedDB fails
  the user reloads; tokens a legacy build left in localStorage are migrated once
  (write, read back, then delete). Never reintroduce a localStorage fallback.
