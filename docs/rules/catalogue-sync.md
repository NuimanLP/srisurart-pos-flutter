# Catalogue and sync cursors

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: `server/src/products/`, `GET /products` pull, part-number uniqueness, PO receive.

**Catalogue/sync (`server/src/products/`):**
- `GET /products?updatedSince=&afterId=` is a **microsecond**-precision keyset cursor —
  a millisecond timestamp skips or re-serves rows sharing one bill's `now()`.
- Part-number uniqueness is a Postgres constraint (`uq_products_partno_ci`), not an app
  check; check `EXPLAIN` as `pos_app`, never as superuser (RLS changes the plan).
- PO receive lock order: PO row → products in id order; weighted-average cost rounds
  satang half-up (deliberately differs from the Dart client's float `round2`).
