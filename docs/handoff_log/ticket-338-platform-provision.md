# Ticket #338 `platform.provision` — provision tenant โดยไม่แตะ psql

**ใบงาน:** #338 (parent #335, ตัดสินใจ D3) · **เลน A** (`team/1`) · **วันที่:** 2026-09-21
**ไม่มีการแก้โค้ดในใบนี้** — `POST /api/v1/platform/tenants` ทำครบตาม ADR-0001 อยู่แล้ว
(`server/src/platform/platform-tenants.service.ts:63-130`) งานของใบนี้คือ **พิสูจน์เส้นทาง
ที่ยิงได้จริง** แล้วเขียนขั้นตอนที่ใช้คำสั่งชุดเดียวกันทั้งบน dev และบน VM
🔴 ขั้นที่ 1 ใช้สคริปต์ของ #337 (PR #359) — ถ้า PR นั้นยังไม่ merge ให้ seed admin ด้วยมือชั่วคราว

🔴 **อัปเดต 2026-09-27 (#443 PR1):** ขั้นตอน `curl`/`wget` ผ่าน nginx loopback ใน §2-§3 เดิม
ถูกแทนที่ด้วย **platform CLI** แล้ว (`server/src/cli/platform.ts` → build เป็น
`dist/cli/platform.js`) — ไม่มี JSON ที่ต้อง escape เอง ไม่มี `/tmp/body.json` ไม่มีการ copy
token ด้วยมือ (แต่ละคำสั่ง login เองทุกครั้งแล้วทิ้ง token ทันที) และรหัสผ่านอ่านจาก stdin/TTY
เท่านั้น (ไม่เคยอยู่ใน argv หรือ log) §1 ยังเป็นบันทึกประวัติที่ใช้ได้จริง (เหตุผลเรื่อง
loopback/guard เดียวกันยังผูกกับ CLI) ส่วน §2 (กับดัก `wget`) **ไม่เกี่ยวกับ §3 แล้ว** เพราะ CLI
ไม่ใช้ `wget`/`curl` เลย — ข้ามไปที่ §3 สำหรับขั้นตอนปัจจุบัน · 🔴 แต่ §4 ข้อ 1-2 (ยิง
`/auth/device` + `/auth/token` ของ**หน้าร้าน** ซึ่ง CLI ไม่ครอบคลุม) **ยังใช้ `wget` +
`/tmp/body.json` อยู่** กับดักใน §2 จึงยังใช้กับสองข้อนั้น

---

## 1. ทำไมต้องยิงจากในคอนเทนเนอร์ (และทำไม `ssh -L` ใช้ไม่ได้)

`docker/nginx/nginx.conf:87-95` :

```
location /api/v1/platform/ {
  allow 127.0.0.1;
  allow ::1;
  deny  all;
  …
}
```

บวกกับ `isAllowedIp` ใน `src/platform/platform-auth.guard.ts` ที่ดักซ้ำอีกชั้น (#270)
→ `/api/v1/platform/…` รับได้เฉพาะคำขอที่ **`$remote_addr` เป็น loopback จริง**

- ✅ **loopback ใน netns ของ nginx คือ loopback จริง** — `docker compose exec nginx wget
  https://127.0.0.1/…` จึงผ่านทั้ง nginx และ guard
- ❌ **`ssh -L` (หรือการยิงจากโฮสต์เข้า port ที่ publish ไว้) ใช้ไม่ได้ และห้ามกลับไปใช้**
  docker-proxy เปิด connection **ใหม่** เข้าไปในคอนเทนเนอร์ ทำให้ `$remote_addr` กลายเป็น
  gateway ของ bridge (`172.30.0.1`) และในไฟล์ **ไม่มี `set_real_ip_from` / `real_ip_header`
  อยู่เลย** → 403 ทั้งที่ nginx และที่ guard · ใครจะเปลี่ยนต้องแก้สองที่พร้อมกัน (D3)

**วัดจริงบน dev แล้ว** — ยิง `GET /api/v1/platform/tenants` ด้วย token ที่ถูกต้องจากโฮสต์
เข้า `https://127.0.0.1` (port 443 ที่ publish ไว้) ได้ **403** และ log ของ nginx บอกสาเหตุตรงตัว:

```
[error] access forbidden by rule, client: 172.30.0.1, server: , request: "GET /api/v1/platform/tenants HTTP/1.1"
{"remote_addr":"172.30.0.1","method":"GET","uri":"/api/v1/platform/tenants","status":403,"upstream":""}
```

`upstream` ว่างเปล่า = nginx ปฏิเสธเองก่อนถึง api · คำขอเดียวกันจากใน netns ของ nginx
เป็น `"remote_addr":"127.0.0.1" … "status":200`

**`nginx.conf` ไม่ถูกแก้ และ `PLATFORM_ADMIN_IPS` ไม่ถูกตั้ง** (ตั้งแล้วจะเป็นการเปิดทางให้
IP ภายนอก ซึ่ง D3 ไม่ต้องการ และ `PLATFORM_ADMIN_IPS` ก็ยังส่งเข้า container ไม่ได้อยู่ดี
— ดูช่องว่างที่รายงานไว้ใน `demo-335-STATUS.md` §2)

🔴 **CLI (#443 PR1) เดินคนละเส้นทางกับข้างบนนี้ทั้งหมด และง่ายกว่า:** มันรันจาก**ใน
container `api-1` เอง** ยิงตรงไปที่ `http://127.0.0.1:3000` (พอร์ตของ api เอง) — **ไม่ผ่าน
nginx เลยด้วยซ้ำ** ดังนั้น `location /api/v1/platform/` ของ nginx ที่พูดถึงข้างบนไม่เกี่ยวกับ
CLI แต่เหตุผลเดิมของ `isAllowedIp` (`platform-auth.guard.ts`) ยังใช้: คำขอจาก `127.0.0.1`
ภายใน container เดียวกันไม่มี `X-Forwarded-For` เลย จึง `clientIp()` อ่านได้ `req.ip` ตรง ๆ
เป็น loopback จริงเสมอ — เหตุผลที่ `ssh -L`/docker-proxy ใช้ไม่ได้ (ข้างบน) ก็ยังใช้ได้เหมือน
เดิม: ต้องรันคำสั่งจาก**ใน** container ไม่ใช่ยิงเข้า port ที่ publish ไว้จากโฮสต์

---

## 2. กับดัก `wget` ที่จะทำให้เสียเวลาเป็นชั่วโมง (ไม่เกี่ยวกับ §3 แล้ว — ยังใช้กับ §4 ข้อ 1-2)

🔴 **ไม่เกี่ยวกับการ provision (§3) ตั้งแต่ #443 PR1 (2026-09-27):** platform CLI ไม่ใช้
`wget`/`curl` เลย — มันคุยกับ api ด้วย `fetch` ของ Node เอง ไม่มี body ที่ต้องยัดเป็น string
ผ่าน shell หลายชั้น แต่ขั้นพิสูจน์ใน §4 ข้อ 1-2 (endpoint หน้าร้าน) ยังยิงด้วย `wget` อยู่
ข้อควรระวังด้านล่างจึงยังใช้กับสองข้อนั้น:

`wget` ในคอนเทนเนอร์ nginx เป็น **BusyBox**:

- รับ `--header STR` และ `--post-data STR` แบบ **เว้นวรรค** เท่านั้น · รูป `--header=...`
  เป็น usage error
- การยัด JSON ผ่าน shell หลายชั้น (PowerShell → docker → sh) มัก **ถูกกินเครื่องหมายคำพูด**
  จน body กลายเป็น `{username:admin,password:x}` แล้วได้ **400** โดยที่ทั้ง nginx และ api
  ตอบว่า "สำเร็จในการรับคำขอ" (ดูได้จาก `content-length` ใน log ที่สั้นกว่าที่ส่ง)
- ทางที่ไม่พลาดตอนนั้น: ส่ง body เป็นไฟล์ด้วย `--post-file` ทุกครั้ง — ต้องมี `/tmp/body.json`
  บนทั้งสองฝั่ง (host + container) และลบทิ้งเองหลังใช้ (ร่องรอยรหัสผ่านค้างในไฟล์ชั่วคราวได้)
- ถ้ารันบน **Windows + Git Bash** ต้อง `MSYS_NO_PATHCONV=1` ไม่งั้น path ถูกแปลงข้าม OS

---

## 3. ขั้นตอน (platform CLI · คำสั่งชุดเดียวกันทั้ง dev และ VM)

CLI: `server/src/cli/platform.ts` → build แล้วอยู่ที่ `dist/cli/platform.js`
(`pnpm build` ที่ `server/` ก็ได้มาแล้ว ไม่ต้องแก้ `nest-cli.json`/`tsconfig` เพิ่ม)
รหัสผ่านทุกตัว (ของ platform admin เอง และของ owner ร้านใหม่) **อ่านจาก stdin/TTY เท่านั้น**
— ไม่มี flag `--password` (CLI ปฏิเสธทันทีถ้าเจอ flag ที่ชื่อมี "pass") ไม่เคยอยู่ใน `ps`/log
และไม่มี token ให้ copy ข้ามคำสั่ง (แต่ละคำสั่ง login เองใหม่ทุกครั้งจาก `--user` + รหัสที่พิมพ์)

```bash
# ── ตัวแปรที่ต่างกันสองที่ (นอกจากนี้เหมือนกันทุกบรรทัด) ───────────────────
# dev :  cd <repo>/server            ;  DC="docker compose"
# VM  :  cd /opt/pos                 ;  DC="sudo docker compose"
DC="docker compose"

# ── 0. ต้องมี platform admin ก่อน (#337) ─────────────────────────────────
$DC run --rm \
  -e BOOTSTRAP_ADMIN_USERNAME='admin' \
  -e BOOTSTRAP_ADMIN_PASSWORD='<อย่างน้อย 12 ตัวอักษร>' \
  -e BOOTSTRAP_ADMIN_DISPLAY_NAME='ผู้ดูแลระบบ' \
  migrate node dist/db/bootstrap-admin.js

# ── 1. ทดสอบว่า admin login ได้ (ไม่บังคับ แต่กันเสียเวลาถ้าตอบ 401) ───────
# แบบ interactive (พิมพ์รหัสเอง ไม่โชว์บนจอ):
$DC exec api-1 node dist/cli/platform.js login --user admin
# แบบ non-interactive (CI/สคริปต์ — ใช้ -T ปิด pseudo-TTY แล้ว pipe รหัสเข้า stdin):
read -rs ADMIN_PW   # พิมพ์รหัส admin (ไม่โชว์ ไม่ติด history)
printf '%s\n' "$ADMIN_PW" | $DC exec -T api-1 node dist/cli/platform.js login --user admin
# → logged in as admin (id …)

# ── 2. provision tenant + owner ───────────────────────────────────────────
# interactive: CLI จะถามรหัส admin ก่อน แล้วถามรหัส owner ร้านใหม่ต่อ (คนละพรอมป์)
$DC exec api-1 node dist/cli/platform.js tenants:create \
  --user admin \
  --code srisurart-demo \
  --shop-name 'ศรีสุรัตน์ อะไหล่ยนต์ (เดโม)' \
  --shop-name-en 'Srisurart Autopart (demo)' \
  --plan demo \
  --owner-username owner_demo \
  --owner-display-name 'เจ้าของร้าน'
# Platform admin password: <พิมพ์รหัส admin>
# New owner password: <พิมพ์รหัสเจ้าของร้าน — อย่างน้อย 12 ตัวอักษร>
# → JSON (พิมพ์แบบหลายบรรทัด) มี tenantId, code, shopName, ownerUsername, enrolCode (เช่น "BE00CB85")

# non-interactive: สองรหัสเรียงบรรทัดตามลำดับที่ถูกถาม (admin ก่อน แล้วค่อย owner)
# อ่านรหัสเข้าตัวแปรด้วย `read -rs` ก่อน — อย่าพิมพ์รหัสตรง ๆ ในบรรทัด printf (จะติด history)
read -rs OWNER_PW   # ADMIN_PW อ่านไว้แล้วในข้อ 1
printf '%s\n%s\n' "$ADMIN_PW" "$OWNER_PW" | \
  $DC exec -T api-1 node dist/cli/platform.js tenants:create \
    --user admin --code srisurart-demo --shop-name 'ศรีสุรัตน์ อะไหล่ยนต์ (เดโม)' \
    --shop-name-en 'Srisurart Autopart (demo)' --plan demo \
    --owner-username owner_demo --owner-display-name 'เจ้าของร้าน'
```

ไม่มีขั้น "ล้างร่องรอยรหัสผ่าน" สำหรับ §3 อีกต่อไป — ไม่มีไฟล์ชั่วคราวให้ลบ (`--post-file` เดิม
หายไปพร้อม `wget`) · แบบ interactive รหัสไม่เข้า `history` ของ shell เลย · แบบ non-interactive
รหัสจะไม่เข้า `history` **ก็ต่อเมื่อ**ส่งผ่านตัวแปรจาก `read -rs` แบบข้างบน — ถ้าพิมพ์รหัสตรง ๆ
ใน `printf '…'` มันจะติด `.bash_history` (เว้นวรรคนำหน้าช่วยได้เฉพาะเมื่อ `HISTCONTROL` มี
`ignorespace`)

คำสั่งอื่นที่ CLI มีให้ (ดู `runPlatformCli` ใน `server/src/cli/platform.ts` สำหรับ flags ทั้งหมด):

- `tenants:list --user <admin>` — แสดงรายการ tenant ทั้งหมดเป็น JSON
- `tenants:status <tenantId> <active|suspended|closed> --user <admin>` — เปลี่ยนสถานะ tenant

Dev-only convenience: จาก `server/` เรียก `pnpm platform <command> …` แทน
`node dist/cli/platform.js <command> …` ได้ (ต้อง `pnpm build` ก่อน) — **ใช้ไม่ได้บน mob04**
เพราะ runtime image ลบ npm/corepack ออกหมดแล้ว (`server/Dockerfile`) ต้องเรียก
`node dist/cli/platform.js` ตรง ๆ ผ่าน `docker compose exec api-1` เท่านั้น

ฟิลด์ของ `tenants:create` (ตรงกับ body เดิมทุกตัว ไม่มีการเปลี่ยน contract ใน PR1):
`--code` (ต้องไม่ซ้ำ — ซ้ำได้ `409 Tenant code or username already exists`) ·
`--shop-name` · `--shop-name-en` (ไม่ใส่ = `''`) · `--plan` `basic|demo|loadtest` (ไม่ใส่ =
`basic`) · `--timezone` (ไม่ใส่ = `Asia/Bangkok`) · `--owner-username` · รหัส owner (พิมพ์ตอน
ถูกถาม) · `--owner-display-name` (ไม่ใส่ = ใช้ `--owner-username`)
🔴 รหัส owner **ต้องยาวอย่างน้อย 12 ตัวอักษร** (แก้แล้วที่ #364 — เดิมตรวจแค่ว่ามีค่า
จึงตั้ง `1234` ได้) เกณฑ์เดียวกับ `bootstrap:admin` ของ #337 เพราะมาจาก**ฟังก์ชันเดียวกัน**
(`server/src/common/password.ts` → `passwordPolicyViolation` / `MIN_PASSWORD_LENGTH`)
ถ้าไม่ผ่านจะได้ **`400 WEAK_PASSWORD`** (`02_API_SCREENS.md §8.1`) โดยที่ยัง**ไม่ได้**
สร้าง tenant / owner / settings / categories / device อะไรเลย — เพราะตรวจก่อน hash argon2
และก่อนเปิดธุรกรรม (`platform-tenants.service.ts` `createTenant()` ต้นฟังก์ชัน) CLI แสดง
error นี้ตรง ๆ ตามที่ api ตอบกลับมา (ไม่มี validation ซ้ำฝั่ง CLI — ปล่อยให้ server ตัดสินเส้น
เดียว) ส่วนข้อความไทยสำหรับหน้าร้านอยู่ใน `server_error_resolver.dart`
🔴 **`ownerPassword` ยังอยู่ใน contract เดิมใน PR1** — การเปลี่ยนไปใช้รหัสผ่านชั่วคราวที่ระบบ
สุ่มให้ (ตัด `ownerPassword` ออกจาก request) เป็นของ #443 PR3 เท่านั้น

### 🔴 `enrolCode` คืนกลับมาครั้งเดียว

DB เก็บแต่ `sha256` (`devices.enrol_code_hash`) และหมดอายุใน **7 วัน**
(`platform-tenants.service.ts:96-104`) → **เอาคืนไม่ได้** · จดไว้ทันทีที่ได้

🔴 **และนี่คือกับดักที่ต้องรู้ก่อนวันเดโม:** ทางออกปกติคือออกเครื่องใหม่ผ่าน
`POST /api/v1/devices` — แต่ route นั้นเรียก `requireEnrolledDevice(req)`
(`devices.controller.ts:57-67`) คือ **ต้องมีเครื่องที่ผูกแล้วอยู่ก่อน** ดังนั้นถ้ารหัสของ
เครื่องแรกหาย/หมดอายุ **ก่อน** ที่จะเคยผูกเครื่องได้สำเร็จเลย จะไม่มีทางออกทาง API เลย
→ ต้อง provision tenant ใหม่ (code ใหม่) หรือแก้ `devices.enrol_code_hash`/`enrol_expires_at`
ในฐานข้อมูลด้วยมือ · **ผูกเครื่องแรกให้เสร็จทันทีหลัง provision** อย่าทิ้งไว้ข้ามวัน

---

## 4. ตรวจว่า tenant ที่ได้ครบตาม ADR-0001

API ตอบกลับเฉพาะคอลัมน์ของ `tenants` — ของที่ ADR-0001 ข้อ 4/5 บังคับ (5 หมวด + เครื่อง
`pos1`) ไม่โผล่ในคำตอบ จึงต้องดูในฐานข้อมูลหนึ่งครั้ง (ใช้คอนเทนเนอร์ ไม่ต้อง publish port):

```bash
$DC exec -T postgres psql -U postgres -d pos -t -c "
  SELECT 'tenant     : '||code||' / '||plan||' / '||status FROM tenants WHERE id='<TID>'
  UNION ALL SELECT 'owner      : '||username||' / role='||role||' / active='||is_active FROM users WHERE tenant_id='<TID>'
  UNION ALL SELECT 'settings   : tax='||tax_rate||' quoteValidDays='||quote_valid_days FROM settings WHERE tenant_id='<TID>'
  UNION ALL SELECT 'categories : '||count(*)||' -> '||string_agg(name,', ' ORDER BY position) FROM categories WHERE tenant_id='<TID>'
  UNION ALL SELECT 'device     : '||id||' no='||device_no||' role='||role||' expires='||enrol_expires_at::date FROM devices WHERE tenant_id='<TID>'
  UNION ALL SELECT 'audit      : '||action FROM audit_log WHERE tenant_id='<TID>'"
```

ผลที่ได้จริงบน dev (2026-09-21, tenant `srisurart-demo`):

```
 tenant     : srisurart-demo / demo / active
 owner      : owner_demo / role=owner / active=true
 settings   : tax=7.00 quoteValidDays=30
 categories : 5 -> เครื่องยนต์, ไฟฟ้า, น้ำมัน, เบรก, ตัวถัง
 device     : pos1 no=1 role=pos enrol_hash=0274c48fec51… expires=2026-09-28
 audit      : platform.tenant.create
```

ครบทั้งหกอย่างในธุรกรรมเดียว (`platform-tenants.service.ts:64` `adminDs.transaction`) —
ถ้าข้อใดล้ม ไม่มีอะไรถูกเขียนเลย (`platform.e2e-spec.ts` มีเคส rollback คุมไว้)

### แล้วพิสูจน์ว่า "ใช้งานได้จริง" ไม่ใช่แค่มีแถว

```bash
# 1) enrolCode ผูกเครื่องได้จริง
printf '%s' '{"code":"<ENROL_CODE>"}' > /tmp/body.json  &&  $DC cp /tmp/body.json nginx:/tmp/body.json
$DC exec -T nginx wget -qO- --no-check-certificate --header 'Content-Type: application/json' \
  --post-file /tmp/body.json https://127.0.0.1/api/v1/auth/device
# → {"status":"success","data":{"deviceToken":"131a5f4f-…-f620e58a-…"}}

# 2) เจ้าของร้าน login บนเครื่องนั้นได้
#    🔴 deviceToken ไป "ใน body" ไม่ใช่ header — ดูกับดักใต้บล็อกนี้
printf '%s' '{"username":"owner_demo","password":"<รหัสเจ้าของร้าน>","deviceToken":"<DEVICE_TOKEN>"}' > /tmp/body.json
$DC cp /tmp/body.json nginx:/tmp/body.json
$DC exec -T nginx wget -qO- --no-check-certificate --header 'Content-Type: application/json' \
  --post-file /tmp/body.json https://127.0.0.1/api/v1/auth/token
# → {"status":"success","data":{"accessToken":"eyJhbGciOiJSUzI1NiIsImtpZCI6ImtleS0xIn0…"}}
#    payload: {"tid":"<tenant ใหม่>","role":"owner","did":"pos1","drole":"pos"}

# 3) เห็นในรายการของ platform — ตอนนี้ใช้ CLI แทน (ไม่ต้องถือ $TOKEN ไว้เองอีกแล้ว, #443 PR1)
printf '%s\n' "$ADMIN_PW" | $DC exec -T api-1 node dist/cli/platform.js tenants:list --user admin   # ADMIN_PW จาก read -rs ใน §3
```

### 🔴 กับดักที่ `/code-review` จับได้ และวัดซ้ำแล้ว: `deviceToken` อยู่ใน body ไม่ใช่ header

รอบแรกเขียนไว้ว่าส่ง `X-Device-Token` — **ผิด** และที่แย่กว่าคือ **ผิดแบบเงียบ**
`AuthController.login` (`auth.controller.ts:15-22`) รับแค่ `@Body() dto: LoginDto` และ
`LoginDto.deviceToken` (`auth.service.ts:16-19`) ถูกอ่านจาก body (`auth.service.ts:71-72`)
· header `X-Device-Token` เป็นของ `DeviceTokenGuard` ซึ่งผูกกับ `/sync/push` เท่านั้น
(`common/tenant-door.spec.ts:135-136`)

ถ้าส่งเป็น header จะยัง **ได้ 200 และได้ accessToken** (เพราะชื่อผู้ใช้ไม่ซ้ำข้ามร้าน
ADR-0004 จึงหาเจอได้) แต่ token นั้น **ไม่มี `did`/`drole`** — วัดด้วย tenant ทิ้งหนึ่งตัว:

```
ส่งเป็น header (ผิด):  {"tid":"db88370f-…","role":"owner"}
ส่งใน body  (ถูก):     {"tid":"db88370f-…","role":"owner","did":"pos1","drole":"pos"}
```

→ ใครก๊อป command แบบผิดไปใช้จะได้ token ที่ไม่มีตัวตนของเครื่อง แล้วไปตายที่ route
ที่ต้องมี device (เช่นเส้นขาย/`requireEnrolledDevice`) โดยที่ขั้น login ดู "ผ่าน" แล้ว

ทั้งสามข้อรันจริงบน dev แล้วและผ่าน (ข้อ 2 รันซ้ำด้วยรูปที่ถูกแล้ว) — **เส้น provision → enrol → owner login เดินได้จริง**
(ไม่ทำส่วน "sell" ต่อ เพราะเป็นของ #293 เลน C ตามสเปกแม่: *"ไม่ทำซ้ำ"*)

---

## 5. ของที่ค้างอยู่บน dev (สำหรับเลนอื่น)

- tenant `srisurart-demo` + owner `owner_demo` + เครื่อง `pos1` **ยังอยู่ใน dev DB โดยตั้งใจ**
  เผื่อเลน B/C อยากทดสอบหน้าเว็บโหมด server กับร้านจริง ๆ หนึ่งร้าน
  (`enrolCode` ตัวแรกถูกใช้ผูกเครื่องไปแล้ว ถ้าต้องผูกเครื่องใหม่ให้ออกรหัสใหม่ผ่าน `POST /devices`)
- ตรวจแล้วว่า **ไม่ทำให้ e2e ของใครพัง**: grep ทั้ง `server/test/*.e2e-spec.ts` แล้ว
  ไม่มี suite ไหน `SELECT count(*) FROM tenants` หรือ assert จำนวนแถว — แต่ละ suite ถือ
  UUID ของตัวเองแบบค่าคงที่ (เช่น `sales.e2e-spec.ts:18`) และลบ tenant ของตัวเองด้วย
  `DELETE FROM tenants WHERE id = …`
- ถ้าจะลบทิ้ง ให้ลบตามลำดับนี้ · 🔴 **ไม่ใช่ทุกตารางที่มี FK ไป `tenants`**: `users`
  (`InitialSchema:52`), `categories` (`:144`) และ `settings` (`:512`) มี
  `REFERENCES tenants(id) ON DELETE CASCADE` แต่ **`devices` กับ `audit_log` ไม่มี FK ไป
  `tenants` เลย** (`:65`, `:113`) → ต้องลบสองตารางนี้ **เอง** ไม่งั้นจะเหลือแถวกำพร้าแบบเงียบ
  (ไม่มี constraint ไหนร้อง) ลำดับข้างล่างปลอดภัยทั้งสองกรณี:

```bash
$DC exec -T postgres psql -U postgres -d pos -c "
  DELETE FROM audit_log WHERE tenant_id='<TID>';
  DELETE FROM categories WHERE tenant_id='<TID>';
  DELETE FROM settings   WHERE tenant_id='<TID>';
  DELETE FROM devices    WHERE tenant_id='<TID>';
  DELETE FROM users      WHERE tenant_id='<TID>';
  DELETE FROM tenants    WHERE id='<TID>';"
```

---

## 6. AC ของ #338 — ปิดจริงข้อไหน

🔴 ตารางนี้เป็นหลักฐานของการรันจริงวันที่ 2026-09-21 ด้วยคำสั่ง `curl`/`wget` ชุดเดิม (ก่อน
CLI ของ #443 PR1) — คอลัมน์ "หลักฐาน" ที่อ้าง "§3" หมายถึงคำสั่งชุดนั้น ไม่ใช่คำสั่ง CLI ที่
เขียนแทนใน §3 ตอนนี้ ผลลัพธ์ (`enrolCode=BE00CB85` ฯลฯ) และเส้น provision → enrol → owner
login ที่วัดไว้ยังเป็นความจริงเหมือนเดิม เพราะ contract ของ `POST /platform/tenants` ไม่ได้
เปลี่ยน (PR1 ไม่แตะ API เลย) — เปลี่ยนแค่**เครื่องมือที่ใช้ยิง**

| AC | สถานะ | หลักฐาน |
|---|---|---|
| สร้าง tenant จากในเครือข่ายของ container ได้ `enrolCode` | ✅ | §3 + §4 — `enrolCode=BE00CB85`, `tenantId=5d991161-…` บน dev |
| `nginx.conf` ไม่ถูกแก้ · `PLATFORM_ADMIN_IPS` ไม่ถูกตั้ง | ✅ | diff ของใบนี้ไม่มีไฟล์โค้ด/คอนฟิกเลย (เอกสารเท่านั้น) |
| runbook เดินตามได้ทั้ง dev และ VM ด้วยคำสั่งชุดเดียวกัน | 🟡 **ปิดครึ่ง** | ชุดคำสั่งใน §3 เดินจบจริงบน **dev** ทุกบรรทัด · ฝั่ง **VM ยังไม่ได้รัน** (รอ VPN ของเจ้าของ ตาม D9) — ต่างกันแค่ `cd /opt/pos` + `sudo` ตามที่ระบุไว้หัวบล็อก |
| runbook บันทึกว่าทำไม tunnel ใช้ไม่ได้ | ✅ | §1 พร้อม log จริงที่วัดได้ (`client: 172.30.0.1`, 403, `upstream` ว่าง) |
| tenant มี owner + settings + 5 หมวด + เครื่อง `pos1` | ✅ | §4 ผลจาก psql ครบหกบรรทัด + enrol/login เดินต่อได้ |

**ไม่เขียนเทสต์ใหม่** — `createTenant` ถูกคุมอยู่แล้วใน `server/test/platform.e2e-spec.ts`
(atomic audit + rollback ทั้งก้อน) และสเปกแม่ระบุว่าเส้น provision → login → sell เป็นของ
#293 เลน C: *"ไม่ทำซ้ำ"*
