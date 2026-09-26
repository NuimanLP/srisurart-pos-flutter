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

**เช็ค backend ตอบจริง:**

```bash
curl -sk https://localhost/health/live
curl -sk https://localhost/health/ready
```

ควรได้ `{"status":"success","data":{"status":"up", ...}}` ทั้งคู่ (`-k` เพราะ cert เป็น
self-signed สำหรับ dev)

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
(ยังไม่เคยมีใคร login ออนไลน์เลยสักครั้ง) ต้องทำ 3 ขั้นตอนนี้ **ครั้งเดียว** ต่อฐานข้อมูล:

### 5.1 สร้าง platform admin ตัวแรก (ADR-0001 — ทำนอก API เท่านั้น)

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml -f ../deploy/compose/monitoring.yml exec -T \
  -e BOOTSTRAP_ADMIN_USERNAME=devadmin \
  -e BOOTSTRAP_ADMIN_PASSWORD=<รหัสผ่านอย่างน้อย12ตัวอักษร> \
  -e BOOTSTRAP_ADMIN_DISPLAY_NAME="Dev Admin" \
  api-1 sh -c 'DATABASE_URL="postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/pos" node dist/db/bootstrap-admin.js'
```

### 5.2 ล็อกอินเป็น platform admin แล้วสร้าง tenant + shop owner

🔴 `location /api/v1/platform/` ของ Nginx จำกัดแค่ `127.0.0.1` — บน Docker Desktop
(Windows/Mac) การ `curl` จากเครื่องจริงไม่นับเป็น loopback ของ container (เห็นเป็น IP
gateway เช่น `172.30.0.1` แล้วโดน `403 Forbidden`) ให้รันคำสั่งจาก**ภายใน container
nginx เอง** แทน (`docker compose exec nginx …` เป็น loopback จริง):

```bash
# ล็อกอิน platform admin
docker compose exec -T nginx sh -c \
  'curl -sk https://127.0.0.1/api/v1/platform/auth/token \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"devadmin\",\"password\":\"<รหัสผ่านข้อ5.1>\"}"'
# → คัดลอกค่า data.token มาใช้ต่อ (TOKEN=...)

# สร้าง tenant + owner แรก
docker compose exec -T nginx sh -c \
  "curl -sk https://127.0.0.1/api/v1/platform/tenants \
    -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer <TOKEN>' \
    -d '{\"code\":\"demo-shop\",\"shopName\":\"ร้านตัวอย่าง\",\"plan\":\"demo\",\"ownerUsername\":\"owner\",\"ownerPassword\":\"<รหัสผ่านอย่างน้อย12ตัวอักษร>\",\"ownerDisplayName\":\"Shop Owner\"}'"
```

Response จะได้ `tenantId`, `enrolCode` (ใช้สำหรับผูกเครื่อง POS Terminal ทีหลังถ้าต้องการ)

### 5.3 ทดสอบ login แบบ shop-level (ไม่ติด loopback restriction — เรียกจาก host ปกติได้)

```bash
curl -sk https://localhost/api/v1/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"owner","password":"<รหัสผ่านข้อ5.2>"}'
```

ได้ `accessToken`/`refreshToken` กลับมา = ใช้ username/password นี้ **login ใน Flutter web
ที่โหมด "Backoffice"** ได้ทันที (role `owner`)

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
| **Frontend (Flutter web)** | http://127.0.0.1:8090 | ตาม tenant ที่ bootstrap ไว้ (`pnpm bootstrap:admin`) |
| **Backend health** | https://localhost/health/live , https://localhost/health/ready | ไม่ต้อง login |
| **Bull-Board** (คิวงาน) | http://127.0.0.1:3100 | Basic Auth: `BULL_BOARD_USER` / `BULL_BOARD_PASSWORD` ใน `server/.env` |
| **Prometheus** | http://127.0.0.1:9090 | ไม่ต้อง login |
| **Grafana** | http://127.0.0.1:3000 | `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` ใน `server/.env` (ค่า placeholder เริ่มต้นคือ `admin` / `dev-only-grafana` ถ้ายังไม่ได้แก้ `.env`) |

Dashboard ของ Grafana ถูก provision มาให้อัตโนมัติจาก `deploy/grafana/provisioning` —
ไม่ต้องเพิ่ม datasource เอง

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
| Grafana panel "Disk usage (/)" ไม่มีข้อมูล | `node-exporter` mount `/:/rootfs:ro` แต่ Docker Desktop รันบน WSL VM ไม่ใช่ดิสก์ Windows ตรง ๆ | รู้ไว้เฉย ๆ ไม่ใช่บั๊ก จะขึ้นปกติบน `mob04` (Linux จริง) |
| `curl` ไปที่ `/api/v1/platform/...` จาก host ได้ `403 Forbidden` | Docker Desktop (Windows/Mac) ไม่ preserve loopback ผ่าน port publishing — nginx เห็น `remote_addr` เป็น gateway IP (เช่น `172.30.0.1`) ไม่ใช่ `127.0.0.1` ซึ่งเป็นเงื่อนไขเดียวที่ location นี้อนุญาต | รันคำสั่งจาก**ภายใน container `nginx` เอง**: `docker compose exec -T nginx sh -c 'curl -sk https://127.0.0.1/api/v1/platform/...'` (ดูข้อ 5.2) |

---

## อ้างอิง

- `server/README.md` — รายละเอียดเต็มของทุก service, environment variable, runbook
- `docs/handoff_log/demo-rehearsal-dev-2026-09-21.md` §9 — ที่มาของ workaround `tlswrap`
  และปัญหาอื่น ๆ ที่เจอตอนซ้อมเดโมจริง
- `docs/Backend_design/07_CICD_DEPLOY.md` §10 — monitoring overlay แบบเดียวกับที่ deploy
  บน `mob04`
