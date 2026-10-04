# Handoff — uptime: ถอด Uptime Kuma, ใช้ Healthchecks.io heartbeat จาก `mob04` (2026-10-04)

> **อัปเดต 2026-10-04 ค่ำ:** PR #596 merged (`e0b880a`) พร้อมการแก้ของ NuimanLP (URL ไม่อยู่ใน argv); ยังไม่ติดตั้งบน `mob04` — สถานะล่าสุดอยู่ที่ [`session-2026-10-04-evening-merge-596-597-599.md`](session-2026-10-04-evening-merge-596-597-599.md)

**วันที่:** 2026-10-04 · **ผู้บันทึก:** PattaraponKitcharoen (+ Claude) · **สถานะ:** รอคนอื่น (PR เข้า main + owner อนุมัติติดตั้งบน VM)
**ขอบเขต:** สคริปต์ heartbeat + cron ใน `provision.yml` + CI test · ถอด Uptime Kuma ออกจาก overlay local
**ต่อจาก:** [`session-2026-10-04-develop-branch-status.md`](session-2026-10-04-develop-branch-status.md)

## 1. ตอนนี้อยู่ตรงไหน
- โค้ดอยู่บน `develop` (`9e48d75`, `595aa13`) · **ยังไม่ได้ติดตั้งอะไรบน `mob04`**
- check ใน Healthchecks.io: ทีมสร้างแล้ว ได้ ping แรกจาก `mob04` (`curl -fsS https://hc-ping.com/<uuid>` → `OK`, 2026-10-04) แล้ว **กด Pause ไว้** — ping ถัดไปจะ resume เอง (ถ้าไม่ได้เปิดตัวเลือก manual resume — ยังไม่ได้ตรวจ)
- `HEALTHCHECKS_PING_URL` **ยังไม่อยู่ใน** `mob04-demo.env` และ `/opt/pos/.env`

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร
- `deploy/scripts/healthcheck-ping.sh`: `curl -k` `https://127.0.0.1/health/ready` ผ่าน Nginx (retry 3 × 15 s, `--retry-connrefused`) → ผ่าน = `GET <URL>` · ไม่ผ่าน = `POST <URL>/fail` + ข้อความ error เป็น body · URL อ่านจาก `/opt/pos/.env` ด้วย `grep` (ไม่ `source` — มี PEM หลายบรรทัด) · ไม่พิมพ์ URL
- 3 สถานะ (กฎเดียวกับ offsite ของ `backup-db.sh`): ไม่ตั้ง URL → `::warning::` exit 0 · ส่งถึง → ping ตามผล · ส่งไม่ถึง → `::error::` exit 1
- `provision.yml`: เพิ่มสคริปต์ใน loop install, debug warn เมื่อ `DEMO_ENV_FILE` ไม่มี key, cron `*/5` ของ user `deploy` ส่ง output เข้า syslog (`logger -t pos-healthcheck`)
- CI: `server.yml` path filter + step ใน job `nginx-check` · `validate.sh` เพิ่มใน REQUIRED_FILES · docs `07_CICD_DEPLOY.md §7b` · `server/.env.example` บรรทัดคอมเมนต์
- ถอด Uptime Kuma: service + volume ออกจาก `observability.yml`, ลบ `deploy/uptime-kuma/`, ลบ container local (volume ยังอยู่)

**ตรวจสอบด้วยอะไร:**
- `deploy/scripts/test/healthcheck-ping.test.sh` 16/16 (stub `curl`) · shellcheck clean · `validate.sh` ผ่าน (Ansible syntax ใน container)
- 2026-10-04 ยิงจริงกับ Nginx local + stub server แทน Healthchecks: ปกติ → `GET /<uuid>` rc=0 เงียบ · path 404 → `POST /<uuid>/fail` body `health/ready failed: curl: (56) … 404` rc=0 · ปลายทางปิด → `::error::` rc=1 ไม่มี URL ใน output
- จาก `mob04` (ทีมรัน 2026-10-04): `curl -v https://hc-ping.com/` → TLS verify ผ่าน issuer **Sectigo** (ไม่ใช่ FortiGate ดักกลาง), จาก `172.30.58.20`, HTTP 301 → healthchecks.io · IPv6 "Network is unreachable" แล้ว fallback IPv4 ทันที

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร
- **Healthchecks.io แทน Uptime Kuma** (ผู้ใช้ 2026-10-04): Kuma บน `mob04` ตายพร้อม VM จึงแจ้ง VM ดับไม่ได้ + กิน container ~100–150 MB · heartbeat ฝั่ง VM แทบไม่กินทรัพยากร และ "เงียบ = แจ้ง" ครอบ VM ดับ/เน็ตขาด/cron ตาย
- เช็กผ่าน Nginx (`127.0.0.1:443`) ไม่ใช่ api ตรง — รอบเดียวได้ Nginx + api + Postgres + redis-cache
- retry ก่อน `/fail` (`595aa13`) — `/fail` แจ้งทันทีไม่มี grace; deploy ที่ restart api ต้องไม่ปลุกคน
- log เข้า syslog ไม่ใช่ไฟล์ — 288 รอบ/วันต้องหมุนไฟล์ journald หมุนให้แล้ว
- URL เป็นความลับ (ใครมีก็ ping แทนได้ → กลบตอนพังจริง) → อยู่ใน `.env` เท่านั้น

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)
- `"${body[@]}"` ว่างใต้ `set -u` บน bash 3.2 (macOS) → unbound variable → ใช้ `${body[@]+"${body[@]}"}`
- stub ในเทสต์ match `*health/ready*` ชน body ของ `/fail` ที่มีคำเดียวกัน → match `127.0.0.1/health/ready`

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์
- `provision.yml` ส่วนนี้ **ยังไม่เคยรันจริง** (syntax check เท่านั้น)
- ยังไม่เคยมี ping จากสคริปต์ไป Healthchecks.io จริง / ยังไม่เคยเห็นแจ้งเตือน `/fail` จริง
- กรณี api ตอบ 503 แล้ว retry ก่อนแจ้ง — ไม่ได้ทดสอบ (ต้องปิด api ทั้ง 3) · อาศัยพฤติกรรม `curl --retry` ที่ retry 503
- แผนฟรีของ Healthchecks.io (~20 checks) — จำจากความรู้ทั่วไป ยังไม่ได้เช็กหน้าราคา

## 6. ก้าวถัดไป (เรียงลำดับ)
1. PR จาก `main` เฉพาะ 7 ไฟล์ (สคริปต์, เทสต์, `provision.yml`, `server.yml`, `validate.sh`, `07 §7b`, `.env.example`) → CI → ทีม merge
2. ทีม: ตั้ง Period 5 นาที, Grace 5–10 นาที, ช่องทางแจ้งเตือนที่ทั้งทีมเห็น · **อย่ากด Ping now ก่อนติดตั้ง cron**
3. ทีม: เพิ่ม `HEALTHCHECKS_PING_URL=` ใน `mob04-demo.env`
4. **owner อนุมัติ** แล้วติดตั้ง — ทาง A `provision.yml` (user `cloud`, `DEMO_ENV_FILE` ต้องครบทุก key เพราะเขียน `.env` ทับ) หรือทาง B มือ: `sudo install -o deploy -g deploy -m 0755` สคริปต์จาก `origin/main`, `sudoedit /opt/pos/.env`, `sudo crontab -u deploy -e` ใส่ `#Ansible: Srisurart POS Uptime Heartbeat` นำหน้าบรรทัด cron
5. ตรวจบน VM: `sudo -u deploy /opt/pos/scripts/healthcheck-ping.sh; echo rc=$?` → 0 · check เขียว · ทดสอบ `/fail` ด้วย `HEALTHCHECK_READY_URL=https://127.0.0.1/health/nope` → แดง + แจ้งเตือน → รอบ cron ถัดไปเขียวเอง · `journalctl -t pos-healthcheck`

## 7. ข้อควรระวัง
- 🔴 ห้าม commit/วาง ping URL จริงที่ไหน (repo, PR, chat) · ส่ง output ให้คนอื่นดูให้ตัด uuid ออก
- 🔴 CD deploy **ไม่ติดตั้ง** สคริปต์นี้ (เหมือน `backup-db.sh`) — แก้สคริปต์ใน repo ต้องรัน `provision.yml` ใหม่
- ถ้าเพิ่ม URL ใน `/opt/pos/.env` ด้วยมือแต่ไม่ใส่ใน `mob04-demo.env` → `provision.yml` ครั้งหน้าจะลบทิ้ง
- ตอนแก้ `.env` ด้วยมือ: เติมบรรทัดว่างก่อน, เช็กด้วย `grep -c '^HEALTHCHECKS_PING_URL='` (CLAUDE.md)
- FortiGate เคยบล็อก `ghcr.io` จนถึง 2026-09-29 — ถ้าวันหนึ่ง log มี `::error::… SSL` ให้สงสัยตรงนี้ก่อน

## 8. อ้างอิง
- `deploy/scripts/healthcheck-ping.sh` · `deploy/scripts/test/healthcheck-ping.test.sh` · `deploy/ansible/provision.yml` (2 task ท้ายไฟล์ + warn) · `docs/Backend_design/07_CICD_DEPLOY.md §7b`
