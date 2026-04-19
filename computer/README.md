# computer

A collection of apps and scripts for Rubrik.

| Folder | Description |
|--------|-------------|
| [`Powershell/`](Powershell/) | All PowerShell scripts — download and run directly. |
| [`Artifacts/`](Artifacts/) | Supporting docs, examples, and reference materials organized by tool name. |
| [`HTML-Apps/`](HTML-Apps/) | Standalone browser-based tools — open directly in a browser, no server required. Includes `csv-report-viewer.html` for viewing and filtering report CSVs with column type detection and Rubrik branding. Artifacts: [`Artifacts/csv-report-viewer/`](Artifacts/csv-report-viewer/) |
| [`Core/`](Core/) | Reusable authentication blocks (RSC and CDM) — reference implementations copied inline into scripts. |

## Scripts

| Script | Description |
|--------|-------------|
| [`Get-Manage-CDM-Reports.ps1`](Powershell/Get-Manage-CDM-Reports.ps1) | Manage custom reports on a Rubrik CDM cluster via the REST API — list, view, create, and export. Artifacts: [`Artifacts/Get-Manage-CDM-Reports/`](Artifacts/Get-Manage-CDM-Reports/) |
| [`Get-RSC-Reports.ps1`](Powershell/Get-RSC-Reports.ps1) | Manage custom reports on RSC via the GraphQL API — list, export CSV, view config, and create. Includes non-interactive mode (`-getCSV -reportID`). |
