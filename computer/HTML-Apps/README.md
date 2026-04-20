# HTML-Apps

Standalone browser-based tools. Each app is a single HTML file — open directly in a browser, no server required.

## csv-report-viewer.html

A CSV viewer with filtering, sorting, column type detection, timezone conversion, and Rubrik branding.

- **Capacity columns** — auto-detected, toggle between GB / TB
- **Duration columns** — auto-detected, toggle between Sec / Min / Hr
- **Date columns** — auto-detected, convert across UTC / PT / MT / CT / ET
- **Enum columns** — multi-select dropdown filter
- **Global search** and per-column filters with sortable headers

Load a CSV by dragging it onto the drop zone or clicking to browse.

---

## Cross-Reference

### Get-Manage-CDM-Reports

Located at [`computer/Powershell/Get-Manage-CDM-Reports.ps1`](../Powershell/Get-Manage-CDM-Reports.ps1) — not part of this app, but pairs well with it. Supporting docs and examples are in [`Artifacts/Get-Manage-CDM-Reports/`](../Artifacts/Get-Manage-CDM-Reports/).

It is a PowerShell script that connects to a Rubrik CDM cluster via the REST API to list, create, and export custom reports. Use it to download report CSVs, then drag them into `csv-report-viewer.html`.

### Get-Capacity-Change-Report

Located at [`computer/Powershell/Get-Capacity-Change-Report.ps1`](../Powershell/Get-Capacity-Change-Report.ps1) — calculates capacity changes per object from an RSC "Object Capacity Over Time" report. Outputs a detailed CSV (among other formats) that can be viewed in `csv-report-viewer.html`. Supporting docs in [`Artifacts/Get-Capacity-Change-Report/`](../Artifacts/Get-Capacity-Change-Report/).
