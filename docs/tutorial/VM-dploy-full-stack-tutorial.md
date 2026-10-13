# คู่มือ deploy full stack ขึ้น VM `mob04` (Ansible) — ฉบับมือใหม่

**อัปเดต 2026-10-13 (release `main` `5c7f210` PR #714 = image หลาย arch #711, `CERT_SAN_IPS` #712, `host-setup.sh` #713 — บน `mob04` (amd64) ขั้นตอน deploy ไม่เปลี่ยน; Tailscale บน `mob04` — §1.2)** — **ตรวจกับโค้ดที่:** `origin/main` @ `5c7f210` · 2026-10-13 (ทบทวนโดย reviewer 3 มุม: ความตรงกับ repo, แหล่งทางการ, ความปลอดภัย/ลำดับ) — ตรวจรอบแรก `494ace3` · 2026-09-30 — **อัปเดต 2026-10-13 (release `main` `8a44a03` PR #704 = แผ่นถ่ายรูปมีกล้องในแอป + เรียงรูป #702 และแท็บซัพพลายเออร์แบบเริ่มที่ซัพฯ #703 — เฉพาะ client: ไม่มี migration, ไม่มีขั้นตอนมือ, `backup-db.sh` ไม่เปลี่ยน; deploy run `38275228902`; APK ใหม่ `apk-32a2544` — §6.7)** — **อัปเดต 2026-10-12 (รูปหลักฐานสินค้าตอนขาย — volume `sale-photos`, ตาราง `sale_photos` → Postgres 31 ตาราง, `backup-db.sh` เก็บ `pos_sale_photos_*.tar.gz`; `main` `c3e33aa` PR #699 — §3 ข้อ 8, §4.7b)** — **อัปเดต 2026-10-10 (รูปสินค้า — volume `product-images`, `/img/`, backup ZIP/รูป; ตรวจกับ branch `feat/product-images`, PR #680 — §3 ข้อ 8, §4.7, §6.5)** — **อัปเดต 2026-10-06 (#616 UUID cutover, `main` = `65861ea`, ดู §6.2/§6.3/§6.3b)** — อัปเดตจุดที่ล้าสมัย 2026-10-01 (#519 `.partial`, #516 CORS) (รวม PR #498–#504 — web-sync หลัง API + สลับแบบ atomic, `.env` มี newline ท้าย, backup resolve `IMAGE_TAG` เอง, web cache-busting · และ #506 — `.env` เปลี่ยน = `deploy.yml` rollout SHA เดิมซ้ำ, provision ตรวจคีย์ก่อนเขียน · #508 — `deploy.yml` สร้าง `docker/nginx` เองบน `/opt/pos` ที่ว่าง · และ deploy/rollback จริงบน `mob04` 2026-09-30)
**เอกสารเจ้าของเรื่อง:** `docs/Backend_design/07_CICD_DEPLOY.md` §5–§7, ADR-0013 · ถ้าคู่มือนี้ขัดกับไฟล์ใน `deploy/` → **ไฟล์ถูก**

---

## 0. หน้าแรก — อ่านหน้านี้ก่อนทำอะไร

> **Raspberry Pi 5 แทน VM?** ดู `docs/tutorial/pi5-full-stack-tutorial.md` (2026-10-13 — `host-setup.sh` + image arm64; ยังไม่มี Pi จริงในระบบ, CD ไป Pi ยังไม่ต่อ)

### 0.1 สถานะวันนี้: FortiGate ไม่ตัด `ghcr.io` แล้ว (2026-09-29)

เดิม (2026-09-21 → 09-28) Firewall **FortiGate** ของคณะทำ SSL inspection กับ HTTPS ขาออกของ VM `172.30.58.20` และตอบ `ghcr.io`
ด้วยใบรับรองที่ **ไม่มี SAN** → `docker compose pull` ล้มด้วย `x509: certificate is not valid for any names` ·
**คลี่คลาย 2026-09-29:** `docker pull ghcr.io/…:<SHA เต็ม>` จาก `mob04` สำเร็จจริง และ TLS จาก VM ไป `ghcr.io`, `registry-1.docker.io`,
`gcr.io`, `github.com`, `api.github.com`, `*.actions.githubusercontent.com` verify ผ่านหมด (ใบของ FortiGate มี SAN `*.ghcr.io`/`ghcr.io` แล้ว)

* ยังคง gate ไว้ที่ §3 ข้อ 5 (`docker pull` จริงจาก VM) — ถ้า inspection กลับมา จะหยุดตรงนั้นก่อน `deploy.yml` แตะอะไร
* `docker save`/`load` ด้วยมือ = ทางกู้วันเดโมเท่านั้น **ห้ามบันทึกว่าเป็น CD**
* ประวัติ: `docs/handoff_log/handoff_demo-335-merge-and-cd-blocked_21_09_2026.md` §4.7

**ทำไม gate ข้อ 5 ต้องมาก่อน:** ใน `deploy.yml` task ที่ **copy ไฟล์ compose / nginx.conf / platform-ui / postgres init / etcd-init.sh / certgen.sh
ลง `/opt/pos`** และ task ที่ **`rmdir` ไดเรกทอรี `etcd-init.sh` เก่า** รัน **ก่อน** `pull` · ถ้าล้มที่ `pull` VM จะเหลือไฟล์ config ใหม่วางคู่กับ
container เก่า — ใครพิมพ์ `docker compose` บน VM หลังจากนั้นจะใช้ config ที่ไม่ตรงกับสิ่งที่รันอยู่

### 0.2 ใครทำอะไร

| บทบาท | ทำ | ต้องมี |
|---|---|---|
| **Owner** (`NuimanLP`) | `provision.yml`, ถือไฟล์ `.env`, ติดตั้ง key ของสมาชิก, approve/cancel run `Deploy (demo)`, ตัดสินเรื่อง re-key/rollback ข้าม migration | key ของ user `cloud` + ไฟล์ secrets |
| **สมาชิก** | pre-flight, `deploy.yml`, ตรวจผล, แปะหลักฐาน — **เฉพาะเมื่อ owner ติดตั้ง key `deploy` ให้แล้ว** | key ของ user `deploy` ของตัวเอง |

สมาชิก **ไม่ถือไฟล์ `.env`** เว้นแต่ owner ตัดสินให้ถือ

### 0.3 สอง user บน VM — สลับกันไม่ได้

| | `cloud` | `deploy` |
|---|---|---|
| sudo | มี (NOPASSWD) | **ไม่มี** |
| group `docker` | **ไม่อยู่** | อยู่ |
| เขียน `/opt/pos` | **ไม่ได้** | ได้ (เจ้าของ) |
| ใช้กับ | **`provision.yml` เท่านั้น** | **`deploy.yml` + คำสั่งตรวจ** |

(วัดจริง: `docs/handoff_log/ticket-343-vm-deploy.md` §3) · `--check` ไม่เผยการใช้ user ผิด ·
🔴 group `docker` = **เทียบเท่า root** (docs.docker.com/engine/install/linux-postinstall/) → เก็บ key ของ `deploy` ให้ดีเท่า key ของ `cloud`

### 0.4 ภาพรวม

```text
merge → main ── Server CI + Flutter CI ──▶ GHCR: srisurart-pos-server:<sha> + srisurart-pos-web:<sha>
                                                      │
notebook (worktree สะอาดที่ <sha>)                     │ docker compose pull  ◀── gate §3 ข้อ 5
   ├─ ssh เป็น cloud  ─▶ provision.yml (owner)          │
   └─ ssh เป็น deploy ─▶ deploy.yml -e image_tag=<sha> ─┴─▶ VM mob04 /opt/pos ─▶ /opt/pos/.current_sha = <sha>
```

ตั้งแต่ `5c7f210` (#711): `:<sha>` เป็น **manifest list (amd64 + arm64)** — image server ทำโดย job `publish-image` จาก `<sha>-amd64` / `<sha>-arm64`
หลังทั้งสองขาผ่าน, image web push ทั้งสอง platform ด้วย buildx ครั้งเดียว · `docker pull` บน `mob04` เลือกขา amd64 เอง — **ไม่มีอะไรต้องเปลี่ยนใน Ansible หรือ `.env`**
· ทางหลักของการ deploy = CD (§6.3) · §3 = ทางสำรองด้วยมือ

### 0.5 เสร็จแล้วรู้ได้อย่างไร

deploy สำเร็จ = **ทุกข้อ** ใน §4 ผ่าน และหลักฐานตาม §5 ถูกแปะใน #344 หรือ issue ของ release นั้น
**ไม่นับเป็นหลักฐาน:** PLAY RECAP เขียว · ผล `--check` · run สีเขียวใน Actions

---

## 1. ติดตั้งครั้งเดียว (ทุกคน)

### 1.1 เครื่องมือ

repo ต้องอยู่บน **path ASCII** (เช่น `C:\srisurart_pos`, `~/srisurart_pos`) — ห้ามอยู่ใต้โฟลเดอร์ภาษาไทย (CLAUDE.md)

**Mac:**

```bash
brew install ansible gh
```

**Windows:** ติดตั้ง Docker Desktop, Git for Windows (Git Bash) และ `gh` (GitHub CLI) · Ansible รันใน container ที่ pin ด้วย digest ไม่ต้องมี WSL

ทั้งสองแบบ — login GitHub CLI (ใช้ตรวจ CI ใน §3):

```bash
gh auth login
```

✅ `gh auth status` บอก `Logged in to github.com`

#### Windows: ฟังก์ชัน `ans` (ประกาศครั้งเดียวต่อหน้าต่าง Git Bash หรือใส่ใน `~/.bashrc`)

ครอบ `docker run` ของ Ansible ไว้ทั้งหมด: mount repo (`REPO`) กับโฟลเดอร์ key (`SSHDIR`), บังคับ `ANSIBLE_CONFIG`, copy key ชื่อ `KEYFILE` ไป `/tmp/k`
แล้ว `chmod 600` ใน container, ส่ง `DEMO_SSH_HOST`/`DEMO_SSH_USER`/`TAG` เข้าไป และส่ง `DEMO_ENV_FILE`/`DEMO_SSH_KEY_PUB` **เฉพาะเมื่อมีค่า**

```bash
ans() {
  local extra=()
  if [ -n "${DEMO_ENV_FILE:-}" ]; then extra+=(-e DEMO_ENV_FILE); fi
  if [ -n "${DEMO_SSH_KEY_PUB:-}" ]; then extra+=(-e DEMO_SSH_KEY_PUB); fi
  MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$REPO:/work" -v "$SSHDIR:/hostssh:ro" \
    -w /work/deploy/ansible \
    -e ANSIBLE_CONFIG=/work/deploy/ansible/ansible.cfg \
    -e DEMO_SSH_HOST -e DEMO_SSH_USER -e DEMO_SSH_KEY_PATH=/tmp/k -e KEYFILE -e TAG \
    "${extra[@]}" \
    'alpine/ansible@sha256:22227b578da3371267201879f44de86569e9b531db536e1d9d2b83aed35b6cfc' \
    sh -c '[ -z "$KEYFILE" ] || { cp "/hostssh/$KEYFILE" /tmp/k && chmod 600 /tmp/k; } || exit 1; exec "$@"' sh "$@"
}
```

```bash
export SSHDIR="$USERPROFILE\.ssh"
```

เหตุผลของแต่ละชิ้น (วัดจริงใน `ticket-343` §2): bind mount ของ Windows เป็น world-writable → Ansible **เมิน `ansible.cfg` เงียบ ๆ** ถ้าไม่บังคับ
`ANSIBLE_CONFIG` · key บน mount `:ro` chmod ไม่ได้ → ต้อง copy · `MSYS_NO_PATHCONV=1` กัน Git Bash แปลง `/work` เป็น path Windows ·
ตัวแปรที่ใส่นำหน้าคำสั่ง (`DEMO_SSH_USER=deploy ans ...`) มีผลแค่คำสั่งนั้น ไม่ค้างใน shell

`REPO` ตั้งจริงใน §3 ข้อ 4 (ชี้ไปที่ worktree สะอาด) · ทดสอบฟังก์ชันตอนนี้ด้วย repo หลัก (Git Bash ที่ root ของ repo · ไม่ใส่ `KEYFILE` = ไม่ copy key):

```bash
REPO="$(pwd -W)" ans ansible --version
```

**Mac** — ตรวจว่า Ansible อ่าน config ถูกไฟล์ (ต้องรันจากใน `deploy/ansible/`):

```bash
cd deploy/ansible
```

```bash
ansible --version
```

```text
ansible [core 2.21.4]
  config file = /Users/<you>/<repo>/deploy/ansible/ansible.cfg
```

✅ `config file =` ชี้ไฟล์ `deploy/ansible/ansible.cfg` (Windows: `/work/deploy/ansible/ansible.cfg`, core 2.18.1)
❌ `config file = None` → Mac: ไม่ได้อยู่ใน `deploy/ansible/` · Windows: ลืม `ANSIBLE_CONFIG` · ห้ามแก้ด้วยการปิด host key checking บน command line

> run จริงกับ `mob04` ที่มีบันทึกทั้งหมดใช้ core 2.18.1 (container) · 2.21 (brew) ผ่าน `--syntax-check` แต่ยังไม่เคยรันกับ VM —
> เจออาการแปลกให้ลองซ้ำด้วย container ก่อนสรุปว่าเป็นบั๊ก
>
> ⚠️ ansible-core **2.18 หมดอายุ (EOL) พฤษภาคม 2026** (docs.ansible.com — release_and_maintenance) · การ bump digest ของ container เป็นงานแยก
> และต้องลองกับ VM ก่อนใช้จริง — ระหว่างนี้ใช้ digest เดิม

### 1.2 เครือข่าย: ต้องอยู่ในเครือข่ายมหาวิทยาลัยหรือต่อ VPN

`172.30.58.20` (hostname `mob04`) เข้าจากนอกมหาวิทยาลัยไม่ได้ — **ยกเว้น HTTPS ผ่าน Tailscale (2026-10-13)** ข้างล่าง ·
งาน ssh / deploy ยังต้องใช้เครือข่ายคณะหรือ VPN

**Tailscale บน `mob04` (2026-10-13 — `docs/research/tailscale-remote-access-plan-2026-10-13.md`):**

* `mob04` เป็น subnet router ของ `172.30.58.20/32` เท่านั้น ด้วย `--snat-subnet-routes=false` — 🔴 **ห้ามเปิด SNAT** (rate limit ต่อ IP ของ login
  จะรวมทุกเครื่องเป็น bucket เดียว และ allowlist RFC1918 ของ nginx จะเห็นทุกคนเป็น LAN)
* สมาชิก tailnet เข้าได้แค่ `https://172.30.58.20` (443) · SSH ผ่าน tailnet = **owner คนเดียว** · สมาชิกที่ต้อง ssh/deploy ยังต้องใช้เครือข่ายคณะ/VPN
* dashboard (Grafana ฯลฯ) ผ่าน SSH tunnel เท่านั้น (§4.5) — ไม่ใช่ grant ของ tailnet
* 🔴 **ห้ามรัน `tailscale up` / `--reset` หรือ `host-setup.sh` บน `mob04`** (ติดตั้งแล้วด้วยมือ — การ `up` ใหม่ล้าง flag ที่ตั้งไว้)
* ตรวจ (owner, เป็น `cloud`): `ssh mob04 'sudo tailscale debug prefs | grep -i nosnat'` → ✅ `"NoSNAT": true`
  (ถ้าชื่อ field ต่างไปในรุ่นที่ติดตั้ง ให้ดูทั้งผลของ `tailscale debug prefs`)

```bash
nc -vz 172.30.58.20 22
```

Windows (PowerShell): `Test-NetConnection 172.30.58.20 -Port 22`

✅ `succeeded` / `TcpTestSucceeded : True` · ❌ timeout → ต่อ VPN ก่อน ไม่มีอะไรข้างล่างทำงานได้

### 1.3 สร้าง SSH key ของ `deploy` (ของใครของมัน)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/deploy_ed25519 -C "deploy@mob04 <ชื่อคุณ>"
```

* ได้ `~/.ssh/deploy_ed25519` (private — **ห้ามออกจากเครื่อง**) และ `~/.ssh/deploy_ed25519.pub` (public — ส่ง owner ได้)
* passphrase: Mac ใช้ได้กับ `ssh-add --apple-use-keychain` + ใน `~/.ssh/config` ใส่ `UseKeychain yes` และ `AddKeysToAgent yes` ·
  ฟังก์ชัน `ans` บน Windows ไม่มี tty และไม่มี agent → key ที่มี passphrase **ไม่ค้าง แต่ล้มทันที** ด้วย `Permission denied (publickey)` / `UNREACHABLE`
  (เช่นเดียวกับ `-K` และคำถาม host key) → ใช้ key ไม่มี passphrase กับ `ans`
* **Windows:** OpenSSH ของ Windows (`C:\Windows\System32\OpenSSH\ssh.exe`) ปฏิเสธ key ที่คนอื่นอ่านได้ (ssh ของ Git Bash ไม่สน) → ตั้ง ACL ใน PowerShell:

```powershell
icacls "$env:USERPROFILE\.ssh\deploy_ed25519" /inheritance:r /grant:r "${env:USERNAME}:R"
```

ส่ง **ไฟล์ `.pub` เท่านั้น** ให้ owner แล้วรอ owner ติดตั้ง (§2.4)

### 1.4 `~/.ssh/config` + ตรึง host key ครั้งแรก

เพิ่มท้าย `~/.ssh/config` (Git Bash: `~` = `%USERPROFILE%`):

```text
Host mob04-deploy
  HostName 172.30.58.20
  User deploy
  IdentityFile ~/.ssh/deploy_ed25519
  IdentitiesOnly yes
```

**`DEPLOY_KEY` = private key ที่ user `deploy` ยอมรับ** — ทุกคำสั่ง Mac ข้างล่างอ่านจากตัวแปรนี้ (ประกาศต่อหน้าต่าง terminal):

```bash
export DEPLOY_KEY=~/.ssh/deploy_ed25519
```

* **สมาชิก:** ค่าข้างบน (key จาก §1.3)
* **owner บน Mac ของ owner (ตรวจแล้ว 2026-09-30):** `authorized_keys` ของ `deploy` มี key เดียวคือ `mob04-SriStore` และ `~/.ssh/deploy_ed25519` **ไม่มี**
  → `export DEPLOY_KEY=~/.ssh/mob04-SriStore` และใน block `Host mob04-deploy` ข้างบนใช้ `IdentityFile ~/.ssh/mob04-SriStore` · Windows: `KEYFILE=mob04-SriStore` แทน `deploy_ed25519`

ด่านก่อนทุกคำสั่งที่ใช้ key (ต้องได้ `key ok`):

```bash
test -s "$DEPLOY_KEY" && test -s "$DEPLOY_KEY.pub" && echo "key ok" || echo "STOP: ไม่มี $DEPLOY_KEY หรือ .pub"
```

`ansible.cfg` ตั้ง `host_key_checking = False` → **Ansible จะไม่ตรวจว่าคุยกับเครื่องจริง** · ssh ด้วยมือหนึ่งครั้งเพื่อให้ `known_hosts` จำ key ของ VM:

```bash
ssh mob04-deploy 'id; docker ps --format "{{.Names}}" | head -3'
```

ครั้งแรกจะถาม `Are you sure you want to continue connecting` พร้อม fingerprint → **เทียบกับที่ owner ประกาศ** ก่อนตอบ `yes`

✅ `id` มี group `docker` และเห็นชื่อ container รูป `srisurart-pos-<service>-<n>` (เช่น `api-1` → `srisurart-pos-api-1-1`,
`nginx` → `srisurart-pos-nginx-1`, `platform-ui` → `srisurart-pos-platform-ui-1`)
❌ `Permission denied (publickey)` → owner ยังไม่ติดตั้ง key ของคุณ · `REMOTE HOST IDENTIFICATION HAS CHANGED` → หยุด ถาม owner

### 1.5 `ansible -m ping` ในนาม `deploy`

`-m ping` ไม่ใช่ ICMP — มัน SSH เข้าไปรัน Python ตอบ `pong` · inventory (`deploy/ansible/inventory/hosts.ini`) อ่านค่าจาก env:

| ตัวแปร | ไม่ตั้ง = | หมายเหตุ |
|---|---|---|
| `DEMO_SSH_HOST` | **`127.0.0.1`** 🔴 | ลืม = SSH เข้าเครื่องตัวเอง |
| `DEMO_SSH_USER` | `deploy` | owner ต้องใส่ `cloud` ตอน provision |
| `DEMO_SSH_KEY_PATH` | `~/.ssh/id_rsa` | Windows: `ans` ตั้งเป็น `/tmp/k` ให้เอง ใช้ `KEYFILE` แทน |

Mac (ใน `deploy/ansible/`):

```bash
DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=deploy DEMO_SSH_KEY_PATH="$DEPLOY_KEY" ansible demo -m ping
```

Windows (Git Bash ที่ root ของ repo):

```bash
REPO="$(pwd -W)" DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=deploy KEYFILE=deploy_ed25519 ans ansible demo -m ping
```

```text
vm-demo | SUCCESS =>
    changed: false
    ping: pong
```

✅ `SUCCESS` + `pong` · ❌ ดู §6.4 (`UNREACHABLE`, `Permission denied`, `Host key verification failed`)

---

## 2. Owner เท่านั้น

### 2.1 key ของ `cloud`

`~/.ssh/config` ของ owner:

```text
Host mob04-SriStore mob04
  HostName 172.30.58.20
  User cloud
  IdentityFile ~/.ssh/mob04-SriStore
```

```bash
ssh mob04 'hostname; id'
```

✅ group มี `sudo` · ping แบบ Ansible: เหมือน §1.5 แต่ `DEMO_SSH_USER=cloud` และ key `mob04-SriStore`

### 2.2 ไฟล์ secrets (`.env` ของ VM)

`/opt/pos/.env` = ค่าที่ `docker compose` บน VM ใช้แทน `${...}` (รหัส Postgres/Redis/etcd, JWT key, Grafana, Bull-Board ฯลฯ) ·
**`provision.yml` เป็นคนเขียน** (ไม่ใช่ `deploy.yml`) จาก env `DEMO_ENV_FILE` ของเครื่องที่รัน · mode `0600` เจ้าของ `deploy:deploy`

**ที่เก็บ:** `~/secrets/mob04-demo.env`

```bash
mkdir -p ~/secrets
```

```bash
chmod 700 ~/secrets
```

> สำเนาปัจจุบันของ owner อยู่ที่ `~/Downloads/mob04-demo.env` (ยังอยู่ตรงนั้น 2026-09-30 — `~/secrets` ยังไม่มี) — **ย้ายไป `~/secrets/`** (แล้ว `chmod 600`)

ทุกคำสั่งข้างล่างอ่านไฟล์ผ่าน **`SECRETS_FILE`** (ประกาศต่อหน้าต่าง terminal · ยังไม่ย้าย = ชี้ `~/Downloads/mob04-demo.env` แทน):

```bash
export SECRETS_FILE=~/secrets/mob04-demo.env
```

```bash
test -s "$SECRETS_FILE" && echo "secrets ok" || echo "STOP: ไม่มี $SECRETS_FILE"
```

🔴 ไฟล์ไม่มี = `$(cat ...)` ได้ค่าว่าง **เงียบ ๆ** → คำสั่ง provision ใน §2.5 จึงขึ้นต้นด้วย `test -s ... &&` ให้หยุดเองก่อนแตะ VM
> Windows: ห้ามเก็บในโฟลเดอร์ที่ OneDrive sync (Documents/Desktop มักถูก sync) และ `chmod` ไม่ป้องกันอะไรบน NTFS → ใช้ `icacls` แบบ §1.3

**กฎ:** ห้ามวางค่าลง chat/PR/commit/issue/log/screenshot · ห้ามเก็บใน repo · **ห้าม `--diff` กับ `provision.yml`** (พิมพ์ `.env` ทั้งไฟล์) ·
ห้ามมี `ALLOW_DEV_SECRETS`, `IMAGE_TAG`, ค่า `dev-only-*` · **ห้าม `export DEMO_ENV_FILE`** — ใส่นำหน้าคำสั่ง provision คำสั่งเดียว (§2.5)

**คีย์ไม่บังคับ `ALERT_DISCORD_WEBHOOK`** (Grafana alerting + Gatus → Discord, `07_CICD_DEPLOY.md §10.5`, 2026-10-13) — รูปแบบ `https://discord.com/api/webhooks/<id>/<token>` · **เป็นความลับ** (ใครมี URL ก็โพสต์เข้าช่องได้) · ไม่มีคีย์นี้ `provision.yml` แค่เตือน และ alert ทุกตัวยังประเมินปกติแต่ส่งไม่ถึงใคร · ใส่ใน `DEMO_ENV_FILE` ได้เลย แต่ **ทุกคีย์เดิมต้องอยู่ครบ** เพราะ `provision.yml` เขียนทับ `.env` ทั้งไฟล์ · 🔴 ก่อนเปิดใช้ ตรวจว่า VM ออกไป Discord ผ่าน FortiGate ได้: `curl -v https://discord.com/api/v10/gateway` (HTTP 200 และ issuer ของใบ **ไม่ใช่** FortiGate) · ~~`HEALTHCHECKS_PING_URL`~~ ปลดแล้ว 2026-10-13 — ลบออกจาก `DEMO_ENV_FILE` ได้

#### ตรวจไฟล์ — ดูแค่ชื่อคีย์

```bash
grep -oE '^[A-Z0-9_]+=' "$SECRETS_FILE" | sort
```

11 คีย์ที่ compose บังคับ (`:?`) ต้องมีและไม่ว่าง:

```bash
for k in POSTGRES_PASSWORD POS_APP_PASSWORD REDIS_PASSWORD JWT_PLATFORM_SECRET JWT_PRIVATE_KEY JWT_PUBLIC_KEYS BULL_BOARD_PASSWORD ETCD_ROOT_PASSWORD GRAFANA_ADMIN_PASSWORD K6_REMOTE_WRITE_BASIC_AUTH_USER K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD; do if grep -qE "^${k}=.+" "$SECRETS_FILE"; then echo "ok       $k"; else echo "MISSING  $k"; fi; done
```

ของต้องห้าม / CRLF — ทั้งสามต้องได้ `0`:

```bash
grep -cE '^(ALLOW_DEV_SECRETS|IMAGE_TAG)=' "$SECRETS_FILE"
```

```bash
grep -c 'dev-only-' "$SECRETS_FILE"
```

```bash
grep -c $'\r' "$SECRETS_FILE"
```

✅ ไม่มี `MISSING` และได้ `0` ทั้งสาม · (สำเนาของ owner ตรวจแล้ว 2026-09-28 แบบดูชื่อคีย์เท่านั้น: ครบ 11 คีย์ + `CORS_ORIGINS`, `PLATFORM_ADMINS` ไม่ว่าง,
ไม่มีของต้องห้าม — ไฟล์เปลี่ยนเมื่อไหร่ตรวจใหม่)
❌ 10 คีย์ `:?` ใน `server/docker-compose.yml` ที่ขาดทำให้ **ทุก** คำสั่ง `docker compose` บน VM ล้ม (`<KEY> is required`) ไม่ใช่แค่ service นั้น ·
`GRAFANA_ADMIN_PASSWORD` (`:?` เฉพาะใน `deploy/compose/monitoring.yml`) ขาด = POS ยัง deploy ได้ แต่บล็อก monitoring ล้มเป็น `WARNING` และ Grafana ไม่ขึ้น
(`provision.yml` ยังบังคับครบ 11 ตัว)

คีย์ที่ไม่ใช่ `:?` แต่มีผล: `CORS_ORIGINS` ต้องเป็น origin ที่เบราว์เซอร์ใช้เป๊ะ ๆ → `https://172.30.58.20` (§4.6) ·
`PLATFORM_ADMINS=user:password` รหัส ≥ 12 ตัว (ผิดรูป = api ไม่ boot) · `PLATFORM_ADMIN_IPS` ไม่ต้องใส่ (default `172.30.0.20`) ถ้าใส่ต้องมี `172.30.0.20` ·
🔴 **`CERT_SAN_IPS` ต้องไม่ตั้งบน `mob04`** — ไม่ตั้ง = SAN `172.30.58.20` แบบเดิมทุกไบต์ (ไม่ออกใบใหม่) · ตั้งแล้วไม่มี `172.30.58.20` = แอป Android ต่อไม่ได้ ·
คีย์นี้มีไว้สำหรับเครื่องที่ IP ต่างออกไป (Pi — `pi5-full-stack-tutorial.md` §5)

#### สร้างไฟล์ใหม่จากศูนย์ — **เฉพาะ VM ใหม่ที่ไม่มี volume** · 🔴 **ห้ามใช้กับ `mob04` เด็ดขาด**

🔴 บล็อกนี้เขียนลง **`NEW_SECRETS_FILE`** ไม่ใช่ `SECRETS_FILE` — `SECRETS_FILE` ข้างบนชี้ไฟล์จริงของ `mob04`; เขียนทับ = secret หาย →
provision รอบหน้าส่งรหัส Postgres/etcd ใหม่ที่ไม่ตรงกับที่ volume อบไว้ (§2.3) → production ล่ม

กฎ (`ticket-336-env-secrets.md` §2–3, `server/.env.example`): **hex เท่านั้น** (รหัสถูกแทนลงใน URL และ SQL literal — `/ + @ '` พัง) ·
`openssl rand -hex 24` ทั่วไป, `-hex 32` สำหรับ `JWT_PLATFORM_SECRET` · JWT = RSA 2048 PKCS#8 **อยู่ใน `"..."`**

```bash
export NEW_SECRETS_FILE=~/secrets/newvm-$(date +%Y%m%d).env
```

ด่าน — ต้องไม่มี output (มีไฟล์อยู่แล้ว = หยุด):

```bash
[ ! -e "$NEW_SECRETS_FILE" ] || echo "STOP: มีไฟล์อยู่แล้ว"; [ ! -e ~/secrets/jwt.key ] || echo "STOP: มี jwt.key ค้างอยู่"
```

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ~/secrets/jwt.key
```

```bash
openssl rsa -in ~/secrets/jwt.key -pubout -out ~/secrets/jwt.pub
```

`set -o noclobber` = มีไฟล์อยู่แล้ว `>` จะล้มแทนการเขียนทับ:

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
    echo "CORS_ORIGINS=https://172.30.58.20"
    echo "PLATFORM_ADMINS=admin:$(openssl rand -hex 12)"
    printf 'JWT_PRIVATE_KEY="%s"\n' "$(cat ~/secrets/jwt.key)"
    printf 'JWT_PUBLIC_KEYS="%s"\n' "$(cat ~/secrets/jwt.pub)"
  } > "$NEW_SECRETS_FILE" )
```

```bash
rm ~/secrets/jwt.key ~/secrets/jwt.pub
```

แล้วรันชุดตรวจข้างบนอีกรอบโดยแทน `"$SECRETS_FILE"` ด้วย `"$NEW_SECRETS_FILE"` · แก้ `CORS_ORIGINS` ให้เป็น IP ของ VM ใหม่ (และตั้ง `CERT_SAN_IPS` ถ้า IP ไม่ใช่ `172.30.58.20`)

### 2.3 กับดัก volume: secret บางตัวถูก "อบ" ตอน bootstrap ครั้งแรก

| volume | ค่าที่อบไว้ | เปลี่ยนใน `.env` แล้ว |
|---|---|---|
| `pgdata` | `POSTGRES_PASSWORD`, `POS_APP_PASSWORD` | `password authentication failed` ที่ migrate/api |
| `etcd-data` | `ETCD_ROOT_PASSWORD` | `etcd-init: FAILED — root cannot authenticate` / etcd ไม่ healthy |
| `nginx-auth` | `K6_REMOTE_WRITE_BASIC_AUTH_*` | ไม่เปลี่ยน (สร้างครั้งเดียว) |

เปลี่ยนรหัสใน `.env` **ไม่ re-key** volume เดิม · re-key เป็นการตัดสินใจของ owner แยกต่างหาก — เจออาการนี้ **หยุดแล้วบันทึก** ห้าม `down -v`

### 2.4 ติดตั้ง key ของสมาชิก (provision — ไม่เขียน .env แต่ติดตั้งสคริปต์ทั้ง 4 ตัว + ufw + cron ใหม่ทุกครั้ง)

`provision.yml` task `Configure SSH authorized key for deploy user` อ่าน public key จาก `DEMO_SSH_KEY_PUB` · `authorized_key state: present`
= **เพิ่มต่อท้าย ไม่ลบ key อื่น** · 🔴 ไม่ตั้ง `DEMO_SSH_KEY_PUB` = playbook หยิบ `~/.ssh/id_rsa.pub` ของเครื่องที่รันไปใส่ให้ `deploy` **เงียบ ๆ**
(ถ้ามีไฟล์นั้น) — ตั้งทุกครั้ง

`provision.yml` copy ops scripts จาก tree ที่รัน → รันจาก worktree สะอาดของ `origin/main` แบบเดียวกับ §3 ข้อ 4 · ใน `deploy/ansible/` ของ worktree นั้น:

ด่านกัน `.env` หลุดเข้ามา (ต้อง **ไม่มี output**):

```bash
[ -z "${DEMO_ENV_FILE:-}" ] || echo "STOP: unset DEMO_ENV_FILE"
```

Mac:

```bash
test -s ./member.pub && DEMO_SSH_KEY_PUB="$(cat ./member.pub)" DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=cloud DEMO_SSH_KEY_PATH="$HOME/.ssh/mob04-SriStore" ansible-playbook provision.yml
```

Windows:

```bash
test -s ./member.pub && DEMO_SSH_KEY_PUB="$(cat ./member.pub)" DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=cloud KEYFILE=mob04-SriStore ans ansible-playbook provision.yml
```

✅ `Configure SSH authorized key for deploy user` = `changed` (ใหม่) / `ok` (มีแล้ว) **และ** `Write server .env configuration (0600 mode)` = **`skipping`**
แล้วดู fingerprint ทั้งหมดของ `deploy`:

```bash
ssh mob04 'sudo -n ssh-keygen -lf /home/deploy/.ssh/authorized_keys'
```

ต้องเห็น comment ของสมาชิก · key ที่ไม่รู้จัก = owner ตัดสินลบเอง (playbook ไม่ลบให้)
❌ task `.env` ไม่ใช่ `skipping` → มี `DEMO_ENV_FILE` ค้างอยู่ → ไปตรวจ §2.5 ทันที

### 2.5 provision พร้อม `.env` (มี backup + hash gate)

🔴 **รันจาก `deploy/ansible/` ของ worktree สะอาดที่ `origin/main` เท่านั้น** (สร้างแบบ §3 ข้อ 4) — ทุกครั้งที่ provision (รวม §2.4) playbook ติดตั้ง
สคริปต์ ops 4 ตัว**จาก tree ที่รัน**ทับ `/opt/pos/scripts` + apt/ufw/cron ใหม่ · tree เก่าหรือมีไฟล์แก้ค้าง = ถอย `backup-db.sh` เงียบ ๆ
(เช่น backup ไม่มีรูปสินค้า/รูปหลักฐานอีกต่อไป) · หลัง provision ทุกครั้ง เทียบ (สองบรรทัดต้องเหมือนกัน):

```bash
sha256sum deploy/scripts/backup-db.sh
```

```bash
ssh mob04-deploy 'sha256sum /opt/pos/scripts/backup-db.sh'
```

(คำสั่งแรกรันที่ root ของ worktree)

**`host-setup.sh` (#713):** รัน **ก่อน** `provision.yml` บน **เครื่องใหม่** เท่านั้น · บน `mob04` มันตรวจเจอ `vm` = รายงานอย่างเดียวไม่เขียนอะไร (ยกเว้น `--tailscale`)
— ไม่ต้องรัน และ 🔴 ห้ามรัน `--tailscale` บน `mob04` (§1.2) · `provision.yml` ไม่ copy มันลง `/opt/pos/scripts` · รายละเอียด `07_CICD_DEPLOY.md` §6

`provision.yml` ทำตามลำดับ: apt ติด Docker Engine + compose plugin → UFW (deny incoming, allow 22/80/443) → user `deploy` (group `docker`) →
authorized key → `/opt/pos/...` → copy `backup-db.sh`, `restore-db.sh`, `measure-container-rss.sh` ลง `/opt/pos/scripts` (และลบ `healthcheck-ping.sh` ที่ปลดแล้ว) →
**ตรวจ `DEMO_ENV_FILE` (#506)** → **เขียน `/opt/pos/.env` 0600 (ข้ามถ้า `DEMO_ENV_FILE` ว่าง — มีข้อความเตือน)** → `/opt/pos/node-textfile` 0755 (gauge ความสดของ backup ให้ node-exporter) → `/opt/pos/backups` 0700 → cron 03:00 ของ `deploy` (backup) → ลบ cron heartbeat Healthchecks.io เดิม (ปลด 2026-10-13 — แทนด้วย Gatus + Grafana alerting, `07 §10.5`)

⚠️ **UFW ไม่ได้กรองพอร์ตที่ container publish** — Docker ใส่กฎใน nat table ก่อน UFW (docs.docker.com/engine/network/packet-filtering-firewalls/) ·
พอร์ตที่ต้องอยู่ในเครื่องต้อง bind `127.0.0.1:` ใน compose (แบบ 9090/3000/3100/3200 วันนี้) — ห้ามพึ่ง `ufw deny`

🔴 **heartbeat ติดตั้งบน `mob04` แล้ว 2026-10-04 (ด้วยมือ, `07 §7b`)** — CD deploy ไม่อัปเดตให้: แก้สคริปต์แล้วต้องรัน `provision.yml` (user `cloud`) ซ้ำ หรือติดตั้งด้วยมือ (`07_CICD_DEPLOY.md` §7b) · **อย่ากด *Ping now* ใน Healthchecks.io ก่อนมี cron**

ตั้งแต่ #506 ก่อนเขียน `.env` provision **ตรวจว่ามีบรรทัด `KEY=<ไม่ว่าง>` ครบทุกคีย์ที่ Compose บังคับ** (11 คีย์ใน §2.2 — ไม่รวม `IMAGE_TAG` ที่ `deploy.yml` ส่งเอง)
ขาดตัวไหน play **ล้มก่อนแตะ `.env`** พร้อมชื่อคีย์ (ไม่พิมพ์ค่า) · ไม่มี `PLATFORM_ADMINS` = แค่ **เตือน** (Compose ไม่บังคับ แต่ platform-ui จะไม่มี admin ให้ login) ·
task เขียน `.env` เป็น `no_log` + `diff: false` แล้ว — แต่ **ยังห้ามใส่ `--diff`** อยู่ดี

🔴 **provision ไม่ restart อะไรเลย** — container ยังใช้ `.env` เก่าจนกว่าจะรัน `deploy.yml` รอบถัดไป · ตั้งแต่ #506 `deploy.yml` เทียบ sha256 ของ `.env`
กับ `/opt/pos/.env_applied_sha256` (hash ของ `.env` ที่ deploy สำเร็จครั้งล่าสุดใช้) → ถ้าต่าง จะ **rollout SHA เดิมซ้ำเอง** ไม่ต้องใส่ `force_redeploy` (§3 ข้อ 6)

**① backup `.env` บน VM ก่อน:**

```bash
ssh mob04 'sudo -n cp -p --no-clobber /opt/pos/.env /opt/pos/.env.bak-$(date +%Y%m%dT%H%M%S)'
```

(ชื่อมีเวลาถึงวินาที + `--no-clobber` = provision สองรอบในวันเดียวไม่ทับ backup ของรอบแรก) · กู้คืน (owner ตัดสิน) แล้ว deploy ใหม่ (§6.3):

```bash
ssh mob04 'sudo -n install -o deploy -g deploy -m 0600 /opt/pos/.env.bak-<ts> /opt/pos/.env'
```

**② เทียบ hash — จะมีอะไรเปลี่ยนไหม** · `$(cat ...)` ตัด newline ท้ายไฟล์ทิ้ง แล้วตั้งแต่ #500 `provision.yml` **เติม newline ท้ายกลับหนึ่งตัว**
(`provision.yml` task `Write server .env configuration (0600 mode)`) → ฝั่ง local ต้องคำนวณแบบเดียวกันด้วย `printf '%s\n'`
(พิสูจน์แล้วด้วยไฟล์ dummy + `copy content:` expression เดียวกันบน localhost, ansible-core 2.21.4 — hash ตรงกัน; ยังไม่เคยเทียบกับไฟล์จริงบน VM):

```bash
printf '%s\n' "$(cat "$SECRETS_FILE")" | shasum -a 256
```

(Windows: `sha256sum` แทน `shasum -a 256`)

```bash
ssh mob04 'sudo -n sha256sum /opt/pos/.env'
```

✅ **hash เท่ากัน** → provision จะรายงาน `.env` เป็น `ok` = ปลอดภัย ไม่มี secret เปลี่ยน
⚠️ **ไม่เท่ากัน — เช็คกรณีเปลี่ยนผ่านครั้งเดียวก่อน:** ไฟล์ที่ provision **ก่อน #500** เขียน (รวมไฟล์บน `mob04` วันนี้) ไม่มี newline ท้าย ·
ลองสูตรเก่า:

```bash
printf '%s' "$(cat "$SECRETS_FILE")" | shasum -a 256
```

* สูตรเก่า **เท่ากับ** hash บน VM → secret เหมือนกันทุกตัว ต่างแค่ newline ท้าย → provision จะรายงาน `changed` **ครั้งเดียว** (เติม newline) = ปลอดภัย ·
  รอบถัดไปสูตรใหม่ต้องเท่ากันแล้ว
* 🛑 **ไม่เท่ากันทั้งสองสูตร** → provision จะ **เปลี่ยน secret บน VM** · ทำต่อเฉพาะเมื่อตั้งใจเปลี่ยนจริง และคีย์ที่เปลี่ยนไม่ใช่ตัวที่ volume อบไว้ (§2.3) —
  ถ้าไม่แน่ใจ **หยุด** (hash ต่างอาจแปลว่ามีคนแก้ไฟล์บน VM ด้วยมือ)

**③ dry-run `--check`** (Mac; Windows ใช้ `... KEYFILE=mob04-SriStore ans ansible-playbook provision.yml --check`) — **ห้ามใส่ `--diff`**:

`$DEPLOY_KEY.pub` = key ที่ provision ใส่ให้ `deploy` (§1.4) — owner วันนี้ = `~/.ssh/mob04-SriStore.pub` (ตรงกับ run จริง 2026-09-30,
`docs/handoff_log/session-2026-09-30-first-runner-deploy.md` ส่วน B) · `test -s ... &&` นำหน้า = ไฟล์ไหนไม่มี คำสั่งไม่รันเลย
(ไม่งั้น `DEMO_SSH_KEY_PUB` ว่าง → playbook หยิบ `~/.ssh/id_rsa.pub` ไปใส่ให้ `deploy` เงียบ ๆ ตาม §2.4 — บน Mac ของ owner ไฟล์นั้น **มีอยู่และไม่ใช่ key ของ deploy**)

```bash
test -s "$SECRETS_FILE" && test -s "$DEPLOY_KEY.pub" && DEMO_ENV_FILE="$(cat "$SECRETS_FILE")" DEMO_SSH_KEY_PUB="$(cat "$DEPLOY_KEY.pub")" DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=cloud DEMO_SSH_KEY_PATH="$HOME/.ssh/mob04-SriStore" ansible-playbook provision.yml --check
```

| task `Write server .env configuration (0600 mode)` | แปลว่า | ทำอะไร |
|---|---|---|
| `ok` | เนื้อหาเหมือนบน VM | ไปต่อได้ |
| `changed` | **secret บน VM จะถูกเขียนทับ** — ยกเว้นกรณีเปลี่ยนผ่านใน ② (สูตรเก่า `printf '%s'` เท่ากับ VM) ที่ต่างแค่ newline ท้าย | กรณีเปลี่ยนผ่าน: ไปต่อได้ (ครั้งเดียว) · นอกนั้น **STOP** เว้นแต่ตั้งใจเปลี่ยน secret (ตรงกับผล ②) |
| `skipping` | `DEMO_ENV_FILE` ไม่ถูกส่ง (มี task `Warn that .env is left untouched` ขึ้นเตือนด้วย) | แก้คำสั่ง |

task ตรวจคีย์ (`Check DEMO_ENV_FILE carries every key Compose requires`) รันใน `--check` ด้วย → ❌ `DEMO_ENV_FILE has no non-empty <KEY>= line` = แก้ไฟล์ secrets ก่อน ·
⚠️ `DEMO_ENV_FILE has no PLATFORM_ADMINS= line` = ไปต่อได้ แต่ platform-ui จะ login ไม่ได้ถ้าใน DB ยังไม่มี admin

**④ รันจริง** — คำสั่งเดียวกับ ③ ไม่มี `--check`:

```bash
test -s "$SECRETS_FILE" && test -s "$DEPLOY_KEY.pub" && DEMO_ENV_FILE="$(cat "$SECRETS_FILE")" DEMO_SSH_KEY_PUB="$(cat "$DEPLOY_KEY.pub")" DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=cloud DEMO_SSH_KEY_PATH="$HOME/.ssh/mob04-SriStore" ansible-playbook provision.yml
```

Windows:

```bash
test -s "$SECRETS_FILE" && test -s "$DEPLOY_KEY.pub" && DEMO_ENV_FILE="$(cat "$SECRETS_FILE")" DEMO_SSH_KEY_PUB="$(cat "$DEPLOY_KEY.pub")" DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=cloud KEYFILE=mob04-SriStore ans ansible-playbook provision.yml
```

`DEMO_ENV_FILE=...` นำหน้าคำสั่ง = มีผลแค่คำสั่งนี้ ไม่ค้างใน shell · shell history เก็บข้อความ `$(cat "$SECRETS_FILE")` ไม่ใช่ตัว secret — ใช้ได้ ·
Windows: `ans` ส่ง `-e DEMO_ENV_FILE` = `.env` ทั้งไฟล์อยู่ใน config ของ container (`docker inspect` เห็น) — ห้ามเปิด `docker inspect` / Docker Desktop
ดู container ของ ansible ระหว่าง provision (`--rm` ลบมันเมื่อจบ)

✅ recap `failed=0` · ❌ `UNREACHABLE` / อื่น ๆ → §6.4

**⑤ ตรวจบน VM** — owner (ในนาม `cloud`) ทุกคีย์ต้องได้ `1`:

```bash
ssh mob04 'for k in POSTGRES_PASSWORD POS_APP_PASSWORD REDIS_PASSWORD JWT_PLATFORM_SECRET JWT_PRIVATE_KEY JWT_PUBLIC_KEYS BULL_BOARD_PASSWORD ETCD_ROOT_PASSWORD GRAFANA_ADMIN_PASSWORD K6_REMOTE_WRITE_BASIC_AUTH_USER K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD CORS_ORIGINS PLATFORM_ADMINS; do printf "%s=%s\n" "$k" "$(sudo -n grep -c "^$k=" /opt/pos/.env)"; done; sudo -n stat -c "%A %U:%G %n" /opt/pos/.env'
```

```text
POSTGRES_PASSWORD=1
...
PLATFORM_ADMINS=1
-rw------- deploy:deploy /opt/pos/.env
```

(สมาชิกตรวจแบบเดียวกันได้โดยไม่ต้อง sudo — §3 ข้อ 7)

> ✅ **แก้แล้วใน #500:** `provision.yml` เติม newline ท้าย `/opt/pos/.env` ถ้ายังไม่มี (สูตร hash ใน ② จึงเป็น `printf '%s\n'`) ·
> เฉพาะไฟล์ที่ provision **ก่อน #500** เขียนและยังไม่ถูกเขียนใหม่: บรรทัดสุดท้ายไม่มี newline → ใคร append ด้วยมือต้องเติมบรรทัดว่างก่อน
> ไม่งั้นคีย์ใหม่ไปต่อท้ายบรรทัดสุดท้าย · ไม่ว่าไฟล์รุ่นไหน ตรวจด้วย `grep -c '^KEY='` เสมอ (`grep -c KEY` ไม่มี `^` ยังนับเจอคีย์ที่ติดท้ายบรรทัดอื่น
> แต่ Compose บอกว่าขาด)

---

## 3. deploy ด้วยมือ (ทางสำรอง — ใช้เมื่อ runner offline เท่านั้น)

> 🔴 **ทางหลัก = CD (§6.3):** merge เข้า `main` → owner approve run `Deploy (demo)` · ทางมือในหมวดนี้ **ไม่มี** ด่าน approve ของ environment `demo`,
> ไม่ถือช่อง concurrency `deploy-demo`, ไม่ผ่าน `flock` ของ `pos-deploy` และ **ไม่มี rollback อัตโนมัติ** → ใช้เฉพาะเมื่อ runner offline
> (`gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners -q '.runners[]|[.name,.status]|@tsv'` ไม่ใช่ `online`) **และ owner อนุญาต** ·
> ระหว่าง deploy ด้วยมือ owner ต้องไม่ approve run ใดเลย

ทุกข้อมี gate · gate ไหนไม่ผ่าน **หยุดที่ข้อนั้น** · คำสั่ง `git`/`gh` รันที่ root ของ repo หลัก (`gh` นอก git repo ต้องใส่ `-R NuimanLP/srisurart-pos-flutter`)

> ✅ **ผ่านแล้ว 2026-09-30:** deploy ครั้งแรกหลังปลดบล็อกเกิดจริงผ่าน runner (`e50f4fa`, ok=48 failed=0) บน `/opt/pos` ที่ว่าง — migration ทั้งหมดรันแล้ว,
> `etcd-init.sh` เป็นไฟล์ + etcd auth เปิดแล้ว (#365), `.current_sha` (ล่าสุดดูด้วย `cat /opt/pos/.current_sha` — อย่าเชื่อ SHA ในคู่มือ; 2026-10-13 = `5c7f210`, PR #714) · กล่องข้างล่างเก็บไว้เป็นประวัติ
>
> **(ประวัติ) deploy ครั้งแรกหลังปลดบล็อก (เฉพาะ `mob04`):** `.current_sha` ที่บันทึกล่าสุดคือ `8e873cd` (บันทึก 2026-09-21) — ห่างจาก `main`
> **500+ commit** (ณ 2026-09-29 · นับเองด้วย `git rev-list --count 8e873cd..origin/main`) และมี **ไฟล์ migration ใหม่ 11 ไฟล์** (+ `1788652800000-InitialSchema.ts`
> ถูกแก้) ที่ย้อนไม่ได้ (ไม่มี down-migration) · ดูรายการ: `git diff --name-status 8e873cd origin/main -- server/src/db/migrations` · เป็นครั้งแรกที่จะ: ซ่อม `etcd-init.sh` ที่เป็นไดเรกทอรี
> (`rmdir`) และเปิด auth ของ etcd, รัน migration `1788652804600` ที่ **บังคับ logout platform admin ทุกคนหนึ่งครั้ง** · ข้อ 8 (backup DB) จึงห้ามข้าม

**1. ประกาศ + เคลียร์คิว** — ทีละคนเท่านั้น · ประกาศในแชททีมว่า "กำลัง deploy `<sha>`" · owner ปฏิเสธ/ยกเลิก run `Deploy (demo)` ที่ค้าง/กำลังรันก่อน
(approve run เก่า = ส่ง SHA เก่าขึ้น · run ที่รันอยู่ = สอง deploy ชนกัน):

```bash
gh run list --workflow "Deploy (demo)" --json databaseId,status,headSha -q '.[] | select(.status=="in_progress" or .status=="queued" or .status=="pending" or .status=="waiting")'
```

✅ ไม่มี output (หรือ owner cancel แล้ว)

**2. เลือก SHA = head ของ `main`**

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

**3. CI เขียว + image ครบบน GHCR**

```bash
gh run list --commit "$TAG" --json workflowName,status,conclusion -q '.[] | [.workflowName,.status,.conclusion] | @tsv'
```

```text
Server CI	completed	success
Flutter CI	completed	success
```

(อาจมีแถว `Deploy (demo)` 1–2 แถวด้วย — ไม่ต้องสนใจ ดูแค่สองแถว CI)

```bash
bash deploy/scripts/verify-ghcr-tags.sh "$TAG" linux/amd64
```

```text
...
Both server and web images for tag '<sha>' are verified on GHCR for linux/amd64.
```

✅ ทั้งสอง CI `success` และสคริปต์ exit 0 · ❌ `in_progress` → รอ · `failure` → ห้ามใช้ SHA นี้ · สคริปต์ exit 1 = image ยังไม่ครบ (รอ CI) ·
exit 2 = ถาม GHCR ไม่ได้ (`Could not verify ...`) **หรือ** tag ไม่มี image `linux/amd64` (`was not built for linux/amd64`) — กรณีหลังรอไปก็ไม่ช่วย ·
release ก่อน `5c7f210` เป็น image เดี่ยว นับเป็น amd64 → ผ่าน (rollback ใช้ได้)
(สคริปต์รันจาก notebook — พิสูจน์ว่า image มี ไม่ได้พิสูจน์ว่า VM ดึงได้ นั่นคือข้อ 5)

**4. worktree สะอาดที่ `$TAG`** — `deploy.yml` copy ทุกไฟล์จาก tree ที่รัน (`repo_root = playbook_dir/../..`) ไม่ใช่จาก GHCR ·
ไฟล์ที่แก้ค้างในเครื่องคุณจะขึ้น VM ทันที จึงรันจาก worktree ใหม่เสมอ

```bash
test -z "$(git status --porcelain)" && echo "clean" || echo "STOP: working tree ไม่สะอาด"
```

```bash
git worktree add ../pos-deploy "$TAG"
```

(Windows: ใช้ `git -c core.autocrlf=false worktree add ../pos-deploy "$TAG"` — repo ไม่มี `.gitattributes` ถ้า autocrlf เปิด สคริปต์ `.sh` ที่ copy ขึ้น Linux จะติด CRLF)

Mac:

```bash
cd ../pos-deploy/deploy/ansible
```

Windows (ฟังก์ชัน `ans` อ่าน `REPO`):

```bash
export REPO="$(cd "$MAIN/../pos-deploy" && pwd -W)"
```

✅ `git -C "$MAIN/../pos-deploy" rev-parse HEAD` เท่ากับ `$TAG`

**5. 🛑 gate: VM ดึง image ของ `$TAG` จาก GHCR ได้จริง** — ข้อ 3 พิสูจน์จาก notebook ว่า image มี ข้อนี้พิสูจน์ว่า **VM** ดึงได้
(ผ่าน FortiGate ของคณะ) ด้วย `docker pull` จริงของ SHA เต็ม ไม่ใช่แค่ดูใบรับรอง · ดูดิสก์ก่อน (pull กินที่):

```bash
ssh mob04-deploy 'df -h /'
```

✅ เหลือหลาย GB · ❌ ดิสก์น้อย → แจ้ง owner ห้าม `prune --volumes` เอง

```bash
ssh mob04-deploy "docker pull ghcr.io/nuimanlp/srisurart-pos-server:$TAG" && echo "gate ok" || echo "STOP: VM ดึง image ไม่ได้"
```

```bash
ssh mob04-deploy "docker pull ghcr.io/nuimanlp/srisurart-pos-web:$TAG" && echo "gate web ok" || echo "STOP: VM ดึง image web ไม่ได้"
```

✅ `gate ok` และ `gate web ok` (ตรวจแล้ว 2026-09-29: `docker pull` SHA เต็มจาก `mob04` สำเร็จ และ TLS ไป `ghcr.io`, `registry-1.docker.io`, `gcr.io`,
`github.com`, `api.github.com`, `*.actions.githubusercontent.com` verify ผ่าน — ใบของ FortiGate มี SAN `*.ghcr.io`/`ghcr.io` แล้ว) ·
image ที่ดึงมาแล้วแค่อยู่ใน cache ให้ข้อ 9 ใช้ต่อ ไม่ได้เปลี่ยนอะไรที่รันอยู่
🛑 `STOP` → **จบตรงนี้** เก็บ output เป็นหลักฐาน (§5) · ถ้าเห็น `x509: certificate is not valid for any names` = FortiGate กลับมาตัดอีก (§6.4)

**6. สถานะ VM: ไปข้างหน้าเท่านั้น, network, ดิสก์**

```bash
export CURRENT="$(ssh mob04-deploy 'cat /opt/pos/.current_sha')"
```

```bash
git merge-base --is-ancestor "$CURRENT" "$TAG" && echo "forward ok" || echo "STOP: TAG ไม่ได้อยู่หลัง CURRENT"
```

✅ `forward ok` และ `$CURRENT` ≠ `$TAG` · 🛑 `STOP` → เป็น rollback หรือ SHA ผิด — rollback ต้องตั้งใจและทำตาม §6.2 เท่านั้น ·
`$CURRENT` = `$TAG` → VM รันอยู่แล้ว: ถ้า `.env` **ไม่ได้**เปลี่ยนตั้งแต่ deploy ครั้งล่าสุด `deploy.yml` จะจบพร้อมข้อความ `Skipping duplicate deployment` (ต้องการ rollout ซ้ำจริง ๆ ค่อยใส่ `-e force_redeploy=true` ในข้อ 9) ·
ถ้า **เพิ่ง provision `.env` ใหม่** (#506) `deploy.yml` จะ rollout SHA เดิมซ้ำเอง — เห็นข้อความ `... but /opt/pos/.env changed since the last deploy. Rolling it out again ...` ·
deploy ครั้งแรกหลัง #506 ยังไม่มี `/opt/pos/.env_applied_sha256` → นับว่าเปลี่ยน → rollout ซ้ำหนึ่งครั้งแม้ `.env` เหมือนเดิม (ตั้งใจ — rollout เกินหนึ่งรอบดีกว่าข้ามการเปลี่ยน secret) · บน `mob04` ไฟล์นี้มีแล้ว (2026-09-30)

```bash
ssh mob04-deploy 'docker network inspect srisurart-pos_default --format "{{json .IPAM.Config}}"'
```

```text
[{"Subnet":"172.30.0.0/24","IPRange":"172.30.0.128/25","Gateway":"172.30.0.1"}]
```

✅ มี `172.30.0.128/25` (หรือ `No such network` บน VM ใหม่) · ❌ ไม่มี `IPRange` → `deploy.yml` จะหยุดที่ assert
`Refuse to deploy onto a network created before ip_range was added` · ต้องทำ network recreate ครั้งเดียวตาม 07 §7 (owner) —
🔴 **ห้ามทำ "เผื่อไว้"** ถ้าผ่านอยู่แล้ว (POS ดับทั้งระบบโดยไม่ได้อะไร) ·
ถ้า `/opt/pos/.current_sha` **ไม่มี** (`$CURRENT` ว่าง = ยังไม่เคย deploy สำเร็จ) ก็ **ไม่มี release ให้ rollback กลับ** — ถ้า network เป็นรุ่นเก่า ให้ owner ตัดสินก่อน deploy ครั้งแรก

```bash
ssh mob04-deploy 'df -h /; docker ps --format "{{.Names}}|{{.Image}}|{{.Status}}"'
```

✅ ดิสก์ยังเหลือหลาย GB หลัง pull ข้อ 5 · เก็บรายการ container ไว้เป็นหลักฐาน "ก่อน" · ❌ ดิสก์น้อย → แจ้ง owner ห้าม `prune --volumes` เอง

**7. `.env` บน VM ครบ** — `deploy` เป็นเจ้าของไฟล์ `0600` จึงอ่านเองได้ไม่ต้อง sudo · พิมพ์แค่จำนวน:

```bash
ssh mob04-deploy 'for k in POSTGRES_PASSWORD POS_APP_PASSWORD REDIS_PASSWORD JWT_PLATFORM_SECRET JWT_PRIVATE_KEY JWT_PUBLIC_KEYS BULL_BOARD_PASSWORD ETCD_ROOT_PASSWORD GRAFANA_ADMIN_PASSWORD K6_REMOTE_WRITE_BASIC_AUTH_USER K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD; do printf "%s=%s\n" "$k" "$(grep -c "^$k=" /opt/pos/.env)"; done; stat -c "%A %U:%G %n" /opt/pos/.env'
```

✅ ทุกตัว `=1` และ `-rw------- deploy:deploy` · 🛑 มี `=0` → แจ้ง owner (§2.5) — 10 คีย์ของ `docker-compose.yml` ขาด = deploy ล้มที่คำสั่ง compose แรกด้วย `<KEY> is required` ·
`GRAFANA_ADMIN_PASSWORD` ขาด = POS ขึ้น แต่ monitoring เป็น `WARNING` และ Grafana ไม่ขึ้น

**8. backup ฐานข้อมูลก่อน deploy** — migration ย้อนไม่ได้ · `backup-db.sh` เรียก `docker compose` พร้อม `vm.override.yml` ซึ่งบังคับ `IMAGE_TAG`
🔴 **แก้แล้วใน `main` (#501):** `backup-db.sh`/`restore-db.sh` resolve `IMAGE_TAG` จาก `/opt/pos/.current_sha` เองถ้า `IMAGE_TAG` ว่าง —
**แต่ owner ต้องรัน `provision.yml` ใหม่ก่อน** (แบบ key-only §2.4 ก็พอ · บน `mob04` ทำแล้ว 2026-09-30 — `/opt/pos/scripts` + cron 03:00 ติดตั้งแล้ว; ก่อนหน้านั้น cron เรียกสคริปต์ที่ไม่มี — แก้ 2026-09-30 เย็น: เฉพาะรอบ 09-30 ที่ "not found"; รอบ 09-29 สคริปต์มีอยู่แต่ fail และทิ้ง .gz ว่าง 20 ไบต์) VM จึงจะได้สคริปต์เวอร์ชันนี้ (`provision.yml` copy สคริปต์ลง
`/opt/pos/scripts` เฉพาะตอน provision ไม่ auto-sync กับ release — CD ไม่อัปเดตสคริปต์บน VM · PR #519 `b089f36` (เขียน `.partial` แล้ว `mv`) ก็ต้องลงเองแบบนี้ (ลงบน `mob04` แล้ว 2026-09-30, sha256 ตรง `origin/main`): `sudo install -o deploy -g deploy -m 0755` จาก `origin/main` แล้วเทียบ sha256) หลังจากนั้นเรียกเฉย ๆ ได้:

```bash
ssh mob04-deploy '/opt/pos/scripts/backup-db.sh /opt/pos/backups && ls -lt /opt/pos/backups | head -8'
```

(ข้อนี้ใช้สคริปต์ **ที่อยู่บน VM แล้ว** · ถ้า release นี้ต้องการ `backup-db.sh` รุ่นใหม่ ลงมัน **หลัง** deploy ตาม §4.8 — ไม่ใช่ตรงนี้)

**เฉพาะ VM ที่สคริปต์ยังเป็นรุ่นก่อน #501** (ยังไม่ได้ provision ใหม่ — ไม่ใช่ `mob04` แล้ว): ต้องส่ง `IMAGE_TAG` เอง — ไม่ส่ง = compose ล้มเงียบ
แล้วสคริปต์เก่าไปจบที่ `::error::Neither active docker compose postgres container nor local pg_dump command found.`:

```bash
ssh mob04-deploy 'IMAGE_TAG=$(cat /opt/pos/.current_sha) /opt/pos/scripts/backup-db.sh /opt/pos/backups && ls -lt /opt/pos/backups | head -8'
```

ผลที่คาดหวัง (สคริปต์รุ่นปัจจุบัน เรียกเฉย ๆ · บรรทัดแรกไม่ขึ้นถ้าส่ง `IMAGE_TAG` เอง):

```text
IMAGE_TAG was unset; resolved from /opt/pos/.current_sha: <sha>
=== Srisurart POS Database Backup ===
...
  -> Backup created successfully (<size>).
Archiving product images (docker)...
  -> product images archived (<size>).
Archiving sale photos (docker)...
  -> sale photos archived (<size>).
::warning::Offsite upload is disabled (BACKUP_RCLONE_REMOTE is not set) — this backup stays on this VM only. ...
...
=== Backup Complete (local only -- offsite upload not configured, see the warning above) ===
```

สามไฟล์ต่อรอบ (ชื่อขึ้นต้นด้วย `pos_` = ชื่อฐานข้อมูล, `<ts>` = `YYYYmmdd_HHMMSSZ` เดียวกัน, แต่ละไฟล์มี `.sha256` คู่):

| ไฟล์ | มาจาก | ถ้าไม่มี |
|---|---|---|
| `pos_backup_<ts>.sql.gz` | `pg_dump` | สคริปต์ล้ม |
| `pos_images_<ts>.tar.gz` (PR #680) | volume `product-images` ผ่าน mount `:ro` ของ `nginx` — รูปไม่อยู่ใน `pg_dump` | ไม่มี volume → `::warning::No product-images volume to archive ...` + exit 0 (**ไม่มีรูปใน backup นั้น**) · เก็บแล้วพัง → `::error::PRODUCT IMAGES ARCHIVE FAILED ...` + exit ≠ 0 |
| `pos_sale_photos_<ts>.tar.gz` (PR #698/#699) | volume `sale-photos` **ผ่าน container `worker`** (`docker compose exec -T worker tar -cf - -C /app/sale-photos .` — nginx ไม่ mount: รูปหลักฐานเป็นส่วนตัว) | ไม่มี `worker`/volume → `::warning::No sale-photos volume to archive ...` + exit 0 · `worker` มีแต่ `exec … test -d /app/sale-photos` ล้ม → `::error::SALE PHOTOS ARCHIVE FAILED ...` + exit ≠ 0 |

กฎ `.partial` / prune / offsite เดียวกันทั้งสามไฟล์ · `restore-db.sh` **ยังไม่กู้รูป** — ต้องแตก `pos_images_*` / `pos_sale_photos_*` ลง volume เอง (ยังไม่มีขั้นตอนที่พิสูจน์แล้ว)

ตรวจความครบ (แทน `<ts>` ด้วยเวลาของไฟล์บนสุดใน `ls`):

```bash
ssh mob04-deploy 'cd /opt/pos/backups && for f in $(ls -t *_<ts>.*gz); do gzip -t "$f" && sha256sum -c "$f.sha256"; done'
```

✅ สามบรรทัด `pos_backup_<ts>.sql.gz: OK`, `pos_images_<ts>.tar.gz: OK`, `pos_sale_photos_<ts>.tar.gz: OK` → **จดชื่อไฟล์** ·
บรรทัด `::warning::` เรื่อง offsite เป็นเรื่องปกติ (สคริปต์ exit 0) — 🔴 backup ทั้งหมดนี้อยู่บนดิสก์ VM ใบเดียวกันเท่านั้น
❌ `No such file` → ยังไม่มี `/opt/pos/scripts` ให้ owner รัน provision (§2.4)
❌ `::error::IMAGE_TAG is required by deploy/compose/vm.override.yml but is unset, and /opt/pos/.current_sha is missing or empty. ...`
→ VM ไม่มี `.current_sha` (ยังไม่เคย deploy สำเร็จ) · หยุด ถาม owner
❌ `::error::docker compose could not resolve the compose configuration (...)` ตามด้วยข้อความของ compose → อ่านบรรทัดถัดไป
(เช่น `<KEY> is required` = `.env` ขาดคีย์ ข้อ 7)
❌ error อื่น / ไฟล์ไม่ครบสาม / `FAILED` จาก `sha256sum -c` → หยุด ห้าม deploy โดยไม่มี backup

**9. deploy** (ห้ามทำถ้าข้อ 5 เป็น STOP)

Mac (ใน `../pos-deploy/deploy/ansible`):

```bash
test -s "$DEPLOY_KEY" && DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=deploy DEMO_SSH_KEY_PATH="$DEPLOY_KEY" ansible-playbook deploy.yml -e image_tag="$TAG" </dev/null
```

Windows:

```bash
DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=deploy KEYFILE=deploy_ed25519 ans ansible-playbook deploy.yml -e image_tag="$TAG"
```

* ใช้เวลา ~10–20 นาทีครั้งแรก · ช่วง `pull` เงียบนานเป็นปกติ
* `FAILED - RETRYING: [vm-demo]: Wait for api-1 health check to pass (25 retries left).` ซ้ำหลายรอบ = ปกติระหว่าง api boot
* ลำดับ task ทั้งหมด: §6.1
* `</dev/null` ท้ายคำสั่ง Mac: ถ้าไม่ใส่ ansible-core อาจปฏิเสธ stdio แบบ non-blocking (§6.4) — วัดจริงตอน rollback 2026-09-30 (#343) ·
  `</dev/null` แก้แค่ stdin — ถ้า error ชี้ `<stdout>`/`<stderr>` ให้ต่อท้าย `</dev/null 2>&1 | cat` (§6.4)

✅ recap `failed=0` + `Successfully deployed release '<sha>' to vm-demo.` — **ยังไม่ใช่หลักฐาน** ไปข้อ 10
❌ จดชื่อ task ที่ล้ม → §6.4 · ถ้าล้มหลัง rolling restart เริ่มแล้ว VM อาจรัน api สองเวอร์ชันปนกัน → แก้แล้วรันคำสั่งเดิม, rollback (§6.2)
หรือ **ให้ runner ทำต่อผ่าน dispatch (§6.3)** — ไม่ต้องพึ่ง VPN ของ notebook
❌ `UNREACHABLE` กลางทาง (VPN หลุด) → VM ค้างครึ่งทาง · เกิดจริง 2026-09-30: หลุดที่ `Wait for api-3 health check` (ok=29) แล้ว **กู้ด้วย dispatch `Deploy (demo)` SHA เดิม**
(run [36686729879](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36686729879), `failed=0`) · `.current_sha` ยังเป็น SHA เก่า จึงไม่ติด early exit

**10. ตรวจผล** — §4 ทุกข้อ

**11. แปะหลักฐาน** — §5 ใน #344 หรือ issue ของ release นั้น (#343 ปิดแล้ว 2026-09-30)

**12. เก็บกวาด + ประกาศจบ**

```bash
git -C "$MAIN" worktree remove ../pos-deploy
```

แล้วประกาศในแชททีม: SHA ที่ขึ้น, ผล §4, ชื่อไฟล์ backup

---

## 4. ตรวจผลหลัง deploy

ทุกข้อเป็นการ tick แยก

**4.1 `.current_sha` = `$TAG`** — หลักฐานเดียวว่า release ถึง VM (task นี้เขียนหลัง readiness ผ่านเท่านั้น):

```bash
ssh mob04-deploy 'cat /opt/pos/.current_sha'
```

**4.2 `/health/ready` ผ่าน Nginx = 200:**

```bash
ssh mob04-deploy 'curl -sk -o /dev/null -w "health_ready=%{http_code}\n" https://127.0.0.1/health/ready'
```

⚠️ endpoint นี้ไม่แตะ etcd → ต้องทำ 4.4 ด้วย

**4.3 api/worker/bull-board รัน image ของ `$TAG`:**

```bash
ssh mob04-deploy 'docker ps --format "{{.Names}}|{{.Image}}|{{.Status}}" | grep -E "api-|worker|bull-board"'
```

✅ ทุกแถวเป็น `ghcr.io/nuimanlp/srisurart-pos-server:<TAG>` และ api เป็น `(healthy)`

**4.3b หน้าเว็บที่เสิร์ฟเป็นของ `$TAG`** — `web-sync` เป็น container `--rm` จึงไม่โผล่ใน `docker ps` · ดูชื่อ entry point ที่ `flutter_bootstrap.js`
ชี้ไป (CI ตั้งชื่อเป็น `main.<12 ตัวแรกของ SHA>.dart.js`):

```bash
ssh mob04-deploy 'curl -sk https://127.0.0.1/flutter_bootstrap.js | grep -o "main\.[0-9a-z]*\.dart\.js"'
```

ชื่อที่ต้องได้ (รันบน notebook):

```bash
echo "main.${TAG:0:12}.dart.js"
```

✅ สองบรรทัดตรงกันทุกตัวอักษร · ❌ ไม่ตรง = volume `web` ยังเป็น release อื่น (web-sync ไม่ได้รัน/ล้ม) · ❌ ว่าง = ได้ `main.dart.js` แบบไม่มีเลข
(image เก่ากว่า #502) หรือ Nginx ไม่ตอบ → จด output แจ้ง owner

**4.4 etcd เปิด auth** — `etcd-init.sh` ต้องเป็น **ไฟล์** `-rwxr-xr-x deploy` ไม่ใช่ไดเรกทอรีของ root:

```bash
ssh mob04-deploy 'ls -la /opt/pos/docker/etcd'
```

อ่านแบบไม่มีรหัสจาก container ใหม่ (สิ่งเดียวกับที่ playbook assert):

```bash
ssh mob04-deploy 'cd /opt/pos && IMAGE_TAG=$(cat .current_sha) docker compose -f docker-compose.yml -f vm.override.yml run --rm --no-deps --entrypoint curl etcd-init -sS -w "\nhttp=%{http_code}\n" -X POST http://etcd:2379/v3/kv/range -d "{\"key\":\"Lw==\"}"'
```

✅ `http=400` (playbook assert เฉพาะ 400 · body ควรเป็น `user name is empty` ตาม comment ใน `deploy.yml` ที่วัดกับ etcd v3.6.12)
❌ `http=200` = auth ปิด → แจ้ง owner (#365) · #365 ต้องพิสูจน์ **สองทาง** (มีรหัส = สำเร็จ ด้วย) ข้อนี้พิสูจน์แค่ครึ่งเดียว

**4.5 monitoring — ตรวจแยก** (บล็อก monitoring ใน playbook ล้มแค่พิมพ์ `WARNING`):

```bash
ssh mob04-deploy 'curl -s -o /dev/null -w "prometheus=%{http_code}\n" http://127.0.0.1:9090/-/healthy; curl -s -o /dev/null -w "grafana=%{http_code}\n" http://127.0.0.1:3000/api/health'
```

✅ ทั้งคู่ `200` · ดูด้วยตาผ่าน SSH tunnel (เปิดค้างไว้หน้าต่างหนึ่ง):

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 3100:127.0.0.1:3100 -L 3200:127.0.0.1:3200 -L 3300:127.0.0.1:3300 mob04-deploy
```

| URL บน notebook | คือ | login |
|---|---|---|
| `http://localhost:3000` | Grafana — dashboard *POS Overview* ต้องมีกราฟ | `GRAFANA_ADMIN_USER`/`_PASSWORD` (owner) |
| `http://localhost:9090` | Prometheus | — |
| `http://localhost:3100` | Bull-Board | `BULL_BOARD_USER`/`_PASSWORD` (owner) |
| `http://localhost:3200` | platform-ui | platform admin (หลัง migration `1788652804600` ทุกคนต้อง login ใหม่ — ปกติ) |
| `http://localhost:3300` | Gatus — uptime ของทุก service (ต้องเขียวหลัง ~3 นาที) · Grafana → Alerting → Alert rules ต้องเห็น 10 rule ไม่มี `Error` (§10.5 ของ 07) | — (ผูก loopback เท่านั้น) |

**4.6 แอปจริงในเบราว์เซอร์** — เปิด `https://172.30.58.20` (ในเครือข่ายคณะ, ต่อ VPN, หรือ Tailscale ที่ login เข้า tailnet ของร้าน — §1.2; ไม่ต้อง build APK ใหม่ เพราะที่อยู่/SAN เดิม) · คำเตือนใบรับรองบนเบราว์เซอร์เป็นเรื่อง **ปกติ** (`certgen` ออกใบจาก CA ส่วนตัวของ VM ซึ่งเบราว์เซอร์ไม่รู้จัก · แอป Android ฝัง `ca.crt` แล้วต่อได้ — ขั้นตอนครั้งเดียวของ owner: `07_CICD_DEPLOY.md` §5 "TLS") · `http://` redirect ไป `https://`

✅ หน้า login ขึ้น และ login/ขายทดสอบได้
❌ หน้าโหลดได้แต่ทุก POST ล้ม → `CORS_ORIGINS`: `Origin` ที่ไม่อยู่ในรายการ API ยังตอบ แต่ไม่ส่ง header `Access-Control-Allow-Origin` (`server/src/app.setup.ts`, #516) → เบราว์เซอร์บล็อกคำตอบ; เบราว์เซอร์ส่ง `Origin` กับ POST
แม้ origin เดียวกัน · ตรวจแบบไม่พิมพ์ค่า (ต้องได้ `1`):

```bash
ssh mob04-deploy 'grep -c "^CORS_ORIGINS=.*https://172\.30\.58\.20" /opt/pos/.env'
```

🔴 ห้ามเขียนว่า "ปิด CORS บน VM แล้ว" จนกว่า 4.1 และข้อนี้จะผ่านทั้งคู่

> 2026-09-30: `Origin` แปลกหน้าเคยได้ HTTP 500 — แก้แล้ว PR #516 (`00d3488`, run `36717963989`) ตอนนี้ได้สถานะปกติของ route (เช่น `/health/live` 200 — ไม่ใช่ 500) ไม่มี `Access-Control-Allow-Origin` · origin ตัวเอง `https://172.30.58.20` ได้ ACAO

**4.7 รูปสินค้า (เมื่อ release มี PR #680)** — volume, Nginx `/img/` และ header:

```bash
# volume ถูกสร้างแล้ว (ชื่อมี prefix ของ compose project)
ssh mob04-deploy 'docker volume inspect srisurart-pos_product-images --format "{{.Name}} {{.Mountpoint}}"'
# api/worker เขียนได้ (rw) และ nginx อ่านได้อย่างเดียว (ro)
ssh mob04-deploy 'docker inspect srisurart-pos-api-1-1 --format "{{range .Mounts}}{{.Destination}} rw={{.RW}}{{println}}{{end}}" | grep product-images'
ssh mob04-deploy 'docker inspect srisurart-pos-nginx-1 --format "{{range .Mounts}}{{.Destination}} rw={{.RW}}{{println}}{{end}}" | grep product-images'
# ไฟล์ที่ไม่มี = 404 ธรรมดา (ไม่มี Cache-Control ยาว) — ใช้ UUID/คีย์ปลอมที่รูปแบบถูกต้อง
ssh mob04-deploy 'curl -sk -D - -o /dev/null https://127.0.0.1/img/00000000-0000-0000-0000-000000000000/00000000000000000000000000000000_t.webp'
```

✅ บรรทัดที่สองเห็น `/app/product-images rw=true` · บรรทัดที่สามเห็น `/srv/product-images rw=false` · คำสั่ง `curl` ได้ `HTTP/2 404` และ**ไม่มี** `cache-control: ...immutable`
(nginx เปิด `http2 on` → curl พิมพ์ `HTTP/2` และชื่อ header เป็นตัวพิมพ์เล็ก)
หลังเจ้าของอัปโหลดรูปจริงหนึ่งรูป (เมนู สินค้า/สต็อก → แก้ไข → เลือกรูป) ให้ลองดึงรูปนั้น — URL คือ `https://172.30.58.20/img/<tenantId>/<imageKey>_t.webp`
(`tenantId` = UUID ของร้าน, `imageKey` = 32 ตัวอักษร hex ที่ `GET /api/v1/products` ส่งมาในช่อง `imageKey`):

```bash
ssh mob04-deploy 'curl -sk -D - -o /dev/null https://127.0.0.1/img/<tenantId>/<imageKey>_t.webp | grep -iE "^HTTP|cache-control|content-type|x-content-type"'
```

✅ `HTTP/2 200` · `content-type: image/webp` · `cache-control: public, max-age=31536000, immutable` · `x-content-type-options: nosniff`
❌ ได้ 404 ทั้งที่แอปแสดงรูป → ชื่อ volume ของ api กับ nginx ไม่ตรงกัน หรือ nginx ยังไม่ถูก recreate (deploy task 13 ทำทุกครั้ง) · ❌ `/img/` ได้หน้า SPA แทน 404 → `nginx.conf` บน VM เป็นรุ่นเก่า
ไม่มี login ที่ `/img/` โดยออกแบบ (URL = UUID ของร้าน + แฮช 128 บิต เดาไม่ได้) · รูปไม่ผ่าน `pg_dump` จึงต้องดู `pos_images_*.tar.gz` ใน §3 ข้อ 8

**4.7b รูปหลักฐานตอนขาย (เมื่อ release มี PR #698)** — volume `sale-photos` ต้องมีที่ api และ worker แต่ **ไม่มีที่ nginx**:

```bash
ssh mob04-deploy 'docker volume ls | grep sale-photos'
ssh mob04-deploy 'docker inspect srisurart-pos-api-1-1 --format "{{range .Mounts}}{{.Destination}} rw={{.RW}}{{println}}{{end}}" | grep sale-photos'
ssh mob04-deploy 'docker inspect srisurart-pos-worker-1 --format "{{range .Mounts}}{{.Destination}} rw={{.RW}}{{println}}{{end}}" | grep sale-photos'
# nginx ต้องไม่มี mount นี้ — ผลลัพธ์ต้องว่าง
ssh mob04-deploy 'docker inspect srisurart-pos-nginx-1 --format "{{range .Mounts}}{{.Destination}}{{println}}{{end}}" | grep sale-photos || echo "nginx: no sale-photos mount (ถูกต้อง)"'
```

✅ api/worker เห็น `/app/sale-photos rw=true` · nginx เห็นข้อความ `nginx: no sale-photos mount` · ❌ nginx มี mount นี้ = ผิดดีไซน์ (รูปหลักฐานต้องเข้าได้ผ่าน API ที่ล็อกอินเท่านั้น) รายงาน owner
ไม่มี login ที่ `/img/` สำหรับรูปสินค้า แต่รูปหลักฐานอยู่นอก `/img/` เสมอ — `/img/<tenantId>/<key>_t.webp` ของ key รูปหลักฐานต้องได้ 404 · ชื่อ container ขึ้นกับชื่อ compose project บน VM (ปรับตามที่ `docker ps` แสดง)

**ขนาดไฟล์ที่ import ได้:** ตอนนี้ import backup รับ `.zip` ได้ถึง **200 MB** (และ `.json` เดิม 10 MB) — Nginx ยก `client_max_body_size 200m` **เฉพาะ** `POST /api/v1/backup/import`
และ `POST /api/v1/platform/tenants/<uuid>/import` (path อื่นยัง 10 MB) และไม่ buffer body ที่ Nginx (`proxy_request_buffering off`) — ถ้า import ใหญ่ ๆ ได้ `413`
ที่ path อื่นนอกสองตัวนี้ คือพฤติกรรมที่ถูกต้อง

**4.8 ลง `backup-db.sh` รุ่นใหม่บน VM (เฉพาะ release ที่เปลี่ยนสคริปต์ — ทำหลัง 4.1–4.7b ผ่าน)**

🔴 **CD deploy ไม่อัปเดต `/opt/pos/scripts`** (เฉพาะ `provision.yml` §2.5 หรือติดตั้งด้วยมือแบบข้างล่าง) — สคริปต์เก่ากว่า PR #680 ทำ backup
**ไม่มีรูปและไม่มีข้อความเตือนใดเลย** · 🔴 **ลำดับ: ลง "หลัง" deploy ที่ส่ง `worker` รุ่นที่มี `/app/sale-photos` ขึ้นไปแล้วเท่านั้น** — ลงก่อน = compose เห็น `worker`
แต่ `exec … test -d /app/sale-photos` ล้ม → `::error::SALE PHOTOS ARCHIVE FAILED ...` + exit ≠ 0 **ทุกคืน** (dump ยังอยู่)

ตรวจก่อนว่า volume ถูกสร้างและ worker mount แล้ว:

```bash
ssh mob04-deploy 'docker volume ls | grep sale-photos'
```

✅ เห็น `srisurart-pos_sale-photos` · ❌ ไม่เห็น = deploy ของ release นี้ยังไม่ถึง → **ห้ามลงสคริปต์**

ลง (owner — ใน root ของ worktree สะอาดที่ `$TAG` จาก §3 ข้อ 4) · สำเนาเก่าตั้งชื่อตาม release ที่รันอยู่:

```bash
scp deploy/scripts/backup-db.sh mob04:/tmp/backup-db.sh
```

```bash
ssh mob04 'sudo cp -a /opt/pos/scripts/backup-db.sh "/opt/pos/scripts/.backup-db.sh.prev-$(sudo cut -c1-7 /opt/pos/.current_sha)" && sudo install -o deploy -g deploy -m 0755 /tmp/backup-db.sh /opt/pos/scripts/backup-db.sh && rm -f /tmp/backup-db.sh'
```

(owner/group ต้องเป็น `deploy` เพราะ cron รันเป็น `deploy`) · เทียบ sha256 กับต้นฉบับ (สองบรรทัดต้องเหมือนกัน):

```bash
sha256sum deploy/scripts/backup-db.sh
```

```bash
ssh mob04-deploy 'sha256sum /opt/pos/scripts/backup-db.sh'
```

แล้วรันหนึ่งครั้งและตรวจความครบแบบ §3 ข้อ 8 (`head -8` + ลูป `gzip -t` / `sha256sum -c`) — ต้องได้ครบสามไฟล์
ลงผิดลำดับแล้ว cron ล้ม: ถอยด้วยสำเนา `.backup-db.sh.prev-*` หรือ deploy ให้เสร็จก่อนแล้วรันซ้ำ — ไม่ต้องแก้ข้อมูล

ประวัติ: ลำดับนี้รันจริงบน `mob04` 2026-09-30 (PR #519), 2026-10-10 หลัง deploy `e77356f` (sha256 `e2fc4c39…`, สำเนาเก่า `.backup-db.sh.prev-ef07e27`,
รันในสภาพ cron — `env -i`, cwd `/home/deploy`, เป็น `deploy` — ได้ dump + `pos_images_…` ผ่าน `gzip -t` + sha256) และ 2026-10-12
(sha256 `e70debda…`, สำเนาเก่า `.backup-db.sh.prev-ec31121`) · user `cloud` อ่าน `/opt/pos/backups` ไม่ได้ — ใช้ `sudo -u deploy` หรือ `ssh mob04-deploy`

---

## 5. หลักฐานที่แปะใน ticket (#344 หรือ issue ของ release นั้น)

**pre-flight (ข้อ 1–8):**

```text
วันที่ / ผู้ทำ:
TAG (origin/main):            <40-hex>
CI (gh run list --commit):    Server CI success · Flutter CI success
verify-ghcr-tags.sh:          "Both server and web images ... verified on GHCR for linux/amd64."
ansible -m ping (deploy):     SUCCESS / pong
docker pull gate (ข้อ 5):       ...srisurart-pos-server:<TAG> → gate ok
.current_sha ก่อน:            <sha>
network IPAM:                 [...IPRange 172.30.0.128/25...]
.env key counts (ข้อ 7):       ทุกคีย์ =1, -rw------- deploy:deploy
```

**หลัง deploy:** ทุกบรรทัดข้างบน และเพิ่ม:

```text
backup ก่อน deploy:           /opt/pos/backups/pos_backup_<ts>.sql.gz + pos_images_<ts>.tar.gz + pos_sale_photos_<ts>.tar.gz (sha256 OK)
คำสั่ง deploy:                ansible-playbook deploy.yml -e image_tag=<TAG>  (จาก worktree ที่ <TAG>)
PLAY RECAP:                   (แปะ แต่ไม่นับเป็นหลักฐานเดี่ยว)
.current_sha หลัง:            <TAG>                         ← ต้องเท่ากัน
health_ready:                 200
api/worker/bull-board image:  ...srisurart-pos-server:<TAG> (healthy)
web entry point (4.3b):       main.<TAG 12 ตัวแรก>.dart.js
etcd-init.sh:                 ไฟล์ -rwxr-xr-x deploy ; anonymous read http=400
prometheus / grafana:         200 / 200 ; POS Overview มีกราฟ
เบราว์เซอร์:                   https://172.30.58.20 login + ขายทดสอบได้
```

**ไม่นับเป็นหลักฐาน:** PLAY RECAP เขียวอย่างเดียว · `ansible-playbook --check` · run สีเขียวของ `Deploy (demo)` (อาจมีแค่ `resolve release` ที่รัน) ·
`docker load` ด้วยมือ

---

## 6. Reference

### 6.1 `deploy.yml` ทำอะไรทีละ task (ตามโค้ดใน `origin/main` @ `5c7f210` · 2026-10-13 — รันครบจริงบน `mob04` ครั้งแรก 2026-09-30: runner `ok=48 failed=0`)

| # | task (ชื่อที่เห็นใน output) | ทำอะไร |
|---|---|---|
| 1 | `Validate image_tag parameter` | ต้องมี `image_tag` |
| 2 | `Check currently deployed SHA on VM` → `Checksum the VM's .env` → `Decide whether .env changed since the last deploy` → `Early exit on duplicate release deployment` | `.current_sha` = tag, ไม่มี `force_redeploy` **และ** sha256 ของ `.env` = `/opt/pos/.env_applied_sha256` → จบ play พร้อมข้อความ `Skipping duplicate deployment` · `.env` เปลี่ยน (หรือยังไม่มีไฟล์ marker) → rollout SHA เดิมต่อ (#506) |
| 3 | `Inspect the existing compose network` → `Refuse to deploy onto a network created before ip_range was added` | กัน network รุ่นเก่า (ยังไม่แตะอะไร) |
| 4 | `Copy docker-compose base configuration` … `Copy Postgres initialization scripts` | copy compose, `vm.override.yml`, สร้าง `docker/nginx` (#508), `nginx.conf`, platform-ui conf+html, postgres init **จาก tree ของคุณ** |
| 5 | `Check for the etcd-init.sh directory ...` → `Remove the Docker-created etcd-init.sh directory ...` → `Copy etcd-init bootstrap script` → `Ensure the certgen directory exists` → `Copy certgen script` | ซ่อมบั๊ก `etcd-init.sh` เป็นไดเรกทอรีของ root (`rmdir` ผ่าน container root — มีของข้างใน = ล้มดัง ๆ) · copy `certgen.sh` |
| 6 | `Pull release images from GHCR` | ถ้าล้มตรงนี้ ข้อ 4–5 (รวม `certgen.sh`) เกิดไปแล้ว (เคยล้มเพราะ FortiGate จนถึง 2026-09-28 — กันด้วย gate §3 ข้อ 5) |
| 6b | `Check whether database migrations are pending (new image)` → `Back up the database before applying migrations` | `migrate.js status` ด้วย image ใหม่ · มี migration ค้าง (หรือเช็คล้ม) = dump DB อย่างเดียวลง `/opt/pos/backups-pre-migrate/` (30 วัน) ก่อน `migrate` · ไม่มีค้าง = task backup ขึ้น `skipping` (ปกติ) · dump ล้ม = deploy ล้มก่อนแตะ schema · dump นี้คือทางย้อนเดียวของ migration (07 §7 "กู้ฐานข้อมูลหลัง migration เสีย" — เจ้าของตัดสิน, ข้อมูลหลัง dump หาย) |
| 7 | `Apply database schema migrations (schema before code)` | `run --rm migrate` (ย้อนไม่ได้) |
| 8 | `Issue the TLS certificate (certgen)` → `Ensure backing datastores, htpasswd-gen and etcd are running` | `run --rm --no-deps certgen` (ล้ม = deploy ล้ม) แล้ว `up -d postgres redis-cache redis-queue htpasswd-gen etcd` |
| 9 | `Bootstrap etcd auth ... (etcd-init)` → `Assert etcd refuses an unauthenticated read` | เปิด auth แล้ว assert HTTP 400 |
| 10 | `Restart instance api-1` → `Wait for api-1 health check to pass` → api-2 → api-3 | rolling ทีละตัว รอ healthy ≤ 25×3 วิ |
| 11 | `Restart worker and bull-board` | |
| 12 | `Populate shared web volume from web image (web-sync)` | หลัง API ทุกตัว · copy เป็นชื่อชั่วคราวแล้ว `mv` ทับ, `flutter_bootstrap.js` → `sw.js` → `index.html` ท้ายสุด, แล้วลบไฟล์เก่า — ยกเว้น `main.<sha12>.dart.js` (12 ตัวแรกของ SHA, ตั้งชื่อโดย `deploy/version-web-build.sh` ใน Flutter CI) ของ release ก่อนหน้า (เก็บไว้หนึ่ง release ให้ page load ที่คร่อมการสลับ) · release แรกที่มีชื่อแบบนี้ **ไม่เก็บ** `main.dart.js` เดิม (ชื่อไม่มีเลข release) (`vm.override.yml`) |
| 13 | `Validate the copied Nginx configuration` → `Recreate Nginx so it loads the copied config` | `nginx -t` ใน container ทิ้ง แล้ว force-recreate ทุกครั้ง (#249) |
| 14 | `Validate the copied platform-ui Nginx configuration` → `Recreate platform-ui ...` | แบบเดียวกัน |
| 15 | `Verify cluster readiness via Nginx (GET /health/ready)` | ต้อง 200 (≤ 15×3 วิ) |
| 16 | `Record deployed SHA in .current_sha` | เขียนเฉพาะเมื่อทุกข้อข้างบนผ่าน |
| 16b | `Record the .env checksum this deploy applied` | เขียน `/opt/pos/.env_applied_sha256` หลัง readiness ผ่านเหมือนกัน — deploy ล้ม = hash เก่ายังอยู่ → รอบหน้ารู้ว่า `.env` ยังไม่ถูกใช้ (#506) |
| 17 | บล็อก `Monitoring overlay` | copy/prune config, pull, up node-exporter, recreate prometheus+grafana, probe · ล้ม = `WARNING` เท่านั้น |

**`--check` ของ `deploy.yml` พิสูจน์แทบไม่ได้อะไร:** `command` ไม่มี check mode → ถูกข้าม → assert network ล้มแบบ false positive (มี `()` ว่างในข้อความ)
และไม่ไปถึง task หลัง `command` ตัวแรก (`ticket-343` §6.4) — ห้ามอ้าง

### 6.2 Rollback (owner ตัดสิน)

SHA ปลายทางต้อง: อยู่บน `main` · ไม่เก่ากว่า `ROLLBACK_FLOOR` `bedd328aa3ba1de8c56b5fe5753fd12deca5dd4f` (merge ของ #617/#616 — id เป็น UUID, release ก่อนนั้นเขียนลง schema ใหม่ไม่ได้ · เดิม `4f3a244…`) — `pos-deploy` (runner) ปฏิเสธ SHA ต่ำกว่า floor ส่วนทางมือคำสั่ง `merge-base` ด้านล่างคือด่านเดียว · floor ขยับเมื่อ merge ใหม่ — แก้ใน `deploy/scripts/pos-deploy.sh` แล้ว**ติดตั้ง `/usr/local/bin/pos-deploy` ทับด้วยมือ** (`07_CICD_DEPLOY.md` §6.2 ข้อ 4; CD ไม่ทำให้) ก่อน approve deploy · มี image ครบบน GHCR ·
**schema ไม่ถอย** (rollback ข้าม migration ที่ลบ/rename คอลัมน์ = owner ตัดสิน)

**ทางหลัก (พิสูจน์แล้ว 2026-09-30): dispatch `Deploy (demo)` ผ่าน runner** ด้วย `image_tag=$OLDTAG` — คำสั่งใน §6.3 ·
run [36687687309](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36687687309) ถอย `494ace3` → `e50f4fa` (`failed=0`, ตาราง `migrations` เหมือนเดิม) ·
ทางมือในนาม `deploy` ข้างล่างก็พิสูจน์แล้ววันเดียวกัน (#343) — ใช้เมื่อ runner offline

```bash
export OLDTAG=<40-hex-sha>
```

```bash
git merge-base --is-ancestor bedd328aa3ba1de8c56b5fe5753fd12deca5dd4f "$OLDTAG" && git merge-base --is-ancestor "$OLDTAG" origin/main && echo "rollback target ok"
```

```bash
bash deploy/scripts/verify-ghcr-tags.sh "$OLDTAG" linux/amd64
```

schema ต้องไม่ถอย — ไม่มี migration ใหม่ระหว่างสอง release (`$CURRENT` จาก §3 ข้อ 6):

```bash
git diff --name-status "$OLDTAG" "$CURRENT" -- server/src/db/migrations
```

✅ ไม่มี output · 🛑 มีไฟล์ → **หยุด** owner ตัดสิน (ไม่มี down-migration — code เก่าบน schema ใหม่)

แล้วทำ §3 ข้อ 1, 4 (worktree ที่ **`$OLDTAG`** — ได้ compose/nginx/playbook ของ release นั้นด้วย), 5, 8 และรัน (Mac):

```bash
test -s "$DEPLOY_KEY" && DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=deploy DEMO_SSH_KEY_PATH="$DEPLOY_KEY" ansible-playbook deploy.yml -e image_tag="$OLDTAG" -e force_redeploy=true </dev/null
```

Windows (`REPO` ชี้ worktree ที่ `$OLDTAG`):

```bash
DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=deploy KEYFILE=deploy_ed25519 ans ansible-playbook deploy.yml -e image_tag="$OLDTAG" -e force_redeploy=true
```

`force_redeploy=true` ใส่เสมอตอน rollback (จำเป็นเมื่อ `.current_sha` ยังชี้ SHA นั้นหลัง deploy ล้ม) · ตรวจด้วย §4 · rollback อัตโนมัติมีแค่ใน
`pos-deploy.sh` บน runner (ติดตั้งแล้ว 2026-09-30 · rollback แบบ `workflow_dispatch` พิสูจน์แล้ว · **rollback อัตโนมัติเมื่อ readiness ล้ม พิสูจน์แล้ว 2026-09-30** — run `36720675552` แดง + `pos-deploy` รัน playbook ของ release ก่อนหน้าซ้ำ, ไม่ใช่ `rescue:` ของ Ansible)

### 6.3 CD อัตโนมัติ

workflow `Deploy (demo)` → self-hosted runner บน VM (#67 — **ติดตั้งแล้ว 2026-09-30** `mob04-demo` online; deploy จริงครั้งแรก `e50f4fa` สำเร็จ) → required reviewer `NuimanLP` บน environment `demo` ·
รายละเอียด: `07_CICD_DEPLOY.md` §6.1–§6.2 และ `deploy/scripts/setup-mob04-runner.sh` · การรันด้วยมือตามคู่มือนี้เป็นทางสำรองเมื่อ runner offline

**dispatch ด้วยมือ** (rollback, กู้ VM ที่ค้างครึ่งทาง, หรือ rollout SHA ใดก็ได้บน `main`) — input ชื่อ **`image_tag`** (ว่าง = head ของ `main`):

```bash
gh workflow run deploy.yml -R NuimanLP/srisurart-pos-flutter --ref main -f image_tag=<40-hex-sha>
```

```bash
gh run list -R NuimanLP/srisurart-pos-flutter --workflow deploy.yml --limit 3 --json databaseId,status,headSha,event,createdAt
```

**ก่อน approve — runner ต้อง online:**

```bash
gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners -q '.runners[]|[.name,.status]|@tsv'
```

✅ `mob04-demo	online` · ❌ `offline` ทั้งที่ service `active` (log ของ runner มี `BrokerServer` … `Operation canceled`) → owner ในนาม `cloud`:
`ssh mob04 'sudo systemctl restart actions.runner.NuimanLP-srisurart-pos-flutter.mob04-demo.service'` แล้วตรวจซ้ำ · ยัง offline → ทางมือ §3 (owner อนุญาต)

**หลัง merge เข้า `main` Deploy ยิง 2 รอบ** (จาก Server CI และ Flutter CI) — รอบแรกมักข้าม (ขึ้นเขียว) เพราะ image web ยังไม่ถูกสร้าง → approve รอบที่สอง · ยกเลิกรันเก่าที่ค้าง waiting ก่อน (ถือช่อง `deploy-demo`) ·
🔴 **หลัง deploy เสร็จ ยกเลิก run แฝดที่ยังรอ approve ทันที** — ไม่งั้นมันถือช่อง `deploy-demo` และ release ถัดไปค้าง `pending` (2026-10-10: run `37786086586` ถือช่องไว้ 2 วัน) · branch: PR เข้า `develop` ก่อน แล้ว `develop` → `main` ด้วย **merge commit เท่านั้น** (squash/rebase ทำให้ SHA ของ floor หายจากประวัติ `main`)

ดู log งาน `resolve release` ว่าบรรทัด `Release to deploy:` เป็น SHA ที่ตั้งใจ **ก่อน** owner approve (GitHub → Actions → run นั้น → Review deployments → `demo`) ·
ถ้ามี run อื่นรอ approve อยู่ ให้ยกเลิกก่อน (§3 ข้อ 1) · ตรวจผลด้วย §4 (`.current_sha` คือหลักฐาน ไม่ใช่สีของ run)

พิสูจน์แล้ว 2026-09-30:

| run | ทำอะไร | ผล |
|---|---|---|
| [36686729879](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36686729879) | กู้ VM ที่ค้างครึ่งทางหลัง VPN หลุดกลาง playbook ด้วยมือ (`e50f4fa` → `494ace3`) | `failed=0` |
| [36687687309](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36687687309) | rollback `494ace3` → `e50f4fa` | `failed=0`, schema เหมือนเดิม |
| [36688248109](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36688248109) | SHA เดิมซ้ำ (`.env` ไม่เปลี่ยน) | จบที่ `Skipping duplicate deployment.` (`ok=7 changed=0`) — container ไม่ถูกแตะ |

### 6.3b ประวัติ #616 UUID cutover บน `mob04` (2026-10-06 — ทำครั้งเดียว ห้ามทำซ้ำ)

**ประวัติ:** วันนั้น deploy `65861ea` (develop → main) · ฐานข้อมูลถูก backup ไว้ที่ `/opt/pos/backups/pos_backup_20261006_035714Z.sql.gz` แล้วล้างทั้งหมด
เพราะ migration `EntityIdsToUuid` ปฏิเสธฐานข้อมูลที่ไม่ว่าง · 🔴 **ไม่มีสำเนาออกนอก VM** (โฟลเดอร์ของ owner หายไปแล้ว ตรวจ 2026-10-07; #363 parked) ·
**วันนี้ `mob04` มีข้อมูลจริงของ tenant `ศรีสุราษฎร์เจริญยนต์`** → 🔴 **ห้ามล้างฐานข้อมูลหรือ volume ใด ๆ ใน deploy ปกติ** ·
`.current_sha` ปัจจุบันดูด้วย `cat /opt/pos/.current_sha` (§4.1) · tenant ใหม่สร้างผ่าน platform-ui (รหัสชั่วคราวหมดอายุใน 10 นาที) · tenant id ตัวพิมพ์เล็กเท่านั้น (#621) · CORS อนุญาต `X-Device-Token` (#618) ·
ไฟล์ backup/snapshot จากแอปเดิม (id เช่น `p1`, `s-0001`) ถูก server ปฏิเสธตอน import: `400 INVALID_ID` · เครื่องลูกข่ายก่อนวันนี้ต้องล้าง (Incognito / Clear site data; Android ล้าง storage แล้วลง APK ใหม่ — §6.7) เพราะ outbox เก่าส่ง/discard ไม่ได้ ·
บันทึก: `docs/handoff_log/session-2026-10-06-uuid-cutover-mob04.md` · runbook: `runbook-616-uuid-cutover-mob04.md`

### 6.4 Troubleshooting

| อาการ | สาเหตุ | ทางแก้ |
|---|---|---|
| `config file = None` | Mac: ไม่ได้อยู่ใน `deploy/ansible/` · Windows: ไม่ได้บังคับ `ANSIBLE_CONFIG` (mount world-writable) | `cd` ให้ถูก · ใช้ฟังก์ชัน `ans` |
| `Host key verification failed` | `ansible.cfg` ไม่ถูกอ่าน · หรือ host key ใน `known_hosts` ไม่ตรง | แก้ข้อบน · ถ้า owner ยืนยันว่า VM เปลี่ยนจริง: `ssh-keygen -R 172.30.58.20` แล้วทำ §1.4 ใหม่ |
| `UNREACHABLE` + timeout | ไม่ได้ต่อ VPN | §1.2 |
| `UNREACHABLE` กับ `127.0.0.1` | ลืม `DEMO_SSH_HOST` (default `127.0.0.1`) | ใส่ `DEMO_SSH_HOST=172.30.58.20` |
| `Permission denied (publickey)` | key/user ไม่ตรงคู่ · key ยังไม่ติดตั้ง · ACL บน Windows | ตาราง §0.3 · §2.4 · `icacls` §1.3 |
| `ERROR: Ansible requires blocking IO on stdin/stdout/stderr. Non-blocking file handles detected: <stdout>, <stderr>` | รันจาก shell ที่ไม่ใช่ terminal ปกติ (สคริปต์, agent, IDE บางตัว) | ต่อท้าย `</dev/null 2>&1 \| cat` หรือรันใน Terminal |
| `<KEY> is required` (เช่น `K6_REMOTE_WRITE_BASIC_AUTH_USER is required`) | `/opt/pos/.env` เก่ากว่า compose — Compose ล้มทุกคำสั่ง | owner เติมคีย์ในไฟล์ secrets แล้ว §2.5 · ห้ามแก้บน VM ด้วยมือ |
| `x509: certificate is not valid for any names, but wanted to match ghcr.io` | FortiGate กลับมาทำ SSL inspection กับ `ghcr.io` (§0.1 — คลี่คลายแล้ว 2026-09-29) | หยุด แจ้ง owner ให้ประสานฝ่ายเครือข่าย · ห้ามปิด TLS verify |
| `... predates the ip_range ...` | network รุ่นเก่า · หรือรันด้วย `--check` (false positive, `()` ว่าง) | `--check`: ไม่ต้องทำอะไร · รันจริง: owner ทำ network recreate ตาม 07 §7 (ห้าม `-v`) |
| `Wait for api-N health check to pass` หมด 25 ครั้ง | api boot ไม่ขึ้น (`PLATFORM_ADMINS` ผิดรูป/รหัส < 12, `CORS_ORIGINS=,`, Postgres auth ฯลฯ) | `ssh mob04-deploy 'cd /opt/pos && IMAGE_TAG=$(cat .current_sha) docker compose -f docker-compose.yml -f vm.override.yml logs --tail 100 api-1'` (`IMAGE_TAG` จำเป็นให้ compose แทนค่าได้) |
| `etcd-init: FAILED — root cannot authenticate` | รหัสใน `etcd-data` ≠ `ETCD_ROOT_PASSWORD` (§2.3) | หยุด รายงาน owner (#365) |
| `password authentication failed for user ...` | รหัสใน `pgdata` ≠ `.env` (§2.3) | หยุด รายงาน owner · ห้ามลบ volume |
| `Validate the copied Nginx configuration` ล้ม | `nginx.conf` ของ SHA นี้พัง | Nginx เดิมยังเสิร์ฟอยู่ · แก้ใน PR → SHA ใหม่ |
| `Release '<sha>' is already active on vm-demo and .env is unchanged. Skipping duplicate deployment.` | `.current_sha` = tag และ `.env` ไม่เปลี่ยน | ตั้งใจ rollout ซ้ำ: `-e force_redeploy=true` · **ห้ามลบ `.current_sha`** · แก้ `.env` แล้วยังเห็นข้อความนี้ = provision ยังไม่ได้เขียนไฟล์ (เช็ก `skipping` ใน §2.5) |
| `Release '<sha>' is already active, but /opt/pos/.env changed since the last deploy. Rolling it out again ...` | provision เขียน `.env` ใหม่ หรือ deploy ครั้งแรกหลัง #506 | ปกติ — ปล่อยให้รันจนจบ แล้วตรวจ §4 |
| provision: `DEMO_ENV_FILE has no non-empty <KEY>= line ...` | ไฟล์ secrets ขาดคีย์ / ค่าว่าง | เติมคีย์ในไฟล์ secrets (§2.2) แล้วรันใหม่ · `.env` บน VM ยังไม่ถูกแตะ |
| `WARNING: release '<sha>' is deployed and healthy, but the monitoring overlay failed ...` | Prometheus/Grafana ขึ้นไม่ได้ (POS ไม่กระทบ) | แก้ต้นเหตุ → release ถัดไป หรือรัน tag เดิมด้วย `-e force_redeploy=true` (ข้อความเองก็แนะนำแบบนี้) · **ห้ามลบ `.current_sha`** |
| platform-ui 403 เงียบ ๆ | สามอย่างของ `172.30.0.20` ไม่ตรงกัน: `ipv4_address` ใน compose, `allow 172.30.0.20;` ใน `nginx.conf`, `PLATFORM_ADMIN_IPS` · หรือ container เสีย IP หลัง network recreate | `ssh mob04-deploy 'docker inspect srisurart-pos-platform-ui-1 --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}"'` ต้องได้ `172.30.0.20` |
| POST จากเบราว์เซอร์ล้มหมด | `CORS_ORIGINS` ไม่ตรง origin | §4.6 |
| backup: `::error::Neither active docker compose postgres container nor local pg_dump command found.` | สคริปต์รุ่นก่อน #501 และไม่ได้ส่ง `IMAGE_TAG` · (รุ่นใหม่: ไม่มีไฟล์ compose ใน `/opt/pos` และไม่มี `pg_dump`) | provision ใหม่ (§2.4) หรือใช้คำสั่ง workaround §3 ข้อ 8 ตามตัวอักษร |
| backup: `::error::IMAGE_TAG is required by deploy/compose/vm.override.yml but is unset, and /opt/pos/.current_sha is missing or empty. ...` | สคริปต์รุ่นใหม่ หา `IMAGE_TAG` ไม่ได้ (ไม่มี `.current_sha`) | หยุด ถาม owner |
| backup: `::error::docker compose could not resolve the compose configuration (...)` | compose ล้มตอนอ่าน config — ข้อความถัดไปบอกสาเหตุ (เช่น `<KEY> is required`) | แก้ตามข้อความ · `.env` ขาดคีย์ → owner (§2.5) |

### 6.5 กฎห้ามทำ

- [ ] ห้าม `docker compose down -v` / `docker volume rm srisurart-pos_*` · ห้าม `docker volume prune` / `docker system prune --volumes`
- [ ] ห้ามลบ volume `certs-ca` — CA ใหม่ = APK ทุกเครื่องที่แจกไปต่อไม่ได้จนกว่าจะ commit CA ใหม่และ build APK ใหม่
- [ ] ห้ามลบ volume `srisurart-pos_product-images` — รูปสินค้าไม่อยู่ใน `pg_dump` และไม่มีที่อื่นนอกจาก volume นี้กับ `pos_images_*.tar.gz` บนดิสก์ VM เดียวกัน
- [ ] ห้ามลบ volume `srisurart-pos_sale-photos` — รูปหลักฐานตอนขายไม่อยู่ใน `pg_dump` ไม่มีใครลบรูปได้ในแอป และไม่มีที่อื่นนอกจาก volume นี้กับ `pos_sale_photos_*.tar.gz` บนดิสก์ VM เดียวกัน
- [ ] ห้าม `--diff` กับ `provision.yml` · ห้าม `export DEMO_ENV_FILE`
- [ ] ห้ามรัน `provision.yml` เป็น `deploy` หรือ `deploy.yml` เป็น `cloud`
- [ ] ห้ามรัน `deploy.yml` จาก working tree ที่ไม่ใช่ worktree สะอาดที่ `$TAG` · ห้ามรันเมื่อ gate `docker pull` ของ §3 ข้อ 5 เป็น STOP
- [ ] ห้ามแก้ `/opt/pos/.env` ด้วยมือโดยไม่เติมบรรทัดว่างก่อน append และไม่ตรวจด้วย `grep -c '^KEY='`
- [ ] ห้ามลบ `.current_sha` — ใช้ `-e force_redeploy=true`
- [ ] ห้าม re-key volume หรือทำ network recreate เอง — owner ตัดสิน
- [ ] ห้ามบันทึก `docker save`/`load` ว่าเป็น CD · ห้ามอ้าง `--check` / Actions เขียว เป็นหลักฐาน
- [ ] ห้ามเขียนว่า "CORS ปิดบน VM แล้ว" หรือ "backup ออกนอก VM แล้ว" (offsite พักไว้ถึงหลังเดโม — #363/#288)
- [ ] ห้าม commit / วางลง chat ไฟล์ env หรือค่าในนั้น · ห้ามใส่ `ALLOW_DEV_SECRETS` / `IMAGE_TAG` ใน `.env`
- [ ] deploy ทีละคน — ประกาศก่อนและหลัง

### 6.6 เอกสารต้นทาง

| เอกสาร | อ่านเมื่อ |
|---|---|
| `docs/Backend_design/07_CICD_DEPLOY.md` §5–§7 | เหตุผลของทุกขั้น, runbook |
| `docs/Backend_design/adr/0013-cicd-toolchain.md` | การตัดสินใจ CI/CD + addendum |
| `docs/handoff_log/ticket-343-vm-deploy.md` | pre-flight จริงบน `mob04`, วิธี container บน Windows |
| `docs/handoff_log/ticket-336-env-secrets.md` | ที่มาของทุกคีย์, วิธีสุ่ม, กับดัก volume |
| `docs/handoff_log/handoff_demo-335-merge-and-cd-blocked_21_09_2026.md` | หลักฐาน FortiGate (§4.7) |
| `deploy/ansible/*.yml`, `deploy/ansible/inventory/hosts.ini`, `deploy/ansible/ansible.cfg`, `deploy/compose/*.yml`, `server/docker-compose.yml`, `deploy/scripts/*.sh` | ของจริง |

### 6.7 build และติดตั้งแอป Android (APK)

APK ไม่ได้มากับ deploy — ต้องสั่ง workflow แยก (รายละเอียด: `07_CICD_DEPLOY.md` §2b)

1. **ก่อนอื่น:** แอปต่อ `mob04` ได้ต่อเมื่อ PR #552 (ดู 07 §5 TLS) deploy แล้ว และ CA cert อยู่ที่ `frontend/assets/certs/pos-ca.crt` ถ้ายังไม่ครบ แอปติดตั้งได้แต่เชื่อมเซิร์ฟเวอร์ไม่ได้
2. GitHub → Actions → **Android APK** → Run workflow → เลือก branch `main` (บน branch อื่น job ไม่รัน)
3. รอจนเขียว แล้วเปิด Releases → prerelease `apk-<sha7>` → ดาวน์โหลด `srisurart-pos-<sha7>.apk`
4. ย้ายไฟล์เข้าเครื่อง Android → เปิดไฟล์ → อนุญาต "ติดตั้งจากแหล่งที่ไม่รู้จัก" (unknown sources) ให้แอปที่ใช้เปิดไฟล์ → ติดตั้ง · รุ่นใหม่ติดตั้งทับรุ่นเก่าได้เพราะเซ็นด้วยกุญแจเดิม
5. เครื่องต้องอยู่ในเครือข่ายคณะ, ต่อ VPN, หรือเปิด Tailscale ที่ login เข้า tailnet ของร้าน (§1.2) จึงเปิดแอปแล้วเข้า `https://172.30.58.20` ได้ — ไม่ต้อง build APK ใหม่ (ที่อยู่/SAN เดิม)

ล้าง storage ของแอปเก่าก่อนใช้ APK ใหม่ — **เฉพาะเครื่องที่ใช้งานครั้งสุดท้ายก่อน 2026-10-06** (#616 เปลี่ยน id เป็น UUID, outbox ของแอปรุ่นก่อนนั้นส่ง/discard ไม่ได้) · เครื่องที่ติดตั้ง/ใช้หลังวันนั้นติดตั้งทับได้เลย ไม่ต้องล้าง

**ชื่อ release = `apk-<sha7>` ของ commit ที่ build** — เลขใหม่สุด (ดูวันที่ build) คือรุ่นล่าสุด เช่น `apk-32a2544` (build 2026-10-13 จาก `main` `32a2544`, run `38325443859`; โค้ดเดียวกับ release `8a44a03`) · ยังไม่ได้ลองบนมือถือจริง

**ครั้งแรกที่ใช้กล้อง** (ปุ่ม **ถ่ายรูป** ในแผ่น **รูปหลักฐานสินค้า**, หรือไอคอนสแกนบาร์โค้ด): Android ขึ้นหน้าต่างขออนุญาตใช้กล้อง → กดอนุญาต · ถ้ากดไม่อนุญาต แอปแสดง `ไม่ได้รับอนุญาตให้ใช้กล้อง` กับคำแนะนำ `อนุญาตให้แอปหรือเบราว์เซอร์ใช้กล้อง แล้วกด ลองอีกครั้ง` และ `หรือปิดหน้านี้ แล้วใช้ปุ่ม เลือกรูปจากเครื่อง` (เลือกรูปจากเครื่องแทนได้) — เปิดสิทธิ์เองได้ที่ ตั้งค่า → แอป → Srisurart POS → สิทธิ์

**สิทธิ์ที่แอปขอ** (จาก `aapt dump badging` ของ `apk-32a2544`): package `com.srisurart.srisurart_pos` · versionCode 1 · minSdk 24 (Android 7.0) · targetSdk 36 · `INTERNET`, `CAMERA`, `READ_EXTERNAL_STORAGE`, `ACCESS_NETWORK_STATE` และสิทธิ์ภายในของ AndroidX (`…DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`) · **ไม่มี `RECORD_AUDIO` / `WRITE_EXTERNAL_STORAGE`** (manifest ตัดทิ้งด้วย `tools:node="remove"` เพราะ plugin `camera` ดึงมารวมให้ — ห้ามลบบรรทัดนั้น)

**ตรวจสิทธิ์เอง** (PowerShell; เลขรุ่น build-tools ใช้ตามที่ติดตั้งอยู่ใน `…\Sdk\build-tools\` · ถ้าไม่มี `aapt.exe` ใช้ `aapt2.exe dump badging` แทน):

```powershell
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\37.0.0\aapt.exe" dump badging srisurart-pos-32a2544.apk | Select-String "package:|sdkVersion|uses-permission"
```

ผ่านเมื่อ: เห็น `CAMERA` และไม่เห็น `RECORD_AUDIO` กับ `WRITE_EXTERNAL_STORAGE`

ข้อควรรู้: workflow ล้มถ้า release `apk-<sha7>` ของ commit นั้นมีอยู่แล้ว (ลบ release ก่อน) · ล้มถ้า secret `ANDROID_KEYSTORE_B64` ว่าง · ผู้ถือ secret ต้องเก็บ keystore สำรองส่วนตัว ห้าม commit
