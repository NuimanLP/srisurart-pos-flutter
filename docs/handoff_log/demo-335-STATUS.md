# 📋 STATUS BOARD — ชุดใบงานเดโม #335 (สามเลนขนานกัน)

**ไฟล์นี้คือแหล่งความจริงเรื่อง "ตอนนี้ใครทำอะไรถึงไหน"** ของ #335
ทุกเลนต้อง **อ่านก่อนเริ่มงาน** และ **อัปเดตหลังปิดทุกใบ**

- แผนแบ่งงาน + กฎกันชนกัน: [`demo-335-three-agent-split.md`](demo-335-three-agent-split.md)
- สเปกแม่: GitHub issue #335 (D1–D10) · **ADR ชนะเอกสารเสมอ**
- อัปเดตล่าสุด: 2026-09-20 · โดย lane A

---

## 🔴 กฎการแก้ไฟล์นี้ (สำคัญ — สามเลนแก้ไฟล์เดียวกัน)

1. **แก้เฉพาะบล็อกของเลนตัวเอง** (§3) และเติม §2 ได้ · **ห้ามแก้บล็อกของเลนอื่น** แม้จะเห็นว่าผิด
   — ถ้าเห็นว่าผิดให้เขียนใน §2 ว่าเห็นอะไร แล้วให้เจ้าของบล็อกแก้เอง
2. **เติมบรรทัดใหม่ไว้บนสุดของบล็อก** (ใหม่ → เก่า) อย่าแทรกกลางหรือเขียนทับของเดิม
   ประวัติที่ผ่านไปแล้วมีค่าพอ ๆ กับสถานะปัจจุบัน
3. **commit ไฟล์นี้ไฟล์เดียว ไม่ปนกับโค้ด** ข้อความ: `docs(status): lane <X> — <ใบ> <สถานะ>`
   ก่อน push ให้ `git fetch origin && git rebase origin/main` เสมอ — ถ้าชนที่ไฟล์นี้
   ให้ **เก็บทั้งสองฝั่ง** ไม่ต้องเลือกข้าง (คนละบล็อกกัน)
4. อัปเดต **ตอนปิดใบ** และ **ตอนติดบล็อกเกอร์** เท่านั้น ไม่ต้องรายงานทุกขั้น
5. **ห้ามติ๊ก `[x]` ถ้ายังไม่ได้รันจริง** — ต้องแปะหลักฐาน (PR / commit / เอาต์พุตคำสั่ง)
   AC ที่ปิดบางส่วนให้เขียนว่า "ปิดบางส่วน" พร้อมเหตุผล ไม่ใช่ติ๊กเต็ม

---

## 1. ตารางใบงาน (ภาพรวม)

| ใบ | ชื่อ | เลน | สถานะ | PR | หมายเหตุ |
|---|---|---|---|---|---|
| #336 | `env.secrets` | A | ✅ **merged** `6d3219f` | #352 | สแตกพร้อมแล้ว — B/C ทดสอบจริงได้ |
| #337 | `admin.bootstrap` | A | 🔨 กำลังทำ | — | blocked by #336 (ปลดแล้ว) |
| #338 | `platform.provision` | A | ⏸️ รอ #337 | — | ต้องต่อ VPN สำหรับขา VM |
| #339 | `metrics.serve` | B | ❓ ยังไม่รายงาน | — | เขียนโค้ดได้เลย · ทดสอบจริงได้แล้ว |
| #340 | `dashboard` | B | ⏸️ รอ #339 | — | — |
| #341 | `replay` counter | B | ⏸️ รอ #340 | — | — |
| #342 | `web.server-build` | C | ❓ ยังไม่รายงาน | — | เริ่มได้ทันที ไม่ต้องรอใคร |
| #346 | `ops.backup-scripts` | C | ❓ ยังไม่รายงาน | — | อิสระ ไม่บล็อกใคร |
| #343 | `vm.deploy` 🔒 | C | ⏸️ รอ VPN | — | #336 ปลดแล้ว เหลือรอเจ้าของต่อ VPN |
| #344 | `vm.demo` 🔒 | — | ⏸️ รอทั้งสามเลน | — | งานรวมตอนท้าย ไม่มอบให้เลนใด |
| #345 | `reconcile` | — | ⏸️ รอ #344 | — | ปิดท้าย |

สถานะ: ✅ merged · 🔨 กำลังทำ · 👀 รอรีวิว/CI · ⏸️ รอใบอื่น · 🛑 ติดบล็อกเกอร์ · ❓ ยังไม่รายงาน

---

## 2. 📣 ประกาศข้ามเลน (ใหม่ → เก่า)

> ที่นี่สำหรับ **เรื่องที่กระทบเลนอื่น** เท่านั้น: ปลดบล็อก, ของที่พัง, ของที่ต้องรู้ก่อนลงมือ
> รูปแบบ: `- **YYYY-MM-DD HH:MM · lane X** — เรื่อง`

- **2026-09-20 15:20 · lane A** — 🔴 **เจอช่องว่างที่ยังไม่มีใครรู้: `CORS_ORIGINS` และ
  `PLATFORM_ADMIN_IPS` ไม่ถูกส่งเข้า container โดย compose ไฟล์ใดเลย**
  (`server/docker-compose.yml` ไม่มี `env_file:` · `x-app-env:18-36` ไม่มีสองคีย์นี้ ·
  `docker-compose.dev.yml` / `deploy/compose/vm.override.yml` ก็ไม่มี) ทั้งที่
  `src/config/config.ts:95-97,100-102` อ่านจริงและ `07_CICD_DEPLOY.md:168` ระบุว่าเป็นส่วนหนึ่ง
  ของ `DEMO_ENV_FILE` → **VM ยังเปิด CORS กว้าง** ห้ามใครเขียน AC ว่า "ปิด CORS แล้ว"
  รายงานที่ #335 (`#issuecomment-5750642942`) รอเจ้าของตัดสินว่าจะเปิดใบแยกหรือให้ #343 รับไป

- **2026-09-20 15:15 · lane A** — ✅ **#336 merged — เลน B รันทดสอบจริงได้แล้ว · #343 เหลือรอแค่ VPN**
  `server/.env` ของเครื่อง dev ครบทุกคีย์แล้ว ไม่ต้องแก้อะไรเพิ่ม
  สแตกหลัก (postgres / redis-cache / redis-queue ผ่าน dev overlay) รันอยู่
  ตรวจแล้วว่า `pos_app` ล็อกอินได้ → `pnpm test:e2e` ใช้ได้เหมือนเดิม

- **2026-09-20 15:10 · lane A** — ⚠️ **คง `dev-only-*` ไว้สามคีย์ในไฟล์ dev โดยตั้งใจ**
  (`POSTGRES_PASSWORD` / `POS_APP_PASSWORD` / `REDIS_PASSWORD`) เพราะ e2e **แปดไฟล์**
  hardcode ค่านี้เป็น default และไม่มีใคร export `DATABASE_URL` ให้ — สุ่มทับแล้ว
  `pnpm test:e2e` ของทุกเลนตายโดยไม่มี error ที่ชี้สาเหตุ · ไฟล์ของ VM สุ่มครบทุกคีย์
  รายละเอียด: [`ticket-336-env-secrets.md`](ticket-336-env-secrets.md) §3

- **2026-09-20 15:05 · lane A** — ℹ️ **รัน `docker compose down` (ไม่มี `-v`) ที่สแตกหลักหนึ่งครั้ง**
  เพื่อปล่อย subnet `172.30.0.0/24` ให้สแตกทิ้งใช้ตอนพิสูจน์คลีนโคลน
  volume ไม่ถูกแตะ คืนสแตกแล้ว — ถ้าใครรัน e2e ค้างอยู่ช่วงนั้นให้รันใหม่

---

## 3. บล็อกของแต่ละเลน

### 3.1 Lane A — platform (`NuimanLP` · #336 → #337 → #338)

**อาณาเขตไฟล์:** `server/.env` (ไม่เข้า git) · `server/src/db/` · `server/src/common/password.ts`
(อ่านอย่างเดียว) · ไฟล์ใหม่ใน `server/test/` · runbook ใน `docs/handoff_log/`
**ห้ามแตะ:** `.github/` · `deploy/` · `server/docker/nginx/nginx.conf` · `server/src/app.setup.ts`

| ใบ | สถานะ | หลักฐาน |
|---|---|---|
| #337 `admin.bootstrap` | 🔨 กำลังทำ | อ่าน D2 + `migrate.ts` / `data-source.ts` / `password.ts` / DDL `platform_admins` / เงื่อนไขสแกนของ `tenant-door.spec.ts` แล้ว |
| #336 `env.secrets` | ✅ merged `6d3219f` | PR #352 · [`ticket-336-env-secrets.md`](ticket-336-env-secrets.md) · 15/15 service ขึ้นครบ, `/health/ready` เขียว, etcd RBAC + htpasswd + cert ตรวจแยก · AC ข้อ 1 **ปิดบางส่วนโดยตั้งใจ** (ไฟล์ dev คง `dev-only-*` สามคีย์) |

**บันทึกที่เลนอื่นอาจใช้ซ้ำได้:**
- กับดัก volume: `pgdata` / `etcd-data` / `nginx-auth` **อบ secret ไว้ตอน bootstrap ครั้งแรก**
  เปลี่ยน `.env` ทีหลังไม่มีผล — จะไปเจออีกทีบน VM (ticket-336 §4)
- `/health/ready` **ไม่แตะ etcd** (`health.controller.ts:48-68`) อย่าใช้ตัวเดียวพิสูจน์ว่าขึ้นครบ
- พิสูจน์คลีนโคลนด้วย `-p <ชื่อทิ้ง>` แล้วลบเฉพาะ volume ที่ขึ้นต้นด้วยชื่อนั้น — **ไม่เคย `down -v`**

---

### 3.2 Lane B — observability (`LomerAlloys` · #339 → #340 → #341)

**อาณาเขตไฟล์:** โมดูล metrics ใหม่ใน `server/src/` · `server/src/app.setup.ts` ·
`server/docker/nginx/nginx.conf` · `deploy/prometheus/` · `deploy/grafana/` · ไฟล์ใหม่ใน `server/test/`
**ห้ามแตะ:** `server/src/db/` · `.github/` · `deploy/ansible/` · `deploy/scripts/`

| ใบ | สถานะ | หลักฐาน |
|---|---|---|
| #339 `metrics.serve` | ❓ ยังไม่รายงาน | _(lane B เติมตรงนี้)_ |
| #340 `dashboard` | ⏸️ รอ #339 | — |
| #341 `replay` counter | ⏸️ รอ #340 | — |

**เตือนจาก D4/D5/D7 — อ่านก่อนลงมือ:**
- ต้องเพิ่ม `metrics` เข้า `exclude` ของ `setGlobalPrefix` ไม่งั้น route ไปอยู่ `/api/v1/metrics`
- ต้องเลี่ยง `EnvelopeInterceptor` ด้วย `@Res()` + `res.send()` ไม่งั้น text format ถูกห่อเป็น JSON
- ต้องเพิ่ม `location = /metrics { return 404; }` ใน `nginx.conf` ไม่งั้นภายนอกได้ 200 + index.html
- hook ที่ใช้ได้คือ **Express middleware** ไม่ใช่ interceptor (401/403/429 ไม่มีวันถึง interceptor)
- label `route` ต้องเป็น **route pattern** ไม่ใช่ path จริง (ตรงข้ามกับ idempotency fingerprint — จงใจ)
- ชื่อ `http_requests_total` / `http_request_duration_seconds` **ถูกล็อกโดย expr ของ panel ที่มีอยู่**
- `pos_idempotency_replay_total` นับผ่าน `onTransactionCommit()` เท่านั้น · **ห้ามใส่ `tenant_id` เป็น label**

---

### 3.3 Lane C — client/CI + ops (`PattaraponKitcharoen` · #342 → #346 → #343)

**อาณาเขตไฟล์:** `.github/workflows/flutter.yml` · `deploy/ansible/` · `deploy/scripts/`
**ห้ามแตะ:** `server/src/` · `server/docker/nginx/nginx.conf` · `server/.env`

| ใบ | สถานะ | หลักฐาน |
|---|---|---|
| #342 `web.server-build` | ❓ ยังไม่รายงาน | _(lane C เติมตรงนี้)_ |
| #346 `ops.backup-scripts` | ❓ ยังไม่รายงาน | — |
| #343 `vm.deploy` 🔒 | ⏸️ รอ VPN | #336 ปลดแล้ว |

**เตือนจาก D8/D9/D10 — อ่านก่อนลงมือ:**
- D8: image เว็บจะไม่ใช่ build ออฟไลน์อีกต่อไป · **ต้องรอ CI build image ของ commit นั้นเสร็จก่อน deploy**
- D9: `/opt/pos/.env` วางโดย `provision.yml` ไม่ใช่ `deploy.yml` · ต้องรันจาก `deploy/ansible/` ·
  ต้องส่ง `-e image_tag=<40-hex>` (+ `force_redeploy=true` ถ้า SHA ซ้ำ) ·
  **rollback ของจริงคือ `ansible-playbook … -e image_tag=<old>` ไม่ใช่ `pos-deploy.sh`** ·
  `rescue` ของขั้น monitoring แค่เตือน ไม่ล้ม → ต้องตรวจ Grafana แยก
- D10: ต้อง **แก้ #184 และ #196 ให้ตรงความจริง** และแจ้งเจ้าของใบก่อนแก้ ไม่ใช่แก้เงียบ ๆ
- `K6_REMOTE_WRITE_BASIC_AUTH_*` อยู่ใน `.env` ทั้งสองไฟล์แล้ว (lane A ทำให้) — ดู ticket-336 §1

---

## 4. ของที่ยังค้างอยู่ทั้งชุด

- 🔑 **เจ้าของต้องเก็บค่า `DEMO_ENV_FILE`** ที่ lane A สุ่มให้ (ส่งทางแชท ไม่อยู่ใน repo)
  แล้ววางเป็น GitHub secret ชื่อ `DEMO_ENV_FILE` — ถ้าไม่เก็บ #343 เริ่มไม่ได้
- 🔒 **VPN** — #343 / #344 เป็น HITL รอเจ้าของต่อ
- ❓ `CORS_ORIGINS` / `PLATFORM_ADMIN_IPS` จะให้ใครรับไป (ดู §2)
- 🌫️ ยังไม่ชัดตาม #335: ข้อมูลตัวอย่างในเดโม (import snapshot จริงหรือ seed มือ) ·
  self-signed cert ตอนนำเสนอ · ผู้ประเมินต้องอยู่ในเครือข่ายมหาลัยไหม
