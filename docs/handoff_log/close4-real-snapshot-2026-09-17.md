# Handoff — #185 `close.4`: นำเข้า Snapshot ร้านจริงผ่าน Checklist 6 ข้อ (`01_DATABASE.md §9`)

**วันที่:** 2026-09-17  
**ผู้ดำเนินการ:** NuimanLP (`team/1`, Lane A)  
**สถานะ:** ปิดแล้ว (DoD Phase 1 ติ๊กใน `03_ARCHITECTURE.md §8`)  
**ไฟล์ที่ใช้ทดสอบ:** `pos-backup-20260916.json` (14.2 KiB)  

---

## 1. ผลการรัน Pre-flight & Import

รันคำสั่ง e2e ตามคู่มือ #185:
```bash
SNAPSHOT_FILE=/Users/chav_sir/Downloads/pos-backup-20260916.json \
RECONCILE_OUT=/tmp/evidence-pos-backup-reconciled.json \
pnpm test:e2e test/import-snapshot.e2e-spec.ts
```

- **Pre-flight Violations:** `0`
- **Orphans:** `0` (ไม่มี foreign key หลุด)
- **Tombstones:** `0`
- **Import Status:** `succeeded` (เวลา 204 ms)

---

## 2. ผลการ Reconcile 6 ข้อตาม `01_DATABASE.md §9` (ไม่เปิดเผยข้อมูลส่วนบุคคล PDPA)

| ข้อ | รายการที่ตรวจสอบ | ผลที่คาดหวัง | ผลจริงใน PostgreSQL | สถานะ |
|---|---|---|---|---|
| **5.1** | ยอดขายรวม `SUM(sales.total)` | 33,700.00 บาท (3,370,000 สตางค์) | 33,700.00 บาท | ✅ ผ่าน |
| **5.2** | ยอดสต็อกรวม `SUM(products.stock)` | 191 ชิ้น | 191 ชิ้น | ✅ ผ่าน |
| **5.3** | จำนวนเรคคอร์ดครบ 18 ตาราง | | | |
| | - `products` | 10 | 10 | ✅ ผ่าน |
| | - `suppliers` | 6 | 6 | ✅ ผ่าน |
| | - `customers` | 3 | 3 | ✅ ผ่าน |
| | - `mechanics` | 3 | 3 | ✅ ผ่าน |
| | - `sales` | 5 | 5 | ✅ ผ่าน |
| | - `sale_items` | 17 | 17 | ✅ ผ่าน |
| | - `movements` | 10 | 10 | ✅ ผ่าน |
| | - `shifts` | 5 | 5 | ✅ ผ่าน |
| | - `settings` | 1 | 1 | ✅ ผ่าน |
| **5.4** | แต้มและยอดซื้อสะสมของลูกค้าทุกคน | ต่างกัน 0 คน (ตรง 100%) | ต่างกัน 0 คน | ✅ ผ่าน |
| **5.5** | ยอดหนี้คงเหลือของช่างทุกคน | ต่างกัน 0 คน (ตรง 100%) | ต่างกัน 0 คน | ✅ ผ่าน |
| **5.6** | ยอดเงินสดในลิ้นชักของกะล่าสุด | 1,000.00 บาท (100,000 สตางค์) | 1,000.00 บาท | ✅ ผ่าน |

---

## 3. สรุป
- การนำเข้าข้อมูลผ่าน Checklist 6 ข้อใน `01_DATABASE.md §9` ครบถ้วน 100%
- ปิด Ticket #185 และติ๊ก DoD ใน `03_ARCHITECTURE.md §8`
