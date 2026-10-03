import { createInterface, type Interface } from 'node:readline';
import { pathToFileURL } from 'node:url';

/**
 * Platform admin CLI (#443 PR1) — the replacement for the `curl`/`wget`-through-nginx
 * runbook in `docs/handoff_log/ticket-338-platform-provision.md`. It talks straight to
 * the api container over plain HTTP on loopback (`http://127.0.0.1:3000` by default),
 * which is itself inside `PlatformAuthGuard`'s allowlist (`isAllowedIp` accepts
 * `127.0.0.1`/`::1` unconditionally) — so this needs no nginx hop, no TLS, and no
 * change to `platform-auth.guard.ts`.
 *
 * On mob04 (no pnpm/corepack in the runtime image — see `Dockerfile`): run it as
 * `docker compose exec api-1 node dist/cli/platform.js …`. Dev-only convenience:
 * `pnpm platform …` (runs the built `dist/cli/platform.js` the same way).
 *
 * Every command logs in for itself — there is no persisted session and no token is
 * ever written to disk or printed. A password (the operator's own platform-admin
 * password, an owner's temporary password, or a chosen replacement) is read from
 * `stdin`/the TTY only: never a `--flag` (it would sit in `ps` and shell history) and
 * never an env var (it would sit in the process's environment block, which
 * `docker inspect`/`/proc` can read). `assertNoPasswordFlags` turns an attempt to pass
 * one into a loud, immediate refusal rather than a silently-accepted leak.
 *
 * #443 PR3: `POST /platform/tenants` no longer takes an `ownerPassword` — the server
 * generates a temporary one and returns it once (`tempPassword`/`enrolCode`). This CLI
 * never prompts for it. `owner:set-password` is the one command on the *tenant* plane
 * (not the platform plane): it logs in as the owner with the temporary password and
 * changes it in the same run, for teams that legitimately own a demo/loadtest tenant's
 * credentials (owner decision 2026-09-27) — never for a real shop's owner account.
 */

const DEFAULT_BASE_URL = 'http://127.0.0.1:3000';

export interface ParsedArgs {
  command: string;
  positionals: string[];
  flags: Record<string, string>;
}

/** `--key value`, `--key=value`, and bare positionals (no `--` prefix). */
export function parseArgv(argv: string[]): ParsedArgs {
  const [command = '', ...rest] = argv;
  const positionals: string[] = [];
  const flags: Record<string, string> = {};
  for (let i = 0; i < rest.length; i++) {
    const token = rest[i];
    if (!token.startsWith('--')) {
      positionals.push(token);
      continue;
    }
    const body = token.slice(2);
    const eq = body.indexOf('=');
    if (eq !== -1) {
      flags[body.slice(0, eq)] = body.slice(eq + 1);
      continue;
    }
    const next = rest[i + 1];
    if (next !== undefined && !next.startsWith('--')) {
      flags[body] = next;
      i++;
    } else {
      flags[body] = '';
    }
  }
  return { command, positionals, flags };
}

/**
 * Refuses any flag that looks like it was meant to carry a secret. Passwords in this
 * CLI come from `readSecret` only — this is the loud failure that catches a habit
 * carried over from the old `curl -d '{"password":...}'` runbook before it ships a
 * password into `ps aux` or `.bash_history`.
 */
export function assertNoPasswordFlags(flags: Record<string, string>): void {
  const offender = Object.keys(flags).find((key) => /pass/i.test(key));
  if (offender) {
    throw new Error(
      `--${offender} is not accepted — passwords are read from stdin/TTY only, ` +
        'never from a flag (it would sit in `ps` output and shell history)',
    );
  }
}

function requireFlag(flags: Record<string, string>, key: string): string {
  const value = flags[key];
  if (!value || !value.trim()) throw new Error(`--${key} is required`);
  return value;
}

// ---------------------------------------------------------------------------
// Secret prompting
// ---------------------------------------------------------------------------

export interface Prompter {
  readonly isTTY: boolean;
  /** Resolves with the next line typed/piped, in the order lines arrive. */
  nextLine(): Promise<string>;
  write(text: string): void;
  close(): void;
}

/**
 * One `Prompter` per CLI run, shared by every `readSecret` call. The `line` listener
 * is attached once, up front — before any prompt is shown — so a chunk that carries
 * several already-buffered lines (e.g. `printf 'adminpw\nownerpw\n' | docker compose
 * exec -T …`, which can land in one `data` event) is queued correctly regardless of
 * how many `await`s separate the calls that eventually ask for each line. Wiring
 * `readline.question()` fresh per secret does not have this property: it only wins
 * the race when the next `question()` call happens synchronously before readline
 * finishes draining the current chunk, which an `await` in between breaks.
 */
export function createPrompter(
  input: NodeJS.ReadableStream = process.stdin,
  // stderr, not stdout: a prompt is a message to whoever is typing, not part of the
  // command's result. Keeping it off stdout is what lets `tenants:create | jq .` (or an
  // e2e test capturing stdout) see clean JSON instead of "Platform admin password: {…}".
  output: NodeJS.WritableStream = process.stderr,
): Prompter {
  const isTTY = !!(input as { isTTY?: boolean }).isTTY;
  const rl: Interface = createInterface({ input, output, terminal: isTTY });

  // We print every prompt and read every line ourselves (see readSecret), so readline's
  // own per-keystroke terminal echo is muted for the whole session — a password must
  // never reach the screen, however many secrets this run ends up asking for. This
  // relies on readline's internal `_writeToOutput` hook; if a future Node version drops
  // it, the override below becomes a no-op and input falls back to being visible while
  // typed (degraded, not broken — the piped/CI path never goes through this at all).
  if (isTTY) {
    (rl as unknown as { _writeToOutput?: (chunk: string) => void })._writeToOutput = () => {};
  }

  const buffered: string[] = [];
  const waiters: Array<{ resolve: (line: string) => void; reject: (err: Error) => void }> = [];
  let closed = false;

  rl.on('line', (line) => {
    const waiter = waiters.shift();
    if (waiter) waiter.resolve(line);
    else buffered.push(line);
  });
  rl.on('close', () => {
    closed = true;
    let waiter: (typeof waiters)[number] | undefined;
    while ((waiter = waiters.shift())) {
      waiter.reject(new Error('input ended before a value was entered'));
    }
  });

  return {
    isTTY,
    nextLine(): Promise<string> {
      const line = buffered.shift();
      if (line !== undefined) return Promise.resolve(line);
      if (closed) return Promise.reject(new Error('input ended before a value was entered'));
      return new Promise((resolve, reject) => waiters.push({ resolve, reject }));
    },
    write: (text: string) => output.write(text),
    close: () => rl.close(),
  };
}

/** Prompts for one line and never echoes it back on a real terminal. */
export async function readSecret(prompter: Prompter, promptText: string): Promise<string> {
  prompter.write(promptText);
  const line = await prompter.nextLine();
  if (prompter.isTTY) prompter.write('\n');
  return line;
}

// ---------------------------------------------------------------------------
// HTTP client — `02_API_SCREENS.md §1.2` envelope: {status:'success',data} /
// {status:'error',error:{code,message}}
// ---------------------------------------------------------------------------

export class PlatformApiError extends Error {
  constructor(
    public readonly httpStatus: number,
    public readonly code: string,
    detail: string,
  ) {
    super(`platform API refused (${httpStatus} ${code}): ${detail}`);
    this.name = 'PlatformApiError';
  }
}

export type FetchLike = typeof fetch;

async function apiRequest<T>(
  baseUrl: string,
  method: string,
  path: string,
  opts: { token?: string; body?: unknown } = {},
  fetchImpl: FetchLike = fetch,
): Promise<T> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`;
  const res = await fetchImpl(`${baseUrl}${path}`, {
    method,
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  const json = (await res.json().catch(() => null)) as
    | { status: 'success'; data: T }
    | { status: 'error'; error: { code: string; message: string } }
    | null;
  if (!res.ok || !json || json.status !== 'success') {
    const code = json && json.status === 'error' ? json.error.code : 'UNKNOWN_ERROR';
    const message = json && json.status === 'error' ? json.error.message : `HTTP ${res.status}`;
    throw new PlatformApiError(res.status, code, message);
  }
  return json.data;
}

export interface PlatformAdmin {
  id: string;
  username: string;
  displayName: string;
}

export function platformLogin(
  baseUrl: string,
  username: string,
  password: string,
  fetchImpl: FetchLike = fetch,
): Promise<{ token: string; admin: PlatformAdmin }> {
  return apiRequest(
    baseUrl,
    'POST',
    '/api/v1/platform/auth/token',
    { body: { username, password } },
    fetchImpl,
  );
}

export function listTenants(
  baseUrl: string,
  token: string,
  fetchImpl: FetchLike = fetch,
): Promise<unknown[]> {
  return apiRequest(baseUrl, 'GET', '/api/v1/platform/tenants', { token }, fetchImpl);
}

/**
 * Same shape as `PlatformTenantsService.CreateTenantDto` (#443 PR3): there is no
 * `ownerPassword` any more — the server generates a temporary one and returns it once
 * in the response (`tempPassword`/`tempPasswordExpiresAt`). Sending `ownerPassword` at
 * all is refused with `400 OWNER_PASSWORD_NOT_ACCEPTED`, so this type does not offer it.
 */
export interface CreateTenantArgs {
  code: string;
  shopName: string;
  shopNameEn?: string;
  plan?: string;
  timezone?: string;
  ownerUsername: string;
  ownerDisplayName?: string;
}

export function createTenant(
  baseUrl: string,
  token: string,
  dto: CreateTenantArgs,
  fetchImpl: FetchLike = fetch,
): Promise<unknown> {
  return apiRequest(baseUrl, 'POST', '/api/v1/platform/tenants', { token, body: dto }, fetchImpl);
}

export type TenantStatus = 'active' | 'suspended' | 'closed';

export function updateTenantStatus(
  baseUrl: string,
  token: string,
  tenantId: string,
  status: TenantStatus,
  fetchImpl: FetchLike = fetch,
): Promise<unknown> {
  return apiRequest(
    baseUrl,
    'PATCH',
    `/api/v1/platform/tenants/${encodeURIComponent(tenantId)}/status`,
    { token, body: { status } },
    fetchImpl,
  );
}

/** `GET /platform/tenants/:id` (#443 PR2) — tenant + devices + last 20 import jobs. */
export function getTenantDetail(
  baseUrl: string,
  token: string,
  tenantId: string,
  fetchImpl: FetchLike = fetch,
): Promise<unknown> {
  return apiRequest(
    baseUrl,
    'GET',
    `/api/v1/platform/tenants/${encodeURIComponent(tenantId)}`,
    { token },
    fetchImpl,
  );
}

/** `GET /platform/tenants/:id/audit` (#443) — one page, newest first; pass `nextCursor` as `before`. */
export function getTenantAudit(
  baseUrl: string,
  token: string,
  tenantId: string,
  page: { before?: string; limit?: string },
  fetchImpl: FetchLike = fetch,
): Promise<unknown> {
  const qs = new URLSearchParams();
  if (page.before) qs.set('before', page.before);
  if (page.limit) qs.set('limit', page.limit);
  const query = qs.toString() ? `?${qs.toString()}` : '';
  return apiRequest(
    baseUrl,
    'GET',
    `/api/v1/platform/tenants/${encodeURIComponent(tenantId)}/audit${query}`,
    { token },
    fetchImpl,
  );
}

/** `GET /platform/system` (#443) — deployed SHA, readiness, queue counts, backup statement. */
export function getSystemStatus(
  baseUrl: string,
  token: string,
  fetchImpl: FetchLike = fetch,
): Promise<unknown> {
  return apiRequest(baseUrl, 'GET', '/api/v1/platform/system', { token }, fetchImpl);
}

/** `POST /platform/tenants/:id/devices/:deviceId/enrol-code` (#443 PR2). */
export function reissueEnrolCode(
  baseUrl: string,
  token: string,
  tenantId: string,
  deviceId: string,
  fetchImpl: FetchLike = fetch,
): Promise<unknown> {
  return apiRequest(
    baseUrl,
    'POST',
    `/api/v1/platform/tenants/${encodeURIComponent(tenantId)}/devices/${encodeURIComponent(deviceId)}/enrol-code`,
    { token },
    fetchImpl,
  );
}

/** `POST /platform/tenants/:id/owner/temp-password` (#443 PR3) — issues a fresh 24 h temp password. */
export function issueOwnerTempPassword(
  baseUrl: string,
  token: string,
  tenantId: string,
  fetchImpl: FetchLike = fetch,
): Promise<unknown> {
  return apiRequest(
    baseUrl,
    'POST',
    `/api/v1/platform/tenants/${encodeURIComponent(tenantId)}/owner/temp-password`,
    { token },
    fetchImpl,
  );
}

/**
 * The tenant plane (#443 PR3), used only by `owner:set-password` below. Unlike the
 * platform plane, `/auth/*` carries no `PlatformAuthGuard`/IP allowlist, so it is
 * reachable the same way — plain HTTP on loopback, straight to the api container.
 */
export function tenantLogin(
  baseUrl: string,
  username: string,
  password: string,
  fetchImpl: FetchLike = fetch,
): Promise<{
  passwordChangeRequired?: boolean;
  passwordChangeToken?: string;
  accessToken?: string;
  user: { id: string; username: string; role: string; displayName: string };
}> {
  return apiRequest(
    baseUrl,
    'POST',
    '/api/v1/auth/token',
    { body: { username, password } },
    fetchImpl,
  );
}

/** `POST /auth/change-password`, Bearer the restricted `typ:'pwchange'` token login just returned. */
export function changeOwnerPassword(
  baseUrl: string,
  passwordChangeToken: string,
  newPassword: string,
  fetchImpl: FetchLike = fetch,
): Promise<{ user: { id: string; username: string; role: string; displayName: string } }> {
  return apiRequest(
    baseUrl,
    'POST',
    '/api/v1/auth/change-password',
    { token: passwordChangeToken, body: { newPassword } },
    fetchImpl,
  );
}

// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

export interface CliIO {
  input?: NodeJS.ReadableStream;
  output?: NodeJS.WritableStream;
  log?: (line: string) => void;
  fetchImpl?: FetchLike;
}

const TENANT_STATUSES: readonly TenantStatus[] = ['active', 'suspended', 'closed'];

/**
 * Runs one CLI invocation. Every branch logs in for itself (`platformLogin`) rather
 * than accepting a token — see the module doc for why: no token is ever persisted or
 * hand-copied between commands.
 */
export async function runPlatformCli(argv: string[], io: CliIO = {}): Promise<void> {
  const log = io.log ?? ((line: string) => console.log(line));
  const fetchImpl = io.fetchImpl ?? fetch;
  const { command, positionals, flags } = parseArgv(argv);
  assertNoPasswordFlags(flags);
  const baseUrl = flags['base-url']?.trim() || DEFAULT_BASE_URL;

  if (command === 'login') {
    const user = requireFlag(flags, 'user');
    const prompter = createPrompter(io.input, io.output);
    try {
      const password = await readSecret(prompter, 'Platform admin password: ');
      const { admin } = await platformLogin(baseUrl, user, password, fetchImpl);
      log(`logged in as ${admin.username} (id ${admin.id})`);
    } finally {
      prompter.close();
    }
    return;
  }

  if (command === 'tenants:list') {
    const user = requireFlag(flags, 'user');
    const prompter = createPrompter(io.input, io.output);
    try {
      const password = await readSecret(prompter, 'Platform admin password: ');
      const { token } = await platformLogin(baseUrl, user, password, fetchImpl);
      const tenants = await listTenants(baseUrl, token, fetchImpl);
      log(JSON.stringify(tenants, null, 2));
    } finally {
      prompter.close();
    }
    return;
  }

  if (command === 'tenants:create') {
    const user = requireFlag(flags, 'user');
    // Validate every non-secret field before asking for the admin password (CLAUDE.md:
    // validate the input first, then use it) — a typo in `--code` should not cost the
    // operator a password prompt before it is refused.
    const code = requireFlag(flags, 'code');
    const shopName = requireFlag(flags, 'shop-name');
    const ownerUsername = requireFlag(flags, 'owner-username');
    const prompter = createPrompter(io.input, io.output);
    try {
      const adminPassword = await readSecret(prompter, 'Platform admin password: ');
      const { token } = await platformLogin(baseUrl, user, adminPassword, fetchImpl);
      // #443 PR3: no owner password to read or send — the server generates one and
      // returns it once as `tempPassword` below.
      const result = await createTenant(
        baseUrl,
        token,
        {
          code,
          shopName,
          shopNameEn: flags['shop-name-en'],
          plan: flags.plan,
          timezone: flags.timezone,
          ownerUsername,
          ownerDisplayName: flags['owner-display-name'],
        },
        fetchImpl,
      );
      log(JSON.stringify(result, null, 2));
      // stderr, not stdout: keeps `tenants:create | jq .`/an e2e test's stdout capture
      // as clean JSON, same reason prompts go to stderr (see `createPrompter` above).
      prompter.write(
        'Note: tempPassword and enrolCode above are shown once and cannot be retrieved again — record them now.\n',
      );
    } finally {
      prompter.close();
    }
    return;
  }

  if (command === 'tenants:show') {
    const [tenantId] = positionals;
    if (!tenantId) {
      throw new Error('usage: tenants:show <tenantId> --user <admin username>');
    }
    const user = requireFlag(flags, 'user');
    const prompter = createPrompter(io.input, io.output);
    try {
      const password = await readSecret(prompter, 'Platform admin password: ');
      const { token } = await platformLogin(baseUrl, user, password, fetchImpl);
      const result = await getTenantDetail(baseUrl, token, tenantId, fetchImpl);
      log(JSON.stringify(result, null, 2));
    } finally {
      prompter.close();
    }
    return;
  }

  if (command === 'tenants:audit') {
    const [tenantId] = positionals;
    if (!tenantId) {
      throw new Error(
        'usage: tenants:audit <tenantId> [--limit <1-200>] [--before <cursor>] --user <admin username>',
      );
    }
    const user = requireFlag(flags, 'user');
    const prompter = createPrompter(io.input, io.output);
    try {
      const password = await readSecret(prompter, 'Platform admin password: ');
      const { token } = await platformLogin(baseUrl, user, password, fetchImpl);
      const result = await getTenantAudit(
        baseUrl,
        token,
        tenantId,
        { before: flags.before, limit: flags.limit },
        fetchImpl,
      );
      log(JSON.stringify(result, null, 2));
    } finally {
      prompter.close();
    }
    return;
  }

  if (command === 'system') {
    const user = requireFlag(flags, 'user');
    const prompter = createPrompter(io.input, io.output);
    try {
      const password = await readSecret(prompter, 'Platform admin password: ');
      const { token } = await platformLogin(baseUrl, user, password, fetchImpl);
      log(JSON.stringify(await getSystemStatus(baseUrl, token, fetchImpl), null, 2));
    } finally {
      prompter.close();
    }
    return;
  }

  if (command === 'devices:reissue-code') {
    const [tenantId, deviceId] = positionals;
    if (!tenantId || !deviceId) {
      throw new Error(
        'usage: devices:reissue-code <tenantId> <deviceId> --user <admin username>',
      );
    }
    const user = requireFlag(flags, 'user');
    const prompter = createPrompter(io.input, io.output);
    try {
      const password = await readSecret(prompter, 'Platform admin password: ');
      const { token } = await platformLogin(baseUrl, user, password, fetchImpl);
      const result = await reissueEnrolCode(baseUrl, token, tenantId, deviceId, fetchImpl);
      log(JSON.stringify(result, null, 2));
      prompter.write(
        'Note: enrolCode above is shown once and cannot be retrieved again — record it now.\n',
      );
    } finally {
      prompter.close();
    }
    return;
  }

  if (command === 'owner:temp-password') {
    const [tenantId] = positionals;
    if (!tenantId) {
      throw new Error('usage: owner:temp-password <tenantId> --user <admin username>');
    }
    const user = requireFlag(flags, 'user');
    const prompter = createPrompter(io.input, io.output);
    try {
      const password = await readSecret(prompter, 'Platform admin password: ');
      const { token } = await platformLogin(baseUrl, user, password, fetchImpl);
      const result = await issueOwnerTempPassword(baseUrl, token, tenantId, fetchImpl);
      log(JSON.stringify(result, null, 2));
      prompter.write(
        'Note: tempPassword above is shown once and cannot be retrieved again — record it now.\n',
      );
    } finally {
      prompter.close();
    }
    return;
  }

  if (command === 'owner:set-password') {
    // Tenant plane, not platform plane: this logs in AS the owner, with the temporary
    // password, and changes it in the same run. Owner decision 2026-09-27: for a
    // demo/loadtest tenant the team legitimately owns, not for a real shop's owner —
    // a real owner changes their own password through the app, not this CLI.
    const [username] = positionals;
    if (!username) {
      throw new Error('usage: owner:set-password <username> [--base-url <url>]');
    }
    const prompter = createPrompter(io.input, io.output);
    try {
      const tempPassword = await readSecret(prompter, 'Temporary owner password: ');
      const newPassword = await readSecret(prompter, 'New owner password: ');
      const loginResult = await tenantLogin(baseUrl, username, tempPassword, fetchImpl);
      if (!loginResult.passwordChangeRequired || !loginResult.passwordChangeToken) {
        throw new Error(
          'login did not ask for a password change — this account may already have a real password',
        );
      }
      const result = await changeOwnerPassword(
        baseUrl,
        loginResult.passwordChangeToken,
        newPassword,
        fetchImpl,
      );
      // Never the tokens `changeOwnerPassword` returns — same rule as every other
      // command here (see the module doc comment).
      log(JSON.stringify({ username: result.user.username, passwordChanged: true }, null, 2));
    } finally {
      prompter.close();
    }
    return;
  }

  if (command === 'tenants:status') {
    const [tenantId, status] = positionals;
    if (!tenantId || !status) {
      throw new Error(
        'usage: tenants:status <tenantId> <active|suspended|closed> --user <admin username>',
      );
    }
    if (!TENANT_STATUSES.includes(status as TenantStatus)) {
      throw new Error(`status must be one of: ${TENANT_STATUSES.join(', ')}`);
    }
    const user = requireFlag(flags, 'user');
    const prompter = createPrompter(io.input, io.output);
    try {
      const password = await readSecret(prompter, 'Platform admin password: ');
      const { token } = await platformLogin(baseUrl, user, password, fetchImpl);
      const result = await updateTenantStatus(
        baseUrl,
        token,
        tenantId,
        status as TenantStatus,
        fetchImpl,
      );
      log(JSON.stringify(result, null, 2));
    } finally {
      prompter.close();
    }
    return;
  }

  throw new Error(
    `unknown command "${command}" — expected one of: login, tenants:list, tenants:create, ` +
      'tenants:status, tenants:show, tenants:audit, system, devices:reissue-code, ' +
      'owner:temp-password, owner:set-password',
  );
}

// Entry guard, same pattern as `db/bootstrap-admin.ts`: only run when node was pointed
// directly at this file (the e2e suite imports `runPlatformCli` without triggering it).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await runPlatformCli(process.argv.slice(2));
  } catch (err) {
    console.error(err instanceof Error ? err.message : err);
    process.exitCode = 1;
  }
}
