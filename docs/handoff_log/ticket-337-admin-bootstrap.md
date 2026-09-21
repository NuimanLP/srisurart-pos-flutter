# Ticket #337 `admin.bootstrap` — คำสั่งเดียวได้ platform admin คนแรก

**ใบงาน:** #337 (parent #335, ตัดสินใจ D2) · **เลน A** (`team/1`) · **วันที่:** 2026-09-21
**PR:** ดู `docs/handoff_log/demo-335-STATUS.md` §3.1

## 1. ทำอะไร

ก่อนใบนี้ การมี platform admin คนแรกต้องเปิด `psql` แล้วเขียน argon2 hash ด้วยมือ (ทุก e2e
ที่ต้องใช้ admin seed แถวเอง — `platform.e2e-spec.ts:34`, `import-snapshot.e2e-spec.ts:63`)
ตอนนี้มีคำสั่งเดียว:

```
DATABASE_URL=postgres://postgres:<POSTGRES_PASSWORD>@127.0.0.1:5432/pos \
BOOTSTRAP_ADMIN_USERNAME=admin \
BOOTSTRAP_ADMIN_PASSWORD='<อย่างน้อย 12 ตัวอักษร>' \
BOOTSTRAP_ADMIN_DISPLAY_NAME='ผู้ดูแลระบบ' \
corepack pnpm bootstrap:admin        # เพิ่ม --force เพื่อรีเซ็ตรหัสของ admin ที่มีอยู่
```

แล้วล็อกอินได้จริงที่ `POST /api/v1/platform/auth/token` (`{username, password}` →
`{data: {token, admin}}`)

ไฟล์ที่เพิ่ม/แก้:

| ไฟล์ | อะไร |
|---|---|
| `server/src/db/bootstrap-admin.ts` | ใหม่ — `export async function bootstrapAdmin()` + entry guard สำหรับ CLI |
| `server/package.json` | เพิ่ม script `bootstrap:admin` ถัดจาก `db:migrate*` |
| `server/test/bootstrap-admin.e2e-spec.ts` | ใหม่ — e2e 6 เคส จบที่ `POST /platform/auth/token` ทุกเคส |

**ADR-0001 ไม่ถูกแก้** — admin ยังถูกสร้างนอกระบบโดยทีม ไม่มี API ใดสร้าง admin
สคริปต์นี้คือ "นอกระบบ" ที่เป็นทางการ ไม่ใช่ endpoint

## 2. สามกับดักของ D2 และสิ่งที่ทำเพื่อเลี่ยง

1. **รูปทรงไฟล์ที่ไม่ต้องเพิ่มรายการใน allowlist ของ `common/tenant-door.spec.ts`**
   spec นั้นสแกน *ทุกไฟล์* ใน `src/` แล้วปฏิเสธ `new DataSource(`, value-import ของ
   `DataSource` จาก `typeorm`, `@Inject(*_DATA_SOURCE)`, `.connection` — และ `ALLOWED`
   ผูกกับ path ของไฟล์ที่ถูกสแกนเอง **ไม่ส่งต่อให้ไฟล์ที่ import มัน**
   `bootstrap-admin.ts` จึงเรียกโรงงาน `createMigrationDataSource` จาก `db/data-source.ts`
   (ซึ่งอยู่ใน allowlist แล้ว) และไม่เอ่ยชื่อ `DataSource` เลย — เหมือน `db/migrate.ts`
   ที่ก็ไม่อยู่ใน allowlist และผ่านมาตลอด · **ไม่แก้ spec และไม่เพิ่ม allowlist**
2. **แหล่ง argon2 ที่ถูกต้อง** — `hashPassword` จาก `src/common/password.ts` (argon2id,
   memoryCost 65536, timeCost 3, parallelism 1) ซึ่งเป็นตัวเดียวกับที่
   `platform/platform-auth.service.ts` ใช้ `verifyPassword` · **ไม่ใช่** `auth/auth.service.ts`
   ซึ่งเป็นเส้นของ user ในร้าน
3. **คอลัมน์ที่ไม่มี default** — `platform_admins.display_name` เป็น `TEXT NOT NULL`
   ไม่มี default (`1788652800000-InitialSchema.ts:41`) จึงต้องรับ
   `BOOTSTRAP_ADMIN_DISPLAY_NAME` เป็นอินพุตตัวที่สาม ไม่ใช่เดาจาก username

## 3. พฤติกรรมที่ต้องรู้ก่อนใช้

- **รันซ้ำไม่ทับรหัส** — default เป็น `ON CONFLICT (username) DO NOTHING` → รายงาน
  `already exists — password left alone (pass --force to reset it)` และ exit 0
- **`--force` เปลี่ยนแค่ `password_hash`** — ไม่แก้ `display_name` ไม่แก้ `is_active`
- 🔴 **การรันซ้ำ แม้ใส่ `--force` ไม่ปลุก admin ที่ถูก `is_active = false`**
  สคริปต์ไม่เขียนคอลัมน์ `is_active` เลย (ตอนสร้างใช้ `DEFAULT TRUE` ของตาราง)
  เป็นพฤติกรรมที่ **ตั้งใจ**: การปิด admin คือการเพิกถอนสิทธิ์ สคริปต์ bootstrap ไม่ใช่ที่
  สำหรับยกเลิกการเพิกถอน · ถ้าจะเปิดคืนต้อง `UPDATE platform_admins SET is_active = true
  WHERE username = …` ด้วยมือโดยเจตนา (มีคอมเมนต์กำกับไว้ในไฟล์และ e2e คุมไว้)
- **เกณฑ์รหัสผ่าน:** ไม่ว่าง/ไม่เป็นช่องว่างล้วน และยาว **อย่างน้อย 12 ตัวอักษร**
  (`MIN_PASSWORD_LENGTH`) · ตรวจ **ก่อน** เชื่อมต่อและก่อน hash ตามกฎ CLAUDE.md
  (validate ก่อน แล้วจึง clamp) — อินพุตพังจะล้มทันที ไม่ล้มกลางการเขียน
- **ต้องเป็น owner role** — หลังเชื่อมต่อจะถาม Postgres ว่าใครเป็นเจ้าของตาราง
  (`pg_get_userbyid(relowner)` + `pg_has_role(current_user, relowner, 'MEMBER')`)
  ไม่ใช่แกะจาก URL · ถ้าต่อด้วย `pos_app` จะได้
  `DATABASE_URL must be the owner role: connected as "pos_app", but platform_admins is owned by "postgres"`
  แล้ว exit 1 · **นี่เป็นการป้องกันจริง ไม่ใช่พิธี**: `1788652800001-RowLevelSecurity.ts`
  ให้ `GRANT SELECT, INSERT, UPDATE, DELETE` บน `platform_admins` แก่ `pos_app` ด้วย
  (มันเป็น `GLOBAL_TABLES` ไม่มี RLS) ดังนั้นถ้าไม่ตรวจ การเผลอใช้ URL ของแอปจะสำเร็จเงียบ ๆ
- ถ้ายังไม่ migrate จะได้ `platform_admins does not exist — run the migrations first`
- exit code: 0 สำเร็จ (ทั้ง created/unchanged/updated) · 1 ทุกกรณีที่ปฏิเสธหรือพัง

## 4. รันบน VM ที่มีแต่ image ไม่มี checkout

`pnpm` ไม่มีบน VM และไม่มีซอร์ส — แต่ service `migrate` ใช้ image เดียวกับ api และมี
`dist/` อยู่แล้ว จึงยิงคำสั่งครั้งเดียวผ่าน `docker compose run --rm` (one-shot, ไม่แตะ
คอนเทนเนอร์ที่รันอยู่ และไม่ต้องรอ service อื่น):

```bash
ssh <DEMO_SSH_USER>@<DEMO_SSH_HOST>
cd /opt/pos
sudo docker compose run --rm \
  -e BOOTSTRAP_ADMIN_USERNAME='admin' \
  -e BOOTSTRAP_ADMIN_PASSWORD='<รหัสจากที่เก็บ secret ของเจ้าของ>' \
  -e BOOTSTRAP_ADMIN_DISPLAY_NAME='ผู้ดูแลระบบ' \
  migrate node dist/db/bootstrap-admin.js
```

- `DATABASE_URL` ไม่ต้องส่ง — service `migrate` ใน `docker-compose.yml` ตั้งไว้เป็น owner
  role อยู่แล้ว (มันคือ role ที่รัน migration)
- เพิ่ม `--force` ต่อท้ายคำสั่งเพื่อรีเซ็ตรหัส: `… migrate node dist/db/bootstrap-admin.js --force`
- 🔴 รหัสจะไปอยู่ใน history ของ shell — ใช้ `history -d` หรือเว้นวรรคนำหน้าคำสั่ง
  (`HISTCONTROL=ignorespace`) และ **ห้าม** เขียนลง `/opt/pos/.env`
- ตรวจผลจากภายใน netns ของ nginx ตาม D3 (loopback ของ nginx คือ loopback จริง จึงผ่านทั้ง
  `allow 127.0.0.1` ของ nginx และ `isAllowedIp` ของ guard):

```bash
sudo docker compose exec -T nginx wget -qO- --no-check-certificate \
  --post-data='{"username":"admin","password":"<รหัส>"}' \
  --header='Content-Type: application/json' \
  https://127.0.0.1/api/v1/platform/auth/token
```

## 5. เทสต์

`server/test/bootstrap-admin.e2e-spec.ts` — เรียก `bootstrapAdmin()` ที่ export (e2e รัน
vitest บน `src/` ไม่มีใครเรียก `dist/`) แล้ววัดผลจากพฤติกรรมที่มองเห็นจากภายนอกคือ HTTP
ของ `POST /api/v1/platform/auth/token` 6 เคส:

1. สร้างใหม่ → `action: 'created'` แล้ว login ได้ 200 + token + `displayName` ตรง
2. รันซ้ำด้วยรหัสอื่น → `action: 'unchanged'` · รหัสเดิม 200 · รหัสใหม่ 401
3. `force: true` → `action: 'updated'` · รหัสใหม่ 200 · รหัสเก่า 401
4. รหัสว่าง/ช่องว่างล้วน/สั้นเกิน/username ว่าง/display name ว่าง → throw และไม่มีแถวใน DB
5. ต่อด้วย URL ของ `pos_app` → throw `must be the owner role` และไม่มีแถวใน DB
6. admin ที่ `is_active = false` แล้วรัน `--force` → login ยัง 401 และ `is_active` ยัง false

owner URL ในเทสต์เอามาจาก `APP_CONFIG.adminDatabaseUrl` และ non-owner URL จาก
`config.databaseUrl` — ไม่ฮาร์ดโค้ด connection string ใหม่ในเทสต์

## 6. ผลรันจริง (2026-09-21, Windows + compose dev overlay)

```
corepack pnpm lint        → oxlint src/ test/ : clean
corepack pnpm typecheck   → tsc --noEmit : clean
corepack pnpm test        → Test Files 47 passed (47) · Tests 397 passed (397)
                            (รวม common/tenant-door.spec.ts ที่ไม่ถูกแก้)
corepack pnpm vitest run --config ./vitest.config.e2e.ts test/bootstrap-admin.e2e-spec.ts
                          → Test Files 1 passed (1) · Tests 6 passed (6)
corepack pnpm test:e2e    → Test Files 2 failed | 46 passed | 1 skipped (51)
                            Tests 3 failed | 578 passed | 2 skipped (590)
```

สามเคสที่แดงใน e2e ชุดเต็ม **ไม่เกี่ยวกับใบนี้** และแดงอยู่ก่อนแล้วบน `origin/main`
บนเครื่อง Windows เครื่องนี้:

- `test/backup-restore.e2e-spec.ts` 2 เคส (exec bit + `bash -n`) — ต้องมี `bash` จริงและ
  file mode ของ POSIX (`WSL … execvpe(/bin/bash) failed`) เป็นของ #288/#346 เลน C
- `test/stock-race-three-writers.e2e-spec.ts` 1 เคส — เคส 600 concurrent writes บวก
  คำเตือน `#160` ของ runner เองว่า Node v24.15.0 บน Windows มีบั๊ก libuv ที่ฆ่า worker
  แบบสุ่ม ("Worker exited unexpectedly" ปรากฏใน run นี้ด้วย)

CLI ตัวจริง (หลัง `pnpm build`) รันครบทุกเส้นบน dev stack แล้ว:

```
run 1            → platform admin "cli-smoke-337": created
run 2 (ซ้ำ)      → platform admin "cli-smoke-337": already exists — password left alone (pass --force to reset it)
run 3 (--force)  → platform admin "cli-smoke-337": password reset
รหัสสั้น          → BOOTSTRAP_ADMIN_PASSWORD is too weak: at least 12 characters required  (exit 1)
URL ของ pos_app  → DATABASE_URL must be the owner role: connected as "pos_app", but platform_admins is owned by "postgres"  (exit 1)
```

(แถว `cli-smoke-337` ถูกลบออกจาก dev DB หลังทดสอบแล้ว)

## 7. สิ่งที่ยังไม่ได้พิสูจน์

- **ยังไม่เคยรันบน VM `mob04`** — ข้อ 4 เป็นคำสั่งที่เขียนจาก `docker-compose.yml` ที่มีอยู่
  (service `migrate` + `DATABASE_URL` ของมัน) ไม่ใช่ log ของการรันจริง · ต้องรอ VPN ของ
  เจ้าของตาม D9/#67 · ห้ามติ๊กช่องนั้นในใบงานจนมี log
