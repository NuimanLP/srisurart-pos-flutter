# Handoff: Client Auth + Device Token + Server Error Strings (Ticket #54, `fe.1`)

**วันที่:** 2026-09-12 · **ผู้บันทึก:** PattaraponKitcharoen (`team/3` / Lane C)
**สถานะ:** เสร็จสมบูรณ์ (พร้อมเปิด PR และ merge)
**ขอบเขต:** สร้าง Network Layer, Token Storage, Device Enrolment, Error Envelope Mapping และ Auth State ใน Flutter (`frontend/`) ปลดล็อก #55 (`fe.2`) และ #56 (`fe.3`)
**ต่อจาก:** [`ticket-4-6-43-auth-jwt-roles.md`](ticket-4-6-43-auth-jwt-roles.md) / [`fe0-drift-schema-v3.md`](fe0-drift-schema-v3.md)

---

## 1. สิ่งที่สร้างและพฤติกรรมของระบบ

### 1. Network Layer & Error Strings
- `frontend/lib/core/network/api_client.dart`:
  - จัดการ HTTP requests ผ่าน `http.Client`
  - แนบ Header `Authorization: Bearer <token>` อัตโนมัติเมื่อมี access token
  - ดักจับ HTTP 401: เรียก `POST /api/v1/auth/refresh` ด้วย refreshToken แล้วนำ accessToken ใหม่มา retry คำขอเดิมอัตโนมัติ พร้อม concurrency lock (`_refreshFuture`) ป้องกันการยิง refresh ซ้ำซ้อน
  - ดักจับ HTTP 429: ถอดรหัส `Retry-After` header แปลงเป็น `ApiException(code: 'RATE_LIMITED')`
  - ถอดรหัส JSON envelope `{ status: 'error', error: { code, message, details } }`
- `frontend/lib/core/network/server_error_resolver.dart`:
  - แมปข้อความไทยตรงตามข้อกำหนดใน `02_API_SCREENS.md §8` และ `§8.1`
  - เคารพข้อความเดิมจาก server หากมีรายละเอียดภาษาไทย (เช่น `สต็อกไม่พอ:\n...`)
  - คงรูปข้อความอังกฤษตามที่สเปคระบุไว้ (`SALE_NOT_FOUND`, `SALE_VOIDED`, `NO_OPEN_SHIFT`)
- `frontend/lib/core/network/api_exception.dart`:
  - Exception มาตรฐานเก็บ `statusCode`, `code`, `serverMessage`, `details`, `retryAfterSeconds` และ `thaiMessage`

### 2. Domain & Token Storage
- `frontend/lib/domain/models/auth_models.dart`:
  - `AuthUser`, `AuthTokens`, และ `JwtClaims` (unverified decoder สำหรับสกัด claim เช่น `did`, `drole`, `exp` ฝั่ง client)
- `frontend/lib/data/storage/token_storage.dart`:
  - `SharedPrefsTokenStorage` สำหรับเก็บ accessToken, refreshToken, deviceToken, และ user profile
  - **ADR-0004 Invariant:** `clearAuthTokens()` ลบเฉพาะข้อมูลผู้ใช้แต่คง `deviceToken` ไว้ (การ logout ไม่ถอนการผูกเครื่อง POS)
  - `clearAll()` ล้างข้อมูลทั้งหมดเมื่อต้องการยกเลิกการผูกเครื่อง

### 3. Data & Presentation
- `frontend/lib/data/repositories/auth_repository.dart`:
  - `login(...)`: แนบ `deviceToken` อัตโนมัติหากเครื่องถูกผูกแล้ว เพื่อให้ server ออก JWT ที่มี `did` และ `drole` (ADR-0004)
  - `enrolDevice(...)`: แลกเปลี่ยน enrolment code 6 หลักที่เจ้าของร้านออกให้เป็น `deviceToken` ถาวร
  - `refresh()`: รันรอบ refresh โทเคน
  - `logout()` และ `clearDeviceEnrolment()`
- `frontend/lib/presentation/blocs/auth_cubit.dart`:
  - State: `AuthInitial`, `AuthLoading`, `Authenticated`, `Unauthenticated`
- `frontend/lib/presentation/screens/settings_screen.dart`:
  - เพิ่มแท็บ **"🔐 บัญชี / ผูกเครื่อง"** ในหน้าตั้งค่า
  - แสดงสถานะผู้ใช้, ปุ่มเข้าสู่ระบบ/ออกจากระบบ, และปุ่มสำหรับผูกเครื่อง POS / ปลดเครื่อง
- `frontend/lib/presentation/widgets/login_dialog.dart` & `device_enrolment_dialog.dart`:
  - ไดอะล็อกสำหรับการล็อกอินและการผูกเครื่องพร้อม indicator บทบาทเครื่อง

---

## 2. การตรวจสอบและความถูกต้อง (Verification)

1. **`dart analyze --fatal-infos`:** Clean 100% (No issues found!)
2. **`flutter test`:** ผ่านครบทั้ง **164 tests** (เพิ่ม unit tests ใหม่ 25 tests สำหรับ resolver, storage, api_client, auth_repository, auth_cubit)
3. **`drift codegen check`:** ไม่มี diff ใน `*.g.dart`
4. **`flutter build web --no-tree-shake-icons`:** คอมไพล์ web build สำเร็จ (26.1s)
5. **Git Hygiene:** `pubspec.yaml` รักษา CRLF line terminators (`git diff --numstat` มีเพียง `1 0`)
