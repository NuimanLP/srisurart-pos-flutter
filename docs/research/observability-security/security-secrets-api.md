# Security gap analysis: secrets and API

> Research doc, written 2026-09-29 on branch `claude/addon-logs-security-monitoring-997144`.
> **This is a recommendation, not a decision.** Anything that changes a repo or GitHub setting, or
> how secrets reach `mob04`, is an owner call (see "Open questions"). Nothing in this doc was
> changed in the repo or on GitHub. Every GitHub setting quoted below was read with `gh api` on
> 2026-09-29 (read-only). Anything not confirmed against a primary source or the repo is marked
> **UNVERIFIED**.

## TL;DR

🔴 **Headline finding: the docs and the real GitHub settings disagree.**
`docs/Backend_design/07_CICD_DEPLOY.md:183` records *"Secret scanning + push protection ✅"*, and
`docs/Backend_design/adr/0013-cicd-toolchain.md:52` says the same (*"เปิด secret scanning + push
protection"*). `.github/dependabot.yml` says security updates stay on.
`gh api repos/NuimanLP/srisurart-pos-flutter` on 2026-09-29 says otherwise.
- `secret_scanning`, `secret_scanning_push_protection`, `secret_scanning_non_provider_patterns`,
  `secret_scanning_validity_checks` and `dependabot_security_updates` are all **`disabled`**.
- Dependabot alerts return **404** (off).
- CodeQL default setup is **`not-configured`**.

The repo is public, so all of these are free. Fix the setting or fix the two docs, but they must
agree.

Apart from that, the repo is well defended *in code*: RLS, argon2, token audiences, pino redaction,
dev-secret boot refusal, Trivy, pnpm audit, OSV-Scanner, digest-pinned images, Nginx rate limits,
Helmet and page caps. The remaining gaps are cheap Nginx/CI items. **None of the recommendations
adds anything to the VM** (see "VM budget").

| # | Gap | Recommended | Runner-up | Effort | Priority |
|---|---|---|---|---|---|
| 1 | Dependabot alerts + security updates off, so `dependabot.yml` currently yields nothing between CI runs | Turn on **Dependabot alerts** and **Dependabot security updates** | Rely on existing CI `pnpm audit` / OSV-Scanner only (catches new CVEs only when CI runs) | S (owner clicks) | **P0** |
| 2 | Repo-level secret scanning + push protection off (docs say on). User-level push protection is on by default for public repos, which is why this is P1, not P0. | Turn on **GitHub Secret Protection** (alerts + repo-level push protection) in Settings → Advanced Security | — (no substitute for a server-side push block) | S (owner clicks) | P1 |
| 3 | No secret scan of git history / no CI gate | **gitleaks** in CI (`gitleaks-action@v3` with `fetch-depth: 0`, which also covers full history) + optional local pre-commit hook | trufflehog (AGPL, live verification) | S | P1 |
| 4 | Nginx: no `server_tokens off` / security headers on the web app | Add `server_tokens off`, `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options` | Rely on Helmet (covers `/api/*` only, not the static web app) | S | P1 |
| 5 | No SAST | **CodeQL default setup** (JS/TS + Actions; no workflow file) | Semgrep CE (`semgrep scan --config auto`) | S | P1 |
| 6 | `CORS_ORIGINS` unset on `mob04`, so the API reflects any Origin. There are no cookies (Bearer only, ADR-0009), so the exploit value is low. | Put `CORS_ORIGINS` in `DEMO_ENV_FILE`, re-run `provision.yml` (#367 already built the plumbing) | — | S | P2 |
| 7 | Third-party Actions pinned by tag, not commit SHA (`aquasecurity/trivy-action@v0.36.0`, `google/osv-scanner-action/…@v2.5.1`, `dorny/paths-filter@v4`, `subosito/flutter-action@v2`, `docker/login-action@v4`) | Pin third-party actions to a full commit SHA with the tag as a comment | Pin only the ones that see secrets (`docker/login-action`, the deploy path) | S | P2 |
| 8 | No versioned record of which keys `DEMO_ENV_FILE` must hold; the values live only on the laptop that last ran `provision.yml` | **`deploy/demo.env.example`** (key names only, no values) + the values in a **team password manager** | SOPS + age in the repo (optional, see §A.2) · Ansible Vault | S | P2 |
| 9 | No written rotation runbook for DB/Redis/etcd/Grafana/k6 passwords (JWT has one in ADR-0009) | A runbook section in `07 §8`, owner-approved, per secret | — | S (doc) / M (drill) | P2 |
| 10 | Nginx `client_body_timeout` / `client_header_timeout` at the 60 s default | Lower to ~10 s | — | S | nice-to-have |
| 11 | No DAST | **Skip for now**; revisit only if the server ever emits OpenAPI | ZAP baseline scan against a throwaway **CI** stack | M–L | P3 |
| 12 | No WAF | **Do not add** (see §B.4) | ModSecurity v3 + OWASP CRS | L | not recommended |
| — | HSTS | **Skip until the host has a real DNS name** (see §B.5) | — | — | deferred |
| — | `deploy` user is in group `docker` (root-equivalent; can read every container's env with `docker inspect`) | **Known limit, no fix required** (see §A.2) | — | — | accepted |

Effort: S ≈ under half a day, M ≈ 1–3 days, L ≈ a week or more. Priority P0 = before the `mob04`
demo (#343/#344), P1 = this phase, P2 = before cutover (#231), P3 = later.

---

## 1. What already exists (inventory)

### Secrets

| Control | Where | Notes |
|---|---|---|
| Boot refusal of dev/public secrets unless `ALLOW_DEV_SECRETS=true` | `server/src/config/config.ts:45-104` (`DEV_ONLY_PREFIX`, sha256 of the dummy RS256 pair, `refusePublicSecret`) | #410/PR #412. `vm.override.yml` forces it empty on `mob04` (CLAUDE.md). |
| `JWT_PLATFORM_SECRET` has no public fallback | `config.ts:193-194` | #398/PR #407 |
| `JWT_PRIVATE_KEY` only on processes that serve `/auth/*` | `config.ts:206-209`; ADR-0009 line 96 | worker / migrate / Bull-Board never get it |
| JWT key rotation by `kid` (multi-key `JWT_PUBLIC_KEYS`) | ADR-0009 line 98; `server/src/auth/jwt-keys.service.ts` | Procedure written; never drilled (not found in handoff logs — **UNVERIFIED**) |
| `PLATFORM_ADMINS` plaintext dropped from `process.env` after use; sync errors log no hash | `server/src/main.ts:40` (`delete process.env.PLATFORM_ADMINS`); `describeSyncError` used at `main.ts:37` | #443 |
| pino redaction of auth header, cookie, `x-device-token`, and 10 secret body fields | `server/src/common/logger.ts:18-51` (`REDACT_PATHS`) | Bodies are not logged at all; redaction is defence in depth |
| `.env` on the VM written 0600 with `no_log: true`, `--diff` forbidden | `deploy/ansible/provision.yml:190-198`; CLAUDE.md | Source is `DEMO_ENV_FILE` from the operator's shell |
| Pre-flight: `DEMO_ENV_FILE` must carry every required key | `provision.yml:158-176` | #506 |
| Redis `--requirepass`, no datastore ports published | `server/docker-compose.yml:279-310` | |
| Platform-ui, Bull-Board, Grafana bound to host loopback only (reach via `ssh -L`) | platform-ui `server/docker-compose.yml:141`, Bull-Board `:253`, Grafana `deploy/compose/monitoring.yml:114` | Bull-Board also has Basic auth (`server/src/bull-board.ts:38-50`) |
| Web access token in memory only, refresh/device token in IndexedDB, no localStorage fallback | ADR-0009 addendum 2026-09-25 | #400 |
| `.trivyignore` forbidden | ADR-0013; `server.yml:20` | |

### API / supply chain

| Control | Where |
|---|---|
| Tenant isolation by Postgres RLS + tenant from token only | migrations `1788652800001-RowLevelSecurity.ts`, `…002-AuthSecurityDefinerAndAuditFix.ts`; `common/tenant-scope.middleware.ts`; architecture specs `tenant-door.spec.ts`, `tenant-wrapper.spec.ts` |
| argon2 password hashing, 12-char floor, common-password list | `server/src/common/password.ts`, `common-passwords.ts`; #364 |
| Login throttle before DB, per IP (10/60 s) via atomic Lua `INCR` | `server/src/auth/auth.service.ts` + `rate-limit/`; CLAUDE.md |
| Per-tenant rate limit guard | `server/src/rate-limit/tenant-rate-limit.guard.ts` (ADR-0006) |
| Nginx per-IP limit 30 r/s burst 60, 429 | `server/docker/nginx/nginx.conf:25-26, 98, 103` |
| Body size: Nest default 100 KiB; 10 MiB only for a verified platform token on the import route; Nginx `client_max_body_size 10m` | `server/src/app.setup.ts:104-125`; `nginx.conf:53` |
| Pagination caps `MAX_LIMIT=200`, `MAX_PAGE=10000` | `server/src/common/paginated.ts:51-59` |
| Input validated by hand-written parsers that build a new object (field allowlist) | e.g. `server/src/sales/sales.dto.ts` (no `class-validator`) |
| Helmet (CSP off, CORP cross-origin), `x-powered-by` off | `app.setup.ts:30-42` |
| CORS allowlist from `CORS_ORIGINS`; set-but-empty throws | `app.setup.ts:44-80`; `config.ts:225`; #367 |
| Platform API: Nginx IP `allow` + app-level `PLATFORM_ADMIN_IPS` guard + separate `aud` | `nginx.conf:87-98`; #270 |
| `/metrics` answered 404 at Nginx; k6 remote-write behind IP allow + Basic auth | `nginx.conf:118-163` |
| `trust proxy` = 1, rightmost XFF | `app.setup.ts:29`; `common/client-ip.ts` |
| `audit_log` append-only for `pos_app` | #399/PR #406 |
| `statement_timeout=25s`, commit-ceiling guard | CLAUDE.md "Transactions & tenancy" |
| CI: `pnpm audit --audit-level=high` + Trivy fs (lockfile + Dockerfile misconfig) | `.github/workflows/server.yml:96-125` |
| CI: Trivy image scan blocks the GHCR push | `server.yml:289-299` |
| CI: OSV-Scanner on `frontend/pubspec.lock` | `.github/workflows/flutter.yml:121-135` |
| CI: `nginx -t` on both configs | `server.yml:146-179` |
| Compose images digest-pinned | `server/docker-compose.yml:17` (#401) |
| `demo` environment requires a reviewer before deploy | CLAUDE.md (#366) |
| e2e security suite | `server/test/security.e2e-spec.ts` |

### What was checked and is **absent**

gitleaks / trufflehog / pre-commit config; CodeQL or Semgrep workflow; `@nestjs/swagger` / any
OpenAPI output; ZAP; `class-validator` / `ValidationPipe` (by design — hand validation);
`server_tokens off`, HSTS or any `add_header` security header in the main `nginx.conf` (only
`platform-ui/nginx.conf:34` sets a CSP); `SECURITY.md`; private vulnerability reporting
(`gh api …/private-vulnerability-reporting` → `{"enabled":false}`).

---

## A. Secrets

### A.1 Scanning — GitHub native first, gitleaks second

**GitHub Secret Protection.** For a public repo it is free: "Secret scanning alerts for users can be
enabled on any free public repository that you own," via *Settings → Advanced Security → Secret
Protection* ([docs.github.com — enabling secret scanning][gh-ss-enable]). It is **not** on here
(`secret_scanning: disabled`). Push protection "blocks secrets detected in pushes from the command
line, commits made in the GitHub UI, file uploads … requests to the REST API" ([about push
protection][gh-pp]). Note the two levels: *push protection for users* is on by default per GitHub
account and only covers that account's pushes to public repos; the **repository-level** setting is
what protects pushes from every contributor. Because user-level push protection already covers each
member's own pushes to this public repo, the repo-level switch is P1, not P0. Also off:
`secret_scanning_non_provider_patterns` (generic secrets such as private keys) and
`secret_scanning_validity_checks`.

⚠️ The docs say secret scanning "runs automatically for free" on public repos ([about secret
scanning][gh-ss-about]). This repo's setting reads `disabled`. `gh api` is the ground truth for the
setting. It is **untested** whether alerts would actually appear here in the current state.

**gitleaks** (the CLI is MIT; regex + entropy; ~29.6k stars) ([gitleaks/gitleaks][gitleaks]). Why add
it as well: GitHub's scanner mainly knows *provider* patterns, and this repo's secrets are mostly
generic (Postgres/Redis/etcd passwords, an RS256 PEM, `JWT_PLATFORM_SECRET`). gitleaks' generic rules,
plus a custom rule for `dev-only-` vs real values, fit that better.

It can also answer "was anything ever committed?", which nobody has checked yet. The **full-history
scan runs in CI**: `actions/checkout` with `fetch-depth: 0` plus `gitleaks-action`, as the action's
README shows ([gitleaks-action][gitleaks-action]). No laptop download is needed.

Licensing of the Action differs from the CLI. The README says: "Since v2.0.0 of Gitleaks-Action, the
license has changed from MIT to a [license]" (its own `LICENSE.txt`). Personal-account repos need no
licence key (this repo is owned by the user `NuimanLP`); organisations need a free key
([gitleaks-action][gitleaks-action]). If the Action's licence is unacceptable, running the MIT CLI
directly in a `run:` step is the fallback.

Hook it into `server-ci-status` as a `needs:` (per `07 §4`: never a new required check). 🔴 The
proposed gitleaks job must use `runs-on: ubuntu-latest`, never `[self-hosted, …]`, or it would run on
`mob04`.

**trufflehog** (runner-up) — AGPL-3.0, 800+ detectors, and its differentiator is **live
verification** ("it can also log in to confirm if that secret is live") ([trufflehog][trufflehog]).
That matters for cloud keys; this repo's secrets are internal passwords a verifier cannot reach, so
the main advantage does not apply.

Pre-commit hook: optional and per-developer. Worth it only if the team already uses the
`pre-commit` framework; the server-side push protection + CI gate cover the case where someone
skips the hook.

### A.2 Storage and delivery on one VM

Today: the whole `server/.env` lives as the string `DEMO_ENV_FILE` in the operator's shell
(`07 §5` row `DEMO_ENV_FILE`), Ansible writes it to `/opt/pos/.env` 0600, and Compose interpolates it
into container **environment variables** (`docker-compose.yml:45` — "interpolation-only, no
`env_file:`"). Two weaknesses: (1) there is **no versioned source of truth** — the value exists on
whichever laptop last ran `provision.yml`, and every new key (`ETCD_ROOT_PASSWORD`,
`GRAFANA_ADMIN_PASSWORD`, `K6_REMOTE_WRITE_*`, `PLATFORM_ADMINS`…) had to be hand-merged into it,
which is exactly how the `/opt/pos/.env` blocker in #343 happened; (2) env vars are "generally
accessible to all processes and may be included in logs or system dumps" ([OWASP Secrets Management
Cheat Sheet][owasp-secrets]).

Decryption, if any, always happens **on the operator's laptop**. `provision.yml` builds
`/opt/pos/.env` from the operator's `DEMO_ENV_FILE` (`provision.yml:18, 190-198`), so the VM never
needs a decryption key under any option below.

| Option | Fit here | Verdict |
|---|---|---|
| **`deploy/demo.env.example` (key names only, no values) + team password manager** | Fixes weakness (1) directly: the *list of keys* is versioned and reviewed in PRs, so a missing key shows up in review rather than on the VM. `provision.yml`'s pre-flight (`:158-176`) could later check against it. Values live in a password manager the three members share; nothing secret enters git. | **Recommended** |
| SOPS + age | Encrypts values only and keeps keys visible, so diffs are reviewable. Supports ENV format and age keys. CNCF Sandbox (donated 2023), MPL-2.0 ([getsops/sops][sops]). An encrypted `deploy/secrets/demo.env.sops` in git; each member holds an age key and runs `sops -d` locally to feed `DEMO_ENV_FILE`. 🔴 The ciphertext would sit in a **public** repo forever: a leaked age key exposes **every historical version**, and rotation can't undo that. | Optional |
| Ansible Vault | Already have Ansible; "encrypts variables and files" ([Ansible Vault][ansible-vault]). Whole-file encryption gives unreadable diffs, and it uses one shared password rather than per-person keys. It has the same public-ciphertext exposure as SOPS, and the same caveat: "ONLY protects data at rest". | Runner-up to SOPS |
| Docker Compose secrets (file-mounted at `/run/secrets/<name>`) | Docs cite exactly the env-var leak risks ([docs.docker.com][compose-secrets]). But the app reads `process.env` everywhere, and Postgres/Redis/etcd/nginx bake secrets from env at bootstrap. Converting means a code change in `config.ts` plus every image's entrypoint. | Later, only if env leakage becomes a real finding |
| Infisical / HashiCorp Vault / OpenBao | A stateful server on a 6 GB VM, with its own unseal/backup story and its own image to pull through FortiGate. RAM figures are in "VM budget". For ~15 secrets and 3 people this adds more attack surface than it removes. | **Not recommended** |

**Known limit (no fix required):** the `deploy` user is in group `docker` (CLAUDE.md, `07 §6`). That
is root-equivalent on the host, and it can read every container's environment, secrets included,
with `docker inspect`. Anyone holding the `deploy` SSH key therefore holds every secret. Moving to
file-mounted secrets would not change this, because the same user can still read the mounts. Record
it; don't try to engineer around it on a single-VM demo.

### A.3 Rotation

| Secret | Rotation story today | Gap |
|---|---|---|
| `JWT_PRIVATE_KEY` / `JWT_PUBLIC_KEYS` | Written (ADR-0009 l.98): add new public key → switch private → drop old after one 04:00 cutoff | Never drilled (**UNVERIFIED**) |
| `JWT_PLATFORM_SECRET` (HS) | None written; rotating it logs out every platform admin (acceptable, 1 h tokens) | Write it down |
| Platform admin passwords | `PLATFORM_ADMINS` re-hash sets `password_changed_at` → old tokens die | Done (#443) |
| Postgres / etcd root / nginx-auth (k6 htpasswd) | **Baked into volumes at first bootstrap**; changing `.env` does not re-key; re-keying is an owner decision (CLAUDE.md, `07 §8`) | No runbook. `etcdctl user passwd root` named but not sequenced (#365) |
| Redis (`--requirepass` from env) | Takes effect on container restart; not volume-baked | Write it down |
| Grafana admin | **UNVERIFIED** whether Grafana re-reads it after first start | Check before writing a runbook |

OWASP's guidance is "regularly rotate secrets so that any stolen credentials will only work for a
short time" ([OWASP cheat sheet][owasp-secrets]). For a student demo the pragmatic target is not a
schedule but a **tested procedure per secret** for the day one leaks. Recommendation: one table in
`07 §8`, each row proven once on a throwaway `-p` stack (never `down -v` on the shared daemon).

### A.4 Don't log secrets

Already good: `REDACT_PATHS` in `server/src/common/logger.ts`, bodies never serialised, Ansible
`no_log`. Two small gaps: Nginx's JSON `access_log` records `$request_uri`, so a secret ever put in a
query string would land in logs (none today — keep it that way); and the redaction list is a manual
allowlist — a new secret body field must be added by hand. A unit test that fails when a DTO field
name matching `/password|token|secret|pin|code/i` is missing from `SECRET_FIELDS` would make that
automatic. **UNVERIFIED** whether such a test already exists (`logger.spec.ts` exists; not read in
full).

---

## B. API security

### B.1 OWASP API Security Top 10 (2023) mapping

Source: [OWASP API Security Top 10 – 2023][owasp-api].

| ID | Risk | Repo defence (path) | Gap / action |
|---|---|---|---|
| API1 | Broken Object Level Authorization | Tenant id from token only, Postgres RLS with `NULLIF` guard, architecture specs `tenant-door.spec.ts` / `tenant-wrapper.spec.ts`, device-token guard (`common/guards/`) | Strong across tenants. Within one tenant there is effectively one role (08 D-decisions), so intra-tenant BOLA is low. No action. |
| API2 | Broken Authentication | RS256 + `kid`, `aud`/`typ` claims (ADR-0009), argon2, 12-char floor, login throttle before DB, NFC+raw verify, forced temp-password change (#447) | Fine. Rotation drill (A.3). |
| API3 | Broken Object Property Level Authorization | Hand-written parsers build a fresh object from named fields (e.g. `sales/sales.dto.ts`) → no mass assignment; `SaleWrite` extra fields set only by `/sync/push` | Response over-exposure not audited (**UNVERIFIED**). Low priority. |
| API4 | Unrestricted Resource Consumption | Nginx 30 r/s/IP; per-tenant limiter (ADR-0006); 100 KiB body (10 MiB only after platform-token check); `MAX_LIMIT` 200 / `MAX_PAGE` 10 000; `statement_timeout` 25 s; Node `headersTimeout` 66 s | Nginx `client_body_timeout` / `client_header_timeout` default to 60 s ([nginx core module][nginx-core]) → slow-loris window; lowering to ~10 s is nice-to-have (a campus-internal demo host). No `limit_conn`. |
| API5 | Broken Function Level Authorization | Separate `aud=platform` plane + Nginx IP allow + app guard; device-role decorator (`common/decorators/device-role.decorator.ts`) | Role checks are per-route and opt-in (10 of 23 controllers reference a role decorator). An architecture spec like `idempotency-routes.spec.ts` that forces every route to declare its guard would make this fail-closed. P2. |
| API6 | Unrestricted Access to Sensitive Business Flows | Idempotency keys, manager-PIN before void (phase 1), login + enrol throttles | Enrol-code guessing: 8 chars + IP bucket — adequate. No action. |
| API7 | SSRF | Only outbound fetch is to `etcdUrl` from config (`config/runtime-config.service.ts:97-285`), never user input | None today. Keep any future URL input on an allowlist. |
| API8 | Security Misconfiguration | Helmet, `x-powered-by` off, CORS allowlist code, TLS 1.2/1.3, `nginx -t` in CI, Trivy Dockerfile misconfig | `CORS_ORIGINS` not set on `mob04`, so the API **reflects any Origin** (CLAUDE.md #367). There are no cookies and auth is Bearer only (ADR-0009 l.101), so the exploit value is low; still worth setting (P2). Nginx: no `server_tokens off` (default `on` emits version — [nginx][nginx-core]), no security headers for the Flutter web root (Helmet only covers responses from Node). Repo security settings off (TL;DR). Third-party Actions pinned by tag, not SHA (P2). |
| API9 | Improper Inventory Management | `/metrics` 404 at edge; Bull-Board / Grafana / platform-ui loopback-only; `02_API_SCREENS.md` is the endpoint list | No machine-readable spec (no `@nestjs/swagger`), so "what is exposed" is checked by reading `nginx.conf`. A test asserting the exact set of routes reachable without auth would be the cheap substitute. P3. |
| API10 | Unsafe Consumption of APIs | No third-party APIs consumed; etcd is internal and authenticated (once #365 is fixed on the VM) | 🔴 etcd has **no auth on `mob04`** until #365 runs there — anything on the compose network can read/write it. Tracked; do on the #343 VM trip. |

### B.2 SAST — CodeQL default setup, Semgrep as runner-up

- **CodeQL default setup**: eligible because the repo "is publicly visible"; needs no workflow file
  ("default setup … automatically created"); JS/TS need no special configuration
  ([docs.github.com][gh-codeql]). `gh api …/code-scanning/default-setup` reports
  `state: not-configured` and lists `javascript-typescript` and `actions` among detected languages.
  **Dart is not supported by CodeQL** (not in the supported list), so the Flutter client gets no SAST
  from it. Default setup does not add a required check, so it cannot break `07 §4`.
- **Semgrep CE**: runs with `semgrep/semgrep` image and `semgrep scan --config auto`, no account
  token ([docs.semgrep.dev][semgrep-ci]). Runner-up: noisier registry rules, but it does have Dart
  rules (**UNVERIFIED** how many) and custom rules are easy — e.g. "no `runTx(` with two arguments",
  which would encode a CLAUDE.md binding rule mechanically.

Recommendation: CodeQL now (zero maintenance); add Semgrep only when there is a repo-specific rule
worth encoding.

### B.3 Dependencies — already covered, but the alert side is off

`pnpm audit --audit-level=high` + Trivy fs (server) and OSV-Scanner (`pubspec.lock`) run in CI.
OSV-Scanner also supports `pnpm-lock.yaml` ([OSV-Scanner lockfiles][osv]), so one tool could cover
both — not worth changing what works. The real gap is between CI runs: a CVE published on a day
nobody pushes is invisible until **Dependabot alerts** are on. They require the dependency graph
and alerts to be enabled ([Dependabot security updates][gh-dependabot]); today they are not, so the
`dependabot.yml` comment "the only thing we wanted from Dependabot" is currently getting nothing.

### B.4 DAST and WAF — judged not worth it now

- **ZAP API scan** needs "OpenAPI, SOAP, or GraphQL" and runs an **active scan** ([ZAP API
  scan][zap]). This server emits no OpenAPI, and `@nestjs/swagger` generates it from decorated
  classes — "interfaces not reflected" ([NestJS OpenAPI][nest-openapi]) — while every DTO here is a
  TypeScript interface plus a hand parser. Emitting a spec means rewriting DTOs as decorated
  classes: L effort for a scanner that mostly finds header issues B.1/API8 already lists. The ZAP
  *baseline* (passive) scan against a CI compose stack is the cheap variant if the owner wants a DAST
  box ticked. It would run on a **GitHub-hosted runner** against a throwaway compose stack (about
  3.4 GB of `mem_limit` there), never on the VM. Never point an active scan at `mob04`.
- **WAF**: Coraza is "100% compatible with OWASP Core Rule Set" ([coraza.io][coraza]) but its Nginx
  connector is titled "Coraza NGINX **Experimental** Connector" ([coraza-nginx][coraza-nginx]);
  ModSecurity v3 + CRS is the mature path but needs a custom-built Nginx image (another image to
  pull through FortiGate) and CRS false positives on a JSON API with Thai text are likely
  (**UNVERIFIED** — not tested). The API has a tiny, authenticated, tenant-scoped surface with
  hand-validated input; a WAF adds operational risk out of proportion. Not recommended.

### B.5 Nginx hardening (concrete)

In the `443` server of `server/docker/nginx/nginx.conf`:

- `server_tokens off;` (default `on` emits the version) ([nginx][nginx-core]).
- **HSTS: skip until the host has a real DNS name.** `mob04` is reached by IP (`172.30.58.20`) and has
  no DNS name. RFC 6797 §8.1 says a user agent must ignore the STS header when the host is an IP
  literal ("the UA MUST NOT note this host as a Known HSTS Host", [RFC 6797 §8.1.1][rfc6797]), so the header would do nothing. (Helmet sends HSTS on API
  responses by default, `max-age=31536000; includeSubDomains` ([helmet.js.org][helmet]); browsers
  ignore it there for the same reason.)
- `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY` on
  `location /`.
- Nice-to-have: `client_body_timeout 10s; client_header_timeout 10s;` (defaults 60 s).
- Remember `add_header` in a `location` replaces, not extends, inherited headers — repeat them in
  `location = /sw.js` and the hashed-JS location that already set `Cache-Control`.

---

## VM budget

`mob04` is 4 vCPU · 6 GB RAM · 48 GB disk (`07_CICD_DEPLOY.md:211`). Existing `mem_limit`s total about
**4.2 GB**: the POS stack is ~3.4 GB, plus Prometheus 512m, Grafana 256m and node-exporter 64m
(`07_CICD_DEPLOY.md:226-229`). That leaves **~1.8 GB of headroom, before** the OS, the page cache,
the Docker daemon and the future self-hosted runner (#67) take their share.

**Precedent:** `07 §5` (`07_CICD_DEPLOY.md:229`, detail in `§10.2`) rejected Wazuh/ELK because their
RAM floor would OOM the POS stack. The same test applies here.

🔴 **Blanket rule:** any option that needs an image **pulled on `mob04`** is blocked until the
network team exempts `ghcr.io`, `registry-1.docker.io` and `gcr.io` from FortiGate SSL inspection
(CLAUDE.md "Still open"). That rule does not touch:
- tools that run on operators' laptops (e.g. SOPS/age binaries);
- images that run on GitHub-hosted runners (Semgrep, ZAP, gitleaks).

| Recommendation | Where it runs | Adds to VM (RAM / disk) |
|---|---|---|
| Dependabot alerts + security updates | GitHub service | 0 / 0 |
| Secret Protection + push protection | GitHub service | 0 / 0 |
| gitleaks | GitHub-hosted runner (`runs-on: ubuntu-latest`) | 0 / 0 |
| CodeQL default setup | GitHub-hosted runner | 0 / 0 |
| Semgrep CE (runner-up) | GitHub-hosted runner, `semgrep/semgrep` image | 0 / 0 |
| Action SHA pinning | Workflow text | 0 / 0 |
| Nginx headers / `server_tokens off` / timeouts | Existing Nginx container, config only | ~0 / 0 |
| `CORS_ORIGINS` | One `.env` line in existing containers | 0 / 0 |
| `deploy/demo.env.example` + password manager | Repo file + laptops | 0 / 0 |
| SOPS + age (optional) | Operators' laptops only; the VM never decrypts | 0 / 0 |
| Rotation runbook | Doc; drills on a throwaway `-p` stack (laptop or CI) | 0 / 0 |
| ZAP baseline (P3) | GitHub-hosted runner against a throwaway stack (~3.4 GB of `mem_limit` **there**) | 0 / 0 |

**The recommended set adds ≈ 0 MB of RAM and ≈ 0 disk to the VM, and needs no new image pull on
`mob04`.**

🔴 The proposed gitleaks job must use `runs-on: ubuntu-latest`, never `[self-hosted, …]`, or it would
run on `mob04`. Today `deploy.yml:146` (`runs-on: [self-hosted, srisurart-demo-deploy]`) is the only
self-hosted job, and **no runner is installed** (0 runners, CLAUDE.md #67). Any new CI job copied from
`deploy.yml` would inherit that label, so check it.

**Rejected options, on RAM grounds as well as the FortiGate pull block:**

| Option | RAM floor (official source) | Also needs |
|---|---|---|
| HashiCorp Vault | Small cluster: "2-4 core", "8-16 GB RAM", "100+ GB" disk ([Vault reference architecture][vault-ra]), which is more than the whole VM | image pull on `mob04` |
| OpenBao | **UNVERIFIED**: no official sizing found. It is a Vault fork, so assume the same order of magnitude. | image pull |
| Infisical | Small: "4" GB per server container (2+ containers), plus Postgres "8 GB" and Redis "4 GB" ([Infisical requirements][infisical-req]) | image pull |
| WAF: ModSecurity v3 + CRS / Coraza | **UNVERIFIED**: no official RAM figure found. It also needs a custom-built Nginx image, and Coraza's Nginx connector is experimental. | image build + pull |
| ZAP **on the VM** | **UNVERIFIED**: no official figure found. It is a JVM-based scanner. Run it on a GitHub-hosted runner instead (above). | image pull |

---

## Open questions for the owner

1. **Enable Dependabot alerts + security updates (P0), GitHub Secret Protection (alerts + push
   protection) and CodeQL default setup?** All are free on this public repo, and all are repo-settings
   changes only the owner should make. Also: `07_CICD_DEPLOY.md:183` and `adr/0013-cicd-toolchain.md:52`
   both claim secret scanning is on. Correct the docs or the setting.
2. Run the one-off **gitleaks full-history scan** in CI before the demo? If it finds a real secret,
   the fix is rotation, not history rewriting.
3. **Where should the values for `DEMO_ENV_FILE` live?** The recommendation is `deploy/demo.env.example`
   (names only) plus a team password manager. SOPS+age or Ansible Vault in the public repo are optional
   alternatives.
4. Set **`CORS_ORIGINS`** on `mob04` in the same VM trip as #343/#365?
5. Accept a **rotation runbook per secret** as a phase-2 deliverable, including a decision on
   re-keying the volume-baked Postgres/etcd/nginx-auth secrets?
6. Pin third-party Actions to commit SHAs (P2)? This changes how Action bumps are done by hand.
7. Enable **private vulnerability reporting** / add a `SECURITY.md`? (Low value for a student repo;
   listed for completeness.)

## Could not verify

- Whether any secret was ever committed to git history. No scan was run; the CI gitleaks job would
  answer it.
- Whether GitHub's automatic public-repo scanning produces alerts while the repo setting reads
  `disabled`.
- Grafana's behaviour on admin-password change after first start.
- That the JWT `kid` rotation procedure has ever been executed.
- RAM floors for OpenBao, ModSecurity/Coraza and ZAP.
- Semgrep's Dart rule coverage; CRS false-positive rate.
- Whether `logger.spec.ts` already enforces redaction coverage for new secret fields.

## Sources (all accessed 2026-09-29)

- `owasp-api` — <https://owasp.org/API-Security/editions/2023/en/0x11-t10/> (redirects to api-security.owasp.org) — OWASP API Security Top 10 2023
- `owasp-secrets` — <https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html>
- `gh-ss-about` — <https://docs.github.com/en/code-security/secret-scanning/introduction/about-secret-scanning>
- `gh-ss-enable` — <https://docs.github.com/en/code-security/secret-scanning/enabling-secret-scanning-features/enabling-secret-scanning-for-your-repository>
- `gh-pp` — <https://docs.github.com/en/code-security/secret-scanning/introduction/about-push-protection>
- `gh-codeql` — <https://docs.github.com/en/code-security/code-scanning/enabling-code-scanning/configuring-default-setup-for-code-scanning>
- `gh-dependabot` — <https://docs.github.com/en/code-security/dependabot/dependabot-security-updates/about-dependabot-security-updates>
- `gitleaks` — <https://github.com/gitleaks/gitleaks> (MIT)
- `gitleaks-action` — <https://github.com/gitleaks/gitleaks-action> (v3, Node 24)
- `trufflehog` — <https://github.com/trufflesecurity/trufflehog> (AGPL-3.0)
- `sops` — <https://github.com/getsops/sops> (MPL-2.0, CNCF Sandbox)
- `ansible-vault` — <https://docs.ansible.com/ansible/latest/vault_guide/vault.html>
- `compose-secrets` — <https://docs.docker.com/compose/how-tos/use-secrets/>
- `semgrep-ci` — <https://docs.semgrep.dev/semgrep-ci/sample-ci-configs>
- `zap` — <https://www.zaproxy.org/docs/docker/api-scan/>
- `nest-openapi` — <https://docs.nestjs.com/openapi/introduction>
- `helmet` — <https://helmetjs.github.io/> (redirects to helmet.js.org)
- `nginx-core` — <https://nginx.org/en/docs/http/ngx_http_core_module.html>
- `coraza` — <https://coraza.io/>
- `coraza-nginx` — <https://github.com/corazawaf/coraza-nginx>
- `osv` — <https://google.github.io/osv-scanner/supported-languages-and-lockfiles/>
- `rfc6797` — <https://www.rfc-editor.org/rfc/rfc6797#section-8.1> (HSTS, §8.1.1 IP-literal hosts)
- `vault-ra` — <https://developer.hashicorp.com/vault/tutorials/day-one-raft/raft-reference-architecture>
- `infisical-req` — <https://infisical.com/docs/self-hosting/configuration/requirements>
- Repo state: `gh api repos/NuimanLP/srisurart-pos-flutter` (`security_and_analysis`),
  `…/code-scanning/default-setup`, `…/vulnerability-alerts`, `…/private-vulnerability-reporting` —
  read-only, 2026-09-29.

[owasp-api]: https://owasp.org/API-Security/editions/2023/en/0x11-t10/
[owasp-secrets]: https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html
[gh-ss-about]: https://docs.github.com/en/code-security/secret-scanning/introduction/about-secret-scanning
[gh-ss-enable]: https://docs.github.com/en/code-security/secret-scanning/enabling-secret-scanning-features/enabling-secret-scanning-for-your-repository
[gh-pp]: https://docs.github.com/en/code-security/secret-scanning/introduction/about-push-protection
[gh-codeql]: https://docs.github.com/en/code-security/code-scanning/enabling-code-scanning/configuring-default-setup-for-code-scanning
[gh-dependabot]: https://docs.github.com/en/code-security/dependabot/dependabot-security-updates/about-dependabot-security-updates
[gitleaks]: https://github.com/gitleaks/gitleaks
[gitleaks-action]: https://github.com/gitleaks/gitleaks-action
[trufflehog]: https://github.com/trufflesecurity/trufflehog
[sops]: https://github.com/getsops/sops
[ansible-vault]: https://docs.ansible.com/ansible/latest/vault_guide/vault.html
[compose-secrets]: https://docs.docker.com/compose/how-tos/use-secrets/
[semgrep-ci]: https://docs.semgrep.dev/semgrep-ci/sample-ci-configs
[zap]: https://www.zaproxy.org/docs/docker/api-scan/
[nest-openapi]: https://docs.nestjs.com/openapi/introduction
[helmet]: https://helmetjs.github.io/
[nginx-core]: https://nginx.org/en/docs/http/ngx_http_core_module.html
[coraza]: https://coraza.io/
[coraza-nginx]: https://github.com/corazawaf/coraza-nginx
[osv]: https://google.github.io/osv-scanner/supported-languages-and-lockfiles/
[rfc6797]: https://www.rfc-editor.org/rfc/rfc6797#section-8.1
[vault-ra]: https://developer.hashicorp.com/vault/tutorials/day-one-raft/raft-reference-architecture
[infisical-req]: https://infisical.com/docs/self-hosting/configuration/requirements
