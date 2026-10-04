# วิธีรัน Frontend + Backend + Prometheus + Grafana แบบ Local ทั้งชุด

คู่มือนี้สำหรับรันสแตกทั้งหมดบนเครื่องตัวเอง (Windows + Docker Desktop) เพื่อดู/ทดสอบระบบ
แบบ end-to-end: Flutter web (พูดกับ backend จริง) + NestJS API (3 instance หลัง Nginx) +
Postgres/Redis/etcd + Prometheus + Grafana. ใช้เวลาแรกประมาณ 3-5 นาที (build imageครั้งแรก
จะช้ากว่านั้น) หลังจากนั้น start ใหม่จะเร็วมาก

> 🔒 ทุกอย่างในคู่มือนี้เป็น **dev เท่านั้น** — ใช้ค่า placeholder จาก `.env.example`
> (`dev-only-*`), self-signed TLS cert, และ workaround สำหรับเบราว์เซอร์ ห้ามทำแบบนี้บน
> host จริงหรือ `mob04` (ดู CLAUDE.md เรื่อง `ALLOW_DEV_SECRETS` และ `docker-compose.dev.yml`)

---

## 0) Prerequisites

- Docker Desktop (Windows, WSL2 backend) — ติดตั้งและ login ไว้แล้ว
- Flutter SDK (เวอร์ชันเดียวกับที่ CI ใช้ — `flutter --version` เทียบกับ
  `.github/workflows/flutter.yml`)
- Repo อยู่ที่ path ปกติ (ไม่จำเป็นต้องเป็น ASCII path สำหรับขั้นตอนในคู่มือนี้ — ไม่มีการรัน
  `build_runner` หรือ `flutter analyze`)

---

## 1) เปิด Docker Desktop

ถ้า Docker Desktop ยังไม่รัน ให้เปิดโปรแกรมก่อน (หรือรันคำสั่งนี้ใน PowerShell):

```powershell
Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
```

รอจน engine พร้อม (เช็คด้วย `docker ps` ไม่ error) ปกติใช้เวลา ~30-60 วินาทีหลังเปิด

---

## 2) เตรียม `server/.env`

ทำครั้งเดียวพอ (ถ้ามีไฟล์นี้อยู่แล้วข้ามได้):

```bash
cd server
cp .env.example .env
```

ไฟล์นี้ตั้ง `ALLOW_DEV_SECRETS=true` ให้อัตโนมัติ ซึ่งจำเป็นสำหรับให้ api/worker/bull-board
บูตด้วยค่า placeholder ได้ (#410) — **ห้ามตั้งค่านี้บนโฮสต์จริง**

---

## 3) รันสแตก backend + monitoring ด้วย Docker Compose

จาก `server/`:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml -f ../deploy/compose/monitoring.yml up -d --build
```

ไฟล์ทั้งสามนี้รวมกัน:

| ไฟล์ | ทำอะไร |
|---|---|
| `docker-compose.yml` | สแตกหลัก: Nginx → api-1/2/3 → Postgres/Redis×2/etcd + worker + bull-board |
| `docker-compose.dev.yml` | เปิด port ของ Postgres/Redis บน `127.0.0.1` ให้ tool นอก Docker เข้าได้ (เช่น `psql`, `pnpm test:e2e`) |
| `../deploy/compose/monitoring.yml` | เพิ่ม node-exporter + Prometheus + Grafana |

ครั้งแรกจะ build image `srisurart-pos/server:local` (ช้าสุด) รอบต่อไปจะ cache ไว้แล้วเร็วขึ้นมาก

**เช็คว่าทุก container healthy:**

```bash
docker ps --format '{{.Names}}: {{.Status}}'
```

รอจนไม่มีบรรทัดไหนเขียนว่า `(health: starting)` ค้างอยู่ (ปกติ ~30-40 วินาที)

> 🟠 **ถ้า `etcd` ขึ้น `(unhealthy)` ค้างตลอด** — เกือบทุกครั้งคือ volume `etcd-data` เหลือจากรอบก่อน
> และรหัสผ่านที่ bake ไว้ใน volume ไม่ตรงกับ `.env` ปัจจุบัน (#365 — อาการจะเป็น "ไม่ green"
> ไม่ใช่ข้อความเรื่องรหัสผ่าน) **ไม่บล็อกส่วนอื่น** api/nginx/platform-ui/Flutter ใช้งานได้ตามปกติ
> ข้ามไปขั้นต่อไปได้เลย อย่าแก้ด้วย `down -v` (ลบ Postgres ของทุกคนไปด้วย — ดูข้อ 8)

**เช็ค backend ตอบจริง:**

```bash
curl -sk https://localhost/health/live
curl -sk https://localhost/health/ready
```

ควรได้ `{"status":"success","data":{"status":"up", ...}}` ทั้งคู่ (`-k` เพราะ cert เป็น
self-signed สำหรับ dev)

### 3.1 (ไม่บังคับ) เพิ่ม log + infrastructure metrics — `observability.yml`

เฉพาะเครื่อง dev — **ไม่อยู่ใน deploy ของ `mob04`** (`deploy.yml` ไม่โหลดไฟล์นี้; เพดาน RAM เพิ่ม ~1.1 GB) จาก `server/`:

```bash
docker compose -f docker-compose.yml -f ../deploy/compose/monitoring.yml -f ../deploy/compose/observability.yml up -d
```

ได้เพิ่ม: Loki (log 7 วัน) + Alloy (เก็บ log ทุก container) + postgres-exporter + redis-exporter + cAdvisor ·
ใน Grafana (<http://127.0.0.1:3000>) มีแดชบอร์ด **POS — infrastructure (local)** 15 แผง (RAM/CPU/OOM ต่อ container · Postgres · Redis)
และ *Explore* → datasource **Loki** ค้น log ได้ เช่น `{service="api-1"} |= "error"` (ตัวอย่างเพิ่ม: `deploy/loki/README.md`) ·
Loki อยู่ที่ `127.0.0.1:3101`, Alloy UI ที่ `127.0.0.1:12345`

- ใช้ชุด `-f` ชุดเดิมที่ใช้ตอนรันสแตกนี้ (ถ้ามี `docker-compose.dev.yml` ในชุดเดิม ให้ใส่ตามเดิม) แล้วต่อ `observability.yml` ท้ายสุด
- Grafana ใต้ overlay ต้องใช้ Docker Compose ≥ 2.24 (`volumes: !override`)
- Alloy/cAdvisor mount `docker.sock` ซึ่ง**ไม่จำกัด Docker API** (สั่ง start/stop container ได้) และ cAdvisor รัน `privileged` — ใช้บนเครื่อง dev เท่านั้น
- ถ้าโค้ด server ใน branch ยังไม่อยู่บน `main` แต่ต้องการรันแบบเดียวกับ VM (ใช้ `vm.override.yml`) ให้ `docker build -t srisurart-pos-server:develop-local server/` แล้วเพิ่ม `-f ../deploy/compose/local-api.yml` **หลัง** `vm.override.yml` (ครอบ migrate, api-1..3, worker, bull-board)
- ห้าม `down -v` (ดูข้อ 8)
- uptime ไม่อยู่ใน overlay นี้ — VM ส่ง heartbeat ไป Healthchecks.io ด้วย cron (`deploy/scripts/healthcheck-ping.sh`)

---

## 4) เปิดเบราว์เซอร์คุยกับ backend ตรง ๆ ได้ผ่าน `tlswrap` (dev-only)

`https://localhost/` เป็น self-signed cert — เบราว์เซอร์ปกติจะเจอหน้าเตือน ซึ่งกดผ่านเองได้
(Advanced → Proceed) แต่ Flutter web app คุยกับ backend ผ่าน `fetch()` ซึ่งเบราว์เซอร์จะ
บล็อกถ้า cert ไม่ได้รับความไว้ใจ — ทำให้แอปค้างที่หน้าโหลด แม้ backend จะตอบถูกต้องก็ตาม

วิธีแก้ (บันทึกไว้ใน `docs/handoff_log/demo-rehearsal-dev-2026-09-21.md` §9.7): รัน
container เสริมที่แปลง `http://127.0.0.1:8081` (plain, เบราว์เซอร์ถือเป็น secure context
เพราะเป็น `localhost`) เป็น TLS ไปหา `nginx:443` โดยไม่เช็ค cert:

```bash
docker run -d --name tlswrap --restart unless-stopped \
  --network srisurart-pos_default \
  -p 127.0.0.1:8081:8081 \
  alpine/socat \
  TCP-LISTEN:8081,fork,reuseaddr OPENSSL:nginx:443,verify=0
```

(ถ้ามี container ชื่อ `tlswrap` รันอยู่แล้วจากรอบก่อน ข้ามขั้นตอนนี้ได้เลย — เช็คด้วย
`docker ps --filter name=tlswrap`)

นี่เป็นแค่ L4 wrapper ไม่ใช่ reverse proxy ตัวที่สอง (ไม่แก้ header ใด ๆ) — ใช้เฉพาะตอน dev
บนเครื่องตัวเองเท่านั้น

---

## 5) สร้างผู้ใช้แรก (platform admin → tenant → shop owner)

ฐานข้อมูล dev เพิ่งสร้างใหม่ ยังไม่มี tenant/user เลย — หน้า login ของ Flutter จะขึ้นข้อความ
"ไม่สามารถใช้ PIN ออฟไลน์ได้ … กรุณาเชื่อมต่ออินเทอร์เน็ตเพื่อเข้าสู่ระบบใหม่" ซึ่งถูกต้องแล้ว
(ยังไม่เคยมีใคร login ออนไลน์เลยสักครั้ง) ต้องทำ 3 ขั้นตอนนี้ **ครั้งเดียว** ต่อฐานข้อมูล

> 🟠 **ฐานข้อมูลอาจไม่ได้ว่างจริง** — volume `pgdata` อยู่รอดข้าม `stop`/`up` และข้าม session
> ถ้าเครื่องนี้เคยรันสแตกมาก่อน admin/tenant จากรอบนั้นยังอยู่ครบ เช็คก่อนได้ด้วย
> `docker volume inspect srisurart-pos_pgdata --format '{{.CreatedAt}}'` (วันที่เก่า = มีข้อมูลเดิม)
> แล้วดูหมายเหตุในข้อ 5.1 และ 5.2 ว่าต้องทำอะไรต่างไปจากฐานว่าง

> 🟢 **มีหน้าเว็บ platform admin แล้ว** (`platform-ui`, #443 PR4) ที่ **http://127.0.0.1:3200** —
> สร้างร้าน, ระงับ/เปิดร้าน, ดูอุปกรณ์ + งาน import, ออก enrolCode ใหม่, ออกรหัสผ่านชั่วคราวให้เจ้าของร้าน
> (แยกจากแอป Flutter ของร้านโดยตั้งใจ — ADR-0002) · 🔴 **สร้าง platform admin ทำได้ทางเดียวคือคำสั่ง
> `bootstrap-admin` ในข้อ 5.1** — ไม่มีปุ่มหรือ API สำหรับเรื่องนี้ (ADR-0001: "admins are created out
> of band by the team — no API creates one") · ขั้น 5.2 ทำได้สองทาง: หน้าเว็บ หรือ platform CLI
> (`server/src/cli/platform.ts`, #443 PR1)

### 5.1 สร้าง platform admin ตัวแรก (ADR-0001 — ทำนอก API เท่านั้น)

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml -f ../deploy/compose/monitoring.yml exec -T \
  -e BOOTSTRAP_ADMIN_USERNAME=devadmin \
  -e BOOTSTRAP_ADMIN_PASSWORD=<รหัสผ่านอย่างน้อย12ตัวอักษร> \
  -e BOOTSTRAP_ADMIN_DISPLAY_NAME="Dev Admin" \
  api-1 sh -c 'DATABASE_URL="postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/pos" node dist/db/bootstrap-admin.js'
```

🔴 **ถ้าผลลัพธ์บอก `already exists — password left alone`** แปลว่า `devadmin` มีอยู่แล้วจาก volume
รอบก่อน และ **รหัสผ่านที่เพิ่งพิมพ์ไม่ได้ถูกบันทึก** (คำสั่งจบแบบไม่ error — login ด้วยรหัสใหม่จะไม่ผ่าน)
รันคำสั่งเดิมซ้ำโดยเติม `--force` ท้าย `bootstrap-admin.js` เพื่อตั้งรหัสใหม่ทับ:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml -f ../deploy/compose/monitoring.yml exec -T \
  -e BOOTSTRAP_ADMIN_USERNAME=devadmin \
  -e BOOTSTRAP_ADMIN_PASSWORD=<รหัสผ่านอย่างน้อย12ตัวอักษร> \
  -e BOOTSTRAP_ADMIN_DISPLAY_NAME="Dev Admin" \
  api-1 sh -c 'DATABASE_URL="postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/pos" node dist/db/bootstrap-admin.js --force'
```

ต้องเห็นบรรทัด `platform admin "devadmin": password reset` (รีเซ็ตรหัสแล้ว) หรือ `platform admin "devadmin": created` (สร้างใหม่) — ถ้าเห็น `already exists — password left alone (pass --force to reset it)` แปลว่ายังไม่ได้ตั้งรหัส (ลืม `--force`) · ข้อความทั้งสามมาจาก `MESSAGES` ใน `server/src/db/bootstrap-admin.ts`

### 5.2 ล็อกอินเป็น platform admin แล้วสร้าง tenant + shop owner

🔴 `location /api/v1/platform/` ของ Nginx จำกัดแค่ `127.0.0.1` และ `platform-auth.guard.ts`
เช็คซ้ำอีกชั้น การยิงจากโฮสต์เข้า port ที่ publish ไว้ **โดน `403` ทุกเครื่อง ไม่ใช่แค่
Docker Desktop** (บน Linux/`mob04` ก็เหมือนกัน) เพราะ docker-proxy เปิด connection ใหม่เข้า
container ทำให้ IP กลายเป็น gateway `172.30.0.1` — และด้วยเหตุผลเดียวกัน **`ssh -L` เข้า nginx ตรง ๆ ก็ใช้ไม่ได้**
(#335 D3, runbook เต็มอยู่ที่ [`docs/handoff_log/ticket-338-platform-provision.md`](../handoff_log/ticket-338-platform-provision.md))
จึงมีสองทางที่ใช้ได้:

**ทาง A — หน้าเว็บ (ง่ายสุด):** เปิด **http://127.0.0.1:3200** แล้ว login ด้วย admin จากข้อ 5.1 →
กรอกฟอร์ม "สร้างร้านใหม่" (ไม่มีช่องรหัสผ่านเจ้าของร้าน — server สุ่มให้) → หน้าต่างสีส้มจะแสดง
`tempPassword` + `enrolCode` **ครั้งเดียว** กดคัดลอกเก็บไว้ทันที · ทำงานได้เพราะคอนเทนเนอร์
`platform-ui` มี IP ตายตัว `172.30.0.20` ซึ่งอยู่ใน allowlist ทั้งของ nginx และของ guard
(`PLATFORM_ADMIN_IPS`) · token อยู่ 1 ชม. เก็บใน `sessionStorage` (ปิดแท็บ = ต้อง login ใหม่) ·
บน `mob04` ใช้ `ssh -L 3200:127.0.0.1:3200 deploy@<vm>` แล้วเปิด URL เดียวกัน
([`07_CICD_DEPLOY.md`](../Backend_design/07_CICD_DEPLOY.md) แถว "ดู platform-ui")

**ทาง B — platform CLI:** รันจาก**ภายใน container `api-1` เอง** ยิงตรงไปที่พอร์ต 3000 ของ
api (ไม่ผ่าน nginx เลยด้วยซ้ำ) — เป็น loopback จริงเสมอ รหัสผ่านพิมพ์ตอนถูกถาม (stdin/TTY)
ไม่มี `--password` ไม่มี JSON ให้ escape เอง และไม่ต้อง copy token ข้ามคำสั่ง (CLI login เอง
ให้ทุกครั้ง):

```bash
# ล็อกอิน platform admin (ทดสอบเฉย ๆ ก็ได้ ไม่จำเป็นสำหรับขั้นถัดไป)
docker compose exec api-1 node dist/cli/platform.js login --user devadmin
# Platform admin password: <พิมพ์รหัสผ่านข้อ 5.1>
# → logged in as devadmin (id …)

# สร้าง tenant + owner แรก — CLI ถามแค่รหัส admin ตัวเดียว (#443 PR3: ไม่มีรหัส owner ให้ตั้งแล้ว)
docker compose exec api-1 node dist/cli/platform.js tenants:create \
  --user devadmin --code demo-shop --shop-name 'ร้านตัวอย่าง' --plan demo \
  --owner-username owner --owner-display-name 'Shop Owner'
# Platform admin password: <พิมพ์รหัสผ่านข้อ 5.1>
```

Response จะได้ `tenantId`, `tempPassword` (รหัสผ่าน**ชั่วคราว**ของ owner ที่ server สุ่มให้ — เห็น**ครั้งเดียว**
อายุ 7 วัน, #443 PR3) และ `enrolCode` (ใช้สำหรับผูกเครื่อง POS Terminal ทีหลังถ้าต้องการ) · **ห้ามส่ง
`ownerPassword`** แล้ว — CLI ตัวนี้ไม่มี flag ให้ส่งอยู่แล้ว แต่ถ้ายิง API ตรง ๆ แล้วส่งเข้าไปจะได้
`400 OWNER_PASSWORD_NOT_ACCEPTED` · stderr ของ CLI จะเตือนด้วยว่า `tempPassword` โชว์ครั้งเดียว —
จดทันที รายละเอียด flags ทั้งหมด คำสั่งอื่น (`tenants:show`, `devices:reissue-code`,
`owner:temp-password`, `owner:set-password`) และตัวอย่างแบบ non-interactive (pipe รหัสเข้า
stdin สำหรับสคริปต์/CI) อยู่ที่
[`docs/handoff_log/ticket-338-platform-provision.md`](../handoff_log/ticket-338-platform-provision.md) §3

> 🟠 **`409 Tenant code or username already exists`** — `--code` หรือ `--owner-username` ซ้ำกับของที่มีอยู่แล้ว
> (มักเป็น volume รอบก่อน) ใช้ค่าใหม่ทั้งคู่ เช่น `--code demo-shop-2 --owner-username owner2`
> ดูร้านที่มีอยู่แล้วได้ที่หน้าเว็บ `:3200` · ห้ามแก้ด้วยการลบ volume
>
> 🟠 **รันจาก PowerShell แล้ว pipe รหัสผ่านเข้า stdin** (เช่น `'รหัส' | docker compose exec -T …`)
> จะได้รหัสที่ผิด (PowerShell ส่ง encoding/บรรทัดท้ายไม่ตรง) → login ไม่ผ่านทั้งที่รหัสถูก
> ให้พิมพ์รหัสตอนถูกถามใน terminal แบบ interactive (ไม่ใส่ `-T`) หรือใช้ **Git Bash**:
>
> ```bash
> printf '%s\n' '<รหัส admin>' | docker compose exec -T api-1 node dist/cli/platform.js login --user devadmin
> ```

### 5.3 ทดสอบ login แบบ shop-level (ไม่ติด loopback restriction — เรียกจาก host ปกติได้)

```bash
curl -sk https://localhost/api/v1/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"owner","password":"<tempPassword จากข้อ 5.2>"}'
```

ครั้งแรกจะได้ `passwordChangeRequired: true` + `passwordChangeToken` (อายุ 10 นาที) **ไม่ใช่**
`accessToken` — ต้องตั้งรหัสของตัวเองก่อน (≥ 12 ตัว, ห้ามซ้ำรหัสชั่วคราว):

```bash
curl -sk https://localhost/api/v1/auth/change-password \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <passwordChangeToken>" \
  -d '{"newPassword":"<รหัสผ่านใหม่ของคุณ>"}'
```

ได้ `accessToken`/`refreshToken` กลับมา = ใช้ username + **รหัสใหม่** นี้ **login ใน Flutter web
ที่โหมด "Backoffice"** ได้ทันที (role `owner`) · หรือจะ login ด้วยรหัสชั่วคราวใน Flutter เลยก็ได้ —
แอปจะเปิดหน้า "ตั้งรหัสผ่านใหม่" ให้เอง

---

## 6) รัน Frontend (Flutter web) ให้พูดกับ backend จริง

จาก `frontend/`:

```bash
flutter pub get
flutter run -d web-server --web-port=8090 --web-hostname=127.0.0.1 \
  --dart-define=USE_API_WRITES=true \
  --dart-define=API_BASE_URL=http://127.0.0.1:8081
```

(หรือใช้ `-d chrome` แทน `-d web-server` ถ้าอยากให้ Flutter เปิด Chrome ให้เองพร้อม hot
reload เต็มรูปแบบ)

รอจนเห็นบรรทัด:

```
lib\main.dart is being served at http://127.0.0.1:8090
```

แล้วเปิด **http://127.0.0.1:8090** ในเบราว์เซอร์ (ห้ามใช้ `https://` หรือ `https://localhost`
ตรงนี้ — หน้านี้เป็น plain HTTP ของ Flutter dev server เอง คนละตัวกับ backend)

> 🟠 ครั้งแรกที่เปิด จะเห็นสินค้า seed ของ Drift (Oil Filter, Spark Plug NGK, …) ปนกับสินค้า
> จาก server เพราะ `syncFromServer()` เพิ่มข้อมูลเข้าไปไม่ได้ล้าง seed ทิ้ง — ไม่ใช่บั๊ก
> ทดสอบขายด้วยสินค้าที่มีจริงบน server (เช่น `DEMO-001`) อย่าจิ้มสินค้าที่มาจาก seed

---

## 7) URL ทั้งหมดที่ควรเปิดได้ตอนนี้

| บริการ | URL | login |
|---|---|---|
| **Frontend (Flutter web)** | http://127.0.0.1:8090 | owner ของร้านที่สร้างในข้อ 5.2 (รหัสชั่วคราว → ตั้งรหัสใหม่ ข้อ 5.3) |
| **Platform admin (หน้าเว็บ)** | http://127.0.0.1:3200 | platform admin จากข้อ 5.1 (`bootstrap-admin`) |
| **Backend health** | https://localhost/health/live , https://localhost/health/ready | ไม่ต้อง login |
| **Bull-Board** (คิวงาน) | http://127.0.0.1:3100 | Basic Auth: `BULL_BOARD_USER` / `BULL_BOARD_PASSWORD` ใน `server/.env` |
| **Prometheus** | http://127.0.0.1:9090 | ไม่ต้อง login |
| **Grafana** | http://127.0.0.1:3000 | `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` ใน `server/.env` (ค่า placeholder เริ่มต้นคือ `admin` / `dev-only-grafana` ถ้ายังไม่ได้แก้ `.env`) |

Dashboard ของ Grafana ถูก provision มาให้อัตโนมัติจาก `deploy/grafana/provisioning` —
ไม่ต้องเพิ่ม datasource เอง

### 7.1 คิวงานใน Bull-Board แต่ละอันคืออะไร

Bull-Board แสดง 6 คิว (`server/src/queue/queue.constants.ts` → `ALL_QUEUES`), แต่ละคิวมี
`@Processor` (worker) ของตัวเองแยกกัน เพื่อไม่ให้สองคลาสแย่งงานคิวเดียวกัน:

| คิว | ใครใส่งานเข้า | ทำอะไร (`server/src/queue/processors/`) |
|---|---|---|
| **sale-post** | หลัง `saveSale`/`createReturn` สำเร็จ | งานเบื้องหลังหลังขาย/คืนของ — ไม่บล็อกการตอบ response ให้ลูกค้า (เช่นต่อยอดไปตรวจสต็อกที่ `inventory`) |
| **inventory** | `sale-post` ต่อยอดมา, หรือเรียกตรง | ตรวจสต็อกสินค้าหลังมีการขาย/คืน (`inventory.check`) |
| **maintenance** | scheduler รายชั่วโมง (`idem-cleanup-global`) + งาน purge อื่น | งานบ้านทั่วไป: ล้าง idempotency key ที่หมดอายุ, purge ใบเสนอราคาเก่า (`quotes.purge`), ลบไฟล์ export เก่า |
| **backup** | เรียกจาก `POST /backup/export` | export ข้อมูล tenant เป็นไฟล์ (`tenant.export`) — งานเดียวในคิวนี้ |
| **tenant-import** | เรียกจาก `POST /platform/tenants/:id/import` | นำเข้าข้อมูลร้านใหม่ตอน onboard (`tenant.import`) — แยกคิวจาก `backup` โดยตั้งใจ แม้เป็นงานฝั่งเดียวกัน เพราะ `@nestjs/bullmq` สร้าง Worker หนึ่งตัวต่อคิวต่อคลาส สองคลาสแย่งคิวเดียวกันจะสุ่มว่าใครได้ job |
| **dlq** (Dead Letter Queue) | job ไหนก็ตามที่ retry ครบ 3 ครั้ง (`attempts: 3`) แล้วยัง fail | ที่พักงานที่ล้มเหลวถาวรไว้ให้คนดูด้วยตา **ไม่มี worker ประมวลผลอัตโนมัติ** — `No workers` ในภาพที่ส่งมาคือของปกติ ไม่ใช่บั๊ก (`tenant-job-runner.ts`'s `routeToDlq`, `queue.module.ts` ไม่ได้ลงทะเบียน `@Processor(QUEUE_DLQ)` ไว้เลย) |

ในภาพตัวอย่าง `tenant-import` มี **FAILED 4** — เพราะรอบทดสอบก่อนหน้านี้เรียก
`POST /platform/tenants/:id/import` ด้วยไฟล์/tenant ที่ผิดเงื่อนไข (เช่น tenant มีบิลอยู่แล้ว)
ไม่ใช่ปัญหาของสแตกที่เพิ่งขึ้นมา — เปิดดู job ที่ fail ใน Bull-Board (คลิกเข้าไปในคิว) เพื่อดู
error message เต็มได้ ถ้าอยากลองใหม่ให้กด "Retry" บน job นั้นหลังแก้ payload/สาเหตุแล้ว

---

## 8) หยุด/เริ่มใหม่

**หยุดทุกอย่าง (เก็บข้อมูลไว้):**

```bash
# Ctrl+C ที่ terminal ของ flutter run (หรือกด q)
cd server
docker compose -f docker-compose.yml -f docker-compose.dev.yml -f ../deploy/compose/monitoring.yml stop
docker stop tlswrap   # ถ้ารันไว้
```

**เริ่มใหม่รอบหน้า (ไม่ build ใหม่ ถ้าไม่มีการแก้โค้ด backend):**

```bash
cd server
docker compose -f docker-compose.yml -f docker-compose.dev.yml -f ../deploy/compose/monitoring.yml up -d
docker start tlswrap  # ถ้ามี container นี้อยู่แล้ว
```

**ล้างข้อมูลทั้งหมด (ระวัง! ลบ Postgres/Redis/Grafana state ทิ้งหมด):**

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml -f ../deploy/compose/monitoring.yml down -v
```

🔴 **ห้ามรัน `docker compose down -v` โดยไม่ตั้งใจ** บน Docker daemon ที่ใช้ร่วมกับ session
อื่น — จะล้าง volume ของ session อื่นไปด้วย (กฎเดียวกับใน CLAUDE.md)

---

## 9) แก้ปัญหาที่เจอบ่อย

| อาการ | สาเหตุ | แก้ |
|---|---|---|
| แอปค้างที่หน้า spinner ตลอด | เบราว์เซอร์ปฏิเสธ self-signed cert ตอน fetch backend | ใช้ `tlswrap` (ข้อ 4) แล้วชี้ `API_BASE_URL` ไปที่ `http://127.0.0.1:8081` |
| `docker compose up --build` fail ที่ "load build context" / "invalid file request" | checkout อยู่บนโฟลเดอร์ BeeStation sync แล้วไฟล์กลายเป็น cloud placeholder | build จาก git object สะอาด: `git archive HEAD server \| tar -x -C <ascii-tmp>/ctx && docker build -t srisurart-pos/server:local <ascii-tmp>/ctx/server` แล้ว `up -d` ไม่ต้อง `--build` |
| container ไหนก็ตามค้าง `(health: starting)` นาน | Postgres/Redis ยังไม่พร้อม (เครื่องช้าตอน build ครั้งแรก) | รอเพิ่ม แล้วดู log: `docker compose logs <service>` |
| ลืม `-f` ชุดเดิมตอนรันคำสั่งอื่น (เช่น `docker compose run migrate`) | compose มองว่าสแตกไม่ตรงไฟล์ แล้ว recreate `postgres` ทิ้ง port ของ dev overlay | ใส่ `-f` ชุดเดิมทุกครั้ง แล้ว `up -d` ซ้ำเพื่อคืน port |
| `etcd` ค้าง `(unhealthy)` ตลอด ส่วนอื่น healthy หมด | volume `etcd-data` จากรอบก่อน bake รหัสผ่านไม่ตรง `.env` (#365) | ไม่บล็อกอะไร ใช้งานต่อได้ — อย่า `down -v` (ข้อ 3) |
| `bootstrap-admin` บอก `already exists — password left alone` แล้ว login admin ไม่ผ่าน | admin มีอยู่แล้วใน `pgdata` รอบก่อน รหัสใหม่ไม่ถูกบันทึก | รันซ้ำพร้อม `--force` (ข้อ 5.1) ต้องเห็น `password reset` |
| `tenants:create` ได้ `409 … already exists` | `--code`/`--owner-username` ซ้ำของเดิมใน volume | ใช้ code + username ใหม่ (ข้อ 5.2) |
| platform CLI login ไม่ผ่านทั้งที่รหัสถูก (pipe จาก PowerShell) | PowerShell pipe ส่งข้อความเข้า stdin ไม่ตรงตัว | พิมพ์รหัสแบบ interactive หรือใช้ Git Bash `printf '%s\n'` (ข้อ 5.2) |
| Grafana panel "Disk usage (/)" ไม่มีข้อมูล | `node-exporter` mount `/:/rootfs:ro` แต่ Docker Desktop รันบน WSL VM ไม่ใช่ดิสก์ Windows ตรง ๆ | รู้ไว้เฉย ๆ ไม่ใช่บั๊ก จะขึ้นปกติบน `mob04` (Linux จริง) |
| ยิงตรงไปที่ `/api/v1/platform/...` จาก host (หรือผ่าน `ssh -L`) ได้ `403 Forbidden` | docker-proxy เปิด connection ใหม่เข้า container — nginx และ guard เห็น IP เป็น gateway (`172.30.0.1`) ไม่ใช่ `127.0.0.1` · เกิดบนทุกโฮสต์ รวม `mob04` (#335 D3) | ใช้หน้าเว็บ http://127.0.0.1:3200 (ข้อ 5.2 ทาง A) หรือ platform CLI จาก**ภายใน container `api-1` เอง**: `docker compose exec api-1 node dist/cli/platform.js login --user <admin>` (ข้อ 5.2 ทาง B) |
| หน้าเว็บ `:3200` เปิดได้ แต่ login/โหลดรายชื่อร้านได้ `403` | IP ของ `platform-ui` ไม่อยู่ใน allowlist ชั้นใดชั้นหนึ่ง: `server/.env` ตั้ง `PLATFORM_ADMIN_IPS` ทับโดยไม่มี `172.30.0.20` (ผ่าน nginx แต่ตายที่ guard) หรือ network ถูกสร้างใหม่จน `platform-ui` เสีย IP ตายตัว | ลบ `PLATFORM_ADMIN_IPS` ออกจาก `.env` (ค่า default คือ `172.30.0.20`) หรือใส่ `172.30.0.20` เพิ่มในลิสต์ แล้ว `up -d` · เช็ค IP: `docker inspect srisurart-pos-platform-ui-1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'` ต้องได้ `172.30.0.20` |

---

## อ้างอิง

- `server/README.md` — รายละเอียดเต็มของทุก service, environment variable, runbook
- `docs/handoff_log/demo-rehearsal-dev-2026-09-21.md` §9 — ที่มาของ workaround `tlswrap`
  และปัญหาอื่น ๆ ที่เจอตอนซ้อมเดโมจริง
- `docs/Backend_design/07_CICD_DEPLOY.md` §10 — monitoring overlay แบบเดียวกับที่ deploy
  บน `mob04`
