import { describe, expect, it, vi } from 'vitest';
import { warnIfRoleTimeoutsDiffer } from './db.module.js';

/** A pool whose `SHOW <name>` answers from `values`. */
function fakeDs(values: Record<string, string>) {
  return {
    query: vi.fn(async (sql: string) => {
      const name = sql.replace(/^SHOW\s+/, '');
      return [{ [name]: values[name] }];
    }),
  };
}

describe('warnIfRoleTimeoutsDiffer (#213)', () => {
  it('is silent when the pool shows 25s / 5s', async () => {
    const logger = { warn: vi.fn() };
    await warnIfRoleTimeoutsDiffer(
      fakeDs({ statement_timeout: '25s', idle_in_transaction_session_timeout: '5s' }) as any,
      logger as any,
    );
    expect(logger.warn).not.toHaveBeenCalled();
  });

  it('warns, naming the setting, when a DB still has the old 5s statement_timeout', async () => {
    const logger = { warn: vi.fn() };
    await warnIfRoleTimeoutsDiffer(
      fakeDs({ statement_timeout: '5s', idle_in_transaction_session_timeout: '5s' }) as any,
      logger as any,
    );
    expect(logger.warn).toHaveBeenCalledTimes(1);
    expect(logger.warn.mock.calls[0][0]).toEqual({
      setting: 'statement_timeout',
      actual: '5s',
      expected: '25s',
    });
  });

  it('warns and does not throw when SHOW fails', async () => {
    const logger = { warn: vi.fn() };
    const ds = { query: vi.fn(async () => Promise.reject(new Error('down'))) };
    await expect(warnIfRoleTimeoutsDiffer(ds as any, logger as any)).resolves.toBeUndefined();
    expect(logger.warn).toHaveBeenCalledTimes(1);
  });
});
