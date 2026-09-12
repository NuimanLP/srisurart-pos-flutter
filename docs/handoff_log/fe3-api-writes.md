# #56 `fe.3` — ApiRepository writes (Checkout, Returns, Cash Drawer)

Branch `feat/fe3-api-writes`. Client-side money path against the server:
`ApiSalesRepository` / `ApiReturnsRepository` / `ApiShiftsRepository` in
`frontend/lib/data/repositories/api/`, plus the wire conventions they share in
`api_wire.dart`. Wiring is opt-in — `--dart-define=USE_API_WRITES=true`, default
off, because phase 1 plans no cutover.

**Read this before touching the sale path or picking up #55.**

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

🔴 **Follow-up owed:** nothing sets it yet, so an over-limit credit sale is
refused with `เกินวงเงินเครดิต` even when the counter confirmed. The fix is one
line in `checkout_screen.dart` — the dialog's `if (ok != true) return` at `:581`
already *is* the consent signal, so pass `overrideCreditLimit: true` below it.
It was left undone here because #56 AC1 forbids touching
`lib/presentation/screens/`. That AC and the server's override contract are in
direct conflict; someone has to decide which gives.

---

## What the server does not return (client left it stale, on purpose)

ADR-0010 §3: *"ถ้า field ไหนไม่อยู่ใน response ให้ถือว่า Drift แถวนั้น stale …
ห้ามคำนวณเองในเครื่อง"*. Four fields fall in that hole. **None of them is a
client bug and none should be fixed on the client** — each is one line of server
work. The ADR's §3 table now records them.

| Gap | Server | Visible effect with `USE_API_WRITES=true` |
|---|---|---|
| `sales.shiftId` | computed at `sales.service.ts:155`, written at `:160`, **not in `CreateSaleResult`** (`:211-225`) | schema v3's new column is null on every bill. #56's *"the bill carries `shiftId`"* is **unreachable from client code**. Also add `shift_id` to `existingSale`'s SELECT. No screen reads it today, so this is latent. |
| `movements` | rows written by `insertMovements` (`:170`), not returned | the "สต็อก log" (`products_screen.dart:2660`) shows PO receipts and adjustments but **no sales and no returns** — a visible regression against the Drift build |
| `saleItems.costAtSale` | server has it from its locked read in `insertLines` | every API-written bill is "estimated" forever — `products_screen.dart:2854` falls back to today's cost, `settings_screen.dart:1887` labels the row `ต้นทุนปัจจุบัน`. This is exactly what ADR-0008 exists to prevent. |
| `mechanics.totalSales` / `totalDiscount` / `totalMarkup` | all three moved by `applyMechanic` (`:320-344`); only `mechanicCreditBalanceAfter` comes back | the mechanics screen shows figures frozen at the last Drift-era write |

Synthesising any of them locally is the second set of invariants ADR-0010 §3
bans, so the code writes nothing and says so at each site.

---

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
- 🔴 **`cash_drawer_screen.dart` has no `try/catch` around `openShift` /
  `closeShift`** (`:147-161`, `:184-197`) — only `addDrawerEntry`'s call site
  catches. With Drift they cannot fail; with the API they can, and the error lands
  in an uncaught async handler. Not fixed here (AC1). Same decision as the
  credit-limit flag: it needs one screen edit.
