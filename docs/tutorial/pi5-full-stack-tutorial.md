# คู่มือตั้ง full stack บน Raspberry Pi 5 (8 GB) — ฉบับมือใหม่

**ตรวจกับโค้ดที่:** `origin/develop` @ `b582fe8` · 2026-10-13 (release `main` `5c7f210`, PR #714)
**เอกสารเจ้าของเรื่อง:** `docs/Backend_design/07_CICD_DEPLOY.md` §3 (multi-arch), §5 (TLS / `CERT_SAN_IPS`), §6 (`host-setup.sh`), §6.2 (runner) ·
แผนย้าย: `docs/research/pi5-migration-plan.md` · ถ้าคู่มือนี้ขัดกับไฟล์ใน `deploy/` → **ไฟล์ถูก**
**คู่มือพี่น้อง:** `docs/tutorial/VM-dploy-full-stack-tutorial.md` (VM `mob04`) — คู่มือนี้ **ชี้ไปที่นั่น** ในทุกขั้นที่เหมือนกัน ไม่คัดลอกซ้ำ

---

## 0. อ่านก่อน — อะไรพิสูจน์แล้ว อะไรยัง

| สถานะ | เรื่อง |
|---|---|
| ✅ พิสูจน์แล้ว | image `srisurart-pos-server` + `srisurart-pos-web` ที่ tag `<sha>`/`main` เป็น manifest list **amd64 + arm64** ตั้งแต่ release `5c7f210` (PR #714, 2026-10-13) — `verify-ghcr-tags.sh 5c7f210e… linux/arm64` ผ่านทั้งสอง image |
| ✅ | ขา arm64 ของ image server ผ่าน sharp check ใต้ `qemu-aarch64 -cpu cortex-a76` (CPU ของ Pi 5) ใน CI ก่อน push (07 §3) |
| ✅ | image ภายนอกที่ pin digest ไว้ (postgres, redis ×2, etcd, nginx, alpine/openssl, curl, prometheus, grafana, node-exporter) ทุกตัวเป็น index ที่มี `linux/arm64` (ตรวจด้วย `docker buildx imagetools inspect` 2026-10-13) |
| ✅ | `host-setup.sh` ผ่าน test แบบ stub (`deploy/scripts/test/host-setup.test.sh` — ไม่แตะดิสก์จริง) + `--dry-run` อ่านอย่างเดียวบน `mob04` (Ubuntu 26.04, amd64) |
| ❌ ยังไม่เคยทำ | **ยังไม่เคยมี Pi จริงสักเครื่อง** — `lsblk`/`findmnt` กับดิสก์จริง, `RequiresMountsFor` ตอนถอดดิสก์, page size ของ kernel Ubuntu บน Pi, Docker/Tailscale apt repo บน Ubuntu arm64, stack ทั้งชุด boot บน Pi — **ยังไม่มีข้อไหนถูกพิสูจน์** |
| ❌ ยังไม่ต่อ | **CD ไป Pi ยังไม่มี:** job `deploy` ใน `.github/workflows/deploy.yml` รันบน `[self-hosted, srisurart-demo-deploy]` (= `mob04`) และ `verify-ghcr-tags.sh` ใน workflow ยังไม่ส่ง platform → §8 ของคู่มือนี้จึงเป็น **ทางมือ / ซ้อม** เท่านั้น |

🔴 **`mob04` ยังเป็น production จนกว่า owner ตัดสิน** (แผนย้าย §5 cutover ยังไม่เริ่ม) · คู่มือนี้ = ตั้ง Pi ขึ้นมา **ซ้อม** ด้วยข้อมูลทดสอบ
ห้ามใช้ tenant จริง ห้ามชี้ APK ที่ร้านใช้มาที่ Pi

ลำดับทั้งหมด (ห้ามสลับ):

```text
§2 ลง OS ─▶ §3 เตรียมดิสก์ ─▶ §4 host-setup.sh ─▶ §5 .env ─▶ §6 provision.yml (cloud) ─▶ [§7 runner] ─▶ §8 deploy.yml (deploy)
```

`host-setup.sh` **ต้องมาก่อน** `provision.yml` — มันปฏิเสธถ้า Docker มี volume แล้ว (§12)

---

## 1. ฮาร์ดแวร์ (ราคา + เหตุผล: แผนย้าย §2)

| # | ของ | หมายเหตุ |
|---|---|---|
| 1 | Raspberry Pi 5 **8 GB** | `host-setup.sh` เตือนถ้า RAM < 7168 MiB (`mem_limit` รวมของ stack ≈ 4.2 GB) |
| 2 | ที่จ่ายไฟทางการ **27 W USB-C** | ห้ามใช้ที่ชาร์จโทรศัพท์ |
| 3 | Active Cooler + เคสระบายอากาศ | |
| 4 | **ดิสก์ข้อมูล** (เลือกหนึ่ง) | USB SSD · USB HDD (**ต้องมีกล่องที่มีไฟเลี้ยงเอง** หรือ hub มีไฟ — สคริปต์เตือนเมื่อเจอ HDD) · NVMe ผ่าน M.2 HAT+ · หรือ microSD ตัวเดียว (**ไม่แนะนำ** — Postgres เขียนตลอด SD สึกและพังโดยไม่เตือน) |
| 5 | microSD 32 GB | ใส่ OS |
| 6 | แบตเตอรี่ RTC | ไฟดับ + เน็ตไม่กลับ = นาฬิกาเพี้ยน → เลขเอกสาร/ใบรับรองผิด |
| 7 | UPS | ร้านไฟตกบ่อย (แผนย้าย §2 ข้อ 7) |
| 8 | สาย LAN | ใช้ Ethernet ไม่ใช้ Wi-Fi |

---

## 2. ลง OS

**OS = Ubuntu Server 26.04 LTS 64-bit** (สำรอง: 24.04 LTS) — สองรุ่นนี้เท่านั้นที่ `host-setup.sh` รับโดยไม่เตือน

🔴 **ห้ามใช้ Raspberry Pi OS:** kernel ของมันบน Pi 5 ใช้ page 16K → Redis/jemalloc พัง · `host-setup.sh` ปฏิเสธ
`kernel page size is 16384, not 4096` · และ `provision.yml` ทดสอบกับ Ubuntu เท่านั้น

1. **Raspberry Pi Imager** → Device: Raspberry Pi 5 → OS: *Other general-purpose OS → Ubuntu → Ubuntu Server 26.04 LTS (64-bit)* → microSD
2. ตั้งค่าใน Imager (OS customisation):
   * **username = `cloud`** — ชื่อเดียวกับ `mob04` คู่มือนี้และคู่มือ VM ใช้ `DEMO_SSH_USER=cloud` ตอน provision (ชื่ออื่นใช้ได้ แต่ต้องแทนทุกที่)
   * hostname เช่น `pi5-pos` · เปิด SSH แบบ **public key เท่านั้น** (วาง `.pub` ของ key ที่จะใช้เป็น `cloud`) · timezone `Asia/Bangkok`
3. เสียบ LAN → boot → ตั้ง **IP คงที่** (แนะนำ: DHCP reservation ที่ router ผูก MAC ของ Pi) · 🔴 IP นี้ถูกฝังใน SAN ของใบรับรอง (§5) —
   IP เปลี่ยน = ต้องแก้ `CERT_SAN_IPS` แล้ว deploy ใหม่ · คู่มือนี้เรียกมันว่า `<PI_IP>`
4. ssh ครั้งแรก + ตรวจ:

```bash
ssh cloud@<PI_IP> 'cat /etc/os-release | grep -E "^(ID|VERSION_ID)="; dpkg --print-architecture; getconf PAGESIZE; sudo -n true && echo "sudo ok"'
```

✅ `ID=ubuntu`, `VERSION_ID="26.04"` (หรือ `24.04`), `arm64`, `4096`, `sudo ok`
❌ `sudo` ถามรหัส → `provision.yml` (`become: true`) จะค้าง: เพิ่ม `-K` (`--ask-become-pass`) ตอนรัน §6 หรือตั้ง NOPASSWD ให้ `cloud`

5. **EEPROM** — Canonical ระบุ Pi 5 + Ubuntu 24.04 ต้อง bootloader EEPROM ≥ 2025-02-11 (แผนย้าย §2) · ตรวจ:

```bash
ssh cloud@<PI_IP> 'sudo rpi-eeprom-update'
```

มีรุ่นใหม่ → `sudo rpi-eeprom-update -a` แล้ว reboot · ⚠️ ยังไม่ได้ยืนยันว่า Ubuntu 26.04 ติดตั้ง `rpi-eeprom-update` มาให้ —
ถ้าไม่มี ใช้ Imager → *Misc utility images → Bootloader* เขียนลง SD แยก boot หนึ่งครั้ง

6. `~/.ssh/config` บน notebook (ตรึง host key ด้วยการ ssh มือครั้งแรกแบบเดียวกับคู่มือ VM §1.4 — `ansible.cfg` ปิด host key checking):

```text
Host pi5
  HostName <PI_IP>
  User cloud
  IdentityFile ~/.ssh/pi5-cloud
  IdentitiesOnly yes

Host pi5-deploy
  HostName <PI_IP>
  User deploy
  IdentityFile ~/.ssh/deploy_ed25519
  IdentitiesOnly yes
```

(`pi5-deploy` ใช้ได้หลัง §6 — `provision.yml` สร้าง user `deploy` + ใส่ key ให้)

---

## 3. เตรียมดิสก์ข้อมูล (ข้ามได้ถ้าเลือก `boot`)

`host-setup.sh` **ไม่ format / partition / wipe อะไรเลย** · ดิสก์ต้องมี **ext4 อยู่แล้ว** · ดิสก์ที่ยังไม่ใช่ ext4 → สคริปต์ปฏิเสธ
แล้ว **พิมพ์** คำสั่งให้คุณรันเอง (§4 ข้อ 2) — คุณรันเองหลังตรวจแล้วเท่านั้น

ดูรายการดิสก์:

```bash
ssh pi5 'lsblk -o NAME,MODEL,SERIAL,SIZE,TRAN,ROTA,FSTYPE,MOUNTPOINT'
```

🔴🔴 **ก่อนรันคำสั่ง `sfdisk`/`mkfs.ext4` ใด ๆ: เทียบ MODEL + SERIAL + SIZE กับฉลากบนดิสก์ที่เสียบจริง** — คำสั่งข้างล่าง **ลบทุกอย่างบนดิสก์นั้น**
ผิดตัว = OS หรือข้อมูลอื่นหาย กู้ไม่ได้ · boot disk ของ Pi ปกติคือ `mmcblk0` (microSD) — ห้ามแตะ

รูปแบบที่สคริปต์พิมพ์ (ตรงกับโค้ดใน `setup_storage`):

* **ดิสก์ทั้งลูกไม่มี partition:**
  ```bash
  printf 'label: gpt\n,,L\n' | sudo sfdisk --wipe always /dev/sdX
  lsblk /dev/sdX    # อ่านชื่อ partition ใหม่ เช่น sda1, nvme0n1p1
  sudo mkfs.ext4 -L pos-data <partition นั้น>
  ```
* **partition ที่มีอยู่แล้ว:** `sudo mkfs.ext4 -L pos-data /dev/sdX1`

ดิสก์ที่มีหลาย partition → สคริปต์ปฏิเสธ ให้ระบุ partition เองใน `--data-disk`

---

## 4. รัน `host-setup.sh` (ในนาม `cloud`, ครั้งเดียว)

**1. ส่งสคริปต์ขึ้น Pi จาก checkout สะอาด** (Windows: ไฟล์ต้องไม่ติด CRLF — ใช้ worktree ที่สร้างด้วย `git -c core.autocrlf=false` แบบคู่มือ VM §3 ข้อ 4):

```bash
scp deploy/scripts/host-setup.sh pi5:/tmp/host-setup.sh
```

```bash
ssh pi5 'grep -c $'"'"'\r'"'"' /tmp/host-setup.sh'
```

✅ `0` · ❌ มากกว่า 0 = ไฟล์ติด CRLF ส่งใหม่

**2. `--dry-run` ก่อนเสมอ** (พิมพ์ทุก action ไม่เขียนอะไร):

```bash
ssh -t pi5 'sudo bash /tmp/host-setup.sh --profile pi5 --data-disk /dev/sdX --dry-run'
```

ส่วนหัวที่ต้องเห็น (`key=value`):

```text
os_id=ubuntu
arch=arm64
page_size=4096
model=Raspberry Pi 5 Model B ...
profile=pi5
data_disk=/dev/sdX
```

ตามด้วยบรรทัด `DRY-RUN: ...` (mkdir, append fstab, write daemon.json, write drop-in) · ❌ `REFUSED: ...` → §12

**3. เลือกที่เก็บข้อมูล** — `--data-disk` มีสามแบบ:

| คำสั่ง | ผล |
|---|---|
| `--data-disk boot` | ไม่เปลี่ยนอะไร (ข้อมูลอยู่บน microSD) · ถ้า boot disk เป็น `mmcblk*` สคริปต์เตือนเรื่อง SD สึก |
| `--data-disk /dev/sda` (ดิสก์) หรือ `/dev/sda1` (partition) | mount ดิสก์ ext4 นั้นที่ `/srv/pos-data` |
| ไม่ใส่ flag (ใน `ssh -t` ที่มี TTY) | เมนูตัวเลข: `0) boot` + ดิสก์ที่เลือกได้พร้อม model/serial/size · ไม่มี TTY = exit 2 |

**4. รันจริง** — คำสั่งเดียวกับข้อ 2 ไม่มี `--dry-run`:

```bash
ssh -t pi5 'sudo bash /tmp/host-setup.sh --profile pi5 --data-disk /dev/sdX'
```

สิ่งที่สคริปต์เขียน (เฉพาะเมื่อเลือกดิสก์ ไม่ใช่ `boot`):

| ไฟล์ | เนื้อหา |
|---|---|
| `/etc/fstab` | เพิ่มบรรทัดเดียว `UUID=<uuid> /srv/pos-data ext4 defaults,noatime,nofail 0 2` (ผ่าน `findmnt --verify` บนสำเนาก่อนแทนที่) · สำรองเดิมไว้ที่ `/etc/fstab.pos-bak` (ครั้งแรกครั้งเดียว) |
| `/srv/pos-data`, `/srv/pos-data/docker` | ไดเรกทอรี + mount |
| `/etc/docker/daemon.json` | `{"data-root": "/srv/pos-data/docker", "features": {"containerd-snapshotter": false}}` — volume, image และ layer ของ Docker อยู่บนดิสก์ข้อมูลทั้งหมด |
| `/etc/systemd/system/docker.service.d/10-pos-data.conf` | `RequiresMountsFor=/srv/pos-data` — ดิสก์หาย Docker **ไม่ start** (แทนที่จะ start บนโฟลเดอร์เปล่าใน SD แล้วดูเหมือนร้านไม่มีข้อมูล) |

* **Docker ยังไม่ได้ติดตั้งตอนนี้ — ปกติ:** สคริปต์เขียน `daemon.json` + drop-in ไว้ก่อน แล้ว restart Docker **เฉพาะเมื่อมันรันอยู่** ·
  `provision.yml` (§6) ติดตั้ง `docker-ce` ทีหลัง และไม่แตะ `daemon.json` → Docker start ครั้งแรกบน `/srv/pos-data/docker` เลย
  (อ่านจากโค้ดทั้งสองไฟล์ — ยังไม่เคยเห็นบน Pi จริง จึงต้องตรวจข้อ 5)
* **backup อยู่ `/opt/pos/backups` บน boot disk** — คนละอุปกรณ์กับ pgdata โดยตั้งใจ (ดิสก์ข้อมูลพัง backup ยังอยู่ และกลับกัน)

✅ จบด้วย `data disk ready: Docker data-root = /srv/pos-data/docker` แล้ว `Next steps:` · ตรวจทันที:

```bash
ssh pi5 'findmnt /srv/pos-data; cat /etc/docker/daemon.json; cat /etc/systemd/system/docker.service.d/10-pos-data.conf'
```

✅ `findmnt` แสดง `/srv/pos-data` จากดิสก์ที่เลือก, `ext4`

**5. ตรวจอีกรอบหลัง §6** (ตอนนั้น Docker ติดตั้งแล้ว):

```bash
ssh pi5 'sudo docker info --format "{{.DockerRootDir}}"; systemctl cat docker | grep RequiresMountsFor'
```

✅ `/srv/pos-data/docker` และ `RequiresMountsFor=/srv/pos-data` · ❌ `/var/lib/docker` → หยุด ห้าม deploy (volume จะไปอยู่บน SD)

**6. (ทางเลือก) ซ้อมถอดดิสก์ — ยังไม่เคยมีใครทำ:** ปิดเครื่อง → ถอดดิสก์ข้อมูล → boot → `systemctl status docker` ต้อง **ไม่ active**
(ตั้งใจ — §12) → ปิด เสียบกลับ boot → `docker` active · ทำก่อนมีข้อมูลจริง

### 4.1 (ทางเลือก) `--tailscale` — เข้าถึงจากนอกร้าน

สรุปจาก `docs/research/tailscale-remote-access-plan-2026-10-13.md` (ทำบน `mob04` แล้ว 2026-10-13) — **owner ทำ 👤 ก่อน:**

* tailnet policy: `tagOwners` มี `tag:pos-server` และ grant ให้ผู้ใช้ถึง `<PI_IP>/32` **tcp:443 เท่านั้น** · SSH ผ่าน tailnet = owner คนเดียว
* แผนฟรี Personal = **ใช้ที่ไม่ใช่เชิงพาณิชย์เท่านั้น** — ร้านใช้จริงต้องให้ owner ตัดสินใหม่

```bash
ssh -t pi5 'sudo bash /tmp/host-setup.sh --profile pi5 --data-disk /dev/sdX --tailscale --lan-ip <PI_IP> --dry-run'
```

ผ่านแล้วรันจริง (ไม่มี `--dry-run`) · สคริปต์ติดตั้งจาก apt repo ที่ลงลายเซ็นของ Tailscale, เปิด `net.ipv4.ip_forward = 1`
แล้ว `tailscale up --advertise-routes=<PI_IP>/32 --advertise-tags=tag:pos-server --snat-subnet-routes=false` — **ไม่รับ auth key**:
มันพิมพ์ URL ให้ owner เปิด login เอง · จากนั้น owner ใน admin console → Machines → `<hostname>-pos`: **approve route** `<PI_IP>/32` + **Disable key expiry**

🔴 **`--snat-subnet-routes=false` ห้ามเปิดกลับ** — ถ้า SNAT ทุก request จะมาจาก IP เดียว → rate limit ต่อ IP ของ login รวมทุกเครื่องเป็น bucket เดียว
และ nginx allowlist แบบ RFC1918 จะเห็นทุกคนเป็น LAN · ตรวจ: access log ของ nginx ต้องเห็น `100.x.y.z` ต่างกันต่อโทรศัพท์
⚠️ ยังไม่ยืนยันว่า Tailscale มี apt repo สำหรับ Ubuntu 26.04 arm64 — สคริปต์ตรวจให้ก่อน (`Tailscale has no apt repo for ...` = หยุด)

---

## 5. `.env` ของ Pi

ทำตามคู่มือ VM §2.2 **"สร้างไฟล์ใหม่จากศูนย์ — เฉพาะ VM ที่ไม่มี volume"** (Pi ใหม่ไม่มี volume) — กฎเดิมทุกข้อ: hex เท่านั้น,
คีย์บังคับครบ 11 ตัว, ไม่มี `ALLOW_DEV_SECRETS`/`IMAGE_TAG`/`dev-only-*`, ห้ามวางค่าในแชต/commit · เก็บแยกไฟล์ เช่น `~/secrets/pi5-demo.env`

```bash
export SECRETS_FILE=~/secrets/pi5-demo.env
```

ต่างจาก `mob04` แค่นี้:

| คีย์ | ค่าบน Pi | ทำไม |
|---|---|---|
| `CERT_SAN_IPS` | `<PI_IP>` (ช่วงซ้อมที่อยากให้ใบเดียวรับทั้งสอง IP: `172.30.58.20,<PI_IP>`) | `certgen.sh` ใส่ IP ใน SAN ของใบ server · ไม่ตั้ง = `172.30.58.20` (ของ `mob04`) → เบราว์เซอร์/แอปที่เรียก `<PI_IP>` จะ `IP address mismatch` · ค่าที่ไม่ใช่ IPv4 = certgen exit 1 |
| `CORS_ORIGINS` | `https://<PI_IP>` | origin ของ Pi เอง · ตั้งแต่ #367 ค่าที่ตั้งแต่ว่างทำให้ api ไม่ boot |
| `HEALTHCHECKS_PING_URL` | check **ใหม่** ของ Pi หรือไม่ใส่ | 🔴 **ห้ามใช้ URL ของ `mob04`** — สองเครื่อง ping URL เดียว = `mob04` ดับแล้วไม่มีใครรู้ |
| `PLATFORM_ADMINS` | ตามคู่มือ VM | ไม่มี = platform-ui ไม่มี admin ให้ login |

secret ทุกตัว **สร้างใหม่** — อย่าคัดลอกของ `mob04` (Pi ซ้อม = stack แยก)

---

## 6. `provision.yml` ในนาม `cloud`

ทำจาก worktree สะอาดที่ SHA ที่จะ deploy (คู่มือ VM §3 ข้อ 4) ใน `deploy/ansible/` · `$DEPLOY_KEY.pub` = key ที่จะใส่ให้ user `deploy`

```bash
test -s "$SECRETS_FILE" && test -s "$DEPLOY_KEY.pub" && DEMO_ENV_FILE="$(cat "$SECRETS_FILE")" DEMO_SSH_KEY_PUB="$(cat "$DEPLOY_KEY.pub")" DEMO_SSH_HOST=<PI_IP> DEMO_SSH_USER=cloud DEMO_SSH_KEY_PATH="$HOME/.ssh/pi5-cloud" ansible-playbook provision.yml
```

(Windows: ฟังก์ชัน `ans` ของคู่มือ VM §1.1 — `KEYFILE=pi5-cloud ans ansible-playbook provision.yml` แทน `DEMO_SSH_KEY_PATH`)

🔴 **ห้าม `--diff`** (พิมพ์ `.env` ทั้งไฟล์) · 🔴 ห้ามลืม `DEMO_SSH_HOST` (ไม่ตั้ง = `127.0.0.1` = เครื่องตัวเอง) · ห้ามใช้ `DEMO_SSH_USER=deploy` กับ playbook นี้

ทำอะไร (ตามโค้ด): apt ติด Docker Engine + compose plugin (repo `download.docker.com/linux/ubuntu`, arch `aarch64→arm64`) → UFW
(อนุญาตแค่ 22/80/443) → user `deploy` (group `docker`) + authorized key → `/opt/pos/...` → copy สคริปต์ ops ลง `/opt/pos/scripts` →
ตรวจคีย์บังคับใน `DEMO_ENV_FILE` → เขียน `/opt/pos/.env` (0600) → `/opt/pos/backups` → cron backup 03:00 + heartbeat ทุก 5 นาที

✅ recap `failed=0` · แล้วทำ **§4 ข้อ 5** (data-root) ทันที · แล้วตรวจ user `deploy`:

```bash
ssh pi5-deploy 'id; ls -ld /opt/pos; stat -c "%A %U:%G %n" /opt/pos/.env'
```

✅ group `docker` และ `-rw------- deploy:deploy /opt/pos/.env`

---

## 7. (ทางเลือก ซ้อมเท่านั้น) runner บน Pi

ติดตั้งได้ แต่ **จะไม่ได้รับงาน deploy ใด ๆ** จนกว่าจะมีคนแก้ `deploy.yml` (ยังรันบน label `srisurart-demo-deploy` ของ `mob04`)

* หน้า GitHub → Settings → Actions → Runners → New self-hosted runner → **Linux + ARM64** → จด token, version, sha256 ของ tarball arm64
* บน `aarch64` สคริปต์ **บังคับ** `RUNNER_NAME` + `RUNNER_LABELS` และ `sudo` ล้าง env จึงต้องใส่หลัง `sudo`:

```bash
sudo RUNNER_NAME=pi5-demo RUNNER_LABELS=srisurart-pi-deploy ./setup-mob04-runner.sh <token> <version> <sha256>
```

🔴 **ห้ามใช้ label `srisurart-demo-deploy` หรือชื่อ `mob04-demo`** — `config.sh --replace` จะยึด registration ของ `mob04` และ GitHub
จะส่ง deploy ของ production ไปเครื่องไหนก็ได้ที่ว่าง · ตรวจ: `gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners` เห็น `pi5-demo` แยกจาก `mob04-demo`

---

## 8. deploy ครั้งแรกขึ้น Pi (ทางมือ ในนาม `deploy`)

ทำตามคู่มือ VM §3 ทุกข้อ โดยแทน `mob04-deploy` → `pi5-deploy` และ `172.30.58.20` → `<PI_IP>` · ต่างกันแค่ข้างล่าง

**1. SHA ต้องมี arm64** — ใช้ได้เฉพาะ `5c7f210` หรือใหม่กว่าบน `main` (release ก่อนหน้าเป็น amd64 อย่างเดียว):

```bash
bash deploy/scripts/verify-ghcr-tags.sh "$TAG" linux/arm64
```

✅ `Both server and web images for tag '<sha>' are verified on GHCR for linux/arm64.` (exit 0)
❌ exit 2 + `Release '<sha>' was not built for linux/arm64 ...` → SHA เก่ากว่า `5c7f210` เลือกใหม่ (exit 2 อื่น = ถาม GHCR ไม่ได้) · exit 1 = image ยังไม่ครบ รอ CI

**2. gate ดึง image จาก Pi จริง** (พิสูจน์ว่าเน็ตที่ Pi อยู่ออก `ghcr.io` ได้):

```bash
ssh pi5-deploy "docker pull ghcr.io/nuimanlp/srisurart-pos-server:$TAG" && echo "gate ok"
```

**3. ข้าม backup ก่อน deploy** — Pi ใหม่ยังไม่มี DB และไม่มี `.current_sha` (`backup-db.sh` จะ error เรื่อง `IMAGE_TAG`) · deploy ครั้งต่อไปทำตามคู่มือ VM §3 ข้อ 8 ตามปกติ

**4. deploy** (ใน `deploy/ansible/` ของ worktree ที่ `$TAG`):

```bash
test -s "$DEPLOY_KEY" && DEMO_SSH_HOST=<PI_IP> DEMO_SSH_USER=deploy DEMO_SSH_KEY_PATH="$DEPLOY_KEY" ansible-playbook deploy.yml -e image_tag="$TAG" </dev/null
```

ครั้งแรกนาน (pull ทุก image + migration ทั้งหมด) · inventory ยังชื่อ host `vm-demo` → ข้อความ `Successfully deployed release '<sha>' to vm-demo.` เป็นปกติ
✅ recap `failed=0` — **ยังไม่ใช่หลักฐาน** ไปข้อ 5

**5. ตรวจผล** (ทุกข้อต้องผ่าน):

```bash
ssh pi5-deploy 'cat /opt/pos/.current_sha'
```

✅ = `$TAG` (หลักฐานเดียวว่า release ถึงเครื่อง)

```bash
ssh pi5-deploy 'curl -sk -o /dev/null -w "health_ready=%{http_code}\n" https://127.0.0.1/health/ready'
```

✅ `health_ready=200`

```bash
ssh pi5-deploy "docker image inspect ghcr.io/nuimanlp/srisurart-pos-server:$TAG --format '{{.Architecture}}'"
```

✅ `arm64`

จาก notebook ที่อยู่ LAN เดียวกับ Pi — SAN ของใบที่ nginx เสิร์ฟต้องมี IP ของ Pi:

```bash
openssl s_client -connect <PI_IP>:443 </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName
```

✅ มี `IP Address:<PI_IP>` · ❌ มีแค่ `172.30.58.20` → `CERT_SAN_IPS` ไม่ถึง `/opt/pos/.env` (กลับ §5 + provision ใหม่ แล้ว deploy ซ้ำ — `.env` เปลี่ยน = deploy SHA เดิมซ้ำเอง)

เปิด `https://<PI_IP>` ในเบราว์เซอร์ → หน้า login ขึ้น (เตือนใบรับรอง = ปกติ ดู §9) · ตรวจต่อตามคู่มือ VM §4 (etcd, migration, รูปสินค้า)

---

## 9. Client — เบราว์เซอร์และ APK

* **CA ของ Pi เป็นคนละตัวกับ `mob04`:** `certgen` สร้าง CA ใหม่ใน volume `certs-ca` ของ Pi ตอน deploy แรก (`ca.key` ไม่เคยออกจากเครื่อง)
  → APK ที่ฝัง `frontend/assets/certs/pos-ca.crt` (CA ของ `mob04`) **ไม่ trust Pi**
* **ช่วงซ้อม:** ใช้เบราว์เซอร์ — ยอมรับคำเตือน หรือติดตั้ง `ca.crt` ของ Pi ในเครื่องทดสอบ (ดึงทาง SSH ตาม 07 §5 runbook ข้อ 2–3 — **ห้าม commit ทับ** `pos-ca.crt` ของ `mob04`)
* **APK สำหรับ Pi = เรื่องที่ owner ต้องตัดสิน (นอกขอบเขตคู่มือนี้):** `android-apk.yml` ฮาร์ดโค้ด `API_BASE_URL: https://172.30.58.20`
  → ต้องแก้ workflow + เลือกว่าจะคัดลอก `certs-ca` จาก `mob04` (ใช้ CA เดิม) หรือ commit CA ใหม่แล้ว build APK ใหม่ทุกเครื่อง
* 🔴 **ห้าม `docker compose down -v` / ลบ volume `certs-ca`** บน Pi เช่นกัน — CA ใหม่ = client ที่ trust CA เดิมต่อไม่ได้

---

## 10. Monitoring + RAM

Grafana / Prometheus / Bull-Board / platform-ui ผูก `127.0.0.1` ของ Pi เท่านั้น — เข้าผ่าน SSH tunnel (ไม่ใช่ grant ของ tailnet):

```bash
ssh -N -L 13000:127.0.0.1:3000 -L 19090:127.0.0.1:9090 -L 13100:127.0.0.1:3100 -L 13200:127.0.0.1:3200 pi5-deploy
```

แล้วเปิด `http://localhost:13000` (Grafana), `:19090`, `:13100`, `:13200`

RAM (งบ 8 GB, `mem_limit` รวม ≈ 4.2 GB — เพดาน ไม่ใช่การจอง):

```bash
ssh pi5-deploy 'free -h; docker stats --no-stream --format "{{.Name}} {{.MemUsage}}"'
```

swap ของ Ubuntu Server บน Pi ตั้งไว้หรือไม่ = ยังไม่ยืนยัน (แผนย้าย §4.8) — ดูจาก `free -h`

---

## 11. Backup — 🔴 ยังไม่ปลอดภัย

* `provision.yml` ตั้ง cron 03:00 ของ `deploy` → `backup-db.sh` เขียน dump + `pos_images_*.tar.gz` + `pos_sale_photos_*.tar.gz` ลง `/opt/pos/backups` (boot disk)
* **ไม่มีสำเนาออกนอกเครื่อง** — offsite (#363) ยัง parked · Pi เครื่องเดียวในร้าน = ไฟไหม้/ขโมย/SD พัง → ข้อมูลหาย ·
  ห้ามเขียนว่า "backup พร้อมแล้ว" ที่ไหน · log สีเขียวไม่ได้แปลว่าออกจากเครื่อง (อ่านบรรทัด `::warning::`)
* `restore-db.sh` ยังไม่ restore รูป · ครั้งแรกบน Pi ให้รัน `backup-db.sh` ด้วยมือหนึ่งครั้งหลัง deploy และอ่าน output (แผนย้าย §4.7)
* สำเนาด้วยมือระหว่างรอ #363 = owner ตัดสิน (แผนย้าย §3 "ผลต่อ offsite backup")

---

## 12. Troubleshooting

| อาการ / ข้อความ | แปลว่า | ทำ |
|---|---|---|
| `REFUSED: kernel page size is 16384, not 4096 ...` | ลง Raspberry Pi OS | ลง Ubuntu Server ใหม่ (§2) |
| `REFUSED: OS '...' is not supported` / `architecture '...' is not supported` | OS อื่น / 32-bit | Ubuntu Server 64-bit |
| `REFUSED: --profile pi5 on a host that is not a Raspberry Pi 5` | `/proc/device-tree/model` ไม่ใช่ Pi 5 | ตรวจบอร์ด / ใช้ `--profile vm` |
| `REFUSED: /dev/... is on the boot disk ...` | เลือกดิสก์ที่มี `/` | ใช้ `--data-disk boot` หรือเลือกดิสก์อื่น |
| `REFUSED: ... is in use (mounted elsewhere, swap, LVM or RAID)` | ดิสก์ถูกใช้อยู่ | unmount เอง หรือเลือกตัวอื่น |
| `REFUSED: ... has filesystem '...', not ext4. This script never formats a disk.` | ยังไม่ใช่ ext4 | §3 (ตรวจ model/serial ก่อน!) |
| `REFUSED: /dev/sdX has N partitions (...)` | หลาย partition | `--data-disk <partition>` |
| `REFUSED: /etc/docker/daemon.json exists with different content` | มีคนตั้ง Docker ไว้แล้ว | รวมเนื้อหาด้วยมือ |
| `REFUSED: Docker already has volumes in /var/lib/docker ...` | รันหลัง provision/deploy | ต้องรันก่อน หรือย้ายข้อมูลด้วยมือ (owner) |
| `REFUSED: /etc/fstab already mounts /srv/pos-data differently` / `findmnt --verify rejects ...` | fstab มีบรรทัดอื่น/ผิดรูป (`/etc/fstab` ไม่ถูกแตะ) | แก้ fstab ด้วยมือ |
| `no --data-disk given and no TTY for the menu` (exit 2) | ไม่มี flag และไม่มี TTY | ใส่ `--data-disk` หรือใช้ `ssh -t` |
| Docker ไม่ start หลัง boot, `systemctl status docker` อ้าง `/srv/pos-data` | ดิสก์ข้อมูลไม่ได้เสียบ/ไม่ mount — **ตั้งใจ** (`RequiresMountsFor`) | เสียบดิสก์ → `sudo mount /srv/pos-data` → `sudo systemctl start docker` · 🔴 **ห้ามลบ drop-in เพื่อให้ Docker ขึ้น** — มันจะ start บน SD เปล่าแล้วร้านดูเหมือนข้อมูลหาย |
| `verify-ghcr-tags.sh` exit 2 + `Release '<sha>' was not built for linux/arm64` | SHA เก่ากว่า `5c7f210` (image amd64 อย่างเดียว) | ใช้ SHA ใหม่กว่า — ห้าม deploy SHA นั้นขึ้น Pi |
| เบราว์เซอร์ `IP address mismatch` / SAN ไม่มี `<PI_IP>` | `CERT_SAN_IPS` ไม่ได้ตั้ง | §5 → provision → deploy |
| อื่น ๆ (`UNREACHABLE`, network `ip_range`, etcd) | เหมือน VM | คู่มือ VM §6.4 |

---

## 13. ย้อน `host-setup.sh` (เฉพาะสิ่งที่สคริปต์สร้าง)

🔴 ทำก่อนมีข้อมูลจริงเท่านั้น — หลังย้อน Docker จะกลับไปใช้ `/var/lib/docker` (ว่าง) = stack เห็นเหมือนติดตั้งใหม่ ข้อมูลเดิมยังอยู่บนดิสก์ข้อมูลแต่ไม่มีใครเห็น

```bash
sudo systemctl stop docker docker.socket
```

```bash
diff /etc/fstab.pos-bak /etc/fstab
```

✅ ต่างกันแค่บรรทัด `UUID=... /srv/pos-data ...` → `sudo cp -p /etc/fstab.pos-bak /etc/fstab` · ต่างมากกว่านั้น = มีคนแก้ fstab ทีหลัง → ลบบรรทัดนั้นด้วยมือแทน

```bash
sudo umount /srv/pos-data
sudo rm /etc/docker/daemon.json /etc/systemd/system/docker.service.d/10-pos-data.conf
sudo systemctl daemon-reload
sudo systemctl start docker
```

Tailscale: `sudo tailscale down` → `sudo apt-get remove tailscale` → ลบ `/etc/sysctl.d/99-tailscale.conf` (เฉพาะถ้าสคริปต์สร้างไฟล์นี้ —
ถ้ามีอยู่ก่อน มันแค่เติมบรรทัด `net.ipv4.ip_forward = 1`) → ลบเครื่องออกจาก admin console (แผน Tailscale §7)

---

## 14. กฎห้ามทำ (สรุป)

* ห้าม `docker compose down -v` · ห้ามลบ `certs-ca` · ห้าม `--diff` กับ `provision.yml`
* `provision.yml` = `cloud` เท่านั้น · `deploy.yml` = `deploy` เท่านั้น
* ห้ามให้ runner บน Pi ใช้ชื่อ `mob04-demo` / label `srisurart-demo-deploy`
* ห้ามลบ drop-in `RequiresMountsFor` · ห้ามเปิด SNAT ของ Tailscale กลับ
* ห้ามใช้ `HEALTHCHECKS_PING_URL` ของ `mob04` · ห้ามเรียก Pi ว่า production / ห้ามบอกว่า backup ปลอดภัย จนกว่า owner ตัดสิน
* แก้ `.env` ด้วยมือ: ตรวจด้วย `grep -c '^KEY='` เสมอ และเติมบรรทัดว่างก่อน append (คู่มือ VM §2.5)
