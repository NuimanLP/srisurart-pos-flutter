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

🔴 **อัปเดต 2026-09-27 (#443 PR2+PR3, บนกิ่งนี้):** `tenants:create` **ไม่ถามรหัส owner อีก
ต่อไป** (พรอมป์เดียวเหลือแค่รหัส platform admin) — server สุ่ม**รหัสผ่านชั่วคราว**ให้เองและคืนใน
`tempPassword`/`tempPasswordExpiresAt` ของผลลัพธ์ ครั้งเดียว (ดูรายละเอียดสัญญาใหม่ใน §3) ·
CLI มีคำสั่งเพิ่มอีกสี่ตัว: `tenants:show <id>` (PR2, ดูอุปกรณ์ของ tenant + import job ล่าสุด),
`devices:reissue-code <tenantId> <deviceId>` (PR2, ออกรหัสผูกเครื่องใหม่ให้เครื่องที่ยังไม่เคย
ผูก — แก้กับดัก "enrolCode หายแล้วไม่มีทางออก" ใน §3 ด้านล่าง), `owner:temp-password <tenantId>`
(PR3, ออกรหัสผ่านชั่วคราวใหม่ 24 ชม. เมื่อ owner ลืมรหัส/รหัสหมดอายุ) และ `owner:set-password
<username>` (PR3, สำหรับ tenant demo/loadtest ที่ทีมเป็นเจ้าของบัญชีเองเท่านั้น — ล็อกอินด้วย
รหัสชั่วคราวแล้วตั้งรหัสจริงในคำสั่งเดียว **ไม่ใช่**สำหรับ owner ร้านจริง)

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
รหัสผ่านทุกตัว (ของ platform admin เอง และรหัสชั่วคราว/รหัสใหม่ของ owner ใน `owner:set-password`) **อ่านจาก stdin/TTY เท่านั้น**
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
# ทางเลือก (#443, 2026-09-28): ใส่ PLATFORM_ADMINS=admin:<อย่างน้อย 12 ตัวอักษร> ใน server/.env
# (บน VM = DEMO_ENV_FILE แล้วรัน provision.yml ใหม่) แล้ว restart api — api ทุกตัว upsert ให้ตอน boot
# (ไม่มี → สร้าง · รหัสไม่ตรง → hash ใหม่ · ชื่อที่ลบออกจาก env ยังอยู่ใน DB) · display_name = username

# ── 1. ทดสอบว่า admin login ได้ (ไม่บังคับ แต่กันเสียเวลาถ้าตอบ 401) ───────
# แบบ interactive (พิมพ์รหัสเอง ไม่โชว์บนจอ):
$DC exec api-1 node dist/cli/platform.js login --user admin
# แบบ non-interactive (CI/สคริปต์ — ใช้ -T ปิด pseudo-TTY แล้ว pipe รหัสเข้า stdin):
read -rs ADMIN_PW   # พิมพ์รหัส admin (ไม่โชว์ ไม่ติด history)
printf '%s\n' "$ADMIN_PW" | $DC exec -T api-1 node dist/cli/platform.js login --user admin
# → logged in as admin (id …)

# ── 2. provision tenant (ไม่มีรหัส owner ให้ตั้งอีกแล้ว — #443 PR3) ─────────
# interactive: CLI ถามแค่รหัส admin ตัวเดียว
$DC exec api-1 node dist/cli/platform.js tenants:create \
  --user admin \
  --code srisurart-demo \
  --shop-name 'ศรีสุรัตน์ อะไหล่ยนต์ (เดโม)' \
  --shop-name-en 'Srisurart Autopart (demo)' \
  --plan demo \
  --owner-username owner_demo \
  --owner-display-name 'เจ้าของร้าน'
# Platform admin password: <พิมพ์รหัส admin>
# → JSON (พิมพ์แบบหลายบรรทัด) มี tenantId, code, shopName, ownerUsername, enrolCode
#   (เช่น "BE00CB85"), tempPassword (16 ตัว, สุ่มโดย server), tempPasswordExpiresAt (+7 วัน)
# stderr (ไม่ปนกับ JSON): "Note: tempPassword and enrolCode above are shown once …" — จดทันที เอาคืนไม่ได้

# non-interactive: รหัส admin ตัวเดียว (ไม่มี OWNER_PW แล้ว)
printf '%s\n' "$ADMIN_PW" | \
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
- `tenants:show <tenantId> --user <admin>` (#443 PR2) — tenant + รายการอุปกรณ์ (id, label,
  role, enrolled, enrolExpiresAt, retiredAt — ไม่มี hash/secret) + import job ล่าสุด 20 รายการ
- `devices:reissue-code <tenantId> <deviceId> --user <admin>` (#443 PR2) — ออกรหัสผูกเครื่องใหม่
  ให้เครื่องที่**ยังไม่เคย**ผูก (อายุ 7 วันเท่ากับตอน provision) — คำตอบมี `deviceId`,
  `enrolCode`, `enrolExpiresAt` และ stderr เตือนว่าโชว์ครั้งเดียวเหมือน `tenants:create`
- `owner:temp-password <tenantId> --user <admin>` (#443 PR3) — owner ลืมรหัส/รหัสหมดอายุ:
  ออกรหัสผ่านชั่วคราวใหม่ (24 ชม.) รหัสเก่า (ไม่ว่าจะเป็นรหัสชั่วคราวหรือรหัสที่ owner ตั้งเอง)
  ตายทันที ยืนยันตัวตนผู้ขอ**โดยโทร/อีเมลกลับ**ไปที่ข้อมูลที่บันทึกไว้ตอนเปิดร้านเท่านั้น
  ก่อนรันคำสั่งนี้
- `owner:set-password <username>` (#443 PR3) — ล็อกอินฝั่ง**หน้าร้าน** (ไม่ใช่ platform plane)
  ด้วยรหัสชั่วคราว แล้วตั้งรหัสจริงในคำสั่งเดียว (สองพรอมป์: รหัสชั่วคราว, รหัสใหม่) —
  **สำหรับ tenant demo/loadtest ที่ทีมเป็นเจ้าของบัญชีเองเท่านั้น** (มติเจ้าของ 2026-09-27)
  ห้ามใช้กับ owner ร้านจริงเด็ดขาด — owner ร้านจริงต้องตั้งรหัสเองผ่านแอป

Dev-only convenience: จาก `server/` เรียก `pnpm platform <command> …` แทน
`node dist/cli/platform.js <command> …` ได้ (ต้อง `pnpm build` ก่อน) — **ใช้ไม่ได้บน mob04**
เพราะ runtime image ลบ npm/corepack ออกหมดแล้ว (`server/Dockerfile`) ต้องเรียก
`node dist/cli/platform.js` ตรง ๆ ผ่าน `docker compose exec api-1` เท่านั้น

ฟิลด์ของ `tenants:create` (#443 PR3 — ไม่มี `--owner-password`/prompt รหัส owner อีกแล้ว):
`--code` (ต้องไม่ซ้ำ — ซ้ำได้ `409 Tenant code or username already exists`) ·
`--shop-name` · `--shop-name-en` (ไม่ใส่ = `''`) · `--plan` `basic|demo|loadtest` (ไม่ใส่ =
`basic`) · `--timezone` (ไม่ใส่ = `Asia/Bangkok`) · `--owner-username` ·
`--owner-display-name` (ไม่ใส่ = ใช้ `--owner-username`)
🔴 **ส่ง `--owner-password`/ฟิลด์ `ownerPassword` อะไรก็ตามจะโดนปฏิเสธทันที** ด้วย **`400
OWNER_PASSWORD_NOT_ACCEPTED`** ก่อนสร้างอะไรเลย (แม้ค่าจะว่าง) — server สุ่ม**รหัสผ่านชั่วคราว**
ให้เองเสมอ (16 ตัว, ตัด `0 O 1 l I` ที่สับสนออก) และคืนใน `tempPassword` **ครั้งเดียว** (อายุ
**7 วัน**, เก็บแค่ hash — เอาคืนไม่ได้เหมือน `enrolCode`) · ส่ง `ownerUsername` + `tempPassword`
+ `enrolCode` ให้ร้าน**ตัวต่อตัว** · owner ต้องตั้งรหัสเองตอน login ครั้งแรก (ADR-0001 addendum
2026-09-26, `POST /auth/change-password`) · ลืมรหัส/หมดอายุ → `owner:temp-password` ข้างบน ·
CLI ไม่ตรวจรหัสอะไรของ owner เองอีกต่อไป (ไม่มีรหัสให้ตรวจ) ส่วนรหัส **admin** เองยังต้องผ่าน
`MIN_PASSWORD_LENGTH` (12 ตัว) ตอน `bootstrap:admin` (#337) เหมือนเดิม

### 🔴 `enrolCode` คืนกลับมาครั้งเดียว

DB เก็บแต่ `sha256` (`devices.enrol_code_hash`) และหมดอายุใน **7 วัน**
(`platform-tenants.service.ts:96-104`) → **เอาคืนไม่ได้** · จดไว้ทันทีที่ได้

🔴 **กับดักนี้ตอนนี้แก้ทาง API ได้แล้ว (#443 PR2) — เดิมต้อง provision ใหม่เท่านั้น:** ถ้ารหัส
ของเครื่องแรกหาย/หมดอายุ **ก่อน** ที่จะเคยผูกเครื่องได้สำเร็จเลย ทางออกปกติ (`POST
/api/v1/devices`) ใช้ไม่ได้เพราะ route นั้นเรียก `requireEnrolledDevice(req)`
(`devices.controller.ts:57-67`) คือ **ต้องมีเครื่องที่ผูกแล้วอยู่ก่อน** — ตอนนี้ใช้
`devices:reissue-code <tenantId> pos1 --user admin` แทนได้ (ใช้ได้เฉพาะเครื่องที่**ยังไม่เคย**
ผูก, `token_hash IS NULL`) โดยไม่ต้อง provision tenant ใหม่หรือแก้ฐานข้อมูลด้วยมือ ·
**ผูกเครื่องแรกให้เสร็จทันทีหลัง provision** ยังเป็นแนวปฏิบัติที่ดีอยู่ดี อย่าทิ้งไว้ข้ามวัน

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

# 2) เจ้าของร้าน login บนเครื่องนั้นได้ — ด้วย tempPassword จากขั้น 2 ใน §3 (ไม่ใช่รหัสที่ตั้งเอง
#    เพราะยังไม่เคยตั้ง) 🔴 deviceToken ไป "ใน body" ไม่ใช่ header — ดูกับดักใต้บล็อกนี้
printf '%s' '{"username":"owner_demo","password":"<TEMP_PASSWORD จาก tenants:create>","deviceToken":"<DEVICE_TOKEN>"}' > /tmp/body.json
$DC cp /tmp/body.json nginx:/tmp/body.json
$DC exec -T nginx wget -qO- --no-check-certificate --header 'Content-Type: application/json' \
  --post-file /tmp/body.json https://127.0.0.1/api/v1/auth/token
# → {"status":"success","data":{"passwordChangeRequired":true,"passwordChangeToken":"eyJ…"}}
#    (#443 PR3: ยังไม่มี accessToken จนกว่า owner จะตั้งรหัสใหม่ — ดูข้อ 2b)

# 2b) ตั้งรหัสจริงด้วย passwordChangeToken ข้างบน (10 นาที, ใช้ได้ครั้งเดียว)
printf '%s' '{"newPassword":"<รหัสจริงของเจ้าของร้าน — อย่างน้อย 12 ตัว>"}' > /tmp/body.json
$DC cp /tmp/body.json nginx:/tmp/body.json
$DC exec -T nginx wget -qO- --no-check-certificate --header 'Content-Type: application/json' \
  --header "Authorization: Bearer <PASSWORD_CHANGE_TOKEN>" \
  --post-file /tmp/body.json https://127.0.0.1/api/v1/auth/change-password
# → {"status":"success","data":{"accessToken":"eyJhbGciOiJSUzI1NiIsImtpZCI6ImtleS0xIn0…"}}
#    payload: {"tid":"<tenant ใหม่>","role":"owner","did":"pos1","drole":"pos"}
#    (device-bound เพราะขั้น 2 ส่ง deviceToken มาด้วย — change-password เก็บ did/drole จาก token เดิม)
#
#    ทางลัดสำหรับ tenant demo/loadtest ที่ทีมเป็นเจ้าของเอง (ไม่ต้องผูกกับเครื่องใดเครื่องหนึ่ง):
#    `owner:set-password owner_demo` (§3) ทำข้อ 2-2b ให้ในคำสั่งเดียว — แต่ไม่ผ่าน deviceToken
#    เข้าไป จึง token ที่ได้จะไม่มี did/drole เหมือนเส้นข้างบน

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
login ที่วัดไว้ยังเป็นความจริงของวันนั้น (PR1 เปลี่ยนแค่**เครื่องมือที่ใช้ยิง**) — แต่ 🔴 #443 PR3
เปลี่ยน contract ของ `POST /platform/tenants` แล้ว (ไม่รับ `ownerPassword`, คืน `tempPassword`,
login แรกได้ `passwordChangeRequired` แทน `accessToken`) จึงรันซ้ำด้วยคำสั่งชุดเดิมไม่ได้ — ใช้ §3/§4 ปัจจุบัน

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
