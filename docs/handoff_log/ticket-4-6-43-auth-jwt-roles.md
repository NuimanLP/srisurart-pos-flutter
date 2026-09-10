# Handoff: Authentication, Device Roles, and Audit Logging (Tickets #4, #6, #43)

**Date:** 2026-09-10
**Project path:** `/Users/peternus/Desktop/srisurart-pos-flutter`
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch `main`
**Previous handoff:** [`to-tickets-backend.md`](to-tickets-backend.md)

## What this session was

This session focused on implementing the core security and authentication layer of the backend, covering three interconnected tickets from `team/3` (Lane C):
1. **Ticket #4**: JWT session, login logic, and token refreshment rules.
2. **Ticket #6**: Device roles (POS vs Backoffice) and the device enrolment flow.
3. **Ticket #43**: Audit logging (`สมุดบันทึกเวรยาม`) for security and tracking.

The implementation strictly followed the architectural decisions laid out in `ADR-0003` (Tenant suspension), `ADR-0004` (Device roles & enrolment), and `ADR-0009` (JWT session lifetime).

## What was built

### 1. Audit Logging (`AuditService`)
- Implemented `server/src/audit/audit.service.ts` using TypeORM raw queries (`manager.query`).
- Records structured logs (`action`, `tenant_id`, `user_id`, `device_id`, `ip`, `before`, `after`) inside business transactions.
- Provides the foundation required for tracking failed login attempts, tenant suspensions, and future business events.

### 2. JWT Configuration & RS256 (`JwtSigner` & `JwtVerifier`)
- Added `jwtPrivateKey` and `jwtPublicKeys` to `AppConfig` (`config.ts`).
- Updated `docker-compose.yml` to securely inject the private key ONLY into `api-*` containers, keeping it out of `worker` and `migrate`.
- Implemented `server/src/auth/jwt-keys.service.ts` using `jsonwebtoken`.
  - Enforces `RS256` asymmetric encryption.
  - Verifier allows a 30-second clock tolerance for resilience.

### 3. Authentication Flow (`AuthService` & `AuthController`)
- **Login (`POST /auth/token`)**:
  - Validates Argon2id password hashes.
  - Supports logging in with or without a `deviceToken`. If provided, it scopes the search to the specific tenant; if not, it ensures the `username` is globally unambiguous.
  - Checks both `users.is_active` and `tenants.status` before issuing tokens.
- **Refresh Token (`POST /auth/refresh`)**:
  - Enforces ADR-0009 rules: expiration is strictly tied to `04:00 AM` in the tenant's specified timezone.
  - Re-verifies tenant, user, and device status to instantly lock out retired devices or suspended tenants.
- **Device Enrolment (`POST /auth/device`)**:
  - Implements ADR-0004 by exchanging a one-time `enrolment_code_hash` for a permanent `deviceToken`.

### 4. Security Contexts & RLS Readiness (`TenantGuard`)
- Built `server/src/common/guards/tenant.guard.ts` to parse Bearer tokens, verify signatures, and extract `tid`, `did`, and `drole`.
- Implemented Redis status caching (`t:{tid}:status`, 300s TTL + jitter) per ADR-0003, falling back to DB on miss.
- Emits standardized Thai error envelopes (`TENANT_SUSPENDED` and `DEVICE_ROLE_FORBIDDEN`) per `02_API_SCREENS.md §8.1`.
- Implemented the `@RequireDeviceRole('pos')` decorator to restrict register/drawer access to POS terminals while granting POS devices full access to backoffice endpoints per ADR-0004.
- Added `GET /auth/me` in `AuthController` guarded by `TenantGuard` to return the current authenticated user context.
- Exported `TenantService` via `DbModule` for transactional RLS isolation.
- Marked `AuthModule` as `@Global()` to provide `JwtVerifier` and `AuthService` across all domain modules.

### 5. Adversarial Scrutiny Fixes & Migration
- Added Migration `1788652800002-AuthSecurityDefinerAndAuditFix.ts`:
  - Implemented `auth_lookup_device_by_token`, `auth_lookup_user_for_login`, and `auth_enrol_device` as `SECURITY DEFINER` procedures to safely bypass PostgreSQL RLS for unauthenticated pre-auth lookups without tenant leaks.
  - Relaxed `audit_log_check` constraint to support non-user events (`device.%` and `auth.%`).
- Fixed `JwtSigner` to natively accept numeric epoch `exp` timestamps, eliminating privateKey property leaks.
- Wrapped `AuthController.refresh` with explicit `401 Unauthorized` handling and `TENANT_SUSPENDED` on inactive tenant per ADR-0003, and added fallback support for `Authorization: Bearer` header.
- Sanitized and strictly validated `params.ip` in `AuditService` using `net.isIP` to prevent Postgres `INET` syntax errors.
- Corrected `TenantGuard` device role logic to ensure POS terminals are never blocked from backoffice operations.
- Resolved Ticket #5 cross-integration collision: unified `password.ts` to Argon2id per ADR-0009, hashed initial POS device `enrolCode` using SHA-256 in `PlatformTenantsService`, and defensively handled malformed password hashes in `AuthService.login`.
- Expanded test suites across 7 test files (`auth.service.spec.ts`, `jwt-keys.service.spec.ts`, `tenant.guard.spec.ts`, `auth.controller.spec.ts`, `audit.service.spec.ts`, `platform.spec.ts`, `http-exception.filter.spec.ts`) — **50/50 passing in <1s**.

## State

- Fully functioning authentication, device roles, and audit logging system.
- Code compiles cleanly (`pnpm typecheck` and `pnpm lint` passed with 0 errors).
- All 50 unit tests pass (`pnpm test` green).
- Frontend `dart analyze` and `flutter test` (123 tests) completely green.

## Next Steps

- **End-to-End Tests**: E2E tests for the authentication and device enrolment flows need to be written (not done in this session to prioritize passing API development).
- **Frontend Integration (q1)**: The Flutter client's `ApiRepository` layer needs to be wired to call `POST /auth/token` and handle the new error strings.
- Remaining backend tickets for `team/1` (Transactions) and `team/2` (Catalogue/Reports) can now safely rely on the `TenantGuard` and `TenantService` for RLS isolation.
