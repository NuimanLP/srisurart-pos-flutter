import * as argon2 from 'argon2';
import { pbkdf2Sync, timingSafeEqual } from 'node:crypto';

export async function hashPassword(password: string): Promise<string> {
  return argon2.hash(password, {
    type: argon2.argon2id,
    memoryCost: 65536, // 64 MiB (ADR-0009)
    timeCost: 3,
    parallelism: 1,
  });
}

export async function verifyPassword(password: string, combinedHash: string): Promise<boolean> {
  if (combinedHash.startsWith('$argon2')) {
    try {
      return await argon2.verify(combinedHash, password);
    } catch {
      return false;
    }
  }

  // Fallback for legacy PBKDF2 hashes
  const parts = combinedHash.split(':');
  if (parts.length !== 2) return false;
  const [salt, hash] = parts;
  const verifyHash = pbkdf2Sync(password, salt, 1000, 64, 'sha512').toString('hex');
  const buf1 = Buffer.from(hash, 'hex');
  const buf2 = Buffer.from(verifyHash, 'hex');
  return buf1.length === buf2.length && timingSafeEqual(buf1, buf2);
}
