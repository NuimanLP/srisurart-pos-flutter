import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';
import { describe, expect, it } from 'vitest';

/**
 * #443 PR3 AC: "no endpoint/CLI where the admin sends or receives the owner's password —
 * checked by a test that scans DTO/route like tenant-door.spec.ts". A mocked unit test cannot
 * see a DTO field someone adds next month; this scan does.
 *
 *   1. No class in `src/platform/` declares a property whose name mentions a password —
 *      that is every request DTO the platform plane accepts.
 *   2. Every object literal a platform method `return`s may carry a password-ish key only if
 *      it is `tempPassword`/`tempPasswordExpiresAt`, and only from the two methods that issue
 *      one (`createTenant`, `issueOwnerTempPassword`) — "returned once, at issue time".
 */
const PLATFORM = fileURLToPath(new URL('.', import.meta.url));
const ALLOWED_KEYS = new Set(['tempPassword', 'tempPasswordExpiresAt']);
const ISSUERS = new Set(['createTenant', 'issueOwnerTempPassword']);

function sources(): ts.SourceFile[] {
  return readdirSync(PLATFORM)
    .filter((f) => f.endsWith('.ts') && !f.endsWith('.spec.ts'))
    .map((f) =>
      ts.createSourceFile(f, readFileSync(join(PLATFORM, f), 'utf8'), ts.ScriptTarget.Latest, true),
    );
}

const mentionsPassword = (name: string) => /password/i.test(name);

describe('platform plane never carries an owner password (#443 PR3)', () => {
  it('no platform class declares a password-ish property (request DTOs)', () => {
    const offenders: string[] = [];
    for (const sf of sources()) {
      const visit = (n: ts.Node): void => {
        if (ts.isClassDeclaration(n) && n.name) {
          for (const m of n.members) {
            if (ts.isPropertyDeclaration(m) && mentionsPassword(m.name.getText(sf))) {
              offenders.push(`${sf.fileName}:${n.name.text}.${m.name.getText(sf)}`);
            }
          }
        }
        ts.forEachChild(n, visit);
      };
      visit(sf);
    }
    expect(offenders).toEqual([]);
  });

  it('only the two issuing methods return a password, and only the temporary one', () => {
    const found: string[] = [];
    for (const sf of sources()) {
      const visit = (n: ts.Node, method: string | null): void => {
        const here = ts.isMethodDeclaration(n) ? n.name.getText(sf) : method;
        if (ts.isReturnStatement(n) && n.expression && ts.isObjectLiteralExpression(n.expression)) {
          for (const p of n.expression.properties) {
            const key = p.name?.getText(sf) ?? '';
            if (mentionsPassword(key)) found.push(`${here}:${key}`);
          }
        }
        ts.forEachChild(n, (c) => visit(c, here));
      };
      visit(sf, null);
    }
    const bad = found.filter((f) => {
      const [method, key] = f.split(':');
      return !ISSUERS.has(method) || !ALLOWED_KEYS.has(key);
    });
    expect(bad).toEqual([]);
    // …and both issuers really do return it (so this scan is not vacuously green).
    expect(found.sort()).toEqual(
      [
        'createTenant:tempPassword',
        'createTenant:tempPasswordExpiresAt',
        'issueOwnerTempPassword:tempPassword',
        'issueOwnerTempPassword:tempPasswordExpiresAt',
      ].sort(),
    );
  });
});
