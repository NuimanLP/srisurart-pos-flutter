Srisurart POS - PC ops folder (โฟลเดอร์งานดูแล mob04 บน PC เครื่องนี้)
Written by deploy/scripts/install-pc-*.ps1 - do not edit here, edit the repo copy (deploy/scripts/pc-ops-README.txt).

โฟลเดอร์นี้อยู่ใต้ D:\Beestation จึงถูกซิงก์ขึ้น BeeStation ของร้านทั้งหมด รวม secrets\ (เจ้าของยอมรับ 2026-10-18)
This folder is under D:\Beestation, so all of it - secrets\ included (owner accepted 2026-10-18) - syncs to the shop NAS.

bin\       สำเนาสคริปต์ที่ Scheduled Task รัน + pos-ca.crt (แก้ใน repo แล้วรัน installer ซ้ำ ห้ามแก้ที่นี่)
           Script copies the Scheduled Tasks run + pos-ca.crt. Change the repo, then re-run the installer.
config\    ค่าตั้งที่ไม่ใช่ความลับ (ยังไม่มี) / non-secret settings (none yet)
secrets\   webhook.txt (Discord), *.env สำเนา .env ของ VM, mob04-certs-ca-*.tar.gz (CA + ca.key ของ TLS) - ห้ามวางใน chat/ticket/commit
           Discord webhook and VM .env copies. Never paste them anywhere. Owner-only ACL.
logs\      watchdog.log, pull.log, ssh.err
state\     watchdog.json, pull.json (นับความล้ม/การแจ้งเตือน / failure counters)
backups\mob04\YYYY-MM\
           backup ที่ดึงจาก mob04 แยกตามเดือนของเวลาในชื่อไฟล์ (UTC) · เก็บ 30 วัน · ข้อมูลลูกค้า (PDPA)
           Backups pulled from mob04, grouped by the month in the file name (UTC). Kept 30 days. Customer data.
           ชุดหนึ่ง = pos_backup_<ts>.sql.gz, pos_images_<ts>.tar.gz, pos_sale_photos_<ts>.tar.gz (+ .sha256 แต่ละไฟล์)

Scheduled Task ทั้งสองรันเฉพาะตอนที่เจ้าของ login อยู่ (logout แล้วไม่มีการเฝ้า/ดึง backup)
Both Scheduled Tasks run only while the owner is logged on (logged off = no watchdog, no backup pull).
สคริปต์ใช้ root จาก env SRISURART_OPS_ROOT (installer ตั้งให้) / Scripts take the root from the SRISURART_OPS_ROOT user
env var (set by the installers), else D:\Beestation\Sri_POS\ops.

กู้คืนชุดหนึ่ง / Restore one set:
  !! ทุกอย่างที่ขาย/บันทึกหลังเวลา <ts> ของชุดนี้จะหายหมด (ทุกร้าน ทุกเครื่อง)
  !! Every write after this set's <ts> is LOST (all tenants, all devices). Owner decision only.
  1. คัดลอกไฟล์ของ <ts> เดียวกัน (+ .sha256) ไป /opt/pos/backups บน VM
     Copy the files of one <ts> (+ their .sha256) to /opt/pos/backups on the VM, e.g.
     scp -i %USERPROFILE%\.ssh\mob04-SriStore pos_backup_<ts>.sql.gz* deploy@172.30.58.20:/opt/pos/backups/
  2. บน VM / on the VM:  cd /opt/pos/backups && sha256sum -c pos_backup_<ts>.sql.gz.sha256
  3. หยุดตัวที่เขียนข้อมูลก่อน / stop every writer first (on the VM):
     cd /opt/pos && IMAGE_TAG=$(cat .current_sha) docker compose -f docker-compose.yml -f vm.override.yml stop api-1 api-2 api-3 worker bull-board
  4. /opt/pos/scripts/restore-db.sh /opt/pos/backups/pos_backup_<ts>.sql.gz
     (restore-db.sh ไม่กู้ไฟล์รูป - รูปอยู่ใน pos_images_/pos_sale_photos_ tar.gz / it does not restore images)
  5. ตรวจข้อมูลที่กู้แล้วก่อน แล้วค่อยเปิดกลับ / verify the restored data, then start them again:
     cd /opt/pos && IMAGE_TAG=$(cat .current_sha) docker compose -f docker-compose.yml -f vm.override.yml start api-1 api-2 api-3 worker bull-board
  รายละเอียด / details: docs/Backend_design/07_CICD_DEPLOY.md section 7a.1 (and section 7 runbook)
