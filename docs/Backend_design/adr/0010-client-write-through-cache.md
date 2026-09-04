# ADR-0010 — client เก็บ Drift เป็น write-through cache และ map ที่ชั้น repository

* **สถานะ:** Accepted — 2026-09-04
* **ผู้ตัดสิน:** เจ้าของโปรเจกต์
* **ปิดข้อค้าง:** ความขัดแย้งระหว่าง `03_ARCHITECTURE §8` (Gantt งาน `q1`) กับ §4 (Architecture C)

## บริบท — เอกสารสองที่ในไฟล์เดียวกันสั่งตรงข้ามกัน

Gantt ใน `§8` เขียนงาน `q1` ว่า **"Flutter ApiRepository (แทน Drift repos)"** — คำว่า *แทน*
อ่านได้อย่างเดียวว่า **ลบ Drift ทิ้งแล้วยิง HTTP แทน**

แต่ `§4` (Architecture C ซึ่งเป็นสถาปัตยกรรมที่เลือก) ระบุว่าตอน **Online** ต้อง
*"cache สินค้า + โควตาสต็อกไว้ในเครื่อง"* และตอน **Degraded** ต้องขายจาก cache นั้นได้

→ ถ้า `q1` ลบ Drift จริงตามที่ Gantt เขียน **งาน `q2` (outbox + offlineOk) จะไม่มีอะไรให้อ่าน**
ต้องสร้าง cache ขึ้นมาใหม่ทั้งชุด = รื้อของที่เพิ่งลบไปเมื่อสองเดือนก่อน

## ทางเลือกที่พิจารณา

| | แนวทาง | ทำไมไม่เอา |
|---|---|---|
| (ก) | **write-through** — `ApiRepository` implement interface เดิม ยิง server แล้วเขียนผลลง Drift | ✅ **เลือกอันนี้** |
| (ข) | **แทนก่อน แล้วค่อยเอา offline กลับมา** (ตาม Gantt เดิม) | ทิ้งชั้น offline ที่ใช้งานได้อยู่แล้ว แล้วสร้างใหม่ — ประมาณการ 20 วันของ `q1` จะกลายเป็นสองเท่า |
| (ค) | **Drift เป็น cache โง่ ๆ เก็บ JSON blob** | `offlineOk` ต้องประเมิน `stock ≥ threshold` ในเครื่อง ซึ่ง query บน blob ไม่ได้ |

## การตัดสินใจ

**1. Drift ยังอยู่ ทำหน้าที่ write-through cache**

`ApiRepository` implement **interface repository เดิม** ยิง server เป็นแหล่งความจริง
แล้วเขียนผลลัพธ์ลง Drift ทุกครั้ง — หน้าจอไม่ต้องแก้แม้แต่ไฟล์เดียว เพราะ `CONTRACT.md`
บังคับไว้แต่ต้นว่า **หน้าจอคุยกับ repository provider ไม่ใช่ `AppDatabase`**
รอยต่อนี้คือสิ่งที่การออกแบบเดิมซื้อไว้ให้แล้ว

**2. schema ทั้งสองฝั่งไม่ต้องเหมือนกัน — แปลงที่ชั้น repository**

Postgres มี 28 ตาราง Drift มี 20 (+ ที่เพิ่มใน schema v2) **ไม่ regenerate Drift ให้ mirror Postgres**
`ApiRepository` แปลง JSON → Drift row ด้วยมือ

* schema ฝั่ง client **หยุดขยับ** — migration ฝั่ง server ไม่ลากเป็น client release ทุกครั้ง
* test 123 ตัวที่เขียนไว้กับ schema เดิม **ยังใช้ได้ทั้งหมด**
* ต้นทุนที่ยอมจ่าย: โค้ด mapping น่าเบื่อและต้องเขียนเอง — แต่มันคือชั้นที่ทำให้เห็นตอน
  field ฝั่ง server ความหมายไม่ตรงกับที่ client สมมติไว้ ซึ่ง mirror อัตโนมัติจะกลืนหายไปเงียบ ๆ

## ผลที่ตามมา

* **`03_ARCHITECTURE §8` ต้องแก้คำ** — `q1` ไม่ใช่ *"แทน Drift repos"* แต่เป็น
  *"เพิ่ม ApiRepository เป็น implementation ใหม่ของ interface เดิม"*
* ทุกวันที่ทำ `q1` **ยังได้ client ที่ใช้ต่อได้ตอนเน็ตหลุด** ไม่มีช่วงที่แอปกลายเป็น online-only
  — สำคัญ เพราะร้านใช้ build นี้ขายของอยู่จริง
* 🔴 **`products.updatedAt` ต้องต่อสายให้เขียนจริงก่อนเริ่ม `q2`** — วันนี้แอปไม่เคยเขียนค่านี้
  มันแค่วิ่งผ่าน snapshot ไปกลับ ถ้า sync ใช้ `?updatedSince=` บน products จะพังเงียบ

## ยังไม่เคาะ

* [ ] cache invalidation ฝั่ง client — Drift ที่ค้างอยู่จะถือว่าหมดอายุเมื่อไหร่ (TTL? ตอน login? ตอน sync เสร็จ?)
* [ ] อ่านตอน Online อ่านจาก Drift ก่อนแล้ว refresh (stale-while-revalidate) หรือรอ server เสมอ
