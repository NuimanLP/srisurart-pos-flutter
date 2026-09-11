import { createHash } from 'node:crypto';
import { Inject, Injectable, ServiceUnavailableException } from '@nestjs/common';
import type { Redis } from 'ioredis';
import type { Logger } from 'pino';
import type { EntityManager } from 'typeorm';
import { LOGGER } from '../infra/logger.provider.js';
import { REDIS_CACHE } from '../infra/redis.module.js';

/** Express lower-cases header names. */
export const IDEMPOTENCY_KEY_HEADER = 'idempotency-key';

/** `(tenant_id, key)` is a btree index; a huge key would fail as a 500, not a 400. */
export const IDEMPOTENCY_KEY_MAX_LENGTH = 200;

/**
 * 02_API_SCREENS.md §5: `t:{tid}:idem:{key}` lives 24h. Deleting the Postgres rows
 * is the `idem.cleanup` repeatable job in Lane C (#31–#37); this slice only records
 * `created_at`, which `idx_idem_created` exists to scan.
 */
export const IDEMPOTENCY_TTL_SECONDS = 24 * 60 * 60;

/**
 * How long a retry may wait for the in-flight original to commit before giving the
 * connection back. Without it the waiter holds a pool slot for as long as the winner
 * runs, and one wedged request can starve the whole instance.
 */
const CLAIM_LOCK_TIMEOUT = '5s';

/** Postgres `lock_not_available` — what `lock_timeout` raises. */
const LOCK_NOT_AVAILABLE = '55P03';

/** A cache lookup may not become the thing that stalls a money write. */
const CACHE_TIMEOUT_MS = 200;

/** What a completed request returned, replayed to a retry. */
export interface StoredResponse {
  /** HTTP status of the original success. */
  code: number;
  /** The handler's return value — the `data` the success envelope wraps. */
  body: unknown;
}

export type ClaimResult =
  /** This request owns the key: do the work, then call `complete`. */
  | { outcome: 'claimed' }
  /** The key already completed for the same request: replay this. */
  | { outcome: 'replay'; response: StoredResponse }
  /** The key already exists against a different request: 409. */
  | { outcome: 'reused' };

interface KeyRow {
  endpoint: string;
  request_hash: string;
  /** The DB's CHECK allows 'failed'; nothing writes it — see `claim`. */
  status: 'in_progress' | 'done' | 'failed';
  response_code: number | null;
  response_body: unknown;
  /** Seconds this row has left before Lane C's cleanup may delete it. */
  ttl_seconds: number;
}

interface CachedResponse extends StoredResponse {
  endpoint: string;
  hash: string;
}

/**
 * The idempotency record, and nothing else. Every money- and stock-moving endpoint
 * goes through it (02_API_SCREENS.md §1.4).
 *
 * Postgres is the authority: the `(tenant_id, key)` primary key is what serialises
 * concurrent retries, not an advisory lock. Redis is consulted only once a key is
 * known to be a repeat, so a first request never waits on it, and its worst case is
 * a lost round-trip.
 *
 * Every method takes the caller's transactional `EntityManager`, so the record is
 * written in the same transaction as the work it describes. A record committed
 * without its work, or work committed without its record, is a double charge.
 */
@Injectable()
export class IdempotencyService {
  constructor(
    @Inject(REDIS_CACHE) private readonly cache: Redis,
    @Inject(LOGGER) private readonly logger: Logger,
  ) {}

  /**
   * A stable fingerprint of the request body, so the same key against a changed
   * body is caught. Hashes the JSON as parsed from the wire: a client that
   * re-sends the same bytes re-sends the same key order, which is what a retry is.
   *
   * The endpoint is deliberately NOT folded in — `idempotency_keys.request_hash` is
   * defined as the hash of the body (01_DATABASE.md §…) — so `claim` compares the
   * stored `endpoint` column separately.
   */
  static requestHash(body: unknown): string {
    return createHash('sha256')
      .update(JSON.stringify(body ?? null))
      .digest('hex');
  }

  private cacheKey(tenantId: string, key: string): string {
    return `t:${tenantId}:idem:${key}`;
  }

  /**
   * Claims `key` for this request, or reports what the winner left behind.
   *
   * `ON CONFLICT DO NOTHING` is the whole concurrency mechanism: a second request
   * carrying a live key blocks on the first transaction's row lock, then finds its
   * own insert did nothing and replays the committed row. If the first transaction
   * rolled back, the second inserts and does the work itself. Either way exactly
   * one request executes.
   */
  async claim(
    em: EntityManager,
    params: {
      tenantId: string;
      key: string;
      endpoint: string;
      requestHash: string;
    },
  ): Promise<ClaimResult> {
    if (await this.insertClaim(em, params)) return { outcome: 'claimed' };

    // Only now, with the key known to be a repeat, is the cache worth asking.
    const cached = await this.readCache(params.tenantId, params.key);
    if (cached) {
      return this.decide(cached, params);
    }

    const rows = (await em.query(
      `SELECT endpoint, request_hash, status, response_code, response_body,
              GREATEST(0, $3::int - EXTRACT(EPOCH FROM now() - created_at))::int AS ttl_seconds
         FROM idempotency_keys
        WHERE tenant_id = $1::uuid AND key = $2`,
      [params.tenantId, params.key, IDEMPOTENCY_TTL_SECONDS],
    )) as KeyRow[];
    const row = rows[0];
    // RLS hid it, or Lane C's cleanup removed it between the two statements. Both
    // mean "not ours to replay"; refusing is the only safe answer.
    if (!row) return { outcome: 'reused' };

    if (row.status !== 'done' || row.response_code === null) {
      // Unreachable while callers use this module as documented: the claim and its
      // completion share one transaction, so a committed row is always 'done'. It
      // means someone committed a claim without completing it — a bug worth seeing,
      // not a client error to dress up as a 409.
      throw new Error(
        `idempotency_keys row for key ${params.key} committed as '${row.status}': ` +
          'claim() and complete() must run in the same transaction',
      );
    }

    const decision = this.decide(
      {
        endpoint: row.endpoint,
        hash: row.request_hash,
        code: row.response_code,
        body: row.response_body,
      },
      params,
    );
    if (decision.outcome === 'replay') {
      await this.writeCache(
        params.tenantId,
        params.key,
        {
          endpoint: row.endpoint,
          hash: row.request_hash,
          code: row.response_code,
          body: row.response_body,
        },
        row.ttl_seconds,
      );
    }
    return decision;
  }

  /**
   * The claim insert, bounded so a retry cannot wait forever on the original.
   * Returns whether this request became the owner of the key.
   */
  private async insertClaim(
    em: EntityManager,
    params: {
      tenantId: string;
      key: string;
      endpoint: string;
      requestHash: string;
    },
  ): Promise<boolean> {
    await em.query(`SET LOCAL lock_timeout = '${CLAIM_LOCK_TIMEOUT}'`);
    let inserted: unknown[];
    try {
      inserted = (await em.query(
        `INSERT INTO idempotency_keys (tenant_id, key, endpoint, request_hash, status)
              VALUES ($1::uuid, $2, $3, $4, 'in_progress')
         ON CONFLICT (tenant_id, key) DO NOTHING
           RETURNING 1`,
        [params.tenantId, params.key, params.endpoint, params.requestHash],
      )) as unknown[];
    } catch (err) {
      // No reset here: the transaction is already aborted, so any further statement
      // would fail with 25P02 and hide this error.
      if ((err as { code?: string }).code === LOCK_NOT_AVAILABLE) {
        // The original is still running. Retrying later is right; executing now is not.
        throw new ServiceUnavailableException({
          code: 'IDEMPOTENCY_KEY_IN_FLIGHT',
          message: 'A request with this Idempotency-Key is still in progress',
        });
      }
      throw err;
    }
    // Leave the caller's transaction as it was found; the handler's own statements
    // should not inherit this module's lock policy.
    await em.query(`SET LOCAL lock_timeout = DEFAULT`);
    return inserted.length > 0;
  }

  /** Same key, same endpoint, same body → replay. Anything else → 409. */
  private decide(
    stored: CachedResponse,
    params: { endpoint: string; requestHash: string },
  ): ClaimResult {
    // The endpoint matters as much as the body: the same key and body against
    // POST /sales and then POST /returns would otherwise replay the sale and
    // silently perform no return. It is the CONCRETE target, path parameters and
    // all, so the same key against two bills' /void is caught here too — the body
    // of a void is just `{pin}` and cannot tell them apart.
    if (
      stored.hash !== params.requestHash ||
      stored.endpoint !== params.endpoint
    ) {
      return { outcome: 'reused' };
    }
    return {
      outcome: 'replay',
      response: { code: stored.code, body: stored.body },
    };
  }

  /**
   * Records the response against a claimed key. Must run in the same transaction as
   * the work, and before it commits.
   */
  async complete(
    em: EntityManager,
    params: {
      tenantId: string;
      key: string;
      response: StoredResponse;
    },
  ): Promise<void> {
    // TypeORM answers an UPDATE with `[rows, affected]` — unlike an INSERT, which
    // answers with the rows alone. Verified against the driver, not assumed.
    const [, affected] = (await em.query(
      `UPDATE idempotency_keys
          SET status = 'done', response_code = $3, response_body = $4::jsonb
        WHERE tenant_id = $1::uuid AND key = $2`,
      [
        params.tenantId,
        params.key,
        params.response.code,
        JSON.stringify(params.response.body ?? null),
      ],
    )) as [unknown[], number];
    if (affected !== 1) {
      // Committing the work with no record is exactly the double charge this module
      // exists to prevent, so fail the request and take the work down with it.
      throw new Error(
        `idempotency_keys row for key ${params.key} vanished before completion`,
      );
    }
  }

  /**
   * Caches a response Postgres has already committed. Only ever called on the replay
   * path: caching at write time would leave a phantom success behind if the
   * transaction then rolled back.
   *
   * `ttlSeconds` is the row's own remaining life, not a fresh 24h, so the cache can
   * never outlive the record it mirrors and answer for a key Lane C has deleted.
   */
  private async writeCache(
    tenantId: string,
    key: string,
    value: CachedResponse,
    ttlSeconds: number,
  ): Promise<void> {
    if (ttlSeconds <= 0) return;
    await this.tryCache('write', () =>
      this.cache.set(
        this.cacheKey(tenantId, key),
        JSON.stringify(value),
        'EX',
        ttlSeconds,
      ),
    );
  }

  private async readCache(
    tenantId: string,
    key: string,
  ): Promise<CachedResponse | null> {
    const raw = await this.tryCache('read', () =>
      this.cache.get(this.cacheKey(tenantId, key)),
    );
    return typeof raw === 'string' ? (JSON.parse(raw) as CachedResponse) : null;
  }

  /**
   * Redis is an accelerator, never an authority: a failure, and a hang in
   * particular, falls through to Postgres rather than stalling the write. ioredis
   * fails fast when disconnected, but a connected-and-silent server would otherwise
   * wait forever, so the timeout is ours, not the client's.
   */
  private async tryCache<T>(
    op: 'read' | 'write',
    run: () => Promise<T>,
  ): Promise<T | null> {
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        run(),
        new Promise<null>((resolve) => {
          timer = setTimeout(() => resolve(null), CACHE_TIMEOUT_MS);
        }),
      ]);
    } catch (err) {
      this.logger.warn({ err, op }, 'idempotency cache unavailable');
      return null;
    } finally {
      clearTimeout(timer);
    }
  }
}
