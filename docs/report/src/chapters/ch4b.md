## ผลการพัฒนาฝั่งเซิร์ฟเวอร์

### ภาพรวมของฝั่งเซิร์ฟเวอร์ เฟส 1

ผลลัพธ์ของเฟส 1 คือเซิร์ฟเวอร์ NestJS [1] บน PostgreSQL ที่รับการเขียนข้อมูลธุรกรรมทั้งหมดของร้าน ได้แก่ การขาย การคืนสินค้า การรับสินค้าเข้าตามใบสั่งซื้อ และกะการขาย โดยย้ายกฎความถูกต้องของข้อมูลจากฝั่ง Dart มาบังคับที่ฝั่งเซิร์ฟเวอร์ตามโครงสร้างโมดูลในตารางที่ {tab:modules} ขนาดของโค้ดและชุดทดสอบสรุปไว้ในตารางที่ {tab:progress-stats} ท้ายบท ส่วนตารางที่ {tab:backend-summary} สรุปองค์ประกอบสำคัญคู่กับไฟล์ทดสอบที่เป็นหลักฐาน

TABLE: สรุปองค์ประกอบสำคัญของฝั่งเซิร์ฟเวอร์และหลักฐานการพิสูจน์ {#tab:backend-summary}
| องค์ประกอบ | หน้าที่ | หลักฐาน |
|---|---|---|
| RLS และคีย์ผสม `(tenant_id, id)` | แยกข้อมูลรายร้านในระดับฐานข้อมูล | `cross-tenant-read.e2e-spec.ts` (25 ตาราง + 12 จุดปลายทาง HTTP) |
| `runTx` / `runIdempotent` | ธุรกรรมในตัวจัดการคำขอ และการกันการเขียนซ้ำ | สเปกสถาปัตยกรรม 3 ไฟล์, `tx-hold-measure.e2e-spec.ts` |
| เพดานเวลาคอมมิต 25 วินาที | กันธุรกรรมค้างยาว | `tx-ceiling.e2e-spec.ts` |
| บทบาทอุปกรณ์ `pos` / `backoffice` | จำกัดสิทธิ์การเขียนบิลตามเครื่อง | `security.e2e-spec.ts` |
| จำกัดอัตราต่อร้านบน Redis | กันร้านหนึ่งกินทรัพยากรร้านอื่น | `rate-limit.e2e-spec.ts`, `rate-limit-pool.e2e-spec.ts` |
| ระนาบแพลตฟอร์ม | สร้างร้านและจัดการเครื่องโดยไม่แตะ psql | `platform.e2e-spec.ts`, `platform-cli.e2e-spec.ts` |
| `POST /sync/push` | เล่นซ้ำงานออฟไลน์ของอุปกรณ์ | `sync-push.e2e-spec.ts`, `sync-push-fixtures.e2e-spec.ts` |
| คิวงาน BullMQ และ Bull-Board | ส่งออกข้อมูลร้านและงานตามเวลา | `queue.e2e-spec.ts`, `worker-jobs.e2e-spec.ts` |

### การแยกข้อมูลรายร้าน

การพิสูจน์ว่า RLS [2] ทำงานจริงอยู่ในไฟล์ `server/test/cross-tenant-read.e2e-spec.ts` ซึ่งตรวจครบทั้ง 25 ตารางที่มีข้อมูลรายร้าน และทดสอบผ่าน HTTP อีก 12 จุดปลายทาง โดยทุกกรณีต้องได้ 0 แถวหรือสถานะ 404

ระหว่างการตรวจโค้ดทั้งระบบพบข้อบกพร่องสองข้อใน migration ของตาราง `owner_review_items` ข้อแรกคือนโยบาย RLS ไม่ห่อค่าตัวแปรเซสชันด้วย `NULLIF(…, '')` ทำให้เมื่อค่าว่างเกิดข้อผิดพลาดและตอบ HTTP 500 แทนศูนย์แถว ข้อที่สองคือคีย์นอกที่ตั้ง `ON DELETE SET NULL` ทำให้ `tenant_id` ซึ่งเป็น NOT NULL ถูกตั้งเป็นค่าว่างไปด้วย ทั้งสองข้อแก้เมื่อวันที่ 25 กันยายน พ.ศ. 2569 ด้วย migration ใหม่ `1788652804200-OwnerReviewItemsFixes.ts` และพิสูจน์ใน `server/test/schema.e2e-spec.ts` โดยไม่แก้ migration ที่ถูกใช้งานไปแล้ว ปัจจุบันมี migration ทั้งหมด 20 ไฟล์

### จุดเชื่อมธุรกรรม (transaction seam) และ idempotency

การย้ายธุรกรรมจาก middleware มาอยู่ใน handler ตามกติกาในบทที่ 3 แบ่งเป็นหกชิ้นงาน ซึ่งรวมเสร็จครบเมื่อวันที่ 15 กันยายน พ.ศ. 2569 การวัดด้วย `tx-hold-measure` หลังย้ายการตรวจ PIN ออกจากธุรกรรม แสดงว่าธุรกรรมที่ยาวที่สุดลดจากราว 101–131 มิลลิวินาทีเหลือราว 14–22 มิลลิวินาที และเวลาตอบเลิกเพิ่มเป็นขั้นบันไดตามจำนวนคำขอพร้อมกัน สเปกสถาปัตยกรรมสามไฟล์ (`tenant-door.spec.ts`, `tenant-wrapper.spec.ts` และ `idempotency-routes.spec.ts`) ตรวจโครงสร้างของโค้ดว่าไม่มีเส้นทางเขียนใดหลบเลี่ยงจุดเชื่อมนี้ แต่มีจุดบอดหนึ่งข้อ คือเส้นทางเขียนที่ไม่ได้อ้างสิทธิ์ idempotency เลยจะไม่ปรากฏในสเปกทั้งสามไฟล์ จึงยังต้องอาศัยการทบทวนโดยคน

ในเชิงพฤติกรรม ระบบรับประกันสิ่งต่อไปนี้ซึ่งมีการทดสอบรองรับตามตารางที่ {tab:dod} การขายที่สต็อกไม่พอหลายบรรทัดตอบข้อความภาษาไทยครบทุกบรรทัดในคำตอบเดียว การขายพร้อมกัน 200 คำขอบนสินค้าที่มี 50 ชิ้นได้บิลสำเร็จ 50 ใบพอดี (วัดบน VM สาธิตเมื่อ 15 กันยายน พ.ศ. 2569 ได้ 201 จำนวน 50 ครั้ง 409 จำนวน 150 ครั้ง และ 5xx ศูนย์ครั้ง) และสภาวะแข่งกัน (race condition) ของสามคำขอบนสินค้าตัวเดียว 200 รอบไม่มีการสูญหายของการอัปเดต นอกจากนี้การนำเข้าสแนปช็อตข้อมูลจริงของร้านผ่านเกณฑ์ตรวจ 44 ข้อ (#185 เมื่อ 17 กันยายน พ.ศ. 2569) โดยไฟล์ที่นำเข้าให้ยอดขาย 33,700 บาทและสต็อกรวม 191 ชิ้น ระบบนำเข้าตรวจข้อมูลก่อน (pre-flight) แล้วจึงปรับค่า เพราะการบีบค่า (clamp) บนข้อมูลที่ยังไม่ตรวจจะเปลี่ยนความเสียหายที่เห็นชัดให้กลายเป็นความเสียหายเงียบ

### ระนาบผู้ดูแลแพลตฟอร์ม

การทดสอบ `platform.e2e-spec.ts` ครอบคลุมวงจรเต็มผ่าน HTTP คือสร้างร้าน เข้าสู่ระบบเป็นเจ้าของ สร้างสินค้า ลงทะเบียนเครื่อง `pos` เข้าสู่ระบบบนเครื่องนั้น เปิดกะ และขายจริง ตั๋วงานหลัก #443 มีโค้ดที่รวมแล้วเมื่อ 27 กันยายน พ.ศ. 2569 ได้แก่ เครื่องมือบรรทัดคำสั่งของแพลตฟอร์ม การออกรหัสลงทะเบียนเครื่องใหม่ รหัสผ่านชั่วคราวของเจ้าของร้านพร้อมบังคับเปลี่ยน และแดชบอร์ดเว็บ `platform-ui` การจำกัดเส้นทาง `/api/v1/platform/` สองชั้น (Nginx และแอปพลิเคชัน) พิสูจน์แล้วว่าได้ 403 ทั้งสองชั้นบนเครื่อง `mob04` เมื่อ 30 กันยายน พ.ศ. 2569 ตั๋ว #443 ยัง **ไม่ปิด** เพราะเกณฑ์ข้อ "เฉพาะ `bootstrap:admin` เท่านั้นที่สร้างผู้ดูแลได้" ขัดกับการซิงก์ผู้ดูแลจากตัวแปร `PLATFORM_ADMINS` ที่เจ้าของโครงงานรับรองแล้ว และยังมีคำถามที่รอเจ้าของโครงงานตัดสิน

### เซิร์ฟเวอร์ของเฟส 2

จุดปลายทาง `POST /sync/push` สร้างตามสเปกเฟส 2 และทดสอบฝั่งเซิร์ฟเวอร์กับไฟล์ตัวอย่างคำขอ 18 ไฟล์ชุดเดียวกับที่ฝั่งไคลเอนต์ใช้ (`sync-push-fixtures.e2e-spec.ts` และ `sync-push.e2e-spec.ts`) ทำให้สองเลนพัฒนาแยกกันได้โดยไม่ต้องรอกัน การตรวจโค้ดทั้งระบบเมื่อ 24 กันยายน พ.ศ. 2569 พบข้อบกพร่องระดับสูงสองข้อ ข้อแรกคือค่าสรุปของคำขอ (fingerprint) ของ `/sync/push` ไม่ตรงกับของเส้นทางออนไลน์ (`POST /sales` เทียบกับ `POST /api/v1/sales`) แก้ด้วย PR #413 ข้อที่สองคือเส้นทางออนไลน์เก็บวันที่จากเนื้อหาคำขอของไคลเอนต์แทนเวลาเซิร์ฟเวอร์ แก้ด้วย PR #414 ทั้งสองข้อแก้แล้วเมื่อ 25 กันยายน พ.ศ. 2569 รายงานเดียวกันพบช่องว่างของสเปกระดับกลางสามข้อซึ่งแก้แล้วเมื่อ 27 กันยายน (PR #456, #458, #469) ข้อที่ยังเหลือสรุปไว้ในบทที่ 5

## ผลการพัฒนา CI/CD

### ระดับที่ 1 ถึง 3

สามระดับแรกของ CI/CD ตามบทที่ 3 เสร็จสมบูรณ์ ประกอบด้วยเวิร์กโฟลว์ GitHub Actions [3] สามไฟล์ ได้แก่ `flutter.yml`, `server.yml` และ `deploy.yml` โดย Flutter CI ตรวจโค้ด ทดสอบ ตรวจไฟล์ที่สร้างอัตโนมัติ และตรวจว่าไฟล์ฐานข้อมูลบนเว็บตรงกับเวอร์ชันแพ็กเกจ ส่วน Server CI รันการตรวจโค้ด การทดสอบหน่วย การทดสอบรวมระบบกับ PostgreSQL และ Redis จริง และสร้างอิมเมจที่ผ่านการสแกนด้วย Trivy [4] ก่อนเผยแพร่ไปยัง GHCR อิมเมจใน Docker Compose ถูกตรึงด้วย digest (#401, PR #403) และมีการทดสอบ `compose-image-pins.spec.ts` ตรวจเรื่องนี้ การป้องกันสาขา `main` ตั้งแต่ 15 กันยายน พ.ศ. 2569 บังคับให้ผ่าน PR และผ่านงานสถานะสองรายการ

เมื่อวันที่ 1 ตุลาคม พ.ศ. 2569 มีการเพิ่มด่านความปลอดภัยสามรายการ ได้แก่ งานสแกนความลับด้วย gitleaks [5] ใน `server.yml` ที่สแกนคอมมิตที่ PR หรือ push เพิ่มเข้ามาทุกครั้งโดยไม่กรองพาธ และเป็นเงื่อนไขของ `server-ci-status` การเปิด secret scanning และ push protection ของ GitHub และการเปิด Dependabot alerts พร้อม security updates นอกจากนี้กลไกข้ามการทดสอบเมื่อ push เป็นเอกสารล้วนทำงานได้หลังแก้ข้อบกพร่องใน PR #548 ซึ่งอธิบายไว้ในบทที่ 5

เมื่อวันที่ 3 ตุลาคม พ.ศ. 2569 มีการเพิ่มด่านคุณภาพอีกชุด ฝั่ง Flutter (PR #579) ได้แก่ การทดสอบที่ตรวจว่าการเขียนข้อมูลทุกจุดในหน้าจอจัดการข้อผิดพลาด (silent-failure guard) เกณฑ์ความครอบคลุมของการทดสอบที่ลดลงไม่ได้ (coverage ratchet) และกฎ lint ที่เข้มขึ้น ฝั่งเซิร์ฟเวอร์ (PR #581) ได้แก่ ไฟล์ตัวอย่างคำขอที่ไคลเอนต์บันทึกแล้วเซิร์ฟเวอร์เล่นซ้ำในการทดสอบ e2e การตรวจว่า migration ที่มีอยู่แล้วไม่ถูกแก้ การตรวจเวิร์กโฟลว์และสคริปต์ด้วย actionlint และ shellcheck ในงานใหม่ `ci-guards` และเกณฑ์ความครอบคลุมของเซิร์ฟเวอร์ บทเรียนจากวันนั้นคือ PR #579 และ #580 ผ่าน CI แยกกัน แต่เมื่อรวมห่างกัน 29 วินาที `main` กลับเป็นสีแดง เพราะด่านใหม่ตีความการอ่านยอดเงินในลิ้นชักของ #580 ว่าเป็นการเขียน PR #582 แก้ให้ `main` กลับมาผ่าน และเอกสาร `07_CICD_DEPLOY.md` §2c (PR #588, #589) บันทึกกติกาว่าหลังด่านใหม่รวมแล้วต้อง rebase PR ที่เปิดอยู่ก่อนรวม

### ระดับที่ 4: การ deploy ด้วย Ansible และ self-hosted runner

self-hosted runner บน `mob04` ติดตั้งเมื่อ 30 กันยายน พ.ศ. 2569 และการ deploy ด้วย Ansible [6] ทำงานจริงในวันเดียวกัน ตั๋ว #67 (การติดตั้ง runner) ปิดในวันนั้นด้วยหลักฐานครบ 15 จาก 15 ข้อ หลักฐานหลักแสดงในตารางที่ {tab:deploy-evidence} ข้อที่ต้องระบุคือ เกณฑ์ย่อยด้านการจัดการ PR จาก fork พิสูจน์จากโค้ดและค่าติดตั้งเท่านั้น ไม่มีการรันจริงจาก fork และเจ้าของโครงงานยอมรับหลักฐานระดับนี้

TABLE: หลักฐานการ deploy บนเครื่อง mob04 (30 กันยายน พ.ศ. 2569) {#tab:deploy-evidence}
| กรณี | คอมมิต | ผล |
|---|---|---|
| deploy จริงครั้งแรก (อนุมัติโดย `NuimanLP`) | `e50f4fa` | Ansible `failed=0`, `.current_sha` = `e50f4fa`, `/health/ready` ตอบ 200 |
| merge เข้า `main` แล้ว deploy อัตโนมัติ | `494ace3` | deploy สำเร็จ |
| ย้อนรุ่นผ่าน `workflow_dispatch` | `e50f4fa` | สำเร็จ สคีมาไม่เปลี่ยน |
| รัน SHA เดิมซ้ำ | SHA ที่ติดตั้งอยู่แล้ว | ข้ามด้วยข้อความ "Skipping duplicate deployment" |
| readiness ล้มเหลว | – | รันเป็นสีแดง และติดตั้งรุ่นเดิมกลับอัตโนมัติ |
| สั่ง deploy จากสาขาที่ไม่ใช่ `main` | – | ถูกปฏิเสธ |
| deploy การแก้ CORS (PR #516) | `00d3488` | Ansible `failed=0` |

ประตูอนุมัติบนสภาพแวดล้อม `demo` ทำงานตามที่ออกแบบ คือทุกรันของ `Deploy (demo)` เข้าสถานะ "Waiting for review" จนกว่าผู้ตรวจที่กำหนดจะอนุมัติ ข้อควรระวังคือการรัน `Deploy (demo)` ที่เป็นสีเขียวไม่ใช่หลักฐานว่ามีการ deploy เพราะงาน `deploy` ถูกข้ามเมื่ออิมเมจของ SHA นั้นยังไม่อยู่บน GHCR โดยเวิร์กโฟลว์ยังรายงานสำเร็จ เช่น เมื่อ 30 กันยายน การตรวจ `pnpm audit` ระดับสูงทำให้ `server-ci-status` บน `main` เป็นสีแดง จึงไม่มีอิมเมจ และทุกรัน deploy ถูกข้ามจนกว่า PR #512 จะรวม หลักฐานที่ใช้ได้มีเพียงไฟล์ `/opt/pos/.current_sha` บนเครื่อง

### เวิร์กโฟลว์ Android APK และ TLS แบบ CA ส่วนตัว (3 ตุลาคม พ.ศ. 2569)

เมื่อวันที่ 3 ตุลาคม พ.ศ. 2569 มีการรวม PR สองชุดที่เปิดทางให้แอปบนอุปกรณ์ Android เชื่อมต่อเซิร์ฟเวอร์บน `mob04` ได้ ตารางที่ {tab:apk-tls} สรุปสิ่งที่รวมแล้วและสถานะจริง การออกแบบอยู่ในบทที่ 3

TABLE: งาน Android APK และ TLS ที่รวมเมื่อ 3 ตุลาคม พ.ศ. 2569 และสถานะ {#tab:apk-tls}
| งาน | สิ่งที่รวมแล้ว | สถานะ |
|---|---|---|
| PR #551 เวิร์กโฟลว์ `android-apk.yml` | สั่งรันด้วยมือ เฉพาะ `main` สร้าง APK บิลด์ API ชนิดเดียว ลงนามด้วยความลับ `ANDROID_KEYSTORE_B64` เผยแพร่เป็น pre-release `apk-<sha7>` เพิ่มสิทธิ์ `INTERNET` | รันแล้วสามครั้งเมื่อ 3 ต.ค. 2569: ครั้งแรกล้มเหลว แก้ด้วย PR #560 จากนั้นได้ pre-release `apk-e191755` และ `apk-ff84fd3` |
| PR #552 CA ส่วนตัวสำหรับ `mob04` | `certgen` รักษา CA ในวอลุ่ม `certs-ca` และออกใบรับรองเซิร์ฟเวอร์ (SAN `localhost`, `127.0.0.1`, `172.30.58.20`) Nginx เชื่อถือ playbook รัน `certgen` มีสคริปต์ทดสอบ `certgen.test.sh` แอปเชื่อถือ CA ที่ฝังมาผ่าน `HttpOverrides` | ติดตั้งบน `mob04` ตั้งแต่การ deploy `7ea0178` และคอมมิต CA ลงแอสเซตแล้ว (PR #559) |
| PR #553 เอกสาร | ปรับ `CLAUDE.md`, คู่มือการ deploy, คู่มือฝ่ายไอที และบันทึกการศึกษาให้ตรงกับสองรายการข้างต้น | รวมแล้ว (เอกสารล้วน) |

ขั้นตอนตามคู่มือ `07_CICD_DEPLOY.md` §5 "TLS" ทำครบในวันเดียวกัน การ deploy `7ea0178` (รัน `37097022857`, Ansible `failed=0`) เป็นครั้งแรกที่ `certgen` สร้าง CA บน `mob04` PR #559 คอมมิตใบรับรอง CA ลงแอสเซต โดยตรวจว่าลายนิ้วมือ SHA-256 ตรงกับ `certs-ca/ca.crt` บนเครื่อง `openssl s_client` ยืนยันใบรับรองของ `172.30.58.20` ได้ และ `HttpClient` ของ Dart ที่เชื่อถือ CA นี้เรียก `/health/ready` ได้ 200 ส่วนเวิร์กโฟลว์ APK รันครั้งแรก (รัน `37099021690`) ล้มเหลวที่ขั้นคอมไพล์ เพราะ `file_picker` รุ่น 11 ไม่คอมไพล์ซอร์ส Kotlin ของตัวเองบน Android Gradle Plugin 9 PR #560 ยกรุ่นเป็น 13.1.0 แล้วการรันครั้งถัดมาสองครั้งสำเร็จ ได้ pre-release `apk-e191755` และ `apk-ff84fd3` ข้อที่ต้องระบุตรงไปตรงมาคือ ที่เก็บโค้ดยังไม่มีบันทึกการติดตั้ง APK บนอุปกรณ์ Android จริงแล้วเข้าสู่ระบบ และ APK ล่าสุด (`ff84fd3`) สร้างก่อนการแก้ไขในหัวข้อ "การทดสอบใช้งานบนเครื่องสาธิตและการแก้ไข" ของบทนี้ จึงยังไม่มีการแก้ไขชุดนั้น

### การ deploy และการทดสอบบนเครื่องสาธิต (3–4 ตุลาคม พ.ศ. 2569)

การแก้ไขในตารางที่ {tab:uxfixes} ถูกนำขึ้น `mob04` ผ่านเส้นทาง CD ปกติ คือรวมเข้า `main` แล้วงาน `deploy` รอการอนุมัติบนสภาพแวดล้อม `demo` ก่อนจะแตะเครื่อง ตารางที่ {tab:deploy-oct} สรุปการ deploy ที่เกี่ยวข้อง รันและการอนุมัติตรวจจาก GitHub ส่วนข้อมูลบนเครื่อง (`.current_sha` และ `/health/ready`) ผู้ทดสอบตรวจผ่าน Secure Shell (SSH) และรายงานไว้ ผู้เขียนรายงานไม่ได้ตรวจซ้ำบนเครื่องเอง

TABLE: การ deploy ขึ้นเครื่อง mob04 ระหว่าง 3–4 ตุลาคม พ.ศ. 2569 {#tab:deploy-oct}
| วันที่ | คอมมิต | รัน `Deploy (demo)` | ผล |
|---|---|---|---|
| 3 ต.ค. 2569 | `7ea0178` | `37097022857` | Ansible `failed=0`, `.current_sha` = `7ea0178`, `certgen` สร้าง CA เป็นครั้งแรก |
| 3 ต.ค. 2569 | `11265b4` | `37132624209` (อนุมัติโดย `NuimanLP`) | `.current_sha` = `11265b4`, `/health/ready` ตอบ 200 |
| 4 ต.ค. 2569 | `f2827ed` | `37168492338` (อนุมัติโดย `NuimanLP`) | งาน `deploy to demo` สำเร็จ, `.current_sha` = `f2827ed`, `/health/ready` ตอบ 200 |

หลังการ deploy `11265b4` การทดสอบบนหน้าจอจริงยืนยันว่าการจ่ายเงินออก 600 บาทจากลิ้นชักที่มี 500 บาทถูกปฏิเสธด้วยข้อความ `เงินในลิ้นชักไม่พอ (มี ฿500)` และตาราง `drawer_entries` ของกะนั้นมีเพียงรายการจ่ายออก 100 บาทที่ยอมรับ ส่วนเส้นทาง 409 ของเซิร์ฟเวอร์ไม่ได้ถูกทดสอบบนเครื่อง เพราะหน้าจอหยุดคำขอไว้ก่อน จึงอาศัยการทดสอบ e2e ใน PR #580 และ #584 แทน หลังการ deploy `f2827ed` การทดสอบช่องจำนวนเงินบนหน้าจอจริงให้ผลตามที่ออกแบบ คือพิมพ์ `a1.2.3` ในช่องส่วนลดได้ `1.23` พิมพ์ `a5.0.009` ในช่องรับเงินได้ `5.00` และพิมพ์ `a5.0.05` ในช่องเงินตั้งต้นของกะได้ `5.00` นอกจากนี้ได้ทดลองเพิ่มสินค้าทดสอบแล้วลบออก โดยไม่มีการขายจริงในรอบนี้ ผลการทดสอบบนหน้าจอเหล่านี้บันทึกตามที่ผู้ทดสอบรายงาน

### การติดตามผลด้วย Grafana

การซ้อมสาธิตวันที่ 21 กันยายน พ.ศ. 2569 บันทึกแผงควบคุม Grafana [7] ขณะมีการเข้าสู่ระบบและขายจริงบนสแตกที่ทำงานอยู่ ดังรูปที่ {fig:grafana-panels} แผงแสดงอัตราความสำเร็จ ความหน่วง p95 อัตราข้อผิดพลาดแยกตามรหัสสถานะ และตัวนับการเล่นซ้ำของ idempotency ที่ Prometheus [8] เก็บจากตัวชี้วัดของเซิร์ฟเวอร์ตามการออกแบบในบทที่ 3

FIGURE: แผงควบคุม Grafana ระหว่างการซ้อมสาธิต (บันทึกเมื่อ 21 กันยายน พ.ศ. 2569) {#fig:grafana-panels} | docs/handoff_log/media/demo-rehearsal-grafana-panels.jpg

## ผลการนำระบบขึ้นใช้งานบนเครื่อง mob04 และการติดตามระบบ

### สแตกบนเครื่องสาธิต

เครื่อง `mob04` เป็น VM ของภาควิชาที่เป็นทั้งเครื่องสาธิตและเป้าหมายการ deploy ตามการตัดสินใจเมื่อ 15 กันยายน พ.ศ. 2569 ที่ให้ระบบเฟส 1 อยู่ภายในเครือข่ายของมหาวิทยาลัย สแตกประกอบด้วยคอนเทนเนอร์ตามตารางที่ {tab:containers} เครื่องดึงอิมเมจจาก `ghcr.io` ได้ตั้งแต่ 29–30 กันยายน พ.ศ. 2569 ก่อนหน้านั้นการ deploy อัตโนมัติ (CD) ซึ่งต้องดึงอิมเมจจาก GHCR ถูกไฟร์วอลล์ของคณะปิดกั้น (บทที่ 5)

ตั๋ว #343 (การ deploy จริงครั้งแรก) ปิดเมื่อ 30 กันยายน พ.ศ. 2569 ครบ 5 จาก 5 ข้อ รวมถึงการย้อนกลับด้วย Ansible ด้วยมือไปยัง `e50f4fa` ที่ได้ `failed=0` ส่วนการสาธิตแบบครบวงจร (#344) ยัง **ไม่ได้ดำเนินการ** ข้อติดขัดสรุปไว้ในบทที่ 5

### การสำรองข้อมูลและ etcd

สคริปต์ `deploy/scripts/backup-db.sh` dump ฐานข้อมูลลงใน `/opt/pos/backups/` ทุกวันเวลา 03:00 ตั๋ว #346 ปิดเมื่อ 30 กันยายน พ.ศ. 2569 หลังรันสคริปต์ในสภาพแวดล้อมแบบเดียวกับ cron สำเร็จและตรวจไฟล์ dump แล้ว ในคืนวันที่ 29 กันยายน สคริปต์ทำงานล้มเหลวและทิ้งไฟล์ว่างไว้ PR #519 จึงให้สคริปต์เขียนไฟล์ชั่วคราวแล้วเปลี่ยนชื่อเมื่อสำเร็จเท่านั้น พร้อมการทดสอบใน CI และสคริปต์ใหม่ที่ติดตั้งบน `mob04` แล้วได้ไฟล์ dump ที่ผ่านการตรวจความสมบูรณ์ ข้อควรระวังคือมีเพียง playbook `provision.yml` ที่ติดตั้งสคริปต์นี้ การ deploy ผ่าน CD ไม่ได้อัปเดตสคริปต์บนเครื่อง

ต้องระบุอย่างตรงไปตรงมาว่า **การสำรองข้อมูลยังไม่ออกนอก VM** กลไกส่งสำเนาออกนอกเครื่องผ่าน `rclone` ถูกสร้างไว้แต่ยังไม่ได้เชื่อมกับปลายทางจริง (#363 และตั๋วงานหลัก #288 ยังเปิดและถูกพักไว้จนหลังการสาธิต) หากดิสก์ของ `mob04` เสียจะสูญเสียข้อมูลของร้านสาธิต เจ้าของโครงงานรับความเสี่ยงนี้โดยรู้ล่วงหน้า และบันทึกของ cron ที่ไม่มีข้อผิดพลาดไม่ได้พิสูจน์ว่าสำเนาออกนอก VM เพราะเมื่อยังไม่ได้ตั้งปลายทาง สคริปต์จะพิมพ์เพียงคำเตือนแล้วจบด้วยรหัสสำเร็จ

ตั๋ว #365 (etcd ไม่มีการยืนยันตัวตนบน VM) ปิดเมื่อ 30 กันยายน พ.ศ. 2569 ครบ 4 จาก 4 ข้อ โดยเปิดการยืนยันตัวตนตั้งแต่การ deploy จริงครั้งแรก พิสูจน์การยืนยันตัวตนทั้งสองด้าน และยืนยันว่า `RuntimeConfigService` อ่านค่า `log_level` จาก etcd ได้

## ผลการทดสอบฝั่งเซิร์ฟเวอร์

ชุดทดสอบของเซิร์ฟเวอร์แบ่งเป็นการทดสอบหน่วย (`*.spec.ts`) ที่อยู่ข้างไฟล์ต้นทาง และการทดสอบรวมระบบ (`*.e2e-spec.ts`) ที่รันกับ PostgreSQL และ Redis จริงภายใต้ `server/test/` จำนวนที่นับเมื่อ 1 ตุลาคม พ.ศ. 2569 แสดงในตารางที่ {tab:server-tests} ตัวเลขฝั่งเซิร์ฟเวอร์นับจากบรรทัด `it(` หรือ `test(` ในซอร์ส จึงเป็นค่าประมาณที่ไม่นับกรณีที่สร้างในลูป ส่วนฝั่งไคลเอนต์แสดงทั้งจำนวนจากตัวรันและจากซอร์สเพื่อเทียบกัน

TABLE: จำนวนไฟล์และกรณีทดสอบของเซิร์ฟเวอร์และไคลเอนต์ (นับเมื่อ 1 ตุลาคม พ.ศ. 2569) {#tab:server-tests}
| กลุ่มทดสอบ | ไฟล์ | กรณีทดสอบ |
|---|---|---|
| เซิร์ฟเวอร์ — unit (`*.spec.ts`) | 54 | ประมาณ 492 (นับจากซอร์ส) |
| เซิร์ฟเวอร์ — e2e (`*.e2e-spec.ts`) | 57 | ประมาณ 655 (นับจากซอร์ส) |
| ไคลเอนต์ Flutter (`*_test.dart`) | 90 | 820 ตามตัวรัน (741 จุดนิยามในซอร์ส) |

ชุด e2e ครอบคลุมความปลอดภัยและบทบาทอุปกรณ์ การแยกข้อมูลรายร้าน ธุรกรรมและ idempotency สภาวะแข่งกันของผู้เขียนหลายราย การจำกัดอัตรา แคชและการล่มของ Redis การขาย คืนสินค้า ใบสั่งซื้อ กะ และรายงาน การนำเข้าและการสำรองข้อมูล ระนาบแพลตฟอร์ม คิวและ worker การซิงก์ และเกณฑ์ของสคีมา การรันชุด e2e เต็มเมื่อ 16 กันยายน พ.ศ. 2569 บันทึกว่าผ่าน 490 กรณีและข้าม 2 กรณีจากทั้งหมด 492 กรณี (ไม่มีกรณีล้มเหลว) ซึ่งเป็นจำนวนของชุด e2e ในวันนั้น รายงานนี้ไม่อ้างผลการรันล่าสุดที่ไม่ได้ทำซ้ำ ข้ออ้างว่าชุดทดสอบผ่านในแต่ละช่วงยึดตามสถานะ `server-ci-status` บน `main` ซึ่งเป็นผลจริงของการรันใน CI

## ตรวจสอบเกณฑ์ตรวจรับ (DoD)

เอกสาร `docs/Backend_design/03_ARCHITECTURE.md` หัวข้อ 8 กำหนดเกณฑ์ตรวจรับ (DoD) ของเฟส 1 จำนวน 17 ข้อ การนับซ้ำกับตัวทดสอบเอง (ไม่ใช่สถานะของตั๋ว) เมื่อ 22 กันยายนและอีกครั้งในการเขียนรายงานนี้พบว่า **ผ่านแล้ว 16 ข้อ และยังเปิดอยู่ 1 ข้อ** คือเกณฑ์ k6 ซึ่งผูกกับตั๋ว #380 ดังตารางที่ {tab:dod}

TABLE: สถานะเกณฑ์ตรวจรับ (DoD) ของเฟส 1 (17 ข้อ) {#tab:dod}
| ลำดับ | เกณฑ์ | สถานะ | หลักฐานหลัก |
|---|---|---|---|
| 1 | `docker compose up` ครั้งเดียวได้ Nginx + NestJS ×3 + Postgres + Redis + worker + Bull-Board | ผ่าน | #14 (6 ก.ย. 2569) |
| 2 | k6 ผ่านเกณฑ์ตาม `02_API_SCREENS.md` หัวข้อ 9 | **ยังเปิด** | ตั๋ว #380 ยังไม่มีผลวัดจริง |
| 3 | `POST /sales` พร้อมกัน 200 ครั้งบนสินค้า 50 ชิ้น ขายได้ 50 บิล สต็อก 0 | ผ่าน | #184 ส่วน `close.3` (15 ก.ย. 2569, VM สาธิต) 201×50 / 409×150 / 5xx 0 |
| 4 | อ่านข้ามร้านได้ 0 แถวทุกเคส | ผ่าน | `cross-tenant-read.e2e-spec.ts` (17 ก.ย. 2569) |
| 5 | `/health/live` ไม่แตะ DB และ `/health/ready` แตะ DB และ Redis | ผ่าน | #14 (6 ก.ย. 2569) |
| 6 | นำเข้าสแนปช็อตร้านจริงผ่านเกณฑ์ 6 ข้อใน `01_DATABASE.md` หัวข้อ 9 | ผ่าน | #185 (17 ก.ย. 2569) 44 checks |
| 7 | `redis-cache` แยกจาก `redis-queue` และ Bull-Board มี auth | ผ่าน | #14 (6 ก.ย. 2569) |
| 8 | ขายสินค้าไม่พอ 3 บรรทัดได้ข้อความไทยครบ 3 บรรทัดในครั้งเดียว | ผ่าน | `sales.e2e-spec.ts`, #20 |
| 9 | ลบลูกค้าที่มีบิลได้ 200 (soft delete) ไม่ใช่ 500 | ผ่าน | `people.e2e-spec.ts`, #17 |
| 10 | สร้างร้านใหม่ด้วย `POST /platform/tenants` แล้วเข้าสู่ระบบและขายได้โดยไม่แตะ psql | ผ่าน | `platform.e2e-spec.ts` (17 ก.ย. 2569) |
| 11 | เครื่อง `backoffice` เรียก `POST /sales` แล้วได้ 403 `DEVICE_ROLE_FORBIDDEN` | ผ่าน | `security.e2e-spec.ts`, #44 |
| 12 | ระงับร้านแล้วคำขอถัดไปถูกปฏิเสธทันที | ผ่าน | `request-context.e2e-spec.ts`, #20 |
| 13 | ระงับร้านแล้วงานค้างในคิวของร้านนั้นไม่ถูกรัน | ผ่าน | `queue.e2e-spec.ts`, #34 |
| 14 | ดับ `redis-cache` แล้วร้านที่ถูกระงับยังถูกปฏิเสธและร้านปกติยังใช้งานได้ | ผ่าน | `redis-cache-outage.e2e-spec.ts`, #383 (22 ก.ย. 2569) |
| 15 | สภาวะแข่งกันของสามคำขอบนสินค้าตัวเดียว 200 รอบ ไม่มี lost update | ผ่าน | `purchase-orders.e2e-spec.ts`, #196 |
| 16 | `owner` ปลดเครื่อง `pos` ที่มีกะเปิด: กะปิดในธุรกรรมเดียว token เดิม refresh ไม่ได้ ลงทะเบียนเครื่องใหม่แล้วขายได้ | ผ่าน | `shifts.e2e-spec.ts`, #384 (22 ก.ย. 2569) |
| 17 | `backoffice` ที่ไม่มี `deviceToken` อ่านสินค้าได้แต่ขายได้ 403 | ผ่าน | `security.e2e-spec.ts`, #196 |

เกณฑ์ข้อ 14 และข้อ 16 ได้รับการยืนยันผ่านใหม่เมื่อมีหลักฐานที่แท้จริง เพราะหลักฐานเดิมของข้อ 14 เพียงจำลอง (spy) การเรียกเมธอดของไคลเอนต์แคชแทนที่จะทำให้ Redis เข้าไม่ถึงจริง และหลักฐานเดิมของข้อ 16 สร้างโทเค็นเองแทนที่จะแลกรหัสลงทะเบียนผ่านจุดปลายทางจริง

เกณฑ์ข้อ 2 ยังไม่มีการวัด ตั๋ว #184 เดิมที่ผูกกับการวัดนี้ถูกปิดและเปิดใหม่รวมสามครั้งในสองวัน จนเจ้าของโครงงานปิดเมื่อ 21 กันยายน พ.ศ. 2569 โดยเกณฑ์ย่อยด้านการวัดยังไม่ผ่าน และตั๋ว #380 เข้ามาแทน

วิธีวัดที่ตกลงแล้วคือใช้สามเครื่องรัน k6 โดยแต่ละเครื่องอยู่ภายใต้ขีดจำกัดอัตราต่อ IP ของตัวเอง และส่งผลเข้า Prometheus ของ VM ส่วนการยกเว้น IP ของเครื่องสร้างโหลดจากขีดจำกัดอัตราถูกพิจารณาแล้วปฏิเสธ

## สรุปผลงานที่มีความก้าวหน้า

ตารางที่ {tab:progress-stats} สรุปตัวเลขภาพรวมของโครงงาน วัดเมื่อ 1 ตุลาคม พ.ศ. 2569 จากสาขา `origin/main` ด้วย `git rev-list --count`, `git ls-files` ร่วมกับ `wc -l`, `gh pr list` และ `gh issue list` จำนวนบรรทัดนับรวมไฟล์ที่สร้างอัตโนมัติที่ถูกคอมมิตไว้ จึงเป็นเพียงมาตรวัดขนาด ไม่ใช่มาตรวัดผลิตภาพ

TABLE: สถิติภาพรวมของโครงงาน (วัดเมื่อ 1 ตุลาคม พ.ศ. 2569) {#tab:progress-stats}
| รายการ | ค่าที่วัดได้ |
|---|---|
| จำนวนคอมมิตบน `origin/main` | 1,058 |
| คอมมิตแรกของที่เก็บโค้ด | 23 มิถุนายน พ.ศ. 2569 |
| Pull request ที่รวมแล้ว | 330 |
| Issue ทั้งหมดบน GitHub | 209 (ปิดแล้ว 198, เปิดอยู่ 11) |
| โค้ดไคลเอนต์ `frontend/lib/` | 120 ไฟล์ ประมาณ 65,600 บรรทัด |
| ชุดทดสอบไคลเอนต์ `frontend/test/` | 93 ไฟล์ (ไฟล์ทดสอบ 90 ไฟล์) ประมาณ 29,800 บรรทัด |
| โค้ดเซิร์ฟเวอร์ `server/src/` | 213 ไฟล์ ประมาณ 33,500 บรรทัด |
| ชุดทดสอบเซิร์ฟเวอร์ `server/test/` | 82 ไฟล์ ประมาณ 29,800 บรรทัด |
| การ deploy และโครงสร้างพื้นฐาน `deploy/` | 22 ไฟล์ ประมาณ 2,800 บรรทัด |
| เวิร์กโฟลว์ CI/CD `.github/` | 7 ไฟล์ ประมาณ 1,100 บรรทัด |
| เอกสาร `docs/` | 286 ไฟล์ (ไฟล์ข้อความ 215 ไฟล์ ประมาณ 56,200 บรรทัด ที่เหลือเป็นภาพและ PDF) |
| ตารางใน Drift (schemaVersion 13) | 26 ตาราง |
| ตารางใน PostgreSQL | 29 ตาราง จาก migration 20 ไฟล์ |
| เกณฑ์ตรวจรับ (DoD) ของเฟส 1 | 16 จาก 17 ข้อ (เหลือ k6, #380) |
| บันทึกการตัดสินใจเชิงสถาปัตยกรรม (ADR) | 13 หมายเลข (ADR-0001 ถึง ADR-0013) |

ตารางที่ {tab:members} สรุปผลงานรายบุคคล คอมมิตนับจากอีเมลผู้เขียนคอมมิตบน `main` โดยบัญชี git สามชื่อ (NuiGates, NuiGates_2456 และ Chavatik Thorarit) เป็นของสมาชิกคนเดียวกัน และบัญชี LomerAlloys สองอีเมลเป็นของสมาชิกคนเดียวกัน ส่วน PR นับด้วย `gh pr list --state merged --json author` จำนวนคอมมิตและ PR ไม่ได้สะท้อนขนาดหรือความยากของงาน และคอมมิตส่วนหนึ่งทำร่วมกับเครื่องมือช่วยพัฒนา (บทที่ 3) ตารางนี้จึงแสดงว่าใครลงมือในส่วนใด ไม่ใช่การจัดอันดับ

TABLE: ผลงานของสมาชิกแต่ละคน (นับเมื่อ 1 ตุลาคม พ.ศ. 2569) {#tab:members}
| สมาชิก (เลน) | คอมมิตบน `main` | PR ที่รวมแล้ว | ตัวอย่างงานที่ส่งมอบ (PR) |
|---|---|---|---|
| Chavatik Thorarit (NuimanLP, A) | 890 | 273 | สแตก Compose และ health (#41), migration และ RLS (#42), idempotency และเส้นทางขาย คืน ลิ้นชัก (#51, #75, #78, #84), `SyncFacade` และไฟล์ตัวอย่าง (#307), แก้เลขเอกสารและการทิ้งรายการในคิว (#483–#495), สคริปต์สำรองข้อมูล (#519) |
| LomerAlloys (B) | 53 | 15 | ระนาบผู้ดูแลแพลตฟอร์มและการสร้างร้าน (#59), การตั้งค่าและ bootstrap (#116), จัดซื้อและต้นทุนถัวเฉลี่ย (#119), แก้ฐานข้อมูลบนเว็บ (#310), `outbox_ops` และ `SyncService` (#324) |
| Pattarapon Kitcharoen (PattaraponKitcharoen, C) | 115 | 43 | JWT และบทบาทอุปกรณ์ (#57), rate limit ต่อร้าน (#77), BullMQ และ worker (#88), Ansible และ runner (#107, #348), `POST /sync/push` (#313), หน้ารอเจ้าของร้านตรวจ (#318), PIN ออฟไลน์ (#332), gitleaks (#526) |

ตั๋วงานที่เปิดอยู่ ณ 1 ตุลาคม พ.ศ. 2569 มี 11 ตั๋ว ได้แก่ ตั๋วงานหลักของเฟส 1 สองตั๋ว (#2 และ #196) ซึ่งยังเปิดอยู่ขณะที่เกณฑ์ k6 ยังไม่ผ่าน การวัดภาระ k6 (#380) การสาธิตและสเปกการสาธิตบน `mob04` (#344, #335) การสร้างร้านโดยไม่แตะ psql พร้อมคู่มือ (#338) เครื่องมือผู้ดูแลแพลตฟอร์ม (#443) การสำรองข้อมูลที่ถูกพักโดยเจตนา (#288, #363) งานที่รอเจ้าของโครงงานตัดสิน (#476) และการย้ายร้านไปใช้ระบบใหม่ (#231) ต่อมาตั๋ว #476 ปิดเมื่อ 3 ตุลาคม พ.ศ. 2569 หลังเพิ่มการแทนที่เครื่องขายที่สูญหายจากระนาบแพลตฟอร์ม (PR #561) และพิสูจน์การกู้คืนบน `mob04` จริง ตั๋วที่เปิดอยู่ ณ 4 ตุลาคม พ.ศ. 2569 จึงเหลือ 10 ตั๋ว


## __ABBREVIATIONS__
CA = Certificate Authority
APK = Android Package Kit
RLS = Row-Level Security
CI/CD = Continuous Integration / Continuous Delivery
GHCR = GitHub Container Registry
JWT = JSON Web Token
DoD = Definition of Done
RC = Receipt (เลขที่ใบเสร็จ)
CN = Credit Note (ใบลดหนี้)
ADR = Architecture Decision Record
e2e = End-to-End
VM = Virtual Machine
CORS = Cross-Origin Resource Sharing
PIN = Personal Identification Number
HTTP = Hypertext Transfer Protocol
SHA = Secure Hash Algorithm
SSH = Secure Shell

## __REFERENCES__
[1] NestJS, "NestJS Documentation," [Online]. Available: https://docs.nestjs.com/. Accessed: Oct. 1, 2026.
[2] PostgreSQL Global Development Group, "PostgreSQL Documentation: Row Security Policies," [Online]. Available: https://www.postgresql.org/docs/current/ddl-rowsecurity.html. Accessed: Oct. 1, 2026.
[3] GitHub, "GitHub Actions documentation," [Online]. Available: https://docs.github.com/en/actions. Accessed: Oct. 1, 2026.
[4] Aqua Security, "Trivy Documentation," [Online]. Available: https://trivy.dev/. Accessed: Oct. 1, 2026.
[5] Gitleaks, "gitleaks," [Online]. Available: https://github.com/gitleaks/gitleaks. Accessed: Oct. 1, 2026.
[6] Ansible Project, "Ansible Documentation," [Online]. Available: https://docs.ansible.com/. Accessed: Oct. 1, 2026.
[7] Grafana Labs, "Grafana Documentation," [Online]. Available: https://grafana.com/docs/. Accessed: Oct. 1, 2026.
[8] Prometheus Authors, "Prometheus Documentation," [Online]. Available: https://prometheus.io/docs/. Accessed: Oct. 1, 2026.

## __FACTS__
commits on origin/main 1058 -> `git rev-list --count origin/main` (2026-10-01)
first commit 2026-06-23 -> `git log --reverse --format=%cd --date=short | head -1`
330 merged PRs -> `gh pr list --state merged --limit 2000 --json number` count
209 issues, 198 closed, 11 open -> `gh issue list --state all --limit 2000 --json state`
frontend/lib 120 files 65569 lines; frontend/test 93 files 29834 lines (92 .dart + 1 JSON fixture); server/src 213 files 33506; server/test 82 files 29848; deploy 22 files 2846; docs 286 files (215 text files 56162 lines; 71 binary); .github 7 files 1089 -> `git ls-files <dir> | xargs cat | wc -l`
server unit spec files 54, e2e 57; it( cases 492 / 655 -> `find server -name "*.spec.ts"`, `grep -rE "^\s*(it|test)(\.each)?\("`
frontend tests 90 *_test.dart; 820 by runner; 741 grep definitions -> see ch4a facts
20 migration files -> `ls server/src/db/migrations`
29 PG tables, 26 Drift tables schema v13 -> CLAUDE.md
DoD 17 boxes 16 ticked 1 open -> docs/Backend_design/03_ARCHITECTURE.md:553-569; CLAUDE.md "Status"
cross-tenant 25 tables + 12 endpoints -> 03_ARCHITECTURE.md:556
200x50 race 201/409x150/5xx0 (#184 close.3) -> 03_ARCHITECTURE.md:555
import 44 checks 33,700 baht 191 pcs (#185) -> 03_ARCHITECTURE.md:558
OwnerReviewItems bugs fixed 2026-09-25 by 1788652804200-OwnerReviewItemsFixes.ts, schema.e2e-spec.ts -> CLAUDE.md
tx.0-tx.5 merged by 2026-09-15; tx hold 101-131 -> 14-22 ms -> docs/Backend_design/adr/0003-handler-scoped-migration-plan.md header
architecture specs blind spot (write route with no idempotency claim) -> CLAUDE.md "Transactions & tenancy"
#443 code merged 2026-09-27; 403 both layers on mob04 2026-09-30; open AC conflict -> CLAUDE.md "#443"
#409 PR #413, #411 PR #414 fixed 2026-09-25; MED items PR #456/#458/#469 2026-09-27; LOW item 6 open -> CLAUDE.md "Two HIGH phase-2 bugs"
#401 PR #403 digest pin; compose-image-pins.spec.ts -> CLAUDE.md; server tests
gitleaks job, push protection, Dependabot 2026-10-01 -> CLAUDE.md CI/CD section
docs-only skip fixed PR #548 -> git log 47be710 / 42b07eb
runner installed 2026-09-30; #67 15/15; run IDs 36685602814/36687687309/36688248109/36720675552/36721404240/36717963989; SHAs e50f4fa/494ace3/00d3488; fork half proven from code only -> CLAUDE.md "Still open (phase 1)"
pnpm audit blocked deploys until PR #512 -> CLAUDE.md "A red server-ci-status on main"
#343 closed 5/5; #344 not run -> CLAUDE.md
FortiGate resolved 2026-09-29/30 -> CLAUDE.md
#346 closed; 2026-09-29 run failed leaving empty .gz; PR #519 partial+mv; installed on mob04, verified run; only provision.yml installs scripts -> CLAUDE.md
#365 closed 4/4 -> CLAUDE.md
#363/#288 parked; unset remote -> ::warning:: + exit 0 -> CLAUDE.md "#363"
e2e 490/492 on 2026-09-16 -> 03_ARCHITECTURE.md:560
#184 closed by owner 2026-09-21, replaced by #380; perip exemption rejected -> CLAUDE.md "#380"
ADR files 0001-0013 -> `ls docs/Backend_design/adr`
per-member commits by author email at 42b07eb: chwathik@gmail.com 372 + NuimanLP noreply 271 + 6610110066@psu.ac.th 247 = 890; pattarapon 115; LomerAlloys 35 + 18 = 53 -> git log 42b07eb --format=%ae | sort | uniq -c
merged PRs by author: NuimanLP 273, PattaraponKitcharoen 43, LomerAlloys 15 (331 total incl. #549 after the snapshot) -> gh pr list --state merged --limit 1000 --json author
representative PRs and authors -> gh pr list --state merged --author <login> --json number,title
open issues #2 #196 #231 #288 #335 #338 #344 #363 #380 #443 #476 -> gh issue list --state open (2026-10-01)
e2e 2026-09-16: 490 passed | 2 skipped (492) -> docs/handoff_log/dod-mapping-2026-09-16.md:32
deploy run IDs (removed from table): 494ace3 run 36685602814; rollback 36687687309; same-SHA 36688248109; readiness fail 36720675552; non-main 36721404240; 00d3488 run 36717963989 -> CLAUDE.md #67
PRs #551/#552/#553 merged 2026-10-03 (03:40:47Z / 03:41:06Z / 03:51:28Z) -> gh pr view N --json state,mergedAt,title
quality gates #579 #581 #582 #588 #589; #579/#580 merged 29 s apart, main red at 2411ebf/a8a8080, fixed by #582 -> docs/handoff_log/session-2026-10-03-ux-test-drawer-ci.md; gh pr view 582
APK runs 37099021690 failure (3c090ee), 37101288734 success (e191755), 37114366754 success (ff84fd3); releases apk-e191755/apk-ff84fd3; PR #560 file_picker 13.1.0 -> gh run list --workflow android-apk.yml; gh release list; gh pr view 560
CA: 7ea0178 run 37097022857 failed=0; PR #559 fingerprint match, openssl verify 0, Dart 200 -> gh pr view 559
no repo record of APK installed on a real device -> docs/handoff_log/session-2026-10-03-apk-private-ca-backup-upload.md (step 3 "never run yet", written before runs); no later record
deploy 11265b4 run 37132624209 approved NuimanLP; .current_sha 11265b4 + health 200 verified by orchestrator ssh; live drawer ฿600 refused, one drawer_entries row out 100.00 -> session-2026-10-03-ux-test-drawer-ci.md:57-76
deploy f2827ed run 37168492338: approvals API user NuimanLP; jobs resolve release success, deploy to demo success 2026-10-04T01:38:24Z -> gh run view 37168492338; gh api .../runs/37168492338/approvals
f2827ed .current_sha + /health/ready 200 + live input results (a1.2.3->1.23, a5.0.009->5.00, a5.0.05->5.00), test product added/deleted, no sale -> reported by the orchestrating session 2026-10-04 (not independently verified; no VPN)
#476 closed 2026-10-03T06:22:11Z, live recovery evidence comment; open issues now 10 [443,380,363,344,338,335,288,231,196,2] -> gh issue view 476; gh issue list --state open (2026-10-04)
