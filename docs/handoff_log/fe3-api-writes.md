# #56 `fe.3` — ApiRepository writes (Checkout, Returns, Cash Drawer)

Branch `feat/fe3-api-writes`. Client-side money path against the server:
`ApiSalesRepository` / `ApiReturnsRepository` / `ApiShiftsRepository` in
`frontend/lib/data/repositories/api/`, plus the wire conventions they share in
`api_wire.dart`. Wiring is opt-in — `--dart-define=USE_API_WRITES=true`, default
off, because phase 1 plans no cutover.

**Read this before touching the sale path or picking up #55.**

| | |
|---|---|
| Branch | `feat/fe3-api-writes` — three commits, opened as a PR |
| Closes | **#82** (the write responses) · **#56** except its AC1, see below |
| Opened along the way | **#83** — `ServerErrorResolver`'s Thai test is too weak, three idempotency codes unmapped |
| Gate | frontend **199 tests**, `dart analyze` clean · server lint + typecheck clean, **97 unit**, **164 e2e** against the real Postgres |
| Not proven | #56 AC2's *"verified against the server"* — every client AC's evidence is a `MockClient`; `useApi` defaults to false, so no path here runs end to end yet |

⚠️ **#56 AC1 (*"git diff touches no file under `lib/presentation/screens/`"*) is broken
deliberately**, on the project owner's instruction. It and the server's
`overrideCreditLimit` contract could not both hold — see *The credit-limit override
inferred consent* below. Three screen files changed; the reasons are recorded per
file and on the issue.

---

## The two things that were wrong on the first pass

Both were found by review, not by tests, and both are the same mistake in
different clothes: **the client reconstructing something only the server or the
human owns.**

### 1. A lost reply became a second bill

`saveSale` minted the sale `id` and the `Idempotency-Key` *inside* the call. So:
`POST /sales` hangs, the counter sees `ขายไม่สำเร็จ…` and presses ยืนยัน again,
and the second press carried a **new** id and a **new** key — defeating both of
the server's defences at once (`existingSale` keys on the client's bill id,
`idempotency_keys` on the header). Two bills, two stock decrements, two receipt
numbers, for goods that left the shop once. The Drift build could not do this;
`ApiClient` sets no timeout, so it is the ordinary failure, not an exotic one.

Now both are minted **once per cart** and parked in `_unresolved` until the
server answers. A `SocketException` leaves the attempt parked (the bill's fate is
unknown — the reply was lost, not necessarily the write); an `ApiException` is a
verdict and closes it, so the next press is correctly a new bill. Three tests
pin this, including that a *different* cart never replays a parked attempt.

### 2. The credit-limit override inferred consent

🔴 The first implementation answered `409 CREDIT_LIMIT_EXCEEDED` by re-reading
the cached mechanic row, replaying `checkout_screen.dart:561`'s own
`creditBalance + total > creditLimit` test, and treating a trip as proof the
counter had answered `ยืนยันขายเครดิต?` — then resending with
`overrideCreditLimit: true`.

It is not proof. **The screen and the repository read different snapshots.** The
screen tests the `MechanicRow` captured when its list loaded
(`checkout_screen.dart:105`); the repository re-read the live Drift row — which
`_patchFromResponse` itself moves after every bill. Concretely: limit 10,000,
captured balance 0, live balance 9,900, cart 500. The screen shows **no dialog**
(`0 + 500 ≤ 10,000`); the server 409s; the old code re-read `9,900 + 500 >
10,000`, overrode, and the server wrote an `audit_log` row named
`sale.credit_limit_override` recording a confirmation **that never happened**.
The shop's own record of who let a bill past its limit was falsified by a cache
read.

`SaleInput` now carries `overrideCreditLimit` (default `false`) and the
repository only passes it through. **Consent is carried, never inferred.**

**Closed the same day.** `checkout_screen.dart` now sets the flag in the branch
where the counter tapped ยืนยัน, and passes it into `SaleInput`.
`test/checkout_credit_override_test.dart` drives the real dialog and pins both
directions — the wiring is three invisible lines, and without a test a refactor
either drops them (bills get refused) or defaults the flag to `true` to make them
go through, which is the original bug with a different author.

⚠️ This breaks #56 AC1 (*"git diff touches no file under
`lib/presentation/screens/`"*) **deliberately, on the project owner's
instruction.** That AC and the server's `overrideCreditLimit` contract could not
both hold: the server refuses an over-limit credit bill without the flag, nothing
but the screen knows whether a human confirmed, and the alternative — having the
repository work it out — is the bug above.

---

## What the server did not return — closed by #82

ADR-0010 §3: *"ถ้า field ไหนไม่อยู่ใน response ให้ถือว่า Drift แถวนั้น stale …
ห้ามคำนวณเองในเครื่อง"*. Four fields the server **wrote but did not hand back**
fell in that hole, so the client left them stale and said so at each site. That
is no longer true: **issue #82 widened both write responses and the client now
patches all four.** The "left stale on purpose" comments are gone with them.

| Was stale | Now carried by | Client patches |
|---|---|---|
| `sales.shiftId` — computed `sales.service.ts:155`, written, not returned | `CreateSaleResult.shiftId` | `Sales.shiftId`, the column #53 added |
| `movements` — written by `insertMovements`, not returned | `movements[]` on both results, via `RETURNING` | the local log, so the สต็อก log sees sales and returns again |
| `saleItems.costAtSale` | `items[] {lineNo, productId, costAtSale}` | joined on **`lineNo`**, not `productId` — one bill can carry the same product twice at different prices, which is a bug #22's review already had to fix once on the server |
| `mechanics.totalSales` / `totalDiscount` / `totalMarkup` | `mechanicAfter {id, totalSales, totalDiscount, totalMarkup, creditBalance}` | all four; `mechanicCreditBalanceAfter` kept so nothing reading it broke |

🔴 **`mechanics.total_credit` is still never written** — #11 settled it as the
legacy alias of `total_discount`.

🔴 **The replay path is where a widened response silently diverges.** Every new
field had to be added to `existingSale` too, or a retried bill answers null for a
shift it really has. The e2e compares the replay's **whole body** with `toEqual`
rather than field by field, and the check was falsified (forcing
`shiftId: null` in the replay branch reds it) rather than trusted. Array order is
pinned on both paths for the same reason: a replay agreeing on values but not
order is still a different body to the client. **Anything added to either result
from here must do all of this.**

Still open on the server: `POST /sales/:id/void` does not return its movements.
It answers `SaleWithItems`, the shape `GET /sales/:id` also returns, so adding
them means either widening a read shape or introducing a void-specific result —
a design call, not a freebie. Note a void writes `movements.type = 'void'`
(migration `1788652800003`), never `'return'`.

## Other live findings

- 🔴 **`REFUND_METHOD_NOT_ALLOWED` reaches the counter in English.**
  `returns.service.ts:178` builds `Refund method 'หักจากเครดิต' needs a bill with
  a mechanic.` — English with one Thai literal quoted inside. `ServerErrorResolver`
  prefers *any* message containing a Thai codepoint over its own canonical string
  (`server_error_resolver.dart:59-63`), so the mapped
  `วิธีคืนเงินไม่ถูกต้องสำหรับบิลนี้` never fires. Fix in #54 (require the message
  to *start* in Thai) or on the server (stop quoting Thai in an English message).
  The test now pins the string the counter actually sees, with the reason, so
  whichever fix lands trips it.
- 🔴 **The override resend's `Idempotency-Key`.** No longer exercised now that the
  flag is carried, but worth knowing: a same-key resend with a *changed* body works
  only because the claim rolls back with the refused transaction
  (`idempotency.interceptor.ts:72-77`). If a claim ever survives a refused request
  — **ADR-0003's `tx.3` is precisely that slice** — such a resend becomes
  `409 IDEMPOTENCY_KEY_REUSED`, which has no `ServerErrorResolver` entry and reaches
  the counter as `เกิดข้อผิดพลาด (IDEMPOTENCY_KEY_REUSED)`.
- **`openShift` leaves the previous shift half-archived locally.** The server
  archives it inside `POST /shifts/open` but answers with only the new shift, so
  `_patchShift` clears `isActive` on the old row without setting `closedAt` /
  `autoArchived` / `archivedAt`. `getShiftHistory` delegates to Drift, so the
  closing-report history shows the previous day as never archived. Nothing in
  `lib/presentation/` reads `autoArchived` today.
- **A drawer entry whose `shiftId` this cache has never seen is returned but not
  stored.** `DrawerEntries.shiftId` is a real FK (`tables.dart:292`) and
  `POST /shifts/current/entries` answers with a bare entry. The row is handed back
  to the screen and the local write is skipped rather than inserting an orphan or
  fabricating a parent. Cache staleness, not data loss — the entry is safe on the
  server.
- **`useApi` defaults to false, so no path here runs end-to-end.** Every AC's
  evidence is a `MockClient`. "Verified against the server" (#56 AC2) is **not**
  satisfied and needs an e2e once a demo tenant is reachable.
- **`ServerErrorResolver` gaps** newly reachable from this slice: no entry for
  `IDEMPOTENCY_KEY_INVALID` / `_REUSED` / `_IN_FLIGHT`, and `NO_OPEN_SHIFT` /
  `SALE_NOT_FOUND` / `SALE_VOIDED` are still English.

---

## Rules this slice establishes

- **`ApiRepository` never calls a Drift transactional service**, enforced at the
  source level by `test/api_repository_contract_test.dart`. Its first draft banned
  `db.transaction(` outright and red-flagged correct code — a local-only
  transaction *after* the response is how a header row and its FK-bearing lines
  avoid being half-written. The rule is now the one ADR-0010 §3 actually implies:
  no Drift transactional service, and **no transaction held open across the wire**.
- **An `ApiException` must never reach a screen.** Checkout, Returns and the Cash
  Drawer all render a failure as `e.toString().replaceFirst('Exception: ', '')`, so
  an escaping `ApiException` prints `ApiException(status: 409, code: …)` at the
  counter. `rethrowThai` (`api_wire.dart`) converts every server verdict to the
  plain `Exception(thaiMessage)` those screens already understand.
- **Money crosses the wire as the string `"1234.50"`** via `wireMoney`, rounded
  through integer satang. `toStringAsFixed` is a float formatting of a float and
  the server's `toSatang` refuses a third decimal.
- **`cash_drawer_screen.dart`'s `openShift` / `closeShift` now catch**, as
  `addDrawerEntry`'s call site always did. With Drift they could not fail; with
  `ApiShiftsRepository` a network error landed in an uncaught async handler and
  the counter saw *nothing* — the drawer silently stayed shut.
- 🔴 **`setState(() => _someFuture = …)` trips a Flutter assertion**, because the
  arrow body *returns* the Future and `setState` asserts its callback did not.
  Six sites had it (`checkout_screen` ×2, `quotes_screen`, `cash_drawer_screen`,
  `customers_screen`, `returns_screen`), all pre-existing and all invisible
  because the shop runs a release web build, where assertions are compiled out.
  The checkout one sits in the **failed-sale `catch`**, so every refused bill hit
  it in any debug build — which is how the new widget test found it. All six are
  now block bodies.
