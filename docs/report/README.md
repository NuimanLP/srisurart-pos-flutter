# รายงานความก้าวหน้าโครงงาน (240-401)

- `progress-report-P1.docx` — ฉบับส่ง (แม่แบบคณะ, TH Sarabun New) · `progress-report-P1.pdf` — ฉบับดูตัวอย่าง
- ข้อความที่ **ไฮไลต์สีเหลือง** ต้องเติม/ยืนยันก่อนส่ง: ชื่อ-รหัสสมาชิก, อาจารย์ที่ปรึกษา, ครั้งที่/วันที่ส่ง,
  นิยาม "เจ้าของโครงงาน" (บทที่ 1), ประโยคเปิดหัวข้อการใช้ AI ช่วยพัฒนา (บทที่ 3 — เทียบนโยบายของคณะ)
- ตัวเลขในรายงานวัด ณ 2026-10-01 (HEAD `42b07eb`); เพิ่มงาน APK workflow (#551) และ TLS CA ส่วนตัว (#552, #553) ที่รวมเมื่อ 2026-10-03 (สถานะ: ยังไม่เคยรัน APK และยังไม่ติดตั้ง CA บน mob04)

## สร้างใหม่จากต้นฉบับ (`src/`)
เนื้อหาอยู่ใน `src/chapters/*.md` (รูปแบบใน `src/BRIEF.md`), ปกใน `src/cover.json`, แผนภาพใน `src/diagrams/`
(HTML/SVG → PNG ด้วย Edge headless). ต้องมี Python + `python-docx` และ Microsoft Word (สำหรับอัปเดตสารบัญ/export PDF)

```bash
cd docs/report/src
python build.py out.docx
powershell -File finalize.ps1 -In "$PWD\out.docx" -Out "$PWD\out_final.docx" -Pdf "$PWD\out.pdf"
```

`src/review/` เก็บผลการตรวจ (ข้อเท็จจริง, /scrutinize 4 มุม) ที่นำมาแก้แล้ว
