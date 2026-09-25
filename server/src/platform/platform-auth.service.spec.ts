import { describe, it, expect, vi } from 'vitest';
import { UnauthorizedException } from '@nestjs/common';
import { PlatformAuthService } from './platform-auth.service.js';

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
    );

    argonHook.verifies = 0;
    const err = await service.login('root', 'wrong', '127.0.0.1').catch((e: unknown) => e);

    expect(argonHook.verifies).toBe(1);
    expect(err).toBeInstanceOf(UnauthorizedException);
    expect((err as UnauthorizedException).message).toBe('Invalid platform admin credentials');
    expect(audit.log).not.toHaveBeenCalled();
  });
});
