# Writing brief — Progress report (รายงานความก้าวหน้าโครงงาน 240-401) for this repo

Repo (read-only for you): D:\Beestation\Sri_POS\Flutter\.claude\worktrees\local-dashboard-setup-69c103
Output dir: C:\Users\nuima\AppData\Local\Temp\claude\D--Beestation-Sri-POS-Flutter--claude-worktrees-local-dashboard-setup-69c103\94761891-6a20-45b0-8a9b-af3b7fee243c\scratchpad\chapters\
Today: 2026-10-01 (พ.ศ. 2569). Read the repo's CLAUDE.md first — it is the most up-to-date status.

## What this is
A Thai university Computer Engineering project progress report (PSU, course 240-401), Word template
style: Heading1 = chapter (auto "บทที่ N"), Heading2 = N.M, Heading3 = N.M.K, body TH Sarabun New 16pt.
A senior's example was 28 pages and thin. Ours is a much bigger project (Flutter offline-first POS →
multi-tenant NestJS backend + CI/CD + phase-2 offline sync), so the report is long: target ~70 pages total.

Project title: ระบบขายหน้าร้านอะไหล่รถยนต์แบบหลายร้านค้าที่ทำงานออฟไลน์ได้ /
Srisurart Autopart POS: An Offline-First Multi-Tenant Point-of-Sale System.
Team (lanes): Chavatik Thorarit (NuimanLP, team/1), LomerAlloys (team/2), Pattarapon Kitcharoen (team/3).

## Rules (karpathy-guidelines: no guessing, verify)
- Write in formal academic Thai (ภาษาเขียนทางวิชาการ), technical terms in English where natural.
  First use of an acronym: full English term then (ABBR). Collect every acronym you use.
- EVERY number, date, count, PR/issue number, and "done/not done" claim must be verified against the
  repo (files, `git log`, tests, docs/handoff_log, CLAUDE.md). `gh` CLI is available for issue/PR state.
  If you cannot verify, leave it out. Never claim open work is done (#344 demo, #380 k6, #363 offsite
  backup, #476, #231 are OPEN). Prefer current state in CLAUDE.md over older docs.
- No marketing tone, no filler. Explain *why* decisions were made (ADRs in docs/Backend_design/adr/).
- Do not copy long passages from docs verbatim; synthesize.
- Do NOT edit or commit anything in the repo. Only write your output file.

## Output format (strict — a script converts it to docx)
```
# <chapter title only, no "บทที่ N">
## <section title, no number>
### <subsection title, no number>
Paragraph text (one paragraph per line; blank line between paragraphs).
- bullet item
1. numbered item
TABLE: <caption without "ตารางที่ N">
| col | col |
|---|---|
| a | b |
FIGURE: <caption without "รูปที่ N"> | <source>
```
- `<source>` is either a repo-relative image path that EXISTS (e.g. docs/tutorial/sri-pos-manual/img/checkout.png)
  or `diagram:<slug>` — then append a spec at the very end of your file:
  ```
  ```diagram slug=<slug>
  <precise description: boxes, labels (Thai/English), arrows, grouping — enough for someone to draw it>
  ```
  ```
- Inline code/identifiers: wrap in backticks. Bold: **x**. Citations: [n] with a local reference list.
- Refer to figures/tables in text as "ดังรูปที่ {fig:<slug>}" / "ดังตารางที่ {tab:<slug>}" and give each
  FIGURE/TABLE an id by ending the caption with ` {#fig:<slug>}` or ` {#tab:<slug>}`.
- At the end of the file, after diagram specs, add:
  - `## __ABBREVIATIONS__` then lines `ABBR = Full term`
  - `## __REFERENCES__` then lines `[n] IEEE-style reference` (official docs/papers/books with URLs and
    "Accessed: Oct. 1, 2026."). Only real, well-known URLs (official docs). Number locally from [1].
  - `## __FACTS__` then lines `claim -> source (file:line, command, or URL)` for every number/status claim.
    This ledger is used for fact-checking and is stripped from the report.
</content>
</invoke>
