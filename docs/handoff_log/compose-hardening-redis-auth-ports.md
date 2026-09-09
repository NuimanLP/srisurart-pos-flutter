# Handoff — ปิดรูรั่วในไฟล์ compose: Redis AUTH + ไม่ publish port ของ datastore (2026-09-09)

**วันที่:** 2026-09-09 · **ผู้บันทึก:** Claude Opus 5 (เซสชันต่อจากรีวิวความปลอดภัยรอบเดียวกัน) · **สถานะ:** ปิดแล้ว
**ขอบเขต:** `server/docker-compose.yml` + overlay ใหม่ + CI job `integration` + เอกสาร 5 ไฟล์ — ไม่แตะโค้ด application เลย
**ต่อจาก:** [`security-review-jwt-audit-cve.md`](security-review-jwt-audit-cve.md)
**Commit:** `bc89a1a` (squash merge PR #49) บน `main`

---

## 1. ตอนนี้อยู่ตรงไหน

* `main` = `bc89a1a` · CI ฝั่ง server เขียวครบ 4 job บน PR #49 (lint 12s · unit 9s · audit 22s ·
  **integration 30s**) · ไม่มี PR ค้าง
* สแตกเฟส 1 ยังเหมือนเดิมทุกอย่าง ยกเว้น **ทางเข้าจาก host**: เหลือ Nginx (80/443) กับ Bull-Board
  (`127.0.0.1:3100`) เท่านั้น · Postgres/Redis คุยกันผ่าน docker network อย่างเดียว
* 🔴 **คนที่มี `server/.env` เก่าอยู่แล้วต้องเติม `REDIS_PASSWORD` ก่อน** ไม่งั้น `docker compose`
  ไม่ยอมขึ้นเลย (ตั้งใจให้ fail fast) — ดู `.env.example`

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

เจ้าของโปรเจกต์เอาผลรีวิว compose มาให้ 2 ข้อ (🟡 Medium-High และ 🟡 Medium) แล้วสั่ง "แก้ซะ":

| # | ปัญหา | สิ่งที่ทำ |
|---|---|---|
| 1 | `redis-cache`/`redis-queue` **ไม่มี `--requirepass`** ใครถึง network ก็สั่ง `FLUSHALL` ล้างคิวงานขายได้ | ใส่ `--requirepass ${REDIS_PASSWORD:?…}` ทั้งสองตัว · รหัสเดินทางไปกับ `REDIS_CACHE_URL`/`REDIS_QUEUE_URL` แบบ `redis://:pass@host:6379` ซึ่ง **ioredis อ่านเองอยู่แล้ว → ไม่ต้องแก้โค้ดสักบรรทัด** · healthcheck ใช้ `REDISCLI_AUTH` (env ไม่ใช่ arg) |
| 2 | `ports:` ของ Postgres (5432) / Redis (6379,6380) ผูก `127.0.0.1` — ยังเชื่อ host ทั้งเครื่อง (user อื่นบน VM หรือ SSRF ยิงถึง DB ตรง ๆ) | เอา `ports:` ของ datastore **ออกจาก `docker-compose.yml` ทั้งหมด** · ย้ายไป `docker-compose.dev.yml` (ไฟล์ใหม่) ที่ใช้เฉพาะเครื่อง dev + CI runner |

ผลที่วัดได้จริงในเซสชันนี้:

* `docker compose config` merge ผ่าน — ทุก URL มีรหัสผ่าน, base file เดี่ยว ๆ publish แค่ 3100/80/443
* **fail-fast ทำงานจริง**: `.env` เก่าบนเครื่อง (ไม่มี `REDIS_PASSWORD`) ทำให้ compose ตอบ
  `required variable REDIS_PASSWORD is missing a value` และไม่ยอมขึ้น
* `pnpm lint` / `typecheck` / `test` (3 tests) ผ่านบนเครื่อง
* `pnpm test:e2e` **รันบนเครื่องไม่ได้** (Docker daemon ไม่ได้เปิด) → job `integration` บน PR #49
  คือที่แรกที่พิสูจน์ว่า Redis AUTH + overlay ต่อติดจริง — **ผ่าน 30s**

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

* **ทำไมต้องมีไฟล์ overlay แยก ไม่แก้ `ports:` ในไฟล์เดิม** — compose **merge `ports:` แบบต่อท้าย
  (append) ลบของเดิมด้วย override ไม่ได้** ทางเดียวที่ base file จะไม่มี port คือไม่เขียนไว้ตั้งแต่แรก
  แล้วให้ overlay เป็นคนเติม → `docker-compose.dev.yml` เกิดจากข้อจำกัดนี้ ไม่ใช่รสนิยม
* **ทำไมชื่อ `docker-compose.dev.yml` ไม่ใช่ `docker-compose.override.yml`** — compose โหลดไฟล์ชื่อ
  `override` **ให้อัตโนมัติ** ถ้า commit ลง repo มันจะติดไปเปิด port บน VM เงียบ ๆ ซึ่งคือสิ่งที่
  งานนี้พยายามปิดพอดี · ชื่อ `dev` บังคับให้ต้องพิมพ์ `-f` เอง
* **CI ใช้ `COMPOSE_FILE` env ระดับ job** ไม่ใช่เติม `-f` ทีละคำสั่ง — job `integration` มีคำสั่ง
  compose 3 จุด (`up`, `logs`, `down`) ลืมจุดใดจุดหนึ่งแล้วจะงงหนัก
* **healthcheck เปลี่ยนเป็น `redis-cli ping | grep -q PONG`** — `redis-cli` **exit 0 แม้เซิร์ฟเวอร์ตอบ
  error** ถ้าปล่อย `["CMD","redis-cli","ping"]` ไว้ container ที่ auth ไม่ผ่านจะรายงานว่า healthy
* **Bull-Board (3100) ยังผูก port ไว้เหมือนเดิม** ทั้งที่รีวิวพูดถึงมันด้วย — Nginx **ไม่ได้ proxy** ให้
  ถ้าเอา port ออกคือเข้าไม่ได้เลย · มันมี basic auth ทับอยู่แล้ว → เหลือ loopback ไว้ เข้าทาง SSH tunnel
* **ผู้ตัดสิน:** เจ้าของโปรเจกต์สั่งแก้ทั้ง 2 ข้อ, รายละเอียดวิธีแก้เป็นของ agent

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

* **ตั้งใจจะ smoke test สแตกจริงบนเครื่อง** (ขึ้น postgres+redis แล้วลอง `redis-cli` แบบไม่ใส่รหัส
  ให้เห็น `NOAUTH`) — **ทำไม่ได้** เพราะ Docker daemon บนเครื่อง Mac ไม่ได้เปิด
  (`Cannot connect to the Docker daemon`) จึงไปพึ่ง CI แทน
* ไม่ได้ลองทางที่ผิดอื่น ๆ นอกจากนี้

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

* **ยืนยันแล้ว** (จาก job `integration` เขียว): Redis 2 ตัวขึ้นพร้อม `--requirepass`, healthcheck ผ่าน,
  app ต่อ Redis ด้วยรหัสใน URL ได้, overlay เปิด port ให้ runner ต่อ Postgres/Redis ได้
* **ยังไม่ได้ทดสอบตรง ๆ**: ไม่ได้ยิง `redis-cli` แบบไม่มีรหัสเพื่อดู `NOAUTH` กับตาดูเอง —
  อนุมานจากพฤติกรรมมาตรฐานของ `requirepass` (ถ้าอยากได้หลักฐานในรายงาน ให้ทำตอนรัน ZAP baseline)
* **ยังไม่มีใครทดสอบบน VM คณะ** — งานนี้ยังไม่มี host จริง (#40 / `q4`)
* Bull-Board ยังไม่ต่อ Redis เลยเพราะยังไม่ลงทะเบียน queue (`queues: []` รอ #34) จึงยังไม่มีหลักฐาน
  ว่า bull-board + AUTH ทำงานร่วมกันได้ — **#34 ต้องเติม `<<: *app-env` ให้ service นี้** (มี comment กำกับไว้ในไฟล์แล้ว)

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **บอกทีมให้เติม `REDIS_PASSWORD` ใน `server/.env` ของตัวเอง** (ทุกคนที่เคย `cp .env.example .env` ไว้ก่อนวันนี้)
2. ใครที่รัน dev/e2e นอก Docker ต้องเปลี่ยนคำสั่งเป็น `-f docker-compose.yml -f docker-compose.dev.yml` (README แก้ให้แล้ว)
3. คนทำ **#34 (BullMQ queue)** — เติม `<<: *app-env` ใน service `bull-board` ตอนลงทะเบียน queue
4. คนทำ **#40 (deploy)** — ตอนเลือก production host ให้ยึดกฎว่า **ห้ามเอา overlay ขึ้น VM**
   และของจริงต้องเปลี่ยน `REDIS_PASSWORD`/`POSTGRES_PASSWORD`/`POS_APP_PASSWORD`/`BULL_BOARD_PASSWORD`
   จากค่า `dev-only-*` เป็น secret จริง
5. **#44 `sec.1`** ยังค้างเหมือนเดิม (Helmet/CORS, rate limit ต่อ user, negative-path e2e, CodeQL, ZAP)

## 7. ข้อควรระวัง

* 🔴 **ห้าม `docker-compose.dev.yml` ขึ้น VM หรือเครื่อง shared** — มันคือรูที่เพิ่งปิดไป
* 🔴 **ห้ามเปลี่ยนชื่อ overlay เป็น `docker-compose.override.yml`** — compose จะโหลดเองอัตโนมัติ
* `--requirepass` โผล่ใน `ps` ของ container นั้น ๆ (ข้อจำกัดของ image `redis:7-alpine` ที่ไม่รับ
  รหัสทาง env) ยอมรับได้ในเฟส 1 เพราะใครที่เข้าไปใน container ได้ก็ยิง Redis ได้อยู่แล้ว
  ถ้าจะแน่นกว่านี้ต้องใช้ config file + secret mount
* ค่าใน `.env.example` เป็น **`dev-only-*` ทั้งหมด** ตั้งใจให้เป็นแบบนั้น — มันคือค่าที่ CI ใช้ด้วย
  (job `integration` ทำ `cp .env.example .env`) **ห้ามเอา secret จริงมาใส่ไฟล์นี้**
* งานนี้ไม่ได้แตะ `.agents/`, `.claude/skills/`, `android/`, `ios/`, `docs/boat_CI_CD.md`,
  `skills-lock.json` ที่ยัง untracked อยู่ในเครื่อง — ยังไม่มีใครตัดสินว่าจะ commit หรือ ignore

## 8. อ้างอิง

* PR: [#49](https://github.com/NuimanLP/srisurart-pos-flutter/pull/49) · commit `bc89a1a`
* ไฟล์: `server/docker-compose.yml` · `server/docker-compose.dev.yml` (ใหม่) · `server/.env.example` ·
  `server/README.md` · `.github/workflows/server.yml` (job `integration`, `COMPOSE_FILE`)
* เอกสาร: [`04_QA_SCRUTINY.md`](../Backend_design/04_QA_SCRUTINY.md) หัวข้อ *"เพิ่มเติม 2026-09-09 — สองรูรั่วในไฟล์ compose เอง"* ·
  [`03_ARCHITECTURE.md`](../Backend_design/03_ARCHITECTURE.md) *"สิ่งที่ห้ามลืมตอน deploy"* ·
  [`adr/README.md`](../Backend_design/adr/README.md) หมายเหตุ CI · `CLAUDE.md` bullet *Security (2026-09-09 review)*
* คนที่ต้องถามถ้าจะเปลี่ยน: เจ้าของโปรเจกต์ (เรื่อง secret จริง) · `PattaraponKitcharoen` (`team/3`, เจ้าของ #44 sec.1)
