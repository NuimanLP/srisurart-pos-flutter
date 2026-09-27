import type { INestApplication } from '@nestjs/common';
import request from 'supertest';

/**
 * #443 PR3: `POST /platform/tenants` no longer takes `ownerPassword` — the server returns a
 * temporary one, and the owner must replace it before anything else works. Suites that only
 * need "a provisioned tenant whose owner can log in" go through the real flow here instead of
 * seeding a password hash by SQL, so they keep proving provisioning end to end.
 */
export const OWNER_CHOSEN_PASSWORD = 'owner chosen passphrase 443';

/** Logs in with the temporary password and sets `newPassword`; returns the full session. */
export async function activateOwner(
  app: INestApplication,
  username: string,
  tempPassword: string,
  newPassword = OWNER_CHOSEN_PASSWORD,
): Promise<{ accessToken: string; refreshToken: string }> {
  const login = await request(app.getHttpServer())
    .post('/api/v1/auth/token')
    .send({ username, password: tempPassword });
  if (login.status !== 200 || !login.body.data?.passwordChangeToken) {
    throw new Error(`temp-password login failed: ${login.status} ${JSON.stringify(login.body)}`);
  }
  const change = await request(app.getHttpServer())
    .post('/api/v1/auth/change-password')
    .set('Authorization', `Bearer ${login.body.data.passwordChangeToken}`)
    .send({ newPassword });
  if (change.status !== 200) {
    throw new Error(`change-password failed: ${change.status} ${JSON.stringify(change.body)}`);
  }
  return change.body.data;
}
