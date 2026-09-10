import { Controller, Post, Body, HttpCode, UnauthorizedException } from '@nestjs/common';
import { AuthService, type LoginDto } from './auth.service.js';
import { JwtVerifier } from './jwt-keys.service.js';

@Controller('auth')
export class AuthController {
  constructor(
    private readonly authService: AuthService,
    private readonly jwtVerifier: JwtVerifier
  ) {}

  @Post('token')
  @HttpCode(200)
  async login(@Body() dto: LoginDto) {
    if (!dto.username || !dto.password) {
      throw new UnauthorizedException('Username and password are required');
    }
    return this.authService.login(dto);
  }

  @Post('refresh')
  @HttpCode(200)
  async refresh(@Body() dto: { refreshToken: string }) {
    if (!dto.refreshToken) {
      throw new UnauthorizedException('Refresh token is required');
    }
    
    // Verify signature and type 'refresh'
    let payload;
    try {
      payload = this.jwtVerifier.verify(dto.refreshToken, 'refresh');
    } catch (err) {
      if (err instanceof UnauthorizedException) {
        throw err;
      }
      throw new UnauthorizedException('Invalid or expired refresh token');
    }
    
    // Check DB status and issue new tokens
    return this.authService.refreshTokenPayload(payload);
  }

  @Post('device')
  @HttpCode(200)
  async enrolDevice(@Body() dto: { code: string }) {
    if (!dto.code) {
      throw new UnauthorizedException('Enrolment code is required');
    }
    return this.authService.enrolDevice(dto.code);
  }
}
