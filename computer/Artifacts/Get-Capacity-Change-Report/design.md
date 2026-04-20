# Get-Capacity-Change-Report — Design Document

## Overview

PowerShell script that processes an RSC "Object Capacity Over Time" CSV, calculates capacity changes per object across time periods, and generates an email-friendly HTML report + CSV with all details. Supports both local CSV input and pulling reports directly from RSC via GraphQL API.

**Future phase:** Interactive HTML app or integration with csv-report-viewer for browsing change data. Not in scope now — the HTML output is designed for email delivery only.

---

## Input

Two input modes (mutually exclusive):

- **Local CSV** (`-csvPath`) — provide a previously downloaded RSC "Object Capacity Over Time" report CSV
- **RSC pull** (`-RscServiceAccountJson` + `-reportID`) — authenticate to RSC via service account and download the report CSV directly via GraphQL API. Use `-getRscReportList` to list available Capacity Over Time reports.

The RSC report must be a "Capacity Over Time" type. Reports with a time range up to 30 days produce daily data points; reports with a time range >30 days produce monthly data points (first of each month).

### CSV Schema (31 columns)

The script expects the standard RSC "Object Capacity Over Time" report format:

| Column | Used By Script |
|--------|---------------|
| Time | Date of data point (detect granularity) |
| Cluster Name | Part of unique ID |
| Object Name | Part of unique ID |
| Location | Part of unique ID |
| Object Type | Object type categorization (dynamic) |
| Logical Bytes | Front-end size metric (raw bytes) |
| Data Stored | Rubrik local storage metric (raw bytes) |
| Local Storage | Equivalent to Data Stored (raw bytes) |
| Archive Storage | Archive target storage (raw bytes) |
| Replica Storage | Replication target storage (raw bytes) |
| Used Size | Consumed size on source disk (raw bytes) |
| Provisioned Size | Equivalent to Logical Bytes (raw bytes) |
| SLA Domain | Display in results |
| Protected On | Display in results |
| Local Data Reduction | Display in results |
| Local Dedup Ratio | Display in results |

Other columns (Data Transferred, CDP fields, ratios, NCD Snapshot Type, etc.) are passed through to the CSV output but not used in calculations.

### Capacity Metric Definitions

These are the 5 capacity metrics the script tracks:

1. **Logical Bytes / Provisioned Size** — the front-end provisioned size of the entire object (e.g., total size of all disks provisioned to a VM). These are equivalent fields; backfill from whichever has the larger value.
2. **Used Size** — the consumed size of the object on disk (bytes actually written). Standalone, no equivalent field.
3. **Data Stored / Local Storage** — the amount of data on Rubrik after data reduction, across all backups in the retention period. These are equivalent fields; backfill from whichever has the larger value.
4. **Archive Storage** — the amount of data used in the archive location for each object. Standalone.
5. **Replica Storage** — the amount of data used on the replication target for each object. Standalone.

---

## Parameters

```powershell
param (
  # Path to the RSC "Object Capacity Over Time" CSV (local/offline mode)
  [Parameter(Mandatory=$false)]
  [string]$csvPath,

  # RSC Service Account JSON file path (RSC pull mode)
  [Parameter(Mandatory=$false)]
  [string]$RscServiceAccountJson,

  # RSC Report ID to pull and process
  [Parameter(Mandatory=$false)]
  [int]$reportID,

  # List available "Capacity Over Time" reports from RSC and exit
  [Parameter(Mandatory=$false)]
  [switch]$getRscReportList,

  # Location and prefix for downloaded RSC report CSV. Timestamp appended automatically.
  [Parameter(Mandatory=$false)]
  [string]$rscReportCSVOutputPrefix = './rsc_capacity_over_time_report_',

  # Override default lookback periods (e.g. @(-7, -14, -30) for daily, @(-1, -3, -6, -12) for monthly)
  [Parameter(Mandatory=$false)]
  [int[]]$compDates,

  # Number of top objects to show in HTML report per time period
  [Parameter(Mandatory=$false)]
  [int]$topNum = 20,

  # Location and prefix for output CSV file. Report name and timestamp appended automatically.
  [Parameter(Mandatory=$false)]
  [string]$csvOutputPrefix = './rubrik_',

  # Location and prefix for output HTML file. Report name and timestamp appended automatically.
  [Parameter(Mandatory=$false)]
  [string]$htmlOutputPrefix = './rubrik_',

  # Send email
  [Parameter(Mandatory=$false)]
  [switch]$sendEmail,

  # SMTP configuration (only used if $sendEmail)
  [Parameter(Mandatory=$false)]
  [string[]]$emailTo,
  [Parameter(Mandatory=$false)]
  [string]$emailFrom,
  [Parameter(Mandatory=$false)]
  [string]$SMTPServer,
  [Parameter(Mandatory=$false)]
  [string]$SMTPPort = '25'
)
```

---

## Processing Pipeline

### Phase 1: Load, Filter & Detect Granularity

1. Import CSV via `Import-Csv`
2. **Filter out zero-capacity rows:** Skip any row where ALL of these are 0/empty/N/A: Logical Bytes, Used Size, Data Stored, Local Storage, Archive Storage, Replica Storage. Objects with capacity on some dates but not others are still included — only rows that are completely empty across all metrics are dropped.
3. Detect granularity from `Time` field format:
   - `"MMM DD, YYYY"` (e.g. `"Apr 01, 2026"`) → **daily** report → default `$compDates = @(-7, -14, -30)`
   - `"MMM YYYY"` (e.g. `"Feb 2026"`) → **monthly** report → default `$compDates = @(-1, -3, -6, -12)`
4. Parse all `Time` values into `[datetime]` objects
5. Determine the sorted list of distinct dates
6. Identify the most recent date as the **baseline**
7. **Edge case:** If only one date exists, warn and output summary only (no comparisons possible)

### Phase 2: Resolve Comparison Dates

For each lookback period in `$compDates`:
1. Calculate the target date (baseline minus N days/months)
2. Check if that exact date exists in the CSV's distinct date list
3. If the target date doesn't exist:
   - Substitute the **oldest date** in the CSV
   - Drop all subsequent (further back) lookback periods (they'd be even older)
4. Deduplicate — if multiple lookbacks resolve to the same date, keep only one

**Result:** A clean list of `$resolvedCompDates`, each mapped to an actual date present in the CSV. Each entry tracks both the original lookback label (e.g. "-7 Days") and the actual resolved date.

**Example — 30-day report with only 17 days of data:**
- Default lookbacks: -7, -14, -30
- -7 exists → keep
- -14 exists → keep
- -30 doesn't exist → substitute oldest date (17 days ago), drop further lookbacks
- Result: -7, -14, -17

**Example — 30-day report with only 3 days of data:**
- -7 doesn't exist → substitute oldest (3 days ago), drop -14 and -30
- Result: -3

### Phase 3: Build Unique IDs, Backfill & Store in Hashtable

The primary data structure is a hashtable keyed by unique ID for O(1) lookups.

For each row in the CSV (single pass):
1. Create unique key: `"$ClusterName+$ObjectName+$Location+$ObjectType"` (uniform 4-part key, no special cases)
2. Parse capacity fields robustly (handle empty, "N/A", "-", "0" — all treated as 0)
3. **Backfill equivalent fields** — take the **max** of the pair:
   - `Data Stored` ↔ `Local Storage` → use whichever is larger for both
   - `Logical Bytes` ↔ `Provisioned Size` → use whichever is larger for both
4. **Store all values in raw bytes** — no conversion to GB until display time (preserves precision for diff calculations)
5. **Handle duplicates:** If the same unique key + date already exists in the hashtable, keep the row with the higher Data Stored value. Add the duplicate to a `$duplicates` array for flagging.
6. Store metadata (Object Type, SLA Domain, Protected On, etc.) from the row

**Hashtable structure:**
```powershell
$objectData = @{}
$objectData["ClusterName+ObjectName+Location"] = @{
    ObjectName = "..."
    ClusterName = "..."
    Location = "..."
    ObjectType = "..."          # from most recent date
    SLADomain = "..."           # from most recent date
    ProtectedOn = "..."         # from most recent date
    LocalDataReduction = "..."  # from most recent date
    LocalDedupRatio = "..."     # from most recent date
    MostRecentDate = [datetime] # track which date metadata came from
    Status = "Active"           # or "Deleted"
    Dates = @{
        [datetime] = @{
            LogicalBytes = [double]     # raw bytes
            UsedSize = [double]         # raw bytes
            DataStored = [double]       # raw bytes (after backfill)
            ArchiveStorage = [double]   # raw bytes
            ReplicaStorage = [double]   # raw bytes
        }
    }
}
```

### Phase 4: Calculate Diffs

Iterate over the **union** of all unique keys (not just baseline objects):
1. Determine object **Status**:
   - If the object exists at baseline → `"Active"`, use baseline metadata
   - If the object does NOT exist at baseline → `"Deleted"`, use metadata from its most recent date
2. For each resolved comparison date:
   - Get baseline values (default to 0 if object missing at baseline — deleted objects)
   - Get comparison values (default to 0 if object missing at comparison date — net new objects)
   - Calculate change = baseline bytes - comparison bytes (for each of the 5 metrics)
3. **All diffs stored in raw bytes** — conversion happens at display time

**Result for each object:**
- Status (Active / Deleted)
- Baseline values (5 metrics, raw bytes)
- Per comparison date: old values + change values (5 metrics each, raw bytes)

### Phase 5: Build Summary Table

For each date (baseline + each comparison date), aggregate across all objects that have data on that date:
- **Total capacities in TB:** Logical Bytes, Data Stored/Local Storage, Archive Storage, Replica Storage
- **Object counts by type:** Dynamic — count distinct objects per `Object Type` value. Columns determined by whatever types appear in the data (no hardcoded categories).
- **Total object count**

### Phase 6: Top N Selection

- For each comparison period, sort all objects by **Data Stored / Local Storage change** descending
- Take top `$topNum` (default 20)
- Default sort metric is Data Stored/Local Storage change; can be made configurable via parameter later
- Both active and deleted objects participate in ranking (deleted objects will have negative changes)

### Phase 7: Generate Outputs

#### CSV Output
- All objects with all capacity values and changes, converted to GB at output time
- Filename: `rubrik_capacity_change_report-YYYY-MM-DD_HHMM.csv`

#### HTML Output (email-optimized)
- See HTML Design section below
- Filename: `rubrik_capacity_change_report-YYYY-MM-DD_HHMM.html`

#### Email (optional)
- HTML body + CSV attachment via `Send-MailMessage`

---

## HTML Report Design (Email-Optimized)

### Constraints
- **Inline styles only** — no `<style>` block (stripped by Outlook, Gmail)
- **No CSS features:** no variables, no `:hover`, no `:nth-child`, no `position: sticky`
- **No external fonts** — use `Arial, sans-serif` (safe everywhere)
- **Tables for layout** — already the approach, works in all email clients

### Structure

```
┌──────────────────────────────────────────────────┐
│  RUBRIK CAPACITY CHANGE REPORT     (#00B2A9 bar) │
├──────────────────────────────────────────────────┤
│  Report Generated: YYYY-MM-DD                    │
│  Source CSV: <filename>                           │
│  Report Type: Daily (30 days) / Monthly (12 mo)  │
│  Baseline Date: <most recent date>               │
├──────────────────────────────────────────────────┤
│                                                  │
│  SUMMARY TABLE                                   │
│  ┌────────┬──────┬──────┬──────┬──────┬────────┐ │
│  │ Date   │Log TB│LS TB │Ar TB │Re TB │Obj Cnt │ │
│  │        │      │      │      │      │per type│ │
│  ├────────┼──────┼──────┼──────┼──────┼────────┤ │
│  │baseline│ ...  │ ...  │ ...  │ ...  │  ...   │ │
│  │ -7 days│ ...  │ ...  │ ...  │ ...  │  ...   │ │
│  │-14 days│ ...  │ ...  │ ...  │ ...  │  ...   │ │
│  │-30 days│ ...  │ ...  │ ...  │ ...  │  ...   │ │
│  └────────┴──────┴──────┴──────┴──────┴────────┘ │
│                                                  │
│  TOP 20: LOCAL STORAGE CHANGE — -7 DAYS          │
│  ┌──────┬────┬────┬──────┬──────┬──────┬───────┐ │
│  │Object│Loc │Type│ΔLocal│Local │Local │Archive│ │
│  │      │    │    │ (GB) │Now   │ -7d  │Now    │ │
│  ├──────┼────┼────┼──────┼──────┼──────┼───────┤ │
│  │ ...  │    │    │color │      │      │       │ │
│  └──────┴────┴────┴──────┴──────┴──────┴───────┘ │
│                                                  │
│  (repeat for each comparison period)             │
│                                                  │
└──────────────────────────────────────────────────┘
```

### Styling Details

| Element | Style |
|---------|-------|
| Header bar | Background: #00B2A9, white text, 20px font, 16px padding |
| Report info | 13px Arial, #333333, no background |
| Summary table headers | 13px bold, #00B2A9 text, white background, bottom border |
| Summary table data | 12px, center-aligned, bottom border #ddd |
| Summary — capacity totals | Bold for Local Storage and Object count columns |
| Top N section header | Merged row, 15px bold, #333333, light gray background (#f5f5f5) |
| Top N table headers | 12px bold, #00B2A9 text |
| Top N data rows | 12px, left-align for Object/Location, center for rest |
| Zebra striping | Even rows: #f9f9f9 background (hardcoded per row during generation) |
| Change column — positive | Text color: #D4870F (amber/gold) — growth |
| Change column — negative | Text color: #2E8B57 (green) — shrinkage |
| Change column — zero | Text color: #999999 (gray) |
| Number formatting | Comma-separated thousands (e.g. 35,818.12) |
| Font | `Arial, sans-serif` everywhere |

### Top N Table Columns

For each comparison period, the top N table shows:

| Column | Description |
|--------|-------------|
| Object Name | Left-aligned |
| Location | Left-aligned |
| Object Type | Center |
| Status | Active / Deleted |
| **Local Storage Change (GB)** | Conditionally colored (primary sort) |
| Local Storage: Baseline (GB) | Current value |
| Local Storage: -N Days (GB) | Old value |
| Archive Storage: Baseline (GB) | Current archive |
| Archive Storage: -N Days (GB) | Old archive |
| Replica Storage: Baseline (GB) | Current replica |

---

## Output Files

| File | Format | Contents |
|------|--------|----------|
| `rubrik_capacity_change_report-YYYY-MM-DD_HHMM.html` | HTML (email-safe) | Summary table + top N tables per period |
| `rubrik_capacity_change_report-YYYY-MM-DD_HHMM.csv` | CSV | All objects, all capacity values + changes per period |

### CSV Columns

The CSV includes every object (active + deleted) with the following columns (in order):

1. Object Name
2. Cluster Name
3. Location
4. UniqueKey
5. Object Type
6. Status (Active / Deleted)
7. SLA Domain
8. Protected On
9. For each capacity metric (Logical Bytes, Used Size, Data Stored, Archive Storage, Replica Storage):
   - Current value (GB)
   - Value at each comparison date (GB)
   - Change from each comparison date (GB)
10. Local Data Reduction (%)
11. Local Dedup Ratio (x)

---

## Data Compensations & Workarounds

The RSC "Object Capacity Over Time" CSV has several inconsistencies and missing features that the script must compensate for:

### 1. No Unique Object Identifier

The CSV does not include a unique object UUID/ID. The same object name can appear across different clusters, locations, or object types. The script synthesizes a 4-part composite key: `ClusterName+ObjectName+Location+ObjectType`. This is necessary because:
- The same VM name can exist on different clusters (e.g. `sh1-PaloAlto` and `sh2-Cork`)
- M365 objects can share the same name but be different object types (e.g., the same name appearing as both "Teams" and "Site")
- Some objects have empty Location fields (cloud workloads, MongoDB), which is valid — the key still works as `Cluster+Name++Type`

### 2. Equivalent Metric Fields with Inconsistent Population

The CSV has two pairs of fields that represent the same metric but are inconsistently populated across object types:

- **Data Stored / Local Storage** — both represent Rubrik local storage after data reduction. ~97% of the time they match when both are populated, but 1,724 rows (in the 30-day sample) have Data Stored with no Local Storage, and 0 rows have the reverse. Different object types populate one or the other.
- **Logical Bytes / Provisioned Size** — both represent front-end provisioned size. These frequently differ even when both are populated (80% of the time), because Logical Bytes can represent total capacity while Provisioned Size may represent a subset. However, many object types only populate one of the two.

The script backfills by taking the **max** of each pair. This ensures we always have the best available value regardless of which field the object type populated.

### 3. Inconsistent Missing Value Representations

Capacity fields use multiple representations for "no data": empty string, `"N/A"`, `"-"`, and `"0"`. The script normalizes all of these to `0` during parsing via a robust parser that handles each case.

### 4. Date Format Varies by Report Type

The `Time` field uses different formats depending on whether the report is daily or monthly:
- Daily: `"MMM DD, YYYY"` (e.g., `"Apr 01, 2026"`)
- Monthly: `"MMM YYYY"` (e.g., `"Feb 2026"`)

The script auto-detects the format and parses accordingly. For monthly reports, the date is normalized to the 1st of the month for consistent date arithmetic.

### 5. Duplicate Rows for the Same Object + Date

Some object types (particularly NAS Cloud Direct) produce multiple rows for the same object on the same date with slightly different capacity values. In the 30-day sample, 2,179 such duplicates were found. The script resolves these by keeping the row with the higher Data Stored value and logging the duplicates for review.

### 6. Report Date Range May Not Cover Requested Lookback Periods

The CSV may not contain enough history to satisfy all default lookback periods (e.g., a 17-day report can't provide a -30 day comparison). The script clamps to the oldest available date when a requested lookback exceeds the data range, and drops any further lookbacks that would be even older.

### 7. Objects Appear and Disappear Over Time

Objects can be added to or removed from protection between report dates. The script handles both directions:
- **Net new objects** (present at baseline, absent at comparison date): old values treated as 0, resulting in positive changes
- **Deleted objects** (absent at baseline, present at comparison date): baseline values treated as 0, resulting in negative changes. These are tagged with `Status = "Deleted"` and their metadata comes from their most recent appearance in the data.

---

## Key Design Decisions

These decisions were made through discussion and should be followed during implementation:

1. **Dual input mode** — local CSV via `-csvPath` or direct RSC pull via `-RscServiceAccountJson` + `-reportID`. RSC functions are copied inline (standalone script, no dot-sourcing).

2. **Uniform 4-part unique key** — `ClusterName+ObjectName+Location` for all object types. No special cases (v1 had a VM-only exception). Empty Location is valid (key becomes `Cluster+Name+`).

3. **Auto-detect granularity** — daily vs monthly determined from Time field format. User can override `$compDates` but defaults are sensible.

4. **Lookback date clamping** — if the CSV doesn't go back far enough for a lookback period, use the oldest available date and drop further lookbacks. Dedup if multiple lookbacks resolve to the same date.

5. **Backfill = take the max** — for equivalent field pairs (Data Stored/Local Storage, Logical Bytes/Provisioned Size), use whichever value is larger. Handles cases where one is 0/N/A/empty and the other has data.

6. **Store raw bytes, convert at display time** — all calculations in raw bytes to preserve precision. Conversion to GB/TB happens only during HTML/CSV generation.

7. **Dynamic object types** — no hardcoded categories. Summary table columns come from whatever Object Type values appear in the data. May get wide with many types; table splitting can be addressed later.

8. **Bidirectional diff** — objects missing at baseline are "Deleted" (current = 0, negative change). Objects missing at comparison date are "Net New" (old = 0, positive change). Uses union of all unique keys, not just baseline objects.

9. **Deleted object tracking** — each object gets a `Status` field: "Active" or "Deleted". Available for filtering in CSV output and future UI integration.

10. **Metadata from most recent appearance** — Object Type, SLA Domain, etc. come from the most recent date the object appears in. For active objects that's the baseline; for deleted objects, it's their last appearance.

11. **Duplicate handling** — if the same unique key + date appears twice, keep the row with the higher Data Stored value. Track duplicates in an array for flagging/logging.

12. **Hashtable-based processing** — primary data structure is a hashtable keyed by unique ID for O(1) lookups. No `Add-Member` — use `[PSCustomObject]` or nested hashtables. Single pass through CSV for loading.

13. **Top N sorted by Local Storage change** — default sort metric for top N tables. Can be made configurable via parameter later. All 5 metric diffs are calculated regardless.

14. **Progress output** — print totals after load, resolved dates, percentage-based progress during processing (every 10%), and output file paths at the end. No per-object output.

15. **Email-safe HTML** — inline styles only, no `<style>` block, system fonts, zebra striping hardcoded per row, conditional text coloring for change values.

---

## Performance Considerations

- **Avoid `Add-Member`** — v1 used this heavily; it's slow due to reflection overhead. Build `[PSCustomObject]` once at output time.
- **Single-pass CSV loading** — build the hashtable in one loop through the imported CSV rows.
- **Hashtable lookups** — O(1) per object per date, vs v1's `Where-Object` filtering (O(n) per lookup).
- **Progress every 10%** — avoids console flood while keeping user informed.

---

## Not In Scope (Future Phases)

- Interactive HTML app for browsing change data
- Integration with csv-report-viewer
- Object type category grouping / table splitting for wide summary tables
- Configurable sort metric parameter for top N tables
