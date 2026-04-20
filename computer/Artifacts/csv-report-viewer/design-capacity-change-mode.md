# Design — Capacity Change Mode for CSV Report Viewer

**Date:** 2026-04-20
**Author:** Steven Tong

---

## Problem

The `Get-Capacity-Change-Report.ps1` script outputs CSVs with 40–52 columns depending on how many comparison periods are configured. Viewing this in the generic table mode produces an overwhelming horizontal scroll with no visual hierarchy — users can't quickly identify which objects changed or by how much.

## Solution

Auto-detect capacity change CSVs and switch to a focused **Capacity Change Mode** that surfaces the most useful information: identity fields, current capacity, and change deltas for user-selected comparison periods. A cross-period summary table provides an at-a-glance aggregate view across all periods.

---

## Detection

When a CSV is loaded, headers are scanned for the regex pattern `-\d+\s+(Days|Months)` (e.g., `-1 Months`, `-7 Days`). If any header matches, capacity change mode activates automatically. No user action required.

**Trigger examples:**
- `Logical Bytes (GB) -1 Months` — matches
- `Used Size Change (GB) -7 Days` — matches
- `Data Stored (GB)` — no match (standard capacity column)

## Column Layout

Instead of showing all 52 columns, the viewer shows a curated set in this order:

### Identity (4)
1. Cluster Name
2. Object Name
3. Location
4. Object Type

The first 3 are frozen (sticky positioning) so they remain visible on horizontal scroll.

### Capacity Metrics (5 × (1 + N selected periods))

For each metric, the **current value** column is shown, followed by **change columns** for each selected period:

| Metric | Current Column | Change Column (per period) |
|--------|---------------|---------------------------|
| Logical Bytes | Logical Bytes (GB) | Logical Bytes Chg -1M |
| Used Size | Used Size (GB) | Used Size Chg -1M |
| Data Stored | Data Stored (GB) | Data Stored Chg -1M |
| Archive Storage | Archive Storage (GB) | Archive Storage Chg -1M |
| Replica Storage | Replica Storage (GB) | Replica Storage Chg -1M |

Change column labels always include the abbreviated period suffix (e.g., `-1M`, `-7D`) so users can distinguish columns when multiple periods are selected.

Change columns use a darker teal header (`#005f58`) to visually distinguish them from current-value columns.

### Trailing (6)
15. Status
16. SLA Domain
17. Protected On
18. Local Data Reduction (%)
19. Local Dedup Ratio (x)
20. UniqueKey

## Multi-Select Period Checkboxes

Topbar displays checkbox toggles (one per detected period) sorted by magnitude (shortest first). At least one must be selected.

Example for a monthly CSV:
```
Compare: [x] -1 Months  [x] -3 Months  [ ] -6 Months  [ ] -10 Months
```

Default: first (shortest) period checked only. Checking additional periods adds 5 change columns per period to the detail table.

Changing selections rebuilds the visible columns and re-renders the table.

## Cross-Period Summary Table

A collapsible table positioned between the toolbar and the detail table showing aggregate capacity across **all** periods (regardless of which period checkboxes are selected). Click the "Cross-Period Summary" header to expand/collapse.

| Period | Logical (TB) | Used (TB) | Data Stored (TB) | Archive (TB) | Replica (TB) | Objects |
|--------|-------------|----------|-------------------|-------------|-------------|---------|
| Baseline (current) | 2.98 | ... | 0.04 | 0.03 | 0.01 | 984 |
| -1 Months | 2.96 | ... | 0.04 | 0.03 | 0.01 | 884 |
| -3 Months | 4.51 | ... | 0.04 | 0.03 | 0.01 | 898 |

- **Baseline row**: sum of current values across Active objects only (Status = "Active"), matching the `Get-Capacity-Change-Report` HTML output
- **Baseline "Objects"**: count of Active objects
- **Period rows**: sum of historical capacity values for that period
- **Period "Objects"**: count of objects that existed in that period (any non-zero historical value across the 5 tracked metrics)
- Always displayed in TB since aggregated values are large
- Updates on every filter change, period change, or unit toggle

## Change Value Formatting

| Condition | Style |
|-----------|-------|
| Positive (capacity grew) | Red text, `+` prefix |
| Negative (capacity shrank) | Green text, `-` prefix |
| Zero | Gray/muted text |

Values are displayed in the selected unit (GB or TB). The CSV stores values in GB; TB display divides by 1000.

## Topbar Behavior

When capacity change mode is active, irrelevant controls are hidden:

| Control | Standard Mode | Capacity Change Mode |
|---------|--------------|---------------------|
| Timezone (UTC/PT/MT/CT/ET) | Visible | Hidden |
| Duration (Sec/Min/Hr) | Visible | Hidden |
| Log/Index event filters | Visible | Hidden |
| Row limit dropdown | Visible | Hidden |
| Capacity (GB/TB) | Visible | **Visible** |
| Compare period checkboxes | Hidden | **Visible** |
| Import CSV | Visible | **Visible** |

When a non-capacity CSV is loaded, all standard controls reappear and capacity change controls hide.

## Retained Functionality

All existing features work in capacity change mode:
- **Per-column text filters** on every column
- **Multi-select dropdowns** for Object Type and Cluster Name (enum detection still applies)
- **Global search** across all columns (searches raw CSV values, including hidden columns)
- **Column sorting** via header click (uses raw CSV column index)
- **Column resize** via drag handle on header right edge (shrinks to ~30px with ellipsis truncation)
- **Frozen columns** — first 3 identity columns stay visible on horizontal scroll
- **Pagination** (10,000 rows per page)
- **GB/TB toggle** rescales all capacity and change values

## Data Flow

```
parseCSV → buildStdColOrder → detectCapChangeMode → configureTopbar
         → buildVisibleCols → buildHeaders (frozen offsets computed synchronously)
         → applyFilters → renderRows (uses visibleColMeta) + updateSummary

Period change → buildVisibleCols → buildHeaders → applyFilters → renderRows + updateSummary
Unit change   → renderPage → updateSummary (no re-filter needed)
Column resize → recomputeFrozenOffsets (updates header + body left values)
```

## Key State Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `isCapChangeMode` | boolean | Whether capacity change mode is active |
| `capChangePeriods` | string[] | Detected periods, sorted by magnitude |
| `selectedPeriods` | Set | Currently selected periods (multi-select) |
| `capChangeColMap` | object | Maps period → metric → { value: colIdx, change: colIdx } |
| `visibleColMeta` | object[] | Ordered list of { rawIdx, isChange, frozen, frozenLast, label } for display columns |

## Design Decisions

**Why multi-select periods instead of single-select?**
Users often want to compare capacity at two or more lookback intervals side by side (e.g., 1-month and 3-month deltas). Multi-select with checkboxes makes this a single click instead of requiring multiple CSV loads.

**Why Current + Change only (not Current + Old + Change)?**
Keeps the table compact. The old value is derivable (current - change). Users primarily care about the delta, not the historical absolute.

**Why a cross-period summary table?**
Mirrors the HTML email output from `Get-Capacity-Change-Report.ps1`, giving an immediate aggregate view. Always shows all periods regardless of checkbox selection so users see the full picture.

**Why TB in the summary table?**
Aggregated values across hundreds of objects produce numbers in the thousands of GB. TB is more readable at that scale.

**Why hide timezone/duration controls?**
The capacity change CSV has no date columns requiring timezone conversion and no duration columns. Hiding them reduces visual noise.

**Why skip the row-limit threshold check?**
Capacity change CSVs have ~1,700 rows (one per protected object). The 300k threshold is irrelevant and would add unnecessary code paths.

**Why red for growth / green for shrink?**
In capacity management, growth means more storage consumed — typically a concern. Shrinkage means freed space — typically desirable. This matches the "cost" mental model.

**Why freeze the first 3 columns?**
With 20+ columns, horizontal scroll loses the object identity. Freezing Cluster Name, Object Name, and Location ensures the user always knows which object they're looking at. This also applies to standard mode for consistency.
