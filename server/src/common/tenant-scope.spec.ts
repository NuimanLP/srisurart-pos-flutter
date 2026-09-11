import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const SRC = join(fileURLToPath(new URL('.', import.meta.url)), '..');

function tsFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return tsFiles(path);
    return path.endsWith('.ts') ? [path] : [];
  });
}

/** Comments are where the *correct* spelling of this mistake is written down. */
function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

// `SET` is a utility statement: Postgres never plans it, so it takes no bind
// parameter and `SET LOCAL app.tenant_id = $1` is a 42601 syntax error — one that
// unit tests cannot see, because a mocked `query` accepts any string. It reached
// `main` three separate times (auth login, auth refresh, TenantService), and the
// one in `refreshTokenPayload` 500'd every refresh for as long as it lived. The
// transaction-scoped form that does take a parameter is `set_config(..., true)`.
//
// Anchored to the start of a statement — a quote, a backtick, a semicolon or a new
// line — because the `SET` of an `UPDATE ... SET col = $1` is a different keyword
// and binds parameters perfectly well.
const SET_WITH_BIND_PARAM =
  /(?:^|[;`'"])\s*SET\s+(?:LOCAL\s+|SESSION\s+)?[\w.]+\s*(?:=|\bTO\b)\s*\$\d/im;

describe('tenant scoping', () => {
  // The scan below is only worth its line count if the pattern still recognises the
  // bug it was written for, and still ignores the statement it kept tripping over.
  it('recognises the broken form and leaves UPDATE ... SET alone', () => {
    expect(SET_WITH_BIND_PARAM.test('`SET LOCAL app.tenant_id = $1`')).toBe(true);
    expect(SET_WITH_BIND_PARAM.test("'SET app.tenant_id TO $1'")).toBe(true);
    expect(SET_WITH_BIND_PARAM.test('`UPDATE tenants SET status = $1 WHERE id = $2`')).toBe(false);
    expect(SET_WITH_BIND_PARAM.test("`SELECT set_config('app.tenant_id', $1, true)`")).toBe(false);
  });

  it('never passes a bind parameter to SET', () => {
    const offenders = tsFiles(SRC)
      // Production code only: the case above deliberately holds the broken spelling.
      .filter((path) => !path.endsWith('.spec.ts'))
      .filter((path) => SET_WITH_BIND_PARAM.test(stripComments(readFileSync(path, 'utf8'))))
      .map((path) => relative(SRC, path).split(sep).join('/'));

    expect(offenders).toEqual([]);
  });
});
