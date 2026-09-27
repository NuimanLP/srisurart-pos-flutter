# Handoff — #443 `platform.admin-ui`: CLI + enrolCode ใหม่ + รหัสชั่วคราว owner + หน้าเว็บ (2026-09-27)

**วันที่:** 2026-09-27 · **ผู้บันทึก:** agent (Claude, orchestrator) กับ owner · **สถานะ:** โค้ดทั้ง 4 ขั้น merge เข้า `main` แล้ว · **issue #443 ยังเปิด** — AC ที่ต้องพิสูจน์บน `mob04` ยังไม่ได้ทำ
**ขอบเขต:** implement ขั้น 1–4 ของ #443 เป็น stacked PR, review ทุกใบ, แก้ CI, ยกสแตกจริงบนเครื่อง dev, แก้จอแคบ + tutorial
**ต่อจาก:** [`session-2026-09-26-local-stack-tutorial-and-admin-ui-issue.md`](session-2026-09-26-local-stack-tutorial-and-admin-ui-issue.md) (ร่าง #443) · [`ticket-338-platform-provision.md`](ticket-338-platform-provision.md) (runbook ที่ถูกเขียนใหม่รอบนี้)

## 1. ตอนนี้อยู่ตรงไหน

| PR | ขั้น | เข้า | หมายเหตุ |
|---|---|---|---|
| #445 | 1 · platform CLI (`server/src/cli/platform.ts`) | `main` | `docker compose exec api-1 node dist/cli/platform.js …` |
| #446 | 2 · `POST /platform/tenants/:id/devices/:deviceId/enrol-code` + `GET /platform/tenants/:id` | `main` | + แก้ `:id` ไม่ใช่ UUID → 400 แทน 500 |
| #447 | 3 · รหัสชั่วคราว owner + บังคับเปลี่ยน (migration `1788652804500-OwnerTempPassword`) + CLI rework | branch ของ PR2 ⚠️ | เข้า `main` จริงผ่าน #448 |
| #448 / #449 | 4 · `platform-ui` (หน้าเว็บ, `127.0.0.1:3200`, IP `172.30.0.20`) | `main` (#448) | head เดียวกัน — #449 ถูก merge ตามไปด้วย |
| #450 | จอแคบไม่มีแถบเลื่อนแนวนอน + tutorial ข้อ 5 | `main` | |

- **ข้อตัดสินของ owner** ทั้งหมดอยู่ในคอมเมนต์ของ #443 — ชุดของวันนี้คือ [คอมเมนต์ 2026-09-27](https://github.com/NuimanLP/srisurart-pos-flutter/issues/443#issuecomment-5853708475) **อ่านที่นั่น ไม่ลอกมาที่นี่**
- **ไม่มีอะไรขึ้น `mob04`** · merge เข้า `main` = run `Deploy (demo)` ใหม่เข้าคิว "Waiting for review" หลายรอบ (ดู CLAUDE.md "Deploy queue")
- **เครื่อง dev (ไม่อยู่ใน git):** สแตก `srisurart-pos` (compose + dev overlay, ไม่มี monitoring) รันจาก worktree ใน scratchpad ของ session นี้ — `platform-ui` bind-mount ไฟล์จาก worktree นั้น ถ้า worktree หาย หน้าเว็บจะพัง ต้อง `up -d` ใหม่จาก checkout ปกติ · มี platform admin `devadmin` (รหัสไม่ได้จดไว้ที่นี่ — `bootstrap-admin.js --force` ถ้าต้องใช้)

## 2. ทำอะไรไป ได้ผลอะไร

วิธีทำงาน: agent หลักเป็น orchestrator ส่ง subagent — **Opus** `/scrutinize` แผนก่อน, **Sonnet/Opus** เขียนโค้ดตาม `karpathy-guidelines`, **Opus อีกตัวที่ไม่ใช่คนเขียน** `/code-review` (+ `/scrutinize` ใบที่แตะ auth/เครือข่าย) ก่อนเปิดทุก PR

1. `/scrutinize` แผนของ #443 → เปลี่ยน 3 อย่างที่ owner รับ: ย้ายรีเซ็ตรหัส owner จากขั้น 2 ไปขั้น 3 (ก่อนมี forced change = admin รู้รหัสถาวร), เพิ่ม `GET /platform/tenants/:id` ในขั้น 2, token เปลี่ยนรหัสเป็น `typ:'pwchange'` (ตัวตรวจ JWT ปฏิเสธ typ อื่นอยู่แล้ว → ทุก guard กันให้ฟรี)
2. review เจอบั๊กจริงที่แก้ก่อน merge:
   - **NFC สลับลำดับวรรณยุกต์ไทย** (tone mark ccc 107 กับสระล่าง ccc 103) → owner ที่ hash ก่อน PR3 login ไม่ได้ตลอดไป · แก้: verify แบบ NFC ก่อน ถ้าไม่ผ่านและ NFC เปลี่ยน input ค่อยลองแบบดิบ (+ dummy verify ฝั่ง user ไม่มี เพื่อเวลาเท่ากัน)
   - `deploy.yml` validate ด้วย `run platform-ui` ชน IP ตายตัว (`Address already in use`) → deploy รอบสองพังทุกครั้ง · และไม่มีขั้นสร้าง `/opt/pos/docker/platform-ui`
   - `add_header` ใน `location` ทำให้ header ความปลอดภัยระดับ server (CSP ฯลฯ) หายจาก API
   - CLI อ่าน secret สองตัวติดกันจาก stdin chunk เดียวแล้วตัวที่สองหาย
   - CLI ของ PR1 ส่ง `ownerPassword` ซึ่ง PR3 ทำให้ 400 → merge PR1 เข้า PR3 แล้วแก้ CLI ในนั้น
3. **วัด 403 ทั้งสองชั้นแล้ว** (stack แยก subnet, Docker Desktop): container อื่น → nginx = 403 · → `platform-ui` = 403 · ตรงเข้า api ด้วย XFF นอก allowlist = 403 `PLATFORM_IP_FORBIDDEN` · host loopback → UI → nginx → api = 200 · ผลเต็มอยู่แถว "ดู platform-ui" ใน [`07_CICD_DEPLOY.md`](../Backend_design/07_CICD_DEPLOY.md)
4. CI ของ #449 แดง: `owner-password.e2e-spec.ts` login 13 ครั้งจาก IP เดียว แต่ throttle ต่อ IP = 10/60 วิ และ bucket ใน Redis ใช้ร่วมกับ e2e ไฟล์อื่น → 429 ตามลำดับการรัน · แก้ให้แต่ละ login มี `X-Forwarded-For` ของตัวเอง (แบบ `devices.e2e-spec.ts`)
5. ยกสแตกจริงจาก `main` บนเครื่อง dev → login หน้าเว็บผ่าน `platform-ui → nginx → api → Postgres` ได้จริง · จอ 375px เดิม `scrollWidth` 400 → หลัง #450 เหลือ 375

## 3. ตัดสินใจอะไรไป เพราะอะไร (เฉพาะที่ไม่อยู่ในคอมเมนต์ #443)

- **PR2 ตั้ง base `main` ไม่ stack บน PR1** — ไม่แตะไฟล์กัน · PR3 stack บน PR2 และ **merge branch PR1 เข้ามา** เพื่อให้ `main` ไม่มีช่วงที่ CLI พัง
- **`platform-ui` ยิง nginx หลักด้วย HTTPS + `proxy_ssl_verify on`** (`proxy_ssl_name localhost` ตาม CN ของ certgen) — nginx หลัก redirect :80→https ทุก path ทาง http ที่ owner ยอมไว้จึงใช้ไม่ได้ · `proxy_ssl_verify off` ห้ามตามคำตัดสิน
- **จอแคบ: ตารางเลื่อนในการ์ด** (`.table-scroll`) ไม่ใช้ `overflow-wrap: anywhere` — ลองแล้ว หัวคอลัมน์ไทยแตกทีละตัวอักษร
- **ไม่เพิ่ม route `/change-password` ใน Flutter** — ฟอร์มเปลี่ยนรหัสสลับเข้าแทน `LoginForm` ในที่เดิม (ใช้ได้ทั้งหน้า `/login` และ `LoginDialog` ใน Settings) จำนวน route ไม่เปลี่ยน · บันทึกใน `CONTRACT.md`

## 4. ลองแล้วไม่เวิร์ก

- **รันสแตก e2e แยกด้วย `-p` อย่างเดียว** → ชน subnet `172.30.0.0/24` ของ `srisurart-pos_default` · ต้องมี override เปลี่ยน subnet + port (`ports: !override [...]`) แล้วตั้ง `DATABASE_URL`/`REDIS_*_URL` **และ `DATABASE_ADMIN_URL=…/pos`** (ไม่ใช่ `/postgres` — fixture ใช้ตัวนี้เปิด admin DataSource) ก่อนรัน `vitest --config ./vitest.config.e2e.ts <files>`
- **`pnpm test:e2e -- <files>` ไม่กรองไฟล์** — รันทั้งชุด ใช้ `pnpm exec vitest run --config ./vitest.config.e2e.ts <files>`
- **`pnpm approve-builds`** ต้องการ TTY → ใช้ `pnpm rebuild argon2 esbuild msgpackr-extract` แทน
- **`gh pr close` กับ PR ที่ merge ไปแล้ว** — #449 merge ตาม #448 เองเพราะ head เดียวกัน

## 5. ยังไม่ชัวร์ / ยังไม่ได้พิสูจน์

- **ยังไม่ได้วัดบน Linux (`mob04`)**: source IP ที่ `platform-ui` เห็นผ่าน docker-proxy/iptables จริง — ค่าที่วัดมาจาก Docker Desktop เท่านั้น · ทำในรอบ #343
- **e2e concurrency 3 ไฟล์** (`sales`, `purchase-orders`, `stock-race-three-writers`) ล้มด้วย ECONNRESET บน Mac ทุกครั้งที่รันทั้งชุด — agent ทดลองบน base ที่ไม่มีงานนี้ก็ล้ม (macOS `somaxconn=128`) · บน CI ผ่าน
- **clock skew**: refresh cutoff (`iat < password_changed_at`) สมมติว่านาฬิกา api กับ Postgres ต่างกัน < 1 วินาที (เขียนใน ADR-0009 addendum)
- **cert จริงจาก CA** บน VM จะทำให้ `platform-ui` ได้ 502 — trust ใบ certgen อยู่

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **#343 → #344 ยังมาก่อน** · ในรอบ VM: วัด 403 สองชั้นบน Linux, ตั้ง `PLATFORM_ADMIN_IPS` บน `mob04` ให้มี `172.30.0.20` (หรือไม่ตั้ง = ใช้ default), เช็ค `docker inspect … platform-ui` ได้ `.20`
2. **owner ตอบคำถามค้าง** (อยู่ใน body ของ #447/#449):
   - SecLists 10k กรอง ≥ 12 ตัวเหลือ **10 คำ** — ขยายเป็น 100k/1M?
   - admin หน้าเว็บทุกคนใช้ bucket login IP เดียว (`.20`, 10/นาที) — ยอมไหม
   - legacy non-NFC hash: fallback ถาวร (ปัจจุบัน) หรือ rehash ตอน login สำเร็จ
   - รับรองข้อความไทย `agent ร่าง` ทั้งหมดใน `02_API_SCREENS §8` + แถบแจ้งเตือน 7 วัน · ข้อความไทยของหน้าเว็บยังไม่อยู่ใน §8
   - runbook #338 §4 ยังใช้ wget — AC ครอบแค่ §3 หรือแปลง
3. ติ๊ก AC ของ #443 ที่พิสูจน์แล้วในใบ แล้วปิดใบหลังข้อ 1 ผ่าน
4. ใบแยกที่ยังไม่ได้เปิด (จาก session ก่อน): ข้อความ `device_enrolment_dialog.dart` ขึ้น "POS Terminal" เสมอ

## 7. ข้อควรระวัง

- 🔴 **Stacked PR: ถ้า base ถูก merge ไปแล้ว ต้อง retarget ใบถัดไปเป็น `main` ก่อน merge** — #447 ถูก merge เข้า branch ของ PR2 ที่ merge ไปแล้ว งาน PR3 เลยไม่เข้า `main` จนกว่า #448 จะ merge (โชคดีที่ #448 มี PR3 อยู่ในตัว)
- **สามอย่างเปลี่ยนพร้อมกันเสมอ**: IP `platform-ui` · `allow` ใน `nginx.conf` · `PLATFORM_ADMIN_IPS` — รายละเอียดใน `07` แถว "ดู platform-ui"
- ฐานข้อมูล dev มีร้าน `test-…`/`cli-…` เยอะ = ขยะจาก e2e (ใช้ฐานเดียวกัน) ไม่ใช่บั๊ก

## Suggested skills

- `run` — ยกสแตก local ตาม tutorial ข้อ 3 + 5 (หน้าเว็บ `:3200`)
- `code-review` — ก่อนปิด #443
- `writing-for-agents` — ถ้าแก้ CLAUDE.md ต่อ
