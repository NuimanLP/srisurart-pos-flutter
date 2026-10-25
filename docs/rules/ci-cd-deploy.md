# CI/CD, deploy and git hygiene

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: `.github/workflows/`, `deploy/`, `mob04`, branch protection, merging/deleting branches, APK, TLS CA, multi-arch, Tailscale.

**CI/CD (`.github/workflows/`, `deploy/`):**
- Both `flutter.yml` and `server.yml` trigger on every PR (any base) and on push to `main` **and
  `develop`** (develop added 2026-10-07, so develop's head always has a full CI result); a `changes`
  job gates each workflow's own jobs internally so a `server/`-only PR still runs (and
  can satisfy) the Flutter required check, and vice versa. Each workflow ends in one
  always-reported status job (`flutter-ci-status`/`server-ci-status`) — the only
  required checks on `main`. On `main`/`develop` `concurrency.group` is keyed by ref + commit SHA
  and never cancelled. 🔴 **A push publishes to GHCR only from `main`** (`build-image`/`build-web`
  gated on `refs/heads/main`; the one exception is a manual `workflow_dispatch` of `build-web`, which
  pushes only a web `<sha>` tag and can never deploy — no server image; `deploy.yml` reacts to `main`
  only) — never let a develop push publish an image.
- Branch protection on `main` has been set since 2026-09-15: PR required (0 approvals),
  the two status jobs required, no force-push/delete, admins not enforced. **`develop` has the
  identical protection since 2026-10-06.** Ruleset 24564072 "main: merge commit only" (target
  `refs/heads/main`, active, **no bypass actors**) refuses squash/rebase into `main` — so admins
  cannot push directly to `main` either. Verify: `gh api repos/NuimanLP/srisurart-pos-flutter/rules/branches/main`.
- Base image digests are pinned and bumped by hand, never suppressed with `.trivyignore`.
- **Backup before migration (2026-10-13, 30-day retention owner-ratified 2026-10-18; released in `main` `21ad935` via PR #727 — no migration pending at that deploy, so it has never dumped on `mob04`):** `deploy.yml` runs `migrate.js status` with the NEW image and, when migrations are pending
  (or the check fails), a DB-only `backup-db.sh` (`BACKUP_VOLUMES=0`, shipped to the VM with `ansible.builtin.script` because `/opt/pos/scripts`
  is stale until `provision.yml`) into `/opt/pos/backups-pre-migrate/` (sibling of `backups/`, 30 days, no offsite). A failed dump stops the deploy before
  any container/schema change. 🔴 It is the only undo for a migration (no down-migrations); restoring is an owner decision and loses every write after the dump (07 §7).
- **Secret scan = gitleaks** (job `secrets` in `server.yml`, 2026-10-01): never path-gated,
  scans the commits each PR/push adds (`-v --redact`), and `server-ci-status` requires its
  `success`. Allowlists live in `.gitleaks.toml` (placeholder patterns) and
  `.gitleaksignore` (reviewed fingerprints). **Never allowlist a real secret — rotate it**
  (history is not rewritten). On a PR, CI reads both files from the **base** commit, so an
  allowlist change takes effect **only after it merges** — land it in its own PR first.
  Inline `gitleaks:allow` is ignored. Details: `07_CICD_DEPLOY.md §2a`.
  GitHub secret scanning + **push protection are ON since 2026-10-01** (verify with
  `gh api repos/NuimanLP/srisurart-pos-flutter --jq .security_and_analysis`; ADR-0013 once claimed
  "on" while off); Dependabot alerts + security updates enabled 2026-10-01.
- **SAST = Semgrep** (job `sast` in `server.yml`, 2026-10-13, ADR-0013 addendum *Accepted* 2026-10-18; in `main` since `21ad935`): never
  path-gated, `server-ci-status` requires `success`, `build-image` needs it. Pinned image digest
  (`--metrics=off`) + pinned `semgrep/semgrep-rules` commit; **any ERROR-severity result fails**,
  WARNING/INFO only go to SARIF. False positive → inline `nosemgrep: rule-id -- reason` (a marker
  without both fails the job); `.semgrepignore` holds vendored/generated paths only and, like the
  gitleaks allowlists, is read from the PR **base**; a `.semgrepignore` anywhere but the root fails the
  job (Semgrep honours nested ones, so a PR could hide its own code); the marker check is
  case-insensitive and also catches the short form Semgrep accepts. Never put `${{ github.ref }}` (or other
  `github.*` user-controlled context) inside `run:` — use `$GITHUB_REF` / an `env:` entry. Every
  third-party action is pinned by commit SHA with a `# vX` comment (trivy binary via `version:`);
  bump = `gh api repos/<o>/<r>/commits/<tag> --jq .sha`, version ≥ 2 weeks old.
- In Actions expressions `0` is falsy: `cond && 0 || 1` is always `1` — use strings (`'0'`). This silently disabled the docs-only push skip until it was fixed (2026-10-01).
- **Quality gates (2026-10-03, PRs #579/#581/#582 — table in `07_CICD_DEPLOY.md §2c`):**
  a UI write that can fail silently gets a surfacing catch — never an `_allowlist` entry
  without a reason; coverage baselines only go **up**, never lowered to go green; a changed
  client request means regenerating and committing `fixtures/client-requests/`; a shipped
  migration is never edited — add a new one. 🔴 Two PRs green alone can be red
  together: #579 + #580 merged 29 s apart turned Flutter CI on `main` red (`2411ebf`,
  `a8a8080`) until #582 — after a gate lands, rebase open PRs before merging.
- **IaC lint + web image scans (2026-10-13, released in `main` `21ad935` via PR #727):** `ci-guards` runs
  **ansible-lint** (`deploy/ansible/.ansible-lint`: profile `production`, offline; hash-pinned
  `deploy/ansible/lint-requirements.txt` on CPython 3.12 pinned by `actions/setup-python` + sha256-checked `ansible.posix`;
  pip wheels and the Galaxy tarball are cached, and a cache hit is still hash-checked) over every playbook in `deploy/ansible/` —
  fix the playbook, or `# noqa: <rule> <reason>` on that line; never a `skip_list`. `audit` Trivy-config-scans
  `deploy/web.Dockerfile`; `build-web` Trivy-scans the web image on PRs too (build-only, no push) — only the single-arch **amd64** build is
  scanned; the pushed amd64+arm64 list is a buildx rebuild of the same COPY-only Dockerfile, its arm64 half unscanned. DS-0002 is met by
  `USER 65534` in the image while `web-sync` runs `user: "0:0"` on purpose (root-owned `web` volume) — never call the
  deploy rootless. 🔴 The lint edits to `deploy.yml` (explicit `changed_when`, folded long lines) are proven **only by a
  real deploy + `.current_sha`** — done: released in `21ad935`, deploy run `39042973596` `failed=0`, `.current_sha` checked. `ansible.cfg` no longer sets
  `host_key_checking = False`: pin the host key first (ssh-keyscan vs the console fingerprint, 07 §7 "SSH host key");
  CD is unaffected (`ansible_connection=local`).
- `.github/dependabot.yml` is security-updates-only — routine bumps are human-timed.
- Never `docker compose down -v` on a shared Docker daemon (wiped another session's dev
  volumes once); throwaway stacks use a unique `-p`.
- **`demo` environment requires a manual approval before `deploy.yml`'s `deploy` job
  touches the VM** (#366, 2026-09-21 — ADR-0013 addendum, option 3). Auto-trigger on
  every green `main` is unchanged; the job enters GitHub's "Waiting for review" state
  and is never handed to a runner until the required reviewer (`NuimanLP`) approves —
  that is the entire mechanism for keeping a merge off the VM mid-demo. This is a live
  repo-settings change (`gh api …/environments/demo`), not just documentation — verify
  with `gh api repos/NuimanLP/srisurart-pos-flutter/environments/demo --jq '.protection_rules'`
  before assuming it's still on. Reconciles #335 D9 (manual Ansible) as the documented
  fallback for when the #67 runner is offline, not a competing trigger policy.
- **A red `server-ci-status` on `main` = no images on GHCR = every Deploy run skips while
  reporting success** (2026-09-30: `pnpm audit --audit-level=high` blocked every deploy
  until PR #512). An ~8 s green run after a merge can mean this, not only "docs-only". Release-gating jobs
  also download from outside at run time, so an outage there is a red run too: PyPI + Galaxy (`ci-guards`, cached and
  hash-checked), Docker Hub (`nginx-check`'s grafana/prometheus/gatus/node-exporter pulls, the semgrep image), GitHub
  (`sast`'s `semgrep-rules` fetch, the gitleaks/actionlint/shellcheck releases) the npm registry (`pnpm audit`, `ERR_SOCKET_TIMEOUT` 2026-10-22, not an advisory) and the Trivy DB (`mirror.gcr.io`, then
  `ghcr.io` — Trivy's own default order (checked at v0.70.0; re-check after the v0.76.1 bump), left as is). Re-run; never weaken the gate.
- **Tests must not hardcode the current month** (2026-10-01, PR #525): `sync-push.e2e-spec.ts` used
  `RC01-2569-09-…` with a server-stamped `now()` date, so on the 1st of the next month the server
  (correctly, 08 §10) added a `date_flag` and `main` went red — which also means no images and
  every Deploy run skipping. Derive RC/CN periods from now in `Asia/Bangkok` (`currentPeriod()`).
- **Docs-only push to main skips tests/images → no deploy; the VM stays on the last code SHA** (2026-10-01,
  `deploy/scripts/push-changes-kind.sh`, 07 §2 rule 2). Docs = `*.md` or `docs/**` except
  `docs/Backend_design/fixtures/**`; anything else is code. `deploy.yml` `resolve` applies the same rule to
  the range run-SHA..main-head, so a docs commit after a code commit does not strand that code deploy.
  A docs-only push to `develop` skips the same test jobs (develop never builds images or deploys).
- **Runner offline while its service is `active`** (2026-10-08): `BrokerServer` TLS read errors in the runner log
  ("Operation canceled") leave a Deploy run queued forever. Fix: `sudo systemctl restart
  actions.runner.NuimanLP-srisurart-pos-flutter.mob04-demo.service` as `cloud`. Check
  `gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners` (`status: online`) before approving a deploy.
- **Cancel stale waiting Deploy runs before approving a newer one** — a job waiting for approval holds
  the `deploy-demo` slot and the newer run sits `pending`; the approval API needs a `comment`.
  A code merge to `main` fires Deploy twice (once per CI workflow); the first usually skips green
  because the other image is not on GHCR yet — approve the second (2026-10-06). When both runs reach the
  gate, the unapproved twin keeps waiting and blocks the *next* release — cancel it right after the deploy
  (2026-10-10: run `37786086586` of `1d70d1c` held the slot for 2 days).
- **A green `Deploy (demo)` run is not evidence that anything was deployed.** Its
  `deploy` job is gated on `needs.resolve.outputs.images_ready == 'true'`, so when the
  images for that SHA are not on GHCR yet the job is skipped and the workflow still
  reports *success* with only `resolve release` having run. The VM's `/opt/pos/.current_sha`
  is the only proof.
- **Never `gh pr merge --delete-branch` on a stacked PR.** Deleting a branch that is
  another PR's base makes GitHub close that PR, and a closed PR's base cannot be
  changed — recovery is push the old tip back, `gh pr reopen`, `gh pr edit --base develop`.
  Clean up branches once, after the whole stack has landed.
- **Retarget a stacked PR to `develop` once its base PR has merged, before merging it.**
  #447 was merged into PR2's already-merged branch, so its code reached `main` only
  because #448 happened to contain it.
- **`ansible-playbook deploy.yml --check` proves almost nothing.** `ansible.builtin.command`
  has no check mode, so it is skipped and the network pre-flight assertion then fails on
  an empty `stdout` — a false positive that reads like a disaster. It also never reaches
  any task past the first `command`. Never cite a `--check` run as evidence.
- `deploy.yml` and `provision.yml` need **different SSH users and are not interchangeable**:
  `deploy.yml` runs as `deploy` (owns `/opt/pos`, in group `docker`, **no sudo**),
  `provision.yml` as `cloud` (has sudo, **not** in group `docker`, cannot write
  `/opt/pos`). `--check` hides this because `copy` compares checksums without writing.
- Never pass `--diff` to `provision.yml` — it prints the whole `/opt/pos/.env`.
- When editing a `.env` by hand, anchor every check with `^` (`grep -c KEY` counts lines
  *containing* the name, so a key glued onto the previous line by a missing trailing
  newline looks present while Compose still reports it missing) and append a blank line
  first. `pgdata`/`etcd-data`/`nginx-auth` bake their secrets in at first bootstrap only:
  changing those passwords in `.env` does not re-key an existing volume, and re-keying is
  a separate owner decision, never an improvised step.
- **Dev `server/.env` needs `ALLOW_DEV_SECRETS=true`** (#410/PR #412, 2026-09-25) — without
  it the api/worker/bull-board refuse to boot on a `dev-only-*` placeholder secret or the
  public dummy JWT pair. **Never set it on a real host** — `vm.override.yml` forces it
  empty on `mob04`.
- **Android APK (PR #551, merged 2026-10-03):** manual `android-apk.yml`, `main` only, **API build only** — no
  offline APK from `main` because `useApiRepositories` defaults true. Signed via secret `ANDROID_KEYSTORE_B64`; the
  keystore backup is the owner's — lose it and no APK can upgrade in place.
- **Private CA for `mob04` TLS (PR #552, merged 2026-10-03):** one-shot `certgen` keeps a CA in volume `certs-ca`
  and re-issues the leaf each deploy. 🔴 Never `down -v` or delete `certs-ca`: a new CA stops every distributed APK
  until the CA asset is recommitted and APKs rebuilt. `ca.key` lives only in `certs-ca`. `frontend/assets/certs/pos-ca.crt`
  holds the CA since 2026-10-03 (first certgen deploy `7ea0178`; SHA-256 `87:7B:B8:F7:…:54:CF:83:65`) — it must match
  `certs-ca/ca.crt` on the VM (`07_CICD_DEPLOY.md` §5 "TLS"). Never add `badCertificateCallback`.
  A host IP change = set `CERT_SAN_IPS` in that host's `.env` (no code edit since PR #712), plus `CORS_ORIGINS`, then
  `provision.yml` + a redeploy; the APK's `API_BASE_URL` is set per `target` in `android-apk.yml`.
- **APK `target` (PR #787, 2026-10-25):** `android-apk.yml` input `target` = `mob04` (default: `https://172.30.58.20`,
  `pos-ca.crt` as committed, tag `apk-<sha>`) | `pi5` (`https://100.70.181.98` = the Pi's Tailscale IP, so the device
  needs Tailscale; `frontend/assets/certs/pos-ca-pi5.crt` copied over `pos-ca.crt` in the runner only; tag
  `apk-pi5-<sha>`). Same package id + key: installing one over the other switches that device's server.
  🔴 `pos-ca-pi5.crt` is the Pi's PUBLIC CA cert only; it must match `certs-ca/ca.crt` on the Pi.
- 🔴 **Hand-run compose on a host that touches `monitoring.yml` services needs `MONITORING_CONFIG_DIR=./deploy`**
  (deploy.yml sets it in its play `environment`), run from `/opt/pos`. Without it the bind mounts fall back to
  `../deploy/...` (empty) and Gatus crash-loops on `configuration file not found` (Pi, 2026-10-25).
- **Multi-arch images + Raspberry Pi 5 host (2026-10-13, PRs #711/#712/#713, release #714 `5c7f210`;
  `docs/tutorial/pi5-full-stack-tutorial.md`):** server/web `:<sha>` and `:main` are **amd64+arm64 manifest lists**. Server: made by
  `publish-image` only after both per-arch legs (`:<sha>-amd64`/`:<sha>-arm64`, each built + smoke + sharp check — arm64 under
  `qemu-aarch64 -cpu cortex-a76` — + Trivy) pass; `server-ci-status` is red if `publish-image` was skipped on a `main` code push.
  Web: pushed for both platforms by one buildx build (no per-arch legs, no Trivy).
  Releases before `5c7f210` are amd64 only. `verify-ghcr-tags.sh <sha> [linux/amd64|linux/arm64]` (no platform = old check).
  `CERT_SAN_IPS` (comma-separated IPv4; unset = `172.30.58.20`, byte-identical SAN on `mob04`). `deploy/scripts/host-setup.sh`
  runs before `provision.yml`: **never formats** (prints `sfdisk`/`mkfs.ext4` for the owner), refuses page size ≠ 4096
  (Raspberry Pi OS on a Pi 5 = 16K; use Ubuntu Server 26.04/24.04), mounts the data disk at `/srv/pos-data` and moves Docker
  `data-root` to `/srv/pos-data/docker` with a `RequiresMountsFor=/srv/pos-data` drop-in (plus `log-driver local`; Docker is restarted only when `daemon.json`/drop-in actually change, so a re-run is safe) — 🔴 never remove it (Docker would
  start on an empty SD dir); backups stay on the boot disk (the only off-host copy is the owner-PC pull, #363, wired for `mob04` only).
  A runner on a Pi must set `RUNNER_NAME` + `RUNNER_LABELS` (script refuses on aarch64 otherwise) and **never share
  `srisurart-demo-deploy`**. 🔴 **Pi CD is not wired:** `deploy.yml` runs on `mob04`'s label and passes no platform.
- **Tailscale on `mob04` (2026-10-13, `docs/research/tailscale-remote-access-plan-2026-10-13.md`):** subnet router for
  `172.30.58.20/32` only (`tag:pos-server`, Personal plan = non-commercial). 🔴 `--snat-subnet-routes=false` is required —
  never re-enable SNAT (every phone would share one IP: per-IP login rate limit + nginx's RFC1918 allowlist). SSH over the
  tailnet is the owner's only; dashboards (Grafana/Prometheus/Bull-Board/platform-ui) only through an SSH tunnel.


## Branch pruning

The repo's long-lived branches are `main`, `develop` and `POC_sample_offline_first` (see Branch
strategy). Merged branches are pruned in sweeps (44 on 2026-09-22, 35 on 2026-09-30, 87 on
2026-10-06), each checked first: ancestor of `main`/`develop`, or PR MERGED with tip == PR head, or
post-merge commits patch-id-equivalent on the base. 🔴 **Before deleting a branch, check it is actually merged** — two
branches (`research/production-host`, `research/pwa-offline-shell`) held the only copy of
`docs/research/*.md` (424 lines, closed tickets #241/#242 whose closing comments linked
straight at the files), had **no PR at all**, and would have been destroyed silently.
`git merge-base --is-ancestor <branch> origin/main` per branch is the check;
`git log --all --diff-filter=A -- '<path>'` is how to prove a file exists nowhere else.
Both docs were merged to `main` first (PR #386) with a banner saying what has since
overridden them — **`production-host.md` recommends a cloud host the owner decided
against on 2026-09-15**; it is kept only because #242's own closing comment says to keep
it as input for the future outside-campus phase.
