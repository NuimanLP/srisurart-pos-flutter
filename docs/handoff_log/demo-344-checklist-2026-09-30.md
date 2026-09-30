# เช็กลิสต์ #344 `vm.demo` — เดินเส้นเดโมบน `mob04` (มือเจ้าของ)

ตรวจกับ `origin/main` @ `494ace3` (VM รัน SHA เดียวกัน) · 2026-09-30 · Thai-first, EN กำกับ
ที่มา: `gh issue view 344`, `docs/handoff_log/demo-rehearsal-dev-2026-09-21.md` (ซ้อมบน dev),
`ticket-338-platform-provision.md` §3 (CLI), `docs/tutorial/sri-pos-manual/` ภาค 01–03, `08_PHASE2_SPEC.md`

> กติกา: ไม่มีรหัสผ่านในไฟล์นี้ · ทุกที่ที่ "พิมพ์รหัส" = คนพิมพ์เองที่ TTY/หน้าจอ · รหัสชั่วคราว + enrolCode
> โผล่ **ครั้งเดียว** จดใส่ที่เก็บรหัสส่วนตัว ไม่ใส่ chat ไม่ใส่ repo
> ห้ามผ่อน AC: ถ้าขั้นไหนไม่ผ่าน จดผลจริงในตารางท้ายไฟล์ ห้ามเขียนว่าผ่าน

## AC ของ #344 (ย่อ)
| รหัส | AC |
|---|---|
| AC1 | provision tenant บน mob04 ด้วย runbook ใบที่ 3 (#338) |
| AC2 | เปิดเว็บ VM เห็นหน้า login และ login ด้วย owner ที่เพิ่ง provision ได้ |
| AC3 | เปิดกะ + ขาย 1 บิล → แถว `sales` ของ tenant +1 |
| AC4 | ส่งซ้ำ key เดิม → ไม่มีบิลที่สอง + replay counter ขยับบน Grafana |
| AC5 | panel success rate / p95 / error rate มีข้อมูลจริงหลังขาย |
| AC6 | AC ทั้ง 11 ข้อของ #335 ติ๊กพร้อมหลักฐาน + บันทึกลง `docs/handoff_log/` |

## 🔴 สิ่งที่โค้ด/deploy วันนี้ "ยังทำไม่ได้" หรือไม่ตรงตัวอักษรของ AC (อ่านก่อนเริ่ม)
1. **AC4 ทำผ่านหน้าแอปตรง ๆ ไม่ได้** — client สร้าง `Idempotency-Key` ครั้งเดียวต่อตะกร้า ไม่มีปุ่มส่งซ้ำ
   (ตาม `CLAUDE.md` "bill id และ Idempotency-Key minted once per cart"). ต้องส่งซ้ำด้วย DevTools "Replay XHR"
   หรือ `curl` (ขั้น 13) · access token อายุ **15 นาที** (`server/src/auth/auth.service.ts:298`) → ส่งซ้ำให้เร็ว
2. **AC2 มีขั้นเพิ่มจากตอนซ้อม 09-21**: `POST /platform/tenants` **ไม่รับ `ownerPassword` แล้ว** (โยน
   `OWNER_PASSWORD_NOT_ACCEPTED`, `server/src/platform/platform-tenants.service.ts:89-96`) — server สุ่ม
   `tempPassword` ให้ · login ครั้งแรกโดนบังคับตั้งรหัสใหม่ (ภายใน 10 นาที) · ข้อความหน้าเปลี่ยนรหัสเป็น
   `agent ร่าง` ยังไม่ผ่านการรับรอง (`frontend/lib/presentation/widgets/change_password_form.dart:13`)
3. **AC3 ต้องสร้างสินค้าก่อน** — tenant ใหม่มีแค่ 5 หมวด ไม่มีสินค้า (`platform-tenants.service.ts` `SEED_CATEGORIES`
   + ขั้น 3-4 ของ `createTenant`) · หน้าขายยังปนสินค้า seed ของ Drift ในเบราว์เซอร์ (ซ้อม 09-21 §9.3) ขายได้เฉพาะ
   สินค้าที่มีบน server → ขายแค่สินค้าที่เพิ่มเอง
4. **AC6 บางข้อของ #335 พิสูจน์บน VM ไม่ได้ตามตัวอักษร** (ดูตาราง B): (ก) "compose up จากคลีนโคลน" — VM ดึง image
   GHCR ไม่ได้ build · (ข) "`pnpm bootstrap:admin`" — บน mob04 admin (lomer/nuiman/pattarapon) ถูกสร้างจาก
   `PLATFORM_ADMINS` ตอน api boot ไม่ใช่สคริปต์ · (ค) "POST tenants จากใน container nginx" — CLI ยิง
   `127.0.0.1:3000` ของ api-1 ไม่ผ่าน nginx (`ticket-338` §1) → หลักฐานของ (ก)(ข) มาจาก dev/e2e เท่านั้น ให้เจ้าของ
   ตัดสินว่ายอมนับหรือไม่ — ห้ามอ้างว่าทำบน VM
5. ~~**อย่าทดสอบ CORS ด้วย Origin แปลก ๆ ระหว่างเดโม** — ได้ HTTP **500** (`server/src/app.setup.ts:67`)~~
   **ล้าสมัย 2026-09-30:** แก้แล้วโดย PR #516, deploy บน `mob04` เป็น `00d3488` (run `36717963989`) — Origin แปลกได้สถานะปกติของ route (เช่น `/health/live` 200 — ไม่ใช่ 500) ไม่มี ACAO ·
   (ข้อเดิมที่ว่า "นับเป็น 5xx ใน SLI" ก็ไม่จริง: 500 ตัวนั้นไม่เคยถูกนับใน `http_requests_total`)
6. **ห้ามกด "ยกเลิกการผูกเครื่อง" / ล้างข้อมูลเบราว์เซอร์** หลังผูก — tenant มี POS ได้ 1 เครื่อง ถ้า IndexedDB หาย
   เครื่องสุดท้ายหลุด = ทางตัน (#476 เปิดอยู่, ต้องให้ platform ออกรหัสใหม่) · ใช้โปรไฟล์เบราว์เซอร์แยกเฉพาะเดโม
7. **อย่าอนุมัติ `Deploy (demo)` ที่ค้างคิวระหว่างเดโม** — approve = recreate container กลางทาง (`CLAUDE.md` "Deploy queue")
8. ขั้น "403 สองชั้นของ platform-ui บน Linux" ยังไม่เคยวัดบน `mob04` (`session-2026-09-27-platform-admin-ui-443.md` §5)
   — เป็นงานของ #443 ไม่ใช่ AC ของ #344 แต่ถ้าใช้ platform-ui ในขั้น 4B ให้จดผลไว้ด้วย

---

## ตัวช่วยในเทอร์มินัล (รันบน notebook ที่ต่อ VPN ครั้งเดียวต่อหน้าต่าง)

```bash
export DEMO_CODE=demo-344-20260930        # รหัสร้านเดโม (unique; ห้ามซ้ำ — tenants.code UNIQUE)
export DEMO_OWNER=owner_demo344           # ชื่อผู้ใช้ owner
# อ่านฐานข้อมูลบน VM แบบ read-only (ผู้ช่วย/agent รันคำสั่งตระกูลนี้แทนได้ ไม่มีรหัสผ่าน):
psql_vm() { ssh mob04 "sudo -n docker exec -i srisurart-pos-postgres-1 psql -U postgres -d pos -Atc \"$1\""; }
TID="(SELECT id FROM tenants WHERE code='$DEMO_CODE')"
# ถาม Prometheus บน VM (loopback :9090):
prom_vm() { ssh mob04 "curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=$1'"; }
```
หมายเหตุ: `psql -U postgres` ในคอนเทนเนอร์ใช้ socket ภายใน (superuser → ข้าม RLS จึงเห็นทุก tenant, ระวังใส่ `WHERE tenant_id`)
ถ้ารันครั้งแรกแล้วขอรหัส = แจ้งเจ้าของ อย่าเดารหัส · ห้าม `SELECT password_hash` / `token_hash` ค่าจริงออกมา

---

## ภาค 0 — Pre-flight (ก่อนเริ่มจับเวลา)

**0.1 VPN + สุขภาพ VM** (AC ของ #335 ข้อ 10)
- ทำ: ต่อ VPN คณะ → `curl -sk -o /dev/null -w '%{http_code}\n' https://172.30.58.20/health/ready`
- คาดหวัง: `200`
- ✅ ตรวจ: `ssh mob04 'sudo -n cat /opt/pos/.current_sha'` = `494ace3…` (40 ตัว) และ
  `ssh mob04 'sudo -n docker ps --format "{{.Names}}|{{.Status}}"'` → api x3, postgres, redis-cache, redis-queue, etcd,
  prometheus, grafana เป็น `(healthy)`, มี nginx/worker/bull-board/platform-ui/node-exporter รันอยู่
  (`session-2026-09-30-first-runner-deploy.md` "หลักฐาน")

**0.2 หน้าเว็บที่เสิร์ฟคือ release เดียวกับ SHA**
- ทำ: `curl -sk https://172.30.58.20/flutter_bootstrap.js | grep -o 'main\.[0-9a-z]*\.dart\.js'`
- ✅ ตรวจ: ได้ `main.494ace37584e.dart.js` (12 ตัวแรกของ SHA) — ตามคู่มือ VM §4.3b

**0.3 CLI platform มีใน image**
- ทำ: `ssh mob04 'sudo -n docker exec srisurart-pos-api-1-1 ls dist/cli/platform.js'`
- ✅ ตรวจ: พิมพ์พาธกลับ ไม่ error

**0.4 เปิด tunnel + ดูว่าเห็นทุกพอร์ต**
- ทำ: หน้าต่างเทอร์มินัลใหม่ รัน `mob04-tunnel` ค้างไว้ (ฟอร์เวิร์ด 3000 Grafana · 3100 Bull-Board · 3200 platform-ui · 9090 Prometheus)
- ✅ ตรวจ: `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/api/health` = 200 ·
  `http://localhost:9090/-/healthy` = 200 · `http://localhost:3200/` = 200

**0.5 baseline ตัวเลข (จดไว้เทียบ)**
- `psql_vm "SELECT count(*) FROM tenants"` → จด `T0`
- `prom_vm 'sum(pos_idempotency_replay_total)'` → จด `R0` (ต้องเป็นค่าเลข ไม่ใช่ว่าง — ถ้า `result:[]` แปลว่า scrape ยังไม่มา
  รอ 30 วิ ค่อยดูใหม่)
- `prom_vm 'sum(http_requests_total)'` → จด `H0`
- `psql_vm "SELECT count(*) FROM tenants WHERE code='$DEMO_CODE'"` = `0` (ชื่อยังว่าง)

**0.6 เตรียมเบราว์เซอร์**
- โปรไฟล์ใหม่ (ไม่เคยเข้า `https://172.30.58.20`) · เปิดหน้าเว็บหนึ่งครั้ง กด *Advanced → Proceed* ล่วงหน้า
  (cert self-signed; ซ้อม §9.7) · เปิดแท็บ DevTools → Network ค้างไว้ก่อนขั้น 11
- จอเตี้ยกว่า ~800px: ตั้งค่า → อื่น → ขนาดตัวอักษร `เล็ก 0.85x` ก่อน ไม่งั้นปุ่ม "ชำระเงิน" ตกจอ (ซ้อม §9.8)
- ล็อกอิน Grafana: ผู้ใช้/รหัสจากไฟล์ secrets ของเจ้าของ (`GRAFANA_ADMIN_USER`/`_PASSWORD`) — พิมพ์เองที่หน้า login

---

## ภาค 1 — Provision (AC1)

**1. ตรวจสถานะ platform admin ล็อกอินได้** (ตัวเลือกกันเสียเวลา)
- ทำ: `ssh -t mob04 'sudo -n docker exec -it srisurart-pos-api-1-1 node dist/cli/platform.js login --user nuiman'`
  (เปลี่ยน `nuiman` เป็นแอดมินของคุณ) — CLI ถามรหัสที่ TTY พิมพ์เอง
- คาดหวัง: `logged in as <user> (id …)`
- ✅ ตรวจ: ไม่ขึ้น 401/429 · ⚠ bucket login ต่อ IP = 10 ครั้ง/60 วิ ร่วมกับ platform-ui (ผิดรัว ๆ = คนอื่นโดน 429 หนึ่งนาที)

**2. สร้าง tenant (AC1)** — ทางหลัก: CLI ตาม runbook `ticket-338` §3
- ทำ:
  ```bash
  ssh -t mob04 'sudo -n docker exec -it srisurart-pos-api-1-1 node dist/cli/platform.js tenants:create \
    --user nuiman --code demo-344-20260930 \
    --shop-name "ศรีสุรัตน์ อะไหล่ยนต์ (เดโม 344)" --shop-name-en "Srisurart Autopart (demo 344)" \
    --plan demo --owner-username owner_demo344 --owner-display-name "เจ้าของร้าน"'
  ```
  พิมพ์รหัสแอดมินที่ prompt (`Platform admin password:`) · **ห้ามใส่ `--owner-password`** (โดน 400)
- คาดหวัง: JSON มี `tenantId`, `code`, `ownerUsername`, `tempPassword`, `tempPasswordExpiresAt` (+7 วัน), `enrolCode` (8 hex) ·
  stderr เตือน "แสดงครั้งเดียว"
- **จดทันที** `tempPassword` + `enrolCode` (ใส่ที่เก็บรหัสส่วนตัว) · `enrolCode` หมดอายุ 7 วัน แต่ใช้ในขั้น 6 เลย
- ทางเลือก 4B (เทียบเท่า): เบราว์เซอร์ `http://localhost:3200` → login แอดมิน → ฟอร์ม "สร้างร้านใหม่ (Create tenant)" →
  หน้าต่างผลลัพธ์แสดงรหัสผ่านชั่วคราว + enrolCode พร้อมปุ่ม "คัดลอก (Copy)" (`server/docker/platform-ui/html/app.js:225-235`)
- ✅ ตรวจ (ผู้ช่วยรัน):
  - `psql_vm "SELECT code,plan,status FROM tenants WHERE code='$DEMO_CODE'"` → `demo-344-20260930|demo|active`
  - `psql_vm "SELECT username,role,is_active,must_change_password FROM users WHERE tenant_id=$TID"` → `owner_demo344|owner|t|t`
  - `psql_vm "SELECT id,role,device_no,token_hash IS NOT NULL AS enrolled,enrol_code_hash IS NOT NULL AS has_code FROM devices WHERE tenant_id=$TID"` → `pos1|pos|1|f|t`
  - `psql_vm "SELECT name FROM categories WHERE tenant_id=$TID ORDER BY position"` → 5 หมวด (เครื่องยนต์…ตัวถัง)
  - `psql_vm "SELECT action,platform_admin_id IS NOT NULL AS by_admin FROM audit_log WHERE tenant_id=$TID ORDER BY id"` → มี `platform.tenant.create|t`
  - `psql_vm "SELECT count(*) FROM tenants"` = `T0+1`

---

## ภาค 2 — เว็บ + login (AC2)

**3. เปิดเว็บ VM เห็นหน้า login**
- ทำ: โปรไฟล์เดโม → `https://172.30.58.20/`
- คาดหวัง: เด้งไป `#/login` ทันที · ป้ายเหนือฟอร์ม `โหมด Backoffice (ยังไม่ได้ผูกเครื่อง POS)` · ลิงก์ `ผูกเครื่องขาย (POS Terminal)`
- ✅ ตรวจ: เห็นหน้า login (ไม่ใช่หน้าขายเลย) = พิสูจน์ว่า image เป็นโหมด server (`USE_API_WRITES`, `frontend/lib/app.dart:18`,
  CI `flutter.yml:213-217`) · ถ้าเข้าหน้าขายเลย = build ผิดโหมด → หยุด แจ้ง #342

**4. ผูกเครื่อง (enrol)**
- ทำ: กด `ผูกเครื่องขาย (POS Terminal)` → กรอก `enrolCode` 8 ตัวจากขั้น 2 → `ยืนยันผูกเครื่อง`
- คาดหวัง: `ผูกเครื่องสำเร็จ! เครื่องนี้ได้รับการตั้งค่าเป็น POS Terminal แล้ว`
- ✅ ตรวจ: `psql_vm "SELECT id,token_hash IS NOT NULL AS enrolled,enrol_code_hash IS NULL AS code_burned FROM devices WHERE tenant_id=$TID"` → `pos1|t|t`
- ⚠ ข้อความ 8 ตัวอักษรของ dialog ยังเป็น `agent ร่าง` (`CLAUDE.md`; `device_enrolment_dialog.dart:97`) — จดคำที่เห็นจริง

**5. login ด้วยรหัสชั่วคราว → บังคับตั้งรหัสใหม่**
- ทำ: ชื่อผู้ใช้ `owner_demo344` + รหัสผ่านชั่วคราว (พิมพ์เอง) → `เข้าสู่ระบบ` → ขึ้นฟอร์ม "ตั้งรหัสผ่านใหม่"
  (`คุณเข้าสู่ระบบด้วยรหัสผ่านชั่วคราว กรุณาตั้งรหัสผ่านของคุณเองก่อนใช้งาน`) → กรอก `รหัสผ่านใหม่` + `ยืนยันรหัสผ่านใหม่`
  (≥ 12 ตัว, ห้ามซ้ำรหัสชั่วคราว) → `บันทึกรหัสผ่าน` **ภายใน 10 นาที** ไม่งั้น `หมดเวลาเปลี่ยนรหัสผ่าน` ต้อง login ใหม่
- คาดหวัง: เข้าหน้า `ขายสินค้า` · มุมขวาบนป้าย `ออนไลน์` · ป้ายสถานะเป็น `เครื่อง POS (มีสิทธิ์ขายและบันทึกเงินสด)`
- ✅ ตรวจ: `psql_vm "SELECT must_change_password,temp_password_expires_at IS NULL AS expiry_cleared,password_changed_at IS NOT NULL AS changed FROM users WHERE tenant_id=$TID"` → `f|t|t`
  · เก็บรหัสใหม่ในที่เก็บรหัสส่วนตัว (ขั้นถัดไปใช้อีก)

---

## ภาค 3 — สินค้า, เปิดกะ, ขาย (AC3)

**6. เพิ่มสินค้าทดสอบ 1 ตัว (ขั้นที่ AC ไม่ได้เขียน แต่ขาดไม่ได้)**
- ทำ: เมนู `สินค้า/สต็อก` → `เพิ่มสินค้า` (ฟอร์ม `เพิ่มสินค้าใหม่`) → รหัส `DEMO-344-001` · ชื่อไทย/อังกฤษอะไรก็ได้ · หมวด
  1 ใน 5 หมวด · ราคา `350` · ทุน `200` · สต็อก `50` → บันทึก
- ✅ ตรวจ: `psql_vm "SELECT part_no,price,cost,stock FROM products WHERE tenant_id=$TID AND deleted_at IS NULL"` → `DEMO-344-001|350.00|200.00|50`
  (ถ้าไม่มีแถว = เขียนลง Drift อย่างเดียว ไม่ถึง server → หยุดตรวจว่าป้ายเป็น `ออนไลน์` หรือไม่)

**7. เปิดกะ**
- ทำ: เมนู `ลิ้นชัก` → เงินตั้งต้น `฿1,000` → `เปิดร้าน`
- คาดหวัง: แท็บ `รายการเงิน` / `ปิดลิ้นชัก` ขึ้น · `เปิดร้าน {hh:mm} · ตั้งต้น ฿1,000`
- ✅ ตรวจ: `psql_vm "SELECT starting_cash,is_active,device_id FROM shifts WHERE tenant_id=$TID"` → `1000.00|t|pos1`
  · ไม่ขึ้น `กรุณาเปิดกะก่อนขาย` ตอนขายขั้น 9

**8. baseline ก่อนขาย**
- ✅ ตรวจ: `psql_vm "SELECT count(*) FROM sales WHERE tenant_id=$TID"` → `0` (จด `S0=0`) · `prom_vm 'sum(pos_idempotency_replay_total)'` ยัง = `R0`

**9. ขายบิลแรก (AC3)**
- ทำ: เมนู `ขายสินค้า` → ค้น/แตะสินค้า **`DEMO-344-001` เท่านั้น** (อย่าจิ้มของ seed) → วิธีชำระ `เงินสด` → รับเงิน `฿350` →
  `ชำระเงิน ฿350` → ใบเสร็จขึ้น (จดเลข เช่น `RC01-2569-09-000N`) → `ปิด`
- ✅ ตรวจ (ผู้ช่วยรัน):
  - `psql_vm "SELECT count(*) FROM sales WHERE tenant_id=$TID"` → `1` (= S0+1)
  - `psql_vm "SELECT receipt_no,total,payment_method,voided,device_id,sold_offline FROM sales WHERE tenant_id=$TID"` → เลขตรงใบเสร็จบนจอ · `350.00|เงินสด|f|pos1|f`
  - `psql_vm "SELECT stock FROM products WHERE tenant_id=$TID AND part_no='DEMO-344-001'"` → `49`
  - `psql_vm "SELECT type,delta,stock_after FROM movements WHERE tenant_id=$TID"` → `sale|-1|49` (ตาราง `movements` ไม่ใช่ `stock_movements`)
  - `psql_vm "SELECT key,endpoint,status,response_code FROM idempotency_keys WHERE tenant_id=$TID AND endpoint LIKE '%/sales'"` → 1 แถว `POST /api/v1/sales|done|201` — **จดค่า `key`** (ใช้ขั้น 11 เทียบ)

---

## ภาค 4 — ส่งซ้ำ key เดิม (AC4)

**10. ขายบิลที่สองไว้เป็นตัวทดสอบซ้ำ** (ซ้อม 09-21 ใช้บิลที่สอง เพราะต้องรู้คู่ key+body แน่นอน)
- ทำ: DevTools → Network → กรอง `sales` แล้วขายบิลที่ 2 (`DEMO-344-001` อีก 1 ชิ้น รับ ฿350) → เห็น `POST /api/v1/sales` 201 อีกหนึ่งรายการ
- ✅ ตรวจ: `sales`=2, `stock`=48, `movements`=2 แถว → จด `S1=2`, `STK1=48`

**11. ส่งซ้ำคำขอเดิม (ทำภายใน 15 นาทีนับจาก login — access token หมดอายุ)**
- ทำ (แนะนำ): DevTools → Network → คลิกขวาที่ `POST /api/v1/sales` ของบิลที่ 2 → **Replay XHR** (Chrome) — ส่ง body และ
  header เดิมทุกตัวรวม `Idempotency-Key` · ตรวจแท็บ Headers ว่า `Idempotency-Key` ตรงกับ `key` ใน DB
- ทางสำรอง: คลิกขวา → Copy → *Copy as cURL* → วางในเทอร์มินัลของคุณเอง **ห้ามวาง cURL ลง chat/เอกสาร (มี Bearer token)**
  ยิงจาก notebook ตรง ๆ ได้เพราะเฉพาะ `/api/v1/platform/` เท่านั้นที่ถูกจำกัด IP
- คาดหวัง: 201 พร้อม body เดิม (บิลเดิม เลขใบเสร็จเดิม `stock` = 48)
- ⚠ ถ้าได้ `409 IDEMPOTENCY_KEY_REUSED` = body ไม่ตรงบิตต่อบิต · ถ้าได้ `403` = token ไม่มี `did/drole` (ต้อง login หลังผูกเครื่อง)
- ✅ ตรวจ (ผู้ช่วยรัน):
  - `psql_vm "SELECT count(*) FROM sales WHERE tenant_id=$TID"` → **ยัง `2`** (ไม่มีบิลที่สาม)
  - `psql_vm "SELECT stock FROM products WHERE tenant_id=$TID AND part_no='DEMO-344-001'"` → **ยัง `48`**
  - `psql_vm "SELECT count(*) FROM movements WHERE tenant_id=$TID"` → **ยัง `2`**
  - `prom_vm 'sum(pos_idempotency_replay_total)'` → `R0 + 1` (รอ scrape ≤ 15 วิ) · ตัวนับเป็น per-process (กระจาย api-1/2/3) ต้องดู `sum()`
    ตามที่ panel ใช้ (`increase()`)

**12. เห็นบน Grafana** (ต่อ AC4 + เริ่ม AC5)
- ทำ: `http://localhost:3000` → login → dashboard *Srisurart POS — overview* (`uid srisurart-pos-overview`) → ช่วงเวลา Last 15 minutes → refresh
- ✅ ตรวจ: panel **Idempotent replays** ขยับ (≈ +1 ใน `increase()`) — ถ่ายภาพหน้าจอเก็บ

---

## ภาค 5 — Observability (AC5)

**13. ตรวจ 3 panel หลังขาย (ภายใน ~1 นาทีหลังขั้น 9–11)**
- ทำ: บน dashboard เดิม ดู 3 panel:
  - **API success rate** — มีค่า (ไม่ใช่ No data) ปกติ ~100% ถ้าไม่มี 5xx
  - **API p95 latency** — มีค่า (ซ้อม dev ≈ 169 ms; บน VM ไม่มีเกณฑ์ ให้จดค่าจริง)
  - **API error rate by status code** — ถ้ามี 4xx (เช่น 403/409 จากที่ลองผิด) จะเห็นเป็น series แยก; ไม่มี error เลยก็ยังต้องมีแกน/ข้อมูลของ panel
- ✅ ตรวจ (ผู้ช่วยรัน — ยืนยันว่าข้อมูลมาจริง ไม่ใช่กราฟว่าง):
  - `prom_vm 'sum(http_requests_total)'` > `H0` (มี series `route="/api/v1/sales"` : `prom_vm 'sum by (route,status) (http_requests_total{route=~".*sales.*"})'`)
  - `prom_vm 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))'` → ค่าเลข
  - `prom_vm 'up{job="api-metrics"}'` → 3 ตัว = 1
- หมายเหตุ: `/metrics`, `/health/*` ไม่นับใน SLI (`UNMEASURED_PATHS`) — เห็นแค่ทราฟฟิกจริงเป็นเรื่องปกติ ·
  panel `Disk usage (/)` ซ้อมบน Docker Desktop ขึ้น No data — บน Linux ควรมีข้อมูล จดว่ามี/ไม่มี · panel k6 = no data (ตามคาด, #380)
- 🔴 target `api-readiness` = down เป็นที่รู้อยู่แล้ว (scrape `/health/ready` ที่ตอบ JSON) ไม่กระทบเดโม

---

## ภาค 6 — ข้อที่เหลือของ #335 (AC6) — ทำบนทริปเดียวกัน

**14. `/metrics` จากในเครือข่าย compose = text format ไม่ห่อ envelope** (#335 ข้อ 7)
- ทำ: `ssh mob04 'sudo -n docker exec srisurart-pos-nginx-1 wget -qO- http://api-1:3000/metrics | head -3'`
- ✅ ตรวจ: บรรทัดขึ้นต้น `# HELP …` (ถ้า resolve `api-1` ไม่ได้ ลอง IP `172.30.0.11` ตามซ้อม §1)

**15. `/metrics` จากภายนอก = 404** (#335 ข้อ 8)
- ทำ: จาก notebook `curl -sk -o /dev/null -w '%{http_code}\n' https://172.30.58.20/metrics`
- ✅ ตรวจ: `404` (ไม่ใช่ `200 + index.html`)

**16. `/health/ready` + `.current_sha`** (#335 ข้อ 10) — ทำแล้วในขั้น 0.1 · ทำซ้ำหลังเดโมเพื่อยืนยันไม่มีอะไรเปลี่ยน
- ✅ ตรวจ: `.current_sha` ยังเท่าเดิม (ถ้าเปลี่ยน = มีคน approve deploy ระหว่างเดโม → บันทึกไว้)

**17. rollback หนึ่งรอบ** (#335 ข้อ 11) — **ไม่ต้องทำซ้ำ** ถ้ายอมใช้หลักฐานเดิม: 2026-09-30 rollback `494ace3 → e50f4fa`
ด้วย `ansible-playbook … -e image_tag=<sha> -e force_redeploy=true` ในนาม `deploy` (ไม่ใช่ runner) สำเร็จ, `failed=0`,
schema/migrations ไม่เปลี่ยน (คอมเมนต์ใน #343). ⚠ roll-forward ตอนนั้นขาดระหว่างทางเพราะ VPN หลุด แล้ว dispatch ผ่าน runner
run `36686729879` — เจ้าของตัดสินว่ายอมนับหรือไม่ · ถ้าไม่ยอม → เดินตามคู่มือ VM §6.2 (จะ recreate container: ทำ **หลัง** เดโมจบ)

**18. ข้อ 1–3 ของ #335 (compose clean clone, `bootstrap:admin`, POST tenants จากใน nginx)** — ดู 🔴 ข้อ 4 ด้านบน
- หลักฐานที่มี: `demo-rehearsal-dev-2026-09-21.md` §1–3 (dev) · `server/test/bootstrap-admin.e2e-spec.ts` (รันซ้ำ/`--force`)
- ✅ ตรวจ: เจ้าของเขียนคำตัดสินในตาราง B (ยอมนับ / ขอทำบน VM เพิ่ม / เปิดใบแยก)

---

## ภาค 7 — ปิดงาน + หลังเดโม

**19. สภาพข้อมูลที่ทิ้งไว้ (ไม่มีวิธีลบ tenant ผ่าน API — มีแค่เปลี่ยนสถานะ)**
- tenant `demo-344-20260930` (plan `demo`) + owner `owner_demo344` + เครื่อง `pos1` ผูกแล้ว + สินค้า `DEMO-344-001` (สต็อก 48) +
  บิล 2 ใบ + กะ 1 กะ (เปิดอยู่) + แถว `audit_log`/`idempotency_keys` (idempotency มี TTL ทำความสะอาดเอง)
- ข้อควรรู้: ห้ามลบด้วย `DELETE FROM tenants` ตรง ๆ (`devices`/`audit_log` ไม่มี FK — ลำดับใน `ticket-338` §5)
- ปิดกะให้เรียบร้อย (ไม่บังคับ): `ลิ้นชัก` → `ปิดลิ้นชัก` นับเงิน `฿2,000` — ปุ่มปิดจะถูก disable ถ้า outbox ไม่ว่าง; อย่าใช้ตอนต้องเดโมซ้ำ
- ถ้าจะเลิกใช้ร้านนี้: platform-ui (`http://localhost:3200`) → ร้าน → `ระงับชั่วคราว (suspend)` หรือ CLI
  `tenants:status <tenantId> suspended --user <admin>` (อย่า `closed` เว้นแต่แน่ใจ — ปิดถาวร)
- ✅ ตรวจ: `psql_vm "SELECT status FROM tenants WHERE code='$DEMO_CODE'"` = สถานะที่ตั้งใจ

**20. บันทึก + ติ๊ก AC** — เติมตารางด้านล่าง → ให้ผู้ช่วยเขียน `docs/handoff_log/session-2026-…-demo-344-mob04.md` (คำสั่งจริงที่ใช้ +
เอาต์พุตที่ sanitized, ไม่มีรหัส) → ติ๊กช่องใน #344 และ #335 เฉพาะข้อที่ "ผ่านจริง" พร้อมลิงก์หลักฐาน
(กฎของ `demo-335-STATUS.md`: ห้ามติ๊ก `[x]` ถ้ายังไม่ได้รันจริง; ปิดบางส่วนให้เขียนว่า "ปิดบางส่วน")

---

## ตาราง A — AC ของ #344 → หลักฐาน (เจ้าของกรอก)

| AC | ขั้น | ผ่าน? (Y/N/บางส่วน) | หลักฐาน (เอาต์พุต/ภาพ/ลิงก์) | หมายเหตุ |
|---|---|---|---|---|
| AC1 provision บน mob04 | 1–2 | | `tenants` +1, `users`, `devices`, `audit_log` (ขั้น 2) | |
| AC2 เห็นหน้า login + login owner ใหม่ | 3–5 | | ภาพหน้า login · `devices` enrolled · `must_change_password` t→f | ต้องผ่านขั้นเปลี่ยนรหัสด้วย |
| AC3 เปิดกะ + ขาย → `sales` +1 | 6–9 | | `count(*)` 0→1 · `receipt_no` ตรงใบเสร็จ · stock 50→49 | |
| AC4 ส่งซ้ำ key เดิม | 10–12 | | sales=2 ก่อน/หลัง · stock 48 · replay counter R0→R0+1 · ภาพ panel Idempotent replays | ส่งซ้ำผ่าน DevTools/curl ไม่ใช่ UI |
| AC5 panel มีข้อมูลจริง | 13 | | ภาพ 3 panel + `prom_vm` ผลลัพธ์ | |
| AC6 #335 ครบ 11 + handoff | 14–20 | | ดูตาราง B + ไฟล์ handoff | |

## ตาราง B — AC 11 ข้อของ #335 → หลักฐาน (เจ้าของกรอก)

| # | AC ของ #335 (ย่อ) | ทำบน VM ได้? | ขั้น / แหล่งหลักฐาน | ผ่าน? | หลักฐาน |
|---|---|---|---|---|---|
| 1 | `docker compose up -d --build` จากคลีนโคลน ขึ้นครบ | ไม่ (VM ใช้ image GHCR) | ซ้อม dev 09-21 §1 · เจ้าของตัดสินยอมนับ? | | |
| 2 | `bootstrap:admin` สร้าง admin, รันซ้ำ, `--force` | ไม่ (VM ใช้ `PLATFORM_ADMINS` env) | `bootstrap-admin.e2e-spec.ts` · แอดมิน 3 คนใน `platform_admins` บน VM | | |
| 3 | `POST /platform/tenants` จากใน container nginx คืน `enrolCode` | ไม่ตรงตัวอักษร (CLI → api-1 loopback) | ขั้น 2 (CLI/platform-ui) · เจ้าของตัดสินว่ายอมนับ | | |
| 4 | เปิด web VM เห็น login + login owner ใหม่ได้ | ได้ | ขั้น 3–5 | | |
| 5 | เปิดกะ + ขาย 1 บิล → `sales` +1 | ได้ | ขั้น 6–9 | | |
| 6 | ส่งซ้ำ key เดิม → ไม่มีบิลสอง + `pos_idempotency_replay_total` ขึ้น | ได้ (ผ่าน DevTools/curl) | ขั้น 10–12 | | |
| 7 | `curl http://api-1:3000/metrics` ในเครือข่าย compose = text format | ได้ | ขั้น 14 | | |
| 8 | `curl -k https://<vm>/metrics` = 404 | ได้ | ขั้น 15 | | |
| 9 | panel success rate + p95 มีข้อมูลภายใน 1 นาที | ได้ | ขั้น 13 | | |
| 10 | `/health/ready` เขียว + `.current_sha` ตรง commit | ได้ | ขั้น 0.1 + 16 | | |
| 11 | ซ้อม rollback หนึ่งรอบ | ทำแล้ว 2026-09-30 (#343) | ขั้น 17 · ลิงก์คอมเมนต์ #343 | | |

## ปัญหาที่น่าจะเจอ (ย่อ)
| อาการ | สาเหตุ / ทำอย่างไร |
|---|---|
| หน้าเว็บขึ้นแล้วทุก POST ล้ม | `CORS_ORIGINS` — `ssh mob04 'sudo -n grep -c "^CORS_ORIGINS=.*https://172\.30\.58\.20" /opt/pos/.env'` ต้อง `1` |
| ขายแล้ว 403 | token ไม่มี `did/drole` → ออกจากระบบแล้ว login ใหม่หลังผูกเครื่อง |
| `ขายไม่สำเร็จ` / สินค้าไม่พบ | ขายของ seed ของ Drift ที่ server ไม่รู้จัก → ขายเฉพาะ `DEMO-344-001` |
| ปุ่มชำระเงินตกจอ | ตั้งขนาดตัวอักษร `เล็ก 0.85x` |
| `429` ตอน login แอดมิน | bucket 10/60 วิ ต่อ IP — รอ 1 นาที |
| panel ว่างหลังขาย | รอ scrape 15 วิ · เช็ค `up{job="api-metrics"}` · ช่วงเวลา Last 15 minutes |
