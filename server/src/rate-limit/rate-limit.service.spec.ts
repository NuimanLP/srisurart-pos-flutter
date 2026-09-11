import { describe, it, expect, vi, beforeEach } from 'vitest';
import { RateLimitService } from './rate-limit.service.js';

describe('RateLimitService (ADR-0006)', () => {
  let service: RateLimitService;
  let redisMock: any;
  let dsMock: any;

  beforeEach(() => {
    redisMock = {
      get: vi.fn(),
      set: vi.fn(),
      eval: vi.fn(),
    };
    dsMock = {
      query: vi.fn(),
    };
    service = new RateLimitService(redisMock, dsMock);
  });

  it('allows request when within quota', async () => {
    // Plan is basic
    redisMock.get.mockResolvedValue('basic');
    // Lua returns [currentCount, ttl]
    redisMock.eval.mockResolvedValue([5, 55]);

    const res = await service.checkRateLimit('tenant-1', 'GET:/products', {
      limit: 10,
      windowSec: 60,
    });

    expect(res.allowed).toBe(true);
    expect(res.retryAfter).toBeUndefined();
    expect(redisMock.eval).toHaveBeenCalledWith(
      expect.any(String),
      1,
      expect.stringContaining('t:tenant-1:rl:GET__products:'),
      60,
    );
  });

  it('rejects request with retryAfter when quota is exceeded', async () => {
    redisMock.get.mockResolvedValue('basic');
    // Count is 11, over limit of 10. TTL is 42 seconds remaining
    redisMock.eval.mockResolvedValue([11, 42]);

    const res = await service.checkRateLimit('tenant-1', 'POST:/sales', {
      limit: 10,
      windowSec: 60,
    });

    expect(res.allowed).toBe(false);
    expect(res.retryAfter).toBe(42);
  });

  it('bypasses rate limit if tenant plan is loadtest (ADR-0006)', async () => {
    redisMock.get.mockResolvedValue('loadtest');

    const res = await service.checkRateLimit('tenant-loadtest', 'POST:/sales', {
      limit: 10,
      windowSec: 60,
    });

    expect(res).toEqual({ allowed: true });
    // Should not even call redis.eval to increment counter
    expect(redisMock.eval).not.toHaveBeenCalled();
  });

  it('queries database for plan on cache miss and caches it in Redis', async () => {
    redisMock.get.mockResolvedValue(null); // cache miss
    dsMock.query.mockResolvedValue([{ plan: 'demo' }]);
    redisMock.eval.mockResolvedValue([1, 60]);

    const res = await service.checkRateLimit('tenant-demo', 'GET:/products', {
      limit: 10,
      windowSec: 60,
    });

    expect(res.allowed).toBe(true);
    expect(dsMock.query).toHaveBeenCalledWith(
      expect.stringContaining('SELECT plan FROM tenants WHERE id = $1'),
      ['tenant-demo'],
    );
    expect(redisMock.set).toHaveBeenCalledWith(
      't:tenant-demo:plan',
      'demo',
      'EX',
      300,
    );
  });

  it('fails open when Redis throws an error (ADR-0006 fail-open rule)', async () => {
    redisMock.get.mockRejectedValue(new Error('Redis connection refused'));
    dsMock.query.mockResolvedValue([{ plan: 'basic' }]);
    redisMock.eval.mockRejectedValue(new Error('Redis connection refused'));

    const res = await service.checkRateLimit('tenant-1', 'POST:/sales', {
      limit: 10,
      windowSec: 60,
    });

    // Must allow request through so POS does not stop selling!
    expect(res.allowed).toBe(true);
  });

  it('isolates tenants: keys contain tenant ID prefix', async () => {
    redisMock.get.mockResolvedValue('basic');
    redisMock.eval.mockResolvedValue([1, 60]);

    await service.checkRateLimit('tenant-A', 'POST:/sales');
    expect(redisMock.eval).toHaveBeenCalledWith(
      expect.any(String),
      1,
      expect.stringContaining('t:tenant-A:rl:'),
      expect.any(Number),
    );

    await service.checkRateLimit('tenant-B', 'POST:/sales');
    expect(redisMock.eval).toHaveBeenCalledWith(
      expect.any(String),
      1,
      expect.stringContaining('t:tenant-B:rl:'),
      expect.any(Number),
    );
  });
});
