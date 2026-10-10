# แผนย้าย production จาก VM `mob04` ไป Raspberry Pi 5

> **สถานะ: แผนศึกษา/วางแผนเท่านั้น (2026-10-10) — ยังไม่ได้ซื้ออะไร ไม่ได้แก้โค้ด ไม่ได้แตะ infra**
> **เจ้าของโปรเจกต์ยังไม่ตัดสินใจ** ("ค่อยคิดดูอีกที") — เอกสารนี้ไว้ให้คิด ไม่ใช่คำสั่งให้เริ่มงาน
> ข้อเท็จจริงที่มาจาก repo อ้าง path/section ที่ grep แล้ว · ข้อเท็จจริงจากเว็บมี URL กำกับ ·
> สิ่งที่ยืนยันไม่ได้ติดป้าย **[ไม่ยืนยัน]** · ราคาทุกตัวเป็น **ประมาณการ ต้อง re-quote ก่อนซื้อ**
> (ราคา Pi ผันผวนหนักช่วงนี้ เพราะวิกฤต DRAM — ดูหมวด 2)
>
> บริบทที่เกี่ยวข้อง: deploy ขึ้น `mob04` เพิ่งล้มเพราะ prebuilt binary ของ `sharp` (x64) ต้องการ CPU ระดับ
> x86-64-v2 (SSE4.2) แต่ CPU ของ VM (QEMU) ไม่มี SSE4/POPCNT — **การแก้ (build `sharp` กับ libvips ของ Alpine)
> กำลังทำแยกต่างหาก ไม่ใช่งานในเอกสารนี้** เอกสารนี้แค่ชี้ว่าการแก้นั้นต้องทดสอบบน arm64 ด้วย (หมวด 4.1) ·
> ที่มาของปัญหาฝั่ง x64: [sharp install docs](https://sharp.pixelplumbing.com/install/) ระบุ Linux x64 ต้อง "CPU with SSE4.2"
> (ฝั่ง ARM64 หน้านั้นไม่ได้ระบุ baseline ของ CPU)
>
> อ่านคู่กับ: `CLAUDE.md` (branch strategy, CI/CD rules), `docs/Backend_design/07_CICD_DEPLOY.md` (§5 เครื่อง/TLS,
> §6 deploy, §7a backup, §7b heartbeat), `docs/Backend_design/adr/0013-cicd-toolchain.md`,
> `docs/research/production-host.md` (ตัวเลือก host เดิม — เจ้าของปฏิเสธทุกตัว 2026-09-15; เอกสารนี้ไม่ใช่การกลับคำตัดสินนั้น
> เพราะ Pi ไม่ใช่ cloud host แต่ต้องให้เจ้าของยืนยันว่า "mob04 เป็น production ตัวเดียว" ยังเป็นจริงหลังย้าย — คำถามข้อ 1)

---

## 1. สรุป + คำแนะนำ

**ข้อเท็จจริงจาก repo ที่กำหนดทุกอย่างในแผนนี้**

| เรื่อง | ค่าปัจจุบัน | ที่มา |
|---|---|---|
| host | VM QEMU x86-64, `172.30.58.20`, 4 vCPU / 6 GB / 48 GB, อยู่ในเครือข่ายคณะ (ต่อจากนอกไม่ได้) | `07_CICD_DEPLOY.md` §5 |
| "เป็นที่ของร้านไหม" | §5 เขียนว่า "ใช้สาธิต/ส่งงานเท่านั้น ไม่ใช่ที่ของร้าน" แต่ #242 (2026-09-15) เคาะว่า `mob04` **คือ** production ตัวเดียว — สองข้อความนี้ยังไม่ถูกทำให้ตรงกัน | `07_CICD_DEPLOY.md` §5 |
| RAM จริงเมื่อโหลด | ทั้งเครื่องสูงสุด **1,561 / 5,920 MiB**, container รวมสูงสุด **648 MiB** (เพดาน `mem_limit` รวม 4,256), CPU VM สูงสุด 25% | `docs/handoff_log/session-2026-10-05-k6-capacity-run.md` (วัดด้วย k6 + sampler ที่มีบั๊กแต่ host memory ถูก; ยัง **ไม่ใช่** ตัวเลขที่เจ้าของรับรอง — #380) |
| งบ `mem_limit` | stack หลัก ≈3.4 GB + monitoring ≈0.83 GB ≈ **4.2 GB** | `07_CICD_DEPLOY.md` §5 |
| image | ทุกตัว pin `name:tag@sha256:<digest>` (#401); server/web ของเราบน GHCR `ghcr.io/nuimanlp/srisurart-pos-{server,web}:<sha>` | `server/docker-compose.yml`, `deploy/compose/vm.override.yml` |
| build image | `ubuntu-latest` (x86) ตัวเดียว, `docker build` ธรรมดา **ไม่ใช่ multi-arch** | `.github/workflows/server.yml` job `build-image`, `.github/workflows/flutter.yml` job `build-web` |
| TLS | private CA ใน volume `certs-ca`, SAN ฮาร์ดโค้ด `DNS:localhost,IP:127.0.0.1,IP:172.30.58.20`, APK ฝัง CA และชี้ `API_BASE_URL: https://172.30.58.20` | `server/docker/certgen/certgen.sh`, `.github/workflows/android-apk.yml`, `07_CICD_DEPLOY.md` §5 "TLS" |

**คำแนะนำ**

1. **Pi 5 (8 GB) รัน stack นี้ได้ในเชิงทรัพยากร** — โหลดจริงวัดได้ ~1.6 GB ทั้งเครื่อง; Pi 5 เป็น Cortex-A76 สี่คอร์ 2.4 GHz
   ([raspberrypi.com/products/raspberry-pi-5](https://www.raspberrypi.com/products/raspberry-pi-5/)) แรงกว่า VM ที่ถูก emulate อยู่
   ข้อกังวลจริงไม่ใช่ความแรง แต่คือ **(ก) multi-arch image ที่ CI ยังไม่ทำ (ข) ไฟดับ/การ์ดพัง (ค) การเข้าถึงจากภายนอก (ง) ผลกระทบต่อ APK/เบราว์เซอร์ที่ใช้อยู่แล้ว**
2. **ควรย้ายเมื่อไร** — *หลัง* ส่งงาน/เดโมคอร์สเสร็จ และเมื่อร้านจะใช้จริงในเครือข่ายร้าน (ซึ่ง mob04 ให้ไม่ได้ เพราะอยู่ในเครือข่ายคณะ)
   ตอนนี้อยู่ใน **development freeze** (`CLAUDE.md` หมวด Branch strategy: freeze 2026-10-07, ปลดเฉพาะคำขอที่เจ้าของสั่ง) การย้ายเป็นงาน CI/infra
   ขนาดกลาง ไม่ใช่ bug fix → **อย่าเริ่มก่อนส่งงาน** และอย่าเริ่มระหว่างรอบ demo #344 ที่ยังต้องเริ่มใหม่จาก AC1
3. **ไม่ควรย้าย ถ้า** (ก) ร้านยังไม่ได้ใช้จริงและ mob04 พอสำหรับการสาธิต (ข) ไม่มีใครดูแล Pi ที่ร้าน (ไฟ/เน็ต/ฮาร์ดแวร์) (ค) เจ้าของยังไม่เลือกเส้น
   remote access/offsite backup (#363 ยัง parked) — ย้ายไปแล้ว **ความเสี่ยงข้อมูลสูญหายเพิ่มขึ้น** ไม่ลดลง ถ้าไม่มีสำเนานอกเครื่อง (Pi + SSD ใบเดียวในร้านเดียว)
4. **ลำดับที่แนะนำ ถ้าตัดสินใจทำ:** ซื้ออุปกรณ์ → ทำ multi-arch CI + ทดสอบ `sharp` บน Pi จริง (งานนี้ทำก่อนได้โดยไม่แตะ mob04) →
   provision Pi เป็น host ที่สอง **ขนาน** กับ mob04 → ซ้อมย้ายข้อมูลด้วยสำเนา dump → ค่อย cutover ในช่วงเวลาที่ร้านปิด → เก็บ mob04 ไว้เป็น rollback อย่างน้อย 1–2 สัปดาห์

---

## 2. ฮาร์ดแวร์ที่ต้องซื้อ

> **ราคาเป็นประมาณการ** — แปลง ~35 THB/USD · ไม่มีราคาไทยที่ยืนยันสำหรับของเกือบทุกอย่าง · **วิกฤต DRAM ทำราคา Pi ขึ้นหลายรอบ** ดูต้นทาง:
> [CNX Software 2025-12-01](https://www.cnx-software.com/2025-12-01/raspberry-pi-5-1gb-launched-for-45-most-other-pi-4-5-models-get-a-price-increase)
> (4 GB $70 / 8 GB $95 / 16 GB $145) → ขึ้นอีกรอบ ม.ค.–ก.พ. 2026 ตาม
> [Notebookcheck](https://www.notebookcheck.net/Raspberry-Pi-5-now-costs-up-to-205-due-to-RAM-crisis.1218213.0.html)
> (4 GB $85 / 8 GB $125 / 16 GB $205 ณ 2026-02-02) — หน้าสินค้าทางการตอนค้นหา (2026-10-10) แสดง 16 GB ที่ **$305**
> ([raspberrypi.com](https://www.raspberrypi.com/products/raspberry-pi-5/)) แปลว่าราคายังขยับขึ้นต่อ — **ราคาข้างล่างอาจล้าสมัยภายในไม่กี่สัปดาห์**

| # | รายการ | สเปก | ราคาประมาณ (THB) | หลักฐาน/แหล่ง | ทำไมต้องมี |
|---|---|---|---|---|---|
| 1 | Raspberry Pi 5 | **8 GB** (ขั้นต่ำที่แนะนำ) | **฿5,000–9,000** | RS Thailand แสดง ฿4,663 รวม VAT สำหรับ 8 GB แต่หน้าอ้างวันส่งเดือน ก.ย. 2025 (น่าจะเก่า): [th.rs-online.com](https://th.rs-online.com/web/p/raspberry-pi/0219255?gb=s) · Newegg Thailand ฿7,745: [newegg.com/global/th-en](https://www.newegg.com/global/th-en/SULE-Mini-PC-Barebone/BrandSubCat/ID-206580-309) (ผลค้นหา ไม่ได้เปิดยืนยัน) · MSRP สหรัฐฯ $125 ก.พ. 2026 | stack วัดจริง ~1.6 GB แต่ `mem_limit` รวม ≈4.2 GB (หมวด 4.8) + page cache ของ Postgres + ที่ว่างให้ Docker/OS → 4 GB ตึงเกินไปเมื่อเปิด monitoring; 16 GB แพงเกินจำเป็น |
| 2 | ที่จ่ายไฟทางการ 27 W USB-C PD | 5 V / 5 A | ฿400–600 | หน้าสินค้าแนะนำ "27W USB-C Power Supply" และเตือนว่าไฟไม่พอทำให้เครื่องมีปัญหา [raspberrypi.com](https://www.raspberrypi.com/products/raspberry-pi-5/) · ร้านค้าปลีกในผลค้นหา ~$12 / £11.50 (ไม่ได้เปิดยืนยัน) | Pi 5 + NVMe กินไฟสูงกว่า Pi 4 ที่ไฟ 3 A จะจำกัดกระแส USB/NVMe ([unverified] รายละเอียดการจำกัด) — อย่าใช้ที่ชาร์จโทรศัพท์ |
| 3 | Active Cooler ทางการ | พัดลม+heatsink, ต่อ JST-SH 4 pin PWM | ฿200–300 | [raspberrypi.com](https://www.raspberrypi.com/products/raspberry-pi-5/) (คำอธิบาย) · ราคา ~$5–6 จากผลค้นหาร้านค้าปลีก | รันตลอด 24/7 + CPU spike ตอน migrate/build; throttle = latency พุ่ง (Postgres+Node) |
| 4 | M.2 HAT+ (หรือ HAT/ฐาน NVMe ที่ HAT+-compliant) | PCIe 2.0 x1 ผ่าน FFC, รองรับ NVMe M-key | ฿800–1,100 | [คู่มือทางการ M.2 HAT+](https://www.raspberrypi.com/documentation/accessories/m2-hat-plus.html) · ราคา ~$21–28 จากผลค้นหา ([Little Bird](https://littlebirdelectronics.com.au/products/raspberry-pi-m-2-hat-plus.md), [PB Tech](https://www.pbtech.co.nz/product/SEVRBP0533)) | **Postgres บน microSD ไม่ควร** — SD สึก/พังจาก write ต่อเนื่อง (WAL) และ I/O ช้า; ตัวอย่าง NVMe boot: [Jeff Geerling](https://www.jeffgeerling.com/blog/2023/nvme-ssd-boot-raspberry-pi-5) |
| 5 | NVMe SSD | **256 GB** ขึ้นไป (ขนาด 2230/2242 ตาม HAT — **[ไม่ยืนยัน]** ว่า HAT+ รับขนาดไหนบ้าง ตรวจหน้าสินค้า), ควรมี PLP/endurance ดี | ฿1,500–3,500 | Raspberry Pi SSD 256 GB เปิดตัว $30 แต่ปัจจุบันขาย $46–95 หรือหมด: [SparkFun](https://www.sparkfun.com/raspberry-pi-ssd-256gb.html), [Adafruit](https://www.adafruit.com/product/6090), [Pi Hut](https://thepihut.com/collections/raspberry-pi-sd-cards-and-adapters/products/raspberry-pi-ssd) (SSD ใดก็ได้ที่ Pi 5 บูตได้) | ฐานข้อมูล+รูปสินค้า+backup local 7 วัน (`BACKUP_KEEP_DAYS` default 7, `deploy/scripts/backup-db.sh`) — ใช้จริง <50 GB; 256 GB เหลือเฟือ |
| 6 | แบตเตอรี่ RTC | cell ลิเธียมชนิดที่บอร์ดรองรับ ต่อขั้ว `BAT` | ฿150–300 | บอร์ดมี "real-time clock … powered from external battery" [raspberrypi.com](https://www.raspberrypi.com/products/raspberry-pi-5/) · [The Pi Hut RTC battery](https://thepihut.com/collections/raspberry-pi-power-supplies/products/rtc-battery-for-raspberry-pi-5) | ไฟดับ + เน็ตยังไม่กลับ = นาฬิกาเพี้ยน → cert/JWT/`date` ของใบเสร็จผิด (เลขเอกสารอิงงวดเดือน — `CLAUDE.md` บทเรียน `currentPeriod()`) |
| 7 | **UPS** (สำคัญที่สุดสำหรับ SD/NVMe + Postgres) | ทางเลือก A: UPS ขนาดเล็กแบบ line-interactive 600–1000 VA จ่ายไฟทั้ง Pi + router/switch · ทางเลือก B: UPS HAT บน Pi | A: ฿1,500–3,500 · B: ฿2,500–5,000 (รวมถ่าน) | B ตัวอย่าง: [Waveshare UPS HAT (E)](https://www.waveshare.com/wiki/UPS_HAT_(E)) — รับถ่าน 21700 ×4 (ขายแยก), เอาต์พุต 5 V สูงสุด 6 A, มีสคริปต์ safe-shutdown และ Pi 5 ต้องตั้ง `PSU_MAX_CURRENT=5000` ใน EEPROM จึงได้ 5 A ([CNX](https://www.cnx-software.com/2024/08/03/waveshare-ups-hat-e-for-raspberry-pi-5-4-3b-takes-four-21700-lithium-batteries-supports-usb-pd-3-0/)) · **[ไม่ยืนยัน]** ว่า UPS HAT ซ้อนกับ M.2 HAT+ ได้ทางกายภาพ/GPIO — แนะนำทางเลือก A เพราะไม่ต้องซ้อน HAT และคุม router ด้วย | ไฟดับไม่ปิดเครื่องดี = Postgres crash-recovery ปกติรอดได้ แต่ SSD/ไฟล์ระบบเสี่ยง; และร้านไทยไฟตกบ่อย ต้องมี shutdown อัตโนมัติ (NUT ผ่านสาย USB กับ UPS ทางเลือก A — **[ไม่ยืนยัน]** รุ่นที่รองรับ) |
| 8 | เคสที่ระบายอากาศ + รองรับ HAT | เข้ากับ Active Cooler + M.2 HAT+ | ฿400–900 | — | ไม่ติดตั้งแบบเปลือย; เคสต้องมีช่องพัดลมและรองรับความสูง HAT |
| 9 | microSD + สาย LAN | microSD 32 GB (แค่ flash ตอนติดตั้ง/fallback), สาย Cat6 | ฿200–400 | — | Pi 5 ไม่บูต NVMe โดยค่าเริ่มต้น ต้องแก้ `BOOT_ORDER` ใน EEPROM (หมวด 4.3); ใช้ Ethernet ไม่ใช่ Wi-Fi |

**รวมประมาณ ฿10,000–20,000** (ขึ้นกับราคา Pi 8 GB และ SSD ณ วันซื้อ — ช่วงกว้างเพราะราคาผันผวน) · ควร **ซื้อชุดเดียวที่ร้านไทยมีในสต็อก** แล้ว re-quote ก่อนสั่ง ·
อย่าลืม: ต้องมี Pi เครื่องที่สอง/ชิ้นส่วนสำรองหรือไม่? (คำถามเจ้าของข้อ 8) — Pi ตัวเดียวพัง = ร้านหยุด ไม่มี hot spare

**บอร์ดที่ต้องมีเวอร์ชัน EEPROM ใหม่พอ:** Canonical ระบุ Pi 5 + Ubuntu 24.04 ต้อง boot EEPROM ≥ 2025-02-11
([Ubuntu on Raspberry Pi docs](https://ubuntu.com/hardware/docs/boards/how-to/ubuntu_supported/raspberry-pi/)) — ตรวจด้วย `rpi-eeprom-update`

---

## 3. Pi ตั้งอยู่ที่ไหน

| | A. ร้าน (LAN ของร้าน) | B. คณะ (ข้าง mob04) |
|---|---|---|
| latency ถึงลูกค้า/แคชเชียร์ | ต่ำสุด (LAN เดียวกัน) | ขึ้นกับว่าร้านต่อเข้าเครือข่ายคณะได้หรือไม่ — **ปัจจุบันต่อไม่ได้** (`07 §5`) |
| FortiGate | ไม่เกี่ยว — แต่ต้องพิสูจน์ว่าเน็ตร้านดึง `ghcr.io`, `registry-1.docker.io`, `gcr.io`, `hc-ping.com` ได้ (รายการนี้มาจากปัญหา x509 เดิม: `CLAUDE.md` → "Still open" #67 และ `07_CICD_DEPLOY.md` §7) | ปัญหา SSL deep inspection เดิมกลับมาได้ (ผ่านมาแล้ว 2026-09-29 แต่เปราะ) |
| เครือข่ายออกเน็ต | ISP ร้าน: ไม่ติด NAT คณะ แต่ IP เปลี่ยน/CGNAT ได้ → ใช้ไม่ได้กับ inbound | เหมือนเดิม |
| ผู้ดูแลทางกายภาพ | เจ้าของร้าน (ไฟ/เน็ต/ฮาร์ดแวร์) | ภาควิชา |
| ข้อมูลอยู่ที่ใคร | ร้านถือเอง (ลด PDPA hand-off) | คณะ |
| ประโยชน์ของการย้าย | **มีจริง** — ทำให้ร้านใช้จริงได้ | แทบไม่มี (ได้แค่เปลี่ยน CPU) |

**คำแนะนำ: A (ร้าน) เท่านั้นที่คุ้ม** ถ้าตั้งที่คณะ ไม่มีเหตุผลจะย้ายจาก VM มา Pi

**Remote access (เจ้าของตัดสิน — ไม่มีข้อไหนเป็นค่าเริ่มต้น):**

| ทาง | ใช้ทำอะไร | ข้อดี | ข้อเสีย/ต้องตัดสิน |
|---|---|---|---|
| ไม่มี (LAN เท่านั้น) | ใช้ใน LAN ร้าน | พื้นผิวโจมตีเล็กสุด ไม่ต้องมีโดเมน | ดูแล/แก้ไขจากนอกร้านไม่ได้; **runner self-hosted ยังได้** (outbound only) จึง deploy ได้ |
| Tailscale | SSH/ดู Grafana/platform-ui ผ่าน mesh VPN | แผน Personal ฟรี 3 ผู้ใช้ 100 อุปกรณ์ ([Tailscale pricing FAQ](https://tailscale.com/pricing/faq)) ไม่เปิดพอร์ต | ต้องใช้กับ **ทุกเครื่องที่ต้องเข้า** (รวมมือถือ) · ข้อมูลธุรกิจผ่านบริการบุคคลที่สามของ control plane — **เรื่อง PDPA ให้เจ้าของพิจารณา** |
| Cloudflare Tunnel | เปิดเว็บ POS ออกอินเทอร์เน็ต | ฟรี, outbound only (พอร์ต 7844) ไม่เปิด inbound ที่ router, ใช้ใบรับรองสาธารณะได้ ([ภาพรวมวิธี](https://flaviocopes.com/cloudflare-tunnel/) — บทความบุคคลที่สาม) | ต้องมีโดเมนที่ DNS อยู่ที่ Cloudflare; ทราฟฟิกทั้งหมดผ่าน Cloudflare (ถอดรหัส TLS ที่ edge) — **ขัดกับแนวคิด private CA / IP-only ปัจจุบัน** และต้องทบทวน `nginx.conf` allowlist กับ `trust proxy`=1 (`CLAUDE.md` หมวด Nginx: ห้ามมี proxy ตัวที่สอง/CDN หน้า Nginx เพราะ rate-limit รวมเป็น bucket เดียว) |

เพราะ Cloudflare Tunnel **ชนกฎ rate-limit/`clientIp()`** ที่ `CLAUDE.md` ระบุ (rightmost `X-Forwarded-For`) ต้องแก้ Nginx
เป็นงานแยก + ตัดสินใจโดยเจ้าของ → แนะนำให้ **ไม่รวมเข้าแผนย้ายนี้** (ทำเป็นโครงการภายหลัง)

**ผลต่อ offsite backup (#363):** ปัจจุบัน **ไม่มี backup ออกนอก VM** (parked, `CLAUDE.md` + `07_CICD_DEPLOY.md` §7a) —
บน Pi ที่ร้านความเสี่ยงสูงกว่า (ไฟ/น้ำ/ขโมย/การ์ดพัง ใบเดียวในร้านเดียว) · #363 ตัดสินว่าปลายทางคือ NAS ของร้านเอง
และ BeeStation (BSM) ไม่มี SFTP (`docs/handoff_log/research-363-sftp-nas-offsite.md`) → ย้ายมาร้านแล้ว NAS **อยู่ LAN เดียวกับ Pi**
ทำให้ **เส้นทางเครือข่ายที่ #363 ยังไม่พิสูจน์ง่ายขึ้นมาก** (ไม่ต้องผ่าน FortiGate) แต่ NAS ในร้านเดียวกันก็ไม่ป้องกันไฟไหม้/ขโมย →
ต้องมีสำเนาที่สามนอกร้านอย่างน้อยด้วยมือ (เช่น USB หมุนเวียนที่เจ้าของพกกลับบ้าน) · **ข้อเสนอ: ถือว่า #363 เป็นเงื่อนไขก่อน cutover**
(ไม่ใช่งานหลังย้าย) ไม่งั้นการย้ายทำให้สถานะ backup แย่ลง

---

## 4. การเปลี่ยนแปลงใน repo ที่ต้องทำ

> ทุก path ด้านล่าง grep แล้วว่ามีจริง · นี่คือรายการงาน ไม่ใช่ diff · ขนาดงานในหมวด 8

### 4.1 Multi-arch image (งานใหญ่สุด)

ตอนนี้ `server.yml` job `build-image` และ `flutter.yml` job `build-web` ใช้ `docker build` บน `ubuntu-latest` (x86) แล้ว push `:<sha>` และ `:main` —
**ได้ image amd64 เท่านั้น** `docker compose pull` บน Pi จะล้ม (`no matching manifest for linux/arm64`) หรือ `exec format error`

| งาน | ไฟล์ | รายละเอียด |
|---|---|---|
| build server image 2 arch | `.github/workflows/server.yml` (`build-image`) | ทางเลือก (ก) **runner arm64 native**: matrix `ubuntu-latest` + `ubuntu-24.04-arm` build แยก push เป็น tag ชั่วคราวต่อ arch แล้ว `docker buildx imagetools create` รวมเป็น manifest list `:<sha>`/`:main` · (ข) QEMU (`docker/setup-qemu-action` + `buildx --platform linux/amd64,linux/arm64`) — ง่ายกว่าแต่ stage `pnpm install`/`pnpm build` ใต้ QEMU ช้ามากและมี `timeout-minutes: 20` จำกัดอยู่ → **แนะนำ (ก)** |
| runner arm64 ฟรีไหม | — | GitHub ระบุ arm64 hosted runner (label `ubuntu-24.04-arm`) **ฟรีและไม่จำกัดนาทีสำหรับ repo สาธารณะ** (4 vCPU / 16 GB), GA ตั้งแต่ 2025-08: [GitHub changelog 2025-01-16](https://github.blog/changelog/2025-01-16-linux-arm64-hosted-runners-now-available-for-free-in-public-repositories-public-preview/), [GA 2025-08-07](https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/) · repo นี้ **สาธารณะ** (`CLAUDE.md`/`deploy.yml`: "This repo is PUBLIC") จึงเข้าเงื่อนไข · **[ไม่ยืนยัน]** ว่า org/ruleset ของ `NuimanLP` อนุญาต label นี้โดยไม่ตั้ง runner group (ลอง job ทดสอบ 1 ตัว) |
| build web image 2 arch | `.github/workflows/flutter.yml` (`build-web`), `deploy/web.Dockerfile` | web image = `busybox:stable-musl@sha256:…` + `COPY build/web /web` ไม่มี `RUN` → `docker buildx build --platform linux/amd64,linux/arm64` ได้ **โดยไม่ต้องใช้ QEMU** · base `busybox:stable-musl` ตรวจแล้วมี arm64/v8 · ถ้าไม่ทำ `web-sync` (`deploy/compose/vm.override.yml`) จะ crash บน Pi |
| digest ของ base | `server/Dockerfile` (`node:22-alpine@sha256:c610fcdf…`) | digest นี้คือ **manifest list** (ตรวจแล้วมี amd64+arm64/v8) ไม่ต้องเปลี่ยน — แต่สคริปต์ bump ที่ใช้ `docker buildx imagetools inspect node:22-alpine` ต้องยังชี้ index ไม่ใช่ digest ของ arch เดียว |
| Trivy ต่อ arch | `server.yml` (`aquasecurity/trivy-action@v0.36.0`, 2 จุด) | scan ทั้ง `linux/amd64` และ `linux/arm64` ก่อน push (`--platform`) · ช่องว่างจริง: dependency tree ต่างกันเฉพาะแพ็กเกจ optional ของ `sharp` (`@img/sharp-linuxmusl-arm64`) — ระวังอย่าเผลอเพิ่ม `.trivyignore` (ADR-0013 ห้าม) |
| smoke test ต่อ arch | `server.yml` step "smoke — every entrypoint…" | รัน smoke บน arm64 job ด้วย (native runner ทำได้ตรง ๆ) |
| `verify-ghcr-tags.sh` | `deploy/scripts/verify-ghcr-tags.sh` | เช็คว่า tag มีอยู่ (HTTP 200/404) — manifest list ผ่านได้เหมือนเดิม แต่ **ยังไม่เช็คว่ามี arm64 ใน list** → เพิ่มเช็คว่า platform ที่ host ต้องการมีอยู่ ไม่งั้น "ภาพของ amd64 อย่างเดียว" จะผ่านและพังตอน pull บน Pi |
| `sharp` (งานแยกที่กำลังทำ) | `server/Dockerfile` | `package.json` pin `sharp 0.35.5`; lockfile มี `@img/sharp-linuxmusl-arm64@0.35.5` + `@img/sharp-libvips-linuxmusl-arm64@1.3.4` (`server/pnpm-lock.yaml`) · การแก้ "build กับ libvips ของ Alpine" ต้อง **ทดสอบบน arm64 ด้วย** (ติดตั้ง `vips-dev` + toolchain ใน stage build บน arm64 และเช็คว่า `require('sharp')` + resize รูปทำงาน) · ข้อกล่าวอ้างว่า prebuilt arm64 ต้องการ ARMv8.2 (Pi 5 = Cortex-A76 ผ่าน) **[ไม่ยืนยัน]** — เอกสาร sharp ไม่ระบุ baseline ของ ARM64 และ README ของ sharp-libvips ก็ไม่ระบุ → **ทดสอบบน Pi จริง** อย่าอนุมาน · หมายเหตุ: CI arm64 (Cobalt 100) ผ่านไม่ได้พิสูจน์ว่า Pi 5 ผ่าน เพราะเป็นคนละ microarchitecture |

**arm64 มีครบทุก image ที่ pin ไว้ (ตรวจด้วย `docker buildx imagetools inspect <ref>@<digest>` เมื่อ 2026-10-10 — ใช้ digest ที่ pin อยู่ใน repo จริง):**

| image (pin ใน repo) | ไฟล์ | มี `linux/arm64`? |
|---|---|---|
| `postgres:16-alpine@sha256:72187…` | `server/docker-compose.yml` | ใช่ (arm64/v8) |
| `redis:7-alpine@sha256:858f0…` | `server/docker-compose.yml` | ใช่ (arm64/v8) |
| `nginx:1.29-alpine@sha256:56168…` | `server/docker-compose.yml` | ใช่ (arm64/v8) |
| `gcr.io/etcd-development/etcd:v3.6.12@sha256:3c2ce…` | `server/docker-compose.yml` | ใช่ (arm64) |
| `alpine/openssl:latest@sha256:6aa2b…` (certgen/htpasswd-gen) | `server/docker-compose.yml` | ใช่ (arm64) |
| `curlimages/curl:8.16.0@sha256:463eaf…` (etcd-init) | `server/docker-compose.yml` | ใช่ (arm64/v8) |
| `grafana/grafana:11.2.0@sha256:408afb…` | `deploy/compose/monitoring.yml` | ใช่ (arm64) |
| `prom/prometheus:v2.55.1@sha256:2659f…` | `deploy/compose/monitoring.yml` | ใช่ (arm64/v8) |
| `prom/node-exporter:v1.8.2@sha256:4032c…` | `deploy/compose/monitoring.yml` | ใช่ (arm64/v8) |
| `node:22-alpine@sha256:c610f…` | `server/Dockerfile` | ใช่ (arm64/v8) |
| `busybox:stable-musl@sha256:3c6ae…` | `deploy/web.Dockerfile` | ใช่ (arm64/v8) |

**ข้อควรระวัง:** สิ่งนี้พิสูจน์ว่ามี *platform* ใน manifest list — **ไม่ได้พิสูจน์ว่า image รันถูกต้องบน Pi** · ต้อง `docker compose up` จริงบนเครื่อง (หมวด 5, ซ้อม) ·
digest ที่ pin คือ manifest list จึง **multi-arch pin ใช้ได้เลย ไม่ต้องเปลี่ยน digest ใน compose** (docker เลือก platform เองตามเครื่อง) ·
`observability.yml` (loki/alloy/cadvisor ฯลฯ) เป็น overlay dev-only ไม่ใช้บน host — **ไม่ได้ตรวจ arm64** และไม่ต้องตรวจถ้าไม่ใช้

### 4.2 Ansible: inventory / host vars

* `deploy/ansible/inventory/hosts.ini` — มีกลุ่ม `[demo]` / host `vm-demo` เดียว ค่าเชื่อมต่อมาจาก env `DEMO_SSH_HOST/USER/KEY_PATH` → ถ้าจะให้ mob04 กับ Pi อยู่ด้วยกันช่วงซ้อม: เพิ่ม host ที่สอง/กลุ่ม `[pi]` **หรือ** ใช้ env เดียวกันชี้ไปคนละเครื่อง (ไม่ต้องแก้ playbook — `production-host.md` ก็ระบุแบบเดียวกัน)
* GitHub Environment `demo` (`07 §5`): secrets `DEMO_*` — `deploy.yml` (workflow) **ไม่ใช้** SSH secret เลย (runner อยู่บน VM) การย้ายจึงไม่ต้องแก้ secret ฝั่ง Actions แต่ **ต้องตัดสินใจเรื่อง environment**: ใช้ `demo` ต่อ (แล้วผูก runner label `srisurart-demo-deploy` กับ Pi แทน mob04) หรือสร้าง environment ใหม่ (ADR-0013 addendum 2026-09-15 พูดถึงกรณี host ที่สอง)
* ถ้าต้องการ `deploy.yml` ให้เลือกเครื่อง: ตอนนี้มี runner label เดียว — ระหว่างซ้อมที่มีสอง host **อย่าลงทะเบียน runner สองตัวด้วย label เดียวกัน** ไม่งั้น deploy ไปผิดเครื่อง → ให้ label ใหม่ (เช่น `srisurart-pi-deploy`) ตอนซ้อม แล้วค่อยสลับ (ต้องแก้ `.github/workflows/deploy.yml` บรรทัด `runs-on: [self-hosted, srisurart-demo-deploy]` และ `deploy/scripts/runner-job-started.sh` ถ้ามีการผูกชื่อ label — grep ก่อนแก้)

### 4.3 `provision.yml` บน OS ของ Pi

* `deploy/ansible/provision.yml` **รองรับ arm64 อยู่แล้ว**: map `x86_64→amd64`, `aarch64→arm64` สำหรับ apt repo ของ Docker (บรรทัด ~47–49) และใช้ `download.docker.com/linux/ubuntu` → ต้อง **Ubuntu** (ไม่ใช่ Raspberry Pi OS ซึ่งเป็น Debian — ต้องเปลี่ยน URL repo เป็น `…/linux/debian`)
* **OS ที่แนะนำ: Ubuntu Server 24.04 LTS 64-bit** — Pi 5 ได้รับ certified ([ubuntu.com/download/raspberry-pi](https://ubuntu.com/download/raspberry-pi), [docs](https://ubuntu.com/hardware/docs/boards/how-to/ubuntu_supported/raspberry-pi/)) และตรงกับสมมติฐานของ playbook ที่มีอยู่ · ทางเลือก Raspberry Pi OS 64-bit: Docker ทางการไม่มีหน้าเฉพาะสำหรับ 64-bit ให้ใช้ชุดติดตั้ง Debian arm64 แทน ([Docker docs](https://docs.docker.com/engine/install/raspberry-pi-os.md)) — ต้องแก้ playbook (repo path + codename) จึงไม่แนะนำ
* ก่อน provision: flash Ubuntu ลง microSD → `rpi-eeprom-update -a` → ตั้ง `BOOT_ORDER` ให้ NVMe มาก่อน (ผ่าน `rpi-eeprom-config --edit`; ค่าเลขที่ถูกต้อง **[ไม่ยืนยัน]** — ตรวจกับเอกสาร bootloader ทางการก่อนแก้, อย่าทำตามความจำ) → ย้าย OS ลง NVMe → ถอด SD
  ([คู่มือ M.2 HAT+](https://www.raspberrypi.com/documentation/accessories/m2-hat-plus.html), [Jeff Geerling](https://www.jeffgeerling.com/blog/2023/nvme-ssd-boot-raspberry-pi-5))
* เพิ่มใน provision (ยังไม่มี): ตั้ง timezone `Asia/Bangkok` + ยืนยัน NTP/RTC; ปรับ `journald`/Docker log-driver ให้จำกัดขนาด (ลดการเขียน SSD) **[ข้อเสนอ]**; `ufw` ยัง allow 22/80/443 ตามเดิม (บรรทัด ~73–78); อย่าติด `rclone` จนกว่า #363 เลือก protocol
* `ansible-core`, `git`, `curl`, `tar` ติดตั้งโดย `setup-mob04-runner.sh` ผ่าน `apt` — ใช้ได้บน Ubuntu arm64
* ข้อห้ามเดิมยังอยู่: `provision.yml` รันเป็น `cloud` (sudo, ไม่อยู่กลุ่ม docker), `deploy.yml` รันเป็น `deploy` — ห้ามสลับ; ห้าม `--diff` กับ `provision.yml` (พิมพ์ `.env` ทั้งไฟล์) (`CLAUDE.md`)

### 4.4 Runner arm64

* `deploy/scripts/setup-mob04-runner.sh` ฮาร์ดโค้ด `RUNNER_ARCHIVE="actions-runner-linux-x64-${RUNNER_VER}.tar.gz"` (บรรทัด ~138) และ `RUNNER_NAME="mob04-demo"` → ต้อง **ทำให้เลือก arch ตาม `uname -m`** (ไฟล์ของ arm64 ชื่อ `actions-runner-linux-arm64-<ver>.tar.gz` — **[ไม่ยืนยัน]** ชื่อไฟล์/sha256 ให้เอาจากหน้า Settings → Actions → Runners → New self-hosted runner → Linux ARM64) และ rename เป็นชื่อกลาง (เช่น `setup-runner.sh`; `07_CICD_DEPLOY.md` §6.2 อ้างชื่อไฟล์เดิม ต้องแก้ให้ตรง)
* ยังใช้ `gha-runner` (ไม่อยู่กลุ่ม `docker`/`deploy`), sudoers `/etc/sudoers.d/pos-deploy`, `/usr/local/bin/pos-deploy`, hook `/usr/local/lib/pos-runner/job-started.sh` — ไม่เปลี่ยนตรรกะ
* 🔴 `pos-deploy` เป็นสำเนา root-owned บนเครื่อง: `ROLLBACK_FLOOR` (`bedd328aa3ba…`) ฝังอยู่ในสำเนานั้น — Pi ได้สำเนาจากการติดตั้งใหม่ ไม่ใช่จากการ deploy; ต้องตรวจว่าเป็นสำเนาจาก `main` ล่าสุด (floor ไม่เปลี่ยนจากนี้)
* ตรวจ runner ออนไลน์ก่อน approve ทุกครั้ง: `gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners` (กฎเดิมใน `CLAUDE.md`)

### 4.5 Private CA / certgen SAN / APK

* `server/docker/certgen/certgen.sh`: `SAN="DNS:localhost,IP:127.0.0.1,IP:172.30.58.20"` ฮาร์ดโค้ด · IP ใหม่ของ Pi ≠ 172.30.58.20 ⇒ **ต้องแก้ SAN** (ตามที่ `CLAUDE.md` ระบุไว้แล้ว: "A VM IP change = edit the SAN") · ข้อเสนอ: ทำให้ SAN รับค่าจาก env (`.env` ของ host) แทนการแก้โค้ดทุกครั้งที่ย้าย — **เป็นการเปลี่ยนพฤติกรรม certgen ต้อง review** · ช่วงซ้อมใส่ *ทั้งสอง IP* ในใบเดียว
* ทดสอบ: `deploy/scripts/test/certgen.test.sh` ยืนยัน SAN เป็นสตริงตายตัว (บรรทัด ~40–41, 69–70) → ต้องแก้ตามที่เปลี่ยน
* `.github/workflows/android-apk.yml`: `API_BASE_URL: https://172.30.58.20` → APK เก่า **ชี้ไป mob04 ตลอด** ต้อง build APK ใหม่ที่ชี้ IP/โดเมนใหม่ และแจกจ่ายใหม่ทุกเครื่อง (ดูหมวด 5 ผลกระทบ)
* `frontend/assets/certs/pos-ca.crt`: ถ้า **รักษา CA เดิม** (คัดลอก volume `certs-ca` — หมวด 5) ไฟล์นี้ **ไม่ต้องแก้** → APK ใหม่ trust ได้ทันที · ถ้าเสีย CA = ต้อง commit `ca.crt` ใหม่ + build APK ใหม่ (ซ้ำ runbook `07_CICD_DEPLOY.md` §5 "Runbook ครั้งเดียว") — และ **APK/เบราว์เซอร์ทุกเครื่องที่เคย trust CA เดิมจะต่อไม่ได้** จนกว่าจะอัปเดต
* ที่อยู่แบบ IP ในร้าน: DHCP reservation/IP คงที่บน router เป็นเงื่อนไขบังคับ (ใบ SAN ผูก IP) · ชื่อ `.local` (mDNS) กับ Dart `HttpClient` บน Android **[ไม่ยืนยัน]** — อย่าพึ่ง

### 4.6 Nginx / allowlist / CORS

* `PLATFORM_ADMIN_IPS` (default `172.30.0.20` = platform-ui container) + `allow 172.30.0.20` ใน `server/docker/nginx/nginx.conf` (บรรทัด ~94, ~127) เป็นที่อยู่ **ใน docker network** (`172.30.0.0/24` ใน `server/docker-compose.yml`) → **ไม่เปลี่ยนตามเครื่อง** แต่ต้องตรวจว่า LAN ร้านไม่ใช้ subnet `172.30.0.0/24` ชนกัน
* `CORS_ORIGINS` (ใน `DEMO_ENV_FILE`/`.env`, ปัจจุบัน `https://172.30.58.20` ตาม `CLAUDE.md`) → เปลี่ยนเป็น origin ใหม่ ไม่งั้น browser client ถูกบล็อก (ไม่มี ACAO) · `provision.yml` rewrite `.env` แต่ไม่ restart — `deploy.yml` ตรวจ `env_changed` (บรรทัด ~67) แล้ว restart ให้
* 🔴 **ข้อควรระวังด้านความปลอดภัยเมื่อย้ายมา LAN ร้าน:** `location = /prometheus-remote-write/api/v1/write` มี `allow 10.0.0.0/8; allow 172.16.0.0/12; allow 192.168.0.0/16` (RFC1918) + Basic Auth — LAN ร้านเป็น `192.168.x.x` ⇒ เครื่องใดใน LAN ผ่านด่าน IP แล้ว เหลือแค่ Basic Auth ด่านเดียว (ตั้งใจสำหรับ k6 ในเครือข่ายคณะ) → พิจารณาตัดทิ้ง/จำกัดบน Pi เมื่อไม่ใช้ k6 (#380) **[ข้อเสนอ — เป็นการแก้ `nginx.conf` ที่ต้อง review ต่างหาก]** · ส่วน Bull-Board/Prometheus/Grafana/node-exporter ผูก loopback เท่านั้น (ไม่เปลี่ยน)
* ห้ามเอา CDN/proxy ที่สองมาไว้หน้า Nginx (`trust proxy`=1) — ผลต่อ Cloudflare Tunnel ดูหมวด 3

### 4.7 Scripts: backup / heartbeat / RSS

* `deploy/scripts/backup-db.sh` ไม่ผูก arch · `pg_dump --create --clean --if-exists` (logical dump ย้าย arch ได้) · เก็บ volume `product-images` เป็น `pos_images_<ts>.tar.gz` · cron 03:00 จาก `provision.yml`
* **เฉพาะ `provision.yml` ติดตั้ง `/opt/pos/scripts`** (CD ไม่อัปเดต) → provision Pi ใหม่ได้สคริปต์ล่าสุดโดยธรรมชาติ แต่ต้องรัน `backup-db.sh` และ `restore-db.sh` ด้วยมือหนึ่งครั้งเพื่อพิสูจน์บน Pi (ตามบทเรียน 2026-09-29)
* `healthcheck-ping.sh` (Healthchecks.io, `HEALTHCHECKS_PING_URL` ใน `.env`) — ใช้ URL เดิมหรือสร้างเช็คใหม่สำหรับ Pi · ถ้าใช้ URL เดิมช่วงซ้อมที่ทั้งสองเครื่องรันพร้อมกันจะ ping ปน → **ใช้ check แยกต่อเครื่อง** · และเมื่อ Pi อยู่ที่ร้าน ping outbound ยังทำงาน (ต้องออก `hc-ping.com` ได้)
* `deploy/scripts/measure-container-rss.sh` — มีบั๊กเก่า (แก้ใน PR #654) และสำเนาบน mob04 เป็นของเก่า; บน Pi ควรวัด RSS ใหม่หลังย้าย (ปิด #380 บนฮาร์ดแวร์ใหม่ ไม่ใช่ mob04 — เจ้าของต้องตัดสินว่าจะวัดซ้ำหรือไม่ คำถามข้อ 6)

### 4.8 RAM limit ใน compose/override สำหรับ RAM ของ Pi

* `mem_limit` ปัจจุบัน (ตัวเลขจาก `server/docker-compose.yml`): api-x3 + worker + bull-board (ค่า anchor 384m / 256m / 128m ตามบริการ), nginx 64m, platform-ui 32m, postgres **1024m** (+`shm_size: 256m`, `max_connections=100`), redis ×2 256m, etcd 256m, certgen/htpasswd-gen 32–128m, etcd-init 32m; monitoring.yml: node-exporter 64m, Prometheus 512m, Grafana 256m → รวม ≈4.2 GB (`07 §5`)
* บน Pi 8 GB: **ไม่ต้องลดเพดาน** เพราะ `mem_limit` เป็นเพดาน ไม่ใช่การจอง และ RSS จริงสูงสุด 648 MiB · ข้อเสนอ: คง `vm.override.yml` เดิมและ **ไม่สร้างไฟล์ override ใหม่ต่อ arch** · ถ้าเลือก Pi 4 GB (ไม่แนะนำ): ต้องทบทวนเพดานรวม + ปิด monitoring (`monitoring.yml`) หรือลด Prometheus retention — **ห้ามเดา ต้องวัดบน Pi ด้วย k6 ก่อน**
* Postgres `shared_buffers`/`work_mem` ไม่ได้ตั้งค่าไว้ (ใช้ default ของ image) — ไม่จำเป็นต้องจูนสำหรับย้าย; อย่าเพิ่มโดยไม่มีตัวเลขวัด
* Pi ไม่มี swap ตามค่าปริยายของ Ubuntu Server? **[ไม่ยืนยัน]** — ตรวจ `free -h` ตอน provision; swap บน NVMe ลดโอกาส OOM แต่ไม่ควรพึ่ง

---

## 5. Runbook ย้ายข้อมูล (cutover) ทีละขั้น

> สมมติ: Pi provision เสร็จและผ่านการซ้อมแล้ว (ข้อ 5.0) · ทำเป็น **ช่วงปิดเขียน (maintenance window) ตอนร้านปิด** · อย่า print secret ลง log/แชต/commit (รวม `.env`, `ca.key`, htpasswd) ·
> คำสั่งด้านล่างคือรูปแบบ — ตรวจ path/ชื่อ volume จริงก่อนรัน (`docker volume ls` บน mob04; compose project name `srisurart-pos` ตาม `deploy/compose/vm.override.yml` จึงชื่อ volume น่าจะเป็น `srisurart-pos_<name>` **[ไม่ยืนยัน — ตรวจ]**)

### 5.0 ซ้อมก่อน (ไม่แตะ production)

1. Pi: provision (หมวด 4.3) + runner + deploy SHA **เดียวกับที่ `/opt/pos/.current_sha` บน mob04** (migration เป็น forward-only ไม่มี down-migration — schema ต้องตรงกัน)
2. ดึง backup ล่าสุดจาก mob04 (`/opt/pos/backups/pos_backup_*.sql.gz` + `.sha256`) มาที่ Pi → `restore-db.sh <file>` บน Pi → เทียบจำนวนแถว (ข้อ 5.4) → ลองล็อกอิน, ขาย 1 บิลทดสอบบน tenant ทดสอบ
3. ทดสอบ `sharp` จริง: อัปโหลดรูปสินค้าและดึงผ่าน API
4. ทดสอบ restart ไฟดับ: ถอดปลั๊ก Pi ระหว่างมี traffic → boot กลับ → `/health/ready` = 200 และ Postgres ไม่ corrupt
5. ซ้อมนี้ **ต้องไม่ใช้ tenant/ข้อมูลจริง** ที่จะถูกลบแล้วตกค้าง — ทำบนสำเนา แล้ว `wipe` Pi (volume ใหม่) ก่อน cutover จริง เพื่อไม่ให้มีเลขเอกสาร/`doc_counters` ปนกัน

### 5.1 ก่อนวัน cutover

1. ประกาศหยุดระบบกับร้าน · ให้ทุกเครื่อง (เบราว์เซอร์/APK) **ซิงก์ outbox จนว่าง** และ **ปิดกะ** (กฎ: ปิดกะต้อง outbox ว่าง — `CLAUDE.md` / 08 §11 #456) — **ข้อมูลที่ค้างใน outbox ของเบราว์เซอร์ผูกกับ origin เดิม (`https://172.30.58.20`) และจะหายจากมุมมองของ origin ใหม่**
2. ตรวจ runner Pi ออนไลน์, `.current_sha` ของ mob04 = SHA ที่ Pi รัน
3. จด baseline: จำนวนแถวต่อตารางสำคัญ (`sales`, `sale_items`, `products`, `customers`, `mechanics`, `shifts`, `doc_counters`, `users`, `devices`, `tenants`) และ `SELECT max(...)` ของเลขเอกสาร (RC/CN/PO/QT) ต่อ tenant — ใช้ตรวจหลังย้าย
4. สำรองเพิ่ม: บน mob04 รัน `backup-db.sh` ด้วยมือ (ได้ทั้ง `pos_backup_*.sql.gz` และ `pos_images_*.tar.gz` + sha256) + `etcdctl snapshot save` (รูปแบบดูที่ `docs/handoff_log/session-2026-09-30-first-runner-deploy.md` บรรทัด ~276) · **สำเนาออกนอก VM ด้วยตนเอง** (ยังไม่มี offsite — #363 — จึงเก็บสำเนาไว้ในเครื่องผู้ใช้ด้วย)

### 5.2 ปิดเขียนบน mob04

1. หยุดไม่ให้รับเขียน: ตัวเลือก (ก) `docker compose stop api-1 api-2 api-3 worker` (nginx ยังตอบ 502 ให้ client รู้ว่า unavailable) · (ข) ใส่ maintenance page ที่ nginx — **[ข้อเสนอ ยังไม่มีใน repo]** ใช้ (ก)
2. ยืนยันไม่มี connection เขียนค้าง: `SELECT count(*) FROM pg_stat_activity WHERE datname='pos' AND state <> 'idle';`
3. สร้าง dump สุดท้าย (นี่คือ dump ที่ใช้จริง): `backup-db.sh` → ตรวจ `.sha256` และ `gzip -t`

### 5.3 ย้ายของไป Pi

| ของ | ย้ายอย่างไร | หมายเหตุ |
|---|---|---|
| **Postgres** (`pgdata`) | **logical dump เท่านั้น** (`pg_dump --create --clean --if-exists`, ผ่าน `backup-db.sh`) → `restore-db.sh` บน Pi | ห้ามคัดลอก `pgdata` ดิบข้าม arch · restore script ตรวจ `pos_app` role timeouts (#213) ให้ · role `pos_app` ถูกสร้างโดย `server/docker/postgres/init/01-app-role.sh` ตอน initdb ครั้งแรกบน volume ว่าง ด้วย `POS_APP_PASSWORD` จาก `.env` → **`.env` บน Pi ต้องใช้ `POS_APP_PASSWORD` เดียวกับ mob04** ไม่งั้นแอปต่อไม่ได้ |
| **`.env` (secrets)** | ส่งผ่านช่องทางที่ปลอดภัย (scp ระหว่างเครื่องที่ยืนยันตัวตน / password manager) แล้ว `provision.yml` วางด้วย `DEMO_ENV_FILE` ตามเดิม (0600) | **ห้าม print/commit** · ใช้ค่าเดิมทุกตัว (`POSTGRES_PASSWORD`, `POS_APP_PASSWORD`, `JWT_*`, `ETCD_ROOT_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `PLATFORM_ADMINS`, `HEALTHCHECKS_PING_URL`…) **ยกเว้น** `CORS_ORIGINS` (origin ใหม่) · ถ้าเปลี่ยน `JWT_*` ทุก session/refresh token เดิมใช้ไม่ได้ (ทุกคนล็อกอินใหม่ — ยอมรับได้แต่ควรรู้) · `pgdata`/`etcd-data`/`nginx-auth` รับรหัสผ่าน ณ ตอน bootstrap ครั้งแรก (`CLAUDE.md`) — บน volume ใหม่ของ Pi จึงใช้ `.env` เดิมได้ปกติ |
| **`product-images`** | `docker run --rm -v product-images:/data … tar` → คัดลอก `pos_images_<ts>.tar.gz` ไป Pi → คลายลง volume `product-images` ให้เจ้าของ uid `node` (Dockerfile สร้าง `/app/product-images` owner `node`) | Postgres เก็บแค่ key ของรูป (ดู `backup-db.sh` หัวไฟล์) — เมื่อรูปไม่ครบ API ตอบ 404 รูป; ไม่มีสคริปต์ restore รูปใน repo ตอนนี้ (**ช่องว่าง** — ควรเขียน `restore` สำหรับรูปเป็นงานเพิ่มในเฟส 2) |
| **`certs-ca`** (CA) | คัดลอกไฟล์ `ca.key`+`ca.crt` จาก volume `certs-ca` → volume `certs-ca` ที่ว่างบน Pi **ก่อน** deploy ครั้งแรกที่ certgen จะรัน | 🔴 ถ้า certgen รันก่อนบน Pi มันจะ **สร้าง CA ใหม่ทันที** (เมื่อ `ca.key` ไม่มี) ⇒ APK/เบราว์เซอร์ที่ pin CA เดิมต่อไม่ได้ ⇒ ต้องวาง CA เดิมใน volume ก่อน `docker compose up certgen` · `ca.key` เป็นความลับสุด: ห้ามออกจาก VM ตามหลักเดิมของ repo (`certgen.sh` หัวไฟล์) — การคัดลอกเป็นการ **ย้าย** ไม่ใช่เผยแพร่: ส่งเข้ารหัส (scp ตรง mob04→Pi หรือ USB เข้ารหัส) แล้ว **ลบสำเนากลางทางทั้งหมด** และเจ้าของต้องอนุมัติ (คำถามข้อ 3) |
| **ผลถ้าได้ CA ใหม่** | ทุก APK ที่แจกแล้ว (pin `pos-ca.crt` เก่า) ต่อ Pi ไม่ได้ · ต้อง commit `frontend/assets/certs/pos-ca.crt` ใหม่ผ่าน PR (public cert) + รัน workflow *Android APK* + แจก APK ใหม่ทุกเครื่อง · เบราว์เซอร์ที่ติดตั้ง `ca.crt` เก่าไว้ต้องติดตั้งใหม่ | ทางเลือกที่ไม่ต้องคัดลอก `ca.key`: ยอมรับ CA ใหม่ + APK ใหม่ (เพราะต้อง build APK ใหม่ที่ชี้ URL ใหม่อยู่แล้ว ราคาเพิ่มคือแค่การ commit cert ใหม่ — **เป็นทางที่ปลอดภัยกว่าในแง่ key hygiene**) |
| `nginx-auth` | ไม่ต้องย้าย — `htpasswd-gen` สร้างใหม่จาก `K6_REMOTE_WRITE_BASIC_AUTH_*` ใน `.env` (ถ้า `.env` เดิมถูกคัดลอก) | ถ้าไม่ใช้ k6 บน Pi ก็ไม่สำคัญ |
| **etcd** (`etcd-data`) | **ไม่ต้องย้ายข้อมูล** — `etcd-init` seed ค่า `log_level` เมื่อยังไม่มี (`07 §8`: ไม่ใช่ข้อมูล ไม่ใช่ความลับ) · ถ้าต้องการค่าที่ตั้งมือไว้: `etcdctl snapshot save` จาก mob04 → restore (ซับซ้อนกว่าที่คุ้ม) | `ETCD_ROOT_PASSWORD` จาก `.env` เดียวกันจะ bake เข้า volume ใหม่ถูกต้อง (บทเรียน: รหัสผ่านไม่ตรง volume = "service ไม่ green" ไม่ใช่ข้อความเรื่องรหัสผ่าน) |
| `redis-queue-data` | ไม่ต้องย้าย (คิวงานชั่วคราว; ตรวจว่า BullMQ ว่างก่อนปิด: bull-board ผ่าน `ssh -L 3100`) | งานค้างในคิว (เช่น export/import) จะหาย — ปล่อยให้เสร็จก่อน |
| `exports` volume | ย้ายเฉพาะถ้ามีไฟล์ pre-import ที่ **ต้องเก็บ** (PDPA: ไฟล์ `/app/exports/<tenant>/pre-import/<jobId>.json` ไม่ถูกลบอัตโนมัติ — `CLAUDE.md`) | ตัดสินกับเจ้าของ (คำถามข้อ 7) |

### 5.4 Restore และตรวจสอบบน Pi

1. ตรวจว่า stack ขึ้นด้วย SHA เดียวกัน (`/opt/pos/.current_sha` ของ Pi = ของ mob04) และ `migrate` ผ่านแล้ว (ได้ schema เปล่าที่ตรง)
2. `docker compose stop api-1 api-2 api-3 worker` บน Pi → `restore-db.sh pos_backup_<ts>.sql.gz` (มี `--clean --if-exists` ทับของเปล่าได้) → สคริปต์ตรวจ checksum + ceiling ของ `pos_app` ให้
3. คลาย `pos_images_<ts>.tar.gz` ลง `product-images`
4. **เทียบจำนวนแถว** กับ baseline 5.1(3) ทุกตาราง + `max` เลขเอกสาร + `doc_counters` ต่อ `(tenant, device_no, kind, period)` ต้องตรงทุกค่า — ไม่ตรง = **หยุด** อย่าเปิดรับเขียน
5. ถ้ามี tenant ที่ import ผ่าน owner/platform import: ยืนยัน `doc_counters` ยังสูงกว่า RC/CN/PO/QT ล่าสุด (กฎ `CLAUDE.md`: ไม่งั้นบิลถัดไปชน `409 RECEIPT_NO_CONFLICT`)
6. start api/worker → `GET /health/ready` = 200 → `/opt/pos/.current_sha` = SHA เดิม (ยืนยันของจริง ไม่ใช่แค่ run เขียว)

### 5.5 สลับ client (DNS/IP) และผลต่อ APK/เบราว์เซอร์

* **ไม่มี DNS** ใช้ IP → "สลับ" = ให้ client ชี้ไปที่อยู่ใหม่ ไม่ใช่ย้าย record · ถ้าเจ้าของอยาก **ย้ายต่อได้ในอนาคตโดยไม่ build APK ใหม่** ควรมีชื่อโดเมน (Let's Encrypt ออกใบให้ IP ไม่ได้ — `07 §5`) — **ตัดสินใจโดยเจ้าของ** (คำถามข้อ 4)
* **APK:** URL ถูก compile เข้า (`API_BASE_URL`) ⇒ **ต้อง build+แจกใหม่** (`android-apk.yml` manual, `main` only) — APK เก่าไม่หยุดทำงานเอง แต่ชี้ mob04 อยู่ (ถ้า mob04 ปิดแล้วต่อไม่ได้) · ข้อมูลใน APK (Drift, device token ใน secure storage) คงอยู่ถ้าติดตั้งทับด้วย keystore เดิม (`ANDROID_KEYSTORE_B64` — ทำหายไม่ได้) · `TenantCacheGuard` (`CLAUDE.md`) ยอมให้ใช้ tenant เดิมต่อ · **device token ที่ออกโดย mob04 ถูกเก็บใน DB (คัดลอกมากับ dump) จึงใช้ได้ต่อ [ไม่ยืนยัน — ซ้อมให้เห็นก่อน]**
* **เบราว์เซอร์ (PWA/web):** origin เปลี่ยน ⇒ IndexedDB/Drift/service worker/localStorage เป็นของ origin ใหม่ **ว่างเปล่า** ⇒ ต้อง **enrol เครื่องใหม่** ด้วย enrolCode (`POST /auth/device`) และข้อมูลที่ยังไม่ซิงก์ที่ origin เดิมเข้าถึงไม่ได้ ⇒ ขั้น 5.1(1) สำคัญมาก · ติดตั้ง `ca.crt` ลงเบราว์เซอร์ถ้ายังไม่เคย (หรือถ้า CA ใหม่)
* สิ่งที่ **ไม่** เปลี่ยน: `tenants`, `users`, รหัสผ่านเจ้าของ, ข้อมูลทั้งหมดใน Postgres, UUID ทุกตัว (คัดลอกตรง)

### 5.6 `ROLLBACK_FLOOR` และ `.current_sha`

* `ROLLBACK_FLOOR` = `bedd328aa3ba1de8c56b5fe5753fd12deca5dd4f` อยู่ใน `deploy/scripts/pos-deploy.sh` (สำเนาที่ติดตั้งแล้วบนเครื่อง) — ใช้กับ Pi เหมือนกัน; **ห้ามลดลง** · merge ของ `develop`→`main` ต้องเป็น merge commit เสมอ (ไม่งั้น floor ไม่ใช่ ancestor)
* `/opt/pos/.current_sha` บน Pi ว่างตอนแรก → deploy ครั้งแรกไม่ถือเป็น duplicate · เขียนหลัง readiness ผ่านเท่านั้น (ไม่ลบเองเพื่อบังคับ deploy — มี `-e force_redeploy=true`)
* หลัง cutover: SHA ที่ Pi รัน = SHA ที่ mob04 รันก่อนปิด · ห้าม deploy `main` ตัวใหม่ทันที — เว้นช่วงให้ข้อมูลเสถียรก่อน (เปลี่ยนทีละอย่าง)

### 5.7 หลัง cutover

* ตรวจ: ล็อกอิน, เปิดกะ, ขาย 1 บิลจริง (หรือบิลทดสอบที่ void ตามกติกา), คิวรูปสินค้า, พิมพ์ใบเสร็จ, Grafana (`ssh -L 3000`/tunnel) เห็น metrics · cron backup ที่ 03:00 วันถัดไปสำเร็จ (อ่าน `backup-cron.log` — และ `::warning::` เรื่อง offsite ยังเป็นปกติ) · heartbeat เข้า Healthchecks
* ปิด mob04 **ยัง**: ปล่อยไว้เป็น rollback (หมวด 6) อย่างน้อย 1–2 สัปดาห์ แต่ **หยุดรับ traffic** (หยุด api/worker) ไม่ให้สองเครื่องเขียน tenant เดียวกัน

---

## 6. Rollback กลับ mob04

**ข้อกำหนดจึงจะ rollback ได้:** mob04 ต้อง **ยังอยู่ครบและอัปเดตได้** (volume ไม่ถูกลบ, runner ออนไลน์) จนกว่าจะสิ้นสุดช่วงสังเกต

| สถานการณ์ | ทำอย่างไร |
|---|---|
| ล้มก่อนเปิดรับเขียนบน Pi (ตรวจแถวไม่ตรง ฯลฯ) | ไม่มีการเขียนบน Pi → เปิด api/worker ของ mob04 กลับ (`docker compose start api-1 api-2 api-3 worker`) ภายในวินาที/นาที — ข้อมูล mob04 ยังเป็นความจริงเดียว · client ยังชี้ mob04 อยู่ |
| ล้มหลังเปิดรับเขียนบน Pi (มีบิลใหม่แล้ว) | **ข้อมูลแตกเป็นสองที่** ⇒ ต้อง dump จาก Pi (`backup-db.sh`) → `restore-db.sh` บน mob04 (ทับ) หลังหยุด mob04 ตามขั้น 5.2 · เลขเอกสารและ `doc_counters` มาตามกับ dump จึงไม่ซ้ำ · ซ้อมเส้นทางนี้ก่อน (ข้อ 5.0) เพราะเป็นเส้นทางที่แพงที่สุด |
| ผู้ใช้ย้ายเบราว์เซอร์/APK ไป origin ใหม่แล้ว | ต้องชี้กลับ: APK เดิม (ที่ไม่ได้ถูกแทน) ชี้ mob04 อยู่ → ใช้งานต่อได้ทันที ถ้า **เก็บ APK เก่า** ให้แจก/ติดตั้งคืน · เบราว์เซอร์ origin เก่ายังมี IndexedDB เดิม (ถ้าไม่ได้ล้างข้อมูลไซต์) ⇒ **ห้ามสั่งให้ล้างข้อมูลเบราว์เซอร์ที่ origin เก่า จนกว่าพ้นช่วงสังเกต** |
| SHA/ภาพของ mob04 | ไม่ต้องทำอะไร — mob04 ไม่ได้ถูกแตะ; `.current_sha` ของ mob04 ยังเป็น SHA เดิม · ถ้าต้อง redeploy: `workflow_dispatch` (manual) ของ `deploy.yml` บน runner ของ mob04 (ต้องเป็น label ที่ mob04 ยังถือ) |
| ปัญหา CA | ถ้าคัดลอก CA เดิมไป Pi และ **ไม่ได้ลบ** บน mob04 ⇒ rollback ไม่กระทบ trust · ถ้าเปลี่ยน CA บน Pi แล้ว rollback กลับ mob04 ⇒ APK ใหม่ (ฝัง CA ใหม่) ต่อ mob04 ไม่ได้ ⇒ **ต้องเก็บ APK เก่าไว้พร้อมติดตั้งคืน** (ข้อดีของการคัดลอก CA เดิม) |
| sharp/แพ็กเกจพังบน arm64 หลัง cutover | rollback ภาพ: `workflow_dispatch` ไปยัง SHA ก่อนหน้า (ต้อง ≥ `ROLLBACK_FLOOR`) — ใช้ได้เฉพาะถ้าภาพ SHA เก่า **มี arm64** (ภาพก่อนทำ multi-arch ไม่มี) ⇒ จะ rollback ภายใน Pi ได้แค่ SHA หลังจากนำ multi-arch เข้า `main` เท่านั้น |

**ระยะสังเกตแนะนำ:** ≥ 14 วัน (ครอบคลุม cron 03:00 หลายรอบ, ปิดงวดเดือนอย่างน้อยหนึ่งครั้ง ถ้าเป็นไปได้ — เลขเอกสารอิงงวด) ก่อนปิด/ล้าง mob04

---

## 7. ความเสี่ยง + คำถามที่เจ้าของต้องตอบ

### ความเสี่ยง

| # | ความเสี่ยง | ระดับ | ลด/จัดการ |
|---|---|---|---|
| R1 | ไฟดับ/ไฟตก → Postgres/SSD เสียหาย | สูง | UPS + shutdown อัตโนมัติ; ซ้อมถอดปลั๊ก (5.0 ข้อ 4) |
| R2 | ฮาร์ดแวร์ตัวเดียวพัง (บอร์ด/SSD) ร้านหยุด | สูง | ชุดสำรอง/ขั้นตอนกู้จาก backup; **ต้องมี offsite (#363)** ก่อน cutover |
| R3 | CI ไม่เคยสร้าง arm64 → `compose pull` ล้ม | แน่นอนถ้าไม่ทำ | หมวด 4.1; เช็ค platform ใน `verify-ghcr-tags.sh` |
| R4 | `sharp` พังบน arm64/Pi 5 (baseline CPU) | กลาง | ทดสอบบน Pi จริง ผ่านการแก้ libvips ของ Alpine; ข้อกล่าวอ้าง ARMv8.2 **[ไม่ยืนยัน]** |
| R5 | เปลี่ยน CA โดยไม่ตั้งใจ (certgen รันก่อนวาง CA) | สูง (ผลร้ายแรง) | วาง `certs-ca` ก่อน deploy ครั้งแรกของ Pi; ตรวจ fingerprint ก่อน/หลัง (`openssl x509 -fingerprint -sha256`) |
| R6 | ข้อมูลแตกสองที่ (สองเครื่องเขียน tenant เดียวกัน) | สูง | หยุด api/worker ของ mob04 ก่อนเปิด Pi; ห้าม dual-active |
| R7 | origin เปลี่ยน → outbox/IndexedDB เบราว์เซอร์หาย | กลาง | ซิงก์ให้ว่างก่อน (5.1) + enrol ใหม่ |
| R8 | LAN ร้านปล่อย RFC1918 ผ่านด่านเดียว (Basic Auth) ของ remote-write | ต่ำ–กลาง | ตัด location นี้บน Pi เมื่อไม่ใช้ k6 |
| R9 | การ์ดไม่บูต NVMe/EEPROM เก่า/PSU ไม่พอ | ต่ำ | ตรวจ `rpi-eeprom-update`, PSU 27 W ทางการ |
| R10 | ราคา Pi/SSD ผันผวนต่อเนื่อง (DRAM) | ต่ำ | re-quote ตอนซื้อ; ตั้ง cap งบ |
| R11 | ขัดกับ development freeze / เดโม #344 | กลาง | เริ่มหลังส่งงาน |
| R12 | ความรู้ดูแล Pi ที่ร้านไม่มีใคร | กลาง | runbook + Healthchecks + Tailscale (ถ้าเจ้าของอนุมัติ) |

### คำถามที่เจ้าของต้องตัดสิน

1. **`mob04` ยังเป็น "production ตัวเดียว" (#242) หรือไม่ หลังย้าย?** (Pi เป็น production ใหม่แทนที่ หรือ mob04 เป็นสำรอง/เดโมต่อไป) — และ `07_CICD_DEPLOY.md` §5 ที่ขัดกันเองเรื่อง "ใช้สาธิตอย่างเดียว/เป็น production" จะแก้ให้ตรงอย่างไร
2. **Pi ตั้งที่ไหน** — ร้าน (แนะนำ) หรือคณะ? ใครรับผิดชอบทางกายภาพ?
3. **คัดลอก CA เดิม (`ca.key`) ไป Pi หรือออก CA ใหม่ + build APK ใหม่ + commit `pos-ca.crt` ใหม่?** (ความสะดวก vs. key hygiene)
4. **จะมีโดเมน (เช่น `pos.<โดเมนร้าน>`) หรือใช้ IP ตรง ๆ ต่อไป?** โดเมน = ใช้ Let's Encrypt/ย้ายเครื่องครั้งหน้าไม่ต้อง build APK ใหม่ ต้นทุน ~฿500–700/ปี (ตัวเลขจาก `docs/research/production-host.md` — ไม่ได้ยืนยันใหม่)
5. **Remote access:** ไม่มี / Tailscale / Cloudflare Tunnel? (ผลต่อ PDPA, `nginx.conf`, `trust proxy`) — หรือเลื่อนไปโครงการแยก
6. **#380 (k6 + RSS) วัดซ้ำบน Pi หรือไม่?** และจะปิด DoD §8 กล่อง k6 บนฮาร์ดแวร์ไหน
7. **`exports/pre-import` (PDPA) ย้ายด้วยหรือไม่ / เก็บที่ไหน?** และ #363 offsite ต้องเสร็จก่อน cutover หรือไม่ (แนะนำ: ใช่)
8. **งบและสำรอง:** อนุมัติ ฿10,000–20,000 หรือไม่? ซื้อ Pi สำรองตัวที่สองหรือไม่? 8 GB หรือ 16 GB?
9. **UPS แบบไหน:** UPS ภายนอก (แนะนำ) หรือ UPS HAT?
10. **เมื่อไรจึงเริ่ม** — หลังส่งงานอย่างเดียวหรือ? ช่วง freeze นี้มี exception ไหมสำหรับงาน CI multi-arch (ซึ่งทำก่อนซื้อฮาร์ดแวร์ได้ และไม่แตะ production)
11. **GitHub:** ใช้ environment `demo` ต่อ (ย้าย runner label) หรือสร้าง environment ใหม่ที่มี required reviewer?

### สิ่งที่ยืนยันไม่ได้ (รวมศูนย์)

* ราคาไทยของเกือบทุกรายการ (มีเพียง RS Thailand/Newegg Thailand สำหรับบอร์ด ซึ่งอาจเก่า) — ทุกช่วงราคาเป็นประมาณการ
* ว่า sharp prebuilt `linuxmusl-arm64` ใช้ได้บน Cortex-A76/ARMv8.2: เอกสารไม่ระบุ baseline (ต้องทดสอบจริง)
* ว่า runner `ubuntu-24.04-arm` ใช้ได้ใน org นี้โดยไม่ต้องตั้ง runner group; ชื่อไฟล์/sha256 ของ self-hosted runner arm64
* ค่า `BOOT_ORDER` ที่ถูกต้องสำหรับ NVMe-first; ขนาด SSD ที่ M.2 HAT+ รับ; UPS HAT ซ้อนกับ M.2 HAT+ ได้หรือไม่; NUT กับรุ่น UPS
* ชื่อ volume จริงบน mob04 (`srisurart-pos_<name>`); ว่า device token เดิมใช้ได้กับ origin ใหม่ใน PWA/APK; ว่า swap ของ Ubuntu Server บน Pi ตั้งไว้หรือไม่
* ว่า arm64 images "รันถูกต้อง" จริง — ตรวจแค่ว่ามี platform ใน manifest list (2026-10-10)

---

## 8. ประมาณการงาน (คร่าว ๆ ต่อเฟส)

> หน่วย = วันทำงานของคนเดียว (รวม review/CI รอ); ไม่รวมรอซื้อของ/รอเจ้าของ · **ประมาณการหยาบ ไม่ใช่การรับประกัน**

| เฟส | งาน | วัน | ทำก่อนซื้อ/ตัดสินใจได้ไหม |
|---|---|---|---|
| 0 | เจ้าของตัดสินใจคำถาม 1–11 + งบ + สั่งของ | (รอ) | — |
| 1 | multi-arch CI: `build-image` matrix arm64 + manifest merge, `build-web` buildx, Trivy ต่อ arch, smoke ต่อ arch, `verify-ghcr-tags.sh` เช็ค platform, ทดสอบ `sharp` (ต่อจากงาน Alpine libvips) | 3–5 | **ได้** (ไม่ต้องมี Pi) |
| 2 | ปรับ runner script (arch + ชื่อ), `certgen.sh` SAN ผ่าน env + แก้ `certgen.test.sh`, inventory/host vars, แก้ doc `07_CICD_DEPLOY.md`/ADR-0013 addendum | 2–3 | ได้ |
| 3 | ประกอบ Pi (EEPROM, NVMe boot, Ubuntu), provision, runner, deploy SHA เดียวกับ mob04 | 1–2 | หลัง Pi มาถึง |
| 4 | ซ้อมย้ายข้อมูลจากสำเนา backup, ทดสอบ sharp/รูป, ซ้อมไฟดับ, ซ้อม rollback, วัด RSS/k6 (ถ้าเลือก) | 2–4 | หลัง Pi |
| 5 | ตั้ง offsite backup (#363: เลือก protocol, พิสูจน์เส้นทาง, ติดตั้ง rclone, upload จริง, restore จริง) | 2–4 | แยก — เป็นเงื่อนไขก่อน cutover |
| 6 | build/แจก APK ใหม่, enrol เบราว์เซอร์, คู่มือร้าน | 1–2 | ช่วง cutover |
| 7 | Cutover (หน้าต่างปิดร้าน) + ตรวจ + สังเกต 14 วัน | 0.5 วัน + 14 วัน | — |
| รวม | | **ประมาณ 11–20 วันทำงาน** (ไม่รวมรอ) | |

---

## ภาคผนวก: แหล่งอ้างอิง (เว็บ — เข้าถึง 2026-10-10)

* Pi 5 specs/อุปกรณ์เสริม: https://www.raspberrypi.com/products/raspberry-pi-5/ · M.2 HAT+: https://www.raspberrypi.com/documentation/accessories/m2-hat-plus.html
* ราคา Pi: https://www.cnx-software.com/2025-12-01/raspberry-pi-5-1gb-launched-for-45-most-other-pi-4-5-models-get-a-price-increase · https://www.notebookcheck.net/Raspberry-Pi-5-now-costs-up-to-205-due-to-RAM-crisis.1218213.0.html · https://th.rs-online.com/web/p/raspberry-pi/0219255?gb=s
* NVMe boot: https://www.jeffgeerling.com/blog/2023/nvme-ssd-boot-raspberry-pi-5
* Ubuntu บน Pi: https://ubuntu.com/download/raspberry-pi · https://ubuntu.com/hardware/docs/boards/how-to/ubuntu_supported/raspberry-pi/
* Docker บน Pi OS 64-bit: https://docs.docker.com/engine/install/raspberry-pi-os.md
* GitHub arm64 runners: https://github.blog/changelog/2025-01-16-linux-arm64-hosted-runners-now-available-for-free-in-public-repositories-public-preview/ · https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/
* sharp: https://sharp.pixelplumbing.com/install/ · https://github.com/lovell/sharp-libvips
* UPS HAT: https://www.waveshare.com/wiki/UPS_HAT_(E) · https://www.cnx-software.com/2024/08/03/waveshare-ups-hat-e-for-raspberry-pi-5-4-3b-takes-four-21700-lithium-batteries-supports-usb-pd-3-0/
* Tailscale: https://tailscale.com/pricing/faq · Cloudflare Tunnel (บทความบุคคลที่สาม): https://flaviocopes.com/cloudflare-tunnel/
