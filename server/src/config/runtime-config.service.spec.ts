import { getEventListeners } from 'node:events';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { Logger } from 'pino';
import { RuntimeConfigService, LOG_LEVEL_KEY } from './runtime-config.service.js';
import type { AppConfig } from './config.js';

describe('RuntimeConfigService', () => {
  let mockLogger: Partial<Logger> & { level: string };
  let mockConfig: AppConfig;
  let service: RuntimeConfigService;

  beforeEach(() => {
    mockLogger = {
      level: 'info',
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
      debug: vi.fn(),
    };

    mockConfig = {
      port: 3000,
      instanceId: 'api-1',
      logLevel: 'info',
      databaseUrl: 'postgres://localhost/pos',
      adminDatabaseUrl: 'postgres://localhost/pos',
      dbPoolSize: 5,
      redisCacheUrl: 'redis://localhost:6379',
      redisQueueUrl: 'redis://localhost:6380',
      redisCommandTimeoutMs: 200,
      jwtPlatformSecret: 'secret',
      etcdUrl: 'http://127.0.0.1:2379',
    };

    service = new RuntimeConfigService(mockConfig, mockLogger as Logger);
  });

  afterEach(() => {
    service.onModuleDestroy();
    vi.restoreAllMocks();
  });

  it('does nothing when etcdUrl is not defined', async () => {
    mockConfig.etcdUrl = undefined;
    const fetchSpy = vi.spyOn(globalThis, 'fetch');

    await service.start();

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(mockLogger.level).toBe('info');
  });

  it('fails open and logs warning once when etcd is unreachable', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('ECONNREFUSED'));

    await service.start();

    expect(mockLogger.warn).toHaveBeenCalledWith(
      expect.objectContaining({ err: 'ECONNREFUSED' }),
      'etcd unavailable, using environment configuration',
    );
    expect(mockLogger.level).toBe('info');
  });

  it('fetches initial log_level from etcd and updates logger.level', async () => {
    const keyBase64 = Buffer.from(LOG_LEVEL_KEY).toString('base64');
    const valBase64 = Buffer.from('debug').toString('base64');

    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({
        kvs: [{ key: keyBase64, value: valBase64 }],
      }),
    } as Response);

    // Mock watchLoop so it does not block
    vi.spyOn<any, any>(service, 'runWatchLoop').mockImplementation(async () => {});

    await service.start();

    expect(mockLogger.level).toBe('debug');
    expect(mockLogger.info).toHaveBeenCalledWith(
      expect.objectContaining({ oldLevel: 'info', newLevel: 'debug' }),
      expect.stringContaining("Runtime config updated log level to 'debug'"),
    );
  });

  it('authenticates with etcd when etcdPassword is configured', async () => {
    mockConfig.etcdPassword = 'secret-root-password';

    const fetchSpy = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({ token: 'mock-jwt-token' }),
      } as Response)
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({ kvs: [] }),
      } as Response);

    vi.spyOn<any, any>(service, 'runWatchLoop').mockImplementation(async () => {});

    await service.start();

    expect(fetchSpy).toHaveBeenCalledWith(
      'http://127.0.0.1:2379/v3/auth/authenticate',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ name: 'root', password: 'secret-root-password' }),
      }),
    );

    // Check subsequent call contains token header
    expect(fetchSpy).toHaveBeenCalledWith(
      'http://127.0.0.1:2379/v3/kv/range',
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: 'mock-jwt-token',
        }),
      }),
    );
  });

  it('updates logger.level dynamically on watch event', () => {
    const valBase64 = Buffer.from('warn').toString('base64');
    const payload = {
      result: {
        events: [
          {
            type: 'PUT',
            kv: {
              key: Buffer.from(LOG_LEVEL_KEY).toString('base64'),
              value: valBase64,
            },
          },
        ],
      },
    };

    service.handleWatchPayload(payload);

    expect(mockLogger.level).toBe('warn');
    expect(mockLogger.info).toHaveBeenCalledWith(
      expect.objectContaining({ oldLevel: 'info', newLevel: 'warn' }),
      expect.stringContaining("Runtime config updated log level to 'warn'"),
    );
  });

  it('ignores invalid log levels and logs a warning', () => {
    const valBase64 = Buffer.from('not-a-valid-level').toString('base64');
    const payload = {
      result: {
        events: [
          {
            type: 'PUT',
            kv: {
              key: Buffer.from(LOG_LEVEL_KEY).toString('base64'),
              value: valBase64,
            },
          },
        ],
      },
    };

    service.handleWatchPayload(payload);

    expect(mockLogger.level).toBe('info');
    expect(mockLogger.warn).toHaveBeenCalledWith(
      expect.objectContaining({ invalidLevel: 'not-a-valid-level' }),
      'Ignoring invalid log level received from etcd',
    );
  });

  it('strips trailing slashes from etcdUrl', async () => {
    mockConfig.etcdUrl = 'http://127.0.0.1:2379///';
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({ kvs: [] }),
    } as Response);

    vi.spyOn<any, any>(service, 'runWatchLoop').mockImplementation(async () => {});

    await service.start();

    expect(fetchSpy).toHaveBeenCalledWith(
      'http://127.0.0.1:2379/v3/kv/range',
      expect.anything(),
    );
  });

  it('aborts watch controller onModuleDestroy', async () => {
    mockConfig.etcdUrl = 'http://127.0.0.1:2379';
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({ kvs: [] }),
    } as Response);

    vi.spyOn<any, any>(service, 'runWatchLoop').mockImplementation(async () => {});

    await service.start();
    expect((service as any).abortController.signal.aborted).toBe(false);

    service.onModuleDestroy();
    expect((service as any).abortController.signal.aborted).toBe(true);
    expect((service as any).isStopped).toBe(true);
  });
});

describe('RuntimeConfigService watch resume (#120)', () => {
  const keyBase64 = Buffer.from(LOG_LEVEL_KEY).toString('base64');
  const b64 = (v: string) => Buffer.from(v).toString('base64');
  /** A fetch that never answers, but rejects when its signal aborts (as real fetch does). */
  const hang = (_url?: unknown, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new Error('aborted')), {
        once: true,
      });
    });
  let logger: Partial<Logger> & { level: string };
  let service: RuntimeConfigService;

  const json = (body: unknown) =>
    ({ ok: true, status: 200, json: async () => body }) as Response;

  /** A watch response whose body emits the given NDJSON lines, then ends. */
  const stream = (...payloads: unknown[]) => {
    const enc = new TextEncoder();
    return {
      ok: true,
      status: 200,
      body: new ReadableStream({
        start(c) {
          for (const p of payloads) {
            c.enqueue(enc.encode(JSON.stringify(p) + '\n'));
          }
          c.close();
        },
      }),
    } as unknown as Response;
  };

  const watchBodies = (spy: { mock: { calls: unknown[][] } }) =>
    spy.mock.calls
      .filter(([url]) => String(url).endsWith('/v3/watch'))
      .map(([, init]) => JSON.parse((init as RequestInit).body as string));

  const until = async (cond: () => boolean) => {
    for (let i = 0; i < 200 && !cond(); i++) {
      await new Promise((r) => setTimeout(r, 1));
    }
    expect(cond()).toBe(true);
  };

  beforeEach(() => {
    logger = {
      level: 'info',
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
      debug: vi.fn(),
    };
    service = new RuntimeConfigService(
      { etcdUrl: 'http://127.0.0.1:2379' } as AppConfig,
      logger as Logger,
    );
    vi.spyOn(service, 'backoffDelay').mockReturnValue(0);
  });

  afterEach(() => {
    service.onModuleDestroy();
    vi.restoreAllMocks();
  });

  it('starts the watch at range header.revision + 1 so no event between get and watch is lost', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(json({ header: { revision: '41' }, kvs: [] }))
      .mockImplementation(hang);

    await service.start();
    await until(() => watchBodies(fetchSpy).length === 1);

    expect(service.latestRevision).toBe(41);
    expect(watchBodies(fetchSpy)[0].create_request).toEqual({
      key: keyBase64,
      start_revision: '42',
    });
  });

  it('resumes a reconnect after the last event revision it applied', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(json({ header: { revision: '10' }, kvs: [] }))
      .mockResolvedValueOnce(
        stream({
          result: {
            events: [
              {
                type: 'PUT',
                kv: { key: keyBase64, value: b64('debug'), mod_revision: '15' },
              },
            ],
          },
        }),
      )
      .mockImplementation(hang);

    await service.start();
    await until(() => watchBodies(fetchSpy).length === 2);

    expect(logger.level).toBe('debug');
    expect(watchBodies(fetchSpy)[1].create_request.start_revision).toBe('16');
  });

  it('keeps retrying after an initial connect failure and applies the level once etcd is up', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockRejectedValueOnce(new Error('ECONNREFUSED'))
      .mockRejectedValueOnce(new Error('ECONNREFUSED'))
      .mockResolvedValueOnce(
        json({
          header: { revision: '7' },
          kvs: [{ key: keyBase64, value: b64('warn') }],
        }),
      )
      .mockImplementation(hang);

    await service.start();
    await until(() => watchBodies(fetchSpy).length === 1);

    expect(logger.level).toBe('warn');
    expect(watchBodies(fetchSpy)[0].create_request.start_revision).toBe('8');
  });

  it('re-reads the key when the watch start revision was compacted', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(json({ header: { revision: '5' }, kvs: [] }))
      .mockResolvedValueOnce(
        stream({ result: { canceled: true, compact_revision: '90' } }),
      )
      .mockResolvedValueOnce(
        json({
          header: { revision: '100' },
          kvs: [{ key: keyBase64, value: b64('error') }],
        }),
      )
      .mockImplementation(hang);

    await service.start();
    await until(() => watchBodies(fetchSpy).length === 2);

    expect(logger.level).toBe('error');
    expect(watchBodies(fetchSpy)[1].create_request.start_revision).toBe('101');
  });

  describe('reconnect backoff (PR #129 review)', () => {
    const tick = (ms = 0) => vi.advanceTimersByTimeAsync(ms);
    /** fetch that answers range with `rangeBody` and every watch with `watch()`. */
    const etcd = (watch: () => Response | Promise<Response>) =>
      vi
        .spyOn(globalThis, 'fetch')
        .mockImplementation(async (url) =>
          String(url).endsWith('/v3/watch')
            ? watch()
            : json({ header: { revision: '1' }, kvs: [] }),
        );

    beforeEach(() => {
      vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
      vi.mocked(service.backoffDelay).mockReturnValue(1_000);
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it('grows the attempt when etcd accepts the watch and then cancels it', async () => {
      etcd(() =>
        stream({ result: { canceled: true, cancel_reason: 'permission denied' } }),
      );

      await service.start();
      for (let i = 0; i < 4; i++) await tick(1_000);

      const attempts = vi.mocked(service.backoffDelay).mock.calls.map(([a]) => a);
      expect(attempts.length).toBeGreaterThanOrEqual(3);
      expect(attempts.slice(0, 3)).toEqual([0, 1, 2]);
    });

    it('backs off after a stream that ends cleanly instead of reconnecting instantly', async () => {
      const fetchSpy = etcd(() => stream());

      await service.start();
      await tick(0);
      await tick(0);

      expect(watchBodies(fetchSpy)).toHaveLength(1);
      expect(service.backoffDelay).toHaveBeenCalledTimes(1);

      await tick(1_000);
      expect(watchBodies(fetchSpy)).toHaveLength(2);
    });

    it('resets the attempt once a real event arrives', async () => {
      let n = 0;
      etcd(() =>
        n++ < 2
          ? stream({ result: { canceled: true } })
          : stream({
              result: {
                events: [
                  { type: 'PUT', kv: { key: keyBase64, value: b64('debug'), mod_revision: '5' } },
                ],
              },
            }),
      );

      await service.start();
      for (let i = 0; i < 3; i++) await tick(1_000);

      const attempts = vi.mocked(service.backoffDelay).mock.calls.map(([a]) => a);
      expect(logger.level).toBe('debug');
      expect(attempts.slice(0, 3)).toEqual([0, 1, 0]);
    });

    it('onModuleDestroy cancels a pending retry timer and leaves no abort listener behind', async () => {
      const fetchSpy = vi
        .spyOn(globalThis, 'fetch')
        .mockRejectedValue(new Error('ECONNREFUSED'));

      await service.start();
      for (let i = 0; i < 5; i++) await tick(1_000);
      const signal = (service as any).abortController.signal as AbortSignal;

      expect(getEventListeners(signal, 'abort').length).toBeLessThanOrEqual(1);
      expect(vi.getTimerCount()).toBe(1);

      service.onModuleDestroy();
      await tick(0);
      expect(vi.getTimerCount()).toBe(0);
      expect(getEventListeners(signal, 'abort')).toHaveLength(0);

      const calls = fetchSpy.mock.calls.length;
      await tick(60_000);
      expect(fetchSpy.mock.calls.length).toBe(calls);
    });

    it('warns once while etcd stays down, then logs retries at debug', async () => {
      vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('ECONNREFUSED'));

      await service.start();
      for (let i = 0; i < 5; i++) await tick(1_000);

      expect(logger.warn).toHaveBeenCalledTimes(1);
      expect(vi.mocked(logger.debug!).mock.calls.length).toBeGreaterThanOrEqual(4);
    });

    it('reconnects through backoff when the watch body errors after headers (undici bodyTimeout shape)', async () => {
      const bodyErr = new Error('Body Timeout Error');
      const erroringStream = () =>
        ({
          ok: true,
          status: 200,
          body: new ReadableStream({
            start(c) {
              // Headers/connection already succeeded; the body errors with no data,
              // matching undici's UND_ERR_BODY_TIMEOUT on an idle watch stream.
              queueMicrotask(() => c.error(bodyErr));
            },
          }),
        }) as unknown as Response;

      const fetchSpy = etcd(erroringStream);

      await service.start();
      for (let i = 0; i < 2; i++) await tick(1_000);

      // No special-casing needed: a mid-stream body error is just another
      // thrown error, so it goes through the same backoff-and-reconnect path.
      expect(watchBodies(fetchSpy).length).toBeGreaterThanOrEqual(2);
      expect(service.backoffDelay).toHaveBeenCalled();
    });
  });

  describe('etcd watch reauthentication (invalid auth token on a 200 watch cancel)', () => {
    let authLogger: Partial<Logger> & { level: string };
    let authService: RuntimeConfigService;

    beforeEach(() => {
      authLogger = {
        level: 'info',
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn(),
        debug: vi.fn(),
      };
      authService = new RuntimeConfigService(
        { etcdUrl: 'http://127.0.0.1:2379', etcdPassword: 'root-pw' } as AppConfig,
        authLogger as Logger,
      );
      vi.spyOn(authService, 'backoffDelay').mockReturnValue(0);
    });

    afterEach(() => {
      authService.onModuleDestroy();
    });

    it('drops a stale token and re-authenticates when /v3/watch answers 200 with a canceled+Unauthenticated body', async () => {
      let authCalls = 0;
      const fetchSpy = vi
        .spyOn(globalThis, 'fetch')
        .mockImplementation(async (url) => {
          const u = String(url);
          if (u.endsWith('/v3/auth/authenticate')) {
            authCalls += 1;
            return json({ token: `token-${authCalls}` });
          }
          if (u.endsWith('/v3/kv/range')) {
            return json({ header: { revision: '1' }, kvs: [] });
          }
          // etcd v3.6.12 shape (measured): HTTP 200 whose body says the token expired.
          return stream({
            result: {
              canceled: true,
              cancel_reason:
                'rpc error: code = Unauthenticated desc = etcdserver: invalid auth token',
            },
          });
        });

      await authService.start();
      await until(() => authCalls >= 2);

      expect(authCalls).toBeGreaterThanOrEqual(2);
      const watchCalls = fetchSpy.mock.calls.filter(([u]) =>
        String(u).endsWith('/v3/watch'),
      );
      expect(watchCalls.length).toBeGreaterThanOrEqual(2);
      const secondWatchInit = watchCalls[1]?.[1] as RequestInit;
      const secondWatchHeaders = secondWatchInit.headers as Record<string, string>;
      expect(secondWatchHeaders.Authorization).toBe('token-2');
    });

    it('does not re-authenticate for a compaction whose revision text contains "401" (e.g. 14017)', async () => {
      let authCalls = 0;
      let rangeCalls = 0;
      let watchCalls = 0;
      const fetchSpy = vi
        .spyOn(globalThis, 'fetch')
        .mockImplementation(async (url, init) => {
          const u = String(url);
          if (u.endsWith('/v3/auth/authenticate')) {
            authCalls += 1;
            return json({ token: `token-${authCalls}` });
          }
          if (u.endsWith('/v3/kv/range')) {
            rangeCalls += 1;
            return json({ header: { revision: '5' }, kvs: [] });
          }
          watchCalls += 1;
          if (watchCalls === 1) {
            // compact_revision '14017' contains the substring '401' — must not be read as HTTP 401.
            return stream({
              result: { canceled: true, compact_revision: '14017' },
            });
          }
          return hang(url, init);
        });

      await authService.start();
      await until(() => watchCalls >= 2);

      // Only the initial authenticate() from start() — a compaction is not an auth failure.
      expect(authCalls).toBe(1);
      // The resync fetchInitialLogLevel() call the compaction forces, plus the initial one.
      expect(rangeCalls).toBe(2);
      expect(fetchSpy).toHaveBeenCalled();
    });
  });

  it('backs off exponentially between 1s and 30s with jitter', () => {
    vi.mocked(service.backoffDelay).mockRestore();
    const random = vi.spyOn(Math, 'random').mockReturnValue(1);
    expect(service.backoffDelay(0)).toBe(1_000);
    expect(service.backoffDelay(3)).toBe(8_000);
    expect(service.backoffDelay(20)).toBe(30_000);
    random.mockReturnValue(0);
    expect(service.backoffDelay(0)).toBe(1_000);
    expect(service.backoffDelay(3)).toBe(4_000);
  });
});
