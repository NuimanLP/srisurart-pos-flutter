# Handoff — เคลียร์ backlog ค่ำ 2026-09-30: ปิด #67/#346/#10/#60 + แก้ backup-db.sh

เอกสารล้วน (PR นี้) · การเปลี่ยนแปลงจริงทำบน `mob04` / GitHub ก่อนหน้า · ไม่มีค่า secret ในไฟล์นี้ · VPN หลุดซ้ำหลายรอบระหว่างวัน

## ที่ทำ (ตรวจแล้ว 2026-09-30 เย็น)
- **Deploy ที่อนุมัติ (ตรวจ SHA กับ head ของ `main`):** `4f4d86c` run `36714408818` สำเร็จ (ตรวจ `.current_sha` บน VM, ready 200) ·
  run ซ้ำที่คิวไว้ `36714438828` ยกเลิก · `00d3488` (แก้ CORS #516) run `36717963989` สำเร็จ, Ansible `failed=0`, `.current_sha` = `00d3488` ตรวจบน VM ภายหลัง
- **CORS:** `Origin` แปลกหน้าไม่ได้ 500 แล้ว — request เสิร์ฟตามสถานะปกติของ route (เช่น `/health/live` 200 ตาม e2e ของ #516) แต่ไม่มี `Access-Control-Allow-Origin` · origin ตัวเอง `https://172.30.58.20` ได้ ACAO
- **PR #518 merged** (docs: #516 deployed + แก้ข้อความ SLI — 500 ของ foreign-Origin ไม่เคยถูกนับใน `http_requests_total`) · commit ที่สอง `dc64f2c` ถูก push หลัง merge → cherry-pick มาใน PR นี้
- **#67 ปิด 15/15** (หลักฐาน 14 ข้อ: comment https://github.com/NuimanLP/srisurart-pos-flutter/issues/67#issuecomment-5912257527 · ปิดด้วย comment 5913430909 ข้างล่าง):
  - AC seed `log_level` — runs `36719282689`, `36720120003` · dispatch SHA เดิม (และ `.env` ไม่เปลี่ยน) จบก่อน etcd-init และ `deploy.yml` ไม่มี input `force` → ทดสอบ seed ซ้ำต้องเปลี่ยน SHA จริง
  - AC concurrency (สอง deploy ไม่รันพร้อมกัน) — `36720120003` / `36720131701` · job ที่รอ approval ถือ slot `deploy-demo` อยู่แล้ว
  - AC readiness ล้ม → run แดง + AC ไทย "playbook fail → rollback อัตโนมัติ" — `36720675552` (หยุด `redis-cache` ระหว่าง deploy) · กลไกคือ `pos-deploy` รัน playbook ของ release ก่อนหน้าซ้ำ **ไม่ใช่** `rescue:` ของ Ansible · readiness พึ่ง `redis-cache` แต่ `/health/live` ไม่พึ่ง
  - AC ไทย hook ปฏิเสธ branch อื่น — `36721404240` (แดง คาดไว้)
  - ครึ่ง fork: พิสูจน์จากโค้ด + settings เท่านั้น owner ยอมรับ **ไม่มี run fork จริง** (comment https://github.com/NuimanLP/srisurart-pos-flutter/issues/67#issuecomment-5913430909)
- **ปิด:** #67, #346 (สคริปต์ backup รันใน env ของ cron ผ่าน, dump ตรวจแล้ว — comment 5913495869), #10 (comment 5913517855), #60 (comment 5913538892)
- **ติ๊กบางส่วน:** #443 — 403-at-both-layers พิสูจน์บน `mob04` (comment 5913452241) · #335 AC7/8/10/11 (comment 5913468668) · #196 ติ๊กกล่อง #67 และแก้บรรทัด #184 ที่ล้าสมัย
- **PR #519 merged** (`b089f36`): `backup-db.sh` เขียน `$BACKUP_FILE.partial` แล้ว `mv` เมื่อสำเร็จ · EXIT trap ลบ partial · prune ลบ `.partial` ค้างตามอายุ · เทสต์ใหม่ `deploy/scripts/test/backup-db.test.sh` รันใน job `nginx-check` ของ `server.yml`

## แก้ข้อมูลเดิมที่ผิด
- ก่อนหน้านี้เขียนว่า "cron 03:00 เรียกสคริปต์ที่ไม่มีอยู่" — **ไม่ถูกทั้งหมด:** 03:00 ของ 2026-09-29 สคริปต์*มีอยู่* แต่ **fail** ("Neither active docker compose postgres container…" ทิ้ง .gz ว่าง 20 ไบต์) · เฉพาะ 03:00 ของ 2026-09-30 ที่ "not found" (แก้ใน `CLAUDE.md`, handoff `session-2026-09-30-first-runner-deploy.md`, tutorial, คู่มือ IT)
- checklist #344 ข้อ 🔴5 (Origin แปลก → 500) ล้าสมัยแล้ว — ทำเครื่องหมายใน `demo-344-checklist-2026-09-30.md`

## บทเรียน
- 🔴 **`provision.yml` เป็นตัวติดตั้ง `/opt/pos/scripts` ทางเดียว** — CD ไม่อัปเดต `backup-db.sh` บน VM · แก้สคริปต์ใน `main` ≠ VM ได้สคริปต์ใหม่
- 🔴 **PR merge ก่อน commit ที่สอง push** เกิดซ้ำ (#518 / `dc64f2c`) — เช็ค `gh pr view N --json headRefOid` ตอน merge
- job ที่รอ approval กิน concurrency slot — อย่าคิว dispatch ทดสอบซ้อนโดยไม่รู้
- rollback อัตโนมัติ = `pos-deploy` รันซ้ำ ไม่ใช่ `rescue:` — อย่าเขียนในเอกสารว่าเป็น Ansible rescue

## สถานะ `backup-db.sh` (#519) บน VM — ~~ยังไม่ได้ติดตั้ง (VPN หลุด)~~ **ติดตั้งแล้ว (แก้ 2026-09-30 ค่ำ)**
ลงแล้วด้วย `sudo install -o deploy -g deploy -m 0755` จาก `origin/main` · sha256 `fa65dbd5…` ตรง `origin/main` · ไฟล์เดิมเก็บเป็น `/opt/pos/scripts/.backup-db.sh.prev-be9e7f3`
รันหนึ่งครั้งด้วย env แบบ cron (cwd `/home/deploy`, `env -i PATH=/usr/bin:/bin`) → rc=0 · `pos_backup_20260930_153554Z.sql.gz` 9580 ไบต์ · `gzip -t` ผ่าน · sha256 sidecar OK · ไม่มี `.partial` · offsite `::warning::` ตามคาด (#363 พัก)
รอบ cron จริงรอบแรกของสคริปต์ที่ติดตั้ง: 03:00 ของ 2026-10-01 — ตรวจ `backup-cron.log` และไฟล์ใน `/opt/pos/backups` (ไม่มี `.partial` ค้าง) · **ยังไม่ได้เห็น** จนกว่าจะถึงรอบนั้น

## ยังเปิด / ต้องใช้ owner หรือฮาร์ดแวร์
- ~~**Deploy (demo) ของ `b089f36` (run `36733325970`) รอ approval อยู่** และถือ slot `deploy-demo` — VM ยังเป็น `00d3488`~~ **แก้ 2026-09-30 ค่ำ:** run `36733325970` ถูก cancel แล้ว · Deploy run `36736199413` ของ `main` head `ca2fef1` ได้ approve → deploy สำเร็จ `failed=0` · VM `.current_sha` = `ca2fef1`, `/health/ready` 200 · approve ไม่ลง `backup-db.sh` ใหม่ (มีแต่ `provision.yml`) · ห้าม approve ระหว่างเดโม #344 · (run `36721768736` ของ `b4107b0` เขียวแต่ job `deploy` ถูก skip — ไม่มีอะไรถึง VM; `36721921531` ถูก cancel แทนด้วย run ของ `b089f36`)
- **#344** เดโมคนจริง — checklist `demo-344-checklist-2026-09-30.md` · #338 ครึ่ง VM ต้องรหัสผ่าน admin คนจริง (ทำใน #344)
- **#380** k6 3 เครื่อง · **#476** owner · **#443** owner ถ้อยคำ + AC "เฉพาะ `bootstrap:admin` สร้าง admin" ขัดกับการ sync `PLATFORM_ADMINS` ที่ owner รับรองแล้ว · **#231** owner · **#363/#288** พักไว้ · **#2/#196** parent

## ต่อไป
1. ~~ลง `backup-db.sh` ใหม่บน `mob04`, ตรวจ sha256~~ (ทำแล้ว ดูหัวข้อ late) · 2. พรุ่งนี้ตรวจ cron 03:00 · 3. #344 ตาม checklist (CORS ข้อ 5 ข้ามได้แล้ว)

## Late (2026-09-30 ~15:40Z) — #521 recovery, ล้าง branch, deploy `ca2fef1`
- **PR #521 merged** (`ca2fef1`): กู้ review fix ของ PR #486 (`GET /settings` เก่ากลบ `PATCH` ใหม่ — guard `_writeGen` ใน `frontend/lib/data/repositories/api_settings_repository.dart`) · commit `47653b1`/`c57019a` ถูก push **หลัง** #486 merge (2026-09-28 01:21:43Z, head `e81abd9`) จึงไม่เคยถึง `main`
- **ล้าง remote branch:** ลบ 35 branch ที่ merge แล้ว หลังตรวจทีละอัน (เป็น ancestor ของ `main` · หรือ PR MERGED และ tip == PR head · หรือ commit หลัง merge patch-id เทียบเท่าบน `main`) · เหลือ `main` + `POC_sample_offline_first`
- 🔴 **บทเรียน:** ก่อนลบ branch ของ PR ที่ merge แล้ว เทียบ tip ของ branch กับ `headRefOid` ของ PR — ไม่ตรง = มี commit หลัง merge ที่อาจหาย (#486 ถูกพบด้วยวิธีนี้)
- **Deploy `ca2fef1`:** run ค้างรอ `36733325970` (`b089f36`) ถูก cancel · `36736199413` ได้ approve → "Successfully deployed release ca2fef1…", Ansible `failed=0`, `.current_sha` = `ca2fef1`, `/health/ready` 200
