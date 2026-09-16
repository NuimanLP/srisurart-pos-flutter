# #271 `fe.fonts` — bundle Sarabun/Barlow as local assets (2026-09-16)

**Branch:** `feat/271-fe-fonts-bundle-assets` · **Reassigned:** LomerAlloys → NuimanLP (see the
comment on #271 for why — an offline-testing session that day hit the exact symptom this ticket
exists to fix, live, and the project owner asked for it to be prioritized ahead of the lane
schedule).

## What the ticket asked for

- Move Sarabun (Thai) + Barlow from `google_fonts` runtime fetch to a bundled `pubspec.yaml`
  asset.
- `GoogleFonts.config.allowRuntimeFetching = false` in the app, not just tests.
- AC: network off → app opens, Thai renders, no request to `fonts.gstatic.com` /
  `fonts.googleapis.com`; `flutter test` has no pending timer from `google_fonts`.

## What was actually true (the scope surprise)

The ticket's "bundle Sarabun + Barlow" reads as one mechanism. It's two:

1. **`google_fonts`** — only ever called once, `GoogleFonts.sarabunTextTheme()` in
   `core/theme/app_theme.dart`. "Barlow" is never actually loaded on screen —
   `presentation/widgets/section_header.dart` only has a comment about a "Barlow Condensed
   feel," rendered with the ordinary theme heading style.
2. **`PdfGoogleFonts`** (a different package, `printing`/`pdf`) — genuinely used, but across
   **5** files, not the 1 (`quote_a4_view.dart`) a shallow read suggests:
   `returns_screen.dart` (credit-note), `receipt_view.dart`, `low_stock_alert.dart` (supplier
   order), `closing_report.dart`. Setting `GoogleFonts.config.allowRuntimeFetching = false`
   does nothing for this second mechanism — it has its own fetch path.

Fixing only the first would have left four PDF documents still fetching over the network while
offline, silently failing the actual motivation (flutter#163554 / the PWA offline shell) even
though it would have technically passed the AC as literally written.

## What shipped

- `frontend/assets/fonts/` — Sarabun-{Regular,Medium,SemiBold,Bold}.ttf,
  BarlowCondensed-Bold.ttf, plus each family's `OFL.txt` and a `SOURCES.txt` recording the exact
  `raw.githubusercontent.com/google/fonts` URLs + sha256 (same pattern as
  `web/WEB_DB_ASSET_VERSIONS.txt`).
  - Sarabun 400/500 cover Material 3's default `TextTheme` (verified against
    `typography.dart`'s `englishLike2021` — only those two weights appear).
  - Sarabun 600/700 + BarlowCondensed 700 cover the weights the PDF paths already called
    (`sarabunSemiBold`/`sarabunBold`/`barlowCondensedBold`). `sarabunMedium` is never called by
    any PDF path, confirmed by grepping all 5 files.
- `core/theme/app_theme.dart` — `GoogleFonts.sarabunTextTheme(...)` → plain
  `ThemeData(...).textTheme.apply(fontFamily: 'Sarabun')`. Verified equivalent against the
  `google_fonts` package source: `sarabunTextTheme` just does per-role `copyWith(fontFamily:
  ...)`, same as `.apply()`.
- `core/utils/pdf_fonts.dart` (new) — `PosPdfFonts`, a small `rootBundle`-backed loader with one
  cached `Future<pw.Font>` per weight, used by all 5 PDF call sites.
- `main.dart` — `GoogleFonts.config.allowRuntimeFetching = false` once, before `runApp`.
- `pubspec.yaml` — the `fonts:` declaration.

## Two rounds of scrutiny (this is the part worth reading before touching this code again)

A Sonnet implementer wrote the above; an Opus reviewer then ran an adversarial pass against the
real committed diff (not the implementer's self-report) — `dart analyze`, `flutter test`,
`flutter build web`, and reading the actual `google_fonts`/`printing`/Flutter engine source
rather than trusting claims. Four real findings, all fixed before merge:

1. 🔴 **AC1 is not fully met on the web target.** `flutter build web`'s JS still references
   `fonts.gstatic.com` — not from `google_fonts` (fully tree-shaken, confirmed absent), but from
   the **Flutter engine's own** fallback-glyph downloader (`FallbackFontDownloadQueue`), used
   for any character the bundled fonts don't cover — this app's UI has emoji in ~29 files. The
   web build's service worker also precaches nothing at all (a pre-existing gap, blocked on
   #266). Both are separate, real gaps from this ticket's actual mechanism — logged above in
   `CLAUDE.md`, not silently swept under "done."
2. 🔴 **A failed font load used to be impossible, now it isn't, and the failure was cached
   forever.** `PdfGoogleFonts`'s real implementation (`printing` package) never throws — it
   silently falls back to Helvetica on any fetch error. The new `PosPdfFonts` loader can throw
   (missing/corrupt bundled asset), and because `_field ??= _load(...)` assigns the *Future*
   synchronously, one transient failure would have permanently broken printing for the rest of
   the session. Fixed: each getter clears its cache field `onError` so a retry is possible.
   (Throwing instead of a silent Helvetica fallback is arguably the right call for Thai text —
   a font that can't show Thai glyphs at all is worse than an error — but that's a real
   behavior change from before, not a wash.)
3. 🔴 **Nothing protected the five asset keys from a typo or a lost `fonts:` block**, and the
   implementer's claimed "falsification" (comment out `fonts:`, get a red `flutter test`) does
   not actually hold — `flutter test` never loads pubspec-declared fonts at all (a pre-existing,
   unrelated comment in `test/checkout_credit_override_test.dart:141` already says so). Added
   `test/bundled_fonts_test.dart`: five `rootBundle.load()` assertions plus one check that
   `AppTheme.light`'s `TextTheme` actually resolves to the `Sarabun` family. This is the only
   thing that would catch a broken asset reference before it reaches a device.
4. 🔴 **A code comment claimed the opposite of what actually happens.** The first draft said
   bold Thai text "synthesizes bold from the nearest face, same as before." It doesn't — before,
   `google_fonts` gave every theme role its own single-face family, so any `.copyWith(fontWeight:
   FontWeight.bold)` call got synthetic (faux) bold; now `Sarabun` has real 600/700 faces
   bundled, so the same call renders genuine Sarabun Bold. This is a real visible change across
   every bold Thai label in the app (an improvement, but the next reader of that comment would
   have been told something false). Comment corrected in `app_theme.dart`.

Also recorded but not blocking: a cheaper alternative existed for the PDF half (`printing`'s own
`DownloadableFont.getFont` checks the asset manifest for a `google_fonts/<name>.ttf` path before
fetching — putting the TTFs there would have made all 12 old `PdfGoogleFonts.*()` call sites
offline-safe with zero code changes, keeping the Helvetica fallback too). Not reworked — the
explicit `PosPdfFonts` loader is more legible and doesn't depend on an undocumented magic path —
but worth knowing if this needs revisiting.

## Verified, not just claimed

- `dart analyze`: clean (run independently by the reviewer, not just the implementer).
- `flutter test`: all passing (run independently).
- `flutter build web --no-tree-shake-icons`: succeeds; `FontManifest.json` in the output lists
  all five bundled faces at the correct weights.
- Every font file's actual `OS/2 usWeightClass` was parsed from the binary and cross-checked
  against its `pubspec.yaml` `weight:` — all five match the filename.
- The two OFL license files are genuinely distinct license texts (not a copy-paste duplicate),
  diffed line by line.

## What's still open

- Web-target AC1 (engine gstatic fallback for emoji, SW precache) — tracked in `CLAUDE.md`
  above, not a new ticket by itself; folds into #266/#241's existing scope.
- `google_fonts` package dependency is kept (one call site, `main.dart`'s `.config` line) even
  though the reviewer confirmed it costs nothing in the built bundle (tree-shaken) and the line
  can no longer functionally fire — an owner call, not blocking.
