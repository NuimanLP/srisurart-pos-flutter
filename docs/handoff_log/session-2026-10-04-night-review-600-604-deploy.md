# Handoff — 2026-10-04 ดึก: รีวิว #599–#603 (merge โดยเพื่อน), แก้ตามรีวิวใน PR #604, deploy `1734b13` → `81245b5`

**ผู้ทำ:** NuiGates + Claude (orchestrator; Opus รีวิวโค้ด #600, Sonnet รีวิวเอกสาร + อัปเดต `docs/tutorial/`)
**สถานะ:** ปิดแล้ว — `mob04` อยู่ที่ `7444ea4` (`.current_sha` อ่านเองบน VM) · heartbeat ติดตั้งแล้ว (§6)

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

## 6. รอบต่อมา (คืนเดียวกัน) — ปิด 3 ข้อที่ค้าง

1. **`.current_sha` อ่านเองบน VM แล้ว** (`ssh mob04`) — `81245b5…` ตรงกับ deploy · ภายหลังเป็น `7444ea4…` (ข้อ 3)
2. **Heartbeat ติดตั้งบน `mob04` แล้ว (ด้วยมือ, `07 §7b`)** 15:14 UTC:
   - สคริปต์จาก `origin/main` → `/opt/pos/scripts/healthcheck-ping.sh` (`deploy:deploy` 0755) · sha256 `77f79d62…` ตรงทั้งต้นทาง/ปลายทาง · `bash -n` ผ่าน
   - คีย์ `HEALTHCHECKS_PING_URL` ต่อท้าย `/opt/pos/.env` ทาง stdin (`grep | ssh … tee -a`) — URL ไม่อยู่ใน argv ทั้งสองฝั่ง · ไฟล์ยัง 0600 `deploy:deploy` · คีย์บรรทัดเดียว · ไฟล์ backup ชั่วคราวลบแล้ว
   - cron ของ `deploy`: `#Ansible: Srisurart POS Uptime Heartbeat` + `*/5 * * * * … | logger -t pos-healthcheck` (ตรงกับ `provision.yml` — รันรอบหน้าจะรับไปดูแล ไม่เพิ่มซ้ำ)
   - ลำดับ: ติดตั้ง cron **ก่อน** แล้วจึงรันมือหนึ่งครั้ง (`env -i` แบบ cron) → `rc=0` เงียบ = ping ปกติ ซึ่ง resume check ที่ pause ไว้ · cron รอบแรก 15:20 UTC รันจริง (`journalctl -u cron`) ไม่มี log `pos-healthcheck` = ปกติ
   - **ยังไม่ได้ทำ:** ดูหน้า Healthchecks.io ว่า check เขียว (ทีมดูเอง) · ทดสอบเคส `/fail` บน VM (`HEALTHCHECK_READY_URL=https://127.0.0.1/health/nope`) — จะยิงแจ้งเตือนจริง ให้ทีมเลือกเวลา
3. **#597 follow-up → PR #606 (`7444ea4`)** — queue read แบบ single-flight: scrape ที่เจอ read ค้างอยู่จะรอตัวเดิม (timeout 1 วิของตัวเอง) ไม่ส่งคำสั่งใหม่ · guard ล้างเมื่อ read ของ **ทุก** queue settle · `pos_db_pool_max_connections` มี `collect` ของตัวเอง · +3 unit test (2 ตัวแดงบนโค้ดเดิม) · CI เขียว · ผมรีวิวเอง: rejection ถูก `withTimeout` จับเสมอ ไม่มี unhandled · deploy run 37213298785 → `failed=0` · บน VM: `.current_sha` = `7444ea4`, `/health/ready` 200, Prometheus `count(pos_queue_jobs)` = 72, `pos_db_pool_max_connections` = 15 ×3

## 7. ยังค้าง

1. pptx สไลด์ยังมี Uptime Kuma (ถ้ามี)
2. binary ใน `docs/report/` (docx 4.2 MB + pdf 5.8 MB) ถูก commit ใหม่ทุกครั้งที่ rebuild — history โตเร็ว
3. รายงาน `docs/report/src/chapters/ch4b.md:109` ยังเขียน heartbeat "ยังไม่ติดตั้ง" — ไม่ได้แก้ (เป็น snapshot ของรายงาน P1 และ pdf/docx ต้อง rebuild พร้อมกัน)
4. `max ?? 0` ของ pool max — ไม่แก้ (`DB_POOL_SIZE` default 5 ใน `config.ts` จึงไม่ถึง fallback)
