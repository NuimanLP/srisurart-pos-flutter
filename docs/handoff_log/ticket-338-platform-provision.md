# Ticket #338 `platform.provision` — provision tenant โดยไม่แตะ psql

**ใบงาน:** #338 (parent #335, ตัดสินใจ D3) · **เลน A** (`team/1`) · **วันที่:** 2026-09-21
**ไม่มีการแก้โค้ดในใบนี้** — `POST /api/v1/platform/tenants` ทำครบตาม ADR-0001 อยู่แล้ว
(`server/src/platform/platform-tenants.service.ts:63-130`) งานของใบนี้คือ **พิสูจน์เส้นทาง
ที่ยิงได้จริง** แล้วเขียนขั้นตอนที่ใช้คำสั่งชุดเดียวกันทั้งบน dev และบน VM
🔴 ขั้นที่ 1 ใช้สคริปต์ของ #337 (PR #359) — ถ้า PR นั้นยังไม่ merge ให้ seed admin ด้วยมือชั่วคราว

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

---

## 2. กับดัก `wget` ที่จะทำให้เสียเวลาเป็นชั่วโมง

`wget` ในคอนเทนเนอร์ nginx เป็น **BusyBox**:

- รับ `--header STR` และ `--post-data STR` แบบ **เว้นวรรค** เท่านั้น · รูป `--header=...`
  เป็น usage error
- การยัด JSON ผ่าน shell หลายชั้น (PowerShell → docker → sh) มัก **ถูกกินเครื่องหมายคำพูด**
  จน body กลายเป็น `{username:admin,password:x}` แล้วได้ **400** โดยที่ทั้ง nginx และ api
  ตอบว่า "สำเร็จในการรับคำขอ" (ดูได้จาก `content-length` ใน log ที่สั้นกว่าที่ส่ง)
- 🔴 **ทางที่ไม่พลาด: ส่ง body เป็นไฟล์** ด้วย `--post-file` ทุกครั้ง
- ถ้ารันบน **Windows + Git Bash** (เครื่อง dev ของเลน A) ต้อง `MSYS_NO_PATHCONV=1` และใช้
  path แบบ Windows เป็นต้นทางของ `docker compose cp` ไม่งั้น `/tmp/body.json` จะถูกแปลเป็น
  `D:\tmp\body.json` · บน VM (Linux) เขียน `/tmp/body.json` ได้ตามปกติ ไม่ต้องทำอะไรเพิ่ม

---

## 3. ขั้นตอน (คำสั่งชุดเดียวกัน · dev กับ VM ต่างแค่ `cd` และ `sudo`)

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

# ── 1. login เอา token (ผ่าน nginx loopback) ─────────────────────────────
printf '%s' '{"username":"admin","password":"<รหัส>"}' > /tmp/body.json
$DC cp /tmp/body.json nginx:/tmp/body.json
$DC exec -T nginx wget -qO- --no-check-certificate \
  --header 'Content-Type: application/json' \
  --post-file /tmp/body.json \
  https://127.0.0.1/api/v1/platform/auth/token
# → {"status":"success","data":{"token":"eyJ…","admin":{…}}}   เก็บ token ไว้เป็น $TOKEN

# ── 2. provision tenant ──────────────────────────────────────────────────
printf '%s' '{"code":"srisurart-demo","shopName":"ศรีสุรัตน์ อะไหล่ยนต์ (เดโม)",
"shopNameEn":"Srisurart Autopart (demo)","plan":"demo","ownerUsername":"owner_demo",
"ownerPassword":"<รหัสเจ้าของร้าน>","ownerDisplayName":"เจ้าของร้าน"}' > /tmp/body.json
$DC cp /tmp/body.json nginx:/tmp/body.json
$DC exec -T nginx wget -qO- --no-check-certificate \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $TOKEN" \
  --post-file /tmp/body.json \
  https://127.0.0.1/api/v1/platform/tenants
# → {"status":"success","data":{"tenantId":"…","code":"srisurart-demo",
#    "shopName":"…","ownerUsername":"owner_demo","enrolCode":"BE00CB85"}}

# ── 3. ล้างร่องรอยรหัสผ่าน ───────────────────────────────────────────────
$DC exec -T nginx rm -f /tmp/body.json
rm -f /tmp/body.json
history -d $(history 1)     # หรือเว้นวรรคนำหน้าทุกคำสั่งที่มีรหัส
```

ฟิลด์ของ body: `code` (ต้องไม่ซ้ำ — ซ้ำได้ `409 Tenant code or username already exists`) ·
`shopName` · `shopNameEn` (ไม่ใส่ = `''`) · `plan` `basic|demo|loadtest` (ไม่ใส่ = `basic`) ·
`timezone` (ไม่ใส่ = `Asia/Bangkok`) · `ownerUsername` · `ownerPassword` ·
`ownerDisplayName` (ไม่ใส่ = ใช้ `ownerUsername`)
🔴 `ownerPassword` **ไม่มีเกณฑ์ความยาวฝั่ง server** (`platform-tenants.service.ts:52-54`
ตรวจแค่ว่ามีค่า) — คนที่รันต้องตั้งรหัสที่ดีเอง ต่างจาก `bootstrap:admin` ของ #337 ที่บังคับ 12 ตัว

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

# 3) เห็นในรายการของ platform
$DC exec -T nginx wget -qO- --no-check-certificate \
  --header "Authorization: Bearer $TOKEN" https://127.0.0.1/api/v1/platform/tenants
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
