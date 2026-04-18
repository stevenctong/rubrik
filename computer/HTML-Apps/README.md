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

### Manage-CDM-Reports

Located separately at [`computer/Manage-CDM-Reports/`](../Manage-CDM-Reports/) — not part of this app, but pairs well with it.

It is a PowerShell script that connects to a Rubrik CDM cluster via the REST API to list, create, delete, and export custom reports. Use it to download report CSVs, then drag them into `csv-report-viewer.html`.
