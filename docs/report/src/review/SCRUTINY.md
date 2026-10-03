# SCRUTINY — progress report draft (ch1–ch5), length/overlap pass

Scope: the six chapter files as they stood before this pass (backup: `chapters_orig/`).
Goal stated in one line: cut ~30% of body text (132 → ~85–95 pages) without losing evidence,
honest "still open" statements, or diagram specs. Body = text before `## __ABBREVIATIONS__`,
diagram blocks excluded: **179,185 chars** before.

## 1. Simpler alternative (the main call)

Sentence-level trimming would not reach 30%. Four structural duplications account for most of
the excess, so the fix is to delete whole passages, not to compress prose:

1. **ch2 is ~40% project implementation**, repeated in ch3 (lock order, `runTx`, #162, NFC
   fallback, metric names, `.current_sha`, Ansible users, gitleaks allowlist, compose service
   list, `cashCountFrom`, `planReturn`, `.env` volume secrets). Template: ch2 = theory.
   → ch2 keeps the concept + one "ในโครงงาน…" pointer; the implementation lives in ch3.
2. **ch4a/ch4b re-explain the design before giving evidence** (invariants, the 7 API-layer
   rules, outbox architecture, RLS mechanics, the seam rules, lock order, metrics rules, CI
   job lists). Template: ch4 = what was achieved, with evidence. → ch4 points to ch3 and keeps
   tables, test files, SHAs, measurements.
3. **21 screenshots in ch4a + 2 in ch4b (23)**. Several show the same screen twice (checkout
   desktop/mobile/payment; drawer closed/open; devices/enrol; quotes list/A4; returns/CN), one
   shows a bug fixed later (vehicle search). → 14 kept.
4. **Three overlapping timelines** (ch1 bullet timeline + Gantt, ch4a `tab:migration`,
   ch4a `tab:clientmilestones`). → ch1 keeps Gantt + short paragraph, ch4a keeps
   `tab:migration` (commit evidence), `tab:clientmilestones` dropped (every row already sits
   in `tab:migration`, `tab:fe` or `tab:phase2`).

## 2. One home per idea (occurrences → home)

| Idea | Was in | Home now | Rationale |
|---|---|---|---|
| RLS / `tenant_isolation` / `pos_app` / FORCE / NULLIF | ch1, ch2, ch3, ch4b | concept ch2, mechanism ch3, proof ch4b | each chapter adds a different layer |
| `runTx`, no 2nd pool connection, 25 s ceiling, PIN outside tx | ch2, ch3, ch4b, ch5 | rule ch3; measurement ch4b; #162 incident ch5 | |
| Idempotency rules (concrete-path fingerprint, once-per-cart key, only 4xx = verdict, 5xx not queued) | ch2 ×2, ch3 ×2, ch4a, ch4b | concept ch2; rules ch3 (API repository) | ch4a had the same 7-item list as ch3 |
| Lock order | ch2, ch3, ch4b | ch3 | |
| Outbox / `op_effects` / stuck after 3 / per-aggregate head-of-line | ch2, ch3, ch4a | concept ch2; design ch3; tickets ch4a | |
| RC/CN numbering, `commitServerIssued`, head-SHA lesson (#489/#494) | ch2, ch3, ch4a, ch4b, ch5 | design ch3; ticket row ch4a; lesson ch5 | lesson told 4 times |
| Metrics names, middleware counting, `UNMEASURED_PATHS` (~36 req/min) | ch2, ch3, ch4b | ch3 | |
| JWT lifetimes / web token storage / NFC fallback | ch2, ch3 ×2, ch4a, ch4b | concept ch2; decision ch3 | |
| CI structure (`changes`, required status jobs), approval gate, "green ≠ deployed" | ch2, ch3, ch4b, ch5 | design ch3; evidence + reading caveat ch4b | |
| Offsite backup not done (#363/#288) | ch1, ch3, ch4b, ch5 | status ch4b; next work ch5; one line in ch1 scope | kept everywhere it is a status claim, cut where it was repetition |
| DoD 16/17 | ch1, ch3 ×2, ch4b ×2, ch5 | table ch4b; one-line mentions ch1/ch5 | |
| Commit / PR / issue counts | ch1, ch4b, ch5 | `tab:progress-stats` (ch4b) | ch1 keeps only the per-month split that explains the timeline |
| Lane split and "blocked-by never crosses a lane" | ch1, ch3, ch4a, ch4b | table ch1; principle ch3 | |
| Screens table | ch3 `tab:screens` and ch4a `tab:screens` | ch3 | **duplicate label id** — ch4a's overwrote ch3's in the build's label map |
| Business invariants (saveSale/createReturn/receivePO/…) | ch2, ch3 (table), ch4a | ch3 `tab:invariants` | |
| CouchDB rejection, Architecture C/T1 choice | ch1, ch2, ch3 | ch1 (decision), ch2 (why not CRDT/replication) | ch3 keeps a one-line pointer |
| Pipeline diagram | ch2 `cicd-pipeline`, ch3 `deploy` | `cicd-pipeline` FIGURE moved to ch3; `deploy` FIGURE line removed | same flow twice; ch2 is theory. Spec blocks untouched |
| Outbox diagram | ch2 `outbox-flow`, ch3 `sync-seq` | `outbox-flow` FIGURE moved to ch3; `sync-seq` FIGURE line removed | same flow twice; spec blocks untouched |

## 3. Numbers that disagreed (fixed)

- **Receipt example**: ch2 `RC01-2569-09-0042` vs ch3/ch4a `RC01-2569-08-0042`. ADR-0007 line 14
  and `adr/README.md` row 0007 use `-08-` → ch2 corrected.
- **Client tests**: ch4a 820 (runner) / 741 (grep) / 92 `.dart` / 90 `*_test.dart`; ch4b table
  "93 files … 741 cases"; ch5 "741 in 90 files". 93 = 92 `.dart` + 1 JSON fixture
  (`git ls-files frontend/test`). → everywhere: **820 cases reported by the runner (741
  definitions in source), 90 test files**.
- **Screens**: ch1 "หน้าจอทั้ง 11 หน้า" (June) vs 12 nav / 14 files now. Both true at their
  dates → ch1 now says 11 *at that time*.
- **Redis memory**: ch3 table 256 MB vs text 192 MB — container `mem_limit` 256m vs Redis
  `--maxmemory 192mb` (both in `server/docker-compose.yml`). Clarified, not changed.
- **CD** expanded as "Continuous Deployment" in ch3 but "Continuous Delivery" everywhere else
  (and in the abbreviation list, first definition wins) → ch3 aligned.
- **References**: ch3 [7] gave RFC 7519 the wrong authors (Nottingham & Wilde → Jones,
  Bradley, Sakimura); ch4a [2] gave Drift the wrong author (Rousset → Binder); ch3 [4] used
  `/docs/16/` URL so the bibliography would list PostgreSQL RLS twice (dedup is by URL);
  ch1 [7] and [12] were the same ADR-0012 file under two titles (two bibliography entries).

## 4. Content in the wrong chapter (moved or cut)

- ch2: "ความลับที่ฝังตอนเริ่มต้น" (volume secrets, `down -v`), Ansible SSH users, gitleaks
  allowlist-from-base-commit, `.current_sha`, metric/label names, compose service list —
  ops/design detail, not theory. Cut (ch3 keeps what matters).
- ch3: first-deploy evidence (SHAs, #67 15/15) → ch4b; team "lessons" (head SHA, branch
  deletion) → ch5 already had them → cut from ch3; open-items paragraph → one line.
- ch4a/ch4b: design re-explanations → pointers to ch3.
- ch4b: FortiGate story and the `0`-is-falsy bug were told in ch4b *and* ch5 → ch5 only.

## 5. Jargon an outside reader cannot follow (trimmed)

- GitHub comment IDs (5912257527, 5913430909) — dropped. Actions run IDs moved out of prose
  into one evidence table (`tab:deploy-evidence`).
- Ticket stacks in prose ("D1–D15, E1–E11, F1–F10 ใน #240", "tx.0–tx.5 #149–#154", "(#534,
  #536, #539)", "08 §11", "F3", "F6", "#196 2026-09-17") — reduced to the one ticket that is
  the evidence, or to a document name.
- Handoff trivia: `.backup-db.sh.prev-be9e7f3`, sha256 checks, 20-byte/9,580-byte files,
  `etcd-init.sh` as a directory, `ansible --check` false positives, 45 grep hits in the error
  resolver, `newAttempts >= 3` line numbers, `serverHasRow`, `/scrutinize`/
  `karpathy-guidelines` skill names — dropped or replaced by plain description.
- "agent ร่าง" → "ร่างโดยผู้พัฒนา รอเจ้าของโครงงานรับรอง".

## 6. Format checks

- Uncited references: ch3 12/12, ch4a 7/7, ch4b 9/9, ch5 4/4 were never cited. Each is now
  either cited at the sentence it supports or deleted (details in the hand-back report).
- `tab:backend-summary` was never referred to → now referenced.
- All `{fig:}`/`{tab:}` refs are backward (the build resolves labels chapter by chapter, so
  a ch2 → ch3 reference would print "?"); cross-chapter prose pointers use section titles.

## 7. Kept on purpose

Every "still open" statement (#344 demo not run, #380 k6 unmeasured, #363/#288 offsite backup
parked and nothing leaves the VM, #231 no cutover, #476 owner call, #443 open, three Thai
strings awaiting ratification, LOW finding on `POST /shifts/open`, fork half of #67 proven from
code only, e2e 490/492 being a 16-Sep number). All evidence tables (DoD, phase-2 tickets,
fe.0–fe.3, migration commits, tests, progress stats, security, endpoints, schema).

Verdict: **fix-then-ship** — the content is verified; the problem was four duplicated layers,
not wrong facts.
