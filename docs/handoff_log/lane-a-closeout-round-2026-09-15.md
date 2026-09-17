# Handoff — Lane A: ปิดงานค้าง phase 1 + เคาะ ADR ของ phase 2 (2026-09-15)

**วันที่:** 2026-09-15 · **ผู้บันทึก:** NuimanLP (`team/1`, Lane A) กับ Claude ในบทบาท orchestrator · **สถานะ:** กำลังทำ (ยังไม่เริ่ม phase 2)
**ขอบเขต:** แตก ticket สำหรับปิด phase 1 และความเสี่ยงของ phase 2 (#182–#196) · ใช้ agent ทำและรีวิว #182 #183 #188 #201 #213 · รีวิวย้อนหลัง #208/#209 · เคาะ #187/#191
**ต่อจาก:** [`followups-169-173-175.md`](followups-169-173-175.md), [`owner-decisions-145-163.md`](owner-decisions-145-163.md)

## 1. ตอนนี้อยู่ตรงไหน
- **เจ้าของโปรเจกต์ตัดสินเมื่อ 2026-09-15:** ปิดงานค้างทั้งหมดก่อน แล้วค่อยเริ่ม phase 2
- ticket ใบรวมของ Lane A คือ **#196**
- **PR ที่เปิดอยู่:** ไม่มีจากรอบนี้
- **agent ที่ยังรันอยู่:** ไม่มี
- **ticket ที่พร้อมให้ agent ทำต่อ:**
  - **#219** งานเล็กที่ตามมาจากรีวิว #208/#209
  - **#221** bug: หน้าช่างไม่ถามยืนยันซ้ำเมื่อชำระเกินยอด
  - **#192** ออกโค้ดใหม่ให้เครื่องเดิม และหน้าจอจัดการเครื่อง
- **รอเจ้าของโปรเจกต์หรือร้าน:**
  - #186 ตั้ง branch protection
  - #184 ใส่ secret แล้ว deploy ขึ้น VM
  - #185 ขอ snapshot จากร้าน (ต้องแก้ #217 ก่อน)
  - #220 ข้อความภาษาไทยตอนขายแล้วไม่รู้ผล
  - #67 ตัดสินเรื่อง auto-deploy
- **DB `pos` ของ dev ในเครื่องนี้:**
  - ใช้ migration `1788652802131` แล้ว → `pos_app` มี `statement_timeout=25s` และ `idle_in_transaction_session_timeout=5s`
  - แอปที่รันค้างอยู่ต้อง restart ถึงจะได้ค่าใหม่
- **checkout หลักในเครื่อง:** มี session ของอีกแผนกใช้ร่วมอยู่ รอบนี้ทำทุกอย่างใน worktree และไม่ `git pull` ให้

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร
| PR | ปิด ticket | ผล |
|---|---|---|
| #197 | #183 | `ApiClient` timeout: อ่าน/refresh 15 วินาที, เขียน 40 วินาที · `ApiTimeoutException` ไม่นับเป็น verdict · fallback 21 จุดของ #55 rethrow · รีวิว 2 รอบ · 301 tests |
| #198 | #182 | scheduler ของ `idem.cleanup` รันทุกชั่วโมง อยู่ใน `QueueSchedulerModule` ซึ่ง import ได้จาก `WorkerModule` เท่านั้น · e2e พิสูจน์ว่าลบข้อมูลของ 2 tenant ได้จริงและ Redis สะอาดหลังรัน |
| #205 | #201 | backoff เปลี่ยนเป็น builtin `{type:'exponential', delay:1000, jitter:1}` · ลบ `jitter-backoff.ts` · ถ้าถอดออก e2e แดง |
| #204 | #188 | `GET /doc-counters` (`pos` เท่านั้น, เครื่องที่ retire แล้วได้ 403) · Drift **schema v6** ใช้ `deviceId` เป็น key · `TENANT_PERIOD_SQL` ตัวเดียวใช้ร่วมกัน · ดึงค่ามาตั้งเป็น `max(local, server)` ใน transaction เดียว · 316 tests |
| #215 | #213 | commit guard 25 วินาทีใน `runTx` และ `TenantJobRunner` + role timeout 25 วินาที/5 วินาที · `TenantJobRunner` ไม่ทำ DLQ หายตอน rollback หรือ BEGIN ล้มแล้ว · รีวิว 2 รอบ · e2e 477 |
| #208, #209 | #200, #199 | อีกแผนกเปิดและ merge เอง **โดยไม่มีรีวิว** · รีวิวย้อนหลังแล้วไม่เจอปัญหาร้ายแรง ไม่ต้อง revert → งานที่ตามมาอยู่ใน #219 |
| #210 → #214 | #187, #191 | บันทึกคำตอบลง ADR-0004/0009/0010 และ 01_DATABASE · #214 แทนที่ #206 (ปิดโดยไม่ merge) และแก้คำตอบที่ #210 บันทึกไว้ |
| #202, #203, #207, #218 | – | `CLAUDE.md` / `AGENTS.md` / ADR-0010 ตาม PR ข้างบน · #202 รวม commit เรื่อง Monitoring ของเจ้าของโปรเจกต์ด้วย |

**ticket ที่เปิดรอบนี้:**
- #182–#196: ใบรวม phase 1 close-out และความเสี่ยงของ phase 2
- #199–#201: ติดตามจากรีวิว #183
- #211–#213: ลงมือตามที่เคาะ #187/#191
- #217: import ประทับ `updated_at` ย้อนหลัง
- #219–#221: ติดตามจากรีวิว #208/#209

**ขั้นตอนที่ใช้กับทุก PR:**
1. agent implement โดยใช้ `karpathy-guidelines`
2. agent เปิด PR แต่ห้าม merge
3. agent อีกตัวรัน `/code-review` + `/scrutinize` แยกกัน พร้อม probe
4. ส่งผลรีวิวกลับให้ agent เดิมแก้
5. CI เขียว → ผู้ใช้สั่ง merge → อัปเดต docs

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร
- **#187 ล็อกอินออฟไลน์** (เจ้าของโปรเจกต์เลือก #206 แต่แก้บางข้อ):
  - PIN ออฟไลน์แยก ใช้ได้เฉพาะ `cashier` · hash ผูกกับเครื่อง · ใช้ได้ภายใน **3 วัน** นับจากล็อกอินออนไลน์ล่าสุดบนเครื่องนั้น · ใช้ได้เฉพาะตอน Degraded · `/sync/push` ตรวจซ้ำ
  - ไม่ cache `users.pin_hash` เพราะ PIN 4–6 หลักแกะได้แบบออฟไลน์ และจะได้ PIN ผู้จัดการตัวจริงไปด้วย
  - ข้อที่ #206 เสนอแต่**ไม่รับ**: ห้าม void ตอนออฟไลน์ และผูก refresh token กับ `deviceToken`
- **#191 stock ตอน reconnect:**
  - push outbox ก่อน แล้ว pull · สินค้าที่มีรายการค้างใน outbox จะไม่ถูกเขียนทับจนกว่า push สำเร็จ
  - `offlineOk` คำนวณที่ client
  - cursor ใช้ keyset `?updatedSince=&afterId=` ถอยย้อนหลัง **30 วินาที** + tombstone · ไม่สร้าง `change_log`
- **#201:** ใช้ jitter ที่มีใน BullMQ แทน strategy ที่เขียนเอง
  - strategy ของ BullMQ ต้องลงทะเบียน**ต่อ Worker** ตัว processor ใหม่จึงลืมได้
  - ถ้า strategy throw job จะค้าง `active` เหมือนบั๊กเดิม
  - Orchestrator ตัดสินใจเองจากผลรีวิว ผู้ใช้ไม่ได้คัดค้าน
- **#213:** เปลี่ยนจาก role timeout 5 วินาทีเป็น commit guard 25 วินาที + timeout 25/5 วินาที
  - รุ่น 5 วินาทีทำให้ report ทั้งหมดพัง (ทดสอบแล้ว)
  - Postgres 16 ไม่มี `transaction_timeout` จึงคุม k statement ได้ด้วย guard เท่านั้น
- **#188:** ใช้ `deviceId` เป็น key แทนการล้างตารางตอน enrol ใหม่ เพราะไม่มีทางลืมล้าง และ schema v6 ยังไม่ได้ปล่อย

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)
- **role `statement_timeout=5s` สำหรับ `pos_app`:** report ทั้งหมดของข้อมูล 550k บิลได้ 57014 ที่ 5010 ms และทำให้ `503 IDEMPOTENCY_KEY_IN_FLIGHT` เกิดไม่ได้ เพราะมีค่าเท่ากับ `CLAIM_LOCK_TIMEOUT`
- **custom backoff `'exponential-jitter'` + `WORKER_SETTINGS` ต่อ processor:** ใช้ได้ แต่เปราะ และ throw สำหรับ type ที่ไม่รู้จัก → เปลี่ยนไปใช้ builtin
- **ลงทะเบียน scheduler ใน `QueueProcessorsModule`:** e2e ทุกไฟล์ที่ import module นี้ไปลงทะเบียน scheduler ด้วย และไล่ลบข้อมูลของ tenant ทั้ง 10 ใน dev
- **e2e ที่ `pause()` คิวหลัง boot:** job แรกรันไปแล้วภายใน 20–35 ms (BullMQ 6.3.4 ไม่รอให้ตรงต้นชั่วโมง)
- **counter ของ #188 ที่ใช้ `deviceNo` เป็น key:** enrol ข้าม tenant แล้ว counter และเครื่องหมาย "ดึงค่าแล้ว" ค้างมาด้วย
- **`gh pr create` / `gh pr edit`:** ติด GraphQL error เรื่อง Projects (classic) → ใช้ `gh api -X POST/PATCH repos/NuimanLP/srisurart-pos-flutter/pulls` แทน
- **`timeout` ใน zsh ของเครื่องนี้ไม่มี** และ `env -u` ถูก sandbox บล็อก → agent ใช้ node spawn wrapper รัน test แบบไม่มี env แทน

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์
- **ยังไม่ได้วัดบน VM:** ตัวเลข report (8.5–9.6 วินาทีต่อข้อมูล 550k บิล) วัดบน Mac · เครื่อง vCPU ที่แชร์กันน่าจะช้ากว่า 2–4 เท่า — ยังไม่ได้วัด
- **อนุมาน ยังไม่ได้ทดสอบ:** #221 จะถึงทางตันจริงไหม ขึ้นอยู่กับว่า `_outstanding` หักยอดที่ค้างใน outbox แล้วหรือยัง
- **ไม่รู้ที่มา:** `'ยอดชำระเกินยอดหนี้คงเหลือ'` มาจาก JS เดิมหรือถูกแต่งขึ้นใหม่
- **ยังไม่ได้ลองบน Windows:** แก้ path separator ของ contract test ใน #204 แล้ว
- **ยังไม่ได้ติ๊กพร้อมหลักฐาน:** DoD ของ phase 1 ใน `03_ARCHITECTURE.md §8` เหลือ 15 ข้อ เดาว่าหลายข้อมี e2e อยู่แล้ว
- **ยังไม่เคาะใน ADR-0009:**
  - PIN ออฟไลน์ต้องห้ามซ้ำกับรหัสที่ใช้ออนไลน์ไหม
  - หลังเน็ตกลับ ต้องล็อกอินใหม่ หรือแลกเป็น JWT เบื้องหลัง (#206 เสนอแบบหลัง แต่ไม่มี credential ของตัวคนให้ server ตรวจ)
  - void ตอนออฟไลน์

## 6. ก้าวถัดไป (เรียงลำดับ)
1. **เจ้าของโปรเจกต์:** #186 รันคำสั่งท้าย `07_CICD_DEPLOY.md §4` — หลาย session merge เข้า `main` พร้อมกัน และ #208/#209 merge ไปโดยไม่มีรีวิว
2. **agent:** #219 และ #221 ขนานกันได้ แต่แตะ `counter_error_resolver_widget_test.dart` ร่วมกัน → merge ใบหนึ่งก่อนแล้วอีกใบ rebase
3. **agent:** ไล่ติ๊ก DoD phase 1 (`03 §8`) พร้อมลิงก์ e2e ข้อที่ไม่มีหลักฐานให้เปิด ticket (ยังไม่มี ticket)
4. **เจ้าของโปรเจกต์:** #184 ใส่ `ETCD_ROOT_PASSWORD` + `GRAFANA_ADMIN_PASSWORD` ใน `DEMO_ENV_FILE` → `provision.yml` → สร้าง network ใหม่ (#156) → `deploy.yml` · จากนั้น agent รัน k6 และวัด report บน VM
5. **agent:** #217 ต้องเสร็จก่อนข้อ 6 ถ้าร้านมีเครื่องที่ sync อยู่แล้ว
6. **เจ้าของโปรเจกต์:** #185 ขอ snapshot จากร้าน → agent ไล่ checklist 6 ข้อใน `01 §9`
7. **ร้านหรือเจ้าของโปรเจกต์:** #220 ข้อความ "ยังไม่รู้ผล" และจะล็อกตะกร้าไหม
8. **เจ้าของโปรเจกต์:** #67 จะเปิด auto-deploy หรือย้ายไป phase 2
9. **ปิดรอบ:** อัปเดต `CLAUDE.md` แล้วปิดใบแม่ #196, #2, #10, #60
10. **แล้วค่อยเริ่ม phase 2:** แตก ticket q2 (outbox, degraded mode, `/sync/push`) ซึ่งตอนนี้ขวาง #189 #190 #193 #194 #195 #211 #212

## 7. ข้อควรระวัง
- 🔴 **รัน test แบบไม่มี env ค้างเสมอ:** รอบแรก #205 เขียวในเครื่องแต่แดงใน CI เพราะ shell มี `DATABASE_URL` ค้างอยู่
- 🔴 **2 session ทำงานเดียวกัน:** #206/#210 บันทึกคำตอบของเจ้าของต่างกัน → ใช้ worktree ของใครของมัน และประกาศว่าใครถือ ticket ไหน
- 🔴 **DB ของ dev ที่เคยรัน migration id `1788652802130`** (อยู่บน branch ช่วงสั้น ๆ): ต้องลบแถวนั้นจาก `migrations` แล้ว migrate ใหม่ ถ้าไม่ทำจะติดค่า 5 วินาที (`DbModule` จะเตือนตอน boot)
- 🔴 **อย่าตั้ง `statement_timeout` ≤ `CLAIM_LOCK_TIMEOUT`**
- 🔴 **ทางเขียนตารางที่ client ดึงด้วย `updated_at` ต้อง commit ผ่าน guard** · job export ของ tenant เป็นข้อยกเว้นเดียว
- 🔴 **backoff ต้องเป็น builtin** · scheduler อยู่ใน `QueueSchedulerModule` เท่านั้น · เปลี่ยนชื่อ scheduler id ต้องลบตัวเก่าใน Redis
- 🔴 **เครื่องหมาย "ดึงค่าแล้ว" ของ #188 ไม่ได้แปลว่า counter เป็นค่าล่าสุด** (hazard บันทึกไว้ที่ #189)
- **ถ้า `gh` ติด rate limit:** รอแล้วลองใหม่ หรือใช้ `gh api`

## 8. อ้างอิง
- ใบรวม: #196 · ADR: `docs/Backend_design/adr/0004`, `0007`, `0009`, `0010` · [`owner-decisions-187-191.md`](owner-decisions-187-191.md)
- `server/README.md`: *The transaction ceiling (#213)*, *Idempotency* (scheduler)
- `CLAUDE.md`: หัวข้อ Merged 2026-09-15 (#182, #183, #187/#191, #188, #199/#200, #201, #213)
- ผู้ที่ต้องถาม: เจ้าของโปรเจกต์ `NuimanLP` (#67, #184–#186, #220) · `PattaraponKitcharoen` (#67, queue/ops) · `LomerAlloys` (import/reports ที่เกี่ยวกับ #217)
