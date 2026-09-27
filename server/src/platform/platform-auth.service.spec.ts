import { describe, it, expect, vi } from 'vitest';
import { HttpException, UnauthorizedException } from '@nestjs/common';
import { PlatformAuthService } from './platform-auth.service.js';
import { verifyJwt } from '../common/jwt.js';

// A rate limiter that always allows, for tests that are not about throttling.
function fakeRateLimit() {
  return {
    consumeAttempt: vi.fn().mockResolvedValue({ allowed: true }),
    clearKey: vi.fn().mockResolvedValue(undefined),
    refundAttempt: vi.fn().mockResolvedValue(undefined),
  };
}

const argonHook = vi.hoisted(() => ({ verifies: 0 }));
vi.mock('argon2', async (importOriginal) => {
  const orig = await importOriginal<typeof import('argon2')>();
  return {
    ...orig,
    verify: (...args: Parameters<typeof orig.verify>) => {
      argonHook.verifies++;
      return orig.verify(...args);
    },
  };
});

// #425: an unknown platform admin must cost the same one argon2 verify as a wrong password,
// and get the same error, so latency does not reveal which admin usernames exist.
describe('PlatformAuthService.login timing shape', () => {
  it.each([
    ['an unknown admin', false],
    ['a wrong password', true],
  ])('runs argon2 verify exactly once and refuses %s identically', async (_l, exists) => {
    const argon2 = await import('argon2');
    const hash = await argon2.hash('right-password-123');
    const adminDs = {
      query: vi.fn().mockResolvedValue(
        exists
          ? [{ id: 'a1', username: 'root', password_hash: hash, display_name: 'R', is_active: true }]
          : [],
      ),
    };
    const audit = { log: vi.fn() };
    const service = new PlatformAuthService(
      adminDs as any,
      { jwtPlatformSecret: 's' } as any,
      audit as any,
      fakeRateLimit() as any,
    );

    argonHook.verifies = 0;
    const err = await service.login('root', 'wrong', '127.0.0.1').catch((e: unknown) => e);

    expect(argonHook.verifies).toBe(1);
    expect(err).toBeInstanceOf(UnauthorizedException);
    expect((err as UnauthorizedException).message).toBe('Invalid platform admin credentials');
    expect(audit.log).not.toHaveBeenCalled();
  });
});

// #443 PR4 (Q8): the browser keeps this token in sessionStorage with no refresh, so its TTL was
// cut from 24h to 1h.
describe('PlatformAuthService token TTL', () => {
  it('issues a token that expires in 1 hour, not 24', async () => {
    const argon2 = await import('argon2');
    const hash = await argon2.hash('right-password-123');
    const adminDs = {
      query: vi.fn().mockResolvedValue([
        { id: 'a1', username: 'root', password_hash: hash, display_name: 'R', is_active: true },
      ]),
    };
    const secret = 'test-secret';
    const service = new PlatformAuthService(
      adminDs as any,
      { jwtPlatformSecret: secret } as any,
      { log: vi.fn() } as any,
      fakeRateLimit() as any,
    );

    const before = Math.floor(Date.now() / 1000);
    const { token } = await service.login('root', 'right-password-123', '127.0.0.1');
    const payload = verifyJwt(token, secret);

    expect(payload).not.toBeNull();
    const ttl = (payload!.exp as number) - before;
    expect(ttl).toBeGreaterThan(3595);
    expect(ttl).toBeLessThanOrEqual(3600);
  });
});

// #443 PR4 (Q5, owner decision): platform login gets the same per-IP + per-username throttle
// as the owner login (auth.service.ts), mirrored via RateLimitService.consumeAttempt.
describe('PlatformAuthService login throttle', () => {
  it('refuses with 429 RATE_LIMITED when the IP bucket is exhausted, before touching the DB', async () => {
    const adminDs = { query: vi.fn() };
    const rateLimit = {
      consumeAttempt: vi.fn().mockResolvedValueOnce({ allowed: false, retryAfter: 42 }),
      clearKey: vi.fn(),
      refundAttempt: vi.fn(),
    };
    const service = new PlatformAuthService(
      adminDs as any,
      { jwtPlatformSecret: 's' } as any,
      { log: vi.fn() } as any,
      rateLimit as any,
    );

    const err = await service
      .login('root', 'whatever', '10.0.0.5')
      .catch((e: unknown) => e);

    expect(err).toBeInstanceOf(HttpException);
    expect((err as HttpException).getStatus()).toBe(429);
    expect((err as HttpException).getResponse()).toMatchObject({
      code: 'RATE_LIMITED',
      retryAfter: 42,
    });
    expect(rateLimit.consumeAttempt).toHaveBeenCalledWith('platform:ip:10.0.0.5', 10, 60);
    expect(adminDs.query).not.toHaveBeenCalled();
  });

  it('refuses with 429 RATE_LIMITED when the username bucket is exhausted', async () => {
    const adminDs = { query: vi.fn() };
    const rateLimit = {
      consumeAttempt: vi
        .fn()
        .mockResolvedValueOnce({ allowed: true }) // IP bucket ok
        .mockResolvedValueOnce({ allowed: false, retryAfter: 7 }), // username bucket exhausted
      clearKey: vi.fn(),
      refundAttempt: vi.fn(),
    };
    const service = new PlatformAuthService(
      adminDs as any,
      { jwtPlatformSecret: 's' } as any,
      { log: vi.fn() } as any,
      rateLimit as any,
    );

    const err = await service
      .login('flaky-admin', 'whatever', '10.0.0.5')
      .catch((e: unknown) => e);

    expect(err).toBeInstanceOf(HttpException);
    expect((err as HttpException).getStatus()).toBe(429);
    expect(rateLimit.consumeAttempt).toHaveBeenCalledWith('platform:user:flaky-admin', 5, 60);
    expect(adminDs.query).not.toHaveBeenCalled();
  });

  it('clears the username bucket and refunds the IP bucket on a successful login', async () => {
    const argon2 = await import('argon2');
    const hash = await argon2.hash('right-password-123');
    const adminDs = {
      query: vi.fn().mockResolvedValue([
        { id: 'a1', username: 'root', password_hash: hash, display_name: 'R', is_active: true },
      ]),
    };
    const rateLimit = fakeRateLimit();
    const service = new PlatformAuthService(
      adminDs as any,
      { jwtPlatformSecret: 's' } as any,
      { log: vi.fn() } as any,
      rateLimit as any,
    );

    await service.login('root', 'right-password-123', '10.0.0.5');

    expect(rateLimit.clearKey).toHaveBeenCalledWith('platform:user:root', 60);
    expect(rateLimit.refundAttempt).toHaveBeenCalledWith('platform:ip:10.0.0.5', 60);
  });

  it('does not clear or refund on a failed login', async () => {
    const adminDs = { query: vi.fn().mockResolvedValue([]) };
    const rateLimit = fakeRateLimit();
    const service = new PlatformAuthService(
      adminDs as any,
      { jwtPlatformSecret: 's' } as any,
      { log: vi.fn() } as any,
      rateLimit as any,
    );

    await service.login('root', 'wrong', '10.0.0.5').catch(() => {});

    expect(rateLimit.clearKey).not.toHaveBeenCalled();
    expect(rateLimit.refundAttempt).not.toHaveBeenCalled();
  });
});
