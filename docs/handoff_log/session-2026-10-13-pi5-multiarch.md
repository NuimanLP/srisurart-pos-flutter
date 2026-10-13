# Session 2026-10-13 — multi-arch images, `CERT_SAN_IPS`, `host-setup.sh` (Raspberry Pi 5 groundwork), release `5c7f210`

**Released:** `main` `5c7f210` (PR #714, merge commit, merged 2026-10-13 11:47Z) = PR #711 (`4e34309`) + PR #712 (`36a70ab`) +
PR #713 (`b582fe8`). Deployed to `mob04` by `Deploy (demo)` run `38393626652` (`resolve release` + `deploy to demo` success);
`.current_sha` = `5c7f210`, `/health/ready` 200. Tutorial: `docs/tutorial/pi5-full-stack-tutorial.md`.

## Owner requests
1. Prepare the stack to run on a Raspberry Pi 5 (8 GB) — plan in `docs/research/pi5-migration-plan.md`.
2. An installer that detects the host and lets the owner pick where the data lives (boot disk, USB HDD/SSD, NVMe).
3. Optional Tailscale on the same installer (already done by hand on `mob04` the same day).
4. "Create the tutorial for fullstack for pi5 setup too."

## Decisions
- **OS = Ubuntu Server 26.04 LTS** (24.04 LTS fallback). Raspberry Pi OS refused: 16K pages on a Pi 5 break Redis/jemalloc.
- **The installer never formats** — a non-ext4 disk is refused and the `sfdisk`/`mkfs.ext4` commands are printed.
- **Backups stay on the boot disk** (`/opt/pos/backups`), a different device from pgdata on purpose.
- **`deploy.yml` unchanged** (still `mob04`'s runner label, no platform passed to `verify-ghcr-tags.sh`) until a Pi is a real
  deploy target; the tutorial's deploy section is the manual/rehearsal path.
- `mob04` stays production; no Pi is in service.

## What shipped
- **#711** — server image: matrix amd64/arm64 (native runners), per-arch `:<sha>-<arch>`; `publish-image` makes the `:<sha>`/`:main`
  manifest lists after both legs pass; `server-ci-status` red if it was skipped on a `main` code push. Web image pushed for both
  platforms. `verify-ghcr-tags.sh <sha> [platform]`. `setup-mob04-runner.sh` picks the runner tarball by `uname -m`; on aarch64
  `RUNNER_NAME` + `RUNNER_LABELS` are required.
- **#712** — `certgen.sh` leaf SAN from `CERT_SAN_IPS` (unset = `172.30.58.20`, so `mob04` is not reissued).
- **#713** — `deploy/scripts/host-setup.sh` (report / Pi 5 data disk / `--tailscale`, `--dry-run`), stub test
  `deploy/scripts/test/host-setup.test.sh` in `nginx-check`.

## Evidence
- `verify-ghcr-tags.sh 5c7f210e… linux/arm64` → both images verified for `linux/arm64` (re-checked 2026-10-13).
- CI: the arm64 leg's sharp check runs under `qemu-aarch64 -cpu cortex-a76` before push (07 §3).
- Every pinned third-party image digest in `server/docker-compose.yml` and `deploy/compose/monitoring.yml` is an index with
  `linux/arm64` (`docker buildx imagetools inspect`, 2026-10-13).
- `host-setup.sh --dry-run` on `mob04` (read-only): `ubuntu 26.04 resolute`, `amd64`, `x86_level=v1`, `page_size=4096`, boot
  `/dev/sda`, profile `vm` → report only. It surfaced three fixes, folded into #713 (device-tree stderr noise, the RAM warning on
  a non-Pi host, admin-console steps printed for an already-joined Tailscale node).
- Deploy run `38393626652`: `.current_sha` `5c7f210`, `/health/ready` 200.

## Not verified (no Pi exists yet)
- Real `lsblk`/`findmnt` on a Pi; `RequiresMountsFor` with the data disk unplugged; page size of Ubuntu's Pi kernel;
  Docker and Tailscale apt repos for Ubuntu 26.04 arm64; `rpi-eeprom-update` availability on Ubuntu 26.04.
- The full stack booting on arm64; `docker-ce` leaving `/etc/docker/daemon.json` alone when installed after `host-setup.sh`.
- Pi CD (`deploy.yml` label + platform check), an APK for a Pi (`android-apk.yml` hardcodes `https://172.30.58.20`; the CA
  choice is the owner's), offsite backup (#363 parked).
