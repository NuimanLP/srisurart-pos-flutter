# Handoff — Grafana POS Overview +17 ช่อง และ metrics ใหม่ใน API (2026-10-04)

> **อัปเดต 2026-10-04 ค่ำ:** PR #597 merged และ deploy แล้ว (`41a8f19` — ยืนยัน `.current_sha` + Prometheus บน VM) — สถานะล่าสุดอยู่ที่ [`session-2026-10-04-evening-merge-596-597-599.md`](session-2026-10-04-evening-merge-596-597-599.md)

**วันที่:** 2026-10-04 · **ผู้บันทึก:** PattaraponKitcharoen (+ Claude) · **สถานะ:** รอคนอื่น (PR เข้า main ยังไม่เปิด)
**ขอบเขต:** Dashboard กลุ่ม 1, 2, read/write บน `pos-overview.json` + metrics ที่ API ต้องส่งให้ช่องเหล่านั้น + unit test
**ต่อจาก:** [`session-2026-10-04-develop-branch-status.md`](session-2026-10-04-develop-branch-status.md)

## 1. ตอนนี้อยู่ตรงไหน
- อยู่บน `develop` เท่านั้น (`b527b2e`, `8beedc5`, `5a46f78`, `8c9ec00`) · **ยังไม่ขึ้น `mob04`** — VM ใช้ image จาก main
- `pos-overview.json` 12 → **29 ช่อง** (id 1–29, k6 ย้ายไป y=80+) · ทุก query ใช้ได้กับ Prometheus + API ที่มีบน VM อยู่แล้ว
- local stack รัน API image `srisurart-pos-server:develop-local` ที่ build จาก `develop` 2026-10-04 (ก่อน `bf48167`; ต่างกันแค่ไฟล์ frontend)

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร
**Dashboard (id ใน `pos-overview.json`):**
- กลุ่ม 1 (13–19): instances up, request rate รวม/ต่อ route, p95 ต่อ route, 5xx ต่อ route, RSS ต่อ instance, event-loop lag p99
- กลุ่ม 2 (20–26): บิล/ยกเลิก/คืน (ยอด + ต่อนาที), DB pool in use + max, pool waiting, login refusals (`route=~".*/auth/token"`, 4xx), งานในคิว `max() by (queue,state)`, งานที่ล้ม
- read/write (27–29): rate, p95, success — read = `GET|HEAD`, write = ที่เหลือยกเว้น `OPTIONS`

**Metrics ใหม่ (`server/src/metrics/`):**
- `pos_documents_total{kind=sale|void|return}` — zero-init · นับใน `onTransactionCommit` (`sales.service.ts:335`, `void.service.ts:149`, `returns.service.ts:318`) · ไม่มี label tenant
- `pos_db_pool_connections{state=in_use|idle|waiting}` + `pos_db_pool_max_connections` — อ่านตอน scrape ผ่าน `DB_POOL_STATS` (`dbPoolStatsReader` ใน `db.module.ts`)
- `pos_queue_jobs{queue,state}` — `getJobCounts` ของ 6 คิว, timeout 1 s, error → `reset()` (ไม่ส่งค่าเก่า)
- `RuntimeMetricsService`/`RuntimeMetricsModule` ใหม่ ลงทะเบียนใน `AppModule` เท่านั้น (worker ไม่มี)

**ตรวจสอบด้วยอะไร:**
- unit +25 ข้อ (`metrics.service.spec.ts`, `runtime-metrics.service.spec.ts`, `metrics.middleware.spec.ts`, `db.module.spec.ts`) → 627/627 · coverage 44.21% → **45.39%** · 3 ไฟล์ metrics = 100%
- e2e +2 ข้อใน `metrics.e2e-spec.ts` (บิลส่งซ้ำนับครั้งเดียว ไม่มี tenant label · gauge pool/คิวมีจาก module graph จริง)
- 2026-10-04 local: query ทั้ง 44 ช่องกับ Prometheus ไม่มี error · ยิง GET 40 / POST 20 / path ผิด 40 → request rate, p95 (read 4.75 ms / write 9.97 ms), error แยกรหัส (401/404), read-vs-write ขึ้นจริง · path ผิดรวมเป็น `unmatched`
- trace โค้ด: ทุกทางเข้าผ่าน service ที่นับ — `sales.create` (หน้าร้าน, `quote-sale.service.ts`, `quotes.service.ts`, `/sync/push`), `voids.void` (online + `sale.void_offline`), `returns.create` · `/sync/push` เป็น `runTx` ต่อ op (ไม่ใช้ savepoint) → op ที่ rollback ไม่ถูกนับ

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร
- **นับตอน commit ไม่ใช่ตอนเรียก** — ตามแบบ `pos_idempotency_replay_total` (CLAUDE.md Metrics) · บิลที่ replay ด้วย key เดิม return ก่อนถึงบรรทัดนับ
- **`void` = ยกเลิกโดยคนเท่านั้น** — auto-void ตอนคืนครบบิลนับเป็น `return`
- **อ่าน pool ผ่าน function token `DB_POOL_STATS` ไม่ใช่ DataSource** — `tenant-door.spec.ts` ห้ามไฟล์นอก allowlist แตะ DataSource (ครั้งแรกส่ง DataSource → spec แดง)
- **คิวใช้ `max()` ไม่ใช่ `sum()`** — API 3 ตัวอ่านคิวเดียวกันใน Redis
- **แยก read/write ตาม HTTP method** (ผู้ใช้ 2026-10-01) — ค่ารวมกลบกรณีขายพังแต่ดูข้อมูลได้
- extract `dbPoolStatsReader` ออกจาก provider factory (2026-10-04) เพื่อ unit test ได้ — พฤติกรรมเดิม
- **ไม่ขยับ coverage floor** 44 → 45 เอง — มีผลกับทุก PR ให้ทีมตัดสิน

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)
- inject `DataSource` ใน `RuntimeMetricsService` → `tenant-door.spec.ts` แดง (เปลี่ยนเป็น reader token)
- unit test "max gauge ไม่มี sample ก่อนต่อ reader" ผิด — prom-client gauge ที่ไม่มี label export `0` เสมอ (เทสต์ปรับให้ตรงจริง)
- ยิง POST รัว 40 ครั้งเพื่อทดสอบ write → Nginx `perip` (30 r/s, burst 60) ตอบ 429 ก่อนถึง API → ไม่ถูกนับ (ถูกต้อง) · ต้องยิงช้า ๆ

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์
- ตัวนับบิลใน local stack ยังเป็น 0 — ไม่มีรหัสผ่านร้านใน DB local · พิสูจน์ด้วย e2e เท่านั้น
- ช่อง pool waiting, failed jobs, 5xx ยังไม่เคยเห็นค่าไม่ใช่ 0 นอกเทสต์
- `redis-queue` ล่ม: คำสั่งที่ timeout ค้างใน ioredis offline queue (`maxRetriesPerRequest: null`) เพิ่ม 6 คำสั่งต่อ scrape ต่อ instance แล้ว flush ตอนต่อได้ — **ยังไม่ได้วัด** (เทสต์ Redis ค้างเคยเห็น scrape ใช้ 1 s แล้วกลับมาปกติ)
- `pos_db_pool_max_connections` ถูก set ใน `collect` ของ gauge อื่น — ถูกเพราะลำดับลงทะเบียน (มี unit test คุม) · ทางที่ดีกว่าคือ collect ของตัวเอง ยังไม่ได้ทำ

## 6. ก้าวถัดไป (เรียงลำดับ)
1. แยก branch จาก `main`: โค้ด metrics + 3 service + `app.module.ts` + `db.module.ts` + tests + `pos-overview.json` (**ไม่เอา** `pos-infra.json`, `datasources/loki.yml`, `local-scrape.yml`, `scrape_config_files`)
2. เพิ่ม docs ใน PR เดียวกัน: ชื่อ metric ใหม่ใน `CLAUDE.md` ส่วน Metrics + ช่องใหม่ใน `07_CICD_DEPLOY.md §10`
3. CI เขียว → ทีมรีวิว → merge → owner approve Deploy → เช็ก `.current_sha` + เปิด Grafana บน VM (SSH tunnel) ว่าช่องใหม่มีข้อมูล
4. (ทีหลัง) single in-flight guard ของ queue read · `dbPoolMax` collect ของตัวเอง

## 7. ข้อควรระวัง
- 🔴 `http_requests_total`/`http_request_duration_seconds` ถูกตั้งชื่อตาม expr ใน dashboard — ห้ามเปลี่ยนชื่อ
- `MetricsService` เป็น dependency บังคับของ `SalesService`/`VoidService`/`ReturnsService` แล้ว — graph ไหนสร้าง 3 service นี้ต้องมี `MetricsModule` (global ใน AppModule; worker ไม่สร้างจึงไม่กระทบ)
- p95 ใน Grafana วัด **ใน API เท่านั้น** ไม่รวม network/Nginx — ต่ำกว่าที่ผู้ใช้รู้สึก (ของ k6 รวม)
- `NaN` ในช่อง rate/p95 = ไม่มี request ในช่วงนั้น ไม่ใช่เสีย

## 8. อ้างอิง
- `deploy/grafana/dashboards/pos-overview.json` · `server/src/metrics/` · `server/src/infra/db.module.ts` · `server/test/metrics.e2e-spec.ts`
- รายการทุกช่อง (ความหมาย + ที่มา) อธิบายใน session นี้ — สรุปสั้นอยู่ใน `docs/infographic/dashboard-status.html`
