# เช็กลิสต์ #344 `vm.demo` — รอบใหม่ เริ่มจาก AC1 บน tenant `ศรีสุราษฎร์เจริญยนต์` (2026-10-18)

ตรวจกับ `origin/main` @ `21ad935` (release #727, VM ควรรัน SHA เดียวกัน — **ต้องเช็กจริงที่ขั้น 0.1**) · เขียนจาก `develop` @ `f0dcff0`
แทนที่ [`demo-344-checklist-2026-09-30.md`](demo-344-checklist-2026-09-30.md) (ยังเก็บไว้เป็นประวัติ + ตาราง B ของ #335) ·
รอบก่อน: [`session-2026-10-05-demo344-retired-device.md`](session-2026-10-05-demo344-retired-device.md)
ที่มาของมติ "เริ่มใหม่จาก AC1": CLAUDE.md (2026-10-07 owner) — #616 cutover ล้างทุก tenant บน `mob04` เมื่อ 2026-10-06

> กติกาเดิมยังใช้: ไม่มีรหัสผ่านในไฟล์นี้ · "พิมพ์รหัส" = คนพิมพ์เองที่ TTY/หน้าจอ · `tempPassword` + `enrolCode` โผล่ **ครั้งเดียว**
> จดใส่ที่เก็บรหัสส่วนตัว ไม่ใส่ chat/repo · ห้ามติ๊ก AC ถ้ายังไม่ได้รันจริง · ขั้นไหนไม่ผ่านจดผลจริงในตารางท้ายไฟล์
> ผู้ช่วย (agent) **ห้าม login อะไรแทน** — ทำได้แค่อ่านผ่าน SSH/psql read-only/Prometheus ที่เจ้าของเปิดให้ (คอลัมน์ "agent ช่วยได้")

## AC ของ #344 (ตัวอักษรบนตั๋ว — ไม่เปลี่ยน)
| รหัส | AC |
|---|---|
| AC1 | provision tenant บน mob04 สำเร็จด้วย runbook จากใบที่ 3 (#338) |
| AC2 | เปิดเว็บ VM เห็นหน้า login และล็อกอินด้วย owner ที่เพิ่ง provision ได้ |
| AC3 | เปิดกะแล้วขายบิล 1 ใบ → แถวใน `sales` ของ tenant เพิ่ม 1 |
| AC4 | ส่งซ้ำด้วยคีย์เดิม → ไม่เกิดบิลที่สอง และตัวนับ replay ขยับบน Grafana |
| AC5 | panel success rate / p95 / error rate มีข้อมูลจริงหลังการขาย |
| AC6 | AC ทั้ง 11 ข้อของ #335 ติ๊กพร้อมหลักฐาน + บันทึกลง `docs/handoff_log/` |

## สิ่งที่เปลี่ยนตั้งแต่เช็กลิสต์ 2026-09-30 (ตรวจกับโค้ด/ตั๋วแล้วเมื่อ 2026-10-18)
- มีเพิ่ม (ไม่ใช่ AC แต่ควรโชว์/ใช้พิสูจน์): Grafana alerting 10 กฎ → Discord, Gatus 9 endpoints (`127.0.0.1:3300`), รูปสินค้า (owner-only),
  รูปหลักฐานหลังชำระเงิน, สแกนบาร์โค้ดด้วยกล้อง, แท็บ ซัพพลายเออร์ (ตามซัพฯ), กู้คืนข้อมูล (owner import) — ดูภาค 8 (ทางเลือก ไม่บังคับ)
- Healthchecks.io heartbeat ถูกถอดจาก `mob04` แล้ว (2026-10-18) — อย่าตามหา `healthcheck-ping.sh`/cron เดิม
- `ALERT_DISCORD_WEBHOOK` ตั้งแล้ว 2026-10-18 → **ระหว่างเดโมถ้ามี 5xx/p95 สูง/restart จะมี Discord เด้งจริง** (ดู "Blocker ใหม่" ท้ายไฟล์)

## 🔴 Blocker เดิม — ตรวจกับโค้ดปัจจุบันแล้ว (เก็บ / ตัด / แก้)
| # (ของเดิม) | สถานะ | หลักฐานที่ตรวจ |
|---|---|---|
| 1 AC4 ทำผ่านหน้าแอปตรง ๆ ไม่ได้ (key ต่อ 1 ตะกร้า) | **ยังจริง** | CLAUDE.md "bill id + Idempotency-Key minted once per cart"; ต้อง Replay XHR / curl · access token `'15m'` (`auth.service.ts:306`) |
| 2 รหัสชั่วคราว → บังคับเปลี่ยน **ภายใน 10 นาที** | **ยังจริง** | `PWCHANGE_TOKEN_TTL = '10m'` (`auth.service.ts:38`); temp password หมดอายุ 7 วัน → `401 TEMP_PASSWORD_EXPIRED`; `POST /platform/tenants` ยัง `400 OWNER_PASSWORD_NOT_ACCEPTED` (`platform-tenants.service.ts:91`) · ข้อความหน้าเปลี่ยนรหัสผ่านเจ้าของ ratify แล้ว 2026-10-07 (ตัด "agent ร่าง") |
| 3 tenant ใหม่ไม่มีสินค้า | **ยังจริง แต่ข้อย่อย "ปนสินค้า seed ของ Drift" ตัดทิ้ง** | `createTenant` ใส่แค่ `SEED_CATEGORIES` (5 หมวด) · API build ไม่ seed ข้อมูลเดโมแล้ว (+ `purgeDemoSeed` ครั้งเดียว) → ขายได้เฉพาะสินค้าที่สร้าง/นำเข้าเอง ทางเลือก: สร้างด้วยมือ 1–3 ตัว **หรือ** กู้คืนข้อมูลจากไฟล์ที่ **ส่งออกจากระบบนี้เอง** (ไฟล์โปรแกรมเดิม = `400 INVALID_ID`; ไม่ใส่ mode = ร้านว่างเท่านั้น, `02 §3.10`) |
| 4 AC ของ #335 ข้อ 1–3 พิสูจน์บน VM ตามตัวอักษรไม่ได้ | **ยังจริง** | ตาราง B ในเช็กลิสต์ 09-30 (เจ้าของตัดสินยอมนับหรือไม่) — ไม่เปลี่ยน |
| 5 CORS Origin แปลก → 500 | **ตัดทิ้ง (แก้แล้ว)** | PR #516 |
| 6 ห้ามยกเลิกผูกเครื่อง/ล้างข้อมูลเบราว์เซอร์หลังผูก (#476 ทางตัน) | **เบาลง แต่ยังควรระวัง** | #476 ปิดแล้ว (2026-10-03): platform-ui "replace" ออกรหัสใหม่ให้เครื่องที่หาย, พิสูจน์สดบน `mob04` — ไม่ใช่ทางตันแล้ว แต่ต้องพึ่ง platform admin; ใช้โปรไฟล์เบราว์เซอร์แยกสำหรับเดโมเหมือนเดิม |
| 7 อย่า approve `Deploy (demo)` ที่ค้างคิวระหว่างเดโม | **ยังจริง** | และยังมีกฎ "twin run" — รัน deploy 2 ตัวต่อ merge; ตัวที่ไม่ approve ค้างล็อก slot `deploy-demo` ไว้ → ยกเลิกหลังเดโมจบ |
| 8 403 สองชั้นของ platform-ui บน Linux | **ตัดทิ้ง** | วัดบน `mob04` แล้ว 2026-09-30 (#443 comment 5913452241) |
| (ใหม่) ปุ่มชำระเงินตกจอเตี้ย | **แก้ด้วยซูม** | มีซูมทั้งหน้าจอถึง 3x (#686) และ UI polish (#693) — ตั้ง `เล็ก 0.85x` ยังใช้ได้ ถ้ายังตกจอให้จดเป็นบั๊ก |

---

## ตัวช่วยในเทอร์มินัล (notebook ที่ต่อ VPN/Tailscale ครั้งเดียวต่อหน้าต่าง)
```bash
# ถามเจ้าของ: code ของร้าน (ASCII ไม่ซ้ำ; ตรวจ SELECT code FROM tenants ก่อน) — ตัวอย่างเท่านั้น
export DEMO_CODE=srisurat-jaroenyon
export DEMO_OWNER=owner_srisurat         # ชื่อผู้ใช้ owner
psql_vm() { ssh mob04 "sudo -n docker exec -i srisurart-pos-postgres-1 psql -U postgres -d pos -Atc \"$1\""; }
TID="(SELECT id FROM tenants WHERE code='$DEMO_CODE')"
prom_vm() { ssh mob04 "curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=$1'"; }
```
`psql -U postgres` ข้าม RLS (เห็นทุก tenant → ใส่ `WHERE tenant_id` เสมอ) · ห้าม `SELECT password_hash`/`token_hash` ค่าจริง ·
ชื่อ container `srisurart-pos-postgres-1` ตรวจรอบก่อน (10-05) ยังใช้ได้ — ถ้า `ssh` ขอรหัสให้แจ้งเจ้าของ อย่าเดา

---

## ภาค 0 — Pre-flight (ก่อนจับเวลา)

| ขั้น | เจ้าของทำ | หลักฐานที่เก็บ | agent ช่วยได้ |
|---|---|---|---|
| 0.1 VPN/Tailscale + สุขภาพ VM | `curl -sk -o /dev/null -w '%{http_code}\n' https://172.30.58.20/health/ready` = `200` | เอาต์พุต | รัน `ssh mob04 'sudo -n cat /opt/pos/.current_sha'` ต้อง = `21ad935…` (40 ตัว; ถ้าไม่ตรง **หยุดแล้วจดค่าจริง** — #728 อยู่ `develop` ยังไม่ถึง `main`) และ `docker ps` ทุกตัว healthy (api x3, postgres, redis-cache/queue, etcd, prometheus, grafana, **gatus**, nginx, worker, bull-board, platform-ui, node-exporter) |
| 0.2 เว็บที่เสิร์ฟ = release เดียวกัน | `curl -sk https://172.30.58.20/flutter_bootstrap.js \| grep -o 'main\.[0-9a-z]*\.dart\.js'` | ชื่อไฟล์ | เทียบ 12 ตัวแรกของ SHA (`main.21ad93586b5c.dart.js` ถ้าเป็นแพตเทิร์นเดิม) |
| 0.3 CLI platform มีใน image | — | — | `ssh mob04 'sudo -n docker exec srisurart-pos-api-1-1 ls dist/cli/platform.js'` |
| 0.4 เปิด tunnel | ฟอร์เวิร์ด **3000 Grafana · 3100 Bull-Board · 3200 platform-ui · 9090 Prometheus · 3300 Gatus** (ตัวหลังเพิ่มใหม่ — ถ้า alias `mob04-tunnel` ยังไม่มี `-L 3300:127.0.0.1:3300` ให้เติม) | `curl` health: `:3000/api/health`, `:9090/-/healthy`, `:3200/`, `:3300/` ได้ 200 | — |
| 0.5 baseline | — | จด `T0` (tenants), `R0` (`sum(pos_idempotency_replay_total)`; ถ้า `result:[]` รอ scrape 30 วิ), `H0` (`sum(http_requests_total)`) | รัน `psql_vm "SELECT count(*) FROM tenants"`, `prom_vm …`, และ `psql_vm "SELECT code,shop_name,status FROM tenants WHERE shop_name LIKE '%ศรีสุราษฎร์%' OR code='$DEMO_CODE'"` → **ถ้ามี tenant นี้อยู่แล้ว หยุด ถามเจ้าของว่าใช้ตัวเดิมหรือสร้างใหม่** |
| 0.6 baseline การเฝ้าระวัง | เปิด Gatus `http://localhost:3300` เห็น 9/9 สำเร็จ · Grafana → Alerting → 10 กฎ Normal | ภาพหน้าจอ 2 ใบ | อ่าน `prom_vm 'ALERTS{alertstate="firing"}'` (ควรว่าง) · ทำให้รู้ว่าก่อนเริ่มเขียว ไม่งั้นแยกไม่ออกว่า alert มาจากเดโม |
| 0.7 เบราว์เซอร์ | โปรไฟล์ใหม่/Incognito (ไม่เคยเข้า `https://172.30.58.20`) เข้าหน้าเว็บหนึ่งครั้ง กด *Advanced → Proceed* (cert จาก CA ส่วนตัว) · เปิด DevTools → Network ค้างก่อนขั้น 10 · Grafana: พิมพ์รหัสเอง | — | — |

---

## ภาค 1 — Provision (AC1)

| ขั้น | เจ้าของทำ | หลักฐาน | agent ช่วยได้ |
|---|---|---|---|
| 1 ทดสอบ login แอดมิน (กันเสียเวลา) | `ssh -t mob04 'sudo -n docker exec -it srisurart-pos-api-1-1 node dist/cli/platform.js login --user <admin>'` พิมพ์รหัสที่ prompt · ⚠ bucket login 10 ครั้ง/60 วิ ต่อ IP ร่วมกับ platform-ui | `logged in as …` | — |
| 2 สร้าง tenant (**AC1**) | CLI: `tenants:create --user <admin> --code $DEMO_CODE --shop-name "ศรีสุราษฎร์เจริญยนต์" --plan demo --owner-username $DEMO_OWNER --owner-display-name "เจ้าของร้าน"` (flags `--shop-name-en` ใส่หรือไม่ก็ได้) **ห้ามใส่ `--owner-password`** · หรือ platform-ui (`:3200`) ฟอร์ม "สร้างร้านใหม่" — ⚠ ฟอร์มนี้ **ไม่มีช่อง plan** (รอบ 10-05 ออกมา `basic`) ถ้าอยากได้ `demo` ใช้ CLI · จด `tempPassword` + `enrolCode` ทันที (หมดอายุ 7 วัน) | JSON ผล (ซ่อนรหัส) หรือภาพหน้าต่างผล | ตรวจใน DB: `tenants` (`code,plan,status`), `users` (`role=owner`, `must_change_password=t`), `devices` (`pos1`, `token_hash IS NULL`, มี `enrol_code_hash`), `categories` = 5 แถว, `audit_log` มี `platform.tenant.create` พร้อม `platform_admin_id`, `count(tenants)=T0+1` |

---

## ภาค 2 — เว็บ + login (AC2)

| ขั้น | เจ้าของทำ | หลักฐาน | agent ช่วยได้ |
|---|---|---|---|
| 3 หน้า login | เปิด `https://172.30.58.20/` → ต้องเด้งไป `#/login` ป้าย `โหมด Backoffice (ยังไม่ได้ผูกเครื่อง POS)` + ลิงก์ `ผูกเครื่องขาย (POS Terminal)` (ถ้าเข้าหน้าขายเลย = build ผิดโหมด หยุด) | ภาพหน้า login | — |
| 4 ผูกเครื่อง | `ผูกเครื่องขาย` → กรอก `enrolCode` 8 ตัว → `ยืนยันผูกเครื่อง` → `ผูกเครื่องสำเร็จ! …` (ข้อความ dialog ratify แล้ว 2026-10-07) | ภาพ | `devices`: `pos1 \| enrolled=t \| code_burned=t` |
| 5 login รหัสชั่วคราว → เปลี่ยนรหัส | ผู้ใช้ `$DEMO_OWNER` + รหัสชั่วคราว → ฟอร์ม "ตั้งรหัสผ่านใหม่" → ≥ 12 ตัว ไม่ซ้ำรหัสชั่วคราว → `บันทึกรหัสผ่าน` **ภายใน 10 นาที** (เกิน = `หมดเวลาเปลี่ยนรหัสผ่าน` ต้อง login ใหม่) → เข้าหน้า `ขายสินค้า` ป้าย `ออนไลน์` และ `เครื่อง POS` · จดรหัสใหม่ลงที่เก็บรหัสส่วนตัว | ภาพหลังเข้าหน้าขาย | `users`: `must_change_password=f`, `temp_password_expires_at IS NULL`, `password_changed_at IS NOT NULL` |

---

## ภาค 3 — สินค้า เปิดกะ ขาย (AC3)

| ขั้น | เจ้าของทำ | หลักฐาน | agent ช่วยได้ |
|---|---|---|---|
| 6 สินค้าทดสอบ (**ขาดไม่ได้**) | `สินค้า/สต็อก` → `เพิ่มสินค้า` → `DEMO-344-001`, ราคา 350, ทุน 200, สต็อก 50 (ทางเลือก: กู้คืนไฟล์ที่ส่งออกจากระบบนี้ — ดูภาค 8) · ป้ายต้อง `ออนไลน์` | ภาพรายการสินค้า | `products` มี `DEMO-344-001\|350.00\|200.00\|50` (ไม่มีแถว = เขียนลง Drift อย่างเดียว ไม่ถึง server) |
| 7 เปิดกะ | `ลิ้นชัก` → ฿1,000 → `เปิดร้าน` | ภาพ | `shifts`: `1000.00\|t\|pos1` |
| 8 baseline | — | `S0=0` | `count(sales)=0` และ `R0` ยังเท่าเดิม |
| 9 ขายบิลแรก (**AC3**) | ขาย `DEMO-344-001` ×1 `เงินสด` รับ ฿350 → ใบเสร็จ (จดเลข `RC01-2569-10-000N`) | ภาพใบเสร็จ | `sales` = 1 · `receipt_no` ตรงใบเสร็จ · `350.00\|เงินสด\|f\|pos1\|f` · `stock=49` · `movements`: `sale\|-1\|49` · `idempotency_keys` 1 แถว `POST /api/v1/sales\|done\|201` **จดค่า key** |

---

## ภาค 4 — ส่งซ้ำ key เดิม (AC4)

| ขั้น | เจ้าของทำ | หลักฐาน | agent ช่วยได้ |
|---|---|---|---|
| 10 บิลที่ 2 (ตัวทดสอบซ้ำ) | DevTools → Network กรอง `sales` → ขาย `DEMO-344-001` อีก 1 ชิ้น → เห็น `POST /api/v1/sales` 201 | ภาพ Network | `sales=2`, `stock=48`, `movements=2` (จด `S1`, `STK1`) |
| 11 ส่งซ้ำ (**ภายใน 15 นาทีหลัง login**) | คลิกขวา request ของบิลที่ 2 → **Replay XHR** (หรือ Copy as cURL วางใน terminal ตัวเอง **ห้ามวางลง chat/doc — มี Bearer token**) · เทียบ header `Idempotency-Key` กับ DB · ผลที่คาด 201 body เดิม; `409 IDEMPOTENCY_KEY_REUSED` = body ไม่ตรงบิตต่อบิต; `403` = token ไม่มี `did/drole` (login ใหม่หลังผูกเครื่อง) | ภาพ response + header | **ยังต้องเป็น `sales=2`, `stock=48`, `movements=2`** · `prom_vm 'sum(pos_idempotency_replay_total)'` = `R0+1` (รอ scrape ≤ 15 วิ; ตัวนับ per-process → ดู `sum()`) |
| 12 เห็นบน Grafana | `:3000` → *Srisurart POS — overview* (`srisurart-pos-overview`) → Last 15 minutes → panel **Idempotent replays** ขยับ | ภาพ panel | อ่านค่า `increase()` ยืนยัน |

---

## ภาค 5 — Observability (AC5)

| ขั้น | เจ้าของทำ | หลักฐาน | agent ช่วยได้ |
|---|---|---|---|
| 13 สาม panel หลังขาย (ภายใน ~1 นาที) | ดู **API success rate**, **API p95 latency**, **API error rate by status code** ต้องไม่ใช่ No data | ภาพ 3 panel | `sum(http_requests_total)` > `H0` · `sum by (route,status) (http_requests_total{route=~".*sales.*"})` · `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` · `up{job="api-metrics"}` 3 ตัว =1 |
| 13b (ใหม่) alert ยังเงียบหลังขาย | Grafana → Alerting ยัง Normal · Gatus ยัง 9/9 · Discord ไม่มีข้อความจากเดโม | ภาพ | `ALERTS{alertstate="firing"}` ว่าง |

หมายเหตุเดิมยังจริง: `/metrics`, `/health/*` ไม่นับใน SLI · panel k6 = no data (เป็นเรื่อง #380) · `Disk usage (/)` บน Linux ควรมีข้อมูล จดว่ามี/ไม่มี · target `api-readiness` down เป็นที่รู้อยู่แล้ว (ตรวจว่ายังจริงหรือแก้แล้ว: `up{job="api-readiness"}`)

---

## ภาค 6 — ข้อที่เหลือของ #335 (AC6)

| ขั้น | เจ้าของทำ | หลักฐาน | agent ช่วยได้ |
|---|---|---|---|
| 14 `/metrics` ในเครือข่าย compose = text | — | `# HELP …` | `ssh mob04 'sudo -n docker exec srisurart-pos-nginx-1 wget -qO- http://api-1:3000/metrics \| head -3'` |
| 15 `/metrics` ภายนอก = 404 | `curl -sk -o /dev/null -w '%{http_code}\n' https://172.30.58.20/metrics` | `404` | — |
| 16 `.current_sha` ไม่เปลี่ยนหลังเดโม | — | SHA ก่อน/หลังตรงกัน | `cat /opt/pos/.current_sha` |
| 17 rollback #335 ข้อ 11 | หลักฐานเดิม 2026-09-30 (#343) — เจ้าของตัดสินว่ายอมนับ; ถ้าไม่ยอม เดินตามคู่มือ VM §6.2 **หลังเดโมจบ** (recreate container) | คำตัดสิน | — |
| 18 #335 ข้อ 1–3 | เจ้าของเขียนคำตัดสินในตาราง B (เช็กลิสต์ 09-30) | ตาราง B | — |

---

## ภาค 7 — ปิดงาน

| ขั้น | เจ้าของทำ | agent ช่วยได้ |
|---|---|---|
| 19 สภาพที่ทิ้งไว้ | จะระงับร้าน: platform-ui → ร้าน → `ระงับชั่วคราว` หรือ CLI `tenants:status <tenantId> suspended` (อย่า `closed` เว้นแต่แน่ใจ) · **ห้าม `DELETE FROM tenants` ตรง ๆ** · ปิดกะ (ลิ้นชัก → ปิด) ถ้าไม่ต้องเดโมซ้ำ — นับ ฿2,000 | ตรวจ `tenants.status` |
| 20 บันทึก + ติ๊ก AC | เติมตาราง A/B ด้านล่าง → ให้ agent เขียน `docs/handoff_log/session-2026-10-…-demo-344-mob04.md` (คำสั่งจริง + เอาต์พุตที่ลบรหัสแล้ว) → ติ๊ก #344/#335 เฉพาะข้อที่ผ่านจริง ("ปิดบางส่วน" ให้เขียนตรง ๆ) · **ยกเลิก Deploy run ที่ค้างรออนุมัติ** ถ้ามี | ร่าง handoff + คอมเมนต์ตั๋ว (ให้เจ้าของอ่านก่อนโพสต์) |

---

## ภาค 8 — ทางเลือก: ฟีเจอร์ใหม่ 2026-10-10..13 (ไม่ใช่ AC — โชว์ได้ถ้ามีเวลา, ทำหลัง AC1–AC5 ผ่านเท่านั้น)

| ฟีเจอร์ | เจ้าของทำ | หลักฐาน / agent ช่วยได้ | ข้อควรระวัง |
|---|---|---|---|
| รูปสินค้า (owner-only, ออนไลน์เท่านั้น) | แก้สินค้า `DEMO-344-001` → เพิ่มรูป (jpeg/png/webp ≤ 3 MB) | `products.image_key` ไม่ว่าง · `curl -sk -o /dev/null -w '%{http_code}' https://172.30.58.20/img/<tenantId>/<key>_t.webp` = 200 | `403 OWNER_ONLY` ถ้าไม่ใช่ owner · ห้าม `down -v` |
| รูปหลักฐานหลังชำระเงิน | ใบเสร็จ → `ถ่ายรูปหลักฐานสินค้า` (กล้อง/ไฟล์ ≤ 5 รูป) → บันทึก | `sale_photos` มีแถว; หน้าเว็บ `/img/` ต้อง 404 สำหรับรูปบิล (เป็น volume แยก) | ปุ่มปิดขณะ Degraded หรือ `sale.create` ยังอยู่ใน outbox; ต้องอนุญาตกล้อง (เบราว์เซอร์ต้อง HTTPS ซึ่งหน้าเดโมเป็นอยู่แล้ว); PDPA notice ยังเป็นเรื่องค้างของเจ้าของ |
| สแกนบาร์โค้ดด้วยกล้อง | หน้าขาย/สินค้า/สร้าง PO → ปุ่มสแกน แสดง `DEMO-344-001` | ภาพ | จับเฉพาะ `partNo` ไม่มีคอลัมน์บาร์โค้ด; Chrome บน Windows ไม่มี BarcodeDetector → ใช้ zxing-wasm ที่แพ็กมา |
| แท็บ ซัพพลายเออร์ (ตามซัพฯ) | สินค้า → ซัพพลายเออร์ → สร้างใบสั่งซื้อ | ภาพ | route ซัพพลายเออร์ไม่มี role check (คำถามค้างของเจ้าของ) |
| กู้คืนข้อมูล (owner import) | ตั้งค่า → สำรอง/กู้คืน → กู้คืนข้อมูล ด้วยไฟล์ `.zip`/`.json` ที่ส่งออกจากระบบนี้ (ร้านว่าง ไม่ใส่ mode) | agent: `audit_log` action `backup.imported`, `doc_counters` ถูกยก | ยังไม่เคยรันจริงบน `mob04` (CLAUDE.md); สำเนา pre-import อยู่บนดิสก์ VM ไม่ถูกลบ; ข้อความไทยบางส่วนยัง `agent ร่าง` |

---

## ตาราง A — AC ของ #344 → หลักฐาน (เจ้าของกรอก)
| AC | ขั้น | ผ่าน? | หลักฐาน | หมายเหตุ |
|---|---|---|---|---|
| AC1 provision | 1–2 | | `tenants` +1, `users`, `devices`, `audit_log` | |
| AC2 login | 3–5 | | ภาพ login · `devices` enrolled · `must_change_password` t→f | ต้องผ่านขั้นเปลี่ยนรหัส |
| AC3 เปิดกะ+ขาย | 6–9 | | `sales` 0→1 · `receipt_no` · stock 50→49 | |
| AC4 ส่งซ้ำ | 10–12 | | sales=2 ก่อน/หลัง · stock 48 · `R0→R0+1` · ภาพ panel | ผ่าน DevTools/curl |
| AC5 panel | 13 | | ภาพ 3 panel + `prom_vm` | |
| AC6 #335 ครบ 11 + handoff | 14–20 | | ตาราง B + handoff | |

ตาราง B (AC 11 ข้อของ #335) ใช้ของเดิมในเช็กลิสต์ 09-30 — ไม่เปลี่ยน

## ปัญหาที่น่าจะเจอ
| อาการ | สาเหตุ / ทำอย่างไร |
|---|---|
| เว็บขึ้นแต่ทุก POST ล้ม | `ssh mob04 'sudo -n grep -c "^CORS_ORIGINS=.*https://172\.30\.58\.20" /opt/pos/.env'` ต้อง `1` |
| ขายแล้ว 403 | token ไม่มี `did/drole` → ออกแล้ว login ใหม่หลังผูกเครื่อง |
| `ขายไม่สำเร็จ`/สินค้าไม่พบ | ขายได้เฉพาะสินค้าที่อยู่บน server (ขั้น 6) |
| `หมดเวลาเปลี่ยนรหัสผ่าน` | เกิน 10 นาที → login ใหม่ด้วยรหัสชั่วคราวเดิม (ยังไม่เกิน 7 วัน) |
| `429` ตอน login แอดมิน | bucket 10/60 วิ ต่อ IP — รอ 1 นาที |
| panel ว่างหลังขาย | รอ scrape 15 วิ · `up{job="api-metrics"}` · ช่วง Last 15 minutes |
| Discord เด้ง alert ระหว่างเดโม | ดู Blocker ใหม่ข้อ N1 |

## Blocker ใหม่ที่พบตอนเขียนฉบับนี้ (ต้องตัดสินก่อนเริ่ม)
- **N1 — Discord alert เปิดจริงแล้ว** (2026-10-18). เดโมที่ปกติไม่ควรเด้ง แต่ถ้ามี 5xx หรือ p95 > 1 s ในช่วงนั้นจะมีข้อความเข้า Discord ของจริง · บอกคนในช่องล่วงหน้า หรือตั้ง silence ใน Grafana (เจ้าของทำเอง) · อย่าทำให้เกิด 5xx โดยตั้งใจ (เช่น ทดสอบ CORS แปลก ๆ ตอนนี้เป็น 2xx/4xx ปกติแล้วไม่เป็นปัญหา)
- **N2 — ไม่ทราบ `code` ของ tenant `ศรีสุราษฎร์เจริญยนต์`** (ชื่อร้านเป็นไทย; `code` ต้องไม่ซ้ำ, ใน DB ไม่เคยเห็นค่าที่เจ้าของเลือก) → เจ้าของเลือก/ยืนยันก่อนขั้น 2 ขั้น 0.5 จะเช็กชื่อซ้ำให้
- **N3 — VM รัน `21ad935` เท่านั้นที่ยืนยันแล้วในเอกสาร 10-17** · `develop` มี #728 (host-setup.sh) ที่ยังไม่ถึง `main` — ไม่กระทบเดโม แต่ถ้ามีคนเปิด release ใหม่ระหว่างทาง `.current_sha` จะเปลี่ยน (ขั้น 16)
- **N4 — ไม่ได้ตรวจกับ VM จริงในรอบเขียนนี้** (ไม่มีการ login/SSH) ทุกข้อ "ตรวจกับโค้ด" ข้างบนคือกับ repo เท่านั้น ชื่อ container/ตาราง/`up{job=…}` ต้องยืนยันตอนรันจริง
