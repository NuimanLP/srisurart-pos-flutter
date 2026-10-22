import { describe, it, expect } from 'vitest';
import { judgeRefresh, REFRESH_GRACE_MAX_SEC } from './refresh-rotation.js';

// Security review 2026-10-21: refresh tokens are single-use. Each login's chain ("family")
// keeps the jti of the one refresh token that may rotate next, plus the one it replaced.
const J0 = '00000000-0000-4000-8000-000000000000';
const J1 = '11111111-1111-4111-8111-111111111111';
const J2 = '22222222-2222-4222-8222-222222222222';

const family = (over: Partial<Parameters<typeof judgeRefresh>[0] & object> = {}) => ({
  current_jti: J1,
  previous_jti: J0,
  revoked: false,
  grace_used: false,
  seconds_since_rotation: 60,
  ...over,
});

describe('judgeRefresh', () => {
  it('rotates the current token', () => {
    expect(judgeRefresh(family(), J1)).toEqual({ kind: 'rotate' });
  });

  it('answers the token just replaced ONCE with the current jti — its reply may have been lost', () => {
    expect(judgeRefresh(family(), J0)).toEqual({ kind: 'grace', jti: J1 });
    // An offline till retrying hours later is still inside the bound.
    expect(judgeRefresh(family({ seconds_since_rotation: 6 * 3600 }), J0)).toEqual({ kind: 'grace', jti: J1 });
  });

  it('calls the token just replaced a reuse the second time it is presented', () => {
    expect(judgeRefresh(family({ grace_used: true }), J0)).toEqual({ kind: 'reused' });
  });

  it('calls the token just replaced a reuse once the current one has been presented (it is then two generations old)', () => {
    // J0 → J1, then J1 presented → J2 (previous J1, grace reset): J0 is now a replayed copy.
    expect(judgeRefresh(family({ current_jti: J2, previous_jti: J1, seconds_since_rotation: 0 }), J0)).toEqual({
      kind: 'reused',
    });
  });

  it('calls the token just replaced a reuse after the time bound', () => {
    expect(judgeRefresh(family({ seconds_since_rotation: REFRESH_GRACE_MAX_SEC }), J0)).toEqual({ kind: 'reused' });
    expect(REFRESH_GRACE_MAX_SEC).toBe(24 * 3600);
  });

  it('refuses every token of a revoked chain, the current one included', () => {
    expect(judgeRefresh(family({ revoked: true }), J1)).toEqual({ kind: 'revoked' });
    expect(judgeRefresh(family({ revoked: true }), J0)).toEqual({ kind: 'revoked' });
  });

  it('refuses a token whose chain is not on record', () => {
    expect(judgeRefresh(undefined, J1)).toEqual({ kind: 'unknown' });
  });

  it('a chain that has never rotated has no previous token to answer', () => {
    expect(judgeRefresh(family({ previous_jti: null }), J0)).toEqual({ kind: 'reused' });
  });
});
