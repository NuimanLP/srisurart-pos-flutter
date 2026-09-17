# ADR-0013 — toolchain ของ CI/CD และการ deploy: GitHub Actions + GHCR + Ansible + etcd + Monitoring (Prometheus + Grafana + Node Exporter)

* **สถานะ:** Accepted — 2026-09-10 (พิจารณาปฏิเสธ Wazuh/ELK จากข้อจำกัด RAM: 2026-09-15) ·
  addendum **2026-09-15** *"Actions เข้าถึง VM อย่างไร"* — แถว Config & Deploy เปลี่ยนจาก "SSH เข้า VM" เป็น
  **self-hosted runner บน VM** (ดูหัวข้อท้ายไฟล์)
* **ผู้ตัดสิน:** เจ้าของโปรเจกต์ (grill 2 รอบ, 19 ข้อ) — บันทึกการสัมภาษณ์อยู่ใน `docs/handoff_log/`
* **เอกสารเจ้าของเรื่องนี้:** [`07_CICD_DEPLOY.md`](../07_CICD_DEPLOY.md)

## บริบท

ตั้งแต่ `ec24f79` เรื่อง deployment/hosting **ไม่มีเอกสารเจ้าของ** และ CI ที่มีอยู่ (`flutter.yml`,
`server.yml`) หยุดที่ "artefact บน main สีเขียว ไม่ deploy" โดยตั้งใจ เพราะยังไม่เลือก production host

คอร์สกำหนด **ตารางบล็อกกระบวนการ DevOps** ที่ต้องแมปเครื่องมือให้ครบ 7 บล็อก (Code & SCM ·
Build & Test · Security Scan · Package/Storage · Config & Deploy · KV Storage · Monitoring) และให้
ทุกคนในทีมแตะ CI/CD · เอกสารประกอบคอร์สที่มี (`docs/boat_CI_CD.md`) เป็นเรื่อง **Jenkins** ของ
อีกโปรเจกต์หนึ่ง

## การตัดสินใจ

| บล็อก | เลือก | ทำไม |
|---|---|---|
| Code & SCM | Git / GitHub | มีอยู่แล้ว |
| Build & Test | **GitHub Actions** (vitest ฝั่ง server, `flutter test` ฝั่ง client) | workflow 2 ไฟล์ทำงานอยู่แล้ว · **ไม่เพิ่ม Jenkins** — เครื่องยนต์ที่สองสำหรับงานเดียวกัน และต้องมีเครื่องรัน Jenkins เพิ่มบน VM 6 GB |
| Security Scan | **Trivy** (fs + **image**) + `pnpm audit` + OSV | Trivy สแกน image **บล็อก** การ push ขึ้น registry · ทำให้ผ่านได้ด้วยการ **ถอด npm ออกจาก runtime stage** + pin base ด้วย digest + `apk upgrade` เฉพาะแพ็กเกจ OS (reproducibility มาจาก digest pin) · **ไม่มี `.trivyignore`** (gate ปลอม) |
| Package / Storage | **Docker + GHCR** (package public) | repo เป็น public อยู่แล้ว · VM ดึงได้โดยไม่ต้องจัดการ token · **ยกเลิก tarball artefact** ให้เหลือทางปล่อยทางเดียว · ทั้ง server และ **web** เป็น image (web = ไฟล์ static ล้วน copy ลง volume ให้ Nginx เดิมอ่าน — **ไม่** bake nginx.conf ลง image ฝั่ง client) จะได้ใช้กลไก pull เดียวกันและ rollback ด้วย SHA เดียว |
| Config & Deploy | **Ansible** → SSH เข้า VM คณะ (environment `demo`) **อัตโนมัติทุก main สีเขียว** | playbook ตั้งเครื่องเปล่าได้ = "เลือก production host ทีหลัง" เป็นจริง (แค่เพิ่ม inventory + เปิดอนุมัติ) · ไม่ใช้ Kubernetes — 1 VM, 4 vCPU |
| KV Storage | **etcd** — เก็บเฉพาะ **dynamic config ที่ไม่ใช่ความลับ** | ให้ etcd มีงานจริง (แอปอ่านตอน boot + watch) โดย**ไม่แตะ data model** · **ห้ามเก็บข้อมูลธุรกิจ** — PostgreSQL ยังเป็น source of truth · แอปต้อง boot ได้แม้ไม่มี etcd (fallback ไป env) |
| Monitoring | **Node Exporter + Prometheus + Grafana (Monitoring)** บน VM เดียวกัน ผูก loopback | dashboard เดียว provision จาก JSON ใน repo · **ไม่มี Alertmanager** · **ปฏิเสธ Wazuh และ ELK stack** — สแต็กความปลอดภัย/Log หนักเหล่านี้ต้องการ RAM 4–5 GB (OpenSearch/Elasticsearch heap) ซึ่งจะทำให้ VM คณะ 6 GB เกิด Out-Of-Memory (OOM) ชนกับ POS stack (~3.4 GB) ทันที · เลือกชุดเล็กที่คุมงบ RAM รวมได้ ~832 MB · เข้าถึงผ่าน SSH tunnel แบบเดียวกับ Bull-Board — ไม่เปิดของใหม่ออกอินเทอร์เน็ตบนเครื่องที่มีข้อมูลลูกค้า |

**ข้อที่ตั้งใจให้ต่างจากที่คนมักคาดหวัง:**

* **deploy อัตโนมัติ ไม่มีคนกดอนุมัติ** บน `demo` — เพื่อสาธิต CD ของจริง · production จะเปิดอนุมัติ
* **branch protection ใช้ `status` job ที่รันเสมอ** ต่อ workflow แทน `paths:` ระดับ workflow —
  เพราะ PR ที่แตะแค่ `server/` จะไม่รัน workflow ฝั่ง Flutter เลย ทำให้ required check ค้างตลอดกาล (#39) ·
  ผลพลอยได้: ทุก push ขึ้น `main` ได้ image ครบทั้งสองฝั่งสำหรับ SHA เดียว (ปิด AC4 ของ #40)
* **job integration รันทุก PR ไม่ดู path** — เป็น job ที่ถือ test อ่านข้ามร้าน (กติกา multi-tenant ข้อ 6)
* **TLS self-signed ต่อไป** — ไม่มี DNS name ชี้ VM, Let's Encrypt ไม่ออก cert ให้ IP
* **rollback = deploy SHA ก่อนหน้า ไม่มี down-migration**

## ผลที่ตามมา

* `server/Dockerfile` runtime stage ไม่มี npm/npx, base pin ด้วย digest · `docker-compose.yml` คง `nginx:1.29-alpine` +
  mount conf แต่เพิ่ม volume `web` (เติมโดย one-shot `web-sync` แบบ `certgen`) · เพิ่ม service `etcd` · overlay monitoring แยกไฟล์
* ระหว่าง scrutinize พบบั๊กเดิม: `location /platform/` ใน Nginx ไม่มีทางถูกเรียกถึงเพราะ global prefix `api/v1` — ต้องแก้เป็น `/api/v1/platform/` พร้อม allowlist (07 §9)
* โฟลเดอร์ใหม่ `deploy/` ที่ root (Ansible, overlay, web Dockerfile) — ADR-0011 ยังใช้: repo เดียว
* GitHub Environment `demo` ถือ secret ทั้งหมด (SSH + ค่าใน `server/.env`) · เปิด secret scanning + push protection
* งบ RAM บน VM (6 GB): ต้องใส่ `mem_limit` ให้ etcd (256m) / Prometheus (512m) / Grafana (256m) / node-exporter (64m) ทุกตัว รวม monitoring overlay ~832m อยู่ในงบรวม ~4.2 GB / 6 GB อย่างปลอดภัย ไม่เพิ่ม Wazuh/ELK ที่กิน RAM 4–5 GB จนเสี่ยง OOM คิล Postgres/API

## ยังไม่เคาะ

* **key ใน etcd มีตัวเดียว (`log_level`)** — ค่า rate limit ถูกตัดออกเพราะไม่มีผู้ใช้ (ADR-0006 เก็บโควตาใน `tenants.plan`)
* **maintenance mode ใน etcd** — ต้องมีข้อความไทยหน้าเคาน์เตอร์ใหม่ ซึ่ง `CLAUDE.md` ห้ามแต่งเอง รอร้าน
* ~~**production host** — ยังไม่เลือก (ครบกำหนดก่อน `q4`) · เมื่อเลือก: inventory ที่สอง + required reviewer~~ — **เคาะ 2026-09-15 (#242): `mob04` production เดียว** (addendum ด้านล่าง)
* **ชื่อโดเมน** — ถ้ามีเมื่อไร ค่อยเปลี่ยน self-signed เป็น certbot
* **retention ของ image บน GHCR** — ยังไม่ตั้งนโยบายลบ tag เก่า · (addendum 2026-09-15: rollback อัตโนมัติ
  ต้องการ image ของ release ก่อนหน้า — นโยบายลบ tag ต้องไม่ลบ tag ที่ `.current_sha` ชี้อยู่)

## Actions เข้าถึง VM อย่างไร — addendum 2026-09-15 (#67, เจ้าของโปรเจกต์)

**ปัญหาที่พบ:** แถว Config & Deploy เขียนว่า "Ansible → SSH เข้า VM" โดยให้ job ของ GitHub Actions เป็นคน SSH
แต่ตอนลง deploy จริงครั้งแรก (#184) พบว่า VM `demo` (`mob04`, `172.30.58.20`) เป็น **address ภายในมหาวิทยาลัย** —
runner ของ GitHub (GitHub-hosted) ต่อเข้าไม่ได้ และที่ `07 §5` บันทึกว่า "รับ inbound จากนอกมหาวิทยาลัยได้"
ก็ไม่เคยมี public address/port ใดถูกบันทึกไว้จริง · ขาออกของ VM ออกผ่าน NAT ได้ปกติ

**การตัดสินใจ (เจ้าของโปรเจกต์ 2026-09-15 — ตัวเลือก 2 ของ handoff `session-2026-09-15-phase1-closeout.md` §6):**
ติดตั้ง **GitHub Actions self-hosted runner บน VM `demo` เอง** — runner ต่อ**ขาออก** (HTTPS 443) ไปหา GitHub
แล้วรอรับ job ไม่มี port ใหม่เปิดเข้า (ufw ยังเป็น 22/80/443 ตามเดิม)

| หัวข้อ | ค่าที่เคาะ |
|---|---|
| งานที่ runner รับ | job `deploy` ของ `.github/workflows/deploy.yml` **job เดียว** · label เฉพาะ `srisurart-demo-deploy` · job อื่นทุกตัว (CI, build image, การเช็ค tag บน GHCR ก่อน deploy) ยังรันบน GitHub-hosted |
| runner เรียก deploy อย่างไร | job มีขั้นเดียว: `sudo -n -u deploy /usr/local/bin/pos-deploy auto\|manual <sha>` (`deploy/scripts/pos-deploy.sh`) ซึ่ง **fetch `main` เอง** ลง clone ของ `deploy`, ปฏิเสธ commit ที่ไม่อยู่บน `main` หรือเก่ากว่า #233, checkout SHA นั้นแล้วรัน **`deploy/ansible/deploy.yml` ตัวเดิม** ด้วย `ansible_connection=local` — **ไม่**เขียนขั้น deploy ซ้ำใน workflow · เหตุผล: ADR นี้เลือก Ansible เป็นเครื่องมือของบล็อก Config & Deploy และ playbook เป็นขั้นตอน deploy **ชุดเดียว**ที่คนรันด้วยมือก็ใช้ (07 §6) — ถ้าย้ายขั้นไปไว้ใน YAML ของ workflow จะมีสองชุดที่ต้องแก้คู่กันและเพี้ยนกันในที่สุด · เปลี่ยนแค่ "ต่อเครื่องอย่างไร" (SSH → local) ไม่เปลี่ยน "ทำอะไร" · ไฟล์ที่รันมาจาก `main` บน GitHub **ไม่ใช่** จาก workspace ของ job |
| user ของ runner | **`gha-runner`** (สร้างใหม่, ไม่อยู่ใน group `docker`, ไม่มี sudo ยกเว้น**กฎเดียว** `gha-runner ALL=(deploy) NOPASSWD: /usr/local/bin/pos-deploy`) · wrapper เป็นไฟล์ของ root แก้ไม่ได้จาก `deploy` หรือ `gha-runner` · ผล: job ที่หลุดมาถึง runner **อ่าน `/opt/pos/.env` ไม่ได้ สั่ง docker ไม่ได้** ทำได้แค่ deploy commit ที่อยู่บน `main` อยู่แล้ว · (ฉบับแรกของ addendum นี้ให้ runner รันเป็น `deploy` ด้วยเหตุผลว่า "user แยกได้อำนาจเท่ากัน" — ผิด: sudo ที่จำกัดเหลือคำสั่งเดียวซึ่งตรวจ argument เอง แคบกว่า group `docker` มาก; แก้ใน review ของ PR #237) |
| job-started hook | `ACTIONS_RUNNER_HOOK_JOB_STARTED` ชี้ `deploy/scripts/runner-job-started.sh` (ติดตั้งเป็นไฟล์ของ root) — job ที่ไม่ใช่ `NuimanLP/srisurart-pos-flutter/.github/workflows/deploy.yml@refs/heads/main` หรือ event ไม่ใช่ `workflow_run`/`workflow_dispatch` **fail ก่อนขั้นแรกจะรัน** · fail-closed: ตัวแปรที่ runner ไม่ส่งมาถือว่าไม่ผ่าน · 🔴 ยังไม่ได้พิสูจน์กับ runner จริงว่าตัวแปรทั้งสามเห็นได้ใน hook — เจ้าของตรวจ log ของ run แรก (07 §6.2) |
| secret | workflow **ไม่ใช้ secret เลย** — `.env` ยังวางโดย `provision.yml` ที่คนรัน (ต้อง sudo) · `DEMO_SSH_HOST/USER/KEY` ไม่จำเป็นต่อ deploy อัตโนมัติอีกต่อไป จึง**ไม่ต้อง**เก็บ private key ของ VM ไว้ใน GitHub · Environment `demo` ยังต้องมี เพื่อบังคับ deployment branch = `main` และเก็บประวัติ deploy · ข้อนี้**แทน**บรรทัด "GitHub Environment `demo` ถือ secret ทั้งหมด" ใน *ผลที่ตามมา* ข้างบน |
| rollback | **อัตโนมัติ**เมื่อ playbook fail (หรือเกิน 20 นาทีต่อรอบ): deploy SHA ใน `.current_sha` ซ้ำด้วย `-e force_redeploy=true` — playbook เขียนไฟล์นี้หลัง `/health/ready` ผ่านเท่านั้น ตอน fail จึงยังเป็น release ก่อนหน้า · **ห้ามลบ `.current_sha` เพื่อบังคับ** — ถ้า rollback fail ด้วยเหตุเดียวกัน VM จะไม่เหลือบันทึกว่ารันอะไรอยู่ · **มือ**: `workflow_dispatch` รับ SHA · schema ไม่ถอยเหมือนเดิม · run ที่ rollback แล้วยังเป็น**สีแดง** · ไม่ deploy/rollback ไปก่อน #233 (`ROLLBACK_FLOOR`) |

**ตัวเลือกที่ปฏิเสธ:**

1. **public IP / port forward มาที่ SSH ของ VM** — คงแบบเดิมของ ADR นี้ได้ครบ แต่ต้องขอคณะเปิด port และทำให้
   SSH ของเครื่องอยู่บนอินเทอร์เน็ต ขัดกับหลัก "ไม่เปิดของใหม่ออกอินเทอร์เน็ต" ของแถว Monitoring · และ GitHub-hosted
   runner ไม่มี IP คงที่ จึงทำ allowlist ต้นทางไม่ได้ ต้องเปิดให้ทั้งโลก
2. **Tailscale บน VM + runner** — ไม่เปิด port เหมือนตัวเลือกที่เลือก แต่เพิ่มบัญชี/บริการภายนอกอีกตัว, auth key ที่ต้อง
   เก็บเป็น secret และหมุน, และ daemon อีกตัวบน VM ที่ RAM จำกัด (07 §5) · ได้สิ่งที่ runner ขาออกให้อยู่แล้ว
   แลกกับชิ้นส่วนเพิ่ม

**ข้อบังคับความปลอดภัย (repo เป็น public — self-hosted runner บน repo public คือความเสี่ยงที่ GitHub เตือนไว้เอง):**

* 🔴 **workflow ที่ใช้ label ของ runner ต้องไม่มีทาง trigger จาก `pull_request` / `pull_request_target`** —
  `deploy.yml` รับเฉพาะ `workflow_run` (ของ push บน `main` ใน repo นี้, conclusion success) กับ `workflow_dispatch`
  บน `main` · ทั้งสอง job มี `if:` เช็ค event + `github.repository` + branch · job `resolve` เช็คอีกชั้นว่า commit อยู่บน
  ประวัติของ `main` (กัน SHA ของ fork ที่ GitHub เสิร์ฟผ่าน `refs/pull/*`) · ห้าม workflow อื่นใช้ label นี้
* 🔴 **`if:` กันได้แค่ไฟล์นี้** — workflow อื่นที่ตั้ง `runs-on` label นี้เอง (branch ที่คนมีสิทธิ์ write push ขึ้นมา, dispatch
  ของ `deploy.yml` ฉบับแก้จาก branch อื่น, PR จาก fork) ไม่ผ่าน `if:` ของเราเลย · ตัวกันมีสามชั้น: (1) **job-started hook**
  รับเฉพาะ `deploy.yml@refs/heads/main` (2) user `gha-runner` ไม่มี docker/`.env` ทำได้แค่ `pos-deploy` ซึ่งรับเฉพาะ commit
  บน `main` (3) setting **"Require approval for all external contributors"** ซึ่ง**ต้อง**ตั้งก่อนลงทะเบียน runner · ห้ามกด
  อนุมัติ run ของ fork ที่แตะ `.github/`
* `permissions: contents: read` ระดับไฟล์ · ค่าจาก input/event ส่งเข้า shell ผ่าน `env:` และตรวจรูปแบบก่อนใช้ ไม่ interpolate
  `${{ }}` ลง script · job บน runner ไม่ checkout อะไรเลย
* runner ลงทะเบียนกับ **repo นี้เท่านั้น** (ไม่ใช่ระดับ account) · runner ไม่ใช้รันงานอื่น · แก้ `pos-deploy.sh` /
  `runner-job-started.sh` ใน repo **ไม่มีผลกับ VM** จนกว่าเจ้าของจะติดตั้งใหม่ (ตั้งใจ — ไฟล์ของ root ต้องผ่านคน)
* **ความเสี่ยงที่ยอมรับ (แก้ 2026-09-15 ใน review PR #237 — ฉบับแรกเขียนว่า "ใครที่เอา commit ขึ้น `main` ได้" ซึ่งไม่ครบ:
  runner ตอนนั้นรับ job จาก branch ใดก็ได้ของคนที่มีสิทธิ์ write):**
  * คนที่เอา commit ขึ้น `main` ได้ (PR ตาม branch protection 07 §4 — approval 0, admin ไม่ถูกบังคับ) กำหนด playbook ที่รันใน
    สิทธิ์ `deploy` = group `docker` = root บน VM `demo` · เป็นอำนาจที่ deploy อัตโนมัติต้องมีไม่ว่าจะต่อด้วยวิธีไหน
  * คนที่มีสิทธิ์ write สั่ง `workflow_dispatch` ได้ = deploy/rollback ไป commit ใดก็ได้บน `main` ที่ใหม่กว่า #233 — ไม่มีอะไรมากกว่านั้น
  * ถ้า hook ไม่ทำงาน (เช่นตัวแปรไม่ถูกส่ง — fail-closed จะทำให้ **ทุก** deploy ถูกปฏิเสธ ไม่ใช่ทุก job ผ่าน) job ที่หลุดมาจะรันโค้ดใน
    สิทธิ์ `gha-runner` บน VM ที่อยู่ในเครือข่ายมหาวิทยาลัยได้ แต่แตะ docker/`.env` ไม่ได้
  * ยอมรับได้บน `demo` ที่ไม่มีข้อมูลร้านจริง · **production host ต้องทบทวนใหม่**: required reviewer ของ Environment และ runner แบบ
    ephemeral/JIT ที่ถูกสร้างต่อ job

**ผลที่ตามมา:**

* `.github/workflows/deploy.yml` (ใหม่) + `.github/actionlint.yaml` ประกาศ label · `deploy/scripts/pos-deploy.sh` +
  `deploy/scripts/runner-job-started.sh` (ใหม่, ติดตั้งบน VM โดยเจ้าของ) · ขั้นตั้ง runner อยู่ใน `07_CICD_DEPLOY.md §6.2`
* VM ต้องมี `ansible-core` + `git` เพิ่ม (playbook รันบนเครื่องตัวเอง)
* `deploy/ansible/deploy.yml` แก้แค่ `force_redeploy` ที่ duplicate-release check · inventory override จาก `pos-deploy` ด้วย
  `-i 'vm-demo,' -e ansible_connection=local` · การรันด้วยมือผ่าน SSH (handoff 2026-09-15 §5) ยังใช้ได้เหมือนเดิม
* `deploy/scripts/verify-ghcr-tags.sh` แยก exit 1 (ยังไม่มี image) ออกจาก 2 (ถาม registry ไม่ได้) — 2 ทำให้ run แดง

## Addendum 2026-09-15 — owner round 2 on #240 (E11) + #242

| # | ตัดสิน | ผลกับ ADR นี้ |
|---|---|---|
| #242 | host = VM ของภาค **`mob04`** · **สภาพแวดล้อมเดียว และเป็น production** · ไม่มี demo แยก · cutover ร้านจริงจากนอกมหาวิทยาลัย = เฟสถัดไป | environment ที่ ADR นี้และ `07_CICD_DEPLOY.md` เรียก `demo` คือ production ตัวเดียว (ชื่อ environment ใน GitHub แก้ใน #67) |
| ~~E11~~ | ~~deploy ด้วย **self-hosted GitHub Actions runner บน `mob04`** · รันเฉพาะ job `deploy` บน `main` ผ่าน protected environment · **ห้ามรัน workflow ของ PR** (repo public)~~ | ~~แทน "Actions → SSH → Ansible" จาก GitHub-hosted runner ซึ่งเข้า VM ในเครือข่ายมหาวิทยาลัยไม่ได้ · Ansible playbook ยังใช้ แต่รันจาก runner บนเครื่องเอง~~ ~~**(แทนที่โดย F4 รอบ 3)**~~ **(F4′: runner ที่ใช้จริงคือของ #237 — ดูหัวข้อ *Actions เข้าถึง VM อย่างไร* ด้านบน)** |

รายละเอียด: [`08_PHASE2_SPEC.md §17`](../08_PHASE2_SPEC.md) · ticket #67

## ~~Addendum 2026-09-15 (รอบ 3) — owner round 3 on #240 (F4)~~ — ถูกกลับโดย F4′

| # | ตัดสิน | ผลกับ ADR นี้ |
|---|---|---|
| ~~F4~~ | ~~**deploy แบบ pull**: systemd timer บน `mob04` อ่าน digest ของ image `main` บน GHCR (server + web) · เปลี่ยน → อ่าน sha จาก label `org.opencontainers.image.revision` → รัน `deploy.yml` ในเครื่อง (rollback เดิม) · lock กันรันซ้อน · **ไม่มี self-hosted runner**~~ | ~~แทน E11 และ "Actions → SSH → Ansible" · repo public — runner ที่ fork PR เรียกได้ = รันโค้ดบน production · ไม่ต้องมี inbound · GitHub Actions เหลือ build + scan + push image~~ |

รายละเอียด: [`08_PHASE2_SPEC.md §17`](../08_PHASE2_SPEC.md) · ticket #67

## Addendum 2026-09-15 (รอบ 4) — owner F4′ on #240

**F4′ แทน F4:** ใช้ **self-hosted runner ที่ PR #237 merge แล้ว** (job-started hook รับเฉพาะ `deploy.yml@refs/heads/main` fail-closed · user `gha-runner` ไม่มี docker/`.env` · sudoers คำสั่งเดียว `pos-deploy` deploy เฉพาะ commit บน `main` · workflow ไม่ใช้ secret) · **ไม่สร้าง pull-based timer** · รายละเอียดทั้งหมดอยู่ในหัวข้อ *Actions เข้าถึง VM อย่างไร* ด้านบน — ไม่คัดลอกซ้ำ · ความเสี่ยง fork PR ที่ review รอบ 2 ของ PR #254 ยกขึ้นปิดด้วย hook + wrapper · run จริงบน VM = #67 · 08 §17
