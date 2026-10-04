# Handoff — local observability overlay: Loki + Alloy + exporters + หน้า POS Infra (2026-10-04)

> **อัปเดต 2026-10-04 ค่ำ:** เปิด PR #600 แล้ว (ยังเป็น local only) · `pos-infra.json`, datasource Loki และ `local-scrape.yml` **ย้ายไป `deploy/grafana-local/` และ `deploy/prometheus-local/`** (`88fca1c`) — path ในไฟล์นี้เป็นของเดิม · ขึ้น VM ยังรอ owner — สถานะล่าสุดอยู่ที่ [`session-2026-10-04-evening-merge-596-597-599.md`](session-2026-10-04-evening-merge-596-597-599.md)

**วันที่:** 2026-10-04 · **ผู้บันทึก:** PattaraponKitcharoen (+ Claude) · **สถานะ:** ปิดแล้ว (local) · รอ owner ถ้าจะขึ้น VM
**ขอบเขต:** ที่เก็บ log (Loki/Alloy) + exporter ของ Postgres/Redis/container + Dashboard หน้าที่ 2 — **local only**, ไม่อยู่ใน deploy ของ VM
**ต่อจาก:** [`session-2026-10-04-develop-branch-status.md`](session-2026-10-04-develop-branch-status.md)

## 1. ตอนนี้อยู่ตรงไหน
- บน `develop` (`6fda489`, `877ece8`, `9e48d75`) · `deploy/ansible/deploy.yml` ไม่โหลด `observability.yml` → VM ไม่มี
- local stack `srisurart-mob04` รัน 19 container (2026-10-04) — Uptime Kuma ถอดออกแล้ว (ดู [uptime](session-2026-10-04-uptime-healthchecks-heartbeat.md))
- เปิดดู: Grafana `127.0.0.1:3000` (Dashboards → *Srisurart POS — infrastructure (local)*; Explore → Loki) · Prometheus `:9090` · Alloy UI `:12345` · Loki `:3101` · Bull-Board `:3100` · platform-ui `:3200`

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร
- `deploy/compose/observability.yml`: loki 3.7.8, alloy v1.20.1, postgres-exporter v0.20.1, redis_exporter v1.93.0, cAdvisor v0.60.6 — pin `name:tag@sha256` ทุกตัว (เพิ่มใน `compose-image-pins.spec.ts`) · mem limit รวม 1152m
- Loki (`deploy/loki/loki.yml`): single binary, tsdb v13, retention 168h · datasource `deploy/grafana/provisioning/datasources/loki.yml` (uid `Loki`)
- Alloy (`deploy/alloy/config.alloy`): `discovery.docker` กรองด้วย label project จาก `sys.env("COMPOSE_PROJECT")` → label `service`/`container` → `loki.write`
- Prometheus: `scrape_config_files: /etc/prometheus/scrape.d/*.yml` ใน `prometheus.yml` + `deploy/prometheus/local-scrape.yml` (job postgres, redis แบบ multi-target `/scrape?target=`, cadvisor) mount เฉพาะใน overlay
- `deploy/grafana/dashboards/pos-infra.json` 15 ช่อง: container mem/limit/CPU/OOM · Postgres up/connections/tps/size/deadlocks · Redis up/mem/evictions/hit ratio/cmds/clients
- `deploy/compose/local-api.yml`: api-1..3 ใช้ image `srisurart-pos-server:develop-local` (ต้องอยู่หลัง `vm.override.yml`)
- `deploy/loki/README.md` (2026-10-04): LogQL ตัวอย่าง ย้ายมาจาก README ของ Kuma

**ตรวจสอบด้วยอะไร (2026-10-04):** query 15 ช่องของ POS Infra มีค่าจริงทุกช่อง ยกเว้น OOM (ไม่มีเหตุการณ์) · RAM จริงของ stack ~1.1 GB (ตัวเลข 4.2–5.3 GB ที่เคยเห็นคือผลรวม mem limit ไม่ใช่การใช้จริง) · promtool v2.55.1 ผ่านทั้งตอนมีและไม่มีไฟล์ใน `scrape.d/`

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร
- **Loki + Alloy** แทน ELK — เบา, Grafana อ่านได้ตรง (ผู้ใช้ให้เลือกเอง 2026-10-01)
- **แยกหน้า Dashboard** (`pos-infra.json`) แทนยัดใน Overview — exporter มีแค่ local; บน VM หน้านี้จะ "No data" ทั้งหน้า ส่วน Overview ใช้ได้ครบ
- **local only** (ผู้ใช้ 2026-10-01) — เอาขึ้น VM = owner decision เพราะ RAM limit เพิ่ม ~1.1 GB เกินงบใน `07 §5`
- postgres-exporter ต่อด้วย superuser — รับได้บนเครื่อง dev เท่านั้น (VM ควรใช้ role `pg_monitor`)
- `scrape_config_files` แบบ glob แทนแก้ `prometheus.yml` ให้มี job local — VM ไม่มีไฟล์ใน glob จึงไม่มีผล

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)
- mount ไฟล์ซ้อนลงโฟลเดอร์ provisioning ที่ mount `:ro` อยู่แล้ว → Grafana start ไม่ได้ → ย้าย `loki.yml` เข้าโฟลเดอร์ datasources ที่แชร์
- Loki publish `3100` ชน Bull-Board → ใช้ `127.0.0.1:3101`
- Alloy กรองด้วยชื่อ project ตายตัว → ไม่เจออะไรเมื่อรันด้วย `-p` อื่น → ใช้ env `COMPOSE_PROJECT`
- cAdvisor mount `/var/run` → บน Docker Desktop `docker.sock` เป็น symlink → ไม่เห็น container → mount `/var/run/docker.sock` ตรง ๆ
- `docker build` ค้างเพราะ `docker-credential-desktop` (keychain) → ใช้ `DOCKER_CONFIG=<scratch>` ที่มี `{}` + symlink `cli-plugins`, `DOCKER_HOST=unix://$HOME/.docker/run/docker.sock` (ไม่แตะ config ของผู้ใช้)
- `compose up` ทับ stack dev เก่า (`srisurart-pos`) → "network has active endpoints" → `down` (ไม่มี `-v`) stack เก่า แล้วใช้ project ใหม่ `srisurart-mob04` + volume ใหม่ (รหัสใน `mob04-demo.env` ไม่ตรงกับ pgdata เก่า)

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์
- ช่อง Infra รวมทุก project ที่ชื่อ `srisurart-*` — ถ้ามี stack อื่นชื่อ service ซ้ำจะถูกบวกรวม (เห็นได้เฉพาะตอนรันหลาย stack)
- Disk panel (Overview #3) ไม่มีค่าบน macOS (Docker Desktop เป็น VM ซ้อน) — บน Linux VM คาดว่ามี ไม่ได้ตรวจในรอบนี้

## 6. ก้าวถัดไป (เรียงลำดับ)
1. ไม่มีงานค้างฝั่ง local
2. รอ owner: เอา Loki/exporters ขึ้น VM ไหม — ถ้าเอา ต้องทำ overlay สำหรับ VM, role `pg_monitor`, ทบทวน `docker.sock` ของ Alloy/cAdvisor, งบ RAM ใน `07 §5`
3. ถ้าไม่ขึ้น VM: อย่าเอา `pos-infra.json` / `datasources/loki.yml` เข้า main

## 7. ข้อควรระวัง
- 🔴 `docker.sock:ro` **ไม่จำกัด Docker API** — Alloy/cAdvisor สั่ง start/stop container ได้ (คอมเมนต์แก้แล้วใน `9e48d75`)
- 🔴 ห้าม `down -v` — volume `srisurart-mob04_*` เป็นข้อมูล local ที่ผูกกับรหัสใน `mob04-demo.env`
- volume ของ Uptime Kuma ที่ไม่ใช้แล้วยังอยู่: `srisurart-mob04_uptime-kuma-data`, `srisurart-obs-verify_uptime-kuma-data` (ยังไม่ลบ — รอผู้ใช้ยืนยัน)
- Alloy ส่ง backlog เก่าครั้งแรก → Loki ปฏิเสธบรรทัดเก่ากว่า 7 วัน (`timestamp too old`) ครั้งเดียว ไม่ใช่ปัญหา

## 8. อ้างอิง
คำสั่งรัน local (จาก `server/`; `IMAGE_TAG` ที่ใช้ = `f4c821b23a6fda25a5a646505482b664e6ef8e6b`):
```bash
docker build -t srisurart-pos-server:develop-local .
docker compose -p srisurart-mob04 --env-file mob04-demo.env -f docker-compose.yml -f ../deploy/compose/vm.override.yml -f ../deploy/compose/local-api.yml -f ../deploy/compose/monitoring.yml -f ../deploy/compose/observability.yml up -d --pull never
```
- `deploy/compose/observability.yml` · `deploy/loki/README.md` · `deploy/alloy/config.alloy` · `deploy/prometheus/local-scrape.yml`
