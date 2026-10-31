# Session 2026-10-24/25 — Raspberry Pi 5 first deploy (shop host)

Owner decision 2026-10-24: the Pi 5 becomes the shop's production host ("ใช้จริงที่ร้านเลย"). `mob04` stays
production until a data migration is agreed — nothing was moved.

## Host

| Item | Value |
|---|---|
| OS | Ubuntu Server 26.04.1 preinstalled arm64+raspi (kernel 7.0.0-1020-raspi, page size 4096), EEPROM 2025-12-08 |
| Addresses | Tailscale `pi5-pos` = `100.70.181.98`; home Wi-Fi reservation `192.168.1.116` (wlan0) |
| Data disk | USB HDD 1 TB, ext4, `/srv/pos-data` (fstab by UUID); Docker `data-root` = `/srv/pos-data/docker`, log driver `local` |
| Provision | `provision.yml` as `cloud` (NOPASSWD), `host-setup.sh --profile pi5 --data-disk` — `failed=0` |
| Release | `b74838752c016e98f6cb91bb5f9299e5a82cf57a` (main head `8d8d11d` is docs-only, no images) |
| Alerts | own `ALERT_DISCORD_WEBHOOK` (not `mob04`'s) |

## Deploy

Run from WSL Ubuntu on the owner PC (`DEMO_SSH_HOST=100.70.181.98 DEMO_SSH_USER=deploy`, `deploy.yml -e image_tag=…`).

- First run **failed** in "Pull release images from GHCR": a Docker Hub layer (postgres) kept retrying over Wi-Fi
  for 14 min. Fix: pull each image of `docker compose … config --images` on the Pi one at a time with retries, then
  re-run `deploy.yml`. Grafana needed 4 attempts the same way. **On a Wi-Fi Pi, pre-pull before the first deploy.**
- Monitoring overlay then failed the same way (rescued, POS unaffected). Brought up by hand after the pre-pull:
  `up -d node-exporter` + `up -d --force-recreate prometheus grafana gatus`.

## Evidence (2026-10-25 ~03:00 ICT)

- `.current_sha` = `b74838752c…`; server image `arm64`
- `/health/ready` 200 on `127.0.0.1` and `192.168.1.116`; `/` serves the web app; `POST /api/v1/auth/token` `{}` → 401
- API ×3, postgres, redis ×2, etcd healthy; nginx, worker, bull-board, platform-ui up
- Served leaf SAN = `localhost, 127.0.0.1, 192.168.1.116, 100.70.181.98` (no `172.30.58.20`); chains to the Pi CA
  (`Verify return code: 0`)
- §8 step 7b done: Pi CA `AA:5C:73:C2:…:CA:2D` (≠ `mob04`'s `87:7B:B8:F7…`) in `gatus-ca-local/ca.crt` 0644;
  every Gatus endpoint green incl. `pos-api-ready`; Prometheus targets api-metrics ×3, gatus, node up
- `backup-db.sh` run by hand once: complete, **local only** (no `BACKUP_RCLONE_REMOTE`)
- PC copies: `ops\secrets\pi5-pos-env-20261024T193209Z.env`, `pi5-certs-ca-20261024T193209Z.tar.gz` (+ `.sha256`, holds `ca.key`)

## Follow-up release — nginx gzip (#778 → `main` `8713c9f`, PR #779)

Owner reported the first load over Tailscale was slow: the Pi's uplink measured ~240 KB/s and nginx sent the ~15 MB
web build uncompressed (canvaskit.wasm 5.8 MB in 51 s). #778 gzips the static web build only (API stays
uncompressed) and lifts three new high advisories. Deploy run `40151601600` to `mob04` success (`.current_sha`
`8713c9f…`, gzip headers checked); Pi by hand `failed=0 rescued=0`, `.current_sha` `8713c9f…`; canvaskit now 2.2 MB
in 2.0 s over Tailscale (the uplink was also faster at that moment).

The tailnet grant `autogroup:member → autogroup:self` now allows `tcp:22, tcp:80, tcp:443` (owner edited it);
HTTPS to `100.70.181.98` from the PC = 200.

## Offsite backup — Google Drive (owner 2026-10-25, PR #783 → `main` `5ab7266`, PR #784)

- `backup-db.sh` now reads `BACKUP_RCLONE_REMOTE`/`BACKUP_RCLONE_CONFIG` from `/opt/pos/.env` (environment wins, explicit
  empty included — pre-migrate dumps never upload). Pi `.env` + the WSL provision source (re-synced from the Pi first: it
  had lacked `ALERT_DISCORD_WEBHOOK`) carry `gdrive-dr:Srisurart-POS-DR/pi5-pos` and `/opt/pos/rclone/rclone.conf`.
- rclone 1.60 (apt) on the Pi, credential `drive.file` scope made by the owner's browser login via
  `ops\setup-pi5-gdrive-backup.ps1` (copy `ops\secrets\pi5-rclone.conf`). `provision.yml` re-run from `5ab7266`:
  `failed=0`, `/opt/pos/scripts/backup-db.sh` = `main`'s.
- Evidence: a bare-environment run of the cron line ended `=== Backup Complete (local + offsite) ===`; Drive holds
  `pos_backup_*`, `pos_images_*`, `pos_sale_photos_*` + `.sha256`; the dump's sha256 in Drive = local.
- HDD (WD My Passport 1 TB, 10,372 power-on h): SMART PASSED, 0 reallocated/pending/CRC, short self-test passed, no USB
  resets or under-voltage since boot.

## Remaining items closed (2026-10-25 afternoon)

- **Restore from Drive rehearsed.** The newest `pos_backup_*` pulled back from `gdrive-dr:Srisurart-POS-DR/pi5-pos`,
  sha256 checked, restored into a throw-away Postgres container: 0 errors, 33 tables and 27 migrations = live. The
  image tarballs are empty placeholders (no product/sale photos yet), so an image restore is still unproven.
- **First tenant:** already present (`001`, user `nuiman`); none created.
- **Power:** `throttled=0x0` across 14 h of uptime with the HDD attached. River 3's USB-C tops out at 5 V/3 A, so
  the Ugreen 240 W cable cannot raise `max_current`; only the official 27 W PSU (on River 3's AC socket) gives 5 A.
- **APK for the Pi** (PR #787 → `main` `b5dccea`, PR #788): `android-apk.yml` takes `target` (`mob04` default |
  `pi5`). `pi5` builds against `https://100.70.181.98` (Tailscale IP, stable when the Pi moves) and trusts
  `frontend/assets/certs/pos-ca-pi5.crt` (the Pi's public CA, copied over `pos-ca.crt` in the runner only).
  Built: release `apk-pi5-b5dccea`. The device needs the Tailscale app on the owner's tailnet; same package id and
  key as the mob04 APK, so installing one over the other switches that device's server. Not yet tried on a device.
- **LAN IP change on the move to the shop:** `ops\pi5-change-lan-ip.sh <new-IP>` (host-side, run in WSL:
  `wsl -d Ubuntu -- bash /mnt/d/Beestation/Sri_POS/ops/pi5-change-lan-ip.sh <new-IP>`). It refuses unless the Pi
  already holds that IP (reserve it in the shop router's DHCP first), rewrites `CERT_SAN_IPS`/`CORS_ORIGINS`/
  `GATUS_POS_URL`, runs `provision.yml` + `deploy.yml` with the current `.current_sha` (`.env` changed → rollout,
  certgen issues a new leaf, same CA), recreates Gatus and checks SAN + ready on both IPs. Rehearsed with the current
  IP (no-op values): OK.

## Incident — Gatus crash-looping (2026-10-25 ~12:50–13:52 ICT)

- Grafana fired `Gatus down`. Gatus logged `panic: configuration file not found` every minute.
- Cause: the IP-script rehearsal recreated Gatus with a bare `docker compose … up -d --force-recreate gatus` from
  `/opt/pos`. Without `MONITORING_CONFIG_DIR=./deploy` (deploy.yml sets it in its play `environment`), the
  `/config` mount fell back to `../deploy/gatus` = `/opt/deploy/gatus`, which is empty.
- Fix: recreated with `MONITORING_CONFIG_DIR=./deploy`; all 9 endpoints green, `up{job="gatus"}=1`. The script now
  passes the variable. POS itself unaffected; only uptime checks were blind for ~1 h.
- Rule: any hand-run compose command on a host that touches `monitoring.yml` services must export
  `MONITORING_CONFIG_DIR=./deploy` (and run from `/opt/pos`).

## Still open

- ✅ 2026-10-26: own Google OAuth client live — Cloud project `srisurart-backup` (`rising-daylight-512815-c0`),
  Drive API on, app **In production** (homepage = this repo, privacy = `docs/privacy-backup.md`, PR #807; needed to
  leave "Testing", whose refresh tokens expire after 7 days), Desktop client `pi5-rclone`. The owner ran
  `ops\switch-pi5-gdrive-own-client.ps1`: backups now go to `Srisurart-POS-DR-own/pi5-pos` (`drive.file` hides the
  old `Srisurart-POS-DR`, kept as is — the owner may delete it). A cron-shaped run: exit 0, `(remote keeps 30 days)`,
  sha256 of the dump on Drive = local. The script's WSL-source edit did not apply; synced by hand (`.env` == source).
- ✅ 2026-10-26 cleanup (owner: "clear what is not needed"): old folder `Srisurart-POS-DR` (36 backup files, 70 KB) moved
  to Drive **Trash** (`rclone purge --drive-use-trash`, recoverable 30 days); old shared-client credential deleted on the
  Pi and the PC (`ops\secrets\pi5-rclone.conf`); superseded Pi env snapshots and this session's WSL `.env` backups
  deleted (current source == Pi `.env` == `ops\secrets\pi5-pos-env-20261026T155201Z.env`); load-test/provision temp
  dirs, the Pi's k6 leftovers and this session's merged branches removed. Owner still to do: revoke the old "rclone"
  grant at myaccount.google.com/permissions (keep "Srisurart POS backup").
- ✅ 2026-10-26: Drive retention live — PR #803 (`main` `35d5199`, release #804), Pi re-provisioned (`failed=0`,
  `.env` == source, script sha = `main`), `BACKUP_RCLONE_KEEP_DAYS=30`; a cron-shaped run ended
  `=== Backup Complete (local + offsite) === (remote keeps 30 days)`.
- 2026-10-27: owner is swapping the Pi's USB power cable. Procedure (now in README + tutorial §10): `ssh pi5 "sudo shutdown -h now"`, wait ~30 s, swap, power on; after 2 min expect `/health/ready` 200 and `get_throttled=0x0`. Avoid the 10:00/19:00 ICT backups. Not yet verified post-boot — run the check when the owner reports the Pi is back.
- 2026-10-28: Home Assistant Container installed on the Pi (owner request) — see README Pi table + tutorial §15. Verified: HA answers 302 on 127.0.0.1:8123, POS ready 200, throttled 0x0, ~300 MB RAM. Tailscale: the owner added `tcp:8123,8443` to the ACL grant and enabled HTTPS certs; `tailscale serve --bg --https=8443` → `https://pi5-pos.tailc2ba46.ts.net:8443` returns 302 with a valid cert, plain `100.70.181.98:8123` also 302. Gotcha: HA 2026.10 migrates YAML `http:` into `.storage/http` once, so the reverse-proxy settings had to be written there (YAML block removed). LAN access untested (PC was on a phone hotspot, 172.20.10.x). Owner still to do: create the HA owner account. The Pi's uptime showed no reboot, so the owner's power-cable swap did not interrupt it.
- 2026-10-29: owner asked for HTTPS on all dashboards. Done on the Pi with `tailscale serve --bg --tls-terminated-tcp=<port> tcp://127.0.0.1:<app>`: 13000 Grafana, 13100 Bull-Board, 13200 platform-ui, 13300 Gatus, 19090 Prometheus (no login!). Verified from the Pi: valid cert, 200 (Bull-Board 401 = basic auth). NOT yet reachable from the PC until the owner adds `tcp:13000,13100,13200,13300,19090` to the tailnet ACL grant. Prometheus and platform-ui were advised to stay on SSH tunnels; owner chose to open them anyway.
- 2026-10-30/31: matter-server container added beside HA (PR #815; image digest-pinned, host network, `:5580` ws is not opened in ufw; HA reaches it on `ws://localhost:5580/ws`). Owner still creates the HA account, adds the Matter integration and commissions the light from the phone app on the shop Wi-Fi.
- 2026-10-30: all 11 Dependabot alerts cleared. #816 (dev/lint tooling: `black` 26.10.1, `filelock` 4.2.1 with refreshed `--require-hashes` sets, `fast-uri` 3.1.9, `@vitest/mocker` 4.1.12 via vitest/coverage-v8 4.1.12) and #818 (`qs` >= 6.16.1 through a `pnpm.overrides` entry, runtime dependency; `pnpm update` could not move express/superagent's pin). Dependabot's own PRs #776/#780 targeted `main` and were closed as superseded. Released as #817 and #819 (merge commits; `bedd328` is still an ancestor of `main`).
- 2026-10-30/31: deployed to the Pi by hand from WSL (`deploy.yml` as `deploy`, tree exported with `git archive` to `~/rel-<sha>`, DB backup first: `Backup Complete (local + offsite)`). `.current_sha` `8713c9f…` → `8e44149f…` → `0710ecf9a81a42bc3a93431ad66890b34bfe75b0`, both runs `failed=0`, `/health/ready` 200 over https, 17 containers, none unhealthy, `throttled=0x0`. Pitfall: an `until` loop filtering `gh run list --commit` returned empty and exited at once; filter on `headSha` and require the runs to exist.
- 2026-10-31: a social-media post warned of a Linux kernel RCE reachable through MPTCP (safe kernels listed as 6.1.190+, 6.6.159+, 6.12.113+, 6.18.56+, 7.2.10+, 7.3+; no CVE given, not verified). Pi kernel is `7.0.0-1020-raspi` and no newer one was in apt, so the mitigation was applied on the owner's yes: `net.mptcp.enabled=0` live and in `/etc/sysctl.d/99-disable-mptcp.conf`. Nothing here uses MPTCP; POS ready 200 and 17 containers after. Re-check `apt list --upgradable` for a kernel and reboot outside shop hours when one lands.
- 2026-10-31 read-only security check of the Pi: ssh key-only (`passwordauthentication no`), 0 failed ssh logins in 7 days, ufw default deny with only 22/80/443 and 8123 (LAN + tailscale0), dashboards bound to tailscale0, unattended-upgrades active, nothing upgradable, no reboot needed. Gaps: `fail2ban` not installed (add before ever exposing :22 to the internet), kernel still below the post's safe list, `:5580` blocked by ufw but not probed from another LAN device (the PC was not on 192.168.1.x), router port forwards not visible from here (owner: confirm none point at 192.168.1.107/.116). Prometheus (:19090) has no login — acceptable only while the tailnet is the owner's devices.
- Not done on purpose: nginx `real_ip` + POS over the Tailscale cert (`serve --https=10000`) — advised against, touches live sales, needs `tcp:10000` in the ACL; matter-server's earlier "Network is unreachable" advertise error did not recur in 30 min.
- Official 27 W PSU for 5 A headroom (not urgent while `throttled` stays `0x0`).
- Try `apk-pi5-b5dccea` on a real device; restore of image tarballs once photos exist.
- Run `ops\pi5-change-lan-ip.sh` on move day. Whether `mob04`'s data moves to the Pi is undecided.
- 2026-10-31 (MPTCP warning re-posted by the owner): Pi re-verified — `net.mptcp.enabled=0` live + persisted, kernel `7.0.0-1020-raspi` (not in the post's safe list, no newer kernel in apt), no reboot needed, `/health/ready` 200; only `tailscale` 1.104.2→.4 upgradable (not applied). `mob04` was NOT mitigated: `7.0.0-28-generic`, `net.mptcp.enabled=1` → set to 0 live and in `/etc/sysctl.d/99-disable-mptcp.conf` (passwordless sudo worked). Neither host rebooted; Ubuntu had no patched kernel (mob04 only offers `linux-image-virtual` 7.0.0-42). Next: re-run `apt list --upgradable | grep linux-image` on both, reboot outside shop hours when a patched kernel lands. Also still open: tailscale upgrade on the Pi, `fail2ban`, mob04 reboot.
- 2026-10-31 (follow-up, owner said do it): Pi — `fail2ban` installed + enabled, `/etc/fail2ban/jail.d/sshd-local.conf` (sshd, systemd backend, maxretry 5, bantime 1h, ignoreip 127/8 + 192.168.1.0/24 + 100.64.0.0/10), jail running, 0 failed. `tailscale` 1.104.2→1.104.4 (run through `systemd-run` so a dropped ssh could not half-finish it): serve config intact (`sudo tailscale serve status`; without sudo it says "No serve config"), :8443 200, :13000 302, :13300 200, POS ready 200. Kernels: still nothing patched (Pi `7.0.0-1020-raspi`, none newer; mob04 `7.0.0-28-generic`, only `linux-image-virtual` 7.0.0-42 offered) → no reboot. Still open: kernel re-check + off-hours reboot; fail2ban on mob04 not done.
- 2026-10-31 release: #822 (camera scan button on the add-product `รหัสสินค้า` field, new product only) → `develop`; #821 (`develop`→`main`, merge commit, `e1f68ab2a39a2014cbe91d4a93469f70b833f6bc`; `bedd328` still an ancestor). Server/Flutter CI green. Deployed to the **Pi** by hand (backup `Backup Complete (local + offsite)`, `deploy.yml` `failed=0`, `.current_sha` = full sha, `/health/ready` 200). **`mob04`'s auto Deploy run `41205979387` sat `pending` 30+ min with no runner assigned (runner `online`, service restarted, no `pending_deployments`) — not deployed; check/cancel it before the next release.** Camera not tried on a real device; the Pi web is `https://100.70.181.98` with a self-signed cert, which may block `getUserMedia` (untested).
