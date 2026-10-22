import { describe, it, expect } from 'vitest';
import { judgeRefresh, REFRESH_REUSE_GRACE_SEC } from './refresh-rotation.js';

// Security review 2026-10-21: refresh tokens are single-use. Each login's chain ("family")
// keeps the jti of the one refresh token that may rotate next, plus the one it replaced.
const J0 = '00000000-0000-4000-8000-000000000000';
const J1 = '11111111-1111-4111-8111-111111111111';
const J2 = '22222222-2222-4222-8222-222222222222';

const family = (over: Partial<Parameters<typeof judgeRefresh>[0] & object> = {}) => ({
  current_jti: J1,
  previous_jti: J0,
  revoked: false,
  seconds_since_rotation: 3600,
  ...over,
});

describe('judgeRefresh', () => {
  it('rotates the current token', () => {
    expect(judgeRefresh(family(), J1)).toEqual({ kind: 'rotate' });
  });

  it('answers the token just replaced, inside the grace window, with the current jti — no new rotation', () => {
    expect(judgeRefresh(family({ seconds_since_rotation: 2 }), J0)).toEqual({ kind: 'grace', jti: J1 });
    expect(judgeRefresh(family({ seconds_since_rotation: REFRESH_REUSE_GRACE_SEC - 1 }), J0)).toEqual({
      kind: 'grace',
      jti: J1,
    });
  });

  it('calls the token just replaced a reuse once the grace window has passed', () => {
    expect(judgeRefresh(family({ seconds_since_rotation: REFRESH_REUSE_GRACE_SEC }), J0)).toEqual({
      kind: 'reused',
    });
  });

  it('calls any older token of the chain a reuse, even right after a rotation', () => {
    expect(judgeRefresh(family({ seconds_since_rotation: 0 }), J2)).toEqual({ kind: 'reused' });
  });

  it('refuses every token of a revoked chain, the current one included', () => {
    expect(judgeRefresh(family({ revoked: true }), J1)).toEqual({ kind: 'revoked' });
    expect(judgeRefresh(family({ revoked: true, seconds_since_rotation: 1 }), J0)).toEqual({
      kind: 'revoked',
    });
  });

  it('refuses a token whose chain is not on record', () => {
    expect(judgeRefresh(undefined, J1)).toEqual({ kind: 'unknown' });
  });

  it('a chain that has never rotated has no previous token to grant grace to', () => {
    expect(judgeRefresh(family({ previous_jti: null, seconds_since_rotation: 0 }), J0)).toEqual({
      kind: 'reused',
    });
  });
});
