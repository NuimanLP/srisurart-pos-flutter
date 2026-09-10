import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Inject,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { verifyJwt } from '../common/jwt.js';

@Injectable()
export class PlatformAuthGuard implements CanActivate {
  constructor(@Inject(APP_CONFIG) private readonly config: AppConfig) {}

  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest();
    const authHeader = req.headers['authorization'];
    if (!authHeader || typeof authHeader !== 'string') {
      throw new UnauthorizedException('Missing Authorization header');
    }

    const [scheme, token] = authHeader.split(' ');
    if (scheme !== 'Bearer' || !token) {
      throw new UnauthorizedException('Invalid Authorization header format');
    }

    const payload = verifyJwt(token, this.config.jwtPlatformSecret);
    if (!payload) {
      throw new UnauthorizedException('Invalid or expired platform token');
    }

    if (payload.aud !== 'platform') {
      throw new ForbiddenException('Token audience is not platform');
    }

    req.platformAdmin = {
      id: payload.sub,
      username: payload.username,
    };

    return true;
  }
}
