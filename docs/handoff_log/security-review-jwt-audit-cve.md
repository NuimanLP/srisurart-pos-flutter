# Handoff: ทบทวนความปลอดภัย — JWT signing, audit log, CVE/OWASP

**Date:** 2026-09-09
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch `main`
**Previous handoff:** [`couchdb-rejected.md`](couchdb-rejected.md)
**Commits:** `419a4e2` (security review) · `ed98cd5` (dependabot แก้กลับ) · commit นี้ (เอกสาร)

---

## 1. ที่มา

เจ้าของโปรเจกต์ถาม 3 คำถามติดกัน:

1. *"did we use the best practice for JWT security reasons, and RS token"*
2. *"did we have user event log (งานเราจำเป็นต้องใช้ไหม)"*
3. *"did we have a plan to do CVE testing, OWASP top10?"*

**คำตอบตอนนั้นคือ ไม่มีทั้งสามอย่าง** — ตรวจแล้วพบว่า:

* `server/` **ไม่มีโค้ด JWT เลย** ไม่มี `jsonwebtoken` / `jose` / `passport` ใน `package.json`
  งาน auth คือ #4 ซึ่งยังไม่เริ่ม → ยังแก้ได้ที่ต้นทาง
* ADR-0009 กำหนด**อายุ** token และสิ่งที่ `/auth/refresh` ต้องเช็คไว้ครบ แต่**ไม่เคยระบุ**
  อัลกอริทึมเซ็น, ที่เก็บกุญแจ, การหมุนกุญแจ และที่เก็บ token ฝั่ง client
  → ถ้าปล่อยไว้ คนเขียน #4 จะได้ค่า default ของ library คือ HS256 + secret ก้อนเดียว
* `audit_log` **มีในสคีมาแล้ว** (`01_DATABASE.md §5`, migration ลงใน #15) และ ADR-0002/0004/0005
  อ้างถึงมันตลอด แต่ **ไม่มี ticket ไหนเป็นเจ้าของงานเขียนลงตาราง**
* ไม่มีคำว่า OWASP / CVE / audit ที่ไหนเลยใน `docs/`, `.github/workflows/` หรือ issue ทั้ง 42 ตัว

---

## 2. สิ่งที่ทำ

### A. ADR-0009 — หัวข้อใหม่ *"การเซ็นและที่เก็บ token"*

| หัวข้อ | ค่าที่เคาะ |
|---|---|
| อัลกอริทึม | **RS256** + `kid` · verifier ล็อกที่ `['RS256']` ห้าม HS256 / `alg:none` |
| กุญแจ | `JWT_PRIVATE_KEY` เฉพาะ process ที่มี `/auth/*` — `worker`/`migrate`/Bull-Board ห้ามมี |
| โค้ด | แยก `JwtSigner` (ต้องมี private key) กับ `JwtVerifier` (public key พอ) |
| claim | เพิ่ม `iss`, `jti` และ **`typ`** (`access`/`refresh`) — `/api/*` รับเฉพาะ `access` |
| skew | 30 วินาที |
| ที่เก็บฝั่ง web | access **ใน memory เท่านั้น** · refresh ใน IndexedDB · ห้าม localStorage |
| log | `pino` redact `authorization` + body ของ `/auth/*` ทั้งหมด |
| รหัสผ่าน/PIN | Argon2id m=64MiB t=3 p=1 |

**เหตุผลที่ต้อง RS256 ไม่ใช่ HS256:** stack มี `api-1..3` + `worker` + Bull-Board ในเครือข่ายเดียว
HS256 ทำให้ทุก process ที่**ตรวจ** token ถือ secret ที่**ออก** token ได้ด้วย และ multi-tenant ทำให้
blast radius เป็นทั้ง cluster ไม่ใช่ร้านเดียว · ยังเป็น stateless ตามกติกาอาจารย์

ซิงก์ต่อไปที่ `02_API_SCREENS.md §1.1` (เพิ่มแถว) และ `adr/README.md` (ตาราง ADR + ตาราง addendum)

### B. GitHub issues

* **#43 `p3d`** — `audit_log` writer · `team/3` · `PattaraponKitcharoen` · blocked by #4
  * writer ตัวเดียว รับ `EntityManager` ของ request → เขียน**ใน transaction เดียวกับ business write**
  * auth events ลงพร้อม #4 · งานที่แตะเงิน/สต็อกใน #16/#20–#28/#36/#5 เรียก writer เดียวกัน
  * `pos_app` ได้แค่ `SELECT, INSERT` (append-only เหมือน `movements`)
* **#44 `sec.1`** — security gate · `team/3` · `PattaraponKitcharoen`
  * Helmet + CORS allowlist + Nginx hardening (A05) → ลงใน #4 หรือ #14
  * rate limit **ต่อ user/IP** บน login และ PIN (A07) — #33 เป็นต่อ tenant ไม่พอ
  * `security.e2e-spec.ts`: body ปลอม `tid`/`did`, SQLi, `alg:none`, key-confusion, `typ` ผิด, brute-force
  * CodeQL หลัง #4+#20 merge · ZAP baseline ครั้งเดียวก่อนส่ง (ไม่ใส่ CI)
* **#4** ได้คอมเมนต์ชี้ addendum + e2e เคสเพิ่ม 2 ตัว
* **#2** และ **#10** เพิ่ม #43/#44 ลงรายการลูกและตาราง ownership

### C. CI — CVE gate

* `server.yml` job **`audit`** = `pnpm audit --audit-level=high` + Trivy `fs` (CVE + Dockerfile misconfig)
* `flutter.yml` job **`deps-audit`** = OSV-Scanner บน `pubspec.lock` (pub ไม่มีคำสั่ง audit)
* รันจริงครั้งแรกบน `419a4e2` — **เขียวทั้ง 2 workflow ทุก job**

### D. CVE จริงที่เจอวันแรก

`pnpm audit` เจอ **3 high + 1 low** ทั้งหมดคือ **multer 2.2.0** ที่ติดมากับ `@nestjs/platform-express`
(GHSA-535w-7cp7-47q4 + อีก 3) · `pnpm update` ไม่ช่วยเพราะ upstream ยัง pin 2.2.0
→ แก้ด้วย **`pnpm.overrides.multer >= 2.3.0`** ใน `server/package.json` · audit สะอาด, typecheck + unit ผ่าน

### E. `04_QA_SCRUTINY.md` รอบ 4

ตาราง **OWASP Top 10 (2021) ครบ 10 ข้อ** — แต่ละข้อปิดด้วยอะไร ยังขาดอะไร ใครเป็นเจ้าของ
พร้อมหัวข้อ *"สิ่งที่ตั้งใจไม่ทำ และทำไม"* (ZAP ใน CI, SAST เต็มรูป, pentest ภายนอก)

---

## 3. 🔴 สิ่งที่พลาดในรอบนี้ — Dependabot

`.github/dependabot.yml` ฉบับแรกตั้ง **version update** รายสัปดาห์ด้วย `patterns: ['*']` โดยไม่กัน major
ทั้งที่เจ้าของโปรเจกต์ไม่ได้ขอ พอ push ขึ้น `main` มันเปิด PR ทันที **4 ตัวภายในไม่กี่นาที**:

| PR | เนื้อหา | CI |
|---|---|---|
| #45 | Node `22-alpine → 26-alpine` | เขียว แต่ข้าม major 4 เวอร์ชัน |
| #46 | GitHub Actions 3 ตัว | แดง `build web artifact` |
| #47 | server dev-deps 4 ตัว | แดง `integration` |
| #48 | Flutter deps 7 ตัว | แดง `analyze + test`, `codegen`, `build web` |

เจ้าของโปรเจกต์ถามว่า *"dependabot มาทำอะไรวะ"* → ตัดสินใจ **ปิด**

**แก้แล้ว (`ed98cd5`):** ปิด PR ทั้ง 4 + ลบ branch + ลบ item ออกจาก project board (ทำมือ เพราะ token
ของ `gh` ไม่มี scope `project`) · config เหลือ **`open-pull-requests-limit: 0` ทุก ecosystem**
= ปิด version update แต่ยังได้ security update

**บทเรียน:** CVE gate ที่ต้องการมาจาก **job ใน CI** (`audit` / `deps-audit`) ซึ่งทำให้ build แดงได้จริง
ส่วน Dependabot version update เป็นของแถมที่ไม่มีใครขอ และกลายเป็น 4 PR ที่ทีมต้องมานั่งปิด
🔴 **อย่าเปิดกลับ** เว้นแต่ทีมตกลงกันก่อน — เหตุผลอยู่ในหัวไฟล์ `dependabot.yml`, `CLAUDE.md`
และกล่องเตือนใน `04_QA_SCRUTINY.md` รอบ 4

---

## 4. สถานะและงานต่อ

* `main` = commit นี้ · CI เขียวทั้ง Flutter และ Server · ไม่มี PR เปิดค้าง ไม่มี dependabot branch
* **#43 / #44 ยังไม่เริ่ม** ทั้งคู่รอ #4 (`p3` auth) ซึ่งเป็น critical path
* คนที่ทำ #4 **ต้องอ่าน ADR-0009 หัวข้อ "การเซ็นและที่เก็บ token" ก่อนเขียนบรรทัดแรก**
  และต้องลง auth events ใน `audit_log` ไปพร้อมกัน (#43) ไม่ใช่ทำทีหลัง
* ยังไม่มีใครตอบ: `tenants.session_reset_at` (ร้านเปิดตอนตี 4 ไหม) และเรื่องอายุ device token
  — ค้างอยู่ท้าย `adr/README.md` เหมือนเดิม
