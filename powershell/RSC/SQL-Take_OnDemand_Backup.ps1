# https://www.rubrik.com/api
# https://github.com/rubrikinc/rubrik-powershell-sdk
<#
.SYNOPSIS
This script takes an on demand backup of a SQL DB.

.DESCRIPTION
This script takes an on demand backup of a SQL DB.

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
./SQL-Take_OnDemand_Backup.ps1 -cluster <cluster> -sqlHost <sql_hostname>
  -sqlInstance <sql_instance> -sqlDBName <sql_db_name> -useCurrentSLA $true
Trigger an on demand backup by passing in all required parameters.DESCRIPTION
Use the currently assigned SLA.

.EXAMPLE
./SQL-Take_OnDemand_Backup.ps1 -cluster <cluster> -sqlHost <sql_hostname>
  -sqlInstance <sql_instance> -sqlDBName <sql_db_name> -useCurrentSLA $false
  -slaName <sla_name>
Trigger an on demand backup by passing in all required parameters.DESCRIPTION
Use another SLA that is passed in as a parameter.

.EXAMPLE
./SQL-Take_OnDemand_Backup.ps1
Trigger an on demand backup if the variables are defined within the script.
#>

### VARIABLES - START ###

param (
  [CmdletBinding()]
  # Rubrik cluster name
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # SQL Hostname
  [Parameter(Mandatory=$false)]
  [string]$sqlHost = '',
  # SQL Instance Name
  [Parameter(Mandatory=$false)]
  [string]$sqlInstance = '',
  # SQL Database Name
  [Parameter(Mandatory=$false)]
  [string]$sqlDBName = '',
  # Whether or not to use the currently assigned SLA
  [Parameter(Mandatory=$false)]
  [bool]$useCurrentSLA = $true,
  # If not using the current SLA, SLA to use
  [Parameter(Mandatory=$false)]
  [string]$slaName = ''
)

### VARIABLES - END ###

Import-Module RubrikSecurityCloud
$connection = Connect-Rsc

# Job in progress statuses
$jobInProgress = @('ACQUIRING','QUEUED','RUNNING')

# Get the Rubrik Cluster ID
$rscCluster = Get-RscCluster -Name $cluster
$clusterUuid = $rscCluster.Id

# Get Rubrik MS SQL details
$rscInstance = Get-RscMssqlInstance -HostName $sqlHost -InstanceName $sqlInstance -RscCluster $rscCluster
$rscDB = Get-RscMssqlDatabase -RscMssqlInstance $rscInstance -Name $sqlDBName

# If using current SLA, set the SLA ID to the current effective SLA on the DB
if ($useCurrentSLA) {
  $rscSLA = Get-RscSLA -id $rscDB.EffectiveSlaDomain.Id
} else {
  # If not using current SLA, get the SLA list and find the matching SLA Name
  $slaDomains = Get-RscSla -name $slaName
  $slaID = $($slaDomains | Where { $_.name -eq $slaName }).id
  $rscSLA = Get-RscSLA -id $slaID
}

# Start an On Demand Backup
Write-Host "Starting On Demand Backup for: $sqlHost\$sqlInstance\$sqlDBName on cluster $cluster"
$result = New-RscMssqlSnapshot -RscMssqlDatabase $rscDB -RscSlaDomain $rscSLA
$jobId = $result.Id

# Check and loop for T-Log status completion

# Create a query to 'mssqlJobStatus'
$jobStatus = New-RscQuery -GqlQuery mssqlJobStatus -FieldProfile FULL
$jobStatus.var.input = New-Object -TypeName RubrikSecurityCloud.Types.GetMssqlAsyncRequestStatusInput
$jobStatus.var.input.ClusterUuid = $clusterUuid
$jobStatus.var.input.id = $jobId

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
