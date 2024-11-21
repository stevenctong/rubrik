# https://www.rubrik.com/api
# https://github.com/rubrikinc/rubrik-powershell-sdk
<#
.SYNOPSIS
This script performs an Export Restore of a SQL DB to the latest recovery point.

.DESCRIPTION
This script performs an Export Restore of a SQL DB to the latest recovery point..

An Export Restore creates a new DB from a source DB and recovery point.

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
./SQL-Export_DB.ps1 -cluster <cluster> -sourceSqlHost <source_sql_hostname>
  -sourceSqlInstance <source_sql_instance> -sourceSqlDBName <source_sql_db_name>
  -targetSqlHost <target_sql_host> -targetSqlInstance <target_sql_instance>
  -targetSqlDBName <target_sql_db_name> -exportType 'Advanced'
Trigger a SQL DB Export by passing in all required parameters. Use the 'Advanced'
Export option where the script will use the same folder path and rename the
database files to the new target DB name.

.EXAMPLE
./SQL-Export_DB.ps1 -cluster <cluster> -sourceSqlHost <source_sql_hostname>
  -sourceSqlInstance <source_sql_instance> -sourceSqlDBName <source_sql_db_name>
  -targetSqlHost <target_sql_host> -targetSqlInstance <target_sql_instance>
  -targetSqlDBName <target_sql_db_name> -exportType 'Basic'
  -targetDataPath <target_data_folder_path> -targetLogPath <target_log_folder_path>
Trigger a SQL DB Export by passing in all required parameters. Use the 'Basic'
Export option where thet target directories need to be specified. The database
filenames will be the same as the original filenames.

.EXAMPLE
./SQL-Export_DB.ps1
Trigger an on demand backup if the variables are defined within the script.
#>

### VARIABLES - START ###

param (
  [CmdletBinding()]
  # Rubrik cluster name
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # Source SQL Hostname
  [Parameter(Mandatory=$false)]
  [string]$sourceSqlHost = '',
  # Source SQL Instance Name
  [Parameter(Mandatory=$false)]
  [string]$sourceSqlInstance = '',
  # Source SQL Database Name
  [Parameter(Mandatory=$false)]
  [string]$sourceSqlDBName = '',
  # Target SQL Hostname
  [Parameter(Mandatory=$false)]
  [string]$targetSqlHost = '',
  # Target SQL Instance Name
  [Parameter(Mandatory=$false)]
  [string]$targetSqlInstance = '',
  # Target SQL Database Name
  [Parameter(Mandatory=$false)]
  [string]$targetSqlDBName = '',
  # Export type - Basic (specify target directory) or Advanced (rename target filenames)
  [Parameter(Mandatory=$false)]
  [string]$exportType = '',
  # Target Data Path Folder - For Basic Export
  [Parameter(Mandatory=$false)]
  [string]$targetDataPath = '',
  # Target Log Path Folder - For Basic Export
  [Parameter(Mandatory=$false)]
  [string]$targetLogPath = ''
)

### VARIABLES - END ###

Import-Module RubrikSecurityCloud
$connection = Connect-Rsc

# Job in progress statuses
$jobInProgress = @('ACQUIRING','QUEUED','RUNNING')

# Get the Rubrik Cluster ID
$rscCluster = Get-RscCluster -Name $cluster
$clusterUuid = $rscCluster.Id

# Get Source Rubrik MS SQL details
$sourceRscInstance = Get-RscMssqlInstance -HostName $sourceSqlHost -InstanceName $sourceSqlInstance -RscCluster $rscCluster
$sourceRscDB = Get-RscMssqlDatabase -RscMssqlInstance $sourceRscInstance -Name $sourceSqlDBName
if ($sourceRscDB.count -eq 0) {
  Write-Error "Could not find source DB: $sourceSqlHost\$sourceSqlInstance\$sourceSqlDBName"
}

# Get the latest recovery point
$latestRecoveryPoint = Get-RscMssqlDatabaseRecoveryPoint -RscMssqlDatabase $rscDB -Latest
if ($latestRecoveryPoint -eq $null) {
  Write-Error "Could not find a recovery point for source DB"
} else {
  Write-Host "Latest recovery point for source DB is (UTC): $latestRecoveryPoint"
}

# Get Target Rubrik MS SQL details
$targetRscInstance = Get-RscMssqlInstance -HostName $targetSqlHost -InstanceName $targetSqlInstance -RscCluster $rscCluster
if ($targetRscInstance.count -eq 0) {
  Write-Error "Could not find target instance: $targetSqlHost\$targetSqlInstance"
}

# If Export type is 'Basic' then only a target directory path for the data and
# log files are specified. The filenames will remain the same as the source DB.
if ($exportType -eq 'Basic') {
  $newRscMssqlExport = @{
      RscMssqlDatabase = $sourceRscDB
      RecoveryDateTime = $latestRecoveryPoint
      TargetMssqlInstance = $targetRscInstance
      TargetDatabaseName = $targetSqlDBName
      TargetDataPath = $targetDataPath
      TargeLogPath = $targetLogPath
      Overwrite = $true
      FinishRecovery = $true
  }
  Write-Host "Performing a Basic Export"
  Write-Host "Source DB: $sourceSqlHost\$sourceSqlInstance\$sourceSqlDBName"
  Write-Host "Target DB: $targetSqlHost\$targetSqlInstance\$targetSqlDBName"
  $newRscMssqlExport
}

# If Export type is 'Advanced' then we will use the same directory as the source
# DB and rename each filename to start with the name of the target DB.
if ($exportType -eq 'Advanced') {
  # Get the current file path details of the source DB
  $dbFiles = Get-RscMssqlDatabaseFiles -RscMssqlDatabase $sourceRscDB -RecoveryDateTime $latestRecoveryPoint
  # Holds the target file path mapping variable
  $targetMappings = @()
  # Counts to increment for each additional data and log file
  $dataCount = 1
  $logCount = 0
  # For each source file path, build the target file mapping
  foreach ($file in $dbFiles) {
    $fileExtension = $file.OriginalName -split '\.+' | Select-Object -Last 1
    if ($fileExtension -eq 'mdf') {
      $newFilename = $targetSqlDBName + '.' + $fileExtension
    } elseif ($fileExtension -eq 'ndf') {
      $newFilename = $targetSqlDBName + '_' + $dataCount + '.' + $fileExtension
      $dataCount += 1
    } else {
      if ($logCount -eq 0) {
        $newFilename = $targetSqlDBName + '_' + 'Log' + '.' + $fileExtension
      } else {
        $newFilename = $targetSqlDBName + '_' + 'Log' + $logCount + '.' + $fileExtension
      }
      $logCount += 1
    }
    $targetMap = @{
      exportPath = $file.OriginalPath
      logicalName = $file.logicalName
      newFilename = $newFilename
    }
    $targetMappings += $targetMap
  }
  $newRscMssqlExport = @{
      RscMssqlDatabase = $sourceRscDB
      RecoveryDateTime = $latestRecoveryPoint
      TargetMssqlInstance = $targetRscInstance
      TargetDatabaseName = $targetSqlDBName
      TargetFilePaths = $targetMappings
      Overwrite = $true
      FinishRecovery = $true
  }
  Write-Host "Performing an Advanced Export"
  Write-Host "Source DB: $sourceSqlHost\$sourceSqlInstance\$sourceSqlDBName"
  Write-Host "Target DB: $targetSqlHost\$targetSqlInstance\$targetSqlDBName"
  $newRscMssqlExport
  $newRscMssqlExport.targetFilePaths
}

$result = New-RscMssqlExport @NewRscMssqlExport
$jobId = $result.Id

# Check and loop for status completion

# Create a query to 'mssqlJobStatus'
$jobStatus = New-RscQuery -GqlQuery mssqlJobStatus -FieldProfile FULL
$jobStatus.var.input = New-Object -TypeName RubrikSecurityCloud.Types.GetMssqlAsyncRequestStatusInput
$jobStatus.var.input.ClusterUuid = $clusterUuid
$jobStatus.var.input.id = $jobId

Write-Host ""
Write-Host "Checking status and looping until completion..."

# Loop to check for job completion
do {
  $status = Invoke-Rsc $jobStatus
  $status
  Write-Host "Waiting 10 seconds..."
  Start-Sleep -Seconds 10
} while ($status.status -in $jobInProgress)

if ($status.status -eq 'FAILED') {
  $status.error | Format-List
}
