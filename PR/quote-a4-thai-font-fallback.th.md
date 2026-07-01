# PR: ตัวอักษรไทยเพี้ยนในใบเสนอราคา A4 (PDF) — แก้ด้วย font fallback

**วันที่พบบั๊ก:** 2026-06-30
**วันที่แก้:** 2026-06-30 (commit `2aaee0a`)
**Branch:** `fix/quote-a4-thai-font-fallback`
**Commit:** `2aaee0a`
**ไฟล์:** `lib/presentation/widgets/quote_a4_view.dart`

---

## ⚡ สรุปสั้น (TL;DR)

Thai font (Sarabun) **โหลดอยู่แล้ว** — บั๊กไม่ได้เกิดจาก font หาย.
ปัญหาคือ PDF ไม่รู้ว่าให้ **ใช้** Sarabun ตอน Barlow วาดตัวไทยไม่ได้.
Fix = บอก PDF ว่า "Barlow วาดบ่ได้ → ตกไปใช้ Sarabun" ผ่าน `fontFallback`.

**ไม่ใช่โหลด font เพิ่ม — แต่บอกให้ใช้ font ไทยที่มีอยู่แล้วเป็นตัวสำรอง.**

---

## 🐞 บั๊กคืออะไร

ใบเสนอราคา A4 (PDF) วาดข้อความ label (ไทย+อังกฤษ) ด้วย font **Barlow Condensed**
ซึ่งเป็น display font อังกฤษล้วน **ไม่มี glyph ไทย** และ **ไม่มี fallback font**.
ผลคือ ตัวอังกฤษแสดงปกติ แต่ตัวไทยกลายเป็นกล่องสี่เหลี่ยม (`.notdef` box — □□□□).

Console error:
```
Unable to find a font to draw "ใ" (U+e43)
```

label ที่พัง:
`เสนอแก่ · TO`, `เลขที่`, `วันที่`, `ใช้ได้ถึง`, `ผู้ออก`,
`รายการ · DESCRIPTION`, `หมายเหตุ · NOTES`, `ผู้เสนอราคา · QUOTED BY`, `ผู้อนุมัติ · APPROVED BY`.

---

## 📍 หน้าไหน

หน้าขายสินค้า → สร้างใบเสนอราคา → เมนู **ใบเสนอราคา** → กด **ดู** → PDF preview A4.
Widget: `QuoteA4View` ไฟล์ `lib/presentation/widgets/quote_a4_view.dart`.

---

## 🔁 ขั้นตอนทำให้เห็นบั๊ก

1. เปิดหน้าขายสินค้า.
2. ใส่สินค้า แล้วสร้างใบเสนอราคา.
3. ไปเมนู **ใบเสนอราคา**.
4. กด **ดู** ที่ใบเสนอราคา.
5. ดู label ใน PDF A4 → ตัวไทยเป็นกล่อง. 🐞

---

## 🧠 ทำไมถึงพัง

font วาดได้แค่ glyph ที่ตัวเองมี. Barlow Condensed มีแต่ตัว Latin.
พอ renderer เจอ `ใ` ที่ไม่มี glyph → วาด `.notdef` box.
**fallback font** คือตัวบอก renderer ว่า "ถ้า font นี้วาดไม่ได้ ให้ลอง font ถัดไป".
เดิมไม่ได้ตั้ง fallback → ไม่มีตัวช่วย → เป็นกล่อง.

---

## 🔧 วิธีแก้

เพิ่ม `fontFallback: [base, bold, semi]` (Sarabun — มี glyph ไทย) ที่ theme ของ PDF document.
package `pdf` จะส่ง fallback ของ theme ไปให้ **ทุก** `TextStyle` แม้ตัวที่ override `font:` เอง.
ผลคือ ตัว Latin ยังสวยแบบ Barlow display ส่วนตัวไทยตกไปใช้ Sarabun.

---

## 📝 โค้ดที่เปลี่ยน

ไฟล์: `lib/presentation/widgets/quote_a4_view.dart` (ใน `_buildPdf`, ~บรรทัด 77)

### ❌ ก่อน (พัง — ตัวไทยเป็นกล่อง)
```dart
final doc = pw.Document(
  theme: pw.ThemeData.withFont(base: base, bold: bold),
);
```

### ✅ หลัง (แก้แล้ว — ตัวไทยแสดงถูก)
```dart
final doc = pw.Document(
  // The display headings use Barlow Condensed (cond), which has NO Thai
  // glyphs. The labels mix Thai + EN (e.g. 'เสนอแก่ · TO'), so without a
  // fallback the Thai half renders as .notdef boxes. Sarabun fonts as the
  // theme-wide fallback render any non-Latin glyph; the fallback is
  // inherited by every TextStyle even when it overrides `font:`.
  theme: pw.ThemeData.withFont(
    base: base,
    bold: bold,
    fontFallback: [base, bold, semi],
  ),
);
```

font ที่ load ไว้ด้านบน (มีอยู่แล้ว):
```dart
final base = await PdfGoogleFonts.sarabunRegular();
final bold = await PdfGoogleFonts.sarabunBold();
final semi = await PdfGoogleFonts.sarabunSemiBold();
final cond = await PdfGoogleFonts.barlowCondensedBold();
```

---

## ✅ ผลลัพธ์

label ภาษาไทยแสดงถูกต้องในใบเสนอราคา PDF A4. อังกฤษยังเป็น style Barlow. ไม่มี `.notdef` box อีก.
