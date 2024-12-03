# https://www.rubrik.com/api
# https://github.com/rubrikinc/rubrik-powershell-sdk
<#
.SYNOPSIS
This script assigns a SLA to a SQL Host Instance, AG, FC, or DB.

.DESCRIPTION
This script assigns a SLA to a SQL Host Instance, AG, FC, or DB.

This script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/25/24

For authentication, use a RSC Service Account:
** RSC Settings -> Users -> Service Account -> Create one and assign it an appropriate role
** Download the service account JSON
** Use Set-RscServiceAccountFile to configure the RSC Service Account for the SDK

.EXAMPLE
./SQL-Assign_SLA.ps1 -slaName 'Gold' -sqlDB 'AdventureWorks' -sqlHost 'PAHost'
  -sqlInstance 'PAInstance'
Assign an SLA to a SQL DB.

./SQL-Assign_SLA.ps1 -slaName 'Gold' -sqlHost 'PAHost'
Assign an SLA to a SQL Host.

./SQL-Assign_SLA.ps1 -slaID '40723531-34c0-479d-aaee-d9b508c5a227' -sqlAG 'F1AG'
Assign an SLA to a SQL AG using a SLA ID.
#>

### VARIABLES - START ###

param (
  [CmdletBinding()]
  # Rubrik cluster name
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # SLA ID to assign, provide this or $slaName
  [Parameter(Mandatory=$false)]
  [string]$slaID = '',
  # Name of SLA to assign, provide this or $slaID.
  # SLA Name can also be 'DO_NOT_PROTECT' or 'NO_ASSIGNMENT'
  [Parameter(Mandatory=$false)]
  [string]$slaName = '',
  # (option #1) SQL DB to assign SLA to. Also provide $slaHost and $sqlInstance
  [Parameter(Mandatory=$false)]
  [string]$sqlDB = '',
  # (option #2) SQL Hostname to assign SLA to
  [Parameter(Mandatory=$false)]
  [string]$sqlHost = '',
  # (option #3) SQL AG to assign SLA to
  [Parameter(Mandatory=$false)]
  [string]$sqlAG = '',
  # (option #1) If assignment to SQL DB, also provide SQL Instance
  [Parameter(Mandatory=$false)]
  [string]$sqlInstance = ''
)

### VARIABLES - END ###

Import-Module RubrikSecurityCloud
$connection = Connect-Rsc

# Get the Rubrik Cluster ID
$rscCluster = Get-RscCluster -Name $cluster
$clusterUuid = $rscCluster.Id

if ( -not ($slaID -eq '' -or $slaID -eq $null) ) {
  $rscSLA = Get-RscSLA -id $slaID
} elseif ($slaName -ne 'DO_NOT_PROTECT' -and $slaName -ne 'NO_ASSIGNMENT') {
  # Get an exact match for SLA Name
  $rscSLA = Get-RscSLA -name $slaName | Where { $_.name -eq $slaName }
}

# If no RSC SLA is found
if ($rscSLA.count -eq 0 -and $slaName -ne 'DO_NOT_PROTECT' -and $slaName -ne 'NO_ASSIGNMENT') {
  Write-Error "No SLA found by ID or Name"
}

# Depending on what variable is passed, get the object to assign the SLA to
if ($sqlDB -ne '' -and $sqlDB -ne $null) {
  $rscInstance = Get-RscMssqlInstance -HostName $sqlHost -InstanceName $sqlInstance -RscCluster $rscCluster
  $rscAssignment = Get-RscMssqlDatabase -RscMssqlInstance $rscInstance -Name $sqlDB
} elseif ($sqlHost -ne '' -and $sqlHost -ne $null) {
  $rscAssignment = Get-RscMssqlInstance -HostName $sqlHost
} elseif ($sqlAG -ne '' -and $sqlAG -ne $null) {
  $rscAssignment = Get-RscMssqlAvailabilityGroup -AvailabilityGroupName $sqlAG -rscCluster $rscCluster
}

$result = Protect-RscWorkload -InputObject $rscAssignment -sla $rscSLA

if ($result.success -eq $true) {
  Write-Host "Successfully assigned $($rscSLA.name) to $($rscAssignment.name)."
}
