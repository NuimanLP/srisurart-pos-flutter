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
- The guard actively hits the DB to check `tenants.status` on every request.
- Implemented the `@RequireDeviceRole('pos' | 'backoffice')` decorator to restrict endpoint access.
- Finalized `TenantService` and exported it via `DbModule` to allow downstream services to execute raw queries safely within a `SET LOCAL app.tenant_id` context for Row-Level Security (RLS).

## State

- The backend now has a fully functioning authentication and session management system.
- Code compiles correctly (`pnpm typecheck` and `pnpm lint` passed with 0 errors).
- Unit tests (`pnpm test`) remain green.
- No global TypeORM entities were used; everything correctly uses raw queries as mandated by the current Phase 1 codebase structure.

## Next Steps

- **End-to-End Tests**: E2E tests for the authentication and device enrolment flows need to be written (not done in this session to prioritize passing API development).
- **Frontend Integration (q1)**: The Flutter client's `ApiRepository` layer needs to be wired to call `POST /auth/token` and handle the new error strings.
- Remaining backend tickets for `team/1` (Transactions) and `team/2` (Catalogue/Reports) can now safely rely on the `TenantGuard` and `TenantService` for RLS isolation.
