# คู่มือ deploy full stack ขึ้น VM `mob04` (Ansible) — ฉบับมือใหม่

**ตรวจกับโค้ดที่:** `origin/main` @ `494ace3` · 2026-09-30 — อัปเดตจุดที่ล้าสมัยกับ `4832172` 2026-10-01 (#519 `.partial`, #516 CORS) (รวม PR #498–#504 — web-sync หลัง API + สลับแบบ atomic, `.env` มี newline ท้าย, backup resolve `IMAGE_TAG` เอง, web cache-busting · และ #506 — `.env` เปลี่ยน = `deploy.yml` rollout SHA เดิมซ้ำ, provision ตรวจคีย์ก่อนเขียน · #508 — `deploy.yml` สร้าง `docker/nginx` เองบน `/opt/pos` ที่ว่าง · และ deploy/rollback จริงบน `mob04` 2026-09-30)
**เอกสารเจ้าของเรื่อง:** `docs/Backend_design/07_CICD_DEPLOY.md` §5–§7, ADR-0013 · ถ้าคู่มือนี้ขัดกับไฟล์ใน `deploy/` → **ไฟล์ถูก**

---

## 0. หน้าแรก — อ่านหน้านี้ก่อนทำอะไร

### 0.1 สถานะวันนี้: FortiGate ไม่ตัด `ghcr.io` แล้ว (2026-09-29)

เดิม (2026-09-21 → 09-28) Firewall **FortiGate** ของคณะทำ SSL inspection กับ HTTPS ขาออกของ VM `172.30.58.20` และตอบ `ghcr.io`
ด้วยใบรับรองที่ **ไม่มี SAN** → `docker compose pull` ล้มด้วย `x509: certificate is not valid for any names` ·
**คลี่คลาย 2026-09-29:** `docker pull ghcr.io/…:<SHA เต็ม>` จาก `mob04` สำเร็จจริง และ TLS จาก VM ไป `ghcr.io`, `registry-1.docker.io`,
`gcr.io`, `github.com`, `api.github.com`, `*.actions.githubusercontent.com` verify ผ่านหมด (ใบของ FortiGate มี SAN `*.ghcr.io`/`ghcr.io` แล้ว)

* ยังคง gate ไว้ที่ §3 ข้อ 5 (`docker pull` จริงจาก VM) — ถ้า inspection กลับมา จะหยุดตรงนั้นก่อน `deploy.yml` แตะอะไร
* `docker save`/`load` ด้วยมือ = ทางกู้วันเดโมเท่านั้น **ห้ามบันทึกว่าเป็น CD**
* ประวัติ: `docs/handoff_log/handoff_demo-335-merge-and-cd-blocked_21_09_2026.md` §4.7

**ทำไม gate ข้อ 5 ต้องมาก่อน:** ใน `deploy.yml` task ที่ **copy ไฟล์ compose / nginx.conf / platform-ui / postgres init / etcd-init.sh
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

(วัดจริง: `docs/handoff_log/ticket-343-vm-deploy.md` §3) · `--check` ไม่เผยการใช้ user ผิด

### 0.4 ภาพรวม

```text
merge → main ── Server CI + Flutter CI ──▶ GHCR: srisurart-pos-server:<sha> + srisurart-pos-web:<sha>
                                                      │
notebook (worktree สะอาดที่ <sha>)                     │ docker compose pull  ◀── gate §3 ข้อ 5
   ├─ ssh เป็น cloud  ─▶ provision.yml (owner)          │
   └─ ssh เป็น deploy ─▶ deploy.yml -e image_tag=<sha> ─┴─▶ VM mob04 /opt/pos ─▶ /opt/pos/.current_sha = <sha>
```

### 0.5 เสร็จแล้วรู้ได้อย่างไร

deploy สำเร็จ = **ทุกข้อ** ใน §4 ผ่าน และหลักฐานตาม §5 ถูกแปะใน #343/#344
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

### 1.2 เครือข่าย: ต้องอยู่ในเครือข่ายมหาวิทยาลัยหรือต่อ VPN

`172.30.58.20` (hostname `mob04`) เข้าจากนอกมหาวิทยาลัยไม่ได้เลย

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
* passphrase: Mac ใช้ได้กับ `ssh-add --apple-use-keychain` · ฟังก์ชัน `ans` บน Windows ไม่มี agent → key ที่มี passphrase จะค้างรอพิมพ์
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
❌ คีย์ `:?` ที่ขาดทำให้ **ทุก** คำสั่ง `docker compose` บน VM ล้ม (`<KEY> is required`) ไม่ใช่แค่ service นั้น

คีย์ที่ไม่ใช่ `:?` แต่มีผล: `CORS_ORIGINS` ต้องเป็น origin ที่เบราว์เซอร์ใช้เป๊ะ ๆ → `https://172.30.58.20` (§4.6) ·
`PLATFORM_ADMINS=user:password` รหัส ≥ 12 ตัว (ผิดรูป = api ไม่ boot) · `PLATFORM_ADMIN_IPS` ไม่ต้องใส่ (default `172.30.0.20`) ถ้าใส่ต้องมี `172.30.0.20`

#### สร้างไฟล์ใหม่จากศูนย์ — **เฉพาะ VM ที่ไม่มี volume** (ไม่ใช่ `mob04` วันนี้)

กฎ (`ticket-336-env-secrets.md` §2–3, `server/.env.example`): **hex เท่านั้น** (รหัสถูกแทนลงใน URL และ SQL literal — `/ + @ '` พัง) ·
`openssl rand -hex 24` ทั่วไป, `-hex 32` สำหรับ `JWT_PLATFORM_SECRET` · JWT = RSA 2048 PKCS#8 **อยู่ใน `"..."`**

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ~/secrets/jwt.key
```

```bash
openssl rsa -in ~/secrets/jwt.key -pubout -out ~/secrets/jwt.pub
```

```bash
( umask 077
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
  } > "$SECRETS_FILE" )
```

```bash
rm ~/secrets/jwt.key ~/secrets/jwt.pub
```

แล้วรันชุดตรวจข้างบนอีกรอบ

### 2.3 กับดัก volume: secret บางตัวถูก "อบ" ตอน bootstrap ครั้งแรก

| volume | ค่าที่อบไว้ | เปลี่ยนใน `.env` แล้ว |
|---|---|---|
| `pgdata` | `POSTGRES_PASSWORD`, `POS_APP_PASSWORD` | `password authentication failed` ที่ migrate/api |
| `etcd-data` | `ETCD_ROOT_PASSWORD` | `etcd-init: FAILED — root cannot authenticate` / etcd ไม่ healthy |
| `nginx-auth` | `K6_REMOTE_WRITE_BASIC_AUTH_*` | ไม่เปลี่ยน (สร้างครั้งเดียว) |

เปลี่ยนรหัสใน `.env` **ไม่ re-key** volume เดิม · re-key เป็นการตัดสินใจของ owner แยกต่างหาก — เจออาการนี้ **หยุดแล้วบันทึก** ห้าม `down -v`

### 2.4 ติดตั้ง key ของสมาชิก (provision แบบ key-only)

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

`provision.yml` ทำตามลำดับ: apt ติด Docker Engine + compose plugin → UFW (deny incoming, allow 22/80/443) → user `deploy` (group `docker`) →
authorized key → `/opt/pos/...` → copy `backup-db.sh`, `restore-db.sh`, `measure-container-rss.sh` ลง `/opt/pos/scripts` →
**ตรวจ `DEMO_ENV_FILE` (#506)** → **เขียน `/opt/pos/.env` 0600 (ข้ามถ้า `DEMO_ENV_FILE` ว่าง — มีข้อความเตือน)** → `/opt/pos/backups` 0700 → cron 03:00 ของ `deploy`

ตั้งแต่ #506 ก่อนเขียน `.env` provision **ตรวจว่ามีบรรทัด `KEY=<ไม่ว่าง>` ครบทุกคีย์ที่ Compose บังคับ** (11 คีย์ใน §2.2 — ไม่รวม `IMAGE_TAG` ที่ `deploy.yml` ส่งเอง)
ขาดตัวไหน play **ล้มก่อนแตะ `.env`** พร้อมชื่อคีย์ (ไม่พิมพ์ค่า) · ไม่มี `PLATFORM_ADMINS` = แค่ **เตือน** (Compose ไม่บังคับ แต่ platform-ui จะไม่มี admin ให้ login) ·
task เขียน `.env` เป็น `no_log` + `diff: false` แล้ว — แต่ **ยังห้ามใส่ `--diff`** อยู่ดี

🔴 **provision ไม่ restart อะไรเลย** — container ยังใช้ `.env` เก่าจนกว่าจะรัน `deploy.yml` รอบถัดไป · ตั้งแต่ #506 `deploy.yml` เทียบ sha256 ของ `.env`
กับ `/opt/pos/.env_applied_sha256` (hash ของ `.env` ที่ deploy สำเร็จครั้งล่าสุดใช้) → ถ้าต่าง จะ **rollout SHA เดิมซ้ำเอง** ไม่ต้องใส่ `force_redeploy` (§3 ข้อ 6)

**① backup `.env` บน VM ก่อน:**

```bash
ssh mob04 'sudo -n cp -p /opt/pos/.env /opt/pos/.env.bak-$(date +%F)'
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

`DEMO_ENV_FILE=...` นำหน้าคำสั่ง = มีผลแค่คำสั่งนี้ ไม่ค้างใน shell · shell history เก็บข้อความ `$(cat "$SECRETS_FILE")` ไม่ใช่ตัว secret — ใช้ได้

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

## 3. ทุกครั้งที่ deploy — happy path

ทุกข้อมี gate · gate ไหนไม่ผ่าน **หยุดที่ข้อนั้น** · คำสั่ง `git`/`gh` รันที่ root ของ repo หลัก (`gh` นอก git repo ต้องใส่ `-R NuimanLP/srisurart-pos-flutter`)

> ✅ **ผ่านแล้ว 2026-09-30:** deploy ครั้งแรกหลังปลดบล็อกเกิดจริงผ่าน runner (`e50f4fa`, ok=48 failed=0) บน `/opt/pos` ที่ว่าง — migration ทั้งหมดรันแล้ว,
> `etcd-init.sh` เป็นไฟล์ + etcd auth เปิดแล้ว (#365), `.current_sha` ดูด้วย `cat /opt/pos/.current_sha` (ล่าสุด 2026-10-01 = `4832172`) · กล่องข้างล่างเก็บไว้เป็นประวัติ
>
> **(ประวัติ) deploy ครั้งแรกหลังปลดบล็อก (เฉพาะ `mob04`):** `.current_sha` ที่บันทึกล่าสุดคือ `8e873cd` (บันทึก 2026-09-21) — ห่างจาก `main`
> **500+ commit** (ณ 2026-09-29 · นับเองด้วย `git rev-list --count 8e873cd..origin/main`) และมี **ไฟล์ migration ใหม่ 11 ไฟล์** (+ `1788652800000-InitialSchema.ts`
> ถูกแก้) ที่ย้อนไม่ได้ (ไม่มี down-migration) · ดูรายการ: `git diff --name-status 8e873cd origin/main -- server/src/db/migrations` · เป็นครั้งแรกที่จะ: ซ่อม `etcd-init.sh` ที่เป็นไดเรกทอรี
> (`rmdir`) และเปิด auth ของ etcd, รัน migration `1788652804600` ที่ **บังคับ logout platform admin ทุกคนหนึ่งครั้ง** · ข้อ 8 (backup DB) จึงห้ามข้าม

**1. ประกาศ + เคลียร์คิว** — ทีละคนเท่านั้น · ประกาศในแชททีมว่า "กำลัง deploy `<sha>`" · owner ปฏิเสธ/ยกเลิก run `Deploy (demo)` ที่ค้างรอ approve ก่อน
(approve run เก่า = ส่ง SHA เก่าขึ้น):

```bash
gh run list --workflow "Deploy (demo)" --status waiting --json databaseId,headSha,createdAt
```

✅ ว่าง `[]` (หรือ owner cancel แล้ว)

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

```bash
bash deploy/scripts/verify-ghcr-tags.sh "$TAG"
```

```text
...
Both server and web images for tag '<sha>' are verified on GHCR.
```

✅ ทั้งสอง CI `success` และสคริปต์ exit 0 · ❌ `in_progress` → รอ · `failure` → ห้ามใช้ SHA นี้ · สคริปต์ exit 1 = image ยังไม่ครบ, exit 2 = ถาม GHCR ไม่ได้
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
(ผ่าน FortiGate ของคณะ) ด้วย `docker pull` จริงของ SHA เต็ม ไม่ใช่แค่ดูใบรับรอง:

```bash
ssh mob04-deploy "docker pull ghcr.io/nuimanlp/srisurart-pos-server:$TAG" && echo "gate ok" || echo "STOP: VM ดึง image ไม่ได้"
```

✅ `gate ok` (ตรวจแล้ว 2026-09-29: `docker pull` SHA เต็มจาก `mob04` สำเร็จ และ TLS ไป `ghcr.io`, `registry-1.docker.io`, `gcr.io`,
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

✅ ดิสก์เหลือหลาย GB · เก็บรายการ container ไว้เป็นหลักฐาน "ก่อน" · ❌ ดิสก์น้อย → แจ้ง owner ห้าม `prune --volumes` เอง

**7. `.env` บน VM ครบ** — `deploy` เป็นเจ้าของไฟล์ `0600` จึงอ่านเองได้ไม่ต้อง sudo · พิมพ์แค่จำนวน:

```bash
ssh mob04-deploy 'for k in POSTGRES_PASSWORD POS_APP_PASSWORD REDIS_PASSWORD JWT_PLATFORM_SECRET JWT_PRIVATE_KEY JWT_PUBLIC_KEYS BULL_BOARD_PASSWORD ETCD_ROOT_PASSWORD GRAFANA_ADMIN_PASSWORD K6_REMOTE_WRITE_BASIC_AUTH_USER K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD; do printf "%s=%s\n" "$k" "$(grep -c "^$k=" /opt/pos/.env)"; done; stat -c "%A %U:%G %n" /opt/pos/.env'
```

✅ ทุกตัว `=1` และ `-rw------- deploy:deploy` · 🛑 มี `=0` → แจ้ง owner (§2.5) — deploy จะล้มที่คำสั่ง compose แรกด้วย `<KEY> is required`

**8. backup ฐานข้อมูลก่อน deploy** — migration ย้อนไม่ได้ · `backup-db.sh` เรียก `docker compose` พร้อม `vm.override.yml` ซึ่งบังคับ `IMAGE_TAG`
🔴 **แก้แล้วใน `main` (#501):** `backup-db.sh`/`restore-db.sh` resolve `IMAGE_TAG` จาก `/opt/pos/.current_sha` เองถ้า `IMAGE_TAG` ว่าง —
**แต่ owner ต้องรัน `provision.yml` ใหม่ก่อน** (แบบ key-only §2.4 ก็พอ · บน `mob04` ทำแล้ว 2026-09-30 — `/opt/pos/scripts` + cron 03:00 ติดตั้งแล้ว; ก่อนหน้านั้น cron เรียกสคริปต์ที่ไม่มี — แก้ 2026-09-30 เย็น: เฉพาะรอบ 09-30 ที่ "not found"; รอบ 09-29 สคริปต์มีอยู่แต่ fail และทิ้ง .gz ว่าง 20 ไบต์) VM จึงจะได้สคริปต์เวอร์ชันนี้ (`provision.yml` copy สคริปต์ลง
`/opt/pos/scripts` เฉพาะตอน provision ไม่ auto-sync กับ release — CD ไม่อัปเดตสคริปต์บน VM · PR #519 `b089f36` (เขียน `.partial` แล้ว `mv`) ก็ต้องลงเองแบบนี้ (ลงบน `mob04` แล้ว 2026-09-30, sha256 ตรง `origin/main`): `sudo install -o deploy -g deploy -m 0755` จาก `origin/main` แล้วเทียบ sha256) หลังจากนั้นเรียกเฉย ๆ ได้:

```bash
ssh mob04-deploy '/opt/pos/scripts/backup-db.sh /opt/pos/backups && ls -lt /opt/pos/backups | head -3'
```

**เฉพาะ VM ที่สคริปต์ยังเป็นรุ่นก่อน #501** (ยังไม่ได้ provision ใหม่ — ไม่ใช่ `mob04` แล้ว): ต้องส่ง `IMAGE_TAG` เอง — ไม่ส่ง = compose ล้มเงียบ
แล้วสคริปต์เก่าไปจบที่ `::error::Neither active docker compose postgres container nor local pg_dump command found.`:

```bash
ssh mob04-deploy 'IMAGE_TAG=$(cat /opt/pos/.current_sha) /opt/pos/scripts/backup-db.sh /opt/pos/backups && ls -lt /opt/pos/backups | head -3'
```

ผลที่คาดหวัง (สคริปต์รุ่นใหม่ เรียกเฉย ๆ · บรรทัดแรกไม่ขึ้นถ้าส่ง `IMAGE_TAG` เอง):

```text
IMAGE_TAG was unset; resolved from /opt/pos/.current_sha: <sha>
=== Srisurart POS Database Backup ===
...
  -> Backup created successfully (<size>).
::warning::Offsite upload is disabled (BACKUP_RCLONE_REMOTE is not set) — this backup stays on this VM only. ...
...
=== Backup Complete (local only -- offsite upload not configured, see the warning above) ===
```

✅ มี `Backup created successfully` และไฟล์ `pos_backup_<YYYYmmdd_HHMMSSZ>.sql.gz` (+ `.sha256`) บนสุดของ `ls` → **จดชื่อไฟล์** ·
บรรทัด `::warning::` เรื่อง offsite เป็นเรื่องปกติ (สคริปต์ exit 0) — backup นี้อยู่บน VM เท่านั้น
❌ `No such file` → ยังไม่มี `/opt/pos/scripts` ให้ owner รัน provision (§2.4)
❌ `::error::IMAGE_TAG is required by deploy/compose/vm.override.yml but is unset, and /opt/pos/.current_sha is missing or empty. ...`
→ VM ไม่มี `.current_sha` (ยังไม่เคย deploy สำเร็จ) · หยุด ถาม owner
❌ `::error::docker compose could not resolve the compose configuration (...)` ตามด้วยข้อความของ compose → อ่านบรรทัดถัดไป
(เช่น `<KEY> is required` = `.env` ขาดคีย์ ข้อ 7)
❌ error อื่น → หยุด ห้าม deploy โดยไม่มี backup

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
* `</dev/null` ท้ายคำสั่ง Mac: ถ้าไม่ใส่ ansible-core อาจปฏิเสธ stdio แบบ non-blocking (§6.4) — วัดจริงตอน rollback 2026-09-30 (#343)

✅ recap `failed=0` + `Successfully deployed release '<sha>' to vm-demo.` — **ยังไม่ใช่หลักฐาน** ไปข้อ 10
❌ จดชื่อ task ที่ล้ม → §6.4 · ถ้าล้มหลัง rolling restart เริ่มแล้ว VM อาจรัน api สองเวอร์ชันปนกัน → แก้แล้วรันคำสั่งเดิม, rollback (§6.2)
หรือ **ให้ runner ทำต่อผ่าน dispatch (§6.3)** — ไม่ต้องพึ่ง VPN ของ notebook
❌ `UNREACHABLE` กลางทาง (VPN หลุด) → VM ค้างครึ่งทาง · เกิดจริง 2026-09-30: หลุดที่ `Wait for api-3 health check` (ok=29) แล้ว **กู้ด้วย dispatch `Deploy (demo)` SHA เดิม**
(run [36686729879](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36686729879), `failed=0`) · `.current_sha` ยังเป็น SHA เก่า จึงไม่ติด early exit

**10. ตรวจผล** — §4 ทุกข้อ

**11. แปะหลักฐาน** — §5 ใน #343/#344

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
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 3100:127.0.0.1:3100 -L 3200:127.0.0.1:3200 mob04-deploy
```

| URL บน notebook | คือ | login |
|---|---|---|
| `http://localhost:3000` | Grafana — dashboard *POS Overview* ต้องมีกราฟ | `GRAFANA_ADMIN_USER`/`_PASSWORD` (owner) |
| `http://localhost:9090` | Prometheus | — |
| `http://localhost:3100` | Bull-Board | `BULL_BOARD_USER`/`_PASSWORD` (owner) |
| `http://localhost:3200` | platform-ui | platform admin (หลัง migration `1788652804600` ทุกคนต้อง login ใหม่ — ปกติ) |

**4.6 แอปจริงในเบราว์เซอร์** — เปิด `https://172.30.58.20` (ในเครือข่ายคณะ) · คำเตือนใบรับรองเป็นเรื่อง **ปกติ** (`certgen` ออกใบ self-signed
`CN=localhost`) · `http://` redirect ไป `https://`

✅ หน้า login ขึ้น และ login/ขายทดสอบได้
❌ หน้าโหลดได้แต่ทุก POST ล้ม → `CORS_ORIGINS`: `Origin` ที่ไม่อยู่ในรายการ API ยังตอบ แต่ไม่ส่ง header `Access-Control-Allow-Origin` (`server/src/app.setup.ts`, #516) → เบราว์เซอร์บล็อกคำตอบ; เบราว์เซอร์ส่ง `Origin` กับ POST
แม้ origin เดียวกัน · ตรวจแบบไม่พิมพ์ค่า (ต้องได้ `1`):

```bash
ssh mob04-deploy 'grep -c "^CORS_ORIGINS=.*https://172\.30\.58\.20" /opt/pos/.env'
```

🔴 ห้ามเขียนว่า "ปิด CORS บน VM แล้ว" จนกว่า 4.1 และข้อนี้จะผ่านทั้งคู่

> 2026-09-30: `Origin` แปลกหน้าเคยได้ HTTP 500 — แก้แล้ว PR #516 (`00d3488`, run `36717963989`) ตอนนี้ได้สถานะปกติของ route (เช่น `/health/live` 200 — ไม่ใช่ 500) ไม่มี `Access-Control-Allow-Origin` · origin ตัวเอง `https://172.30.58.20` ได้ ACAO

---

## 5. หลักฐานที่แปะใน ticket (#343 / #344)

**pre-flight (ข้อ 1–8):**

```text
วันที่ / ผู้ทำ:
TAG (origin/main):            <40-hex>
CI (gh run list --commit):    Server CI success · Flutter CI success
verify-ghcr-tags.sh:          "Both server and web images ... verified"
ansible -m ping (deploy):     SUCCESS / pong
docker pull gate (ข้อ 5):       ...srisurart-pos-server:<TAG> → gate ok
.current_sha ก่อน:            <sha>
network IPAM:                 [...IPRange 172.30.0.128/25...]
.env key counts (ข้อ 7):       ทุกคีย์ =1, -rw------- deploy:deploy
```

**หลัง deploy:** ทุกบรรทัดข้างบน และเพิ่ม:

```text
backup ก่อน deploy:           /opt/pos/backups/pos_backup_<...>.sql.gz
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

### 6.1 `deploy.yml` ทำอะไรทีละ task (ตามโค้ดใน `origin/main` @ `494ace3` — รันครบจริงบน `mob04` แล้ว 2026-09-30: runner `ok=48 failed=0`)

| # | task (ชื่อที่เห็นใน output) | ทำอะไร |
|---|---|---|
| 1 | `Validate image_tag parameter` | ต้องมี `image_tag` |
| 2 | `Check currently deployed SHA on VM` → `Checksum the VM's .env` → `Decide whether .env changed since the last deploy` → `Early exit on duplicate release deployment` | `.current_sha` = tag, ไม่มี `force_redeploy` **และ** sha256 ของ `.env` = `/opt/pos/.env_applied_sha256` → จบ play พร้อมข้อความ `Skipping duplicate deployment` · `.env` เปลี่ยน (หรือยังไม่มีไฟล์ marker) → rollout SHA เดิมต่อ (#506) |
| 3 | `Inspect the existing compose network` → `Refuse to deploy onto a network created before ip_range was added` | กัน network รุ่นเก่า (ยังไม่แตะอะไร) |
| 4 | `Copy docker-compose base configuration` … `Copy Postgres initialization scripts` | copy compose, `vm.override.yml`, สร้าง `docker/nginx` (#508), `nginx.conf`, platform-ui conf+html, postgres init **จาก tree ของคุณ** |
| 5 | `Check for the etcd-init.sh directory ...` → `Remove the Docker-created etcd-init.sh directory ...` → `Copy etcd-init bootstrap script` | ซ่อมบั๊ก `etcd-init.sh` เป็นไดเรกทอรีของ root (`rmdir` ผ่าน container root — มีของข้างใน = ล้มดัง ๆ) |
| 6 | `Pull release images from GHCR` | ถ้าล้มตรงนี้ ข้อ 4–5 เกิดไปแล้ว (เคยล้มเพราะ FortiGate จนถึง 2026-09-28 — กันด้วย gate §3 ข้อ 5) |
| 7 | `Apply database schema migrations (schema before code)` | `run --rm migrate` (ย้อนไม่ได้) |
| 8 | `Ensure backing datastores, certgen, htpasswd-gen and etcd are running` | `up -d postgres redis-cache redis-queue certgen htpasswd-gen etcd` |
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

SHA ปลายทางต้อง: อยู่บน `main` · ไม่เก่ากว่า `ROLLBACK_FLOOR` `4f3a24447094547bdcc00486bd29b53833f81c3f` · มี image ครบบน GHCR ·
**schema ไม่ถอย** (rollback ข้าม migration ที่ลบ/rename คอลัมน์ = owner ตัดสิน)

**ทางหลัก (พิสูจน์แล้ว 2026-09-30): dispatch `Deploy (demo)` ผ่าน runner** ด้วย `image_tag=$OLDTAG` — คำสั่งใน §6.3 ·
run [36687687309](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36687687309) ถอย `494ace3` → `e50f4fa` (`failed=0`, ตาราง `migrations` เหมือนเดิม) ·
ทางมือในนาม `deploy` ข้างล่างก็พิสูจน์แล้ววันเดียวกัน (#343) — ใช้เมื่อ runner offline

```bash
export OLDTAG=<40-hex-sha>
```

```bash
git merge-base --is-ancestor 4f3a24447094547bdcc00486bd29b53833f81c3f "$OLDTAG" && git merge-base --is-ancestor "$OLDTAG" origin/main && echo "rollback target ok"
```

```bash
bash deploy/scripts/verify-ghcr-tags.sh "$OLDTAG"
```

แล้วทำ §3 ข้อ 1, 4 (worktree ที่ **`$OLDTAG`** — ได้ compose/nginx/playbook ของ release นั้นด้วย), 5, 8 และรัน (Mac):

```bash
test -s "$DEPLOY_KEY" && DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=deploy DEMO_SSH_KEY_PATH="$DEPLOY_KEY" ansible-playbook deploy.yml -e image_tag="$OLDTAG" -e force_redeploy=true </dev/null
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

ดู log งาน `resolve release` ว่าบรรทัด `Release to deploy:` เป็น SHA ที่ตั้งใจ **ก่อน** owner approve (GitHub → Actions → run นั้น → Review deployments → `demo`) ·
ถ้ามี run อื่นรอ approve อยู่ ให้ยกเลิกก่อน (§3 ข้อ 1) · ตรวจผลด้วย §4 (`.current_sha` คือหลักฐาน ไม่ใช่สีของ run)

พิสูจน์แล้ว 2026-09-30:

| run | ทำอะไร | ผล |
|---|---|---|
| [36686729879](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36686729879) | กู้ VM ที่ค้างครึ่งทางหลัง VPN หลุดกลาง playbook ด้วยมือ (`e50f4fa` → `494ace3`) | `failed=0` |
| [36687687309](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36687687309) | rollback `494ace3` → `e50f4fa` | `failed=0`, schema เหมือนเดิม |
| [36688248109](https://github.com/NuimanLP/srisurart-pos-flutter/actions/runs/36688248109) | SHA เดิมซ้ำ (`.env` ไม่เปลี่ยน) | จบที่ `Skipping duplicate deployment.` (`ok=7 changed=0`) — container ไม่ถูกแตะ |

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

- [ ] ห้าม `docker compose down -v` / `docker volume rm srisurart-pos_*`
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
