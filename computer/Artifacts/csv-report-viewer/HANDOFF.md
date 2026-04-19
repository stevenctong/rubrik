# Handoff — Rubrik CSV Report Viewer

**Date:** 2026-04-19
**Author:** Steven Tong

---

## Overview

A fully self-contained, single-file HTML/CSS/JS web app for viewing and exploring CSV report data. No server, no dependencies, no build step — open `csv-report-viewer.html` directly in a browser.

Designed to pair with the PowerShell report scripts (`Get-Manage-CDM-Reports.ps1`, `Get-RSC-Reports.ps1`) but works with any well-formed CSV.

**Location:** `computer/HTML-Apps/csv-report-viewer.html`

---

## Architecture

Everything lives in one `.html` file (~910 lines):

- **Lines 1–203** — CSS (inline `<style>` block)
- **Lines 205–334** — HTML structure (topbar, toolbar, drop zone, table, footer, multi-select panel)
- **Lines 336–911** — JavaScript (inline `<script>` block, no modules)

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

### Data Flow

```
loadFile → showLoading → parseCSV → detect TaskType column
                                   → applyPreFilters → effectiveRows
                                   → checkThreshold
                                       ├─ under rowLimit → buildHeaders + applyFilters → render
                                       └─ over rowLimit  → show threshold message (no render)

filter input (debounced 2s) → applyFilters (scans effectiveRows)
                                ├─ over rowLimit results → update threshold message
                                └─ under rowLimit results → render table

log/index toggle → applyPreFilters → checkThreshold → (same branching as above)
row limit change → checkThreshold → (same branching as above)
```

Unit/timezone changes call `renderPage()` directly (no re-filter needed — raw values are stored, conversion happens at render time).

### Large Dataset Handling

- **Row limit / display threshold:** `rowLimit` variable (default `300,000`), controlled by a topbar dropdown with presets: 50k, 100k, 200k, 300k, 500k, 1M. If `effectiveRows` exceeds this after pre-filters, the table body is not rendered until filters narrow the result set below the limit. Column headers and filter inputs remain visible so users can apply filters
- **Log event filter:** A topbar checkbox (default: checked, always visible) filters out rows where the `TaskType` column value starts with "Log" (case-insensitive). Has no effect on CSVs without a `TaskType` column. Applied before the threshold check
- **Index event filter:** A topbar checkbox (default: checked, always visible) filters out rows where the `TaskType` column value is exactly "Index" (case-insensitive). Applied after the log filter
- **Threshold message:** Positioned inside the table section below column headers/filters. Shows total rows, log/index events filtered (if applicable), remaining rows, and prompts the user to add filters
- **Cross-threshold behavior:** If the user changes filters (including log/index toggles or the row limit dropdown) and the result count crosses the limit, the table body is cleared and the threshold message reappears
- **Loading indicator:** Shown during file read and CSV parsing. Displays row count once the line split is complete
- **Debounced filter inputs:** Global search, per-column text filters, and enum multi-select changes are debounced (2 seconds) to give users time to set up multiple filters before the scan runs

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

## UI Components

### Top Bar (`#00B2A9` teal)

| Control | Behavior |
|---------|----------|
| Timezone toggle (UTC/PT/MT/CT/ET) | Re-renders date columns; no re-filter |
| Capacity toggle (GB/TB) | Re-renders capacity columns; no re-filter |
| Duration toggle (Sec/Min/Hr) | Re-renders duration columns; no re-filter |
| Filter Log Events checkbox | Filters out `TaskType` values starting with "Log"; default checked; always visible (no effect if CSV lacks `TaskType` column) |
| Filter Index Events checkbox | Filters out `TaskType` value "Index" (exact match); default checked; always visible |
| Load dropdown (50k–1M) | Controls display threshold — max rows to render. Default 300k. Tooltip explains usage |
| Import CSV (mini drop zone) | Click or drag-and-drop; replaces current data |

### Toolbar

- **Global search** — filters across all columns simultaneously (substring, case-insensitive)
- **Clear filters** button — resets global search, all per-column text filters, and all enum selections

### Table

- **Header row** — sticky, dark teal (`#007A73`). Click to sort (toggle asc/desc). Sort icon: `⇅` (unsorted), `↑` (asc), `↓` (desc)
- **Filter row** — sticky below header. Text inputs for text/numeric/capacity/duration/date columns. Multi-select dropdown trigger for enum columns
- **Body** — alternating row colors, hover highlight (`#f0fffe`). Cell overflow truncated with ellipsis (`max-width: 320px`), full value in `title` tooltip

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
| Active toggle buttons | White text on teal → teal text on white |
| Hover highlight | `#f0fffe` |
| Focus borders | `#00B2A9` |

---

## Known Limitations

- **No server communication** — purely client-side. Cannot fetch data from Rubrik APIs directly
- **Full dataset in memory** — all rows are parsed and held in JS arrays. Practical ceiling ~500k–1M rows depending on browser/column count. The row limit dropdown (default 300k) prevents rendering oversized result sets but does not reduce memory usage
- **Duration units assumed seconds** — raw values are divided by 1/60/3600. If Rubrik changes the unit, divisors need updating
- **Column type detection is heuristic** — based on column name keywords, not data schema. A column named e.g. `customSize` would be auto-detected as capacity even if it isn't
- **No CSV export** — the viewer is read-only; filtered data cannot be re-exported
- **Single file at a time** — loading a new CSV replaces the previous one entirely

---

## Potential Future Work

- **CSV re-export** — download the currently filtered/sorted view as a new CSV
- **Multi-file tabs** — load multiple CSVs and switch between them
- **Column visibility toggle** — hide/show columns without removing data
- **Persistent filter presets** — save named filter configurations to localStorage
- **Dark mode** — alternate color scheme
