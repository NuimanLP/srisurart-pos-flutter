#!/usr/bin/env bash
# Tests for deploy/scripts/host-setup.sh against a fixture root (HOST_SETUP_ROOT) and PATH stubs
# that log their arguments: no real disk, apt or Tailscale is touched. Every stub for a destructive
# tool (mkfs.ext4, sfdisk, wipefs, dd) writes to DANGER_LOG, which must stay empty in every case.
# Usage: deploy/scripts/test/host-setup.test.sh
# Stub bodies and bash -c scripts are single-quoted on purpose (they expand when they run):
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/host-setup.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
export STUB_LOG="$WORK/stub.log" DANGER_LOG="$WORK/danger.log"
: > "$DANGER_LOG"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }
stub dpkg 'echo "${STUB_ARCH:-amd64}"'
stub getconf 'echo "${STUB_PAGE:-4096}"'
stub id 'echo 0'
stub hostname 'echo pi5'
stub ip 'echo "1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.50 uid 0"'
stub mount 'echo "mount $*" >> "$STUB_LOG"'
stub sysctl 'echo "sysctl $*" >> "$STUB_LOG"'
stub apt-get 'echo "apt-get $*" >> "$STUB_LOG"'
stub systemctl 'echo "systemctl $*" >> "$STUB_LOG"; [ "$1" != is-active ] || [ "${STUB_DOCKER_ACTIVE:-1}" = 1 ]'
stub tailscale 'echo "tailscale $*" >> "$STUB_LOG"; [ "$1" != status ] || [ "${STUB_TS_LOGGEDIN:-0}" = 1 ]'
stub dpkg-query '[ "${STUB_TS_INSTALLED:-0}" = 1 ] && printf "install ok installed" || exit 1'
for t in mkfs.ext4 sfdisk wipefs dd; do stub "$t" "echo \"$t \$*\" >> \"\$DANGER_LOG\""; done
# curl: -o FILE creates it; -fsI fails when STUB_CURL_404=1.
stub curl 'echo "curl $*" >> "$STUB_LOG"
prev=""; for a in "$@"; do [ "$prev" = -o ] && : > "$a"; prev="$a"; done
case "$*" in *-fsI*) [ "${STUB_CURL_404:-0}" != 1 ] ;; esac'
# findmnt: SOURCE of / from the fixture; the data mount reports STUB_DATA_UUID.
stub findmnt 'echo "findmnt $*" >> "$STUB_LOG"
case "$*" in
  "-no SOURCE /") cat "$HOST_SETUP_ROOT/rootsrc" ;;
  "-no UUID /srv/pos-data") echo "${STUB_DATA_UUID:-}" ;;
  "-n /srv/pos-data") [ "${STUB_DATA_MOUNTED:-0}" = 1 ] ;;
  --verify*) [ "${STUB_VERIFY_FAIL:-0}" != 1 ] ;;
esac'
# lsblk over $HOST_SETUP_ROOT/lsblk.txt: NAME PARENT TYPE FSTYPE MOUNTPOINT UUID SIZE TRAN ROTA SERIAL MODEL...
# ('-' = empty). Modes: no device = top level (-d: disks only); -d dev = that row; -s dev = row +
# ancestors; dev = row + descendants.
cat > "$STUBS/lsblk" <<'STUB'
#!/bin/sh
d=0 s=0 cols='' dev='' want=''
for a in "$@"; do
  if [ -n "$want" ]; then cols="$a"; want=''; continue; fi
  case "$a" in
    -*) case "$a" in *d*) d=1 ;; esac
        case "$a" in *s*) s=1 ;; esac
        case "$a" in *o) want=1 ;; esac ;;
    *) dev="$a" ;;
  esac
done
exec awk -v dev="$dev" -v d="$d" -v s="$s" -v cols="$cols" '
function out(n,  k, c, line, i, x) {
  k = split(cols, c, ","); line = ""
  for (i = 1; i <= k; i++) { x = v[n, c[i]]; if (x == "-") x = ""; line = line (i > 1 ? " " : "") x }
  print line
}
function desc(n,  i) { out(n); for (i = 1; i <= N; i++) if (par[name[i]] == n) desc(name[i]) }
{
  n = $1; name[NR] = n; seen[n] = 1; par[n] = $2
  v[n, "NAME"] = n; v[n, "TYPE"] = $3; v[n, "FSTYPE"] = $4; v[n, "MOUNTPOINT"] = $5; v[n, "UUID"] = $6
  v[n, "SIZE"] = $7; v[n, "TRAN"] = $8; v[n, "ROTA"] = $9; v[n, "SERIAL"] = $10
  m = $0; for (i = 1; i <= 10; i++) sub(/^[^ ]+ +/, "", m); v[n, "MODEL"] = m
}
END {
  N = NR
  if (dev == "") { for (i = 1; i <= N; i++) if (par[name[i]] == "-" && (!d || v[name[i], "TYPE"] == "disk")) out(name[i]); exit 0 }
  if (!(dev in seen)) { print "lsblk: " dev ": not a block device" > "/dev/stderr"; exit 32 }
  if (s) { x = dev; while (x != "-") { out(x); x = par[x] }; exit 0 }
  if (d) out(dev); else desc(dev)
}' "$HOST_SETUP_ROOT/lsblk.txt"
STUB
chmod +x "$STUBS/lsblk"

fails=0
check() { # description, command...
  local desc="$1"
  shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fails=$((fails + 1)); fi
}
has() { grep -qF -- "$1" <<<"$out"; }
logged() { grep -qF -- "$1" "$STUB_LOG"; }
no_danger() { test ! -s "$DANGER_LOG"; }

PI_DISKS='/dev/mmcblk0 - disk - - - 59.5G mmc 0 0x1234 SD64G
/dev/mmcblk0p1 /dev/mmcblk0 part vfat /boot/firmware AAAA-1111 512M mmc 0 - -
/dev/mmcblk0p2 /dev/mmcblk0 part ext4 / root-uuid 59G mmc 0 - -
/dev/sda - disk - - - 1.8T usb 1 WD123 WD Elements 25A2
/dev/sda1 /dev/sda part ext4 - data-uuid-1 1.8T usb 1 - -
/dev/sdb - disk - - - 64G usb 0 SB999 SanDisk Ultra
/dev/sdb1 /dev/sdb part exfat - EXFAT-1 64G usb 0 - -
/dev/sdc - disk - - - 500G usb 0 BLANK1 Blank SSD
/dev/nvme0n1 - disk - - - 256G nvme 0 NV1 Samsung 980
/dev/nvme0n1p1 /dev/nvme0n1 part LVM2_member - lvm-uuid 256G nvme 0 - -
/dev/nvme1n1 - disk - - - 512G nvme 0 NV2 Crucial P3
/dev/nvme1n1p1 /dev/nvme1n1 part ext4 - nvme-uuid 512G nvme 0 - -'
VM_DISKS='/dev/vda - disk - - - 40G virtio 1 - QEMU HARDDISK
/dev/vda1 /dev/vda part ext4 / root-uuid 40G virtio 1 - -'

mkroot() { # dir os-id version codename model(empty=none) memKiB cpuflags lsblk rootsrc
  local r="$WORK/$1"
  rm -rf "$r"
  mkdir -p "$r/etc" "$r/proc/device-tree" "$r/var/lib/docker/volumes"
  printf 'ID=%s\nVERSION_ID="%s"\nVERSION_CODENAME=%s\n' "$2" "$3" "$4" > "$r/etc/os-release"
  [ -z "$5" ] || printf '%s\0' "$5" > "$r/proc/device-tree/model"
  printf 'MemTotal:       %s kB\n' "$6" > "$r/proc/meminfo"
  printf 'processor\t: 0\nflags\t\t: %s\n' "$7" > "$r/proc/cpuinfo"
  printf '%s\n' "$8" > "$r/lsblk.txt"
  echo "$9" > "$r/rootsrc"
  printf '# fstab\n/dev/mmcblk0p2 / ext4 defaults 0 1\n' > "$r/etc/fstab"
  touch "$r/var/lib/docker/volumes/metadata.db"
  snap "$r" > "$r.snap"
  echo "$r"
}
snap() { (cd "$1" && find . -type f -exec md5sum {} + | sort); }

rc=0
out=''
run() { # root, env..., -- args...
  local root="$1"
  shift
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$STUB_LOG"
  out="$(env PATH="$STUBS:$PATH" HOST_SETUP_ROOT="$root" "${envs[@]}" bash "$SCRIPT" "$@" 2>&1 </dev/null)"
  rc=$?
}
written() { diff "$1.snap" <(snap "$1"); } # prints what changed under the root

QEMU64='fpu de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 syscall nx lm nopl pni cx16 hypervisor lahf_lm'
PI5='Raspberry Pi 5 Model B Rev 1.0'

# 1. mob04: ubuntu resolute amd64, qemu64 (= x86-64-v1), no device tree → vm, report only.
VM="$(mkroot vm ubuntu 26.04 resolute '' 8000000 "$QEMU64" "$VM_DISKS" /dev/vda1)"
run "$VM" STUB_ARCH=amd64 --
check "vm: exits 0" test "$rc" -eq 0
check "vm: profile=vm" has 'profile=vm'
check "vm: arch=amd64" has 'arch=amd64'
check "vm: x86_level=v1" has 'x86_level=v1'
check "vm: boot_disk=/dev/vda" has 'boot_disk=/dev/vda'
check "vm: writes nothing" test -z "$(written "$VM")"
check "vm: runs nothing but the boot-disk lookup" test -z "$(grep -vxF 'findmnt -no SOURCE /' "$STUB_LOG")"
check "vm: prints provision.yml next step" has 'provision.yml'
run "$VM" STUB_ARCH=amd64 -- --profile pi5 --data-disk boot
check "vm: --profile pi5 refused" test "$rc" -eq 1 -a -n "$(grep 'not a Raspberry Pi 5' <<<"$out")"

# 2. unsupported hosts.
run "$VM" STUB_ARCH=armhf --
check "armhf: refused, asks for the 64-bit OS" test "$rc" -eq 1 -a -n "$(grep '64-bit OS' <<<"$out")"
FED="$(mkroot fedora fedora 40 '' '' 8000000 "$QEMU64" "$VM_DISKS" /dev/vda1)"
run "$FED" --
check "fedora: refused" test "$rc" -eq 1
PI="$(mkroot pi ubuntu 26.04 resolute "$PI5" 8000000 '' "$PI_DISKS" /dev/mmcblk0p2)"
run "$PI" STUB_ARCH=arm64 STUB_PAGE=16384 -- --data-disk boot
check "16K pages: refused, points at Ubuntu" test "$rc" -eq 1 -a -n "$(grep 'Ubuntu' <<<"$out")"

# 3. pi5 detection + data-disk choice.
run "$PI" STUB_ARCH=arm64 --
check "pi5 no flag no TTY: exit 2" test "$rc" -eq 2
check "pi5: profile=pi5 (model read past the NUL)" has 'profile=pi5'
check "pi5: model printed without NUL" has "model=$PI5"
run "$PI" STUB_ARCH=arm64 -- --data-disk boot
check "boot on mmcblk: exits 0" test "$rc" -eq 0
check "boot on mmcblk: SD wear warning" has 'microSD'
check "boot on mmcblk: writes nothing" test -z "$(written "$PI")"
DEB="$(mkroot deb debian 12 bookworm "$PI5" 8000000 '' "$PI_DISKS" /dev/mmcblk0p2)"
run "$DEB" STUB_ARCH=arm64 -- --data-disk boot
check "debian: warned untested, not refused" test "$rc" -eq 0 -a -n "$(grep 'untested' <<<"$out")"

# candidates() as the menu would list them: source the functions with a fake boot disk.
cands="$(env PATH="$STUBS:$PATH" HOST_SETUP_ROOT="$PI" bash -c '
  set -euo pipefail; DATA=/srv/pos-data; boot_disk=/dev/mmcblk0
  eval "$(sed -n "/^col()/p; /^mounted_elsewhere()/p; /^excluded()/,/^}/p; /^candidates()/,/^}/p" "$1")"
  candidates' _ "$SCRIPT")"
check "candidates: exclude boot mmcblk0" test -z "$(grep -x /dev/mmcblk0 <<<"$cands")"
check "candidates: include usb sda" grep -qx /dev/sda <<<"$cands"
check "candidates: include nvme1n1" grep -qx /dev/nvme1n1 <<<"$cands"
check "candidates: exclude LVM member nvme0n1" test -z "$(grep -x /dev/nvme0n1 <<<"$cands")"

run "$PI" STUB_ARCH=arm64 -- --data-disk /dev/mmcblk0
check "boot disk itself: refused" test "$rc" -eq 1
run "$PI" STUB_ARCH=arm64 -- --data-disk /dev/mmcblk0p2
check "boot partition: refused" test "$rc" -eq 1
run "$PI" STUB_ARCH=arm64 -- --data-disk /dev/nvme0n1
check "LVM member disk: refused" test "$rc" -eq 1

# 4. ext4 partition: mounted by UUID, one fstab line after two runs, daemon.json + drop-in.
run "$PI" STUB_ARCH=arm64 STUB_DATA_UUID=data-uuid-1 -- --data-disk /dev/sda
check "ext4: new fstab verified before it is installed" logged 'findmnt --verify --tab-file '"$PI"'/etc/fstab.pos-new'
check "ext4: no .pos-new left behind" test ! -e "$PI/etc/fstab.pos-new"
run "$PI" STUB_ARCH=arm64 STUB_DATA_UUID=data-uuid-1 -- --data-disk /dev/sda
check "ext4: exits 0 (second run)" test "$rc" -eq 0
check "ext4: fstab line exactly once" test "$(grep -cxF 'UUID=data-uuid-1 /srv/pos-data ext4 defaults,noatime,nofail 0 2' "$PI/etc/fstab")" = 1
check "ext4: fstab backed up" grep -q '^/dev/mmcblk0p2' "$PI/etc/fstab.pos-bak"
check "ext4: daemon.json content" test "$(cat "$PI/etc/docker/daemon.json")" = '{"data-root": "/srv/pos-data/docker", "features": {"containerd-snapshotter": false}}'
check "ext4: drop-in content" test "$(cat "$PI/etc/systemd/system/docker.service.d/10-pos-data.conf")" = "$(printf '[Unit]\nRequiresMountsFor=/srv/pos-data')"
check "ext4: mounted" logged 'mount /srv/pos-data'
check "ext4: docker restarted (was active)" logged 'systemctl restart docker'
check "ext4: HDD warning (ROTA=1)" has '27 W'
check "ext4: backups stay on the boot disk (said)" has 'backups stay'
run "$PI" STUB_ARCH=arm64 STUB_DATA_UUID=data-uuid-1 -- --data-disk /dev/sda1
check "ext4 partition named directly: exits 0" test "$rc" -eq 0
PW="$(mkroot pw ubuntu 26.04 resolute "$PI5" 8000000 '' "$PI_DISKS" /dev/mmcblk0p2)"
run "$PW" STUB_ARCH=arm64 STUB_DATA_UUID=wrong -- --data-disk /dev/nvme1n1
check "mount not from the expected UUID: refused" test "$rc" -eq 1 -a -n "$(grep 'not mounted from UUID=nvme-uuid' <<<"$out")"
check "mount not from the expected UUID: no daemon.json" test ! -e "$PW/etc/docker/daemon.json"

# fstab safety: a failed verify leaves fstab as it was; a last line without a newline is not glued to ours.
PV="$(mkroot pv ubuntu 26.04 resolute "$PI5" 8000000 '' "$PI_DISKS" /dev/mmcblk0p2)"
run "$PV" STUB_ARCH=arm64 STUB_DATA_UUID=data-uuid-1 STUB_VERIFY_FAIL=1 -- --data-disk /dev/sda
check "verify fails: refused" test "$rc" -eq 1 -a -n "$(grep 'left unchanged' <<<"$out")"
check "verify fails: fstab, daemon.json, drop-in untouched" test -z "$(written "$PV")"
check "verify fails: nothing mounted" test -z "$(grep '^mount' "$STUB_LOG")"
printf '# fstab\n/dev/mmcblk0p2 / ext4 defaults 0 1' > "$PV/etc/fstab"
run "$PV" STUB_ARCH=arm64 STUB_DATA_UUID=data-uuid-1 -- --data-disk /dev/sda
check "no trailing newline: root line intact" grep -qx '/dev/mmcblk0p2 / ext4 defaults 0 1' "$PV/etc/fstab"
check "no trailing newline: our line on its own" grep -qx 'UUID=data-uuid-1 /srv/pos-data ext4 defaults,noatime,nofail 0 2' "$PV/etc/fstab"
PM="$(mkroot pm ubuntu 26.04 resolute "$PI5" 8000000 '' "$PI_DISKS" /dev/mmcblk0p2)"
run "$PM" STUB_ARCH=arm64 STUB_DATA_MOUNTED=1 STUB_DATA_UUID=other -- --data-disk /dev/sda
check "/srv/pos-data already mounted from another fs: refused" test "$rc" -eq 1 -a -n "$(grep 'already mounted' <<<"$out")"
check "/srv/pos-data already mounted from another fs: nothing written" test -z "$(written "$PM")"
PR="$(mkroot pr ubuntu 26.04 resolute "$PI5" 8000000 '' "$PI_DISKS" /dev/root)"
run "$PR" STUB_ARCH=arm64 -- --data-disk /dev/sda
check "boot disk unknown: pi5 refused" test "$rc" -eq 1 -a -n "$(grep 'which disk holds' <<<"$out")"
VR="$(mkroot vr ubuntu 26.04 resolute '' 8000000 "$QEMU64" "$VM_DISKS" /dev/root)"
run "$VR" STUB_ARCH=amd64 --
check "boot disk unknown: vm report still exits 0" test "$rc" -eq 0

# 5. non-ext4: refused, commands printed with model/serial, nothing formatted.
P2="$(mkroot p2 ubuntu 26.04 resolute "$PI5" 8000000 '' "$PI_DISKS" /dev/mmcblk0p2)"
run "$P2" STUB_ARCH=arm64 -- --data-disk /dev/sdb
check "exfat: refused" test "$rc" -eq 1
check "exfat: prints mkfs for the existing partition" has 'sudo mkfs.ext4 -L pos-data /dev/sdb1'
check "exfat: names model + serial" has 'SanDisk'
run "$P2" STUB_ARCH=arm64 -- --data-disk /dev/sdb1
check "exfat partition named: re-run hint names the partition" has '--data-disk /dev/sdb1'
run "$P2" STUB_ARCH=arm64 -- --data-disk /dev/sdc
check "blank disk: refused" test "$rc" -eq 1
check "blank disk: prints sfdisk gpt" has "sudo sfdisk --wipe always /dev/sdc"
check "blank disk: names serial" has 'BLANK1'
check "no mkfs/sfdisk/wipefs/dd ever invoked" no_danger
check "non-ext4: writes nothing" test -z "$(written "$P2")"

# 6. Docker refusals.
P3="$(mkroot p3 ubuntu 26.04 resolute "$PI5" 8000000 '' "$PI_DISKS" /dev/mmcblk0p2)"
mkdir -p "$P3/var/lib/docker/volumes/server_pgdata"
run "$P3" STUB_ARCH=arm64 STUB_DATA_UUID=data-uuid-1 -- --data-disk /dev/sda
check "existing volumes: refused" test "$rc" -eq 1 -a -n "$(grep 'provision.yml' <<<"$out")"
check "existing volumes: fstab untouched" test "$(grep -c pos-data "$P3/etc/fstab")" = 0
P4="$(mkroot p4 ubuntu 26.04 resolute "$PI5" 8000000 '' "$PI_DISKS" /dev/mmcblk0p2)"
mkdir -p "$P4/etc/docker"
echo '{"log-driver": "local"}' > "$P4/etc/docker/daemon.json"
run "$P4" STUB_ARCH=arm64 STUB_DATA_UUID=data-uuid-1 -- --data-disk /dev/sda
check "different daemon.json: refused" test "$rc" -eq 1
check "different daemon.json: left as is" grep -q log-driver "$P4/etc/docker/daemon.json"

# 7. Tailscale.
run "$VM" STUB_ARCH=amd64 -- --tailscale
check "ts ubuntu: exits 0" test "$rc" -eq 0
check "ts ubuntu: resolute repo" logged 'https://pkgs.tailscale.com/stable/ubuntu/resolute.noarmor.gpg'
check "ts ubuntu: keyring list" logged 'resolute.tailscale-keyring.list'
check "ts: up with /32 route" logged 'tailscale up --hostname=pi5-pos --advertise-routes=192.168.1.50/32'
check "ts: up with --snat-subnet-routes=false" logged '--snat-subnet-routes=false'
check "ts: up with tag" logged '--advertise-tags=tag:pos-server'
check "ts: never an auth key" test -z "$(grep -i authkey "$STUB_LOG")"
check "ts: sysctl file" grep -qx 'net.ipv4.ip_forward = 1' "$VM/etc/sysctl.d/99-tailscale.conf"
check "ts: prints the policy prerequisite" has 'tag:pos-server'
check "ts: prints approve + key expiry" has 'Disable key expiry'
run "$DEB" STUB_ARCH=arm64 -- --data-disk boot --tailscale --lan-ip 10.0.0.5 --ts-hostname shop
check "ts debian: bookworm repo" logged 'https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg'
check "ts: --lan-ip used" logged '--advertise-routes=10.0.0.5/32'
run "$VM" STUB_ARCH=amd64 STUB_TS_LOGGEDIN=1 -- --tailscale
check "ts logged in: set, not up" test -n "$(grep 'tailscale set --advertise-routes=192.168.1.50/32 --snat-subnet-routes=false' "$STUB_LOG")" -a -z "$(grep 'tailscale up' "$STUB_LOG")"
# mob04 as it is: installed by hand, logged in, sysctl file already there → only `tailscale set`.
MB="$(mkroot mb ubuntu 26.04 resolute '' 8000000 "$QEMU64" "$VM_DISKS" /dev/vda1)"
mkdir -p "$MB/etc/sysctl.d"
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > "$MB/etc/sysctl.d/99-tailscale.conf"
snap "$MB" > "$MB.snap"
run "$MB" STUB_ARCH=amd64 STUB_TS_INSTALLED=1 STUB_TS_LOGGEDIN=1 -- --tailscale --lan-ip 172.30.58.20
check "mob04 ts: exits 0" test "$rc" -eq 0
check "mob04 ts: no curl, no apt-get" test -z "$(grep -E '^(curl|apt-get)' "$STUB_LOG")"
check "mob04 ts: writes nothing (repo, keyring, sysctl kept)" test -z "$(written "$MB")"
check "mob04 ts: only set, never up" test -n "$(grep -x 'tailscale set --advertise-routes=172.30.58.20/32 --snat-subnet-routes=false' "$STUB_LOG")" -a -z "$(grep 'tailscale up' "$STUB_LOG")"
printf 'net.ipv6.conf.all.forwarding = 1' > "$MB/etc/sysctl.d/99-tailscale.conf"
run "$MB" STUB_ARCH=amd64 STUB_TS_INSTALLED=1 STUB_TS_LOGGEDIN=1 -- --tailscale --lan-ip 172.30.58.20
check "ts sysctl: ipv4 line appended, other lines kept" test "$(cat "$MB/etc/sysctl.d/99-tailscale.conf")" = "$(printf 'net.ipv6.conf.all.forwarding = 1\nnet.ipv4.ip_forward = 1')"
run "$VM" STUB_ARCH=amd64 -- --tailscale --lan-ip 100.101.102.103
check "ts: tailnet 100.64/10 address refused as lan ip" test "$rc" -eq 1
run "$VM" STUB_ARCH=amd64 -- --tailscale --lan-ip 300.1.1.1
check "ts: invalid lan ip refused" test "$rc" -eq 1
run "$VM" STUB_ARCH=amd64 STUB_CURL_404=1 -- --tailscale
check "ts: missing repo refused clearly" test "$rc" -eq 1 -a -n "$(grep 'no apt repo' <<<"$out")"

# 8. memory, dry-run, usage.
P5="$(mkroot p5 ubuntu 24.04 noble "$PI5" 4000000 '' "$PI_DISKS" /dev/mmcblk0p2)"
run "$P5" STUB_ARCH=arm64 -- --data-disk boot
check "4 GB: memory warning" has 'MiB RAM'
run "$P5" STUB_ARCH=arm64 STUB_DATA_UUID=data-uuid-1 -- --data-disk /dev/sda --dry-run
check "dry-run: exits 0" test "$rc" -eq 0
check "dry-run: prints the fstab line" has 'DRY-RUN: append to /etc/fstab: UUID=data-uuid-1'
check "dry-run: writes nothing" test -z "$(written "$P5")"
run "$VM" -- --bogus
check "unknown option: exit 2" test "$rc" -eq 2
check "no mkfs/sfdisk/wipefs/dd ever invoked (end)" no_danger

if [ "$fails" -ne 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all host-setup tests passed"
