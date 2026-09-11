import { randomUUID } from 'node:crypto';

let counter = 0;

/**
 * `prefix + base36(nowMs) + "_" + 8 hex + "_" + base36(++counter)` — the same shape
 * as the client's `core/utils/ids.dart`, itself a port of `pos/db.js` `_newId`.
 * Rows written by the server and rows imported from the old app therefore look alike,
 * and nothing downstream has to care which side made an id.
 */
export function newId(prefix: string): string {
  const ms = Date.now().toString(36);
  const short = randomUUID().replaceAll('-', '').slice(0, 8);
  return `${prefix}${ms}_${short}_${(++counter).toString(36)}`;
}
