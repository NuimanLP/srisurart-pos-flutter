# Handoff — runner #67 ติดตั้ง + deploy จริงครั้งแรกถึง `mob04` (2026-09-30)

เอกสารล้วน (PR นี้) · การเปลี่ยนแปลงจริงทำบน `mob04` / repo settings ก่อนหน้า · ไม่มีค่า secret ในไฟล์นี้

## ที่ทำ (ตรวจแล้ว 2026-09-30)
- ติดตั้ง self-hosted runner `mob04-demo` บน `mob04` ด้วย `deploy/scripts/setup-mob04-runner.sh` — runner v2.337.0 linux-x64
  (ตรวจ sha256), label `self-hosted`/`Linux`/`X64`/`srisurart-demo-deploy`, service user `gha-runner` (กลุ่มเดียว),
  `/etc/sudoers.d/pos-deploy` ลงแล้ว, sudo self-test ผ่าน · `gh api …/actions/runners` = 1 online
- Fork-PR approval: `first_time_contributors` → `all_external_contributors` (เจ้าของอนุมัติ)
- Environment `demo`: `deployment_branch_policy` = `{protected_branches:false, custom_branch_policies:true}` + branch policy `main`;
  required reviewer `NuimanLP` คงเดิม
- ยกเลิก run ค้างของ `639238f` (36551431740) · run `36591519465` (`e50f4fa`) `NuimanLP` อนุมัติ

## หลักฐาน
- Actions: 2 job เขียว, deploy 2m3s, hook `job-started` อนุญาต, Ansible `ok=48 changed=27 failed=0 ignored=2`
  (ignored 1 = ไม่มี `.current_sha` ครั้งแรก — คาดไว้), pull จาก GHCR สำเร็จ
- บน VM: `/opt/pos/.current_sha` = `e50f4fa983cada763e1e6ba4d7c84509682f58e0` · `curl -k https://localhost/health/ready` = 200
  (postgres, redisCache, redisQueue up)
- healthy: postgres, redis-cache, redis-queue, etcd, api x3, prometheus, grafana, node-exporter · up ไม่มี healthcheck: nginx,
  platform-ui, worker, bull-board · certgen/htpasswd-gen exit 0

## ยังเปิด (ห้ามอ่านว่าเสร็จ)
- platform-ui login ยังไม่มีคนทดสอบจริง (admin มีแล้ว — ดูหัวข้อ "ต่อมา")
- auto-rollback และ rollback ด้วย `workflow_dispatch` ของ #67 ยังไม่เคยพิสูจน์ด้วย run จริง
- #344 (demo e2e) ยังไม่รัน · ไม่มี AC ของ #343 ที่ถูกติ๊ก (run นี้หนุนฝั่ง "deploy ถึง VM")
- #365 etcd auth ยังไม่แตะ
- CORS: `Origin` แปลกหน้าได้ **HTTP 500** (`app.setup.ts:67` throw `Error('Not allowed by CORS')`) แทนการปฏิเสธเรียบร้อย — พฤติกรรมเดิม นับเป็น 5xx ใน SLI · follow-up ไม่แก้ใน PR นี้
- #363/#288 backup พักไว้ → ยังไม่มี backup ออกจาก VM

## ต่อมา 2026-09-30 (orchestrator ตรวจบน VM)
- รัน `provision.yml` จาก `origin/main` สะอาด: `ok=18 changed=3 failed=0` · `.env` เขียนใหม่จากสำเนาของเจ้าของ — คีย์ที่**เพิ่ม**มีแค่
  `PLATFORM_ADMINS` (3 รายการ) อีก 17 คีย์เหมือนเดิมทุกตัว · สำรองเดิมไว้ที่ `/opt/pos/.env.bak-2026-09-30-0431`
- `CORS_ORIGINS=https://172.30.58.20` **มีอยู่ใน `.env` ของ VM ก่อนแล้ว** → CORS บน `mob04` ปิดแล้ว (ไม่ใช่ `'*'`) ตั้งแต่ deploy แรกของ runner ·
  ตรวจ: origin ตัวเองได้ `Access-Control-Allow-Origin: https://172.30.58.20`, origin อื่นไม่ได้ ACAO (แต่ได้ 500 — ดู "ยังเปิด")
- provision สร้าง `/opt/pos/scripts` + ลง `backup-db.sh`/`restore-db.sh`/`measure-container-rss.sh` — **ก่อนหน้านี้ cron 03:00 เรียกสคริปต์ที่ไม่มีอยู่**
  (backup ในเครื่องไม่เคยรัน) · offsite ยังพักไว้ (#363)
- Deploy (demo) แบบ dispatch run `36669582543` (`e50f4fa`) อนุมัติแล้ว สำเร็จ · `.env_applied_sha256` = hash ของ `.env` ใหม่ · api×3 สร้างใหม่ healthy ·
  `/health/ready` 200 · log api-1 `PLATFORM_ADMINS synced` สร้าง 3 · `platform_admins`: `lomer`, `nuiman`, `pattarapon` active (ไม่บันทึกรหัส)
