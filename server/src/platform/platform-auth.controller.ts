import { Body, Controller, HttpCode, HttpStatus, Post, Req } from '@nestjs/common';
import type { Request } from 'express';
import { PlatformAuthService } from './platform-auth.service.js';

@Controller('platform/auth')
export class PlatformAuthController {
  constructor(private readonly authService: PlatformAuthService) {}

  @Post('token')
  @HttpCode(HttpStatus.OK)
  async login(
    @Body() body: { username?: string; password?: string },
    @Req() req: Request,
  ) {
    if (!body.username || !body.password) {
      throw new Error('Username and password are required');
    }
    const ip = (req.headers['x-forwarded-for'] as string) || req.ip;
    return this.authService.login(body.username, body.password, ip);
  }
}
