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
- CORS: `Origin` แปลกหน้าได้ **HTTP 500** (`app.setup.ts:67` throw `Error('Not allowed by CORS')`) แทนการปฏิเสธเรียบร้อย — พฤติกรรมเดิม (แก้ 2026-09-30: *ไม่*นับใน `http_requests_total`/SLI) · แก้แล้วใน PR #516, deploy `00d3488`
- #363/#288 backup พักไว้ → ยังไม่มี backup ออกจาก VM

## ต่อมา 2026-09-30 (orchestrator ตรวจบน VM)
- รัน `provision.yml` จาก `origin/main` สะอาด: `ok=18 changed=3 failed=0` · `.env` เขียนใหม่จากสำเนาของเจ้าของ — คีย์ที่**เพิ่ม**มีแค่
  `PLATFORM_ADMINS` (3 รายการ) อีก 17 คีย์เหมือนเดิมทุกตัว · สำรองเดิมไว้ที่ `/opt/pos/.env.bak-2026-09-30-0431`
- `CORS_ORIGINS=https://172.30.58.20` **มีอยู่ใน `.env` ของ VM ก่อนแล้ว** → CORS บน `mob04` ปิดแล้ว (ไม่ใช่ `'*'`) ตั้งแต่ deploy แรกของ runner ·
  ตรวจ: origin ตัวเองได้ `Access-Control-Allow-Origin: https://172.30.58.20`, origin อื่นไม่ได้ ACAO (แต่ได้ 500 — ดู "ยังเปิด")
- provision สร้าง `/opt/pos/scripts` + ลง `backup-db.sh`/`restore-db.sh`/`measure-container-rss.sh` — **ก่อนหน้านี้ cron 03:00 เรียกสคริปต์ที่ไม่มีอยู่**
  (backup ในเครื่องไม่เคยรัน) — ⚠️ แก้ 2026-09-30 เย็น: ไม่ถูกทั้งหมด — 03:00 ของ 09-29 สคริปต์*มีอยู่* แต่ **fail** ("Neither active docker compose postgres container…" ทิ้ง .gz ว่าง 20 ไบต์); เฉพาะ 03:00 ของ 09-30 ที่ "not found" (ดู session-2026-09-30-evening-clear-backlog.md) · offsite ยังพักไว้ (#363)
- Deploy (demo) แบบ dispatch run `36669582543` (`e50f4fa`) อนุมัติแล้ว สำเร็จ · `.env_applied_sha256` = hash ของ `.env` ใหม่ · api×3 สร้างใหม่ healthy ·
  `/health/ready` 200 · log api-1 `PLATFORM_ADMINS synced` สร้าง 3 · `platform_admins`: `lomer`, `nuiman`, `pattarapon` active (ไม่บันทึกรหัส)

## คำสั่งจริง (sanitized)

คำสั่งจริงของ 2026-09-30 **คัดจาก transcript ของ agent ที่รันแต่ละส่วน** ตามลำดับที่รัน (ปิด AC "คำสั่งจริงบันทึกใน `docs/handoff_log/`" ของ #343 และ #365) ·
บรรทัดที่ล้มหรือไม่ทำอะไร (no-op) คงไว้พร้อมหมายเหตุ — เป็นส่วนของบันทึกจริง · ไม่มีค่า secret: มีแค่ชื่อคีย์, placeholder และรหัสผิดที่ตั้งใจใส่ (`definitely-wrong`) ·
รหัส/token อ่านผ่าน `$(cat file)`, stdin หรือในเชลล์ปลายทางเท่านั้น
- ย่อ path: `<worktree>` = worktree ของ session, `$SPD` = scratchpad ของ session, `$SP` = `$SPD/pos-main` (worktree detached ที่ `e50f4fa`), `$WT` = `<worktree>`
- `…` ในคำสั่ง = ส่วนที่ย่อ (jq filter / inline python ยาว) ตามที่หมายเหตุใต้บล็อกอธิบาย
- Fork-PR approval และ environment `demo` **ถูกรันจริงแล้ว** (ส่วน A ข้อ 1–2) และตรวจซ้ำสดหลังรัน

### A. Runner + deploy แรก (#67, #366)

**0. Read-only pre-checks** (before step 1)
```
cd <worktree> && git fetch -q && git log --oneline -1 origin/main && sed -n 400,470p docs/Backend_design/07_CICD_DEPLOY.md && cat deploy/scripts/setup-mob04-runner.sh
R=repos/NuimanLP/srisurart-pos-flutter; gh api $R/actions/permissions/fork-pr-contributor-approval; gh api $R/environments/demo --jq '{p:.protection_rules, d:.deployment_branch_policy}'; gh api $R/actions/runners --jq '.total_count'; gh run list -R NuimanLP/srisurart-pos-flutter --workflow deploy.yml --limit 10 --json databaseId,headSha,status,conclusion,createdAt
```

**1. Fork-PR approval**
```
R=repos/NuimanLP/srisurart-pos-flutter; gh api -X PUT $R/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors && gh api $R/actions/permissions/fork-pr-contributor-approval
```

**2. `demo` environment**
```
R=repos/NuimanLP/srisurart-pos-flutter; gh api -X PUT $R/environments/demo --input - --jq '{p:[.protection_rules[]|{type, r:[.reviewers[]?.reviewer.login]}], d:.deployment_branch_policy}' <<'JSON'
{
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true },
  "reviewers": [{ "type": "User", "id": 64192543 }]
}
JSON
gh api -X POST $R/environments/demo/deployment-branch-policies -f name=main -f type=branch --jq '{name,type}'
gh api $R/environments/demo --jq '{p:[…same…], d:.deployment_branch_policy}'; gh api $R/environments/demo/deployment-branch-policies --jq '[.branch_policies[]|{name,type}]'
```

**3. Runner**
- SHA check and VM pre-state:
```
gh api repos/actions/runner/releases/tags/v2.337.0 --jq .body | grep -i -A1 'linux-x64-2.337.0.tar.gz' | head; gh api repos/actions/runner/releases/tags/v2.337.0 --jq '.assets[]|select(.name=="actions-runner-linux-x64-2.337.0.tar.gz")|.digest'
ssh mob04 'hostname; id; ls -la /opt/pos 2>&1 | head -20; sudo test -f /opt/pos/.env && echo env-present; sudo test -f /opt/pos/.current_sha && echo has-current-sha || echo no-current-sha; id gha-runner 2>&1; ls /home/gha-runner 2>&1; sudo docker ps --format "{{.Names}} {{.Status}}"; sudo grep -c "^PLATFORM_ADMINS=" /opt/pos/.env'
```
- Copy the scripts:
```
cd <worktree> && D=$(ssh mob04 'mktemp -d -p ~ pos-runner-setup.XXXX') && echo "$D" && scp -q deploy/scripts/setup-mob04-runner.sh deploy/scripts/pos-deploy.sh deploy/scripts/runner-job-started.sh mob04:"$D"/ && ssh mob04 "ls -la $D; sha256sum $D/*" && sha256sum deploy/scripts/... || shasum -a 256 deploy/scripts/...
```
- Registration token and installer run (token read from stdin on the VM):
```
D=/home/cloud/pos-runner-setup.NQKe; TOKEN=$(gh api -X POST repos/NuimanLP/srisurart-pos-flutter/actions/runners/registration-token --jq .token) && [ -n "$TOKEN" ] && printf '%s\n' "$TOKEN" | ssh mob04 "IFS= read -r T; sudo bash $D/setup-mob04-runner.sh \"\$T\" 2.337.0 70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613" 2>&1 | grep -v -i token | tail -40; unset TOKEN
```
- Cleanup and verify:
```
ssh mob04 'rm -rf /home/cloud/pos-runner-setup.NQKe; ls -d /home/cloud/pos-runner-setup.* 2>&1; id gha-runner; sudo cat /home/gha-runner/actions-runner/.env | grep HOOK; sudo cat /etc/sudoers.d/pos-deploy'; sleep 5; gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners --jq '.runners[]|{name,status,busy,labels:[.labels[].name]}'
```

**4. Pending deployments**
- Recheck (GET):
```
R=repos/NuimanLP/srisurart-pos-flutter; gh api $R/actions/runs/36591519465 --jq '{head_sha,status,event,head_branch}'; gh run list -R NuimanLP/srisurart-pos-flutter --workflow deploy.yml --status waiting --json databaseId,headSha; gh api $R/actions/runs/36591519465/pending_deployments --jq '[.[]|{env:.environment.name,id:.environment.id,can:.current_user_can_approve}]'; git -C <worktree> ls-remote origin refs/heads/main
```
- Approve (POST):
```
gh api -X POST repos/NuimanLP/srisurart-pos-flutter/actions/runs/36591519465/pending_deployments --input - --jq '.[]|{environment, sha, ref}' <<'JSON'
{"environment_ids":[21965225957],"state":"approved","comment":"first runner deploy e50f4fa (#67)"}
JSON
```

**5. Watch the run**
```
gh run watch 36591519465 -R NuimanLP/srisurart-pos-flutter --exit-status --interval 20 2>&1 | tail -15
```

**6. Log and VM verification**
- Job log and container state:
```
gh run view 36591519465 -R NuimanLP/srisurart-pos-flutter --log --job 109485667226 2>&1 | grep -E -i 'PLAY RECAP|failed=|rollback|rolled|hook|admit|current_sha|::error|::warning|deployed' | cut -c1-250 | head -20
ssh mob04 'sudo cat /opt/pos/.current_sha; sudo docker ps --format "{{.Names}}\t{{.Status}}\t{{.Image}}" ; sudo docker ps -a --filter status=exited --filter status=restarting --format "{{.Names}} {{.Status}}"'
```
- Health through nginx:
```
ssh mob04 'sudo docker ps --format "{{.Names}} {{.Ports}}" | grep -E "nginx|platform"; for u in http://localhost/api/v1/health/ready http://localhost/health/ready https://localhost/api/v1/health/ready https://localhost/health/ready; do printf "%s -> " $u; curl -sk -o /tmp/h.out -w "%{http_code}" --max-time 10 $u; echo " $(head -c 200 /tmp/h.out)"; done; rm -f /tmp/h.out; curl -sk -o /dev/null -w "web / -> %{http_code}\n" https://localhost/; sudo docker ps -a --format "{{.Names}} {{.Status}}" | grep -i etcd'
```

Only three substitutions were made: `<worktree>` stands for `/Users/chav_sir/Downloads/srisurart-pos-flutter/.claude/worktrees/sweet-poincare-4efdd9`, and the two `...` in the scp line are the same three script paths listed earlier on that line. No secret values were in any command.

### B. provision.yml re-run พร้อม `.env` (`VM-dploy-full-stack-tutorial.md` §2.5)

**0. Setup and reading (read-only)**
```
cd $WT && git fetch -q origin && git rev-parse origin/main && git worktree add --detach $SPD/pos-main e50f4fa983cada763e1e6ba4d7c84509682f58e0 2>&1 | tail -1 && grep -n '^## \|^### ' $SP/docs/tutorial/VM-dploy-full-stack-tutorial.md | head -40
sed -n 243,484p $SP/docs/tutorial/VM-dploy-full-stack-tutorial.md
cat $SP/deploy/ansible/provision.yml; ls $SP/deploy/ansible; cat $SP/deploy/ansible/inventory* 2>/dev/null | head -40; cat $SP/deploy/ansible/ansible.cfg 2>/dev/null
cat $SP/deploy/ansible/inventory/*; grep -n 'env_applied\|sha256\|force_redeploy\|workflow_dispatch' -A3 $SP/deploy/ansible/deploy.yml | head -80
sed -n 1,80p $SP/.github/workflows/deploy.yml; sed -n 455,470p $SP/deploy/ansible/deploy.yml
```

**1. Local file checks**
```
F=~/Downloads/mob04-demo.env; stat -f '%Sp' $F; for k in POSTGRES_PASSWORD POS_APP_PASSWORD REDIS_PASSWORD JWT_PLATFORM_SECRET JWT_PRIVATE_KEY JWT_PUBLIC_KEYS BULL_BOARD_PASSWORD ETCD_ROOT_PASSWORD GRAFANA_ADMIN_PASSWORD K6_REMOTE_WRITE_BASIC_AUTH_USER K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD; do grep -qE "^${k}=.+" $F && echo "ok $k" || echo "MISSING $k"; done; echo forbidden=$(grep -cE '^(ALLOW_DEV_SECRETS|IMAGE_TAG)=' $F) devonly=$(grep -c 'dev-only-' $F) crlf=$(grep -c $'\r' $F); echo pa_lines=$(grep -c '^PLATFORM_ADMINS=' $F) cors_lines=$(grep -c '^CORS_ORIGINS=' $F) pai_lines=$(grep -c '^PLATFORM_ADMIN_IPS=' $F)
python3 - <<'EOF'   # per PLATFORM_ADMINS entry: user non-empty, password length >= 12; CORS_ORIGINS == 'https://172.30.58.20' (prints booleans only)
grep -oE '^[A-Z0-9_]+=' $F | sort | tr '\n' ' '
```

Checking the server parser:
```
grep -rn 'PLATFORM_ADMINS' $SP/server/src --include=*.ts | grep -v spec | head
```
That one failed: zsh glob, no matches.
```
grep -rln 'PLATFORM_ADMINS\b' $SP/server/src | grep -v spec; f=$(...| head -1); grep -n "split\|log\|created\|updated\|PLATFORM_ADMINS" $f | head -40
sed -n 1,200p $SP/server/src/db/platform-admins-env.ts | grep -v '^\s*$' | head -120
grep -n 'export function passwordPolicyViolation' -A15 $SP/server/src/common/password.ts; grep -n 'MIN_PASSWORD\|MAX_' $SP/server/src/common/password.ts | head
python3 - <<'EOF'   # prints: quoted, has_space, has_hash, has_dollar, dup_users, password lengths
```

**2. Per-key hash diff**

`keyhash.py`, written with a heredoc, prints the key name plus the first 16 hex characters of sha256(value).
```
python3 $SPD/keyhash.py < ~/Downloads/mob04-demo.env | sort > $SPD/local.kh
ssh mob04 "sudo -n cat /opt/pos/.env | python3 -c '$(cat $SPD/keyhash.py)'" | sort > $SPD/vm.kh
```
That line failed on a quoting syntax error and produced no VM output.
```
join -a1 -a2 -e MISSING -o 0,1.2,2.2 $SPD/local.kh $SPD/vm.kh | awk '{...same/ADDED/REMOVED/CHANGED...}' | sort
```

Retry:
```
ssh mob04 'sudo -n cat /opt/pos/.env | python3 -c "$(cat)"' < /dev/null >/dev/null 2>&1
```
This was a stray no-op: empty stdin, so python ran with an empty script.
```
ssh mob04 'cat > /tmp/keyhash.py' < $SPD/keyhash.py && ssh mob04 'sudo -n cat /opt/pos/.env | python3 /tmp/keyhash.py; rm -f /tmp/keyhash.py' | sort > $SPD/vm.kh
wc -l < $SPD/vm.kh
join ... (same as above)
printf '%s\n' "$(cat ~/Downloads/mob04-demo.env)" | shasum -a 256 | cut -c1-16; printf '%s' "$(cat ~/Downloads/mob04-demo.env)" | shasum -a 256 | cut -c1-16; ssh mob04 'sudo -n sha256sum /opt/pos/.env | cut -c1-16; sudo -n cat /opt/pos/.env_applied_sha256 2>/dev/null | cut -c1-16; sudo -n tail -c1 /opt/pos/.env | od -c | head -1'
printf '%s' "$(grep -v '^PLATFORM_ADMINS=' ~/Downloads/mob04-demo.env)" | shasum -a 256 | cut -c1-16; ssh mob04 'sudo -n stat -c "%A %U:%G" /opt/pos/.env; cat /opt/pos/.current_sha; sudo -n grep -c "^PLATFORM_ADMIN_IPS=" /opt/pos/.env'
```

`linehash.py`, written with a heredoc, prints a per-line tag (KEY / BLANK / COMMENT / cont) plus the first 12 hex characters of the line's sha256.
```
python3 $SPD/linehash.py < ~/Downloads/mob04-demo.env > $SPD/l.lh
ssh mob04 'cat > /tmp/lh.py' < $SPD/linehash.py; ssh mob04 'sudo -n cat /opt/pos/.env | python3 /tmp/lh.py; rm -f /tmp/lh.py' > $SPD/v.lh
wc -l $SPD/l.lh $SPD/v.lh; diff $SPD/l.lh $SPD/v.lh
```

**3. Backup**
```
ssh mob04 'sudo -n cp -p /opt/pos/.env /opt/pos/.env.bak-$(date +%F-%H%M) && sudo -n ls -l /opt/pos/ | grep env.bak'
```
The copy succeeded. Exit was 1 only because `ls` without `-a` hides dotfiles, so the grep found nothing.
```
ssh mob04 'sudo -n ls -la /opt/pos/ | grep -i env'
```

**Deploy-user key check**
```
for f in ~/.ssh/*.pub; do ssh-keygen -lf "$f" | awk -v f="$f" '{print $2, f}'; done; echo ---; ssh mob04 'sudo -n ssh-keygen -lf /home/deploy/.ssh/authorized_keys' | awk '{print $2, $3, $4}'
awk '{print $1, $3}' ~/.ssh/mob04-SriStore.pub; ssh mob04 'sudo -n awk "{print \$1, \$3, NF}" /home/deploy/.ssh/authorized_keys; sudo -n sha256sum /home/deploy/.ssh/authorized_keys' ; shasum -a 256 ~/.ssh/mob04-SriStore.pub
```

**4. provision `--check`** (no `--diff`)
```
cd $SP/deploy/ansible && [ -z "${DEMO_ENV_FILE:-}" ] || echo "STOP: DEMO_ENV_FILE set"; ansible-playbook --version | head -1; DEMO_ENV_FILE="$(cat ~/Downloads/mob04-demo.env)" DEMO_SSH_KEY_PUB="$(cat ~/.ssh/mob04-SriStore.pub)" DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=cloud DEMO_SSH_KEY_PATH="$HOME/.ssh/mob04-SriStore" ansible-playbook provision.yml --check 2>&1 | grep -E '^(TASK|ok|changed|skipping|failed|fatal)|PLAY RECAP|vm-demo *:|msg' | paste - - | sed 's/\t/ => /' | cut -c1-200
ssh mob04 'ls -l /etc/apt/keyrings/ /usr/share/keyrings/ 2>&1 | grep -i docker; cat /etc/apt/sources.list.d/docker.list; ls -ld /opt/pos/scripts 2>&1; sudo -n crontab -l -u deploy 2>&1 | tail -2; curl -sS -o /dev/null -w "%{http_code}\n" https://download.docker.com/linux/ubuntu/gpg'
```

**5. provision, real run**
```
cd $SP/deploy/ansible && DEMO_ENV_FILE="$(cat ~/Downloads/mob04-demo.env)" DEMO_SSH_KEY_PUB="$(cat ~/.ssh/mob04-SriStore.pub)" DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=cloud DEMO_SSH_KEY_PATH="$HOME/.ssh/mob04-SriStore" ansible-playbook provision.yml 2>&1 | grep -E '^(TASK|ok|changed|skipping|failed|fatal)|vm-demo *:' | paste - - | sed 's/\t/ => /' | grep -vE '=> ok: \[vm-demo\]$' | cut -c1-160
printf '%s\n' "$(cat ~/Downloads/mob04-demo.env)" | shasum -a 256 | cut -c1-16; ssh mob04 'sudo -n sha256sum /opt/pos/.env | cut -c1-16; for k in PLATFORM_ADMINS CORS_ORIGINS POSTGRES_PASSWORD JWT_PRIVATE_KEY; do printf "%s=%s\n" $k "$(sudo -n grep -c "^$k=" /opt/pos/.env)"; done; sudo -n stat -c "%a %U:%G" /opt/pos/.env; ls -l /opt/pos/scripts'
```

**6. Dispatch, approve, watch**
```
ssh mob04 'sudo -n docker ps --format "{{.Names}} {{.ID}} {{.Status}}" | sort'; cd $WT && gh run list -w deploy.yml -L 5 --json databaseId,status,conclusion,headSha,event,createdAt
cd $WT && gh workflow run deploy.yml --ref main -f image_tag=e50f4fa983cada763e1e6ba4d7c84509682f58e0 && sleep 8 && gh run list -w deploy.yml -L 1 --json databaseId,status,headSha,event,createdAt
cd $WT && for i in $(seq 1 30); do s=$(gh run view 36669582543 --json status,jobs --jq '...'); echo "$s"; case "$s" in waiting*|completed*) break;; esac; sleep 10; done; gh api repos/NuimanLP/srisurart-pos-flutter/actions/runs/36669582543/pending_deployments --jq '.[]|{env:.environment.name,id:.environment.id,can:.current_user_can_approve}'; gh run view 36669582543 --log --job $(...) 2>/dev/null | grep -iE 'sha=|images_ready|deploy' | tail -5 | cut -c1-200
cd $WT && J=$(gh run view 36669582543 --json jobs --jq '.jobs[]|select(.name=="resolve release")|.databaseId'); gh api repos/NuimanLP/srisurart-pos-flutter/actions/jobs/$J/logs | grep -iE 'e50f4fa|images_ready' | tail -6 | cut -c1-200; gh run view 36669582543 --json headSha,event,headBranch
gh api -X POST repos/NuimanLP/srisurart-pos-flutter/actions/runs/36669582543/pending_deployments -F 'environment_ids[]=21965225957' -f state=approved -f comment='Apply PLATFORM_ADMINS .env change (#367/#443), owner-approved' --jq '.[].environment' ; cd $WT && gh run watch 36669582543 --interval 20 --exit-status > /dev/null 2>&1; gh run view 36669582543 --json status,conclusion,jobs --jq '...'
```
- The only input passed to `gh workflow run` was `image_tag=e50f4fa983cada763e1e6ba4d7c84509682f58e0`, on `--ref main`.
- In the polling loop and the final `gh run view`, the long `--jq` expressions are shortened to `'...'`. They only formatted status and conclusion for each job.

**7. VM verification**
```
ssh mob04 'cat /opt/pos/.current_sha; echo "applied=$(cut -c1-16 /opt/pos/.env_applied_sha256) env=$(sudo -n sha256sum /opt/pos/.env | cut -c1-16)"; sudo -n docker ps --format "{{.Names}} {{.ID}} {{.Status}}" | grep -E "api|worker|platform|nginx|bull"; curl -sk -o /dev/null -w "ready=%{http_code}\n" https://localhost/health/ready; for i in 1 2 3; do sudo -n docker logs srisurart-pos-api-$i-1 2>&1 | grep -E "PLATFORM_ADMINS (synced|sync failed)" | python3 -c "...print instance, msg, [(username[:2]+'…', action)]..."; done'
ssh mob04 'echo "-- evil"; curl -sk -o /dev/null -D - -H "Origin: https://evil.example" https://localhost/health/live | grep -i "^access-control\|^HTTP"; echo "-- own"; curl -sk -o /dev/null -D - -H "Origin: https://172.30.58.20" https://localhost/health/live | grep -i "^access-control\|^HTTP"; sudo -n docker exec srisurart-pos-postgres-1 sh -c "psql -U \"\$POSTGRES_USER\" -d \"\${POSTGRES_DB:-\$POSTGRES_USER}\" -Atc \"SELECT username, is_active FROM platform_admins ORDER BY username\""'
grep -rn "enableCors\|origin:" $SP/server/src --include='*.ts' 2>/dev/null | grep -v spec | head; grep -rln "enableCors" $SP/server/src | head -2 | xargs grep -n -A12 "enableCors" | head -30; ssh mob04 'sudo -n docker logs --since 5m srisurart-pos-api-1-1 2>&1 | grep -i "cors\|not allowed" | tail -2 | cut -c1-250'
```
In the first line, the inline python body is shortened to `"..."`. It parsed each JSON log line and printed the instance, the message, and each username's first 2 letters with its action.

**8. Cleanup**
```
cd $WT && git worktree remove $SPD/pos-main && rm -f $SPD/*.kh $SPD/*.lh $SPD/keyhash.py $SPD/linehash.py && git worktree list | grep -c pos-main; ssh mob04 'ls /tmp/keyhash.py /tmp/lh.py 2>&1 | head -2'; git branch --show-current
```

What was printed, other than hashes and booleans:
- the password lengths (19, 19, 19);
- the first 2 letters of each username in the log check;
- the full usernames (lomer, nuiman, pattarapon) from the `platform_admins` query.

No password or secret value was printed.

### C. etcd auth (#365) และ Grafana/Prometheus (#343)

ผลอยู่ใน comment ของ issue: #365 https://github.com/NuimanLP/srisurart-pos-flutter/issues/365#issuecomment-5906185451 · #343 https://github.com/NuimanLP/srisurart-pos-flutter/issues/343#issuecomment-5906181492

**1. Stack and path state (read-only)**
```
cat .current_sha 2>/dev/null; echo; ls -la docker/etcd/ 2>&1; stat -c "%F %U" docker/etcd/etcd-init.sh; sudo -n -u deploy docker ps --format "{{.Names}}\t{{.Status}}" | sort; ls /opt/pos/*.yml; ls -ld /opt/pos/backups
```

**2. etcd before-state (read-only)**
```
D="sudo -n -u deploy"; F="-f docker-compose.yml -f monitoring.yml -f vm.override.yml"
$D docker exec srisurart-pos-etcd-1 etcdctl --endpoints=http://127.0.0.1:2379 auth status 2>&1
$D docker exec srisurart-pos-etcd-1 etcdctl --endpoints=http://127.0.0.1:2379 get /pos/config/log_level 2>&1
$D docker exec -e ETCDCTL_USER= srisurart-pos-etcd-1 etcdctl --endpoints=http://127.0.0.1:2379 get /pos/config/log_level; echo "rc=$?"
$D docker compose $F run --rm --no-deps --entrypoint curl etcd-init -sS -w " HTTP=%{http_code}\n" -X POST http://etcd:2379/v3/kv/range -d "{\"key\":\"Lw==\"}" 2>&1 | tail -2
```
The last line failed with `IMAGE_TAG is required` and never ran curl.

**3. Proof both ways and api logs**
```
D="sudo -n -u deploy"; F="-f docker-compose.yml -f monitoring.yml -f vm.override.yml"; export IMAGE_TAG=$(cat .current_sha)
$D env IMAGE_TAG=$IMAGE_TAG docker compose $F run --rm --no-deps --entrypoint curl etcd-init -sS -o /dev/null -w "HTTP=%{http_code}\n" -X POST http://etcd:2379/v3/kv/range -d "{\"key\":\"Lw==\"}" 2>&1 | tail -1
$D env IMAGE_TAG=$IMAGE_TAG docker compose $F run --rm --no-deps --entrypoint sh etcd-init -c "curl -sS -o /dev/null -w \"HTTP=%{http_code}\n\" -X POST http://etcd:2379/v3/auth/authenticate -d \"{\\\"name\\\":\\\"root\\\",\\\"password\\\":\\\"\$ETCD_ROOT_PASSWORD\\\"}\"" 2>&1 | tail -1
$D env IMAGE_TAG=$IMAGE_TAG docker compose $F run --rm --no-deps --entrypoint curl etcd-init -sS -o /dev/null -w "HTTP=%{http_code}\n" -X POST http://etcd:2379/v3/auth/authenticate -d "{\"name\":\"root\",\"password\":\"definitely-wrong\"}" 2>&1 | tail -1
for i in 1 2 3; do $D docker logs srisurart-pos-api-$i-1 2>&1 | grep -iE "etcd|runtimeconfig|runtime config|log_level" | tail -4; done
$D docker ps -a --filter name=etcd-init --format "{{.Names}} {{.Status}}"
```
In the authenticate line, `$ETCD_ROOT_PASSWORD` is expanded inside the container, from its compose env.

**4. Snapshot, then the `log_level` toggle**
```
D="sudo -n -u deploy"; C=srisurart-pos-etcd-1; E="--endpoints=http://127.0.0.1:2379"; TS=$(date -u +%Y%m%dT%H%M%SZ)
$D docker exec $C etcdctl $E snapshot save /tmp/etcd-$TS.db 2>&1 | tail -1
$D docker cp $C:/tmp/etcd-$TS.db /opt/pos/backups/etcd-$TS.db && $D ls -la /opt/pos/backups/etcd-$TS.db
$D docker run --rm -v /opt/pos/backups:/b:ro --entrypoint etcdutl gcr.io/etcd-development/etcd:v3.6.12@sha256:3c2ced08f23b1183e8bd4613064c3fb6b8db5057a4d1f13c3518c76e357a07a8 snapshot status /b/etcd-$TS.db -w table 2>&1 | tail -4
S=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "since=$S"
$D docker exec $C etcdctl $E put /pos/config/log_level debug; sleep 4
$D docker exec $C etcdctl $E put /pos/config/log_level info; sleep 4
$D docker exec $C etcdctl $E get /pos/config/log_level --print-value-only
for i in 1 2 3; do $D docker logs --since $S srisurart-pos-api-$i-1 2>&1 | grep -E "Runtime config|etcd" | sed -E "s/\"time\":[0-9]+,//"; done
```
Inside the etcd container, `ETCDCTL_USER=root:<ETCD_ROOT_PASSWORD>` comes from compose.

**5. Grafana and Prometheus**
```
D="sudo -n -u deploy"
$D docker inspect --format "{{.Name}} {{.State.Health.Status}} started={{.State.StartedAt}}" srisurart-pos-grafana-1 srisurart-pos-prometheus-1
curl -sS -w " HTTP=%{http_code}\n" http://127.0.0.1:3000/api/health
curl -sS "http://127.0.0.1:9090/api/v1/query?query=up" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[\"status\"]); [print(r[\"metric\"].get(\"job\"), r[\"metric\"].get(\"instance\"), r[\"value\"][1]) for r in d[\"data\"][\"result\"]]"
U=$($D grep -m1 "^GRAFANA_ADMIN_USER=" .env | cut -d= -f2- | tr -d "\"\r"); [ -n "$U" ] || U=admin
P=$($D grep -m1 "^GRAFANA_ADMIN_PASSWORD=" .env | cut -d= -f2- | tr -d "\"\r"); echo "pw_len=${#P}"
cfg(){ printf "user = \"%s:%s\"\n" "$U" "$P"; }
cfg | curl -sS -K - "http://127.0.0.1:3000/api/dashboards/uid/srisurart-pos-overview" -o /tmp/dash.json -w "HTTP=%{http_code}\n"; python3 -c "import json; d=json.load(open(\"/tmp/dash.json\")); m=d.get(\"meta\",{}); print(d[\"dashboard\"][\"title\"], \"| panels:\", len(d[\"dashboard\"].get(\"panels\",[])), \"| provisioned:\", m.get(\"provisioned\"), \"| folder:\", m.get(\"folderTitle\"))"; rm -f /tmp/dash.json
cfg | curl -sS -K - http://127.0.0.1:3000/api/datasources | python3 -c "import json,sys; [print(x[\"name\"],x[\"type\"],x[\"url\"],\"readOnly=\",x.get(\"readOnly\")) for x in json.load(sys.stdin)]"
curl -sS -o /dev/null -w "HTTP=%{http_code}\n" http://127.0.0.1:3000/api/dashboards/uid/srisurart-pos-overview
```
`cfg` sends the Grafana credentials to curl over stdin.

**6. Readiness investigation (read-only)**
```
D="sudo -n -u deploy"
curl -sS "http://127.0.0.1:9090/api/v1/targets?state=active" | python3 -c "import json,sys; [print(t[\"labels\"][\"job\"], t[\"scrapeUrl\"], t[\"health\"], t.get(\"lastError\")) for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"] if t[\"labels\"][\"job\"]==\"api-readiness\"]"
for i in 1 2 3; do $D docker exec srisurart-pos-api-$i-1 wget -qSO- http://127.0.0.1:3000/health/ready 2>&1 | grep -E "HTTP/|status" | head -3; done
$D docker exec srisurart-pos-prometheus-1 cat /etc/prometheus/prometheus.yml 2>/dev/null | grep -n -A8 readiness
```

**Notes**
- The Grafana checks (5) ran after the etcd work (1–4); this is the true order.
- The Grafana dashboard file (`/tmp/dash.json`) was written and deleted on the VM host.
- Locally I also ran `git`/`gh` read commands and the two `gh issue comment` posts. None of those touched the VM.

## ต่อมา (บ่าย) 2026-09-30 — CI แดงบล็อก deploy, พิสูจน์ merge→CD และ rollback

ตรวจโดย orchestrator · ไม่มีค่า secret · #343 / #365 / #67 **ไม่ได้ถูกติ๊กในไฟล์นี้** — สถานะ AC ด้านล่างคือสถานะตอนเขียน

**Merge ตามลำดับ:** PR #510 (docs resync) `04c6ea3` → PR #511 (คำสั่งจริง sanitized ในไฟล์นี้) `68c23e3` → PR #512 `494ace3` → PR #513 (แก้ tutorial VM, `c8cce8d`) merge เป็น `5098001`

**สาเหตุที่ deploy ถูกข้ามทุกครั้ง:** Server CI บน `main` แดงที่ `pnpm audit --audit-level=high` — `brace-expansion`
(GHSA-qhr7-859c-m2p7 / GHSA-6j4f-fj2g-mc7p) ผ่าน `@nestjs/cli > minimatch` (dev-only) → ไม่มี image ขึ้น GHCR → ทุก Deploy run ข้าม
ทั้งที่รายงานสำเร็จ · PR #512 แก้ด้วย pnpm override `brace-expansion@>=4.0.0 <5.0.11 → ^5.0.11` และยก override ของ `multer` เป็น `>=2.4.0`
(GHSA-3pph-fpjx-jg34) · เหลือ moderate 1 ตัว: `fast-uri` (dev-only ผ่าน `@nestjs/cli`)
บทเรียน: Deploy run สีเขียว ~8 วินาทีหลัง merge อาจแปลว่า "image ยังไม่พร้อม (CI แดง)" ไม่ใช่แค่ "docs-only"

**merge → CD พิสูจน์ด้วยโค้ดใหม่:** Deploy run `36685602814` (`494ace3`, อนุมัติแล้ว) สำเร็จ, api×3/worker รัน `494ace3` · run ของ `68c23e3`
ปฏิเสธถูกต้องว่า "main has moved on to `494ace3`"

**Rollback / roll-forward (schema ไม่เปลี่ยนตลอด 5 deploy — ตาราง `migrations` 20 แถว, max `1788652804600`):**
- Manual Ansible ด้วยผู้ใช้ `deploy` ย้อนไป `e50f4fa` — `failed=0` (AC ของ #343):
  `ansible-playbook deploy.yml -e image_tag=<sha> -e force_redeploy=true </dev/null`
- ระหว่าง roll-forward มือ **VPN หลุด** → VM ค้างครึ่งทาง: api `494ace3`, worker/bull-board/web `e50f4fa` · กู้ด้วย dispatch run `36686729879`
- Dispatch rollback ไป `e50f4fa` run `36687687309` (AC ของ #67)
- รันซ้ำ SHA เดิม run `36688248109`: "Skipping duplicate deployment", `changed=0`, container ID เดิมทุกตัว (AC ของ #67)
- สุดท้าย: `mob04` บน `494ace3`, `/health/ready` 200, ทุก container healthy

**#365:** etcd auth เปิดอยู่ตั้งแต่ deploy แรกของ runner · พิสูจน์ทั้งสองทาง (ใช้รหัสได้ / ไม่ใช้ถูกปฏิเสธ) · รหัสใน `.env` ตรงกับ volume ·
`RuntimeConfigService` อ่านการเปลี่ยน `log_level` ได้ · snapshot `/opt/pos/backups/etcd-20260930T071608Z.db` · AC1–3 ติ๊กแล้ว

**#343:** ตรวจ Grafana เองแล้ว (AC ติ๊ก) · Prometheus target `api-readiness` ขึ้น down เพราะ `/health/ready` ตอบ JSON ไม่ใช่ metrics
(ช่องว่างที่บันทึกไว้แล้ว `docs/study/17_lab.md:730`)

**สถานะ AC ตอนเขียน:** #343 4/5 (เหลือ log คำสั่งจริง — ส่วนคำสั่ง rollback/roll-forward ของบ่ายนี้อยู่ในหัวข้อนี้ด้านบนแล้ว) ·
#365 3/4 (เหลือ log คำสั่ง — ครอบคลุมโดย PR #511 ที่ merge แล้ว) ·
#67 9/15 — ยังเปิด: one-image-only แล้ว deploy (ประวัติของ `494ace3` อาจพิสูจน์ได้ ยังไม่ตรวจ), ไม่มี deploy พร้อมกัน, readiness ล้ม → แดง,
auto-rollback เมื่อล้ม, hook ปฏิเสธ branch อื่น/fork, seed `log_level` · owner อนุมัติให้รันการทดสอบล้มเหลวโดยตั้งใจเหล่านี้**หลัง demo #344**
⚠️ แก้ 2026-09-30 เย็น: owner อนุญาตให้รันก่อน #344 และรันแล้ว — #67 ปิด 15/15 (ครึ่ง fork พิสูจน์จากโค้ด + settings เท่านั้น) ดู `session-2026-09-30-evening-clear-backlog.md`

**#344:** เขียน checklist แล้ว `docs/handoff_log/demo-344-checklist-2026-09-30.md` — **ยังไม่รัน** · ตัวขวาง: AC2 (รหัสชั่วคราว + บังคับเปลี่ยนใน 10 นาที,
ข้อความไทยยังไม่รับรอง `change_password_form.dart:13`), AC3 (tenant ใหม่ไม่มีสินค้า), AC4 (แอปส่ง idempotency key ซ้ำไม่ได้ → DevTools/curl ภายใน token 15 นาที),
AC6 (3 AC ของ #335 พิสูจน์บน VM ตรง ๆ ไม่ได้ — owner ตัดสิน), #476 (ล้างข้อมูลเบราว์เซอร์ = ทางตัน) · helper `psql_vm`/`prom_vm` ตรวจแล้วใช้ได้บน VM (ยังไม่มี tenant)

**tutorial audit** พบผิดจริง (fallback เงียบไป `id_rsa.pub`, path secrets, alias `mob04-deploy` ขาด, `docker compose exec etcd` ต้องมี `IMAGE_TAG`, ไม่มีเส้นทาง dispatch rollback/กู้ครึ่งทาง, สถานะเก่า) → แก้ใน PR #513

**เครื่องมือบน Mac ของ owner:** `~/.local/bin/mob04-tunnel` (ssh -N forward 3000/3100/3200/9090 ไป loopback ของ `mob04` ผ่าน `cloud@172.30.58.20`) · ไฟล์ secrets ยังอยู่ที่ `~/Downloads/mob04-demo.env`

**ยังเปิด:** ~~CORS `Origin` แปลกหน้า → HTTP 500~~ (แก้ PR #516, ไม่เคยปนใน SLI) · `PLATFORM_ADMINS` ตั้งแล้ว (lomer/nuiman/pattarapon) แต่ยังไม่มีใครล็อกอิน platform-ui ·
backup ออกนอก VM พักไว้ (#363/#288) · #380 k6 ยังไม่วัด
