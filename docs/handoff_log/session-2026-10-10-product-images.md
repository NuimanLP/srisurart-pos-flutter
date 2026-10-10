# Handoff — รูปสินค้าบนการ์ดหน้าขาย + backup ร้านเป็น ZIP: `main` = `e77356f` deploy ขึ้น `mob04` + APK (2026-10-10)

**วันที่:** 2026-10-10 · **สถานะ:** deploy แล้ว (ตรวจ `.current_sha` ผ่าน SSH เอง) · owner ยกเลิก freeze แล้ว ("ยกเลิก เราจะกลับมาพัฒนาละ") และสั่ง "approved all the way" + "approve deploy เอาให้เสร็จเลย ถ้ามีปัญหาอะไรก็แก้ให้เสร็จ"
**ต่อจาก:** [`session-2026-10-10-qr-payment-accounts.md`](session-2026-10-10-qr-payment-accounts.md)
**วิธีตรวจ:** SHA/PR/run id จาก `gh` · ฝั่ง VM ตรวจเองผ่าน `ssh mob04` (user `cloud`) · **ยังไม่มีใครอัปโหลดรูปจริงผ่านแอปบน `mob04`** (ทดสอบการเสิร์ฟ `/img/` ด้วยไฟล์ทดสอบที่เขียนแล้วลบทิ้ง)

## 1. สรุปสั้น
- owner ขอ: รูปสินค้าบนการ์ดหน้าขายทุกใบ (layout ตามรูปตัวอย่างที่ owner ส่ง) · หนึ่งรูปต่อสินค้า · **owner เท่านั้น** อัปโหลด/ลบ · URL สาธารณะที่เดาไม่ได้ (ไม่ต้อง login) · รูปต้องอยู่ใน backup/import ของเจ้าของร้าน → **ZIP**
- orchestrator: สัญญา → Opus server lane + Opus client lane (worktree แยก) → รวม `feat/product-images` → Sonnet `/scrutinize` (server/deploy) + `/code-review` (client/seam) → Opus แก้ S1–S6, C1–C7 → Sonnet docs pass
- PR #680 (`feat/product-images` → `develop`, squash) = `748d8b2` · head `cf8f712` == `headRefOid`
- PR #681 (`develop` → `main`, merge commit) = `ac9d4dd` → 🔴 **deploy ล้ม + rollback อัตโนมัติ** (run `38063244805`, §5)
- PR #682 (`fix/sharp-baseline-cpu` → `develop`, squash) = `632a26e` · PR #683 (`develop` → `main`, merge commit) = **`e77356f`** · `bedd328` ยังเป็น ancestor · merge base เดียว
- deploy run `38066101954` (approve โดย Claude ตามคำสั่ง owner) · log `running=ef07e27… release=e77356f…`, migration task รัน, `failed=0` · run คู่ `38066068378` ข้าม (image ยังไม่ขึ้น GHCR) · ไม่มี run เก่าค้าง
- APK: run `38066427603` → §8

## 2. Server
- migration **`1788652805100-ProductImageKey`**: `products.image_key TEXT NULL` + CHECK `^[0-9a-f]{32}$` + partial index (ใช้เช็ก orphan) · เพิ่มอย่างเดียว · RLS ไม่เปลี่ยน · **Postgres ยังเป็น 30 ตาราง** · migration นี้รันบน `mob04` ไปตั้งแต่รอบ `ac9d4dd` ที่ rollback (คอลัมน์ว่าง โค้ดเก่าไม่อ่าน — ไม่มีผล)
- `PUT /api/v1/products/:id/image` — owner เท่านั้น (`403 OWNER_ONLY`) · body ดิบ `image/jpeg|png|webp` ≤ 3 MB อ่านเฉพาะหลัง verify token owner (`app.setup.ts`) · fingerprint idempotency = sha256 ของไบต์ · sharp: sniff magic bytes, `failOn:'error'`, เพดาน 24 MP, auto-orient, ตัด metadata → `<tenantId>/<key>_t.webp` (256) + `_p.webp` (1024) เขียน temp+rename · key = 32 hex แรกของ sha256(preview) · งาน sharp ทำ**ก่อน** claim (ข้อยกเว้นที่ pin ใน `idempotency-routes.spec.ts`)
- `DELETE /api/v1/products/:id/image` — owner เท่านั้น, idempotent
- ลบไฟล์เก่า: **หลัง commit เท่านั้น**, เมื่อไม่มีสินค้าใช้ key นั้น **และไฟล์เก่ากว่า `ORPHAN_GRACE_MS` 10 นาที** (กัน race กับ upload รูปเดียวกันที่กำลัง commit) · upload ที่ถูกปฏิเสธลบไฟล์ที่ตัวเองเพิ่งสร้างทันที
- volume `product-images` (api/worker rw `/app/product-images`, nginx ro `/srv/product-images`) · nginx `location ^~ /img/` regex เข้ม, GET/HEAD, `Cache-Control: public, max-age=31536000, immutable`, `nosniff`, ไม่มี autoindex · `nginx-img.test.sh` รัน nginx จริงใน job `nginx-check`
- export (owner + platform) เป็น **ZIP** (`data.json` + `images/<key>.webp`) · import รับ `.zip` (≤ 200 MB, stream ลงดิสก์, nginx ขยาย limit เฉพาะ 2 location ของ import, Node `requestTimeout` 15 นาที) หรือ `.json` เดิม (10 MB) · ZIP: whitelist (`data.json`, `images/<32hex>.webp` — อย่างอื่นปฏิเสธทั้งไฟล์), ห้าม path สัมบูรณ์/`..`, ≤ 20,000 entry, ≤ 1 GB หลังคลาย (ตรวจขนาดจริง), ≤ 3 MB ต่อรูป, ห้าม encrypted/ชื่อซ้ำ · รูปที่ import ผ่าน pipeline sharp ใหม่ (key เปลี่ยนหลัง backup→restore) · code ใหม่ `400 BACKUP_ZIP_INVALID`
- `backup-db.sh` เก็บ volume เป็น `pos_images_<ts>.tar.gz` + `.sha256` (`.partial`+`mv`, prune/offsite เดียวกัน) · **`restore-db.sh` ยังไม่กู้รูป**
- pre-import ZIP ของ replace import มีรูปทุกรูป และไม่ถูกลบอัตโนมัติ (PDPA — owner ตัดสิน)

## 3. Client
- Drift **v15** `Products.imageKey` · `TableMigration` ของ v7 ระบุคอลัมน์ใหม่ (ไม่งั้น DB ก่อน v7 อัปเกรดไม่ผ่าน) · v15 ลบ sync cursor ของ `products` → เครื่องที่อัปเดตดึงสินค้าใหม่ทั้งหมดหนึ่งรอบ (ได้ key รูปที่มีอยู่) · stock guard ไม่เปลี่ยน · หลัง upload เขียนเฉพาะ `imageKey` · Drift ยัง 27 ตาราง
- `ProductImage`: `Image.network` ผ่าน `HttpOverrides` ของ `installPosTrust()` = CA เดียวกับ `ApiClient` · ไม่มี `badCertificateCallback` · `product_image_trust_test` (HTTPS จริง, ต้องมี `openssl`): CA ของเราโหลด, CA อื่นถูกปฏิเสธ → placeholder · ไม่ใช้ `cached_network_image` (Android โหลดรูปใหม่หลังเปิดแอปใหม่; รูปย่อ ~8 KB)
- การ์ดหน้าขาย: รูป 120 px บน (ไม่มี/โหลดไม่ได้ = ไอคอน), ป้ายหมวดซ้ายบน, ⭐ ขวาบน (`Key('fav-star-<id>')`, 40 px), ปุ่มดูรูปขวาล่าง (ไม่หยิบใส่ตะกร้า) → dialog ซูมได้ รูปเต็มขนาด · การ์ดสูง 288 px · ไม่ล้นที่ 390/1280 สว่าง/มืด
- หน้าสินค้า: owner เพิ่ม/เปลี่ยน/ลบรูป (ย่อ ≤ 1600 px เป็น JPEG q85 ด้วย package `image` ผ่าน `compute`; EXIF orientation ตรวจแล้วว่า Skia จัดการ) · ออนไลน์เท่านั้น · `PendingWrites` · ข้อความไทยผ่าน `posExceptionFromApi`
- ตั้งค่า → สำรอง/กู้คืน: backup ดาวน์โหลด `.zip` จาก export job ของ server (`ApiClient.getBytes`) · import รับ `.zip`/`.json` (ตรวจ ZIP จาก magic bytes `PK\x03\x04`, ส่งดิบด้วย `ApiClient.sendBytes`)
- Drift-only build: ไม่มีรูป (placeholder), backup `sa_*` เดิม

## 4. ตรวจบน `mob04` หลัง deploy (2026-10-10 ~16:06 UTC)
- `/opt/pos/.current_sha` = `e77356f582a4b110f26b14e7135acb369f4de5d9` · `/health/ready` 200 · api-1/2/3 healthy บน image `e77356f`
- `docker exec … require('sharp')` ใน api-1 และ worker → libvips **8.18.7**
- volume `srisurart-pos_product-images` มีแล้ว เจ้าของ uid 1000 (node) · nginx เห็น `/srv/product-images`
- `/img/`: ไฟล์ทดสอบ (tenant ปลอม, เขียนผ่าน api-1 แล้วลบทิ้ง) → 200 `image/webp`, `cache-control: public, max-age=31536000, immutable`, `x-content-type-options: nosniff` · POST = 403 · ไม่มีไฟล์ = 404 · list โฟลเดอร์ = 404 · `../` ถูก nginx ยุบแล้วตกไปหน้า SPA (ไม่ได้ไฟล์ระบบ) · `%2e%2e` = 400
- **`backup-db.sh` ติดตั้งด้วยมือแล้ว** (CD ไม่อัปเดต `/opt/pos/scripts`): sha256 `e2fc4c39…` = `origin/main`, สำเนาเก่า `/opt/pos/scripts/.backup-db.sh.prev-ef07e27` · รันในสภาพ cron (`env -i`, เป็น `deploy`, cwd `/home/deploy`) → rc 0, `pos_backup_20261010_160755Z.sql.gz` (269K) + `pos_images_20261010_160755Z.tar.gz` (ยังว่าง — ไม่มีรูป) ผ่าน `gzip -t` + sha256, ไม่มี `.partial`, `::warning::` offsite ตามคาด (#363 parked) · cron 03:00 รอบแรกที่มีรูป = 2026-10-11

## 5. 🔴 deploy แรกล้ม: CPU ของ `mob04` ต่ำกว่า x86-64-v2
- run `38063244805` (`ac9d4dd`): api-1 `unhealthy` ครบทุก retry → `pos-deploy` rollback ไป `ef07e27` อัตโนมัติ (`failed=0` รอบ rollback) · ร้านไม่หยุด
- สาเหตุ (รัน image แยกบน VM): `Could not load the "sharp" module using the linuxmusl-x64 runtime — Unsupported CPU: Prebuilt binaries for Linux x64 require v2 microarchitecture` · `/proc/cpuinfo` = `QEMU Virtual CPU version 2.5+`, ไม่มี popcnt/sse4_1/sse4_2/ssse3 · CI ไม่เจอเพราะ runner ของ GitHub CPU ใหม่
- libvips ของ Alpine 3.24 (8.18.2) ใช้ไม่ได้: sharp 0.35.5 ต้อง `8.18.7+` (`src/common.h`) และ 8.18.2 มี CVE ที่ GHSA-f88m-g3jw-g9cj แก้
- แก้ (PR #682): `server/Dockerfile` build **libvips 8.18.7** จาก tarball (sha256 pin) ด้วย flag baseline ของ Alpine เฉพาะ jpeg/png/webp/exif/lcms/zlib (ไม่มี SVG/HEIF/TIFF/PDF/GIF) · compile sharp กับมันด้วย node-gyp (dev deps `node-addon-api 8.9.2`, `node-gyp 12.4.0`) · ลบ `@img/sharp-*` prebuilt ทั้งหมด · runtime เพิ่มเฉพาะ shared lib ที่ link จริง
- กันซ้ำ: `server.yml` `build-image` รัน `server/docker/sharp-check/check.cjs` ใน image ใต้ `qemu-x86_64 -cpu qemu64` ก่อน Trivy/push (pipeline จริงจาก `dist/`, ปฏิเสธ JPEG ขาด + >24 MP, ล้มถ้ามี prebuilt) · negative control: sharp prebuilt ปกติตาย `Illegal instruction` ใต้ `qemu64` · ขั้นนี้ผ่านบน Actions แล้วใน Server CI ของ `e77356f`
- ก่อน merge ลอง image บน `mob04` จริง (`docker load` แยก ไม่แตะ stack): `sharp 0.35.5 libvips 8.18.7` / `sharp check OK` แล้วลบ image ทดสอบออก
- Trivy ไม่ติดตาม libvips ที่ build เอง → ต้องอัปเวอร์ชันเองเมื่อมี CVE
- PR #682/#683 merge ด้วย auto-merge (pin `--match-head-commit`, ไม่มี agent push ค้าง) เพราะ owner ไปนอนและสั่งให้ทำให้จบ

## 6. ข้อความไทยใหม่ — `agent ร่าง` รอ owner รับรอง
- error: `PRODUCT_IMAGE_INVALID` `ไฟล์รูปไม่ถูกต้อง กรุณาใช้รูป JPG, PNG หรือ WebP` · `PRODUCT_IMAGE_TOO_LARGE` `รูปใหญ่เกิน 3 MB` · `BACKUP_ZIP_INVALID` `ไฟล์สำรอง (.zip) ไม่ถูกต้อง — <เหตุผล>` · `OWNER_ONLY` บน route รูป `เฉพาะเจ้าของร้านเท่านั้นที่เปลี่ยนรูปสินค้าได้`
- หน้าขาย: `มีสินค้า` · `ดูรูป` · `ปิด`
- หน้าสินค้า: `รูปสินค้า` · `เลือกรูป` · `เปลี่ยนรูป` · `ลบรูป` · `ลบรูปสินค้า?` · `ลบรูปของ "<name>" ออก การ์ดสินค้าจะแสดงเป็นไอคอนแทน` · `ลบ` · `ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะเปลี่ยนรูปสินค้าได้`
- backup/import: `ไฟล์ใหญ่เกินไป (เกิน 200 MB) — นำเข้าไม่ได้` · `ต้องใช้เครื่องที่ลงทะเบียนแล้วจึงจะส่งออกข้อมูลได้` · `สร้างไฟล์สำรองไม่สำเร็จ กรุณาลองใหม่` · `การเตรียมไฟล์สำรองใช้เวลานานเกินไป กรุณาลองใหม่อีกครั้ง` · `กำลังเตรียมไฟล์สำรอง (ข้อมูลและรูปสินค้า)… กรุณาอย่าปิดหน้านี้` · `รองรับไฟล์ .zip หรือ .json ที่ส่งออกจากระบบนี้เท่านั้น` · `ไฟล์: <name> (<x.x> MB) · ข้อมูลและรูปสินค้า` · `⬇ ดาวน์โหลดไฟล์ backup (.zip)`
- รวมถึงข้อความใหม่ในคู่มือ SOP (`01`/`02`/`04`) · แถวใน `02 §8`/`§8.1`/`§8.1.1`

## 7. ทดสอบ
- client: `dart analyze` สะอาด · `flutter test` **1763** ผ่าน (ใหม่: `checkout_product_card_test`, `product_image_editor_test`, `product_image_repository_test`, `product_image_trust_test`, `schema_v15_migration_test`)
- server: lint/typecheck สะอาด · unit **796** · e2e product-images/backup/owner-import 24/24 ในเครื่อง · CI #680–#683 เขียวทั้งหมด รวม `integration` และ `drift codegen is up to date`
- `backup-db.test.sh` 34 ok · `nginx-img.test.sh` 23 ok
- gitleaks: ค่า key ทดสอบ 32 hex (`0123…cdef`) ถูกจับเป็น `generic-api-key` → เปลี่ยนเป็นค่า entropy ต่ำ (`aaaaaaaabbbbbbbbccccccccdddddddd`) และ squash branch ก่อน merge · **ใช้ค่า entropy ต่ำในเทสเสมอ**

## 8. APK
- run `38066427603` (`main` `e77356f`) → prerelease [`apk-e77356f`](https://github.com/NuimanLP/srisurart-pos-flutter/releases/tag/apk-e77356f) (`srisurart-pos-e77356f.apk`, ~77 MB, API build, key เดิม) · มีการ์ดรูปสินค้า + ตัวแก้รูป + backup ZIP · ต้องติดตั้งทับ APK เดิม (Drift v14→v15 อัปเกรดเอง และดึงสินค้าใหม่ทั้งหมดหนึ่งรอบ)

## 9. ยังค้าง / ข้อควรรู้
- ข้อความไทย §6 = `agent ร่าง` รอ owner รับรอง
- `restore-db.sh` ไม่กู้ `pos_images_*.tar.gz` · backup ทั้งหมดยังอยู่บน VM เดียว (#363 parked)
- หน้าต่างแก้รูปหา URL ครั้งเดียวต่อการเปิด · session ที่ค้างจากก่อนมี AppMeta `tenant_id` ต้อง login ใหม่ถึงเห็นรูป (ทางแก้ = ใช้ tenant id จาก token — owner ตัดสิน)
- ไม่มี client-request fixture ของ `PUT` แบบไบต์ (harness บันทึกแต่ JSON) · replay `PUT` เก่าหลังมีรูปใหม่อาจได้ key เก่า (pull รอบหน้าแก้)
- cache รายการสินค้าเดิมอาจยังไม่มี `imageKey` ได้ถึง 5 นาทีหลัง deploy
- ยังไม่มีใครลองอัปโหลดรูปจริงผ่านแอป / import ZIP จริงบน `mob04`
- แผนย้ายไป Raspberry Pi 5: [`docs/research/pi5-migration-plan.md`](../research/pi5-migration-plan.md) — แผนเท่านั้น owner ยังไม่ตัดสินใจ (คำถาม 11 ข้อใน §7 ของแผน)
- โฟลเดอร์ worktree ค้างบนดิสก์ (ลบไม่ได้ "Directory not empty", ไม่ได้ลบเอง): `agent-a05cc7211d87708d7`, `pi-combine`, `agent-a5c18f90cf27c2e6e` · โฟลเดอร์ `agent-*` เก่าอีก ~60 จากเซสชันก่อน
- คำถาม bank API / ตรวจสลิปจาก handoff ก่อนหน้ายังเปิดอยู่
