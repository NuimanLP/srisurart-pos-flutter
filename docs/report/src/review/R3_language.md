# R3 — Thai academic writing review (language angle only)

Method: read all six chapter sources end to end, then ran counts/greps for terminology variants, repeated words,
stray combining marks, first-use acronym expansion. Result in one line: spelling is clean (no typos, no doubled
words, no stray marks; ซิงก์/คอมมิต/ไคลเอนต์/เวิร์กโฟลว์ are used uniformly), register is mostly formal. The real
problems are (a) the same concept carrying 2-4 names across chapters, (b) a handful of machine-translated
phrases, (c) acronyms used before expansion, (d) a few over-long run-on paragraphs. File names are
`chapters\chN.md`; "find" strings are exact source text.

---

## A. Terminology inconsistency (highest value)

1. [HIGH] ch1 (แผนการดำเนินงาน > โครงสร้างทีม, ~line 127), ch3 (วิธีการทำงานของทีม, ~lines 325, 333), vs ch4a/ch4b/ch5 — "ticket" has three names: **ใบงาน** (ch1 x2, ch3 x4), **ตั๋ว / ตั๋วงาน / ตั๋วแม่** (ch4a, ch4b, ch5, ~46x) and **issue** (21x). Readers of ch1/ch3 meet "ใบงาน" and later "ปิดตั๋ว" with no bridge; ch4a:5 is the only place that defines it ("ตั๋วงานบน GitHub (issue)").
   Fix: standardise on **ตั๋วงาน** and define it at first use in ch1.
   - ch1 find `เป็น 35 ใบงาน แบ่งเป็นเลน A 3 ใบ เลน B 15 ใบ และเลน C 17 ใบ` -> `เป็น 35 ตั๋วงาน (issue บน GitHub) แบ่งเป็นเลน A 3 ตั๋ว เลน B 15 ตั๋ว และเลน C 17 ตั๋ว`
   - ch1 scope table find `ใบงานส่วนใหญ่ merge แล้ว ยังไม่ปิดทั้งหมด` -> `ตั๋วงานส่วนใหญ่ผ่านการรวมโค้ดแล้ว ยังไม่ปิดทั้งหมด`
   - ch1 lane table `(3 ใบ)` / `(15 ใบ)` / `(17 ใบ)` -> `(3 ตั๋ว)` / `(15 ตั๋ว)` / `(17 ตั๋ว)`
   - ch3 find `แบ่งใบงาน 35 ใบเป็นสามเลน` -> `แบ่งตั๋วงาน 35 ตั๋วเป็นสามเลน`; `มีใบงานปลดล็อกสามใบ` -> `มีตั๋วงานปลดล็อกสามตั๋ว`; `ใบงานที่ถูกผ่าเป็นสองครึ่ง` -> `ตั๋วงานที่ถูกแบ่งเป็นสองส่วน`; `ใบงานแต่ละใบเริ่มด้วย` -> `ตั๋วงานแต่ละตั๋วเริ่มด้วย`
   - ch4a/ch4b/ch5 `ตั๋วแม่` (ch4a:88, ch4b:33, ch4b:82, ch5:61) -> `ตั๋วงานหลัก (parent issue)` on first use, then `ตั๋วงานหลัก`.
   - ch4a:5 keep the definition but move the sentence into ch1 (see item 1 first bullet); in ch4a just say `คำว่า "ปิดตั๋ว" หมายถึง ตั๋วงานมีสถานะ closed บน GitHub`.

2. [HIGH] ch1 diagram spec `evolution` (labels "ระยะที่ 1/2/3"), ch4b (ระบบหลังบ้านระยะที่ 1, เซิร์ฟเวอร์ฝั่งระยะที่ 2, ระบบระยะแรก, DoD ของระยะที่ 1), ch5 (4x) vs ch1/ch3/ch4a "เฟส 1/เฟส 2" (52x) vs ch4a/ch1 "Phase 0-6" — **three words (เฟส, ระยะ, Phase) for three different things**. The diagram calls the Flutter app "ระยะที่ 2" while ch4b/ch5 call the server's offline work "ระยะที่ 2". A reader cannot tell "ระยะที่ 2" from "เฟส 2", and "Phase 1" (data layer, ch4a table) from "เฟส 1" (server).
   Fix (a): global replace in ch4b and ch5 `ระยะที่ 1` -> `เฟส 1`, `ระยะที่ 2` -> `เฟส 2`, `ระบบระยะแรก` -> `ระบบเฟส 1`, headings `ภาพรวมของระบบหลังบ้านระยะที่ 1` -> `ภาพรวมของระบบหลังบ้านเฟส 1`, `เซิร์ฟเวอร์ฝั่งระยะที่ 2` -> `เซิร์ฟเวอร์ของเฟส 2`.
   Fix (b): in the diagram spec use `ขั้นที่ 1: เว็บแอป React + localStorage`, `ขั้นที่ 2: Flutter offline-first`, `ขั้นที่ 3: ระบบหลายร้านค้า (เฟส 1 = Architecture A)`, and `ไม่มี cutover: ร้านยังใช้ระบบขั้นที่ 2`.
   Fix (c): rename the Flutter migration stages so they stop colliding: ch4a heading `ลำดับความก้าวหน้า Phase 0 ถึง Phase 6` -> `ลำดับความก้าวหน้าของการย้ายระบบ ขั้น 0 ถึง ขั้น 6`; ch4a `การย้ายระบบแบ่งเป็นเฟสย่อย 0 ถึง 6` -> `การย้ายระบบแบ่งเป็นขั้น 0 ถึง 6 (ไม่ใช่เฟส 1-2 ของเซิร์ฟเวอร์)`; table cells `Phase 0:`...`Phase 3–6:` -> `ขั้น 0:`...`ขั้น 3–6:`; ch1 Gantt row 1 `(Phase 0–6)` -> `(ขั้น 0–6)`.

3. [HIGH] ผู้เช่า / ร้านค้า / tenant never reconciled (ch1:41,52; ch2 §2.7; ch3). ch1 introduces "multi-tenant" as "ร้านอะไหล่หลายร้านที่เป็นเจ้าของคนละราย" and uses ร้านค้า; ch2 and ch3 switch to ผู้เช่า without saying they are the same thing; ch3 also leaks raw "tenant" in prose (ch3 `ไม่รับ tenant id`, `เพราะ tenant มาจาก JWT`, `ผ่านชั้น tenancy`, `กติกาว่า tenant ต้องมาจาก JWT`, table `guard ต่อ tenant`).
   Fix: add one sentence at the end of ch1 §1.1.4 paragraph 1 (after `(multi-tenant)`): `ในรายงานนี้ ร้านอะไหล่หนึ่งร้านที่ใช้ระบบเรียกว่า "ผู้เช่า" (tenant) เมื่อกล่าวถึงการแยกข้อมูลในเชิงเทคนิค และเรียกว่า "ร้านค้า" เมื่อกล่าวถึงงานของร้าน`
   Then in ch3: `ไม่รับ tenant id เป็นอาร์กิวเมนต์` -> `ไม่รับรหัสผู้เช่า (tenant id) เป็นอาร์กิวเมนต์`; `เพราะ tenant มาจาก JWT` -> `เพราะผู้เช่ามาจาก JWT`; `ผ่านชั้น tenancy และ idempotency` (figure caption) -> `ผ่านชั้นการแยกผู้เช่าและ idempotency`; `ว่า tenant ต้องมาจาก JWT เท่านั้น` -> `ว่าผู้เช่าต้องมาจาก JWT เท่านั้น`; table `guard ต่อ tenant` -> `guard ต่อผู้เช่า`.

4. [HIGH] ch2 §2.7 first sentence — `ให้ลูกค้าหลายรายใช้ระบบเดียวกัน` : here "ลูกค้า" means the tenant-organisation, but everywhere else ลูกค้า = the shop's customer (ลูกค้าประจำ, ลูกค้า in Customers table). Misleading in the exact paragraph that defines tenancy.
   Fix: `ระบบหลายผู้เช่า (multi-tenant) ให้องค์กรหลายราย (ผู้เช่า) ใช้ระบบเดียวกันโดยข้อมูลต้องไม่ปะปนกัน`

5. [HIGH] "deploy" has three Thai renderings plus 62 raw uses: ch1 `ปล่อยขึ้น VM` / `ปล่อยจริงครั้งแรก` (5x), ch2 `นำไปติดตั้งได้`, ch3-ch5 raw `deploy`/`การ deploy` (62x), and headings `## การ deploy`, `### โครงสร้างการ deploy`, `## ผลการ deploy บนเครื่อง mob04`. "ปล่อยขึ้น" also reads colloquial.
   Fix: define once in ch1 (scope table, row การปฏิบัติการ) and use the English verb after that, as the rest of the report already does:
   - ch1 find `ปล่อยขึ้น VM `mob04` ด้วย self-hosted runner และ Ansible` -> `นำระบบขึ้นใช้งาน (deploy) บน VM `mob04` ด้วย self-hosted runner และ Ansible`; `ปล่อยจริงครั้งแรกเมื่อ 30 กันยายน` -> `deploy จริงครั้งแรกเมื่อ 30 กันยายน`; objective 6 `การปล่อยขึ้นเครื่องเสมือน` -> `การนำขึ้นใช้งาน (deploy) บนเครื่องเสมือน`; timeline `การปล่อยขึ้น VM `mob04` ครั้งแรก` -> `การ deploy ขึ้น VM `mob04` ครั้งแรก`.
   - Headings: ch3 `## การ deploy` -> `## การนำระบบขึ้นใช้งาน (deploy)`; ch4b `## ผลการ deploy บนเครื่อง mob04 และการติดตามระบบ` -> `## ผลการนำระบบขึ้นใช้งานบนเครื่อง mob04 และการติดตามระบบ`.

6. [MED] ch1 vs ch4b/ch5 — DoD has three Thai names: `เกณฑ์ความสำเร็จของเฟส 1 (Definition of Done: DoD)` (ch1), `รายการตรวจรับ`/`เกณฑ์ตรวจรับ` (ch4a, ch4b, ch5). Also ch4b heading `ตรวจสอบเกณฑ์ Definition of Done` leaves the term unexpanded in Thai.
   Fix: one name, **เกณฑ์ตรวจรับ**. ch1 `ในเกณฑ์ความสำเร็จของเฟส 1 (Definition of Done: DoD) 17 ข้อ ติ๊กแล้ว 16 ข้อ เหลือข้อ k6 หนึ่งข้อ` -> `ในเกณฑ์ตรวจรับของเฟส 1 (Definition of Done: DoD) 17 ข้อ ผ่านแล้ว 16 ข้อ เหลือข้อ k6 หนึ่งข้อ`; ch4b `ตรวจสอบเกณฑ์ Definition of Done` -> `ตรวจสอบเกณฑ์ตรวจรับ (DoD)`; ch4b table caption `สถานะเกณฑ์ Definition of Done ของระยะที่ 1` -> `สถานะเกณฑ์ตรวจรับ (DoD) ของเฟส 1`; ch4b `รายการตรวจรับ (Definition of Done: DoD)` -> `เกณฑ์ตรวจรับ (DoD)` (already expanded in ch1).

7. [MED] The closing report has four names: ch1 `รายงานปิดกะ`, ch3 `รายงานปิดวัน` (x2), ch4a `รายงานปิดร้าน`/`รายงานสรุปยอดปิดร้าน`, ch3 `closing report`. They are one screen (figure caption says "Daily Closing Report").
   Fix: **รายงานปิดร้าน** everywhere. ch1 lane table `กะและรายงานปิดกะ` -> `กะและรายงานปิดร้าน`; ch3 screen table `รายงานสรุป รายงานปิดวัน สต็อกต่ำ` -> `รายงานสรุป รายงานปิดร้าน สต็อกต่ำ`; ch3 `ทั้งในหน้าลิ้นชักและรายงานปิดวัน` -> `ทั้งในหน้าลิ้นชักและรายงานปิดร้าน`; ch4a `รายงานสรุปยอดปิดร้านรวบรวม` -> `รายงานปิดร้านรวบรวม`.

8. [MED] "source of truth" has three Thai renderings: `แหล่งอ้างอิง (source of truth)` (ch1:27), `แหล่งข้อมูลจริง` (ch1:61 objective 2), `แหล่งความจริง` (10x elsewhere). `แหล่งอ้างอิง` additionally collides with "reference/แหล่งอ้างอิง" = bibliography.
   Fix: first use ch1:27 `ยึดเป็นแหล่งอ้างอิง (source of truth) ของกติกาทางธุรกิจ` -> `ยึดเป็นแหล่งความจริง (source of truth) ของกติกาทางธุรกิจ`; ch1:61 `เป็นแหล่งข้อมูลจริง` -> `เป็นแหล่งความจริง`.

9. [MED] Three words for "client side": ฝั่งไคลเอนต์ (11x), ฝั่งอุปกรณ์ (6x, ch4a), ฝั่งเครื่อง (5x, ch1/ch3), plus ch2 `ฝั่งแอป` (heading `เทคโนโลยีฝั่งแอป`) and `สถาปัตยกรรมฝั่งผู้ใช้` (ch2 intro). ฝั่งเครื่อง/ฝั่งอุปกรณ์ are sometimes meant as "the pos device" (ch4a heading `ระบบทำงานออฟไลน์ เฟส 2 ฝั่งอุปกรณ์`), which is fine, but ฝั่งผู้ใช้/ฝั่งแอป are just unplanned synonyms.
   Fix: ch2 intro `ไปสู่สถาปัตยกรรมฝั่งผู้ใช้ (offline-first, Flutter, Drift)` -> `ไปสู่สถาปัตยกรรมฝั่งไคลเอนต์ (offline-first, Flutter, Drift)`; ch2 heading `## เทคโนโลยีฝั่งแอป` -> `## เทคโนโลยีฝั่งไคลเอนต์` (TOC 2.4 updates automatically). Keep ฝั่งอุปกรณ์/ฝั่งเครื่อง only where the on-device engine is meant.

10. [MED] "ระบบหลังบ้าน" (ch4b x3, headings 4.x) vs "ฝั่งเซิร์ฟเวอร์" everywhere else vs the **`backoffice` device role = "เครื่องหลังร้าน"** (ch1:46). "หลังบ้าน/หลังร้าน/backoffice" is three near-identical words for two different things; a committee reader will take "ระบบหลังบ้าน" to mean the back-office terminal.
   Fix: ch4b heading `## ผลการพัฒนาระบบหลังบ้าน` -> `## ผลการพัฒนาฝั่งเซิร์ฟเวอร์`; `### ภาพรวมของระบบหลังบ้านระยะที่ 1` -> `### ภาพรวมของฝั่งเซิร์ฟเวอร์ เฟส 1`; table caption `สรุปองค์ประกอบสำคัญของระบบหลังบ้านและหลักฐานการพิสูจน์` -> `สรุปองค์ประกอบสำคัญของฝั่งเซิร์ฟเวอร์และหลักฐานการพิสูจน์`.

11. [MED] "fingerprint" of a request: ch2 `ลายนิ้วมือ (fingerprint)`, ch4b `ลายนิ้วมือของ /sync/push`, ch3 raw `fingerprint` (6x) and `key` raw (`เก็บ key และ fingerprint`). "ลายนิ้วมือ" literally = human fingerprint, reads as machine translation; idempotency "key" is also called `รหัสกำกับการเขียน` (ch2 heading) and `คีย์ idempotency` (ch5).
   Fix: define once in ch2 and reuse: ch2 `เซิร์ฟเวอร์จดรหัสพร้อมลายนิ้วมือ (fingerprint) ของคำขอและผลลัพธ์` -> `เซิร์ฟเวอร์บันทึกคีย์พร้อมค่าสรุปของคำขอ (request fingerprint) และผลลัพธ์`; ch4b `ลายนิ้วมือของ `/sync/push` ไม่ตรงกับ` -> `ค่าสรุปของคำขอ (fingerprint) ของ `/sync/push` ไม่ตรงกับ`; ch3 `เก็บ key และ fingerprint ของคำขอ โดย fingerprint คือ` -> `เก็บคีย์และ fingerprint ของคำขอ โดย fingerprint คือ`; ch5 `คีย์ idempotency` -> `Idempotency-Key`.

12. [MED] Token names mixed inside one paragraph (ch3 การผูกเครื่อง/ยืนยันตัวตน): `โทเค็นเข้าถึง ... โทเค็นต่ออายุ ... access token ... refresh token`. ch2 does define `โทเค็นเข้าถึง (access token)` / `โทเค็นต่ออายุ (refresh token)`, so ch3 should stay Thai or stay English, not both.
   Fix: ch3 `บนเว็บให้เก็บ access token ในหน่วยความจำเท่านั้น ส่วน refresh token และ device token เก็บใน IndexedDB` -> `บนเว็บให้เก็บโทเค็นเข้าถึงในหน่วยความจำเท่านั้น ส่วนโทเค็นต่ออายุและโทเค็นอุปกรณ์เก็บใน IndexedDB`; security table row `access token ในหน่วยความจำ, refresh หรือ device token ใน IndexedDB, ห้าม localStorage` -> `โทเค็นเข้าถึงในหน่วยความจำ, โทเค็นต่ออายุหรือโทเค็นอุปกรณ์ใน IndexedDB, ห้าม localStorage`.

13. [LOW] Other single-term drifts worth a one-line sweep: `image` (ch3/4b/5, 35x) vs `อิมเมจ` (ch1/ch2, 8x) -> pick **อิมเมจ** in prose, keep `image` only inside table cells/code; `pipeline` (ch2,3 x5) vs `ไปป์ไลน์` (x8) -> **ไปป์ไลน์**; `ไดเรกทอรี` (ch4a, 1x) vs `โฟลเดอร์` (5x) -> `โฟลเดอร์`; `ล็อกอิน` (13x) vs `เข้าสู่ระบบ` (5x) -> prefer **เข้าสู่ระบบ** in prose, keep `ล็อกอิน` only in the UI labels; `โครงการ` (ch4b table caption `สถิติภาพรวมของโครงการ`) -> `โครงงาน`; `ผู้จัดทำ` (ch4a:26) -> `ผู้พัฒนา` (the report's self-reference everywhere else); `ผู้เช่า`-`สาธิต`: `demo tenant` (ch1:52) -> `ผู้เช่าสาธิต` after item 3.

---

## B. Machine-translated / awkward phrases (give exact replacement)

14. [HIGH] ch5 ปัญหา pool (#162): `guard ระดับโลก` ("global guard" translated literally; reads as "world-level").
    -> `guard แบบ global (ทำงานกับทุกคำขอ)` — full: `guard แบบ global ที่ทำงานกับทุกคำขอและอ่านแผนของร้านตอนแคชว่าง ขอการเชื่อมต่อจาก pool ...`

15. [HIGH] ch2 §2.4.3 and §2.10 — `ฉีดความสัมพันธ์ (dependency injection)` and `ระบบฉีดความสัมพันธ์`: "dependency" is การพึ่งพา, not ความสัมพันธ์; this is a mistranslation of a standard term.
    -> `ฉีดการพึ่งพา (dependency injection)` and `ระบบฉีดการพึ่งพา (dependency injection)`.

16. [MED] ch2 §2.3.5 heading and ch3 repo rule 2: `ความล้มเหลวระหว่างทางและชะตากรรมที่ไม่ทราบ` / `ไม่ทราบชะตากรรมของการเขียน` ("unknown fate", repeated in ch5 as "ผลที่ไม่ทราบ").
    -> heading `ความล้มเหลวระหว่างทางและผลลัพธ์ที่ไม่ทราบแน่ชัด`; ch3 `หมายถึงไม่ทราบชะตากรรมของการเขียน` -> `หมายถึงไม่ทราบว่าการเขียนสำเร็จหรือไม่`.

17. [MED] ch4b `### ตะเข็บธุรกรรมและ idempotency` (+ ch4b:27 `หลบเลี่ยงตะเข็บ`, ch5 `ตะเข็บธุรกรรม`, `บังคับตะเข็บนี้`): "seam" translated as ตะเข็บ (a sewing seam). Opaque in Thai and never explained.
    -> `### จุดเชื่อมธุรกรรม (transaction seam) และ idempotency`; body `หลบเลี่ยงตะเข็บ` -> `หลบเลี่ยงจุดเชื่อมนี้`; ch5 `ตะเข็บธุรกรรมกับ idempotency` -> `จุดเชื่อมธุรกรรมกับ idempotency`; `บังคับตะเข็บนี้` -> `บังคับจุดเชื่อมนี้`.

18. [MED] ch3 §ฐานข้อมูล PostgreSQL: `ส่งผ่านสายเป็นสตริง` ("over the wire") -> `ส่งผ่านเครือข่ายเป็นสตริง`.

19. [MED] ch2 §2.10: `Redis เป็นที่เก็บคู่กุญแจ-ค่าในหน่วยความจำ` — กุญแจ is used for cryptographic keys elsewhere in the same chapter (`กุญแจอสมมาตร`).
    -> `Redis เป็นที่เก็บข้อมูลแบบคีย์–ค่า (key-value store) ในหน่วยความจำ`.

20. [MED] "race condition" rendered as การแข่งขัน: ch4b `การแข่งขันสามฝ่ายบนสินค้าตัวเดียว`, `การแข่งขันของผู้เขียนหลายราย`, DoD row 15, and ch3 `การแข่งสิทธิ์สต็อก` (k6 row). "การแข่งขัน" = competition.
    -> `สภาวะแข่งกัน (race condition) ของสามคำขอบนสินค้าตัวเดียว` on first use, then `สภาวะแข่งกัน`; `การแข่งขันของผู้เขียนหลายราย` -> `สภาวะแข่งกันของผู้เขียนหลายราย`; ch3 `การแข่งสิทธิ์สต็อก` -> `สภาวะแข่งกันบนสต็อก`.

21. [MED] ch4a §การนำเข้าข้อมูลสำรอง: `ที่ลบข้อมูลตัวอย่างซึ่งระบบเพาะไว้ครั้งแรกออกหนึ่งครั้ง` ("seeded" -> เพาะ = to cultivate/germinate; also word order unclear).
    -> `ที่ลบข้อมูลตัวอย่าง (seed data) ซึ่งระบบสร้างไว้ตอนเริ่มต้นออกหนึ่งครั้ง`. Same sweep: ch4a `โดยไม่ต้องคีย์ใหม่` -> `โดยไม่ต้องป้อนข้อมูลใหม่`.

22. [MED] ch4a §งานที่ยังไม่เสร็จ: `ยังไม่มีการตัดระบบ (no cutover)` — "ตัดระบบ" reads as "cut the system off". ch1 uses `การย้ายร้านจริงไปใช้ระบบใหม่ (cutover)`.
    -> `ยังไม่มีการย้ายร้านไปใช้ระบบใหม่ (no cutover)`.

23. [MED] Informal / slangy verbs in a formal report (replace in place):
    - ch3 table `ยิง endpoint ออนไลน์ตรง` -> `เรียก endpoint ออนไลน์โดยตรง`; ch4b DoD row 11 `เครื่อง backoffice ยิง POST /sales ได้ 403` -> `เครื่อง backoffice เรียก POST /sales แล้วได้ 403`
    - ch3 `พนักงานจึงไม่ถูกเด้งออกขณะลูกค้ายืนรอ` -> `พนักงานจึงไม่ถูกบังคับออกจากระบบขณะลูกค้ายืนรอ`
    - ch3 `รอต่อกันเป็นทอด` -> `รอต่อเนื่องกันตามลำดับ`
    - ch3 `เพราะเคยทำให้ pool ตันมาแล้ว` -> `เพราะเคยทำให้ connection pool เต็มจนระบบหยุดตอบสนองมาแล้ว`
    - ch3 `ของปลอมของฝั่งตนเอง` -> `ตัวจำลอง (fake) ของฝั่งตนเอง` (ch4a already says `ตัวจำลองเซิร์ฟเวอร์`)
    - ch3 `ซึ่งถ้าล้มจะเตือนอย่างเดียว` -> `ซึ่งหากล้มเหลวจะเพียงแจ้งเตือน`; `สุดท้ายยกชุดมอนิเตอร์` -> `สุดท้ายเริ่มชุดมอนิเตอร์`; `CI จึงล้มบิลด์เมื่อเวอร์ชันไม่ตรง` -> `CI จึงทำให้บิลด์ล้มเหลวเมื่อเวอร์ชันไม่ตรง`; `ควรล้มทั้งธุรกรรมให้เห็นชัด` -> `ควรยกเลิกทั้งธุรกรรม (rollback) เพื่อให้เห็นชัด`
    - ch4b `กวาดตรวจทั้ง 25 ตาราง` -> `ตรวจครบทั้ง 25 ตาราง`; `เพียงสอดแนมเมธอดของไคลเอนต์แคช` -> `เพียงจำลอง (spy) การเรียกเมธอดของไคลเอนต์แคช`
    - ch5 `วิธีกู้ภัยในวันสาธิต` -> `ทางแก้ฉุกเฉินในวันสาธิต`; `ใช้ติ๊กเกณฑ์ DoD ข้อสุดท้าย` -> `ใช้ยืนยันเกณฑ์ DoD ข้อสุดท้าย`
    - `ติ๊ก/ติ๊กใหม่/ไม่ได้ติ๊ก` (ch1:93, ch4b x2, ch5) -> `ผ่านแล้ว / ยืนยันผ่านใหม่ / ยังไม่ผ่าน`; ch4b `ทำเครื่องหมายแล้ว 16 ข้อ และเปิดอยู่ 1 ข้อ` -> `ผ่านแล้ว 16 ข้อ และยังเปิดอยู่ 1 ข้อ`.
    - `เช็ก` (ch2 x3, ch3 x1; "status check") -> `การตรวจสอบสถานะ (status check)`, e.g. ch2 `ต้องผ่านเช็กที่กำหนดก่อนรวมโค้ด` -> `ต้องผ่านการตรวจสอบสถานะที่กำหนดก่อนรวมโค้ด`; ch3 `เหตุผลคือเช็กที่บังคับต้องมีผลทุกครั้ง` -> `เหตุผลคือการตรวจสอบสถานะที่บังคับต้องรายงานผลทุกครั้ง`.

24. [LOW] ch2 intro of §2.2.5/ch3 `ใบลดหนี้ ... ย้อนส่วนลด แต้ม` — `แต้ม` (9x) is colloquial; the Thai point-system term in formal writing is `คะแนนสะสม`. Optional: first use `แต้ม` -> `คะแนนสะสม (แต้ม)`, afterwards keep `แต้ม` as the UI string (it is quoted from the app, so keeping is defensible).

25. [LOW] ch2 `เปลือกออฟไลน์` ("offline shell") -> `เปลือกสำหรับใช้งานออฟไลน์ (offline shell)`; ch3 `กฎล้วน (pure rules)` -> `กฎที่ไม่มีผลข้างเคียง (pure function)`; ch3 `เก็บกะที่ active ก่อนหน้าเข้าคลัง` -> `จัดเก็บ (archive) กะที่ยังเปิดอยู่ก่อนหน้า`; ch3 `ตัวกำหนดเส้นทาง` fine.

26. [LOW] ch3 `ความล้มเหลวด้านการขนส่งข้อมูลจริง (transport failure)` (ch3 repo rule 2) -> `ความล้มเหลวของการส่งผ่านเครือข่ายจริง (transport failure)`; ch2/ch3 `ค่าท้องถิ่น` (ch2:51) -> `ค่าในเครื่อง`; ch3 `งานเงิน` -> `งานด้านการเงิน`.

27. [LOW] ch1 `ความมองไม่เห็นของเจ้าของร้าน` (quoted label for P4-P8) -> `"ข้อมูลที่เจ้าของร้านมองไม่เห็น"`; ch1 §1.1.1 `จากการสรุปความของเจ้าของโครงงานที่บันทึกไว้ในเอกสารประกอบโครงงาน [1] ก่อนมีระบบ ร้านประสบปัญหาหลัก 8 ประการ` (ambiguous "ก่อนมีระบบ") -> `ตามที่เจ้าของโครงงานสรุปไว้ในเอกสารประกอบโครงงาน [1] ร้านประสบปัญหาหลัก 8 ประการก่อนมีระบบ`.

28. [MED] ch1 §ข้อจำกัด heading `ข้อจำกัดของสิ่งที่รายงานนี้อ้างว่าเสร็จ` (appears in TOC 1.3.3) is clumsy and sounds like the report is hedging.
    -> `สิ่งที่รายงานนี้ยังไม่ถือว่าแล้วเสร็จ`.

29. [MED] "เจ้าของโครงงาน" is used ~40x as the decision authority (decisions, ratification, "ตัดสิน") but is never defined; the three authors are "ทีม/ผู้พัฒนา". A grader will not know whether this is the advisor, the shop owner or a team member (ch3 also says bare `เจ้าของ` meaning shop owner: `เจ้าของเลือกส่งใหม่ด้วย key เดิม`).
    Fix: add at first use (ch1 §1.1.1, after `เจ้าของโครงงาน`): `(เจ้าของโครงงาน คือผู้กำหนดโจทย์และตัดสินใจขอบเขตงานในรายงานนี้)` — wording must be corrected by the team if the role is different; and ch3 `เจ้าของเลือกส่งใหม่` -> `เจ้าของร้านเลือกส่งใหม่`.

---

## C. Acronyms / jargon used before expansion (template rule: expand on first use)

The merged "รายการคำย่อ" front page covers all of these, but the in-text first use should still expand the ones below (checked against first occurrence in reading order):

30. [MED] ch1 first-use order problems:
    - **ADR** first appears in §1.1.4 reason 4 `(ADR-0004 [8])` but is expanded only in objective 7. Fix reason 4: `... ต้องเห็นสต็อกชุดเดียวกัน (บันทึกการตัดสินใจเชิงสถาปัตยกรรม Architecture Decision Record: ADR-0004 [8])` and shorten objective 7 to `เพื่อบันทึกการตัดสินใจเชิงสถาปัตยกรรมเป็น ADR พร้อมเหตุผล ...`.
    - **PWA, JWT, PIN, RC, CN** first appear unexpanded in the ch1 scope/lane tables (`PWA, outbox, SyncService, เลขใบเสร็จ/ใบลดหนี้ฝั่งเครื่อง, PIN แบบออฟไลน์`; `ยืนยันตัวตน JWT`; `เลข RC/CN`). Fix in scope table row เฟส 2: `เว็บแอปแบบก้าวหน้า (PWA), outbox, SyncService, เลขใบเสร็จ (RC) และใบลดหนี้ (CN) ฝั่งเครื่อง, รหัสผ่านสั้น (PIN) แบบออฟไลน์ ...`; lane table C: `ยืนยันตัวตนด้วย JSON Web Token (JWT)`.
    - **outbox / op / aggregate** are used as nouns before being defined: ch1 objective 5 says `คิวคำสั่งในเครื่อง` but the scope table says `outbox`; ch3 §3.1 table says `รายการ op ที่กำหนด` and `aggregates (หน่วยข้อมูลของตัวเองและที่ต้องรอ)` with no definition. Fix ch3 table row `เครื่อง pos เข้าคิวได้ตามรายการ op ที่กำหนด` -> `เครื่อง pos เข้าคิวได้ตามรายการคำสั่ง (operation: op) ที่กำหนด`; `aggregates (หน่วยข้อมูลของตัวเองและที่ต้องรอ)` -> `aggregates (กลุ่มข้อมูลที่คำสั่งนั้นแก้ เช่น บิลหนึ่งใบหรือกะหนึ่งกะ และกลุ่มที่ต้องรอก่อน)`. Use `กล่องขาออก (outbox)` once in ch1 §1.1.4 so ch2's heading `รูปแบบกล่องขาออก (outbox pattern)` is not the first appearance of the Thai name.
31. [MED] ch2 §2.4.2: `รองรับธุรกรรม ACID [4]` is used before ACID is expanded in §2.6.1. Fix: `รองรับธุรกรรมแบบ ACID (ความเป็นอะตอม ความสอดคล้อง การแยกจากกัน และความคงทน ดูหัวข้อ 2.6.1) [4]`.
32. [LOW] Never expanded in running text (only on the abbreviation page): ch3 `CORS`, `DDL`, `NFC`, `ER` (figure caption), `PDF`, `CP`/`QT` (the prefix list does gloss them in Thai: fine); ch2 `YAML`, `SQL`, `HTTP`, `IP`; ch4b `SHA`, `e2e`; ch5 `AOT`, `ASCII`, `SMB`, `SFTP`, `NAS` (ch5 item 3 uses `SMB`, `SFTP`, `NAS` in one sentence). Minimum worth doing: ch5 `เลือกระหว่างการเชื่อมผ่าน SMB กับการซื้อ NAS ที่รองรับ SFTP` -> `เลือกระหว่างการเชื่อมผ่านโปรโตคอล Server Message Block (SMB) กับการซื้ออุปกรณ์จัดเก็บข้อมูลบนเครือข่าย (Network-Attached Storage: NAS) ที่รองรับ SSH File Transfer Protocol (SFTP)`; ch3 `ข้อกำหนด DDL` first use -> `ภาษานิยามข้อมูล (Data Definition Language: DDL)`; ch3 `รูปแบบยูนิโคด NFC` -> `รูปแบบยูนิโคด Normalization Form C (NFC)`. The rest can stay on the abbreviation page.
33. [LOW] Abbreviation page: lists `CI`, `CD` and `CI/CD` as three rows; keep `CI/CD` only plus the two expansions in its line. `POS` is `Point-of-Sale` in ch2 but `Point of Sale` in ch1/ch3 (the page shows the latter; make ch2 body `(Point of Sale: POS)` to match). `RC = Receipt (เลขใบเสร็จ)` vs `(เลขที่ใบเสร็จ)` in different chapters -> `Receipt (เลขที่ใบเสร็จ)`.

---

## D. Formatting leaks and run-on paragraphs

34. [MED] ch3 heading `### Repository แบบ API (`USE_API_WRITES`)` — literal backticks print in the TOC (PDF p. ค, line "3.3.4 Repository แบบ API (`USE_API_WRITES`)") and as the heading in the body. Headings are not code-formatted by the build.
    -> `### Repository แบบ API (USE_API_WRITES)`.

35. [MED] ch2 headings: heading `### เหตุที่ไม่ใช้ CRDT หรือการ replicate ฐานข้อมูลโดยตรง` and `## ความซ้ำซ้อนของคำขอและรหัสกำกับการเขียน (idempotency)`: "ความซ้ำซ้อนของคำขอ" suggests *redundancy*, but the section is about safe repetition. -> `## การทำซ้ำคำขออย่างปลอดภัยและรหัสกำกับการเขียน (idempotency)`; and `replicate` -> `ทำสำเนา (replicate)`.

36. [MED] Over-long single paragraphs that read as run-ons (all are strings of 4-8 semicolon/`และ` clauses); split into bullets or sentences:
    - ch3 §การแยกข้อมูลผู้เช่าด้วย RLS, paragraph 2 (`กติกาที่ผูกพันกับส่วนนี้มีสี่ข้อ ได้แก่ ...` ~1,400 characters, four rules joined by semicolons then `ไฟล์ทดสอบเชิงสถาปัตยกรรมสามไฟล์ ...`). Turn the four rules into a numbered list (as §Repository แบบ API already does for its five rules).
    - ch3 §POST /sync/push paragraph 1: inline `หนึ่ง ... สอง ... สาม ... และสี่` inside one paragraph; -> numbered list `1.` to `4.`, and put the `retry` sentence after it.
    - ch3 §POST /sync/push paragraph 2: split after `ส่วน op อื่นยังไปต่อได้` and again before `เจ้าของเลือกส่งใหม่ ...`.
    - ch4a §ผลเพิ่มเติม (two paragraphs `ข้อแรก ... ข้อที่สอง` / `ข้อที่สาม ... ข้อที่สี่`): each item is 2-3 clauses joined by `จึง ... และ ... แต่`; make four bullets (`- #473/#488: ...`, `- #489: ...`, `- PR #544: ...`, `- PR #539/#541: ...`).
    - ch4b §ตะเข็บธุรกรรม: the last sentence (`... แต่มีจุดบอดคือเส้นทางเขียนที่ไม่มีการอ้างสิทธิ์ idempotency เลยจะมองไม่เห็นในทั้งสามสเปก จึงยังต้องอาศัยการทบทวนโดยคน`) -> `... แต่มีจุดบอดหนึ่งข้อ คือเส้นทางเขียนที่ไม่ได้อ้างสิทธิ์ idempotency เลยจะไม่ปรากฏในสเปกทั้งสามไฟล์ จึงยังต้องอาศัยการทบทวนโดยคน`.
    - ch4b §ตรวจสอบเกณฑ์ DoD closing paragraph (`เกณฑ์ข้อ 14 และข้อ 16 ถูกติ๊กใหม่ ...` ~900 characters covering #14, #16, #2, #184, #380 and the rate-limit decision): split into three short paragraphs (ข้อ 14/16 evidence; ข้อ 2 and #184/#380; วิธีวัดที่ตกลงแล้ว).

37. [LOW] ch3 overview sentence lists seven topics with spaces and no conjunction (`... ฝั่งเซิร์ฟเวอร์ การซิงก์ข้อมูลในเฟส 2 ความปลอดภัย การ deploy เทคโนโลยีที่ใช้ และวิธีการทำงานของทีม`): readable but add a comma-substitute: insert `และ` only before the last item is already there; instead start the list with `ได้แก่` then group in pairs: `ได้แก่ สถาปัตยกรรมและส่วนประกอบ ฝั่งไคลเอนต์ ฝั่งเซิร์ฟเวอร์ การซิงก์ข้อมูลในเฟส 2 ความปลอดภัย การนำระบบขึ้นใช้งาน (deploy) เทคโนโลยีที่ใช้ และวิธีการทำงานของทีม`.

38. [LOW] ch4b §ระดับที่ 4: `ข้อที่ต้องระบุคือครึ่งหนึ่งของเกณฑ์ที่เกี่ยวกับ PR จาก fork พิสูจน์จากโค้ดและค่าติดตั้งเท่านั้น` — `ครึ่งหนึ่งของเกณฑ์` is unclear (half of which AC?). -> `ข้อที่ต้องระบุคือ เกณฑ์ย่อยด้านการจัดการ PR จาก fork พิสูจน์จากโค้ดและค่าติดตั้งเท่านั้น ไม่มีการรันจริงจาก fork`.

39. [LOW] Dash usage: Thai paragraphs use `-` and `–` for ranges inconsistently (`P1–P3`, `รับ–จ่าย`, `เปิด–ปิด` use en dash; `20,800`, `65,600` fine; ch4b heading uses em dash `ระดับที่ 4 — การ deploy`). Use en dash in ranges, and replace the heading em dash with a colon: `ระดับที่ 4: การ deploy ด้วย Ansible และ self-hosted runner`.

40. [LOW] ch1 reference `[12]` is absent in the chapter source numbering (`[11]` -> `[13]`); the build renumbers globally (PDF shows [1]-[19] contiguous) so no visible defect, but if the source numbering is ever used for IEEE ordering, renumber ch1 `[13]`-`[17]` to `[12]`-`[16]`. Also in ch2 `Idempotency-Key ... [27]` is cited before refs [11]-[26] (IEEE: numbered in order of first citation) — PDF shows it as [39] ahead of [20]-[38]; reorder ch2 refs so the Idempotency RFC draft is [11] and renumber the rest.

---

## Not worth changing (checked)
- Spelling variants are uniform (ซิงก์, คอมมิต, ไคลเอนต์, เวิร์กโฟลว์, เฟรมเวิร์ก, แพ็กเกจ, เซสชัน). Only `อ็อบเจ็กต์` (ch2 tenancy table) vs `ออบเจ็กต์` (ch5) differs: use `ออบเจ็กต์` in ch2.
- Register is formal throughout; no `นะ/ค่ะ/มั้ย`-type particles, no first-person.
- The "ท างาน/ก าไร" gaps seen in `draft2.txt` are pdftotext artefacts of sara-am in TH Sarabun, not source defects (source contains proper ำ).
- Cover title: Thai `ระบบขายหน้าร้านอะไหล่รถยนต์แบบหลายร้านค้าที่ทำงานออฟไลน์ได้` matches the English title; note it promises offline working while ch1 §1.3 says phase 2 is not complete — that is a scope/claims issue for another reviewer, not language.
