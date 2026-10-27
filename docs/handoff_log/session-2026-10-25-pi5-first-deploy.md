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
- Official 27 W PSU for 5 A headroom (not urgent while `throttled` stays `0x0`).
- Try `apk-pi5-b5dccea` on a real device; restore of image tarballs once photos exist.
- Run `ops\pi5-change-lan-ip.sh` on move day. Whether `mob04`'s data moves to the Pi is undecided.
