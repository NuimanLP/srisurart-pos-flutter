# UI/UX polish pass — 2026-10-11/12 (branch `feat/ui-ux-polish`, local only)

Owner request: "UI/UX improvement in every page — easier to use, better, logic stays the same".
Presentation-only: no change under `frontend/lib/data/`, `domain/`, repositories, cubits, router or `server/`.

Six Opus agents each audited + polished one group in an isolated worktree; a separate reviewer
(Sonnet; Opus for checkout) reviewed each group for logic drift, Thai-string parity, overflow/zoom
and dark mode; every finding was fixed by the original agent before merge.

| Group | Audit | Scope |
|---|---|---|
| A | [A-shell-kit.md](A-shell-kit.md) | app shell / nav, shared widgets, theme, login, low-stock banner |
| B | [B-checkout.md](B-checkout.md) | checkout (POS), receipt, QR panel |
| C | [C-catalogue.md](C-catalogue.md) | products, vehicle search, label printer, product image |
| D | [D-returns-quotes-customers.md](D-returns-quotes-customers.md) | returns, quotes, customers, A4 quote PDF |
| E | [E-mechanics-po-drawer.md](E-mechanics-po-drawer.md) | mechanics, purchase orders, cash drawer, closing report |
| F | [F-reports-settings-devices.md](F-reports-settings-devices.md) | reports, settings, devices, owner review |

## Review findings fixed before merge (the ones that touched behaviour)
- Checkout: F9 (new pay shortcut) is a no-op while a line price is being edited — otherwise the sale
  saved the old price while the field showed the new one. Tests cover F9 (empty cart / in flight / price edit).
- Checkout: tap-to-type qty starts fully selected (Android/iOS appended "1"+"12" → "112").
- Checkout: a scan while a sale is in flight is ignored and left in the field (was silently wiped).
- Returns: one widget tree for all sizes, so the soft keyboard no longer drops focus mid-edit.
  Trade-off: on desktop with many lines the summary scrolls with the items instead of staying pinned.

## Verification
- `dart analyze` clean; full `flutter test` **1848 passed, 0 failed** (baseline on develop: 1813).
- `flutter build web --no-tree-shake-icons` OK; local offline build checked in a browser at 1366 px and 375 px.

## For the owner
- **Ratify the new Thai strings** — every audit doc has a "New Thai strings (agent ร่าง — owner to ratify)"
  section. No existing Thai string was changed, except the mechanic quick-pay chips: "+฿100" → "฿100"
  (they replace the amount, they never added to it).
- Things deliberately NOT done because they would change behaviour are listed at the end of each audit
  (e.g. double-tap guard on new-product save, per-line PO receive, English stock-status labels).
- Check the 1500 px icon-only threshold of the products table on the shop laptop (C).
