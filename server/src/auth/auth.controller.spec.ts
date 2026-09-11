import { describe, it, expect, vi } from 'vitest';
import { UnauthorizedException } from '@nestjs/common';
import { AuthController } from './auth.controller.js';

describe('AuthController', () => {
  const authServiceMock = {
    login: vi.fn(),
    refreshTokenPayload: vi.fn(),
    enrolDevice: vi.fn(),
  };

  const jwtVerifierMock = {
    verify: vi.fn(),
  };

  const controller = new AuthController(
    authServiceMock as any,
    jwtVerifierMock as any,
  );

  it('login delegates to authService.login', async () => {
    authServiceMock.login.mockResolvedValue({ accessToken: 'a1', refreshToken: 'r1' });

    const res = await controller.login({ username: 'owner', password: 'pwd' });
    expect(res).toEqual({ accessToken: 'a1', refreshToken: 'r1' });
    expect(authServiceMock.login).toHaveBeenCalledWith({ username: 'owner', password: 'pwd' });
  });

  it('login throws UnauthorizedException when credentials are missing', async () => {
    await expect(controller.login({ username: '', password: '' } as any)).rejects.toThrow(
      UnauthorizedException,
    );
  });

  it('refresh accepts token from body', async () => {
    jwtVerifierMock.verify.mockReturnValue({ typ: 'refresh', sub: 'u1' });
    authServiceMock.refreshTokenPayload.mockResolvedValue({ accessToken: 'a2', refreshToken: 'r2' });

    const reqMock = { headers: {} } as any;
    const res = await controller.refresh({ refreshToken: 'token-body' }, reqMock);

    expect(jwtVerifierMock.verify).toHaveBeenCalledWith('token-body', 'refresh');
    expect(res).toEqual({ accessToken: 'a2', refreshToken: 'r2' });
  });

  it('refresh accepts token from Authorization Bearer header when body is empty', async () => {
    jwtVerifierMock.verify.mockReturnValue({ typ: 'refresh', sub: 'u1' });
    authServiceMock.refreshTokenPayload.mockResolvedValue({ accessToken: 'a2', refreshToken: 'r2' });

    const reqMock = {
      headers: {
        authorization: 'Bearer token-bearer',
      },
    } as any;
    const res = await controller.refresh({}, reqMock);

    expect(jwtVerifierMock.verify).toHaveBeenCalledWith('token-bearer', 'refresh');
    expect(res).toEqual({ accessToken: 'a2', refreshToken: 'r2' });
  });

  it('refresh throws UnauthorizedException when neither body nor header has token', async () => {
    const reqMock = { headers: {} } as any;
    await expect(controller.refresh({}, reqMock)).rejects.toThrow(UnauthorizedException);
  });

  it('enrolDevice delegates to authService.enrolDevice', async () => {
    authServiceMock.enrolDevice.mockResolvedValue({ deviceToken: 'dev-tok' });

    const res = await controller.enrolDevice({ code: 'CODE123' });
    expect(res).toEqual({ deviceToken: 'dev-tok' });
    expect(authServiceMock.enrolDevice).toHaveBeenCalledWith('CODE123');
  });

  it('me returns req.user', async () => {
    const reqMock = {
      user: {
        userId: 'u1',
        tenantId: 't1',
        role: 'owner',
      },
    } as any;

    const res = await controller.me(reqMock);
    expect(res).toEqual(reqMock.user);
  });
});
