#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
This script will bulk set the consistency level of a VM

.DESCRIPTION
This script will bulk set the consistency level of a VM

.NOTES
Written originally by Chris Lunmah for community usage
Updated by Steven Tong
GitHub: stevenctong
Date: 6/30/22

First connect to a Rubrik cluster using "Connect-Rubrik".
Update the parameters below as needed for SLA or consistency setting.

.EXAMPLE
./Set-App-Consistency.ps1
#>

# Get a list of Nutanix VMs
# For VMware, use "Get-RubrikVM"
$vms = Get-RubrikNutanixVM

# Specify the SLA that you want to set the consistency for
$sla = '1d-30d-NoArchive'

# Consistency levels: Automatic, ApplicationConsistent, CrashConsistent
$consistency = 'ApplicationConsistent'

foreach($vm in $vms)
{
  # If you want to set consistency level regardless of SLA, comment out this if statement block
  if($vm.effectiveSlaDomainName -eq $sla)
  {
    Write-Host "$($vm.name)" -foregroundcolor green
    Write-Host "Current Consistency - $($vm.snapshotConsistencyMandate)"
    # For VMWare use 'Set-RubrikVM'
    Set-RubrikNutanixVM -id $vm.id -SnapConsistency $consistency -confirm:0 | out-null
    $newVM = Get-RubrikNutanixVM -id $vm.id
    Write-Host "New Consistency - $($newVM.snapshotConsistencyMandate)"
    Write-Host ""
  }
}
