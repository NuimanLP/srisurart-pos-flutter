/**
 * Refresh-token rotation with reuse detection (security review 2026-10-21; ADR-0009 addendum
 * 2026-10-22). Every login's chain of refresh tokens is one row of `refresh_families`, keyed by
 * the jti of the chain's first refresh token (`fid` in every later one). The row holds the jti
 * of the one token that may rotate next (`current_jti`) and of the one it replaced
 * (`previous_jti`).
 *
 * Why a grace window for `previous_jti`: two tabs of the web client share one refresh token in
 * IndexedDB and can send it at the same moment, and a reply lost on a shop network leaves the
 * client holding the token it sent. Within `REFRESH_REUSE_GRACE_SEC` of the rotation the replaced
 * token is answered with a token carrying the CURRENT jti — no new rotation — so the two callers
 * converge on one token instead of forking the chain. Past the window, or for any older token,
 * it is a reuse: a copy of the token is being played by someone else, so the whole chain is
 * revoked and both holders must log in again.
 */
export const REFRESH_REUSE_GRACE_SEC = 30;

export interface RefreshFamilyState {
  current_jti: string;
  previous_jti: string | null;
  revoked: boolean;
  /** Seconds since `current_jti` was issued, measured by Postgres's own clock. */
  seconds_since_rotation: number;
}

export type RefreshVerdict =
  | { kind: 'rotate' }
  | { kind: 'grace'; jti: string }
  | { kind: 'reused' }
  | { kind: 'revoked' }
  | { kind: 'unknown' };

/** What `/auth/refresh` does with a refresh token whose chain is `family`. */
export function judgeRefresh(family: RefreshFamilyState | undefined, jti: string): RefreshVerdict {
  if (!family) return { kind: 'unknown' };
  if (family.revoked) return { kind: 'revoked' };
  if (jti === family.current_jti) return { kind: 'rotate' };
  if (
    family.previous_jti !== null &&
    jti === family.previous_jti &&
    family.seconds_since_rotation < REFRESH_REUSE_GRACE_SEC
  ) {
    return { kind: 'grace', jti: family.current_jti };
  }
  return { kind: 'reused' };
}
