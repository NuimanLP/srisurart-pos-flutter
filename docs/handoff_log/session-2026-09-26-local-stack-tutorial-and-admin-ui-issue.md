# Handoff — รันสแตก local ครบชุด + tutorial + ร่าง issue #443 `platform.admin-ui` (2026-09-26)

**วันที่:** 2026-09-26 · **ผู้บันทึก:** agent (Claude) กับ owner · **สถานะ:** ปิดรอบ — งานต่อคือ #443 (ยังไม่ `ready-for-agent`)
**ขอบเขต:** รัน frontend + backend + Prometheus + Grafana บนเครื่อง dev, เขียน tutorial, อธิบายโมเดลบัญชี/เครื่อง, ร่างและเคาะ issue หน้าจัดการ platform
**ต่อจาก:** [`demo-rehearsal-dev-2026-09-21.md`](demo-rehearsal-dev-2026-09-21.md) (ที่มาของ `tlswrap`) · [`ticket-338-platform-provision.md`](ticket-338-platform-provision.md)

## 1. ตอนนี้อยู่ตรงไหน

- **เอกสาร:** [`docs/tutorial/local-full-stack-tutorial.md`](../tutorial/local-full-stack-tutorial.md) — วิธีรันทั้งสแตก, สร้างผู้ใช้แรก, ความหมายคิวใน Bull-Board, troubleshoot · merge ผ่าน PR #442 และ PR ต่อท้ายที่แก้คำอธิบาย 403
- **Issue ใหม่:** [#443 `platform.admin-ui`](https://github.com/NuimanLP/srisurart-pos-flutter/issues/443) (`team/1`, `enhancement`, `wayfinder:grilling`) — ข้อตัดสินทั้งหมดอยู่ในคอมเมนต์ 1–5 ของใบนั้น **อ่านที่นั่น ไม่ลอกมาที่นี่**
- **เครื่อง dev ของ owner (ไม่อยู่ใน git):**
  - สแตก compose (`docker-compose.yml` + `docker-compose.dev.yml` + `deploy/compose/monitoring.yml`) รันอยู่ healthy ทั้งหมด + container `srisurart-pos-tlswrap-1` (จาก overlay นอก repo ของรอบซ้อมเดโม)
  - Flutter `web-server` ที่ `127.0.0.1:8090` ชี้ `API_BASE_URL=http://127.0.0.1:8081` — เป็น process เบื้องหลังของ session นี้ อาจตายไปพร้อม session
  - ฐานข้อมูล dev มี platform admin `devadmin` และร้าน `demo-shop` (owner `owner`) — **รหัสไม่ได้จดไว้ที่นี่** ต้องการใช้ให้รีเซ็ตด้วย `bootstrap-admin.js --force` หรือสร้างร้านใหม่ตาม tutorial ข้อ 5

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

1. `git pull` บน branch ที่ถูก merge และลบจาก remote ไปแล้ว → ย้ายไป `main` แล้ว fast-forward 126 commit
2. เปิด Docker Desktop — สแตกเดิมจาก 2026-09-21 กลับมาเองเพราะ `restart: unless-stopped` · `health/ready` = postgres/redisCache/redisQueue `up` · Prometheus healthy · Grafana `database: ok`
3. Flutter web ต่อ backend จริงได้ **เฉพาะผ่าน `tlswrap` (`http://127.0.0.1:8081`)** — ยืนยันจาก network log `GET http://127.0.0.1:8081/health/ready → 200`
4. `bootstrap:admin` → `created` · login platform จากใน netns ของ nginx ได้ token · `POST /platform/tenants` ได้ `tenantId` + `enrolCode` · `POST /api/v1/auth/token` ของ owner ได้ access/refresh (access อายุ 900 วินาที)
5. ร่างและโพสต์ #443 แล้วเคาะกับ owner ต่ออีก 4 รอบในคอมเมนต์

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

ข้อตัดสินของ #443 ทั้งหมดอยู่ในใบ — สรุปบรรทัดเดียวเพื่อค้นเจอ: **CLI + หน้าเว็บ** · **`team/1`** · **ไม่ใช้ Google** (ทั้ง Sign-in และ Authenticator) ·
**รหัสชั่วคราวที่ server สุ่มต่อร้าน + บังคับเปลี่ยนตอน login แรก + หมดอายุ 7 วัน/24 ชม.** · **ไม่บังคับเปลี่ยนตามรอบ** · **ตัด `ownerPassword` ทุก plan** ·
**ลืมรหัส = ทีมติดต่อกลับเบอร์/อีเมลที่บันทึกไว้** · **ADR-0009 ไม่ขัด แต่ต้อง addendum** (owner อนุญาตให้แก้ ADR) · **PIN ออฟไลน์อยู่นอกขอบเขต** — ตัดสินโดย owner ทั้งหมด

เหตุผลที่ไม่ได้อยู่ในใบ:
- **ไม่ทำ "admin panel สร้าง platform admin"** — ไม่ได้ลืมทำ: ADR-0001 ตั้งใจให้คนแรกสร้างนอกระบบ เพราะไม่มีใครยืนยันตัวตนให้คนแรกได้ และ endpoint สร้าง admin = ทางยกสิทธิ์เป็น superuser ข้ามทุกร้าน
- **"1 ร้าน = 1 login"** เป็นเจตนา (`users.role CHECK (role='owner')` + `uq_users_one_active`) — พนักงานใช้เครื่องที่ผูก + PIN ไม่ใช่บัญชีแยก ถ้าถูกถามว่า "สร้าง user พนักงานยังไง" คำตอบคือ "ไม่มี"
- **สร้างเครื่องใหม่ (`POST /devices`) ต้องมาจาก session ที่มี `did`** (`requireEnrolledDevice`) — role เครื่อง `pos` หรือ `backoffice` ก็ได้ · login ด้วยรหัสอย่างเดียว = 403

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- **`API_BASE_URL=https://localhost`** → เบราว์เซอร์ `ERR_CERT_AUTHORITY_INVALID` แอปค้างที่ spinner/ขึ้นว่าออฟไลน์ · ใช้ `http://127.0.0.1:8081` (tlswrap)
- **เปลี่ยน `--dart-define` แล้วแท็บที่เปิดค้างยังใช้ค่าเก่า** — ต้อง `Ctrl+Shift+R` · server ส่ง `cache-control: max-age=0, must-revalidate` ปัญหาคือโค้ดเก่าในหน่วยความจำของแท็บ
- **ยิง `/api/v1/platform/*` จากโฮสต์** → 403 — **เกิดทุกโฮสต์ ไม่ใช่เฉพาะ Docker Desktop** (#335 D3) · รอบนี้ agent เขียนผิดไปทีหนึ่งว่า "เฉพาะ Docker Desktop" แล้วแก้แล้ว · `ssh -L` ก็ไม่ได้
- **browser pane ในตัวของ agent:** navigate ไป `https://localhost` ไม่ได้ (หน้าเตือน cert) และ drift worker โหลดไม่ขึ้น — ใช้เบราว์เซอร์จริงของ owner (`Start-Process <url>`)
- **อ่าน `server/.env`** ถูก auto-mode classifier ปฏิเสธ (credential) — อย่าพยายามซ้ำ ใช้ `$POSTGRES_PASSWORD` จาก env ภายใน container แทน (ดู tutorial ข้อ 5.1)

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

- **ยังไม่ได้ตรวจ:** FortiGate จะทำให้ Sign in with Google / SMTP จาก `mob04` พังแบบ `ghcr.io` — เป็นการเดาจากพฤติกรรมเดิม (ไม่เกี่ยวแล้วเพราะไม่ใช้ Google)
- **ยังไม่ได้ตรวจ:** owner login เข้าแอปผ่านโหมด Backoffice สำเร็จจริงหลัง hard reload — ยืนยันได้แค่ `/auth/token` ด้วย curl
- **ยังไม่ได้ดู:** งาน `tenant-import` ที่ FAILED 4 ใน Bull-Board มาจากไหน (น่าจะเป็นการทดสอบ import รอบก่อน)
- **ยืนยันแล้ว:** ไม่มีค่าจากผู้ใช้ถูกต่อเข้า SQL (สแกน `query(\`…${…}\`)` นอก migration เจอแค่ชื่อคงที่) · `SECURITY DEFINER` ตั้ง `search_path` แล้ว · pino redact แค่ header ไม่ครอบ body (ขัด ADR-0009 บรรทัด 103 — อยู่ใน checklist ของ #443)

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **#343 → #344 มาก่อน #443** (ลำดับใน CLAUDE.md) — ไม่ต้องเริ่ม #443 ระหว่างนี้
2. เคาะรายละเอียด Q1-B ของ #443 (IP คอนเทนเนอร์ UI / `allow` ใน `nginx.conf` / `PLATFORM_ADMIN_IPS` บน `mob04`) — รอ owner
3. `/scrutinize` #443 → แตกเป็นใบย่อยตามขั้น 1–4 → ค่อยติด `ready-for-agent`
4. เปิดใบแยก (ยังไม่ได้เปิด): บั๊กข้อความใน `frontend/lib/presentation/widgets/device_enrolment_dialog.dart` — ขึ้น "POS Terminal" เสมอแม้โค้ดเป็นของ `backoffice` และ hint "POS-ABCD หรือรหัส 6 หลัก" ไม่ตรงกับโค้ดจริง (8 hex)
5. เพิ่มบรรทัด #443 ลง `CLAUDE.md` ส่วน "Still open" ถ้า owner ต้องการ

## 7. ข้อควรระวัง

- 🔴 **merge เข้า `main` = มี run `Deploy (demo)` ใหม่เข้าคิว "Waiting for review"** — อย่า approve ตามความเคยชิน (ปัญหาคิวซ้อนใน CLAUDE.md "Deploy queue")
- `tlswrap` **ไม่มีไฟล์นิยามใน repo** — overlay อยู่นอก repo ตามรอบซ้อมเดโม · คำสั่ง `docker run` ใน tutorial ข้อ 4 คือสำเนาเดียวใน repo · dev เท่านั้น ห้ามขึ้น `mob04`
- ถ้าจะ implement #443: สัญญา `POST /platform/tenants` เปลี่ยน (ตัด `ownerPassword`) → runbook #338, tutorial ข้อ 5.2, test/e2e ต้องแก้ใน PR เดียวกัน · addendum ของ ADR-0001 และ ADR-0009 ร่างไว้ในคอมเมนต์ #443 ใส่พร้อม PR ที่ implement

## Suggested skills

- `9arm-skills:scrutinize` — ก่อนติด `ready-for-agent` ให้ #443
- `mattpocock-skills:to-issues` หรือ `to-tickets` — แตก #443 เป็นใบย่อยตามขั้น 1–4
- `karpathy-guidelines` + `tdd` — ตอนลงมือ (ตาม `09 §10` working agreement)
- `code-review` — ปิดงานแต่ละใบย่อย
- `writing-for-agents` — ถ้าจะเพิ่ม #443 ลง `CLAUDE.md`
- `run` — ถ้าต้องยกสแตก local ขึ้นใหม่ (ทำตาม tutorial)
