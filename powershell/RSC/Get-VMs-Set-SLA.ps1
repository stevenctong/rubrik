<#
.SYNOPSIS
This script imports a CSV of VMware VMs and assigns a SLA to them.

.DESCRIPTION
This script imports a CSV of VMware VMs and assigns a SLA to them.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 6/3/25

Requirements:
- Rubrik Security Cloud PowerShell SDK: https://github.com/rubrikinc/rubrik-powershell-sdk

.EXAMPLE
./Get-VMs-Set-SLA.ps1 -csvInput './ashlist.csv' -slaName '1d-7d'
Read in a CSV file and assigns all VMs under column 'Name' to the SLA '1d-7d'

#>

param (
  [CmdletBinding()]
  # CSV File
  [Parameter(Mandatory=$true)]
  [string]$csvInput = '',
  # SLA Name
  [Parameter(Mandatory=$true)]
  [string]$slaName = ''
)

$date = Get-Date

Write-Host "Importing list of VMs from CSV: $csvInput"
$csvList = Import-Csv $csvInput -ErrorAction Stop
if ($csvList.count -eq 0) {
  Write-Error "No VMs found in CSV, exiting..."
  exit
}
Write-Host "Found $($csvList.count) VMs to assign SLA" -foregroundcolor green

Write-Host "Connecting to RSC..."
Connect-Rsc

Write-Host "Getting SLA details for: $slaName"
$slaInfo = Get-RscSla -Name $slaName
if ($slaInfo -eq $null) {
  Write-Error "SLA $slaName not found, exiting..."
  exit
} else {
  Write-Host "Found SLA: $slaName" -foregroundcolor green
  $slaInfo
}

Write-Host "Getting a list of VMware VMs..."
$vms = Get-RscVmwareVm
Write-Host "$($vms.count) VMware VMs found" -foregroundcolor green

$count = 1
$total = $csvList.count

foreach ($vm in $csvList) {
  Write-Host "[$count / $total] Looking up VM: $($vm.name)..."
  $vmInfo = $vms | Where-Object { $_.name -eq $vm.name }
  if ($vmInfo -eq $null) {
    Write-Error "Could not find VM: $($vm.name)"
  } else {
    Write-Host "[$count / $total] Assigning SLA to VM: $($vm.name)..."
    $result = $vmInfo | Protect-RscWorkload -Sla $slaInfo
    if ($result.success -ne $true) {
      Write-Error "Error assigning to VM: $($vm.name)"
      $result
    }
  }
}

Disconnect-Rsc
