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

## คำสั่งจริง (sanitized)

รวมคำสั่งของ 2026-09-30 ตามลำดับ (ปิด AC "คำสั่งจริงบันทึกใน `docs/handoff_log/`" ของ #343 และ #365) · ใช้เฉพาะสิ่งที่มีบันทึกไว้ —
ที่ไม่มีบรรทัดตรงตัวเขียนว่า "(คำสั่งตรงตัวไม่ได้บันทึก — ดู …)" · ไม่มีค่า secret: `<TOKEN>`, `<SHA256>`, `<RUN_ID>` คือ placeholder ·
รหัสผ่านทุกตัวอ่านจาก `/opt/pos/.env` หรือ env ของ container **ในเชลล์ปลายทาง** ไม่พิมพ์ออก

### A. รอบ runner + deploy แรก (#67, #366)
1. Fork-PR approval `first_time_contributors` → `all_external_contributors`:
   ```bash
   gh api -X PUT repos/NuimanLP/srisurart-pos-flutter/actions/permissions/fork-pr-contributor-approval \
     -f approval_policy=all_external_contributors
   ```
2. Environment `demo` — branch policy (`07_CICD_DEPLOY.md` §6.2 ข้อ 2 · ตรวจผลด้วย `gh api repos/NuimanLP/srisurart-pos-flutter/environments/demo --jq '.protection_rules'`):
   ```bash
   gh api -X PUT repos/NuimanLP/srisurart-pos-flutter/environments/demo --input - <<'JSON'
   {
     "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true },
     "reviewers": [{ "type": "User", "id": 64192543 }]
   }
   JSON
   gh api -X POST repos/NuimanLP/srisurart-pos-flutter/environments/demo/deployment-branch-policies \
     -f name=main -f type=branch
   ```
   (ค่าที่ PUT ตรงกับผลที่ตรวจได้ตามหัวข้อ "ที่ทำ" — คำสั่งตรงตัวของวันนั้นไม่ได้บันทึกแยก อ้างจากขั้นตอนใน `07 §6.2`)
3. Token ลงทะเบียน runner (เครื่องเจ้าของ) → ส่งเข้า VM ทาง ssh stdin ไม่วางลง chat/issue:
   ```bash
   gh api -X POST repos/NuimanLP/srisurart-pos-flutter/actions/runners/registration-token --jq .token
   ```
   (คำสั่งตรงตัวของ ssh ที่ส่ง token ผ่าน stdin ไม่ได้บันทึก — ดู #67 และ `slice-25-cd2-runner-guide.md`)
4. ติดตั้ง runner บน `mob04` (รูปแบบจาก header ของสคริปต์; เวอร์ชันที่ใช้ 2.337.0 ตรวจ sha256 แล้ว):
   ```bash
   sudo bash setup-mob04-runner.sh <TOKEN> 2.337.0 <SHA256>
   ```
5. ตรวจ runner: `gh api …/actions/runners` = 1 online (บรรทัดตรงตัวไม่ได้บันทึก — ดู #67 https://github.com/NuimanLP/srisurart-pos-flutter/issues/67#issuecomment-5905499082)
6. ยกเลิก run ค้าง `36551431740` (`639238f`) (คำสั่งตรงตัวไม่ได้บันทึก — ดู #67 comment ข้างบน)
7. อนุมัติ run `36591519465` (`e50f4fa`) โดย `NuimanLP`:
   ```bash
   gh api -X POST repos/NuimanLP/srisurart-pos-flutter/actions/runs/<RUN_ID>/pending_deployments ...
   ```
   (ชื่อ endpoint ตามที่บันทึก; body ตรงตัวไม่ได้บันทึก — ดู #67 comment ข้างบน)
8. ตรวจบน VM (ผลอยู่ในหัวข้อ "หลักฐาน"): `/opt/pos/.current_sha` และ `curl -k https://localhost/health/ready`

### B. provision.yml re-run พร้อม `.env` (`VM-dploy-full-stack-tutorial.md` §2.5)
```bash
ssh mob04 'sudo -n cp -p /opt/pos/.env /opt/pos/.env.bak-$(date +%F)'
printf '%s\n' "$(cat ~/secrets/mob04-demo.env)" | shasum -a 256
ssh mob04 'sudo -n sha256sum /opt/pos/.env'
DEMO_ENV_FILE="$(cat ~/secrets/mob04-demo.env)" DEMO_SSH_KEY_PUB="$(cat ~/.ssh/deploy_ed25519.pub)" DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=cloud DEMO_SSH_KEY_PATH="$HOME/.ssh/mob04-SriStore" ansible-playbook provision.yml --check
```
- diff ต่อคีย์ (ตรวจว่าเพิ่มแค่ `PLATFORM_ADMINS`): คำสั่งตรงตัวไม่ได้บันทึก — ดู #343 https://github.com/NuimanLP/srisurart-pos-flutter/issues/343#issuecomment-5905500111 และหัวข้อ "ต่อมา" ข้างบน
- provision จริง = คำสั่ง `ansible-playbook provision.yml` เดียวกับข้างบน ไม่มี `--check` (ผล `ok=18 changed=3 failed=0`; ห้าม `--diff`; บรรทัดที่รันจริงไม่ได้บันทึกแยก)
- Deploy (demo) แบบ `workflow_dispatch` run `36669582543` (`e50f4fa`) + อนุมัติ `pending_deployments`: inputs และคำสั่งตรงตัวไม่ได้บันทึก — ดู #343 comment ข้างบน

### C. Grafana แยกจากผล playbook (#343 https://github.com/NuimanLP/srisurart-pos-flutter/issues/343#issuecomment-5906181492)
```bash
docker inspect --format '{{.State.Health.Status}}' srisurart-pos-grafana-1 srisurart-pos-prometheus-1
curl http://127.0.0.1:3000/api/health
curl '127.0.0.1:9090/api/v1/query?query=up'
curl -K - http://127.0.0.1:3000/api/dashboards/uid/srisurart-pos-overview   # admin creds จาก /opt/pos/.env ในเชลล์ปลายทาง ส่งผ่าน stdin
```
- `GET /api/datasources` (Grafana, ต้อง auth) · GET dashboard เดิมไม่ใส่ creds → 401 (ข้อความ comment บันทึกแค่ method/path)

### D. etcd auth (#365 https://github.com/NuimanLP/srisurart-pos-flutter/issues/365#issuecomment-5906185451)
ไม่มี `down -v` ไม่แตะ `.env`/volume · `$ETCD_ROOT_PASSWORD` อ่านจาก env ของ container `etcd-init` ในเชลล์ปลายทาง
```bash
# สภาพก่อนตรวจ
etcdctl auth status            # Authentication Status: true, AuthRevision: 4  (บรรทัด wrapper docker exec ไม่ได้บันทึก)
# AC1 สองทาง
docker compose … run --rm --no-deps --entrypoint curl etcd-init -X POST http://etcd:2379/v3/kv/range -d '{"key":"Lw=="}'   # ไม่มี creds → HTTP 400
docker exec -e ETCDCTL_USER= srisurart-pos-etcd-1 etcdctl get /pos/config/log_level                                        # rc=1 user name is empty
# POST /v3/auth/authenticate root + $ETCD_ROOT_PASSWORD → 200 · รหัสผิด → 400 (บรรทัด curl ตรงตัวไม่ได้บันทึก)
docker exec srisurart-pos-etcd-1 etcdctl get /pos/config/log_level                                                         # → info
# AC3
etcdctl snapshot save /opt/pos/backups/etcd-20260930T071608Z.db     # ตรวจด้วย etcdutl snapshot status (บรรทัด wrapper ไม่ได้บันทึก)
etcdctl put /pos/config/log_level debug
etcdctl put /pos/config/log_level info                              # คืนค่าเดิม
```
- `docker compose …` ย่อจาก comment ต้นทาง (ตัว `…` = ธง `-f`/`--env-file` ที่ไม่ได้บันทึก)
- ผล: api-1/2/3 log `Runtime config updated log level to 'debug' from etcd` แล้ว `… 'info' …` · `/health/ready` 200
