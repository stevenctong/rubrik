# Handoff — Rubrik CDM Report Tools

**Date:** 2026-04-24
**Author:** Steven Tong

---

## Overview

Two standalone tools for working with Rubrik CDM custom reports:

1. **`Get-Manage-CDM-Reports.ps1`** — PowerShell CLI for interactively (or non-interactively) listing, viewing, creating, and deleting CDM reports, managing email subscriptions, and configuring SMTP instances via the internal REST API. Outputs CSVs and HTML chart files to disk.
2. **`csv-report-viewer.html`** — Static browser-based CSV viewer with filtering, sorting, column type detection, and Rubrik branding. No backend or server required. Reads the CSVs that the script produces.

The two tools are intentionally decoupled. The script writes files to disk; the web app reads them via drag-and-drop or file picker. This avoids CORS and credential exposure — the browser never touches the cluster directly.

---

## Project Structure

```
computer/
├── Powershell/
│   ├── Get-Manage-CDM-Reports.ps1      # Main PowerShell script
│   └── Get-RSC-Reports.ps1
├── Artifacts/
│   └── Get-Manage-CDM-Reports/
│       ├── HANDOFF.md                  # This file
│       ├── README.md
│       ├── docs/
│       │   ├── Rubrik CDM 9.2 User Guide Excerpt- Chapter 27 Reports.pdf
│       │   └── Rubrik CDM 9.3 User Guide Excerpt - Chapter 27 Reports.pdf
│       └── reportExamples/             # Sample output files (CSV + HTML)
├── HTML-Apps/
│   ├── csv-report-viewer.html          # Standalone web app — open directly in browser
│   └── README.md
└── rsc-service-account-rr.json         # Service account credentials (gitignored)
```

`csv-report-viewer.html` lives in `HTML-Apps/` because it is a general-purpose tool — it works with any CSV from any script, not just this one.

---

## Get-Manage-CDM-Reports.ps1

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-serviceAccountPath` | Yes | Path to the CDM service account JSON file |
| `-clusterIP` | Yes | IP or hostname of the Rubrik CDM cluster |
| `-reportID` | No | Report ID to target in non-interactive mode |
| `-getCSV` | No | Non-interactive flag: download CSV for `-reportID` and exit |
| `-getHTML` | No | Non-interactive flag: generate HTML chart for `-reportID` and exit |

Test defaults for `-serviceAccountPath` and `-clusterIP` are hardcoded in the `param()` block so the script runs without arguments during development. Remove or update these before distributing.

### Usage — Interactive Mode

```powershell
./Get-Manage-CDM-Reports.ps1 -serviceAccountPath './rsc-service-account-rr.json' -clusterIP '10.8.49.104'
```

Launches the persistent interactive loop. Lists all reports; enter a row number or Report ID to select one. Enter `new` to create a report, `r` to refresh the list, or press Enter to exit.

### Usage — Non-Interactive Mode

```powershell
# Download CSV only
./Get-Manage-CDM-Reports.ps1 -serviceAccountPath './rsc-sa.json' -clusterIP '10.8.49.104' -reportID 'ReportId:::abc123' -getCSV

# Generate HTML chart only
./Get-Manage-CDM-Reports.ps1 -serviceAccountPath './rsc-sa.json' -clusterIP '10.8.49.104' -reportID 'ReportId:::abc123' -getHTML

# Both at once
./Get-Manage-CDM-Reports.ps1 -serviceAccountPath './rsc-sa.json' -clusterIP '10.8.49.104' -reportID 'ReportId:::abc123' -getCSV -getHTML
```

`-getCSV` and `-getHTML` can be combined. Both require `-reportID`; the script will error and exit if it is missing.

### Output Files

Output filenames are controlled by two variables near the top of the script in the `### VARIABLES ###` block:

```powershell
$csvOutputPrefix  = "./rubrik_"
$htmlOutputPrefix = "./rubrik_"
```

The report name (sanitized) and a timestamp are appended automatically:

```
./rubrik_<ReportName>-yyyy-MM-dd_HHmm.csv
./rubrik_<ReportName>-yyyy-MM-dd_HHmm.html
```

To write output to a subdirectory, set the prefix to include the path (e.g. `"./reports/rubrik_"`). The directory must already exist. Illegal filename characters are stripped; spaces become underscores.

### Authentication

Uses an **RSC Service Account JSON file**, passed into the CDM cluster's session API to obtain a bearer token. The `access_token_uri` must point to the CDM cluster, not to RSC:

```json
{
  "client_id": "client|...",
  "client_secret": "...",
  "access_token_uri": "https://<clusterIP>/api/client_token"
}
```

Token obtained via `POST /api/v1/service_account/session`. Session deleted on exit via `DELETE /api/v1/session/{id}`.

Requires **PowerShell 7+**.

### API Schema & Documentation

The CDM cluster exposes interactive Swagger API documentation at:

```
https://<clusterIP>/docs/v1        # v1 API (auth, sessions, etc.)
https://<clusterIP>/docs/internal  # internal API (reports — used by this script)
```

Swagger is the first place to look when exploring new endpoints or debugging unexpected responses. It lets you browse schemas and test calls live against the cluster.

**Important:** Swagger alone is not always sufficient. During development of the report creation wizard, the schema showed field names but did not document which enum values were valid per report template. The correct values for `chartType`, `taskType`, `taskStatus`, and `dateConfig.period` were only found by cross-referencing the **Rubrik CDM 9.2 User Guide, Chapter 27 (Reporting)** (included in `docs/`). That chapter contains tables listing the valid attributes, measures, table columns, and filter options for each of the 9 report templates — which is what populates `$templateConstraints` in the script.

When the API returns a `422 Unprocessable Content` error on a PATCH, the first thing to check is whether enum values match what the documentation specifies, not what seems intuitive (e.g. `chartType = 'Vertical'` not `'Bar'`; `taskType = 'Archival'` not `'Archive'`).

### Interactive Main Loop

| Input | Action |
|-------|--------|
| Row number or Report ID | Select that report |
| `new` | Launch the report creation wizard |
| `r` / `refresh` | Re-fetch and redisplay the report list |
| `smtp` | Enter SMTP instance management |
| *(Enter)* | Delete session and exit |

Report status is color-coded: **Ready** = green, **Updating** = yellow. Updating reports cannot be accessed — the list redisplays automatically. After any action (create, delete, view charts, download CSV), the loop returns to the report list.

On startup, the script checks whether any SMTP instances are configured. If not, warnings are shown when entering the email subscription screen or after creating a subscription, reminding the user to configure SMTP via the `smtp` command.

### Feature Menu (after selecting a report)

| Option | API Call | Output |
|--------|----------|--------|
| 1 — View charts | `GET /report/{id}/chart` | HTML file opened in browser |
| 2 — Export table as CSV | `GET /report/{id}/csv_link` → download | CSV file saved to disk |
| 3 — View config JSON | `GET /report/{id}` | Full config printed; press Enter to continue |
| 4 — Delete report | `DELETE /report/{id}` | Confirmation prompt required |
| 5 — Manage email subs | `GET/POST/PATCH/DELETE /report/email_subscription` | Interactive sub-menu (see below) |

### Chart HTML Generation

- Uses Chart.js (CDN) to render line charts.
- Byte-based measures (storage, data transferred, etc.) are auto-detected by keyword matching and auto-scaled to MB/GB/TB/PB.
- Month labels are reformatted from `yyyy-MM` to `MMM yyyy`.
- HTML is opened automatically in the default browser (`open` on macOS, `Start-Process` on Windows).
- Chart generation is implemented in the `Invoke-ChartHtml` function (defined in the HELPER FUNCTIONS section), called from both interactive and non-interactive paths.

### Report Creation Wizard (`new`)

Two-step CDM API flow:
1. **POST** `/api/internal/report` — creates a shell (name + template key only)
2. **PATCH** `/api/internal/report/{id}` — applies full configuration (filters, chart0, chart1, table columns)

The PATCH JSON body is always printed on both success and failure to aid debugging.

**9 report templates** are hardcoded from the CDM 9.2 User Guide (Ch. 27). They don't change often and fetching them live was removed in favor of reliability:

| Template Key | Display Name |
|---|---|
| `ProtectionTasksSummary` | Protection Tasks Summary |
| `ProtectionTasksDetails` | Protection Tasks Details |
| `RecoveryTasksDetails` | Recovery Tasks Details |
| `SlaComplianceSummary` | SLA Compliance Summary |
| `ObjectBackupTaskSummary` | Object Backup Task Summary |
| `ObjectIndexingSummary` | Object Indexing Summary |
| `ObjectProtectionSummary` | Object Protection Summary |
| `CapacityOverTime` | Capacity Over Time |
| `SystemCapacity` | System Capacity |

Each template has two modes:

- **Default** — uses hardcoded chart/table config from the user guide; optionally customize the date or snapshot range filter only.
- **Customize** — interactively select filters, chart type/attribute/measure, and table columns. All options are constrained to the valid values for that template (stored in `$templateConstraints`).

**Valid API enum values** (from CDM 9.2 User Guide — using wrong values causes 422 errors):

| Field | Valid Values |
|-------|-------------|
| `chartType` | `Vertical`, `Horizontal`, `Line`, `Donut`, `StackedVertical`, `StackedHorizontal` |
| `taskType` (filter) | `Backup`, `Archival`, `Replication` |
| `taskStatus` (filter) | `Succeeded`, `Failed`, `Canceled` |
| `dateConfig.period` | `Past24Hours`, `Past7Days`, `Past30Days`, `PastYear` |

---

## csv-report-viewer.html

A fully self-contained single-file web app. Open directly in a browser — no server needed. Located at `computer/HTML-Apps/csv-report-viewer.html`. Works with any report CSV, not just output from `Get-Manage-CDM-Reports.ps1`.

### Loading Data

- **Drag and drop** a CSV onto the drop zone (on initial load) or the "Import CSV" mini drop zone in the top bar (after a file is already loaded).
- **Click** either area to open a file picker.
- Loading a new CSV replaces the current data.

### Column Type Detection

Column types are inferred from the header name (normalized: lowercased, spaces/underscores removed):

| Type | Detection Rule | Rendering |
|------|---------------|-----------|
| **Capacity** | Name contains: `size`, `storage`, `datatransferred`, `datastored`; or exactly: `logicalbytes`, `bytestransferred`, `localmetereddata` | Right-aligned, divided by selected unit, blue badge |
| **Duration** | Name contains `duration` | Right-aligned, divided by selected unit, purple badge |
| **Date** | Name ends in `Time`, `Date`, `Snapshot`, `Stamp`, `On`; confirmed by ISO date value in first 20 rows; or exactly `starttime`/`endtime` | Monospace, timezone-converted, green badge |
| **Enum** | Name contains: `taskstatus`, `tasktype`, `objecttype`, `clustername` | Multi-select dropdown filter |
| **Numeric** | All sampled values parseable as numbers (and not any above type) | Right-aligned |
| **Text** | Everything else | Left-aligned, text filter |

### Top Bar Controls

| Control | Options | Effect |
|---------|---------|--------|
| Timezone | UTC / PT / MT / CT / ET | Converts all date columns; always visible |
| Capacity | GB / TB | Divides capacity columns; always visible |
| Duration | Sec / Min / Hr | Divides duration columns by 1 / 60 / 3600; always visible |
| Import CSV | Click or drag & drop | Loads a new CSV file |

All controls are always visible regardless of whether a CSV is loaded.

### Filtering & Sorting

- **Global search** — filters across all columns simultaneously.
- **Per-column text filters** — substring match, shown in the filter row below the header.
- **Enum multi-select** — dropdown with search, Select All / Clear; highlighted when active.
- **Column sort** — click any header; click again to reverse; sort icon indicates direction.
- **Clear filters** button — resets all filters and search.

### Pagination

Page size is 10,000 rows. Prev/Next buttons and page indicator in the footer. Row count and filter state shown in both toolbar and footer.

### Branding

Uses Rubrik primary color `#00B2A9` (teal) for the topbar and footer. Table header uses `#007A73` (darker teal). Active toggle buttons are white with teal text.

### Email Subscription Management (option 5)

Manages scheduled email subscriptions on individual reports. The CDM cluster sends an HTML email containing report charts and the first 100 table rows, with an optional CSV attachment.

**Navigation:** Two-level menu structure.
- **Level 1 (list):** Lists all subscriptions for the selected report in a table (schedule type, hour, recipients, CSV toggle, status, owner). Enter a row number to manage, `new` to create, or Enter to go back.
- **Level 2 (detail):** GETs the subscription by ID, displays full details. Options: `1` to update (PATCH), `2` to delete, Enter to go back. After update, re-GETs and redisplays (stays in Level 2). After delete, returns to Level 1.

When Level 1 re-fetches and finds zero subscriptions after an action, it auto-returns to the report menu.

**API endpoints (all under `/api/internal/`):**

| Action | Method | Endpoint |
|--------|--------|----------|
| List subs for report | GET | `/report/{id}/email_subscription` |
| Create sub | POST | `/report/{id}/email_subscription` |
| Get sub by ID | GET | `/report/email_subscription/{subscription_id}` |
| Update sub | PATCH | `/report/email_subscription/{subscription_id}` |
| Delete sub | DELETE | `/report/email_subscription/{subscription_id}` |

**`timeAttributes` object:** Only include fields relevant to the chosen schedule type — the API rejects payloads with all fields populated.
- Daily: `{ dailyScheduleHour }` only
- Weekly: `{ weeklyScheduleHour, daysOfWeek }` only (daysOfWeek: 0=Sun … 6=Sat)
- Monthly: `{ monthlyScheduleHour, dayOfMonth }` only

**PowerShell array serialization gotcha:** `ConvertTo-Json` collapses single-element arrays to scalars. Fields like `emailAddresses` and `attachments` must be cast to `[string[]]` before being assigned to the hashtable to ensure they serialize as JSON arrays.

### SMTP Instance Management (`smtp` command)

Manages cluster-wide SMTP server configuration. At least one SMTP instance must be configured for email subscriptions to deliver.

**Navigation:** Same two-level pattern as email subscriptions.
- **Level 1 (list):** Lists all SMTP instances (hostname, port, security, username, from email). Enter a row number to manage, `new` to create, Enter to go back.
- **Level 2 (detail):** GETs instance by ID, displays details. Options: update (PATCH), delete, or back. Update re-GETs to verify. Delete returns to Level 1.

**API endpoints (all under `/api/internal/`):**

| Action | Method | Endpoint |
|--------|--------|----------|
| List all | GET | `/smtp_instance` |
| Create | POST | `/smtp_instance` |
| Get by ID | GET | `/smtp_instance/{id}` |
| Update | PATCH | `/smtp_instance/{id}` |
| Delete | DELETE | `/smtp_instance/{id}` |

**POST/PATCH body fields:** `smtpHostname`, `smtpPort`, `smtpSecurity` (NONE/SSL/STARTTLS), `smtpUsername`, `smtpPassword`, `fromEmailId`, `certificateId`. Password is write-only (not returned in GET). Only populated fields are sent.

**Startup SMTP check:** On auth, the script queries `/smtp_instance` and sets `$script:smtpConfigured`. This flag triggers warnings in two places:
1. Entering the email subscription screen
2. After successfully creating an email subscription

The flag is kept in sync by the `Manage-SmtpInstances` function (updated on every list fetch, create, and delete).

---

## Known Limitations

- **CORS**: The web app cannot call the Rubrik API directly. A local HTTP proxy would be required to enable cluster connectivity from the browser (deferred — see Future Work).
- **Chart type**: The HTML chart output always renders as a line chart regardless of the report's configured chart type. The CDM chart data structure does not include a rendering hint.
- **Duration units**: Duration values in CSVs are assumed to be in seconds. If Rubrik ever changes this the divisors would need updating.
- **Template data**: The 9 templates and their constraints are hardcoded. If Rubrik adds a new template type it must be added manually to `$apiTemplates` and `$templateConstraints`.

---

## Potential Future Work

- **Local HTTP proxy** (`report-server.ps1`) — PowerShell `HttpListener` that serves the web app and proxies Rubrik API calls, enabling the "Connect to Cluster" workflow directly from the browser.
- **Chart type fidelity** — Map CDM chart types (`Vertical`, `Donut`, etc.) to Chart.js chart types (`bar`, `doughnut`, etc.) in the HTML output.
- **Multi-cluster support** — Accept an array of cluster IPs and aggregate report data.
- ~~**Report scheduling** — Trigger on-demand report refresh via the CDM API from the script.~~ Done — email subscription management (daily/weekly/monthly schedules) implemented in 4/24/26 update.
