# Research: QR PromptPay ที่ใส่ยอดอัตโนมัติ และ API ธนาคารที่ยืนยันการชำระเงินเอง (SCB / KBank)

> วันที่ค้นข้อมูล: **2026-10-10** (ทุกข้อเท็จจริงในเอกสารนี้ดึงมาวันนี้ ยกเว้นที่ระบุปี)
> ขอบเขต: research only ไม่มีโค้ด ไม่แตะ git ไม่แก้ repo
> สถานะหลักฐาน: **[ยืนยัน]** = อ่านจากหน้าแหล่งปฐมภูมิโดยตรง, **[รอง]** = แหล่งรอง/ชุมชน, **[ไม่ยืนยัน]** = หาไม่พบหรือยืนยันไม่ได้

## 0. สรุปสั้น (TL;DR)

1. **QR ใส่ยอดเองได้โดยไม่ต้องมีธนาคาร**: สร้าง payload ตามมาตรฐาน Thai QR Payment (EMVCo MPM + ภาคผนวกของ ธปท.) ฝั่ง client เอง ใช้ tag 29 (PromptPay ID: เบอร์มือถือ / เลขบัตร ปชช. / เลขผู้เสียภาษี) + tag 54 (ยอด) + POI = `12` + CRC16 (tag 63). **แต่ไม่มีการยืนยันการชำระเงินอัตโนมัติ** แคชเชียร์ต้องดูสลิป/แอปเอง
2. **การยืนยันอัตโนมัติ = ต้องใช้ API ธนาคาร** ซึ่งเป็น QR "Tag 30 (Bill Payment)" ออกโดยธนาคาร (ต้องมี Biller ID) ไม่ใช่ tag 29
3. **SCB**: sandbox สมัครได้ฟรีทันที (เอกสารสาธารณะ) แต่ **เงื่อนไข production และค่าธรรมเนียมของ Open API ไม่มีเผยแพร่** [ไม่ยืนยัน] ทางเลือกที่ "ร้านบุคคลธรรมดา" ใช้ได้จริงคือ **แอปแม่มณี + Mae Manee QR API** (เอกสารระบุรับบุคคลธรรมดา)
4. **KBank**: QR API ต่อตรง **รับเฉพาะนิติบุคคล** [ยืนยัน] ถ้าเป็นบุคคลธรรมดาต้องผ่านผู้ให้บริการ POS ที่ธนาคารเปิดให้สมัคร (QR on POS)
5. **Callback ต้องเป็น public HTTPS** (SCB: cert จริง ห้าม self-signed; KBank: ต้องลงทะเบียน callback URL + IP/domain + client certificate) VM ที่อยู่หลัง FortiGate และเข้าได้ทาง VPN อย่างเดียว **รับไม่ได้** ต้องเลือก: เปิด port/VIP จากทีมเครือข่ายมหาวิทยาลัย, ใช้ relay สาธารณะ, หรือ **poll ผ่าน inquiry API (ขาออกอย่างเดียว)**
6. **แนะนำ**: *ตอนนี้* ทำ QR local (tag 29) + ปุ่ม "ยืนยันว่าลูกค้าโอนแล้ว" ด้วยมือ; *ภายหลัง* ค่อยต่อ bank API เมื่อรู้ว่าร้านเป็นบุคคลธรรมดาหรือนิติบุคคล และทีมเครือข่ายตอบเรื่อง inbound/outbound ได้

---

## 1. มาตรฐาน PromptPay / Thai QR Payment (สร้าง payload ในเครื่อง)

### 1.1 เอกสารต้นทาง

| เรื่อง | แหล่ง | สถานะ |
|---|---|---|
| Policy Guideline "Standardized Thai QR Code for Payment Transactions" ธปท. ลงวันที่ **17 เม.ย. 2562 (2019)** มีผลตั้งแต่วันเดียวกัน แทนที่ guideline ปี 2560 (ฉบับแปลไม่เป็นทางการ ฉบับไทยเป็นหลัก) | https://www.bot.or.th/content/dam/bot/fipcs/documents/FPG/2562/EngPDF/25620084.pdf (อ่าน PDF ครบทั้งฉบับ) | [ยืนยัน] — ไฟล์ PDF มี metadata แก้ไขล่าสุด 2023-05-14 จึง**ไม่ยืนยันว่าเนื้อหายังเป็นฉบับปัจจุบัน** ณ 2026 |
| ธปท. อ้างอิง EMVCo QRCPS Merchant-Presented Mode เป็นฐาน และให้แอปของผู้ให้บริการทุกรายอ่าน QR ของรายอื่นได้ (interoperability) | BOT PDF ข้างต้น หัวข้อ 3.1.2 | [ยืนยัน] |
| EMVCo QRCPS Merchant-Presented Mode **v1.1 (27 พ.ย. 2020)** เป็นฉบับล่าสุดที่ EMVCo ลงรายการ | https://www.emvco.com/emv-technologies/qr-codes/ (หน้าไม่มีลิงก์ PDF ตรง ตัวไฟล์ต้องผ่านหน้า terms) | [ยืนยัน] ว่ามีฉบับนี้; **ไม่ได้อ่านตัว spec เอง** (ดาวน์โหลดตรงไม่ได้) |
| ภาคผนวก "Thai QR Payment" ของ ธปท./สมาคมธนาคารไทย/KBank ที่ละเอียดกว่า guideline | ไม่เผยแพร่สาธารณะ (ชุมชนระบุว่าอยู่หลัง KBank API portal) https://thai-qr-payment.js.org/reference/spec/ | [ไม่ยืนยัน] |

### 1.2 Tag ที่เกี่ยวข้อง (ตาม BOT guideline Attachment 1 ข้อ 2.1–2.3)

การจัดสรร Tag ID: 00–25 card scheme สากล; 26–28 card scheme ในประเทศ; **29–31 PromptPay และนวัตกรรมการชำระเงิน**; 32–51 สำรอง; 52–64 ข้อมูลเสริม (ยอด, ประเภทร้าน, ref)

| Tag | ความหมาย | ค่า/หมายเหตุ (จาก BOT guideline) |
|---|---|---|
| 00 | Payload Format Indicator | ตาม EMVCo (ค่า `01`) |
| 01 | Point of Initiation | ตาม EMVCo: `11` = static, `12` = dynamic (ยืนยันค่าจากข้อกำหนด HKMA ที่สร้างบน EMV QRCPS: https://www.hkma.gov.hk/media/chi/doc/key-functions/financial-infrastructure/infrastructure/retail-payment-initiatives/Common_QR_Code_Specification.pdf และ https://thai-qr-payment.js.org/reference/spec/) |
| **29** | PromptPay Credit Transfer (โอนเข้า PromptPay ID) | sub-tag 00 = AID `A000000677010111` (merchant-presented) / `A000000677010114` (customer-presented); sub-tag 01 เบอร์มือถือ `0066XXXXXXXXX` (13 หลัก), 02 เลขบัตร ปชช./เลขผู้เสียภาษี (13), 03 e-Wallet ID (15), 04 บัญชีธนาคาร (สงวนอนาคต) |
| **30** | PromptPay Bill Payment (Biller ID) | AID `A000000677010112` (ในประเทศ); sub-tag 01 Biller ID (15 หลัก = เลขผู้เสียภาษี + suffix), 02 Ref1 (บังคับ, ≤20), 03 Ref2 (เลือก) — **ผู้ให้บริการต้องได้ใบอนุญาตรับชำระแทนและต้องขึ้นทะเบียน Biller ID ให้ร้านค้า** |
| 31 | Payment innovation (API) | AID `A000000677012004`; มี API ID `001` = Transaction verification API |
| 52 | Merchant Category Code | ตัวเลือก |
| 53 | Currency | `764` (บาท) |
| **54** | Transaction Amount | ยอดเงิน; รูปแบบเลขกับจุดทศนิยม (SCB ระบุ ≤13 ตัวอักษรรวม `.`: https://developer.scb/assets/documents/api-reference-index/qr-payments/post-qrcode-create.html) |
| 55–57 | Tip/convenience fee | **ห้ามใช้** กับ PromptPay |
| 58 | Country | `TH` |
| 59 | Merchant name | สำหรับ PromptPay แอปต้อง**ไม่แสดง**ค่านี้ แต่ให้ไป lookup ชื่อจากระบบ PromptPay แทน (ลูกค้าจึงเห็นชื่อบัญชีผู้รับที่ลงทะเบียนจริง) |
| 63 | CRC | BOT ระบุเป็น "optional" สำหรับ PromptPay แต่ EMVCo กำหนด CRC และแอปธนาคารจริงมักตรวจ — ควรใส่เสมอ |

**CRC (tag 63)**: คำนวณตาม ISO/IEC 13239 polynomial `0x1021`, initial value `0xFFFF` ครอบคลุมทุก data object รวม ID+Length ของ CRC เอง แต่ไม่รวมค่า CRC, ผลลัพธ์เป็นเลขฐานสิบหก 4 ตัวอักษรพิมพ์ใหญ่ (ตัวอย่าง `6304007B`) — ยืนยันจาก HKMA (อนุพันธ์ของ EMV QRCPS) และธนาคารกลางบราซิล ซึ่งอ้างหัวข้อ 4.7.3 ของ EMVCo โดยตรง: https://www.bcb.gov.br/content/config/Documents/BR_Code_MANUAL_Version_2_May_2020.pdf [รอง — ไม่ได้อ่านตัว EMVCo spec]

### 1.3 Static vs Dynamic

- BOT (ข้อ 3.1.3): static = ภาพ QR ไม่เปลี่ยน พิมพ์ติดร้านได้; dynamic = สร้าง QR ใหม่ทุกครั้งที่ทำรายการ
- ในทางเทคนิค: static = POI `11` ไม่มี tag 54; dynamic = POI `12` + tag 54 (ยอด) (ค่า 11/12 ตาม HKMA ข้างต้น)
- โครงตัวอย่าง (จาก library ชุมชน ไม่ใช่ทางการ): `…010212` `29 37 0016A000000677010111 0113 0066…` `5303764` `54 05 50.00` `5802TH` `6304XXXX` — https://www.npmjs.com/package/promptpay-js [รอง]

**ข้อจำกัดสำคัญของ QR ที่สร้างเอง (tag 29)** — ข้อสรุปของผู้วิจัยจากโครงสร้างมาตรฐาน:
- ไม่มีเลขอ้างอิงธุรกรรมต่อบิล (tag 29 ไม่มี Ref1/Ref2) → ระบบ **จับคู่ "บิลนี้ถูกจ่ายแล้ว" อัตโนมัติไม่ได้**
- ไม่มีวันหมดอายุในตัว QR
- ธนาคารไม่ส่ง callback ให้ใคร (ผู้รับคือบัญชี PromptPay ธรรมดา)

### 1.4 ทุกแอปธนาคารเคารพยอดใน QR หรือไม่?

- **มาตรฐานบังคับให้แอปทุกค่ายอ่าน QR ของค่ายอื่นได้** (BOT 3.1.2) แต่ **ไม่พบแหล่งปฐมภูมิที่รับรองว่า "ทุกแอปล็อกยอดตาม tag 54"** → [ไม่ยืนยัน]
- ธนาคารอธิบายพฤติกรรมของ QR ที่ออกผ่าน API ว่า ยอดถูกกำหนดและลูกค้าแก้ไม่ได้ (KBank: https://www.kasikornbank.com/th/business/sme/financial-services/pages/qr-api.aspx) แต่เป็นเรื่อง QR ผ่าน API ไม่ใช่ tag 29 ที่สร้างเอง
- SCB เตือนเองว่า "ความสามารถในการรองรับและแสดงตัวเลือกการชำระขึ้นกับแต่ละแอปธนาคาร" (https://developer.scb/assets/documents/documentation/qr-payment/thai-qr.html)
- **ข้อเสนอ**: ทำตารางทดสอบบนเครื่องจริง (SCB Easy, K PLUS, Krungthai NEXT, Bualuang mBanking, Krungsri, ttb touch, GSB MyMo, TrueMoney) ก่อนตัดสินใจ — เป็นวิธีเดียวที่หาข้อยืนยันได้

### 1.5 วงเงิน

- **ไม่มีเพดานกลางที่พิสูจน์ได้จากแหล่งปฐมภูมิ**: Bangkok Bank ระบุว่าจำนวนครั้งต่อวันไม่จำกัด ส่วน "ยอดต่อรายการและยอดรวมต่อวัน **กำหนดโดยแต่ละธนาคาร**" — https://www.bangkokbank.com/en/Personal/Digital-Banking/PromptPay [ยืนยัน]
- ตัวเลข 2 ล้านบาทต่อรายการมีในแหล่งรอง (Stripe FAQ, Flywire) แต่ไม่พบหน้าทางการของ ธปท./ITMX → [ไม่ยืนยัน]
- วงเงินที่เกี่ยวกับร้านจริงๆ คือ **วงเงินของฝั่งผู้จ่าย** (ลูกค้า) และ **วงเงินรับของผู้ให้บริการ** (ดูหัวข้อ 2)

---

## 2. API ธนาคารที่สร้าง QR และยืนยันการชำระเงินอัตโนมัติ

### 2.1 SCB (SCB Developers / SCB Open API)

> หมายเหตุ: `developer.scb.co.th` resolve DNS ไม่ได้จากเครื่องนี้เมื่อ 2026-10-10 แต่ไฟล์เอกสารชุดเดียวกัน serve ได้จาก `https://developer.scb/…` ลิงก์ด้านล่างใช้โดเมนหลัง (เสิร์ชเอนจินยังชี้ไปโดเมนเดิม)

**ผลิตภัณฑ์/flow (QR 30 = Thai QR Tag 30)** — https://developer.scb/assets/documents/documentation/qr-payment/thai-qr.html [ยืนยัน]
1. `POST /v1/oauth/token` (OAuth 2.0 **Client Credentials**; API key + secret)
2. `POST /v1/payment/qrcode/create` (หรือ v2 คืน URL รูป QR) — qrType `PP` (QR30), `ppType=BILLERID`, `ppId` = Biller ID 15 หลัก, `amount`, `ref1` (บังคับ A-Z0-9 ≤20), `ref3` = prefix ที่ SCB กำหนด + ค่า (ใช้ผูกกับ callback endpoint) — https://developer.scb/assets/documents/api-reference-index/qr-payments/post-qrcode-create.html
3. SCB ส่ง **Payment Confirmation** ไป URL ที่ลงทะเบียนไว้ เมื่อลูกค้าจ่ายสำเร็จเท่านั้น (ไม่ส่งเมื่อล้มเหลว) ครอบคลุมทุกแอปธนาคารที่จ่าย QR30 ได้
4. Fallback: **Payment Transaction Inquiry** (`POST /v3/payment/billpayment/inquiry`) — SCB ระบุให้ใช้ "เมื่อลูกค้าบอกว่าจ่ายแล้วแต่ไม่ได้รับ confirmation เท่านั้น" (ไม่ได้ออกแบบให้ poll เป็นช่องทางหลัก) และ **Slip Verification** (`GET /v1/payment/billpayment/transactions/{transRef}?sendingBank=014`) ใช้ transaction ID จาก mini-QR บนสลิป — https://developer.scb/assets/documents/api-reference-index/qr-payments/get-billpayment-transactions.html
5. `POST /v1/payment/qrcode/void` ยกเลิก QR

**Callback (Payment Confirmation)** — https://developer.scb/assets/documents/documentation/qr-payment/payment-confirmation.html [ยืนยัน]
- URL ต้องเป็น **`https` ที่มี SSL cert ถูกต้อง ไม่รองรับ `http` และไม่รองรับ self-signed**
- ลงทะเบียน endpoint ต่อ **Biller ID + Reference 3 (prefix)** สำหรับ QR30
- ถ้าไม่ตอบ: SCB ส่งซ้ำ **สูงสุด 3 ครั้ง ห่าง 12 วินาที** แล้วส่งรายละเอียดไปอีเมลที่ลงทะเบียน
- ฟิลด์หลัก: `transactionId`, `amount`, `transactionDateandTime` (ISO 8601, GMT+7), `currencyCode` (764), `transactionType`, `payeeProxyId`, `payerName`, `payerAccountNumber`, `billPaymentRef1/2/3`, `sendingBankCode`, `receivingBankCode`, `channelCode`
- **ไม่พบการระบุ signature/HMAC ของ callback** ในหน้าเอกสาร → วิธีตรวจว่า callback มาจาก SCB จริง = [ไม่ยืนยัน] ต้องถามธนาคาร (ใน design ควรยืนยันซ้ำด้วย Inquiry ก่อนปิดบิล)

**Onboarding**
- ได้ยืนยัน: สมัครบัญชีบน portal ฟรี สร้างแอปได้ **2 แอป/บัญชี** ได้ API key/secret และเข้า sandbox ได้ทันที (onboarding sandbox เป็นอัตโนมัติ) sandbox จำกัด **5 TPS ต่อ API ต่อแอป**; มีแอป SCB EASY Simulator — https://developer.scb/assets/documents/documentation/basics/getting-started.html , https://developer.scb/assets/documents/documentation/basics/developer-sandbox.html , glossary: https://developer.scb/assets/documents/api-reference-index/references/glossary.html
- Biller ID/Merchant ID ออกให้ "เมื่อผ่านกระบวนการ onboarding" — **เงื่อนไข production (ต้องเป็นนิติบุคคลหรือไม่, เอกสาร, ระยะเวลา) ไม่มีเผยแพร่** → [ไม่ยืนยัน]
- **ค่าธรรมเนียม SCB Open API QR30 (MDR/ค่าเชื่อมระบบ): ไม่พบหน้าสาธารณะ** → [ไม่ยืนยัน]
- Auth ฝั่ง B-scan-C (ร้านสแกน QR ลูกค้า) ต้องมี CSR ออกโดย SCB — ไม่เกี่ยวกับ flow นี้

**ทางเลือกสำหรับร้านขนาดเล็ก: Mae Manee (แม่มณี) API**
- แอปแม่มณีรับ **บุคคลธรรมดาได้** (ต้องมีบัญชีออมทรัพย์/กระแสรายวันเดี่ยวของ SCB + SCB EASY) และรับนิติบุคคลแล้ว — https://www.scb.co.th/th/personal-banking/payment/for-merchant/mae-manee-app.html [ยืนยัน]
- Mae Manee QR Code Payment API: `POST /v1/maemanee/payment/qr/create` + callback (endpoint ลงทะเบียนตาม ref1/ref2=Wallet ID/ref3=Terminal ID) + inquiry รายธุรกรรม/ย้อนหลังสูงสุด 30 วัน — https://developer.scb/assets/documents/documentation/mae-manee-marchants/mae-manee-qr-payment.html
- ต้องอาศัย "Sharing Mae Manee Merchant Profile" = เจ้าของร้านอนุญาต (3-legged OAuth, access token อายุ 30 นาที) ให้แอปของเรา (partner) — https://developer.scb/assets/documents/documentation/mae-manee-marchants/mae-manee-sharing-profile.html และ https://developer.scb/assets/documents/documentation/basics/authentication.html
- วงเงินต่อรายการ QR แม่มณี: **ร้านบุคคลธรรมดา 100,000 บาท**; นิติบุคคลตามเกณฑ์ธนาคาร; ธนาคารปรับวงเงินรับชำระมีผล **5 ก.ย. 2569 (2026-09-05)** ให้ดูในแอป (หน้าเดียวกับลิงก์แม่มณีด้านบน)
- ค่าธรรมเนียม: หน้าโฆษณา "เพียง 1%*" โดยตัวหน้าอ้างถึงบริการรับบัตรเครดิต เงื่อนไขดอกจันและอัตรา QR พร้อมเพย์ **ไม่ปรากฏ** → [ไม่ยืนยัน]
- ที่ไม่ยืนยัน: partner (แอปเรา) ต้องผ่านการอนุมัติจาก SCB อย่างไรจึงใช้ Mae Manee API กับร้านจริง

### 2.2 KBank (K API / "QR API")

แหล่งหลัก: หน้าบริการ https://www.kasikornbank.com/th/business/sme/financial-services/pages/qr-api.aspx (ดึงผ่าน browser เพราะ curl ถูก 403) และพอร์ทัล https://apiportal.kasikornbank.com (SPA; เอกสาร API ฉบับเต็มอยู่หลังการล็อกอิน **ไม่ได้อ่าน** → รายละเอียด endpoint/payload/signature ของ KBank = [ไม่ยืนยัน])

**ที่ยืนยันได้จากหน้าธนาคาร**
- API QR Payment: สร้าง Thai QR **แบบ Dynamic** (ระบุยอด ลูกค้าแก้ไม่ได้) และ QR บัตรเครดิต, QR มีอายุ **10 นาที**; มี Cancel QR, **Payment Notification Callback**, **Inquire Payment**, Void, Settlement
- **QR API ต่อตรง "อนุญาตเฉพาะนิติบุคคล"** (ขั้นตอนที่ 3/9 และ FAQ "ธนาคารขอสงวนสิทธิ์ให้บริการ QR API สำหรับนิติบุคคลเท่านั้น")
- ขั้นตอนสมัคร 9 ขั้น: สมัคร apiportal (เลือก "นิติบุคคล", ใช้อีเมลบริษัท) → สร้าง My Apps หมวด "Payment and Collection" ผลิตภัณฑ์ "QR Payment" → **ทำแบบทดสอบให้ผ่านครบทุกข้อ** → กดสมัครบริการ → เจ้าหน้าที่ธนาคารติดต่อเพื่อ **Pre-Screen** → ส่ง infra info เพื่อทำ UAT → ฝ่ายขายเก็บใบสมัคร/เอกสาร ทดสอบ UAT (รวม callback)
- **วงเงิน**: Thai QR **80,000 บาท/รายการ และ 300,000 บาท/เดือน** (ปรับตามขนาดธุรกิจ)
- **ค่าธรรมเนียม**: Thai QR MDR "ยกเว้นค่าธรรมเนียมต่อรายการ" (ธนาคารแจ้งล่วงหน้า 30 วันก่อนเก็บ); QR บัตรเครดิต 1.6% / 2.4% (non-premium / premium); "มีค่าธรรมเนียมการเชื่อมระบบ โปรดสอบถาม" — **ตารางในรูป FAQ (`…/qr-api/assets/img/table.png`) ระบุ Thai QR 0.35% ยกเว้นถึง 31 ธ.ค. 2565 และบัตรเครดิต 1.60%/2.20% ซึ่งขัดกับข้อความหลักของหน้า → รูปน่าจะเก่า ให้ถือข้อความหลักแต่ต้องถามธนาคาร**
- Certificate: ลูกค้าต้อง **ซื้อ SSL Certificate จากผู้ให้บริการ Digital Certificate** และต่ออายุให้ใช้ได้ตลอดสัญญา
- **ร้านบุคคลธรรมดา/นิติบุคคล ใช้ "QR on POS" ผ่านผู้ให้บริการ POS ที่ร่วมโครงการสมัครผ่านธนาคาร** (ตัวอย่างที่หน้าระบุ: Bento, Food Story, ZORT, StoreHub, IPST) — ธนาคารเป็นเพียงช่องทางรับสมัคร ระบบ POS ของเราไม่ได้อยู่ในรายการ

**ที่เห็นจากหน้า "My Apps" ของ portal (ข้อความ UI ใน bundle ของ SPA ไม่ใช่เอกสารทางการ [รอง])**: ฟอร์มตั้งค่าแอปมีช่อง *Partner IP/Domain Name* (ฝั่งเราเชื่อมธนาคาร), *Partner Callback IP/Domain Name* (ปลายทาง callback), *Callback URL* (https), *Settlement Report IP*, *Upload Client Certificate* (ไฟล์ .zip อายุ cert ≥ 6 เดือน), แยกข้อมูล UAT/PROD infra → สะท้อนว่า KBank **whitelist IP/โดเมนทั้งสองทิศทาง** และใช้ client certificate

**Slip verification ของ KBank**: ไม่พบ API ตรวจสลิปสำหรับร้านค้าบนหน้าสาธารณะ → [ไม่ยืนยัน] (หน้า K PLUS "verified slip" https://www.kasikornbank.com/en/personal/digital-banking/kplus/functions/verified-slip/Pages/index.html ดึงเนื้อหาไม่ได้)

### 2.3 ธนาคารอื่น (ตามที่ขอเป็นทางเลือก)

- **Bangkok Bank (BBL)** — เอกสารสาธารณะละเอียดที่สุดในสามค่าย: https://apiportal.bangkokbank.com/en/api/qr-payment และ https://apiportal.bangkokbank.com/en/api/qr-payment/api-documents [ยืนยัน] — QR Tag 30; OAuth 2.0 client credentials (access token 24 ชม.) **+ ลายเซ็น JWT (RS256) ด้วย private key ของร้านในทุก request**; TLS 1.2; แจ้งผลผ่าน notification URL ส่งซ้ำสูงสุด 3 ครั้ง; มี `qr-inquiry`, `payment-inquiry`, pull-payment (ตรวจจากสลิป), refund/void (ก่อน 23:00 ของวันเดียวกัน); **เฉพาะนิติบุคคล**; ค่าธรรมเนียม "ตามเงื่อนไขของธนาคาร"; sandbox ต้องล็อกอิน; ต้องส่ง public certificate และเซ็นสัญญา
- **KTB**: **ไม่พบ API portal/เอกสารสาธารณะสำหรับ Tag 30 dynamic QR + callback** → [ไม่ยืนยัน] (พบเฉพาะเส้นทางผ่าน gateway เช่น Opn/Omise)
- **ตัวกลาง (PSP) ทางเลือก** — ไม่ต้องต่อธนาคารเอง: Opn/Omise PromptPay ต้องอีเมลขอเปิดฟีเจอร์ ยอดขั้นต่ำ 20 บาท สูงสุด 150,000 บาท QR หมดอายุปริยาย 24 ชม. (ตั้งสั้นกว่าได้) webhook `charge.complete` — https://docs.omise.co/promptpay ; ค่าธรรมเนียมหน้าราคา 1.65%/รายการ + VAT 7% — https://omise.co/en/pricing/thailand (ไม่ระบุว่าบุคคลธรรมดาสมัครได้หรือไม่) [ยืนยันเฉพาะที่ระบุ] — แต่ก็ใช้ **webhook เข้า public HTTPS** เช่นกัน

### 2.4 ตารางเปรียบเทียบ

| หัวข้อ | SCB Open API (QR30) | SCB Mae Manee API | KBank QR API ต่อตรง | KBank QR on POS | BBL QR Payment |
|---|---|---|---|---|---|
| ผู้ใช้ | production ไม่ระบุ [ไม่ยืนยัน] | **บุคคลธรรมดาได้** (+นิติบุคคล) | **นิติบุคคลเท่านั้น** | บุคคล/นิติบุคคล (ผ่านผู้ให้บริการ POS) | **นิติบุคคลเท่านั้น** |
| Sandbox | ฟรี สมัครเอง | มี (sandbox แยก) | สมัครเอง + ต้องผ่านแบบทดสอบ | — | ต้องล็อกอิน |
| Auth | OAuth2 client credentials | OAuth2 (3-legged + client credentials) | consumer ID/secret + client cert [รอง] | — | OAuth2 + JWT signature |
| Callback | https cert จริง, retry 3×12s | มี | URL + IP/domain + cert [รอง] | — | notification URL, retry 3× |
| Inquiry fallback | มี | มี | มี (Inquire Payment) | — | มี |
| QR อายุ | ไม่พบค่า (QR30) [ไม่ยืนยัน] | ไม่พบ | 10 นาที | — | ไม่พบ |
| วงเงิน | ไม่พบ | 100,000/รายการ (บุคคล) | 80,000/รายการ, 300,000/เดือน | — | ไม่พบ |
| ค่าธรรมเนียม | ไม่พบ | ไม่พบ (QR พร้อมเพย์) | MDR Thai QR ยกเว้น + ค่าเชื่อมระบบ (สอบถาม) | — | ตามเงื่อนไขธนาคาร |

### 2.5 Callback vs VM หลัง FortiGate (ประเด็นสถาปัตยกรรม)

ข้อเท็จจริงจากโปรเจกต์: `mob04` เข้าได้ผ่าน VPN เท่านั้น และ FortiGate เคยบล็อก `ghcr.io` จนต้องให้ทีมเครือข่ายยกเว้น (`CLAUDE.md` หัวข้อ "Still open (phase 1)") → **ขาออกไปโดเมน API ธนาคารก็อาจต้องขอเปิด** และ nginx ของโปรเจกต์ออกแบบเป็น reverse proxy ตัวเดียว (กฎ `trust proxy`)

| ทางเลือก | ข้อดี | ข้อเสีย / ความเสี่ยง |
|---|---|---|
| A. ขอทีมเครือข่าย publish endpoint (VIP/port-forward + DNS + cert จาก CA สาธารณะ) | ได้ callback จริง ตรงสเปกธนาคาร | ต้องเปิด inbound สู่มหาวิทยาลัย; KBank ต้อง whitelist IP; cert ต้องต่ออายุเอง; นโยบายมหาวิทยาลัย [ไม่ยืนยัน] |
| B. Relay สาธารณะเล็กๆ (นอกมหาวิทยาลัย) รับ callback แล้วให้ VM ดึง | ไม่เปิด inbound เข้า VM | มี component ใหม่ถือข้อมูลธุรกรรม (PDPA: ชื่อ/เลขบัญชีผู้จ่าย) + จุดล้ม; ต้อง authenticate relay→VM |
| C. ไม่รับ callback — VM **poll Inquiry** ออกไปเอง (outbound HTTPS อย่างเดียว) | ง่ายที่สุดด้านเครือข่าย | SCB ระบุ inquiry เป็น fallback ไม่ใช่ช่องทางหลัก; **rate limit ของ production ไม่ทราบ** [ไม่ยืนยัน]; ต้องการ egress IP คงที่ถ้าธนาคาร whitelist (KBank) — IP ออกของมหาวิทยาลัยอาจแชร์/เปลี่ยน [ไม่ยืนยัน] |

ทั้งสามต้อง **ถามธนาคารว่ายอมรับ C เป็น production หรือไม่** ก่อนลงแรง และทุกทางต้องให้ **server เป็นผู้เรียก API ธนาคาร** (ห้ามเก็บ secret ใน Flutter client)

### 2.6 ประมาณงาน (ประมาณการของผู้วิจัย ไม่ใช่ตัวเลขจากแหล่งใด)

| งาน | ประมาณ |
|---|---|
| Phase A: QR local (tag 29 + ยอด + CRC + หน้าจอ + ปุ่มยืนยันมือ + เทสต์ตารางแอป) | ~2–4 วันทำงาน ไม่มี onboarding |
| Phase B: โมดูล server (สร้าง QR, callback/poll, สถานะ pending/paid/expired, idempotency ผูกบิล, UI รอจ่าย, void/refund policy, e2e กับ sandbox) | ~3–5 สัปดาห์ dev ต่อ 1 ธนาคาร |
| ปฏิทิน onboarding production | SCB/KBank ไม่เผยแพร่ระยะเวลา → [ไม่ยืนยัน] (KBank มี 9 ขั้น รวมแบบทดสอบ, pre-screen, UAT, สัญญา; คาดเป็นหลักสัปดาห์–เดือน) |

ข้อควรระวังกับสถาปัตยกรรมเดิมของโปรเจกต์ (อ้าง `CLAUDE.md`): ยอดเงินเป็น string `"1234.50"`; bill id/`Idempotency-Key` ต้อง mint ครั้งเดียวต่อตะกร้า (ใช้เป็น Ref1 ได้ ต้องเป็น A-Z0-9 ≤20 ตามสเปก SCB จึงต้องมี mapping); ถ้าธนาคาร 5xx/timeout สถานะการชำระ "ไม่ทราบ" ห้ามปิดบิลเอง; QR ธนาคารต้องออนไลน์ → ต้องคง fallback แบบ offline (Phase A) ไว้

---

## 3. คำแนะนำสำหรับร้านนี้

**ตอนนี้ (Phase A) — ทำ QR local ไม่ต้องรอใคร**
1. สร้าง payload tag 29 + tag 54 ยอดตามบิล + POI `12` + CRC; แสดงเป็น QR ที่หน้าชำระเงิน เมธอด "โอน/QR" ที่มีอยู่แล้ว (`'โอน/QR'` ใน `net_sales.dart`)
2. เก็บ PromptPay ID ของร้านใน Settings (เบอร์/เลขผู้เสียภาษี) — ให้เจ้าของร้านกรอกเอง
3. ปุ่ม "ลูกค้าโอนแล้ว (ตรวจสลิปแล้ว)" ให้แคชเชียร์กดเอง **อย่าเรียกว่ายืนยันอัตโนมัติ**
4. ทดสอบตารางแอปธนาคารจริงก่อน เพื่อตอบข้อ 1.4

**ภายหลัง (Phase B) — ตัดสินใจเมื่อได้คำตอบ 4 ข้อ**
1. **ร้านจดทะเบียนเป็นนิติบุคคลหรือไม่?** (กำหนดว่า KBank/BBL direct เปิดให้หรือไม่; ถ้าเป็นบุคคลธรรมดา เหลือ SCB Mae Manee หรือ QR on POS/PSP)
2. ร้านมีบัญชีธนาคารหลักที่ไหน (ผูกกับ SCB หรือ KBank)? ค่ายที่ร้านมีบัญชีและความสัมพันธ์อยู่แล้วควรเป็นตัวแรก
3. ทีมเครือข่ายมหาวิทยาลัยยอมเปิด inbound (A) หรือรับได้เฉพาะ outbound (C)? และ egress IP คงที่หรือไม่?
4. ธนาคารยอมให้ production ใช้ poll inquiry แทน callback หรือไม่ (ถามโดยตรง)

**ลำดับที่ผู้วิจัยแนะนำ**: (1) Phase A → (2) ถ้าเป็นบุคคลธรรมดาและใช้ SCB: เริ่ม sandbox Mae Manee เพราะสมัครเองได้และเอกสารเปิด; ถ้าเป็นนิติบุคคล: sandbox SCB Open API ควบคู่ ติดต่อธนาคารขอเงื่อนไข production + ค่าธรรมเนียม (2) KBank รอบสองเพราะต้องนิติบุคคล + client cert + IP whitelist + ผ่านแบบทดสอบ (3) หลีกเลี่ยงทำสองธนาคารพร้อมกันในรอบแรก — ออกแบบ interface ภายใน (`createQr` / `onPaymentConfirmed` / `inquire`) ให้สลับค่ายได้ แต่ต่อจริงค่ายเดียวก่อน

หมายเหตุ: ช่วงนี้โปรเจกต์อยู่ในสถานะ development freeze (CLAUDE.md, owner 2026-10-07) — งานนี้ต้องให้เจ้าของอนุมัติก่อนเริ่ม ไม่ควรถือเป็นงานที่เริ่มได้เอง

---

## 4. รายการที่ยืนยันไม่ได้ (ต้องถามธนาคารหรือทดสอบ)

- เงื่อนไข production + ค่าธรรมเนียม SCB Open API QR30 และ Mae Manee QR (พร้อมเพย์); ระยะเวลา onboarding
- วิธียืนยันความถูกต้องของ callback SCB (signature/IP) และสเปก callback ของ KBank (portal ต้องล็อกอิน)
- อายุ QR ของ SCB QR30 และของ BBL; rate limit production ของ inquiry ทุกค่าย
- ธปท. ฉบับปัจจุบันของ Thai QR Payment supplement (ไม่เผยแพร่); guideline ปี 2562 ยังเป็นฉบับล่าสุดหรือไม่
- ทุกแอปธนาคารล็อกยอดตาม tag 54 หรือไม่ (ต้องทดสอบเครื่องจริง)
- เพดานรายการ PromptPay กลาง (ตัวเลข 2 ล้านมาจากแหล่งรองเท่านั้น)
- KTB: ไม่พบ API ตรงสำหรับ Tag 30 dynamic QR
- รูปตารางค่าธรรมเนียมของ KBank (ลงปี 2565) ขัดกับข้อความหลักบนหน้าเดียวกัน
- การ extract ข้อความ BOT/EMVCo: อ่าน BOT PDF ครบ; EMVCo spec ต้นฉบับอ่านไม่ได้ ใช้ HKMA/BCB เป็นตัวยืนยัน CRC และ POI

## 5. รายการแหล่งอ้างอิง

- BOT Policy Guideline 2019: https://www.bot.or.th/content/dam/bot/fipcs/documents/FPG/2562/EngPDF/25620084.pdf
- EMVCo QR codes: https://www.emvco.com/emv-technologies/qr-codes/
- HKMA Common QR Code Specification (อนุพันธ์ EMV QRCPS): https://www.hkma.gov.hk/media/chi/doc/key-functions/financial-infrastructure/infrastructure/retail-payment-initiatives/Common_QR_Code_Specification.pdf
- BCB BR Code manual: https://www.bcb.gov.br/content/config/Documents/BR_Code_MANUAL_Version_2_May_2020.pdf
- SCB QR Code Payment: https://developer.scb/assets/documents/documentation/qr-payment/thai-qr.html
- SCB Payment Confirmation: https://developer.scb/assets/documents/documentation/qr-payment/payment-confirmation.html
- SCB QR create / inquiry / slip verification: https://developer.scb/assets/documents/api-reference-index/qr-payments/post-qrcode-create.html , …/post-billpayment-inquiry.html , …/get-billpayment-transactions.html
- SCB Getting started / Sandbox / Authentication / Glossary: https://developer.scb/assets/documents/documentation/basics/getting-started.html , …/developer-sandbox.html , …/authentication.html , https://developer.scb/assets/documents/api-reference-index/references/glossary.html
- SCB Mae Manee API: https://developer.scb/assets/documents/documentation/mae-manee-marchants/mae-manee-qr-payment.html , …/mae-manee-sharing-profile.html
- SCB Mae Manee product page: https://www.scb.co.th/th/personal-banking/payment/for-merchant/mae-manee-app.html
- KBank QR API: https://www.kasikornbank.com/th/business/sme/financial-services/pages/qr-api.aspx ; portal: https://apiportal.kasikornbank.com
- BBL QR Payment: https://apiportal.bangkokbank.com/en/api/qr-payment , https://apiportal.bangkokbank.com/en/api/qr-payment/api-documents
- BBL PromptPay FAQ (limits set by each bank): https://www.bangkokbank.com/en/Personal/Digital-Banking/PromptPay
- Opn/Omise: https://docs.omise.co/promptpay , https://omise.co/en/pricing/thailand
- Community spec reference [รอง]: https://thai-qr-payment.js.org/reference/spec/ ; https://www.npmjs.com/package/promptpay-js
