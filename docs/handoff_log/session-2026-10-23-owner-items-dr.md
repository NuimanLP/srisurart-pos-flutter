# Session 2026-10-23 — owner decisions, ops hardening, DR rehearsal

Owner answered the open items from `session-2026-10-22-review-fixes-round2.md` in chat on 2026-10-23.

## Owner decisions

| Item | Decision |
|---|---|
| ADR-0009 addendum 2026-10-22 (single-use refresh tokens, 24 h once-only grace) | **Ratified** — PR #766 |
| `IMAGE_BUSY` Thai string | **Ratified** — PR #766 |
| Rotate k6 remote-write password | Do it — done (below) |
| `certs-ca` backup | Do it — done (below) |
| Second (evening) backup | Do it — PR #767 |
| Fresh-host DR rehearsal (#363 AC3) | Do it — done (below) |
| UX touch targets, CLAUDE.md split, Node 24 | Do them — PRs #770, #768, #769 |
| Read-only `backup-ro` key, `age` encryption of dumps, dead man's switch | **Not chosen** this round |

## Done on the hosts (no repo change)

- **k6 remote-write password rotated on `mob04`.** `.env` backed up as `/opt/pos/.env.bak-k6rot-<ts>`; new 48-hex password
  written to `K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD`; `nginx-auth` volume's `k6-remote-write.htpasswd` rewritten
  (previous kept as `.prev`). Check: old credentials → 401, new → past auth (400 on a junk body). No GitHub secret uses it.
  Load-test laptops must take the new value from the PC copy `ops\secrets\mob04-pos-env-20261023T130504Z.env`.
- **`certs-ca` copied off the VM:** `ops\secrets\mob04-certs-ca-20261023T130519Z.tar.gz` (+ `.sha256`; holds `ca.key`).
  `ca.crt` fingerprint = `frontend/assets/certs/pos-ca.crt` (`87:7B:B8:F7:…:54:CF:83:65`). Restore steps: `07 §5 TLS`.
- **Evening backup live:** `deploy` crontab is `0 3,12 * * *` (10:00 + 19:00 ICT, `#Ansible:` marker kept);
  PC task "Srisurart mob04 backup pull" has triggers 11:00 + 20:00. First evening run: 2026-10-24 12:00 UTC — check
  `backup-cron.log` and that the PC pulls a `*_120001Z` set.

## DR rehearsal (#363 AC3) — passed

Fresh host = new Docker Engine 29.1.3 installed in WSL Ubuntu 26.04 on the owner PC (Docker Desktop's engine would not
start). Inputs only: `git archive 4b45093` (the deployed SHA), the PC-pulled set `20261023_030001Z`, the newest
`ops\secrets` `.env` (with `ALERT_DISCORD_WEBHOOK` removed so nothing alerted) and the `certs-ca` archive.

| Step | t |
|---|---|
| layout from git (deploy.yml's file map) | 0 s |
| `certs-ca` volume restored | 8 s |
| GHCR images pulled (`IMAGE_TAG=4b45093`) | 82 s |
| postgres/redis/etcd healthy | 90 s |
| `sha256sum -c` + `restore-db.sh` (ceiling 25 s / 5 s ok, 27 migrations) | 101 s |
| `product-images` / `sale-photos` volumes from tarballs (both empty on prod today) | 102 s |
| full stack up, `GET /health/ready` = 200 through Nginx/TLS | 112 s |

Result: tenants 1 / sales 16 / products 51 / latest sale `2026-10-13 00:02:22` — **identical to live `mob04`**;
33 base tables; Nginx serves a new leaf signed by the **same** private CA, so installed APKs keep trusting it.
Torn down afterwards (all containers/volumes/images removed, the `.env` copy deleted, `docker`/`containerd` services
disabled in WSL; the `docker.io` package stays installed).

Limits: same PC, local copy (not pulled back from the NAS on another machine); no login/sale exercised on the restored
stack; monitoring stack not brought up.

## PRs

- #766 ratification (docs) — merged to `develop`
- #767 evening backup + PC pull 20:00 + `certs-ca` restore docs — merged to `develop`
- #768 CLAUDE.md → 239 lines + `docs/rules/*.md` + `docs/status.md` (verbatim move, line check 1144/1145; the one
  missing line is the `## Phase 2` heading) — merged to `develop`; its files were committed CRLF and are normalised to LF
  by the handoff PR
- #769 Node 22 → 24 + `grafana/k6` pinned
- #770 UX: ≥48 px counter tap targets, 14 px degraded banner, scan button label

## Still open

- `backup-ro` key, `age` encryption, team dead man's switch — not chosen; ask again later.
- DR on a second machine from the NAS copy.
- Flutter 3.47 / go_router 18 upgrades (R8) not started.
