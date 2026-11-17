#requires -Version 7.0

# https://build.rubrik.com

<#
.SYNOPSIS
Gets BigQuery sizing information (datasets, tables, logical and physical bytes) for GCP projects.
Read-only. BigQuery only: no Compute Engine, Cloud SQL, or Spanner data is collected.

.DESCRIPTION
'Get-GCPBigQuerySizingInfo.ps1' collects one row per BigQuery table / materialized view / external
table / snapshot / view in the specified projects and exports a CSV and a log file, compressed
into a zip file. Send the resulting zip file to Rubrik for analysis.

Three collection methods are available, selected with -Method:

  InformationSchema (default, fastest)
      Runs one SQL query per project per dataset location against
      `region-<location>`.INFORMATION_SCHEMA.TABLE_STORAGE (via 'bq query'). Returns logical and
      physical bytes for every table in a handful of calls instead of one call per table.
      Requires: 'bq' on PATH and bigquery.jobs.create (see permissions below).
      Not included: views and external tables are not returned by TABLE_STORAGE, and
      NumberOfColumns / ExternalSource* columns are left empty.

  Rest
      Calls the BigQuery REST API (datasets.list, tables.list, tables.get) directly using an
      access token from 'gcloud auth print-access-token'. One tables.get call per table, run in
      parallel (see -ThrottleLimit). Does NOT require 'bq' and does NOT require bigquery.jobs.create.

  Bq
      Uses the 'bq' CLI ('bq ls' / 'bq show'), one call per table, sequentially. This is the same
      approach used by Get-GCPSizingInfo.ps1. Slowest, but needs only metadata read permissions.

By default, if the chosen method fails for a project (for example a permissions error), the
script automatically tries the next method in the order InformationSchema -> Bq -> Rest. Use
-NoFallback to try only the method selected with -Method.

Before collecting anything the script shows the account, the number of projects, and the method
order, and asks for confirmation. Use -Yes to skip the prompt (required when input is redirected).
At the end it prints a per-project result table and lists every project that failed or was skipped.

Pass a comma separated list of projects or a CSV/text file containing the project names. If no
project IDs are specified, all projects the logged in user can see are used.

PERMISSIONS (read-only; required on all projects):

  - resourcemanager.projects.get
  - bigquery.datasets.get
  - bigquery.tables.get
  - bigquery.tables.list
  - serviceusage.services.list        (to check that the BigQuery API is enabled)
  - bigquery.jobs.create              (InformationSchema method only)
  - bigquery.routines.get             (InformationSchema table-label query only)
  - bigquery.routines.list            (InformationSchema table-label query only)

Suggested roles: roles/bigquery.metadataViewer (+ roles/bigquery.jobUser for InformationSchema).

This script can be run from the Google Cloud Shell or from a laptop/server with PowerShell 7 and
the gcloud SDK installed and authenticated ('gcloud auth login'). 'bq' is included with the
standard gcloud SDK installer and is preinstalled in Cloud Shell.

All commands that touch GCP are read-only (gcloud projects list/describe, gcloud services list,
bq ls/show/query against INFORMATION_SCHEMA, and HTTPS GET requests to bigquery.googleapis.com).
No GCP resources or data are created, modified, or deleted. The InformationSchema method does run
'bq query' jobs against INFORMATION_SCHEMA views; these appear in BigQuery job history and are
billed at the on-demand minimum (a negligible cost).

.PARAMETER GetAllProjects
Flag (default) to find all projects that the user has access to and gather data.

.PARAMETER Projects
A comma separated list of GCP project IDs to gather data from.

.PARAMETER ProjectFile
Path to a file containing a list of GCP project IDs separated by line breaks. No header is required.

.PARAMETER Method
Collection method: InformationSchema (default), Rest, or Bq. See DESCRIPTION.

.PARAMETER Fallback
Deprecated, accepted for compatibility. Fallback is now the default behavior; see -NoFallback.

.PARAMETER NoFallback
Only try the method selected with -Method. By default, if the selected method fails for a project,
the script tries the next method in the order InformationSchema -> Bq -> Rest.

.PARAMETER Yes
Skip the confirmation prompt that is shown before collection starts. Required when the script is
run with redirected input (for example from a scheduler).

.PARAMETER ThrottleLimit
Rest method only. Number of parallel tables.get calls. Default 8.

.PARAMETER QuotaProject
Rest method only. Optional project to send in the 'x-goog-user-project' header (billing/quota
project). Normally not needed.

.PARAMETER SkipTableLabels
InformationSchema method only. Skip the extra TABLE_OPTIONS query that retrieves table-level labels.
Dataset-level labels are still collected.

.PARAMETER Anonymize
Anonymize data collected.

.PARAMETER AnonymizeFields
A comma separated list of fields in the resulting CSV to anonymize, encased in quotes with no spaces.

.PARAMETER NotAnonymizeFields
A comma separated list of fields in the resulting CSV to not anonymize (only required for fields
which are by default being anonymized). By default these fields are anonymized:
"Project", "DatasetId", "TableId", "ExternalSourceUri"
Specify "Tags" to exclude all label fields (properties starting with "Label/Tag:") from anonymization.

.NOTES
Based on Get-GCPSizingInfo.ps1 by Steven Tong (GitHub: stevenctong).

.EXAMPLE
Fastest method, all accessible projects:
PS> ./Get-GCPBigQuerySizingInfo.ps1

.EXAMPLE
REST API method for specific projects (no 'bq' needed):
PS> ./Get-GCPBigQuerySizingInfo.ps1 -Method Rest -Projects 'projectA,projectB'

.EXAMPLE
Use the 'bq' CLI per-table method for a list of projects in a file:
PS> ./Get-GCPBigQuerySizingInfo.ps1 -Method Bq -ProjectFile 'projectFile.txt'

.EXAMPLE
Use only INFORMATION_SCHEMA and do not fall back to the other methods on failure:
PS> ./Get-GCPBigQuerySizingInfo.ps1 -Method InformationSchema -NoFallback

.EXAMPLE
Run without the confirmation prompt:
PS> ./Get-GCPBigQuerySizingInfo.ps1 -Projects 'projectA,projectB' -Yes
#>

[CmdletBinding(DefaultParameterSetName = 'GetAllProjects')]
param (

  # Get all projects
  [Parameter(ParameterSetName='GetAllProjects', Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [switch]$GetAllProjects,

  # Pass in comma separated list of projects
  [Parameter(ParameterSetName='Projects', Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [string]$Projects,

  # Pass in a file with a list of projects separated by line breaks, no header required
  [Parameter(ParameterSetName='ProjectFile', Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [string]$ProjectFile,

  # Collection method
  [Parameter(Mandatory=$false)]
  [ValidateSet('InformationSchema', 'Rest', 'Bq')]
  [string]$Method = 'InformationSchema',

  # Deprecated no-op: fallback is the default
  [Parameter(Mandatory=$false)]
  [switch]$Fallback,

  # Do not fall back to the next method on failure
  [Parameter(Mandatory=$false)]
  [switch]$NoFallback,

  # Skip the confirmation prompt
  [Parameter(Mandatory=$false)]
  [switch]$Yes,

  # Rest method: parallel tables.get calls
  [Parameter(Mandatory=$false)]
  [ValidateRange(1, 64)]
  [int]$ThrottleLimit = 8,

  # Rest method: optional quota project
  [Parameter(Mandatory=$false)]
  [string]$QuotaProject,

  # InformationSchema method: skip table-level label query
  [Parameter(Mandatory=$false)]
  [switch]$SkipTableLabels,

  # Option to anonymize the output files.
  [Parameter(Mandatory=$false)]
  [switch]$Anonymize,

  # Choose to anonymize additional fields
  [Parameter(Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [string]$AnonymizeFields,

  # Choose to not anonymize certain fields
  [Parameter(Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [string]$NotAnonymizeFields
)

# Script version: update this with every change to this script.
$scriptVersion = "1.1.1"

# Save the current culture so it can be restored later
$CurrentCulture = [System.Globalization.CultureInfo]::CurrentCulture

# Set the culture to en-US; this is to ensure that output to CSV is written properly
[System.Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'
[System.Threading.Thread]::CurrentThread.CurrentUICulture = 'en-US'

# Disable gcloud interactive prompts for scripted execution
$env:CLOUDSDK_CORE_DISABLE_PROMPTS = 1

# gcloud is always required (project discovery, API check, access token for the Rest method)
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: 'gcloud' CLI was not found on PATH." -ForegroundColor Red
    Write-Host "Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install" -ForegroundColor Red
    Write-Host "On Windows, close and reopen your PowerShell window after installing so PATH is refreshed." -ForegroundColor Red
    Write-Host "Then verify with: gcloud --version" -ForegroundColor Red
    throw "gcloud CLI not found. See guidance above."
}

$bqAvailable = [bool](Get-Command bq -ErrorAction SilentlyContinue)

# Order in which methods are tried when -Fallback is specified
$methodOrder = @('InformationSchema', 'Bq', 'Rest')
$methodChain = @($Method)
if (-not $NoFallback) {
    $startIndex = [array]::IndexOf($methodOrder, $Method)
    $methodChain = @($methodOrder[$startIndex..($methodOrder.Count - 1)])
}

# Drop methods that need 'bq' when it is not installed
if (-not $bqAvailable) {
    $needsBq = @('InformationSchema', 'Bq')
    $usable = @($methodChain | Where-Object { $_ -notin $needsBq })
    if ($usable.Count -eq 0) {
        Write-Host "ERROR: Method '$Method' requires the 'bq' CLI, which was not found on PATH." -ForegroundColor Red
        Write-Host "Install it with 'gcloud components install bq' (or your package manager's google-cloud-cli package)," -ForegroundColor Red
        Write-Host "or rerun with -Method Rest, which does not need 'bq'." -ForegroundColor Red
        throw "bq CLI not found. See guidance above."
    }
    if ($usable.Count -ne $methodChain.Count) {
        Write-Host "WARNING: 'bq' was not found on PATH; methods requiring it are skipped. Methods to try: $($usable -join ' -> ')" -ForegroundColor Yellow
    }
    $methodChain = $usable
}

# --- Function definitions ---

function Resolve-GCPProjects {
    param(
        [string]$Projects,
        [string]$ProjectFile
    )
    $projectList = @()
    $requested = @()
    # An explicit -ProjectFile / -Projects that yields nothing is an error; it must never fall through
    # to "discover all projects".
    if ($ProjectFile -ne '') {
        if (-not (Test-Path -Path $ProjectFile -PathType Leaf)) {
            throw "Project file '$ProjectFile' was not found."
        }
        $requested = @(Get-Content -Path $ProjectFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($requested.Count -eq 0) { throw "Project file '$ProjectFile' contains no project IDs." }
    } elseif ($Projects -ne '') {
        $requested = @($Projects.split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($requested.Count -eq 0) { throw "-Projects did not contain any project IDs." }
    }

    if ($requested.Count -gt 0) {
        foreach ($project in $requested) {
            $stderrFile = New-TemporaryFile
            try {
                $projectJson = gcloud projects describe $project --format=json 2>$stderrFile
                if ($projectJson) {
                    $projectList += ($projectJson -join '') | ConvertFrom-Json
                } else {
                    $stderrText = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue)
                    Write-Host "Project $project not found or not accessible" -foregroundcolor red
                    if ($stderrText) { Write-Host "  gcloud: $($stderrText.Trim())" -foregroundcolor red }
                }
            } catch {
                Write-Host "Failed to get project $project" -foregroundcolor red
                Write-Host "Error: $_" -foregroundcolor red
            } finally {
                Remove-Item $stderrFile -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Host "No project list provided, discovering all GCP projects accessible to the authenticated account..." -ForegroundColor green
        # Capture stderr so a real error (auth, perms, disabled API) is not masked as "0 projects".
        $stderrFile = New-TemporaryFile
        $callFailed = $false
        try {
            $projectListJson = gcloud projects list --format=json 2>$stderrFile
            if ($projectListJson) {
                $projectList = ($projectListJson -join '') | ConvertFrom-Json
            }
        } catch {
            $callFailed = $true
            Write-Host "Failed to get projects" -foregroundcolor Red
            Write-Host "Error: $_" -foregroundcolor Red
        }
        $stderrText = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue)
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
        if (-not $callFailed -and (-not $projectList -or $projectList.Count -eq 0)) {
            if ($stderrText) {
                Write-Host "ERROR: 'gcloud projects list' returned no projects." -ForegroundColor Red
                Write-Host "gcloud stderr:" -ForegroundColor Red
                Write-Host $stderrText -ForegroundColor Red
                Write-Host "Common causes (check in this order):" -ForegroundColor Yellow
                Write-Host "  1. Not authenticated, or active account is the wrong one. Run: gcloud auth list" -ForegroundColor Yellow
                Write-Host "     Re-authenticate if needed: gcloud auth login" -ForegroundColor Yellow
                Write-Host "  2. Caller lacks 'resourcemanager.projects.list' at org / folder scope." -ForegroundColor Yellow
                Write-Host "  3. Cloud Resource Manager API disabled on the quota project." -ForegroundColor Yellow
                Write-Host "Workaround: pass project IDs explicitly with -Projects or -ProjectFile:" -ForegroundColor Yellow
                Write-Host "  .\Get-GCPBigQuerySizingInfo.ps1 -Projects 'project-id-1,project-id-2'" -ForegroundColor Yellow
                throw "gcloud projects list returned no projects -- see guidance above."
            } else {
                Write-Host "WARNING: 'gcloud projects list' returned no projects and gcloud reported no errors." -ForegroundColor Yellow
                Write-Host "If you expected projects, pass them explicitly with -Projects 'id1,id2' or -ProjectFile path." -ForegroundColor Yellow
            }
        }
    }
    if (-not $projectList -or @($projectList).Count -eq 0) {
        throw "No accessible projects were found. Nothing to collect."
    }
    return $projectList
}

# Returns a Status of 'Enabled', 'Disabled', or 'Unknown'. 'Unknown' means the check itself failed
# (auth or permission error), which must not be reported as "API not enabled".
function Test-BigQueryApiEnabled {
    param(
        [string]$ProjectId
    )
    $global:LASTEXITCODE = 0
    $merged = @(gcloud services list --enabled --project=$ProjectId `
        --filter="config.name:bigquery.googleapis.com" `
        --format="value(config.name)" --quiet 2>&1)
    $exitCode = $global:LASTEXITCODE
    $out = @($merged | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_".Trim() })
    $errText = (@($merged | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ')
    if ($exitCode -ne 0) {
        return [PSCustomObject]@{ Status = 'Unknown'; Error = $errText }
    }
    if ($out -contains 'bigquery.googleapis.com') {
        return [PSCustomObject]@{ Status = 'Enabled'; Error = $null }
    }
    return [PSCustomObject]@{ Status = 'Disabled'; Error = $null }
}

# Verifies gcloud has working credentials. 'gcloud auth list' still shows an account when the refresh
# token is invalid (invalid_grant), so an access token is requested instead.
function Test-GcloudAuth {
    $global:LASTEXITCODE = 0
    $merged = @(gcloud auth print-access-token 2>&1)
    $exitCode = $global:LASTEXITCODE
    $token = @($merged | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $errText = (@($merged | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
    if ($exitCode -ne 0 -or $token.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Account = $null; Error = $errText }
    }
    $account = (gcloud config get-value account --quiet 2>$null) -join ''
    return [PSCustomObject]@{ Success = $true; Account = $account.Trim(); Error = $null }
}

# Shows what is about to be processed and asks the user to confirm. Returns $true to proceed.
function Confirm-Collection {
    param(
        [object[]]$ProjectList,
        [string]$Account,
        [string[]]$MethodChain,
        [string]$Source,
        [bool]$SkipPrompt
    )
    $ids = @($ProjectList | ForEach-Object { $_.projectId })
    Write-Host
    Write-Host "About to collect BigQuery sizing data:" -ForegroundColor Cyan
    Write-Host "  Account:   $Account"
    Write-Host "  Projects:  $($ids.Count) ($Source)"
    Write-Host "  Methods:   $($MethodChain -join ' -> ')"
    Write-Host "  Read-only: no GCP resources are changed. InformationSchema runs 'bq query' jobs (negligible cost, visible in job history)."
    $showMax = 25
    foreach ($id in ($ids | Select-Object -First $showMax)) { Write-Host "    $id" }
    if ($ids.Count -gt $showMax) {
        Write-Host "    ... and $($ids.Count - $showMax) more (enter 'l' at the prompt to list all)"
    }
    Write-Host

    if ($SkipPrompt) {
        Write-Host "-Yes specified; proceeding without confirmation." -ForegroundColor Yellow
        return $true
    }
    if ([Console]::IsInputRedirected) {
        Write-Host "ERROR: Input is redirected, so the confirmation prompt cannot be shown. Rerun with -Yes to proceed non-interactively." -ForegroundColor Red
        return $false
    }
    while ($true) {
        $answer = (Read-Host "Proceed? [y/N/l=list all projects]").Trim().ToLower()
        if ($answer -eq 'l') {
            $ids | ForEach-Object { Write-Host "    $_" }
            continue
        }
        return ($answer -eq 'y' -or $answer -eq 'yes')
    }
}

# Mirrors the ConvertTo-GCPSizeUnits helper in Get-GCPSizingInfo.ps1 (byte input only).
function ConvertTo-GCPSizeUnits {
    param(
        [double]$Value,
        [string]$Prefix,
        [int]$Precision = 6
    )
    $gib = $Value / 1073741824
    $tib = $gib  / 1024
    $gb  = $Value / 1000000000
    $tb  = $gb   / 1000
    @{
        "${Prefix}GiB" = [math]::Round($gib, $Precision)
        "${Prefix}TiB" = [math]::Round($tib, $Precision)
        "${Prefix}GB"  = [math]::Round($gb,  $Precision)
        "${Prefix}TB"  = [math]::Round($tb,  $Precision)
    }
}

function Add-LabelsToObject {
    param(
        $obj,
        $labels,
        [string]$prefix = "Label/Tag: ",
        [hashtable]$WarnedCollisions,
        [string]$CollisionContext
    )
    if (-not $labels) { return }
    foreach ($prop in $labels.PSObject.Properties) {
        $key = $prop.Name -replace '[^a-zA-Z0-9]', '_'
        $columnName = "$prefix$key"
        if ($null -ne $WarnedCollisions -and $obj.PSObject.Properties[$columnName]) {
            $warnKey = "$CollisionContext|$columnName"
            if (-not $WarnedCollisions.ContainsKey($warnKey)) {
                $WarnedCollisions[$warnKey] = $true
                Write-Host "WARNING: Column '$columnName' is produced by both a dataset label and a table label in $CollisionContext; the table label value overwrites the dataset label value." -ForegroundColor Yellow
            }
        }
        $obj | Add-Member -MemberType NoteProperty -Name $columnName -Value $prop.Value -Force
    }
}

function Add-TagsToAllObjectsInList($list) {
    # Determine all unique column names so every row has every label column
    $allTagKeys = @{}
    foreach ($obj in $list) {
        foreach ($property in $obj.PSObject.Properties) {
            if (-not $allTagKeys.ContainsKey($property.Name)) {
                $allTagKeys[$property.Name] = $true
            }
        }
    }
    $allTagKeys = $allTagKeys.Keys
    foreach ($obj in $list) {
        foreach ($key in $allTagKeys) {
            if (-not $obj.PSObject.Properties.Name.Contains($key)) {
                $obj | Add-Member -MemberType NoteProperty -Name $key -Value $null -Force
            }
        }
    }
}

function ConvertTo-LongOrZero {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return 0L }
    try { return [long]$Value } catch { return 0L }
}

function ConvertTo-IsoTime {
    param($Millis)
    if ($null -eq $Millis -or "$Millis" -eq '') { return "" }
    try { return ([System.DateTimeOffset]::FromUnixTimeMilliseconds([long]$Millis)).ToString("yyyy-MM-ddTHH:mm:ssZ") } catch { return "" }
}

# Builds one output row. All three methods produce rows with exactly the same columns.
# Sizes are in bytes; the Gb/Tb/GiB/TiB columns are derived here.
function New-BigQueryRow {
    param(
        [string]$ProjectId,
        [string]$DatasetId,
        [string]$Location,
        [string]$TableId,
        [string]$TableType,
        [long]$NumRows,
        $NumberOfColumns,
        [long]$TotalLogicalBytes,
        [long]$ActiveLogicalBytes,
        [long]$LongTermLogicalBytes,
        [long]$TotalPhysicalBytes,
        [long]$ActivePhysicalBytes,
        [long]$LongTermPhysicalBytes,
        [long]$TimeTravelPhysicalBytes,
        [long]$FailSafePhysicalBytes,
        [string]$ExternalSourceFormat,
        [string]$ExternalSourceUri,
        [string]$CreationTime,
        [string]$LastModifiedTime,
        [string]$CollectionMethod
    )
    $tot = ConvertTo-GCPSizeUnits -Value $TotalLogicalBytes    -Prefix "TotalLogicalSize"
    $act = ConvertTo-GCPSizeUnits -Value $ActiveLogicalBytes   -Prefix "ActiveLogicalSize"
    $lt  = ConvertTo-GCPSizeUnits -Value $LongTermLogicalBytes -Prefix "LongTermLogicalSize"
    $ptot = ConvertTo-GCPSizeUnits -Value $TotalPhysicalBytes  -Prefix "TotalPhysicalSize"

    [PSCustomObject]@{
        "Project"                  = $ProjectId
        "DatasetId"                = $DatasetId
        "Location"                 = $Location
        "TableId"                  = $TableId
        "TableType"                = $TableType
        "NumRows"                  = $NumRows
        "NumberOfColumns"          = $NumberOfColumns
        "TotalLogicalSizeBytes"    = $TotalLogicalBytes
        "TotalLogicalSizeGb"       = $tot["TotalLogicalSizeGB"]
        "TotalLogicalSizeTb"       = $tot["TotalLogicalSizeTB"]
        "TotalLogicalSizeGiB"      = $tot["TotalLogicalSizeGiB"]
        "TotalLogicalSizeTiB"      = $tot["TotalLogicalSizeTiB"]
        "ActiveLogicalSizeBytes"   = $ActiveLogicalBytes
        "ActiveLogicalSizeGb"      = $act["ActiveLogicalSizeGB"]
        "ActiveLogicalSizeTb"      = $act["ActiveLogicalSizeTB"]
        "ActiveLogicalSizeGiB"     = $act["ActiveLogicalSizeGiB"]
        "ActiveLogicalSizeTiB"     = $act["ActiveLogicalSizeTiB"]
        "LongTermLogicalSizeBytes" = $LongTermLogicalBytes
        "LongTermLogicalSizeGb"    = $lt["LongTermLogicalSizeGB"]
        "LongTermLogicalSizeTb"    = $lt["LongTermLogicalSizeTB"]
        "LongTermLogicalSizeGiB"   = $lt["LongTermLogicalSizeGiB"]
        "LongTermLogicalSizeTiB"   = $lt["LongTermLogicalSizeTiB"]
        "TotalPhysicalSizeBytes"   = $TotalPhysicalBytes
        "TotalPhysicalSizeGb"      = $ptot["TotalPhysicalSizeGB"]
        "TotalPhysicalSizeTb"      = $ptot["TotalPhysicalSizeTB"]
        "TotalPhysicalSizeGiB"     = $ptot["TotalPhysicalSizeGiB"]
        "TotalPhysicalSizeTiB"     = $ptot["TotalPhysicalSizeTiB"]
        "ActivePhysicalSizeBytes"  = $ActivePhysicalBytes
        "LongTermPhysicalSizeBytes" = $LongTermPhysicalBytes
        "TimeTravelPhysicalSizeBytes" = $TimeTravelPhysicalBytes
        "FailSafePhysicalSizeBytes" = $FailSafePhysicalBytes
        "ExternalSourceFormat"     = $ExternalSourceFormat
        "ExternalSourceUri"        = $ExternalSourceUri
        "CreationTime"             = $CreationTime
        "LastModifiedTime"         = $LastModifiedTime
        "CollectionMethod"         = $CollectionMethod
    }
}

# Builds a row from a BigQuery REST 'Table' resource. 'bq show --format=prettyjson' returns the same
# JSON shape, so the Bq and Rest methods share this function.
function ConvertFrom-BigQueryTableResource {
    param(
        [string]$ProjectId,
        [string]$DatasetId,
        [string]$Location,
        $DatasetLabels,
        [string]$TableId,
        [string]$TableType,
        $TableInfo,      # $null when the details call failed
        [string]$CollectionMethod,
        [hashtable]$LabelCollisionsWarned
    )
    $logical = 0L; $longTerm = 0L; $rows = 0L; $cols = 0
    $activePhys = 0L; $totalPhys = 0L; $ltPhys = 0L; $ttPhys = 0L; $fsPhys = 0L
    $created = ""; $modified = ""; $extFormat = ""; $extUri = ""; $tableLabels = $null
    $activeLogical = $null

    if ($TableInfo) {
        $logical    = ConvertTo-LongOrZero $TableInfo.numBytes
        if ($logical -eq 0) { $logical = ConvertTo-LongOrZero $TableInfo.numTotalLogicalBytes }
        $longTerm   = ConvertTo-LongOrZero $TableInfo.numLongTermBytes
        if ($longTerm -eq 0) { $longTerm = ConvertTo-LongOrZero $TableInfo.numLongTermLogicalBytes }
        if ($null -ne $TableInfo.numActiveLogicalBytes -and "$($TableInfo.numActiveLogicalBytes)" -ne '') {
            $activeLogical = ConvertTo-LongOrZero $TableInfo.numActiveLogicalBytes
        }
        $rows       = ConvertTo-LongOrZero $TableInfo.numRows
        if ($TableInfo.schema -and $TableInfo.schema.fields) { $cols = @($TableInfo.schema.fields).Count }
        $created    = ConvertTo-IsoTime $TableInfo.creationTime
        $modified   = ConvertTo-IsoTime $TableInfo.lastModifiedTime
        $totalPhys  = ConvertTo-LongOrZero $TableInfo.numTotalPhysicalBytes
        $activePhys = ConvertTo-LongOrZero $TableInfo.numActivePhysicalBytes
        $ltPhys     = ConvertTo-LongOrZero $TableInfo.numLongTermPhysicalBytes
        $ttPhys     = ConvertTo-LongOrZero $TableInfo.numTimeTravelPhysicalBytes
        $fsPhys     = ConvertTo-LongOrZero $TableInfo.numFailSafePhysicalBytes
        if ($TableInfo.externalDataConfiguration) {
            $extFormat = $TableInfo.externalDataConfiguration.sourceFormat
            $uris = @($TableInfo.externalDataConfiguration.sourceUris)
            if ($uris.Count -gt 0) { $extUri = $uris -join '; ' }
        }
        $tableLabels = $TableInfo.labels
        if (-not $TableType -and $TableInfo.type) { $TableType = $TableInfo.type }
    }
    if ($null -eq $activeLogical) { $activeLogical = [math]::Max(0L, $logical - $longTerm) }

    $row = New-BigQueryRow -ProjectId $ProjectId -DatasetId $DatasetId -Location $Location -TableId $TableId `
        -TableType $TableType -NumRows $rows -NumberOfColumns $cols `
        -TotalLogicalBytes $logical -ActiveLogicalBytes $activeLogical -LongTermLogicalBytes $longTerm `
        -TotalPhysicalBytes $totalPhys -ActivePhysicalBytes $activePhys -LongTermPhysicalBytes $ltPhys `
        -TimeTravelPhysicalBytes $ttPhys -FailSafePhysicalBytes $fsPhys `
        -ExternalSourceFormat $extFormat -ExternalSourceUri $extUri `
        -CreationTime $created -LastModifiedTime $modified -CollectionMethod $CollectionMethod

    Add-LabelsToObject $row $DatasetLabels "Label/Tag: dataset_"
    Add-LabelsToObject $row $tableLabels "Label/Tag: " -WarnedCollisions $LabelCollisionsWarned -CollisionContext "BigQuery dataset ${ProjectId}:${DatasetId}"
    return $row
}

# ---------------------------------------------------------------------------
# bq CLI helpers (used by the Bq and InformationSchema methods)
# ---------------------------------------------------------------------------

# bq ls returns only 50 results unless --max_results is set. 2147483647 is the largest value bq accepts.
$BQ_MAX_RESULTS = 2147483647

# bq writes some error text to stdout and some to stderr, so the exit code is checked before parsing
# stdout and the failure message includes both streams.
function Invoke-BqJson {
    param(
        [string[]]$BqArgs
    )
    try {
        $global:LASTEXITCODE = 0
        $merged = @(bq @BqArgs 2>&1)
        $exitCode = $global:LASTEXITCODE
        $output = @($merged | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        $errorLines = @($merged | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
        if ($exitCode -ne 0) {
            $details = (@($output | ForEach-Object { "$_" }) + $errorLines) -join ' '
            return [PSCustomObject]@{ Success = $false; Data = @(); Error = "exit code ${exitCode}: $details" }
        }
        $data = @()
        if ($output) {
            $data = @(($output -join '') | ConvertFrom-Json)
        }
        return [PSCustomObject]@{ Success = $true; Data = $data; Error = $null }
    } catch {
        return [PSCustomObject]@{ Success = $false; Data = @(); Error = "$_" }
    }
}

function Write-TruncationWarning {
    param(
        $Items,
        [string]$What
    )
    if (@($Items).Count -ge $BQ_MAX_RESULTS) {
        Write-Host "WARNING: The list of $What reached the limit of $BQ_MAX_RESULTS items and may be truncated; the BigQuery totals may be incomplete." -ForegroundColor Yellow
        $script:bqCollectionWarnings++
    }
}

# ---------------------------------------------------------------------------
# Method: Bq  (bq ls / bq show, one call per table)
# ---------------------------------------------------------------------------
function Get-BigQueryInventoryViaBq {
    param(
        [string]$ProjectId
    )
    $rows = New-Object collections.arraylist
    $labelCollisionsWarned = @{}

    $datasetsResult = Invoke-BqJson -BqArgs @('ls', '--format=json', "--max_results=$BQ_MAX_RESULTS", "--project_id=$ProjectId")
    if (-not $datasetsResult.Success) {
        Write-Host "ERROR: [Bq] Failed to list BigQuery datasets in project ${ProjectId}: $($datasetsResult.Error)" -ForegroundColor Red
        return [PSCustomObject]@{ Success = $false; Rows = $rows; Datasets = 0; Error = $datasetsResult.Error }
    }
    $datasets = @($datasetsResult.Data)
    Write-TruncationWarning -Items $datasets -What "datasets in project $ProjectId"

    $datasetCounter = 1
    $datasetTotal = $datasets.Count
    foreach ($dataset in $datasets) {
        $datasetId = $dataset.datasetReference.datasetId
        Write-Progress -ID 6 -Activity "[Bq] Processing BigQuery dataset: $datasetId" -Status "Dataset $datasetCounter of $datasetTotal" -PercentComplete (($datasetCounter / $datasetTotal) * 100)
        $datasetCounter++

        $location = ""
        $datasetLabels = $null
        $datasetInfoResult = Invoke-BqJson -BqArgs @('show', '--format=prettyjson', "${ProjectId}:${datasetId}")
        if ($datasetInfoResult.Success) {
            if ($datasetInfoResult.Data) {
                $location = $datasetInfoResult.Data[0].location
                $datasetLabels = $datasetInfoResult.Data[0].labels
            }
        } else {
            Write-Host "WARNING: [Bq] Failed to get details for dataset ${ProjectId}:${datasetId}: $($datasetInfoResult.Error)" -ForegroundColor Yellow
            $script:bqCollectionWarnings++
        }

        $tablesResult = Invoke-BqJson -BqArgs @('ls', '--format=prettyjson', "--max_results=$BQ_MAX_RESULTS", "${ProjectId}:${datasetId}")
        if (-not $tablesResult.Success) {
            Write-Host "WARNING: [Bq] Failed to list tables in dataset ${ProjectId}:${datasetId}: $($tablesResult.Error)" -ForegroundColor Yellow
            $script:bqCollectionWarnings++
            continue
        }
        $tables = @($tablesResult.Data)
        Write-TruncationWarning -Items $tables -What "tables in dataset ${ProjectId}:${datasetId}"
        foreach ($table in $tables) {
            $tableId = $table.tableReference.tableId
            if (-not $tableId) { continue }
            $tableInfoResult = Invoke-BqJson -BqArgs @('show', '--format=prettyjson', "${ProjectId}:${datasetId}.${tableId}")
            $tableInfo = $null
            if ($tableInfoResult.Success -and $tableInfoResult.Data) {
                $tableInfo = $tableInfoResult.Data[0]
            } else {
                Write-Host "WARNING: [Bq] Failed to get details for table ${datasetId}.${tableId} in project ${ProjectId}; its size is reported as 0: $($tableInfoResult.Error)" -ForegroundColor Yellow
                $script:bqCollectionWarnings++
            }
            try {
                $row = ConvertFrom-BigQueryTableResource -ProjectId $ProjectId -DatasetId $datasetId -Location $location `
                    -DatasetLabels $datasetLabels -TableId $tableId -TableType $table.type -TableInfo $tableInfo `
                    -CollectionMethod 'Bq' -LabelCollisionsWarned $labelCollisionsWarned
                $rows.Add($row) | Out-Null
            } catch {
                Write-Host "WARNING: [Bq] Failed to process table ${datasetId}.${tableId} in project ${ProjectId}: $_" -ForegroundColor Yellow
                $script:bqCollectionWarnings++
            }
        }
    }
    Write-Progress -ID 6 -Activity "Processing BigQuery datasets" -Completed
    return [PSCustomObject]@{ Success = $true; Rows = $rows; Datasets = $datasetTotal; Error = $null }
}

# ---------------------------------------------------------------------------
# Method: Rest  (BigQuery REST API with a gcloud access token)
# ---------------------------------------------------------------------------
function Get-GcpAccessToken {
    $token = gcloud auth print-access-token 2>$null
    if (-not $token) { throw "Unable to get an access token. Run 'gcloud auth login' and retry." }
    $script:restToken = ($token -join '').Trim()
    $script:restTokenTime = Get-Date
}

# Access tokens last about an hour; refresh well before that.
function Get-RestHeaders {
    param([string]$ProjectId)
    if (-not $script:restToken -or ((Get-Date) - $script:restTokenTime).TotalMinutes -gt 40) {
        Get-GcpAccessToken
    }
    $headers = @{ Authorization = "Bearer $($script:restToken)" }
    if ($QuotaProject) { $headers['x-goog-user-project'] = $QuotaProject }
    return $headers
}

# GET with retry/backoff for throttling (429) and transient server errors (5xx)
function Invoke-BqRestGet {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($attempt -lt 5 -and ($status -eq 429 -or ($status -ge 500 -and $status -le 599))) {
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                continue
            }
            throw
        }
    }
}

# Follows nextPageToken. $ItemsProperty is the array property in the response ('datasets' or 'tables').
function Get-BqRestPaged {
    param(
        [string]$BaseUri,
        [string]$ItemsProperty,
        [string]$ProjectId,
        [string]$ExtraQuery = ''
    )
    $items = New-Object collections.arraylist
    $pageToken = $null
    do {
        $uri = "${BaseUri}?maxResults=1000$ExtraQuery"
        if ($pageToken) { $uri += "&pageToken=$([uri]::EscapeDataString($pageToken))" }
        $resp = Invoke-BqRestGet -Uri $uri -Headers (Get-RestHeaders -ProjectId $ProjectId)
        if ($resp.$ItemsProperty) {
            foreach ($i in $resp.$ItemsProperty) { $items.Add($i) | Out-Null }
        }
        $pageToken = $resp.nextPageToken
    } while ($pageToken)
    return $items
}

function Get-BigQueryInventoryViaRest {
    param(
        [string]$ProjectId
    )
    $rows = New-Object collections.arraylist
    $labelCollisionsWarned = @{}
    $base = "https://bigquery.googleapis.com/bigquery/v2/projects/$ProjectId"

    try {
        $datasets = @(Get-BqRestPaged -BaseUri "$base/datasets" -ItemsProperty 'datasets' -ProjectId $ProjectId -ExtraQuery '&all=true')
    } catch {
        Write-Host "ERROR: [Rest] Failed to list BigQuery datasets in project ${ProjectId}: $_" -ForegroundColor Red
        return [PSCustomObject]@{ Success = $false; Rows = $rows; Datasets = 0; Error = "$_" }
    }

    $datasetCounter = 1
    $datasetTotal = $datasets.Count
    foreach ($dataset in $datasets) {
        $datasetId = $dataset.datasetReference.datasetId
        Write-Progress -ID 6 -Activity "[Rest] Processing BigQuery dataset: $datasetId" -Status "Dataset $datasetCounter of $datasetTotal" -PercentComplete (($datasetCounter / $datasetTotal) * 100)
        $datasetCounter++

        # datasets.list normally includes location and labels; fall back to datasets.get if it does not
        $location = $dataset.location
        $datasetLabels = $dataset.labels
        if (-not $location) {
            try {
                $dsInfo = Invoke-BqRestGet -Uri "$base/datasets/$([uri]::EscapeDataString($datasetId))" -Headers (Get-RestHeaders -ProjectId $ProjectId)
                $location = $dsInfo.location
                $datasetLabels = $dsInfo.labels
            } catch {
                Write-Host "WARNING: [Rest] Failed to get details for dataset ${ProjectId}:${datasetId}: $_" -ForegroundColor Yellow
                $script:bqCollectionWarnings++
            }
        }

        try {
            $tables = @(Get-BqRestPaged -BaseUri "$base/datasets/$([uri]::EscapeDataString($datasetId))/tables" -ItemsProperty 'tables' -ProjectId $ProjectId)
        } catch {
            Write-Host "WARNING: [Rest] Failed to list tables in dataset ${ProjectId}:${datasetId}: $_" -ForegroundColor Yellow
            $script:bqCollectionWarnings++
            continue
        }
        if ($tables.Count -eq 0) { continue }

        # Fetch table details in parallel. A fresh token is read once per dataset.
        $headers = Get-RestHeaders -ProjectId $ProjectId
        $details = $tables | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $t = $_
            $tid = $t.tableReference.tableId
            $uri = "https://bigquery.googleapis.com/bigquery/v2/projects/$($using:ProjectId)/datasets/$([uri]::EscapeDataString($using:datasetId))/tables/$([uri]::EscapeDataString($tid))"
            $info = $null
            $err = $null
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try {
                    $info = Invoke-RestMethod -Method Get -Uri $uri -Headers $using:headers -ErrorAction Stop
                    $err = $null
                    break
                } catch {
                    $err = "$_"
                    $status = $null
                    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
                    if ($status -eq 429 -or ($status -ge 500 -and $status -le 599)) {
                        Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                    } else {
                        break
                    }
                }
            }
            [PSCustomObject]@{ TableId = $tid; Type = $t.type; Info = $info; Error = $err }
        }

        foreach ($d in $details) {
            if ($d.Error) {
                Write-Host "WARNING: [Rest] Failed to get details for table ${datasetId}.$($d.TableId) in project ${ProjectId}; its size is reported as 0: $($d.Error)" -ForegroundColor Yellow
                $script:bqCollectionWarnings++
            }
            try {
                $row = ConvertFrom-BigQueryTableResource -ProjectId $ProjectId -DatasetId $datasetId -Location $location `
                    -DatasetLabels $datasetLabels -TableId $d.TableId -TableType $d.Type -TableInfo $d.Info `
                    -CollectionMethod 'Rest' -LabelCollisionsWarned $labelCollisionsWarned
                $rows.Add($row) | Out-Null
            } catch {
                Write-Host "WARNING: [Rest] Failed to process table ${datasetId}.$($d.TableId) in project ${ProjectId}: $_" -ForegroundColor Yellow
                $script:bqCollectionWarnings++
            }
        }
    }
    Write-Progress -ID 6 -Activity "Processing BigQuery datasets" -Completed
    return [PSCustomObject]@{ Success = $true; Rows = $rows; Datasets = $datasetTotal; Error = $null }
}

# ---------------------------------------------------------------------------
# Method: InformationSchema  (TABLE_STORAGE via 'bq query', one query per location)
# ---------------------------------------------------------------------------
$tableStorageSql = @'
SELECT
  table_schema AS dataset_id,
  table_name,
  table_type,
  total_rows,
  total_logical_bytes,
  active_logical_bytes,
  long_term_logical_bytes,
  total_physical_bytes,
  active_physical_bytes,
  long_term_physical_bytes,
  time_travel_physical_bytes,
  fail_safe_physical_bytes,
  UNIX_MILLIS(creation_time) AS creation_ms,
  UNIX_MILLIS(storage_last_modified_time) AS modified_ms
FROM `region-{REGION}`.INFORMATION_SCHEMA.TABLE_STORAGE
WHERE deleted = FALSE
'@

$tableLabelsSql = @'
SELECT table_schema AS dataset_id, table_name, option_value
FROM `region-{REGION}`.INFORMATION_SCHEMA.TABLE_OPTIONS
WHERE option_name = 'labels'
'@

# option_value looks like: [STRUCT("key1", "value1"), STRUCT("key2", "value2")]
function ConvertFrom-BqLabelOption {
    param([string]$OptionValue)
    $labels = [ordered]@{}
    foreach ($m in [regex]::Matches($OptionValue, 'STRUCT\("((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\)')) {
        $labels[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    if ($labels.Count -eq 0) { return $null }
    return [PSCustomObject]$labels
}

function Get-BigQueryInventoryViaInformationSchema {
    param(
        [string]$ProjectId
    )
    $rows = New-Object collections.arraylist
    $labelCollisionsWarned = @{}

    # 1) Dataset list with location and dataset labels (one bq call per project, one bq show per dataset)
    $datasetsResult = Invoke-BqJson -BqArgs @('ls', '--format=json', "--max_results=$BQ_MAX_RESULTS", "--project_id=$ProjectId")
    if (-not $datasetsResult.Success) {
        Write-Host "ERROR: [InformationSchema] Failed to list BigQuery datasets in project ${ProjectId}: $($datasetsResult.Error)" -ForegroundColor Red
        return [PSCustomObject]@{ Success = $false; Rows = $rows; Datasets = 0; Error = $datasetsResult.Error }
    }
    $datasets = @($datasetsResult.Data)
    Write-TruncationWarning -Items $datasets -What "datasets in project $ProjectId"

    $datasetInfo = @{}   # datasetId -> @{ Location; Labels }
    $datasetCounter = 1
    foreach ($dataset in $datasets) {
        $datasetId = $dataset.datasetReference.datasetId
        Write-Progress -ID 6 -Activity "[InformationSchema] Reading dataset locations" -Status "Dataset $datasetCounter of $($datasets.Count)" -PercentComplete (($datasetCounter / $datasets.Count) * 100)
        $datasetCounter++
        $location = $dataset.location
        $labels = $dataset.labels
        if (-not $location) {
            $r = Invoke-BqJson -BqArgs @('show', '--format=prettyjson', "${ProjectId}:${datasetId}")
            if ($r.Success -and $r.Data) {
                $location = $r.Data[0].location
                $labels = $r.Data[0].labels
            } else {
                Write-Host "WARNING: [InformationSchema] Failed to get details for dataset ${ProjectId}:${datasetId}: $($r.Error)" -ForegroundColor Yellow
                $script:bqCollectionWarnings++
            }
        }
        $datasetInfo[$datasetId] = @{ Location = $location; Labels = $labels }
    }
    Write-Progress -ID 6 -Activity "Reading dataset locations" -Completed

    # 2) One TABLE_STORAGE query per distinct dataset location
    $locations = @($datasetInfo.Values | ForEach-Object { $_.Location } | Where-Object { $_ } | Sort-Object -Unique)
    $allOk = $true
    $firstError = $null
    foreach ($loc in $locations) {
        $region = $loc.ToLower()
        Write-Host "  [InformationSchema] Querying TABLE_STORAGE in project $ProjectId, location $loc" -ForegroundColor Cyan
        $sql = $tableStorageSql.Replace('{REGION}', $region)
        $q = Invoke-BqJson -BqArgs @('query', '--quiet', '--use_legacy_sql=false', '--format=json', '--max_rows=100000000', "--location=$loc", "--project_id=$ProjectId", $sql)
        if (-not $q.Success) {
            Write-Host "ERROR: [InformationSchema] TABLE_STORAGE query failed in project $ProjectId, location ${loc}: $($q.Error)" -ForegroundColor Red
            $script:bqCollectionWarnings++
            $allOk = $false
            if (-not $firstError) { $firstError = $q.Error }
            continue
        }

        # Optional table-level labels
        $tableLabelMap = @{}
        if (-not $SkipTableLabels) {
            $lq = Invoke-BqJson -BqArgs @('query', '--quiet', '--use_legacy_sql=false', '--format=json', '--max_rows=100000000', "--location=$loc", "--project_id=$ProjectId", $tableLabelsSql.Replace('{REGION}', $region))
            if ($lq.Success) {
                foreach ($l in $lq.Data) {
                    $tableLabelMap["$($l.dataset_id)|$($l.table_name)"] = ConvertFrom-BqLabelOption -OptionValue $l.option_value
                }
            } else {
                Write-Host "WARNING: [InformationSchema] Table label query failed in project $ProjectId, location ${loc}; table-level labels will be missing: $($lq.Error)" -ForegroundColor Yellow
                $script:bqCollectionWarnings++
            }
        }

        foreach ($r in $q.Data) {
            try {
                # Normalise TABLE_STORAGE table_type to the values used by the Bq and Rest methods
                $type = switch ($r.table_type) {
                    'BASE TABLE'        { 'TABLE' }
                    'CLONE'             { 'TABLE' }   # a clone is restored as a full logical table
                    'MATERIALIZED VIEW' { 'MATERIALIZED_VIEW' }
                    'SNAPSHOT'          { 'SNAPSHOT' }
                    default             { "$($r.table_type)" }
                }
                $ds = $datasetInfo["$($r.dataset_id)"]
                if (-not $ds) { $ds = @{ Location = $loc; Labels = $null } }
                # Skip datasets whose location is a different location than the one being queried
                if ($ds.Location -and $ds.Location -ne $loc) { continue }

                $row = New-BigQueryRow -ProjectId $ProjectId -DatasetId "$($r.dataset_id)" -Location $loc -TableId "$($r.table_name)" `
                    -TableType $type -NumRows (ConvertTo-LongOrZero $r.total_rows) -NumberOfColumns $null `
                    -TotalLogicalBytes (ConvertTo-LongOrZero $r.total_logical_bytes) `
                    -ActiveLogicalBytes (ConvertTo-LongOrZero $r.active_logical_bytes) `
                    -LongTermLogicalBytes (ConvertTo-LongOrZero $r.long_term_logical_bytes) `
                    -TotalPhysicalBytes (ConvertTo-LongOrZero $r.total_physical_bytes) `
                    -ActivePhysicalBytes (ConvertTo-LongOrZero $r.active_physical_bytes) `
                    -LongTermPhysicalBytes (ConvertTo-LongOrZero $r.long_term_physical_bytes) `
                    -TimeTravelPhysicalBytes (ConvertTo-LongOrZero $r.time_travel_physical_bytes) `
                    -FailSafePhysicalBytes (ConvertTo-LongOrZero $r.fail_safe_physical_bytes) `
                    -ExternalSourceFormat "" -ExternalSourceUri "" `
                    -CreationTime (ConvertTo-IsoTime $r.creation_ms) -LastModifiedTime (ConvertTo-IsoTime $r.modified_ms) `
                    -CollectionMethod 'InformationSchema'

                Add-LabelsToObject $row $ds.Labels "Label/Tag: dataset_"
                Add-LabelsToObject $row $tableLabelMap["$($r.dataset_id)|$($r.table_name)"] "Label/Tag: " -WarnedCollisions $labelCollisionsWarned -CollisionContext "BigQuery dataset ${ProjectId}:$($r.dataset_id)"
                $rows.Add($row) | Out-Null
            } catch {
                Write-Host "WARNING: [InformationSchema] Failed to process row for $($r.dataset_id).$($r.table_name) in project ${ProjectId}: $_" -ForegroundColor Yellow
                $script:bqCollectionWarnings++
            }
        }
    }

    return [PSCustomObject]@{ Success = $allOk; Rows = $rows; Datasets = $datasets.Count; Error = $(if ($allOk) { $null } else { "TABLE_STORAGE query failed: $firstError" }) }
}

function Compress-SizingArchive {
    param(
        [string[]]$OutputFiles,
        [string]$ArchiveFile
    )
    $existingFiles = $OutputFiles | Where-Object { Test-Path $_ }
    if ($existingFiles) {
        Compress-Archive -Path $existingFiles -DestinationPath $ArchiveFile
    }
    foreach ($file in $OutputFiles) {
        Remove-Item -Path $file -ErrorAction SilentlyContinue
    }
}

# --- Main script body ---

# Auth preflight, before any output files are created. Exits with a clear message if gcloud has no
# working credentials (for example an expired refresh token: invalid_grant).
$authCheck = Test-GcloudAuth
if (-not $authCheck.Success) {
    Write-Host "ERROR: gcloud is not authenticated or its credentials have expired." -ForegroundColor Red
    if ($authCheck.Error) { Write-Host $authCheck.Error -ForegroundColor Red }
    Write-Host "Fix this, then rerun the script:" -ForegroundColor Yellow
    Write-Host "  1. Log in:                 gcloud auth login" -ForegroundColor Yellow
    Write-Host "  2. Check the active user:  gcloud auth list" -ForegroundColor Yellow
    Write-Host "  3. Switch account:         gcloud config set account ACCOUNT" -ForegroundColor Yellow
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $CurrentCulture
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $CurrentCulture
    exit 1
}

# Set when the run ends early. The zip and "send to Rubrik" steps are skipped and the log is kept.
$script:fatal = $false
$script:declined = $false

try {
$date = Get-Date
$date_string = $($date.ToString("yyyy-MM-dd_HHmmss"))

$output_log = "output_gcp_bigquery_$date_string.log"

if (Test-Path "./$output_log") {
  Remove-Item -Path "./$output_log"
}

if ($Anonymize) {
  "Anonymized file; customer has original. Request customer to sanitize and provide output log if needed" > $output_log
  $log_for_anon_customers = "output_gcp_bigquery_not_anonymized_$date_string.log"
  Start-Transcript -Path "./$log_for_anon_customers"
} else {
  Start-Transcript -Path "./$output_log"
}

Write-Host "Script version: $scriptVersion" -ForeGroundColor Cyan
Write-Host "Arguments passed to $($MyInvocation.MyCommand.Name):" -ForeGroundColor Green
$PSBoundParameters | Format-Table
Write-Host "Method order: $($methodChain -join ' -> ')" -ForegroundColor Cyan
Write-Host "Authenticated account: $($authCheck.Account)" -ForegroundColor Cyan

# Filename of the CSV output (kept identical to Get-GCPSizingInfo.ps1 so downstream analysis is unchanged)
$outputBigQuery = "gce_bigquery_info-$date_string.csv"
$archiveFile = "gcp_bigquery_sizing_results_$date_string.zip"
$outputFiles = @($outputBigQuery, $output_log)

# Resolve the list of projects to process
$projectList = @(Resolve-GCPProjects -Projects $Projects -ProjectFile $ProjectFile)

$projectSource = 'discovered with gcloud projects list'
if ($ProjectFile) { $projectSource = "from file $ProjectFile" }
elseif ($Projects) { $projectSource = 'from -Projects' }

# Show what is about to be processed and ask before collecting anything
$proceed = Confirm-Collection -ProjectList $projectList -Account $authCheck.Account -MethodChain $methodChain -Source $projectSource -SkipPrompt ([bool]$Yes)
if (-not $proceed) {
  $script:declined = $true
  throw "USER_DECLINED"
}
Write-Host "Full project list: $(($projectList | ForEach-Object { $_.projectId }) -join ', ')"

$bigQueryList = New-Object collections.arraylist
$script:bqCollectionWarnings = 0
$script:restToken = $null
$script:restTokenTime = $null
$totalBQDatasets = 0
$methodUsedByProject = @{}
$projectResults = New-Object collections.arraylist

$projectCounter = 1
foreach ($project in $projectList) {
  $pid_ = $project.projectId
  Write-Progress -ID 1 -Activity "Processing project: $pid_" -Status "Project: $($projectCounter) of $($projectList.Count)" -PercentComplete (($projectCounter / $projectList.Count) * 100)
  Write-Host "[$projectCounter/$($projectList.Count)] Project $pid_" -ForegroundColor Green
  $projectCounter++

  $apiCheck = Test-BigQueryApiEnabled -ProjectId $pid_
  if ($apiCheck.Status -eq 'Disabled') {
    Write-Host "WARNING: BigQuery API is not enabled on project [$pid_]. Skipping." -ForegroundColor Yellow
    $projectResults.Add([PSCustomObject]@{ Project = $pid_; Status = 'SKIPPED'; Method = ''; Datasets = 0; Tables = 0; Detail = 'BigQuery API not enabled' }) | Out-Null
    continue
  }
  if ($apiCheck.Status -eq 'Unknown') {
    Write-Host "WARNING: Could not check whether the BigQuery API is enabled on [$pid_]; attempting collection anyway. gcloud: $($apiCheck.Error)" -ForegroundColor Yellow
    $script:bqCollectionWarnings++
  }

  $done = $false
  $lastError = ''
  foreach ($m in $methodChain) {
    Write-Host "Project ${pid_}: collecting BigQuery data using method '$m'" -ForegroundColor Green
    $result = switch ($m) {
      'InformationSchema' { Get-BigQueryInventoryViaInformationSchema -ProjectId $pid_ }
      'Rest'              { Get-BigQueryInventoryViaRest -ProjectId $pid_ }
      'Bq'                { Get-BigQueryInventoryViaBq -ProjectId $pid_ }
    }
    if ($result.Success) {
      foreach ($r in $result.Rows) { $bigQueryList.Add($r) | Out-Null }
      $totalBQDatasets += $result.Datasets
      $methodUsedByProject[$pid_] = $m
      $status = 'OK'
      $detail = ''
      if ($result.Datasets -eq 0) { $status = 'EMPTY'; $detail = 'no datasets in project' }
      elseif ($result.Rows.Count -eq 0) { $status = 'EMPTY'; $detail = "$($result.Datasets) dataset(s) but no tables" }
      Write-Host "  Result: $status via $m ($($result.Datasets) datasets, $($result.Rows.Count) tables) $detail" -ForegroundColor Cyan
      $projectResults.Add([PSCustomObject]@{ Project = $pid_; Status = $status; Method = $m; Datasets = $result.Datasets; Tables = $result.Rows.Count; Detail = $detail }) | Out-Null
      $done = $true
      break
    }
    $lastError = "[$m] $($result.Error)"
    if ($m -ne $methodChain[-1]) {
      Write-Host "WARNING: Method '$m' failed for project $pid_; trying the next method." -ForegroundColor Yellow
    }
  }
  if (-not $done) {
    Write-Host "ERROR: All methods failed for project $pid_. Its BigQuery data is not included." -ForegroundColor Red
    if ($lastError -match 'Access Denied|permission|PERMISSION_DENIED|403') {
      Write-Host "  This looks like a permissions problem. Grant roles/bigquery.metadataViewer (and roles/bigquery.jobUser for InformationSchema) on the project," -ForegroundColor Yellow
      if ($NoFallback) {
        Write-Host "  or rerun without -NoFallback / with -Method Rest, which only needs dataset-level metadata read access." -ForegroundColor Yellow
      }
    }
    $methodUsedByProject[$pid_] = 'FAILED'
    $script:bqCollectionWarnings++
    $projectResults.Add([PSCustomObject]@{ Project = $pid_; Status = 'FAILED'; Method = ($methodChain -join ','); Datasets = 0; Tables = 0; Detail = $lastError }) | Out-Null
  }
}
Write-Progress -ID 1 -Activity "Processing projects" -Completed

if ($Anonymize) {
  $global:anonymizeProperties = @("Project", "DatasetId", "TableId", "ExternalSourceUri")

  if ($AnonymizeFields) {
    [string[]]$anonFieldsList = $AnonymizeFields.split(',')
    foreach ($field in $anonFieldsList) {
      if (-not $global:anonymizeProperties.Contains($field)) {
        $global:anonymizeProperties += $field
      }
    }
  }
  $global:anonymizeTags = $true
  if ($NotAnonymizeFields) {
    [string[]]$notAnonFieldsList = $NotAnonymizeFields.split(',')
    $global:anonymizeProperties = $global:anonymizeProperties | Where-Object { $_ -notin $notAnonFieldsList }
    if ($notAnonFieldsList -contains "Tags") {
      $global:anonymizeTags = $false
    }
  }

  $global:anonymizeDict = @{}
  $global:anonymizeCounter = @{}

  function Get-NextAnonymizedValue ($anonField) {
      if (-not $global:anonymizeCounter.ContainsKey($anonField)) {
        $global:anonymizeCounter[$anonField] = 0
      }
      $global:anonymizeCounter[$anonField]++

      # Plain zero-padded decimal counter: unique per field (grows past 5 digits if needed)
      $paddedValue = "{0:D5}" -f $global:anonymizeCounter[$anonField]

      return "$($anonField)-$($paddedValue)"
  }

  function Anonymize-Data {
      param (
          [PSObject]$DataObject
      )

      # Snapshot the property list: label columns are removed/re-added while iterating
      foreach ($property in @($DataObject.PSObject.Properties)) {
          $propertyName = $property.Name
          $shouldAnonymize = $global:anonymizeProperties -contains $propertyName

          if ($shouldAnonymize) {
              $originalValue = $DataObject.$propertyName
              if ($null -ne $originalValue -and "$originalValue" -ne '') {
                  if (-not $global:anonymizeDict.ContainsKey("$($originalValue)")) {
                      $global:anonymizeDict["$($originalValue)"] = Get-NextAnonymizedValue($propertyName)
                  }
                  $DataObject.$propertyName = $global:anonymizeDict["$($originalValue)"]
              }
          }
          elseif ($propertyName -like "Label/Tag:*" -and $global:anonymizeTags) {
              # Must anonymize both the label name and value
              $tagValue = $DataObject.$propertyName
              $tagName = $propertyName.Substring(10)

              if (-not $global:anonymizeDict.ContainsKey("$tagName")) {
                  $global:anonymizeDict["$tagName"] = Get-NextAnonymizedValue("Label/TagName")
              }
              $anonymizedTagKey = 'Label/Tag:' + $global:anonymizeDict["$tagName"]

              $anonymizedTagValue = $null
              if ($null -ne $tagValue) {
                  if (-not $global:anonymizeDict.ContainsKey("$($tagValue)")) {
                    $global:anonymizeDict["$($tagValue)"] = Get-NextAnonymizedValue("Label/TagValue")
                  }
                  $anonymizedTagValue = $global:anonymizeDict["$($tagValue)"]
              }
              $DataObject.PSObject.Properties.Remove($propertyName)
              $DataObject | Add-Member -MemberType NoteProperty -Name $anonymizedTagKey -Value $anonymizedTagValue -Force
          }
      }
      return $DataObject
  }

  $anonymized = @()
  foreach ($item in $bigQueryList) { $anonymized += Anonymize-Data -DataObject $item }
  $bigQueryList = $anonymized
}

# Summary
$totalBQTables        = @($bigQueryList | Where-Object { $_.TableType -eq 'TABLE' }).Count
$totalBQMatViews      = @($bigQueryList | Where-Object { $_.TableType -eq 'MATERIALIZED_VIEW' }).Count
$totalBQViews         = @($bigQueryList | Where-Object { $_.TableType -eq 'VIEW' }).Count
$totalBQExternal      = @($bigQueryList | Where-Object { $_.TableType -eq 'EXTERNAL' }).Count
$totalBQSnapshots     = @($bigQueryList | Where-Object { $_.TableType -eq 'SNAPSHOT' }).Count
$protectable          = @($bigQueryList | Where-Object { $_.TableType -in @('TABLE', 'MATERIALIZED_VIEW') })
$totalBQLogicalBytes  = ($protectable | Measure-Object -Property TotalLogicalSizeBytes -Sum).Sum
$totalBQPhysicalBytes = ($protectable | Measure-Object -Property TotalPhysicalSizeBytes -Sum).Sum
$totalBQLogicalTb     = [math]::Round($totalBQLogicalBytes / 1000000000000, 4)
$totalBQPhysicalTb    = [math]::Round($totalBQPhysicalBytes / 1000000000000, 4)

Write-Host
Write-Host "Per-project results:" -ForegroundColor Green
$projectResults | Format-Table Project, Status, Method, Datasets, Tables -AutoSize | Out-String -Width 200 | Write-Host
$notOk = @($projectResults | Where-Object { $_.Status -in @('FAILED', 'SKIPPED', 'EMPTY') })
if ($notOk.Count -gt 0) {
  Write-Host "Projects that need attention ($($notOk.Count) of $($projectResults.Count)):" -ForegroundColor Yellow
  foreach ($n in $notOk) {
    Write-Host "  $($n.Project): $($n.Status) $($n.Detail)" -ForegroundColor Yellow
  }
  Write-Host
}
Write-Host "Total # of BigQuery datasets: $totalBQDatasets" -foregroundcolor green
Write-Host "Total # of BigQuery native tables: $totalBQTables" -foregroundcolor green
Write-Host "Total # of BigQuery materialized views: $totalBQMatViews" -foregroundcolor green
Write-Host "Total # of BigQuery views (not protected): $totalBQViews" -foregroundcolor green
Write-Host "Total # of BigQuery external tables (not protected, data not in BQ): $totalBQExternal" -foregroundcolor yellow
Write-Host "Total # of BigQuery table snapshots (not included in the protectable size below): $totalBQSnapshots" -foregroundcolor yellow
Write-Host "Total logical size of protectable BQ data (TABLE + MATERIALIZED_VIEW): $totalBQLogicalTb TB" -foregroundcolor green
Write-Host "Total physical size of protectable BQ data (TABLE + MATERIALIZED_VIEW): $totalBQPhysicalTb TB (0 if physical bytes were not returned)" -foregroundcolor green
if ($methodUsedByProject.Values -contains 'InformationSchema') {
  Write-Host "NOTE: The InformationSchema method does not return views or external tables, so those counts exclude projects collected that way." -ForegroundColor Yellow
}
if ($script:bqCollectionWarnings -gt 0) {
  Write-Host "WARNING: $($script:bqCollectionWarnings) BigQuery call(s) failed; the BigQuery totals above may be incomplete. See the warnings above." -foregroundcolor yellow
}

# Nothing collected: do not produce a CSV/zip that looks like a successful run
if ($bigQueryList.Count -eq 0) {
  Write-Host
  Write-Host "ERROR: No BigQuery tables were collected from any project, so no results file was created." -ForegroundColor Red
  Write-Host "Review the per-project results and warnings above (common cause: missing permissions)." -ForegroundColor Red
  $script:fatal = $true
  throw "NO_DATA_COLLECTED"
}

# Export to CSV
Write-Host
Add-TagsToAllObjectsInList($bigQueryList)
Write-Host "CSV file output to: $outputBigQuery" -foregroundcolor green
$bigQueryList | Export-CSV -path $outputBigQuery

Write-Host
Write-Host
Write-Host "Results will be compressed into $archiveFile and original files will be removed." -ForegroundColor Green

if ($Anonymize) {
  # Exporting as rows as new value - old value
  $transformedDict = $global:anonymizeDict.GetEnumerator() | ForEach-Object {
    [PSCustomObject]@{
      AnonymizedValue = $_.Value
      ActualValue     = $_.Key
    }
  } | Sort-Object -Property AnonymizedValue

  $anonKeyValuesFileName = "gcp_bigquery_anonymized_keys_to_actual_values-$date_string.csv"

  $transformedDict | Export-CSV -Path $anonKeyValuesFileName
  Write-Host
  Write-Host "Provided anonymized keys to actual values in the CSV: $anonKeyValuesFileName" -ForeGroundColor Cyan
  Write-Host "Provided log file here: $log_for_anon_customers" -ForegroundColor Cyan
  Write-Host "These files are not part of the zip file generated" -ForegroundColor Cyan
  Write-Host
}

} catch {
  $script:fatal = $true
  if ($script:declined) {
    Write-Host "Cancelled by user; nothing was collected." -ForegroundColor Yellow
  } elseif ($_.Exception.Message -ne 'NO_DATA_COLLECTED') {
    Write-Host "ERROR: The script has exited prematurely: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
  }
} finally {
  try { Stop-Transcript | Out-Null } catch { }
  [System.Threading.Thread]::CurrentThread.CurrentCulture = $CurrentCulture
  [System.Threading.Thread]::CurrentThread.CurrentUICulture = $CurrentCulture
}

if ($script:fatal) {
  if ($script:declined) {
    # Nothing useful was collected; remove the empty log
    Remove-Item -Path $outputFiles -ErrorAction SilentlyContinue
    if ($log_for_anon_customers) { Remove-Item -Path "./$log_for_anon_customers" -ErrorAction SilentlyContinue }
    exit 2
  }
  # Keep the log on disk for troubleshooting; do not create a zip or ask the user to send anything
  Write-Host
  Write-Host "The run did not complete. No zip file was created. Log file kept for troubleshooting:" -ForegroundColor Red
  if ($Anonymize) { Write-Host "  $log_for_anon_customers" -ForegroundColor Red } else { Write-Host "  $output_log" -ForegroundColor Red }
  exit 1
}

Compress-SizingArchive -OutputFiles $outputFiles -ArchiveFile $archiveFile

Write-Host
Write-Host
Write-Host "Results have been compressed into $archiveFile and original files have been removed." -ForegroundColor Green

Write-Host
Write-Host
Write-Host "Please send $archiveFile to your Rubrik representative." -ForegroundColor Cyan
Write-Host
