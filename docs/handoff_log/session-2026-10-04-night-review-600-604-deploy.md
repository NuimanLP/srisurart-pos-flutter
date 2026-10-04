# Handoff — 2026-10-04 ดึก: รีวิว #599–#603 (merge โดยเพื่อน), แก้ตามรีวิวใน PR #604, deploy `1734b13` → `81245b5`

**ผู้ทำ:** NuiGates + Claude (orchestrator; Opus รีวิวโค้ด #600, Sonnet รีวิวเอกสาร + อัปเดต `docs/tutorial/`)
**สถานะ:** ปิดแล้ว — `mob04` อยู่ที่ `81245b5` (deploy log: `Successfully deployed release '81245b5…'`, Ansible `failed=0`)

## 1. เกิดอะไรขึ้น

`PattaraponKitcharoen` merge PR #599–#603 เข้า `main` (14:12 UTC) เราตรวจหลัง merge:

| PR | ชนิด | merge | ผล |
|---|---|---|---|
| #599 | docs (รายงาน P1) | `b292522` | ok |
| #600 | **code** — local observability overlay | `1734b13` | ไม่มี blocker · should-fix 2 ข้อ (→ #604) |
| #601 | docs (infographic + pptx) | `c843f0b` | infographic ยังมี Uptime Kuma (→ #604) |
| #602 | docs (รายงาน: #597 deployed) | `945aa08` | ok |
| #603 | docs (handoff 6 ไฟล์) | `dc9118e` | ok |

head SHA ของทุก PR ตรงกับ commit ที่ merge (ไม่มี commit หลุดหลังกด merge) · CI เขียวทุก merge commit · ไม่เจอความลับใน md/html/yml/json ที่เพิ่ม และใน XML ของ docx/pptx (มีแค่ placeholder `https://hc-ping.com/<uuid>`)

## 2. รีวิว #600 (Opus) — สรุป

- **ส่วนเดียวที่ถึง `mob04`:** `deploy/prometheus/prometheus.yml` เพิ่ม `scrape_config_files: /etc/prometheus/scrape.d/*.yml` — บน VM ไม่มีโฟลเดอร์นี้ glob ไม่ match = ไม่ error · ยืนยันจาก deploy จริง: `TASK [Verify Prometheus and Grafana answer on host loopback]` → `ok` ทั้ง `:9090/-/healthy` และ `:3000/api/health`
- overlay อื่น (`observability.yml`, `local-api.yml`, `*-local/`, `alloy/`, `loki/`) ไม่มี Ansible task ไหนอ้างถึง · port ใหม่ผูก `127.0.0.1` · image ใหม่ 5 ตัว pin digest ครบ และ `compose-image-pins.spec.ts` ครอบ `observability.yml` แล้ว · exporter อ่านรหัสจาก `.env` ด้วย `${…:?}` ไม่มีค่าใน repo
- **should-fix 1:** `local-api.yml` override แค่ `api-1..3` → `migrate`/`worker`/`bull-board` ยังเป็น image GHCR — migration ใหม่ของ branch ไม่รัน, worker รันโค้ดเก่า
- **should-fix 2:** ไม่มี `promtool` ใน CI — `deploy.yml` แค่ **เตือน** ถ้า Prometheus พังบน VM (`rescue` ของ monitoring block) แล้ว deploy ยังเขียว
- nit ที่ไม่แก้ (ยอมรับ): regex `srisurart-.*` ของ dashboard infra รวม stack `-p` ชั่วคราวด้วย · Loki เก็บ log Postgres local 7 วัน

## 3. PR #604 (`81245b5`) — แก้ตามรีวิว

- `server.yml` job `nginx-check`: `promtool check config` (prom/prometheus v2.55.1 digest เดียวกับ `monitoring.yml` — bump พร้อมกัน) 2 แบบ: config ล้วน (รูปแบบ VM) และ mount `prometheus-local/local-scrape.yml` เข้า `scrape.d/` · path filter `server` เพิ่ม `deploy/prometheus/**`, `deploy/prometheus-local/**` · step ผ่านบน PR
- `local-api.yml`: เพิ่ม `migrate`, `worker`, `bull-board`
- `07 §10.4`: แก้ "โฟลเดอร์ว่าง" → "ไม่มีโฟลเดอร์" · เพิ่ม cAdvisor `privileged: true` + mount `/`
- infographic `monitoring-dashboard.html`: Uptime Kuma → Healthchecks.io · PNG render ใหม่จาก HTML (Edge headless, 3840×2160) · 🔴 `slides-update-2026-10-03.pptx` **ยังไม่ได้แก้** ถ้ามีหน้า Kuma ต้องแก้มือ

## 4. Deploy

| run | release | ผล |
|---|---|---|
| 37208737473 | `1734b13` (#600) | approved → `failed=0`, Prometheus healthy |
| 37209980750 | `81245b5` (#604) | approved → `failed=0`, Prometheus healthy |

🔴 ยังไม่ได้อ่าน `/opt/pos/.current_sha` บน VM เอง — หลักฐานคือ log ของ deploy job (`Successfully deployed release …`) · ตรวจด้วย `cat /opt/pos/.current_sha` ครั้งหน้าที่ SSH เข้า

**สังเกต (ไม่ใช่บั๊กที่ต้องแก้):** หลัง merge หลาย PR ติดกัน Deploy run ที่เกิดจาก CI ของ commit docs-only (`c843f0b`) resolve ไปที่ SHA docs นั้นเอง ("only docs changed since c843f0b … is deployed") แล้ว skip เพราะไม่มี image — ปลอดภัย (ไม่มีอะไรถูก deploy) แต่ข้อความ notice ชวนเข้าใจผิดว่าเป็น "latest code" · run ของ `1734b13` เองรอ image web ครบก่อน แล้ว run ถัดไปจึงเข้า "Waiting for review"

## 5. เอกสารที่อัปเดตใน PR นี้

- `docs/tutorial/`: `sri-pos-manual/04-it-operations.html` (heartbeat: ติดตั้ง/อ่าน log/ความหมาย warning-error), `05-dashboards.html` (Overview 29 ช่อง + metrics ใหม่ #597, หน้า infra = เครื่อง dev เท่านั้น), `index.html`, `local-full-stack-tutorial.md` (§3.1 overlay), `VM-dploy-full-stack-tutorial.md` (คีย์ `HEALTHCHECKS_PING_URL`, cron), `testing-tutorial.md` (เทสต์สคริปต์ + promtool)
- `CLAUDE.md`: กฎ observability/heartbeat · `handoff_log/INDEX.md`

## 6. ยังค้าง (ไม่ใช่ของ session นี้)

1. **Heartbeat ยังไม่ติดตั้งบน `mob04`** — ต้องรัน `provision.yml` (user `cloud`) หรือทำตาม `07 §7b` · `mob04-demo.env` ในเครื่อง NuiGates มี `HEALTHCHECKS_PING_URL` แล้ว (ตรวจแบบไม่พิมพ์ค่า, มีบรรทัดเดียว) · อย่ากด Ping now ก่อนมี cron
2. #597 follow-up: ช่วง redis-queue ล่ม `withTimeout` ไม่ยกเลิก `getJobCounts` → คำสั่งค้างสะสม (~6 ต่อ scrape ต่อ instance) — ควรข้ามการอ่านถ้ารอบก่อนยังค้าง · ยังไม่เปิด issue
3. `pos_db_pool_max_connections` ถูก set เป็นผลข้างเคียงของ `collect` ของ gauge อีกตัว — เปราะ
4. pptx สไลด์ยังมี Uptime Kuma (ถ้ามี)
5. binary ใน `docs/report/` (docx 4.2 MB + pdf 5.8 MB) ถูก commit ใหม่ทุกครั้งที่ rebuild — history โตเร็ว
