# รายงานความก้าวหน้าโครงงาน (240-401)

- `progress-report-P1.docx` — ฉบับส่ง (แม่แบบคณะ, TH Sarabun New) · `progress-report-P1.pdf` — ฉบับดูตัวอย่าง
- ข้อความที่ **ไฮไลต์สีเหลือง** ต้องเติม/ยืนยันก่อนส่ง: ชื่อ-รหัสสมาชิก, อาจารย์ที่ปรึกษา, ครั้งที่/วันที่ส่ง,
  นิยาม "เจ้าของโครงงาน" (บทที่ 1), ประโยคเปิดหัวข้อการใช้ AI ช่วยพัฒนา (บทที่ 3 — เทียบนโยบายของคณะ)
- ตัวเลขสถิติในรายงานวัด ณ 2026-10-01 (HEAD `42b07eb`); เนื้อหาปรับถึง 2026-10-04 (HEAD `f2827ed`): APK workflow (#551, รันแล้ว ได้ `apk-e191755`/`apk-ff84fd3` แต่ยังไม่มีบันทึกการทดสอบบนอุปกรณ์จริง), TLS CA ส่วนตัว (#552, ติดตั้งบน mob04 ตั้งแต่ deploy `7ea0178` และคอมมิต CA แล้วใน #559), การทดสอบใช้งานบน mob04 และการแก้ไข #578–#595, deploy `f2827ed` เมื่อ 2026-10-04; 2026-10-04 เพิ่มหัวข้อ "การขยายการเฝ้าสังเกตระบบ (1–4 ตุลาคม)" ในบทที่ 4 และงานถัดไปข้อ 11 ในบทที่ 5 (#596, #597 รวมแล้ว; ยังไม่ deploy/ติดตั้งบน mob04); 2026-10-04 (ค่ำ) แก้สถานะหัวข้อการเฝ้าสังเกตระบบ: #597 deploy แล้ว (`41a8f19`, ยืนยัน `.current_sha`), heartbeat ยังไม่ติดตั้ง, เพิ่มตัวเลขหน่วยความจำของ `mob04`; 2026-10-04 (ดึก) heartbeat ติดตั้งบน `mob04` แล้ว (ด้วยมือ, §7b) และ PR #606 (ตัวอ่านคิว single-flight) deploy แล้ว (`7444ea4`)

## สร้างใหม่จากต้นฉบับ (`src/`)
เนื้อหาอยู่ใน `src/chapters/*.md` (รูปแบบใน `src/BRIEF.md`), ปกใน `src/cover.json`, แผนภาพใน `src/diagrams/`
(HTML/SVG → PNG ด้วย Edge headless). ต้องมี Python + `python-docx` และ Microsoft Word (สำหรับอัปเดตสารบัญ/export PDF)

```bash
cd docs/report/src
python build.py out.docx
powershell -File finalize.ps1 -In "$PWD\out.docx" -Out "$PWD\out_final.docx" -Pdf "$PWD\out.pdf"
```

บน macOS ไม่มี `finalize.ps1`: เปิดไฟล์ด้วย Word ทาง AppleScript โดย**อ้างเอกสารด้วยชื่อไฟล์เท่านั้น** (ห้ามใช้ `active document`
— จะไปทำกับเอกสารอื่นที่เปิดค้าง) แล้ว `update (table of contents 1 of d)` และ `update (table of figures i of d)` สองรอบ
ก่อน `save as` เป็น docx และ PDF · field อื่น (เลขรูป/ตาราง) `build.py` ใส่ค่าไว้แล้ว AppleScript update ทีละ field ไม่ได้

`src/review/` เก็บผลการตรวจ (ข้อเท็จจริง, /scrutinize 4 มุม) ที่นำมาแก้แล้ว
