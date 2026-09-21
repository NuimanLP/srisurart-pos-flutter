# ซ้อมเดโม #335 บนเครื่องผู้พัฒนา (rehearsal on dev) — 2026-09-21

> 🔴 **นี่คือการ "ซ้อม" บนเครื่อง dev เท่านั้น — ไม่ปิด AC ของ #335, #343 หรือ #344 แม้ข้อเดียว**
> User story 32 ของ #335 เขียนไว้ตรงตัวว่าผู้ประเมินต้องเห็นระบบทำงาน **บนเครื่องจริง ไม่ใช่
> localhost ของนักศึกษา** ดังนั้นทุกอย่างในเอกสารนี้เป็นการพิสูจน์ว่า **โค้ดเดินได้ทั้งเส้น**
> เพื่อให้ตอนขึ้น VM เหลือแค่ปัญหาของ VM · **เดโมบน `mob04` ยังไม่ได้ทำ** และห้ามเขียนหรือ
> ตีความว่าทำแล้ว · AC จะถูกติ๊กที่ **#344** พร้อมหลักฐานจาก VM เท่านั้น

| | |
|---|---|
| วันที่รัน | 2026-09-21 (เวลาไทย ~20:45–21:20) |
| `main` ที่รัน | `5b16d05` (หลัง merge #371 #372 #373 #374) |
| เครื่อง | Windows 11 Pro, Docker Desktop, checkout ที่ `D:\Beestation\Sri_POS\Flutter` |
| สแตก | `srisurart-pos` (สแตกเดิมที่รันอยู่แล้ว — **ไม่ได้ตั้งสแตกที่สอง**, ไม่เคยรัน `down -v`) |
| tenant ที่ใช้ซ้อม | `srisurart-rehearsal` / `9e7c86d4-1463-4b4f-a885-b472e26774d8` (แยกจาก `srisurart-demo` ของ #338 ที่ยังอยู่) |
| GIF | [`media/demo-rehearsal-login-sale-grafana.gif`](media/demo-rehearsal-login-sale-grafana.gif) (50 เฟรม, 7.3 MB) |
| ภาพนิ่ง | [`media/demo-rehearsal-grafana-panels.jpg`](media/demo-rehearsal-grafana-panels.jpg) |
| แก้โค้ดไหม | **ไม่** — diff ของ branch นี้มีแต่ไฟล์ในโฟลเดอร์ `docs/handoff_log/` |

**ผลรวม 7 ขั้น:** ✅ 1 สแตกขึ้น · ✅ 2 bootstrap admin + platform token · ✅ 3 provision tenant
ได้ `enrolCode` · ✅ 4 build web โหมด server · ✅ 5 login → เปิดกะ → ขาย 1 บิล ·
✅ 6 `sales` +1 แล้วส่งซ้ำคีย์เดิมไม่เกิดบิลที่สอง + counter ขยับ · ✅ 7 Grafana มีข้อมูลจริง
🔴 มีหลายจุดที่สะดุดและต้องใช้ทางเลี่ยงบนเครื่อง dev — §9

---

## 1. ขั้น 1 — สแตกขึ้น

`server/.env` มีครบทุกคีย์ที่ compose บังคับด้วย `:?` แล้วตั้งแต่ #336 — ตรวจซ้ำ:

```
$ grep -ohE '\$\{[A-Z_0-9]+:\?[^}]*\}' server/docker-compose.yml deploy/compose/*.yml \
    | grep -oE '[A-Z_0-9]+' | sort -u
BULL_BOARD_PASSWORD ETCD_ROOT_PASSWORD GRAFANA_ADMIN_PASSWORD IMAGE_TAG JWT_PLATFORM_SECRET
JWT_PRIVATE_KEY JWT_PUBLIC_KEYS K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD
K6_REMOTE_WRITE_BASIC_AUTH_USER POSTGRES_PASSWORD POS_APP_PASSWORD REDIS_PASSWORD
```

ครบทุกตัวที่เป็นของสแตก (ไม่นับ `IMAGE_TAG` ที่ Ansible ส่งเอง) — **ไม่ต้องเดาหรือสร้างค่าใหม่**

🔴 **`CORS_ORIGINS` ถูกปล่อยไม่ตั้งค่าโดยเจตนา** (dev = `'*'`) ห้ามใส่ค่าว่าง ๆ อย่าง `,`
เพราะ `csvAllowlist` (`server/src/config/config.ts:66-77`) **throw ตอน boot**:
`CORS_ORIGINS is set but lists no entry (got ',') — leave it empty to disable`

ค่าที่ container เห็นจริงหลัง #373 (ผ่าน `x-app-env`) — สตริงว่างสองตัว ซึ่ง config แปลว่า "ไม่ตั้ง":

```
$ docker compose exec -T api-1 sh -c 'printenv | grep -cE "^(CORS_ORIGINS|PLATFORM_ADMIN_IPS)="'
2
$ docker compose exec -T api-1 printenv CORS_ORIGINS PLATFORM_ADMIN_IPS
(ว่างทั้งสองบรรทัด)
```

สแตกขึ้นด้วยชุด overlay นี้ (ใช้ชุดเดิมทุกครั้ง — ดู §9.2 ว่าทำไมสำคัญ):

```bash
SP=<scratchpad>          # ไฟล์ overlay ของ dev ที่ไม่ commit — §9.1 / §9.7
cd server
docker compose -f docker-compose.yml -f docker-compose.dev.yml \
               -f "$SP/web-dev.override.yml" -f ../deploy/compose/monitoring.yml up -d
```

```
srisurart-pos-api-1-1          Up (healthy)      srisurart-pos-node-exporter-1  Up (healthy)
srisurart-pos-api-2-1          Up (healthy)      srisurart-pos-postgres-1       Up (healthy)
srisurart-pos-api-3-1          Up (healthy)      srisurart-pos-prometheus-1     Up (healthy)
srisurart-pos-bull-board-1     Up                srisurart-pos-redis-cache-1    Up (healthy)
srisurart-pos-etcd-1           Up (healthy)      srisurart-pos-redis-queue-1    Up (healthy)
srisurart-pos-grafana-1        Up (healthy)      srisurart-pos-worker-1         Up
srisurart-pos-nginx-1          Up
```

```
$ curl -sk https://localhost/health/ready
{"status":"success","data":{"status":"up","checks":{"postgres":"up","redisCache":"up","redisQueue":"up"}}}

$ docker compose exec -T nginx wget -qO- http://172.30.0.11:3000/metrics | head -3
# HELP process_cpu_user_seconds_total Total user CPU time spent in seconds.
# TYPE process_cpu_user_seconds_total counter
process_cpu_user_seconds_total 0.25833900000000004

$ curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/metrics
404
```

→ text format จากในเครือข่าย compose (ไม่ถูกห่อ envelope) และ **404 จากภายนอก** ตาม D4 ข้อ 3

---

## 2. ขั้น 2 — `bootstrap:admin` → platform token

รหัสสุ่มด้วย `openssl rand -hex 10` (20 ตัวอักษร ≥ 12 ตาม #364) เก็บไว้นอก repo **ไม่ commit**

```bash
docker compose run --rm \
  -e BOOTSTRAP_ADMIN_USERNAME='admin' \
  -e BOOTSTRAP_ADMIN_PASSWORD='<20 hex>' \
  -e BOOTSTRAP_ADMIN_DISPLAY_NAME='ผู้ดูแลระบบ' \
  migrate node dist/db/bootstrap-admin.js
```

```
platform admin "admin": created
```

จากนั้นเอา token ผ่าน loopback ของ nginx ตามรันบุ๊ก #338 §3 (`--post-file` เสมอ):

```bash
printf '{"username":"admin","password":"<รหัส>"}' > /tmp/body.json
docker compose cp /tmp/body.json nginx:/tmp/body.json
docker compose exec -T nginx wget -qO- --no-check-certificate \
  --header 'Content-Type: application/json' --post-file /tmp/body.json \
  https://127.0.0.1/api/v1/platform/auth/token
```

```
{"status":"success","data":{"token":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzcmlz…",
 "admin":{"id":"45d33ceb-5b35-46b4-8087-8a8c82aa34d4","username":"admin",
 "displayName":"ผู้ดูแลระบบ",…}}}
```

⚠️ **ไม่ได้ทดสอบซ้ำในรอบนี้:** การรันสคริปต์ซ้ำแล้วรหัสเดิมยังใช้ได้ และ `--force` เปลี่ยนรหัส
— สองข้อนั้นเป็น AC ของ **#337** และมี e2e คุมอยู่แล้ว (`server/test/bootstrap-admin.e2e-spec.ts`)
รอบนี้รันสคริปต์ครั้งเดียว บน DB ที่ยังไม่มี admin จึงได้ `created`

---

## 3. ขั้น 3 — provision tenant จากในคอนเทนเนอร์ nginx

```bash
printf '{"code":"srisurart-rehearsal","shopName":"ศรีสุรัตน์ อะไหล่ยนต์ (ซ้อมเดโม)",
"shopNameEn":"Srisurart Autopart (rehearsal)","plan":"demo","ownerUsername":"owner_rehearsal",
"ownerPassword":"<20 hex>","ownerDisplayName":"เจ้าของร้าน"}' > /tmp/body.json
docker compose cp /tmp/body.json nginx:/tmp/body.json
docker compose exec -T nginx wget -qO- --no-check-certificate \
  --header 'Content-Type: application/json' --header "Authorization: Bearer $TOKEN" \
  --post-file /tmp/body.json https://127.0.0.1/api/v1/platform/tenants
```

```
{"status":"success","data":{"tenantId":"9e7c86d4-1463-4b4f-a885-b472e26774d8",
 "code":"srisurart-rehearsal","shopName":"ศรีสุรัตน์ อะไหล่ยนต์ (ซ้อมเดโม)",
 "ownerUsername":"owner_rehearsal","enrolCode":"CE7DA8B3"}}
```

`enrolCode` = **`CE7DA8B3`** (คืนครั้งเดียว · DB เก็บแต่ sha256 · หมดอายุ 7 วัน) →
ถูกใช้ผูกเครื่องในเบราว์เซอร์ทันทีในขั้นที่ 5 ตามที่รันบุ๊ก #338 เตือนไว้ว่า **อย่าทิ้งข้ามวัน**

ไม่แก้ `nginx.conf` และไม่ตั้ง `PLATFORM_ADMIN_IPS` · ไม่ใช้ `ssh -L` (ตาม D3)

---

## 4. ขั้น 4 — build web โหมด server แบบเดียวกับ CI

คำสั่งเดียวกับ `.github/workflows/flutter.yml:213-217` เป๊ะ:

```bash
cd frontend
flutter pub get
flutter build web --no-tree-shake-icons \
  --dart-define=USE_API_WRITES=true \
  --dart-define=API_BASE_URL=
```

```
Compiling lib\main.dart for the Web...                             40.8s
√ Built build\web
```

🔴 **`API_BASE_URL=` (ว่าง) คือค่าที่ถูก ไม่ใช่โฮสต์ของ nginx ตรง ๆ** —
`ApiClient` (`frontend/lib/core/network/api_client.dart:20`) มี default เป็น
`http://localhost:3000` และ `--dart-define=KEY=` **override เป็นสตริงว่าง** ซึ่งแปลว่า
*same-origin* · path ของทุกคำขอมี `/api/v1` อยู่แล้ว และเว็บถูกเสิร์ฟผ่าน nginx ตัวเดียวกับ API
→ ไม่มี CORS และไม่ต้องรู้ชื่อโฮสต์ตอน build (นี่คือเหตุผลที่ #342 เลือกค่าว่าง)
ถ้าใส่โฮสต์ตรง ๆ จะกลายเป็น cross-origin ทันที และต้องไปตั้ง `CORS_ORIGINS` ให้ตรงเป๊ะ

บน dev ต้อง bind-mount `frontend/build/web` เข้า nginx เอง เพราะ `server/docker-compose.yml`
ไม่มี volume ของเว็บ (บน VM `deploy/compose/vm.override.yml:29-40` เอามาจาก image GHCR) — §9.1

---

## 5. ขั้น 5 — เบราว์เซอร์: login → ผูกเครื่อง → เปิดกะ → ขาย 1 บิล

ดู GIF `media/demo-rehearsal-login-sale-grafana.gif` (บันทึกจริงทั้งรอบ)

1. เปิดเว็บ → เด้งไป **`#/login`** ทันที · หน้าจอมีป้าย *"โหมด Backoffice (ยังไม่ได้ผูกเครื่อง POS)"*
   → **นี่คือหลักฐานว่า build เป็นโหมด server** (`USE_API_WRITES` เปิด `requireLogin`
   ที่ `frontend/lib/app.dart:18`) build ออฟไลน์จะเข้าหน้าขายเลยโดยไม่ถามอะไร
2. กด **"ผูกเครื่องขาย (POS Terminal)"** → กรอก `CE7DA8B3` →
   *"ผูกเครื่องสำเร็จ! เครื่องนี้ได้รับการตั้งค่าเป็น POS Terminal แล้ว"*
3. login `owner_rehearsal` → เข้าหน้าขาย · มุมขวาบนขึ้น **ออนไลน์**
4. **ลิ้นชัก → เงินตั้งต้น ฿1,000 → เปิดร้าน** → กะเปิด (แถวใหม่ใน `shifts` ฝั่งเซิร์ฟเวอร์)
5. **ขายสินค้า → Brake Pad (demo) ฿350 → รับเงิน ฿350 → ชำระเงิน** → ใบเสร็จ **`RC01-2569-09-0001`**

---

## 6. ขั้น 6 — ยืนยันฝั่งเซิร์ฟเวอร์ + ส่งซ้ำด้วยคีย์เดิม

**ก่อนขาย** `sales` ของ tenant นี้ = **0** แถว

**หลังขายบิลแรก:**

```
$ docker compose exec -T postgres psql -U postgres -d pos -c \
  "SELECT id,receipt_no,total,payment_method,voided,shift_id,device_id,sold_offline
     FROM sales WHERE tenant_id='9e7c86d4-1463-4b4f-a885-b472e26774d8'"
          id          |    receipt_no     | total  | payment_method | voided |       shift_id        | device_id | sold_offline
 smubbk5f0_e2f7efd6_3 | RC01-2569-09-0001 | 350.00 | เงินสด          | f      | shmubbfmfs_136cd4c6_1 | pos1      | f
(1 row)

  id                   |  date_str  | starting_cash | is_active | device_id
 shmubbfmfs_136cd4c6_1 | 2026-09-21 |       1000.00 | t         | pos1

  product_id           | part_no  | qty | price
 pmubb666o_50cabf0c_1  | DEMO-001 |   1 | 350.00

 part_no  | stock
 DEMO-001 |    49        ← จาก 50
```

**`sales` เพิ่มจาก 0 → 1 เป๊ะ** และแถวพก `device_id='pos1'`, `shift_id`, `sold_offline=false`

### 6.1 ส่งซ้ำด้วย `Idempotency-Key` เดิม

ขายบิลที่สองในเบราว์เซอร์ (`smubbn2x9_8cf6a86b_5` / `RC01-2569-09-0002`) แล้ว **ส่งคำขอเดิมซ้ำ**
จาก CLI · คีย์จริงที่ client ใช้อ่านได้จาก `idempotency_keys`:

```
key           | idemmubbn2x9_bf7b7616_6
endpoint      | POST /api/v1/sales
request_hash  | 8ca605f39551413fd7db615bf847f883e064422601ccd5e872a1fed5f543276e
status        | done
response_code | 201
```

🔴 `IdempotencyService.requestHash` เป็น `sha256(JSON.stringify(body))` **ตามลำดับคีย์ที่มาบนสาย**
ถ้า body ไม่ตรงบิตต่อบิตจะได้ `409 IDEMPOTENCY_KEY_REUSED` ไม่ใช่ replay จึง **ประกอบ body
ขึ้นใหม่จาก `_saleBody`** (`frontend/lib/data/repositories/api/api_sales_repository.dart:225-263`)
แล้ว **ตรวจว่าแฮชตรงก่อนส่ง** — ตรงเป๊ะ (`8ca605f3…` = `8ca605f3…`) จึงยิงได้อย่างมั่นใจ
(นี่คือเหตุผลที่ replay ทำกับ **บิลใบที่สอง** ไม่ใช่ใบแรก: ต้องมีคีย์+body คู่กันที่พิสูจน์ได้)

ค่าก่อนส่งซ้ำ: `pos_idempotency_replay_total` = `0 / 0 / 0` (api-1/2/3)

```bash
docker compose exec -T nginx wget -qO- --no-check-certificate \
  --header 'Content-Type: application/json' --header "Authorization: Bearer $AT" \
  --header 'Idempotency-Key: idemmubbn2x9_bf7b7616_6' \
  --post-file /tmp/replay.json https://127.0.0.1/api/v1/sales
```

```
{"status":"success","data":{"id":"smubbn2x9_8cf6a86b_5",…,"products":[{"id":"pmubb666o_50cabf0c_1",
 "stock":48}],…,"receiptNo":"RC01-2569-09-0002","pointsGranted":35,…}}
```

คำตอบคือ **body ที่ถูกเก็บไว้** (บิลเดิม เลขเดิม `stock:48` ค่าเดิม) ไม่ใช่การขายใหม่ · ตรวจ DB:

```
 sales_rows      2          ← ยังเป็น 2 (สองคีย์ = สองบิล) ไม่มีบิลที่สาม
 part_no DEMO-001 stock 48  ← ไม่ถูกตัดซ้ำ
 movement_rows   2          ← ไม่มี movement เพิ่ม

$ for ip in 11 12 13; do … /metrics | grep pos_idempotency_replay_total; done
172.30.0.11: pos_idempotency_replay_total 0
172.30.0.12: pos_idempotency_replay_total 0
172.30.0.13: pos_idempotency_replay_total 1     ← ขยับ 1
```

counter เป็น **per process** ตามที่ D5 เขียนไว้ — ขยับที่ instance ที่รับคำขอเท่านั้น
panel ต้อง `sum()` ซึ่งทำอยู่แล้ว

🔴 **กับดักที่เจอซ้ำกับที่รันบุ๊ก #338 เตือน:** ยิง `POST /sales` ด้วย token ที่ login โดย
**ไม่ส่ง `deviceToken` ใน body** ได้ **403** (log ของ api-3 ยืนยัน `"statusCode":403`) เพราะ token
ไม่มี `did`/`drole` · ต้อง login ใหม่พร้อม `deviceToken` จึงได้
`{"tid":"9e7c86d4-…","role":"owner","did":"pos1","drole":"pos"}` แล้วยิงผ่าน
(`deviceToken` ของเครื่องในเบราว์เซอร์อยู่ที่ `localStorage['flutter.auth_device_token']`)

---

## 7. ขั้น 7 — Grafana

`http://127.0.0.1:3000` (loopback เท่านั้น) · dashboard `srisurart-pos-overview` · ช่วง 15 นาที

Prometheus targets: `api-metrics` **up 3/3** (`api-1:3000`, `api-2:3000`, `api-3:3000`), `node` up

| panel | ค่าที่เห็นภายใน ~1 นาทีหลังขาย |
|---|---|
| **API success rate** | **100 %** — มีข้อมูลจริง |
| **API p95 latency** | **169 ms** — มีข้อมูลจริง |
| **API error rate by status code** | มี series **`403`** จริง (คำขอที่ขาด `did` ใน §6.1) → พิสูจน์ว่า middleware นับคำขอที่ guard ปฏิเสธด้วย ตาม D4 |
| **Idempotent replays** | **1.01** (`increase()` ของ counter ที่เพิ่ง +1) |
| CPU / Memory (node-exporter) | มีข้อมูล |
| Disk usage (/) | **No data** — §9.4 |
| k6 429 panel | **no data** ตามคาด (ของ #251/#184 ยังไม่ได้รัน) |

ภาพ: [`media/demo-rehearsal-grafana-panels.jpg`](media/demo-rehearsal-grafana-panels.jpg)

---

## 8. สคริปต์พูดตอนเดโม (ผู้เล่าอ่านตามได้เลย)

> เตรียมก่อนขึ้นเวที: สแตกขึ้นแล้ว · tenant provision แล้วและ **ผูกเครื่องเรียบร้อย** ·
> กดผ่านหน้าเตือนใบรับรองไปแล้ว · ตั้งขนาดตัวอักษรเป็น `เล็ก 0.85x` ถ้าจอเตี้ย (§9.8) ·
> เปิดแท็บไว้สองแท็บ (แอป, Grafana) และเปิด terminal ที่เตรียมคำสั่งไว้ · **อย่าเพิ่ง login**

1. **เปิดแท็บแอป**
   > "นี่คือเว็บที่ deploy อยู่บนเครื่องเซิร์ฟเวอร์ครับ สังเกตว่ามันขึ้น**หน้าล็อกอิน** —
   > แค่ตรงนี้ก็บอกแล้วว่า build ตัวนี้เป็นโหมดที่คุยกับเซิร์ฟเวอร์จริง ไม่ใช่แอปออฟไลน์ที่ร้านใช้อยู่"

2. **ชี้ป้าย "โหมด Backoffice / ผูกเครื่องขาย (POS Terminal)"**
   > "เครื่องที่จะขายได้ต้องถูก 'ผูก' กับร้านก่อน ด้วยรหัสที่ระบบออกให้ตอนเปิดร้านใหม่
   > เครื่องนี้ผูกไว้แล้ว ส่วนเครื่องที่ยังไม่ผูกจะดูข้อมูลได้แต่ขายไม่ได้"

3. **login ด้วยบัญชีเจ้าของร้าน**
   > "ล็อกอินด้วยบัญชีเจ้าของร้านที่ถูกสร้างขึ้นพร้อมร้านตอน provision — ไม่มีการแก้ฐานข้อมูลด้วยมือเลย"

4. **ชี้ป้าย "ออนไลน์" มุมขวาบน**
   > "ป้ายนี้บอกว่าแอปคุยกับเซิร์ฟเวอร์ได้ ทุกบิลจากนี้จะลง PostgreSQL ไม่ใช่แค่ในเครื่อง"

5. **ไปหน้า "ลิ้นชัก" → ใส่เงินตั้งต้น ฿1,000 → กด "เปิดร้าน"**
   > "เปิดกะก่อนเริ่มขาย เหมือนที่ร้านทำทุกเช้า — กะนี้ถูกบันทึกฝั่งเซิร์ฟเวอร์ พร้อมว่าเครื่องไหนเปิด"

6. **ไปหน้า "ขายสินค้า" → กดสินค้า 1 ตัว → กดปุ่มจำนวนเงินที่รับ → "ชำระเงิน"**
   > "ขายหนึ่งบิล ... ใบเสร็จได้เลขจากเซิร์ฟเวอร์ ไม่ใช่เลขที่เครื่องคิดเอง
   > สองเครื่องขายพร้อมกันเลขก็ไม่ชนกัน"

7. **สลับไป terminal รันคำสั่งนับแถวใน `sales`**
   > "ฝั่งฐานข้อมูล บิลเพิ่มขึ้นหนึ่งแถวพอดี เลขใบเสร็จเดียวกับที่เห็นบนจอ และสต็อกลดลงหนึ่งชิ้น"

8. **รันคำสั่งส่งซ้ำด้วย `Idempotency-Key` เดิม**
   > "สมมติว่าเน็ตหลุดตอนกดขาย แล้วเครื่องส่งคำขอเดิมซ้ำ — เซิร์ฟเวอร์ตอบ**บิลใบเดิม**
   > ด้วยเลขเดิม ไม่ได้ขายใหม่"

9. **รันคำสั่งนับแถวอีกครั้ง**
   > "ยังเท่าเดิม ไม่มีบิลที่สอง สต็อกก็ไม่ถูกตัดซ้ำ นี่คือกลไกกันบิลซ้ำที่ทำงานจริง"

10. **สลับไปแท็บ Grafana**
    > "แดชบอร์ดนี้อ่านตัวเลขจาก API ทั้งสามตัวรวมกัน — success rate, p95 latency
    > และ error rate ที่แยกตาม status code ไม่ปน 4xx ที่เป็นเรื่องปกติกับ 5xx ที่เป็นเรื่องใหญ่"

11. **ชี้ panel *Idempotent replays* ที่ขยับ**
    > "กราฟนี้คือหลักฐานว่ากลไกกันบิลซ้ำ **มองเห็นได้** ไม่ใช่แค่เชื่อว่ามี"

12. **ปิด**
    > "ทั้งหมดนี้วิ่งบนเครื่องเซิร์ฟเวอร์ หลัง Nginx ตัวเดียว · `/metrics` ตอบ 404 จากข้างนอก
    > และหน้า platform admin เรียกได้จากในเครื่องเท่านั้น"

**คำถามที่น่าจะถูกถาม + คำตอบสั้น**
- *"ทำไมสินค้าในหน้าขายมีทั้งของร้านใหม่และของตัวอย่าง?"* → หน้าขายอ่านจากแคช Drift ในเครื่อง
  ซึ่งมี seed ตัวอย่างติดมาตอนเปิดครั้งแรก · ของที่ **ขายได้จริง** คือของที่มีในเซิร์ฟเวอร์ (§9.3)
- *"ใบกำกับภาษีเต็มรูปล่ะ?"* → อยู่นอกขอบเขต v1
- *"ออฟไลน์ขายได้ไหม?"* → เป็นงานเฟส 2 (outbox + `/sync/push`) ยังไม่อยู่ในเดโมนี้
- *"ทำไมขึ้นเตือนใบรับรองไม่ปลอดภัย?"* → ใบรับรองเป็น self-signed ของเดโม ยังไม่ได้ออกใบจริง

---

## 9. ทุกจุดที่สะดุด และแก้ด้วยอะไร

### 9.1 🔴 nginx บน dev ไม่มี volume ของเว็บ (ช่องว่างข้อ 4 ของ #335)
`server/docker-compose.yml` ไม่ mount web root เลย → `https://localhost/` ได้หน้า
"Welcome to nginx!" · บน VM `vm.override.yml` เอามาจาก image `srisurart-pos-web`
**แก้ (dev เท่านั้น):** overlay ใน scratchpad ที่ bind-mount `frontend/build/web` เข้า
`/usr/share/nginx/html` — ต้องเขียน `volumes:` ของ nginx **ซ้ำทั้งชุด** เพราะ compose
**แทนที่** list ไม่ได้ merge · **ไม่ commit และไม่แก้ไฟล์ใน repo**
บน VM ไม่ต้องทำอะไร — เป็นความต่างของ dev อย่างเดียว

overlay ทั้งไฟล์ (รวม `tlswrap` ของ §9.7) — วางไว้นอก repo แล้วต่อด้วย `-f` ทุกครั้ง:

```yaml
name: srisurart-pos
services:
  nginx:
    volumes:
      - D:/Beestation/Sri_POS/Flutter/server/docker/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - certs:/etc/nginx/certs:ro
      - nginx-auth:/etc/nginx/auth:ro
      - D:/Beestation/Sri_POS/Flutter/frontend/build/web:/usr/share/nginx/html:ro

  tlswrap:
    image: alpine/socat
    restart: unless-stopped
    depends_on:
      nginx: { condition: service_started }
    command: TCP-LISTEN:8081,fork,reuseaddr OPENSSL:nginx:443,verify=0
    ports:
      - "127.0.0.1:8081:8081"
```

### 9.2 🔴 `docker compose run` โดยไม่ใส่ `-f` ชุดเดิม → recreate postgres ทิ้ง port ของ dev
รัน `docker compose run --rm … migrate` จากใน `server/` โดยไม่ต่อ `-f docker-compose.dev.yml`
ทำให้ compose เห็นสแตกที่ "ต่างจากไฟล์" แล้ว **recreate `postgres`** (หาย `127.0.0.1:5432`)
พร้อมเตือนว่า `prometheus/grafana/node-exporter` เป็น orphan
**แก้:** ใส่ `-f` ชุดเดิมทุกคำสั่ง แล้ว `up -d` ซ้ำเพื่อคืน port
🔴 บน VM มีโอกาสเจอแบบเดียวกันถ้าใครรัน `docker compose` ใน `/opt/pos` โดยไม่ใส่
`-f docker-compose.yml -f vm.override.yml -f monitoring.yml` ให้ครบ

### 9.3 🟠 หน้าขายแสดง seed ของ Drift ปนกับสินค้าจากเซิร์ฟเวอร์
แคช Drift ในเบราว์เซอร์ถูก seed ด้วยสินค้าตัวอย่าง (Oil Filter, Spark Plug NGK …) ตอนเปิด
ครั้งแรก ส่วน `ApiProductsRepository.syncFromServer()` **เพิ่ม** ของจากเซิร์ฟเวอร์เข้าไป —
ไม่ได้ล้าง seed ทิ้ง → บนจอจึงเห็นทั้งสองชุด และสินค้าที่มีแต่ในแคชจะขายไม่ผ่าน
(เซิร์ฟเวอร์ไม่รู้จัก `productId`) · รอบนี้ขาย `DEMO-001` ที่มีอยู่จริงบนเซิร์ฟเวอร์
ไม่ใช่บั๊กที่ต้องแก้ในใบนี้ แต่ **เป็นเรื่องต้องรู้ก่อนเดโม** — อย่าจิ้มสินค้ามั่ว
บน VM เบราว์เซอร์ใหม่ก็จะมี seed ชุดนี้เหมือนกัน

### 9.4 🟠 panel *Disk usage (/)* = No data บน Docker Desktop
`node-exporter` mount `/:/rootfs:ro` ซึ่งใน Docker Desktop (VM ของ WSL) ไม่ใช่ดิสก์ของ
Windows → filesystem collector ไม่มี mount ที่ตรงกับ expr · **น่าจะขึ้นปกติบน `mob04`
(Linux จริง)** ไม่ใช่ปัญหาของโค้ด

### 9.5 🟠 target `api-readiness` = down
เป็นไปตาม D6 ที่สั่งให้ **ปล่อยไว้ตามเดิมพร้อมหมายเหตุ** (มันขูด `/health/ready` ซึ่งตอบ JSON
ไม่ใช่ text format ของ Prometheus) ไม่กระทบ panel ใด ๆ ที่ใช้ในเดโม

### 9.6 🔴 BuildKit ไม่ยอม build จาก checkout ที่อยู่บนโฟลเดอร์ BeeStation sync
`docker compose up -d --build` ล้มทันทีที่ขั้น load build context:

```
#8 [internal] load build context
#8 ERROR: invalid file request src/documents/doc-number.service.spec.ts
failed to solve: invalid file request src/documents/doc-number.service.spec.ts
```

สาเหตุ: หลัง `git pull` ไฟล์ใน `server/src/` กลายเป็น **cloud placeholder ของ BeeStation**
(`(Get-Item …).Attributes` → `Archive, ReparsePoint`) ซึ่ง BuildKit ปฏิเสธ · เกิดกับไฟล์
เกือบทั้ง `server/src/` ไม่ใช่ไฟล์เดียว · `docker builder prune --filter type=source.local`
และ `docker build` ตรง ๆ ก็ล้มเหมือนกัน
**แก้:** build จาก context สะอาดที่ได้จาก git objects (ไม่แตะ reparse point เลย)

```bash
git archive HEAD server | tar -x -C "$SCRATCH/ctx"
cd "$SCRATCH/ctx/server" && docker build -t srisurart-pos/server:local .
```

แล้ว `docker compose … up -d` (ไม่ต้อง `--build`) ก็หยิบ image ใหม่ไปใช้
🔴 **จะไม่เกิดบน `mob04`** — บน VM ไม่ได้ build เลย ดึง image จาก GHCR
🔴 **แต่จะเกิดกับใครก็ตามที่ build จาก checkout ในโฟลเดอร์ sync** → ใช้ trick นี้ หรือ
clone ไปที่ path ปกติ (คล้ายกฎ ASCII path ของ `build_runner` ใน CLAUDE.md
แต่เป็น **สาเหตุคนละตัว**: อันนี้คือ reparse point ไม่ใช่ตัวอักษรนอก ASCII)

### 9.7 🔴 เบราว์เซอร์อัตโนมัติผ่านหน้าเตือนใบรับรอง self-signed เองไม่ได้
`https://localhost/` เปิดเป็น Chrome SSL interstitial (`chrome-error://`) ซึ่ง **extension
ที่ขับเบราว์เซอร์เข้าไปคลิกไม่ได้** (`Frame with ID 0 is showing error page` /
`Cannot attach to this target`) และพอร์ต 80 ของ nginx `return 301 https://…`
**แก้ (dev เท่านั้น):** service `tlswrap` (`alpine/socat`) ใน overlay ของ scratchpad —
รับ HTTP ที่ `127.0.0.1:8081` แล้วต่อ **TLS** ไปที่ `nginx:443` ด้วย `verify=0`

```yaml
tlswrap:
  image: alpine/socat
  command: TCP-LISTEN:8081,fork,reuseaddr OPENSSL:nginx:443,verify=0
  ports: ["127.0.0.1:8081:8081"]
```

มันเป็น **L4 wrapper ไม่ใช่ reverse proxy ตัวที่สอง** — ไม่เติมและไม่แก้ header ใด ๆ
nginx จึงยังเป็น proxy ตัวเดียวหน้า API (`trust proxy = 1` / `X-Forwarded-For` ไม่ถูกกระทบ) ·
Chrome ถือ `http://localhost:8081` เป็น secure context อยู่แล้ว จึงใช้ localStorage ได้ปกติ
🔴 **บน `mob04` จะเจอหน้าเตือนเดียวกัน** (cert ยัง self-signed) — แต่มี **คนอยู่หน้าจอ** กด
*Advanced → Proceed* ครั้งเดียวก็จบ · **ให้กดล่วงหน้าก่อนขึ้นเวที** อย่ากดตอนนำเสนอ

### 9.8 🟠 ปุ่ม "ชำระเงิน" ตกใต้จอเมื่อกรอกเงินรับ (วิวพอร์ต 1568×749 CSS)
พอกรอก "รับเงิน" แถว *เงินทอน* โผล่ขึ้นมา ดันปุ่ม *ชำระเงิน* ต่ำกว่าขอบจอ และ panel ขวา
**ไม่ scroll** · กดปุ่มโดยยังไม่กรอกเงินรับจะได้ dialog `รับเงินไม่ครบ`
**แก้:** ตั้งค่า → อื่น → **ขนาดตัวอักษร `เล็ก 0.85x`** แล้วทุกอย่างพอดีจอ
🔴 **ถ้าจอที่ใช้เดโมเตี้ยกว่า ~800 px ต้องทำแบบเดียวกันก่อนขึ้นเวที**
(ขยายหน้าต่างไม่ช่วย — วิวพอร์ตไม่โตขึ้นเพราะขนาดจอ/DPI scaling)

### 9.9 🟠 ป้าย "ยังไม่ได้ผูกเครื่อง POS" ไม่อัปเดตทันทีหลังผูกเครื่องสำเร็จ
snackbar บอก *"ผูกเครื่องสำเร็จ!"* แล้ว แต่ป้ายบนการ์ด login ยังเขียนว่ายังไม่ผูก
(อัปเดตหลัง login) — **cosmetic** ไม่กระทบเส้นทาง แต่เวลาเดโมอย่าชี้ป้ายนั้นซ้ำหลังผูกเครื่อง

---

## 10. อะไรจะต่างบน `mob04` (ให้รอบ VM สั้นที่สุด)

| หัวข้อ | dev (รอบนี้) | `mob04` |
|---|---|---|
| **`CORS_ORIGINS`** | ปล่อยไม่ตั้ง = `'*'` | 🔴 **ต้องอยู่ใน `DEMO_ENV_FILE`** แล้วรัน `provision.yml` ใหม่ · #373 ต่อสายผ่าน `x-app-env` แล้ว (ข้อ 3 ของ "ของค้าง" ใน `ticket-343-vm-deploy.md §11` ที่เขียนว่า "ไม่ได้ต่อสายเลย" **ล้าสมัยแล้ว**) · 🔴 ค่าว่าง ๆ แบบ `,` = **boot ล้ม** |
| **`PLATFORM_ADMIN_IPS`** | ไม่ตั้ง (loopback only) | ไม่ตั้งเหมือนกันตาม D3 · ชั้น nginx `allow 127.0.0.1` ไม่เกี่ยวกับคีย์นี้ |
| **image** | build เอง `srisurart-pos/server:local` + bind-mount `frontend/build/web` | `ghcr.io/nuimanlp/srisurart-pos-{server,web}:<40-hex>` ผ่าน `-e image_tag=` · เว็บมาทาง volume `web` + `web-sync` |
| **ต้องรอ CI** | ไม่ | 🔴 **ใช่** — ต้องรอ CI ของ commit นั้น build+push image เสร็จก่อน (D8) · เช็คด้วย `deploy/scripts/verify-ghcr-tags.sh <sha>` |
| **GHCR pull** | ไม่เกี่ยว | 🔴 **ถูก FortiGate ของคณะบล็อก** (`handoff_demo-335-merge-and-cd-blocked_21_09_2026.md`) — ต้องต่อ VPN / ให้เปิดทางก่อนวันเดโม |
| **self-hosted runner (#67)** | ไม่เกี่ยว | 🔴 **ยังไม่ติดตั้ง** → deploy ด้วย `ansible-playbook` ด้วยมือตาม D9 · ต้องรันจากไดเรกทอรี `deploy/ansible/` ไม่งั้น `ansible.cfg` ไม่ถูกอ่าน |
| **`-e image_tag` / `force_redeploy`** | ไม่มี | 🔴 ต้องส่ง `image_tag=<40-hex>` เสมอ · ถ้า `.current_sha` ตรงกับ tag เดิมต้อง `-e force_redeploy=true` ไม่งั้น play จบกลางทางเงียบ ๆ |
| **`/opt/pos/.env`** | `server/.env` ในเครื่อง | เขียนโดย `provision.yml` จาก `DEMO_ENV_FILE` เท่านั้น — `deploy.yml` **ไม่** วางไฟล์นี้ |
| **build context / BeeStation** | 🔴 ต้องใช้ `git archive` (§9.6) | ไม่เกี่ยว — VM ไม่ build |
| **หน้าเตือน cert** | เลี่ยงด้วย `tlswrap` (§9.7) | 🔴 คนกด *Advanced → Proceed* เอง **ล่วงหน้า** |
| **เว็บเข้าทางไหน** | `http://127.0.0.1:8081` (wrapper) | `https://<vm>/` ผ่าน nginx ตรง ๆ |
| **Grafana** | `http://127.0.0.1:3000` ตรง (เครื่องเดียวกัน) | loopback ของ VM → ต้อง `ssh -L 3000:127.0.0.1:3000` |
| **datastore port** | publish บน loopback ผ่าน `docker-compose.dev.yml` | 🔴 **ห้ามใช้ overlay นั้นบน VM เด็ดขาด** — psql ให้ทำผ่าน `docker compose exec postgres` |
| **Disk usage panel** | No data (§9.4) | น่าจะมีข้อมูล (Linux จริง) |
| **`.current_sha` / `/health/ready`** | ไม่มี `.current_sha` | ต้องเช็คว่าเขียวและ sha ตรงกับ commit ที่ deploy (AC ของ #335) |
| **ซ้อม rollback** | ไม่ได้ทำ | ต้องทำหนึ่งรอบ (`-e image_tag=<sha เก่า> -e force_redeploy=true`) |
| **k6 / #184 #251** | ไม่ได้รัน | ยังค้าง — panel k6 จะ `no data` จนกว่าจะรัน |

**ของที่ยกไปใช้ซ้ำได้เลยบน VM:** คำสั่งทุกบรรทัดใน §2, §3, §6.1 เหมือนกันทั้งหมด
ต่างแค่ `cd /opt/pos` + `sudo docker compose` ตามหัวบล็อกของ `ticket-338-platform-provision.md §3`

---

## 11. สิ่งที่รอบนี้ **ไม่ได้** ทำ (อย่าเข้าใจผิด)

- ❌ **ไม่ได้ deploy หรือแตะ `mob04` เลย** — ไม่มี VPN ในเซสชันนี้ และใบที่แตะ VM เป็น HITL
- ❌ ไม่ได้ซ้อม rollback, ไม่ได้ตรวจ `.current_sha`, ไม่ได้รัน `provision.yml` / `deploy.yml`
- ❌ ไม่ได้ทดสอบ `bootstrap:admin --force` / การรันซ้ำ (AC ของ #337 มี e2e คุมอยู่แล้ว)
- ❌ ไม่ได้รัน k6 (#184/#251)
- ❌ **ไม่ติ๊ก AC ของ #335 / #343 / #344 แม้ข้อเดียว** — ทั้งหมดรอหลักฐานจาก VM ที่ #344
- ❌ ไม่ได้แก้โค้ดหรือคอนฟิกใน repo — overlay ของ dev ทั้งสองส่วนอยู่ใน scratchpad เท่านั้น

## 12. ของที่ค้างไว้ในเครื่อง dev (สำหรับคนถัดไป)

- tenant `srisurart-rehearsal` (`9e7c86d4-…`) + owner `owner_rehearsal` + เครื่อง `pos1`
  (ผูกแล้ว) + สินค้า `DEMO-001` + กะที่ **ยังเปิดอยู่** + บิล 2 ใบ — **ตั้งใจทิ้งไว้**
  เผื่อใครอยากทดสอบต่อ · tenant `srisurart-demo` ของ #338 ยังอยู่ ไม่ถูกแตะ
- ถ้าจะลบ ใช้ลำดับใน `ticket-338-platform-provision.md §5` (🔴 `devices` และ `audit_log`
  **ไม่มี FK** ไป `tenants` ต้องลบเอง)
- ตอนนี้ image `srisurart-pos/server:local` ถูก build จาก `5b16d05` แล้ว และสแตกรันจาก image นั้น
- รหัสผ่านทั้งหมดถูกสุ่มในเซสชันนี้ และอยู่ใน scratchpad ของ agent เท่านั้น **ไม่มีอะไรลง git**
