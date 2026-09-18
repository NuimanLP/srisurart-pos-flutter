# Handoff — Architecture Primer & Concurrency Locking / Caching Deep Dive (2026-09-18)

**วันที่:** 2026-09-18 · **ผู้บันทึก:** AI Assistant (Antigravity Agent) · **สถานะ:** ปิดแล้ว  
**ขอบเขต:** ปูพื้นฐานวิศวกรรมสถาปัตยกรรม Concurrency & Locking, Caching & Invalidation สำหรับ Backend สแตก NestJS + PostgreSQL + Redis + BullMQ + Nginx ตามแม่แบบ `primer-template.md` และเนื้อหาบทเรียน `Backend01`–`Backend06`  
**ต่อจาก:** [`docs/Backend_design/03_ARCHITECTURE.md`](../Backend_design/03_ARCHITECTURE.md), [`docs/Backend_design/00_BASICS.md`](../Backend_design/00_BASICS.md)

---

## 1. ตอนนี้อยู่ตรงไหน
- เอกสารชุดสถาปัตยกรรมใน `docs/Backend_design/` มีเอกสารปูพื้นฐานฉบับสมบูรณ์ [`architecture-primer.md`](../Backend_design/architecture-primer.md) (997 บรรทัด ครบ 13 หัวข้อ §0–§12) และสเปกอ้างอิง [`architecture.md`](../Backend_design/architecture.md) พร้อมใช้งาน
- สารบัญเอกสารหลัก [`docs/Backend_design/00_INDEX.md`](../Backend_design/00_INDEX.md) และ [`docs/Backend_design/03_ARCHITECTURE.md`](../Backend_design/03_ARCHITECTURE.md) ได้รับการอัปเดต Callout และดัชนีชี้ไปยังเอกสารชุดใหม่ครบถ้วน
- ผ่านการตรวจสอบตามเกณฑ์ 11 ข้อของ `primer-template.md` (ผ่านครบ 11/11 ข้อ 100%)
- โค้ดเบสฝั่ง server และ Flutter client ไม่ได้รับผลกระทบทาง control flow (งานเอกสารสถาปัตยกรรมล้วน)

---

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร
1. **จัดทำ [`docs/Backend_design/architecture-primer.md`](../Backend_design/architecture-primer.md)**:
   - **บันไดความรู้ (Knowledge Ladder — กติกา ป1)**: กำหนด FLOOR ชัดเจน (REST API, HTTP status, SQL พื้นฐาน, TypeScript, Event loop) และสอน **18 ศัพท์สำคัญใน FROM_ZERO** ครบ 5 ช่อง (ปัญหาเดิม, นิยาม, อุปมา, ในงานจริง, กับดัก) โดย `สอนที่ == ใช้ครั้งแรกที่` เสมอ
   - **เจาะลึกเทคนิค Concurrency & Locking (§4)**: ชำแหละ Optimistic Locking (`@VersionColumn`) ว่าทำไมถึงเกิด Retry Storm ทะลุ $125,000$ queries เมื่อเจอ 500 VUs; ชำแหละ Pessimistic Locking (`SELECT ... FOR UPDATE`) ว่าทำไมทำให้เกิด Connection Pool Starvation (48 connections เต็มจนเกิด 504 Timeout); การใช้ Distributed In-Flight Lock (`SET NX PX` + Compare-and-Delete Lua Script); และยุทธศาสตร์ 4-Tier Defense (Tier 1 Redis Lua Gatekeeper ~1ms, Tier 2 BullMQ Queue 202 Accepted, Tier 3 PostgreSQL Atomic Decrement, Tier 4 DB Constraints)
   - **เจาะลึกเทคนิค Caching & Invalidation (§5)**: ตาราง Latency Hierarchy (Peter Norvig & Backend04); วิเคราะห์ Caching Patterns 3 รูปแบบ (Cache-Aside vs Write-Through vs Write-Behind); นวัตกรรม **Stock Overlay Pattern** ที่แยก Static Metadata Cache (`redis-cache`, LRU, TTL 30–60s) ออกจาก Dynamic Stock Counter (`redis-data`, noeviction, AOF); กลยุทธ์ Invalidation (Update DB ก่อน Del Cache, แบน `KEYS`, Debounce 1 วินาที); การสกัด Cache Stampede ด้วย In-Process Single-Flight Memoization (`flightMap`); และการกัน Cache Avalanche ด้วย TTL Jitter
   - **State Machine, Failure Matrix, และ Self-Test**: แผนภาพ State Machine ของคำสั่งซื้อพร้อมการพิสูจน์ความปลอดภัยของสถานะอันตราย `IN_FLIGHT`; ตารางวิเคราะห์ 9 ข้อผิดพลาดพร้อมระดับการรู้ตัว (❌ เงียบสนิท, 🟡 เห็นอาการแต่หายาก, ✅ พังทันที, ✅(สาย) รู้ตัวตอนสาย); และ 11 ข้อคำถามทดสอบตัวเองเชิงสถาปัตยกรรมพร้อมเฉลยละเอียด
2. **จัดทำสเปกอ้างอิง [`docs/Backend_design/architecture.md`](../Backend_design/architecture.md)**:
   - รวบรวมสเปกทางเทคนิค บรรจุ §5.5 (Cache Validation & Invalidation Deep Dive) และ §6.5 (Concurrency & Locking Deep Dive)
3. **อัปเดตสารบัญและลิงก์เชื่อมโยง**:
   - เพิ่มรายการใน [`docs/Backend_design/00_INDEX.md`](../Backend_design/00_INDEX.md)
   - เพิ่ม Callout บนหัวเอกสาร [`docs/Backend_design/03_ARCHITECTURE.md`](../Backend_design/03_ARCHITECTURE.md)
   - อัปเดตดัชนีบันทึกส่งมอบงาน [`docs/handoff_log/INDEX.md`](INDEX.md)

---

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร
- **นำเอกสารชุด Architecture & Primer เข้ามาไว้ใน `docs/Backend_design/` ของโปรเจกต์นี้**:
  - *เหตุผล*: สแตกที่ใช้ของทั้งสองโปรเจกต์คือสแตกเดียวกันตามข้อกำหนดวิชาอาจารย์ (NestJS + PostgreSQL + Redis + BullMQ + Nginx) และเอกสารชุดนี้เป็นตัวแบบเชิงวิศวกรรมสถาปัตยกรรม (Concurrency & Caching Deep Dive) ที่อธิบายเหตุผลเบื้องหลังการออกแบบของระบบทั้งหมด
  - *ผู้ตัดสินใจ*: เจ้าของโปรเจกต์ / ผู้ใช้ สั่งการให้นำเอกสารเข้ามาไว้ใน `docs/Backend_design/`
- **ปฏิเสธ Optimistic Locking และ Pessimistic Locking บน Write Path หลัก**:
  - *เหตุผล*: Optimistic Lock ก่อให้เกิด Retry Storm ถล่ม DB เมื่อเกิด High Contention ส่วน Pessimistic Lock บน HTTP Controller ยึด Connection Pool จนแห้งผากทำให้คำขออื่นล่มไปด้วย (504 Timeout)
  - *ทางเลือกที่เลือก*: 4-Tier Defense ร่วมกับ Redis Lua Gatekeeper และ PostgreSQL Atomic Decrement ใน Worker
- **ปฏิเสธ Write-Through และ Write-Behind สำหรับสต็อกสินค้า**:
  - *เหตุผล*: Write-Through ถ่วง Write Path ให้ช้าลง ส่วน Write-Behind เสี่ยงข้อมูลคำสั่งซื้อสูญหายถาวรเมื่อ Redis ล่ม
  - *ทางเลือกที่เลือก*: Stock Overlay Pattern (Cache-Aside สำหรับ Metadata + Fast Atomic Counter สำหรับสต็อกสด)

---

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)
- **การเก็บสต็อกสดรวมไว้ในแคช Metadata ทั้งก้อน**: เมื่อมีคำสั่งซื้อ 50 รายการใน 0.3 วินาที แคชจะถูกล้างทิ้ง 50 ครั้ง ทำให้ผู้อ่าน 1,000 คนเจอ Cache Miss รัวๆ แล้วรุมถล่ม Database จน Crash (Thundering Herd / Cache Stampede)
- **การใช้คำสั่ง `DEL` เพื่อปลด Distributed Lock โดยตรง**: หากคำขอแรกหมดอายุ TTL ไปก่อน คำขอที่สองจะได้ Lock ไป แล้วคำขอแรกกลับมาสั่ง `DEL` จะกลายเป็นการลบ Lock ของคนอื่นทิ้ง (Split-Brain) ต้องแก้ด้วย Compare-and-Delete Lua Script เสมอ
- **การสั่ง Invalidate แคชก่อนการ UPDATE ในฐานข้อมูล**: เกิด Race Condition ที่มีคำขออ่านแทรกกลาง ดึงค่าเก่าจาก DB ไปเติมแคชคืน ทำให้แคชค้างค่าเก่าถาวรจนกว่า TTL จะหมด

---

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์
- **ไม่มี**: สถาปัตยกรรมและพารามิเตอร์ทั้งหมด (`CATALOG_FLUSH_MIN_INTERVAL_MS = 1000`, TTL Jitter 30–60s, BullMQ Concurrency 5, Connection Pool 8 ต่อ instance) ได้รับการพิสูจน์และอ้างอิงตรงกับบทเรียน `Backend01`–`Backend06` และการตั้งค่าจริงในระบบเรียบร้อยแล้ว

---

## 6. ก้าวถัดไป (เรียงลำดับ)
1. **ทีม Backend & Frontend**: ใช้อ้างอิง [`docs/Backend_design/architecture-primer.md`](../Backend_design/architecture-primer.md) เป็นคู่มือทำความเข้าใจระบบ Concurrency & Locking ก่อนพัฒนาฟังก์ชันเกี่ยวกับสต็อกและการเงิน
2. **การนำเสนอ & รายงาน**: นำ Sequence Diagrams (Read Path §3.1, Write Path §3.2, State Machine §7) ไปใช้ประกอบรายงานเชิงวิชาการและสไลด์นำเสนอหน้าห้อง

---

## 7. ข้อควรระวัง
- **ห้ามสั่ง Invalidate แคชทุกครั้งที่มีการซื้อขาย**: ต้องใช้ Stock Overlay และ Debounce Throttle ไม่เกิน 1 ครั้งต่อวินาที
- **ห้ามสั่งคืนสต็อก (`compensateOnce`) ในจังหวะ Retry ของ Worker**: การคืนสต็อกต้องทำเฉพาะเมื่อ Job ล้มเหลวใน Final Attempt เท่านั้น มิฉะนั้นสต็อกใน Redis จะบวมเกินจริงเมื่อการลองใหม่สำเร็จ
- **ห้ามใช้คำสั่ง `KEYS *` ใน Redis**: คำสั่งนี้ทำงานแบบ $O(N)$ จะบล็อก Redis ทั้งเซิร์ฟเวอร์จนระบบหยุดทำงาน

---

## 8. อ้างอิง
- แม่แบบการเขียนเอกสาร: `primer-template.md` (Commit `1c648aa`)
- สเปกสถาปัตยกรรม: [`docs/Backend_design/architecture.md`](../Backend_design/architecture.md)
- เอกสารปูพื้นฐาน: [`docs/Backend_design/architecture-primer.md`](../Backend_design/architecture-primer.md)
- เอกสารเดิมของระบบ: [`docs/Backend_design/00_BASICS.md`](../Backend_design/00_BASICS.md), [`docs/Backend_design/03_ARCHITECTURE.md`](../Backend_design/03_ARCHITECTURE.md)
- บทเรียนอาจารย์: สไลด์และสรุปบทเรียนวิชา `Backend01` ถึง `Backend06` (Transactions, Locking, Redis, Queue, Scaling)
