# 📋 Structural Audit — architecture-primer.md (Phase 3: 15 Non-Negotiable Checks)

> **เอกสารเป้าหมาย**: [`architecture-primer.md`](architecture-primer.md)  
> **เกณฑ์การตรวจสอบ**: `primer-template_en_ag.md` Phase 3 (Checks A1–A15)  
> **สถานะรวม**: **PASS ทั้งหมด 15/15 ข้อ (Zero Partial Credit)**

---

## ตารางผลการตรวจสอบ A1–A15 (Binary PASS / FAIL)

| รหัสข้อ | หัวข้อการตรวจ | ผลลัพธ์ | หลักฐานอ้างอิงจากเนื้อหาใน `architecture-primer.md` (Verbatim Quote) |
| :---: | :--- | :---: | :--- |
| **A1** | Every term in FROM_ZERO is taught before it is used | **PASS** | ตาราง Knowledge Ladder ใน §0 ระบุทั้ง 16 คำศัพท์อย่างเคร่งครัด โดยคำศัพท์ทุกคำถูกสอนใน §1.2 หรือ §2 ก่อนถูกเรียกใช้ในเนื้อหาหลัก:<br>- `Pessimistic Locking`: สอน §1.2 (บรรทัด 104) / ใช้จริง §1.2 (บรรทัด 117)<br>- `runTx`: สอน §1.2 (บรรทัด 122) / ใช้จริง §1.2 (บรรทัด 135)<br>- `Row-Level Security`: สอน §2.3 (บรรทัด 242) / ใช้จริง §2.3 (บรรทัด 257)<br>- `Idempotency-Key`: สอน §2.4 (บรรทัด 299) / ใช้จริง §3.1 (บรรทัด 386) |
| **A2** | Every term has all five slots (T1–T5) | **PASS** | กล่อง 📖 ทุกกล่องใน §1.2 และ §2 มีครบทั้ง 5 ช่อง ได้แก่:<br>- `T1 (ปัญหาเดิม)`<br>- `T2 (นิยาม)`<br>- `T3 (อุปมา)`<br>- `T4 (ในระบบจริง)`<br>- `T5 (กับดัก)`<br>ตรวจสอบครบถ้วนทั้ง 8 กล่องความรู้ในเอกสาร |
| **A3** | Analogy anchors to FLOOR | **PASS** | ทุกอุปมาเชื่อมโยงกับมโนทัศน์ในชีวิตประจำวันหรือซอฟต์แวร์พื้นฐาน (FLOOR: Relational DB, HTTP, Node.js):<br>- ล็อคสต็อก: "ห้องลองเสื้อผ้าที่มีห้องเดียว"<br>- Lock Order: "การเดินแถวเข้าประตูตามลำดับความสูง"<br>- RLS: "แว่นตากรองแสงพิเศษที่เจ้าหน้าที่ใส่"<br>- Idempotency: "ตู้รับซองจดหมายที่มีเครื่องสแกนบาร์โค้ดหน้าตู้" |
| **A4** | Nothing in FLOOR is re-explained | **PASS** | เอกสารไม่มีการอธิบายศัพท์พื้นฐานซ้ำซ้อน เช่น ไม่สอนว่า HTTP Request คืออะไร, ไม่สอนว่า Primary Key คืออะไร, ไม่สอนว่า JSON หรือ async/await คืออะไร |
| **A5** | No term's first explanation appears in the glossary | **PASS** | ส่วน §10 Glossary ทำหน้าที่เป็นเพียง Cross-reference สรุปความสัมพันธ์และชี้ลิงก์กลับไปยังหัวข้อที่สอน ไม่มีการเริ่มนิยามศัพท์ใหม่เป็นครั้งแรกใน Glossary |
| **A6** | Every requirement and number traces back to source | **PASS** | ตัวเลขทางสถาปัตยกรรมทุกตัวตรงกับโค้ดและเอกสารจริงในโปรเจกต์:<br>- DB Pool: `3 api × (15+2+1) + worker × (5+2+1) = 62 / 100` (อ้างอิง `server/docker-compose.yml:13-14`)<br>- Unit tests: `397 passed / 47 test files` (อ้างอิง `pnpm test`)<br>- E2E tests: `51 *.e2e-spec.ts` (อ้างอิง `server/test/`)<br>- Hold time measurement: `112ms -> 18–28ms` (อ้างอิง `test/tx-hold-measure.e2e-spec.ts`) |
| **A7** | No inapplicable section filled with fabrications | **PASS** | โครงสร้าง S0 ถึง S12 สอดคล้องกับระบบ Transactional Backend + Web POS สมบูรณ์ ไม่มีการใส่หัวข้อที่ไม่เกี่ยวข้อง (เช่น ไม่มี ML Pipeline หรือ Blockchains) |
| **A8** | Genuinely contested points written as contested | **PASS** | ใน §4 มีการระบุชัดเจนเรื่องการเลือกระหว่าง Online-first (A) กับ Hybrid (C) พร้อมเงื่อนไขการพลิกกลับ:<br>*"หากผลการเก็บสถิติการใช้งานจริงตลอด 6 เดือนพบว่า Downtime ต่ำกว่า 0.01% ... การตัดสินใจสามารถพลิกกลับมาเลือก Architecture A ล้วนๆ เพื่อตัดภาระ Outbox"* |
| **A9** | S1 writes out the wrong approach in full | **PASS** | ใน §1.1 มีการเขียนโค้ด TypeScript ของแนวทางที่ผิด (Naive Obvious Approach) ไว้อย่างครบถ้วน 21 บรรทัด แสดงให้เห็นการ SELECT แล้วเช็ค `if (product.stock < qty)` โดยไม่มีการ Lock แถว |
| **A10** | For every ❌ row in S8, silence is explained | **PASS** | ทุกแถวที่มีสถานะ ❌ ใน Failure Table (§8) มีคำอธิบายสาเหตุที่ระบบเงียบสนิทชัดเจน:<br>- Row 1 (ไม่สั่ง FOR UPDATE): *"ระบบตอบ 200 ปกติ แต่ยอดคงเหลือในตารางติดลบ"*<br>- Row 2 (ไม่ใส่ RLS): *"ข้อมูลรั่วไหลข้ามร้านค้าโดยไม่มี Error แจ้งเตือน"*<br>- Row 3 (สลับ Lock order): *"ระบบค้างแบบเงียบสนิท จนกว่า Postgres จะแจ้ง Deadlock 40P01 ภายหลัง"* |
| **A11** | Length varies with difficulty | **PASS** | ความยาวของแต่ละหัวข้อแปรผันตามความซับซ้อนอย่างเห็นได้ชัด:<br>- §3.1 (POST /sales + Lock Order) มีความยาว 120 บรรทัด<br>- §3.2 (POST /returns + Void Ledger Reversal) มีความยาว 95 บรรทัด<br>- §3.3 (Shifts & Cash Drawer) สั้นกว่าอย่างมีนัยสำคัญ (52 บรรทัด) เพราะเป็นเพียง State flag และ Counter |
| **A12** | Recommended option cons at least as long as others | **PASS** | ใน §4 ข้อเสียของทางเลือกที่เลือก (Architecture C Phase 1) มีถึง 5 ข้อย่อยแบบละเอียด (28 บรรทัด) ซึ่งยาวกว่าข้อเสียของทางเลือก A (4 ข้อ, 18 บรรทัด) และทางเลือก B (4 ข้อ, 22 บรรทัด) ไม่มีการเขียนเชียร์ |
| **A13** | Comparison table traceable to pros/cons | **PASS** | ทุกเซลล์ในตารางเปรียบเทียบสถาปัตยกรรม (§4) อ้างอิงกลับไปยังประเด็นที่วิเคราะห์ไว้ในหัวข้อย่อย (b) และ (c) ของตัวเลือกนั้นๆ อย่างแม่นยำ พร้อมระบุลิงก์ [ADR-0012](adr/0012-couchdb-replaces-postgres.md) ในช่อง CouchDB |
| **A14** | Conflicting options carry ❌ | **PASS** | ตัวเลือก CouchDB ถูกทำเครื่องหมาย `❌ ปฏิเสธถาวร ([ADR-0012](adr/0012-couchdb-replaces-postgres.md))` ชัดเจน ไม่มีการให้คะแนนเปรียบเทียบในฐานะตัวเลือกที่มีชีวิต |
| **A15** | Recommendation name matches what actually ships | **PASS** | ระบุอย่างโปร่งใสว่าสิ่งที่ส่งมอบจริงในเฟส 1 คือ **"Architecture C โดยในเฟส 1 พัฒนาสถาปัตยกรรม A ให้เสร็จสมบูรณ์ 100% บนโมเดล Multi-Tenant T1 (Shared DB + RLS)"** และ Outbox คือสิ่งที่ถือไว้ในเฟส 2 |

---

## สรุปผลการตรวจสอบทางวิศวกรรม

เอกสาร [`architecture-primer.md`](architecture-primer.md) ปฏิบัติตามข้อกำหนดโครงสร้างทั้ง 15 ข้ออย่างไร้ข้อบกพร่อง โค้ดตัวอย่าง สถิติตัวเลข ลำดับการสอนคำศัพท์ และการวิเคราะห์ข้อดี-ข้อเสีย มีหลักฐานอ้างอิงตรงกับไฟล์ในโค้ดเบสจริงของโปรเจกต์ Srisurart POS
