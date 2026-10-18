# คู่มือตั้ง full stack บน Raspberry Pi 5 (8 GB) — ฉบับมือใหม่

**ตรวจกับโค้ดที่:** `origin/main` @ `5c7f210` (release PR #714 — tree เดียวกับ `origin/develop` @ `b582fe8`) · 2026-10-13 · ทบทวนโดย reviewer 3 มุม (ความตรงกับ repo, แหล่งทางการ, ความปลอดภัย/ลำดับ) 2026-10-13
🔴 **2026-10-14 — ส่วน Gatus / Discord alert (`GATUS_POS_URL`, `GATUS_CA_DIR`, `ALERT_DISCORD_WEBHOOK`, ข้อ 5b/7b, port `13300`) ใช้ได้เมื่อ checkout `main` ตั้งแต่ `21ad935`:** ชุด devops release แล้ววันที่ 2026-10-17 (PR #727) — `TAG` ที่เก่ากว่านั้นยังไม่มี Gatus และ `provision.yml` ของมันยังลง cron heartbeat · สถานะ: `docs/handoff_log/session-2026-10-14-devops-develop.md`
**เอกสารเจ้าของเรื่อง:** `docs/Backend_design/07_CICD_DEPLOY.md` §3 (multi-arch), §5 (TLS / `CERT_SAN_IPS`), §6 (`host-setup.sh`), §6.2 (runner) ·
แผนย้าย: `docs/research/pi5-migration-plan.md` · ถ้าคู่มือนี้ขัดกับไฟล์ใน `deploy/` → **ไฟล์ถูก**
**คู่มือพี่น้อง:** `docs/tutorial/VM-dploy-full-stack-tutorial.md` (VM `mob04`) — คำสั่งของ Pi เขียนไว้ครบในคู่มือนี้แล้ว ·
🔴 **ห้ามคัดลอกคำสั่งจากคู่มือ VM มารันกับ Pi ตามตัวอักษร** — ทุกบรรทัดในคู่มือนั้นชี้ `mob04` (production) · ที่ใดคู่มือนี้ชี้ไปคู่มือ VM จะบอกด่านกันพลาดก่อนเสมอ

---

## 0. อ่านก่อน — อะไรพิสูจน์แล้ว อะไรยัง

| สถานะ | เรื่อง |
|---|---|
| ✅ พิสูจน์แล้ว | image `srisurart-pos-server` + `srisurart-pos-web` ที่ tag `<sha>`/`main` เป็น manifest list **amd64 + arm64** ตั้งแต่ release `5c7f210` (PR #714, 2026-10-13) — `verify-ghcr-tags.sh 5c7f210e… linux/arm64` ผ่านทั้งสอง image |
| ✅ | ขา arm64 ของ image server ผ่าน sharp check ใต้ `qemu-aarch64 -cpu cortex-a76` (CPU ของ Pi 5) ใน CI ก่อน push (07 §3) |
| ✅ | image ภายนอกที่ pin digest ไว้ (postgres, redis ×2, etcd, nginx, alpine/openssl, curl, prometheus, grafana, node-exporter) ทุกตัวเป็น index ที่มี `linux/arm64` (ตรวจด้วย `docker buildx imagetools inspect` 2026-10-13) |
| ✅ | `host-setup.sh` ผ่าน test แบบ stub (`deploy/scripts/test/host-setup.test.sh` — ไม่แตะดิสก์จริง) + `--dry-run` อ่านอย่างเดียวบน `mob04` (Ubuntu 26.04, amd64) |
| ✅ ตรวจจากแหล่งทางการ (ยังไม่ใช่บน Pi จริง) 2026-10-13 | kernel `linux-raspi` ของ Ubuntu (26.04: `7.0.0-1020`, 24.04: `6.8.0-1065`) = `CONFIG_ARM64_4K_PAGES=y` · `download.docker.com` มี `resolute` arm64 (`docker-ce` 29.9.0) · `pkgs.tailscale.com` มี `ubuntu/resolute` arm64 · image raspi ของ Ubuntu 26.04.1 และ 24.04.5 มี `rpi-eeprom` (28.14) มาให้ |
| ❌ ยังไม่เคยทำ | **ยังไม่เคยมี Pi จริงสักเครื่อง** — `lsblk`/`findmnt` กับดิสก์จริง, `RequiresMountsFor` ตอนถอดดิสก์ (ออกแบบถูกตามเอกสาร systemd — ตอน boot จะรอดิสก์ได้ถึง 90 วิ ตาม device timeout), stack ทั้งชุด boot บน Pi — **ยังไม่มีข้อไหนถูกพิสูจน์บนเครื่องจริง** |
| ❌ ยังไม่ต่อ | **CD ไป Pi ยังไม่มี:** job `deploy` ใน `.github/workflows/deploy.yml` รันบน `[self-hosted, srisurart-demo-deploy]` (= `mob04`) และ `verify-ghcr-tags.sh` ใน workflow ยังไม่ส่ง platform → §8 ของคู่มือนี้จึงเป็น **ทางมือ / ซ้อม** เท่านั้น · 🔴 **กด approve `Deploy (demo)` = deploy ไป `mob04` เสมอ ไม่ใช่ Pi** |

🔴 **`mob04` ยังเป็น production จนกว่า owner ตัดสิน** (แผนย้าย §5 cutover ยังไม่เริ่ม) · คู่มือนี้ = ตั้ง Pi ขึ้นมา **ซ้อม** ด้วยข้อมูลทดสอบ
ห้ามใช้ tenant จริง ห้ามชี้ APK ที่ร้านใช้มาที่ Pi

ลำดับทั้งหมด (ห้ามสลับ):

```text
§2 ลง OS ─▶ §3 เตรียมดิสก์ ─▶ §3.5 เลือก SHA + worktree ─▶ §4 host-setup.sh ─▶ §5 .env ─▶ §6 provision.yml (cloud) ─▶ [§7 runner] ─▶ §8 deploy.yml (deploy)
```

`host-setup.sh` **ต้องมาก่อน** `provision.yml` — มันปฏิเสธถ้า Docker มี volume แล้ว (§12)

---

## 1. ฮาร์ดแวร์ (ราคา + เหตุผล: แผนย้าย §2)

| # | ของ | หมายเหตุ |
|---|---|---|
| 1 | Raspberry Pi 5 **8 GB** | `host-setup.sh` เตือนถ้า RAM < 7168 MiB (`mem_limit` รวมของ stack ≈ 4.3 GB) |
| 2 | ที่จ่ายไฟทางการ **27 W USB-C (5V/5A)** | ตัวนี้ตัวเดียวที่ทำให้ Pi จ่ายไฟ USB ได้ 1.6 A · ที่จ่ายไฟอื่น = USB รวมแค่ 600 mA → ดิสก์ USB หลุดกลางทาง · ห้ามใช้ที่ชาร์จโทรศัพท์ · **ห้ามบังคับ `usb_max_current_enable` ใน `config.txt`** แทนการใช้ที่จ่ายไฟทางการ (ตรวจใน §2 ข้อ 6) |
| 3 | Active Cooler + เคสระบายอากาศ | |
| 4 | **ดิสก์ข้อมูล** (เลือกหนึ่ง) | USB SSD · USB HDD (**ต้องมีกล่องที่มีไฟเลี้ยงเอง** หรือ hub มีไฟ — สคริปต์เตือนเมื่อเจอ HDD) · NVMe ผ่าน M.2 HAT+ · หรือ microSD ตัวเดียว (**ไม่แนะนำ** — Postgres เขียนตลอด SD สึกและพังโดยไม่เตือน) · กล่อง USB-SATA บางรุ่นพังในโหมด UAS — ดู `dmesg` ก่อนไว้ใจ (§3) |
| 5 | microSD **≥ 64 GB** (ใส่ OS) | 32 GB พอสำหรับ OS แต่ backup ทุกคืนอยู่บน SD นี้ (§11) — ถ้าเลือก `--data-disk boot` ข้อมูลทั้งหมดก็อยู่บนนี้ด้วย |
| 6 | แบตเตอรี่ RTC | ไฟดับ + เน็ตไม่กลับ = นาฬิกาเพี้ยน → เลขเอกสาร/ใบรับรองผิด |
| 7 | UPS | ร้านไฟตกบ่อย (แผนย้าย §2 ข้อ 7) · USB SSD ส่วนใหญ่ไม่มี power-loss protection → ไฟดับขณะ Postgres เขียน = เสี่ยงฐานข้อมูลพัง · ปิดเครื่องอัตโนมัติผ่าน NUT = **ยังไม่เคยทดสอบ, owner ตัดสิน** |
| 8 | สาย LAN | ใช้ Ethernet ไม่ใช้ Wi-Fi |

---

## 2. ลง OS

**OS = Ubuntu Server 26.04 LTS 64-bit** (สำรอง: 24.04 LTS) — สองรุ่นนี้เท่านั้นที่ `host-setup.sh` รับโดยไม่เตือน

🔴 **ห้ามใช้ Raspberry Pi OS:** kernel ของมันบน Pi 5 (`kernel_2712`) ใช้ page 16K (เอกสาร `config.txt` ของ raspberrypi.com) — stack นี้ทดสอบบน
kernel 4K เท่านั้น และ `provision.yml` ใช้ Docker repo ของ Ubuntu ทดสอบกับ Ubuntu เท่านั้น · `host-setup.sh` ปฏิเสธ `kernel page size is 16384, not 4096`
(เหตุผลคือ "ทดสอบบน kernel 4K เท่านั้น" — ไม่ใช่ Redis/jemalloc: `redis:7-alpine` ทางการ build jemalloc รองรับ page 16K บน non-x86 แล้ว) ·
Ubuntu `linux-raspi` = 4K ✅

**0. อัปเดต EEPROM ก่อนลง OS** — 🔴 Ubuntu 26.04 ต้อง bootloader EEPROM **≥ 2025-02-11** · บอร์ดที่ EEPROM ยังเป็นรุ่น **≤ 2024-09-23 จะ boot 26.04 ไม่ได้เลย**
(ubuntu.com/hardware/docs/boards/how-to/ubuntu_supported/raspberry-pi/, LP #2146383) · 24.04 ไม่มีขั้นต่ำ แต่ทำข้อนี้ไว้ก่อนเสมอ:

1. Raspberry Pi Imager → Device: **Raspberry Pi 5** → OS: *Misc utility images → Bootloader (Pi 5 family) → SD Card Boot* → เขียนลง microSD
2. ใส่ SD → เสียบไฟ → รอ (ไฟเขียวกระพริบเร็วต่อเนื่อง / จอเขียว = เสร็จ) → ถอดไฟ
3. แล้วค่อยเขียน Ubuntu ลง SD ใบเดิม (ข้อ 1–2 ข้างล่าง)

**1. Imager** → Device: Raspberry Pi 5 → OS: *Other general-purpose OS → Ubuntu → **Ubuntu Server 26.04.1 (64-bit)***
(สำรอง: *Ubuntu Server 24.04.5 LTS (64-bit)*) → microSD

**2. key ของ `cloud` — สร้างบน notebook ก่อนเปิด OS customisation:**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/pi5-cloud -C "cloud@pi5 <ชื่อคุณ>"
```

แล้วตั้งค่าใน Imager (OS customisation):

* **username = `cloud` + รหัสผ่าน** — Imager v2.0.12 บังคับรหัสผ่านเมื่อตั้ง username และไม่มีตัวเลือก sudo แบบไม่ใช้รหัสสำหรับ Ubuntu
  (มันเขียน `sudo: null`) → **`sudo` ถามรหัสเป็นเรื่องปกติ** · ชื่อ `cloud` = ชื่อเดียวกับ `mob04` (ชื่ออื่นใช้ได้ แต่ต้องแทนทุกที่)
* เปิด SSH แบบ **public key เท่านั้น** → วางเนื้อหา `~/.ssh/pi5-cloud.pub` (login ด้วยรหัสผ่านทาง SSH ยังปิด — `ssh_pwauth: false`)
* hostname เช่น `pi5-pos` · timezone `Asia/Bangkok`

**3. เสียบ LAN → boot → ตั้ง IP คงที่** (แนะนำ: DHCP reservation ที่ router ผูก MAC ของ Pi) · 🔴 IP นี้ถูกฝังใน SAN ของใบรับรอง (§5) —
IP เปลี่ยน = ต้องแก้ `CERT_SAN_IPS` + `CORS_ORIGINS` แล้ว provision + deploy ใหม่

**4. หน้าต่าง terminal ของ Pi** — 🔴 เปิด **หน้าต่างใหม่แยก** ไว้ทำ Pi อย่างเดียว (ตัวแปร `DEPLOY_KEY`/`SECRETS_FILE` ของ `mob04` ต้องไม่อยู่ในหน้าต่างนี้)
แล้วประกาศ (แทน `<PI_IP>` ด้วย IP จริงของ Pi):

```bash
export PI_IP=<PI_IP>
```

```bash
export DEPLOY_KEY=~/.ssh/pi5-deploy_ed25519
```

ด่านกันพลาด — ทุกคำสั่ง Ansible ของ Pi ในคู่มือนี้ขึ้นต้นด้วย `pi_guard &&` (ประกาศครั้งเดียวต่อหน้าต่าง):

```bash
pi_guard() { [ -n "${PI_IP:-}" ] && [ "$PI_IP" != 172.30.58.20 ] && [[ "${DEPLOY_KEY:-}" == *pi5* ]] && echo "pi_guard ok: $PI_IP" || { echo "STOP: PI_IP ว่าง / เป็น IP ของ mob04 / DEPLOY_KEY ไม่ใช่ key ของ Pi"; return 1; }; }
```

```bash
pi_guard
```

✅ `pi_guard ok: <PI_IP>`

**key ของ user `deploy` บน Pi = key ใหม่แยกจาก `mob04`** — key เดียวกัน = พิมพ์ IP พลาดครั้งเดียวก็ deploy ทับ production โดยข้ามด่าน approve:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/pi5-deploy_ed25519 -C "deploy@pi5 <ชื่อคุณ>"
```

(Windows: ตั้ง ACL ด้วย `icacls` ให้ทั้ง `pi5-cloud` และ `pi5-deploy_ed25519` แบบคู่มือ VM §1.3)

**5. `~/.ssh/config` บน notebook — ทำก่อน ssh ครั้งแรก:**

```text
Host pi5
  HostName <PI_IP>
  User cloud
  IdentityFile ~/.ssh/pi5-cloud
  IdentitiesOnly yes

Host pi5-deploy
  HostName <PI_IP>
  User deploy
  IdentityFile ~/.ssh/pi5-deploy_ed25519
  IdentitiesOnly yes
```

(`pi5-deploy` ใช้ได้หลัง §6 — `provision.yml` สร้าง user `deploy` + ใส่ key ให้) · `ansible.cfg` **ตรวจ host key**
(2026-10-13) → ต้องตรึง host key ของ Pi ก่อนรัน Ansible (ข้อ 6)

**6. ตรึง host key + ssh ครั้งแรก + ตรวจ:**

บน **จอที่ต่อกับ Pi เอง** (console — ไม่ใช่ผ่าน SSH) อ่าน fingerprint: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` · แล้วบน notebook:

```bash
ssh-keyscan -t ed25519 "$PI_IP" > /tmp/pi5.keyscan && ssh-keygen -lf /tmp/pi5.keyscan
```

✅ `SHA256:…` ตรงกับค่าบน console ทุกตัวอักษร → `cat /tmp/pi5.keyscan >> ~/.ssh/known_hosts` · ❌ ไม่ตรง → **หยุด** ห้ามเพิ่ม
(คู่มือ VM §1.4, 07 §7 แถว "SSH host key") · ssh ข้างล่างไม่ควรถามเรื่อง fingerprint อีก

```bash
ssh pi5 'grep -E "^(ID|VERSION_ID)=" /etc/os-release; dpkg --print-architecture; getconf PAGESIZE; sudo -n true 2>/dev/null && echo "sudo nopasswd" || echo "sudo asks password"'
```

✅ `ID=ubuntu`, `VERSION_ID="26.04"` (หรือ `24.04`), `arm64`, `4096` · `sudo asks password` = **ปกติ** (Imager ตั้งให้ — ข้อ 2)

`sudo` ถามรหัส แล้ว `provision.yml` (`become: true`) จะทำอย่างไร:

* **Mac/Linux:** เพิ่ม `-K` (`--ask-become-pass`) ตอนรัน §6 แล้วพิมพ์รหัสของ `cloud`
* **Windows (ฟังก์ชัน `ans`):** `-K` **ใช้ไม่ได้** (`docker run` ไม่มี `-it` = ไม่มี tty ให้พิมพ์รหัส) → ต้องตั้ง NOPASSWD ให้ `cloud` (owner ตัดสิน — ทำให้ key ของ `cloud` = root):

```bash
ssh -t pi5 'echo "cloud ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/010-cloud-nopasswd && sudo chmod 0440 /etc/sudoers.d/010-cloud-nopasswd && sudo visudo -cf /etc/sudoers.d/010-cloud-nopasswd'
```

✅ บรรทัดสุดท้าย `/etc/sudoers.d/010-cloud-nopasswd: parsed OK`

ไฟเลี้ยง USB (ข้อ 2 ของ §1):

```bash
ssh pi5 'vcgencmd get_config usb_max_current_enable'
```

✅ `usb_max_current_enable=1` (ที่จ่ายไฟทางการ 27 W) · ❌ `=0` → เปลี่ยนที่จ่ายไฟ ห้ามบังคับใน `config.txt` · ไม่มีคำสั่ง `vcgencmd` = ชื่อแพ็กเกจบน Ubuntu ยังไม่ยืนยัน → ใช้ที่จ่ายไฟทางการแล้วข้ามได้

**7. อัปเดตทั้งเครื่องครั้งแรก** (cloud-init / unattended-upgrades มักถือ lock ของ apt อยู่ช่วงแรก — `provision.yml` จะล้มถ้าชนกัน):

```bash
ssh -t pi5 'sudo apt-get update && sudo apt-get full-upgrade -y && sudo reboot'
```

หลัง reboot — Pi ต้อง **ไม่ reboot เองในเวลาร้านเปิด**:

```bash
ssh pi5 'grep -n "Automatic-Reboot " /etc/apt/apt.conf.d/50unattended-upgrades'
```

✅ บรรทัดที่ไม่ขึ้นต้นด้วย `//` เป็น `"false"` หรือมีแค่บรรทัดที่ comment ไว้ (ค่าเริ่มต้น = ไม่ reboot เอง) · ❌ `"true"` → owner ตัดสิน

**8. นาฬิกา** — ต้องผ่านก่อน §8 (เลขเอกสาร/ใบรับรองใช้เวลาเครื่อง):

```bash
ssh pi5 'timedatectl'
```

✅ `System clock synchronized: yes` และ `Time zone: Asia/Bangkok (+07, +0700)`

**9. ตรวจ EEPROM อีกรอบ** (image raspi ของ Ubuntu มี `rpi-eeprom` มาให้):

```bash
ssh pi5 'sudo rpi-eeprom-update'
```

✅ `BOOTLOADER: up to date` · มีรุ่นใหม่กว่า → `ssh -t pi5 'sudo rpi-eeprom-update -a && sudo reboot'`

---

## 3. เตรียมดิสก์ข้อมูล (ข้ามได้ถ้าเลือก `boot`)

`host-setup.sh` **ไม่ format / partition / wipe อะไรเลย** · ดิสก์ต้องมี **ext4 อยู่แล้ว** · ดิสก์ที่ยังไม่ใช่ ext4 → สคริปต์ปฏิเสธ
แล้ว **พิมพ์** คำสั่งให้คุณรันเอง (§4 ข้อ 2) — คุณรันเองหลังตรวจแล้วเท่านั้น

🔴🔴 **ระบุดิสก์ด้วยการถอด-เสียบ ไม่ใช่ด้วยชื่อ** — กล่อง USB รายงาน model/serial ของชิป bridge (ไม่ใช่ของดิสก์) และชื่อ `sdX` เปลี่ยนได้ทุกครั้งที่เสียบ:

1. **ถอด** ดิสก์ข้อมูล แล้ว:

```bash
ssh pi5 'lsblk -dno NAME,MODEL,SERIAL,SIZE'
```

2. **เสียบ** ดิสก์ข้อมูล รอ 5 วิ แล้วรันคำสั่งเดิมซ้ำ → **บรรทัดที่เพิ่มขึ้นมา = ดิสก์ข้อมูล** · ดิสก์ที่มี `/` (ปกติ `mmcblk0` = microSD;
ถ้าไม่มี `mmcblk0` แปลว่า boot จาก USB/NVMe — ดิสก์ที่ถือ `/` คือ OS) **ห้ามแตะ**
3. ชื่อถาวรของมัน (ใช้ชื่อนี้ในคำสั่งทุกตัวข้างล่าง ไม่ใช่ `sdX`):

```bash
ssh pi5 'ls -l /dev/disk/by-id/ | grep -v part'
```

✅ บรรทัดที่ชี้ไป (`-> ../../sdX`) ตัวที่เพิ่งโผล่ในข้อ 2 · ต่อจากนี้เรียกมันว่า `/dev/disk/by-id/<ID>`

4. ดูว่าบนดิสก์มีอะไร (**อ่านอย่างเดียว** — `-n` = ไม่เขียน):

```bash
ssh pi5 'sudo wipefs -n /dev/disk/by-id/<ID>'
```

5. กล่อง USB ทำงานปกติไหม (โหมด UAS ของบาง bridge reset วนซ้ำ):

```bash
ssh pi5 'sudo dmesg | grep -iE "uas|usb-storage|reset|I/O error" | tail -20'
```

✅ ไม่มี `reset` / `I/O error` ซ้ำ ๆ · ❌ มี → เปลี่ยนกล่องก่อนไว้ใจข้อมูล

รูปแบบที่สคริปต์พิมพ์ (ตรงกับโค้ดใน `setup_storage`) — **รันทันทีหลังข้อ 1–4 ห้าม reboot หรือถอด-เสียบระหว่างนั้น** · คำสั่งข้างล่าง **ลบทุกอย่างบนดิสก์นั้น** กู้ไม่ได้:

* **ดิสก์ทั้งลูกไม่มี partition:**
  ```bash
  printf 'label: gpt\n,,L\n' | sudo sfdisk --wipe always /dev/disk/by-id/<ID>
  ls -l /dev/disk/by-id/ | grep '<ID>-part'    # partition ใหม่ = <ID>-part1
  sudo mkfs.ext4 -L pos-data /dev/disk/by-id/<ID>-part1
  ```
* **partition ที่มีอยู่แล้ว:** `sudo mkfs.ext4 -L pos-data /dev/disk/by-id/<ID>-part1`

(รันใน `ssh -t pi5` · สคริปต์เองพิมพ์ชื่อ `/dev/sdX` — ใช้ชื่อ by-id ที่ชี้ไปตัวเดียวกันแทน) · ดิสก์ที่มีหลาย partition → สคริปต์ปฏิเสธ ให้ระบุ partition เองใน `--data-disk`

---

## 3.5 เลือก SHA + worktree (ครั้งเดียว ก่อน §4)

`host-setup.sh` (§4), `provision.yml` (§6 — copy สคริปต์ ops จาก `{{ playbook_dir }}/../scripts`) และ `deploy.yml` (§8) ใช้ไฟล์จาก **tree ที่รัน**
→ ต้องเป็น worktree สะอาดที่ SHA เดียวกันตลอด · คำสั่ง `git`/`gh` รันที่ root ของ repo หลัก

```bash
export MAIN="$(git rev-parse --show-toplevel)"
```

```bash
git fetch origin
```

```bash
export TAG="$(git rev-parse origin/main)"
```

```bash
[[ "$TAG" =~ ^[0-9a-f]{40}$ ]] && echo "TAG ok" || echo "STOP: TAG ผิดรูปแบบ"
```

CI ของ SHA นี้ต้องเขียว (อาจมีแถว `Deploy (demo)` 1–2 แถวด้วย — ไม่ต้องสนใจ ดูแค่สองแถวนี้):

```bash
gh run list --commit "$TAG" --json workflowName,status,conclusion -q '.[] | [.workflowName,.status,.conclusion] | @tsv'
```

✅ `Server CI	completed	success` และ `Flutter CI	completed	success`

**SHA ต้องมี arm64** — ใช้ได้เฉพาะ `5c7f210` หรือใหม่กว่าบน `main` (release ก่อนหน้าเป็น amd64 อย่างเดียว):

```bash
bash deploy/scripts/verify-ghcr-tags.sh "$TAG" linux/arm64
```

✅ บรรทัดสุดท้าย `Both server and web images for tag '<sha>' are verified on GHCR for linux/arm64.` (exit 0)
❌ exit 2 + `Release '<sha>' was not built for linux/arm64 ...` → SHA เก่ากว่า `5c7f210` เลือกใหม่ · exit 2 + `Could not verify the release images ...` = ถาม GHCR ไม่ได้ ·
exit 1 (`... are not both on GHCR yet ...`) = image ยังไม่ครบ รอ CI

worktree สะอาด (ชื่อ `pos-pi5` — แยกจาก `pos-deploy` ของคู่มือ VM):

```bash
test -z "$(git status --porcelain)" && echo "clean" || echo "STOP: working tree ไม่สะอาด"
```

```bash
git -c core.autocrlf=false worktree add ../pos-pi5 "$TAG"
```

(`core.autocrlf=false` จำเป็นบน Windows — ไม่งั้นสคริปต์ `.sh` ที่ส่งขึ้น Pi ติด CRLF)

```bash
export WT="$(cd "$MAIN/../pos-pi5" && pwd)"
```

```bash
[ "$(git -C "$WT" rev-parse HEAD)" = "$TAG" ] && echo "worktree ok" || echo "STOP: worktree ไม่ใช่ TAG"
```

Windows (ฟังก์ชัน `ans` ของคู่มือ VM §1.1 อ่าน `REPO`):

```bash
export REPO="$(cd "$WT" && pwd -W)"
```

---

## 4. รัน `host-setup.sh` (ในนาม `cloud`, ครั้งเดียว)

**1. ส่งสคริปต์ขึ้น Pi จาก worktree §3.5:**

```bash
scp "$WT/deploy/scripts/host-setup.sh" pi5:/tmp/host-setup.sh
```

```bash
ssh pi5 'grep -c $'"'"'\r'"'"' /tmp/host-setup.sh'
```

✅ `0` · ❌ มากกว่า 0 = ไฟล์ติด CRLF ส่งใหม่ · `/tmp` ถูกล้างทุกครั้งที่ reboot → reboot แล้วต้อง `scp` ใหม่

🔴 **รันสคริปต์ด้วย `sudo bash /tmp/host-setup.sh ...` เสมอ** — รวมถึงตอนที่สคริปต์พิมพ์ `then re-run: sudo /tmp/host-setup.sh ...`
(บรรทัดนั้นใช้ `$0` และไฟล์ที่ `scp` มาอาจไม่มีสิทธิ์ execute) — เติม `bash` เอง

**2. `--dry-run` ก่อนเสมอ** (พิมพ์ทุก action ไม่เขียนอะไร):

```bash
ssh -t pi5 'sudo bash /tmp/host-setup.sh --profile pi5 --data-disk /dev/disk/by-id/<ID> --dry-run'
```

ส่วนหัวที่ต้องเห็น (`key=value` — มีบรรทัดอื่นแทรก เช่น `os_version`, `mem_mib`, `boot_source`):

```text
os_id=ubuntu
arch=arm64
page_size=4096
model=Raspberry Pi 5 Model B ...
boot_disk=/dev/mmcblk0
profile=pi5
```

ตามด้วย `data_disk=/dev/disk/by-id/<ID>` (พิมพ์ทีหลังโดย `setup_storage`), บรรทัด `using /dev/sdX1 (UUID=...) on ...` แล้ว `DRY-RUN: ...`
(`mkdir`, `append to /etc/fstab`, `systemctl daemon-reload`, `mount /srv/pos-data`, `write /etc/docker/daemon.json`, `write` drop-in)
✅ `boot_disk=` **ต้องไม่ใช่** ดิสก์ที่ใส่ใน `--data-disk` · ❌ `REFUSED: ...` → §12

**3. เลือกที่เก็บข้อมูล** — `--data-disk` มีสามแบบ:

| คำสั่ง | ผล |
|---|---|
| `--data-disk boot` | ไม่เปลี่ยนอะไร (ข้อมูลอยู่บน microSD) · ถ้า boot disk เป็น `mmcblk*` สคริปต์เตือนเรื่อง SD สึก |
| `--data-disk /dev/disk/by-id/<ID>` (ดิสก์) หรือ `...-part1` (partition) | mount ดิสก์ ext4 นั้นที่ `/srv/pos-data` (สคริปต์แปลง by-id เป็น `/dev/sdX` เอง) |
| ไม่ใส่ flag (ใน `ssh -t` ที่มี TTY) | เมนูตัวเลข: `0) boot` + ดิสก์ที่เลือกได้พร้อม model/serial/size · ไม่มี TTY = exit 2 |

**4. รันจริง** — คำสั่งเดียวกับข้อ 2 ไม่มี `--dry-run`:

```bash
ssh -t pi5 'sudo bash /tmp/host-setup.sh --profile pi5 --data-disk /dev/disk/by-id/<ID>'
```

สิ่งที่สคริปต์เขียน (เฉพาะเมื่อเลือกดิสก์ ไม่ใช่ `boot`):

| ไฟล์ | เนื้อหา |
|---|---|
| `/etc/fstab` | เพิ่มบรรทัดเดียว `UUID=<uuid> /srv/pos-data ext4 defaults,noatime,nofail 0 2` (ผ่าน `findmnt --verify` บนสำเนาก่อนแทนที่) · สำรองเดิมไว้ที่ `/etc/fstab.pos-bak` (ครั้งแรกครั้งเดียว) |
| `/srv/pos-data` (mount point), `/srv/pos-data/docker` | ไดเรกทอรี + mount |
| `/etc/docker/daemon.json` | `{"data-root": "/srv/pos-data/docker", "log-driver": "local", "features": {"containerd-snapshotter": false}}` — volume, image และ layer ของ Docker อยู่บนดิสก์ข้อมูลทั้งหมด · log ของ container หมุน + บีบอัด (ค่าเริ่มต้นของ `local` ≈ 100 MB ต่อ container) |
| `/etc/systemd/system/docker.service.d/10-pos-data.conf` | `RequiresMountsFor=/srv/pos-data` — ดิสก์หาย Docker **ไม่ start** (แทนที่จะ start บนโฟลเดอร์เปล่าใน SD แล้วดูเหมือนร้านไม่มีข้อมูล) |

* **Docker ยังไม่ได้ติดตั้งตอนนี้ — ปกติ:** สคริปต์เขียน `daemon.json` + drop-in ไว้ก่อน แล้ว restart Docker **เฉพาะเมื่อมันรันอยู่และไฟล์ทั้งสองเปลี่ยนจริง** (รันซ้ำด้วยค่าเดิม = `unchanged: ...` ไม่ restart) ·
  `provision.yml` (§6) ติดตั้ง `docker-ce` ทีหลัง และไม่แตะ `daemon.json` → Docker start ครั้งแรกบน `/srv/pos-data/docker` เลย
  (อ่านจากโค้ดทั้งสองไฟล์ — ยังไม่เคยเห็นบน Pi จริง จึงต้องตรวจข้อ 5)
* **backup อยู่ `/opt/pos/backups` บน boot disk (microSD)** — เลือกดิสก์ข้อมูล = backup อยู่คนละอุปกรณ์กับ pgdata ·
  🔴 **เลือก `--data-disk boot` = ข้อมูลและ backup อยู่บน SD ใบเดียวกัน** (SD พัง = หายทั้งคู่) · ทั้งสองแบบ backup **ไม่ออกจากเครื่อง** (§11)

✅ จบด้วย `data disk ready: Docker data-root = /srv/pos-data/docker` แล้ว `Next steps:` · ตรวจทันที:

```bash
ssh pi5 'findmnt /srv/pos-data; cat /etc/docker/daemon.json; cat /etc/systemd/system/docker.service.d/10-pos-data.conf'
```

✅ `findmnt` แสดง `/srv/pos-data` จากดิสก์ที่เลือก, `ext4`

**5. ตรวจอีกรอบหลัง §6** (ตอนนั้น Docker ติดตั้งแล้ว):

```bash
ssh pi5 'sudo docker info --format "{{.DockerRootDir}} {{.Driver}}"; systemctl cat docker | grep RequiresMountsFor'
```

✅ `/srv/pos-data/docker overlay2` และ `RequiresMountsFor=/srv/pos-data`
❌ `/var/lib/docker` หรือ driver ไม่ใช่ `overlay2` (เช่น `overlayfs` = containerd image store → image อยู่บน SD) → **หยุด ห้าม deploy**

**6. (ทางเลือก) ซ้อมถอดดิสก์ — ยังไม่เคยมีใครทำ:** ปิดเครื่อง → ถอดดิสก์ข้อมูล → boot (รอได้ถึง ~90 วิ) → `systemctl status docker` ต้อง **ไม่ active**
(ตั้งใจ — §12) → ปิด เสียบกลับ boot → `docker` active · ทำก่อนมีข้อมูลจริง

### 4.1 (ทางเลือก) Tailscale — เข้าถึงจากนอกร้าน

สรุปจาก `docs/research/tailscale-remote-access-plan-2026-10-13.md` (ทำบน `mob04` แล้ว 2026-10-13) — **owner ทำ 👤 ก่อน:**

* tailnet policy: `tagOwners` มี `tag:pos-server` และ grant ให้ผู้ใช้ถึง `<PI_IP>/32` **tcp:443 เท่านั้น** · SSH ผ่าน tailnet = owner คนเดียว
* `autoApprovers` ของ tailnet ครอบแค่ `172.30.58.20/32` (`mob04`) → **route ของ Pi ต้อง approve ด้วยมือ**
* แผนฟรี Personal = **ใช้ที่ไม่ใช่เชิงพาณิชย์เท่านั้น** — ร้านใช้จริงต้องให้ owner ตัดสินใหม่

🔴 **ห้าม `--lan-ip 172.30.58.20`** และห้ามมี `172.30.58.20` ใน `CERT_SAN_IPS` ของ Pi — route `/32` ซ้อนกันบน tailnet อาจส่ง traffic ของ production ไปที่ Pi

**ใช้ `--profile vm` ตอนเพิ่ม Tailscale** (หลัง §4 ข้อ 4 แล้ว) — เขียนแค่ส่วน Tailscale ไม่แตะดิสก์เลย · `--profile vm` บน Pi ใช้ได้
(สคริปต์ปฏิเสธแค่ `pi5` บนเครื่องที่ไม่ใช่ Pi) · ถ้าเผลอรันซ้ำด้วย `--profile pi5 --data-disk <ดิสก์เดิม>` สคริปต์ตั้งแต่ 2026-10-14 ก็ไม่ restart Docker
เมื่อ `daemon.json`/drop-in ไม่เปลี่ยน — แต่สคริปต์รุ่นก่อนหน้า restart เสมอ (= **POS ดับ**) จึงยังใช้ `--profile vm` · `/tmp` ถูกล้างตอน reboot → `scp` สคริปต์ใหม่ก่อน (§4 ข้อ 1)

```bash
pi_guard && ssh -t pi5 "sudo bash /tmp/host-setup.sh --profile vm --tailscale --lan-ip $PI_IP --dry-run"
```

ผ่านแล้วรันจริง (ไม่มี `--dry-run`) · สคริปต์ติดตั้งจาก apt repo ที่ลงลายเซ็นของ Tailscale, เปิด `net.ipv4.ip_forward = 1`
แล้ว `tailscale up --hostname=<hostname>-pos --advertise-routes=<PI_IP>/32 --advertise-tags=tag:pos-server --snat-subnet-routes=false` — **ไม่รับ auth key**:
มันพิมพ์ URL ให้ owner เปิด login เอง · จากนั้น owner ใน admin console → Machines → `<hostname>-pos`: **approve route** `<PI_IP>/32`
(เครื่องที่ติด tag ปิด key expiry ให้อัตโนมัติ — tailscale.com/kb/1068/tags · ตรวจแค่ว่าไม่มีป้าย "Expires" · เครื่องที่ติด tag ไม่ผูกกับตัวตนผู้ใช้อีกต่อไป)

🔴 **`--snat-subnet-routes=false` ห้ามเปิดกลับ** — ถ้า SNAT ทุก request จะมาจาก IP เดียว → rate limit ต่อ IP ของ login รวมทุกเครื่องเป็น bucket เดียว
และ nginx allowlist แบบ RFC1918 จะเห็นทุกคนเป็น LAN · ตรวจ: access log ของ nginx ต้องเห็น `100.x.y.z` ต่างกันต่อโทรศัพท์

---

## 5. `.env` ของ Pi

กฎเดียวกับคู่มือ VM §2.2: hex เท่านั้น, คีย์บังคับครบ 11 ตัว, ไม่มี `ALLOW_DEV_SECRETS`/`IMAGE_TAG`/`dev-only-*`, ห้ามวางค่าในแชต/commit ·
คำสั่งของ Pi เขียนครบข้างล่าง — **ไม่ต้องเปิด §2.2 ของคู่มือ VM** (บรรทัดแรกของมัน `export SECRETS_FILE=~/secrets/mob04-demo.env` จะชี้ไฟล์ของ production)

ในหน้าต่างของ Pi (§2 ข้อ 4):

```bash
export SECRETS_FILE=~/secrets/pi5-demo.env
```

ด่าน — ไฟล์ต้องยังไม่มี (ไม่งั้นคำสั่งสร้างจะไม่ทำงาน):

```bash
mkdir -p ~/secrets && chmod 700 ~/secrets
```

```bash
pi_guard && [[ "$SECRETS_FILE" == */pi5-demo.env ]] && test ! -e "$SECRETS_FILE" && test ! -e ~/secrets/jwt.key && echo ok || echo "STOP: มีไฟล์อยู่แล้ว / ตัวแปรผิด"
```

✅ `ok` (ถ้ามี `pi5-demo.env` อยู่แล้วจากรอบก่อน — ใช้ของเดิม ข้ามไปชุดตรวจข้างล่าง)

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ~/secrets/jwt.key
```

```bash
openssl rsa -in ~/secrets/jwt.key -pubout -out ~/secrets/jwt.pub
```

secret **ทุกตัวสร้างใหม่** (ห้ามคัดลอกของ `mob04` — Pi ซ้อม = stack แยก) · `set -o noclobber` = ถ้ามีไฟล์อยู่แล้ว `>` จะล้มแทนการเขียนทับ:

```bash
( set -o noclobber; umask 077
  {
    echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
    echo "POS_APP_PASSWORD=$(openssl rand -hex 24)"
    echo "REDIS_PASSWORD=$(openssl rand -hex 24)"
    echo "JWT_PLATFORM_SECRET=$(openssl rand -hex 32)"
    echo "ETCD_ROOT_PASSWORD=$(openssl rand -hex 24)"
    echo "BULL_BOARD_USER=admin"
    echo "BULL_BOARD_PASSWORD=$(openssl rand -hex 24)"
    echo "GRAFANA_ADMIN_USER=admin"
    echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 24)"
    echo "K6_REMOTE_WRITE_BASIC_AUTH_USER=k6"
    echo "K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD=$(openssl rand -hex 24)"
    echo "DB_POOL_SIZE=15"
    echo "LOG_LEVEL=info"
    echo "REDIS_COMMAND_TIMEOUT_MS=1000"
    echo "CORS_ORIGINS=https://$PI_IP"
    echo "CERT_SAN_IPS=$PI_IP"
    echo "PLATFORM_ADMINS=admin:$(openssl rand -hex 12)"
    printf 'JWT_PRIVATE_KEY="%s"\n' "$(cat ~/secrets/jwt.key)"
    printf 'JWT_PUBLIC_KEYS="%s"\n' "$(cat ~/secrets/jwt.pub)"
  } > "$SECRETS_FILE" )
```

```bash
rm ~/secrets/jwt.key ~/secrets/jwt.pub
```

ต่างจาก `mob04` แค่นี้:

| คีย์ | ค่าบน Pi | ทำไม |
|---|---|---|
| `CERT_SAN_IPS` | `<PI_IP>` เท่านั้น | `certgen.sh` ใส่ IP ใน SAN ของใบ server · ไม่ตั้ง = `172.30.58.20` (ของ `mob04`) → เบราว์เซอร์/แอปที่เรียก `<PI_IP>` จะ `IP address mismatch` · ค่าที่ไม่ใช่ IPv4 = certgen exit 1 · 🔴 **ห้ามใส่ `172.30.58.20`** (§4.1) |
| `CORS_ORIGINS` | `https://<PI_IP>` | origin ของ Pi เอง · ตั้งแต่ #367 ค่าที่ตั้งแต่ว่างทำให้ api ไม่ boot |
| `GATUS_POS_URL` | `https://<PI_IP>` — **ตั้งเสมอ** | Gatus เช็ก `/health/ready` ผ่าน Nginx + TLS ของเครื่องตัวเอง · 🔴 ไม่ตั้ง = ค่า default `https://172.30.58.20` → Gatus ของ Pi **เฝ้า `mob04` เงียบ ๆ** (ไม่มี warning ใด ๆ) แทนตัวเอง |
| `GATUS_CA_DIR` | `/opt/pos/gatus-ca-local` | โฟลเดอร์ (0755, owner `deploy`) ที่มี `ca.crt` **public** ของ Pi (0644) — **สร้างก่อน deploy แรก** (§8 ข้อ 5b: ไม่มี = Docker สร้างโฟลเดอร์ว่างของ root ให้) แล้วใส่ `ca.crt` หลัง deploy แรก (§8 ข้อ 7b) — CA ของ Pi ≠ `mob04` · ไม่ตั้ง = Gatus ใช้ CA ของ `mob04` → check `pos-api-ready` แดงด้วย x509 · 🔴 ห้ามชี้ไปที่ volume `certs`/`certs-ca` |
| `ALERT_DISCORD_WEBHOOK` | webhook **แยก**ของ Pi (สร้างใหม่) หรือไม่ใส่ | ห้ามใช้ webhook ของ `mob04` — แยกช่อง/ชื่อให้รู้ว่า alert มาจากเครื่องไหน และ rotate แยกกันได้ · ~~`HEALTHCHECKS_PING_URL`~~ ปลดแล้ว 2026-10-13 |
| `PLATFORM_ADMINS` | `admin:<hex ใหม่ 24 ตัว>` (สร้างข้างบน) | ไม่มี = platform-ui ไม่มี admin ให้ login · 🔴 **ห้ามใช้รหัสเดียวกับ `mob04`** |

🔴 `provision.yml` **ไม่ตรวจ** `CERT_SAN_IPS`/`CORS_ORIGINS` (ตรวจแค่ 11 คีย์ `:?`) → ค่าผิดจะ deploy "เขียว" แต่ SAN/CORS ผิด · ตรวจเอง:

```bash
grep -c '^CERT_SAN_IPS=' "$SECRETS_FILE"; grep -c '172\.30\.58\.20' "$SECRETS_FILE"; grep -E '^(CORS_ORIGINS|CERT_SAN_IPS)=' "$SECRETS_FILE"
```

✅ `1` แล้ว `0` แล้วสองบรรทัดที่มี IP ของ Pi (ค่าพวกนี้ไม่ใช่ความลับ พิมพ์ได้)

ชุดตรวจเดียวกับ `mob04` — ทุกคีย์ `ok`, สามคำสั่งหลังได้ `0`:

```bash
for k in POSTGRES_PASSWORD POS_APP_PASSWORD REDIS_PASSWORD JWT_PLATFORM_SECRET JWT_PRIVATE_KEY JWT_PUBLIC_KEYS BULL_BOARD_PASSWORD ETCD_ROOT_PASSWORD GRAFANA_ADMIN_PASSWORD K6_REMOTE_WRITE_BASIC_AUTH_USER K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD; do if grep -qE "^${k}=.+" "$SECRETS_FILE"; then echo "ok       $k"; else echo "MISSING  $k"; fi; done
```

```bash
grep -cE '^(ALLOW_DEV_SECRETS|IMAGE_TAG)=' "$SECRETS_FILE"; grep -c 'dev-only-' "$SECRETS_FILE"; grep -c $'\r' "$SECRETS_FILE"
```

---

## 6. `provision.yml` ในนาม `cloud`

ทำใน `deploy/ansible/` ของ worktree §3.5 · `$DEPLOY_KEY.pub` = key ของ Pi (§2 ข้อ 4) ที่จะใส่ให้ user `deploy` · ไม่ตั้ง `DEMO_SSH_KEY_PUB` =
playbook หยิบ `~/.ssh/id_rsa.pub` ไปใส่เงียบ ๆ (คู่มือ VM §2.4)

Mac/Linux:

```bash
cd "$WT/deploy/ansible"
```

```bash
pi_guard && [[ "$SECRETS_FILE" == */pi5-demo.env ]] && test -s "$SECRETS_FILE" && test -s "$DEPLOY_KEY.pub" && DEMO_ENV_FILE="$(cat "$SECRETS_FILE")" DEMO_SSH_KEY_PUB="$(cat "$DEPLOY_KEY.pub")" DEMO_SSH_HOST="$PI_IP" DEMO_SSH_USER=cloud DEMO_SSH_KEY_PATH="$HOME/.ssh/pi5-cloud" ansible-playbook provision.yml -K
```

(`-K` ถามรหัส sudo ของ `cloud` — ตัดออกถ้าตั้ง NOPASSWD แล้ว)

Windows (Git Bash, ต้องตั้ง NOPASSWD ใน §2 ข้อ 6 ก่อน — `ans` อ่าน `REPO` จาก §3.5):

```bash
pi_guard && [[ "$SECRETS_FILE" == */pi5-demo.env ]] && test -s "$SECRETS_FILE" && test -s "$DEPLOY_KEY.pub" && DEMO_ENV_FILE="$(cat "$SECRETS_FILE")" DEMO_SSH_KEY_PUB="$(cat "$DEPLOY_KEY.pub")" DEMO_SSH_HOST="$PI_IP" DEMO_SSH_USER=cloud KEYFILE=pi5-cloud ans ansible-playbook provision.yml
```

(`-e DEMO_ENV_FILE` ของ `ans` ใส่ `.env` ทั้งไฟล์ไว้ใน config ของ container — ห้ามเปิด `docker inspect` / Docker Desktop ดู container ของ ansible ระหว่างนี้)

🔴 **ห้าม `--diff`** (พิมพ์ `.env` ทั้งไฟล์) · 🔴 ห้ามลืม `DEMO_SSH_HOST` (ไม่ตั้ง = `127.0.0.1` = เครื่องตัวเอง) · ห้ามใช้ `DEMO_SSH_USER=deploy` กับ playbook นี้

ทำอะไร (ตามโค้ด): apt ติด Docker Engine + compose plugin (repo `download.docker.com/linux/ubuntu`, arch `aarch64→arm64`) → UFW
(อนุญาตแค่ 22/80/443) → user `deploy` (group `docker`) + authorized key → `/opt/pos/...` → copy สคริปต์ ops 4 ตัวจาก worktree ลง `/opt/pos/scripts` →
ตรวจคีย์บังคับใน `DEMO_ENV_FILE` → เขียน `/opt/pos/.env` (0600) → `/opt/pos/backups` → cron backup 03:00 + heartbeat ทุก 5 นาที (`main` ปัจจุบัน · หลัง release ชุด devops PR #723: สคริปต์เหลือ 3 ตัว, สร้าง `/opt/pos/node-textfile`, **ลบ** cron + สคริปต์ heartbeat แทนการลง)

✅ recap `failed=0` · แล้วทำ **§4 ข้อ 5** (data-root + driver) ทันที · แล้ว ssh เป็น `deploy` ครั้งแรก (host key ตรึงไว้แล้วใน §2 ข้อ 6 — key ของเครื่องเดียวกัน ไม่ขึ้นกับ user) + ตรวจ:

```bash
ssh pi5-deploy 'id; ls -ld /opt/pos; stat -c "%A %U:%G %n" /opt/pos/.env'
```

✅ group `docker` และ `-rw------- deploy:deploy /opt/pos/.env` · 🔴 group `docker` = เทียบเท่า root → เก็บ `pi5-deploy_ed25519` แบบเดียวกับ key ของ `cloud`

---

## 7. (ทางเลือก ซ้อมเท่านั้น — ไม่แนะนำตอนนี้) runner บน Pi

**ไม่แนะนำจนกว่า `deploy.yml` จะ target Pi** — runner ที่ติดตั้งจะ **ไม่ได้รับงาน deploy ใด ๆ** (job ยังรันบน label `srisurart-demo-deploy` ของ `mob04`)
แต่สคริปต์ยังเขียน `/etc/sudoers.d/pos-deploy` และ GitHub ใส่ label เริ่มต้น `self-hosted`, `Linux`, `ARM64` ให้ — workflow ใดที่ขอแค่ `self-hosted` อาจมาลงเครื่องนี้

ถ้ายังต้องการ: ทำ **หลัง §6** (สคริปต์อ้าง user `deploy`) · ส่งสคริปต์ทั้งสามจาก worktree §3.5 (ไม่งั้นมัน `git clone --depth 1` จาก `main`
มาเอง ซึ่งไม่ตรึงที่ `$TAG`):

* หน้า GitHub → Settings → Actions → Runners → New self-hosted runner → **Linux + ARM64** → จด token, version, sha256 ของ tarball arm64

```bash
scp "$WT"/deploy/scripts/{setup-mob04-runner.sh,pos-deploy.sh,runner-job-started.sh} pi5:/tmp/
```

บน `aarch64` สคริปต์ **บังคับ** `RUNNER_NAME` + `RUNNER_LABELS` และ `sudo` ล้าง env จึงต้องใส่หลัง `sudo`:

```bash
ssh -t pi5 'cd /tmp && sudo RUNNER_NAME=pi5-demo RUNNER_LABELS=srisurart-pi-deploy bash ./setup-mob04-runner.sh <token> <version> <sha256>'
```

🔴 **ห้ามใช้ label `srisurart-demo-deploy` หรือชื่อ `mob04-demo`** — `config.sh --replace` จะยึด registration ของ `mob04` และ GitHub
จะส่ง deploy ของ production ไปเครื่องไหนก็ได้ที่ว่าง · ตรวจ: `gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners -q '.runners[]|[.name,.status]|@tsv'` เห็น `pi5-demo` แยกจาก `mob04-demo`

**ถอด runner** (หน้า GitHub → runner `pi5-demo` → Remove → จด remove token):

```bash
ssh -t pi5 'cd /home/gha-runner/actions-runner && sudo ./svc.sh stop && sudo ./svc.sh uninstall && sudo -u gha-runner ./config.sh remove --token <remove-token> && sudo rm /etc/sudoers.d/pos-deploy'
```

✅ `gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners -q '.runners[].name'` ไม่มี `pi5-demo`

---

## 8. deploy ครั้งแรกขึ้น Pi (ทางมือ ในนาม `deploy`)

ทุกคำสั่งเขียนครบข้างล่าง · ข้ามจากคู่มือ VM §3 ได้แก่: ข้อ 1 (คิว `Deploy (demo)` เป็นของ `mob04`), ข้อ 2–4 (ทำแล้วใน §3.5 — ห้ามสร้าง worktree ซ้ำ),
และการตรวจ `forward ok` ในข้อ 6 (Pi ใหม่ไม่มี `.current_sha` → คำสั่งนั้นพิมพ์ `STOP` เสมอ)

**1. SHA + worktree** — ทำแล้วใน §3.5 (`$TAG`, `$WT`, Windows `$REPO`) · หน้าต่างใหม่ = ประกาศตัวแปร §2 ข้อ 4 และ §3.5 ใหม่

**2. gate ดึง image จาก Pi จริง** (พิสูจน์ว่าเน็ตที่ Pi อยู่ออก `ghcr.io` ได้ — ทั้งสอง image):

```bash
ssh pi5-deploy "docker pull ghcr.io/nuimanlp/srisurart-pos-server:$TAG" && echo "gate server ok" || echo "STOP: Pi ดึง image server ไม่ได้"
```

```bash
ssh pi5-deploy "docker pull ghcr.io/nuimanlp/srisurart-pos-web:$TAG" && echo "gate web ok" || echo "STOP: Pi ดึง image web ไม่ได้"
```

**3. สถานะ Pi ก่อน deploy:**

```bash
ssh pi5-deploy 'cat /opt/pos/.current_sha 2>/dev/null || echo "no .current_sha"; docker network inspect srisurart-pos_default --format "{{json .IPAM.Config}}" 2>&1 | tail -1; df -h / /srv/pos-data'
```

✅ `no .current_sha` · บรรทัด network มี `No such network` · ดิสก์เหลือหลาย GB (บรรทัด `/srv/pos-data` ไม่มีถ้าเลือก `boot`)

**4. `.env` บน Pi ครบ** (พิมพ์แค่จำนวน):

```bash
ssh pi5-deploy 'for k in POSTGRES_PASSWORD POS_APP_PASSWORD REDIS_PASSWORD JWT_PLATFORM_SECRET JWT_PRIVATE_KEY JWT_PUBLIC_KEYS BULL_BOARD_PASSWORD ETCD_ROOT_PASSWORD GRAFANA_ADMIN_PASSWORD K6_REMOTE_WRITE_BASIC_AUTH_USER K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD CORS_ORIGINS CERT_SAN_IPS; do printf "%s=%s\n" "$k" "$(grep -c "^$k=" /opt/pos/.env)"; done'
```

✅ ทุกตัว `=1`

**5. ข้าม backup ก่อน deploy ครั้งแรก** — Pi ใหม่ยังไม่มี DB และไม่มี `.current_sha` (`backup-db.sh` จะ error เรื่อง `IMAGE_TAG`) ·
deploy ครั้งต่อไปรัน `ssh pi5-deploy '/opt/pos/scripts/backup-db.sh /opt/pos/backups && ls -lt /opt/pos/backups | head -8'` ก่อนทุกครั้ง

**5b. โฟลเดอร์ CA ของ Gatus — ก่อน deploy แรก** (ไม่มีโฟลเดอร์ = Docker สร้างโฟลเดอร์ว่างของ root ให้ตอน bind mount แล้ว Gatus ไม่ trust อะไรเลย):

```bash
ssh pi5-deploy 'install -d -m 0755 /opt/pos/gatus-ca-local && ls -ld /opt/pos/gatus-ca-local'
```

✅ `drwxr-xr-x ... deploy deploy` · `pos-api-ready` ของ Gatus จะแดงด้วย x509 จนกว่าจะทำข้อ 7b — ปกติ

**6. deploy** — Mac (ใน `$WT/deploy/ansible`):

```bash
pi_guard && test -s "$DEPLOY_KEY" && DEMO_SSH_HOST="$PI_IP" DEMO_SSH_USER=deploy DEMO_SSH_KEY_PATH="$DEPLOY_KEY" ansible-playbook deploy.yml -e image_tag="$TAG" </dev/null
```

Windows:

```bash
pi_guard && DEMO_SSH_HOST="$PI_IP" DEMO_SSH_USER=deploy KEYFILE=pi5-deploy_ed25519 ans ansible-playbook deploy.yml -e image_tag="$TAG"
```

* ครั้งแรกนาน (pull ทุก image + migration ทั้งหมด) · inventory ยังชื่อ host `vm-demo` → ข้อความ `Successfully deployed release '<sha>' to vm-demo.` เป็นปกติ
* `fatal: [vm-demo]: FAILED! ...` ตามด้วย `...ignoring` **สองครั้ง** ช่วงต้น = ปกติบนเครื่องใหม่ — ยังไม่มี `/opt/pos/.current_sha`
  (`Check currently deployed SHA on VM`) และ `/opt/pos/.env_applied_sha256` (`Read the .env checksum the last deploy applied`) · ทั้งสอง task เป็น `ignore_errors`
* `</dev/null` แก้แค่ stdin — ถ้า error ชี้ `<stdout>`/`<stderr>` ต่อท้าย `</dev/null 2>&1 | cat` (คู่มือ VM §6.4)

✅ recap `failed=0` — **ยังไม่ใช่หลักฐาน** ไปข้อ 7

**7. ตรวจผล** (ทุกข้อต้องผ่าน):

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
openssl s_client -connect "$PI_IP:443" </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName
```

✅ มี `IP Address:<PI_IP>` และ **ไม่มี** `172.30.58.20` · ❌ มีแค่ `172.30.58.20` → `CERT_SAN_IPS` ไม่ถึง `/opt/pos/.env` (กลับ §5 + provision ใหม่ แล้ว deploy ซ้ำ — `.env` เปลี่ยน = deploy SHA เดิมซ้ำเอง)

เปิด `https://<PI_IP>` ในเบราว์เซอร์ → หน้า login ขึ้น (เตือนใบรับรอง = ปกติ ดู §9) · ตรวจต่อ (etcd, migration, รูปสินค้า) ตามคู่มือ VM §4 —
🔴 คำสั่งในนั้นเป็น `ssh mob04-deploy ...` ทั้งหมด: **พิมพ์ใหม่เป็น `ssh pi5-deploy ...` ทีละบรรทัด** ห้ามวางทั้งก้อน

**7b. ให้ Gatus trust CA ของ Pi** — `certgen` ของ deploy แรกเพิ่งสร้าง CA · ดึงแค่ `ca.crt` (public) จากสำเนาใน volume `certs` ผ่าน nginx
(ไม่แตะ `certs-ca` / `ca.key`) แล้ว recreate เฉพาะ gatus:

```bash
ssh pi5-deploy 'cd /opt/pos && IMAGE_TAG=$(cat .current_sha) docker compose -f docker-compose.yml -f vm.override.yml exec -T nginx cat /etc/nginx/certs/ca.crt > gatus-ca-local/ca.crt && chmod 0644 gatus-ca-local/ca.crt && openssl x509 -in gatus-ca-local/ca.crt -noout -subject -fingerprint -sha256'
```

```bash
ssh pi5-deploy 'cd /opt/pos && IMAGE_TAG=$(cat .current_sha) docker compose -f docker-compose.yml -f vm.override.yml -f monitoring.yml up -d --force-recreate gatus'
```

✅ fingerprint **ไม่ตรง** กับของ `mob04` (`87:7B:B8:F7:…`) — เป็น CA ใหม่ของ Pi · หลัง ~3 นาที tunnel `13300` (§10) → `pos-api-ready` เขียว ·
ยังแดงด้วย x509 = `GATUS_CA_DIR` ไม่ถึง `/opt/pos/.env` (§5) · แดงด้วย connection refused/timeout = `GATUS_POS_URL` ไม่ใช่ IP ของ Pi

**8. เก็บกวาด** (เมื่อเลิกซ้อม — worktree ใช้ซ้ำได้ถ้าจะ deploy SHA เดิมอีก):

```bash
git -C "$MAIN" worktree remove ../pos-pi5
```

---

## 9. Client — เบราว์เซอร์และ APK

* **CA ของ Pi เป็นคนละตัวกับ `mob04`:** `certgen` สร้าง CA ใหม่ใน volume `certs-ca` ของ Pi ตอน deploy แรก (`ca.key` ไม่เคยออกจากเครื่อง)
  → APK ที่ฝัง `frontend/assets/certs/pos-ca.crt` (CA ของ `mob04`) **ไม่ trust Pi**
* **ช่วงซ้อม (แนะนำ):** ใช้ CA ใหม่ของ Pi + เบราว์เซอร์ — ยอมรับคำเตือน หรือติดตั้ง `ca.crt` ของ Pi ในเครื่องทดสอบ (ดึงทาง SSH ตาม 07 §5 runbook ข้อ 2–3 — **ห้าม commit ทับ** `pos-ca.crt` ของ `mob04`)
* **APK สำหรับ Pi = เรื่องที่ owner ต้องตัดสิน (นอกขอบเขตคู่มือนี้):** `android-apk.yml` ฮาร์ดโค้ด `API_BASE_URL: https://172.30.58.20`
  → ต้องแก้ workflow + เลือกว่าจะใช้ CA เดิมของ `mob04` หรือ commit CA ใหม่แล้ว build APK ใหม่ทุกเครื่อง
* 🔴 **คัดลอก `certs-ca` จาก `mob04` = ย้าย CA private key (`ca.key`) ออกจาก `mob04`** — owner ตัดสินเท่านั้น · ถ้าทำ: ส่ง VM → Pi **ตรงผ่าน ssh**
  (ห้ามผ่าน notebook / แชต / USB), ตรวจว่า SHA-256 ของ `ca.crt` บน Pi = ของ `frontend/assets/certs/pos-ca.crt`, และกฎใน CLAUDE.md
  "`ca.key` lives only in `certs-ca`" ต้องแก้ตาม · สำหรับซ้อม **ใช้ CA ใหม่**
* 🔴 **ห้าม `docker compose down -v` / ลบ volume `certs-ca`** บน Pi เช่นกัน — CA ใหม่ = client ที่ trust CA เดิมต่อไม่ได้

---

## 10. Monitoring + RAM + log

Grafana / Prometheus / Bull-Board / platform-ui ผูก `127.0.0.1` ของ Pi เท่านั้น — เข้าผ่าน SSH tunnel (ไม่ใช่ grant ของ tailnet):

```bash
ssh -N -L 13000:127.0.0.1:3000 -L 19090:127.0.0.1:9090 -L 13100:127.0.0.1:3100 -L 13200:127.0.0.1:3200 -L 13300:127.0.0.1:3300 pi5-deploy
```

แล้วเปิด `http://localhost:13000` (Grafana), `:19090`, `:13100`, `:13200`, `:13300` (Gatus — uptime + alert → Discord, `07 §10.5`)

RAM (งบ 8 GB, `mem_limit` รวม ≈ 4.3 GB — เพดาน ไม่ใช่การจอง):

```bash
ssh pi5-deploy 'free -h; docker stats --no-stream --format "{{.Name}} {{.MemUsage}}"'
```

swap ของ Ubuntu Server บน Pi ตั้งไว้หรือไม่ = ยังไม่ยืนยัน (แผนย้าย §4.8) — ดูจาก `free -h`

**log ของ container:** compose ไม่มี `logging:` → ใช้ค่าของ daemon = `log-driver local` ที่ `host-setup.sh` เขียน (หมุน + บีบอัด,
≈ 100 MB ต่อ container) · ใช้กับ container ที่**สร้างหลัง**ตั้งค่าเท่านั้น · ตรวจ: `docker info --format '{{.LoggingDriver}}'` = `local` ·
ห้ามแก้ log option ใน `/etc/docker/daemon.json` เอง (รันสคริปต์ซ้ำจะ `REFUSED: /etc/docker/daemon.json exists with different content`) ·
`--data-disk boot` ไม่เขียน `daemon.json` → log ไม่มีเพดาน ดู `df -h /` เป็นระยะ

---

## 11. Backup — 🔴 ยังไม่ปลอดภัย

* `provision.yml` ตั้ง cron 03:00 ของ `deploy` → `backup-db.sh` เขียน dump + `pos_images_*.tar.gz` + `pos_sale_photos_*.tar.gz` **เต็มทุกคืน** ลง `/opt/pos/backups` (microSD)
  เก็บ 7 วัน (`BACKUP_KEEP_DAYS` ค่าเริ่ม 7) → รูปเยอะ = SD 32 GB เต็มได้ (root เต็ม = apt/journald พัง) และ SD สึก ·
  ตรวจ `ssh pi5-deploy 'df -h / /srv/pos-data'` หลัง backup สองสามคืนแรก · ใช้ microSD ≥ 64 GB หรือให้ owner ตัดสินลด `BACKUP_KEEP_DAYS`
* **backup บนเครื่องเดียวกันไม่ใช่ backup ที่ปลอดภัย** — offsite (#363) ยัง parked · Pi เครื่องเดียวในร้าน = ไฟไหม้/ขโมย/SD พัง → ข้อมูลหาย ·
  `--data-disk boot` = ข้อมูลกับ backup อยู่บน SD ใบเดียวกัน · ห้ามเขียนว่า "backup พร้อมแล้ว" ที่ไหน · log สีเขียวไม่ได้แปลว่าออกจากเครื่อง (อ่านบรรทัด `::warning::`)
* ครั้งแรกบน Pi ให้รัน `backup-db.sh` ด้วยมือหนึ่งครั้งหลัง deploy และอ่าน output (แผนย้าย §4.7) ·
  **ซ้อม `restore-db.sh` หนึ่งครั้ง** ตอนที่ Pi มีแต่ข้อมูลทดสอบ (`restore-db.sh <pos_backup_….sql.gz> [target_database]`) — `restore-db.sh` ยังไม่กู้รูปสินค้า/รูปหลักฐาน
* สำเนาด้วยมือระหว่างรอ #363 = owner ตัดสิน (แผนย้าย §3 "ผลต่อ offsite backup")

---

## 12. Troubleshooting

| อาการ / ข้อความ | แปลว่า | ทำ |
|---|---|---|
| `REFUSED: kernel page size is 16384, not 4096 ...` | ลง Raspberry Pi OS (kernel 16K) | ลง Ubuntu Server ใหม่ (§2) |
| Pi ไม่ boot Ubuntu 26.04 เลย (จอดำ/ไฟแดง) | EEPROM เก่า (≤ 2024-09-23) | §2 ข้อ 0 |
| `REFUSED: OS '...' is not supported` / `architecture '...' is not supported` | OS อื่น / 32-bit | Ubuntu Server 64-bit |
| `REFUSED: --profile pi5 on a host that is not a Raspberry Pi 5` | `/proc/device-tree/model` ไม่ใช่ Pi 5 | ตรวจบอร์ด / ใช้ `--profile vm` |
| `REFUSED: /dev/... is on the boot disk ...` | เลือกดิสก์ที่มี `/` | ใช้ `--data-disk boot` หรือเลือกดิสก์อื่น |
| `REFUSED: ... is in use (mounted elsewhere, swap, LVM or RAID)` | ดิสก์ถูกใช้อยู่ | unmount เอง หรือเลือกตัวอื่น |
| `REFUSED: ... has filesystem '...', not ext4. This script never formats a disk.` | ยังไม่ใช่ ext4 | §3 (ระบุดิสก์ด้วยการถอด-เสียบก่อน!) แล้วรันซ้ำด้วย `sudo bash /tmp/host-setup.sh ...` |
| `REFUSED: /dev/sdX has N partitions (...)` | หลาย partition | `--data-disk <partition>` |
| `REFUSED: /etc/docker/daemon.json exists with different content` | มีคนตั้ง Docker ไว้แล้ว | รวมเนื้อหาด้วยมือ |
| `REFUSED: Docker already has volumes in /var/lib/docker ...` | รันหลัง provision/deploy | ต้องรันก่อน หรือย้ายข้อมูลด้วยมือ (owner) |
| `REFUSED: /etc/fstab already mounts /srv/pos-data differently` / `findmnt --verify rejects ...` | fstab มีบรรทัดอื่น/ผิดรูป (`/etc/fstab` ไม่ถูกแตะ) | แก้ fstab ด้วยมือ |
| `no --data-disk given and no TTY for the menu` (exit 2) | ไม่มี flag และไม่มี TTY | ใส่ `--data-disk` หรือใช้ `ssh -t` |
| `sudo: /tmp/host-setup.sh: command not found` / `Permission denied` | รันตามบรรทัด `then re-run:` ที่ไม่มี `bash` | `sudo bash /tmp/host-setup.sh ...` (§4) · หลัง reboot `scp` ใหม่ |
| `docker info` เห็น `/var/lib/docker` หรือ driver ≠ `overlay2` | `daemon.json` ไม่ถูกใช้ / containerd image store | หยุด ห้าม deploy (§4 ข้อ 5) |
| Docker ไม่ start หลัง boot, `systemctl status docker` อ้าง `/srv/pos-data` | ดิสก์ข้อมูลไม่ได้เสียบ/ไม่ mount — **ตั้งใจ** (`RequiresMountsFor`) | เสียบดิสก์ → `sudo mount /srv/pos-data` → `sudo systemctl start docker` · 🔴 **ห้ามลบ drop-in เพื่อให้ Docker ขึ้น** — มันจะ start บน SD เปล่าแล้วร้านดูเหมือนข้อมูลหาย |
| ดิสก์ USB หลุดเป็นช่วง ๆ, `dmesg` มี `reset` / `I/O error` | ไฟไม่พอ หรือ bridge มีปัญหากับ UAS | ที่จ่ายไฟทางการ 27 W (§1) · เปลี่ยนกล่อง |
| `verify-ghcr-tags.sh` exit 2 + `Release '<sha>' was not built for linux/arm64` | SHA เก่ากว่า `5c7f210` (image amd64 อย่างเดียว) | ใช้ SHA ใหม่กว่า — ห้าม deploy SHA นั้นขึ้น Pi |
| เบราว์เซอร์ `IP address mismatch` / SAN ไม่มี `<PI_IP>` | `CERT_SAN_IPS` ไม่ได้ตั้ง | §5 → provision → deploy |
| `pi_guard` ขึ้น `STOP` | หน้าต่างใหม่ / ตัวแปรของ `mob04` ค้าง | ประกาศ §2 ข้อ 4 ใหม่ในหน้าต่างของ Pi |
| `Permission denied (publickey)` / `UNREACHABLE` ทันทีจาก `ans` | key มี passphrase หรือ `sudo` ต้องการรหัส (ไม่มี tty ใน container) | key ไม่มี passphrase สำหรับ `ans` · NOPASSWD (§2 ข้อ 6) |
| อื่น ๆ (`UNREACHABLE`, network `ip_range`, etcd) | เหมือน VM | คู่มือ VM §6.4 (อ่านเท่านั้น — คำสั่งในนั้นชี้ `mob04`) |

---

## 13. ย้อน `host-setup.sh` (เฉพาะสิ่งที่สคริปต์สร้าง)

🔴 ทำก่อนมีข้อมูลจริงเท่านั้น — หลังย้อน Docker จะกลับไปใช้ `/var/lib/docker` (ว่าง) = stack เห็นเหมือนติดตั้งใหม่ ·
ข้อมูลเดิม **ยังอยู่บน `/srv/pos-data`** (ไม่ถูกลบ) — 🔴 ห้าม `mkfs` ดิสก์นั้นจนกว่า owner ยืนยันว่าไม่ต้องการข้อมูลแล้ว ·
ขั้นตอนนี้ **ไม่ย้อน** สิ่งที่ `provision.yml` ทำ (UFW, user `deploy`, cron, `/opt/pos`) และไม่ถอด runner (§7)

หยุด stack ก่อนแบบปกติ (🔴 ห้าม `down -v`):

```bash
ssh pi5-deploy 'cd /opt/pos && IMAGE_TAG=$(cat .current_sha) docker compose -f docker-compose.yml -f vm.override.yml stop'
```

ต่อจากนี้ใน `ssh -t pi5` (เป็น `cloud`):

```bash
sudo systemctl stop docker docker.socket
```

```bash
diff /etc/fstab.pos-bak /etc/fstab
```

✅ ต่างกันแค่บรรทัด `UUID=... /srv/pos-data ...` → `sudo cp -p /etc/fstab.pos-bak /etc/fstab` · ต่างมากกว่านั้น = มีคนแก้ fstab ทีหลัง → ลบบรรทัดนั้นด้วยมือแทน

```bash
sudo umount /srv/pos-data
```

`target is busy` → ดูว่าใครใช้อยู่ `sudo fuser -vm /srv/pos-data` แล้วหยุดโปรเซสนั้นก่อน (ห้าม `umount -l`)

```bash
sudo rm /etc/docker/daemon.json /etc/systemd/system/docker.service.d/10-pos-data.conf
sudo systemctl daemon-reload
sudo systemctl start docker
```

Tailscale: `sudo tailscale down` → `sudo apt-get remove tailscale` → ลบ `/etc/sysctl.d/99-tailscale.conf` (เฉพาะถ้าสคริปต์สร้างไฟล์นี้ —
ถ้ามีอยู่ก่อน มันแค่เติมบรรทัด `net.ipv4.ip_forward = 1`) → ลบเครื่องออกจาก admin console (แผน Tailscale §7)

---

## 14. กฎห้ามทำ (สรุป)

* ห้ามรันคำสั่งจากคู่มือ VM ตามตัวอักษรกับ Pi (ทุกบรรทัดชี้ `mob04`) · ทำ Pi ในหน้าต่าง terminal แยก + `pi_guard` ทุกคำสั่ง Ansible
* ห้ามใช้ key `deploy`, ไฟล์ secrets, รหัส `PLATFORM_ADMINS` หรือ `ALERT_DISCORD_WEBHOOK` ร่วมกับ `mob04`
* ห้าม `docker compose down -v` · ห้ามลบ `certs-ca` · ห้าม `--diff` กับ `provision.yml` · ห้ามคัดลอก `certs-ca` ของ `mob04` โดย owner ไม่ตัดสิน
* `provision.yml` = `cloud` เท่านั้น · `deploy.yml` = `deploy` เท่านั้น
* ห้ามให้ runner บน Pi ใช้ชื่อ `mob04-demo` / label `srisurart-demo-deploy`
* ห้ามลบ drop-in `RequiresMountsFor` · ห้ามเปิด SNAT ของ Tailscale กลับ · ห้าม `--lan-ip 172.30.58.20` / `172.30.58.20` ใน `CERT_SAN_IPS` ของ Pi
* หลัง deploy เพิ่ม Tailscale ด้วย `--profile vm` (§4.1) — ไม่รัน `--profile pi5 --data-disk ...` ซ้ำ (สคริปต์รุ่นเก่า restart Docker เสมอ)
* ห้ามเรียก Pi ว่า production / ห้ามบอกว่า backup ปลอดภัย จนกว่า owner ตัดสิน
* แก้ `.env` ด้วยมือ: ตรวจด้วย `grep -c '^KEY='` เสมอ และเติมบรรทัดว่างก่อน append (คู่มือ VM §2.5)
