# https://www.rubrik.com/api
# https://github.com/rubrikinc/rubrik-powershell-sdk
<#
.SYNOPSIS
This script will add a host to a Rubrik cluster.

.DESCRIPTION
This script will add a host to a Rubrik cluster.

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
./Add-Host.ps1 -cluster <cluster> -hostname <hostname_or_ip>
Add the host to the Rubrik cluster.
#>

### VARIABLES - START ###

param (
  [CmdletBinding()]
  # Rubrik cluster name
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # Hostnames or IPs to add
  [Parameter(Mandatory=$false)]
  [string]$hostname = ''
)

### VARIABLES - END ###

Import-Module RubrikSecurityCloud
$connection = Connect-Rsc

# Get the Rubrik Cluster ID
$rscCluster = Get-RscCluster -Name $cluster
$clusterUuid = $rscCluster.Id

$hosts = @( @{ Hostname = $hostname } )

$registerHost = New-RscMutationHost -operation BulkRegister
$registerHost.var.input = New-Object -TypeName RubrikSecurityCloud.Types.BulkRegisterHostInput
$registerHost.var.input.clusterUuid = $clusteruuid
$registerHost.var.input.hosts = $hosts

$result = Invoke-Rsc $registerHost
if ($result -eq $null -or $result.count -eq 0) {
  Write-Error "Error adding host: $hostname"
} else {
  Write-Host "Successfully added host: $hostname"
}
