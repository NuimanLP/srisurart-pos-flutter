import { BadRequestException } from '@nestjs/common';
import { describe, expect, it } from 'vitest';
import { parseGitSha } from '../config/config.js';
import {
  AUDIT_PAGE_DEFAULT,
  AUDIT_PAGE_MAX,
  decodeAuditCursor,
  encodeAuditCursor,
  parseAuditLimit,
  toAuditEntry,
  type AuditRow,
} from './platform-audit.service.js';

function codeOf(fn: () => unknown): string | undefined {
  try {
    fn();
  } catch (err) {
    expect(err).toBeInstanceOf(BadRequestException);
    return ((err as BadRequestException).getResponse() as { code?: string }).code;
  }
  return undefined;
}

describe('parseAuditLimit — validate first, then clamp', () => {
  it('defaults when absent or empty', () => {
    expect(parseAuditLimit(undefined)).toBe(AUDIT_PAGE_DEFAULT);
    expect(parseAuditLimit('')).toBe(AUDIT_PAGE_DEFAULT);
  });

  it('accepts 1..max and clamps a well-formed larger value', () => {
    expect(parseAuditLimit('1')).toBe(1);
    expect(parseAuditLimit('200')).toBe(200);
    expect(parseAuditLimit('999999')).toBe(AUDIT_PAGE_MAX);
  });

  it.each(['0', '-1', '1.5', 'abc', '1e3', ' 5', '9999999', ['5', '6']])(
    'refuses %j with INVALID_AUDIT_LIMIT',
    (raw) => {
      expect(codeOf(() => parseAuditLimit(raw))).toBe('INVALID_AUDIT_LIMIT');
    },
  );
});

describe('audit cursor codec', () => {
  it('round-trips microseconds and a bigint id', () => {
    const c = { createdAt: '2026-10-03T01:02:03.123456Z', id: '9223372036854775807' };
    expect(decodeAuditCursor(encodeAuditCursor(c))).toEqual(c);
  });

  it.each([
    ['not base64url', '***'],
    ['an array (repeated ?before=)', ['a', 'b']],
    ['millisecond precision', Buffer.from('2026-10-03T01:02:03.123Z|1').toString('base64url')],
    ['an impossible date', Buffer.from('2026-13-45T01:02:03.123456Z|1').toString('base64url')],
    ['a non-numeric id', Buffer.from('2026-10-03T01:02:03.123456Z|x').toString('base64url')],
    ['an id past bigint', Buffer.from('2026-10-03T01:02:03.123456Z|9223372036854775808').toString('base64url')],
    ['SQL in the payload', Buffer.from("2026-10-03T01:02:03.123456Z|1'; --").toString('base64url')],
  ])('refuses %s with INVALID_AUDIT_CURSOR', (_label, raw) => {
    expect(codeOf(() => decodeAuditCursor(raw))).toBe('INVALID_AUDIT_CURSOR');
  });
});

describe('toAuditEntry — actor resolution, no before/after', () => {
  const base: AuditRow = {
    id: '7',
    action: 'x',
    entity: null,
    entity_id: null,
    platform_admin_id: null,
    admin_username: null,
    user_id: null,
    user_username: null,
    device_id: null,
    device_label: null,
    device_no: null,
    ip: null,
    created_at_cursor: '2026-10-03T01:02:03.123456Z',
  };

  it('prefers the platform admin', () => {
    const e = toAuditEntry({ ...base, platform_admin_id: 'pa', admin_username: 'ops', user_id: 'u' });
    expect(e.actor).toEqual({ type: 'platform_admin', id: 'pa', username: 'ops' });
  });

  it('a user acting on a device names both', () => {
    const e = toAuditEntry({
      ...base,
      user_id: 'u',
      user_username: 'owner',
      device_id: 'pos1',
      device_label: 'POS #1',
      device_no: 1,
    });
    expect(e.actor).toEqual({ type: 'user', id: 'u', username: 'owner' });
    expect(e.device).toEqual({ id: 'pos1', label: 'POS #1', deviceNo: 1 });
  });

  it('a device alone is the actor, and is not repeated in `device`', () => {
    const e = toAuditEntry({ ...base, device_id: 'pos1', device_label: 'POS #1', device_no: 1 });
    expect(e.actor).toEqual({ type: 'device', id: 'pos1', label: 'POS #1', deviceNo: 1 });
    expect(e.device).toBeNull();
  });

  it('nothing → system; the entry never carries before/after', () => {
    const e = toAuditEntry({ ...base, before: { secret: 1 }, after: { secret: 2 } } as AuditRow);
    expect(e.actor).toEqual({ type: 'system' });
    expect(Object.keys(e).sort()).toEqual(
      ['action', 'actor', 'createdAt', 'device', 'entity', 'entityId', 'id', 'ip'].sort(),
    );
  });
});

describe('parseGitSha', () => {
  it('keeps a hex SHA, lower-cased', () => {
    expect(parseGitSha('E191755')).toBe('e191755');
    expect(parseGitSha('e1917553c90f4d1c2c8a6b0e7a3d1f2e4b5c6d7e')).toBe(
      'e1917553c90f4d1c2c8a6b0e7a3d1f2e4b5c6d7e',
    );
  });

  it.each([undefined, '', 'abc', 'not-a-sha', 'e191755; rm -rf /', 'g'.repeat(40)])(
    'returns null for %j',
    (raw) => {
      expect(parseGitSha(raw)).toBeNull();
    },
  );
});
