# Handoff — 2026-10-01 (เช้า UTC): CI แดงเพราะข้ามเดือน · บทเรียน 19 · deploy `4832172`

ต่อจาก [`session-2026-09-30-evening-clear-backlog.md`](session-2026-09-30-evening-clear-backlog.md).

## สถานะท้ายรอบ
- `main` = `4832172` · VM `mob04` `.current_sha` = `4832172`, `/health/ready` 200 (ตรวจบน VM หลัง run `36807431940`)
- ไม่มี PR เปิด · ไม่มี Deploy run ค้างรอ approve · remote branch เหลือ `main` + `POC_sample_offline_first`

## ทำอะไรไป
1. **บทเรียนใหม่ `docs/study/19_deploy_mob04_story.md`** (สไตล์ study-and-learn, ภาษาไทย) — เล่าการ deploy ขึ้น `mob04` ทุกขั้น 2026-09-29 → 10-01: pipeline, สองเพลย์บุ๊ก/สอง user, blocker ที่เคลียร์, หลักฐานทุก run, วิธี deploy/rollback เอง, กับดัก · ผ่าน fact-check (แก้ 10 จุด) · **PR #524** (commit เดิม `0fa93ad` ถูก push ไป branch ของ #523 *หลัง* merge → cherry-pick มาเปิด PR ใหม่ — กับดักเดิมซ้ำอีกครั้ง)
2. **CI `main` แดงตั้งแต่ 2026-10-01** — `server/test/sync-push.e2e-spec.ts` 2 เทสต์ได้ `date_flag` 2 แทน 1 (run `36804787819`, `36804171179`) · สาเหตุ: เทสต์ hardcode เลขใบเสร็จ `RC01-2569-09-…` แต่ sale ถูกเก็บที่ `now()` → พอข้ามเดือน server ติด flag เดือนไม่ตรงถูกต้องตาม 08 §10 · **เป็นบั๊กเทสต์ ไม่ใช่ server** · พิสูจน์โดยตั้งนาฬิกา Node เป็น 2026-09-20 แล้วผ่าน · แก้ด้วย helper `currentPeriod()` (เดือนไทยปัจจุบันแบบ Asia/Bangkok) — **PR #525** (`fdeaef7`)
3. **merge `main` เข้า #524** (merge ไม่ rebase) → CI เขียว → merge (`4832172`)
4. **Deploy:** cancel run ค้าง `36742768824`/`36742775298` (`6384e20`, docs) · run `36807043345` (`4832172`) เขียวแต่ job `deploy` skip (image ยังไม่พร้อม — ปกติ) · run `36807431940` approve หลังเช็ค SHA = `main` → success → VM `4832172`

## บทเรียน
- 🔴 **เทสต์ที่ผูกกับเดือน/วันปัจจุบันจะพังวันข้ามเดือน** — RC/CN period ต้องคำนวณจาก "ตอนนี้" ตาม timezone ของ tenant (Asia/Bangkok) ไม่ hardcode · CI แดง = ไม่มี image = ทุก deploy skip เงียบ (กฎเดิมใน CLAUDE.md)
- 🔴 **push หลัง PR merge = ไม่ถึง `main`** เกิดอีกครั้ง (#523 → `0fa93ad`) — เช็ค `gh pr view N --json state` ก่อน push ต่อ branch เก่า
- job ที่รอ approve ถือ slot `deploy-demo` → cancel run ที่ถูกแทนแล้วก่อน

## ยังเปิด
- **cron 03:00 UTC 2026-10-01** (รอบจริงแรกของ `backup-db.sh` จาก #519) — **ยังไม่ได้ตรวจ** (owner ให้ข้าม) · ตรวจ `backup-cron.log` + `/opt/pos/backups` (ไม่มี `.partial`) เมื่อสะดวก
- #344 เดโมคนจริง · #380 k6 3 เครื่อง · #476 / #443 / #231 owner · #363/#288 พักหลังเดโม
