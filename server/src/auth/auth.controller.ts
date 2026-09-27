import { Controller, Post, Get, Body, HttpCode, UnauthorizedException, UseGuards, Req } from '@nestjs/common';
import type { Request } from 'express';
import { AuthService, type LoginDto } from './auth.service.js';
import { JwtVerifier } from './jwt-keys.service.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { clientIp } from '../common/client-ip.js';

@Controller('auth')
export class AuthController {
  constructor(
    private readonly authService: AuthService,
    private readonly jwtVerifier: JwtVerifier
  ) {}

  @Post('token')
  @HttpCode(200)
  async login(@Body() dto: LoginDto, @Req() req: Request) {
    if (!dto.username || !dto.password) {
      throw new UnauthorizedException('Username and password are required');
    }
    // One validated source for the caller's address, the same helper the audit services use (#138).
    return this.authService.login(dto, clientIp(req) ?? undefined);
  }

  @Post('refresh')
  @HttpCode(200)
  async refresh(
    @Body() dto: { refreshToken?: string },
    @Req() req: Request,
  ) {
    const authHeader = req.headers.authorization;
    const bearerToken = authHeader?.startsWith('Bearer ') ? authHeader.substring(7) : undefined;
    const refreshToken = dto?.refreshToken || bearerToken;
    if (!refreshToken) {
      throw new UnauthorizedException('Refresh token is required');
    }
    
    // Verify signature and type 'refresh'
    let payload;
    try {
      payload = this.jwtVerifier.verify(refreshToken, 'refresh');
    } catch (err) {
      if (err instanceof UnauthorizedException) {
        throw err;
      }
      throw new UnauthorizedException('Invalid or expired refresh token');
    }
    
    // Check DB status and issue new tokens
    return this.authService.refreshTokenPayload(payload);
  }

  /**
   * #443 PR3: the only route a `typ:'pwchange'` token opens. Verified here rather than by
   * `TenantGuard`, which demands `typ:'access'` and so refuses this token everywhere else.
   */
  @Post('change-password')
  @HttpCode(200)
  async changePassword(@Body() dto: { newPassword?: unknown }, @Req() req: Request) {
    const authHeader = req.headers.authorization;
    const token = authHeader?.startsWith('Bearer ') ? authHeader.substring(7) : undefined;
    if (!token) {
      throw new UnauthorizedException('Password change token is required');
    }
    const payload = this.jwtVerifier.verify(token, 'pwchange');
    return this.authService.changePassword(payload, dto?.newPassword, clientIp(req) ?? undefined);
  }

  @Post('device')
  @HttpCode(200)
  async enrolDevice(@Body() dto: { code: string }) {
    if (!dto.code) {
      throw new UnauthorizedException('Enrolment code is required');
    }
    return this.authService.enrolDevice(dto.code);
  }

  @Get('me')
  @UseGuards(TenantGuard)
  async me(@Req() req: Request & { user: any }) {
    return req.user;
  }
}
