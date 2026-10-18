> **Update 2026-10-17: this bundle was RELEASED** (PR #727, `main` `21ad935`, deployed to `mob04`) — see `session-2026-10-17-release-727.md`. The text below is the 2026-10-14 state.

# Session 2026-10-13/14 — DevOps bundle (Semgrep, pre-migrate dump, Discord alerting + Gatus, ansible-lint) merged into `develop`, PARKED

**Not released.** `develop` got PR #723 (`devops-improvements` → `develop`, merge commit `840d9d4`, merged 2026-10-14 03:32Z),
then PR #722 (`cfd4a11`) and PR #724 (`3dbc197`). 🔴 **Owner decision 2026-10-14: park it in `develop` — nothing to `main`,
nothing to `mob04`.** `main` = `62e3688` (docs-only PR #716 on top of the last code release `5c7f210`, PR #714, deployed
2026-10-13, run `38393626652`). `mob04` runs `5c7f210`: no Gatus, no alert rules, no `node-textfile`, the Healthchecks.io
heartbeat cron (installed by hand 2026-10-04) still pings — none of this was re-checked over SSH this session.

## What is in `develop` (not on `main`)
| PR | Commit | What | Where it bites |
|---|---|---|---|
| #717 | `cbcc329` | Semgrep SAST gate (job `sast`, ERROR fails, image digest + `semgrep-rules` commit pinned, `nosemgrep: rule-id -- reason` only) + every third-party action pinned by SHA | CI — already gates every PR into `develop` |
| #718 | `95432ea` | `deploy.yml`: `migrate.js status` with the new image; pending (or failed check) → DB-only `backup-db.sh` into `/opt/pos/backups-pre-migrate/` (30 days) before `migrate`; a failed dump stops the deploy before any schema change | deploy — only after release |
| #719 | `49c2956` | Grafana alerting (10 file-provisioned rules) + Gatus (`127.0.0.1:3300`) → one Discord webhook (`ALERT_DISCORD_WEBHOOK`); backup-freshness gauge via node-exporter textfile; Healthchecks.io heartbeat retired (`provision.yml` removes cron + script) | deploy + `provision.yml` — only after release |
| #720 | `5ad8800` | ansible-lint (profile `production`, hash-pinned) in `ci-guards`; Trivy config scan of `deploy/web.Dockerfile`; web image Trivy scan on PRs too; `ansible.cfg` no longer sets `host_key_checking = False` | CI now; host-key pinning for manual Ansible after release |
| #721 | `5fd040d` | 3-angle review fixes of the branch | — |
| #722 | `cfd4a11` | `host-setup.sh`: Docker restarted only when `daemon.json`/drop-in change, `log-driver local`, honest 16K page-size message, `sudo bash` re-run hint | Pi/host setup — script is run by hand |
| #724 | `3dbc197` | `sast` step that surfaces Semgrep scan errors / skipped files as a `::warning::` (never fails); stale §7b / pi5-plan heartbeat refs | CI now |

Binding rules for all of it are in `CLAUDE.md` (CI/CD + Metrics sections) and `07_CICD_DEPLOY.md` §2c, §6 step 3b, §7, §10.5;
ADR-0013 has two addenda (Semgrep, alerting), both **proposed / `agent ร่าง`**. The 30-day pre-migrate retention has **no ADR
addendum** — it is a `agent ร่าง` row in 07 §7 and a CLAUDE.md bullet only.

## Reviews (read-only, after the merge into `develop`)
`/scrutinize` + `/code-review` of #723: **no blockers.** Verified by them:
- CD cannot be locked out by host-key pinning — `pos-deploy` runs Ansible with `ansible_connection=local`.
- Pre-migrate dump runs as `deploy` inside the postgres container, after pull and before `migrate`; failure stops the deploy before
  the schema changes; costs nothing when no migration is pending.
- shellcheck / actionlint / ansible-lint clean; `backup-db`, `host-setup`, `measure-container-rss`, `verify-ghcr-tags`,
  `check-migrations-immutable` tests pass in `ubuntu:24.04`; `monitoring-alerting.test.sh` passed (10/10 rules, Gatus 9 endpoints);
  Semgrep 0 ERROR.
This session re-ran two locally on `develop` @ `840d9d4` (docs in `testing-tutorial.md` §2.8): ansible-lint in `python:3.12` →
`Passed: 0 failure(s), 0 warning(s)`, profile `production`; Semgrep (pinned image + rules) → ERROR 0, WARNING 52, INFO 72.

## Release checklist (owner — before `develop` → `main`)
**Pre-release items from the reviews:**
1. 🔴 **SHOULD-FIX first — webhook token in logs.** A Discord send that fails at the network level (DNS/TLS/FortiGate) writes the
   **full webhook URL incl. token** into `docker logs gatus` (Go error text), maybe Grafana's error log too. Gate before putting
   `ALERT_DISCORD_WEBHOOK` in `.env`: on `mob04` `curl -v https://discord.com/api/v10/gateway` → HTTP 200 **and** a cert issuer
   that is not FortiGate. After the release, check Grafana's error log the same way. Never paste those logs unredacted; leaked = rotate.
2. **Rollback across this release is not clean.** An automatic (or manual) rollback to `5c7f210` leaves the `gatus` container
   running and the 10 file-provisioned rules firing ("Gatus down" / "backup stale" every 4 h); cleanup is manual (07 §7 row
   "rollback ข้าม release alerting": `docker rm -f` gatus + a `deleteRules:` file). Someone watches the first deploy with those
   commands ready.
3. **More external CI dependencies** (`semgrep-rules` on GitHub, Docker Hub images, PyPI, Ansible Galaxy, Trivy DB). An outage =
   red `server-ci-status` = no GHCR images = `Deploy (demo)` "succeeds" doing nothing. Re-run; never weaken a gate; check
   `.current_sha`.
4. **Owner decision:** pre-migrate dump retention 30 days vs nightly 7; the dumps hold every customer's data (PDPA). Also ratify
   (or change) the two ADR-0013 addenda.

**Release steps on `mob04` (07 §10.5 order):**
1. VM: `df -h /` under 85% + the Discord `curl` above.
2. Ask the Healthchecks.io account owner to pause/delete the check (not the team's account — removing the cron makes it page *them*).
3. Create the Discord webhook; compare `sha256sum` of the local `DEMO_ENV_FILE` with the VM's `/opt/pos/.env` (mismatch = stop);
   then add `ALERT_DISCORD_WEBHOOK`, remove `HEALTHCHECKS_PING_URL`.
4. On the Ansible laptop: pin the host key (`ssh-keyscan` vs the console fingerprint, 07 §7 "SSH host key"), `ansible.posix` installed.
5. Merge `develop` → `main` (**merge commit only**). `Deploy (demo)` waits for approval — do not approve yet.
6. While it waits: `provision.yml` as `cloud` from a **clean `origin/main` worktree** (creates `/opt/pos/node-textfile`, installs
   the new `backup-db.sh`, removes heartbeat cron + script). Never before the merge — old `origin/main` re-installs the heartbeat.
7. Run `backup-db.sh` once as `deploy` in cron's env to seed the freshness gauge.
8. Approve the deploy; cancel the stale twin run.
9. Verify: `/opt/pos/.current_sha` = the merge SHA; monitoring block `WARNING`s; Gatus at `127.0.0.1:3300` and Grafana → Alerting
   rules (no `Error`, "backup stale" Normal) via SSH tunnel; Discord contact point **Test**.

## Docs updated in this session (PR into `develop`)
- `CLAUDE.md`: Branch-strategy release paragraph (develop ahead of main, parked); parked/release markers on the Backup-before-migration,
  Semgrep, IaC-lint and Alerting bullets; the retired-heartbeat bullet now says it still runs on `mob04` until the release.
- `07_CICD_DEPLOY.md`: status box at §10.5, markers in §1 table, §6 step 3b, §7 SSH-host-key row (`main`'s `ansible.cfg` still
  disables checking). §7b untouched.
- Tutorials: VM (§2.6 status box, `3300` row, step 6b), pi5 (status line under the header; `provision.yml` heartbeat line), testing
  (§2.8 Semgrep + ansible-lint run locally), Thai manual 04 (status note, CI/deploy note) and 05 (no alerts on `mob04` yet; what
  changes after release).
- Report: `docs/report/src/chapters/ch5.md` — section "สถานะล่าสุด 2026-10-14" (table 5.4) + next-step 13.

## Not verified / open
- 🔴 **`progress-report-P1.docx` / `.pdf` were NOT rebuilt.** `build.py` ran (python-docx in a venv): text differs from the committed
  docx only by the new section + TOC/figure-list fields awaiting Word. Word on macOS did not open the file via `open -a` +
  AppleScript (`count of documents` = 0), so no TOC update / PDF export. Next person: build + finalize per `docs/report/README.md`
  and commit both files.
- Nothing checked on `mob04` this session (no SSH): heartbeat still running, `.current_sha` = `5c7f210` are from the last records.
- Discord egress through the FortiGate: unknown until step 1.
- The `deploy.yml` lint edits (`changed_when`, folded lines) are proven only by a real deploy + `.current_sha`.
- Gatus runs on the host it watches: a dead `mob04` pages nobody until a second host exists.
