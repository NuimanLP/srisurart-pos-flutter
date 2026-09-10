import { Global, Module } from '@nestjs/common';
import { AuthController } from './auth.controller.js';
import { AuthService } from './auth.service.js';
import { JwtSigner, JwtVerifier } from './jwt-keys.service.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';

@Global()
@Module({
  controllers: [AuthController],
  providers: [AuthService, JwtSigner, JwtVerifier, TenantGuard],
  exports: [JwtVerifier, AuthService, TenantGuard],
})
export class AuthModule {}
