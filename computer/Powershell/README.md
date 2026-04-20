# Powershell

PowerShell scripts for Rubrik — download and run directly.

## Scripts

| Script | Description |
|--------|-------------|
| [`Get-Manage-CDM-Reports.ps1`](Get-Manage-CDM-Reports.ps1) | Manage custom reports on a Rubrik CDM cluster via the REST API — list, view, create, and export. Artifacts: [`Artifacts/Get-Manage-CDM-Reports/`](../Artifacts/Get-Manage-CDM-Reports/) |
| [`Get-RSC-Reports.ps1`](Get-RSC-Reports.ps1) | Manage custom reports on RSC via the GraphQL API — list, export CSV, view config, and create. Includes non-interactive mode (`-getCSV -reportID`). |
| [`Get-Capacity-Change-Report.ps1`](Get-Capacity-Change-Report.ps1) | Calculate capacity changes per object from an RSC "Object Capacity Over Time" report. Supports local CSV or direct RSC pull. Generates email-friendly HTML + detailed CSV. Artifacts: [`Artifacts/Get-Capacity-Change-Report/`](../Artifacts/Get-Capacity-Change-Report/) |
