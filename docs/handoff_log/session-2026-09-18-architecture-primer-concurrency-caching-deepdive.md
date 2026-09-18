# Handoff: Architecture Primer & Concurrency Locking / Caching Deep Dive

> **วันที่**: 2026-09-18  
> **หมวดงาน**: Documentation & Architecture Engineering Primer  
> **ไฟล์ที่เพิ่ม/แก้ไข**:
> - [`docs/Backend_design/architecture-primer.md`](../Backend_design/architecture-primer.md) (เพิ่มใหม่ 997 บรรทัด ครบ 13 หัวข้อ §0–§12)
> - [`docs/Backend_design/architecture.md`](../Backend_design/architecture.md) (เพิ่มใหม่ ครอบคลุมสเปก §5.5 Caching & §6.5 Locking)
> - [`docs/Backend_design/00_INDEX.md`](../Backend_design/00_INDEX.md) (เพิ่มดัชนีชี้ทั้ง 2 ไฟล์)
> - [`docs/Backend_design/03_ARCHITECTURE.md`](../Backend_design/03_ARCHITECTURE.md) (เพิ่ม callout ชี้ primer)
> - [`docs/handoff_log/INDEX.md`](INDEX.md) (อัปเดตสารบัญ)

---

## 1. 🎯 วัตถุประสงค์และที่มาของเอกสาร

ทีมพัฒนา backend ของโปรเจกต์นี้ใช้สแตกตามที่อาจารย์กำหนดสำหรับวิชา Backend/Mobile Architecture:
**Nginx (Load Balancer) $\to$ NestJS ($\ge 3$ instances) $\to$ PostgreSQL (TypeORM) + Redis (Cache/Data) + BullMQ (Queue) + JWT Stateless**

ในการพัฒนาฟังก์ชันที่มีการแย่งชิงทรัพยากรสูง (Concurrency) เช่น การตัดสต็อกสินค้าใน `POST /sales`, การคืนสินค้า `POST /returns`, การตัดยอดเครดิตช่าง, และการแคชหน้าแคตตาล็อกสินค้า จำเป็นต้องมีเอกสารที่ปูพื้นฐานเชิงวิศวกรรมตั้งแต่นิยามพื้นฐาน (Pedagogical Baseline) เพื่อให้ทุกคนในทีมและผู้ตรวจเข้าใจ **"ทำไมถึงเลือกเทคนิคนี้ และทำไมเทคนิคทั่วไปในตำราจึงล้มเหลว"**

เอกสาร [`docs/Backend_design/architecture-primer.md`](../Backend_design/architecture-primer.md) ถูกสร้างขึ้นตามแม่แบบ `primer-template.md` ครอบคลุมเนื้อหาบทเรียน `Backend01` ถึง `Backend06` ของอาจารย์ และผ่านการทำ Review / Fix / Scrutinize ครบ 2 รอบ

---

## 2. 📚 สรุปเนื้อหาสำคัญใน `architecture-primer.md`

1. **บันไดความรู้ (Knowledge Ladder — กติกา ป1)**:
   - กำหนด **FLOOR**: REST API, HTTP Status Codes, SQL พื้นฐาน, TypeScript, Node.js Event Loop
   - สอน **18 ศัพท์สำคัญใน FROM_ZERO** แบบครบ 5 ช่อง (ปัญหาเดิม, นิยามหนึ่งประโยค, อุปมาที่ยึดกับ FLOOR, ในงานจริงคือตัวไหน, กับดักของศัพท์นี้) โดย `สอนที่ == ใช้ครั้งแรกที่` เสมอ
2. **เจาะลึกเทคนิค Concurrency & Locking (§4, §6.5)**:
   - **Optimistic Locking (`@VersionColumn`)**: อธิบายกลไก และชี้จุดตายเมื่อเกิด High Contention ที่ผู้ใช้แย่งซื้อสินค้าพร้อมกัน จะเกิด **Retry Storm** นับแสนครั้งถล่มจน PostgreSQL CPU 100%
   - **Pessimistic Locking (`SELECT ... FOR UPDATE`)**: อธิบายกลไก Exclusive Row Lock และชี้จุดตายบน Synchronous HTTP Path ที่จะทำให้เกิด **Connection Pool Starvation** (Pool 48 connections ถูกยึดค้าง) จนเกิด 504 Gateway Timeout
   - **Distributed In-Flight Lock (`SET NX PX`)**: การป้องกัน Double-click ระดับผู้ใช้ด้วย Compare-and-Delete Lua Script (`release-lock.lua`)
   - **ยุทธศาสตร์ที่เลือกใช้จริง (4-Tier Defense Architecture)**:
     - Tier 1: Redis Lua Gatekeeper (`gatekeeper.lua`) สกัด 90%+ ที่ขอบระบบใน ~1ms
     - Tier 2: BullMQ Queue ตอบ 202 Accepted ทันที ไม่ผูกกับ Disk I/O
     - Tier 3: PostgreSQL Atomic Decrement (`UPDATE ... WHERE remaining_stock > 0`) ถือ Exclusive Row Lock สั้นที่สุดระดับซับมิลลิวินาที
     - Tier 4: Database Constraints (`CHECK`, `UNIQUE`) การันตีความถูกต้องระดับคณิตศาสตร์
   - **Deadlock (`40P01`) และ Lock Hierarchy**: กฎการจัดลำดับ Lock (อัปเดต Products ก่อน Orders เสมอ) และการ Retry พร้อม Exponential Backoff + Jitter
3. **เจาะลึกเทคนิค Caching & Invalidation (§5, §5.5)**:
   - **Latency Hierarchy**: เปรียบเทียบ RAM (Redis) เร็วกว่า Disk (PostgreSQL) 10,000–50,000 เท่า
   - **วิเคราะห์ 3 Caching Patterns**: Cache-Aside (Lazy Loading) vs Write-Through vs Write-Behind
   - **Stock Overlay Pattern**: การแยก Static Metadata Cache (`redis-cache`, LRU, TTL 30–60s) ออกจาก Dynamic Stock Counter (`redis-data`, noeviction, AOF) ป้องกันปัญหาแคชแตกเมื่อมีคำสั่งซื้อ
   - **กลยุทธ์ Invalidation**: ลำดับการ Update DB ก่อน Del Cache, แบนคำสั่ง $O(N)$ `KEYS *` (ใช้ Catalog Index Set แทน), Debounced Invalidation (`CATALOG_FLUSH_MIN_INTERVAL_MS = 1000`)
   - **การป้องกันระบบล่ม**: In-Process Single-Flight Promise Memoization (`flightMap`) กัน Cache Stampede, และ TTL Jitter (`30 + Math.floor(Math.random() * 30)`s) กัน Cache Avalanche
4. **State Machine, Failure Matrix, และ Self-Test**:
   - วิเคราะห์ State Machine ของออเดอร์และการรับประกันความปลอดภัยของสถานะอันตราย `IN_FLIGHT`
   - ตารางความผิดพลาด 9 ประการในระดับการรู้ตัว (❌ เงียบสนิท, 🟡 เห็นอาการแต่หายาก, ✅ พังทันที, ✅(สาย) รู้ตัวตอนสาย)
   - 11 ข้อคำถามทดสอบตัวเองเชิงสถาปัตยกรรมพร้อมเฉลยละเอียด

---

## 3. 🔍 การตรวจสอบความถูกต้อง (Review & Audit Status)

- ผ่านการตรวจสอบตามเกณฑ์ 11 ข้อของ `primer-template.md` **ผ่านครบ 11/11 ข้อ (100%)**
- ลิงก์ภายในเชื่อมโยงกับเอกสาร [`00_BASICS.md`](../Backend_design/00_BASICS.md), [`01_DATABASE.md`](../Backend_design/01_DATABASE.md), [`02_API_SCREENS.md`](../Backend_design/02_API_SCREENS.md), [`03_ARCHITECTURE.md`](../Backend_design/03_ARCHITECTURE.md), [`04_QA_SCRUTINY.md`](../Backend_design/04_QA_SCRUTINY.md), และ [`adr/`](../Backend_design/adr/README.md) อย่างสมบูรณ์
