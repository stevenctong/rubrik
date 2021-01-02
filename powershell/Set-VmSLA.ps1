#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

# Written by Steven Tong for community usage
# GitHub: stevenctong
# Date: 10/8/20

# This script reads in a CSV file with a list of VMs and assigns a SLA to them
# CSV must have a column "name" containing the VM name
# CSV must have a column "sla" containing the SLA name, "DoNotProtect", or "Inherit
# By default the assignment will retain existing snapshots with the SLA that they were taken with

# Import VM list and identify what the column name of the VM name is called
$vmList = Import-Csv -Path 'vm_list.csv'

# Rubrik hostname or IP address
$server = 'sand1-rbk01.rubrikdemo.com'

##### RUBRIK AUTHENTICATION #####

# Option 1) Use an API token for authentication
# $token = ''

# Option 2) Use a credential file for authentication
# To create a credential file (note: only the user who creates it can use it):
# Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
# $credential  = Import-Clixml -Path ./rubrik_cred.xml

# Option 3) Use a username and password for authentication
# $user = ''
# $password = '' | ConvertTo-SecureString -AsPlainText -Force

# Connect to Rubrik cluster
# Connect-Rubrik -Server $server
Connect-Rubrik -Server $server -Credential $credential
# Connect-Rubrik -Server $server -Token $token
# Connect-Rubrik -Server $server -Username $user -Password $password

##### RUBRIK AUTHENTICATION #####

# Get all Rubrik VMware VMs from the cluster
$rubrikVMs = Get-RubrikVM

# Iterate through the provided list of VMs we want to assign a SLA to
foreach ($i in $vmList)
{
  $findVM = $rubrikVMs | Where-Object -Property 'name' -eq $i.name

  # If the VM name exists in the cluster then try to assign the SLA
  if ($findVM -ne $null)
  {
    try {
      if ($i.sla -eq 'DoNotProtect')
      { $result = Protect-RubrikVM -id $findVM.id -DoNotProtect }
      elseif ($i.sla -eq 'Inherit')
      { $result = Protect-RubrikVM -id $findVM.id -Inherit }
      else
      { $result = Protect-RubrikVM -id $findVM.id -SLA $i.sla }
      Write-Host "VM: $($i.name), Configured: $($result.configuredSlaDomainId), Effective: $($result.effectiveSlaDomainName)" -Foregroundcolor green
    } catch {
      Write-Error "$($i.name) error setting SLA to $($i.sla)"
    }
  }
  else { Write-Error "$($i.name) not found" }
}

Disconnect-Rubrik -Confirm:$false
