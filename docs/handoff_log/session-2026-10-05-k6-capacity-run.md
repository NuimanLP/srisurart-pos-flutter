# Handoff — k6 บน `mob04` จาก 3 เครื่อง: รอบตามเกณฑ์ + รอบหา capacity (2026-10-05)

**วันที่:** 2026-10-05 · **ผู้บันทึก:** PattaraponKitcharoen (+ Claude) · **สถานะ:** รอคนอื่น (owner อ่านผล/ตัดสิน DoD, PR แก้สคริปต์ยังไม่ทำ)
**ขอบเขต:** การวัดจริงครั้งแรกของ **#380** — 3 เครื่องยิงผ่าน Nginx ของ `mob04` คนละ `perip`, ผลเข้า Prometheus ของ VM ด้วย remote-write
**ต่อจาก:** [`ticket-184-k6-rss-runbook.md`](ticket-184-k6-rss-runbook.md) (runbook เดิม) · `server/test/k6/README.md`

## 1. ตอนนี้อยู่ตรงไหน
- `mob04` = `7444ea4` ตลอดการวัด (ไม่มี deploy แทรก — Deploy run ที่ค้างรออนุมัติ `37213318965` ถูกยกเลิกก่อนเริ่ม)
- ข้อมูล k6 อยู่ใน Prometheus ของ VM (เก็บ 7 วัน): `testid="20261005T025730Z"` (รอบ 1) และ **`testid="20261005T034212Z"`** (รอบ 2 capacity, มี label `step`)
- ร้าน `loadtest` (tenant `00000000-0000-4000-8000-000000000001`) ยังอยู่ใน DB พร้อมบิลจากการวัด (3,752 บิล) — `pnpm k6:setup` ครั้งหน้าจะล้างและ seed ใหม่
- เก็บกวาดแล้ว: tunnel ปิด, logger บน VM หยุดและลบไฟล์ `/tmp` แล้ว, `k6-env.json` ลบบนเครื่อง peter-mac — **debian และ nui-meme ต้องลบเอง** (token อายุ 24 ชม.)
- ค้างบน VM: `/opt/pos/rss-under-load-20261005T025730Z.md` (root, จาก sampler ที่มีบั๊ก — ตาราง container ว่าง, "0 MiB" — **อย่าอ้างไฟล์นี้**)
- #380 ยังเปิด · ช่อง k6 ของ `03 §8` ยังไม่ติ๊ก (owner ตัดสิน)

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

**เครื่องยิง (campus Wi-Fi ไม่ผ่าน VPN — Nginx เห็น IP จริงต่อเครื่อง ไม่มี NAT, ยืนยันจาก log):**

| `MACHINE` | shard | IP | OS |
|---|---|---|---|
| `peter-mac` | 1 | 172.31.206.79 | macOS (k6 v2.2.0) |
| `debian` | 2 | 172.31.206.96 | Linux |
| `nui-meme` | 3 | 172.31.207.46 | macOS |

**ตรวจสอบด้วยอะไร:** k6 summary ต่อเครื่อง · Prometheus บน VM (`k6_*` ต่อ `machine`/`step`, metric ของ API/node-exporter) · Nginx access log (status ต่อ IP) · `pnpm k6:verify` + SQL ตรงบน DB · `docker stats` ดิบทุก 2 วินาที (คำนวณ peak เอง)

### รอบ 1 — ตามเกณฑ์ `02 §9` (`TESTID 20261005T025730Z`, 10:15–10:38 ICT)
| scenario | ผล | ใช้ได้ไหม |
|---|---|---|
| 1 อ่าน (24 r/s/เครื่อง) | p95 16 / 29 / 33 ms, error 0, cache ≥ 94.7%, **429 = 0** | ✅ (รอบ 10:31 — รอบ 10:15 debian/nui ไม่ได้ส่ง remote-write) |
| 2 แย่งซื้อ 200 คน (p12=50) | ขาย 50 พอดี, `k6:verify` ผ่านทุกข้อ · p95 1.64 s / 1.52 s ❌ · debian เริ่มช้า 5 วิ ได้แต่ 409 | ⚠️ |
| 3 replay 100 VU | 1 key = 1 บิล (67/67) · **429 = 39 + 23** · nui-meme ไม่ได้ยิงพร้อมกัน | ❌ (ดู §4) |

### รอบ 2 — หา capacity (`TESTID 20261005T034212Z`, 11:03:39–11:22:50 ICT, 15 ขั้น ตั้งเวลาอัตโนมัติ)
seed `P12_STOCK=375` (= 25+50+100+200) ให้ทุกขั้นของชุด 2 ขายสำเร็จจริง · ทุกขั้น **429 = 0** ทุกเครื่อง · **5xx = 0** · **restart/OOM = 0** (14 container) · สต็อกติดลบ 0 · บิล 3,752 = เลขใบเสร็จไม่ซ้ำ 3,752

| ชุด | โหลดรวม 3 เครื่อง | p95 (ช่วงของ 3 เครื่อง) | หมายเหตุ |
|---|---|---|---|
| 1 อ่าน | 18 / 36 / 54 / 72 r/s | 19–88 / 16–74 / 60–95 / 16–80 ms | API ฝั่ง server p95 ~7 ms; peter-mac ช้ากว่าเครื่องอื่นทุกขั้น = network ของเครื่องนั้น |
| 2 แย่งซื้อ p12 | 25 / 50 / 100 / 200 คน | 323–466 ms / 0.78–1.0 s / 0.96–2.0 s / 2.98–3.12 s | โตเป็นเส้นตรง ~15 ms/คน (คิวล็อกแถวสินค้า) |
| 3 replay ×5 | 9 / 18 / 27 VU | 78–118 / 260–481 / 655–787 ms | 53 key = 53 บิล; คิวที่ `doc_counters` ของร้าน |
| 4 ผสม 2 นาที/ขั้น | 18 / 36 / 54 / 72 r/s | 58–139 / 29–66 / 20–43 / 57–107 ms | p99 สูงสุด 338 ms (debian), pool exhaustion 0 |

**ฝั่ง VM ตลอดรอบ 2 (04:00:58–04:23:22 UTC):** RAM ทั้งเครื่องสูงสุด **1,561 / 5,920 MiB** · RAM รวม container ณ จุดเดียวกันสูงสุด **648 MiB** (เพดานรวม 4,256) · CPU VM สูงสุด 25% · event-loop p99 ≤ 12 ms · DB pool waiting 0 (scrape 15 วิ — ชุด 2/3 สั้นกว่านั้น จึงไม่เห็น) · POST /sales ฝั่ง API p95 25 ms (ชุด 4)

| container | peak MiB | limit | peak CPU% |
|---|---|---|---|
| postgres | 158 | 1024 | 118 |
| grafana | 82 | 256 | 21 |
| api-1/2/3 | 71 / 72 / 70 | 384 | 36 / 42 / 26 |
| prometheus | 66 | 512 | 31 |
| worker | 62 | 256 | 34 |
| อื่น ๆ (bull-board, etcd, redis×2, nginx, node-exporter, platform-ui) | ≤ 36 | — | ≤ 18 |

**สรุป capacity (p95 ไม่เกินเกณฑ์):** อ่าน **≥ 72 r/s** · ขาย+อ่านปน **≥ 72 r/s** (ชนเพดานเครื่องยิง ไม่ใช่ระบบ) · แย่งซื้อชิ้นเดียวร้านเดียว **~25 คน** · ส่งบิลพร้อมกันร้านเดียว **~18 บิล**

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร
- **เปลี่ยนจากลุ้นผ่านเกณฑ์เป็นหา capacity** (ผู้ใช้ 2026-10-05: "ไม่ต้องการแก้งานหลักแล้ว อยากรู้ว่ารับโหลดได้แค่ไหน") — ขั้นโหลดและรายงาน**ทุกขั้น**ไม่ใช่เฉพาะขั้นที่ผ่าน; ไม่ลดโหลดจนเขียว
- **scenario 3 สูงสุด 27 VU** — 34 VU × 5 ครั้ง ≈ 170 คำขอ/2 วิ ต่อ IP ชน `perip` (30 r/s, burst 60) แน่นอน; 9 VU/เครื่อง × 5 = 45 = burst budget · ไม่แตะ `perip` (owner ปฏิเสธ carve-out แล้ว)
- **ไม่เพิ่ม worker** — `POST /sales` ทำใน API แบบ synchronous; worker ทำงานหลัง commit; คอขวดคือล็อกแถว Postgres (สินค้า, `doc_counters`) ไม่ใช่จำนวน process
- **เริ่มพร้อมกันด้วยเวลา epoch** (`while date < START`) + ขั้นที่เลยเวลาแล้ว `SKIP` — แทนการนับ "go" (รอบ 1 มีเครื่องเริ่มช้า)
- **`k6:verify` รันจากเครื่อง peter-mac ผ่าน SSH tunnel** (Postgres/redis-cache ไม่มี port บน VM — IP container อ่านทุกครั้ง: ตอนนั้น `.128`/`.134`)
- ไม่แก้ `measure-container-rss.sh` บน VM ระหว่างวัด (มีแต่ `provision.yml` ที่ติดตั้ง) → ใช้ `docker stats` ดิบแทน

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)
- **`measure-container-rss.sh` บั๊ก:** `to_mib` เช็ก `[Bb]` ก่อน → `"55.4MiB"` ถูกหารแบบ byte → 0.00 · ตาราง container ว่าง + "Peak Total Stack RSS 0 MiB" แต่ verdict ยังพิมพ์ PASS · host memory ถูก (1,447 MiB รอบ 1)
- **`Idempotency-Key` ของสคริปต์ชนข้ามเครื่อง:** `02` = `idem-k6-contention-${__VU}-${__ITER}-${Date.now()}`, `03` = `idem-k6-replay-vu-${__VU}-${Date.now()}` · เลข VU นับใหม่ทุกเครื่อง + เริ่มพร้อมกันแม่น → 2 ครั้ง key เดียวกัน body ต่างกัน → server **409** (ถูกต้อง) · ผล: รอบ 2 ชุด 2 ขาย 374/375 (`k6:verify` ข้อ 4/5 FAIL), `replay-09` ของ peter-mac 409 ×5
- **`assertBurstSafe` ของ scenario 3 ตรวจไม่ครบ** — เช็กแค่จำนวน VU ≤ 45 ไม่คูณ 5 ครั้งที่ส่ง → 100 VU ผ่าน assert แต่ติด 429
- **remote-write จากเครื่องอื่นล้มเพราะพิมพ์ URL ผิด:** `https://k6/:<pw>@…/write/` (`/` หลัง `k6` และท้าย) → `lookup k6: no such host` · รหัสผิด → 401 (k6 ยังจบด้วย exit 0 และสคริปต์ทดสอบพิมพ์ `sent as …` ทั้งที่ส่งไม่ถึง)
- `pkill -f "measure-container-rss.sh 2400"` ใน `ssh '…'` ฆ่า shell ของ ssh เอง (command line มีข้อความเดียวกัน) — ใช้ `pgrep -f "^bash /opt/pos/scripts/…"`

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์
- **ขีดสุดจริงของอ่าน/ผสม ไม่ทราบ** — 72 r/s คือเพดานเครื่องยิง (3 IP × 24) ระบบยังไม่เหนื่อย (CPU 25%)
- "~15 ms ต่อคนในคิว" = สังเกตจากความชันของ p95 ใกล้กับ tx hold 14–22 ms ที่เคยวัด — ไม่ได้ trace รายคำขอ
- p95/p99 จาก remote-write เป็น **gauge ต่อเครื่อง** — ห้ามเฉลี่ยข้ามเครื่อง (README) · ค่าในตารางรอบ 2 = `last_over_time` (บาง series มี 2 ค่า/เครื่อง จึงให้เป็นช่วง)
- `K6_PROMETHEUS_RW_INSECURE_SKIP_TLS_VERIFY=true` ใช้ได้จริงกับ CA ส่วนตัวของ VM (ยืนยันแล้ว) — แต่ไม่ได้ลองแบบชี้ CA
- รหัส remote-write ใน `/opt/pos/.env` **ไม่ตรง** `mob04-demo.env` (sha ต่างกัน) ขณะที่ Nginx รับค่าของ `mob04-demo.env` — ไม่ได้ตรวจว่าทำไม (htpasswd ถูก bake ตอน bootstrap; `.env` อาจมี `\r`/ถูกเขียนทับภายหลัง)

## 6. ก้าวถัดไป (เรียงลำดับ)
1. debian + nui-meme ลบ `server/test/k6/k6-env.json`
2. owner: อ่านผลและตัดสินช่อง k6 ของ `03 §8` / AC ของ #380 (รอบ 1 scenario 1 ผ่านเกณฑ์; scenario 2 @200 = p95 ~3 s ไม่ผ่าน; scenario 3 @100 ไม่สะอาดเพราะ 429) — แปะสรุปนี้เป็น comment ใน #380
3. PR แก้สคริปต์: `to_mib` (เช็ก `GiB`/`MiB`/`KiB` ก่อน `B`) + test · key ของ `02`/`03` ใส่ shard/UUID · `assertBurstSafe` ของ `03` คูณจำนวนครั้งที่ส่ง · หลัง merge ต้อง **รัน `provision.yml` หรือติดตั้งมือ** ให้ `measure-container-rss.sh` บน VM เป็นตัวใหม่
4. owner: **เปลี่ยนรหัส remote-write** (หลุดในแชต 2026-10-05) — re-key volume `nginx-auth` เป็นงานแยก (CLAUDE.md) · ตรวจความต่างของรหัสใน `/opt/pos/.env`
5. (ทางเลือก) ลบ `/opt/pos/rss-under-load-20261005T025730Z.md` ที่ผิด (root)

## 7. ข้อควรระวัง
- 🔴 อย่าอ้าง "รับได้ 1,000 คนพร้อมกัน" — สิ่งที่วัดได้คือ ≤ 72 r/s ผ่าน 3 IP
- 🔴 ส่ง error ของ k6 ในแชตให้ลบรหัสออกก่อน (URL remote-write มีรหัสอยู่ในข้อความ error)
- ทุกเครื่องต้องอยู่ใน campus Wi-Fi/LAN คนละ IP (hotspot/router เดียวกัน = IP เดียว = 429) · ผ่าน allowlist = remote-write ได้ 401 ก่อนใส่รหัส
- `pnpm k6:setup` ได้ token ใหม่ทุกครั้ง → ต้องแจก `k6-env.json` ใหม่; ไม่ต้อง seed ใหม่หลัง scenario 1 (อ่านอย่างเดียว)
- ห้ามรัน k6 บน VM — มีคนรัน `curl` ทดสอบจาก VM เอง (`172.30.58.20`) ระหว่างเตรียม; ตอนยิงจริงไม่มี
- IP ของ Postgres/redis-cache ใน compose network เปลี่ยนทุก recreate — อ่านก่อนเปิด tunnel ทุกครั้ง

## 8. อ้างอิง
- Prometheus บน VM: `k6_http_req_duration_p95{testid="20261005T034212Z",machine,step}`, `k6_http_reqs_total{…,status}` · Grafana *Srisurart POS — overview* ช่อง k6 (SSH tunnel `-L 3000:127.0.0.1:3000`)
- สคริปต์: `server/test/k6/0{1..4}-*.js`, `server/test/k6/setup.ts`, `verify-integrity.ts`, `lib/shard.js` · `deploy/scripts/measure-container-rss.sh`
- `03_ARCHITECTURE.md §8.1` (วิธีวัด), `02_API_SCREENS.md §9` (เกณฑ์), #380
