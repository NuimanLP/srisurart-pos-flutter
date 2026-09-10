import { Injectable, Inject, Logger } from '@nestjs/common';
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

  constructor(@Inject(APP_CONFIG) cfg: AppConfig) {
    if (!cfg.jwtPrivateKey) {
      this.logger.error('JWT_PRIVATE_KEY is missing but JwtSigner is instantiated.');
      throw new Error('JWT_PRIVATE_KEY is required to issue tokens.');
    }
    this.privateKey = cfg.jwtPrivateKey;
  }

  sign(payload: Omit<JwtPayload, 'iss' | 'iat' | 'exp'>, expiresIn: number | string): string {
    // Determine a basic key ID from the private key itself or just use a fixed one for phase 1.
    // In a real system, you'd extract the kid from the private key if it's a JWK, or pass it via env.
    // For now, we use a default kid "key-1".
    return jwt.sign(
      { ...payload, iss: 'srisurart-pos' },
      this.privateKey,
      { algorithm: 'RS256', expiresIn: expiresIn as any, keyid: 'key-1' }
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
    // Assuming keys are provided as a single PEM block if not explicitly separated by commas.
    // In phase 1, we just take the first key and map it to "key-1".
    // If multiple keys exist (for rotation), we map them sequentially or parse if they have headers.
    cfg.jwtPublicKeys.forEach((keyPem, idx) => {
      this.publicKeys.set(`key-${idx + 1}`, keyPem);
    });
  }

  verify(token: string, expectedTyp: 'access' | 'refresh'): JwtPayload {
    const decoded = jwt.decode(token, { complete: true });
    if (!decoded || !decoded.header || !decoded.header.kid) {
      throw new Error('Invalid token structure or missing kid');
    }

    const kid = decoded.header.kid;
    const publicKey = this.publicKeys.get(kid);
    if (!publicKey) {
      throw new Error(`Unknown kid: ${kid}`);
    }

    // Verify signature with RS256 only, 30s clock tolerance
    const payload = jwt.verify(token, publicKey, {
      algorithms: ['RS256'],
      clockTolerance: 30, // 30 seconds skew allowed
    }) as JwtPayload;

    if (payload.iss !== 'srisurart-pos') {
      throw new Error('Invalid issuer');
    }
    if (payload.typ !== expectedTyp) {
      throw new Error(`Expected token of type ${expectedTyp}`);
    }
    return payload;
  }
}
