# Resources

## In-repo (primary, high-trust — the source of truth)
- `CLAUDE.md` — project knowledge base: build-path constraint, commands, architecture, status.
- `CONTRACT.md` — the binding spec: 20 tables, repo signatures, providers, routes,
  screen→sub-view ownership, Thai-string & money rules. **Read first before editing.**
- `lib/data/db/tables.dart` / `database.dart` — Drift schema + seed (behavioural source of truth,
  ported from legacy `pos/db.js`).
- `lib/core/` — router, theme, utils (the configurable "knobs").
- `lib/presentation/` — 11 screens, providers, shared widget kit.

## External (framework docs — for grounding claims)
- Drift (SQLite ORM + codegen): https://drift.simonbinder.eu/ — tables, transactions, web/WASM.
- Riverpod (state/DI): https://riverpod.dev/ — Provider, ConsumerWidget, ref.watch/read/invalidate.
- go_router (routing): https://pub.dev/packages/go_router — ShellRoute pattern.
- google_fonts: https://pub.dev/packages/google_fonts — runtime fetch vs bundling.
- drift / sqlite3 release assets (web DB): https://github.com/simolus3/drift/releases ·
  https://github.com/simolus3/sqlite3.dart/releases

## Styling reference
- `…/Kittasil/01_Summary/cookies-101.html` — the visual design language for these lessons.

## Community (to acquire wisdom / test understanding)
- r/FlutterDev and the Flutter Discord — architecture & Riverpod questions.
- Drift GitHub Discussions (simolus3/drift) — codegen / web-DB issues.
