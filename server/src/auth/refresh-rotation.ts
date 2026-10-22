/**
 * Refresh-token rotation with reuse detection (security review 2026-10-21; ADR-0009 addendum
 * 2026-10-22). Every login's chain of refresh tokens is one row of `refresh_families`, keyed by
 * the jti of the chain's first refresh token (`fid` in every later one). The row holds the jti
 * of the one token that may rotate next (`current_jti`) and of the one it replaced
 * (`previous_jti`).
 *
 * The replaced token stays answerable until the token that replaced it is presented: until then
 * the server cannot tell whether its holder ever received the reply. A reply lost on a shop
 * network (the client keeps the token it sent, however long the till then stays offline), or two
 * tabs sharing one refresh token in IndexedDB, are answered with a token carrying the CURRENT
 * jti — no new rotation — so the callers converge on one token instead of forking the chain.
 * Presenting the current token rotates it, which is the proof that its holder got it: from then
 * on the token before it is two generations old, and presenting that, or anything older, is a
 * reuse — a copy is being played by someone else, so the whole chain is revoked and every holder
 * must log in again.
 *
 * "Current presented at least once" therefore needs no column of its own: it is the rotation.
 * (Owner review of #755 replaced a fixed 30 s window, which logged an offline till out when a
 * lost reply was retried later.)
 */
export interface RefreshFamilyState {
  current_jti: string;
  previous_jti: string | null;
  revoked: boolean;
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
  if (family.previous_jti !== null && jti === family.previous_jti) {
    return { kind: 'grace', jti: family.current_jti };
  }
  return { kind: 'reused' };
}
