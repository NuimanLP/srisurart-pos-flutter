import { Injectable, Inject, Logger, UnauthorizedException } from '@nestjs/common';
import * as jwt from 'jsonwebtoken';
import { APP_CONFIG, type AppConfig } from '../config/config.js';

export interface JwtPayload {
  iss: 'srisurart-pos';
  aud: 'tenant' | 'platform';
  sub: string;      // userId
  iat: number;
  exp: number;
  jti: string;
  typ: 'access' | 'refresh';
  tid?: string;     // tenant_id (absent for platform admin)
  role?: string;    // user role
  did?: string;     // device id
  drole?: string;   // device role ('pos' | 'backoffice')
}

@Injectable()
export class JwtSigner {
  private readonly logger = new Logger(JwtSigner.name);
  private readonly privateKey: string;
  private readonly keyId: string;

  constructor(@Inject(APP_CONFIG) cfg: AppConfig) {
    if (!cfg.jwtPrivateKey) {
      this.logger.error('JWT_PRIVATE_KEY is missing but JwtSigner is instantiated.');
      throw new Error('JWT_PRIVATE_KEY is required to issue tokens.');
    }
    this.privateKey = cfg.jwtPrivateKey;
    this.keyId = cfg.jwtKeyId ?? 'key-1';
  }

  sign(
    payload: Omit<JwtPayload, 'iss' | 'iat' | 'exp'>,
    expiresInOrExp: number | string,
  ): string {
    const options: jwt.SignOptions = {
      algorithm: 'RS256',
      keyid: this.keyId,
    };

    if (typeof expiresInOrExp === 'number') {
      return jwt.sign(
        { ...payload, iss: 'srisurart-pos', exp: expiresInOrExp },
        this.privateKey,
        options,
      );
    }

    return jwt.sign(
      { ...payload, iss: 'srisurart-pos' },
      this.privateKey,
      { ...options, expiresIn: expiresInOrExp as any },
    );
  }
}

@Injectable()
export class JwtVerifier {
  private readonly logger = new Logger(JwtVerifier.name);
  private readonly publicKeys: Map<string, string>; // kid -> PEM

  constructor(@Inject(APP_CONFIG) cfg: AppConfig) {
    if (!cfg.jwtPublicKeys || cfg.jwtPublicKeys.length === 0) {
      this.logger.error('JWT_PUBLIC_KEYS is missing but JwtVerifier is instantiated.');
      throw new Error('JWT_PUBLIC_KEYS is required to verify tokens.');
    }
    
    this.publicKeys = new Map();
    cfg.jwtPublicKeys.forEach((keyPem, idx) => {
      this.publicKeys.set(`key-${idx + 1}`, keyPem);
    });
    if (cfg.jwtKeyId && !this.publicKeys.has(cfg.jwtKeyId) && cfg.jwtPublicKeys[0]) {
      this.publicKeys.set(cfg.jwtKeyId, cfg.jwtPublicKeys[0]);
    }
  }

  verify(token: string, expectedTyp: 'access' | 'refresh'): JwtPayload {
    let decoded: jwt.Jwt | null = null;
    try {
      decoded = jwt.decode(token, { complete: true });
    } catch {
      throw new UnauthorizedException('Invalid token structure');
    }

    if (!decoded || !decoded.header || !decoded.header.kid) {
      throw new UnauthorizedException('Invalid token structure or missing kid');
    }

    const kid = decoded.header.kid;
    const publicKey = this.publicKeys.get(kid);
    if (!publicKey) {
      throw new UnauthorizedException(`Unknown key id: ${kid}`);
    }

    try {
      // Verify signature with RS256 only, 30s clock tolerance
      const payload = jwt.verify(token, publicKey, {
        algorithms: ['RS256'],
        clockTolerance: 30, // 30 seconds skew allowed
      }) as JwtPayload;

      if (payload.iss !== 'srisurart-pos') {
        throw new UnauthorizedException('Invalid token issuer');
      }
      if (payload.typ !== expectedTyp) {
        throw new UnauthorizedException(`Expected token of type ${expectedTyp}`);
      }
      return payload;
    } catch (err) {
      if (err instanceof UnauthorizedException) {
        throw err;
      }
      throw new UnauthorizedException(
        err instanceof Error ? err.message : 'Token verification failed',
      );
    }
  }
}
