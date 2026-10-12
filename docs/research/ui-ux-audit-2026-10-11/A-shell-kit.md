# UI/UX audit — Group A: app shell, shared UI kit, login (2026-10-11)

Scope: `presentation/widgets/{app_shell, app_button, app_card, app_text_field, empty_state,
loading_view, search_field, section_header, status_chip, confirm_dialog, tap_target, money_text,
password_field, login_form, login_dialog, device_role_banner, low_stock_alert,
sync_status_builder}.dart`, `screens/login_screen.dart`, `core/theme/*`.

Users walked through: counter clerk on a 390 px phone (touch), iPad (touch), shop PC 1366–1920
(mouse/keyboard), elderly owner on whole-screen zoom 2x–3x (logical width shrinks to 455–960 px),
light and dark theme. Presentation-only: no change to what is saved, computed, validated or called.

Priority: **P1** = blocks or misleads the user, **P2** = slows them down or is hard to read,
**P3** = polish.

## Findings and fixes

### app_shell.dart
| P | Where | Problem | Why it hurts | Fix |
|---|---|---|---|---|
| P1 | `_TopBar` row, l.318–424 | Menu (48) + sync pill + theme toggle (48) + cashier/date block (up to 220) are all fixed-width; the shop name is the only flexible child. At 390 px the fixed parts already sum to ~389 px, and the degraded pill (`ออฟไลน์ (ขายสำรอง) · ค้าง N`, ~200 px) overflows the row. | Overflow stripes on a phone, shop name squeezed to nothing, exactly in the offline moment the clerk needs to read the bar. | Below `AppBreakpoints.compact`: sync pill and owner badge show icon (+count) only, full label kept in a `Tooltip`/`Semantics` (the `SyncAlertBanner` right under the bar already spells the state out); cashier block capped at 112 px and shows the time only (same `thaiTime`). Below `AppBreakpoints.expanded` (tablet, 2x–3x zoomed laptop) the same bar also overflowed (~110 px at 820) when offline **and** an owner item were both showing: there, and only then, the offline/sending pill goes icon + count while the owner badge keeps its words. ≥ 1000 px unchanged. Proven by `test/widgets/app_shell_phone_topbar_test.dart` (fails on the old shell: overflow 110 px at 390, 111 px at 820). |
| P2 | `_NavDrawer` l.224–240 | `DrawerHeader` is ~160 px tall of decoration. | At 2x–3x zoom on a phone half the drawer is header; the elderly owner has to scroll to reach รายงาน/ตั้งค่า. | Compact 64 px brand strip (same text, same orange underline). |
| P2 | `_NavDrawer` l.242–261 | Selected item differs only by orange text; no background, ripple colour is default on navy. | Current page is hard to spot at a glance, especially for low vision. | `selectedTileColor` (orange tint) + rounded tile shape + 48 px min height; hover/focus/splash tinted for navy. |
| P2 | `_Rail` l.189–209 | Material 3 default indicator (secondaryContainer, a pale lilac-ish pill) is computed from the seed and clashes with the navy rail; hover is near invisible. | Current page is less obvious; mouse users get weak hover feedback. | `indicatorColor` = orange tint so the icon sits on a clear brand pill; unselected labels kept `gray300` (≥ 7:1 on `navyDeep`). |
| P2 | `_buildNeedsOwnerBadge` l.561 | Tappable pill is ~22 px tall; red text on the navy bar ~2:1. | Hard to hit with a finger, hard to read. | Min 40 px hit box around the same visual (stays inside the 68 px bar); light-red text token. |
| P3 | `SyncAlertBanner` l.631–638 | One-off hex colours for the banner. | Not theme tokens; drift risk. | Same values moved to `AppColors` tokens (`warningBg/warningFg/…`), no visual change. Owner banner row gets ≥ 44 px height since the whole row is a tap target. |

### status_chip.dart
| P | Where | Problem | Fix |
|---|---|---|---|
| P2 | `_color` l.42–55, text l.69 | One colour for tint, border **and** text. In light mode `successLight`/`warning`/`steelBlue` text on a pale tint is ~3:1; in dark mode `gray500` (neutral) and `error` text on navy is ~2:1 — chips like `ยกเลิกบิล` are barely readable. | Text colour chosen per brightness from tokens (dark text on light, light text on dark); tint/border unchanged. |

### empty_state.dart
| P | Where | Problem | Fix |
|---|---|---|---|
| P2 | l.38–52 | Message and hint both `steelBlue` (≈3.3:1 on off-white, small hint text). | Message uses `onSurface` at medium weight, hint `onSurfaceVariant`; icon keeps steel-blue inside a soft circle so the empty state reads as intentional, not broken. |

### app_text_field.dart / theme
| P | Where | Problem | Fix |
|---|---|---|---|
| P1 | `InputDecoration` l.34–40 (and every raw `TextField` in the app) | `errorMaxLines` is null → Flutter clips the error to **one line with an ellipsis**. Server refusals worded in Thai (`AuthCubit.deviceEnrolmentGone`, PIN lock, etc.) are long and get cut. | Theme-level `inputDecorationTheme.errorMaxLines: 3`, `helperMaxLines: 3` (applies through `applyDefaults` to every field; text unchanged). |
| P3 | label l.86–93 | Label ok. | No change. |

### app_button.dart
| P | Where | Problem | Fix |
|---|---|---|---|
| P2 | busy spinner l.62–67 | Spinner inherits `primary` (orange) and sits on the gray disabled fill — low contrast, looks like nothing happens. | Spinner coloured with the button's foreground (white on filled, navy/white on outlined). |
| P3 | sizes l.88, l.108, l.124 | Height ≈ 48 already; `minimumSize` not pinned, so a short label at shrink-wrap density can fall under 48. | `minimumSize: Size(64, 48)` on all three variants. |

### confirm_dialog.dart
| P | Where | Problem | Fix |
|---|---|---|---|
| P2 | l.17–35 | Long message + 3x zoom → `AlertDialog` content can overflow (not scrollable). Danger confirm looks the same as a normal one apart from button colour. | `scrollable: true`; a warning icon above the title when `danger`. |

### search_field.dart
| P | Where | Problem | Fix |
|---|---|---|---|
| P3 | clear button l.57–63 | No tooltip/semantic label on the ✕. | Tooltip `ล้างคำค้นหา` (new string). |

### login_form.dart / login_screen.dart / login_dialog.dart
| P | Where | Problem | Fix |
|---|---|---|---|
| P1 | device chip l.172–213; notices l.237–324 | Hard-coded `Colors.grey[700/800]`, `Colors.brown`, `Colors.red`, `Colors.grey` text — in **dark mode** the device chip and the "PIN not configured / expired" notices are dark-on-dark and unreadable; light grey 12 px text is ~2.8:1. | One private `_Notice` (icon + text, tone) using theme-aware token colours; same strings, same order. |
| P2 | submit row l.466–482 | On the login route (no cancel) the only action is a right-aligned compact button. | Full-width primary button when there is no cancel button (the login route); dialog keeps the right-aligned pair. |
| P2 | `login_screen.dart` l.36–107 | Plain card on a plain background — no brand cue that this is the shop's till; the title row `Text` is not flexible (risk under 3x zoom). | Navy brand strip with the orange underline at the top of the card (same `Srisurart POS` text, same lock icon + title); title `Flexible`. |

### device_role_banner.dart
| P | Where | Problem | Fix |
|---|---|---|---|
| P2 | l.108–117 | `AppColors.error` text on the dark theme's navy ≈ 2:1. | Light red token in dark mode. |

### low_stock_alert.dart
| P | Where | Problem | Fix |
|---|---|---|---|
| P2 | stock figure l.539–561 | `100/120` at 20 px w800 in a fixed 64 px box wraps or clips. | `FittedBox(scaleDown)` around the figure. |
| P1 | whole banner (found by group B) | On a 390×844 phone the full banner pushed the checkout product grid down to y≈790 until dismissed. | Below `AppBreakpoints.compact` it starts as a one-line strip (⚠ + the existing `พบ N รายการหมด + M รายการต่ำกว่าขั้นต่ำ` + `ดูรายการ` + `✕ ปิด`); `ดูรายการ` opens the same full banner (same list, same handled ticks, same print/order). `✕ ปิด` calls the same `onClose`. Wider screens unchanged. Test: `test/widgets/low_stock_banner_compact_test.dart`. |
| P3 | private colour consts l.73–76 | Duplicate hex for brand tokens. | Point them at `AppColors` (same values). |

### Considered, not changed
- `TapTarget.minSize` 44 → 48: many screens size rows around 44; a default change risks overflow
  in screens owned by other agents. Left at 44 (meets Apple HIG; Material says 48).
- Global `ScrollbarTheme.thumbVisibility`: throws when one controller drives several scroll views;
  not worth the risk.
- Snackbar behaviour/position: tests and screens rely on the default.
- `loading_view.dart`, `section_header.dart`, `money_text.dart`, `app_card.dart`,
  `password_field.dart`, `sync_status_builder.dart`: no user-facing problem found worth the churn.

## New Thai strings (agent ร่าง — owner to ratify)
- `ล้างคำค้นหา` — tooltip on the search field's clear (✕) button (`search_field.dart`).
- `ดูรายการ` — button that opens the low-stock list from the compact phone strip
  (`low_stock_alert.dart`); same words as the owner-review banner's existing `ดูรายการ ›` link.

Follow-up (coordinator review): the phone topbar's time-only line carries the full
day + date (`EEE` + `thaiDate` + `thaiTime`, the same string the wide bar shows) as its
tooltip and semantics label — no new string.
