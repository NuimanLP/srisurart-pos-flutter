import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';
import { describe, expect, it } from 'vitest';

const SRC = join(fileURLToPath(new URL('.', import.meta.url)), '..');

/**
 * #616: every id is a lowercase UUID, and a non-UUID that reaches a `uuid` column is a 22P02.
 * `invalidUuidInput` turns that into a 400 after the fact, but only once SQL has already run
 * (and inside `/sync/push` it decides which op is rejected). So an id a client names in the
 * URL must be checked before the handler body runs: a controller `@Param`/`@Query` whose name
 * ends in `id`/`Id` either carries `ParseUuidPipe`, or the handler passes it to
 * `parseUuid`/`requiredUuid`/`optionalUuid`. A new route that forgets both fails here, the
 * same way `idempotency-routes.spec.ts` pins the claim — a source scan, because a mocked unit
 * test of the route would never see the missing check.
 */
const ID_NAME = /[iI]d$/;
const VALIDATORS = ['parseUuid', 'requiredUuid', 'optionalUuid'];

/** `Class.method @Decorator('name')` — not validated as a lowercase UUID on purpose. */
const ALLOWLIST: Record<string, string> = {
  // Tenant ids predate #616 and are checked by the any-case tenant validator
  // (`assertValidTenantId` / `UUID_ANY_CASE_RE`, 400 INVALID_TENANT_ID) in the service.
  "PlatformTenantsController.updateStatus @Param('id')": 'tenant id: any-case tenant validator in the service',
  "PlatformTenantsController.reissueEnrolCode @Param('id')": 'tenant id: any-case tenant validator in the service',
  "PlatformTenantsController.replaceDevice @Param('id')": 'tenant id: any-case tenant validator in the service',
  "PlatformTenantsController.issueOwnerTempPassword @Param('id')": 'tenant id: any-case tenant validator in the service',
  "PlatformTenantsController.getTenantDetail @Param('id')": 'tenant id: any-case tenant validator in the service',
  "PlatformAuditController.listTenantAudit @Param('id')": 'tenant id: any-case tenant validator in the service',
  "TenantImportController.importSnapshot @Param('id')": 'tenant id: any-case tenant validator in the service',
  "TenantImportController.getImportJob @Param('id')": 'tenant id: any-case tenant validator in the service',
  // BullMQ assigns these, not `newUuid`; the lookup is `queue.getJob(id)`, never SQL.
  "BackupController.getJobStatus @Param('id')": 'BullMQ job id, looked up in Redis, never SQL',
  "BackupController.downloadExport @Param('id')": 'BullMQ job id, looked up in Redis, never SQL',
};

function controllerFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return controllerFiles(path);
    return path.endsWith('.controller.ts') ? [path] : [];
  });
}

interface IdParam {
  key: string;
  file: string;
  validated: boolean;
}

function idParams(): IdParam[] {
  const out: IdParam[] = [];
  for (const file of controllerFiles(SRC)) {
    const sf = ts.createSourceFile(file, readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
    const rel = relative(SRC, file).split(sep).join('/');
    const visit = (node: ts.Node): void => {
      if (ts.isClassDeclaration(node) && node.name) {
        for (const member of node.members) {
          if (!ts.isMethodDeclaration(member) || !member.body) continue;
          const body = member.body.getText(sf);
          for (const param of member.parameters) {
            for (const d of ts.getDecorators(param) ?? []) {
              const call = d.expression;
              if (!ts.isCallExpression(call)) continue;
              const decorator = call.expression.getText(sf);
              if (decorator !== 'Param' && decorator !== 'Query') continue;
              const [nameArg, ...pipes] = call.arguments;
              if (!nameArg || !ts.isStringLiteral(nameArg) || !ID_NAME.test(nameArg.text)) continue;
              const local = param.name.getText(sf);
              const piped = pipes.some((p) => /\bParseUuidPipe\b/.test(p.getText(sf)));
              const passed = VALIDATORS.some((v) =>
                new RegExp(`\\b${v}\\(\\s*${local}\\b`).test(body),
              );
              out.push({
                key: `${node.name.text}.${member.name.getText(sf)} @${decorator}('${nameArg.text}')`,
                file: rel,
                validated: piped || passed,
              });
            }
          }
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sf);
  }
  return out;
}

describe('controller id params are validated as UUIDs (#616)', () => {
  const params = idParams();

  it('finds the id params (the scan is not silently empty)', () => {
    expect(params.length).toBeGreaterThan(30);
  });

  it('every @Param/@Query id uses ParseUuidPipe or a parseUuid/requiredUuid/optionalUuid call', () => {
    const unvalidated = params
      .filter((p) => !p.validated && !(p.key in ALLOWLIST))
      .map((p) => `${p.file}: ${p.key}`);
    expect(unvalidated).toEqual([]);
  });

  it('every allowlist entry is still an unvalidated id param (no stale entries)', () => {
    const live = new Set(params.filter((p) => !p.validated).map((p) => p.key));
    expect(Object.keys(ALLOWLIST).filter((k) => !live.has(k))).toEqual([]);
  });
});
