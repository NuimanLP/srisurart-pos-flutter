import { describe, it, expect, beforeEach } from 'vitest';
import * as crypto from 'node:crypto';
import * as jwt from 'jsonwebtoken';
import { UnauthorizedException } from '@nestjs/common';
import { JwtSigner, JwtVerifier } from './jwt-keys.service.js';
import type { AppConfig } from '../config/config.js';

describe('JwtSigner & JwtVerifier', () => {
  let privateKeyPem: string;
  let publicKeyPem: string;
  let config: AppConfig;
  let signer: JwtSigner;
  let verifier: JwtVerifier;

  beforeEach(() => {
    const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });

    privateKeyPem = privateKey;
    publicKeyPem = publicKey;

    config = {
      port: 3000,
      instanceId: 'api-1',
      logLevel: 'silent',
      databaseUrl: 'postgres://dummy',
      adminDatabaseUrl: 'postgres://dummy-admin',
      dbPoolSize: 5,
      redisCacheUrl: 'redis://dummy',
      redisQueueUrl: 'redis://dummy',
      jwtPlatformSecret: 'dummy-platform-secret',
      jwtTenantSecret: 'dummy-tenant-secret',
      jwtPrivateKey: privateKeyPem,
      jwtPublicKeys: [publicKeyPem],
      jwtKeyId: 'key-1',
    };

    signer = new JwtSigner(config);
    verifier = new JwtVerifier(config);
  });

  it('signs and verifies a valid RS256 access token', () => {
    const token = signer.sign(
      {
        aud: 'tenant',
        sub: 'user-123',
        jti: 'jti-1',
        typ: 'access',
        tid: 'tenant-456',
        role: 'cashier',
        drole: 'pos',
      },
      '15m',
    );

    const payload = verifier.verify(token, 'access');
    expect(payload.sub).toBe('user-123');
    expect(payload.tid).toBe('tenant-456');
    expect(payload.typ).toBe('access');
    expect(payload.drole).toBe('pos');
    expect(payload.iss).toBe('srisurart-pos');
  });

  it('signs with numeric Unix epoch exp and verifies', () => {
    const targetExp = Math.floor(Date.now() / 1000) + 3600;
    const token = signer.sign(
      {
        aud: 'tenant',
        sub: 'user-123',
        jti: 'jti-2',
        typ: 'refresh',
        tid: 'tenant-456',
      },
      targetExp,
    );

    const payload = verifier.verify(token, 'refresh');
    expect(payload.exp).toBe(targetExp);
    expect(payload.typ).toBe('refresh');
  });

  it('rejects an access token presented when expecting a refresh token', () => {
    const token = signer.sign(
      {
        aud: 'tenant',
        sub: 'user-123',
        jti: 'jti-1',
        typ: 'access',
        tid: 'tenant-456',
      },
      '15m',
    );

    expect(() => verifier.verify(token, 'refresh')).toThrow(UnauthorizedException);
    expect(() => verifier.verify(token, 'refresh')).toThrow(/Expected token of type refresh/);
  });

  it('rejects key-confusion attack (ADR-0009): token signed with HS256 using public key as secret', () => {
    // Classic vulnerability where verifier accepts HMAC using RSA public key string
    const forgedToken = jwt.sign(
      {
        iss: 'srisurart-pos',
        aud: 'tenant',
        sub: 'attacker',
        jti: 'jti-forged',
        typ: 'access',
        tid: 'tenant-456',
      },
      publicKeyPem,
      { algorithm: 'HS256', keyid: 'key-1' },
    );

    expect(() => verifier.verify(forgedToken, 'access')).toThrow(UnauthorizedException);
  });

  it('rejects expired token after clock skew', () => {
    // Expired 40 seconds ago (tolerance is 30s)
    const expiredExp = Math.floor(Date.now() / 1000) - 40;
    const token = signer.sign(
      {
        aud: 'tenant',
        sub: 'user-123',
        jti: 'jti-3',
        typ: 'access',
        tid: 'tenant-456',
      },
      expiredExp,
    );

    expect(() => verifier.verify(token, 'access')).toThrow(UnauthorizedException);
  });

  it('rejects tokens with missing or unknown kid', () => {
    const forgedNoKid = jwt.sign(
      { iss: 'srisurart-pos', aud: 'tenant', sub: 'u', typ: 'access' },
      privateKeyPem,
      { algorithm: 'RS256' }, // no keyid
    );

    expect(() => verifier.verify(forgedNoKid, 'access')).toThrow(UnauthorizedException);
    expect(() => verifier.verify(forgedNoKid, 'access')).toThrow(/missing kid/);

    const forgedWrongKid = jwt.sign(
      { iss: 'srisurart-pos', aud: 'tenant', sub: 'u', typ: 'access' },
      privateKeyPem,
      { algorithm: 'RS256', keyid: 'unknown-key-99' },
    );

    expect(() => verifier.verify(forgedWrongKid, 'access')).toThrow(UnauthorizedException);
    expect(() => verifier.verify(forgedWrongKid, 'access')).toThrow(/Unknown key id/);
  });
});
