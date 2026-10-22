/**
 * Refresh-token rotation with reuse detection (security review 2026-10-21; ADR-0009 addendum
 * 2026-10-22). Every login's chain of refresh tokens is one row of `refresh_families`, keyed by
 * the jti of the chain's first refresh token (`fid` in every later one). The row holds the jti
 * of the one token that may rotate next (`current_jti`) and of the one it replaced
 * (`previous_jti`).
 *
 * The replaced token may be answered — with a token carrying the CURRENT jti, no new rotation —
 * exactly once, while the current one has not been presented, and within
 * `REFRESH_GRACE_MAX_SEC` of the rotation. That covers a reply lost on a shop network (the
 * client keeps the token it sent on a timeout, and an offline till may retry hours later) and
 * two tabs sharing one refresh token in IndexedDB: the callers converge on one token instead of
 * forking the chain. Anything else is a reuse — a copy is being played by someone else — so the
 * whole chain is revoked and every holder must log in again:
 * - the replaced token a second time (`grace_used`): a thief holding it cannot keep pulling the
 *   current token while the owner's device sits idle;
 * - the replaced token after the current one was presented: presenting it rotates it, so the
 *   replaced token is then two generations old (the rotation itself is "current seen");
 * - the replaced token after the time bound, or any older token.
 */
export const REFRESH_GRACE_MAX_SEC = 24 * 3600;

export interface RefreshFamilyState {
  current_jti: string;
  previous_jti: string | null;
  revoked: boolean;
  /** The replaced token has already been answered once since the last rotation. */
  grace_used: boolean;
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
    !family.grace_used &&
    family.seconds_since_rotation < REFRESH_GRACE_MAX_SEC
  ) {
    return { kind: 'grace', jti: family.current_jti };
  }
  return { kind: 'reused' };
}
