# การตรวจสอบสลิปโอนเงิน (e-Slip verification) สำหรับ POS ร้านอะไหล่ — ผลวิจัย

- วันที่เก็บข้อมูล: **2026-10-10** (ทุกข้อเท็จจริงด้านล่างอ่านจากหน้าเว็บในวันนี้ ราคาและเงื่อนไขเปลี่ยนได้)
- ขอบเขต: research อย่างเดียว ไม่มีโค้ด ไม่แตะ git
- สัญลักษณ์: **[ยืนยัน]** = อ่านจากหน้า primary ของเจ้าของข้อมูล, **[อนุมาน]** = ข้อสรุปของผู้วิจัยจากข้อเท็จจริงที่ยืนยันแล้ว, **[ยืนยันไม่ได้]** = หาหลักฐาน primary ไม่เจอ

---

## 0. สรุปสั้น (TL;DR)

1. สลิปโอนเงินของไทยมี **mini-QR** ที่ไม่ได้บรรจุยอด/ผู้รับ/เวลา แต่บรรจุแค่ **รหัสธนาคารผู้ส่ง (3 หลัก) + transRef** ผู้ตรวจต้องเอา 2 ค่านี้ไปถามธนาคารผ่าน API เพื่อได้ข้อมูลจริง
2. ไม่มีเอกสารของ ธปท. (BOT) ที่ตั้งเป็น "มาตรฐานตรวจสลิปสำหรับร้านค้า" ให้อ่านได้ **[ยืนยันไม่ได้]** ข้อกำหนดโครงสร้าง mini-QR ที่ยืนยันได้มาจากเอกสาร SCB Developers และไลบรารี open source เท่านั้น
3. API แบบ "ธนาคารตรง" (SCB, BBL, KBank) ใช้ได้เฉพาะ **ผู้รับชำระที่ลงทะเบียนเป็น biller/partner กับธนาคารนั้น** ไม่เหมาะกับร้านเดียวที่รับโอนเข้าบัญชี/พร้อมเพย์ธรรมดา และต้องต่อทีละธนาคาร **[อนุมาน]** จากฟิลด์ `billerId` ที่บังคับ
4. ตัวกลางเชิงพาณิชย์ที่มีอยู่จริงและมีเอกสารสาธารณะ: **EasySlip, SlipOK, Slip2Go, Thunder Solution, RDCW Slip Verify** (ชื่อ "Thunder" ที่ผู้ใช้ถามคือ Thunder Solution; "RDCW" เป็นอีกเจ้าหนึ่ง ไม่ใช่เจ้าเดียวกัน)
5. ทุกเจ้าเป็น **outbound HTTPS จาก server ของเราไปหาเขา** ไม่ต้องมี inbound callback ถ้าใช้ endpoint แบบ synchronous (Queue/Async ของ Slip2Go/EasySlip เท่านั้นที่ต้องการ webhook หรือ poll)
6. **ห้ามเชื่อ API อย่างเดียว** POS ต้องทำเอง: `UNIQUE(transRef)`, เทียบบัญชีผู้รับ, เทียบยอด, เทียบเวลา, และเก็บผลดิบไว้เป็นหลักฐาน
7. คำแนะนำ: **EasySlip API v2 เป็นตัวหลัก, Slip2Go เป็นตัวสำรอง/ราคาถูกสุด** (เหตุผลและเงื่อนไขในหัวข้อ 4) และต้องมีเส้นทาง "แคชเชียร์อนุมัติเอง" เมื่อ vendor ล่ม เพราะ **ไม่มีเจ้าไหนประกาศ SLA เป็นลายลักษณ์อักษร**

---

## 1. สลิปตรวจสอบได้อย่างไร: mini-QR

### 1.1 mini-QR คืออะไร

- ไม่ใช่ QR สำหรับจ่ายเงิน หน้าที่เดียวคือป้อนข้อมูลอ้างอิงให้ Open API ของธนาคารค้นหารายการหลังอ่านภาพสลิป — ไลบรารี `thai-qr-payment` (เอกสาร third-party แต่ตรงกับสเปก SCB ด้านล่าง) https://thai-qr-payment.js.org/guide/slip-verify/ [ยืนยัน, 2026-10-10]
- ใครก็ได้สแกน QR บน e-Slip ด้วยแอปธนาคารใดก็ได้เพื่อดูผู้โอน/ผู้รับ/ยอด/เวลา — ธนาคารกรุงเทพ https://www.bangkokbank.com/th-TH/Personal/Tips-and-Insights/Verify-eSlip (ผ่านผลสรุปการค้นหา; หน้าเว็บ fetch ตรงไม่สำเร็จเพราะ timeout) และ Krungsri https://www.krungsri.com/th/plearn-plearn/lifestyle/living/how-to-check-fake-slip [ยืนยัน]; SCB แนะนำให้ทดสอบ e-Slip ด้วยการสแกน QR เช่นกัน https://www.scb.co.th/th/personal-banking/stories/tips-for-you/check-transfer-slip.html [ยืนยัน]

### 1.2 โครงสร้างข้อมูล (TLV, EMVCo-style)

จากเอกสารของ SCB "Extracting data from mini QR" (สร้างไฟล์ 2019-06-25) https://developer.scb/assets/documents/documentation/qr-payment/extracting-data-from-mini-qr.pdf [ยืนยัน, อ่านด้วย pdftotext 2026-10-10] และไลบรารี https://thai-qr-payment.js.org/guide/slip-verify/:

| Tag | ความหมาย | หมายเหตุ |
|---|---|---|
| 00 (parent) | payload | ประกอบด้วย sub-tag ด้านล่าง |
| 00.00 | API ID | `000001` = "Verify Pay Slip API" |
| 00.01 | Sending bank ID | รหัส ธปท. 3 หลัก เช่น `002` BBL, `014` SCB (ในเอกสาร SCB ระบุ hardcode `014` เพราะเป็นสเปกของ SCB เอง) |
| 00.02 | Transaction Ref | ยาวสูงสุด 25 ตัว รูปแบบ Nov 2018 = `YYYYMMDD + rand(0-9) + traceID` |
| 51 | Country code | `TH` |
| 91 | CRC | CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) |

ตัวอย่างจากเอกสาร SCB: `002702232019062543mc8k3ykZbndfi5102TH910377E`

**ข้อสรุปสำคัญ [อนุมาน จากตารางข้างต้น]:** QR ไม่มี **ยอดเงิน ผู้รับ หรือเวลา** — ทุกอย่างต้องมาจากการ query ธนาคาร ดังนั้นสลิปที่ตัดต่อตัวเลขบนภาพแต่ QR เดิมยังคง "scan ผ่าน" ได้ ถ้าเราไปอ่านตัวเลขจากภาพแทนผลลัพธ์ API (ดู §3)

ยังมีรูปแบบของ TrueMoney Wallet อีกแบบ (tag 00 มี marker `01`,`01`, event `P2P`, transaction id, วันที่ DDMMYYYY) — เฉพาะไลบรารี https://thai-qr-payment.js.org/guide/slip-verify/ ไม่พบสเปกทางการ [ยืนยันไม่ได้ ในฝั่งต้นทาง]

### 1.3 ธนาคารใดออก mini-QR

- **ไม่มีรายชื่อทางการ** ที่หาเจอ [ยืนยันไม่ได้] ธนาคารกรุงเทพระบุว่าตรวจ "ได้ทุกธนาคาร" ด้วยแอปธนาคารใดก็ได้ (หน้า BBL ข้างต้น) แต่นั่นคือคำกล่าวฝั่งผู้ใช้ ไม่ใช่รายการธนาคารผู้ออก
- หลักฐานทางอ้อมที่ดีที่สุด: ตาราง "Slip Age Support" ของ EasySlip ครอบคลุมแอป 22 รายการ — K PLUS, Make by KBank, SCB EASY, Krungthai NEXT, Bangkok Bank Mobile, Krungsri (KMA), Kept, ttb touch, UOB TMRW, CIMB THAI, CLICX, GSB MyMo, GHB ALL, A-Mobile (BAAC), PromptPay, TISCO, KKP, Dime!, ICBC, Thai Credit, LHB You, TrueMoney Wallet https://document.easyslip.com/en/reference/slip-age-support [ยืนยัน, 2026-10-10] — ใช้เป็น "ธนาคารที่ vendor ตรวจได้" ไม่ใช่ "ธนาคารที่ออก mini-QR ทุกใบ"

### 1.4 อายุสลิปที่ตรวจได้ (สำคัญต่อการ "ตรวจตอนขาย")

| แอป | ตรวจย้อนหลังได้ (โดยประมาณ) |
|---|---|
| K PLUS, Make, Krungthai NEXT, BBL, UOB, CIMB, CLICX, GHB, BAAC, PromptPay, TISCO, TrueMoney | 30 วัน |
| SCB EASY, Krungsri KMA, Kept, ttb touch, GSB MyMo, KKP, Dime!, ICBC, Thai Credit, LHB | 7 วัน |

แหล่ง: https://document.easyslip.com/en/reference/slip-age-support ระบุเองว่า "approximate and may change"; สลิปเก่าเกินจะได้ `SLIP_NOT_FOUND` — **ต้องตรวจทันทีตอนรับชำระ อย่าเก็บไว้ตรวจทีหลัง**

### 1.5 แนวทาง ธปท. (BOT)

- ค้นบน bot.or.th ไม่พบเอกสารที่กำหนดสเปก/แนวปฏิบัติการตรวจสลิปสำหรับร้านค้า **[ยืนยันไม่ได้]**
- สิ่งที่ ธปท. มีที่เกี่ยวกันแต่ไม่ใช่เรื่องนี้โดยตรง: มาตรฐาน shared responsibility ตาม พ.ร.ก. อาชญากรรมทางเทคโนโลยี (เมษายน 2568) https://www.bot.or.th/th/news-and-media/news/news-20250428.html — เป็นหน้าที่ของ **ธนาคาร** (แจ้งเตือนโอนออก, ระงับธุรกรรม) ไม่ใช่ขั้นตอนตรวจสลิปของร้านค้า [ยืนยัน จากผลสรุปการค้นหา]
- ธนาคารเองแนะนำร้านค้าให้ยืนยันเงินเข้าจริงจากบัญชี/แจ้งเตือนเงินเข้า (LINE/SMS) มากกว่าเชื่อภาพสลิป — Krungsri https://www.krungsri.com/th/plearn-plearn/lifestyle/living/how-to-check-fake-slip [ยืนยัน] — ใช้เป็นแนวปฏิบัติสำรองของแคชเชียร์

---

## 2. เปรียบเทียบบริการ

### 2.1 ตารางรวม

| | **EasySlip** | **SlipOK** | **Slip2Go** | **Thunder Solution** | **RDCW Slip Verify** |
|---|---|---|---|---|---|
| ผู้ให้บริการ | Easy Slip Co., Ltd. | SlipOK | Slip2Go Co., Ltd. | บริษัท ธันเดอร์ โซลูชั่น จำกัด (ขอนแก่น) | RDCW Co., Ltd. |
| Docs ทางการ | https://document.easyslip.com | https://slipok.com/api-documentation/ | https://slip2go.com/guide | https://document.thunder.in.th/th/ | https://slip.rdcw.co.th/docs |
| ฟรี | ทดลอง 7 วัน (ไม่ระบุจำนวน) | **แพ็ก BASIC ฟรี 100 สลิป/เดือน** (2 ร้าน) | ทดลอง 100 สลิป (7 วัน, 50 token) | TESTER 100 สลิป อายุ 15 วัน | ไม่ระบุ |
| ราคาเริ่มต้น | 99 ฿/250 ตรวจ/30 วัน (≈0.40 ฿/ตรวจ) | 350 ฿/500 สลิป; เกินโควตา 0.70 ฿ (รายเดือน) | 88 ฿ → 352 สลิป API (≈0.25 ฿) | 159 ฿/400 สลิป (≈0.40 ฿) | **ไม่แสดงราคา** (prepaid, แพ็ก 30 วัน) |
| ราคา bulk (ตัวอย่าง) | Premium-3 40,000 ฿/320,000 (≈0.125) | GOLD 2,580 ฿/6,000 | BASIC-5 888 ฿/4,826 (≈0.184) | ELITE 49,999 ฿/400,000 (≈0.125) | — |
| Input | payload (QR), image, base64, URL | `data` (QR), `files` (รูป), `url` | QR, รูป, base64, URL, PromptPay QR | payload, image, base64, URL | JSON `payload`, multipart, raw `image/jpeg\|png` |
| ตรวจซ้ำ (duplicate) | `checkDuplicate`; ตอบ `isDuplicate` | `log:true` + error `1012` (ดูข้อสังเกต) | `checkDuplicate`; code `200501` | "built-in" ไม่อธิบายรายละเอียด | **ไม่กล่าวถึง** |
| จับคู่ผู้รับ/ยอดฝั่ง vendor | `matchAccount`, `matchAmount` (v2) | `amount` → `1013`; ผู้รับเทียบกับบัญชีที่ผูกใน LINE LIFF → `1014` | `checkReceiver`, `checkAmount`, `checkDate` | v2: account + amount | ไม่มี |
| Auth | Bearer + IP whitelist | header `x-authorization` + branch id ใน URL | header `Authorization` = Secret Key + IP whitelist (≤10 IP, ค่าเริ่ม `*`) | Bearer + IP whitelist | HTTP Basic (clientId:secret) + IP whitelist (error 1003) |
| Rate limit | ขึ้นกับแพ็ก (TPS), ส่ง `X-RateLimit-*`, `Retry-After`, 429 | ไม่ประกาศ | มี `429000` แต่ไม่ประกาศตัวเลข | ไม่ประกาศ | ไม่ประกาศ (error 1007 "usage exceeded") |
| SLA | ไม่มี SLA; โฆษณา "99.9% uptime" | ไม่ระบุ | ไม่ระบุ (support 24 ชม.) | ไม่ระบุ; โฆษณา "99.9% uptime" | **ไม่มี SLA**; ToS ระบุช่วง Beta ผู้ใช้รับความเสี่ยงข้อมูลผิด/หาย |
| Inbound callback | ไม่ต้อง (sync); async มี `callbackUrl` หรือ poll `/jobs/:id` | ไม่ต้อง | ไม่ต้อง (REST); **Queue API ต้องตั้ง Webhook** (400422) | ไม่ต้อง (sync) | ไม่ต้อง |

แหล่งของแต่ละช่องอยู่ในหัวข้อย่อยด้านล่าง ตัวเลข "≈ ฿/ตรวจ" คำนวณเองจากราคา÷โควตาในหน้าเดียวกัน [อนุมาน]

### 2.2 EasySlip

- ราคา (แพ็ก 30 วัน): Start 99/250, Basic 350/1,000, Starter 700/2,500, Gold 3,500/17,500, Premium-3 40,000/320,000 — https://easyslip.com [ยืนยัน, 2026-10-10]; ทดลองฟรี 7 วัน ไม่ระบุจำนวนตรวจ
- Base URL `https://api.easyslip.com/v2`, `Authorization: Bearer`; `POST /verify/bank`, `/verify/bank/async`, `/verify/bank/batch`, `GET /verify/bank/jobs/:jobId`, `/bank-accounts`, `/banks` — https://document.easyslip.com/en/v2/ [ยืนยัน]
- Request: `payload` | `image` (multipart) | `base64` | `url` (เลือกอย่างเดียว), `remark`, `matchAccount`, `matchAmount`, `checkDuplicate` (default false); ภาพ ≤4 MB, JPEG/PNG/GIF/WebP — https://document.easyslip.com/en/v2/verify/bank/ [ยืนยัน]
- Response: `isDuplicate`, `matchedAccount` (bank, ชื่อ, `bankNumber`, `PERSONAL|JURISTIC`), `amountInOrder`, `amountInSlip`, `isAmountMatched`, `rawSlip` { `payload`, `transRef`, `date` (ISO 8601 +07:00), `countryCode`, `amount.amount`, `fee`, `ref1-3`, `sender`/`receiver` { `bank`, `account.name.th/en`, `account.bank` | `account.proxy`, `merchantId` } } เลขบัญชีเป็นแบบ mask — หน้าเดียวกัน [ยืนยัน]
- Duplicate: บัญชีเดียวกัน (branch) เคยตรวจแล้ว → `isDuplicate:true`, ใช้ cache **ไม่หักโควตา**; ต่าง branch → `true` แต่ข้อมูลสด และหักโควตา — หน้าเดียวกัน [ยืนยัน]
- Error ที่เกี่ยวข้อง: `SLIP_NOT_FOUND` (404, รวมสลิปเก่าเกิน), `SLIP_PENDING` (404, สลิป BBL ที่โอนภายใน 5 นาที), `QUOTA_EXCEEDED` (403), `RATE_LIMIT_EXCEEDED` (429) — https://document.easyslip.com/en/reference/error-codes [ยืนยัน]
- Rate limit: ขึ้นกับแพ็ก ขอเพิ่มได้ ไม่มีตัวเลขสาธารณะ — https://document.easyslip.com/en/reference/rate-limit [ยืนยัน]
- Outbound-only: ใช่สำหรับ sync; async รับ `callbackUrl` (ต้องเป็น public HTTPS) หรือจะ poll ก็ได้ — https://document.easyslip.com/en/reference/error-codes (รหัส `INVALID_CALLBACK_URL`, `JOB_NOT_FOUND`) [ยืนยัน บางส่วน; หน้า async ตรง fetch ไม่ได้ (403)]
- PDPA: Privacy Policy ระบุเก็บ "รูปภาพสลิปเงินโอน"; EasySlip เป็น **processor** ของข้อมูลบุคคลที่สามที่ผู้ใช้อัปโหลด (§2.3) ผู้ใช้เป็น controller; แจ้งเหตุละเมิดต่อ PDPC ใน 72 ชม.; **ไม่ระบุระยะเวลาเก็บ ไม่ระบุที่ตั้ง server** (cloud ไทยหรือต่างประเทศ) — https://easyslip.com/privacy [ยืนยัน]

### 2.3 SlipOK

- ราคา: BASIC ฟรี 100 สลิป/เดือน (≤2 ร้าน), START 350/500, SME 600/1,000, ENTERPRISE 1,000/2,000, GOLD 2,580/6,000; เกินโควตา 1.00–0.43 ฿ ตามแพ็ก (รายเดือน) และลดตามสัญญายาว; ธุรกิจเกิน 200 สลิป/วันให้ขอใบเสนอราคา — https://slipok.com/our-service/ และ https://slipok.com [ยืนยัน]; ไม่มีค่า API แยก
- Endpoint: `POST https://api.slipok.com/api/line/apikey/<BRANCH_ID>`, header `x-authorization`; ฟิลด์ `data` | `files` (JPG/PNG/JFIF/WEBP) | `url`; `log` (boolean) , `amount` (optional) — https://slipok.com/api-documentation/check-slip/ (v1.8, อัปเดต 2024-07-30) [ยืนยัน]
- Response: `success`, `data.{success,message,language,receivingBank,sendingBank,transRef,transDate (yyyyMMdd),transTime,transTimestamp,sender,receiver,amount,paidLocalAmount,ref1-3,toMerchantId,...}` ชื่อ/บัญชี mask ตามธนาคารผู้ออก — หน้าเดียวกัน [ยืนยัน]
- Error: `1010` สลิปดีเลย์ (บอกจำนวนนาทีที่ต้องรอ), `1011` QR หมดอายุ/ไม่มีรายการ, `1012` สลิปซ้ำ (ส่งเวลาที่ส่งครั้งแรกกลับมา), `1013` ยอดไม่ตรง, `1014` ผู้รับไม่ตรงกับบัญชีหลักของร้าน — https://slipok.com/api-documentation/error-status-code/ [ยืนยัน]
- **ข้อสังเกต/ความขัดแย้งในแหล่งเดียวกัน:** หน้าผลิตภัณฑ์ https://slipok.com/api/ บอกว่า SlipOK "ไม่ได้เก็บข้อมูลไว้ให้" และระบบเราต้องตรวจสลิปซ้ำเอง แต่เอกสาร API ระบุว่า `log:true` เก็บยอดเพื่อตรวจสลิปซ้ำและจับคู่ผู้รับกับบัญชีที่ผูกใน LINE LIFF — **การตรวจผู้รับ/ซ้ำของ SlipOK ผูกกับการตั้งค่าผ่าน LINE** ซึ่งอึดอัดสำหรับระบบ multi-tenant ที่จัดการบัญชีผู้รับเองในแอป [อนุมาน]
- Rate limit: ไม่ประกาศ; มี endpoint โควตา `GET .../quota` — https://slipok.com/api-documentation/check-slip-quota/ [ยืนยัน]
- PDPA: ระบุ PDPA พ.ศ. 2562; Merchant เป็น controller, SlipOK เป็น processor; ระยะเก็บ "เท่าที่จำเป็น" ไม่ระบุตัวเลข; **ข้อมูลอาจประมวลผลนอกประเทศไทย**; เปิดเผยแก่ธนาคาร/ธปท. เพื่อตรวจสลิป — https://slipok.com/privacy [ยืนยัน]; นโยบายนี้ยังพูดถึง Facebook Messenger ซึ่งอาจเป็นคนละบริบทกับการใช้ API ล้วน [อนุมาน]

### 2.4 Slip2Go

- ราคา (รายเดือน): Trial ฟรี 50 token = 100 สลิป, BASIC-1 88 ฿ (352 สลิป API, 0.250), BASIC-2 188 (854, 0.220), BASIC-3 288 (1,515, 0.190), BASIC-4 488 (2,609, 0.187), BASIC-5 888 (4,826, 0.184) — https://slip2go.com [ยืนยัน]; ระยะเวลาใช้ของ token ไม่ได้ตรวจ
- Endpoint: `POST /api/verify-slip/qr-code/info` (มี image, base64, image-url, PromptPay QR ด้วย); request `payload.qrCode`, `payload.checkCondition.{checkDuplicate, checkReceiver[], checkAmount{type,amount}, checkDate{type,date}}` — https://slip2go.com/guide (หน้า QR code REST) [ยืนยัน]; base URL ไม่ปรากฏในหน้าที่อ่านได้
- Response `data`: `referenceId`, `decode`, `transRef`, `dateTime`, `amount`, `ref1-3`, `receiver`/`sender` { `account.name`, `account.bank.account`, `account.proxy`, `bank.{id,name}` } — หน้าเดียวกัน [ยืนยัน]
- Response codes: `200000` พบสลิป, `200200` valid, `200401` ผู้รับไม่ตรง, `200402` ยอดไม่ตรง, `200403` วันที่ไม่ตรง, `200404` ไม่พบ, `200500` สลิปปลอม/เสียหาย, `200501` สลิปซ้ำ, `200502` ธนาคาร error, `429000` rate limit, `401005` token หมด, `500503` maintenance — https://slip2go.com/guide/response [ยืนยัน]; ไม่มี code "ดีเลย์" โดยเฉพาะ
- Auth: Secret Key ใน header `Authorization`; IP whitelist ≤10 IP (ค่าเริ่มต้น `*`) — https://slip2go.com/guide/authentication [ยืนยัน]
- Inbound: REST ไม่ต้องมี; **Queue API ต้องตั้ง Webhook URL ก่อน** (400422) — https://slip2go.com/guide/queue-api/qr-code [ยืนยัน] → เราไม่ใช้ Queue API
- PDPA: เก็บรูปสลิป, เลขบัญชี, ประวัติชำระ; เมื่อเป็นข้อมูลลูกค้าของผู้ใช้ **ผู้ใช้เป็น controller, Slip2Go เป็น processor**; เก็บ "ตราบที่ยังมีความสัมพันธ์/จำเป็น" ไม่ระบุตัวเลข; cloud ไทยหรือต่างประเทศ ไม่ระบุที่ตั้ง; ตอบคำขอสิทธิ์ใน 30 วัน, แจ้ง PDPC ใน 72 ชม. — https://slip2go.com/privacy?tags=pdpa [ยืนยัน]
- Rate limit: ไม่ประกาศตัวเลข

### 2.5 Thunder Solution (ไม่ใช่ RDCW)

- ราคา: TESTER ฟรี 100 สลิป/15 วัน; MINI 159/400 (0.398), STANDARD 899/3,200 (0.281), MASTER 3,599/18,000 (0.200), ELITE 49,999/400,000 (0.125); รายปีมีส่วนลด — https://thunder.in.th/services/api/ [ยืนยัน]
- Base URL `https://api.thunder.in.th/v2` (v1 legacy), `POST /v2/verify/bank`, Bearer, IP whitelist; account+amount match เฉพาะ v2 — https://document.thunder.in.th/th/ [ยืนยัน]
- Response ตัวอย่าง: `success`, `data.transRef`, `data.amount.amount`, `sender/receiver.{bank.short, account.name.th}` — หน้าเดียวกัน [ยืนยัน]
- Error codes ของ v2 มีโครงสร้างเกือบเหมือน EasySlip ทุกประการ (`SLIP_PENDING`, `extraVerify`, `RATE_LIMIT_EXCEEDED`, async `callbackUrl`) — https://document.thunder.in.th/th/reference/error-codes [ยืนยัน] — **เอกสารสองเจ้านี้หน้าตาเหมือนกันมาก อาจมี upstream/stack ร่วมกัน แต่ไม่มีหลักฐานยืนยัน [ยืนยันไม่ได้]** ผลคือการมี 2 vendor นี้ไม่ได้ให้ redundancy จริง
- PDPA: เอกสารขัดแย้งกันเอง — นโยบาย PDPA บอกเก็บ "ตลอดอายุสัญญา + 7 ปี"; ข้อตกลงการใช้งานบอก 6 เดือนหลังสิ้นสุด; FAQ บอกข้อมูลตรวจสลิปบันทึก "ตลอดไป" ใช้ AWS ไม่ระบุ region ไม่มีข้อความเรื่องโอนข้อมูลข้ามประเทศ และไม่ระบุว่าเป็น processor — https://thunder.in.th/privacy-policy-pdpa/ , https://thunder.in.th/news/thunder-solution-customer-slip-data-security/ [ยืนยัน] (ข้อความขัดแย้งสรุปจากผลค้นหาของ https://thunder.in.th/privacy/ + https://thunder.in.th/faq/ ซึ่งหน้า privacy หลัก fetch ตรงไม่สำเร็จ)

### 2.6 RDCW Slip Verify

- Endpoint: `POST https://suba.rdcw.co.th/v2/inquiry` (เอกสารเก่าใน Notion ยังชี้ `/v1/inquiry`), Basic Auth; input JSON `payload` / multipart / raw image — https://slip.rdcw.co.th/docs [ยืนยัน]
- **Response schema ฝั่งสำเร็จไม่มีในเอกสาร**; มีแต่ error code (1003 IP ไม่ได้ whitelist, 1007 usage exceeded, 2002-2004 bank API error, 2006 bank ไม่ตอบข้อมูล) และ error ตอบ HTTP 400 เสมอ — หน้าเดียวกัน [ยืนยัน]
- ไม่ระบุธนาคารที่รองรับ ไม่มี duplicate detection ไม่มีราคาสาธารณะ ("คิดเฉพาะสลิปจริง", prepaid แพ็ก 30 วัน) — https://slip.rdcw.co.th/pricing [ยืนยัน]
- ToS: ไม่ระบุระยะเก็บข้อมูล **ไม่กล่าวถึง PDPA** ไม่มี SLA; ช่วง Beta ผู้ใช้รับความเสี่ยงข้อมูลผิด/หาย; ห้ามใช้กับการพนัน ยาสูบ อาวุธ คริปโต; RDCW อ้างว่าเป็น "ตัวกลางรับส่งข้อมูล" — https://slip.rdcw.co.th/tos [ยืนยัน]
- ข้อสรุป: schema ไม่พอสำหรับออกแบบ integration, ไม่มีชั้นกันซ้ำ, เอกสารเตือนเองว่าบางส่วนอาจไม่ถูกต้อง (Notion) → **ไม่แนะนำ**

### 2.7 API ของธนาคารโดยตรง (bank-native)

| ธนาคาร | สิ่งที่ยืนยันได้ | ข้อจำกัด |
|---|---|---|
| **SCB** | Slip Verification อยู่ใน "C Scan B Payment" ของ SCB Developers; endpoint `GET /v1/payment/billpayment/transactions/{transRef}?sendingBank=014`, headers `resourceOwnerId`(API key), `requestUId`, `authorization` (OAuth client-credentials); response `transRef, sendingBank, receivingBank, transDate, transTime, amount, ref1-3, sender/receiver{displayName,name,proxy,account}`; สนับสนุน **QR 30** เท่านั้น — https://developer.scb/assets/documents/documentation/qr-payment/thai-qr.html และ https://developer.scb/assets/documents/api-reference-index/qr-payments/get-billpayment-transactions.html [ยืนยัน, 2026-10-10] | `sendingBank` เป็น `014` (SCB) **[อนุมาน: ตรวจได้เฉพาะรายการที่ผ่านระบบ SCB]**; ต้องเป็น partner/biller ของ SCB; ไม่ระบุ time limit/rate limit/error เฉพาะ; โดเมน `developer.scb.co.th` ไม่ resolve จากเครื่องที่ใช้วิจัย แต่ `developer.scb` ใช้ได้ |
| **BBL** | "Pull Payment Transaction API": `POST https://api.bangkokbank.com/biller/v1/pull-payment`, Bearer + JWT `Signature`, ต้องส่ง `billerId` (Tax ID ผู้รับ), `transRef`, `destBank`, `reference1`, `amount`; error 209 (ไม่พบรายการ), 211 (biller/ref/amount ไม่ตรงคำขอเดิม), 213 (เอกสารมี 2 ความหมายขัดกัน), 429 — https://apiportal.bangkokbank.com/th/api/qr-payment/api-documents [ยืนยัน] | ต้องเป็น biller ที่ลงทะเบียนกับ BBL; ไม่ใช่การตรวจสลิปทั่วไป |
| **KBank** | หน้า API Portal ระบุว่ามีผลิตภัณฑ์ "Slip Verification" ตรวจสถานะ/รายละเอียดการโอนจากโมบายแบงก์กิ้ง (ตามผลสรุปค้นหา https://apiportal.kasikornbank.com/product); กรณีศึกษา Qorus 2021: ตรวจ >13 ล้านรายการ/>7 พันล้านบาท ใน 4 เดือน https://www.qorusglobal.com/innovations/23405-slip-verification-api; บทความ Katalyst ระบุ Two-Way SSL (ผลสรุปค้นหา https://katalyst.kasikornbank.com/th/blog/Pages/api-with-kbank.html) | **หน้า API Portal / Katalyst เป็น JS-rendered อ่านเนื้อหาจริงไม่ได้: endpoint, ราคา, คุณสมบัติผู้สมัคร [ยืนยันไม่ได้]**; README ของไลบรารี third-party อ้างว่าต่อตรงธนาคารมีค่าขั้นต่ำสูง (50k/10k ต่อเดือน) — ข้อมูลไม่เป็นทางการ ไม่ควรอ้าง |

**ข้อสรุปหัวข้อนี้ [อนุมาน]:** bank-native API ออกแบบมาให้ **biller ที่รับชำระผ่าน QR30 กับธนาคารนั้น** ตรวจรายการของตัวเอง ไม่ใช่ร้านที่รับโอน/พร้อมเพย์ธรรมดาจากลูกค้าธนาคารใดก็ได้ และต้องผ่านการสมัครเป็น partner ทีละธนาคาร ใช้เวลานาน จึงไม่เหมาะกับร้านเดี่ยวในช่วงนี้ ตัวกลางเชิงพาณิชย์ที่เชื่อมหลายธนาคารให้ในครั้งเดียวคือทางเลือกที่เป็นไปได้

---

## 3. Threat model: สิ่งที่ POS ต้องทำเอง

หลักการ: **API บอกแค่ว่า "ธนาคารมีรายการนี้จริง" และ "ข้อมูลจริงของรายการคืออะไร"** — ไม่ได้บอกว่า "รายการนี้คือการชำระของบิลนี้ของร้านเรา" การผูกกับบิลเป็นหน้าที่ของ POS

| ภัย | ช่องโหว่ | ป้องกัน (ฝั่ง POS) | vendor ช่วยได้เท่าไร |
|---|---|---|---|
| **สลิปที่แก้ไข** (เปลี่ยนยอด/ชื่อบนภาพ) | mini-QR ไม่มียอด/ผู้รับ ภาพที่แก้ตัวเลขแต่ QR เดิมยังผ่านได้ถ้าเราอ่านตัวเลขจากภาพ/OCR | ใช้ **เฉพาะค่าจาก response ของธนาคาร** (`amountInSlip`, receiver, `date`) ห้ามใช้ข้อความที่อ่านจากรูปเอง; เก็บ `rawSlip` ไว้เป็นหลักฐาน | vendor คืนข้อมูลจากธนาคาร จึงตัดเรื่องภาพแก้ได้ ถ้าเราใช้ค่านั้นจริง |
| **สลิปซ้ำ / reuse** (ใช้สลิปจริงใบเดียวจ่ายหลายบิล หรือส่งซ้ำ) | vendor เช็คซ้ำได้เฉพาะภายในบัญชี vendor (EasySlip ต่าง branch ก็ยัง "ซ้ำ" แต่หักโควตา) และไม่ครอบคลุมหากสลับ vendor/ตกไปเส้นทางแคชเชียร์อนุมัติเอง | ตาราง `slip_payments` ที่ `UNIQUE (tenant_id, sending_bank, trans_ref)` (ดู §4.3) แทรกในทรานแซกชันเดียวกับการปิดบิล; ถ้า insert ชน = ปฏิเสธ | ชั้นที่สอง ไม่ใช่ชั้นหลัก |
| **สลิปจากบัญชีอื่น / โอนเข้าบัญชีไม่ใช่ของร้าน** (ลูกค้าโอนให้เพื่อน แล้วเอาสลิปมาโชว์) | สลิปจริงแต่ผู้รับไม่ใช่ร้าน | เทียบ receiver กับ **บัญชีรับเงิน/พร้อมเพย์ที่ร้านตั้งค่าไว้** (ต่อ tenant) — แต่เลขบัญชีบนสลิปถูก **mask** (EasySlip/SlipOK) จึงต้องเทียบแบบ pattern + ชื่อ + proxy (เบอร์/เลข ปชช./Biller ID) ไม่ใช่ string เต็ม | EasySlip `matchAccount` / Slip2Go `checkReceiver` ทำให้ แต่ **ต้องทดสอบกับสลิปจริงของร้านก่อนเชื่อ** (ผลของ mask ต่างกันตามธนาคาร — SlipOK ระบุเอง) |
| **ยอดไม่ตรง** (จ่ายน้อยกว่าบิล) | — | เทียบ `amountInSlip` กับยอดที่ต้องชำระ (ทศนิยมสองตำแหน่งเป็น string/สตางค์ ห้ามใช้ float) | `matchAmount` / `checkAmount` / `amount` ช่วยได้ แต่ POS ยังต้องเช็คเอง |
| **โอนก่อนสั่งซื้อ / เวลาไม่สมเหตุผล** | สลิปเก่าถูกนำมาใช้ | เทียบ `transDate` กับเวลาเปิดบิล (ต้องไม่เก่ากว่ากรอบที่ตั้งไว้) | Slip2Go `checkDate` |
| **ดีเลย์ / pending** (โอนแล้วธนาคารยังไม่ลงรายการ) | ตรวจทันทีอาจ "ไม่พบ" โดยไม่ใช่ปลอม | แยกสถานะ **pending-retry** ออกจาก **rejected**: BBL ภายใน 5 นาที (`SLIP_PENDING`), SlipOK `1010` ให้เวลารอเป็นนาที, Slip2Go `200502` ให้ลองใหม่; UI แสดง "รอตรวจ ลองใหม่" แทน "สลิปปลอม" | ทุกเจ้ามี code ที่แยกได้ (ยกเว้น RDCW) |
| **สลิปเก่าเกินอายุตรวจ** | 7 วัน/30 วันตามธนาคาร (§1.4) → `SLIP_NOT_FOUND` | ตรวจตอนรับชำระเท่านั้น | — |
| **vendor ล่ม / โควตาหมด / 429** | ลูกค้ารอที่เคาน์เตอร์ | เส้นทางสำรอง: แคชเชียร์ยืนยันเงินเข้าเองในแอปธนาคาร/K Shop แล้วกดอนุมัติพร้อมเหตุผล → บันทึก `verified_by='manual'` + user id (ไม่มี transRef จาก API ก็ยังต้องกันซ้ำด้วยการกรอก transRef มือ หรือกำหนดว่าต้องมี) | ไม่มี SLA ประกาศจากทุกเจ้า → ต้องออกแบบรับมือเอง |
| **ความเป็นส่วนตัว (PDPA)** | ภาพสลิปมีชื่อ/บัญชีของลูกค้า ส่งออกไป vendor | ส่ง **QR payload (ข้อความ) แทนภาพ** เมื่ออ่าน QR ได้ที่ฝั่ง client/server เพื่อลดข้อมูลที่ออกไป (payload มีแค่ bank + transRef ตาม §1.2); เมื่อต้องส่งภาพให้ระบุในประกาศความเป็นส่วนตัวของร้าน (ร้านคือ controller; EasySlip/Slip2Go/SlipOK ระบุตัวเองเป็น processor) | เจ้าที่ชัดเรื่อง processor: EasySlip, Slip2Go, SlipOK; Thunder ไม่ระบุและเอกสารขัดกัน; RDCW ไม่กล่าวถึง PDPA |
| **ข้อมูลที่ vendor ได้เห็นจาก payload** | payload = รหัสธนาคาร + transRef เท่านั้น แต่ vendor ได้ **ผลจากธนาคาร** (ชื่อ/บัญชี/ยอด) กลับมาเก็บด้วย | ตกลงในสัญญา/ToS เรื่อง retention, ขอลบได้ (EasySlip/Slip2Go/Thunder ระบุสิทธิลบ) | — |

**ข้อควรทำเสมอ (ไม่ขึ้นกับ vendor):** ความจริงขั้นสุดท้ายคือ **เงินเข้าบัญชีร้านจริง** — กรณียอดสูง ให้แคชเชียร์ยืนยันในแอปธนาคารอีกชั้น ตามที่ Krungsri แนะนำ (§1.5)

---

## 4. คำแนะนำ

### 4.1 เลือก vendor

**ตัวหลัก: EasySlip API v2** เพราะ (ทั้งหมดอ่านจากเอกสารสาธารณะของเขาเอง):
1. เอกสาร v2 ครบที่สุดในกลุ่ม: request/response schema ชัด, error code ครบ, rate-limit headers, ตารางอายุสลิปรายธนาคาร
2. มี `matchAccount` + `matchAmount` + `checkDuplicate` ในคำขอเดียว และ **ผูกกับบัญชีรับเงินที่จัดการผ่าน API (`/bank-accounts`)** ได้ — เหมาะกับ multi-tenant ที่แต่ละร้านมีบัญชีรับเงินของตนเอง (SlipOK ผูกบัญชีผ่าน LINE LIFF จึงไม่เหมาะ)
3. ระบุตัวเองเป็น **processor** ในนโยบายความเป็นส่วนตัว (§2.3) ชัดกว่า Thunder/RDCW
4. มี path แบบ outbound-only (sync) ชัดเจน
5. ราคาเริ่ม 99 ฿/เดือน/250 ตรวจ เหมาะกับร้านเดียว

ข้อควรระวัง: ไม่มี SLA ลายลักษณ์อักษร (มีแต่คำโฆษณา 99.9%); ไม่ระบุ retention และ region ของข้อมูล; ต้องทดลองแพ็กฟรี 7 วันกับสลิปจริงของลูกค้าร้านก่อน

**ตัวสำรอง/ทางเลือก: Slip2Go** — ถูกที่สุดต่อสลิป (≈0.18–0.25 ฿), มี code ผลลัพธ์ละเอียด (ผู้รับไม่ตรง, ยอดไม่ตรง, ซ้ำ, ปลอม, ดีเลย์/ธนาคาร error), `checkDate`, ระบุ processor และ IP whitelist ปรับได้ แต่ base URL และ rate limit ไม่ปรากฏในหน้าที่อ่านได้ และเอกสาร response ของสลิปที่ซ้ำไม่ละเอียด

**เก็บไว้ดู:** SlipOK (มีฟรี 100/เดือนเป็นประโยชน์ตอนทดสอบ แต่ผูกการเทียบผู้รับ/ซ้ำกับ LINE), Thunder (ราคาดี แต่เอกสาร retention ขัดกันเอง), RDCW (ไม่แนะนำ), bank-native (ไม่เหมาะกับร้านเดี่ยว)

> นี่คือการเลือกของผู้วิจัยจากเกณฑ์ข้างต้น [อนุมาน] เจ้าของร้านควรเป็นผู้ตัดสินสุดท้าย เรื่องงบประมาณและความไว้วางใจ vendor

### 4.2 การเลือกใช้เส้นทาง "payload vs image"

- ถ้า client อ่าน QR จากภาพได้ (Flutter, ในเครื่อง) → ส่ง **payload** ไป NestJS → vendor: ข้อมูลส่วนบุคคลที่ออกจากร้านน้อยที่สุด (bank code + transRef)
- ถ้าอ่านไม่ได้ (ภาพเบลอ) → fallback ส่งภาพ (≤4 MB สำหรับ EasySlip) หรือให้ลูกค้าถ่ายใหม่

### 4.3 ร่างการออกแบบ integration (อนาคต ไม่ทำตอนนี้)

โครงตามกฎของ repo (ทรานแซกชันอยู่ใน handler, idempotency key ต่อ cart, ห้ามเปิด connection ที่สองใน request เดียว, tenant RLS) — ข้อมูลจาก CLAUDE.md ของ repo:

1. **เรียก vendor นอก transaction** (เหมือนการตรวจ PIN ของ void ที่อยู่หน้า `runIdempotent`): `POST /payments/slip/verify` รับ `payload` + `saleDraftId`/ยอดที่ต้องจ่าย → NestJS เรียก vendor ด้วย HTTPS ขาออก, timeout สั้น, retry เฉพาะ error ที่ vendor ระบุว่า retry ได้ (5xx/`SLIP_PENDING`/429 ตาม `Retry-After`) — ห้ามเชื่อ 4xx ที่เป็น verdict แล้ว retry
2. **ตารางใหม่ (ต้องผ่าน migration ใหม่ ห้ามแก้ migration เดิม)** เช่น `slip_payments`: `tenant_id`, `sending_bank`, `trans_ref`, `amount`, `receiver_ref` (ค่า mask/proxy), `trans_at`, `sale_id`, `vendor`, `raw_response` (jsonb), `verified_by` (`api`/`manual`), `created_at`; ข้อจำกัด **`UNIQUE (tenant_id, sending_bank, trans_ref)`** + RLS แบบเดียวกับตารางอื่น; แทรกในทรานแซกชันเดียวกับ `saveSale` เพื่อให้ไม่มีสลิปที่ผูกกับบิลที่ rollback
3. **ตัดสินใจฝั่งเรา** ในลำดับ: (a) vendor ตอบ valid → (b) ยอดตรงบิล → (c) receiver ตรงกับบัญชีที่ตั้งค่าของ tenant (นอกเหนือจาก `matchAccount` ของ vendor) → (d) `trans_at` ≥ เวลาเปิดบิล − ค่าเผื่อ → (e) insert `slip_payments` ผ่าน unique
4. **ข้อพิจารณา cross-tenant:** transRef ซ้ำข้าม tenant (สลิปเดียวใช้กับสองร้าน) ไม่ถูกจับโดย RLS ต่อ tenant — ถ้าต้องการกันต้องใช้ตารางระดับแพลตฟอร์มที่ไม่ผ่าน RLS (เก็บ hash ของ `sending_bank+trans_ref` เท่านั้น) เป็นการตัดสินใจของเจ้าของ ไม่ใช่การเดา
5. **ความลับ/คอนฟิก:** API key ต่อ tenant หรือต่อแพลตฟอร์ม เก็บแบบเดียวกับ secret อื่น ห้าม commit; คอนฟิก (ผู้ให้บริการ, โควตาเตือน) ผ่านที่เก็บคอนฟิกรันไทม์เดิม
6. **เครือข่าย:** ต้องให้ VM `mob04` ออก HTTPS ไปโดเมนของ vendor ได้ — repo เคยถูก FortiGate ขวาง `ghcr.io` จน cert SAN แก้ (CLAUDE.md ของ repo) ให้ขอเปิด/ทดสอบโดเมน vendor (เช่น `api.easyslip.com`) ล่วงหน้า; IP whitelist ของ vendor เป็นทางเลือก (Slip2Go ค่าเริ่มต้น `*`) — ถ้าจะใช้ ต้องรู้ public egress IP ของมหาวิทยาลัยซึ่งยังไม่ทราบ [ยืนยันไม่ได้]
7. **Degraded mode:** ถ้า vendor ล่ม/โควตาหมด/ออฟไลน์ → POS ไม่บล็อกการขาย; แคชเชียร์อนุมัติเอง (`verified_by='manual'`, บันทึก user, เหตุผล) แล้วคิวตรวจย้อนหลัง **ภายในอายุสลิป** (7 วันขั้นต่ำตาม §1.4); สอดคล้องกฎของ repo ที่ว่า 5xx/429 ไม่เข้า offline queue (ต้องตัดสินใจว่ากรณีนี้คือ "ลองใหม่" หรือ "manual")
8. **Metrics:** นับ `slip_verify_total{result}` ใน `onTransactionCommit` ตามกฎ metrics เดิม (ไม่ใส่ label tenant_id)
9. **ทดสอบ:** ใช้แพ็กฟรี/trial กับสลิปจริงของแต่ละธนาคารที่ลูกค้าร้านใช้บ่อย (K PLUS, SCB EASY, Krungthai NEXT, BBL, Krungsri) ตรวจเรื่อง mask ของบัญชีผู้รับและพฤติกรรมสลิปใหม่/เก่าก่อนล็อกการเทียบผู้รับ

### 4.4 ตัวเลือกนอกขอบเขต

ถ้าต้องการ "เงินเข้าแล้วระบบรู้เอง" โดยไม่พึ่งสลิป ต้องใช้ payment gateway / biller QR30 ที่ธนาคารส่ง **callback เข้าหาเรา** (inbound) ซึ่ง VM หลัง FortiGate ตอนนี้ไม่มีเส้นทางรับ — เป็นเรื่องแยกต่างหาก ไม่ใช่ข้อเสนอของเอกสารนี้

---

## 5. สิ่งที่ยืนยันไม่ได้ / ควรถามต่อ

| หัวข้อ | สถานะ |
|---|---|
| เอกสารทางการของ ธปท. ที่กำหนดสเปก mini-QR / แนวปฏิบัติตรวจสลิปของร้านค้า | ไม่พบ |
| รายชื่อธนาคารที่ออก mini-QR อย่างเป็นทางการ | ไม่พบ (มีเพียงรายชื่อแอปที่ EasySlip รองรับ) |
| KBank Slip Verification API: endpoint, ราคา, เงื่อนไขสมัคร | หน้า portal อ่านไม่ได้ (JS) |
| SCB: rate limit, time limit, ข้อกำหนดผู้สมัคร | เอกสารไม่ระบุ |
| ราคา RDCW | ไม่เผยแพร่ |
| base URL และ rate limit ของ Slip2Go | ไม่ปรากฏในหน้าที่อ่านได้ |
| SLA ทุก vendor | ไม่มี มีแต่ "99.9% uptime" ในหน้าโฆษณาของ EasySlip/Thunder |
| ที่ตั้ง server/ระยะเวลาเก็บข้อมูลที่แน่นอนของทุก vendor | ไม่ระบุตัวเลข (SlipOK: อาจนอกประเทศ) |
| ความสัมพันธ์ระหว่าง EasySlip กับ Thunder (เอกสารเหมือนกันมาก) | ไม่มีหลักฐาน |
| ลักษณะการ mask เลขบัญชีผู้รับของแต่ละธนาคารจริงๆ และผลต่อ `matchAccount` | ต้องทดลองกับสลิปจริง |
| หน้า BBL "Verify-eSlip" ช่วง 7–60 วัน และหน้าแนะนำ SCB ที่ fetch ตรงไม่สำเร็จ | อ้างผ่านผลสรุปการค้นหาเท่านั้น ไม่ได้อ่านหน้าเต็ม |
| SlipOK: นโยบายความเป็นส่วนตัวพูดถึง Facebook Messenger ซึ่งอาจเป็นคนละบริบทกับ API | ควรถาม vendor |

## 6. รายการแหล่งข้อมูลหลัก (เข้าถึง 2026-10-10)

- SCB mini-QR spec: https://developer.scb/assets/documents/documentation/qr-payment/extracting-data-from-mini-qr.pdf
- SCB Slip Verification: https://developer.scb/assets/documents/documentation/qr-payment/thai-qr.html , https://developer.scb/assets/documents/api-reference-index/qr-payments/get-billpayment-transactions.html
- BBL Pull Payment: https://apiportal.bangkokbank.com/th/api/qr-payment/api-documents
- KBank: https://apiportal.kasikornbank.com/product , https://www.qorusglobal.com/innovations/23405-slip-verification-api
- EasySlip: https://easyslip.com , https://document.easyslip.com/en/v2/ , https://document.easyslip.com/en/v2/verify/bank/ , https://document.easyslip.com/en/reference/error-codes , https://document.easyslip.com/en/reference/rate-limit , https://document.easyslip.com/en/reference/slip-age-support , https://easyslip.com/privacy
- SlipOK: https://slipok.com , https://slipok.com/our-service/ , https://slipok.com/api/ , https://slipok.com/api-documentation/check-slip/ , https://slipok.com/api-documentation/error-status-code/ , https://slipok.com/api-documentation/check-slip-quota/ , https://slipok.com/privacy
- Slip2Go: https://slip2go.com , https://slip2go.com/services/slip2go-api , https://slip2go.com/guide , https://slip2go.com/guide/response , https://slip2go.com/guide/authentication , https://slip2go.com/guide/queue-api/qr-code , https://slip2go.com/privacy?tags=pdpa
- Thunder Solution: https://thunder.in.th , https://thunder.in.th/services/api/ , https://document.thunder.in.th/th/ , https://document.thunder.in.th/th/reference/error-codes , https://thunder.in.th/privacy-policy-pdpa/ , https://thunder.in.th/news/thunder-solution-customer-slip-data-security/
- RDCW: https://slip.rdcw.co.th/docs , https://slip.rdcw.co.th/pricing , https://slip.rdcw.co.th/tos
- ธนาคาร/ผู้บริโภค: https://www.bangkokbank.com/th-TH/Personal/Tips-and-Insights/Verify-eSlip , https://www.krungsri.com/th/plearn-plearn/lifestyle/living/how-to-check-fake-slip , https://www.scb.co.th/th/personal-banking/stories/tips-for-you/check-transfer-slip.html
- ไลบรารี third-party (ใช้ประกอบเท่านั้น): https://thai-qr-payment.js.org/guide/slip-verify/
- ธปท.: https://www.bot.or.th/th/news-and-media/news/news-20250428.html (เกี่ยวข้องทางอ้อม)
