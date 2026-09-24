# คู่มือการ Test ของ Srisurart POS (ฉบับเข้าใจง่าย)

> คู่มือนี้อธิบายว่าโปรเจกต์มี test อะไรบ้าง แต่ละตัวตรวจอะไร มีไว้ทำไม
> สั่งรันเองได้อย่างไร และดูผลได้ที่ไหน
> ตัวเลขตัวอย่างทั้งหมดมาจากรันจริงบน `main` วันที่ 23 ก.ย. 2026 (commit `616c187`)

---

## 0. ภาพรวม: test มี 3 ระดับ

ให้นึกภาพร้านซ่อมรถที่ต้องตรวจรถก่อนส่งคืนลูกค้า

| ระดับ | เปรียบเทียบ | ในโปรเจกต์นี้คือ |
|---|---|---|
| **1. ตรวจโค้ด** (ไม่ต้องรันโปรแกรม) | ดูด้วยตาว่าน็อตครบไหม มีรอยรั่วไหม | lint, typecheck, dart analyze, สแกนช่องโหว่, nginx -t, codegen check |
| **2. ทดสอบการทำงาน** (รันโปรแกรมจริง) | สตาร์ทเครื่อง ลองขับรอบลาน | unit test, integration test, flutter test, smoke test ของ image |
| **3. วัดความเร็ว** (performance) | เอาไปวิ่งบนถนนจริง จับเวลา | k6 load test |

ระดับ 1 กับ 2 **รันอัตโนมัติทุกครั้งที่ push หรือเปิด PR** ผ่าน GitHub Actions (เรียกว่า **CI**)
ระดับ 3 ต้อง**สั่งรันเอง** เพราะต้องมี server จริงให้ยิงใส่

### ตารางสรุป test ทั้งหมด

| # | Test | ฝั่ง | ตรวจอะไรโดยย่อ | ใช้เวลาบน CI | ผลล่าสุด |
|---|---|---|---|---|---|
| 1 | lint + typecheck | server | เขียนโค้ดถูกหลัก ไม่มี type ผิด | 14 วิ | 0 warnings, 0 errors |
| 2 | audit | server | library ที่ใช้มีช่องโหว่ไหม | 25 วิ | 0 ช่องโหว่ |
| 3 | unit | server | ฟังก์ชันย่อยๆ คำนวณถูกไหม | 20 วิ | 412 ผ่าน |
| 4 | nginx check | server | ไฟล์ตั้งค่า nginx เขียนถูกไหม | 9 วิ | syntax ok |
| 5 | integration | server | ระบบทั้งก้อนทำงานกับฐานข้อมูลจริงได้ไหม | 3 นาที 15 วิ | 607 ผ่าน, 2 ข้าม |
| 6 | image smoke + Trivy | server | Docker image สร้างถูกและปลอดภัยไหม | 1 นาที 1 วิ | 0 HIGH/CRITICAL |
| 7 | dart analyze | Flutter | โค้ด Dart ถูกหลักไหม | (อยู่ใน job เดียวกับ 8) | No issues found |
| 8 | flutter test | Flutter | หน้าจอ/logic ฝั่งแอปทำงานถูกไหม | 1 นาที 44 วิ (รวม 7) | 533 ผ่าน |
| 9 | OSV-Scanner | Flutter | package ของ Flutter มีช่องโหว่ไหม | 13 วิ | No issues found |
| 10 | codegen check | Flutter | โค้ดที่ generate อัตโนมัติตรงกับที่ commit ไหม | 1 นาที 28 วิ | ไม่มี diff |
| 11 | build web + smoke | Flutter | build เว็บได้และไฟล์ครบไหม | 1 นาที 29 วิ | Built build/web |
| 12 | k6 (4 scenario) | server | ระบบเร็วพอไหมเมื่อคนใช้เยอะ | สั่งรันเอง | **ยังไม่ได้วัดจริง** |

---

## 1. เตรียมเครื่องก่อนรัน

| เครื่องมือ | ใช้กับ | ติดตั้ง (macOS) |
|---|---|---|
| Node.js 22 + pnpm | test ฝั่ง server | `brew install node@22` แล้ว `corepack enable` |
| Docker Desktop | integration, nginx check, image | ดาวน์โหลดจาก docker.com |
| Flutter 3.44.3 | test ฝั่ง Flutter | ดูเวอร์ชันใน `frontend/.fvmrc` |
| Trivy (ถ้าจะสแกนเอง) | audit, image | `brew install trivy` |
| OSV-Scanner (ถ้าจะสแกนเอง) | Flutter audit | `brew install osv-scanner` |
| k6 | performance | `brew install k6` |

ติดตั้ง dependency ครั้งแรก:

```bash
cd server && pnpm install --frozen-lockfile
```

```bash
cd frontend && flutter pub get
```

> ⚠️ **path ภาษาไทย:** `build_runner` กับ `flutter analyze` พังถ้าโฟลเดอร์ที่เก็บโปรเจกต์มีตัวอักษรที่ไม่ใช่ภาษาอังกฤษ
> ให้เก็บโปรเจกต์ไว้ใน path ภาษาอังกฤษล้วน เช่น `~/Downloads/srisurart-pos-flutter`

---

## 2. Test ฝั่ง Server (NestJS) — รันในโฟลเดอร์ `server/`

### 2.1 Lint + Typecheck — "ตรวจการสะกดของโค้ด"

- **คืออะไร:** `oxlint` อ่านโค้ดหารูปแบบที่มักเป็นบั๊ก เช่น ตัวแปรที่ประกาศแล้วไม่ใช้ ส่วน `tsc` ตรวจว่า type ถูกทุกจุด เช่น ส่งข้อความไปในที่ที่ต้องเป็นตัวเลข
- **เพื่ออะไร:** จับความผิดพลาดง่ายๆ ได้ในไม่กี่วินาที ก่อนต้องรอ test ตัวที่ช้ากว่า
- **คำสั่ง:**

```bash
pnpm lint && pnpm typecheck
```

- **ผ่านเมื่อเห็น:** `Found 0 warnings and 0 errors.` และ `tsc` ไม่พิมพ์ error ใดๆ
- **ถ้าแดง:** ข้อความจะบอกชื่อไฟล์และบรรทัด ให้แก้ตามนั้น

### 2.2 Unit test — "ทดสอบชิ้นส่วนทีละชิ้น"

- **คืออะไร:** test เล็กๆ ที่เรียกฟังก์ชันหรือ class ทีละตัว โดยไม่ต้องมีฐานข้อมูล ไฟล์ลงท้ายด้วย `*.spec.ts` อยู่ใน `server/src/` (เช่น `auth`, `idempotency`, `rate-limit`, `purchasing`)
- **เพื่ออะไร:** ยืนยันว่า logic ย่อยคำนวณถูก เช่น ตรวจรหัสผ่าน หรือคำนวณ retry backoff รันเร็วมาก จึงใช้รันบ่อยๆ ระหว่างเขียนโค้ดได้
- **คำสั่ง:**

```bash
pnpm test
```

  รันเฉพาะไฟล์ที่สนใจ:

```bash
pnpm vitest run src/auth
```

  ดูเวลาของแต่ละ test แยกกัน:

```bash
pnpm vitest run --reporter=verbose
```

- **ผ่านเมื่อเห็น:**
  ```
  Test Files  49 passed (49)
       Tests  412 passed (412)
    Duration  9.54s (transform 1.59s, setup 0ms, import 16.35s, tests 5.25s, environment 5ms)
  ```
  บรรทัด `Duration` แยกเวลาให้ดูว่าหมดไปกับอะไร `import` คือเวลาโหลดโค้ด ส่วน `tests` คือเวลารัน test จริง

> บรรทัด `WARN ... Password verification failed` ที่เห็นใน log เป็นเรื่องปกติ test จงใจส่ง hash ผิดรูปแบบเข้าไปเพื่อดูว่าระบบรับมือได้

### 2.3 Integration (e2e) test — "ประกอบรถทั้งคันแล้วลองขับ"

- **คืออะไร:** บูตแอปจริงทั้งตัว ต่อกับ **PostgreSQL และ Redis ตัวจริง** (ไม่ใช้ของปลอม) แล้วยิง HTTP request เหมือนผู้ใช้จริง มี 50 กว่าไฟล์ `*.e2e-spec.ts` ใน `server/test/` ครอบคลุมเรื่อง เช่น
  - การขาย การคืนของ รอบกะ (`sales`, `returns`, `shifts`)
  - **ความปลอดภัยข้ามร้าน**: ร้าน A ต้องมองไม่เห็นข้อมูลร้าน B (`tenant-isolation-sweep`, `cross-tenant-read`)
  - **แย่งกันแก้สต็อก**: ยิง 600 คำสั่งพร้อมกันจาก 3 ช่องทางที่เขียนสต็อก ต้องไม่มี error และยอดสต็อกต้องยังถูกต้อง (`stock-race-three-writers`)
  - **กดส่งบิลซ้ำ**: ต้องได้บิลเดียว (`idempotency`, `idempotency-money`)
  - Redis ล่มแล้วระบบต้องยังขายได้ (`redis-cache-outage`), rate limit, backup/restore, migration (`schema`)
- **เพื่ออะไร:** บั๊กจำนวนมากเกิดตรงรอยต่อระหว่างโค้ดกับฐานข้อมูล ซึ่ง unit test จับไม่ได้ แอปรันในสิทธิ์ `pos_app` ที่โดน Row Level Security บังคับ ถ้าข้อมูลรั่วข้ามร้าน test จะจับได้
- **คำสั่ง** (ทำตามลำดับเดียวกับ CI):

```bash
cp .env.example .env
```

```bash
COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml docker compose up -d --wait postgres redis-cache redis-queue
```

```bash
pnpm build
```

```bash
DATABASE_URL=postgres://postgres:dev-only-postgres@127.0.0.1:5432/pos pnpm db:migrate
```

```bash
pnpm test:e2e
```

  รันเฉพาะไฟล์เดียว:

```bash
pnpm test:e2e test/sales.e2e-spec.ts
```

  ปิดฐานข้อมูลเมื่อเสร็จ:

```bash
COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml docker compose down
```

- **ผ่านเมื่อเห็น:**
  ```
  Test Files  52 passed | 1 skipped (53)
       Tests  607 passed | 2 skipped (609)
    Duration  162.16s
  ```
- **ข้อควรรู้:**
  - test รัน**ทีละไฟล์** (`fileParallelism: false`) เพราะแต่ละไฟล์บูตแอปเต็มตัว ถ้ารันพร้อมกัน connection ของ Postgres จะเกิน 100
  - รัน `pnpm test:e2e` **ได้ทีละคนต่อฐานข้อมูล 1 ตัว** ถ้ามีอีกรอบรันค้างอยู่ จะขึ้นว่า `e2e runner lock: another pnpm test:e2e is already running` ให้รอหรือปิดรอบนั้นก่อน
  - **อย่าใช้ `docker compose down -v`** ถ้าเครื่องนั้นมีคนอื่นใช้ Docker ร่วมด้วย เพราะ `-v` ลบ volume ของทุกคน บน CI ใช้ได้เพราะเครื่องถูกทิ้งหลังรันเสร็จ

### 2.4 Audit — "ตรวจอะไหล่ว่ามีของเสียไหม"

- **คืออะไร:** โปรเจกต์ใช้ library ภายนอกหลายร้อยตัว ขั้นนี้เอารายการเวอร์ชันใน `pnpm-lock.yaml` ไปเทียบกับฐานข้อมูลช่องโหว่ที่ประกาศแล้ว (CVE) และให้ Trivy ตรวจ Dockerfile ว่าตั้งค่าเสี่ยงไหม
- **เพื่ออะไร:** ต่อให้โค้ดของเราไม่มีบั๊ก ถ้า library ที่ใช้มีช่องโหว่ server ก็โดนเจาะได้
- **คำสั่ง:**

```bash
pnpm audit --audit-level=high
```

```bash
trivy fs --scanners vuln,misconfig --severity HIGH,CRITICAL --ignore-unfixed .
```

- **ผ่านเมื่อเห็น:** `No known vulnerabilities found` และตาราง Trivy เป็น 0 ทุกช่อง
- **เกณฑ์:** ถ้าเจอระดับ HIGH หรือ CRITICAL ที่มีเวอร์ชันแก้แล้ว → fail (`--ignore-unfixed` ข้ามตัวที่ยังไม่มีทางแก้)

### 2.5 Nginx config check — "ตรวจป้ายบอกทางหน้าร้าน"

- **คืออะไร:** nginx เป็นประตูหน้าที่รับ request ทั้งหมดก่อนส่งต่อให้ API คำสั่ง `nginx -t` ตรวจว่าไฟล์ตั้งค่าเขียนถูกไวยากรณ์
- **เพื่ออะไร:** ถ้า config ผิด nginx จะไม่ยอมเปิด และ**ทั้งระบบจะเข้าไม่ได้เลย** ควรรู้ตั้งแต่ใน CI ไม่ใช่ตอน deploy
- **คำสั่ง** (รันที่ root ของรีโป สร้าง cert ปลอมให้ nginx อ่านได้):

```bash
mkdir -p .tmp-nginx/certs .tmp-nginx/auth && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" -keyout .tmp-nginx/certs/server.key -out .tmp-nginx/certs/server.crt && printf 'dummy:%s\n' "$(openssl passwd -apr1 dummy)" > .tmp-nginx/auth/k6-remote-write.htpasswd
```

```bash
docker run --rm -v "$PWD/server/docker/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$PWD/.tmp-nginx/certs:/etc/nginx/certs:ro" -v "$PWD/.tmp-nginx/auth:/etc/nginx/auth:ro" nginx:1.29-alpine nginx -t
```

```bash
rm -rf .tmp-nginx
```

- **ผ่านเมื่อเห็น:** `syntax is ok` และ `test is successful`

### 2.6 Image smoke test + Trivy image — "ตรวจรถก่อนออกจากโรงงาน"

- **คืออะไร:** หลัง build Docker image ของ server แล้ว CI จะตรวจ 3 อย่าง
  1. มีไฟล์ `main.js`, `worker.js`, `bull-board.js`, `db/migrate.js` ครบ
  2. ไม่มี `npm`/`npx` หลงอยู่ใน image (ลดช่องทางโจมตี)
  3. ถ้าไม่ใส่ `DATABASE_URL` แอปต้อง**ล้มทันที**พร้อมบอกสาเหตุ ไม่ใช่เปิดขึ้นมาแบบพังๆ

  จากนั้นให้ Trivy สแกนทุก package ใน image
- **เพื่ออะไร:** image คือสิ่งที่จะเอาไปรันบน server จริง ถ้าไม่ผ่านจะ**ไม่ถูก push ขึ้น GHCR เลย** จึงไม่มีทางไปถึงเครื่องจริง
- **คำสั่ง** (ที่ `server/`):

```bash
docker build -t pos-server:local .
```

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed pos-server:local
```

- **ทำงานเฉพาะบน `main`** และต้องรอให้ test 2.1–2.5 ผ่านทั้งหมดก่อน

---

## 3. Test ฝั่ง Flutter — รันในโฟลเดอร์ `frontend/`

### 3.1 dart analyze — "ตรวจการสะกดฝั่งแอป"

- **คืออะไร:** ตรวจโค้ด Dart แบบเดียวกับ lint ฝั่ง server ใช้ `--fatal-infos` คือแม้แต่คำแนะนำระดับ info ก็ทำให้ fail
- **คำสั่ง:** (ใช้ `dart analyze` เสมอ **ไม่ใช่** `flutter analyze`)

```bash
dart analyze --fatal-infos
```

- **ผ่านเมื่อเห็น:** `No issues found!`

### 3.2 flutter test — "ลองกดทุกหน้าจอ"

- **คืออะไร:** test ใน `frontend/test/` มีหลายแบบ
  - **repository test** เช่น บันทึกการขายลงฐานข้อมูลในเครื่อง (SQLite) แล้วอ่านกลับได้ถูก
  - **widget test** เช่น หน้าจอแสดง error ถูกไหม ปุ่มถูกล็อกตอนยังไม่เปิดกะไหม
  - **migration test** อัปเกรดฐานข้อมูลจาก schema เก่าไปใหม่แล้วข้อมูลไม่หาย
  - **route smoke test** เปิดทุกหน้าในแอปได้โดยไม่ crash
  - **offline test** ขายตอนเน็ตหลุด แล้ว sync ภายหลังได้
- **เพื่ออะไร:** แอปหน้าร้านห้ามพังระหว่างขาย test ชุดนี้ยืนยันว่าทุกหน้าจอและทุก flow หลักยังใช้ได้
- **คำสั่ง:**

```bash
flutter test --reporter expanded
```

  รันไฟล์เดียว:

```bash
flutter test test/sales_repository_test.dart
```

- **ผ่านเมื่อเห็น:** `00:52 +533: All tests passed!` ตัวเลขหน้าสุดคือเวลาที่ผ่านไป (52 วินาที) ส่วน `+533` คือจำนวน test ที่ผ่าน

### 3.3 Web DB asset check — "เช็คว่าอะไหล่รุ่นตรงกัน"

- **คืออะไร:** เวอร์ชันเว็บต้องใช้ไฟล์ `sqlite3.wasm` กับ `drift_worker.js` ที่ commit ไว้ใน `frontend/web/` ขั้นนี้เทียบเวอร์ชันของไฟล์เหล่านี้กับ `pubspec.lock`
- **เพื่ออะไร:** ถ้าเวอร์ชันไม่ตรง แอปเว็บจะเปิดฐานข้อมูลไม่ได้
- **ผ่านเมื่อเห็น:** `pubspec.lock: sqlite3=3.4.0 drift=2.34.1` ตรงกับ `web/WEB_DB_ASSET_VERSIONS.txt`

### 3.4 Codegen check — "โค้ดอัตโนมัติต้องไม่เก่า"

- **คืออะไร:** Drift (ตัวจัดการฐานข้อมูลในแอป) สร้างไฟล์ `*.g.dart` อัตโนมัติ CI จะสั่ง generate ใหม่ แล้วเช็คว่าผลลัพธ์ตรงกับที่ commit ไว้
- **เพื่ออะไร:** ถ้ามีคนแก้ตารางแต่ลืม generate ใหม่ แอปจะทำงานผิดแบบหาสาเหตุยาก ต้องตรวจบน CI เพราะ runner ของ GitHub ใช้ path ภาษาอังกฤษ
- **คำสั่ง:**

```bash
dart run build_runner build --delete-conflicting-outputs && git diff --stat -- '*.g.dart'
```

- **ผ่านเมื่อ:** `git diff` ไม่แสดงอะไรเลย (บน CI เห็น `wrote 330 outputs`)

### 3.5 OSV-Scanner — "ตรวจอะไหล่ฝั่งแอป"

- **คืออะไร:** เหมือน audit ของ server แต่ตรวจ package ของ Flutter ใน `pubspec.lock`
- **คำสั่ง** (ที่ root ของรีโป):

```bash
osv-scanner --lockfile=frontend/pubspec.lock
```

- **ผ่านเมื่อเห็น:** `No issues found`

### 3.6 Build web + smoke — "ประกอบแอปเว็บแล้วเปิดกล่องดู"

- **คืออะไร:** build เว็บ ใส่ใน Docker image แล้วเช็คว่ามี `index.html`, `sqlite3.wasm`, `drift_worker.js` และ image ไม่เปิด port เอง
- **คำสั่ง:**

```bash
flutter build web --no-tree-shake-icons
```

- **ผ่านเมื่อเห็น:** `✓ Built build/web` (บน CI ใช้เวลา compile 41.4 วินาที)

---

## 4. Performance test ด้วย k6 — "เอาไปวิ่งบนถนนจริง"

### k6 คืออะไร

k6 เป็นโปรแกรมจำลองผู้ใช้จำนวนมากยิง request เข้า server พร้อมกัน แล้ววัดว่าตอบเร็วแค่ไหนและ error กี่เปอร์เซ็นต์
test ใน CI ตอบคำถามว่า "**ทำงานถูกไหม**" ส่วน k6 ตอบคำถามว่า "**เร็วพอไหมตอนคนใช้เยอะ**"

### ศัพท์ที่ต้องรู้

- **p95 < 200ms** = 95% ของ request ต้องตอบกลับภายใน 200 มิลลิวินาที (อีก 5% ที่ช้าที่สุดไม่นับ) ใช้แทนค่าเฉลี่ยเพราะค่าเฉลี่ยซ่อน request ที่ช้ามากๆ ไว้ได้
- **threshold** = เกณฑ์ที่เขียนไว้ในสคริปต์ ถ้าไม่ผ่าน k6 จะจบด้วย exit code ≠ 0 จึงใช้เป็น Quality Gate ได้
- **429** = server ตอบว่า "ยิงถี่เกินไป" (โดน rate limit)

### 4 scenario ใน `server/test/k6/`

| Scenario | จำลองสถานการณ์ | เกณฑ์ผ่าน | คำสั่ง |
|---|---|---|---|
| `01-read-products.js` | หลายเครื่องเปิดดูรายการสินค้าพร้อมกัน | p95 < 200ms, cache hit > 90%, error < 0.1% | `pnpm k6:read` |
| `02-write-sales-contention.js` | 200 การขายแย่งสต็อกเดียวกันพร้อมกัน | p95 < 500ms, 5xx = 0 | `pnpm k6:write` |
| `03-idempotent-replay.js` | ส่งบิลเดิมซ้ำ 5 รอบติดกัน (เหมือนเน็ตกระตุกแล้วกดซ้ำ) | p95 < 500ms, 5xx = 0 | `pnpm k6:idem` |
| `04-mixed-workload.js` | อ่านและเขียนผสมกันเหมือนวันจริง | p95 < 500ms, error < 0.1%, connection pool ไม่เต็ม | `pnpm k6:mixed` |
| `verify-integrity.ts` | ตรวจฐานข้อมูลหลังยิงเสร็จ | stock ไม่ติดลบ, บิลไม่ซ้ำ | `pnpm k6:verify` |

### ทำไมต้องรันจาก 3 เครื่องพร้อมกัน

nginx จำกัด **30 request/วินาที ต่อ IP** ถ้ายิงจากเครื่องเดียว k6 จะโดน 429 ก่อนที่ server จริงจะเริ่มเหนื่อย ตัวเลขที่ได้จะเป็นการวัดตัว rate limiter ไม่ใช่วัดระบบ
ทีมจึงตกลงกันว่าจะรันจากโน้ตบุ๊ก 3 เครื่อง แต่ละเครื่องยิงไม่เกิน 24 r/s (80% ของเพดาน) แล้วส่งผลเข้า Prometheus ตัวเดียวกัน

### ขั้นตอนรัน (ย่อจาก `server/test/k6/README.md`)

1. **ตั้งนาฬิกาทุกเครื่องให้ตรงกัน** (macOS: `sudo sntp -sS time.nist.gov`)
2. **เครื่องใดเครื่องหนึ่ง** สร้างร้านทดสอบ `loadtest` กับ token:

```bash
BASE_URL=https://<demo-vm-host> pnpm k6:setup
```

   จะได้ไฟล์ `server/test/k6/k6-env.json` ส่งให้อีก 2 เครื่องทาง AirDrop/USB **ห้าม commit** เพราะมี token จริงอยู่ในไฟล์
3. **ทุกเครื่อง** ตั้งปลายทางส่งผล (ขอรหัสผ่านจากคนที่ถือ `server/.env`):

```bash
export K6_PROMETHEUS_RW_SERVER_URL="https://k6:<password>@<demo-vm-host>/prometheus-remote-write/api/v1/write"
```

```bash
export K6_PROMETHEUS_RW_TREND_STATS="p(95),p(99)"
```

4. **ทุกเครื่องรัน scenario เดียวกันพร้อมกัน** เปลี่ยน `SHARD` เป็น `1/3`, `2/3`, `3/3` และ `MACHINE` ให้ต่างกันแต่ละเครื่อง ใช้ `TESTID` ค่าเดียวกันทุกเครื่อง:

```bash
SHARD=1/3 k6 run -o experimental-prometheus-rw --insecure-skip-tls-verify --tag testid="$TESTID" --tag machine=laptop-a test/k6/01-read-products.js
```

   ทำซ้ำกับ `02`, `03`, `04` ทีละตัว
5. **เครื่องเดียว** ตรวจความถูกต้องของข้อมูลหลังรันเสร็จ:

```bash
BASE_URL=https://<demo-vm-host> pnpm k6:verify
```

### ดูผล k6 ที่ไหน

- **ใน terminal:** ตอน k6 จบ จะพิมพ์ตารางสรุป `http_req_duration ... p(95)=...` และ threshold แต่ละข้อมีเครื่องหมาย ✓ หรือ ✗
- **ใน Grafana:** ทำ SSH tunnel เข้า VM แล้วเปิด `http://127.0.0.1:3000` เลือก dashboard **Srisurart POS — overview** และกรองตาม `testid`

```bash
ssh -L 3000:127.0.0.1:3000 <user>@<demo-vm-host>
```

- ค่า p95 ต้องผ่าน**ทีละเครื่อง** (เอา p95 ของ 3 เครื่องมาเฉลี่ยกันไม่ได้)
- จำนวน 429 ต้องเป็น **0 ทุกเครื่อง** ถ้าไม่เป็น 0 แปลว่ารอบนั้นเชื่อผลไม่ได้ ต้องรันใหม่

> 🔴 **สถานะวันนี้:** สคริปต์และเกณฑ์พร้อมแล้ว แต่**ยังไม่เคยรันวัดผลจริง** (issue #380) เพราะต้องใช้ demo VM ตัวเดียวกับที่ CD ติดปัญหา network อยู่

---

## 5. ดูผล test บน GitHub Actions

### ผ่านหน้าเว็บ

1. เปิด `https://github.com/NuimanLP/srisurart-pos-flutter/actions`
2. เลือก workflow ทางซ้าย: **Server CI**, **Flutter CI** หรือ **Deploy (demo)**
3. คลิก run ที่ต้องการ จะเห็น
   - **Status** (Success/Failure) และ **Total duration** เวลารวม
   - **กราฟ job** พร้อมเวลาของแต่ละ job เช่น `integration 3m 15s`
   - **Annotations** ข้อความ error/warning สรุปไว้ด้านล่าง
4. คลิกชื่อ job เพื่อดู log ทีละ step พร้อมเวลาของแต่ละ step (**ต้อง login GitHub ก่อน**)
5. เมนู **Usage** ทางซ้ายบอกเวลาที่ใช้ของทั้ง run

### ผ่าน terminal (gh CLI)

รายการ run ล่าสุด:

```bash
gh run list -L 10
```

เวลาเริ่มและจบของแต่ละ job:

```bash
gh run view 35811055994 --json jobs --jq '.jobs[] | "\(.name) | \(.conclusion) | \(.startedAt) → \(.completedAt)"'
```

log ของ job ที่ fail:

```bash
gh run view 35811055994 --log-failed
```

log เต็มของ job เดียว (เลข job ดูได้จาก URL หรือคำสั่งด้านบน):

```bash
gh api repos/NuimanLP/srisurart-pos-flutter/actions/jobs/107022509504/logs
```

### อ่านสีให้ถูก

- ✅ **เขียว** = ผ่าน · ❌ **แดง** = ไม่ผ่าน · ⊘ **เทา** = ถูกข้าม (skipped ซึ่งนับว่าผ่าน เช่น job `changes` ที่รันเฉพาะใน PR)
- `server-ci-status` / `flutter-ci-status` คือ **job สรุปผล** ถ้าตัวนี้เขียว แปลว่าทุก job ข้างบนผ่านหรือถูกข้ามอย่างถูกต้อง ตัวนี้คือสิ่งที่ GitHub ใช้ตัดสินว่า merge เข้า `main` ได้ไหม
- ⚠️ **Deploy (demo) ขึ้นเขียวไม่ได้แปลว่า deploy แล้ว** job `deploy to demo` อาจถูกข้ามเพราะ image ยังไม่ครบ ต้องกดเข้าไปดูว่า job นั้นรันจริงไหม

---

## 6. เมื่อ test แดง ต้องทำอะไร

| อาการ | สาเหตุที่พบบ่อย | วิธีแก้ |
|---|---|---|
| lint/analyze แดง | โค้ดผิดหลักตามที่ข้อความบอก | แก้ที่ไฟล์และบรรทัดที่ระบุ แล้วรันคำสั่งเดิมซ้ำ |
| unit/flutter test แดง | logic เปลี่ยนแล้ว test ไม่ตรง หรือเกิดบั๊กจริง | อ่านชื่อ test กับ `expected` / `received` ก่อนแก้ อย่าแก้ test ให้ผ่านโดยไม่เข้าใจ |
| e2e ขึ้น `e2e runner lock` | มีอีกรอบรันอยู่กับฐานข้อมูลเดียวกัน | รอให้รอบนั้นจบ |
| e2e เชื่อมฐานข้อมูลไม่ได้ | ยังไม่ได้ `docker compose up` หรือยังไม่ migrate | ทำขั้น 2.3 ให้ครบตามลำดับ |
| audit/Trivy แดง | library มีช่องโหว่ใหม่ | อัปเดต library ตัวนั้น (ห้ามปิดด้วย `.trivyignore`) |
| codegen แดง | แก้ตาราง Drift แต่ไม่ได้ generate ใหม่ | รัน build_runner บน path ภาษาอังกฤษแล้ว commit ไฟล์ `*.g.dart` |
| image → GHCR แดงตอน push | registry มีปัญหาชั่วคราว (เคยเจอ `unknown blob`) | กด **Re-run failed jobs** บนหน้า run |

---

## 7. Cheat sheet — คำสั่งทั้งหมดในที่เดียว

| ต้องการ | อยู่ที่ | คำสั่ง |
|---|---|---|
| ตรวจโค้ด server | `server/` | `pnpm lint && pnpm typecheck` |
| unit test server | `server/` | `pnpm test` |
| เวลาทีละ test | `server/` | `pnpm vitest run --reporter=verbose` |
| integration test | `server/` | ขั้น 2.3 (compose up → build → migrate → `pnpm test:e2e`) |
| สแกนช่องโหว่ server | `server/` | `pnpm audit --audit-level=high` |
| ตรวจโค้ด Flutter | `frontend/` | `dart analyze --fatal-infos` |
| test Flutter | `frontend/` | `flutter test --reporter expanded` |
| สแกนช่องโหว่ Flutter | root | `osv-scanner --lockfile=frontend/pubspec.lock` |
| codegen | `frontend/` | `dart run build_runner build --delete-conflicting-outputs` |
| performance | `server/` | `pnpm k6:setup` แล้ว `pnpm k6:read` / `k6:write` / `k6:idem` / `k6:mixed` แล้ว `pnpm k6:verify` |
| ดูผล CI | ไหนก็ได้ | `gh run list` / `gh run view <id>` |

---

**อ่านต่อ:** `server/README.md` (หัวข้อ Checks และ The e2e suite) · `server/test/k6/README.md` · `.github/workflows/server.yml` · `.github/workflows/flutter.yml`
