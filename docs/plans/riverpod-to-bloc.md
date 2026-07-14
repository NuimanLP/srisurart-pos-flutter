# Riverpod → flutter_bloc migration

**Status: Complete (2026-07-14).** All 12 steps executed; `dart analyze` clean;
122/122 tests passing; `flutter_riverpod` removed from `pubspec.yaml`. Manually
smoke-tested in a running browser session (theme/font-scale repaint, quote→checkout
hand-off, post-sale stock refresh) in addition to the automated suite.

Full replacement of Riverpod with flutter_bloc across the Srisurart POS Flutter app: DI, the
4 stateful controllers, and the 20 one-shot data loads. Approved 2026-07-14. Draft history /
rationale: `docs/plans/riverpod-to-bloc.draft.html` (two independent review passes applied).

## Scope

- 20 files under `lib/` + 3 test files import `flutter_riverpod` today.
- 13 repository DI providers (`Provider<Repository>`, all reading `databaseProvider`).
- 4 stateful `NotifierProvider`s: `CartNotifier`, `PendingQuoteNotifier`, `ThemeModeNotifier`,
  `FontScaleNotifier`.
- 20 `FutureProvider.autoDispose` one-shot loads.
- `app_router.dart` has no redirect/state coupling — confirmed twice, untouched by this migration.

## Decided policy: FutureProvider → FutureBuilder, not Cubit

Of the 20 loads, 15 call `ref.invalidate` after a write (customers, mechanics, quotes,
returns, purchase orders, cash drawer, plus checkout's 6); only 5 are truly one-shot
(`reports_screen.dart`, `vehicle_search_screen.dart`, checkout's `_categoriesProvider` /
`_catColorsProvider`, `closing_report.dart`). This looked like it needed a Cubit for the 15 —
it doesn't: every refetch is local to its own screen, and `app_router.dart`'s plain
`ShellRoute` means a screen already re-fetches on every visit regardless.

**Rule for every one of the 20 sites:** convert to `context.read<XRepository>().getX()` inside
a `FutureBuilder`, with the future created in `initState` (or an explicit `_refresh()` method
that calls `setState`) — **never created inline in `build`**. An inline future re-runs on every
rebuild, which is the actual failure mode to avoid (over-fetching, or a memoized future that
never refetches), not "loses invalidate."

No Cubit is required for any of the 20 sites by default. Exception: if checkout's 6 loads
(Step 9 below) turn out to share enough refresh logic to be worth centralizing, a
`CheckoutDataCubit` is a reasonable judgment call at that point — not a requirement.

## Coexistence strategy

`ProviderScope` and flutter_bloc's `RepositoryProvider`/`BlocProvider` are separate
`InheritedWidget`s with no conflict — both frameworks live in the widget tree simultaneously
for the whole migration. Root DI wiring goes in once; screens convert one at a time; only the
final step removes `flutter_riverpod` once nothing imports it.

## Two silent-coupling risks — the reason for this exact step order

Both are read/write pairs split across files where converting one side without the other
compiles clean, passes `dart analyze`, but breaks at runtime with no error — just a UI that
stops responding to a state that used to update it.

1. **Theme / font scale.** `app.dart` reads `themeModeProvider`/`fontScaleProvider`.
   `app_shell.dart:299` (toggle) and `settings_screen.dart:489,633,673` (🎨 ธีม tab pickers)
   write them. If the read side converts to Cubit before these three write call sites do, the
   toggle/picker keep persisting to `shared_preferences` but silently stop repainting the app.
2. **Pending quote hand-off.** `quotes_screen.dart:130` writes to `pendingQuoteForCartProvider`
   on quote-convert; `checkout_screen.dart:311,314,708` reads + `ref.listen`s it to prime the
   cart. Converting `quotes_screen.dart` before `checkout_screen.dart` makes the hand-off
   silently drop — empty cart, no error. This is the regression `quote_to_checkout_test.dart`
   exists to catch.

## Steps

### Phase 1 — foundation

**1. Add packages.**
`pubspec.yaml`: add `flutter_bloc`, `bloc`. `equatable` is already a dependency — no new
package needed for state classes. Do not remove `flutter_riverpod` yet.

**2. Repository DI tree.**
New `lib/presentation/repositories/repository_providers.dart` with 13 `RepositoryProvider`
entries mirroring today's `providers.dart` + `shift_providers.dart`. Wire
`MultiRepositoryProvider` in `main.dart` alongside (not instead of) the existing
`ProviderScope`.

**3. `ThemeModeCubit` + `FontScaleCubit` — reader and writers together.**
Direct ports of `ThemeModeNotifier`/`FontScaleNotifier` (same methods, same persistence keys
`sa_pos_theme`/`sa_pos_font_scale`). Wire via `MultiBlocProvider` at app root. In the same
pass, convert:
- `app.dart` — read side (`context.watch` instead of `ref.watch`)
- `app_shell.dart:299` — the toggle call site only
- `settings_screen.dart:489,633,673` — the appearance-tab picker call sites only

Do not convert the rest of `app_shell.dart`/`settings_screen.dart` here — their other repo
reads stay on Riverpod until their normal Phase 2 slot (Step 7 / Step 4 respectively).

**4. `PendingQuoteCubit` — state shape only.**
Direct port of `PendingQuoteNotifier`. Wire it in via `MultiBlocProvider`, but do **not**
convert its two call sites yet — that happens in Step 6, together.

### Phase 2 — convert consumers, screen by screen

**5. Convert 9 of the 11 screens' repository reads.**
Screens: all except `checkout_screen.dart` and `quotes_screen.dart`. Per screen (its own file
+ the sub-views it owns, per CONTRACT §5): swap `ref.watch(xRepoProvider)` →
`context.read<XRepository>()`, drop `Consumer(Stateful)Widget` where nothing else needs it,
and apply the FutureBuilder rule above to that screen's one-shot loads. These 9 screens are
independent of each other — parallelizable.

**6. `quotes_screen.dart` + `checkout_screen.dart`'s pending-quote side — together.**
Convert `quotes_screen.dart`'s write (`ref.read(pendingQuoteForCartProvider.notifier).set(qi)`
→ `context.read<PendingQuoteCubit>().set(qi)`) and `checkout_screen.dart`'s read/listen side in
the same pass. Do this as a solo pair, not split across the parallel batch in Step 5.

**7. Shared widgets outside the 1:1 screen model.**
`app_shell.dart` (remaining repo reads, e.g. `settingsRepoProvider.watchSettings()`) and
`closing_report.dart` (6-repo aggregate load — one-shot, apply the FutureBuilder rule). Do
these after the screens that embed them are otherwise converted.

**8. Mechanical snags found during review — handle inline wherever they're hit:**
- `settings_screen.dart:997` — `ref.invalidate(snapshotRepoProvider)` after backup restore.
  `snapshotRepoProvider` is a plain DI provider with no refetch semantics; just delete this
  call, it has no flutter_bloc equivalent to port.
- `mechanics_screen.dart:301` — passes `ref` into `_PayCreditDialog`'s constructor. Replace
  with explicit repository injection (pass the repository instance, not a context/ref).

**9. `CartCubit` — solo, last among conversions.**
`checkout_screen.dart`'s `CartNotifier` (lines 89–174) is self-contained: no `ref` usage, pure
synchronous mutations, every mutation creates a new `List` instance (so Cubit's `==`
emit-skip never suppresses a rebuild). Its validation methods (`add`, `setQty`, `setPrice`)
return a `String?` error alongside mutating state — this maps directly onto a Cubit method
(`emit` + `return` in the same call, no event indirection needed). Also convert this screen's
6 co-located data loads per the FutureBuilder rule (or a `CheckoutDataCubit` if refresh logic
across them ends up shared enough to justify it — a judgment call at implementation time, not
a requirement).

### Phase 3 — close out

**10. Rewrite CONTRACT.md.**
Six sections reference Riverpod, not just the provider table:
- §0.5 — dependency list (`flutter_riverpod` → `flutter_bloc`, `bloc`)
- §1 — folder layout comment (`providers.dart ← Riverpod providers (Contract — frozen)`)
- §3 — "exposed through a Riverpod provider (§4)"
- §4 — the provider table itself → Cubit/RepositoryProvider table
- §5 — "All screens are `ConsumerWidget` stubs"
- §11 — `theme_controller.dart` row: `NotifierProvider<ThemeModeNotifier,ThemeMode>`,
  `ref.read(...).toggle()`, and the coordination note telling `app.dart` to be a
  `ConsumerWidget`

**11. Update the 3 Riverpod-dependent tests.**
`route_smoke_test.dart`, `quote_to_checkout_test.dart`, `closing_report_layout_test.dart` —
replace `ProviderScope`/`ProviderContainer` overrides with `MultiRepositoryProvider`/
`MultiBlocProvider` test harnesses, keeping the same `NativeDatabase.memory()` seam. No
shared pump-widget helper exists today — each test builds its own container inline, so this
touches all 3 independently. Run `route_smoke_test.dart` last: it pumps all 11 screens under
one container, so it's the widest blast radius of the three and will catch anything the
screen-by-screen passes missed.

**12. Remove Riverpod, verify.**
Delete `providers.dart`, `shift_providers.dart`, and the old Notifier classes. Remove
`flutter_riverpod` from `pubspec.yaml` (confirmed: no transitive dependency requires it).
Run `dart analyze` (never `flutter analyze` — non-ASCII path constraint, see CLAUDE.md), then
`flutter test`, then a manual pass through all 11 screens.

## Files & parallelization

| Step | Files | Parallel? |
|---|---|---|
| 1–4 | `pubspec.yaml`, `repository_providers.dart`, `main.dart`, `app.dart`, `theme_controller.dart`, `font_scale_controller.dart`, `pending_quote_provider.dart` + just `app_shell.dart:299` and `settings_screen.dart:489,633,673` | Solo — foundation, blocks everything else |
| 5 | `lib/presentation/screens/*.dart` (all except `checkout_screen.dart`, `quotes_screen.dart`) + their owned sub-views | Parallel — one screen per pass |
| 6 | `quotes_screen.dart` + `checkout_screen.dart`'s pending-quote read/listen side | Solo pair — must land together |
| 7 | `app_shell.dart`, `closing_report.dart` | Solo — after their host screens |
| 8 | `settings_screen.dart:997`, `mechanics_screen.dart:301` | Fold into step 5's pass over those screens |
| 9 | `checkout_screen.dart` (CartCubit + 6 data loads) | Solo — most complex, do last |
| 10 | `CONTRACT.md` (§0.5, §1, §3, §4, §5, §11) | Solo — after code settles |
| 11 | `test/quote_to_checkout_test.dart`, `test/closing_report_layout_test.dart`, `test/route_smoke_test.dart` | Parallel with each other; run `route_smoke_test.dart` last |
| 12 | `pubspec.yaml` (remove flutter_riverpod), delete `providers.dart` + `shift_providers.dart` | Solo — final cutover |

## Verification

- `dart analyze` — not `flutter analyze` (non-ASCII path breaks the Flutter analyzer here).
- `flutter test`.
- Manual smoke test of all 11 screens, with particular attention to: theme/font-scale toggle
  actually repainting (Step 3 risk), quote-convert → checkout cart hand-off (Step 6 risk), and
  post-write data refresh on customers/mechanics/quotes/returns/purchase-orders/cash-drawer/
  checkout screens (the 15 `ref.invalidate` sites, now plain `setState`-driven refetch).
