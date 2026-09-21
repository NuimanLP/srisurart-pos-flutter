# Handoff — ปิดชุดใบงานเดโม #335 ทั้งสามเลน และ CD ถูกบล็อกที่ firewall ของคณะ (2026-09-21)

**วันที่:** 2026-09-21 · **ผู้บันทึก:** Claude Opus 5 ทำหน้าที่ orchestrator ของสามเลน (เลน A/B/C) ร่วมกับเจ้าของ `NuimanLP` · **สถานะ:** ติดอยู่ — งานในรีโปปิดครบ แต่ deploy ขึ้น VM ทำไม่ได้เพราะเครือข่าย
**ขอบเขต:** merge งานทั้งสามเลนของ #335 เข้า `main`, ปลดบล็อกเกอร์ `.env` บน `mob04`, พยายาม deploy จริง แล้วพบว่า CD ตายที่ SSL inspection ของ FortiGate
**ต่อจาก:** [`demo-335-three-agent-split.md`](demo-335-three-agent-split.md) (แผน) · [`demo-335-STATUS.md`](demo-335-STATUS.md) (กระดานสถานะ) · [`ticket-343-vm-deploy.md`](ticket-343-vm-deploy.md) (runbook ที่รอบนี้พิสูจน์ว่ามีช่องว่าง)

---

## 1. ตอนนี้อยู่ตรงไหน

- **`main` = `825a497`** · ไม่มี PR เปิดค้าง · `docs/handoff_log/INDEX.md` และ `demo-335-STATUS.md` เป็น LF สะอาด
- **`mob04` (172.30.58.20) ไม่ถูกแตะเลยแม้ไบต์เดียวในส่วนของสแตก** — 13 container ยังรัน image `8e873cd56a4e3012c0474ebf20027987203a35aa` (merge #234) ขึ้นมา 5 วัน healthy ทุกตัว · `.current_sha` ยังเป็น `8e873cd…` **ตามหลัง `main` 188 commit**
- สิ่งเดียวที่เปลี่ยนบน VM: `/opt/pos/.env` ถูกเติมสองคีย์ (ดู §2) และมี backup `/opt/pos/.env.bak-1789975618` (= เนื้อหาเดิมก่อนแก้ ขนาด 2789 ไบต์)
- **CI ทำงานครบ 100%** · **CD ทำไม่ได้** — ทั้งเส้นทาง deploy ด้วยมือ (D9) และเส้นทาง self-hosted runner (#67) ตายที่จุดเดียวกัน (§4)
- AC ของ **#343 ยังไม่ปิดข้อใดเลย** — pre-flight ผ่านหมดแล้ว เหลือขั้นเดียวคือ "ทำให้ image ลงเครื่องได้"

---

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

### 2.1 merge 11 PR เข้า `main`
| PR | ใบ | เลน |
|---|---|---|
| #349 → #350 → #351 | #339 #340 #341 (metrics) | B |
| #359 · #360 | #337 · #338 | A |
| #361 · #362 | #346 · #343 | C |
| #355 · #358 | กระดานสถานะ | B · C |
| #368 | แก้ line ending ที่เซสชันนี้ทำพัง (§4.1) | — |

### 2.2 เปิดใบใหม่ 5 ใบจากของที่ตรวจพบพร้อมหลักฐาน
- **#363** `backup-db.sh` ไม่มีขั้นส่งไฟล์ออกนอก VM เลย (`grep -nE 'scp|rsync|aws |s3|rclone|sftp'` ไม่มีผล จบที่ prune ในเครื่อง `:107-108`) ขณะที่ AC ข้อนั้นของ **#288 ยังเป็น `[ ]` ทั้งที่ใบปิดแล้ว**
- **#364** `ownerPassword` ของ `POST /platform/tenants` ตรวจแค่ว่ามีค่า (`platform-tenants.service.ts:52-54`) ⇒ ตั้ง `1234` ได้ ขณะที่ `bootstrap:admin` บังคับ 12 ตัว
- **#365** `/opt/pos/docker/etcd/etcd-init.sh` บน VM **เป็นไดเรกทอรีของ root** ⇒ etcd ไม่เคยเปิด auth
- **#366** `Deploy (demo)` ยิงอัตโนมัติทุก green `main` ขัดกับ D9 ที่เลือก deploy ด้วยมือ
- **#367** `CORS_ORIGINS` / `PLATFORM_ADMIN_IPS` ไม่มี compose ไฟล์ใดส่งเข้า container ⇒ CORS เป็น `'*'` ตลอด · **ห้ามใครเขียน AC ว่าปิด CORS แล้ว** จนใบนี้ merge

### 2.3 แก้สถานะใบที่ไม่ตรงความจริง
- **#345** ติ๊กให้ **3 จาก 5** ข้อ เฉพาะข้อที่ orchestrator ตรวจยืนยันจากใบจริงเอง (`#196` ไม่เหลือ *needs owner secrets*, ช่อง #292–#297 ติ๊กครบหก, `#184` ระบุว่าเหลือ k6+RSS) · **สองข้อที่ไม่ติ๊กและเหตุผลเขียนไว้ในใบ**: เจ้าของใบ `PattaraponKitcharoen` ยังไม่ตอบรับ และ `#184` ไม่มีช่องใดมีหลักฐาน (`- [x]` = 0) จึงยังไม่มีอะไรให้ติ๊ก · ใบ **ยังเปิด** ไม่ปิดโดย AC ว่าง
- กระดานสถานะ: แถว #337–#341 ปรับเป็น ✅ merged · #346 เป็น `AC1/AC3 ค้าง` · #343 เป็น `pre-flight เสร็จ` · #345 เป็น `ทำแล้ว`

### 2.4 รัด ACL ของ key และไฟล์ secret บนเครื่อง dev
พบว่า `mob04-SriStore`, `deploy_ed25519`, `demo.env` มีสิทธิ์ **`Everyone:(RX)` + `NT AUTHORITY\Authenticated Users:(M)`** — `(M)` คือ **แก้ไฟล์ได้** ไม่ใช่แค่อ่าน · private key ที่แก้ได้คือ private key ที่สลับได้
แก้เป็น `NUIGATES-PC\nuima:(R)` ทั้งสามไฟล์ · ยืนยันหลังแก้ว่า ssh เข้า VM ได้ปกติ
นี่คือเหตุผลที่ orchestrator ต่อ VM ได้ตั้งแต่ต้นแต่เจ้าของต่อไม่ได้: `ssh` ของ Git Bash (MSYS) ไม่อ่าน Windows ACL ส่วน `C:\Windows\System32\OpenSSH\ssh.exe` บังคับ

### 2.5 pre-flight ของ #343 — ผ่านทุกข้อ
| ตรวจอะไร | ผลจริง |
|---|---|
| SHA + image | `825a4972fa461fa4f5c01897dbda8e2ef5e2d8fb` · Server CI + Flutter CI **success** · `verify-ghcr-tags.sh` → server และ web **HTTP 200** |
| `ansible -m ping` (user `deploy`) | **SUCCESS / ping: pong** |
| network pre-flight (D9 ข้อ 4) | `{"Subnet":"172.30.0.0/24","IPRange":"172.30.0.128/25"}` ⇒ assert ผ่าน **ไม่ต้องดาวน์ไทม์ และห้ามทำเผื่อ** |
| ดิสก์ | 48G ใช้ 14% |

### 2.6 ปลดบล็อกเกอร์ `.env` สำเร็จ
เติม `K6_REMOTE_WRITE_BASIC_AUTH_USER=k6` และ `K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD=<สุ่ม hex 24>` ต่อท้าย `/opt/pos/.env`
ยืนยันด้วย `grep -c -e ^K6_REMOTE_WRITE_BASIC_AUTH_USER=` → **1** และ `..._PASSWORD=` → **1** · สิทธิ์ยังเป็น `-rw------- deploy deploy`
**พิสูจน์ว่าได้ผลจริง**: รอบก่อนแก้ `deploy.yml` ตายที่ `error while interpolating services.htpasswd-gen.environment.K6_REMOTE_WRITE_BASIC_AUTH_USER` · รอบหลังแก้ ผ่าน task นั้นไปถึงขั้น `docker pull` จริง

### ตรวจสอบด้วยอะไร
ทุกข้อในตารางข้างบนมาจากการรันคำสั่งจริงบน VM แบบอ่านอย่างเดียว (`ssh` + `cat`/`ls`/`docker ps`/`docker network inspect`/`openssl s_client`) และการรัน `ansible-playbook` จริงสองรอบ · **ไม่มีข้อใดมาจากการอนุมานจากไฟล์**

---

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

### 3.1 กัน `/metrics` + `/health/live` + `/health/ready` ออกจาก SLI — เจ้าของรับรอง
ทางเลือก: (ก) เก็บไว้ (ข) ถอนออกตามตัวอักษร D4/D6 (ค) เก็บไว้แต่เพิ่ม panel แยก
**เลือก (ก)** · เหตุผลชี้ขาดเป็นตัวเลข: scrape ทุก 15 วิ × 3 instance + healthcheck 15 วิ × 3 = **~36 คำขอสถานะ 200 การันตีต่อนาที** และ panel *API success rate* / *p95* เฉลี่ยทุกซีรีส์ใน `http_requests_total` ⇒ **วันที่บิลจริงพลาดทุกใบ dashboard จะยังอ่านได้ ~92% healthy** · dashboard ที่โกหกแบบนั้นแย่กว่าไม่มี dashboard
สิ่งที่ D6 สั่งตรง ๆ ยังครบ: 401/429 ยังถูกนับ · ชื่อเมตริกไม่เปลี่ยน · ไม่มี label `tenant_id` · replay ยังนับหลัง commit
**ผู้ตัดสิน:** เจ้าของ (`NuimanLP`) · บันทึกเป็น addendum ของ D6 ที่ #335 `#issuecomment-5756036860`

### 3.2 CORS แยกเป็นใบทำ **หลัง** เดโม (#367)
เกือบเลือกทำก่อนเพราะการแก้ compose จะได้ติดไปกับ deploy รอบเดียว แต่สองข้อนี้พลิกคำตอบ:
- VM **รับ inbound จากนอกมหาวิทยาลัยไม่ได้แล้ว** (`07_CICD_DEPLOY.md:157` ขีดฆ่าไว้) ⇒ `'*'` บนกล่องที่เข้าได้แค่ผ่าน VPN ความเสี่ยงต่ำ
- ตั้ง `CORS_ORIGINS` ผิด origin **ทำให้ web client พังทั้งใบ** และจะพังตอนเดโม ไม่ใช่ตอนทดสอบ

🔴 **เงื่อนไขที่พลิกทันที**: ถ้า VM กลับมารับ inbound จากนอกมหาวิทยาลัย ใบนี้ต้องทำก่อน

### 3.3 ไม่แก้ค่า default `ansible_user` ใน `hosts.ini`
เลน C เสนอเหตุผลที่ orchestrator ยอมรับ: `deploy` **ถูกแล้ว** เพราะเป็น playbook ที่รันทุก release และที่ `pos-deploy.sh` เรียก · `provision.yml` เป็นงานนาน ๆ ครั้ง ให้ผู้เรียกส่ง `DEMO_SSH_USER=cloud` เอง · แก้ default = ทำทางหลักผิดเพื่อให้ทางหายากสะดวก · **ที่ขาดคือตาราง user ไม่ใช่ default อื่น**

### 3.4 เติมสองคีย์ K6 ลง `.env` เดิม แทนที่จะเขียนไฟล์ทั้งใบทับ
นี่คือการตัดสินใจที่สำคัญที่สุดของรอบนี้ (ดู §4.3 สำหรับสาเหตุ) · เลือกทางที่**กลับได้และแตะน้อยที่สุด** เพราะสองคีย์นี้ใช้แค่กับ `htpasswd-gen` สำหรับ k6 remote-write ไม่เกี่ยวกับรหัสที่อบใน volume · สร้างรหัสใหม่บน VM เอง (`openssl rand -hex 24`) ไม่ต้องขนค่าจาก #336 ข้ามเครื่อง
**ผู้ตัดสิน:** orchestrator เสนอ เจ้าของรันเอง

---

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

### 4.1 🔴 `--delete-branch` กับ stacked PR → PR ถัดไปถูกปิดอัตโนมัติ
`gh pr merge 349 --merge --delete-branch` ลบ `feat/339-metrics-serve` ซึ่งเป็น **base ของ #350** → GitHub ปิด #350 ทันที และ **ไม่ยอมให้เปลี่ยน base ของ PR ที่ปิดแล้ว**
กู้ได้ด้วย: `git push origin <old-tip>:refs/heads/<base-branch>` → `gh pr reopen` → `gh pr edit --base main` → merge → ลบ branch ทีหลัง
**บทเรียน: อย่าใช้ `--delete-branch` กับ stacked PR เลย เก็บกวาด branch ทีเดียวตอนจบ**

### 4.2 🔴 เขียนไฟล์ด้วย Python text mode บน Windows → CRLF ทั้งไฟล์ → ชนทั้งไฟล์กับทุก branch
สคริปต์รวม conflict ของ #360 เขียนผ่าน `open(p,"w")` ซึ่งบน Windows แปลง `\n` → `\r\n` · **เนื้อหาไม่เปลี่ยนเลย** แต่ `INDEX.md` และ `demo-335-STATUS.md` กลายเป็น CRLF ⇒ conflict กับ #355/#358/#361/#362 **ตั้งแต่บรรทัด 1 ถึงท้ายไฟล์** เพราะ git ไม่มีบรรทัดไหนจับคู่ได้
เกือบไปนั่งรวมกระดานทั้งใบด้วยมือ ซึ่งจะทำให้เนื้อหาของเลน B/C หายบางส่วน
แก้ด้วย PR #368 (แปลงกลับเป็น LF ด้วย `open(p,"wb")`) · ยืนยันด้วย `git diff --ignore-cr-at-eol origin/main` = ว่าง
**บทเรียน: แก้ conflict ต้องเขียนแบบ binary `open(p,"wb")` และอ่านแบบ `replace(b"\r\n",b"\n")` เสมอ**

### 4.3 🔴 `DEMO_ENV_FILE` ที่เจ้าของถือ **ไม่มีคีย์ K6** — runbook §7 step 3 ใช้ไม่ได้ตามที่เขียน
| ไฟล์ | คีย์ K6 | ปัญหา |
|---|---|---|
| `~/.ssh/demo.env` (ที่เจ้าของถือ) | **0** | re-provision ด้วยไฟล์นี้ **บล็อกเกอร์ไม่หาย** — มี 14 คีย์เท่ากับ `.env` เก่าบน VM |
| `vm.env` ที่ #336 สร้าง | 2 ✅ | **สุ่ม `POSTGRES_PASSWORD` / `POS_APP_PASSWORD` / `ETCD_ROOT_PASSWORD` ใหม่หมด** ⇒ ไม่ตรงกับที่อบไว้ใน volume `pgdata`/`etcd-data` ⇒ Postgres ปฏิเสธ `pos_app` และ etcd-init ล้ม `root cannot authenticate` |

พยายามพิสูจน์ว่าไฟล์เก่าตรงกับบน VM เป๊ะไหมด้วย **การเทียบ sha256 ไม่อ่านค่า** → **ต่างกัน** (`d10f9a5b…` vs `17a04cfa…`) จึงพิสูจน์ไม่ได้ว่าปลอดภัย
⇒ ทางตันของ step 3 ตามที่เขียนไว้ · ทางที่ใช้จริงคือ §3.4

### 4.4 `>>` ผ่าน `sudo -n sh -c "…"` ที่ส่งข้าม PowerShell → bash → ssh
quote ถูกกินจนหมด ทำให้ **shell ฝั่ง VM (ที่ไม่ใช่ root) เป็นคน redirect** → `bash: line 3: /opt/pos/.env: Permission denied`
แก้ด้วย `sudo -n tee -a /opt/pos/.env < /tmp/k6.add > /dev/null` — `<` และ `>` ทำโดย shell ที่มีสิทธิ์อยู่แล้ว ส่วนการเขียนไฟล์เป็นงานของ `tee` ที่รันเป็น root

### 4.5 ไฟล์เดิมไม่มี newline ปิดท้าย → คีย์แรกที่เติมถูกเชื่อมติดท้ายค่าของคีย์ก่อนหน้า
`grep -c K6_REMOTE_WRITE_BASIC_AUTH` ได้ **2** (ดูเหมือนสำเร็จ) แต่ `grep -c -e ^K6_REMOTE_WRITE_BASIC_AUTH_USER=` ได้ **0**
เพราะ `grep -c` นับ *บรรทัดที่มีคำนั้น* ไม่ได้เช็คว่าขึ้นต้นบรรทัด · ไบต์สุดท้ายของ backup คือ `7` ไม่ใช่ `\n`
compose จึงยังฟ้องว่าตัวแปรหาย ทั้งที่ `grep` บอกว่ามี
**บทเรียน: ตรวจ `.env` ต้อง anchor ด้วย `^` เสมอ และ append ต้อง `echo` บรรทัดว่างนำหน้า**

### 4.6 `ansible-playbook --check` พิสูจน์ `deploy.yml` ไม่ได้ (บันทึกโดยเลน C ยืนยันโดย orchestrator)
`--check` พ่น `fatal: network … predates the ip_range` ซึ่งเป็น **false positive** — `ansible.builtin.command` ไม่มี check mode จึงถูก skip ทำให้ `pos_network.stdout` ว่าง (สังเกต `()` ว่างในข้อความ) · network จริงมี `ip_range` ครบ
⇒ `--check` ของ playbook นี้ไปไม่เกิน `command` ตัวแรก **ห้ามเอาผลไปอ้างเป็นหลักฐาน**

### 4.7 🔴 ทางตันของจริง — FortiGate ตัด TLS ขา outbound ของ VM
`deploy.yml` ล้มที่ `Pull release images from GHCR`:
```
tls: failed to verify certificate: x509: certificate is not valid for any names, but wanted to match ghcr.io
```
วินิจฉัยจาก VM:
```
subject = C=US, ST=California, L=Sunnyvale, O=Fortinet, OU=FortiGate, CN=FG3K4ETB19900078
issuer  = C=US, ST=California, L=Sunnyvale, O=Fortinet, OU=Certificate Authority, CN=fortinet-subca2001
notBefore=Sep 17 23:14:52 2024 GMT   notAfter=May 26 20:48:33 2056 GMT
```
DNS ยังชี้ IP จริงของ GitHub (`20.205.243.164`) ⇒ **transparent SSL deep inspection ที่ firewall ของคณะ** ไม่ใช่ DNS hijack และไม่ใช่ปัญหาของโค้ดหรือ config ในรีโป

🔴 **ติดตั้ง CA ของ Fortinet เข้า trust store ก็แก้ไม่ได้** — ข้อความคือ *"not valid for any names"* หมายถึงใบนั้น **ไม่มี SAN เลย** เป็นใบประจำเครื่องของ FortiGate ไม่ใช่ใบที่สร้างต่อโฮสต์ ⇒ hostname verification ล้มอยู่ดีไม่ว่าจะ trust CA หรือไม่

⇒ **CD ตายทั้งสองเส้นทางพร้อมกัน**: deploy ด้วยมือ (D9) และ auto-deploy ผ่าน self-hosted runner (#67) เพราะ runner จะรันบน VM เดียวกันและใช้ docker daemon เดียวกัน

---

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

**ยืนยันแล้ว**
- FortiGate ทำ SSL inspection กับ `ghcr.io` จาก `172.30.58.20` (ดูใบรับรองจริงใน §4.7)
- `.env` บน VM มีคีย์ K6 ครบและ anchor ถูกบรรทัด
- image ของ `825a4972…` ทั้ง server และ web **มีอยู่จริงบน GHCR** (HTTP 200 จากเครื่อง dev)
- เครื่อง dev เข้า `ghcr.io` ได้ (จึงเป็นไปได้ที่จะขน image ด้วยมือ)
- VM เคย pull image สำเร็จเมื่อ 5 วันก่อน (container ทั้ง 13 ตัวรัน image จาก GHCR อยู่) ⇒ policy เพิ่งเปลี่ยน

**แค่เดา / ยังไม่ตรวจ**
- **ไม่รู้ว่า policy เปลี่ยนเมื่อไหร่และใครเปลี่ยน** — ไม่ได้ถามฝ่ายเครือข่าย
- **ไม่รู้ว่า inspection ครอบทุก host หรือเฉพาะบางหมวด** — ตรวจแค่ `ghcr.io` ตัวเดียว ยังไม่ได้ลอง `registry-1.docker.io` / `gcr.io` ทั้งที่ playbook ต้องใช้ทั้งสอง (`postgres:16-alpine`, `redis:7-alpine`, `nginx:1.29-alpine`, `gcr.io/etcd-development/etcd:v3.6.12`, `alpine/openssl`, `curlimages/curl:8.16.0`)
- **ไม่รู้ว่า `docker save`/`load` จะพอ** — ถ้า inspection ครอบ Docker Hub ด้วย ต้องขน image พื้นฐานทั้งหมดไม่ใช่แค่สองตัวของเรา
- **ไม่รู้ว่ารหัสใน `~/.ssh/demo.env` ตรงกับที่อบใน volume `pgdata`/`etcd-data` หรือไม่** — hash ต่างจากไฟล์บน VM แต่ไม่ได้แปลว่าค่าต่าง อาจต่างแค่คอมเมนต์/รูปแบบ · **ยังไม่พิสูจน์** และห้ามเดา
- **AC 1–3 ของ #340** (Prometheus target เขียวสามตัว, panel มีข้อมูลใน 1 นาที, ค่ารวมไม่เพี้ยนเมื่อ container รีสตาร์ท) — เลน B บอกเองว่าเลขคณิตรองรับแต่ **ไม่มีใครเห็นจริง** ต้องเดินบน VM ก่อนติ๊ก

---

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **ขอฝ่ายเครือข่าย/IT ยกเว้น SSL deep inspection สำหรับ `172.30.58.20`** ปลายทาง `ghcr.io`, `registry-1.docker.io`, `gcr.io` — **รอคน: ฝ่ายเครือข่ายคณะ** · นี่คือทางเดียวที่ทำให้ CD กลับมาใช้ได้จริง แนบใบรับรองใน §4.7 เป็นหลักฐาน
2. **ตรวจว่า inspection ครอบ registry อื่นด้วยหรือไม่** — รัน `openssl s_client` กับ `registry-1.docker.io` และ `gcr.io` จาก VM · ทำได้ทันทีไม่ต้องรอใคร และเป็นข้อมูลที่ข้อ 1 ต้องใช้
3. **ถ้าเดโมใกล้จนรอ IT ไม่ได้: ขน image ด้วยมือ** `docker pull` บนเครื่อง dev → `docker save` → `scp` → `docker load` บน VM แล้วรัน playbook โดยข้ามขั้น pull · **ไม่ใช่ CD** ใช้กู้สถานการณ์เท่านั้น และต้องบันทึกว่าทำแบบนี้ ห้ามให้ใครเข้าใจว่า CD ใช้งานได้
4. **เปิดใบใหม่บันทึกว่า CD ถูกบล็อกโดย network policy** เพื่อไม่ให้ใครติ๊ก AC ของ #67 หรือ #343 ว่าผ่าน — ยังไม่ได้เปิด
5. **แก้ runbook `ticket-343-vm-deploy.md` §5/§7 step 3** ตาม §4.3 ของไฟล์นี้ (DEMO_ENV_FILE ที่เจ้าของถือไม่มีคีย์ K6 / ไฟล์ที่มีดันสุ่มรหัส datastore ใหม่ / วิธีเติมแบบกลับได้) — ยังไม่ได้ทำ
6. **หลัง deploy ผ่านแล้ว** เดิน §7 step 5–6 และ §8 ของ runbook: `/health/ready` + `.current_sha` (AC 2) → ตรวจ Grafana **แยกจาก exit code ของ playbook** (AC 4) → ซ้อม rollback ไป `325bf802641372b307c791363e890a1cb01a5e5f` แล้ว deploy กลับ (AC 3) → บันทึกคำสั่งจริงทุกบรรทัด (AC 5)
7. **แล้วจึงปิด #340 AC 1–3, #346 AC3, #184 AC1–2** ซึ่งทั้งหมดรอ VM เดินก่อน
8. **#346 AC1 รอเจ้าของรับทราบ** ว่า premise กลับด้าน — cron ไม่เคยถูกติดตั้งเลย ไม่ใช่ล้มเงียบทุกคืน

---

## 7. ข้อควรระวัง

- 🔴 **ห้าม `docker compose down -v`** ทั้งบนเครื่อง dev และบน VM (CLAUDE.md — เคยลบ volume ของเซสชันอื่น) · สแตก local ชื่อ default `srisurart-pos` เป็นของเลน A · เลนอื่นใช้ `-p <ชื่อไม่ซ้ำ>` และลบเฉพาะ volume ที่ prefix ตรงกัน
- 🔴 **ห้ามใส่ `--diff` กับ `provision.yml`** — จะพิมพ์ `/opt/pos/.env` ทั้งไฟล์ (ทุก secret) ลงจอและลง log
- 🔴 **`pgdata` / `etcd-data` / `nginx-auth` อบ secret ไว้ตอน bootstrap ครั้งแรกเท่านั้น** — เปลี่ยน `POSTGRES_PASSWORD` หรือ `ETCD_ROOT_PASSWORD` ใน `.env` **ไม่ re-key volume** · ถ้า deploy ล้มด้วย `root cannot authenticate` หรือ Postgres ปฏิเสธ `pos_app` **นั่นคือเรื่องนี้ ไม่ใช่บั๊ก — หยุดและรายงาน** การ re-key เป็นการตัดสินใจแยก ไม่ใช่ขั้นตอนที่ improvise ได้
- 🔴 **`deploy.yml` กับ `provision.yml` ใช้ user คนละคน ไม่สลับกันได้** — `deploy.yml` = `deploy` + `~/.ssh/deploy_ed25519` (เป็นเจ้าของ `/opt/pos` และอยู่ group `docker` แต่ **ไม่มี sudo**) · `provision.yml` = `cloud` + `~/.ssh/mob04-SriStore` (มี sudo แต่ **ไม่อยู่ group `docker`** และเขียน `/opt/pos` ไม่ได้)
- **`--check` ปิดบั๊กเรื่อง user ไว้สนิท** (`copy` เทียบ checksum แล้วไม่เขียน, `command` ถูก skip) — ถ้าไม่เจอตอน pre-flight จะไปเจอวันเดโม
- **`Deploy (demo)` รายงาน `success` ได้ทั้งที่ไม่ deploy อะไรเลย** — job `deploy to demo` ถูกข้ามเมื่อ `needs.resolve.outputs.images_ready != 'true'` (เช่นตอน Server CI ยังรัน) ⇒ **badge เขียวของ workflow นี้ไม่ใช่หลักฐานว่า deploy แล้ว** ต้องดู `.current_sha` บน VM เท่านั้น
- **ตรวจ `.env` ต้อง anchor `^`** (§4.5) · **append ต้องมี newline นำหน้า**
- **แก้ merge conflict ต้องเขียนไฟล์แบบ binary** (§4.2)
- **`~/.ssh/demo.env` และ `scratchpad/336/vm.env` มี secret จริง** — `vm.env` อยู่ใน temp ของเซสชันและจะหายเมื่อเซสชันจบ ถ้าต้องเก็บ `DEMO_ENV_FILE` ฉบับที่มีคีย์ครบ **ให้ย้ายออกไปที่ปลอดภัยก่อน** · ทั้งสองไฟล์ห้ามขึ้น git
- **backup ของ `.env` ก่อนแก้อยู่ที่ `/opt/pos/.env.bak-1789975618`** (2789 ไบต์ ไม่มี newline ปิดท้าย) — ถ้าต้องกู้ ใช้ไฟล์นี้
- **สแตก dev บนเครื่องนี้มีของค้างโดยตั้งใจ**: platform admin `vmform-337` และ tenant `srisurart-demo` (owner `owner_demo`, เครื่อง `pos1` ผูกแล้ว) — รหัสเป็น dev-only ของ Postgres ใน compose เครื่องนี้ ไม่ใช่ค่าของ VM · คำสั่งลบตามลำดับปลอดภัยอยู่ใน `ticket-337-admin-bootstrap.md` §5 · `devices` และ `audit_log` **ไม่มี FK ไป `tenants`** จึงต้องลบเอง ไม่งั้นเหลือแถวกำพร้าเงียบ ๆ
- **`deviceToken` ต้องส่งใน JSON body ไม่ใช่ header `X-Device-Token`** — ส่งเป็น header ก็ยังได้ 200 + accessToken แต่ token **ไม่มี `did`/`drole`** แล้วไปตายทีหลังที่ route ที่ต้องมีเครื่อง (ผิดแบบเงียบ)

---

## 8. อ้างอิง

- **สเปกแม่และการตัดสินใจ**: #335 (D1–D10) · addendum ของ D6 ที่ #335 `#issuecomment-5756036860`
- **แผนและสถานะ**: [`demo-335-three-agent-split.md`](demo-335-three-agent-split.md) · [`demo-335-STATUS.md`](demo-335-STATUS.md)
- **runbook ที่ใช้รอบนี้**: [`ticket-343-vm-deploy.md`](ticket-343-vm-deploy.md) (§2 วิธีรัน ansible จาก Windows · §3 ตาราง user · §7 ขั้นตอน deploy · §8 rollback drill) — **§7 step 3 มีช่องว่างตาม §4.3 ของไฟล์นี้ ยังไม่ได้แก้**
- **runbook ของใบอื่นในชุด**: [`ticket-336-env-secrets.md`](ticket-336-env-secrets.md) (§4 กับดักเรื่อง volume อบ secret) · [`ticket-337-admin-bootstrap.md`](ticket-337-admin-bootstrap.md) · [`ticket-338-platform-provision.md`](ticket-338-platform-provision.md) · [`ticket-346-backup-script-install.md`](ticket-346-backup-script-install.md)
- **เอกสารออกแบบ**: `docs/Backend_design/07_CICD_DEPLOY.md` §6 (ขั้นตอน deploy) §7 (network/etcd) §8 (อาการ auth ล้ม) · ADR-0013
- **ใบที่เปิดใหม่รอบนี้**: #363 #364 #365 #366 #367
- **ใบที่ยังเปิดและรอ VM**: #338 #340 (AC 1–3) #343 #344 #345 #346 #184 #67
- **คนที่ต้องถาม**: เจ้าของโครงการ `NuimanLP` (การตัดสินใจทั้งหมด) · `PattaraponKitcharoen` (เจ้าของ #184 #67 — ยังไม่ตอบรับเรื่อง reconcile) · **ฝ่ายเครือข่าย/IT ของคณะ** (ข้อ 1 ของ §6 — ตัวบล็อก CD)
