# Client-side Flutter

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: `frontend/lib/presentation/`, UI zoom, web build checks, tenant-scoped cache, customer/mechanic pull, web DB assets.

**Client-side Flutter:**
- `setState(() { x = …; })`, never the arrow form, **when the assigned value is a
  `Future`** — the arrow form trips a Flutter assertion (compiled out in release builds,
  which is why it hid for a while).
- **Whole-screen zoom (#686):** `UiZoom` wraps the app in `MaterialApp.builder`. Code that needs the real
  window size must use `MediaQueryData.fromView(View.of(context))`; everything else uses `MediaQuery`
  (the zoomed logical screen). The route smoke test runs every screen at 3x on 1920x1080 and 2x on
  1366x768 — a new screen must pass both. The zoom card's Thai strings are `agent ร่าง` (owner to ratify).
- **Look at the built web app, not only the tests (#693, 2026-10-12):** three layout bugs passed 1848 tests and were only
  seen by eye (a `Container(alignment:)` inside a `Wrap` fills the whole row — wrap it in `IntrinsicWidth`). For a local
  look: `flutter build web --no-tree-shake-icons --no-web-resources-cdn` (CanvasKit from gstatic is blocked in the app's
  browser pane), serve `build/web`, and unregister the service worker + clear caches before re-checking a rebuild — `sw.js`
  otherwise serves the previous build.
- **Local cache is tenant-scoped (API build, #539):** `AppMeta tenant_id` + `TenantCacheGuard`;
  a switch resets via `resetTenantCache`/`resetPulledCache` and is **refused with unsent work**
  (`TENANT_SWITCH_UNSENT_WORK`, `ENROL_UNSENT_WORK`). `cacheGeneration` fences late pulls/seeds, and
  `ApiClient` has a session generation so a stale refresh/401/token never acts for the next user
  (#534/#536). Replies to in-flight online writes are not fenced (accepted limit).
- **Customer/mechanic pull keeps local totals under unsent money ops** (`outbox_ledger_refs.dart`): rows referenced by `sale.create`/`sale.void_offline`/`return.create`/`credit_payment.create` (any status) or a queued credit payment keep `points`/`totalSpend` / `creditBalance`/`totalSales`/`totalDiscount`/`totalMarkup`; the guard is recomputed per page inside the write txn and the saved cursor never passes a protected row. A new money-op type must be added to `_moneyOps`.

## Web DB assets (from the migration-status section)

**Web DB:** needs `web/sqlite3.wasm` + `web/drift_worker.js` matching the pub-locked
`sqlite3`/`drift` versions (`frontend/web/WEB_DB_ASSET_VERSIONS.txt`); CI fails the build
on any skew. 🔴 **Bumping `drift` or `sqlite3` → re-download both assets from the
matching GitHub release tags and update the version file** — a skew changes SQLite-core
or worker-cancellation behaviour, it isn't cosmetic. 🔴 **#266** (browsers without
`dedicatedWorkersInSharedWorkers` hit a `LinkError` on `xFileControl` in drift's
non-OPFS fallback): a fix (stub `xFileControl` → `SQLITE_NOTFOUND`) merged 2026-09-17
by `LomerAlloys` (`docs/handoff_log/ticket-266-web-db-linkerror.md`, PR #310), and the
GitHub issue was closed 2026-09-19 (verified 2026-09-23) — #241 (PWA precache manifest)
is no longer blocked on it.
