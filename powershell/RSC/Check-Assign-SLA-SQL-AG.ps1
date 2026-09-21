# https://www.rubrik.com/api
<#
.SYNOPSIS
This script checks whether a SQL Server host's databases belong to an
Availability Group (AG) and optionally assigns an SLA Domain to that AG.

.DESCRIPTION
When onboarding a Windows SQL Server host into RSC, databases that participate
in an Availability Group should be protected at the AG level rather than per
host / per database. This script looks up one or more SQL hosts, determines
whether any of their databases are members of an AG, and reports the AG
name(s) and ID(s) found.

Optionally, an SLA Domain can be assigned to each distinct AG found, either by
providing the SLA name (which will be looked up to get its ID) or by
providing the SLA ID directly. AGs are deduped so the SLA is only assigned
once per AG, not once per member database. An AG that already has an SLA
assigned is skipped by default; use -ForceSLA to assign to it anyway.

This script requires communication to RSC via outbound HTTPS (TCP 443).

This script requires PowerShell v7+.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 9/21/26

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $ServiceAccountPath

For Service Account custom role:
** Create a custom role with the appropriate permissions to view MSSQL hosts,
   databases, Availability Groups, and SLA Domains, and to assign SLA Domains.

.PARAMETER SQLHostName
One or more SQL host names to check, comma-separated.

.PARAMETER SLAName
Optional. The name of the SLA Domain to assign to any AG(s) found. The name
will be looked up to resolve the SLA Domain ID. Cannot be used together with
-SLAId.

.PARAMETER SLAId
Optional. The ID of the SLA Domain to assign to any AG(s) found, provided
directly instead of a name lookup. Cannot be used together with -SLAName.

.PARAMETER ForceSLA
Optional switch. By default, if an AG's member databases already show an
assigned SLA (i.e. not 'UNPROTECTED' or 'DO_NOT_PROTECT'), that AG is skipped
during assignment. Use -ForceSLA to assign the given SLA to the AG regardless
of its current SLA.

.PARAMETER ExportCsv
Optional switch. Forces a CSV summary to be written even when only a single
host is checked. A CSV is written automatically when more than one host is
provided.

.PARAMETER ServiceAccountPath
Optional. Filepath to the RSC Service Account JSON credentials.
Defaults to './rsc-service-account-rr.json'.

.PARAMETER CsvOutputPrefix
Optional. Prefix for the CSV output filename. The date/time will be appended
automatically. Defaults to './rubrik_sql_ag_sla_assignment'.

.EXAMPLE
./Check-Assign-SLA-SQL-AG.ps1 -SQLHostName 'sqlhost01'
Checks whether 'sqlhost01' has any databases in an Availability Group.

.EXAMPLE
./Check-Assign-SLA-SQL-AG.ps1 -SQLHostName 'sqlhost01,sqlhost02' -SLAName 'Gold'
Checks both hosts for AG membership and assigns the 'Gold' SLA Domain to any
AG(s) found.

.EXAMPLE
./Check-Assign-SLA-SQL-AG.ps1 -SQLHostName 'sqlhost01' -SLAId 'a1b2c3d4-1234-5678-9abc-def012345678'
Checks 'sqlhost01' for AG membership and assigns the SLA Domain with the
given ID to any AG(s) found.

.EXAMPLE
./Check-Assign-SLA-SQL-AG.ps1 -SQLHostName 'sqlhost01' -SLAName 'Gold' -ForceSLA
Checks 'sqlhost01' for AG membership and assigns the 'Gold' SLA Domain to any
AG(s) found, even if the AG already has a different SLA assigned.
#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]
  # One or more SQL host names to check, comma-separated
  [Parameter(Mandatory=$false)]
  [string]$SQLHostName = '',
  # Name of the SLA Domain to resolve and assign to any AG(s) found
  [Parameter(Mandatory=$false)]
  [string]$SLAName = '',
  # ID of the SLA Domain to assign directly to any AG(s) found
  [Parameter(Mandatory=$false)]
  [string]$SLAId = '',
  # Assign the SLA even if the AG already has one assigned
  [Parameter(Mandatory=$false)]
  [switch]$ForceSLA,
  # Force a CSV summary to be written even for a single host
  [Parameter(Mandatory=$false)]
  [switch]$ExportCsv,
  # Filepath for the RSC Service Account json creds
  [Parameter(Mandatory=$false)]
  [string]$ServiceAccountPath = './rsc-service-account-rr.json',
  # CSV output prefix, filename will have the date/time appended
  [Parameter(Mandatory=$false)]
  [string]$CsvOutputPrefix = './rubrik_sql_ag_sla_assignment'
)

$date = Get-Date
$dateString = $date.ToString("yyyy-MM-dd_HHmm")

### VARIABLES - END ###

if ($SQLHostName -eq '') {
  Write-Host ""
  Write-Host "Usage: ./Check-Assign-SLA-SQL-AG.ps1 -SQLHostName <hostname1,hostname2,...> [-SLAName <name> | -SLAId <id>] [-ExportCsv]"
  Write-Host ""
  Write-Host "Checks whether the given SQL host(s) have databases in a SQL Server"
  Write-Host "Availability Group (AG), and optionally assigns an SLA Domain to any"
  Write-Host "AG(s) found - either by SLA name (-SLAName) or SLA ID (-SLAId)."
  Write-Host ""
  exit 0
}

if ($SLAName -ne '' -and $SLAId -ne '') {
  throw "Specify either -SLAName or -SLAId, not both."
}

if ($PSVersionTable.PSVersion.Major -le 5) {
  Write-Error "Current PS version: $PSVersionTable.PSVersion.Major"
  Write-Error "Script requires PS version 7+"
  Write-Error "This script may have errors running"
}

$hostNameList = $SQLHostName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique

###### RUBRIK AUTHENTICATION - BEGIN ######

Write-Host "Attempting to read the Service Account file: $ServiceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$ServiceAccountPath" -ErrorAction Stop | ConvertFrom-Json
} catch {
  $errorMessage = $_.Exception | Out-String
  if($errorMessage.Contains('because it does not exist')) {
    throw "The Service Account JSON secret file was not found. Ensure the file is location at $ServiceAccountPath."
  }
  throw $_.Exception
}

Write-Debug -Message "Determing if the Service Account file contains all required variables."
$missingServiceAccount = @()
if ($serviceAccountFile.client_id -eq $null) {
  $missingServiceAccount += "'client_id'"
}

if ($serviceAccountFile.client_secret -eq $null) {
  $missingServiceAccount += "'client_secret'"
}

if ($serviceAccountFile.access_token_uri -eq $null) {
  $missingServiceAccount += "'access_token_uri'"
}

if ($missingServiceAccount.count -gt 0){
  throw "The Service Account JSON secret file is missing the required paramaters: $missingServiceAccount"
}

$headers = @{
  'Content-Type' = 'application/json';
  'Accept' = 'application/json';
}

$payload = @{
  grant_type = "client_credentials";
  client_id = $serviceAccountFile.client_id;
  client_secret = $serviceAccountFile.client_secret
}

$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")

Write-Host "Connecting to RSC to get an auth token: $rubrikURL"
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

$global:rubrikConnection = @{
  accessToken = $response.access_token;
  rubrikURL = $rubrikURL
}

if ($null -eq $rubrikConnection.accessToken) {
  throw "Error getting access token, exiting..."
}

# Rubrik GraphQL API URL
$endpoint = $rubrikConnection.rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json';
  'Accept' = 'application/json';
  'Authorization' = $('Bearer ' + $rubrikConnection.accessToken);
}

Write-Host "Successfully connected to: $rubrikURL" -foregroundcolor green

###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Look up a MSSQL host by name
Function Get-MssqlHost {
  param (
    [CmdletBinding()]
    # Host name to search for
    [Parameter(Mandatory=$true)]
    [string]$hostName
  )
  $variables = @{
    "typeFilter" = @("MSSQL_HOST")
    "filter" = @(
      @{
        "field" = "NAME"
        "texts" = @($hostName)
      }
    )
  }
  $query = 'query MssqlTopLevelDescendantsQuery($typeFilter: [HierarchyObjectTypeEnum!], $filter: [Filter!]) {
    mssqlTopLevelDescendants(typeFilter: $typeFilter, filter: $filter) {
      edges {
        node {
          id
          name
          objectType
          __typename
        }
        __typename
      }
      __typename
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.mssqlTopLevelDescendants
  return $result.edges.node
}  ### Function Get-MssqlHost

# Get all MSSQL database descendants of a host, including AG membership info
Function Get-MssqlHostDatabases {
  param (
    [CmdletBinding()]
    # Host ID (fid) to get databases for
    [Parameter(Mandatory=$true)]
    [string]$hostId,
    # Page info after cursor
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
  )
  $variables = @{
    "id" = $hostId
    "typeFilter" = @("Mssql")
    "first" = 1000
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = 'query MssqlHostHierarchyDatabaseListQuery($id: UUID!, $typeFilter: [HierarchyObjectTypeEnum!], $first: Int, $after: String) {
    hierarchyObject(fid: $id) {
      id
      name
      ... on MssqlHost {
        databaseDescendantConnection: descendantConnection(typeFilter: $typeFilter, first: $first, after: $after) {
          edges {
            node {
              id
              name
              logicalPath {
                fid
                name
                objectType
                __typename
              }
              effectiveSlaDomain {
                id
                name
                __typename
              }
              ... on MssqlDatabase {
                isInAvailabilityGroup
              }
              __typename
            }
            __typename
          }
          pageInfo {
            endCursor
            hasNextPage
            __typename
          }
          __typename
        }
      }
      __typename
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.hierarchyObject
  return $result.databaseDescendantConnection
}  ### Function Get-MssqlHostDatabases

# Look up an SLA Domain by exact name and return its id/name
Function Get-SLADomainByName {
  param (
    [CmdletBinding()]
    # SLA Domain name to search for
    [Parameter(Mandatory=$true)]
    [string]$slaName
  )
  $variables = @{
    "filter" = @(
      @{
        "field" = "NAME"
        "text" = $slaName
      }
    )
  }
  $query = 'query SLADomainsForNameFilterQuery($filter: [GlobalSlaFilterInput!]) {
    slaDomains(filter: $filter) {
      nodes {
        id
        name
        __typename
      }
      __typename
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.slaDomains
  return $result.nodes
}  ### Function Get-SLADomainByName

# Assign an SLA Domain to an object hierarchy (e.g. an Availability Group)
Function Set-SLAForHierarchy {
  param (
    [CmdletBinding()]
    # Object ID (fid) of the hierarchy root to assign the SLA to
    [Parameter(Mandatory=$true)]
    [string]$objectId,
    # SLA Domain ID to assign
    [Parameter(Mandatory=$true)]
    [string]$slaId
  )
  $variables = @{
    "objectIds" = @($objectId)
    "globalSlaAssignType" = "protectWithSlaId"
    "globalSlaOptionalFid" = $slaId
    "shouldApplyToExistingSnapshots" = $false
    "shouldApplyToNonPolicySnapshots" = $false
    "userNote" = ""
  }
  $query = 'mutation AssignSlasForSnappableHierarchiesMutation($globalExistingSnapshotRetention: GlobalExistingSnapshotRetention, $globalSlaOptionalFid: UUID, $globalSlaAssignType: SlaAssignTypeEnum!, $objectIds: [UUID!]!, $applicableSnappableTypes: [WorkloadLevelHierarchy!], $shouldApplyToExistingSnapshots: Boolean, $shouldApplyToNonPolicySnapshots: Boolean, $userNote: String) {
    assignSlasForSnappableHierarchies(globalExistingSnapshotRetention: $globalExistingSnapshotRetention, globalSlaOptionalFid: $globalSlaOptionalFid, globalSlaAssignType: $globalSlaAssignType, objectIds: $objectIds, applicableSnappableTypes: $applicableSnappableTypes, shouldApplyToExistingSnapshots: $shouldApplyToExistingSnapshots, shouldApplyToNonPolicySnapshots: $shouldApplyToNonPolicySnapshots, userNote: $userNote) {
      success
      __typename
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.assignSlasForSnappableHierarchies
  return $result
}  ### Function Set-SLAForHierarchy

###### FUNCTIONS - END ######

# Resolve the SLA Domain to assign, if one was requested
$resolvedSLAId = ''
$resolvedSLAName = ''
if ($SLAId -ne '') {
  $resolvedSLAId = $SLAId
  $resolvedSLAName = $SLAId
} elseif ($SLAName -ne '') {
  Write-Host "Looking up SLA Domain: $SLAName"
  $slaMatches = Get-SLADomainByName -slaName $SLAName
  $exactMatches = $slaMatches | Where-Object { $_.name -eq $SLAName }
  if ($exactMatches.count -eq 0) {
    throw "No SLA Domain found with the exact name: $SLAName"
  }
  if ($exactMatches.count -gt 1) {
    throw "Multiple SLA Domains found with the exact name: $SLAName. Use -SLAId instead."
  }
  $resolvedSLAId = $exactMatches[0].id
  $resolvedSLAName = $exactMatches[0].name
  Write-Host "Resolved SLA Domain '$resolvedSLAName' to ID: $resolvedSLAId" -foregroundcolor green
}
$assignSLA = ($resolvedSLAId -ne '')

# Check each host for AG membership
$summaryList = @()
$distinctAGs = @{}

foreach ($hostName in $hostNameList) {
  Write-Host ""
  Write-Host "Checking host: $hostName"
  $hostMatches = Get-MssqlHost -hostName $hostName
  $hostMatch = $hostMatches | Where-Object { $_.name -eq $hostName } | Select-Object -First 1
  if ($null -eq $hostMatch) {
    Write-Host "Host not found: $hostName" -foregroundcolor yellow
    continue
  }
  try {
    $dbConnection = Get-MssqlHostDatabases -hostId $hostMatch.id
  } catch {
    Write-Host "Error querying databases for host: $hostName - $($_.Exception.Message)" -foregroundcolor red
    continue
  }
  $databases = $dbConnection.edges.node
  $totalDatabases = $databases.count
  $agDatabaseCount = 0
  foreach ($db in $databases) {
    if ($db.isInAvailabilityGroup -eq $true) {
      $agNode = $db.logicalPath | Where-Object { $_.objectType -eq 'MssqlAvailabilityGroup' } | Select-Object -First 1
      if ($null -eq $agNode) {
        Write-Host "Database '$($db.name)' is flagged as in an AG but no AG entry was found in its logical path" -foregroundcolor yellow
        continue
      }
      $agDatabaseCount++
      $currentSLA = $db.effectiveSlaDomain.name
      $summaryList += [PSCustomObject] @{
        "SQLHostName" = $hostName
        "DatabaseName" = $db.name
        "AGName" = $agNode.name
        "AGId" = $agNode.fid
        "CurrentSLA" = $currentSLA
      }
      if (-not $distinctAGs.ContainsKey($agNode.fid)) {
        $distinctAGs[$agNode.fid] = [PSCustomObject] @{
          "Name" = $agNode.name
          "CurrentSLA" = $currentSLA
        }
      }
    }
  }
  $nonAgDatabaseCount = $totalDatabases - $agDatabaseCount
  if ($agDatabaseCount -gt 0) {
    Write-Host "Databases in an AG on host $hostName below. There are $nonAgDatabaseCount databases on this host that are not in an AG." -foregroundcolor green
  } else {
    Write-Host "No databases in an AG found on this host. There are $nonAgDatabaseCount databases on this host that are not in an AG." -foregroundcolor cyan
  }
}

Write-Host ""
$summaryList | Format-Table -AutoSize

# Assign the SLA Domain to each distinct AG found, if requested
if ($assignSLA) {
  if ($distinctAGs.count -eq 0) {
    Write-Host ""
    Write-Host "No AGs were found across the given host(s), skipping SLA assignment." -foregroundcolor yellow
  } else {
    Write-Host ""
    Write-Host "Found $($distinctAGs.count) distinct AG(s):"
    foreach ($agFid in $distinctAGs.Keys) {
      $agInfo = $distinctAGs[$agFid]
      Write-Host "  $($agInfo.Name) (ID: $agFid), current SLA: '$($agInfo.CurrentSLA)'"
    }
    Write-Host ""
    Write-Host "Assigning SLA Domain '$resolvedSLAName' to $($distinctAGs.count) AG(s)..."
    foreach ($agFid in $distinctAGs.Keys) {
      $agInfo = $distinctAGs[$agFid]
      $agName = $agInfo.Name
      $currentSLA = $agInfo.CurrentSLA
      $isProtected = $currentSLA -ne $null -and $currentSLA -ne '' -and $currentSLA -ne 'UNPROTECTED' -and $currentSLA -ne 'DO_NOT_PROTECT'
      if ($isProtected -and -not $ForceSLA) {
        Write-Host "Skipping AG '$agName' (ID: $agFid) - already has SLA '$currentSLA' assigned. Use -ForceSLA to override." -foregroundcolor yellow
        continue
      }
      $assignResult = Set-SLAForHierarchy -objectId $agFid -slaId $resolvedSLAId
      if ($assignResult.success -eq $true) {
        Write-Host "Successfully assigned SLA '$resolvedSLAName' to AG '$agName' (ID: $agFid)" -foregroundcolor green
      } else {
        Write-Host "Failed to assign SLA '$resolvedSLAName' to AG '$agName' (ID: $agFid)" -foregroundcolor red
      }
    }
  }
}

if ($ExportCsv -or $hostNameList.count -gt 1) {
  $csvOutput = "$CsvOutputPrefix-$dateString.csv"
  $summaryList | Export-CSV -Path $csvOutput -NoTypeInformation
  Write-Host "Results output to: $csvOutput"
}
