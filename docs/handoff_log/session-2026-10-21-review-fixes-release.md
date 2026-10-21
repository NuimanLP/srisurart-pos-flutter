# Session 2026-10-17 → 2026-10-21 — DevOps releases, PC backup pull, 5-angle review fixes

Three releases to `main`, all merge commits, all deployed to `mob04` with `.current_sha` checked over SSH.

| Release | PR | `main` | Deploy run | What |
|---|---|---|---|---|
| 1 | #727 | `21ad935` | `39042973596` | DevOps bundle #717–#726 (Semgrep, pre-migrate dump, Grafana alerting → Discord + Gatus, ansible-lint) |
| 2 | #736 | `e6374df` | `39116359714` | host-setup fix #728, alert metric-name check + `/srv/pos-data` disk rule #734, restore-db table fix #735, PC watchdog #733, docs |
| 3 | #744 | `d5e2d10` | `39633605566` | nginx 1.30.6 / Prometheus 3.13.5 / Grafana 12.4.13 / node-exporter 1.12.1 / Trivy 0.76.1 (#743), restore-db safety (#741), PC ops (#737–#740), docs (#742) |

## Done on `mob04` by hand (no `provision.yml` on 10-17; `provision.yml` without `DEMO_ENV_FILE` on 10-18 and 10-21)
- 10-17: release `backup-db.sh` installed, `/opt/pos/node-textfile` created, one backup run → freshness gauge.
- 10-18: `ALERT_DISCORD_WEBHOOK` set (backup `.env.bak-20261018T041536Z`), grafana + gatus recreated, contact-point test ok.
  Healthchecks.io heartbeat removed (owner paused the check first; backups `.env.bak-20261018T024347Z`, `.deploy.cron.bak-…`).
- 10-21: `provision.yml` from a clean `d5e2d10` tree → `restore-db.sh` `cc854480…` installed; `.env` sha256 unchanged.
- Verified after release 3: 10 Grafana rules `inactive/ok`, Gatus 9/9, Prometheus 3.13.5 + Grafana 12.4.13 healthy, no plugin download at boot.

## Owner decisions (2026-10-18)
ADR-0013 addenda (Semgrep, alerting) **Accepted**; pre-migrate retention **30 days**; `actions/*` stay on version tags;
#363 off-VM copy = **owner PC pulls daily** into `D:\Beestation\Sri_POS\ops\backups\mob04\YYYY-MM\` (BeeStation syncs to the NAS);
everything PC-side under one root `D:\Beestation\Sri_POS\ops\` incl. `secrets\` (owner accepted secrets on the NAS).

## PC side (owner's Windows PC)
- Scheduled Tasks "Srisurart mob04 watchdog" (5 min) and "Srisurart mob04 backup pull" (11:00), run via `conhost --headless`
  (no console flash; **always reports exit 0** — read `ops\logs\`). Watchdog also alerts when the newest off-VM set is > 26 h old.
- 🔴 Never `%LOCALAPPDATA%`: written from the MSIX Claude desktop app it is virtualized and Task Scheduler sees nothing (`0xFFFD0000`).

## Proven / not proven
- Restore from the NAS copy into a fresh PostgreSQL 18.6 (WSL): failure path exit 3, success path exit 0, rows tenants 1 / sales 16 /
  products 51 (PR #741 comment). **Not** a full fresh-host DR — #363 AC3 still open. Compose-mode stop/start only stub-tested.
- Docker Desktop on the PC would not start (stale `dockerInference` socket); not reset, to protect the local `srisurart-pos` stack.

## Corrections
- The "partial JWT private key leaked" (10-18) is **not** the production key — normalized key bodies differ (checked 10-21).
  A review agent claimed otherwise by hashing only the `BEGIN PRIVATE KEY` line.

## Open (owner)
1. Rotate the k6 remote-write password (leaked in chat 2026-10-05, still live; htpasswd lives in the `nginx-auth` volume).
2. PC backup pull uses `mob04-SriStore` (no passphrase, root on mob04) → a read-only `backup-ro` user + restricted key.
3. Encrypt dumps before they leave the VM (`age`), keep the key offline; decide on `certs-ca` backup.
4. Second nightly backup after closing time; team-owned Healthchecks.io dead-man's switch (email + Discord).
5. Follow-ups from #743 review: GOAMD64/CPU check for Prometheus/Grafana/node-exporter images in CI; re-check Trivy DB repo order.
