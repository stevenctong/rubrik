# Manage-CDM-Reports

PowerShell script for managing custom reports on a Rubrik CDM cluster via the internal REST API. Supports interactive and non-interactive (scripted) operation.

## Features

- **List reports** — displays all reports with name, status (color-coded), ID, and template type
- **View charts** — fetches chart data and generates a local HTML file with Chart.js visualizations, opened automatically in the browser
- **Export CSV** — downloads the report's table data as a timestamped CSV
- **View config JSON** — fetches and displays the full report configuration via `GET /report/{id}`
- **Delete reports** — with confirmation prompt
- **Create reports** — guided wizard supporting all 9 CDM report templates in Default or Customize mode
- **Non-interactive mode** — pass `-getCSV` / `-getHTML` with a `-reportID` to skip the prompt and run from a script or scheduler

## Requirements

- PowerShell 7+
- Network access to the Rubrik CDM cluster
- A CDM service account JSON file (see Authentication below)

## Authentication

The script uses an **RSC Service Account JSON file**, passed into the CDM cluster's session API to obtain a bearer token. The `access_token_uri` in the JSON must point to the CDM cluster (not to RSC):

```json
{
  "client_id": "client|...",
  "client_secret": "...",
  "access_token_uri": "https://<clusterIP>/api/client_token"
}
```

## Usage

### Interactive

```powershell
./Manage-CDM-Reports.ps1 -serviceAccountPath './rubrik-sa.json' -clusterIP '10.8.49.104'
```

Lists all reports. Enter a row number or Report ID to select a report, then choose:

```
1 - View charts (generates HTML, opens in browser)
2 - Export table data as CSV
3 - View report config JSON
4 - Delete report
```

Enter `new` to create a report using the wizard. Enter `r` to refresh the list. Press Enter to exit.

### Non-Interactive

```powershell
# Download CSV for a specific report
./Manage-CDM-Reports.ps1 -serviceAccountPath './rubrik-sa.json' -clusterIP '10.8.49.104' `
  -reportID 'ReportId:::abc123' -getCSV

# Generate HTML chart file
./Manage-CDM-Reports.ps1 -serviceAccountPath './rubrik-sa.json' -clusterIP '10.8.49.104' `
  -reportID 'ReportId:::abc123' -getHTML

# Both at once
./Manage-CDM-Reports.ps1 -serviceAccountPath './rubrik-sa.json' -clusterIP '10.8.49.104' `
  -reportID 'ReportId:::abc123' -getCSV -getHTML
```

`-getCSV` and `-getHTML` both require `-reportID`. The script will error and exit if it is missing.

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-serviceAccountPath` | Yes | Path to the CDM service account JSON file |
| `-clusterIP` | Yes | IP address or hostname of the CDM cluster |
| `-reportID` | Conditional | Report ID — required when using `-getCSV` or `-getHTML` |
| `-getCSV` | No | Non-interactive: download CSV for the specified report and exit |
| `-getHTML` | No | Non-interactive: generate HTML chart for the specified report and exit |

## Output Files

Output filenames are controlled by `$csvOutputPrefix` and `$htmlOutputPrefix` in the `### VARIABLES ###` block at the top of the script. The report name and a timestamp are appended automatically:

```
./rubrik_<ReportName>-yyyy-MM-dd_HHmm.csv
./rubrik_<ReportName>-yyyy-MM-dd_HHmm.html
```

To write to a subdirectory, set the prefix to include the path (e.g. `"./reports/rubrik_"`). The directory must already exist.

## Viewing CSV Output

The CSV files produced by this script can be loaded into [`csv-report-viewer.html`](../HTML-Apps/csv-report-viewer.html) — a standalone browser-based viewer in the `HTML-Apps/` folder. Drag a CSV onto the drop zone or click to browse. The viewer handles column type detection (capacity, duration, date, enum), filtering, sorting, and timezone conversion with no server required.

## Report Templates

The creation wizard supports all 9 CDM report templates:

| Template | Display Name |
|----------|-------------|
| `ProtectionTasksSummary` | Protection Tasks Summary |
| `ProtectionTasksDetails` | Protection Tasks Details |
| `RecoveryTasksDetails` | Recovery Tasks Details |
| `SlaComplianceSummary` | SLA Compliance Summary |
| `ObjectBackupTaskSummary` | Object Backup Task Summary |
| `ObjectIndexingSummary` | Object Indexing Summary |
| `ObjectProtectionSummary` | Object Protection Summary |
| `CapacityOverTime` | Capacity Over Time |
| `SystemCapacity` | System Capacity |

Each template supports **Default** mode (uses the template's standard config) and **Customize** mode (interactive filter, chart, and column selection constrained to valid values per template).

## Files in This Folder

```
Manage-CDM-Reports/
├── Manage-CDM-Reports.ps1   # Main script
├── README.md                # This file
├── HANDOFF.md               # Developer/maintainer notes
├── docs/                    # Reference PDFs
│   ├── Rubrik CDM 9.2 User Guide Excerpt- Chapter 27 Reports.pdf
│   └── Rubrik CDM 9.3 User Guide Excerpt - Chapter 27 Reports.pdf
└── reportExamples/          # Sample CSV and HTML output
```

For developer notes — API schema location, enum quirks, architecture decisions, and future work — see [HANDOFF.md](HANDOFF.md).
