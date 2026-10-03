# 19 — เรื่องเล่าการ deploy ขึ้น `mob04`: จาก push หนึ่งครั้ง ถึง `.current_sha` บน VM

> บทนี้ตอบคำถาม: **"ช่วง 2026-09-29 → 2026-10-01 ทีมทำอะไรบ้างจน stack ของ Srisurart POS ขึ้น VM เดโม `mob04`
> ได้จริง ทุกกระบวนท่า — แต่ละชิ้นกันความผิดพลาดแบบไหน พิสูจน์ด้วยอะไร และถ้าต้องทำเองพรุ่งนี้ต้องพิมพ์อะไร"**

---

## 🧭 ก่อนอ่าน

- **ต้องอ่านก่อน:** [14_devops.md](14_devops.md) (Docker, Compose, Ansible, GHCR, Trivy คืออะไร) และ
  [15_cicd.md](15_cicd.md) (GitHub Actions, status job, "green ≠ deployed") — บทนี้**ไม่สอนซ้ำ**พื้นฐานพวกนั้น
- **เวลาอ่าน:** ~90–120 นาที (ถ้าลองไล่คำสั่งตามด้วย +1 ชั่วโมง และต้องต่อ VPN ของคณะ)
- **อ่านจบแล้วคุณจะ…**
  - วาด pipeline ตั้งแต่ `git push` ถึง VM ได้เองทั้งเส้น และบอกได้ว่าแต่ละด่านกันอะไร
  - อธิบายได้ว่าทำไมมี playbook สองตัว และ user บน VM สองคน (`cloud` กับ `deploy`) ที่สลับกันไม่ได้
  - เล่าได้ว่าวันที่ 29–30 ก.ย. มีอะไรขวางอยู่ และแต่ละตัวถูกปลดยังไง
  - ชี้หลักฐานจริง (run id, comment) ของการ deploy, rollback และการทดสอบล้มเหลวโดยตั้งใจได้
  - deploy / rollback / ตรวจผลเองได้ โดยไม่ตกหลุมพราง "ปุ่มเขียว = เสร็จ"

> 📅 **ที่มาของข้อเท็จจริงทุกข้อในบทนี้:** `CLAUDE.md`, `docs/handoff_log/session-2026-09-30-first-runner-deploy.md`,
> `docs/handoff_log/session-2026-09-30-evening-clear-backlog.md`, `docs/handoff_log/demo-344-checklist-2026-09-30.md`,
> `docs/Backend_design/07_CICD_DEPLOY.md`, `docs/tutorial/VM-dploy-full-stack-tutorial.md`, ไฟล์โค้ด
> `.github/workflows/deploy.yml`, `server.yml`, `flutter.yml`, `deploy/ansible/*.yml`, `deploy/scripts/*.sh`
> และตรวจซ้ำด้วย `gh run view` / `gh api` (อ่านอย่างเดียว) วันที่ 2026-10-01
> 🔒 บทนี้**ไม่มีค่า secret ใด ๆ** — มีแต่ชื่อคีย์ ห้ามเติมค่าจริงลงไปเด็ดขาด

---

## 🍱 1. เริ่มจากภาพในหัว: ครัวกลาง → สาขา

ลองนึกถึงร้านข้าวกล่องที่มี **ครัวกลาง** กับ **สาขา** หนึ่งแห่งนะครับ

| ในร้านข้าวกล่อง | ในระบบเรา |
|---|---|
| ครัวกลางทำอาหารตามสูตร แล้วชิมก่อน | **CI** (`Server CI`, `Flutter CI`) build + test |
| ตรวจสารปนเปื้อนก่อนบรรจุ | **Trivy** สแกน image ของ server |
| ปิดฉลากกล่องด้วย "เลขล็อต" | tag ของ image = **SHA ของ commit** |
| ห้องเย็นเก็บกล่อง | **GHCR** (`ghcr.io/nuimanlp/srisurart-pos-server` / `-web`) |
| ใบสั่งส่งของไปสาขา | workflow **`Deploy (demo)`** |
| ผู้จัดการต้องเซ็นก่อนรถออก | **required reviewer** (`NuimanLP`) บน environment `demo` |
| พนักงานรับของที่สาขา ทำได้แค่กดปุ่มเดียว | **self-hosted runner** `mob04-demo` (user `gha-runner`) → `sudo -u deploy pos-deploy` |
| ยามหน้าประตู ตรวจว่าใบสั่งมาจากสำนักงานใหญ่จริง | **job-started hook** (`runner-job-started.sh`) |
| เชฟสาขาเปลี่ยนเมนูทีละเตา ไม่ปิดร้าน | **Ansible `deploy.yml`** ทำ rolling restart `api-1 → api-2 → api-3` |
| ชิมจานสุดท้ายก่อนเปิดขาย | `GET /health/ready` ผ่าน Nginx ต้องได้ 200 |
| **ป้ายหน้าร้าน "วันนี้เสิร์ฟล็อต X"** | ไฟล์ **`/opt/pos/.current_sha`** บน VM |

ประโยคสำคัญที่สุดของบทนี้:

> 🟢 ไฟเขียวที่ครัวกลาง ≠ อาหารถึงสาขา
> **ป้ายหน้าร้าน (`.current_sha`) คือหลักฐานเดียว** ว่าสาขาเสิร์ฟล็อตไหนอยู่ — และป้ายนี้ถูกเปลี่ยนก็ต่อเมื่อชิมผ่านแล้วเท่านั้น

---

## 🧭 2. คำถามหลักของบทนี้

> ไม่ใช่แค่ "deploy เสร็จหรือยัง?"
> แต่คือ **"อะไรพิสูจน์ว่า VM รัน SHA นี้อยู่จริง — และถ้าพังกลางทาง ระบบถอยกลับเองได้ไหม โดยไม่มีใครต้องเดา?"**

ทุกหัวข้อข้างล่างจะย้อนกลับมาที่คำถามนี้เสมอ: ชิ้นนี้ช่วย *พิสูจน์* อะไร หรือช่วย *ถอยกลับ* ยังไง

---

## 🎭 3. แยก "ดูเหมือนเสร็จ" ออกจาก "เสร็จจริง" ก่อน

ก่อนลงรายละเอียด ต้องแยกให้ออกก่อนว่าอะไรเป็นแค่สัญญาณ อะไรเป็นหลักฐาน

| ❌ ดูเหมือนเสร็จ (สัญญาณ) | ทำไมไม่พอ | ✅ เสร็จจริง (หลักฐาน) |
|---|---|---|
| run `Deploy (demo)` สีเขียว | job `deploy` ถูก **skip** ได้ (image ยังไม่ครบ) แต่ทั้ง run ยังขึ้น *success* | `cat /opt/pos/.current_sha` = SHA ที่ตั้งใจ |
| PR merge แล้ว | commit ที่ push **หลัง** กด merge ไม่ถึง `main` (เกิดจริงหลายครั้ง ดู §10) | `gh pr view N --json headRefOid` ตรงกับสิ่งที่คิด |
| `ansible-playbook --check` ผ่าน | `ansible.builtin.command` ไม่มี check mode → ข้ามหมด แถมทำ false positive | รันจริง + ตรวจ §8 |
| `PLAY RECAP … failed=0` | ไม่ได้บอกว่า SHA ไหน และไม่บอกว่า monitoring ล้มแค่เตือน | `.current_sha` + `/health/ready` 200 + `docker ps` เห็น tag ตรง |
| แก้ `backup-db.sh` ใน `main` แล้ว | **CD ไม่อัปเดต `/opt/pos/scripts`** — มีแต่ `provision.yml` ที่ลง | `sha256sum` ของไฟล์บน VM = ของ `origin/main` |
| `backup-cron.log` ไม่มี error | offsite ปิดอยู่ = exit 0 + `::warning::` (ตั้งใจ) | อ่านบรรทัด `::warning::`/`::error::` จริง |

ถามตัวเองทุกครั้งด้วยคำถามหลัก: *"สิ่งที่ฉันเห็นอยู่ พิสูจน์ว่า VM รัน SHA นี้ หรือแค่บอกว่ามีอะไรสักอย่างเขียว?"*

---

## 🗺️ 4. ภาพใหญ่: pipeline ทั้งเส้น

```text
dev: git push / merge PR เข้า main
   │
   ├──▶ Server CI ── lint · audit(pnpm audit + Trivy fs) · unit · integration · nginx-check
   │        │                         (ทุกตัวต้อง success)
   │        └──▶ build-image: docker build → smoke → Trivy image (HIGH/CRITICAL บล็อก) → push
   │                ghcr.io/nuimanlp/srisurart-pos-server:<sha>  (+ :main)
   │        └──▶ server-ci-status  ← required check ตัวเดียวของฝั่ง server
   │
   └──▶ Flutter CI ── analyze/test ── build-web → smoke image → push
            ghcr.io/nuimanlp/srisurart-pos-web:<sha>  (+ :main)
            └──▶ flutter-ci-status ← required check ตัวเดียวของฝั่ง Flutter
   │
   ▼  (CI แต่ละตัวจบ → ยิง workflow_run หนึ่งครั้ง = สองครั้งต่อหนึ่ง merge)
Deploy (demo)
   │
   ├─ job resolve (GitHub-hosted, ubuntu-latest)
   │     ├─ workflow_run: CI ที่ยิงมาต้องเป็น push บน main และจบ success — CI แดง = job นี้ถูก skip ทั้ง job
   │     ├─ หา SHA: workflow_run.head_sha หรือ input image_tag (ว่าง = head ของ main)
   │     ├─ ต้องเป็น commit บน main · workflow_run ต้องเป็น head ปัจจุบันของ main
   │     └─ verify-ghcr-tags.sh: image สองตัวที่ SHA นี้ครบไหม → images_ready
   │            exit 0 ครบ · exit 1 ยังไม่ครบ (workflow_run = notice จบเขียว) · exit 2 ถาม GHCR ไม่ได้ = แดง
   │
   └─ job deploy  (if images_ready == 'true')
         ├─ environment: demo → ⏸ "Waiting" จนกว่า NuimanLP กด approve  (branch policy: main เท่านั้น)
         ├─ concurrency: deploy-demo, cancel-in-progress: false
         ├─ runs-on: [self-hosted, srisurart-demo-deploy] → runner mob04-demo (user gha-runner)
         ├─ 🛂 job-started hook: รับเฉพาะ deploy.yml@refs/heads/main + workflow_run|workflow_dispatch
         └─ sudo -n -u deploy /usr/local/bin/pos-deploy auto|manual <sha40>
                 ├─ flock (รอได้ 5 นาที) · fetch main เอง · SHA ต้องอยู่บน main และไม่เก่ากว่า ROLLBACK_FLOOR
                 ├─ checkout SHA นั้น (compose/nginx/playbook ของ release นั้นเอง)
                 └─ ansible-playbook deploy.yml (connection=local, 20 นาทีต่อรอบ)
                        ├─ SHA ซ้ำ + .env ไม่เปลี่ยน → "Skipping duplicate deployment" จบ
                        ├─ network pre-flight · copy compose/nginx/etcd-init.sh
                        ├─ pull images · migrate (schema ก่อนโค้ด) · up datastores + etcd
                        ├─ etcd-init (เปิด auth + seed log_level ถ้าไม่มี) · assert อ่านแบบไม่มีรหัส = 400
                        ├─ api-1 → รอ healthy → api-2 → รอ → api-3 → รอ · worker + bull-board
                        ├─ web-sync · nginx -t แล้ว recreate nginx · platform-ui
                        ├─ GET https://127.0.0.1/health/ready (ผ่าน Nginx) = 200
                        ├─ เขียน /opt/pos/.current_sha  ← ป้ายหน้าร้าน
                        ├─ เขียน /opt/pos/.env_applied_sha256
                        └─ monitoring overlay (ล้ม = แค่ WARNING ไม่กระทบ POS)
                 ถ้า playbook ล้ม → pos-deploy รัน playbook ของ release เดิม (.current_sha) ด้วย force_redeploy=true
                                  → run ยังแดง (ตั้งใจ) แต่ VM กลับมาเป็นของเดิม
```

ดูยาว แต่จำเป็นชิ้น ๆ ได้ครับ ไล่ทีละด่านด้านล่าง

### ① CI + status job + image บน GHCR

- **นิยาม:** ทุก push ไป `main` จะ build image สองตัว ติด tag ด้วย SHA เต็ม แล้ววางบน GHCR
- **ใน `server.yml`:** job `build-image` มี `needs: [lint, audit, unit, integration, nginx-check]` และ `if:` ที่ต้องการให้ทุกตัว
  `success` — ถ้าตัวไหนแดง **ไม่มี image server** เลย Trivy สแกน image *ก่อน* login/push (HIGH/CRITICAL ที่แก้ได้ = บล็อก)
  และ ADR-0013 ห้ามมี `.trivyignore`
- **ใน `flutter.yml`:** job `build-web` build → smoke test (ต้องมี `index.html`, `sqlite3.wasm`, `drift_worker.js`, ไม่มี nginx,
  ไม่ EXPOSE port) → push ⚠️ ใน `flutter.yml` ที่อ่านมา **ไม่มีขั้น Trivy สำหรับ web image** — image ที่ถูก Trivy สแกนคือของ server
- **กันอะไร:** กันไม่ให้โค้ดที่ test ไม่ผ่าน หรือมี CVE ร้ายแรง ไปถึง VM ได้เลย เพราะ "ไม่มี image = ไม่มีอะไรให้ deploy"

### ② `resolve` — "จะ deploy SHA ไหน และของพร้อมไหม?"

- **นิยาม:** job บนเครื่องของ GitHub (ไม่แตะ VM) ที่ตัดสินว่ารอบนี้ควร deploy อะไร
- **คนในหัวของ job คิดว่า:** *"merge หนึ่งครั้งยิงฉันมาสองรอบ — รอบแรกคงเจอ image แค่ตัวเดียว ก็จบเงียบ ๆ ไป รอบสองค่อยเจอครบ"*
- **กฎสำคัญ:**
  - ใช้ `github.event.workflow_run.head_sha` ไม่ใช่ `github.sha` (ใน `workflow_run`, `github.sha` = head ของ main *ตอนนี้*)
  - **`workflow_run` deploy เฉพาะ head ปัจจุบันของ `main`** — merge สองครั้งติดกัน deploy แค่ตัวหลัง
    (เห็นจริง: run ของ `68c23e3` ขึ้น notice "main has moved on to `494ace3`")
  - `verify-ghcr-tags.sh` แยก "ยังไม่มี" (exit 1) ออกจาก "ถาม GHCR ไม่ได้" (exit 2 = แดงเสมอ) — registry ล่มต้องไม่ดูเหมือน "ยังไม่มา"
- **mini-scenario:** merge `494ace3` → run [36685569626] เจอ image ไม่ครบ → `deploy to demo` **skipped** ·
  run [36685602814] เจอครบ → deploy **success** (ยืนยันใน #67 comment 5912257527)

### ③ ด่านเซ็นอนุมัติ — environment `demo`

- **นิยาม:** job `deploy` ประกาศ `environment: demo` ซึ่งมี **required reviewer = `NuimanLP`** และ branch policy = `main` เท่านั้น
- GitHub จะพัก job ไว้สถานะ *Waiting* และ **ไม่ส่งให้ runner เลย** จนกว่าจะ approve
- **กันอะไร:** merge ระหว่างเดโม → ไม่มีใครกด approve → container ไม่ถูก recreate กลางเดโม (#366, ADR-0013 addendum)
- ตั้งค่า branch policy `main` และ fork-PR approval = `all_external_contributors` ทำจริงวันที่ 2026-09-30
- ตรวจว่ายังเปิดอยู่: `gh api repos/NuimanLP/srisurart-pos-flutter/environments/demo --jq '.protection_rules'`

### ④ runner + hook + `sudo` แค่คำสั่งเดียว

- VM `172.30.58.20` อยู่ในเครือข่ายคณะ เครื่องของ GitHub เข้าไม่ถึง → จึงต้องติด **self-hosted runner บน VM เอง**
  (ต่อออก 443 อย่างเดียว ไม่เปิด port เข้า)
- runner รันในนาม **`gha-runner`**: ไม่อยู่ group `docker`, ไม่อยู่ group `deploy`, อ่าน `/opt/pos/.env` ไม่ได้
- สิทธิ์เดียวที่มีคือ sudoers หนึ่งบรรทัด:

  ```text
  Defaults!/usr/local/bin/pos-deploy env_reset
  gha-runner ALL=(deploy) NOPASSWD: /usr/local/bin/pos-deploy
  ```

- **hook** (`/usr/local/lib/pos-runner/job-started.sh`, ชี้โดย `ACTIONS_RUNNER_HOOK_JOB_STARTED` ใน `.env` ของ runner)
  รันก่อนทุก step ของ job ถ้า exit ≠ 0 job ล้มทันที มันเช็กสามอย่าง:
  `GITHUB_REPOSITORY` = repo นี้ · `GITHUB_WORKFLOW_REF` = `…/deploy.yml@refs/heads/main` · event = `workflow_run`/`workflow_dispatch`
  และ **fail closed** — ตัวแปรหาย = ปฏิเสธ
- **กันอะไร:** repo นี้เป็น **public** — ถ้าใครแอบเขียน workflow บน branch อื่นหรือ fork ให้ไปรันบน label ของ runner นี้
  hook จะปฏิเสธก่อน step แรก และต่อให้หลุดมา ก็ทำได้แค่ "deploy commit ที่อยู่บน `main` อยู่แล้ว"

```text
สิทธิ์ส่งต่อได้ทางเดียว:  gha-runner ──(sudo แค่ 1 คำสั่ง)──▶ deploy ──(docker group, /opt/pos)──▶ container
                         ❌ docker   ❌ .env   ❌ shell ของ deploy
```

### ⑤ `pos-deploy` — กล่องดำที่ "ทำต่อจนจบเสมอ"

ไฟล์ `deploy/scripts/pos-deploy.sh` ติดตั้งเป็น `/usr/local/bin/pos-deploy` (root-owned) ทำตามลำดับ:

1. ต้องรันเป็น `deploy` · รับ `auto|manual` + SHA 40 ตัว
2. `flock` รอ lock สูงสุด 300 วินาที (กันสองตัวรันซ้อน แม้ไม่ได้มาจาก workflow)
3. **fetch `main` เอง** ลง `/home/deploy/pos-deploy/repo` — ไม่เชื่อไฟล์ใน workspace ของ job
4. SHA ต้องอยู่บน `main` **และ** ไม่เก่ากว่า `ROLLBACK_FLOOR` = `4f3a244…` (release ก่อน #233 crash-loop บนเครื่องจริง)
5. โหมด `auto` + SHA เก่ากว่าที่รันอยู่ → ไม่ deploy (CI ของ commit เก่าที่ re-run ทีหลังจะไม่ดึง VM ถอยหลัง)
6. ตั้งแต่จุดนี้ **ไม่สนใจ INT/TERM/HUP** — กด Cancel ใน Actions แล้ว run ขึ้น cancelled แต่ deploy ยังรันจนจบ (รวม rollback)
   log จริงอยู่ที่ `/home/deploy/pos-deploy/last-deploy.log`
7. checkout SHA → รัน playbook (จำกัด 1200 วินาที + grace 60 วินาที ด้วย watchdog แยก session)
8. ล้ม → **auto rollback**: checkout SHA ใน `.current_sha` (release ก่อนหน้า เพราะไฟล์นี้เขียนหลัง readiness ผ่านเท่านั้น)
   แล้วรัน playbook ของ release นั้นด้วย `-e force_redeploy=true` → run ยัง **แดง** พร้อมข้อความ
   `rolled back to …; release … is NOT deployed`

> 🔑 **rollback อัตโนมัติ = `pos-deploy` รัน playbook ของ release เดิมซ้ำ — ไม่ใช่ `rescue:` ของ Ansible**
> (`rescue:` ใน `deploy.yml` มีแค่ที่ block monitoring และทำแค่เตือน)

ทำไมต้องไม่ยอมให้ cancel? เพราะหยุดกลาง rolling restart = VM รันสอง version ปนกัน ซึ่งแย่กว่าปล่อยให้จบ

### ⑥ Ansible `deploy.yml` — ทีละ task

| ลำดับ | task (ย่อ) | กันอะไร |
|---|---|---|
| 1 | อ่าน `.current_sha` + checksum ของ `.env` เทียบ `.env_applied_sha256` | SHA เดิม + `.env` ไม่เปลี่ยน → `Skipping duplicate deployment.` จบเลย (ไม่แตะ container) · `.env` เปลี่ยน → rollout SHA เดิมซ้ำให้ |
| 2 | network pre-flight: network `srisurart-pos_default` ต้องมี `172.30.0.128/25` | ไม่เอา release ใหม่ไปลง network รุ่นเก่า (api จะเสีย IP คงที่ → Nginx ไม่มี upstream) |
| 3 | copy compose, `nginx.conf`, platform-ui, postgres init, `etcd-init.sh` (ลบ "ไดเรกทอรี" `etcd-init.sh` เก่าที่ Docker สร้างไว้ก่อน) | config ตรงกับ image ของ release เดียวกัน |
| 4 | `docker compose pull` | ดึงจาก GHCR (ที่ FortiGate เคยตัด) |
| 5 | `run --rm migrate` | **schema ก่อนโค้ด** · ไม่มี down-migration → rollback ไม่ถอย schema |
| 6 | `run --rm --no-deps certgen` แล้ว `up -d postgres redis-cache redis-queue htpasswd-gen etcd` | certgen ออกใบ TLS (ล้ม = deploy ล้ม) · ทุก step หลังจากนี้ใช้ `--no-deps` |
| 7 | `run --rm etcd-init` + assert อ่านแบบไม่มีรหัสได้ **400** | etcd ต้องเปิด auth จริง (#365) · seed `/pos/config/log_level` ถ้ายังไม่มี |
| 8 | `api-1` → รอ healthy → `api-2` → รอ → `api-3` → รอ | rolling: ร้านไม่ดับระหว่าง deploy |
| 9 | worker + bull-board · web-sync · `nginx -t` แล้ว recreate nginx · platform-ui | config nginx เสียไม่ทำให้ nginx เดิมหยุด |
| 10 | `GET https://127.0.0.1/health/ready` (retries 15, delay 3) | ชิมก่อนเสิร์ฟ — ตรวจ Postgres + Redis ทั้งสอง |
| 11 | เขียน `.current_sha` แล้ว `.env_applied_sha256` | **ป้ายหน้าร้าน** เขียนหลังชิมผ่านเท่านั้น |
| 12 | monitoring overlay (Prometheus/Grafana/node-exporter) | ล้ม = WARNING, release POS ไม่กระทบ |

---

## 👥 5. สอง playbook สอง user — ทำไมสลับกันไม่ได้

```text
          provision.yml  (คนรันด้วยมือ, owner)          deploy.yml  (runner หรือคนรัน)
          ssh เป็น cloud                                ssh เป็น deploy (หรือ local บน runner)
          become: true                                  become: false
          ─────────────────────────                     ─────────────────────────
          ลง Docker, UFW (22/80/443)                    pull / migrate / rolling restart
          สร้าง user deploy + authorized key            เขียน .current_sha
          เขียน /opt/pos/.env (0600) จาก DEMO_ENV_FILE   ไม่แตะ /opt/pos/scripts, ไม่แตะ cron
          ลง /opt/pos/scripts/* + cron 03:00 ของ deploy
```

| | `cloud` | `deploy` |
|---|---|---|
| sudo | มี | **ไม่มี** |
| group `docker` | **ไม่อยู่** | อยู่ |
| เขียน `/opt/pos` | **ไม่ได้** | ได้ (เจ้าของ) |
| ใช้กับ | `provision.yml` เท่านั้น | `deploy.yml` + คำสั่งตรวจ |

**คนในหัวของ owner:** *"ทำไมไม่ใช้ user เดียว?"* — เพราะ user ที่ deploy บ่อย ๆ ไม่ควรมี sudo
และ user ที่มี sudo ไม่ควรถือสิทธิ์ docker ตลอดเวลา ผลข้างเคียงที่ต้องจำ:

- `--check` **ซ่อน** การใช้ user ผิด (`copy` แค่เทียบ checksum ไม่เขียนจริง)
- **ห้าม `--diff` กับ `provision.yml`** — มันพิมพ์ `/opt/pos/.env` ทั้งไฟล์ (task เขียน `.env` เป็น `no_log` + `diff: false`
  แล้ว แต่กฎยังห้ามอยู่ดี)
- **ห้าม `export DEMO_ENV_FILE`** — ใส่นำหน้าคำสั่ง provision คำสั่งเดียว (`DEMO_ENV_FILE="$(cat …)" ansible-playbook provision.yml`)
  ตัวแปรจะได้ไม่ค้างใน shell
- ไม่ตั้ง `DEMO_SSH_KEY_PUB` → playbook หยิบ `~/.ssh/id_rsa.pub` ของเครื่องที่รันไปใส่ให้ `deploy` **เงียบ ๆ**
- 🔴 **`provision.yml` คือทางเดียวที่ลง `/opt/pos/scripts`** → แก้ `backup-db.sh` ใน `main` แล้ว CD **ไม่** ส่งไป VM
- secret บางตัวถูก "อบ" ลง volume ตอน bootstrap ครั้งแรก (`pgdata`, `etcd-data`, `nginx-auth`) — เปลี่ยนใน `.env`
  ไม่ re-key volume และอาการที่เห็นจะเป็น "service ไม่ green" ไม่ใช่ข้อความเรื่องรหัส → หยุด รายงาน owner **ห้าม `down -v`**

---

## 🚧 6. สิ่งที่ขวางอยู่ และถูกปลดยังไง

(ช่วงเวลาในไทม์ไลน์ = เวลาไทย · ส่วน cron 03:00 คือเวลาของ VM ซึ่งเป็น UTC = 10:00 เวลาไทย)

```text
09-21 ─────── 09-28   FortiGate ทำ SSL inspection กับ ghcr.io (ใบไม่มี SAN) → pull ล้ม
09-29         ✅ FortiGate ปลด · run 36591519465 (e50f4fa) ถูกสร้าง แต่ยังไม่มี runner รับ
09-30 เช้า    ✅ ติดตั้ง runner mob04-demo → approve → deploy จริงครั้งแรก
09-30 เช้า    ✅ provision.yml รันซ้ำ: เพิ่ม PLATFORM_ADMINS + ลง /opt/pos/scripts
09-30 บ่าย    ✅ etcd auth พิสูจน์สองทาง (#365)
09-30 บ่าย    ✅ PR #512 แก้ pnpm audit แดง → image กลับมา → merge→CD จริง
09-30 เย็น    ✅ CORS 500 (PR #516) · ทดสอบล้มโดยตั้งใจ (#67) · backup-db.sh (#519) ลงมือ
09-30 ค่ำ     ✅ deploy ca2fef1 → 3258b21
10-01 03:00 UTC ⏳ cron backup รอบจริงรอบแรกของสคริปต์ใหม่ — รอตรวจ
```

### 🧱 ① FortiGate ตัด `ghcr.io` (คลี่คลาย 2026-09-29)

- **อาการ:** `docker compose pull` บน VM ล้มด้วย `x509: certificate is not valid for any names` — firewall ของคณะ
  ทำ SSL inspection และตอบ `ghcr.io` ด้วยใบรับรองที่ไม่มี SAN
- **ทางแก้:** อยู่นอก repo (ฝั่งเครือข่ายคณะ) — ใบของ FortiGate ตอนนี้มี SAN `ghcr.io`/`*.ghcr.io` แล้ว · 09-29 `docker pull` จาก `mob04` สำเร็จจริง
- **ถ้ากลับมา:** ให้ฝ่ายเครือข่าย exempt `ghcr.io`/`registry-1.docker.io`/`gcr.io` ให้ `172.30.58.20` ·
  `docker save`/`load` ด้วยมือ = ทางกู้วันเดโมเท่านั้น **ไม่ใช่ CD** · **ห้ามปิด TLS verify**

### 🤖 ② runner ไม่เคยถูกติดตั้ง (ติดตั้ง 2026-09-30)

- ติดตั้งด้วย `deploy/scripts/setup-mob04-runner.sh`: runner v2.337.0 linux-x64 (**ตรวจ sha256 ก่อนแตกไฟล์**),
  ชื่อ `mob04-demo`, label `srisurart-demo-deploy`, สร้าง `gha-runner` (ปฏิเสธถ้าอยู่ group docker/deploy),
  ลง `pos-deploy` + hook + sudoers (ผ่าน `visudo -cf` ก่อน) แล้ว self-test
- token ลงทะเบียนส่งเข้า VM ทาง **stdin ของ ssh** (ไม่อยู่ใน command line ฝั่ง notebook และกรองออกจาก output) ·
  ⚠️ บน VM สคริปต์ยังรับ token เป็น **argument** (`setup-mob04-runner.sh <TOKEN> <VERSION> <SHA256>`) — token ใช้ครั้งเดียวและหมดอายุเร็ว แต่ไม่ได้ "ไม่เคยอยู่ใน command line" เลย
- ก่อนนั้นตั้ง fork-PR approval และ branch policy ของ `demo` ให้เสร็จก่อน (ลำดับบังคับ เพราะ repo public)
- ยกเลิก run ค้างเก่าของ `639238f` (`36551431740`) แล้ว approve run `36591519465` (`e50f4fa`) →
  hook อนุญาต · Ansible `ok=48 changed=27 failed=0 ignored=2` (ignored ตัวหนึ่ง = ยังไม่มี `.current_sha` ครั้งแรก) ·
  `.current_sha` = `e50f4fa…` · `/health/ready` 200

### 🔴 ③ `pnpm audit` แดงบน `main` = ไม่มี image = ทุก deploy ถูกข้ามแบบ "เขียว"

- **กลไก:** `Server CI` แดงที่ `pnpm audit --audit-level=high` (`brace-expansion` ผ่าน `@nestjs/cli > minimatch`, dev-only) →
  `build-image` ไม่รัน → GHCR ไม่มี server image → run ที่ `Server CI` (แดง) ยิงมา: `resolve` ถูก skip ทั้ง job ·
  run ที่ `Flutter CI` (เขียว) ยิงมา: `verify-ghcr-tags.sh` ได้ exit 1 → notice แล้วจบ **เขียว** → ทั้งสองแบบ job `deploy` skipped
- **ทางแก้:** PR #512 (`494ace3`) — pnpm override `brace-expansion` → `^5.0.11` และยก override `multer` เป็น `>=2.4.0`
- **บทเรียน:** run `Deploy (demo)` เขียวแค่ ~8 วินาทีหลัง merge อาจแปลว่า "CI แดง ไม่มี image" ไม่ใช่แค่ "PR แก้ docs"

### 🔐 ④ etcd ไม่มี auth (#365, ปิด 2026-09-30)

- **อาการเดิม:** `etcd-init.sh` บน VM เป็น **ไดเรกทอรีของ root** (Docker สร้างให้ตอน bind-mount ไฟล์ที่ไม่มี) →
  `etcd-init` รัน `sh <directory>` จบ exit 0 โดยไม่ได้ทำอะไร → etcd ไม่เคยเปิด auth
- **ทางแก้:** playbook ตรวจเจอไดเรกทอรีแล้วลบ, copy ไฟล์จริง, รัน `etcd-init`, แล้ว **assert ว่าอ่านแบบไม่มีรหัสได้ 400**
- **พิสูจน์สองทาง:** มีรหัส = สำเร็จ · รหัสผิด (`definitely-wrong`) = ปฏิเสธ · `RuntimeConfigService` เห็นการเปลี่ยน `log_level` ·
  snapshot `/opt/pos/backups/etcd-20260930T071608Z.db`

### 👤 ⑤ `PLATFORM_ADMINS` (เพื่อ platform-ui)

- `provision.yml` รันซ้ำจาก `origin/main`: `ok=18 changed=3 failed=0` · คีย์ที่**เพิ่ม**ใน `.env` มีแค่ `PLATFORM_ADMINS`
  (อีก 17 คีย์เหมือนเดิม — ตรวจด้วย hash ต่อคีย์ ไม่พิมพ์ค่า) · สำรองไฟล์เดิมเป็น `.env.bak-2026-09-30-0431`
- `.env` เปลี่ยนแต่ SHA เดิม → dispatch `e50f4fa` (run `36669582543`) → playbook เห็น `.env` เปลี่ยน → rollout ซ้ำ →
  log `PLATFORM_ADMINS synced` สร้าง admin 3 คน (`lomer`, `nuiman`, `pattarapon`)
- ⚠️ ยังไม่มีมนุษย์คนไหน login platform-ui จริง

### 💾 ⑥ สคริปต์ backup หาย / พัง (#346 ปิด, #519 ลงมือ)

- **ประวัติที่แก้แล้ว:** 03:00 ของ 09-29 สคริปต์ *มีอยู่* แต่ **fail** ("Neither active docker compose postgres container…")
  ทิ้ง `.gz` ว่าง 20 ไบต์ · 03:00 ของ 09-30 สคริปต์ "not found" · provision 09-30 ลงกลับเวลา 04:34
- #346: รันซ้ำแบบ env ของ cron → exit 0, dump ตรวจผ่าน (comment 5913495869)
- PR #519 (`b089f36`): dump ลง `$BACKUP_FILE.partial` แล้ว `mv` เมื่อสำเร็จ, EXIT trap ลบ partial, prune ลบ `.partial` ค้างตามอายุ,
  มีเทสต์ `deploy/scripts/test/backup-db.test.sh` ใน job `nginx-check`
- เพราะ CD ไม่อัปเดต scripts → **ลงมือ**: `sudo install -o deploy -g deploy -m 0755` จาก `origin/main`, sha256 ตรง (`fa65dbd5…`),
  เก็บของเดิมเป็น `.backup-db.sh.prev-be9e7f3` · รันหนึ่งครั้งด้วย `env -i` cwd `/home/deploy` → rc=0, ไฟล์ 9580 ไบต์,
  `gzip -t` ผ่าน, sha256 sidecar ผ่าน, ไม่มี `.partial`, มี `::warning::` offsite ตามคาด (#363 พักไว้)

### 🌐 ⑦ CORS: `Origin` แปลกหน้าได้ HTTP 500 (PR #516)

- เดิม `app.setup.ts` throw → 500 · PR #516 เปลี่ยนเป็น `callback(null, false)`: request เสิร์ฟตามปกติแต่ไม่มี
  `Access-Control-Allow-Origin` · deploy `00d3488` (run `36717963989`, `failed=0`)
- `CORS_ORIGINS=https://172.30.58.20` มีใน `.env` ของ VM ตั้งแต่ deploy แรกอยู่แล้ว · 500 ตัวนั้นไม่เคยถูกนับใน `http_requests_total`

---

## 🧪 7. หลักฐานทุกชิ้น — ตาราง run จริง

> ⚠️ คอลัมน์ "head" ของ run แบบ `workflow_dispatch` คือ head ของ `main` ตอนกด ไม่ใช่ SHA ที่ deploy —
> SHA ที่ deploy จริงอยู่ในบรรทัด `Release to deploy:` / `pos-deploy: … release=…` ของ log

| run | event | ทำอะไร | ผล |
|---|---|---|---|
| `36591519465` | workflow_run | deploy จริงครั้งแรก `e50f4fa` | ✅ `ok=48 failed=0`, `.current_sha` = `e50f4fa` |
| `36669582543` | dispatch | rollout `e50f4fa` ซ้ำเพราะ `.env` เปลี่ยน (`PLATFORM_ADMINS`) | ✅ |
| `36685569626` | workflow_run | `494ace3` CI ตัวแรกจบ — image ไม่ครบ | ✅ เขียว, `deploy` **skipped** |
| `36685602814` | workflow_run | **merge → CD** `494ace3` | ✅ api×3/worker รัน `494ace3` |
| (มือ) | Ansible as `deploy` | rollback ไป `e50f4fa` (#343) | ✅ `failed=0` |
| `36686729879` | dispatch | กู้ VM ที่ค้างครึ่งทางหลัง **VPN หลุด** (`e50f4fa` → `494ace3`) | ✅ `failed=0` |
| `36687687309` | dispatch | rollback `494ace3` → `e50f4fa` (AC #67) | ✅ schema เหมือนเดิม |
| `36688248109` | dispatch | SHA เดิมซ้ำ | ✅ `Skipping duplicate deployment.` `changed=0` |
| `36714408818` | workflow_run | `4f4d86c` | ✅ |
| `36717963989` | workflow_run | `00d3488` (CORS #516) | ✅ |
| `36719282689` | dispatch | ทดสอบ seed `log_level` (ลบคีย์ก่อน, deploy `4f4d86c`) | ✅ task etcd-init **changed** |
| `36720120003` / `36720131701` | dispatch ×2 | ทดสอบ concurrency (A/B ห่าง 6 วินาที) | ✅ ไม่ซ้อน, B รอจน A จบ |
| `36720675552` | dispatch | readiness ล้มโดยตั้งใจ → auto rollback | ❌ **แดง (ตั้งใจ)** VM กลับ `00d3488` |
| `36721404240` | dispatch จาก `tmp/67-hook-test` | hook ปฏิเสธ branch อื่น | ❌ **แดง (ตั้งใจ)** `Refused: workflow ref` |
| `36736199413` | workflow_run | `ca2fef1` (PR #521) | ✅ `.current_sha` = `ca2fef1` |
| `36740619787` | workflow_run | `3258b21` CI ตัวแรก | ✅ เขียวแต่ `deploy` skipped |
| `36740720083` | workflow_run | `3258b21` (PR #522) | ✅ `.current_sha` = `3258b21` |

ตลอด 5 deploy แรกของบ่าย 09-30 ตาราง `migrations` อยู่ที่ 20 แถว max `1788652804600` — rollback ไม่ถอย schema

### 🎬 mini-scenario: การทดสอบ "ล้มโดยตั้งใจ" ของ #67 (เจ้าของอนุญาต, comment 5912257527)

**ก. seed `log_level` เมื่อหาย และไม่ทับค่าที่คนตั้ง**

```text
etcdctl del /pos/config/log_level          → คีย์หาย
deploy 4f4d86c (run 36719282689)           → etcd-init "changed" → คีย์กลับมา = info (จาก LOG_LEVEL ใน .env)
etcdctl put /pos/config/log_level debug    → คนตั้งเอง
deploy 00d3488 (run 36720120003)           → etcd-init "ok" (ไม่ changed) → ค่ายังเป็น debug ✅
(ตั้งกลับเป็น info ด้วยมือภายหลัง)
```

ทำไมต้อง deploy SHA อื่น? เพราะ dispatch SHA เดิม (และ `.env` ไม่เปลี่ยน) จบที่ duplicate check **ก่อน** ถึง etcd-init
และ `deploy.yml` ไม่มี input `force` — อยากทดสอบซ้ำต้องเปลี่ยน SHA จริง

**ข. สอง deploy ไม่รันพร้อมกัน**

```text
13:15:05  A=queued        B=pending   ← A ถูก approve, B ถูก group deploy-demo กันไว้
13:15:18… A=in_progress   B=pending
13:16:50  A=success       B=waiting   ← ตอนนี้ B ถึงเพิ่งขอ approve
B ได้ approve → "Skipping duplicate deployment"
```

🔑 ข้อค้นพบ: **job ที่ยังรอ approval ก็ถือ slot `deploy-demo` แล้ว** — B ค้าง pending ตั้งแต่ตอนที่ A ยังแค่ waiting

**ค. readiness ล้ม → run แดง + rollback อัตโนมัติ**

```text
pos-deploy: running=00d3488 release=4f4d86c mode=manual
(ตัวเฝ้าบน VM) api-3 รัน 4f4d86c healthy แล้ว → docker stop redis-cache
TASK Verify cluster readiness … 503 (15 attempts) → failed=1
::error:: release 4f4d86c failed to deploy
::warning:: rolling back to 00d3488 (schema ไม่ถอย)
playbook ของ 00d3488 (force_redeploy) → up -d datastores ปลุก redis-cache กลับ → ready 200 → failed=0
::error:: rolled back to 00d3488; release 4f4d86c is NOT deployed   → run แดง
```

ทำไมหยุด `redis-cache` และทำไมรอให้ `api-3` healthy ก่อน? เพราะ `/health/ready` เช็ก Postgres + Redis ทั้งสอง
แต่ healthcheck ของ container api ใช้ `/health/live` ซึ่งไม่เช็ก Redis → api ยัง "healthy" อยู่ แล้วไปล้มที่ด่านชิมสุดท้ายพอดี ·
ถ้าหยุดเร็วกว่านั้น task `up -d postgres redis-cache …` ของ playbook จะปลุกมันกลับมาเอง ·
ผลคือตลอด run นี้ `.current_sha` ไม่เคยถูกเขียนเป็น `4f4d86c` (ยังเป็น `00d3488` mtime 13:16:19Z จาก run A ของข้อ ข)

**ง. hook ปฏิเสธ branch อื่น**

branch ชั่วคราว `tmp/67-hook-test` (ลบแล้ว) มี `deploy.yml` ปลอมหนึ่ง job ที่ `runs-on` label ของ runner เรา
ไม่มี `environment:` → runner รับงาน → hook พิมพ์
`workflow_ref=…/deploy.yml@refs/heads/tmp/67-hook-test` แล้ว `Refused: workflow ref` → step `echo` ไม่เคยรัน, VM ไม่ขยับ

**จ. ครึ่ง fork** — **ไม่มี run fork จริง** เจ้าของยอมรับการพิสูจน์จากโค้ด + settings (comment 5913430909):
sha256 ของ hook บน VM = ของ `origin/main`, ลองรันสคริปต์ด้วยค่าแบบ fork (`refs/pull/N/merge` + `pull_request`) → ปฏิเสธ,
`pull_request_target` → ปฏิเสธที่ event, fork-PR approval = `all_external_contributors` · #67 ปิด 15/15

### ✅ หลักฐานอื่นที่ติ๊กบน VM วันเดียวกัน

- **#443** (comment 5913452241): IP ที่ไม่อยู่ใน allowlist ได้ **403 ทั้งที่ nginx และที่ guard** บน Linux จริง
  (`PLATFORM_IP_FORBIDDEN`) — ticket ยังเปิด (รอ owner เรื่องถ้อยคำ AC)
- **#335** (comment 5913468668): `/metrics` ใน compose = text format · จากข้างนอก `/metrics` = 404 ·
  `/health/ready` 200 + `.current_sha` ตรง · rollback ด้วย `force_redeploy=true` หนึ่งครั้ง
- **#343** ปิด 5/5 · **#365** ปิด 4/4 · **#346** ปิด

---

## 🛠️ 8. ทำเองยังไง — deploy, approve, ตรวจ, rollback

> ต้องอยู่ในเครือข่ายคณะหรือ **ต่อ VPN** ก่อน · deploy **ทีละคน** ประกาศในแชททีมก่อนและหลัง ·
> ระหว่างเดโม #344 **ห้าม approve** อะไรทั้งนั้น

### 8.1 ทางหลัก: ผ่าน runner

**① เคลียร์คิว** — run ที่ค้างรอ approve อยู่ = SHA เก่า ถ้าเผลอ approve = ส่งของเก่าขึ้น

```bash
gh run list -R NuimanLP/srisurart-pos-flutter --workflow deploy.yml --status waiting --json databaseId,headSha,createdAt
gh run list -R NuimanLP/srisurart-pos-flutter --workflow deploy.yml --status pending --json databaseId,headSha,createdAt
```

(`waiting` = รอคน approve · `pending` = ถูก concurrency `deploy-demo` กันไว้หลัง run อื่น — ดูทั้งสองแบบ)

**② สั่ง deploy / rollback** (input ชื่อ `image_tag`, ว่าง = head ของ `main`, SHA เก่ากว่า = rollback):

```bash
gh workflow run deploy.yml -R NuimanLP/srisurart-pos-flutter --ref main -f image_tag=<40-hex-sha>
```

**③ ก่อน approve ตรวจ SHA ก่อนเสมอ** — ดู log ของ job `resolve release` ว่าบรรทัด `Release to deploy:` เป็น SHA ที่ตั้งใจ
และ image ครบบน GHCR แล้วค่อย approve (GitHub → Actions → run นั้น → *Review deployments* → `demo`)
หรือทาง API (owner เท่านั้น — `<env-id>` ได้จาก GET ก่อน):

```bash
gh api repos/NuimanLP/srisurart-pos-flutter/actions/runs/<run-id>/pending_deployments \
  --jq '.[]|{env:.environment.name,id:.environment.id,can:.current_user_can_approve}'
gh api -X POST repos/NuimanLP/srisurart-pos-flutter/actions/runs/<run-id>/pending_deployments \
  -F 'environment_ids[]=<env-id>' -f state=approved -f comment='<เหตุผล>'
```

**④ ดูจนจบ**

```bash
gh run watch <run-id> -R NuimanLP/srisurart-pos-flutter --exit-status --interval 20
```

### 8.2 ทางสำรอง: Ansible ด้วยมือในนาม `deploy` (เมื่อ runner offline)

รันจาก `deploy/ansible/` ใน **worktree สะอาดที่ SHA นั้น** (จะได้ compose/nginx/playbook ของ release นั้นด้วย):

```bash
TAG=<40-hex-sha>   # SHA เต็ม 40 ตัวเท่านั้น: tag บน GHCR เป็น SHA เต็ม และค่านี้ถูกเขียนลง .current_sha ตรง ๆ
DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=deploy DEMO_SSH_KEY_PATH="$DEPLOY_KEY" \
  ansible-playbook deploy.yml -e image_tag="$TAG" </dev/null
# rollback: เติม -e force_redeploy=true (ห้ามลบ .current_sha แทน)
```

- `</dev/null` ท้ายคำสั่ง: ansible-core ปฏิเสธ stdio แบบ non-blocking เมื่อรันจาก shell ที่ไม่ใช่ terminal ปกติ
- ลืม `DEMO_SSH_HOST` → default `127.0.0.1` = SSH เข้าเครื่องตัวเอง
- rollback ต้อง: อยู่บน `main`, ไม่เก่ากว่า `ROLLBACK_FLOOR` `4f3a244…`, image ครบบน GHCR, และ **schema ไม่ถอย**
  (ข้าม migration ที่ลบ/rename คอลัมน์ = owner ตัดสิน)

### 8.3 ตรวจผล — ทุกข้อเป็นการติ๊กแยก

```bash
ssh mob04-deploy 'cat /opt/pos/.current_sha'                                   # = SHA ที่ตั้งใจ (หลักฐานหลัก)
ssh mob04-deploy 'curl -sk -o /dev/null -w "ready=%{http_code}\n" https://127.0.0.1/health/ready'   # 200
ssh mob04-deploy 'docker ps --format "{{.Names}}|{{.Image}}|{{.Status}}" | grep -E "api-|worker|bull-board"'
#   ทุกแถว = ghcr.io/nuimanlp/srisurart-pos-server:<SHA> และ api (healthy)
```

- web ไม่ใช่ container ที่รันค้าง (`web-sync` เป็น `--rm`) → ตรวจจากชื่อ `main.<12 ตัวแรกของ SHA>.dart.js` ใน `flutter_bootstrap.js`
- `/health/ready` ไม่แตะ etcd → etcd ตรวจแยก (อ่านไม่มีรหัสต้องได้ 400)
- monitoring ล้มแค่ WARNING → ตรวจ Prometheus `:9090/-/healthy` และ Grafana `:3000/api/health` แยก

### 8.4 ดู Grafana / platform-ui — ผ่าน SSH tunnel เท่านั้น

พอร์ตพวกนี้ bind แค่ loopback ของ VM:

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 3100:127.0.0.1:3100 -L 3200:127.0.0.1:3200 mob04-deploy
```

| บน notebook | คือ |
|---|---|
| `http://localhost:3000` | Grafana (dashboard *POS Overview*) |
| `http://localhost:9090` | Prometheus |
| `http://localhost:3100` | Bull-Board |
| `http://localhost:3200` | platform-ui |

บน Mac ของ owner มีสคริปต์ `~/.local/bin/mob04-tunnel` ที่ทำ forward 4 พอร์ตนี้ผ่าน `cloud@172.30.58.20` ให้

### 8.5 VPN หลุดกลาง playbook (เกิดจริง 2026-09-30)

ระหว่าง roll-forward ด้วยมือ VPN หลุดที่ `Wait for api-3 health check` → VM ค้างครึ่งทาง:
api เป็น `494ace3` แต่ worker/bull-board/web ยังเป็น `e50f4fa`
**ทางกู้:** dispatch `Deploy (demo)` (run `36686729879`) — runner อยู่บน VM เอง จึงไม่พึ่ง VPN ของ notebook

---

## 📋 9. สรุปเป็นตาราง + คำจำสั้น ๆ

| ชิ้นส่วน | ตอบคำถามอะไร | กันอะไร |
|---|---|---|
| CI + status job | โค้ดนี้ผ่านทุกด่านไหม | ของเสียไม่มี image ให้ deploy |
| Trivy (server image) | มี CVE HIGH/CRITICAL ที่แก้ได้ไหม | image มีช่องโหว่ขึ้น GHCR |
| `resolve` + `verify-ghcr-tags.sh` | SHA ไหน และ image ครบไหม | deploy ของครึ่ง ๆ กลาง ๆ / SHA ที่ไม่อยู่บน main |
| environment `demo` | คนอนุมัติแล้วหรือยัง | merge กลางเดโมแล้ว container ถูก recreate |
| concurrency `deploy-demo` | มีใคร deploy อยู่ไหม | สอง deploy ซ้อนกัน |
| hook | ใบสั่งมาจาก `deploy.yml@main` จริงไหม | workflow จาก branch/fork แอบใช้ runner |
| `gha-runner` + sudoers | runner ทำอะไรได้บ้าง | job หลุดมาแล้วแตะ docker/`.env` |
| `pos-deploy` | ทำต่อจนจบไหม ถอยได้ไหม | cancel กลาง rolling → VM สองเวอร์ชัน |
| `deploy.yml` | ทำทีละขั้นอย่างไร | ร้านดับระหว่าง deploy |
| `/health/ready` | ทั้งระบบพร้อมจริงไหม | ป้ายหน้าร้านเปลี่ยนก่อนชิม |
| `.current_sha` | VM รัน SHA ไหน | การเดาจากสีของปุ่ม |
| `provision.yml` | `.env`, scripts, cron ใครวาง | deploy user ต้องมี sudo |

> **Green run = ใบสั่งผ่าน ไม่ใช่ของถึง**
> **`.current_sha` = ป้ายหน้าร้าน เขียนหลังชิม**
> **Waiting job = จองคิวแล้ว**
> **Rollback auto = pos-deploy รันซ้ำ ไม่ใช่ rescue**
> **provision ลง scripts / deploy ไม่ลง**
> **cloud = sudo · deploy = docker · สลับไม่ได้**
> **--check = พิสูจน์อะไรไม่ได้**

---

## ⚠️ 10. กับดักที่เจอมาแล้วจริง

1. **"run เขียว = deploy แล้ว"** — `deploy` ถูก skip ได้แต่ run ยัง success (เกิดซ้ำ: `36740619787`, และ run ของ `b4107b0`
   `36721768736`) · ถามเสมอ: *"`.current_sha` บอกอะไร?"*
2. **`--check` ผ่าน/ไม่ผ่าน ไม่มีความหมาย** — `command` ไม่มี check mode → network pre-flight เจอ `stdout` ว่าง
   แล้วฟ้อง `predates the ip_range` แบบ false positive · ห้ามอ้าง `--check` เป็นหลักฐาน
3. **commit ที่ push หลังกด merge หายไปเงียบ ๆ** — เกิดแล้วสามรอบ:
   `dbaa7e5` หลัง PR #491/#492 → ต้อง cherry-pick ใน PR #494 · `dc64f2c` หลัง PR #518 → cherry-pick ใน PR ถัดไป ·
   `47653b1`/`c57019a` (review fix ของ PR #486) → กู้ใน PR #521 (`ca2fef1`)
   - ตอน merge: `gh pr view N --json headRefOid` ต้องเป็น commit ล่าสุดที่คุณ push
   - ก่อนลบ branch ที่ merge แล้ว: tip ของ branch ต้อง = `headRefOid` ของ PR · ไม่ตรง = มี commit ที่อาจไม่มีที่อื่น
     (นี่คือวิธีที่เจอ #486)
4. **job ที่รอ approval ถือ slot ไว้แล้ว** — คิว dispatch ทดสอบซ้อนโดยไม่รู้ตัว = ตัวหลังค้าง pending ·
   และ run ที่ *รอ* อาจถูก run ใหม่แทนได้ (rollback มือที่รออยู่อาจถูก auto-deploy ของ merge ใหม่แซง)
5. **VPN หลุดกลาง Ansible มือ** → VM ครึ่ง ๆ → กู้ด้วย dispatch ผ่าน runner (§8.5)
6. **CD ไม่อัปเดต `/opt/pos/scripts`** — และ `pos-deploy.sh`/hook บน VM ก็เป็นสำเนาที่ owner ติดตั้ง
   PR ที่แก้ไฟล์เหล่านี้ไม่มีผลจนกว่าจะ `install` ใหม่
7. **ห้าม `docker compose down -v`** — เคยลบ volume ของ session อื่นมาแล้ว · volume คือข้อมูลจริง
8. **รหัสใน `.env` ≠ ที่ volume อบไว้** → อาการคือ "service ไม่ green" (`password authentication failed`,
   `etcd-init: FAILED — root cannot authenticate`) ไม่มีข้อความบอกตรง ๆ → หยุด รายงาน owner
9. **ห้ามลบ `.current_sha` เพื่อบังคับ deploy** — ใช้ `-e force_redeploy=true`
10. **แก้ `.env` ด้วยมือ** — ทุกการตรวจต้องมี `^` (`grep -c '^KEY='`) และเติมบรรทัดว่างก่อน append
    (คีย์ที่ติดท้ายบรรทัดก่อนหน้าจะดูเหมือนมี แต่ Compose บอกว่าหาย)

> ข้อควรระวังเชิงบริบท: "ล้มแล้ว rollback อัตโนมัติ" **ไม่** ครอบคลุม schema — ไม่มี down-migration
> และถ้า watchdog ฆ่า playbook ระหว่าง monitoring block (ซึ่งรัน *หลัง* เขียน `.current_sha`) มันจะ rollback release ที่ healthy อยู่ทิ้ง
> (เป็นข้อที่ยอมรับไว้ใน 07 §6.1)

---

## 🔍 11. ชุดคำถามที่ใช้กับ deploy ไหนก็ได้

```text
SHA ที่จะ deploy คืออะไร และอยู่บน main ไหม?
   ↓
CI ของ SHA นี้เขียวทั้งสองตัว และ GHCR มี image ครบทั้ง server + web ไหม?
   ↓
มี run อื่นรอ approve / กำลังรันอยู่ไหม? (ถ้ามี เคลียร์ก่อน)
   ↓
บรรทัด "Release to deploy:" ตรงกับ SHA ที่ตั้งใจไหม? → ค่อย approve
   ↓
run จบแล้ว: .current_sha = SHA นี้ไหม? /health/ready 200 ไหม? docker ps เห็น tag ถูกไหม?
   ↓
ถ้าแดง: last-deploy.log บอกว่า rollback ไป SHA ไหน และ .current_sha ยังเป็นของเดิมไหม?
   ↓
ถ้าแก้ไฟล์ใน /opt/pos/scripts หรือ pos-deploy/hook: ลงบน VM ด้วยมือแล้วหรือยัง (sha256 ตรงไหม)?
```

---

## ⏳ 12. สิ่งที่ยังเปิดอยู่ (ณ 2026-10-01)

| เรื่อง | สถานะ |
|---|---|
| **cron backup 03:00 รอบจริงรอบแรก** ของสคริปต์ #519 | **ต้องตรวจหลัง 03:00 UTC 2026-10-01** — ดู `backup-cron.log` และ `/opt/pos/backups` (ต้องไม่มี `.partial` ค้าง) · บทนี้ยังไม่ได้ยืนยันผล |
| **#344** เดโมคนจริงครบวง | ยังไม่รัน · checklist `docs/handoff_log/demo-344-checklist-2026-09-30.md` (รหัสชั่วคราว + บังคับเปลี่ยนใน 10 นาที, tenant ใหม่ไม่มีสินค้า, แอปส่ง idempotency key ซ้ำเองไม่ได้, บาง AC ของ #335 พิสูจน์บน VM ตรง ๆ ไม่ได้, #476) |
| **#380** k6 สามเครื่อง + container RSS | ยังไม่มีตัวเลขเลย |
| **#363 / #288** backup ออกนอก VM | **พักไว้จนหลังเดโม** — ตอนนี้ **ไม่มี backup ออกจาก VM เลย** ห้ามเขียนว่า "backup พร้อมแล้ว" |
| **#476** เครื่องสุดท้ายหลุด = ทางตัน | รอ owner ตัดสิน |
| **#443** platform admin UI | code merge แล้ว, 403 สองชั้นพิสูจน์บน VM แล้ว · รอ owner เรื่อง AC "เฉพาะ `bootstrap:admin`" ที่ขัดกับ `PLATFORM_ADMINS` sync · ยังไม่มีคน login จริง |
| **#231** cutover ร้านจาก Drift build ไป server | รอ owner · ร้านจริงยังใช้ Drift build |

สถานะ VM ณ เวลาเขียน (2026-10-01): `.current_sha` = `3258b21` (จาก run `36740720083`; `/health/ready` 200 ตอนจบ run นั้น) ·
PR #523 (docs ล้วน) merge เป็น `6384e20` แล้ว แต่ **ยังไม่ถูก deploy** — run `36742768824` ของ `6384e20` ค้าง *waiting* รอ approve
และ run `36742775298` ค้าง *pending* อยู่หลังมัน (ตัวอย่างจริงของกับดักข้อ 4) · สถานะเปลี่ยนได้ทุกเมื่อ ให้ดู `.current_sha` เอง

---

## 🌉 13. ต่อจากบทก่อน และบทถัดไป

- บท [14](14_devops.md) สอนว่า **Ansible, Compose, GHCR, Trivy** คืออะไร · บท [15](15_cicd.md) สอนว่า **pipeline เขียว ≠ deploy**
  และเล่าตอนที่ deploy ยังติด FortiGate — บทนี้คือ "ตอนจบ" ของเรื่องนั้น: ด่านเดิมทั้งหมดถูกเดินผ่านจริง
  และ "green ≠ deployed" ถูกพิสูจน์ด้วย run จริงหลายตัว
- กฎ **validate ก่อน แล้วค่อย clamp** จาก [18](18_capstone.md) โผล่ที่นี่อีกแบบ: `pos-deploy` ตรวจ SHA (40 hex, อยู่บน main,
  ไม่เก่ากว่า floor) *ก่อน* แตะ VM และ `verify-ghcr-tags.sh` แยก "ยังไม่มี" ออกจาก "ถามไม่ได้"

**บทถัดไปที่แนะนำ:** เปิด `docs/handoff_log/demo-344-checklist-2026-09-30.md` แล้วอ่านคู่กับ [16_performance.md](16_performance.md)
เพราะงานสองชิ้นที่เหลือของ phase 1 คือ **#344** (เดินเส้นเดโมด้วยมือคนจริงบน VM ที่บทนี้ deploy ไว้) และ **#380**
(วัด k6 บน VM ตัวเดียวกัน) — ทั้งสองต้องการคนที่ deploy/ตรวจ/rollback เป็น ซึ่งคือสิ่งที่บทนี้สอน

---

## ❓ ทดสอบตัวเอง

<details>
<summary>1. run <code>Deploy (demo)</code> เขียวภายใน 8 วินาทีหลัง merge แปลว่าอะไรได้บ้าง?</summary>

image ของ SHA นั้นยังไม่ครบบน GHCR → job `deploy` ถูก skip — อาจเพราะเป็น CI ตัวแรกที่จบ (ปกติ)
หรือเพราะ `Server CI` แดง (เช่น `pnpm audit`) จนไม่มี image เลย ต้องดู `.current_sha` เท่านั้น
</details>

<details>
<summary>2. ทำไม runner ถึงรันเป็น <code>gha-runner</code> ไม่ใช่ <code>deploy</code>?</summary>

repo เป็น public — ถ้า job แปลกปลอมหลุดถึง runner ได้ มันต้องทำอะไรไม่ได้นอกจาก `sudo -u deploy pos-deploy`
ซึ่ง deploy ได้แค่ commit ที่อยู่บน `main` อยู่แล้ว · `gha-runner` ไม่มี docker group และอ่าน `.env` ไม่ได้
</details>

<details>
<summary>3. readiness ล้มแล้วใครเป็นคน rollback?</summary>

`pos-deploy` — มันรัน playbook ของ SHA ใน `.current_sha` (release ก่อนหน้า) ซ้ำด้วย `force_redeploy=true` และให้ run แดง
ไม่ใช่ `rescue:` ของ Ansible (พิสูจน์ใน run `36720675552`)
</details>

<details>
<summary>4. merge PR ที่แก้ <code>backup-db.sh</code> แล้ว deploy สำเร็จ VM ได้สคริปต์ใหม่ไหม?</summary>

ไม่ได้ — มีแต่ `provision.yml` ที่ลง `/opt/pos/scripts` · ต้อง provision ใหม่หรือ `sudo install` ด้วยมือ แล้วเทียบ sha256 กับ `origin/main`
</details>

<details>
<summary>5. อยากทดสอบว่า etcd-init seed <code>log_level</code> ซ้ำ โดย dispatch SHA เดิม ได้ไหม?</summary>

ไม่ได้ — SHA เดิม + `.env` ไม่เปลี่ยน จบที่ duplicate check ก่อนถึง etcd-init และ `deploy.yml` ไม่มี input force
ต้อง deploy SHA อื่นจริง
</details>
