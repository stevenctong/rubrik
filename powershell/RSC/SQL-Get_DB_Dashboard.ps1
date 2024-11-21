# https://www.rubrik.com/api
# https://github.com/rubrikinc/rubrik-powershell-sdk
<#
.SYNOPSIS
This script gets the Database Log Events Dashboard.

.DESCRIPTION
This script gets the Database Log Events Dashboard.

This script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/20/24

For authentication, use a RSC Service Account:
** RSC Settings -> Users -> Service Account -> Create one and assign it an appropriate role
** Download the service account JSON
** Use Set-RscServiceAccountFile to configure the RSC Service Account for the SDK

.EXAMPLE
./SQL-Get_DB_Dashboard.ps1.ps1
Gets the Database Log Events and show the current log delay stats.
#>

### VARIABLES - START ###

param (
  [CmdletBinding()]
  # Rubrik cluster name
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # Database type - either 'SQL' or 'Oracle'
  [Parameter(Mandatory=$false)]
  [string]$databaseType = 'SQL',
  # Log Backup Delay threshold, in seconds
  [Parameter(Mandatory=$false)]
  [int]$logBackupDelay = 300
)

### VARIABLES - END ###

Import-Module RubrikSecurityCloud
$connection = Connect-Rsc

# Get the Rubrik Cluster ID
$rscCluster = Get-RscCluster -Name $cluster
$clusterUuid = $rscCluster.Id

$dbLogReportQuery = "
query DatabaseLogReportForClusterQuery(`$input: QueryLogReportInput!, `$clusterUuid: UUID!) {
  databaseLogReportForCluster(input: `$input) {
    data {
      id
      name
      lastSnapshotTime
      logBackupDelay
      primaryClusterId
      latestRecoveryTime
      effectiveSlaDomainId
      effectiveSlaDomainName
      logBackupFrequency
      location
      databaseType
      __typename
    }
    hasMore
    total
    __typename
  }
  cluster(clusterUuid: `$clusterUuid) {
    id
    timezone
    __typename
  }
}
"

$dbLogReportVars = @{
  clusterUuid = $clusterUuid
  input = @{
    clusterUuid = $clusterUuid
    databaseType = $databaseType
    sortBy = 'V1_QUERY_LOG_REPORT_REQUEST_SORT_BY_NAME'
    sortOrder = 'V1_QUERY_LOG_REPORT_REQUEST_SORT_ORDER_ASC'
  }
}

$result = $(Invoke-Rsc -GqlQuery $dbLogReportQuery -Var $dbLogReportVars).data

Write-Host "Got DB events for $($result.count) databases on cluster: $cluster" -foregroundcolor green

$noBackups = $result | Where { $_.LastSnapshotTime -eq $null }
$hasBackups = $result | Where { $_.LastSnapshotTime -ne $null }

$simpleModeDBs = $hasBackups | Where { $_.logBackupFrequency -eq $null }
$fullModeDBs = $hasBackups | Where { $_.logBackupFrequency -ne $null }

$delayedDBs = $fullModeDBs | Where { $_.logBackupDelay -gt $logBackupDelay }

Write-Host ""
Write-Host "Number of DBs without any backups: $($noBackups.count)" -foregroundcolor yellow
Write-Host "Number of DBs with at least one backup: $($hasBackups.count)" -foregroundcolor green

Write-Host ""
Write-Host "Number of DBs with backups in Simple mode: $($simpleModeDBs.count)" -foregroundcolor green
Write-Host "Number of DBs with backups in Full Recovery mode: $($fullModeDBs.count)" -foregroundcolor green
Write-Host "Number of DBs that have log backups delayed more than $logBackupDelay seconds: $($delayedDBs.count)" -foregroundcolor cyan

Disconnect-Rsc
