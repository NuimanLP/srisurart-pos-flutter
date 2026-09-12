# Handoff — รอบตรวจ 3 แกนบน #56/#82 แล้ว merge PR #84 (2026-09-12)

**วันที่:** 2026-09-12 · **ผู้บันทึก:** NuimanLP (`team/1`) · **สถานะ:** ปิดแล้ว
**ขอบเขต:** กู้ CI ที่แดงบน PR #84 → merge `main` เข้า branch → ตรวจ 3 แกน → แก้ 🔴 4 ตัว + บั๊กที่เป็นของ #55/#54 → merge → เคลียร์ ticket
**ต่อจาก:** [`fe3-api-writes.md`](fe3-api-writes.md) (ตัวสไลซ์เอง) · [`ticket-55-fe2-api-repository-reads.md`](ticket-55-fe2-api-repository-reads.md)

## 1. ตอนนี้อยู่ตรงไหน

`main` = `ae4d47b` เขียวทั้ง Server CI และ Flutter CI · PR #84 merged, branch ลบแล้ว · frontend **239 tests**, `dart analyze` clean

- ปิดรอบนี้: **#56 #82** (จาก PR) · **#33 #34** (merge ไปแล้วแต่ค้างเปิดไว้)
- จงใจไม่ปิด พร้อมเหตุผลในคอมเมนต์ของ issue: **#54 #55**
- ใบที่ `team/1` หยิบต่อได้: **#24** แล้วค่อย **#30** (ดูข้อ 6)

## 2. รอบนี้ทำอะไรไป ได้ผลอะไร

1. **CI แดงบน #84 — ไม่ใช่โค้ดของ branch** run ที่แดงเป็น sha `cc66555` ซึ่งเป็น merge commit ที่ GitHub สร้างเอง ไม่ใช่ head ของ branch (`0eda8ed` รันตอน 05:58 เขียวทั้งคู่) ตัวที่พังคือ `test/reports.e2e-spec.ts:205` p95 = 2577 ms ของ #29 ที่ merge เข้า `main` ตอน 09:25 แล้วทำ `main` แดงด้วย (2666 ms) · #88 แถม `776f05f` มาแก้ merge `main` เข้ามาก็หาย
2. **Conflict เดียวตอน merge: `repository_providers.dart`** — #55 กับ #56 ต่างใส่สวิตช์ของตัวเองที่ signature เดียวกัน เก็บไว้ทั้งคู่ (ดูข้อ 3)
3. **ตรวจ 3 แกนขนาน** (Standards / Spec / Scrutinize, Opus) บน diff `a57fb1e...0eda8ed` — Standards: โค้ดไม่ผิด convention ข้อไหน เจอแต่เอกสารขัดกันเอง 4 จุด · Spec: #82 ผ่าน 9/9, #56 ผ่าน 5/7 · Scrutinize: 🔴 3 ตัว — **ไล่โค้ดยืนยันเองทุกตัวก่อนแก้**
4. **แก้ 🔴 4 ตัว** (commit `d5d22f8`) ทั้งหมดคือความผิดพลาดเดียวกัน: *ถือว่า server ตอบแล้วทั้งที่ยังไม่ได้ตอบ*
   - `ApiException` ทุกตัวถูกนับเป็นคำตอบ รวม 5xx/429 → nginx 504 (รูปแบบที่เกิดจริงที่สุด เพราะ `ApiClient` ไม่ตั้ง timeout) ทำให้กดซ้ำได้บิลที่สอง เคสคมสุดคือ `503 IDEMPOTENCY_KEY_IN_FLIGHT` ซึ่งแปลตรงตัวว่า "ตัวเดิมยังทำงานอยู่" → `isVerdict()` = `< 500 && != 429`
   - `createReturn` / `addDrawerEntry` ไม่มีการกันซ้ำเลย mint key ใหม่ทุกครั้ง · `POST /returns` ไม่รับ id จาก client เลย header คือด่านเดียว และ `assertRefundable` กันแค่ `sold − refunded` → คืน 3 จาก 10 สองครั้ง = ใบลดหนี้ 2 ใบที่ถูกกติกา คืนเงิน 600 บาทสำหรับของ 300 บาท → ย้ายกลไกเป็น `PendingWrites` ใน `api_wire.dart` ใช้ร่วมกันทั้งสามทางเงิน
   - `409 CREDIT_LIMIT_EXCEEDED` ไม่มีตัวรับ → ทางตันที่กดกี่ทีก็ซ้ำเดิม
   - ปิด attempt **ก่อน** patch → patch พังเมื่อไหร่ retry เปิดบิลที่สอง
5. **แก้บั๊กที่เป็นของ #55 และ #54 ต่อในใบเดียวกัน** (commit `a5358d1`) — fallback 16 จุด + wire `onSessionExpired` (ดูข้อ 3)
6. **เทสต์ 223 → 239** ทุกตัวใหม่แดงบนโค้ดเดิม: 504 ไม่ใช่ verdict · 503 in-flight · patch พังแล้วยัง park · retry ใบลดหนี้/รายการลิ้นชักใช้ key เดิม · 409 credit limit ถามใหม่แล้วส่งต่อ / กดยกเลิกแล้วไม่ส่ง · 5 reads พร้อมกัน refresh ครั้งเดียว · refresh ถูกปฏิเสธแล้วปิด session เงียบ · ไม่มี `deviceId`/`tenantId` บนสาย · contract test 2 ตัวใหม่ + self-check
7. **เอกสารที่ agent จับได้ว่าขัดกันเอง** แก้แล้ว: `CONTRACT.md` §4 (สองสวิตช์ + 16 providers + `BootstrapService`) และ §6 (`SaleInput.overrideCreditLimit` หายจากรายการ frozen) · `02_API_SCREENS.md` §3.1 (`offlineOk` ค้างในตัวอย่าง สวนทางกับโค้ดและอีก 3 เอกสาร) · ADR-0010 §3 (ตารางหลักหล่น `movements` และไม่เคยได้ 4 field ของ #82 · addendum 4 ยังเขียน "ไม่ใช่ `mechanicAfter`" ทั้งที่ #82 เพิ่มไปแล้วใน PR เดียวกัน)

## 3. ตัดสินใจอะไรไปบ้าง เพราะอะไร

| เรื่อง | ทางเลือก | เลือก | เหตุผล |
|---|---|---|---|
| conflict `repository_providers.dart` | เอาของ #55 / เอาของ #56 / เก็บทั้งคู่ | **เก็บทั้งคู่** — `useApi` (writes, default false) + `useApiRepositories` (reads, default true) | เลือกข้างใดข้างหนึ่ง = อีกสไลซ์ตายเงียบ repo ฝั่งนั้นกลับไปเป็น Drift ล้วนโดยไม่มีใครรู้ |
| บั๊ก `catch (_)` ของ #55 | เปิด ticket ใหม่ / แก้ใน #84 | **แก้ใน #84** | จุดบอดที่ทำให้ไม่มีใครเห็นคือ contract test ของ #56 เอง (glob ครอบแค่ `repositories/api/`) จะขยาย glob โดยไม่แก้ไฟล์ที่มันจับได้ก็ทำไม่ได้ |
| fallback ของ #55 | ลบทิ้ง / ใส่ guard | **ใส่ guard** — เฉพาะ `on ApiException` ที่ห้าม fallback | fallback มีเหตุผลจริง: เฟส 1 ไม่มี cutover และ `API_BASE_URL` default = localhost ลบออก = แอปที่ร้านใช้พังทันที |
| หน้า login ของ #54 | สร้างให้ / ไม่สร้าง | **ไม่สร้าง** | เป็น UI ที่ลูกค้าเห็นและมี Thai string ที่ CLAUDE.md สั่งว่า "Never invent new ones" — เจ้าของร้านเป็นคนตั้งคำ |
| TTL ของ parked attempt | ไม่มี / ผูกกับ `CartCubit` / TTL | **TTL 10 นาที** | ไม่มี = ตะกร้าเหมือนกันคนละเวลาไป replay บิลเก่า · ผูกกับ cubit สะอาดกว่าแต่เป็น refactor คนละขนาด (ยังเป็นข้อเสนอที่ดี ดูข้อ 6) |
| ปิด #54 / #55 ไหม | ปิดตาม PR ที่ merge / เปิดไว้ | **เปิดไว้** | AC ที่ยังไม่จริงเป็นเรื่องมีอยู่จริง ไม่ใช่แค่ไม่มีเทสต์ (ดูข้อ 5) — ธรรมเนียมเดียวกับที่ #23/#28 เคยเปิดค้างไว้ |

ผู้ตัดสิน: NuimanLP ทั้งหมด (สั่ง "แก้ทั้งหมดเลย แล้ว merge")

## 4. ลองแล้วไม่เวิร์ก (ทางตัน)

- **แก้ 409 credit limit โดยไม่แตะ `rethrowThai` ไม่ได้** — `rethrowThai` แปลง `ApiException` เป็น `Exception(thaiMessage)` ซึ่ง **ลบ error code ทิ้ง** จอเลยแยกไม่ออกว่า 409 ตัวไหน ต้องเพิ่ม `PosException` (code + message + details) ที่ `toString()` คืนประโยคไทยล้วน ทั้งสามจอจึงไม่ต้องแก้อะไรเลย
- **`final SaleRow sale;` แล้ว assign ทั้งใน try และ catch ไม่ผ่าน analyzer** (`assignment_to_final_local`) เพราะ flow analysis ถือว่า try อาจ assign ไปแล้ว → เปลี่ยนเป็น closure `Future<SaleRow?> submit()` แล้ว `if (sale == null) return;` สำหรับเคสกดยกเลิก
- **ปิด #54 ไม่ได้ และไม่ใช่เพราะไม่มีเทสต์** — `lib/presentation/screens/` มี 11 จอเท่าเดิม ไม่มี login และ `app_router.dart` ไม่มี auth guard AC3 *"lands on the login screen"* กับ AC5 *"enrolling with a code"* ไม่มีที่ให้ไปโผล่

## 5. ยังไม่ชัวร์ / สมมติฐานที่ยังไม่พิสูจน์

**ยืนยันแล้ว** (ไล่โค้ด / รันจริง): 🔴 ทั้ง 4 ตัว · fallback 16 จุด · `onSessionExpired` ไม่มีคนฟัง · reports ฝั่ง client ยังไม่มีคนเรียก `/reports` · #24/#30 ปลดบล็อกครบ

**ยังไม่พิสูจน์ / รู้ตัวว่ายังค้าง:**

- 🔴 **default ของสองสวิตช์ยังไม่สอดคล้องกัน และ *ไม่ได้แก้* รอบนี้** — `useApiRepositories = true` เป็นค่า hard-code ไม่มี `bool.fromEnvironment` เลยไม่มี build ไหนปิด reads ได้ ขณะที่ `useApi = false` ทำให้ Drift `saveSale` ขยับสต็อกและ ledger ในเครื่องสำหรับบิลที่ server ไม่เคยเห็น วันที่ `API_BASE_URL` ชี้ไป demo tenant จริงโดยไม่เปิด `USE_API_WRITES` การ sync รอบถัดไปจะทับค่าเหล่านั้น (Scrutinize ข้อ 7 — **PLAUSIBLE ยังไม่ได้ทดลอง**) วันนี้ยังไม่พังเพราะ `API_BASE_URL` default = `http://localhost:3000` แล้วทุก read ตกกลับ Drift เงียบ ๆ
- **#56 AC2 "verified against the server" ยังไม่เคยรัน end-to-end** — พิสูจน์เป็นสองซีก (client = MockClient, server = e2e จริง) มาบรรจบกันด้วยการอ่านโค้ด เพราะ `useApi` default false
- **TTL 10 นาที เป็นการตัดสินใจ ไม่ใช่ค่าที่วัดมา** — สั้นไปเสี่ยงบิลซ้ำ ยาวไปเสี่ยง replay บิลเก่า ยังไม่มีข้อมูลหน้างานมายืนยัน
- **FK guard ใน `addDrawerEntry` กันสิ่งที่เกิดไม่ได้** — SQLite ปิด `foreign_keys` เป็น default และทั้งแอปไม่มีที่ไหนเปิด (grep แล้ว 0 hit) แปลว่า insert ที่มันหลบจะสำเร็จอยู่แล้ว ส่วนที่แลกไปคือมัน **ทิ้งรายการจริงเงียบ ๆ** เมื่อกะแม่ไม่อยู่ใน cache — ไม่ได้แก้ เพราะมีเทสต์ pin พฤติกรรมนั้นไว้ และรายการยังปลอดภัยอยู่บน server

## 6. ก้าวถัดไป (เรียงลำดับ)

1. **#24 `p5.7` mechanic credit payments** — ปลดบล็อกแล้ว (#19 #17 ปิด) · ตาราง `credit_payments` (migration `…000`) และ series `CP` ใน `DOC_PREFIX` มีรออยู่แล้ว ยังไม่มี endpoint
2. **#30 `p7.2` closing report** — 🔴 **ต้องทำหลัง #24** AC ข้อแรกคือ *"expected cash รวมเงินที่ช่างมาผ่อนชำระ และเทสต์ที่ถอดพจน์นี้ออกต้องแดง"* ซึ่งต้องมี endpoint ของ #24 ก่อน · **tracker ไม่ได้บันทึกความสัมพันธ์นี้** (Blocked by ของ #30 มีแค่ #28 #29)
3. **#54** — รอเจ้าของโปรเจกต์ตัดสิน: ทำหน้า login ต่อในใบนี้ หรือแตกใบใหม่ใต้ #52
4. **#55** — reports ฝั่ง client (ของ `LomerAlloys`)
5. **#39** — trap เดิม: `paths:` ที่ trigger ทำให้ PR ที่แตะแค่ `server/` ไม่รัน Flutter jobs เลย ถ้าตั้ง required status checks บน `main` เมื่อไหร่จะบล็อกถาวร (ของ `LomerAlloys`)
6. (งานเก็บ) ย้าย fingerprint ของ `PendingWrites` ไปผูกกับ identity ของตะกร้าใน `CartCubit` แทน value fingerprint — ตัด TTL และ map ที่ไม่มีขอบเขตทิ้งได้ทั้งคู่

## 7. ข้อควรระวัง

- 🔴 **lock order ปัจจุบัน `sale → mechanic → products → doc_counters → customer`** — #24 แตะ mechanic + doc_counters ต้องเรียงตามนี้ ไม่งั้น deadlock กับบิลเครดิต
- 🔴 **validate ก่อน clamp** — AC ของ #24 สั่ง `GREATEST(0, …)` ซึ่งเป็นรูปแบบเดียวกับที่ทำให้บั๊กเงินของ #22 เงียบ (clamp บน input ที่ไม่ได้ตรวจ เปลี่ยน corruption ที่ดังให้เงียบ)
- **`isVerdict` เป็นกฎเดียวที่กันบิลซ้ำทั้งระบบตอนนี้** — endpoint ใหม่ที่เขียนเงิน/สต็อกต้องไปผ่าน `PendingWrites` ไม่ใช่เรียก `idempotencyKey()` ตรง ๆ
- **contract test ตรวจที่ระดับ source และครอบ 2 โฟลเดอร์แล้ว** (`repositories/api/` + `repositories/api_*.dart`) เพิ่มไฟล์ repo ใหม่ต้องรู้ว่ามันจะถูกตรวจ
- **กับดักเครื่องมือ ไม่ใช่ของโปรเจกต์:** ระหว่างเซสชันนี้ การเขียนไฟล์ผ่าน Python heredoc ทำ `CLAUDE.md` เหลือ 0 ไบต์ครั้งหนึ่ง เพราะ `open(…,'w')` truncate ก่อน แล้ว encode emoji พัง (surrogate pair) กู้ด้วย `git checkout --` วิธีที่ปลอดภัยคือ `data = s.encode('utf-8')` **ก่อน** เปิดไฟล์ แล้วเขียนแบบ `'wb'` · อีกอันคือ backslash ใน heredoc ถูกยุบ ต้องใช้ `chr(92)` แทน

## 8. อ้างอิง

- PR #84 (`ae4d47b`) · commit `ed5f297` (merge main) · `d5d22f8` (แก้ 🔴 4 ตัว) · `a5358d1` (fallback + session)
- [`fe3-api-writes.md`](fe3-api-writes.md) — รายละเอียดของสไลซ์ + ส่วน *"สามสิ่งที่รอบตรวจที่สองเจอ"*
- `frontend/lib/data/repositories/api/api_wire.dart` — `PendingWrites`, `isVerdict`
- `frontend/lib/core/network/api_exception.dart` — `PosException`, `rethrowServerRefusal`
- `frontend/test/api_repository_contract_test.dart` — กฎที่บังคับใช้จริง
- ADR-0010 §3 · `02_API_SCREENS.md` §3.1 §8.1 §8.2 · `CONTRACT.md` §4 §6
- คนที่ต้องถาม: เจ้าของโปรเจกต์ (คำไทยของหน้า login, #12 #13) · `LomerAlloys` (#55 #39) · `PattaraponKitcharoen` (#54 #83)
