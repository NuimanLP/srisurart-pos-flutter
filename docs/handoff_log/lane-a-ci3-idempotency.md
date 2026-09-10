# Handoff — Lane A: #40 ci.3 image artefact + #18 p5.1 idempotency (2026-09-09)

**วันที่:** 2026-09-09 · **ผู้บันทึก:** NuiGates (`NuimanLP`, Lane A / `team/1`) · **สถานะ:** #40 ปิดแล้ว · #18 รอ merge
**ขอบเขต:** สอง ticket แรกของ Lane A ที่ไม่ติด blocker — #40 (CI/CD) และ #18 (backend) ทำทีละใบ แยก branch
**ต่อจาก:** [`merge-p1-p2-lane-assignments.md`](merge-p1-p2-lane-assignments.md)

## 1. ตอนนี้อยู่ตรงไหน

- **#40 ปิดแล้ว** — PR #50 squash เข้า `main` เป็น `2a5d377` · branch ถูกลบ · CI บน `main` เขียว
- **#18 ยังไม่ merge** — PR #51 เปิดอยู่ branch `feat/p5.1-idempotency` · CI เขียวครบ (lint / unit / integration / audit) · `build-image` ขึ้น *skipping* ตามสเปก
- **Lane A ที่เหลือติดหมด** — #19 → #20 → #21 → #22/#23/#28/#30 รอ **#6** (device enrolment, Lane C) และ #11/#17/#29 · หลังจาก #18 merge แล้ว **Lane A ไม่มีอะไรหยิบได้อีกจนกว่า #4 → #6 จะเสร็จ**
- เครื่อง dev: compose datastores รันค้างอยู่ (`docker compose -f docker-compose.yml -f docker-compose.dev.yml`), migration ลงแล้วใน DB `pos`

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

**#40 — `build-image` job ใน `server.yml`**
- build image → เช็ค 4 entrypoint ที่ compose รัน (`main.js`, `worker.js`, `bull-board.js`, `db/migrate.js`) → smoke run → `docker save | gzip` → **โหลด tarball กลับมา `docker load` + `inspect` แล้วค่อย upload**
- ผลจริงบน `main` commit `2a5d377`: `pos-server-image-…` **63,606,766 bytes** + `pos-web-…` **16,135,183 bytes** — ครบทั้งสองฝั่งสำหรับ commit เดียว (เพราะ commit นี้แตะทั้ง `server/**` และ workflow ฝั่ง frontend ซึ่งเป็นข้อยกเว้น ไม่ใช่กรณีปกติ)
- แถมที่ไม่ได้อยู่ใน AC แต่จำเป็น: `build-web` เดิม `needs: [analyze-and-test]` เท่านั้น → **web artefact ออกได้แม้ `codegen-check` แดง** ซึ่งเป็นที่เดียวที่ตรวจ `*.g.dart` · แก้เป็น `needs: [analyze-and-test, codegen-check, deps-audit]`
- `cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}` ทั้งสอง workflow — เดิม push main ติด ๆ กันสองที ตัวแรกโดน cancel กลางคัน commit นั้นเลยไม่มี artefact แบบเงียบ ๆ
- `permissions: contents: read` ทั้งสอง workflow

**#18 — idempotency module** (10 ไฟล์, +999 บรรทัด)
- `src/idempotency/{service,interceptor,module}.ts` + `src/common/request-context.ts` + unit spec + e2e spec
- ผลเทสต์: **unit 8 ผ่าน · e2e 26 ผ่าน** (เดิม 16 → ของ #18 เอง 10 ตัว) · ใน CI: `test/idempotency.e2e-spec.ts (10 tests) 908ms`
- **หลักฐานว่า `ON CONFLICT DO NOTHING` block จริง** (agent เปิด psql 2 session ยิงชนกันเอง): ตัวแพ้ block **13.54 วิ** รอตัวชนะ commit แล้วอ่านแถวที่ `status=done, response_code=201` · เคส rollback: block **5.01 วิ** แล้วกลายเป็นเจ้าของ key เอง
- e2e พิสูจน์ contention จริง ไม่ใช่ยิงเรียงกัน — handler ถือ transaction 400 ms ด้วย `pg_sleep` แล้วยิง 3 request พร้อมกัน → 201 เหมือนกันทั้งสาม แต่ **effect เดียว**

**ตรวจสอบด้วยอะไร**
- `actionlint` (ผ่าน docker) — clean ทั้ง repo · ยืนยันด้วยว่ามัน**จับ bug ที่ผมเคยเขียนได้จริง** (ทดลองใส่กลับใน scratch repo แล้วมันฟ้อง)
- docker จริงบนเครื่อง: build 65 MB, รันเป็น user `node`, save/load round-trip ผ่าน
- `oxlint` + `tsc --noEmit` + vitest ทั้งสองชุด ก่อน commit ทุกครั้ง

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

| เรื่อง | เลือก | เหตุผล | ใครตัดสิน |
|---|---|---|---|
| image ไปไหน | Actions artifact (`docker save` tarball) **ไม่ push registry** | ยังไม่เลือก production host → ยังไม่เลือก registry (`03_ARCHITECTURE §8`) · GHCR ไว้ทีหลังพร้อมกับ host | เจ้าของโปรเจกต์ |
| #40 AC4 (web artefact ของ commit เดียวกัน) | ยอมรับว่าไม่ผ่าน โยนให้ **#39** | วิธีแก้คือถอด `paths:` ออกจาก `push` trigger ซึ่งเป็นไฟล์เดียวกัน/blast radius เดียวกับ #39 | เจ้าของโปรเจกต์ |
| Trivy image scan ใน `build-image` | **ถอดออก** โยนให้ #44 | รันจริงแล้วมันจะทำให้ `main` แดงตั้งแต่ merge แรก (ดู §4) และวิธีแก้เป็นการตัดสินใจด้าน security ของ #44 ไม่ใช่ ticket build artefact | ผมเสนอ (มีหลักฐาน) |
| #18 ต้องรอ #4 ไหม | **ไม่รอ** ทำ seam เล็ก ๆ เองให้ #4 มาเสียบ | #18 blocked by แค่ #15 ซึ่งปิดแล้ว · ถ้ารอ Lane A จะว่างทั้งใบ | เจ้าของโปรเจกต์ |
| tenant id มาจากไหน | `AsyncLocalStorage` ที่ **throw ถ้าไม่มี** ไม่ใช่ header | ถ้ารับจาก header จะกลายเป็นรูโหว่ทันทีที่มีคนลืม — ตรงกับเจตนา ADR-0004 (`did`/`drole` ห้ามมาจาก request) | ผม |
| endpoint ที่ใช้พิสูจน์ | อยู่ใน **test** ไม่ใช่ `src/` | ถ้าอยู่ใน `src/` มันคือ route ที่รันไม่ได้จริง (ไม่มีคนเติม context) และเป็นของแถมที่อันตราย | ผม |
| `endpoint` เทียบยังไง | เก็บเป็น**คอลัมน์แยกแล้วเทียบ** ไม่ fold เข้า `request_hash` | `01_DATABASE.md` นิยาม `request_hash` = sha256 ของ **body** เปลี่ยนความหมายคอลัมน์ = ขัดเอกสาร | ผม |
| Redis fast layer | อ่าน**หลัง** INSERT ชนเท่านั้น · เขียน**เฉพาะตอน replay** · TTL = อายุที่เหลือของแถว | อ่านก่อน = เพิ่ม round-trip ให้ write ทุกใบเพื่อเร่ง retry ที่นาน ๆ เกิดที · เขียนตอน claim = ถ้า rollback จะเหลือ "ความสำเร็จผี" · TTL ใหม่ 24 ชม. = cache อยู่นานกว่าแถวที่ Lane C ลบไปแล้ว | ผม |
| ไม่มี header / key ยาวเกิน | `400 IDEMPOTENCY_KEY_INVALID` (code เดียวคุมทั้งสอง) | §1.4 บังคับ header แต่ไม่เคยบอกว่าไม่มีแล้วยังไง · write ที่แอบรันโดยไม่มี key retry ไม่ได้โดยไม่เก็บเงินซ้ำ · เอา code เดียวเพื่อไม่ให้ catalogue โตเกินจำเป็น | ผม |
| รอ lock นานแค่ไหน | `SET LOCAL lock_timeout = '5s'` แล้ว restore ทันที เกินนั้น `503 IDEMPOTENCY_KEY_IN_FLIGHT` | คนแพ้ถือ pool connection ไว้เท่ากับเวลาที่คนชนะใช้ (วัดได้ 13.54 วิ) · `DB_POOL_SIZE` default แค่ 5 | ผม |
| ADR-0003 vs guard ที่ทำไม่ได้ | เขียนเป็น **split 3 ท่อน** แล้วคอมเมนต์เตือนที่ #4 ไม่แก้ ADR เอง | ADR เป็นของทีม ไม่ใช่ของผมจะไปแก้ใน PR · แต่ถ้าไม่เตือน คนทำ #4 จะออกแบบชนกำแพง | ผม |

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- **`${{ runner.temp }}` ใน job-level `env:`** → กลายเป็น string ว่าง (context `runner` ใช้ตรงนั้นไม่ได้) ไฟล์จะถูกเขียนลง `/` แล้ว permission denied · ใช้ `$RUNNER_TEMP` ใน `run:` แทน · **`actionlint` จับได้** — ควรเอาเข้า CI เป็น slice ของตัวเอง
- **Trivy image scan บน `node:22-alpine`** → 13 fixable HIGH/CRITICAL ที่ไม่ใช่ของเรา: 11 ตัวอยู่ใน npm ที่ base image แถมมา (`/usr/local/lib/node_modules/npm/` — `tar` CRITICAL, `sigstore`, `pacote`, `brace-expansion`, `picomatch`, `ip-address`) + `libssl3`/`libcrypto3` ของ alpine 3.24.1 · pull base image ใหม่สด ๆ แล้วก็ยังเท่าเดิม · `pnpm audit` กับ Trivy fs เขียวทั้งคู่ → **ไม่ใช่ปัญหาของ dependency เรา** · หลักฐาน + ทางออก 3 ทางอยู่ในคอมเมนต์ #44
- **`COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml` บน Windows** → พัง ตัวคั่น path บน Windows คือ `;` ไม่ใช่ `:` · บนเครื่อง dev ต้องใช้ `-f a.yml -f b.yml` · **CI เป็น Linux เลยไม่กระทบ อย่าไปแก้ `server.yml`**
- **`corepack enable`** → `EPERM` เขียน `C:\Program Files\nodejs\` ไม่ได้ · ใช้ `corepack pnpm <cmd>` ตรง ๆ ได้เลย ไม่ต้อง enable
- **`ds.query()` + `set_config('app.tenant_id', …, false)`** ในเทสต์ → RLS คืน **0 แถว** เสมอ เพราะ pool แจก connection คนละตัวต่อ query · ต้องทำใน query runner + transaction เดียวกัน (`asTenant()` ในไฟล์เทสต์)
- **`UPDATE … RETURNING 1` แล้วนับ `rows.length`** → TypeORM คืน `[rows, affected]` สำหรับ UPDATE แต่คืน `rows` เฉย ๆ สำหรับ INSERT (ยิง probe จริงไปดู ไม่ได้เดา) · ต้อง destructure `[, affected]`
- **replay "byte for byte" ตามที่ #18 เขียน** → เป็นไปไม่ได้ผ่านคอลัมน์ `jsonb` ซึ่งไม่รักษาลำดับ key และ handler ที่ไม่คืนค่าจะกลายเป็น `null` · แก้คำสัญญาแทน (JSON-equal ไม่ใช่ byte-equal) ถ้าอยากได้ byte จริงต้องแก้ schema = งานของ Lane B
- **ให้ `TenantGuard` เปิด transaction + ถือ scope ข้าม handler + commit เอง** → ทำไม่ได้ `canActivate` return ก่อน handler รัน · ต้องแยกเป็น middleware / guard / interceptor

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

**ยืนยันแล้ว (รันจริง/วัดจริง):** ทุกอย่างใน §2 · การ block ของ `ON CONFLICT` ทั้งสองสาขา · shape ที่ TypeORM คืน · CVE ของ base image · artefact ที่ออกบน `main`

**ยังไม่พิสูจน์:**
- **AC5 ของ #18** ("kill ระหว่าง commit กับ response") — เทสต์**สร้าง state หลัง commit ขึ้นมาเอง**แล้วยิงซ้ำ **ไม่ได้ kill process จริง** พิสูจน์ว่า state นั้น replay ได้ แต่ไม่ได้พิสูจน์ว่า kill แล้วจะได้ state นั้น
- เทสต์ multi-key body พิสูจน์ **JSON equality** เท่านั้น ไม่ได้พิสูจน์ว่า jsonb สลับลำดับ key จริงในเคสนั้น (`toEqual` ไม่สนลำดับอยู่แล้ว)
- **path `503 IDEMPOTENCY_KEY_IN_FLIGHT` ไม่มีเทสต์** — ต้องถือ lock เกิน 5 วิ ซึ่งช้าเกินไปสำหรับ CI
- error code ใหม่ 2 ตัว (`IDEMPOTENCY_KEY_INVALID`, `IDEMPOTENCY_KEY_IN_FLIGHT`) **ยังไม่ผ่านเจ้าของร้าน/อาจารย์** — ผมเติมลง `02_API_SCREENS §8` เองโดยไม่มีข้อความไทย (เหมือน `IDEMPOTENCY_KEY_REUSED`)
- **ยังไม่รู้ว่าเจ้าของ #4 จะรับ split 3 ท่อนไหม** หรือจะเสนอทางอื่น · และยังไม่รู้ว่า ADR-0003 จะได้ addendum หรือไม่
- ยังไม่รู้ว่า `IdempotencyInterceptor` จะเข้ากับ `POST /sales` (#20) ได้ราบรื่นแค่ไหน — ยังไม่มีใครลองใช้จริง

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **merge PR #51** (#18) — CI เขียวแล้ว รอเจ้าของโปรเจกต์กดเท่านั้น
2. **หลัง merge: `git pull --ff-only origin main` ทันที** ก่อนทำอะไรต่อ (บทเรียนจาก handoff ก่อนหน้า — `gh pr merge` อัปเดตแค่ remote)
3. **รอ #4** (`PattaraponKitcharoen`) — อ่านคอมเมนต์ที่ผมทิ้งไว้ใน #4 ก่อนเริ่ม โดยเฉพาะเรื่อง split และคำถาม 2 ข้อ (route ไหนควรได้ transaction / ADR-0003 ควรมี addendum ไหม)
4. **#11 ต้องให้เจ้าของตัดสิน** (`mechanics.total_credit`) — บล็อก #21 เป็นต้นไป **ห้ามตัดสินใน PR** เอกสารกับ Dart reference ขัดกัน อ่านฝั่งเดียวจะได้คำตอบที่ผิดแบบมั่นใจ
5. **frontend backlog ยังไม่ถูกตัดเป็น issue** — task `q1` + Drift schema v3 (`Sales.shiftId`, `Shifts.id` TEXT, `Products.offlineOk`) ตาม ADR-0010 ต้องเสร็จก่อนใครจบ backend bundle · ถูก flag มา 3 handoff ติดแล้วยังไม่มีใครทำ
6. **#44** — ตัดสินใจเรื่อง image CVE (ทางที่ดูดีที่สุด: ลบ npm ออกจาก runtime stage เคลียร์ 11 จาก 13) แล้วค่อยเปิด Trivy image scan กลับ ~9 บรรทัดใน `build-image`
7. **#39** — ถอด `paths:` ออกจาก `push` trigger เพื่อปิด AC4 ของ #40

## 7. ข้อควรระวัง

- 🔴 **`build-image` รันเฉพาะบน `main`** (`if: github.ref == 'refs/heads/main'`) → บน PR มัน *skip* เสมอ แปลว่า**การรันจริงครั้งแรกคือหลัง merge** ถ้าแก้ job นี้ ต้องทดสอบด้วย docker บนเครื่องเอง อย่าเชื่อว่า PR เขียวแล้วปลอดภัย
- 🔴 **`currentRequestContext()` throw ไม่ default** — ตั้งใจ ถ้ามีใครไป "แก้" ให้มัน return tenant เปล่า ๆ หรือรับจาก header จะกลายเป็นรูโหว่ข้าม tenant ทันที
- 🔴 **`claim()` กับ `complete()` ต้องอยู่ใน transaction เดียวกัน** ถ้าใครเรียก `claim()` แล้ว commit โดยไม่ `complete()` แถวจะค้างที่ `in_progress` และ `claim()` รอบต่อไป **จะ throw** (ตั้งใจ — เป็น bug ของคนเรียก ไม่ใช่ error ของ client)
- **`SET LOCAL lock_timeout` restore ด้วย `= DEFAULT` เฉพาะตอนสำเร็จ** ถ้า INSERT throw แล้วยังไปยิง statement ต่อ transaction มัน abort อยู่แล้ว จะได้ `25P02` มาทับ error จริง
- **`vitest.config.ts` (unit) ไม่เก็บ `test/*.e2e-spec.ts`** ยืนยันแล้วจากผลรัน — unit spec ต้องวางไว้ข้าง ๆ โค้ดใน `src/` เท่านั้น
- **อย่าเชื่อ agent ทันที** — รอบนี้ agent ตัวหนึ่งบอกว่า `github.event_name == 'push'` ใน `if:` ซ้ำซ้อน ซึ่ง**ผิด** (มันกัน `workflow_dispatch` ออกด้วย) แต่ข้อสรุปสุดท้ายยังถูกคือควรถอดออกเพื่อให้เหมือน `build-web`

## 8. อ้างอิง

- PR **#50** (#40, merged `2a5d377`) · PR **#51** (#18, เปิดอยู่)
- คอมเมนต์ที่ทิ้งไว้: **#40** (สรุป AC ทีละข้อ) · **#39** (รับ AC4 ต่อ) · **#44** (หลักฐาน CVE + ทางออก) · **#4** (split 3 ท่อน + คำถาม 2 ข้อ)
- `server/README.md` → *Idempotency (#18)* และ *The request-context seam* — กติกาทั้งหมดอยู่ที่นั่น
- `docs/Backend_design/adr/0003-tenant-lifecycle.md` — ข้อผูกมัดที่ทำให้ #4 ต้องเป็น split
- `docs/Backend_design/02_API_SCREENS.md` §1.4 (idempotency), §5 (Redis key), §8 (error catalogue — 2 แถวใหม่)
- คนที่ต้องถาม: เจ้าของโปรเจกต์ (#11, error codes ใหม่, merge) · `PattaraponKitcharoen` (#4, #6, #44) · `LomerAlloys` (#39, #17, #29)
