import { createHmac, timingSafeEqual } from 'node:crypto';

export interface JwtPayload {
  iss?: string;
  aud?: string;
  sub?: string;
  tid?: string;
  did?: string;
  drole?: string;
  username?: string;
  iat?: number;
  exp?: number;
  jti?: string;
  typ?: string;
  [key: string]: unknown;
}

export function signJwt(payload: JwtPayload, secret: string): string {
  const header = { alg: 'HS256', typ: 'JWT' };
  const base64Header = Buffer.from(JSON.stringify(header)).toString('base64url');
  const base64Payload = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = createHmac('sha256', secret)
    .update(`${base64Header}.${base64Payload}`)
    .digest('base64url');
  return `${base64Header}.${base64Payload}.${signature}`;
}

export function verifyJwt(token: string, secret: string): JwtPayload | null {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [base64Header, base64Payload, signature] = parts;
  const expectedSig = createHmac('sha256', secret)
    .update(`${base64Header}.${base64Payload}`)
    .digest('base64url');

  const sigBuf = Buffer.from(signature);
  const expBuf = Buffer.from(expectedSig);
  if (sigBuf.length !== expBuf.length || !timingSafeEqual(sigBuf, expBuf)) {
    return null;
  }
  try {
    const payload = JSON.parse(
      Buffer.from(base64Payload, 'base64url').toString('utf-8'),
    ) as JwtPayload;
    if (payload.exp && typeof payload.exp === 'number' && Date.now() / 1000 > payload.exp) {
      return null;
    }
    return payload;
  } catch {
    return null;
  }
}
