import { execFileSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import type { Logger } from 'pino';
import type { DataSource } from 'typeorm';
import { describe, expect, it, vi } from 'vitest';
import { APP_ROLE_TIMEOUTS } from '../src/common/database/commit-ceiling.js';
import { warnIfRoleTimeoutsDiffer } from '../src/infra/db.module.js';

describe('daily database backup and restore verification (Slice 23 / #288, 08 §17)', () => {
  const repoRoot = path.resolve(__dirname, '../..');
  const backupScript = path.join(repoRoot, 'deploy/scripts/backup-db.sh');
  const restoreScript = path.join(repoRoot, 'deploy/scripts/restore-db.sh');

  it('scripts exist and have executable permissions', () => {
    expect(fs.existsSync(backupScript)).toBe(true);
    expect(fs.existsSync(restoreScript)).toBe(true);

    const backupStat = fs.statSync(backupScript);
    const restoreStat = fs.statSync(restoreScript);

    // Assert executable bit is set (user executable: 0o100)
    expect(backupStat.mode & 0o100).toBeGreaterThan(0);
    expect(restoreStat.mode & 0o100).toBeGreaterThan(0);
  });

  it('scripts pass bash syntax validation (bash -n)', () => {
    expect(() => {
      execFileSync('bash', ['-n', backupScript], { stdio: 'pipe' });
    }).not.toThrow();

    expect(() => {
      execFileSync('bash', ['-n', restoreScript], { stdio: 'pipe' });
    }).not.toThrow();
  });

  describe('role ceiling preservation invariant (#213)', () => {
    it('warnIfRoleTimeoutsDiffer logs zero warnings when pos_app timeouts match APP_ROLE_TIMEOUTS', async () => {
      const mockDs = {
        query: vi.fn().mockImplementation(async (sql: string) => {
          if (sql.includes('statement_timeout')) {
            return [{ statement_timeout: APP_ROLE_TIMEOUTS.statement_timeout }];
          }
          if (sql.includes('idle_in_transaction_session_timeout')) {
            return [{ idle_in_transaction_session_timeout: APP_ROLE_TIMEOUTS.idle_in_transaction_session_timeout }];
          }
          return [{}];
        }),
      } as unknown as DataSource;

      const warnSpy = vi.fn();
      const mockLogger = {
        warn: warnSpy,
      } as unknown as Logger;

      await warnIfRoleTimeoutsDiffer(mockDs, mockLogger);

      expect(warnSpy).not.toHaveBeenCalled();
    });

    it('warnIfRoleTimeoutsDiffer emits loud warning on timeout mismatch', async () => {
      const mockDs = {
        query: vi.fn().mockImplementation(async (sql: string) => {
          if (sql.includes('statement_timeout')) {
            return [{ statement_timeout: '0' }]; // mismatch: expected 25s
          }
          if (sql.includes('idle_in_transaction_session_timeout')) {
            return [{ idle_in_transaction_session_timeout: '5s' }];
          }
          return [{}];
        }),
      } as unknown as DataSource;

      const warnSpy = vi.fn();
      const mockLogger = {
        warn: warnSpy,
      } as unknown as Logger;

      await warnIfRoleTimeoutsDiffer(mockDs, mockLogger);

      expect(warnSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          setting: 'statement_timeout',
          actual: '0',
          expected: '25s',
        }),
        expect.stringContaining('pos_app transaction ceiling is not in force (#213)'),
      );
    });
  });

  describe('backup stream format and role ceiling payload', () => {
    it('backup-db.sh contains the role ceiling SQL payload for pos_app', () => {
      const content = fs.readFileSync(backupScript, 'utf8');

      // Must append role ceiling setting for pos_app in database pos
      expect(content).toContain('ALTER ROLE pos_app IN DATABASE');
      expect(content).toContain('statement_timeout');
      expect(content).toContain("'25s'");
      expect(content).toContain('idle_in_transaction_session_timeout');
      expect(content).toContain("'5s'");
      expect(content).toContain('gzip -9');
      expect(content).toContain('sha256');
    });

    it('restore-db.sh checks checksum and asserts 25s/5s role timeouts', () => {
      const content = fs.readFileSync(restoreScript, 'utf8');

      expect(content).toContain('.sha256');
      expect(content).toContain('SHOW statement_timeout');
      expect(content).toContain('SHOW idle_in_transaction_session_timeout');
      expect(content).toContain('"25s"');
      expect(content).toContain('"5s"');
    });
  });
});
