import { createServer, type Server, type Socket } from 'node:net';
import type { AddressInfo } from 'node:net';
import type { Redis } from 'ioredis';

/**
 * A real TCP server that speaks just enough RESP to get ioredis to `ready`, then can be
 * told to go silent on an already-open connection — the #140 case ("Redis that keeps the
 * TCP connection open but stops answering"), which no `vi.spyOn` mock can reproduce
 * because a mocked rejection settles instantly instead of never settling at all.
 *
 * Shared by `src/infra/redis-command-timeout.spec.ts` (unit-level, calls `TenantGuard`/
 * `TenantCache` directly) and `redis-cache-outage.e2e-spec.ts` (e2e-level, boots the whole
 * app against it) so the one RESP-parsing implementation only needs fixing in one place.
 */

/** One RESP array of bulk strings off the front of `buf`, or null if it is not all here yet. */
function parseCommand(buf: string): { args: string[]; consumed: number } | null {
  if (!buf.startsWith('*')) return null;
  let pos = buf.indexOf('\r\n');
  if (pos < 0) return null;
  const n = Number(buf.slice(1, pos));
  pos += 2;
  const args: string[] = [];
  for (let i = 0; i < n; i++) {
    const end = buf.indexOf('\r\n', pos);
    if (end < 0) return null;
    const len = Number(buf.slice(pos + 1, end));
    const start = end + 2;
    if (buf.length < start + len + 2) return null;
    args.push(buf.slice(start, start + len));
    pos = start + len + 2;
  }
  return { args, consumed: pos };
}

/** Just enough of a Redis to get ioredis to `ready`: refuse RESP3, answer INFO, OK the rest. */
function reply(args: string[]): string {
  const cmd = (args[0] ?? '').toUpperCase();
  if (cmd === 'HELLO') return "-ERR unknown command 'HELLO'\r\n";
  if (cmd === 'INFO') {
    const body = '# Server\r\nredis_version:7.2.0\r\nloading:0\r\n';
    return `$${Buffer.byteLength(body)}\r\n${body}\r\n`;
  }
  return '+OK\r\n';
}

export interface FakeRedis {
  url: string;
  /** From now on, read every byte and answer none of them. */
  hang(): void;
  close(): Promise<void>;
}

export async function fakeRedis(): Promise<FakeRedis> {
  let answering = true;
  const sockets = new Set<Socket>();
  const server: Server = createServer((socket) => {
    sockets.add(socket);
    let buf = '';
    socket.on('data', (chunk) => {
      if (!answering) return;
      buf += chunk.toString('utf8');
      for (let parsed = parseCommand(buf); parsed; parsed = parseCommand(buf)) {
        buf = buf.slice(parsed.consumed);
        socket.write(reply(parsed.args));
      }
    });
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  return {
    url: `redis://127.0.0.1:${port}`,
    hang: () => {
      answering = false;
    },
    close: async () => {
      for (const s of sockets) s.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

export async function untilReady(client: Redis): Promise<void> {
  if (client.status === 'ready') return;
  await new Promise<void>((resolve) => client.once('ready', () => resolve()));
}
