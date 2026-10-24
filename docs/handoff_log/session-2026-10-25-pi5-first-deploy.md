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

## Still open

- **Tailnet grant allows only `tcp:22` to the Pi** — HTTPS via `100.70.181.98` times out from the PC. Add
  `tcp:443` (and `tcp:80`) to the `autogroup:member → autogroup:self` grant in the Tailscale admin console.
- Power: River 3 USB-C gives 3 A (`max_current` 3000) with a bus-powered HDD; test the Ugreen 240 W cable, else use
  the official 27 W PSU on River 3's AC socket.
- Backups leave the Pi nowhere yet (PC pull task / watchdog are hard-wired to `mob04`); dumps sit on the SD card.
- Moving to the shop changes the LAN IP: edit `CERT_SAN_IPS`/`CORS_ORIGINS`/`GATUS_POS_URL`, re-run provision + deploy.
- APK `API_BASE_URL` still points at `mob04`; first tenant not created yet (platform-ui via SSH tunnel to `127.0.0.1:3200`).
