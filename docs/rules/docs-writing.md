# Writing in docs/Backend_design/

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: any edit under `docs/Backend_design/`.

**Writing in `docs/Backend_design/` (added 2026-09-23, PR #391 —
`handoff_log/session-2026-09-23-key-primer-docs.md`):**
- **Never cite a `-- 🆕 migration NNNN:` comment as a live constraint.** `01_DATABASE.md §5`
  can carry both shipped DDL and not-yet-applied migrations in the same code fences. Check
  which side of that line an identifier sits on — and that its migration is in `MIGRATIONS`
  (`server/src/db/data-source.ts`) — before quoting it. 🔴 **Corrected 2026-09-25:** the
  example first recorded here was itself backwards — `uq_products_partno_ci` (migration
  `1788652800007`) **is** applied and is the enforcing case-insensitive index;
  `uq_products_partno` still exists but is subsumed by it.
- **Mermaid ER diagrams cannot express a composite key** — labelling `tenant_id PK` and `id PK`
  as two rows made readers see two primary keys, even with a warning above the diagram. Since
  2026-09-24 `§3` never puts a `PK`/`UK` label on a multi-column key: those columns carry the
  comment `"PK ร่วม (tenant_id, id)"` / `"UNIQUE (tenant_id, receipt_no)"` instead, and
  `tenant_id` is labelled `FK` (to `tenants`). Only single-column keys (`TENANTS`) keep
  `PK`/`UK`. Keep that convention if you add a table to a diagram.
- **A cross-reference to another doc's section must be grepped before it is written.** Three
  pointers shipped in the first pass named things that do not exist (`ADR-0003` has no
  `PRIMARY KEY` in it at all; `architecture-primer.md §4` is about architecture options, not FKs).
  Restating a *definition* in several files is fine — it does not drift; inventing a
  *file-specific example* is what produced every false claim.
- Two known doc-vs-reality divergences, both annotated, neither reconciled: `architecture.md`'s
  DDL is an old sketch (single-column PK, still has `offline_ok`, dropped per #272) while
  `00_INDEX.md` advertises it as the reference spec — `01_DATABASE.md §5` binds; and
  `audit_log` is `id BIGSERIAL PRIMARY KEY` in the docs but `(tenant_id, id)` in the shipped
  migration (recorded at the end of `adr/README.md`).
- The key terminology primer has **one** home: `00_BASICS.md#keys` (full) and
  `01_DATABASE.md#keys` (short). Link to them; do not copy the table into a third file.
