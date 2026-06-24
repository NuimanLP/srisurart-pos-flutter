# 0001 — Course bootstrap: project-onboarding mission

**Date:** 2026-06-24
**Status:** active

## Context
First session. Learner (NuiGates, project owner/dev) asked to understand "what this project is all
about," how a dev configures "what the code does each sector," styled after `cookies-101.html`,
output as HTML. They authorised up to 5 research agents.

## What I did
- Ran 4 parallel Explore agents to map the codebase: lib architecture, data layer + CONTRACT.md,
  build/config/run, and the presentation layer. Read the cookies-101 design system directly.
- Stood up the teaching workspace under `teaching/` (MISSION, NOTES, RESOURCES, assets, lessons,
  reference, learning-records).
- Extracted the cookies-101 design language into a reusable `assets/course.css` (+ `course.js`)
  so every lesson is one consistent course, not a pile of one-offs.
- Built 3 lessons + index + 2 reference docs (glossary, cheat-sheet).

## Lessons produced
1. `0001-what-is-this-project.html` — the one-paragraph pitch, why the stack, offline-first, 3 golden rules.
2. `0002-the-four-sectors.html` — core/data/domain/presentation, data flow, "screens never touch AppDatabase".
3. `0003-configure-and-run.html` — theme, routes, Drift schema/codegen, web-DB assets, build commands.

## Calibration (zone of proximal development)
- Learner is the project owner → already fluent in Flutter/Dart generally; the gap is *this
  codebase's* structure and conventions, not the language. So lessons lead with "where does X live
  / what do I touch," not language basics.
- Content is in Thai (UI is Thai-first; learner bilingual), code/identifiers in EN.

## Open threads / likely next lessons
- Deep-dive a single repository line-by-line (candidate: `SalesRepository.saveSale`).
- Write-a-new-screen end-to-end (provider → repo → widget).
- Phase 7 Supabase sync design; font bundling; re-capturing tutorial screenshots.

## Notes to revise later
- If the learner says the Thai-heavy framing is too much, switch lesson prose to EN-primary
  (keep Thai UI strings verbatim per parity rule).
