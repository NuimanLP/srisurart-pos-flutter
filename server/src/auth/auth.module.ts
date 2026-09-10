import { Global, Module } from '@nestjs/common';
import { AuthController } from './auth.controller.js';
import { AuthService } from './auth.service.js';
import { JwtSigner, JwtVerifier } from './jwt-keys.service.js';

@Global()
@Module({
  controllers: [AuthController],
  providers: [AuthService, JwtSigner, JwtVerifier],
  exports: [JwtVerifier, AuthService],
})
export class AuthModule {}
