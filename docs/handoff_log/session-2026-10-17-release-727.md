# Session 2026-10-17 — DevOps bundle released (PR #727, `main` `21ad935`)

The bundle parked in `develop` on 2026-10-14 (`session-2026-10-14-devops-develop.md`: PR #723 + #722 + #724) is now released.

## Release
- PR #727 (`develop` -> `main`, merge commit) = `main` `21ad935` (`21ad93586b5c744e9a8e4f0e81ac3f4a2b69598f`), merged 2026-10-17.
  Server CI + Flutter CI green; multi-arch images published.
- Deploy (demo) run `39042973596` approved; Ansible `failed=0`; `/health/ready` ok; `/opt/pos/.current_sha` = `21ad935...`
  checked over SSH. Twin run `39042895154` skipped green (normal).
- No migration pending -> the pre-migrate dump was correctly skipped. It has **still never actually dumped on `mob04`**.

## Done by hand (provision.yml was NOT run), over SSH as `cloud`
- Installed the release `backup-db.sh` (sha256 `c312728f...`); previous copy `/opt/pos/scripts/.backup-db.sh.prev-5c7f210`.
- Created `/opt/pos/node-textfile` (deploy:deploy 0755).
- Ran `backup-db.sh` once as `deploy` in cron env (rc=0) -> gauge `pos_backup_last_success_timestamp_seconds` visible in Prometheus.
- All 10 Grafana alert rules Normal (inactive/ok); Gatus 9/9 endpoints success.

## Still open on `mob04`
- `ALERT_DISCORD_WEBHOOK` NOT set -> Grafana's Discord notify fails; alerts reach nobody.
  Discord egress from `mob04` checked 2026-10-17: HTTP 200, cert issuer Google Trust Services (not FortiGate) -> setting it is safe.

## 2026-10-18 follow-up
- Account owner paused the Healthchecks.io check; the heartbeat was then removed from `mob04` by hand over SSH (no `provision.yml`):
  cron entry, `healthcheck-ping.sh`, `HEALTHCHECKS_PING_URL`. Backups: `/opt/pos/.env.bak-20261018T024347Z`,
  `/opt/pos/.deploy.cron.bak-20261018T024347Z`, `/opt/pos/scripts/.healthcheck-ping.sh.removed-20261018T024347Z`.
- Owner decisions: pre-migrate retention **30 days** (PDPA) ratified; both ADR-0013 addenda (Semgrep, alerting) **Accepted**.

## Not on `main` yet
- PR #728 (squash `0d7ffd6`, into `develop`): `host-setup.sh` accepts the `5c7f210` `daemon.json` as an upgrade and restarts
  Docker when `DockerRootDir` != `/srv/pos-data/docker`.

## Docs flipped from "parked / not released" to "released"
`CLAUDE.md`, `README.md`, `docs/Backend_design/07_CICD_DEPLOY.md` (table row, step 3b, §10.5 box),
`docs/tutorial/sri-pos-manual/04-it-operations.html`, `05-dashboards.html`, `docs/tutorial/VM-dploy-full-stack-tutorial.md`,
`docs/tutorial/pi5-full-stack-tutorial.md`. `docs/report` (docx) not rebuilt — left alone.
