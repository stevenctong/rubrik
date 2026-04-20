# Handoff — Rubrik CSV Report Viewer

**Date:** 2026-04-20
**Author:** Steven Tong

---

## Overview

A fully self-contained, single-file HTML/CSS/JS web app for viewing and exploring CSV report data. No server, no dependencies, no build step — open `csv-report-viewer.html` directly in a browser.

Works with any well-formed CSV. Auto-detects CSVs from `Get-Capacity-Change-Report.ps1` and switches to a specialized **Capacity Change Mode** with curated columns, multi-period comparison, change formatting, and aggregate summaries.

**Location:** `computer/HTML-Apps/csv-report-viewer.html`

---

## Architecture

Everything lives in one `.html` file (~1,560 lines):

- **Lines 1–305** — CSS (inline `<style>` block)
- **Lines 307–445** — HTML structure (topbar, toolbar, summary bar, drop zone, table, footer, multi-select panel)
- **Lines 447–1500** — JavaScript (inline `<script>` block, no modules)

No external dependencies except the browser. No CDN imports, no frameworks.

### State Model

All state is held in module-level `let` variables:

| Variable | Purpose |
|----------|---------|
| `rawRows` | Parsed CSV data (array of arrays) |
| `columns` | Header names |
| `capCols`, `durCols`, `numCols`, `enumCols`, `dateCols` | Boolean arrays — column type flags |
| `enumValues`, `enumFilters` | Per-column unique values and active selections |
| `colFilters` | Per-column text filter strings |
| `unit` | Capacity display unit (`GB` or `TB`) |
| `durUnit` | Duration display unit (`Seconds`, `Minutes`, `Hours`) |
| `tz`, `tzLabel` | Active timezone (IANA string + display label) |
| `sortCol`, `sortAsc` | Current sort column index and direction |
| `filterLogEvents` | Log event filter toggle (default `true`) |
| `filterIndexEvents` | Index event filter toggle (default `true`) |
| `taskTypeColIdx` | Index of `TaskType` column (`-1` if absent) |
| `rowLimit` | Display threshold controlled by dropdown (default `300000`) |
| `effectiveRows` | `rawRows` after log/index pre-filtering |
| `displayRows` | Filtered + sorted result set |
| `currentPage` | Zero-based page index |
| `stdColOrder` | Array of raw column indices in display order (standard mode) |
| `stdFrozenMeta` | Frozen column metadata for standard mode (displayIdx, rawIdx, left offset) |
| `stdHasPriority` | Whether all 3 priority columns were detected |
| `isCapChangeMode` | Whether capacity change mode is active |
| `capChangePeriods` | Detected comparison periods, sorted by magnitude |
| `selectedPeriods` | Set of currently selected comparison periods |
| `capChangeColMap` | Maps period → metric → { value: colIdx, change: colIdx } |
| `visibleColMeta` | Ordered list of { rawIdx, isChange, frozen, frozenLast, label } for display columns |

### Data Flow

#### Standard Mode
```
loadFile → showLoading → parseCSV → buildStdColOrder (reorder priority cols)
                                   → detectCapChangeMode (no match)
                                   → detect TaskType column
                                   → applyPreFilters → effectiveRows
                                   → configureTopbar (show standard controls)
                                   → buildHeaders (uses stdColOrder, computes frozen offsets)
                                   → checkThreshold
                                       ├─ under rowLimit → applyFilters → render (frozen cols)
                                       └─ over rowLimit  → show threshold message (no render)

filter input (debounced 2s) → applyFilters (scans effectiveRows)
                                ├─ over rowLimit results → update threshold message
                                └─ under rowLimit results → render table
```

#### Capacity Change Mode
```
loadFile → showLoading → parseCSV → buildStdColOrder
                                   → detectCapChangeMode (match!)
                                   → configureTopbar (show period checkboxes, hide irrelevant)
                                   → buildVisibleCols → buildHeaders (frozen offsets)
                                   → applyFilters → renderRows + updateSummary

period change → buildVisibleCols → buildHeaders → applyFilters → renderRows + updateSummary
unit change   → renderPage → updateSummary
```

Unit/timezone changes call `renderPage()` directly (no re-filter needed — raw values are stored, conversion happens at render time).

### Column Reordering & Freezing

Both modes reorder and freeze columns when "Cluster Name", "Object Name", and "Location" are detected:

- **Standard mode:** `buildStdColOrder()` moves the 3 priority columns to the front of `stdColOrder`. `buildHeaders()` and `renderRows()` iterate `stdColOrder` instead of raw `columns`. The first 3 get `position: sticky` with computed `left` offsets.
- **Capacity change mode:** `buildVisibleCols()` places identity columns first (Cluster Name, Object Name, Location, Object Type). The first 3 get frozen metadata (`frozen: true`, `frozenLast` on the third).
- **Frozen offsets** are computed synchronously after headers are appended (the table section is made visible before `buildHeaders()` so `offsetWidth` returns accurate values).
- **Column resize** drag handles are attached to all header `th` elements. On first drag, the table switches to `table-layout: fixed` with all columns locked at their current widths. Columns can be shrunk to ~30px (3 characters); narrower content truncates with ellipsis. Resizing a frozen column triggers `recomputeFrozenOffsets()` which updates both header and body `left` values.

### Large Dataset Handling

- **Row limit / display threshold:** `rowLimit` variable (default `300,000`), controlled by a topbar dropdown with presets: 50k, 100k, 200k, 300k, 500k, 1M. If `effectiveRows` exceeds this after pre-filters, the table body is not rendered until filters narrow the result set below the limit. Column headers and filter inputs remain visible so users can apply filters
- **Log event filter:** A topbar checkbox (default: checked) filters out rows where the `TaskType` column value starts with "Log" (case-insensitive). Has no effect on CSVs without a `TaskType` column. Applied before the threshold check
- **Index event filter:** A topbar checkbox (default: checked) filters out rows where the `TaskType` column value is exactly "Index" (case-insensitive). Applied after the log filter
- **Threshold message:** Positioned inside the table section below column headers/filters. Shows total rows, log/index events filtered (if applicable), remaining rows, and prompts the user to add filters
- **Loading indicator:** Shown during file read and CSV parsing. Displays row count once the line split is complete
- **Debounced filter inputs:** Global search, per-column text filters, and enum multi-select changes are debounced (2 seconds) to give users time to set up multiple filters before the scan runs

Note: Large dataset handling (threshold, log/index filters) is bypassed in capacity change mode as those CSVs have ~1,700 rows.

---

## Column Type Detection

Types are inferred from header names (normalized: lowercased, spaces/underscores removed) and, for dates, confirmed by sampling values in the first 20 rows.

| Type | Detection Rule | Badge | Rendering |
|------|---------------|-------|-----------|
| **Capacity** | Exact: `logicalbytes`, `bytestransferred`, `localmetereddata`. Contains: `size`, `storage`, `datatransferred`, `datastored` | Blue (`#3b7dd8`) | Right-aligned, divided by unit divisor (1e9 for GB, 1e12 for TB), 2 decimal places |
| **Duration** | Contains: `duration` | Purple (`#7a4a9a`) | Right-aligned, divided by unit divisor (1/60/3600), 2 decimal places |
| **Date** | Name ends in `Time`, `Date`, `Snapshot`, `Stamp`, `On` AND first 20 rows contain ISO date values. Explicit: `starttime`, `endtime` (no value check needed) | Green (`#2a7a5a`) | Monospace, timezone-converted via `Intl.DateTimeFormat` |
| **Enum** | Contains: `taskstatus`, `tasktype`, `objecttype`, `clustername` | None | Multi-select dropdown filter |
| **Numeric** | All sampled values (first 10 rows) parseable as numbers, and not any above type | None | Right-aligned |
| **Text** | Everything else | None | Left-aligned, text substring filter |

**Adding new detection keywords:** Update the constants at the top of the `<script>` block — `CAP_EXACT`, `CAP_CONTAINS`, `ENUM_KEYWORDS`, `DATE_NAME_RE`, `DATE_EXPLICIT`.

---

## Capacity Change Mode

Auto-detects CSVs from the `Get-Capacity-Change-Report.ps1` script and switches to a focused view with curated columns, multi-period comparison, and aggregate summaries.

**Detection:** Headers are scanned for `-\d+\s+(Days|Months)` pattern. If matched, mode activates automatically.

**Design doc:** See `Artifacts/csv-report-viewer/design-capacity-change-mode.md` for full rationale and decisions.

### Column Layout

Instead of showing all 52 columns, the viewer shows a curated set in this order:

| Group | Columns |
|-------|---------|
| Identity (4) | Cluster Name, Object Name, Location, Object Type |
| Per metric (5 × (1 + N periods)) | Current value + change columns for each selected period: Logical Bytes, Used Size, Data Stored, Archive Storage, Replica Storage |
| Trailing (6) | Status, SLA Domain, Protected On, Local Data Reduction (%), Local Dedup Ratio (x), UniqueKey |

The first 3 identity columns are frozen (sticky) on horizontal scroll.

### Multi-Select Period Checkboxes

Topbar displays checkbox toggles for each detected period, sorted by magnitude (shortest first). Users can select one or more periods — at least one must be selected.

Example for a monthly CSV:
```
Compare: [x] -1 Months  [x] -3 Months  [ ] -6 Months  [ ] -10 Months
```

Default: first (shortest) period checked only. Checking additional periods adds 5 more change columns per period to the detail table.

### Cross-Period Summary Table

A collapsible table between the toolbar and the detail table showing aggregate capacity across **all** periods (regardless of checkbox selection). Click the "Cross-Period Summary" header to expand/collapse.

| Period | Logical (TB) | Used (TB) | Data Stored (TB) | Archive (TB) | Replica (TB) | Objects |
|--------|-------------|----------|-------------------|-------------|-------------|---------|
| Baseline (current) | 2.98 | ... | 0.04 | 0.03 | 0.01 | 984 |
| -1 Months | 2.96 | ... | 0.04 | 0.03 | 0.01 | 884 |

- **Baseline row**: sum of current values across Active objects only (matches `Get-Capacity-Change-Report` HTML output)
- **Baseline "Objects"**: count of rows where Status = "Active"
- **Period rows**: sum of historical capacity values for that period
- **Period "Objects"**: count of objects that existed in that period (any non-zero historical value)
- Always displays in TB (aggregated values are large)
- Updates on filter, period, and unit changes

### Change Formatting

- Positive (grew): red, `+` prefix
- Negative (shrank): green, `-` prefix
- Zero: gray/muted
- Change column headers use darker teal (`#005f58`)
- Change column labels always include the period suffix (e.g., `Logical Bytes Chg -1M`)

### Topbar in Capacity Change Mode

Hidden: Timezone, Duration, Log/Index filters, Row limit
Shown: Capacity GB/TB toggle, Period checkboxes, Import CSV

---

## UI Components

### Top Bar (`#00B2A9` teal)

| Control | Standard Mode | Cap Change Mode |
|---------|--------------|-----------------|
| Timezone toggle (UTC/PT/MT/CT/ET) | Visible | Hidden |
| Capacity toggle (GB/TB) | Visible | Visible |
| Duration toggle (Sec/Min/Hr) | Visible | Hidden |
| Filter Log Events checkbox | Visible | Hidden |
| Filter Index Events checkbox | Visible | Hidden |
| Load dropdown (50k–1M) | Visible | Hidden |
| Compare period checkboxes | Hidden | Visible |
| Import CSV (mini drop zone) | Visible | Visible |

### Toolbar

- **Global search** — filters across all columns simultaneously (substring, case-insensitive)
- **Clear filters** button — resets global search, all per-column text filters, and all enum selections

### Summary Bar (capacity change mode only)

Collapsible cross-period summary table showing aggregate stats for all periods across filtered rows. Click the "Cross-Period Summary" header to toggle visibility.

### Table

- **Header row** — sticky, dark teal (`#007A73`). Change column headers use `#005f58`. Click to sort (toggle asc/desc). Sort icon: `⇅` (unsorted), `↑` (asc), `↓` (desc)
- **Filter row** — sticky below header. Text inputs for text/numeric/capacity/duration/date columns. Multi-select dropdown trigger for enum columns
- **Body** — alternating row colors, hover highlight (`#f0fffe`). Cell overflow truncated with ellipsis (`max-width: 320px`), full value in `title` tooltip. In capacity change mode, change values are color-coded
- **Column resize** — drag the right edge of any header column to resize. Columns can shrink to ~30px (~3 characters); content truncates with ellipsis. On first resize, the table switches to `table-layout: fixed` to allow independent column sizing. Works in both standard and capacity change modes
- **Frozen columns** — first 3 columns (Cluster Name, Object Name, Location) use `position: sticky` with computed `left` offsets. A solid border separates frozen from scrollable columns. Works in both modes when those columns are detected

### Multi-Select Dropdown

Shared single panel (`#ms-panel`) repositioned on each open. Features:
- Search input to filter values
- Select All / Clear actions (respect current search filter)
- Checkbox list with highlighted state when active
- Closes on click-outside or Escape

### Footer (`#00B2A9` teal)

- Row count (total and filtered)
- Page indicator with Prev/Next buttons
- Page size: 10,000 rows

---

## CSV Parser

Custom parser with two stages:
1. **`joinQuotedLines()`** — joins continuation lines when a quoted field spans multiple lines (tracks quote parity to detect open fields)
2. **`parseLine()`** — handles quoted fields with embedded commas and escaped double-quotes (`""`)

Does not use `Papa Parse` or any library. The multi-line join handles real-world Rubrik exports where `Status Reason` fields contain embedded newlines (e.g., Cloud Direct error messages).

---

## Branding

| Element | Color |
|---------|-------|
| Top bar, footer | `#00B2A9` (Rubrik primary teal) |
| Table header | `#007A73` (darker teal) |
| Change column header | `#005f58` (darkest teal) |
| Active toggle buttons | White text on teal → teal text on white |
| Hover highlight | `#f0fffe` |
| Focus borders | `#00B2A9` |
| Change positive (growth) | `#c0392b` (red) |
| Change negative (reduction) | `#27ae60` (green) |
| Change zero | `#999` (gray) |

---

## Known Limitations

- **No server communication** — purely client-side. Cannot fetch data from Rubrik APIs directly
- **Full dataset in memory** — all rows are parsed and held in JS arrays. Practical ceiling ~500k–1M rows depending on browser/column count. The row limit dropdown (default 300k) prevents rendering oversized result sets but does not reduce memory usage
- **Duration units assumed seconds** — raw values are divided by 1/60/3600. If Rubrik changes the unit, divisors need updating
- **Column type detection is heuristic** — based on column name keywords, not data schema. A column named e.g. `customSize` would be auto-detected as capacity even if it isn't
- **No CSV export** — the viewer is read-only; filtered data cannot be re-exported
- **Single file at a time** — loading a new CSV replaces the previous one entirely
- **Capacity change mode assumes GB values** — the CSV column names include `(GB)` and values are pre-converted. If the script changes to output raw bytes, the rendering logic would need updating

---

## Potential Future Work

- **CSV re-export** — download the currently filtered/sorted view as a new CSV
- **Multi-file tabs** — load multiple CSVs and switch between them
- **Column visibility toggle** — hide/show columns without removing data
- **Persistent filter presets** — save named filter configurations to localStorage
- **Dark mode** — alternate color scheme
- **Capacity change sparklines** — inline mini charts showing capacity trend across all comparison periods
- **Top-N changers** — quick filter to show only the N objects with the largest absolute change
