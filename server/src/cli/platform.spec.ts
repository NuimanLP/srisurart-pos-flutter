import { describe, it, expect, vi } from 'vitest';
import { PassThrough } from 'node:stream';
import {
  assertNoPasswordFlags,
  createPrompter,
  parseArgv,
  readSecret,
  runPlatformCli,
  type FetchLike,
} from './platform.js';

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * A typed `fetch` mock: `FetchLike` (== `typeof fetch`) is overloaded, so a bare
 * `vi.fn(async (url: string, init: RequestInit) => …)` is not assignable to it — the
 * `...args: Parameters<FetchLike>` spread keeps the mock's signature exactly as wide as
 * every overload requires. `calls` captures each `[url, init]` pair as a plain string +
 * `RequestInit`, which is all these tests need to assert on.
 */
function mockFetch(handler: (url: string, init: RequestInit) => Response | Promise<Response>) {
  const calls: Array<[string, RequestInit]> = [];
  const fetchImpl = vi.fn(async (...args: Parameters<FetchLike>) => {
    const [input, init] = args;
    const url = String(input);
    calls.push([url, init ?? {}]);
    return handler(url, init ?? {});
  }) as unknown as FetchLike;
  return { fetchImpl, calls };
}

/** A `fake stdin` that behaves like a real pipe: writable any time, `isTTY` settable. */
function fakeStream(isTTY = false): PassThrough & { isTTY: boolean } {
  const s = new PassThrough() as PassThrough & { isTTY: boolean };
  s.isTTY = isTTY;
  return s;
}

describe('parseArgv', () => {
  it('splits the command from positionals and flags', () => {
    expect(parseArgv(['tenants:status', 't1', 'suspended', '--user', 'admin'])).toEqual({
      command: 'tenants:status',
      positionals: ['t1', 'suspended'],
      flags: { user: 'admin' },
    });
  });

  it('accepts --key=value alongside --key value', () => {
    expect(parseArgv(['tenants:create', '--code=shop1', '--shop-name', 'ร้าน'])).toEqual({
      command: 'tenants:create',
      positionals: [],
      flags: { code: 'shop1', 'shop-name': 'ร้าน' },
    });
  });

  it('leaves a trailing flag with no value as empty, not swallowing the next command', () => {
    expect(parseArgv(['login', '--user'])).toEqual({
      command: 'login',
      positionals: [],
      flags: { user: '' },
    });
  });

  it('returns an empty command for an empty argv', () => {
    expect(parseArgv([])).toEqual({ command: '', positionals: [], flags: {} });
  });
});

describe('assertNoPasswordFlags', () => {
  it.each(['password', 'ownerPassword', 'owner-password', 'PASSWORD', 'admin-pass'])(
    'refuses a flag named %s',
    (key) => {
      expect(() => assertNoPasswordFlags({ [key]: 'x' })).toThrow(/not accepted/);
    },
  );

  it('does not throw when no flag looks like a secret', () => {
    expect(() => assertNoPasswordFlags({ user: 'admin', code: 'shop1' })).not.toThrow();
  });
});

describe('createPrompter / readSecret', () => {
  it('reads a piped (non-TTY) line without needing terminal echo', async () => {
    const input = fakeStream(false);
    const output = fakeStream(false);
    const prompter = createPrompter(input, output);

    const promise = readSecret(prompter, 'Platform admin password: ');
    input.write('hunter2\n');
    expect(await promise).toBe('hunter2');
    prompter.close();
  });

  it('resolves two secrets piped in a single chunk, in order, even across an intervening await', async () => {
    // Regression guard: an earlier draft asked for the second secret via a fresh
    // `readline.question()` call issued only after the first one's promise settled,
    // which loses whatever else was already sitting in the same `data` chunk — a real
    // failure mode for `printf 'adminpw\nownerpw\n' | docker compose exec -T …`, which
    // typically arrives as one chunk. `createPrompter` queues lines from a listener
    // attached up front specifically so this ordering can never drop the second line.
    const input = fakeStream(false);
    const output = fakeStream(false);
    const prompter = createPrompter(input, output);

    const first = readSecret(prompter, 'Platform admin password: ');
    input.write('adminpw\nownerpw\n');
    expect(await first).toBe('adminpw');

    const second = readSecret(prompter, 'New owner password: ');
    expect(await second).toBe('ownerpw');
    prompter.close();
  });

  it('never writes the secret to the output stream on a real TTY', async () => {
    const input = fakeStream(true);
    const output = fakeStream(true);
    let written = '';
    output.on('data', (chunk: Buffer) => {
      written += chunk.toString('utf8');
    });
    const prompter = createPrompter(input, output);

    // Worst case for a naive implementation: the whole line is already sitting in the
    // stream before the prompt is even shown, exercising the always-on TTY mute rather
    // than one that only engages after the first prompt.
    input.write('super-secret-pw\n');
    const value = await readSecret(prompter, 'Platform admin password: ');
    prompter.close();

    expect(value).toBe('super-secret-pw');
    expect(written).not.toContain('super-secret-pw');
    expect(written).toContain('Platform admin password: ');
  });

  it('rejects a pending read when the input stream ends first', async () => {
    const input = fakeStream(false);
    const output = fakeStream(false);
    const prompter = createPrompter(input, output);

    const pending = readSecret(prompter, 'Platform admin password: ');
    input.end();
    await expect(pending).rejects.toThrow('input ended before a value was entered');
  });
});

describe('runPlatformCli', () => {
  function io(overrides: { input?: string; fetchImpl: FetchLike }) {
    const input = fakeStream(false);
    const output = fakeStream(false);
    const log = vi.fn();
    if (overrides.input !== undefined) {
      // Written before the CLI ever calls createPrompter — proves the queued-line
      // design (see above) rather than relying on write-after-question timing.
      queueMicrotask(() => input.write(overrides.input as string));
    }
    return { input, output, log, fetchImpl: overrides.fetchImpl };
  }

  it('login: rejects a password given on argv before ever touching the network', async () => {
    const fetchImpl = vi.fn();
    await expect(
      runPlatformCli(['login', '--user', 'admin', '--password', 'x'], { fetchImpl }),
    ).rejects.toThrow(/not accepted/);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('login: requires --user', async () => {
    const fetchImpl = vi.fn();
    await expect(runPlatformCli(['login'], { fetchImpl })).rejects.toThrow('--user is required');
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('login: exits (throws) non-zero-shaped on a wrong password, without leaking it to log', async () => {
    const { fetchImpl, calls } = mockFetch(() =>
      jsonResponse(401, { status: 'error', error: { code: 'UNAUTHORIZED', message: 'Invalid platform admin credentials' } }),
    );
    const { input, output, log } = io({ input: 'wrong-pw\n', fetchImpl });

    await expect(
      runPlatformCli(['login', '--user', 'devadmin'], { input, output, log, fetchImpl }),
    ).rejects.toThrow(/UNAUTHORIZED/);

    expect(log).not.toHaveBeenCalled();
    expect(JSON.parse(calls[0][1].body as string)).toEqual({
      username: 'devadmin',
      password: 'wrong-pw',
    });
  });

  it('login: prints only the username/id, never the token or password', async () => {
    const { fetchImpl } = mockFetch(() =>
      jsonResponse(200, {
        status: 'success',
        data: { token: 'super-secret-token', admin: { id: 'a1', username: 'devadmin', displayName: 'Dev' } },
      }),
    );
    const { input, output, log } = io({ input: 'right-pw\n', fetchImpl });

    await runPlatformCli(['login', '--user', 'devadmin'], { input, output, log, fetchImpl });

    expect(log).toHaveBeenCalledWith('logged in as devadmin (id a1)');
    expect(log.mock.calls.flat().join('\n')).not.toContain('super-secret-token');
    expect(log.mock.calls.flat().join('\n')).not.toContain('right-pw');
  });

  it('tenants:list: logs in once, then calls GET with the bearer token', async () => {
    const { fetchImpl, calls } = mockFetch((url) => {
      if (url.endsWith('/platform/auth/token')) {
        return jsonResponse(200, {
          status: 'success',
          data: { token: 'tok-abc', admin: { id: 'a1', username: 'devadmin', displayName: 'Dev' } },
        });
      }
      return jsonResponse(200, { status: 'success', data: [{ id: 't1', code: 'shop1' }] });
    });
    const { input, output, log } = io({ input: 'right-pw\n', fetchImpl });

    await runPlatformCli(['tenants:list', '--user', 'devadmin'], { input, output, log, fetchImpl });

    expect(calls).toHaveLength(2);
    expect(calls[1][0]).toContain('/api/v1/platform/tenants');
    expect((calls[1][1].headers as Record<string, string>).Authorization).toBe('Bearer tok-abc');
    expect(log).toHaveBeenCalledWith(JSON.stringify([{ id: 't1', code: 'shop1' }], null, 2));
  });

  it('tenants:create: validates required flags before ever prompting for a password', async () => {
    const fetchImpl = vi.fn();
    await expect(
      runPlatformCli(['tenants:create', '--user', 'devadmin'], { fetchImpl }),
    ).rejects.toThrow('--code is required');
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('tenants:create: sends the admin login then the create body built from flags only (#443 PR3: no ownerPassword)', async () => {
    const { fetchImpl, calls } = mockFetch((url) => {
      if (url.endsWith('/platform/auth/token')) {
        return jsonResponse(200, {
          status: 'success',
          data: { token: 'tok-abc', admin: { id: 'a1', username: 'devadmin', displayName: 'Dev' } },
        });
      }
      return jsonResponse(200, {
        status: 'success',
        data: { tenantId: 't1', code: 'demo', tempPassword: 'servergenerated1', enrolCode: 'ABCD1234' },
      });
    });
    // Only one secret is ever prompted for now — the admin's own password.
    const { input, output, log } = io({ input: 'adminpw\n', fetchImpl });

    await runPlatformCli(
      [
        'tenants:create',
        '--user', 'devadmin',
        '--code', 'demo',
        '--shop-name', 'ร้านทดสอบ',
        '--owner-username', 'owner1',
      ],
      { input, output, log, fetchImpl },
    );

    expect(calls).toHaveLength(2);
    const loginBody = JSON.parse(calls[0][1].body as string);
    expect(loginBody).toEqual({ username: 'devadmin', password: 'adminpw' });
    const createBody = JSON.parse(calls[1][1].body as string);
    expect(createBody).toEqual({
      code: 'demo',
      shopName: 'ร้านทดสอบ',
      shopNameEn: undefined,
      plan: undefined,
      timezone: undefined,
      ownerUsername: 'owner1',
      ownerDisplayName: undefined,
    });
    expect(createBody).not.toHaveProperty('ownerPassword');
    expect(log).toHaveBeenCalledWith(
      JSON.stringify(
        { tenantId: 't1', code: 'demo', tempPassword: 'servergenerated1', enrolCode: 'ABCD1234' },
        null,
        2,
      ),
    );
  });

  it('tenants:create: writes a one-time-secret note to stderr, not stdout', async () => {
    const { fetchImpl } = mockFetch((url) => {
      if (url.endsWith('/platform/auth/token')) {
        return jsonResponse(200, {
          status: 'success',
          data: { token: 'tok-abc', admin: { id: 'a1', username: 'devadmin', displayName: 'Dev' } },
        });
      }
      return jsonResponse(200, {
        status: 'success',
        data: { tenantId: 't1', code: 'demo', tempPassword: 'x', enrolCode: 'ABCD1234' },
      });
    });
    const input = fakeStream(false);
    const output = fakeStream(false);
    let written = '';
    output.on('data', (chunk: Buffer) => (written += chunk.toString('utf8')));
    const log = vi.fn();
    queueMicrotask(() => input.write('adminpw\n'));

    await runPlatformCli(
      ['tenants:create', '--user', 'devadmin', '--code', 'demo', '--shop-name', 'ร้านทดสอบ', '--owner-username', 'owner1'],
      { input, output, log, fetchImpl },
    );

    expect(written).toContain('shown once');
    expect(log.mock.calls.flat().join('\n')).not.toContain('shown once');
  });

  it('tenants:show: logs in then GETs the tenant detail', async () => {
    const { fetchImpl, calls } = mockFetch((url) => {
      if (url.endsWith('/platform/auth/token')) {
        return jsonResponse(200, {
          status: 'success',
          data: { token: 'tok-abc', admin: { id: 'a1', username: 'devadmin', displayName: 'Dev' } },
        });
      }
      return jsonResponse(200, { status: 'success', data: { tenant: { id: 't1' }, devices: [], importJobs: [] } });
    });
    const { input, output, log } = io({ input: 'right-pw\n', fetchImpl });

    await runPlatformCli(['tenants:show', 't1', '--user', 'devadmin'], { input, output, log, fetchImpl });

    expect(calls[1][0]).toContain('/api/v1/platform/tenants/t1');
    expect(calls[1][1].method).toBe('GET');
    expect(log).toHaveBeenCalledWith(
      JSON.stringify({ tenant: { id: 't1' }, devices: [], importJobs: [] }, null, 2),
    );
  });

  it('tenants:show: requires the tenantId positional', async () => {
    const fetchImpl = vi.fn();
    await expect(
      runPlatformCli(['tenants:show', '--user', 'devadmin'], { fetchImpl }),
    ).rejects.toThrow(/usage: tenants:show/);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('devices:reissue-code: logs in then POSTs to the enrol-code route', async () => {
    const { fetchImpl, calls } = mockFetch((url) => {
      if (url.endsWith('/platform/auth/token')) {
        return jsonResponse(200, {
          status: 'success',
          data: { token: 'tok-abc', admin: { id: 'a1', username: 'devadmin', displayName: 'Dev' } },
        });
      }
      return jsonResponse(200, {
        status: 'success',
        data: { deviceId: 'pos1', enrolCode: 'NEWCODE1', enrolExpiresAt: '2026-10-04T00:00:00.000Z' },
      });
    });
    const { input, output, log } = io({ input: 'right-pw\n', fetchImpl });

    await runPlatformCli(['devices:reissue-code', 't1', 'pos1', '--user', 'devadmin'], {
      input,
      output,
      log,
      fetchImpl,
    });

    expect(calls[1][0]).toContain('/api/v1/platform/tenants/t1/devices/pos1/enrol-code');
    expect(calls[1][1].method).toBe('POST');
    expect(log).toHaveBeenCalledWith(
      JSON.stringify(
        { deviceId: 'pos1', enrolCode: 'NEWCODE1', enrolExpiresAt: '2026-10-04T00:00:00.000Z' },
        null,
        2,
      ),
    );
  });

  it('devices:reissue-code: requires both positionals', async () => {
    const fetchImpl = vi.fn();
    await expect(
      runPlatformCli(['devices:reissue-code', 't1', '--user', 'devadmin'], { fetchImpl }),
    ).rejects.toThrow(/usage: devices:reissue-code/);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('owner:temp-password: logs in then POSTs to the reset route', async () => {
    const { fetchImpl, calls } = mockFetch((url) => {
      if (url.endsWith('/platform/auth/token')) {
        return jsonResponse(200, {
          status: 'success',
          data: { token: 'tok-abc', admin: { id: 'a1', username: 'devadmin', displayName: 'Dev' } },
        });
      }
      return jsonResponse(200, {
        status: 'success',
        data: { tenantId: 't1', ownerUsername: 'owner1', tempPassword: 'freshtemp1', tempPasswordExpiresAt: '2026-09-28T00:00:00.000Z' },
      });
    });
    const { input, output, log } = io({ input: 'right-pw\n', fetchImpl });

    await runPlatformCli(['owner:temp-password', 't1', '--user', 'devadmin'], { input, output, log, fetchImpl });

    expect(calls[1][0]).toContain('/api/v1/platform/tenants/t1/owner/temp-password');
    expect(calls[1][1].method).toBe('POST');
    expect(log.mock.calls.flat().join('\n')).toContain('freshtemp1');
  });

  it('owner:temp-password: requires the tenantId positional', async () => {
    const fetchImpl = vi.fn();
    await expect(
      runPlatformCli(['owner:temp-password', '--user', 'devadmin'], { fetchImpl }),
    ).rejects.toThrow(/usage: owner:temp-password/);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('owner:set-password: logs in as the owner with the temp password, then changes it — no platform admin, no tokens printed', async () => {
    const { fetchImpl, calls } = mockFetch((url) => {
      if (url.endsWith('/auth/token')) {
        return jsonResponse(200, {
          status: 'success',
          data: {
            passwordChangeRequired: true,
            passwordChangeToken: 'pwchange-tok',
            user: { id: 'u1', username: 'owner1', role: 'owner', displayName: 'Owner' },
          },
        });
      }
      return jsonResponse(200, {
        status: 'success',
        data: {
          accessToken: 'access-secret',
          refreshToken: 'refresh-secret',
          user: { id: 'u1', username: 'owner1', role: 'owner', displayName: 'Owner' },
        },
      });
    });
    const { input, output, log } = io({ input: 'temppw\nnewpw12345678\n', fetchImpl });

    await runPlatformCli(['owner:set-password', 'owner1'], { input, output, log, fetchImpl });

    expect(calls).toHaveLength(2);
    expect(calls[0][0]).toContain('/api/v1/auth/token');
    expect(JSON.parse(calls[0][1].body as string)).toEqual({ username: 'owner1', password: 'temppw' });
    expect(calls[1][0]).toContain('/api/v1/auth/change-password');
    expect((calls[1][1].headers as Record<string, string>).Authorization).toBe('Bearer pwchange-tok');
    expect(JSON.parse(calls[1][1].body as string)).toEqual({ newPassword: 'newpw12345678' });
    expect(log).toHaveBeenCalledWith(JSON.stringify({ username: 'owner1', passwordChanged: true }, null, 2));
    expect(log.mock.calls.flat().join('\n')).not.toContain('access-secret');
    expect(log.mock.calls.flat().join('\n')).not.toContain('refresh-secret');
    expect(log.mock.calls.flat().join('\n')).not.toContain('pwchange-tok');
  });

  it('owner:set-password: refuses when login does not ask for a password change', async () => {
    const { fetchImpl } = mockFetch(() =>
      jsonResponse(200, {
        status: 'success',
        data: {
          accessToken: 'a',
          refreshToken: 'r',
          user: { id: 'u1', username: 'owner1', role: 'owner', displayName: 'Owner' },
        },
      }),
    );
    const { input, output, log } = io({ input: 'alreadyrealpw\nnewpw12345678\n', fetchImpl });

    await expect(
      runPlatformCli(['owner:set-password', 'owner1'], { input, output, log, fetchImpl }),
    ).rejects.toThrow(/did not ask for a password change/);
  });

  it('owner:set-password: requires the username positional', async () => {
    const fetchImpl = vi.fn();
    await expect(runPlatformCli(['owner:set-password'], { fetchImpl })).rejects.toThrow(
      /usage: owner:set-password/,
    );
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('tenants:status: validates the status value before logging in', async () => {
    const fetchImpl = vi.fn();
    await expect(
      runPlatformCli(['tenants:status', 't1', 'not-a-status', '--user', 'devadmin'], { fetchImpl }),
    ).rejects.toThrow('status must be one of: active, suspended, closed');
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('tenants:status: requires both positionals', async () => {
    const fetchImpl = vi.fn();
    await expect(
      runPlatformCli(['tenants:status', 't1'], { fetchImpl }),
    ).rejects.toThrow(/usage: tenants:status/);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('tenants:status: PATCHes the status after logging in', async () => {
    const { fetchImpl, calls } = mockFetch((url) => {
      if (url.endsWith('/platform/auth/token')) {
        return jsonResponse(200, {
          status: 'success',
          data: { token: 'tok-abc', admin: { id: 'a1', username: 'devadmin', displayName: 'Dev' } },
        });
      }
      return jsonResponse(200, { status: 'success', data: { tenantId: 't1', status: 'suspended' } });
    });
    const { input, output, log } = io({ input: 'right-pw\n', fetchImpl });

    await runPlatformCli(['tenants:status', 't1', 'suspended', '--user', 'devadmin'], {
      input,
      output,
      log,
      fetchImpl,
    });

    expect(calls[1][0]).toContain('/api/v1/platform/tenants/t1/status');
    expect(calls[1][1].method).toBe('PATCH');
    expect(JSON.parse(calls[1][1].body as string)).toEqual({ status: 'suspended' });
  });

  it('rejects an unknown command', async () => {
    const fetchImpl = vi.fn();
    await expect(runPlatformCli(['bogus'], { fetchImpl })).rejects.toThrow('unknown command "bogus"');
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('uses a custom --base-url instead of the loopback default', async () => {
    const { fetchImpl, calls } = mockFetch(() =>
      jsonResponse(200, {
        status: 'success',
        data: { token: 't', admin: { id: 'a1', username: 'devadmin', displayName: 'Dev' } },
      }),
    );
    const { input, output, log } = io({ input: 'pw\n', fetchImpl });

    await runPlatformCli(['login', '--user', 'devadmin', '--base-url', 'http://api-1:3000'], {
      input,
      output,
      log,
      fetchImpl,
    });

    expect(calls[0][0]).toBe('http://api-1:3000/api/v1/platform/auth/token');
  });
});
