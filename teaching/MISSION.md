# Mission

**Learner:** NuiGates (project owner / developer on the Srisurart Autopart POS).

**What they want to learn:** A complete mental model of the *Srisurart Autopart POS (Flutter)*
codebase — what the project *is*, what each code **sector** (layer) does, and **how to configure
and run** every part of it. Audience framing: "teach the dev."

**Why (the grounding):** This is an offline-first Flutter port of a Thai auto-parts shop POS
(migrated from a React + localStorage app). The owner needs to be able to onboard themselves or a
new developer fast — to know where each responsibility lives, which knobs to turn, and the rules
that keep the data layer faithful to the legacy `pos/db.js`. Without this map, changes risk
breaking transactional invariants (stock, points, credit) or the non-ASCII-path codegen rule.

**Definition of done for the mission:**
- Can explain the project in one paragraph to a stranger.
- Can name the 4 sectors and say what each owns + how data flows between them.
- Can configure: brand theme, routes/nav, the Drift DB + seed, the web-DB assets, and run/build
  the app — knowing which commands are safe on a non-ASCII path.

**Output format:** Beautiful, self-contained HTML lessons, styled after the reference document
`cookies-101.html` (warm paper / caramel, Fraunces + IBM Plex Sans Thai + JetBrains Mono,
section-numbered editorial layout).

**Constraints / notes:**
- Work only in the `Sri_POS/Flutter` repo (see machine memory). Teaching files live under
  `teaching/` so they don't pollute `lib/`.
- Lessons are reference-grade: the dev will return to them while editing code.
