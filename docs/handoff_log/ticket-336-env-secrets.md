# #336 `env.secrets` — สุ่ม secrets ครบชุด แล้วสแตกขึ้นได้จากคลีนโคลน

สเปกแม่ #335 (D1) · lane A · ตรวจกับ `main` ที่ `1f4dffc` เมื่อ 2026-09-20

> ใบนี้ไม่ได้เพิ่มโค้ด — สิ่งที่ส่งมอบคือ **ไฟล์ `.env` สองชุดที่ไม่อยู่ใน git** บวกเอกสารนี้
> `server/.env.example` **ไม่ถูกแก้** (มีครบทุกคีย์อยู่แล้ว — ช่องว่างคือยังไม่ได้สุ่มค่า)

---

## 1. คีย์ที่ต้องมี

compose บังคับด้วย `:?` (ขึ้นไม่ได้ถ้าขาด) **10 ตัว** — ตรวจซ้ำได้ด้วย
`grep -ohE '\$\{[A-Z_0-9]+:\?[^}]*\}' server/docker-compose.yml deploy/compose/*.yml | sort -u`

| คีย์ | บังคับที่ | หมายเหตุ |
|---|---|---|
| `POSTGRES_PASSWORD` | `docker-compose.yml:23,118,185` | ใช้ทั้ง `ADMIN_DATA_SOURCE` และ `migrate` |
| `POS_APP_PASSWORD` | `:19,186` | ฝังใน URL **และ** ใน SQL literal ที่ `docker/postgres/init/01-app-role.sh:7` |
| `REDIS_PASSWORD` | `:27,28,204,216,230,241` | ฝังใน URL สองเส้น + `REDISCLI_AUTH` |
| `JWT_PLATFORM_SECRET` | `:26` | HS256 ของ platform-admin token · ถ้าขาด `config.ts:91` fallback เป็นสตริง dev ที่เป็นสาธารณะ |
| `ETCD_ROOT_PASSWORD` | `:36,295,316` | ดูกับดัก §4 |
| `BULL_BOARD_PASSWORD` | `:169` | — |
| `JWT_PRIVATE_KEY` / `JWT_PUBLIC_KEYS` | `:130-131,138-139,146-147` | RS256 ของ token ฝั่งร้าน |
| `K6_REMOTE_WRITE_BASIC_AUTH_USER` / `_PASSWORD` | `:103-104` | `htpasswd-gen` ของ **สแตกหลัก** ไม่ใช่ overlay — ขาดแล้วสแตกไม่ขึ้นทั้งที่ไม่ได้รัน k6 |

คีย์ที่ **ไม่ใช่ `:?` แต่ต้องใส่**:

- `BULL_BOARD_USER` — `docker-compose.yml:168` ใส่ default `admin` ให้ แต่ `src/bull-board.ts:20` เรียก `requiredEnv()` · รอดได้เพราะ default ของ compose เท่านั้น ใส่ไว้ตรง ๆ ดีกว่า
- `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` — `deploy/compose/monitoring.yml:89,92` (password เป็น `:?` เมื่อเปิด overlay)
- `DB_POOL_SIZE` / `LOG_LEVEL` / `REDIS_COMMAND_TIMEOUT_MS` — มี default อยู่แล้ว ใส่ไว้ให้อ่านง่าย

คีย์ที่ **ห้ามใส่**:

- `IMAGE_TAG` — `deploy/compose/vm.override.yml:11` บังคับก็จริง แต่ `deploy/ansible/deploy.yml:186` ส่งเป็น shell env var ซึ่ง **ชนะไฟล์ `.env`** · ค่าที่ปักไว้ในไฟล์จะกลายเป็น tag เก่าค้างที่ไม่มีใครสังเกต

---

## 2. วิธีสุ่ม

**charset: hex เท่านั้น** — `POS_APP_PASSWORD` / `POSTGRES_PASSWORD` / `REDIS_PASSWORD` ถูกแทนลงใน
URL (`docker-compose.yml:19,27,28,118`) และ `POS_APP_PASSWORD` ถูกแทนลงใน single-quoted SQL
literal อีกชั้น (`01-app-role.sh:7`) — `/`, `+`, `@`, `'` พังทั้งคู่ `openssl rand -base64` จึงใช้ไม่ได้

```bash
openssl rand -hex 24      # password ทั่วไป
openssl rand -hex 32      # JWT_PLATFORM_SECRET
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt.key   # PKCS#8 = BEGIN PRIVATE KEY
openssl rsa -in jwt.key -pubout -out jwt.pub
```

🔴 **PEM ต้องคงรูป multi-line ในเครื่องหมายคำพูด** แบบเดียวกับ `.env.example:51-78`
`server/test/k6/setup.ts:39` แกะคีย์ออกจากไฟล์ด้วย regex `JWT_PRIVATE_KEY="([^"]+)"` และ `:44`
throw ถ้าไม่เจอ — เขียนเป็น `\n` บรรทัดเดียวหรือไม่ใส่ quote แล้ว `pnpm k6:setup` (#184/#251, lane C) พัง

---

## 3. สองไฟล์ ต่างกันตรงไหน

| | `server/.env` (dev) | `DEMO_ENV_FILE` (VM — `provision.yml:124-131` เขียนลง `/opt/pos/.env`) |
|---|---|---|
| `POSTGRES_PASSWORD` / `POS_APP_PASSWORD` / `REDIS_PASSWORD` | **คงค่า `dev-only-*` ไว้ตามเดิม** (เหตุผลด้านล่าง) | สุ่มใหม่ทั้งสามตัว |
| คีย์ที่เหลือทุกตัว | สุ่มใหม่หมด | สุ่มใหม่หมด **คนละค่ากับ dev** |
| `JWT_PRIVATE_KEY` / `JWT_PUBLIC_KEYS` | คู่กุญแจใหม่ (ของเดิมใน `.env.example` เป็น dummy สาธารณะ) | อีกคู่หนึ่ง คนละคู่กับ dev |
| `IMAGE_TAG` | ไม่มี | ไม่มี — Ansible ส่งเอง |

### ทำไม dev ยังใช้ `dev-only-*` สำหรับสามตัวนั้น

ชุดเทสต์ e2e **hardcode ค่าสามตัวนี้ไว้เป็น default** และไม่มีใคร export `DATABASE_URL` ให้:
`test/support/fixture.ts:96,104,105`, `test/schema.e2e-spec.ts:25-26`,
`test/support/e2e-runner-lock.ts:31`, `test/k6/setup.ts:23`, `test/health.e2e-spec.ts:16-18`,
`test/idempotency.e2e-spec.ts:176-181`, `test/backoff-strategy.e2e-spec.ts:34-36`

สุ่มค่าใหม่ในไฟล์ dev = `pnpm test:e2e` ของ **ทุกเลน** ตายทันทีโดยไม่มี error ที่ชี้สาเหตุ
รับความเสี่ยงนี้ได้เพราะ dev overlay publish พอร์ตบน loopback เท่านั้น (`docker-compose.dev.yml:9-21`)
และ #335 บรรทัด 34 กำกับไว้เองว่าเครื่อง dev คือ "ที่ไว้รันเทสต์" ของจริงคือ VM
ถ้าจะสุ่มจริงเมื่อไหร่ ต้องแก้ default ในเจ็ดไฟล์นั้นก่อน แล้วประกาศให้ทุกเลนรู้

### ⚠️ ช่องว่างที่พบระหว่างทำใบนี้ (ไม่ได้แก้ในใบนี้)

`CORS_ORIGINS` และ `PLATFORM_ADMIN_IPS` ถูกอ่านจริงที่ `config.ts:95-97,100-102` และ
`app.setup.ts:47-51` ใช้ `'*'` เมื่อว่าง — แต่ **ไม่มี compose ไฟล์ไหนส่งสองคีย์นี้เข้า container**
(`server/docker-compose.yml` ไม่มี `env_file:` และ `x-app-env:18-36` ไม่มีสองคีย์นี้ ·
`docker-compose.dev.yml` และ `deploy/compose/vm.override.yml` ก็ไม่มี) ทั้งที่
`07_CICD_DEPLOY.md:168` ระบุว่า `CORS_ORIGINS` เป็นส่วนหนึ่งของ `DEMO_ENV_FILE`

→ **ใส่ลงไฟล์ตอนนี้ก็ไม่มีผล** และห้ามอ้างว่า VM ปิด CORS แล้ว
การต่อสายเป็นการแก้ compose ซึ่งอยู่นอกอาณาเขตของ lane A — รายงานไว้ที่ #335 แล้ว

---

## 4. กับดัก volume: secret สามตัวถูกอบไว้ตอน bootstrap ครั้งแรก

เปลี่ยนค่าใน `.env` แล้ว **ไม่มีผล** กับ volume ที่ bootstrap ไปแล้ว — ของเก่ายังอยู่เงียบ ๆ

| volume | อบตอนไหน | อ้างอิง |
|---|---|---|
| `pgdata` | `POSTGRES_PASSWORD` + `POS_APP_PASSWORD` ตอน data dir ว่างครั้งแรก | `docker/postgres/init/01-app-role.sh:2,7` — entrypoint ของ postgres รัน `initdb.d` เฉพาะตอน `PGDATA` ว่าง |
| `etcd-data` | `ETCD_ROOT_PASSWORD` ตอน `etcd-init` เปิด RBAC ครั้งแรก | `docker-compose.yml:289-295` — เปลี่ยนทีหลังแล้ว **healthcheck ของ etcd เองจะ fail auth** |
| `nginx-auth` | `K6_REMOTE_WRITE_BASIC_AUTH_*` | `docker-compose.yml:99` — `test -f … ||` ทำให้ re-run เป็น no-op |

`REDIS_PASSWORD` ไม่มีปัญหานี้ (มาจาก `--requirepass` บน command line, `:204,230`) แต่ต้อง recreate container

**ถ้าต้องหมุนค่าจริงบน volume เดิม**: `ALTER ROLE postgres PASSWORD …; ALTER ROLE pos_app PASSWORD …;`
ผ่าน `docker compose exec postgres psql` · `etcdctl user passwd root` · ลบไฟล์ htpasswd แล้วให้ `htpasswd-gen` สร้างใหม่
**ห้าม `docker compose down -v`** และห้าม `docker volume rm srisurart-pos_*`
(กฎ CLAUDE.md + `demo-335-three-agent-split.md` ข้อ 1)

---

## 5. ขั้นตอนตรวจ (รันจริงแล้ว 2026-09-20)

พิสูจน์แบบคลีนโคลนด้วย **project name ทิ้ง** ไม่แตะ volume ของสแตกหลัก
(`-p` บน CLI ชนะ `name: srisurart-pos` ที่ `docker-compose.yml:16`)

```bash
# subnet 172.30.0.0/24 ถูกจองโดย network ของสแตกหลัก จึงต้องปล่อยก่อน — down เปล่า ไม่มี -v
cd server && docker compose down

cd <worktree>/server && docker compose -p pos336verify up -d --build
docker compose -p pos336verify ps -a
curl -sk https://localhost/health/ready
docker compose -p pos336verify logs etcd-init
docker compose -p pos336verify exec -T nginx sh -c 'cut -d: -f1 /etc/nginx/auth/k6-remote-write.htpasswd'
docker compose -p pos336verify run --rm --no-deps --entrypoint sh etcd-init \
  -c 'curl -s -X POST http://etcd:2379/v3/kv/range -d "{\"key\":\"L3Bvcy9jb25maWcvbG9nX2xldmVs\"}"'

# เก็บกวาด: ลบเฉพาะ volume ของโปรเจกต์ทิ้ง ไม่เคยแตะ srisurart-pos_*
docker compose -p pos336verify down
docker volume ls --format '{{.Name}}' | grep '^pos336verify_' | xargs -r docker volume rm

# คืนสแตกหลักให้เลนอื่น
cd server && docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --wait postgres redis-cache redis-queue
```

ผลที่ได้ (ค่า secret ถูกตัดออก):

```
api-1/api-2/api-3   running (healthy)      etcd         running (healthy)
worker              running                postgres     running (healthy)
bull-board          running                redis-cache  running (healthy)
nginx               running                redis-queue  running (healthy)
certgen             exited (0)             migrate      exited (0)
htpasswd-gen        exited (0)             etcd-init    exited (0)

$ curl -sk https://localhost/health/ready
{"status":"success","data":{"status":"up","checks":{"postgres":"up","redisCache":"up","redisQueue":"up"}}}

$ docker compose -p pos336verify logs etcd-init
etcd-init: bootstrapping root user + auth (authenticate got HTTP 400)
etcd-init: asserting root authenticates
etcd-init: asserting anonymous access is refused
etcd-init: auth ok — root authenticates, anonymous access refused (HTTP 400)
etcd-init: seeded /pos/config/log_level = info

$ … cut -d: -f1 /etc/nginx/auth/k6-remote-write.htpasswd
k6

$ … /v3/kv/range  (ไม่ใส่ token)
{"code":3, "message":"etcdserver: user name is empty"}
```

🔴 **`/health/ready` อย่างเดียวพิสูจน์ไม่ได้ว่า "ขึ้นครบทุก service"** — `src/health/health.controller.ts:46-66`
ตรวจแค่ Postgres + Redis สองตัว **ไม่แตะ etcd** สามบรรทัดสุดท้ายข้างบนคือสิ่งที่พิสูจน์
`ETCD_ROOT_PASSWORD` / `K6_REMOTE_WRITE_*` / cert ซึ่งเป็นคีย์ที่ D1 บอกเองว่ามักถูกลืม

หลังคืนสแตกหลักแล้ว ตรวจซ้ำว่า volume เดิมไม่เสีย:

```bash
docker compose exec -T -e PGPASSWORD=dev-only-pos-app postgres psql -U pos_app -d pos -c 'select current_user'
# -> pos_app
```

---

## 6. ไฟล์จริงอยู่ที่ไหน

- `server/.env` (dev) — วางไว้ในเครื่องแล้ว · gitignore ที่ `.gitignore:61`
- เนื้อหาสำหรับ `DEMO_ENV_FILE` ของ VM — ส่งให้เจ้าของทางแชท **ไม่ถูกเขียนลง repo ไม่ว่ากรณีใด**
  เจ้าของเป็นคนวางเป็น GitHub secret `DEMO_ENV_FILE` (ใช้โดย `deploy/ansible/provision.yml`)
- ไฟล์ `.env` เดิมของเครื่อง (9 คีย์ ขาด `ETCD_ROOT_PASSWORD` / `JWT_PLATFORM_SECRET` / `GRAFANA_*` / `K6_*`
  ตรงกับช่องว่างข้อ 1 ของ #335) ถูกสำรองไว้นอก repo แล้ว
