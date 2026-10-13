#!/usr/bin/env bash
# host-setup.sh — prepare a host BEFORE provision.yml (07_CICD_DEPLOY.md §6 "host-setup.sh").
#
# Detects the OS / architecture / board and, on a Raspberry Pi 5, moves Docker's data (pgdata,
# images, container layers) off the microSD card onto a disk the owner chooses. It never formats,
# partitions or wipes anything: a disk without an ext4 filesystem is refused and the exact commands
# are PRINTED for the owner to run by hand. It does not call Ansible.
#
# Usage:
#   sudo host-setup.sh [--profile auto|vm|pi5] [--data-disk boot|/dev/DEVICE]
#                      [--tailscale [--lan-ip IP] [--ts-hostname NAME]] [--dry-run]
#
#   --profile     auto (default): pi5 when /proc/device-tree/model says "Raspberry Pi 5", else vm.
#                 vm  = report only (mob04); writes nothing unless --tailscale.
#                 pi5 = also set up the data disk (refused on anything that is not a Pi 5).
#   --data-disk   pi5 only. `boot` = keep everything on the boot disk (no changes), or a whole disk
#                 (USB HDD/SSD, NVMe) / one of its partitions holding an existing ext4 filesystem.
#                 Omitted on a TTY: numbered menu. Omitted without a TTY: exit 2.
#   --tailscale   install Tailscale from its signed apt repo and advertise <lan-ip>/32 as a subnet
#                 route (docs/research/tailscale-remote-access-plan-2026-10-13.md). Never takes an
#                 auth key: `tailscale up` prints a login URL the owner opens.
#   --dry-run     print every action, write nothing (no root needed).
#
# Exit: 0 ok · 1 refused · 2 usage.
# Tests: HOST_SETUP_ROOT prefixes every file path read or written; HOST_SETUP_ARCH overrides dpkg.
set -euo pipefail

R="${HOST_SETUP_ROOT:-}"
DATA=/srv/pos-data
DAEMON_JSON='{"data-root": "/srv/pos-data/docker", "features": {"containerd-snapshotter": false}}'
DROPIN=/etc/systemd/system/docker.service.d/10-pos-data.conf

profile=auto data_disk='' tailscale=0 lan_ip='' ts_hostname='' dry=0

usage() { sed -n '9,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "REFUSED: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
run() { if [ "$dry" = 1 ]; then echo "DRY-RUN: $*"; else "$@"; fi; }
put() { # path content — write a file under $R
  if [ "$dry" = 1 ]; then printf 'DRY-RUN: write %s:\n%s\n' "$1" "$2"; return; fi
  mkdir -p "$R$(dirname "$1")"
  printf '%s\n' "$2" > "$R$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="${2:-}"; shift 2 || usage ;;
    --data-disk) data_disk="${2:-}"; shift 2 || usage ;;
    --tailscale) tailscale=1; shift ;;
    --lan-ip) lan_ip="${2:-}"; shift 2 || usage ;;
    --ts-hostname) ts_hostname="${2:-}"; shift 2 || usage ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done
case "$profile" in auto|vm|pi5) ;; *) usage ;; esac
[ -z "$data_disk" ] || [[ "$data_disk" =~ ^(boot|/dev/[A-Za-z0-9/_.:-]+)$ ]] || usage
{ [ -z "$lan_ip$ts_hostname" ] || [ "$tailscale" = 1 ]; } || usage
[ "$dry" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root (sudo), or use --dry-run"

# ---------- detect ----------
# shellcheck source=/dev/null
IFS='|' read -r os_id os_version codename < <(. "$R/etc/os-release" && echo "${ID:-}|${VERSION_ID:-}|${VERSION_CODENAME:-}")
arch="${HOST_SETUP_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"
page_size="$(getconf PAGESIZE)"
model="$(tr -d '\0' < "$R/proc/device-tree/model" 2>/dev/null || true)"
mem_mib=$(( $(awk '/^MemTotal:/ {print $2}' "$R/proc/meminfo") / 1024 ))
x86_level=n/a
if [ "$arch" = amd64 ]; then
  x86_level=v1
  flags=" $(grep -m1 '^flags' "$R/proc/cpuinfo" | cut -d: -f2) "
  v2=1
  for f in cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; do [[ "$flags" == *" $f "* ]] || v2=0; done
  [ "$v2" = 1 ] && x86_level=v2+
fi
# Tolerant here (the vm report must not die on an odd root); setup_storage refuses an empty boot_disk.
boot_source="$(findmnt -no SOURCE / || true)"
boot_source="${boot_source%%[*}"
boot_disk=""
[ -z "$boot_source" ] || boot_disk="$(lsblk -s -prno NAME,TYPE "$boot_source" 2>/dev/null | awk '$2 == "disk" {print $1; exit}' || true)"
is_pi5=0
[[ "$model" == *"Raspberry Pi 5"* ]] && is_pi5=1
[ "$profile" = auto ] && { if [ "$is_pi5" = 1 ]; then profile=pi5; else profile=vm; fi; }

cat <<EOF
os_id=$os_id
os_version=$os_version
codename=$codename
arch=$arch
x86_level=$x86_level
page_size=$page_size
model=${model:-none}
mem_mib=$mem_mib
boot_source=$boot_source
boot_disk=$boot_disk
profile=$profile
EOF

case "$os_id" in
  ubuntu) case "$os_version" in 26.04|24.04) ;; *) warn "Ubuntu $os_version is untested (use 26.04 LTS, or 24.04 LTS)";; esac ;;
  debian) warn "Debian/Raspberry Pi OS is untested; Ubuntu Server 26.04 LTS (or 24.04 LTS) is the supported OS" ;;
  *) die "OS '$os_id' is not supported — install Ubuntu Server 26.04 LTS (or 24.04 LTS)" ;;
esac
case "$arch" in amd64|arm64) ;; *) die "architecture '$arch' is not supported — install the 64-bit OS (amd64/arm64)" ;; esac
[ "$page_size" = 4096 ] || die "kernel page size is $page_size, not 4096 (Raspberry Pi OS uses 16K pages on a Pi 5; Redis/jemalloc breaks) — install Ubuntu Server instead"
[ "$mem_mib" -ge 7168 ] || warn "only $mem_mib MiB RAM; the full stack is sized for 8 GB"
[ "$profile" != pi5 ] || [ "$is_pi5" = 1 ] || die "--profile pi5 on a host that is not a Raspberry Pi 5 (model: ${model:-none})"
[ "$profile" = pi5 ] || [ -z "$data_disk" ] || die "--data-disk is only for --profile pi5"

# ---------- storage (pi5) ----------
info() { # one line describing a disk or partition
  local d="$1" x
  x="$(lsblk -dpno MODEL,SERIAL,SIZE,TRAN,ROTA "$d" | tr -s ' ')"
  echo "$d  model/serial/size/transport/rota: ${x# }"
}
col() { lsblk -dpno "$1" "$2" | tr -d ' '; }
# (grep >/dev/null, not -q: with pipefail an early -q exit can SIGPIPE the writer and read as "no match")
mounted_elsewhere() { lsblk -prno MOUNTPOINT "$1" | grep -v '^$' | grep -vx "$DATA" >/dev/null; }
excluded() { # disk is boot, mounted elsewhere, swap, LVM or RAID
  [ "$1" = "$boot_disk" ] || mounted_elsewhere "$1" ||
    lsblk -prno FSTYPE "$1" | grep -xE 'swap|LVM2_member|linux_raid_member' >/dev/null
}
candidates() {
  local d
  for d in $(lsblk -dprno NAME,TYPE | awk '$2 == "disk" {print $1}'); do
    excluded "$d" || echo "$d"
  done
}

setup_storage() {
  [ -n "$boot_disk" ] || die "cannot tell which disk holds / (source '$boot_source') — refusing to pick a data disk"
  if [ -z "$data_disk" ]; then
    [ -t 0 ] || { echo "no --data-disk given and no TTY for the menu — pass --data-disk boot|/dev/..." >&2; exit 2; }
    local list=() i=1 c
    mapfile -t list < <(candidates)
    echo "Where should the POS data (Postgres, images, Docker) live?"
    echo "  0) boot — keep it on the boot disk $boot_disk (no changes)"
    for c in "${list[@]}"; do echo "  $i) $(info "$c")"; i=$((i + 1)); done
    read -r -p "choice: " c
    [[ "$c" =~ ^[0-9]{1,3}$ ]] || { echo "invalid choice" >&2; exit 2; }
    c=$((10#$c)) # "00"/"08": base 10, never octal, never index -1
    [ "$c" -le "${#list[@]}" ] || { echo "invalid choice" >&2; exit 2; }
    if [ "$c" = 0 ]; then data_disk=boot; else data_disk="${list[$((c - 1))]}"; fi
  fi
  echo "data_disk=$data_disk"

  if [ "$data_disk" = boot ]; then
    [[ "$boot_disk" == *mmcblk* ]] &&
      warn "!!! Postgres will write to the microSD card ($boot_disk). SD cards wear out under database writes and fail without warning — use a USB SSD/HDD or NVMe for a shop that relies on it. !!!"
    echo "keeping data on the boot disk — no changes"
    return
  fi

  local type disk part parts fs
  type="$(col TYPE "$data_disk" 2>/dev/null)" || die "$data_disk is not a block device"
  case "$type" in
    disk) disk="$data_disk" ;;
    part) disk="$(lsblk -s -prno NAME,TYPE "$data_disk" | awk '$2 == "disk" {print $1; exit}')" ;;
    *) die "$data_disk is a '$type', not a disk or partition" ;;
  esac
  data_disk="$(col NAME "$data_disk")" # canonical /dev/sdX even for a /dev/disk/by-* link
  [ "$disk" != "$boot_disk" ] || die "$data_disk is on the boot disk $boot_disk — use --data-disk boot for that"
  excluded "$disk" && die "$disk is in use (mounted elsewhere, swap, LVM or RAID): $(info "$disk")"
  [ "$(col ROTA "$disk")" = 1 ] &&
    warn "$disk is a spinning HDD: use a powered enclosure (or powered hub) and the official 27 W PSU"

  if [ "$type" = part ]; then
    part="$data_disk"
  else
    mapfile -t parts < <(lsblk -prno NAME,TYPE "$disk" | awk '$2 == "part" {print $1}')
    case "${#parts[@]}" in
      0) part="$disk" ;;
      1) part="${parts[0]}" ;;
      *) die "$disk has ${#parts[@]} partitions (${parts[*]}) — name one: --data-disk <partition>" ;;
    esac
  fi
  fs="$(col FSTYPE "$part")"
  if [ "$fs" != ext4 ]; then
    {
      echo "REFUSED: $part has filesystem '${fs:-none}', not ext4. This script never formats a disk."
      echo "Double-check this is the right device — the commands below ERASE EVERYTHING on it:"
      echo "  $(info "$disk")"
      if [ "$part" != "$disk" ]; then
        echo "  sudo mkfs.ext4 -L pos-data $part"
      else
        printf '%s\n' "  printf 'label: gpt\n,,L\n' | sudo sfdisk --wipe always $disk"
        echo "  lsblk $disk    # read the new partition's name (e.g. sda1, nvme0n1p1)"
        echo "  sudo mkfs.ext4 -L pos-data <that partition>"
      fi
      echo "then re-run: sudo $0 --profile pi5 --data-disk $data_disk"
    } >&2
    exit 1
  fi
  local uuid
  uuid="$(col UUID "$part")"
  [ -n "$uuid" ] || die "$part has no filesystem UUID"
  local line="UUID=$uuid $DATA ext4 defaults,noatime,nofail 0 2"

  # Refusals before any write.
  if [ -f "$R/etc/docker/daemon.json" ] && [ "$(cat "$R/etc/docker/daemon.json")" != "$DAEMON_JSON" ]; then
    die "/etc/docker/daemon.json exists with different content — merge by hand:
$DAEMON_JSON"
  fi
  if [ ! -f "$R/etc/docker/daemon.json" ] &&
    find "$R/var/lib/docker/volumes" -mindepth 1 -maxdepth 1 ! -name metadata.db ! -name backingFsBlockDev 2>/dev/null | grep . >/dev/null; then
    die "Docker already has volumes in /var/lib/docker — run this before provision.yml / the first deploy, or move the data by hand"
  fi
  if grep -E "^[^#]*[[:space:]]${DATA}[[:space:]]" "$R/etc/fstab" 2>/dev/null | grep -vxF "$line" >/dev/null; then
    die "/etc/fstab already mounts $DATA differently — fix it by hand"
  fi
  if findmnt -n "$DATA" >/dev/null 2>&1 && [ "$(findmnt -no UUID "$DATA")" != "$uuid" ]; then
    die "$DATA is already mounted from another filesystem — unmount it first"
  fi

  echo "using $part (UUID=$uuid) on $(info "$disk")"
  run mkdir -p "$R$DATA"
  # fstab: build the new file beside it, verify THAT, then swap it in — a failed verify leaves
  # /etc/fstab untouched. Newline-safe: a last line without a newline would swallow the new entry.
  local fstab="$R/etc/fstab"
  if ! grep -qxF "$line" "$fstab"; then
    if [ "$dry" = 1 ]; then
      echo "DRY-RUN: append to /etc/fstab: $line"
    else
      cp -p "$fstab" "$fstab.pos-new"
      [ -z "$(tail -c1 "$fstab.pos-new")" ] || echo >> "$fstab.pos-new"
      echo "$line" >> "$fstab.pos-new"
      findmnt --verify --tab-file "$fstab.pos-new" ||
        { rm -f "$fstab.pos-new"; die "findmnt --verify rejects /etc/fstab + '$line' — /etc/fstab left unchanged"; }
      [ -e "$fstab.pos-bak" ] || cp -p "$fstab" "$fstab.pos-bak"
      mv "$fstab.pos-new" "$fstab"
    fi
  fi
  run systemctl daemon-reload # systemd re-reads fstab before the mount
  findmnt -n "$DATA" >/dev/null 2>&1 || run mount "$DATA"
  if [ "$dry" = 0 ] && [ "$(findmnt -no UUID "$DATA")" != "$uuid" ]; then
    die "$DATA is not mounted from UUID=$uuid after mount"
  fi
  run mkdir -p "$R$DATA/docker"
  put /etc/docker/daemon.json "$DAEMON_JSON"
  put "$DROPIN" "$(printf '[Unit]\nRequiresMountsFor=%s' "$DATA")"
  run systemctl daemon-reload
  if systemctl is-active --quiet docker; then run systemctl restart docker; fi
  echo "data disk ready: Docker data-root = $DATA/docker"
  echo "note: backups stay in /opt/pos/backups on the boot disk — a different device from pgdata, on purpose"
}

# ---------- tailscale ----------
setup_tailscale() {
  local base="https://pkgs.tailscale.com/stable/$os_id/$codename" installed=0
  # shellcheck disable=SC2016 # ${Status} is a dpkg-query format field, not a shell expansion
  [ "$(dpkg-query -W -f='${Status}' tailscale 2>/dev/null || true)" = "install ok installed" ] && installed=1
  if [ "$installed" = 0 ]; then
    curl -fsI "$base.noarmor.gpg" >/dev/null ||
      die "Tailscale has no apt repo for $os_id/$codename ($base.noarmor.gpg) — check tailscale.com/download/linux"
  fi
  if [ -z "$lan_ip" ]; then
    lan_ip="$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  fi
  local o ok=1
  [[ "$lan_ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || ok=0
  for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || ok=0; done
  [ "$ok" = 1 ] || die "LAN IP '$lan_ip' is not an IPv4 address — pass --lan-ip"
  # 100.64.0.0/10 is Tailscale's own range: advertising it would route the tailnet into itself.
  if [ "${BASH_REMATCH[1]}" = 100 ] && [ "${BASH_REMATCH[2]}" -ge 64 ] && [ "${BASH_REMATCH[2]}" -le 127 ]; then
    die "LAN IP '$lan_ip' is a Tailscale (100.64/10) address, not the LAN — pass --lan-ip"
  fi
  ts_hostname="${ts_hostname:-$(hostname)-pos}"
  [[ "$ts_hostname" =~ ^[A-Za-z0-9-]+$ ]] || die "Tailscale hostname '$ts_hostname' must be letters, digits and '-'"

  if [ "$installed" = 1 ]; then
    # mob04: installed by hand — no repo rewrite, no apt-get (an install would upgrade + restart tailscaled).
    echo "tailscale package already installed — repo and package left as they are"
  else
    run mkdir -p "$R/usr/share/keyrings" "$R/etc/apt/sources.list.d"
    run curl -fsSL "$base.noarmor.gpg" -o "$R/usr/share/keyrings/tailscale-archive-keyring.gpg"
    run curl -fsSL "$base.tailscale-keyring.list" -o "$R/etc/apt/sources.list.d/tailscale.list"
    run apt-get update
    run apt-get install -y tailscale
  fi
  local sc=/etc/sysctl.d/99-tailscale.conf
  if ! grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$R$sc" 2>/dev/null; then
    if [ -s "$R$sc" ]; then # keep whatever else it holds (e.g. an IPv6 forwarding line)
      if [ "$dry" = 1 ]; then echo "DRY-RUN: append to $sc: net.ipv4.ip_forward = 1"
      else { [ -z "$(tail -c1 "$R$sc")" ] || echo; echo 'net.ipv4.ip_forward = 1'; } >> "$R$sc"; fi
    else
      put "$sc" 'net.ipv4.ip_forward = 1'
    fi
  fi
  run sysctl -p "$R/etc/sysctl.d/99-tailscale.conf"

  cat <<EOF
Prerequisite (tailnet policy, docs/research/tailscale-remote-access-plan-2026-10-13.md §6):
  tagOwners must list tag:pos-server, and a grant must allow your users to $lan_ip/32 tcp:443.
EOF
  if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
    echo "already logged in to Tailscale — correcting the route only (no 'up')"
    run tailscale set --advertise-routes="$lan_ip/32" --snat-subnet-routes=false
  else
    run tailscale up --hostname="$ts_hostname" --advertise-routes="$lan_ip/32" \
      --advertise-tags=tag:pos-server --snat-subnet-routes=false
  fi
  cat <<EOF
Then in the Tailscale admin console -> Machines -> $ts_hostname:
  1. Edit route settings -> approve $lan_ip/32
  2. ... -> Disable key expiry
EOF
}

[ "$profile" = pi5 ] && setup_storage
[ "$tailscale" = 1 ] && setup_tailscale
[ "$profile" = vm ] && [ "$tailscale" = 0 ] && echo "vm profile: report only, nothing written"

cat <<EOF
Next steps:
  1. provision.yml as 'cloud' (DEMO_SSH_USER=cloud; never --diff — it prints /opt/pos/.env)
  2. deploy/scripts/setup-mob04-runner.sh
EOF
