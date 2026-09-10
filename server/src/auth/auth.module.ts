import { Module } from '@nestjs/common';
import { AuthController } from './auth.controller.js';
import { AuthService } from './auth.service.js';
import { JwtSigner, JwtVerifier } from './jwt-keys.service.js';

@Module({
  controllers: [AuthController],
  providers: [AuthService, JwtSigner, JwtVerifier],
  exports: [JwtVerifier], // Export verifier so guards can use it
})
export class AuthModule {}
