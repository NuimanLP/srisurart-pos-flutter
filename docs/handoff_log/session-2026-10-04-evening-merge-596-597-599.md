# Handoff — ค่ำ: merge #596 heartbeat, #597 metrics + Overview, #599 รายงาน · deploy `41a8f19` · PR #600–#603 (2026-10-04)

**วันที่:** 2026-10-04 · **ผู้บันทึก:** PattaraponKitcharoen (+ Claude) · **สถานะ:** รอคนอื่น (รีวิว PR #600–#603 / owner ติดตั้ง heartbeat)
**ขอบเขต:** ต่อจาก handoff 5 ไฟล์ของ 2026-10-04 (ช่วงบ่าย) — งานส่วนที่ใช้กับ VM ได้ถูกแยกเป็น PR และรวมเข้า `main` แล้ว
**ต่อจาก:** [`session-2026-10-04-develop-branch-status.md`](session-2026-10-04-develop-branch-status.md) (และอีก 4 ไฟล์ที่ลิงก์จากไฟล์นั้น)

## 1. ตอนนี้อยู่ตรงไหน
- `main` = `b292522` (merge #599) · `develop` = `7950598` · main ไม่มี commit ที่ `develop` ไม่มี
- ก่อน #600–#603: `develop` ต่างจาก `main` **เฉพาะของที่ตั้งใจเก็บไว้**: overlay local (`observability.yml`, Loki, Alloy, exporters, `local-api.yml`), `pos-infra.json`, datasource Loki, `local-scrape.yml` + `scrape_config_files`, `.gitignore` `/server/*.env`, image-pin test ของ overlay, handoff, infographic/pptx — โค้ด server และ `pos-overview.json` **ตรงกับ main ทุกบรรทัด**
- Deploy: run `37204172280` (`41a8f19`, #597) job `deploy to demo` = success → **ยืนยันบน VM แล้ว** (SSH `cloud@172.30.58.20`, read-only): `/opt/pos/.current_sha` = `41a8f197e1b5…`, `/health/ready` 200, Prometheus บน VM มี `pos_documents_total` 3 kind, `pos_db_pool_max_connections`=15 ×3, `pos_queue_jobs` 72 series · run ของ `b292522` (#599 docs-only) = `deploy` skipped ตามกติกา
- **PR เปิดค้าง (ทำหลังจากนั้น — ทุกอย่างที่เหลือบน `develop` แยกเป็น PR):** #600 overlay local (Loki/Alloy/exporters/หน้า Infra — ย้ายไฟล์ไป `deploy/grafana-local/`, `deploy/prometheus-local/` ก่อน ดู §3) · #601 infographic + pptx · #602 รายงาน: #597 deploy แล้ว + ตัวเลข RAM · #603 handoff ชุดนี้ + INDEX
- heartbeat: โค้ดอยู่บน main แล้ว **ยังไม่ติดตั้งบน `mob04`** · check ใน Healthchecks.io ยัง Pause อยู่ · `HEALTHCHECKS_PING_URL` ยังไม่อยู่ใน `mob04-demo.env`

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร
| PR | อะไร | merge | head = merged? |
|---|---|---|---|
| #596 | heartbeat (`healthcheck-ping.sh`, test, `provision.yml`, CI, `validate.sh`, `07 §7b`, `.env.example`) | 2026-10-04 12:48Z (squash → `e0b880a`) โดยคนอื่นก่อนที่เราจะสั่ง | yes (`c9f8c39`) |
| #597 | metrics `pos_documents_total`/`pos_db_pool_*`/`pos_queue_jobs` + Overview 12 → 29 panels + 25 unit/2 e2e + `CLAUDE.md` Metrics + `07 §10` | 12:55Z (`41a8f19`) หลัง rebase บน `e0b880a` | yes (`d336cfa`) |
| #599 | รายงาน P1: หัวข้อ "การขยายการเฝ้าสังเกตระบบ (1–4 ต.ค.)" บทที่ 4 + งานถัดไปข้อ 11 บทที่ 5 + `dashboard-status.png`; 120 หน้า | 13:14Z (`b292522`) | yes (`478cdfd`) |

- **#596 มี commit เพิ่มจาก NuimanLP หลังเปิด PR** — `3ea4489` ส่ง ping URL ให้ curl ทาง config stdin (`-K -`) แทน argv (เดิมเห็นได้ผ่าน `ps` — จุดที่ฝั่งเราพลาด), ตัด URL ออกจาก error, key ซ้ำใช้บรรทัดสุดท้าย, test 18 กรณี (CI แดง SC1003) → `c9f8c39` ปฏิเสธ URL ที่มี quote/backslash/space แทนการ escape (+6 กรณี) → CI เขียว
- **CI ที่ GitHub ยืนยันสิ่งที่ค้างจาก local**: #597 integration (e2e ทั้งชุด รวม 2 ข้อใหม่) ผ่าน 4m7s และ `tx-ceiling` ที่เคยล้มในเครื่องไม่ล้ม
- รายงาน: main มี #598 (NuimanLP, รายงานถึง `f2827ed`, 117 หน้า) เข้ามาก่อน → รวมกับส่วนของเรา → build ใหม่ 120 หน้า สถานะในตาราง = "#596/#597 รวมแล้ว, รอ deploy / ยังไม่ติดตั้ง" (เขียนก่อนเห็นว่า deploy run ผ่าน)
- ดึง main เข้า `develop` 2 รอบ (`8c7ab3d`, `7950598`) — conflict เฉพาะไฟล์ heartbeat/รายงาน → ใช้ของ main

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร
- **ย้ายไฟล์ Grafana/Prometheus ของ overlay ออกจาก `deploy/grafana/` และ `deploy/prometheus/`** (`88fca1c` บน `develop`, ใน #600) — `deploy.yml` copy สองโฟลเดอร์นั้นขึ้น VM ทั้งก้อน · `observability.yml` mount provisioning ของ Grafana ทีละไฟล์ด้วย `volumes: !override` (Compose ≥ 2.24; local 2.34) + provider ที่สอง `local` · ทดสอบบน stack local แล้ว: datasource 2 ตัว, dashboard 2 หน้า, job postgres/redis/cadvisor `up` · ผู้ใช้สั่ง "เอาขึ้นให้หมด เป็น PR แยก" 2026-10-04
- แตก `develop` เป็น PR ย่อยจาก `main` แทน merge ทั้งก้อน — `deploy.yml` copy `deploy/grafana/` ทั้งโฟลเดอร์ขึ้น VM (เหตุผลเต็มใน handoff บ่าย)
- รอ #597 merge ก่อนทำ PR รายงาน (ผู้ใช้ 2026-10-04) — ไม่ให้สถานะ "รอรวม" ในรายงานล้าสมัยทันที
- PR เขียนภาษาอังกฤษตามธรรมเนียม repo
- merge ด้วย `--match-head-commit` ทุกครั้ง (กฎ `headRefOid` ใน CLAUDE.md)

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)
- 🔴 **AppleScript `active document` ใน Word ไปทำกับเอกสารอื่นที่ผู้ใช้เปิดค้าง** (รายงานโครงงาน give_and_take) — save as เป็นไฟล์ใหม่แล้วปิดโดยไม่บันทึกทับ · ไฟล์เดิมบนดิสก์ไม่ถูกแก้ · สำเนาสถานะในหน่วยความจำตอนนั้นอยู่ที่ `~/Desktop/RECOVERED-word-doc-closed-2026-10-04-1938.docx/.pdf` (ผู้ใช้ย้ายไปเอง) · **ผู้ใช้ยังไม่ได้ยืนยันว่ามีงานค้างที่หายหรือไม่**
- Word for Mac: `update (fields of …)` และ `update field i` ใช้ไม่ได้ (445/445 ล้ม) · `repeat with t in tables of contents` error `-1708` · ใช้ได้: `update (table of contents 1 of d)` + `update (table of figures i of d)` — เลขรูป/ตารางมาจาก `build.py` อยู่แล้ว
- Word for Mac (sandbox) save ลง `/private/tmp/...` ไม่ได้ (`doesn't understand the "save as" message`) → ทำในโฟลเดอร์ repo แล้วค่อย copy
- เปิด docx ใหญ่ด้วย AppleScript เกิน timeout 2 นาที → ใส่ `with timeout of … seconds`
- ตารางยาว + caption: แถวตารางห้ามตัดข้ามหน้า → caption ค้างหน้าเปล่า → ย่อเนื้อหาในตาราง ย้ายรายละเอียดเป็นย่อหน้า

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์
- ช่องใหม่ใน Grafana บน VM ยังไม่มีใครเปิดดูด้วยตา (Prometheus บน VM ยืนยันว่ามี metric ครบ)
- **RAM ของ `mob04`** (2026-10-04): 5,920 MB, **ไม่มี swap**, `free -m` used 1,387 MB · เพดาน `mem_limit` รวม 4,256 MB (14 container) · ใช้จริงรวม ~460 MB · overlay จะเพิ่มเพดาน 1,152 MB → 5,408 MB — ใต้โหลด k6 ยังไม่เคยวัด (#380)
- heartbeat ยังไม่เคยมี ping จากสคริปต์ / `/fail` จริง / `provision.yml` ส่วนนี้ยังไม่เคยรันกับเครื่องจริง

## 6. ก้าวถัดไป (เรียงลำดับ)
1. ~~เช็ก `.current_sha`~~ — ยืนยันแล้ว 2026-10-04 · ~~แก้รายงาน "รอ deploy"~~ — PR #602
2. ทีมรีวิว/merge #600–#603 (เช็ก `headRefOid` ตอน merge) · #600 อย่าเปิดใช้บน VM โดยไม่มี owner decision
3. owner: ติดตั้ง heartbeat ตาม `07 §7b` (เพิ่ม `HEALTHCHECKS_PING_URL` ใน `mob04-demo.env` ก่อน) → ตรวจ `rc=0`, check เขียว, ทดสอบ `/fail`
4. ผู้ใช้: เช็กไฟล์ `RECOVERED-…` บน Desktop เทียบกับไฟล์ใน `~/Desktop/give_and_take/docs/`
5. รอ owner: เอา overlay/Loki/exporters ขึ้น VM ไหม (+~1.1 GB RAM limits)

## 7. ข้อควรระวัง
- 🔴 สั่ง Word ด้วย AppleScript: **อ้างเอกสารด้วยชื่อไฟล์เท่านั้น ห้าม `active document`** และเช็ก `get name of every document` ก่อนเริ่ม
- 🔴 green `Deploy (demo)` ≠ deploy แล้ว — `.current_sha` เท่านั้น (CLAUDE.md)
- PR เอกสารล้วนยังรัน job `integration` (~4 นาที) — `server.yml` ข้ามเฉพาะตอน push
- #596 ถูก squash เป็น `e0b880a` — commit `c735752`/`3ea4489`/`c9f8c39` ไม่อยู่บน main ทีละตัว
- branch PR ที่ merge แล้วยังไม่ลบ: `feat/uptime-heartbeat`, `feat/app-metrics-overview-dashboard`, `docs/report-observability-2026-10-04` — ลบได้หลังเช็ก tip == `headRefOid` (ตรงทั้งสาม ณ เวลาบันทึก)

## 8. อ้างอิง
- PR #596, #597, #598, #599 · Deploy run `37204172280` · `docs/Backend_design/07_CICD_DEPLOY.md §7b` · `docs/report/README.md`
