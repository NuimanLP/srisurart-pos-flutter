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
- **OS = Ubuntu Server 26.04 LTS** (24.04 LTS fallback). Raspberry Pi OS refused: its Pi 5 kernel uses 16K pages and the
  stack is only tested on 4K kernels (corrected by the tutorial review below — the official `redis:7-alpine` already builds
  jemalloc for 16K pages on non-x86, so "breaks Redis/jemalloc" was the wrong reason; `host-setup.sh`'s message still says it).
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
- Real `lsblk`/`findmnt` on a Pi; `RequiresMountsFor` with the data disk unplugged.
  (Checked from official sources since, not on a Pi: Ubuntu `linux-raspi` is `CONFIG_ARM64_4K_PAGES=y`; `download.docker.com`
  and `pkgs.tailscale.com` both carry `resolute` arm64; the Ubuntu raspi images ship `rpi-eeprom`.)
- The full stack booting on arm64; `docker-ce` leaving `/etc/docker/daemon.json` alone when installed after `host-setup.sh`.
- Pi CD (`deploy.yml` label + platform check), an APK for a Pi (`android-apk.yml` hardcodes `https://172.30.58.20`; the CA
  choice is the owner's), offsite backup (#363 parked).

## Tutorial review (2026-10-13, after the release)
Six reviewers — three angles (accuracy against the repo, facts against official sources, safety/order) × two guides
(`docs/tutorial/pi5-full-stack-tutorial.md`, `docs/tutorial/VM-dploy-full-stack-tutorial.md`); every command re-checked against
the scripts/playbooks before it was written. Docs only (branch `docs/pi5-full-stack-tutorial`).

Main fixes:
- **Pi guide:** written out in full for the Pi (`pi5`/`pi5-deploy`, `$PI_IP`, a `pi_guard` shell check on every Ansible
  command, its own `deploy` key and `pi5-demo.env`) instead of "follow the VM guide and swap the IP" — one missed substitution
  would have provisioned/deployed production `mob04` past the approval gate. New §3.5 picks the SHA + worktree before
  `host-setup.sh`/`provision.yml` use it. EEPROM fact corrected (26.04 needs EEPROM ≥ 2025-02-11 and must be updated *before*
  installing; 24.04 has no minimum); Imager forces a sudo password (Windows `ans` then needs NOPASSWD); disk identified by
  unplug/replug + `/dev/disk/by-id`; Tailscale added with `--profile vm` (re-running `--profile pi5` restarts Docker);
  `boot` mode keeps data and backups on one SD; `certs-ca` copy = moving the CA key (owner only); runner removal steps;
  first-deploy `...ignoring` lines, header lines, `docker info` driver check, clock/UPS/log-growth notes.
- **VM guide:** §3 renamed to the manual *fallback* (no approval gate, concurrency slot, `flock` or auto-rollback); the
  from-scratch secrets generator now writes `NEW_SECRETS_FILE` with `noclobber` (it could overwrite `mob04-demo.env`);
  §6.3b now says there is no off-VM copy and `mob04` holds real tenant data; provision installs scripts from the tree it runs
  from (clean `origin/main` worktree + sha256 check); the backup-script install moved to new §4.8 (after the deploy);
  three-file backup integrity check; HTTP/2 output; `verify-ghcr-tags.sh … linux/amd64`; Tailscale on `mob04` (§1.2);
  runner-online check, twin-run cancel, rollback migration-diff gate + Windows command.
- CLAUDE.md multi-arch / `CERT_SAN_IPS` bullets and the Tailscale plan (superseded no-SSH lines) corrected.

Deferred to the script follow-up (no script/workflow changed here): `host-setup.sh` page-size message still blames
Redis/jemalloc; its `then re-run:` line uses `$0` without `bash`; a Tailscale-only re-run path that never touches storage;
container log limits (`log-driver local`); a Pi target for `deploy.yml` / `verify-ghcr-tags.sh` platform in the workflow.

## Script follow-up (2026-10-14, branch `fix/host-setup-followups`)
Done: page-size message no longer blames Redis/jemalloc · re-run hint is `sudo bash $0 ...` · `put` skips identical files and
Docker is restarted only when `daemon.json`/drop-in changed (a re-run after deploy no longer stops the POS) · `daemon.json` adds
`"log-driver": "local"` (rotated logs; only containers created afterwards). Tests: `host-setup.test.sh` all pass in `ubuntu:24.04`
(the suite needs GNU tools — it fails on macOS before and after this change). Still deferred: a Pi target for `deploy.yml` /
the platform argument to `verify-ghcr-tags.sh` (no Pi exists).
