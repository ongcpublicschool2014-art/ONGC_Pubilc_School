# EduCore 360 — Colour Palette

Single source of truth: [`lib/utils/app_theme.dart`](../lib/utils/app_theme.dart) (`AppColors`).

Always reference the **token**, never the hex. The palette was swapped wholesale
once already (Navy + Amber → Royal Blue + Slate); because every screen reads
`AppColors.*`, that was a one-file change. Hardcoded hex values break that.

---

## Core

| Token | Hex | Use |
|---|---|---|
| `primary` · `accent` · `textAccent` · `tabSelected` | `#2563EB` | Royal Blue — buttons, active states, links |
| `primaryLight` · `accentLight` | `#DBEAFE` | Blue-100 tint — selected fills, chips |
| `primaryHover` · `accentDark` | `#1D4ED8` | Hover blue |
| `primaryDark` · `surfaceDark` | `#0F2D5C` | Navy |

> `accent` is deliberately the **same** blue as `primary` — this palette has no
> separate accent hue. Anything that needs to read *apart* from primary must use
> a metric hue (below), not `accent`.

## Surfaces

| Token | Hex | Use |
|---|---|---|
| `surface` | `#F8FAFC` | page background |
| `surfaceCard` | `#FFFFFF` | cards |
| `tableHeadBg` | `#EEF2F8` | table header band |

## Sidebar (dark navy chrome)

| Token | Hex | Use |
|---|---|---|
| `sidebarBg` · `surfaceSidebar` | `#0F2D5C` | sidebar background |
| `sidebarBorder` | `#1E3A66` | divider |
| `sidebarText` | `#E2E8F0` | text/icons on navy |

> Anything placed on the sidebar needs a light foreground (`sidebarText`) or a
> white plate behind it. Dark-on-transparent assets disappear into the navy.

## Text — three AA-verified tiers

| Token | Hex | Contrast | Use |
|---|---|---|---|
| `textPrimary` | `#1E293B` | ~13:1 | titles, key values |
| `textSecondary` | `#475569` | ~7:1 (AA/AAA) | body / content |
| `textLight` · `tabUnselected` | `#64748B` | ~4.6:1 (AA) | labels, captions, hints |
| `textOnPrimary` | `#FFFFFF` | — | on blue / navy |

## Borders & dividers

| Token | Hex | Use |
|---|---|---|
| `border` · `secondary` | `#CBD5E1` | Slate-300 — inputs, structural card edges |
| `cardBorder` · `divider` · `secondaryLight` | `#E2E8F0` | Slate-200 — softer inner edges |

## Feedback

| Token | Hex | Use |
|---|---|---|
| `success` | `#22C55E` | success green |
| `warning` | `#F59E0B` | warning orange |
| `error` | `#EF4444` | error red |
| `info` | `#3B82F6` | info blue |

## Metric hues — KPI / summary cards

| Token | Hex | Meaning |
|---|---|---|
| `primary` | `#2563EB` | collection |
| `today` | `#14B8A6` | today's figures (teal) |
| `demand` | `#8B5CF6` | demand / outstanding (violet) |
| `success` | `#22C55E` | collected |
| `warning` | `#F59E0B` | pending |

Used consistently on every dashboard — Fee Collection, Class-wise Demand,
Date-wise, and Super Admin (trust totals *and* per-institution cells) — so a
figure keeps its colour wherever it appears.

**Card recipe:** background `colour @ 8% alpha`, border `colour @ 28% alpha`,
icon chip solid white with a `colour @ 22% alpha` border. Low alpha keeps the
dark value text well above AA.

## Gradients

| Token | Stops |
|---|---|
| `primaryGradient` · `accentGradient` | `#2563EB` → `#1D4ED8` |
| `splashGradient` | `#2563EB` → `#1D4ED8` → `#0F2D5C` |

## Chart palette

[`lib/widgets/collection_charts.dart`](../lib/widgets/collection_charts.dart)
cycles 8 hues so adjacent bars separate:

`#2563EB` · `#14B8A6` · `#8B5CF6` · `#F59E0B` · `#22C55E` · `#0EA5E9` · `#EC4899` · `#6366F1`

Each bar is a vertical gradient from the hue to `lerp(hue, black, 0.18)`.

---

## Known outliers (hardcoded, not tokenised)

35 files still hardcode hex values. Worth cleaning up:

| Hex | Count | Where / what | Action |
|---|---|---|---|
| `#10B981` | 24 | Green **Refresh** button — a de-facto convention across 13 screens | promote to a token (`AppColors.refresh`) |
| `#6C8EEF` | 6 | Old periwinkle table header — `students_screen`, `student_ledger_screen`, `staff_designation_screen`, `failed_transactions_screen` | replace with `tableHeadBg` |
| `#002147` | 5 | **Old navy from before the theme swap** — no longer matches anything | replace with `primaryDark` |
| `#555555`, `#333333`, `#B0B0B0` | 29 | greys bypassing the text tiers, mostly PDF/receipt generation | acceptable — PDFs need fixed values |

`#002147` is the highest priority: it is a pre-swap colour that now clashes with
the current palette.
