import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { HttpStatus } from '@nestjs/common';
import ts from 'typescript';
import { describe, expect, it } from 'vitest';

const SRC = join(fileURLToPath(new URL('.', import.meta.url)), '..');

/**
 * tx.3 (#152): idempotency is no longer a decorator a reader can check by eye, so this scan
 * checks what `@UseInterceptors(IdempotencyInterceptor)` used to make obvious.
 *
 *   1. **Which routes are idempotent** — pinned below, so a route that silently loses its
 *      claim fails here instead of double-charging.
 *   2. **The claim comes first.** The handler's whole body is `return this.idempotency
 *      .runIdempotent(idempotencyParamsOf(req, …), res, …)` — or tx.2's `runTx` wrapper around
 *      a private `*In` whose whole body is — so nothing reads or locks before the claim.
 *   3. **The stored success status is the one the route sends.** The interceptor read it from
 *      `@HttpCode`; now each call site passes it, and a typo would replay a 201 for a 200.
 *   4. **`@Res({ passthrough: true })`.** A plain `@Res()` hands the response to the handler,
 *      which never sends it — the request would hang.
 */
const ROUTE_DECORATORS = new Set(['Get', 'Post', 'Put', 'Patch', 'Delete']);
const CLAIM =
  /^\{\s*return this\.idempotency\.runIdempotent\(\s*idempotencyParamsOf\(req,\s*([^)]+?)\s*\),\s*res,/;
const WRAPPER =
  /^\{\s*return this\.tenants\.runTx\(\(\) =>\s*this\.(\w+In)\([^)]*\),?\s*\);\s*\}$/;

/**
 * The one exception to rule 2, as a whole-body shape rather than a loosened rule: tx.5 (#154)
 * checks the manager PIN BEFORE the void's claim, because argon2 inside the claim's
 * transaction held a pooled connection for ~75 ms per void. The key is still read first (a
 * bad key stays a 400), the PIN check reads nothing about the bill, and the claim is still the
 * first statement of the only transaction that touches it. A route matching this shape is
 * reported with ` (PIN pre-check)`, and the pinned list below allows it for
 * `SalesController.voidSale` alone.
 */
const PIN_PRECHECK =
  /^\{\s*const params = idempotencyParamsOf\(req,\s*([^)]+?)\s*\);\s*const authorised = await this\.voids\.authorise\(id, voidActorOf\(req, body\)\);\s*return this\.idempotency\.runIdempotent\(params, res, \(\) =>\s*this\.voids\.void\(id, authorised\),?\s*\);\s*\}$/;

interface Route {
  route: string;
  successCode: number | 'no claim first';
  precheck: boolean;
  declared: number;
  passthrough: boolean;
}

function decoratorsOf(node: ts.Node, sf: ts.SourceFile) {
  return (ts.canHaveDecorators(node) ? (ts.getDecorators(node) ?? []) : [])
    .map((d) => d.expression)
    .filter(ts.isCallExpression)
    .map((call) => ({
      name: call.expression.getText(sf),
      arg: call.arguments[0]?.getText(sf),
    }));
}

function statusOf(text: string): number {
  const m = /^HttpStatus\.(\w+)$/.exec(text);
  const value = m ? HttpStatus[m[1] as keyof typeof HttpStatus] : Number(text);
  if (!Number.isInteger(value)) throw new Error(`unreadable status: ${text}`);
  return value;
}

function idempotentRoutes(
  source: string,
  file = 'x.ts',
): Record<string, Route> {
  const sf = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const out: Record<string, Route> = {};
  const visit = (node: ts.Node): void => {
    if (ts.isClassDeclaration(node) && node.name) {
      const controller = decoratorsOf(node, sf).find(
        (d) => d.name === 'Controller',
      );
      const methods = node.members.filter(ts.isMethodDeclaration);
      const bodyOf = (name: string) =>
        methods.find((m) => m.name.getText(sf) === name)?.body?.getText(sf) ??
        '';
      for (const m of methods) {
        const decorators = decoratorsOf(m, sf);
        const verb = decorators.find((d) => ROUTE_DECORATORS.has(d.name));
        if (!controller || !verb) continue;
        const body = m.body?.getText(sf) ?? '';
        const inner = WRAPPER.exec(body)?.[1];
        const precheck = inner ? null : PIN_PRECHECK.exec(body);
        const claimed = precheck ?? CLAIM.exec(inner ? bodyOf(inner) : body);
        const mentions = (inner ? bodyOf(inner) : body).includes(
          'idempotencyParamsOf',
        );
        if (!claimed && !mentions) continue;
        const httpCode = decorators.find((d) => d.name === 'HttpCode');
        const resArg = m.parameters
          .flatMap((p) => decoratorsOf(p, sf))
          .find((d) => d.name === 'Res')?.arg;
        const path = [controller.arg, verb.arg]
          .filter(Boolean)
          .map((p) => p!.replace(/^'|'$/g, ''))
          .join('/');
        out[`${node.name.text}.${m.name.getText(sf)}`] = {
          route: `${verb.name.toUpperCase()} /${path}`,
          successCode: claimed ? statusOf(claimed[1]) : 'no claim first',
          precheck: precheck !== null,
          declared: httpCode
            ? statusOf(httpCode.arg!)
            : verb.name === 'Post'
              ? 201
              : 200,
          passthrough: /passthrough:\s*true/.test(resArg ?? ''),
        };
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(sf);
  return out;
}

function controllerFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return controllerFiles(path);
    return /\.controllers?\.ts$/.test(path) ? [path] : [];
  });
}

describe('idempotent routes claim first, with the status they send (tx.3 #152)', () => {
  it('reads the claim, the wrapper shape and the declared status', () => {
    const src = `
      @Controller('things')
      class C {
        @Post()
        create(@Req() req, @Res({ passthrough: true }) res) {
          return this.idempotency.runIdempotent(idempotencyParamsOf(req, 201), res, () => 1);
        }
        @Post(':id/accept')
        @HttpCode(HttpStatus.ACCEPTED)
        accept(@Req() req, @Res({ passthrough: true }) res) {
          return this.tenants.runTx(() => this.acceptIn(req, res));
        }
        private acceptIn(req, res) {
          return this.idempotency.runIdempotent(idempotencyParamsOf(req, 201), res, () => 1);
        }
        @Delete(':id')
        late(@Req() req, @Res() res) {
          const x = this.read();
          return this.idempotency.runIdempotent(idempotencyParamsOf(req, 200), res, () => x);
        }
        @Get()
        list() { return []; }
        @Post(':id/void')
        @HttpCode(200)
        async pinFirst(@Req() req, @Res({ passthrough: true }) res) {
          const params = idempotencyParamsOf(req, 200);
          const authorised = await this.voids.authorise(id, voidActorOf(req, body));
          return this.idempotency.runIdempotent(params, res, () =>
            this.voids.void(id, authorised),
          );
        }
        @Post(':id/void2')
        @HttpCode(200)
        async pinFirstAndARead(@Req() req, @Res({ passthrough: true }) res) {
          const params = idempotencyParamsOf(req, 200);
          const authorised = await this.voids.authorise(id, voidActorOf(req, body));
          const sale = await this.reads.byId(id);
          return this.idempotency.runIdempotent(params, res, () =>
            this.voids.void(id, authorised),
          );
        }
      }`;
    expect(idempotentRoutes(src)).toEqual({
      'C.create': {
        route: 'POST /things',
        successCode: 201,
        precheck: false,
        declared: 201,
        passthrough: true,
      },
      'C.accept': {
        route: 'POST /things/:id/accept',
        successCode: 201,
        precheck: false,
        declared: 202,
        passthrough: true,
      },
      'C.late': {
        route: 'DELETE /things/:id',
        successCode: 'no claim first',
        precheck: false,
        declared: 200,
        passthrough: false,
      },
      // The tx.5 shape is recognised, and flagged as a pre-check…
      'C.pinFirst': {
        route: 'POST /things/:id/void',
        successCode: 200,
        precheck: true,
        declared: 200,
        passthrough: true,
      },
      // …and one more statement between the PIN check and the claim is not that shape.
      'C.pinFirstAndARead': {
        route: 'POST /things/:id/void2',
        successCode: 'no claim first',
        precheck: false,
        declared: 200,
        passthrough: true,
      },
    });
  });

  it('every idempotent route claims first and stores the status it declares', () => {
    const found: Record<string, Route> = {};
    for (const path of controllerFiles(SRC)) {
      Object.assign(found, idempotentRoutes(readFileSync(path, 'utf8'), path));
    }
    const summary = Object.fromEntries(
      Object.entries(found).map(([name, r]) => [
        name,
        `${r.route} ${r.successCode}${r.successCode === r.declared ? '' : ` (declares ${r.declared})`}${r.passthrough ? '' : ' (no @Res passthrough)'}${r.precheck ? ' (PIN pre-check)' : ''}`,
      ]),
    );
    // The 38 routes that carried `@UseInterceptors(IdempotencyInterceptor)` before tx.3.
    // 37 are live: `PurchasingController` is registered in no module (dead code, follow-up).
    expect(summary).toEqual({
      'CustomersController.create': 'POST /customers 201',
      'CustomersController.update': 'PATCH /customers/:id 200',
      'CustomersController.delete': 'DELETE /customers/:id 200',
      'DevicesController.create': 'POST /devices 201',
      'DevicesController.retire': 'POST /devices/:id/retire 200',
      'MechanicsController.create': 'POST /mechanics 201',
      'MechanicsController.update': 'PATCH /mechanics/:id 200',
      'MechanicsController.creditPayment':
        'POST /mechanics/:id/credit-payments 201',
      'MechanicsController.delete': 'DELETE /mechanics/:id 200',
      'ParkedSalesController.park': 'POST /parked-sales 201',
      'ParkedSalesController.remove': 'DELETE /parked-sales/:id 200',
      'CategoriesController.create': 'POST /categories 201',
      'CategoriesController.delete': 'DELETE /categories/:name 200',
      'SuppliersController.create': 'POST /suppliers 201',
      'SuppliersController.update': 'PATCH /suppliers/:id 200',
      'SuppliersController.delete': 'DELETE /suppliers/:id 200',
      'ProductsController.create': 'POST /products 201',
      'ProductsController.update': 'PATCH /products/:id 200',
      'ProductsController.delete': 'DELETE /products/:id 200',
      'ProductsController.adjustStock': 'POST /products/:id/adjust-stock 201',
      'PurchaseOrdersController.create': 'POST /purchase-orders 201',
      'PurchaseOrdersController.receive':
        'POST /purchase-orders/:id/receive 200',
      'PurchaseOrdersController.cancel': 'POST /purchase-orders/:id/cancel 200',
      'PurchaseOrdersController.delete': 'DELETE /purchase-orders/:id 200',
      'PurchasingController.receive': 'POST /purchase-orders/:id/receive 201',
      'QuotesController.purgeQuotes': 'POST /quotes/purge 202',
      'QuotesController.create': 'POST /quotes 201',
      'QuotesController.update': 'PATCH /quotes/:id 200',
      'QuotesController.delete': 'DELETE /quotes/:id 200',
      'QuotesController.duplicate': 'POST /quotes/:id/duplicate 201',
      'QuotesController.convert': 'POST /quotes/:id/convert 201',
      'ReturnsController.create': 'POST /returns 201',
      'ReviewItemsController.markReviewed':
        'POST /review-items/:id/reviewed 200',
      'SalesController.create': 'POST /sales 201',
      'SalesController.voidSale': 'POST /sales/:id/void 200',
      'SettingsController.updateSettings': 'PATCH /settings 200',
      'ShiftsController.open': 'POST /shifts/open 200',
      'ShiftsController.close': 'POST /shifts/close 200',
      'ShiftsController.addEntry': 'POST /shifts/current/entries 201',
      'SyncController.discard': 'POST /sync/discards 200',
    });
  });

  it('POST /sync/push idempotency coverage: maps each op type to an online endpoint and declared status (08 §8, slice 20-s)', () => {
    // SyncController.push is the bulk ingestion entrypoint for offline outbox ops.
    // Idempotency is not claimed at the batch HTTP request level, but per-op inside SyncService
    // using the exact online endpoint and success status code (08 §8.3 step 1).
    const syncSrc = readFileSync(join(SRC, 'sync/sync.service.ts'), 'utf8');
    const opMappings: Record<string, { endpointPrefix: string; successCode: number }> = {
      'sale.create': { endpointPrefix: 'POST /sales', successCode: 201 },
      'return.create': { endpointPrefix: 'POST /returns', successCode: 201 },
      'shift.open': { endpointPrefix: 'POST /shifts/open', successCode: 200 },
      'drawer.entry': { endpointPrefix: 'POST /shifts/current/entries', successCode: 201 },
      'credit_payment.create': {
        endpointPrefix: 'POST /mechanics/',
        successCode: 201,
      },
      'customer.create': { endpointPrefix: 'POST /customers', successCode: 201 },
      'customer.update': { endpointPrefix: 'PATCH /customers/', successCode: 200 },
      'sale.void_offline': {
        endpointPrefix: 'POST /sales/',
        successCode: 200,
      },
    };

    // Every mapped op type must correspond to an idempotent write route in the pinned summary
    const found: Record<string, Route> = {};
    for (const path of controllerFiles(SRC)) {
      Object.assign(found, idempotentRoutes(readFileSync(path, 'utf8'), path));
    }
    const pinnedRoutes = Object.values(found).map((r) => `${r.route} ${r.declared}`);

    for (const [opType, target] of Object.entries(opMappings)) {
      const matchesPinned = pinnedRoutes.some((r) =>
        r.startsWith(target.endpointPrefix) && r.endsWith(` ${target.successCode}`),
      );
      expect(
        matchesPinned,
        `Op ${opType} (prefix: ${target.endpointPrefix}, status: ${target.successCode}) must match a pinned idempotent route`,
      ).toBe(true);

      // Verify that sync.service.ts actually routes this op
      expect(syncSrc).toContain(`case '${opType}':`);
    }

    // Verify claim and complete calls are present in SyncService
    expect(syncSrc).toContain('this.idempotency.claim(manager');
    expect(syncSrc).toContain('this.idempotency.complete(manager');
  });
});

