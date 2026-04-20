# Get-Capacity-Change-Report — Session Handoff

## What Was Done

Built a new PowerShell script (`computer/Powershell/Get-Capacity-Change-Report.ps1`) that processes RSC "Object Capacity Over Time" CSV reports and generates capacity change analysis with HTML + CSV output. Supports both local CSV input and direct RSC report pulling via GraphQL API.

## Files

| File | Purpose |
|------|---------|
| `computer/Powershell/Get-Capacity-Change-Report.ps1` | The script |
| `computer/artifacts/Get-Capacity-Change-Report/design.md` | Full design document with all decisions |
| `computer/artifacts/Get-Capacity-Change-Report/data-analysis.md` | CSV data analysis and field mapping |

## Source Data

Sample CSVs in `computer/artifacts/Get-Capacity-Change-Report/InternalCapacityReports/` (gitignored):

- `rsc_object_capacity_over_time_past_30_days.csv` — 87,174 rows, ~3,102 objects, 29 daily data points (Mar 21 – Apr 18, 2026), values in raw bytes
- `rsc_object_capacity_over_time_past_12_months.csv` — 7,872 rows, ~3,201 objects, 2 monthly data points (Feb 2026, Mar 2026), same schema

Both use the standard RSC "Object Capacity Over Time" report format (31 columns).

## How the Script Works

1. **Input mode** — local CSV via `-csvPath`, or pull from RSC via `-RscServiceAccountJson` + `-reportID`. Use `-getRscReportList` to list available Capacity Over Time reports.
2. **CSV column validation** — verifies required columns exist (identity + capacity + time fields)
3. **Load & filter** — imports CSV, drops rows with zero capacity across all metrics (~67% of rows are zeros)
4. **Auto-detect granularity** — parses `Time` field format to determine daily (`"Apr 01, 2026"`) vs monthly (`"Feb 2026"`)
5. **Resolve comparison dates** — maps lookback periods to actual dates in the CSV, clamping to oldest if needed
6. **Build hashtable** — single pass, 4-part unique key (`Cluster+Name+Location+ObjectType`), backfills equivalent fields, stores raw bytes
7. **Calculate diffs** — iterates union of all keys, computes baseline - comparison for all 5 metrics, handles both net-new and deleted objects
8. **Summarize** — aggregates totals (TB) and object counts by type (dynamic, not hardcoded categories)
9. **Output** — HTML (email-safe, inline styles) with summary + top N tables, CSV with all details

## Key Design Decisions Made in This Session

These were discussed and agreed upon one-by-one:

1. **Dual input mode** — local CSV via `-csvPath`, or pull directly from RSC via `-RscServiceAccountJson` + `-reportID`. RSC functions copied inline (standalone script).
2. **4-part unique key** — `Cluster+Name+Location+ObjectType`. Originally planned as 3-part, changed to 4-part after discovering M365 objects share names across types (Teams vs Site).
3. **Auto-detect daily vs monthly** — from Time field format. Defaults: daily = `-7, -14, -30`, monthly = `-1, -3, -6, -12`. User can override via `-compDates`.
4. **Date clamping** — if CSV doesn't go back far enough, substitute oldest date and drop further lookbacks. If only 3 days of data, result is just `-3 Days`.
5. **Backfill = take the max** — for Data Stored/Local Storage and Logical Bytes/Provisioned Size pairs. Handles inconsistent population across object types.
6. **Raw bytes until display** — all calculations in bytes for precision. Convert to GB/TB only at output time.
7. **Dynamic object types** — summary table columns come from whatever types appear in the data. No hardcoded categories. May get wide; table splitting deferred.
8. **Bidirectional diffs** — deleted objects (missing at baseline) get Status="Deleted" with negative changes. Net new objects get positive changes. Uses union of all keys.
9. **Duplicate handling** — same key+date duplicates (mostly NCD objects) resolved by keeping higher Data Stored value. Duplicates logged.
10. **Top N by Local Storage change** — default. Can be made configurable later. All 5 metric diffs are always calculated.
11. **Email-safe HTML** — inline styles only, no `<style>` block. Zebra striping, conditional coloring (gold=growth, green=shrinkage, gray=zero), comma-formatted numbers.
12. **Metadata from most recent appearance** — for deleted objects, use metadata from their last date in the data.

## Test Results

### 30-day CSV
```
Loaded 87174 rows → Filtered to 28851
Detected: Daily, 29 dates (2026-03-21 to 2026-04-18)
Resolved: -7 Days → 2026-04-11, -14 Days → 2026-04-04, -28 Days → 2026-03-21 (clamped from -30)
1005 unique objects (Active: 953, Deleted: 52)
2179 duplicates resolved (NCD objects)
```

### 12-month CSV
```
Loaded 7872 rows → Filtered to 2019
Detected: Monthly, 2 dates (2026-02-01 to 2026-03-01)
Resolved: -1 Months → 2026-02-01 (only comparison possible with 2 months)
1006 unique objects (Active: 984, Deleted: 22)
151 duplicates resolved
```

## Capacity Metric Definitions

These are the business definitions Steven provided:

1. **Logical Bytes / Provisioned Size** — front-end size of the entire object (e.g., total size of all disks provisioned to a VM)
2. **Used Size** — consumed size on disk (bytes actually written)
3. **Data Stored / Local Storage** — data on Rubrik after data reduction, across all backups in retention period
4. **Archive Storage** — data used in the archive location
5. **Replica Storage** — data used on the replication target

## Known Issues / Future Work

- **NCD duplicates** — 2,179 duplicate rows in the 30-day CSV (same object+date, slightly different values). Handled by keeping max, but root cause in the report itself is unclear.
- **Wide summary table** — with 50 object types, the summary table has many columns. Table splitting or category grouping may be needed later.
- **Interactive HTML / csv-report-viewer** — future phase to build a browsable UI for the change data instead of static email HTML.
- **Configurable sort metric** — currently hardcoded to Data Stored change for top N. Parameter to choose sort metric planned.
- **Performance** — filtering uses `+=` array appending which is slow for large datasets. Could switch to `[System.Collections.ArrayList]` or `[System.Collections.Generic.List[object]]` for the filtering phase.

## Conventions Established

- All project artifacts go under `computer/artifacts/<project-name>/`
- Always include `.PARAMETER` section in PowerShell script headers
- Design docs in `design.md`, data analysis in `data-analysis.md`, script analysis in `script-analysis.md`
