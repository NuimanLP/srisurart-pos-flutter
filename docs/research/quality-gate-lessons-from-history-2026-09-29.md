# บทเรียน CI/CD & Quality Gate จากประวัติโปรเจกต์ (สำหรับพรีเซนต์วิชา DevOps)

**วันที่รวบรวม:** 2026-09-29 · **ขอบเขต:** งานเขียนใน repo (`docs/handoff_log/*`, `.github/workflows/*`, `CLAUDE.md`, `docs/Backend_design/07_CICD_DEPLOY.md`), `git log --all`, และ `gh issue/pr` — ไม่ได้ดูรายการ Actions run (มี agent อื่นทำ)
**หลักการ:** ทุกข้อเคลมมีที่มา (ไฟล์ / commit / PR / issue) · สิ่งที่ตรวจไม่ได้เขียนว่า "ไม่พบหลักฐาน" · สถานะ **ยังเปิด** เขียนตรง ๆ

> ธีมที่ซ้ำหลายเรื่อง: **gate ที่ "เขียว" แต่ไม่ได้พิสูจน์อะไร** (skipped job, test ที่ mock, deploy ที่ไม่ได้ deploy) ทีมเจอแล้วแก้ที่ตัว gate ไม่ใช่แค่แก้ผล

---

## สรุปตาราง

| # | เรื่อง | Stage | สถานะ |
|---|---|---|---|
| 1 | Required check + path filter → PR ฝั่งเดียว merge ไม่ได้ / false green | PR gate | แก้แล้ว (มีข้อสังเกต cancelled-run) |
| 2 | Release image ไม่เคยถูก push ตั้งแต่ #39 (job ถูก skip เงียบ) | Build/Release | แก้แล้ว |
| 3 | CVE gate: multer, Trivy 13 findings, ห้าม `.trivyignore` | Security scan | แก้แล้ว |
| 4 | Dependabot เปิด 4 PR ทันที (แดง 3 / เขียว 1) | Dependency mgmt | แก้ด้วยการปิด version updates |
| 5 | Compose image ไม่ pin digest (#401) | Supply chain | แก้แล้ว + test |
| 6 | Secret fallback สาธารณะ (#398, #410) + `audit_log` แก้ได้ (#399) | Security/config gate | แก้แล้ว |
| 7 | Pool deadlock (#162) | Integration test | แก้แล้ว + regression test |
| 8 | e2e flaky: Windows crash (#160) และ login rate-limit ตามลำดับรัน (#449) | Test reliability | #160 บรรเทา / #449 แก้ที่ไฟล์ |
| 9 | Test ที่เขียวแต่พิสูจน์ไม่ตรง AC (#383/#384, re-audit #196) | Test quality | แก้แล้ว |
| 10 | Web DB asset skew (#245) + LinkError (#266) + codegen-check | Build gate (Flutter) | แก้แล้ว มีช่องว่างที่ CI ไม่ครอบ |
| 11 | Deploy เขียวแต่ไม่ได้ deploy + `.env` เปลี่ยนแล้วไม่ถูกใช้ (#506) | CD | แก้บางส่วน |
| 12 | Ansible: `--check` false positive, user คนละตัว, `.env` newline, bind-mount inode (#249) | CD verification | แก้/บันทึกเป็นกติกา |
| 13 | FortiGate ตัด TLS ของ `ghcr.io` → CD ตาย | CD / network | **ยังเปิด** |
| 14 | Review-fix push หลัง merge ไม่เข้า main (#491/#492 → #494) + stacked PR `--delete-branch` | Process | แก้แล้ว / เป็นกติกา |
| 15 | GitHub Actions Node 20 deprecation (#504) | Pipeline maintenance | แก้แล้ว (บางส่วนยังพิสูจน์ไม่ได้) |

---

## 1. Required check + path filter — PR ฝั่งเดียว merge ไม่ได้ (#39)

- **ปัญหา/ความเสี่ยง:** `flutter.yml` เดิมใช้ `paths-ignore` ทำให้ PR ที่แตะแต่ `server/**` ไม่รัน Flutter job เลย ถ้า job นั้นเป็น required check จะ merge ไม่ได้ตลอดกาล — issue #39 เรียกว่า "The trap" (`gh issue view 39`).
- **Root cause / สิ่งที่ทำ:** ย้าย path filter จาก trigger เข้าไปเป็น job `changes` (`dorny/paths-filter`) ภายใน workflow, และมี job ปิดท้าย `flutter-ci-status` / `server-ci-status` ที่รายงานทุก PR — เป็น required check ตัวเดียวของแต่ละฝั่ง (commit `bb4d6dc`, `.github/workflows/flutter.yml` หัวไฟล์, `CLAUDE.md` หัวข้อ CI/CD).
- **แต่ระหว่างทางมี bug จริง 2 ชั้น** (commit `ab81b73` — review ของ PR เอง เจอ 2 BLOCKER + อื่น ๆ):
  1. บน push `changes` ถูก skip → job ที่ `needs: [changes]` โดนคาสเคดให้ skip หมด (implicit `success()`) แก้ด้วย `!cancelled() &&` ในทุก `if:`
  2. status job ไม่ได้ดู `changes` → `changes` พัง = ทุก job skip = status เห็นแต่ "skipped" = **false green**; แก้โดยใส่ `changes` ใน `needs` และในลูปตรวจผล
  3. `paths-filter` บน PR ต้อง `pull-requests: read`; status job ใช้ `always()` แทน `!cancelled()` เพราะ skipped required check ถูก GitHub นับเป็นผ่าน
  - ต่อมา commit `3b179ac`: status job ไม่มี checkout แต่ `working-directory` ระดับ workflow ชี้ `frontend/` `server/` ที่ไม่มี → **ทั้งสอง check ล้มทุก PR**
- **Prevention/proof:** loop ใน `server-ci-status` (`server.yml` ~บรรทัด 338-357) ล้มเมื่อผลใด ๆ ไม่ใช่ success/skipped; concurrency group ผูกกับ SHA บน main กัน run ถูกแทนที่.
- **สถานะ:** แก้แล้ว. **ข้อสังเกตตรง ๆ:** commit `ab81b73` เขียนเองว่า "ยังต้องยืนยันด้วย cancelled-run จริงบน GitHub" — ผมไม่พบบันทึกว่ายืนยันแล้ว.

## 2. Release image ไม่เคยถูก push ตั้งแต่ #39 — job ถูก skip เงียบ ๆ

- **ปัญหา:** `build-image`/`build-web` ใช้ `if:` เปล่า → implicit `success()` ต้องการให้ ancestor สำเร็จด้วย แต่ `changes` ถูก skip บนทุก push → **ทั้งสอง job ถูก skip ทุก push บน main**; GHCR มีแค่ tag `main` เก่า. ถูกจับได้ตอน deploy จริงครั้งแรก (#184) เพราะหา image ไม่เจอ (commit `66aed92`).
- **Fix:** ตรวจ `needs.<job>.result == 'success'` ทีละตัวแบบ explicit (`server.yml` บรรทัด ~229-236, `flutter.yml` ~178-184) และ **ให้ status job ล้มถ้า image job ไม่ทำงานบน main push** (`server.yml` ~บรรทัด 352-357 ที่อ้างถึง #39/#184 ในคอมเมนต์).
- **Commit เดียวกันแก้อีก 2 อย่างที่เจอตอน provision ครั้งแรก:** `arch=x86_64` ใน apt source (ต้องเป็น `amd64`), และ callback `yaml` ถูกลบจาก `community.general` ใน `ansible.cfg`.
- **สถานะ:** แก้แล้ว — และเป็นตัวอย่างว่า "เขียวเพราะไม่ได้รัน" ถูกดักโดยกฎในตัว gate เอง

## 3. CVE gate: multer, Trivy image, และกฎ "ห้าม `.trivyignore`"

- **ปัญหา:** เดิมไม่มีการสแกน CVE เลย (`docs/handoff_log/security-review-jwt-audit-cve.md` §1 — ไม่มีคำว่า CVE/OWASP ใน docs/workflows/issues). เพิ่ม job `audit` (`pnpm audit --audit-level=high` + Trivy fs) และ `deps-audit` (OSV-Scanner บน `pubspec.lock`) ใน commit `419a4e2`.
- **เจอจริงวันแรก:** `pnpm audit` เจอ 3 high + 1 low ทั้งหมดคือ `multer 2.2.0` ที่มากับ `@nestjs/platform-express` (GHSA-535w-7cp7-47q4 ฯลฯ); `pnpm update` ไม่ช่วยเพราะ upstream pin → แก้ด้วย `pnpm.overrides.multer >= 2.3.0` ใน `server/package.json` (handoff §D).
- **Trivy image gate (`1fb0363`, PR #70/#61):** base `node:22-alpine` มี **13 fixable HIGH/CRITICAL** (2 alpine libssl3/libcrypto3 + 11 จาก npm ที่ bundle มา). แก้โดย pin digest, `apk upgrade`, ลบ npm/npx/corepack ก่อน `USER node` → 0 findings (ตรวจบน arm64 และ amd64 ในเครื่อง). Trivy อยู่หน้า step push จึง **image ที่มี CVE ไม่ถึง registry**.
- **กฎที่ผูกไว้:** ADR-0013 ห้าม `.trivyignore` — แก้โดยเปลี่ยน digest ของ base ใน `server/Dockerfile` เท่านั้น (คอมเมนต์ใน `server.yml` ~บรรทัด 289-292; `CLAUDE.md` "Base image digests are pinned and bumped by hand, never suppressed").
- **หมายเหตุ scope:** `ignore-unfixed: true` ใน trivy step (`server.yml` ~123, 298) = CVE ที่ยังไม่มี patch ไม่บล็อก — เป็นการเลือกนโยบาย ไม่ใช่การซ่อน.
- **สถานะ:** แก้แล้ว

## 4. Dependabot เปิด 4 PR ภายในไม่กี่นาที (แดง 3 ตัว เขียว 1 ตัว)

- **ปัญหา:** `dependabot.yml` แรกตั้ง version update รายสัปดาห์ (`patterns: ['*']`) โดยไม่มีใครขอ → เปิด PR #45–#48 ทันที: Node `22→26` (CI เขียว แต่ข้าม 4 major), Actions 3 ตัว (แดง `build web artifact`), server dev-deps (แดง `integration`), Flutter deps 7 ตัว (แดง `analyze + test`, `codegen`, `build web`) (handoff `security-review-jwt-audit-cve.md` §3).
- **Fix:** commit `ed98cd5` ปิด PR ทั้งหมด + ลบ branch; ตั้ง `open-pull-requests-limit: 0` ทุก ecosystem = ปิด version update เหลือ security update (`.github/dependabot.yml` บรรทัด 3, 25, 32).
- **บทเรียน (บันทึกเอง):** gate ที่ต้องการคือ **job ใน CI ที่ทำให้ build แดงได้** (`audit`/`deps-audit`) ไม่ใช่บอทที่เปิด PR. ข้อดีเชิงหลักฐาน: 3 ใน 4 PR ทำให้ CI แดงจริง จึงเห็นว่า gate จับการอัปเกรดที่พังได้ (ส่วน #45 ข้าม major 4 เวอร์ชันแต่ CI ยังเขียว — gate ไม่จับ) — แต่ทีมเลือกไม่รับภาระคัดกรอง
- **สถานะ:** แก้ด้วยนโยบาย (routine bump เป็นการทำมือ ตาม `CLAUDE.md`)

## 5. Compose image ไม่ pin digest (#401)

- **ความเสี่ยง:** tag เช่น `nginx:1.29-alpine`, `postgres:16-alpine` ถูก re-push ได้ → CI build กับ VM build ไม่ตรงกัน ทั้งที่ Dockerfile pin แล้ว (commit `b6fa639`).
- **Fix:** pin ทุก external image ใน `server/docker-compose.yml` และ `deploy/compose/monitoring.yml` เป็น `name:tag@sha256:…`.
- **Proof:** `server/test/compose-image-pins.spec.ts` สแกนทั้งสองไฟล์และล้มถ้ามี image ที่ไม่ใช่ของเราไม่มี `@sha256:` — commit message ระบุว่า "confirmed red against the pre-fix files, green after".
- **สถานะ:** แก้แล้ว. **ข้อจำกัดที่บันทึกไว้:** digest ต้อง bump ด้วยมือ — commit `ca3dd20` แก้คอมเมนต์ว่า Dependabot ไม่ได้ bump digest ใน compose

## 6. Secret/config: fallback สาธารณะ, dev secret หลุด production, audit_log แก้ได้, CORS

| ใบ | ปัญหา | Fix (commit) | Proof |
|---|---|---|---|
| #398 | `config.ts` fallback `'dev-only-platform-secret'` เมื่อ `JWT_PLATFORM_SECRET` ว่าง → ปลอม platform-admin JWT ได้ | `6c4945d` ใช้ `required()` | แก้ config.spec.ts + e2e 3 ไฟล์ให้ตั้งค่าเอง (หากไม่ตั้ง test จะล้ม) |
| #410 | `.env.example` มีค่า `dev-only-*`; ลืมเปลี่ยน = boot ได้ = บั๊ก #398 ทางอื่น | `9972c23` refuse ตาม `NODE_ENV=production` → **พังเอง**: Dockerfile ตั้ง `NODE_ENV=production` ตลอด ทำ dev quickstart crash-loop → `0b5467c` เปลี่ยนเป็น gate ด้วย `ALLOW_DEV_SECRETS=true`, `vm.override.yml` บังคับว่างบน VM | unit/e2e config; ตามด้วย `2656963`/`30d105d` ครอบ password ใน connection URL |
| #399 | `pos_app` UPDATE/DELETE `audit_log` ได้ | `4aca476` migration REVOKE (ไม่แก้ migration เดิม) | `schema.e2e-spec.ts`: INSERT/SELECT ผ่าน, UPDATE/DELETE/TRUNCATE ได้ 42501 |
| #367 | `CORS_ORIGINS=","` truthy → split ได้ `[]` → fallback `['*']` เงียบ ๆ | `25e9429` `csvAllowlist()` throw ตอน boot | `config.spec.ts` 4 เคส + รันจริงใน container ได้ error ตามที่บันทึก |

- **สถานะ:** โค้ดแก้แล้วทั้งหมด. **ยังเปิด:** `CLAUDE.md` ระบุ `mob04` ยังเป็น `'*'` จนกว่า `DEMO_ENV_FILE` จะมีคีย์และรัน `provision.yml` ใหม่ — ห้ามอ้างว่า CORS ปิดแล้วบน VM (ไม่ได้ตรวจสถานะ VM ตอนนี้)

## 7. Pool deadlock ที่ concurrency สูง (#162)

- **ปัญหา:** `TenantRateLimitGuard` อ่าน `tenants.plan` ด้วย connection ที่สองจาก pool เดียวกันเมื่อ cache เย็น → burst ขนาด `DB_POOL_SIZE` แต่ละ request ถือ 1 connection แล้วรออีก 1 → ทุกตัวรอจนหมด `connectionTimeoutMillis`, บางตัว 500, ตัวที่ถืออยู่ fail-open เป็น `basic` (commit `476c631`).
- **วัดจริง (clean main, pool 8):** เปิดพร้อมกัน 10 → 8 lookup ล้มหลัง 10 000 ms + 500 สองตัว; 200 บิลพร้อมกัน → ได้แค่ 8 บิล.
- **Fix:** อ่าน plan บน request transaction ใน savepoint.
- **Proof:** `server/test/rate-limit-pool.e2e-spec.ts` บังคับ burst ที่ pool 2 + cold cache — unfixed ได้ `200,200,500×10` ใน 5065 ms, fixed ได้ 200 ทั้งหมด.
- **Prevention เชิงสถาปัตยกรรม:** กฎใน `CLAUDE.md` "No component may take a second pool connection inside one request" และ spec 3 ตัวที่ gate seam (`tenant-door.spec.ts`, `tenant-wrapper.spec.ts`, `idempotency-routes.spec.ts`).
- **หมายเหตุตรง ๆ:** test เดิม (`shifts.e2e-spec.ts` › *ten simultaneous opens*) ล้มบนเครื่อง dev แต่ **CI ผ่าน** (issue #162 ระบุ "CI passes") — gate ใน CI จึงไม่จับบั๊กนี้; และมันถูกวินิจฉัยผิดเป็น pool limit ของ tx.\* จนมีการ "วัด" บน clean main (commit message: "filed as a local pool limit … neither is")
- **สถานะ:** แก้แล้ว

## 8. e2e ไม่เสถียร — สองสาเหตุที่ต่างกัน

**8a. Windows crash (#160):** "Worker exited unexpectedly" 0xC0000409 = stack-cookie overwrite ใน libuv ที่ bundle กับ Node (`RtlGetVersion` ด้วย struct ไม่ initialise). Node 24.15.0 ล้ม 5/9 รอบ, Node 24.21.0 ล้ม 0/8; แก้ใน upstream libuv `aabb765` (libuv#5107, มากับ Node 24.16.0 / 26.1.0); commit `ab98acb` ใน repo นี้คือ commit ที่ trace สาเหตุ + เพิ่ม warning เท่านั้น. **CI (Linux) ไม่ได้รับผลกระทบ** (ไม่คอมไพล์ `src/win`). สิ่งที่ repo ทำ = `globalSetup` เตือนเมื่อเป็น Node/Windows ที่ได้รับผลกระทบ (`server/test/support/windows-node-check.ts`) + บันทึกหลักฐานใน `server/README.md` → เป็น **บรรเทา ไม่ใช่แก้**

**8b. Rate limit ตามลำดับรัน (#449 — เป็นหมายเลข PR ของ platform-ui ไม่ใช่ issue; commit แก้อยู่ใน branch เดียวกับ PR #448/#449):** ไฟล์ e2e login 13 ครั้งจาก IP เดียว แต่ limit 10/60 วิ ต่อ IP และ Redis bucket แชร์กับทุกไฟล์ → CI ได้ 429 ขึ้นกับลำดับรัน (commit `7a1f991`). Fix: ให้แต่ละไฟล์ส่ง `X-Forwarded-For` ของตัวเอง (แบบเดียวกับ `devices.e2e-spec.ts`). กติกาบันทึกใน `CLAUDE.md`. **ไม่พบ automated guard** ที่บังคับกติกานี้ — เป็นข้อตกลงในเอกสารเท่านั้น

## 9. Test ที่เขียวแต่ไม่ได้พิสูจน์สิ่งที่ AC ระบุ (#383, #384, #196)

- **ปัญหา:** DoD 17 ช่องใน `03_ARCHITECTURE.md §8` ถูกติ๊กจากใบที่ปิดด้วยมือ; re-audit เทียบกับ diff ของ PR (commit `9b8d212`) พบ 2 ช่องที่หลักฐานไม่ตรง:
  - redis-cache outage: test เดิม `vi.spyOn` เมธอดของ cache client และยิง `/tx4-probe` — ไม่ใช่ Redis ที่เข้าไม่ถึงจริง และไม่ใช่ `GET /products` + `POST /sales` ที่ AC ระบุ
  - retire/enrol: test มินต์ `accessToken` เอง (`shifts.e2e-spec.ts:575`) ไม่ผ่าน `POST /auth/device`
- **Fix:** `290ba86` (#383) — `redis-cache-outage.e2e-spec.ts` ทำ outage จริง 2 แบบ (connection refused; เชื่อมต่อแล้วเงียบ = เคส #140 ที่ mock reject ไม่มีทางครอบ) ยืนยัน 200 / 201 + stock 10→9 และ tenant suspended ถูกปฏิเสธทันที; `0cd7eb6` (#384) แลก enrolCode จริง เช็คใช้ซ้ำแล้ว 401.
- **Proof แบบ mutation:** ทั้งสอง commit ระบุว่า "Falsified by …" — ตัด fail-open catch / ทำ enrol code พัง แล้วยืนยันว่า test แดงก่อน revert
- **ผลข้างเคียง:** DoD จาก 17 ติ๊ก 16 เหลือ 1 (k6, #380) — `CLAUDE.md`
- **สถานะ:** แก้แล้ว; **ยังเปิด:** ช่อง k6 (#380) ยังไม่มีตัวเลขวัดจริง

## 10. Flutter web: asset skew (#245), LinkError (#266), และ codegen-check

- **codegen-check (ออกแบบ 2026-09-04, `grill-round2-ci.md`):** repo อาจอยู่บน path ภาษาไทยที่ `build_runner` รันไม่ได้ จึง commit `*.g.dart` ไว้; CI เป็น ASCII path จึงเป็น "ที่เดียวที่โค้ดที่ generate ถูกตรวจกับ schema" (`flutter.yml` job `codegen-check` บรรทัด ~140-152).
- **Skew (#245, `64d663a`):** `pubspec.lock` ได้ `sqlite3=3.4.0`/`drift=2.34.1` แต่ `web/sqlite3.wasm` + `drift_worker.js` ที่ commit เป็นของ 3.3.3/2.34.0 (sha256 เหมือนกัน) — skew จริงที่เปลี่ยนพฤติกรรม SQLite/worker (ไม่มี build error). Fix: แทนไฟล์ด้วย release asset ที่ตรงเวอร์ชัน + `frontend/web/WEB_DB_ASSET_VERSIONS.txt` + step ใน `flutter.yml` (~บรรทัด 86-111) ที่ **fail build เมื่อ lock กับไฟล์เวอร์ชันไม่ตรง**
- **LinkError (#266, PR #310, `docs/handoff_log/ticket-266-web-db-linkerror.md`):** เบราว์เซอร์ที่ไม่มี `dedicatedWorkersInSharedWorkers` → `sqlite3.wasm` ต้องการ import `dart.xFileControl` แต่ worker ของ drift 2.34.1 ไม่มี → `LinkError` DB ไม่ขึ้น. เจอตอน boot จริงหลังแก้ skew (ไม่ใช่จาก CI). Fix = เติม stub คืน `12` (SQLITE_NOTFOUND) ใน `drift_worker.js`; ทดสอบ instantiate wasm ก่อน/หลัง (ล้มด้วย error ตรงเป๊ะ → ผ่าน 86 exports).
- **ช่องว่างที่ต้องบอกอาจารย์ตรง ๆ:** ผมไม่พบ check ใน CI/test ที่ตรวจ `xFileControl` — CI ตรวจแค่เวอร์ชัน. patch คือการแก้มือในไฟล์ minified ที่ vendor มา; ถ้าอัปเกรด drift แล้วดาวน์โหลด asset ใหม่ patch อาจหาย (กฎใน `CLAUDE.md` บอกให้ re-download ทั้งคู่เมื่อ bump) และ CI จะไม่จับ
- **สถานะ:** issue #266 ปิดแล้ว (`CLAUDE.md`, verified 2026-09-19) แต่ความเสี่ยงข้างต้นยังไม่มี gate

## 11. Deploy เขียวแต่ไม่ได้ deploy + `.env` เปลี่ยนแล้วไม่เข้า container

- **Green ที่โกหก:** job `deploy` มีเงื่อนไข `needs.resolve.outputs.images_ready == 'true'` (`.github/workflows/deploy.yml` ~บรรทัด 138-145) — ถ้า image ของ SHA นั้นยังไม่อยู่ใน GHCR job ถูก skip และ workflow รายงาน success (เพราะมีแค่ `resolve release` รัน) — `CLAUDE.md` บันทึกว่า **`/opt/pos/.current_sha` บน VM เป็นหลักฐานเดียวว่า deploy จริง**. Design ตั้งใจให้ผลนี้ "ไม่ใช่ error" สำหรับ workflow_run ตัวแรกจากสองตัว (`deploy.yml` ~123-126) แต่ออก exit 1 เมื่อ dispatch ด้วยมือ และ exit 2 (แดง) เมื่อถาม GHCR ไม่ได้ เพื่อไม่ให้ outage ดูเป็น "ยังไม่พร้อม".
- **`.env` เปลี่ยนแล้วไม่ถูกใช้ (#506, `639238f`, merged 2026-09-29):** `provision.yml` เขียน `/opt/pos/.env` แต่ไม่ restart; `deploy.yml` จบที่ duplicate-SHA exit เพราะ release นั้นขึ้นอยู่แล้ว → `PLATFORM_ADMINS`/`CORS_ORIGINS` ใหม่ไม่ถึง container. Fix: บันทึก sha256 ของ `.env` ที่ deploy สำเร็จใน `/opt/pos/.env_applied_sha256` (เขียนหลัง readiness เหมือน `.current_sha`), ถ้าเปลี่ยนก็ไม่ออกทาง duplicate-SHA; `provision.yml` assert ว่า `DEMO_ENV_FILE` มีทุกคีย์ `${KEY:?}`, เตือนเมื่อไม่มี `PLATFORM_ADMINS`, `no_log`+`diff: false` กัน secret รั่ว.
- **สถานะ:** โค้ด merged แต่ **PR body ระบุ "Not verified":** เครื่องที่เขียนไม่มี `ansible-playbook` ผ่านแค่ YAML parse — ยังไม่เคยรันจริงบน mob04 (`gh pr view 506` — #506 เป็นหมายเลข PR). อีกทั้งกฎ "deploy ที่เขียวไม่ใช่หลักฐาน" ยังใช้เมื่อ VM ยังไม่เคยได้รับ deploy (เรื่อง 13)

## 12. บทเรียนการ verify การ deploy (Ansible)

- **`--check` false positive:** `ansible.builtin.command` ไม่มี check mode ถูก skip → `pos_network.stdout` ว่าง → pre-flight assert ล้มทั้งที่ network จริงถูกต้อง; ไปไม่ถึง task หลัง `command` ตัวแรก ⇒ ห้ามอ้างผล `--check` เป็นหลักฐาน (`handoff_demo-335-merge-and-cd-blocked_21_09_2026.md` §4.6). และ `--check` ยังซ่อนความต่าง user: `deploy.yml` รันเป็น `deploy` (ไม่มี sudo), `provision.yml` เป็น `cloud` — เพราะ `copy` เทียบ checksum ไม่เขียนไฟล์ (§3.3 และบรรทัด ~180 ของไฟล์เดียวกัน)
- **`.env` ไม่มี newline ท้ายไฟล์:** `grep -c KEY` นับบรรทัดที่ "มีคำ" → ดูเหมือนมี 2 แต่ `grep -c ^KEY=` ได้ 0 เพราะคีย์แรกถูกต่อท้ายค่าก่อนหน้า; compose ยัง fail. กติกา: anchor ด้วย `^` และ append บรรทัดว่างนำ (§4.5). ต่อมา `0307a23` ทำให้ `provision.yml` เขียน `.env` พร้อม newline ท้าย
- **Bind mount inode (#249, `d872c0a`):** `ansible.copy` เขียน temp แล้ว rename → inode ใหม่ แต่ container ที่รันอยู่ยึด inode เก่า → `up -d --no-deps` no-op และ `nginx -s reload` ก็ไม่ช่วย. **Reproduce ได้เฉพาะบน Linux bind mount จริง (docker:27-dind)** — Docker Desktop บน Windows ไม่ reproduce (จึงซ่อนบั๊กนี้ได้). Fix: `--force-recreate` nginx ทุก deploy
- **Monitoring recovery (#148, `74d3435`):** gate "recreate เมื่อไฟล์เปลี่ยนใน run นี้" ทำให้ config change หายถาวรถ้า run ที่คัดลอกล้มทีหลัง → recreate ทุกครั้ง; และ commit message ระบุตรง ๆ ว่า "Untested on the VM"
- **สถานะ:** เป็นกติกาใน `CLAUDE.md` แล้วทั้งหมด; ส่วนที่ต้อง verify บน VM จริงยังรอ (เรื่อง 13)

## 13. FortiGate ตัด TLS ของ `ghcr.io` — CD ตาย (ยังเปิด)

- **อาการ:** `docker compose pull` บน `mob04` ล้ม `x509: certificate is not valid for any names, but wanted to match ghcr.io` (`handoff_demo-335-merge-and-cd-blocked_21_09_2026.md` §4.7).
- **Root cause (วินิจฉัยด้วย `openssl s_client` จาก VM):** ใบที่ตอบแทน ghcr.io คือใบประจำเครื่อง FortiGate (`O=Fortinet, OU=FortiGate, CN=FG3K4ETB19900078`) ที่ **ไม่มี SAN เลย**; DNS ยังชี้ IP จริงของ GitHub → เป็น SSL deep inspection ของ firewall คณะ ไม่ใช่บั๊กใน repo. trust CA ของ Fortinet **ไม่ช่วย** เพราะ hostname verification ล้มอยู่ดี.
- **ผลกระทบ:** ตายทั้งเส้นทาง manual Ansible (D9) และ self-hosted runner (#67) เพราะใช้ Docker daemon เดียวกัน.
- **Fix ที่ทำได้ใน repo:** ไม่มี. ทางแก้จริง = ฝ่ายเครือข่ายยกเว้น `ghcr.io`, `registry-1.docker.io`, `gcr.io` สำหรับ `172.30.58.20` (`07_CICD_DEPLOY.md` แถวตาราง ~บรรทัด 497). `docker save/load` = ทางกู้วันเดโม "ห้ามบันทึกว่าเป็น CD"
- **สิ่งที่ pipeline ทำได้ดี:** pre-flight ผ่าน (`ansible ping`, network assertion, `verify-ghcr-tags.sh` ได้ HTTP 200 ทั้งสอง image) และ `deploy` job ถูกกั้นด้วย required reviewer บน environment `demo` (#366, `4cc276c`) — ตัดสินใจโดยเจ้าของ 2026-09-21
- **สถานะ:** **ยังเปิด** — `CLAUDE.md`/`07_CICD_DEPLOY.md` ยืนยัน (2026-09-23) ว่ายังไม่เคย deploy ถึง VM และ #67 เคยถูกปิดทั้งที่ runner ไม่ได้ติดตั้ง (ปิด 2026-09-20 โดย commit ไม่มี PR) — **ตรวจซ้ำ 2026-09-29: #67 ถูก reopen แล้ว (OPEN, reopen 2026-09-26), runner = 0 ตัว, `deployment_branch_policy` ของ `demo` = `null`, required reviewer = NuimanLP; run `Deploy (demo)` ของ `639238f` และ `c8383a7` ยังค้าง `waiting`/`pending`** (ไม่ได้ตรวจสถานะเครื่อง VM เอง)

## 14. กระบวนการ: review-fix หลัง merge ไม่เข้า main, และ stacked PR

- **#491/#492 → #494:** commit `dbaa7e5` (ให้ `/sync/push` replay เขียนเลขเอกสารกลับ local counter) ถูก push เข้า branch **หลัง** PR #491/#492 ถูก merge จึงไม่เคยถึง `main`. เดิมมีการสรุปผิดว่า "ไม่เคยเขียนโค้ดนี้" (จาก grep) — `e4483b5` แก้ความเข้าใจนั้น. Cherry-pick เข้า PR #494 ซึ่ง **test replay ล้มเมื่อไม่มี commit นี้**. บทเรียน: เช็ค `gh pr view N --json headRefOid` ตอน merge.
  - **อัปเดตจากการตรวจวันนี้:** `gh pr view 494` → `state: MERGED`, `mergedAt 2026-09-28T03:08:02Z` — ดังนั้นข้อความใน `CLAUDE.md` ที่ว่า #494 "open, not merged" **ล้าสมัยแล้ว** (ข้อเท็จจริงเดียวกับที่บทเรียนเตือน)
- **Stacked PR + `--delete-branch`:** `gh pr merge 349 --delete-branch` ลบ base ของ #350 → GitHub ปิด #350 ชั่วคราวและเปลี่ยน base ของ PR ที่ปิดแล้วไม่ได้ (หลังกู้ #350 merge สำเร็จ 2026-09-21); กู้ด้วย push tip เดิม → `gh pr reopen` → `gh pr edit --base main` (handoff §4.1). และ #447 ถูก merge เข้า branch ของ PR ก่อนหน้าที่ merge ไปแล้ว → ถึง main เพราะ #448 บังเอิญมีมัน (`CLAUDE.md`)
- **อีกเรื่องที่ใกล้กัน:** สคริปต์รวม conflict เขียนไฟล์ด้วย Python text mode บน Windows → CRLF ทั้งไฟล์ conflict ตั้งแต่บรรทัด 1 ทุก branch; แก้ด้วย PR #368 (handoff §4.2)
- **สถานะ:** เป็นกติกาในเอกสาร ไม่ได้ถูก gate อัตโนมัติ (ไม่พบ check ที่บังคับ)

## 15. GitHub Actions Node 20 deprecation (#504)

- **ปัญหา:** GitHub บังคับ action ที่ใช้ Node 20 ไปรันบน Node 24 และเตือนทุก run (commit `ebca7c9`, merged ผ่าน PR #504).
- **Fix:** ตรวจ `action.yml` ของแต่ละ action ว่าประกาศ `node24` แล้วค่อยขยับ major ต่ำสุดที่ใช่: `checkout v4→v5`, `setup-node v4→v5`, `upload-artifact v4→v6` (v5 ยัง default node20), `docker/login-action v3→v4`. ระบุว่า action ที่เป็น composite/docker ไม่ต้องแก้.
- **ผลข้างเคียงที่ตรวจพบ:** major ใหม่ต้องการ Actions Runner ≥ 2.327.1 → ขยับ default ใน `deploy/scripts/setup-mob04-runner.sh` 2.322.0 → 2.337.0 (ตรวจ URL tarball = 200).
- **สถานะ:** แก้แล้ว. **ที่พิสูจน์ไม่ได้:** ยังไม่มี self-hosted runner ติดตั้ง (#67) จึงไม่เคยลองรัน runner เวอร์ชันใหม่จริง; `deploy.yml` มี action เดียวที่รันบน `ubuntu-latest`

---

## เรื่องออกแบบที่จับได้ก่อนเขียนโค้ด (ใส่สไลด์เสริมได้)

- **Nginx `location /platform/` ไม่เคยถูกใช้จริง** เพราะ prefix ของแอปคือ `api/v1` → allowlist ของ admin plane ไม่เคยทำงาน; เจอตอน scrutinize design (`cicd-design-grill.md`), แก้ใน #62/#69, ต่อด้วย #270 (PR #308) และ job `nginx-check` (`server.yml` ~145-175).
- **CI ทดสอบก่อนเขียน:** grill-round2 ระบุว่าทุก check ใน `flutter.yml` แรกถูกรันในเครื่องก่อน commit (123/123 tests, `dart analyze --fatal-infos` สะอาด) — `docs/handoff_log/grill-round2-ci.md`.

## แหล่งอ้างอิง

- Workflows: `.github/workflows/flutter.yml`, `server.yml`, `deploy.yml`; `.github/dependabot.yml`
- Handoff: `docs/handoff_log/grill-round2-ci.md`, `cicd-design-grill.md`, `security-review-jwt-audit-cve.md`, `ticket-266-web-db-linkerror.md`, `handoff_demo-335-merge-and-cd-blocked_21_09_2026.md`
- Docs: `CLAUDE.md`, `docs/Backend_design/07_CICD_DEPLOY.md`
- Commits: `bb4d6dc`, `ab81b73`, `3b179ac`, `66aed92`, `419a4e2`, `ed98cd5`, `1fb0363`, `b6fa639`, `6c4945d`, `9972c23`, `0b5467c`, `4aca476`, `25e9429`, `476c631`, `ab98acb`, `7a1f991`, `9b8d212`, `290ba86`, `0cd7eb6`, `64d663a`, `4cc276c`, `639238f`, `d872c0a`, `74d3435`, `0307a23`, `e4483b5`, `ebca7c9`
- Issues: #39, #162, #160, #245, #266, #249, #367, #383, #384, #398, #399, #401, #410, #366, #67; PRs: #45–#48, #70, #306, #310, #349/#350, #368, #447/#448/#449, #491/#492/#494, #504, #506 (ตรวจด้วย `gh issue view` / `gh pr view` เมื่อ 2026-09-29)
- Tests ที่ยืนยันว่ามีไฟล์อยู่: `server/test/rate-limit-pool.e2e-spec.ts`, `compose-image-pins.spec.ts`, `redis-cache-outage.e2e-spec.ts`, `schema.e2e-spec.ts`, `server/src/config/config.spec.ts`, `server/test/support/windows-node-check.ts`
- **ข้อจำกัดของเอกสารนี้:** ไม่ได้เปิดดูรายการ Actions run; ไม่ได้เข้าตรวจเครื่อง VM (สถานะ runner/environment ตรวจซ้ำด้วย `gh api` เมื่อ 2026-09-29; ส่วน VM อ้างตาม `CLAUDE.md` ณ 2026-09-23); ตัวเลข commit ที่ไม่ได้เปิดอ่าน message ตรง ๆ (`ca3dd20`, `2656963`, `30d105d`) อ้างเฉพาะ subject line

---

## Fact-check 2026-09-29

ตรวจทุก SHA (31), PR/issue (~45), ไฟล์/test ที่อ้าง และสถานะ ณ วันนี้ ด้วย `git show`, `gh issue/pr view`, `gh api`. ผล: **ยืนยันตรงเกือบทั้งหมด, แก้ 9 จุด, ตรวจไม่ได้ 3 จุด**

**แก้แล้ว**
1. เรื่อง 5: SHA `ca4aca4` **ไม่มีอยู่จริง** → commit ที่ถูกคือ `ca3dd20` (แก้ทั้งเนื้อหาและข้อจำกัดท้ายเอกสาร)
2. เรื่อง 4: เดิมเขียนว่า 4 PR "แดง" — จริงคือ #45 (Node 22→26) **CI เขียว** แดง 3 ตัว (#46–#48) (ตาม handoff `security-review-jwt-audit-cve.md` §3)
3. เรื่อง 8a: `ab98acb` ไม่ใช่ commit แก้ upstream — เป็น commit ใน repo นี้; upstream fix คือ libuv `aabb765` (libuv#5107)
4. เรื่อง 8b: #449 เป็นหมายเลข **PR** (platform-ui) ไม่ใช่ issue
5. เรื่อง 11: #506 เป็น **PR** ไม่ใช่ issue (`gh pr view 506`)
6. เรื่อง 13: "#67 ปิดไปแล้ว" **ล้าสมัย** — #67 ถูก reopen 2026-09-26 (OPEN); ตรวจซ้ำวันนี้ runner = 0, `demo` branch policy = null, deploy run ค้าง waiting
7. เรื่อง 7: เดิมเขียนว่าบั๊กไม่ถูกจับโดย test ที่มี — จริง ๆ test เดิมล้มบนเครื่อง dev แต่ **CI ผ่าน** (issue #162) จึงไม่ถูก gate จับ; ปรับถ้อยคำ
8. เรื่อง 14: ระบุว่า #350 ถูกปิดชั่วคราวแล้วกู้ merge ได้ (gh แสดง MERGED)
9. รายการอ้างอิงท้ายเอกสาร: แยก Issues / PRs ให้ถูกชนิด

**ตรวจไม่ได้ / ไม่ยืนยัน**
- การยืนยัน cancelled-run จริงบน GitHub (เรื่อง 1) — ไม่พบบันทึก (เอกสารบอกไว้แล้ว)
- สถานะเครื่อง VM `mob04` (CORS ยังเป็น `'*'`, deploy ถึง VM หรือไม่) — ไม่มีสิทธิ์เข้าเครื่อง
- ข้ออ้าง "ไม่พบ automated guard" (เรื่อง 8b, 14) — พิสูจน์ปฏิเสธไม่ได้ ยืนยันได้เพียงว่าไม่พบ; ส่วน "ไม่มี check `xFileControl` ใน CI" ค้น `.github`/`frontend/test` แล้วไม่พบจริง

**ยืนยันแล้วเป็นพิเศษ:** DoD 03 §8 = 16 ติ๊ก / 1 เปิด (k6, #380 OPEN); #266/#160/#162/#245/#249/#367/#383/#384/#398/#399/#401/#410/#366/#148/#184 ปิดแล้ว; #494 MERGED 2026-09-28 (`dbaa7e5` ไม่ได้อยู่ใน #491); #504/#506 MERGED; `dependabot.yml` `open-pull-requests-limit: 0`; test ทุกไฟล์ที่อ้างมีอยู่จริง
