# 📋 STATUS BOARD — ชุดใบงานเดโม #335 (สามเลนขนานกัน)

**ไฟล์นี้คือแหล่งความจริงเรื่อง "ตอนนี้ใครทำอะไรถึงไหน"** ของ #335
ทุกเลนต้อง **อ่านก่อนเริ่มงาน** และ **อัปเดตหลังปิดทุกใบ**

- แผนแบ่งงาน + กฎกันชนกัน: [`demo-335-three-agent-split.md`](demo-335-three-agent-split.md)
- สเปกแม่: GitHub issue #335 (D1–D10) · **ADR ชนะเอกสารเสมอ**
- อัปเดตล่าสุด: 2026-09-21 · โดย lane A

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
| #337 | `admin.bootstrap` | A | ✅ **merged** | #359 | `pnpm bootstrap:admin` + e2e 6/6 · ล็อกอินผ่าน nginx จริงแล้ว |
| #338 | `platform.provision` | A | ✅ **merged** | #360 | ขา dev ปิดครบ (มี tenant `srisurart-demo` จริง) · ขา VM ปิดครึ่ง รอ VPN |
| #339 | `metrics.serve` | B | ✅ **merged** | #349 | PR เปิดแล้ว · text format, bypass envelope, Nginx 404 block, route pattern label, e2e ผ่าน |
| #340 | `dashboard` | B | ✅ **merged** | #350 | PR เปิดแล้ว · base #349 · scrape target api-metrics, panel titles, 07_CICD_DEPLOY.md |
| #341 | `replay` counter | B | ✅ **merged** | #351 | PR เปิดแล้ว · base #350 · pos_idempotency_replay_total (no tenant_id), onTransactionCommit, panels 11 & 12, e2e ผ่าน (commit vs rollback) |
| #342 | `web.server-build` | C | ✅ **merged** `c8eb552` | #353 | CI สร้าง image ของ merge commit สำเร็จแล้ว (Flutter CI #35554301669) |
| #346 | `ops.backup-scripts` | C | 🔄 AC1/AC3 ค้าง | #356 + #361 (merged) | คัดลอกสคริปต์ ops ครบสามตัวขึ้น VM + cron เก็บ log แล้ว · 🔴 **AC1 premise กลับด้าน**: `crontab -l -u deploy` ว่าง ⇒ cron ไม่เคยถูกติดตั้งเลย ไม่ใช่ล้มเงียบ · AC3 รอ `provision.yml` รันบน VM · off-site backup แยกเป็น #363 |
| #343 | `vm.deploy` 🔒 | C | 🔄 pre-flight เสร็จ รอเจ้าของรัน | #362 | VPN ต่อแล้ว · `-m ping` SUCCESS · D9 เคลียร์ 5/6 · **ยังไม่ติ้ก AC ข้อใด** · 🔴 บล็อกเกอร์: `/opt/pos/.env` (2026-09-15) ขาด `K6_REMOTE_WRITE_BASIC_AUTH_*` ⇒ `:?` ทำให้ `docker compose pull` ตายก่อน — `provision.yml` (user `cloud`) ปลด · `deploy.yml` ต้องใช้ user `deploy` |
| #344 | `vm.demo` 🔒 | — | ⏸️ รอทั้งสามเลน | — | งานรวมตอนท้าย ไม่มอบให้เลนใด |
| #345 | `reconcile` | C | ✅ **ทำแล้ว** | — | #184 เปิดกลับพร้อมคอมเมนต์แจ้งเจ้าของใบ **ไม่ติ้กช่องใด** (AC ว่างทั้งสี่ ไม่มีหลักฐาน) · #196 ลบ *needs owner secrets* แล้วแทนด้วยบล็อกเกอร์จริง · ติ้ก #292–#297 ครบหก แต่กำกับว่าห้ามใช้ติ้กช่อง `03 §8` |

สถานะ: ✅ merged · 🔨 กำลังทำ · 👀 รอรีวิว/CI · ⏸️ รอใบอื่น · 🛑 ติดบล็อกเกอร์ · ❓ ยังไม่รายงาน

---

## 2. 📣 ประกาศข้ามเลน (ใหม่ → เก่า)

> ที่นี่สำหรับ **เรื่องที่กระทบเลนอื่น** เท่านั้น: ปลดบล็อก, ของที่พัง, ของที่ต้องรู้ก่อนลงมือ
> รูปแบบ: `- **YYYY-MM-DD HH:MM · lane X** — เรื่อง`

- **2026-09-21 11:45 · lane A** — 🎁 **มีร้านจริงให้ทดสอบบน dev แล้ว: tenant `srisurart-demo`**
  (owner `owner_demo`, เครื่อง `pos1` ผูกเรียบร้อย) สร้างด้วย `POST /platform/tenants` ตอนทำ #338
  → เลน B/C เอาไปทดสอบหน้าเว็บโหมด server ได้ทันที ไม่ต้อง provision เอง
  รหัสของร้านเดโมบนเครื่อง dev: `owner_demo` / `demo-owner-secret-1` — **dev-only** อยู่ใน
  Postgres ของ compose บนเครื่องนี้เท่านั้น ไม่ใช่ค่าที่ใช้บน VM (VM ต้อง provision ใหม่
  ด้วยรหัสของตัวเอง) · วิธีเอา token + วิธี provision ร้านของตัวเองอยู่ใน
  [`ticket-338-platform-provision.md`](ticket-338-platform-provision.md)
  · ตรวจแล้วว่า **ไม่ทำให้ e2e ของใครพัง** (ไม่มี suite ไหน assert จำนวนแถวใน `tenants`)
  · ถ้าจะลบ ต้องลบตามลำดับ FK ที่เขียนไว้ใน runbook §5 (อย่าลบ `tenants` ก่อน)
  · 🔴 **เตือนไว้กันเสียเวลา: `/api/v1/platform/…` ยิงจากโฮสต์ไม่ได้** ได้ 403 เพราะ
  docker-proxy ทำให้ `$remote_addr` เป็น `172.30.0.1` — ต้อง `docker compose exec -T nginx wget …
  https://127.0.0.1/…` เท่านั้น (วัดจริงแล้ว ดู runbook §1) · และ BusyBox `wget` ต้องใช้ `--post-file`

- **2026-09-21 11:30 · lane B** — 🔧 **quality pass ของสแตก #349/#350/#351 เสร็จ — rebase บน `main` +
  force-push แล้ว (ยังไม่ merge · เจ้าของกดเอง)**
  สามอย่างที่เลนอื่นอาจกระทบ: (1) `nginx.conf` เปลี่ยนเป็น `location = /metrics` ไม่ใช่ `^~` —
  path ที่ขึ้นต้นด้วย `/metrics` (เช่น route SPA) ไม่ถูกบล็อกอีกแล้ว · (2) **middleware ไม่นับ
  `/metrics` `/health/live` `/health/ready`** เพราะ scrape + healthcheck เป็น 200 การันตีที่กลบ
  SLI จริง — ใครเขียน panel ใหม่บน `http_requests_total` ต้องรู้ว่าสามเส้นนี้ไม่มีในซีรีส์ ·
  (3) `MetricsService` เป็น dependency แบบ **required** ของ `IdempotencyService` แล้ว — กราฟที่
  ขาด `MetricsModule` จะ fail ตอน bootstrap ไม่ใช่เงียบ
  ผลรันจริงบนสแตก `laneb339`: lint ✅ · typecheck ✅ · unit 397/397 ✅ · e2e 591 ผ่าน / 2 แดง
  (`backup-restore` exec-bit บน Windows + `stock-race-three-writers` 600 concurrent) — **ยืนยันแล้วว่า
  สองใบนี้แดงบน `origin/main` เปล่า ๆ ในเครื่องนี้ด้วย ไม่ใช่ของสแตกนี้**

- **2026-09-21 11:15 · lane A** — ℹ️ **สแตก dev เต็ม (15 service) ขึ้นอยู่บนเครื่องนี้ และ image
  `srisurart-pos/server:local` ถูก build ใหม่จาก branch `feat/337-admin-bootstrap`**
  (เพิ่มแค่ไฟล์ใหม่ `src/db/bootstrap-admin.ts` — ไม่แก้โค้ดเดิม) ใครจะทดสอบต่อไม่ต้อง build ใหม่
  แต่ถ้าอยากได้ของ `main` เป๊ะ ๆ ให้ build ทับเองได้เลย · **ไม่เคย `down -v`** และไม่แตะ volume ใด
  · มี platform admin `vmform-337` ค้างไว้ใน dev DB **โดยตั้งใจ** เพื่อให้ #338 ยิง
  `POST /api/v1/platform/tenants` ต่อได้ (รหัสอยู่ใน `ticket-337-admin-bootstrap.md` §6 — dev เท่านั้น)
  · วิธีสร้าง admin ของตัวเองอยู่ใน runbook ของ #337

- **2026-09-21 09:40 · lane C** — ⚠️ `Deploy (demo)` ถูก trigger อัตโนมัติหลัง CI ของ
  merge commit แม้ #343 ยังเป็น HITL: run `35554527721` (commit `c8eb552`) ไปถึง
  `resolve release` แต่ job `deploy to demo` **ไม่มี runner และไม่มี step เริ่ม** ก่อนถูกยกเลิก;
  run ของ `325bf80` (`35554800740`, `35554806746`) ก็ถูกยกเลิกแล้ว → จึง **ไม่มีหลักฐานว่า VM
  ถูก deploy** จากสอง merge นี้ และห้ามนับเป็นการรัน #343. ต้องให้เจ้าของตัดสินว่าจะปิด/ปรับ
  auto-deploy อย่างไร ก่อนอนุญาต VM runbook.

- **2026-09-20 23:00 · lane B** — ✅ **#339, #340, #341 เสร็จครบทั้ง 3 ใบ — เปิด PR #349, #350, #351 แล้ว**
  เลน B ปิดงาน observability: `/metrics` พร้อมให้ Prometheus scrape, dashboard มี 12 panels ครบ
  (รวม Error Rate และ Idempotent Replays), counter `pos_idempotency_replay_total` นับผ่าน `onTransactionCommit`
  และไม่ใส่ `tenant_id` ตาม D5 · Architecture tests และ E2E metrics tests ผ่านครบ 100%


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
| #338 `platform.provision` | 👀 รอรีวิว/CI | PR **#360** · [`ticket-338-platform-provision.md`](ticket-338-platform-provision.md) · **ไม่แก้โค้ดเลย** (บริการทำครบอยู่แล้ว) · พิสูจน์บนสแตก dev เต็ม: `POST /platform/tenants` จากใน netns ของ nginx → `enrolCode=BE00CB85`, tenant `srisurart-demo` · psql ยืนยัน ADR-0001 ข้อ 4/5 ครบหกแถวในธุรกรรมเดียว (owner role=owner · settings 7%/30 วัน · 5 หมวด · `pos1` no=1 role=pos · audit) · เดินต่อจน `/auth/device` → deviceToken → `/auth/token` ได้ accessToken ที่มี `tid` ใหม่ · ยิงจากโฮสต์ได้ **403** พร้อม log `client: 172.30.0.1` `upstream=""` = หลักฐานตัวเลขว่า `ssh -L` ใช้ไม่ได้ · `nginx.conf` ไม่แก้ `PLATFORM_ADMIN_IPS` ไม่ตั้ง · **ปิดครึ่ง**: AC "คำสั่งชุดเดียวกันบน VM" ยังไม่ได้รันบน `mob04` (รอ VPN) |
| #337 `admin.bootstrap` | 👀 รอรีวิว/CI | PR **#359** · [`ticket-337-admin-bootstrap.md`](ticket-337-admin-bootstrap.md) · `lint`/`typecheck` คลีน · unit 397/397 (รวม `tenant-door.spec.ts` ที่ **ไม่ถูกแก้** และ **ไม่เพิ่ม allowlist**) · e2e ใบนี้ 6/6 · `pnpm test:e2e` เต็ม 578 ผ่าน / 3 แดง ซึ่ง **แดงเหมือนกันบน `origin/main` cd8989b** (backup-restore ×2 ต้องมี `bash` จริง+exec bit บน Windows · stock-race 1 เคส + คำเตือน `#160` Node 24.15.0) · รูปแบบ VM รันจริงบนสแตกเต็มแล้ว: `docker compose run --rm … migrate node dist/db/bootstrap-admin.js` → created แล้ว login ผ่าน nginx loopback ได้ token จริง · **ยังไม่ปิด**: การรันบน `mob04` เอง (รอ VPN) |
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
| #339 `metrics.serve` | 👀 รอรีวิว/CI (ผ่าน quality pass แล้ว) | PR #349 · `prom-client@15.1.3` · bypass global prefix & envelope · `location = /metrics { return 404; }` · route pattern label · e2e `server/test/metrics.e2e-spec.ts` 11 เทสต์ผ่าน |
| #340 `dashboard` | 👀 รอรีวิว/CI | PR #350 · uncomment `api-metrics` job ใน `deploy/prometheus/prometheus.yml` · ล้าง `#34/#35` ใน dashboard และ `07_CICD_DEPLOY.md` |
| #341 `replay` counter | 👀 รอรีวิว/CI (ผ่าน quality pass แล้ว) | PR #351 · `pos_idempotency_replay_total` (no `tenant_id` label) · `onTransactionCommit` hook ใน `IdempotencyService` (dependency แบบ required) · Panels 11 & 12 ใน `pos-overview.json` · e2e ผ่าน (commit vs rollback) |

**Quality pass 2026-09-21 (rebase ทั้งสแตกบน `main` แล้ว force-push · ไม่ merge · ไม่เปิด PR ใหม่):**
- **nginx แก้เป็น `location = /metrics`** (เดิม `^~ /metrics`) ตาม D4 verbatim · วัดจริงด้วย nginx container:
  `=` → `/metrics` 404 แต่ `/metrics-guide` 200 · `^~` → 404 ทั้งสอง (บล็อก route SPA ในอนาคตเกินสเปก)
- **`@Optional()` ของ `MetricsService` ใน `IdempotencyService` ถอดออก** — ไม่มี context ไหนที่ขาด
  `MetricsModule` จริง (มีแต่ `test/idempotency.e2e-spec.ts` ซึ่ง import `AppModule.forRoot` อยู่แล้ว) ·
  `IdempotencyModule` import `MetricsModule` ตรง ๆ + e2e ยืนยัน edge ในกราฟโมดูลจริง (ทดสอบด้วยการ
  ทำลาย wiring แล้วเทสต์แดงจริง)
- 🔴 **middleware ไม่นับ `/metrics` `/health/live` `/health/ready` แล้ว** — scrape 15 วิ × 3 instance +
  healthcheck 15 วิ × 3 เป็น 200 การันตี ถ้านับรวม panel *API success rate* จะอ่าน ~92% ทั้งที่บิลจริง
  พลาดทุกใบ (เจอจาก `/code-review` สองแกนพร้อมกัน)
- **เพิ่มเทสต์ 429** — AC ข้อ 3 ของ #339 ระบุ 429 ไว้แต่ไม่มีเทสต์ (429 คือเคสที่พิสูจน์ว่าต้องใช้
  middleware ไม่ใช่ interceptor)

**บันทึกที่เลนอื่นอาจใช้ซ้ำได้:**
- `/metrics` ให้ scrape จากภายใน compose network เท่านั้น (port 3000 ของ api instance)
- Nginx บล็อก `/metrics` จากภายนอกด้วย `location = /metrics { return 404; }` (exact match ตาม D4 —
  `^~` กว้างเกินไป) · `/metrics/` ยังตกไปที่ SPA ซึ่งไม่เป็นไรเพราะไม่มีอะไรถูก proxy ใต้ path นั้น
- `pos_idempotency_replay_total` ไม่ติด label `tenant_id` ป้องกัน cardinality explosion และรักษา tenant privacy
- Architecture tests (`tenant-door.spec.ts`, `tenant-wrapper.spec.ts`, `idempotency-routes.spec.ts`) เขียวโดยไม่ต้องแก้สเปก
- สแตก dev ของเลน B ใช้ `-p laneb339` + port 55432/56379/56380 (ของ default `srisurart-pos` เป็นของเลน A)

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

#### อัปเดต 2026-09-21 — pre-flight #343 เสร็จ (อ่านอย่างเดียว) · #346 รอบสอง · #345 เสร็จ

> ⚠️ **เซสชันนี้ไม่ได้เปลี่ยนสถานะอะไรบน VM เลย** — อ่านอย่างเดียว + `ansible -m ping` + `--check --diff`
> เท่านั้น · ไม่มีค่า secret ใดถูกอ่านหรือบันทึก อ่านแต่ **ชื่อคีย์** · **ห้ามติ๊ก AC ของ #343 ข้อใด**

| ใบ | สถานะ | หลักฐาน |
|---|---|---|
| #343 `vm.deploy` 🔒 | 🛑 **pre-flight เสร็จ 5/6 · ติด 1 บล็อกเกอร์ · รอเจ้าของกดรัน** | PR **#362** → `ticket-343-vm-deploy.md` (ตาราง D9 6 ข้อ + คำสั่ง copy-paste + ผล `-m ping`/`--check` verbatim §6) |
| #346 `ops.backup-scripts` | 🛑 **ปิดไม่ได้** — AC2/AC4 ปิดแล้ว · AC1 ได้ผล**ตรงข้าม**กับที่ใบเขียน · AC3 รอเจ้าของ | PR **#361** (`References #346`) · `ticket-346-backup-script-install.md` รอบสอง |
| #345 `reconcile` | ✅ **เสร็จ** (ทำก่อน #344 เพราะหลักฐานพร้อมและ D10 สั่งให้แก้ใบ) | #184 **reopen** + คอมเมนต์ข้อเท็จจริง · #196 แก้บรรทัด #184 + ติ๊ก dod หกใบ + คอมเมนต์สรุป |

**สิ่งที่ตรวจได้จริงบน `mob04` (172.30.58.20, 2026-09-21, read-only):**
- `.current_sha` = `8e873cd56a4e3012c0474ebf20027987203a35aa` (merge #234) — **ตามหลัง `main` 188 commit**
  container 13 ตัว `Up 5 days` → **VM ยังไม่เคยถูก deploy จาก `main`**
- 🛑 **บล็อกเกอร์เดียว:** `/opt/pos/.env` เขียน 2026-09-15 ก่อน #251 → **ไม่มี**
  `K6_REMOTE_WRITE_BASIC_AUTH_USER/_PASSWORD` ซึ่ง `server/docker-compose.yml:103-104` บังคับด้วย `:?`
  → `docker compose pull` ตัวแรกของ `deploy.yml` ตายที่ interpolation **ต้องรัน `provision.yml` ด้วย
  `DEMO_ENV_FILE` ของ #336 ก่อน** (คีย์ที่มีอยู่ครบอีก 12 ตัว รวม `ETCD_ROOT_PASSWORD` /
  `GRAFANA_ADMIN_PASSWORD`)
- ✅ **ไม่ต้องยอมดาวน์ไทม์** — `docker network inspect srisurart-pos_default` →
  `IPRange: "172.30.0.128/25"` → assert ที่ `deploy.yml:96-104` ผ่าน · 07 §7 ไม่ต้องทำ **ห้ามทำเผื่อ**
- SHA ที่ควร deploy: **`cd8989b44912076aaa93b347d62c7eaf1530fa82`** (head ของ `main`, image ทั้งสอง
  HTTP 200, Server CI + Flutter CI เขียว, ไม่ต้อง `force_redeploy`) · ซ้อม rollback ที่
  **`325bf802641372b307c791363e890a1cb01a5e5f`** (image ครบ, สูงกว่า `ROLLBACK_FLOOR` `4f3a244`,
  และอยู่หลัง #342 จึงเป็น web image โหมด server แล้ว — `8e873cd` มี image แต่เป็น build ออฟไลน์)

**🔴 สามข้อที่เลนอื่นและคนรัน playbook ต้องรู้:**
1. **`deploy.yml` รันเป็น `cloud` ไม่ได้** — มันเป็น `become: false`, `/opt/pos` เป็น
   `drwxr-xr-x deploy:deploy`, `cloud` fail `test -w /opt/pos` และเข้า docker socket ไม่ได้ ·
   ส่วน **`provision.yml` รันเป็น `deploy` ไม่ได้** เพราะ `deploy` ไม่มี sudo เลย
   → **`provision.yml` = `DEMO_SSH_USER=cloud` (key `mob04-SriStore`) · `deploy.yml` = `deploy`
   (key `deploy_ed25519`)** · `--check` ปิดบั๊กนี้ไว้ (copy เทียบ checksum ไม่เขียน, `command` ถูก skip)
   → default `deploy` ใน `hosts.ini` **ถูกแล้ว ไม่ต้องแก้** (ถูกสำหรับ playbook ที่รันทุก release
   และที่ `pos-deploy.sh` เรียก) — ที่ขาดคือตารางนี้ ไม่ใช่ default อื่น
2. **bind mount ของ Windows เป็น world-writable → Ansible ทิ้ง `ansible.cfg` เงียบ ๆ**
   (`config file = None` แล้ว ping ล้มด้วย `Host key verification failed`) แม้จะ `cd` เข้า
   `deploy/ansible/` ตาม D9 แล้วก็ไม่พอ → **ต้องส่ง `ANSIBLE_CONFIG` ตรง ๆ**
   เครื่องนี้ไม่มี `ansible-core` จึงรันในคอนเทนเนอร์ pin digest
   `alpine/ansible@sha256:22227b578da3371267201879f44de86569e9b531db536e1d9d2b83aed35b6cfc`
3. **`--check` พิสูจน์ playbook เหล่านี้ไม่ได้เลยเกิน `command` ตัวแรก** — assert เรื่อง network
   fail ใน check mode เพราะ `pos_network.stdout` ว่าง (**false positive** ไม่ใช่ข้อ 4 ของ D9 ล้ม)

**บั๊กที่เจอและแก้แล้วใน PR #361:** `restore-db.sh` และ `measure-container-rss.sh` **ไม่เคย**ถูกคัดลอก
ขึ้น VM โดย playbook ใดเลย · `slice-22 §2.2` สั่ง `./deploy/scripts/measure-container-rss.sh` จาก
`/opt/pos` ซึ่งไม่มีอยู่ (`/opt/pos/deploy/` มีแค่ `prometheus/`, `grafana/`) → **runbook ของ #184
รันไม่ได้ตามที่เขียน** · cron ของ backup ไม่เคยถูกติดตั้งเลย (`crontab -l -u deploy` **ว่าง**)
จึงไม่ใช่ "ล้มเงียบทุกคืน" แต่เป็น "ไม่มีอะไรจะล้ม" ซึ่งเงียบกว่า · redirect `>/dev/null 2>&1`
เปลี่ยนเป็น `>>/opt/pos/backups/backup-cron.log 2>&1`

**อีกสองเรื่องที่เจอตอนอ่าน VM (ไม่ใช่ของเลน C แก้):**
- 🔴 `/opt/pos/docker/etcd/etcd-init.sh` ยังเป็น**ไดเรกทอรีของ root** → **etcd ตัวนี้ไม่เคยเปิด auth**
  (07 §7) · `deploy.yml` ซ่อมเองตอน deploy จริงครั้งถัดไป
- `CORS_ORIGINS` / `PLATFORM_ADMIN_IPS` ไม่อยู่ใน `.env` **และไม่มี compose ไฟล์ใดส่งเข้า container**
  (ตรงกับที่ lane A ประกาศไว้ §2) → ใส่ใน `DEMO_ENV_FILE` ก็ไม่ปิด CORS **ห้ามใครเขียน AC ว่าปิดแล้ว**
  · **addendum 2026-09-21 (#367):** ขา compose แก้แล้ว — สองคีย์อยู่ใน `x-app-env` ของ
  `server/docker-compose.yml` แล้ว แต่ `/opt/pos/.env` บน VM ยังว่างเหมือนเดิม
  ⇒ ข้อห้ามข้างบนยังมีผล จนกว่าเพิ่มค่าใน `DEMO_ENV_FILE` แล้วรัน `provision.yml` ใหม่

---

**ประวัติก่อนหน้า (2026-09-21 รอบแรก):**

| ใบ | สถานะ | หลักฐาน |
|---|---|---|
| #342 `web.server-build` | ✅ merged `c8eb552` | PR #353 · CI run `35554301669` สร้าง web image ของ merge commit สำเร็จ · image digest `sha256:e699667945cb48283d556b717ccab2c89c4c2c0bd3dffa31131c4fa03472bd6e` ถูก pull/run พิสูจน์จริง |
| #346 `ops.backup-scripts` | 🛑 ติด VM validation | PR #356 merged `325bf80` · `deploy/scripts/validate.sh` และ CI (`35554355118` / `35554355151`) ผ่าน · ยังไม่ tick AC ที่ต้อง cron log + backup/restore บน VM จริง |
| #343 `vm.deploy` 🔒 | 🛑 รอ secret + VPN + HITL | #336 ปลดแล้ว; ตรวจ `gh secret list` แล้วไม่มี `DEMO_ENV_FILE`, ไม่มี `DEMO_SSH_*` / `ansible-playbook` ในเครื่อง และต้องได้คำสั่งเจ้าของก่อนรัน playbook |

**เตือนจาก D8/D9/D10 — อ่านก่อนลงมือ:**
- 2026-09-21: workflow `Deploy (demo)` ทำงานอัตโนมัติหลัง CI จึงไม่ใช่หลักฐานการ deploy ที่
  อนุญาตตาม D9/HITL; run ที่สั่งยกเลิกของ `c8eb552` / `325bf80` ไม่มี deployment step เริ่ม
  (รายละเอียด §2) และต้องรอคำตัดสินเจ้าของก่อน VM runbook
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
