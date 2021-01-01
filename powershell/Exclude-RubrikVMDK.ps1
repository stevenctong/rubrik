#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Provide a VM to show a list of its VMDKs and select one or more to exclude

.DESCRIPTION
The Exclude-RubrikVMDK script shows the VMDKs for a VM and allows you to select one or more to exclude.
You must pass in the VM name in the "-vm" argument.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 9/29/20

For authentication, use an API token (recommended), username/password, or credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./Exclude-RubrikVMDK.ps1 -server <Rubrik_server> -token <API_token> -vm testvm
Use an API token for authentication

.EXAMPLE
./Get-.ps1 -server <Rubrik_server> -vm testvm
Checks for credential file and if none found prompts for username/password.

#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$false)]
  [string]$server = '',

  # Use API token for authentication
  [Parameter(Mandatory=$false)]
  [string]$token = $null,

  # Use Rubrik username/password for authentication
  [Parameter(Mandatory=$false)]
  [string]$user = $null,

  # Use Rubrik username/password for authentication
  [Parameter(Mandatory=$false)]
  [string]$password = $null,

  # Use credential file for authentication, location of it
  [Parameter(Mandatory=$false)]
  [string]$rubrikCred = 'rubrik_cred.xml',

  # VM name to exclude VMDKs on
  [Parameter(Mandatory=$true)]
  [string]$vm
)

Import-Module Rubrik

# Rubrik authentication - first try using API token, then username/password if a user is provided, then credential file
try
{
  if ($token) {
    Connect-Rubrik -Server $server -Token $token
  }
  # Else if a username is provided, use username/password for authentication
  elseif ($user) {
    if ($password) {
      $password = ConvertTo-SecureString $password -AsPlainText -Force

      Connect-Rubrik -Server $server -Username $user -Password $password
    }
    # If username provided but no password, prompt for a password
    else {
      $credential = Get-Credential -Username $user

      Connect-Rubrik -Server $server -Credential $credential
    }
  }
  # Else if a credential file is found then use for authentication
  elseif (Test-Path $rubrikCred) {

    # Import Credential file
    $credential  = Import-Clixml -Path $rubrikCred

    Connect-Rubrik -Server $server -Credential $credential
  }
  # Else if no authentication method is provided then prompt for username/password
  else {
    Write-Host "`nNo API token or credential file found ($rubrikCred), please provide Rubrik credentials"

    $credential = Get-Credential
    Connect-Rubrik -Server $server -Credential $credential
  }
} catch
{
  $ERROR[0]
  Exit
}

# Get VM details and exit if no VM found
$vmInfo = Get-RubrikVM $vm | Select-Object "name", "id"

if ($vmInfo.id -eq $null) {
  Write-Error "`nNo VM found by name $vm"
  break
} else {
  $vmInfo
}

# Get VMDKs associated with the VM
$vmdks = Get-RubrikVM -id $vmInfo.id | Select-Object -ExpandProperty "virtualDiskIds"
$vmdksList = @()

Write-Host "Listing VMDKs for VM: $vmInfo.name"

$num = -1

# Loop through each VMDK and get additional details for each VMDK into an array ($vmdksList)
foreach ($i in $vmdks)
{
  $num += 1
  $vmdkInfo = Invoke-RubrikRESTCall -Method "Get" -Endpoint "vmware/vm/virtual_disk/$i"

  $vmdkObj = New-Object PSObject
  $vmdkObj | Add-Member -MemberType NoteProperty -Name "number" -Value $num
  $vmdkObj | Add-Member -MemberType NoteProperty -Name "fileName" -Value $vmdkInfo.fileName
  $vmdkObj | Add-Member -MemberType NoteProperty -Name "sizeGB" -Value ($vmdkInfo.size / 1000000000)
  $vmdkObj | Add-Member -MemberType NoteProperty -Name "excludeFromSnapshots" -Value $vmdkInfo.excludeFromSnapshots
  $vmdkObj | Add-Member -MemberType NoteProperty -Name "id" -Value $vmdkInfo.id

  $vmdksList += $vmdkObj
}

# List all VMDKs and then prompt user for which VMDKs they want to exclude
$vmdksList

do
{
  $vmdkNumError = $false

  # Get user input on VMDKs to exclude based on displayed list
  [string]$vmdkNum = Read-Host -Prompt "Which VMDK number(s) do you want to exclude (comma separated) [0-$num]"
  [array]$vmdkNumList = $vmdkNum.Split(",")

  # Light error checking of user input
  foreach ($j in $vmdkNumList)
  {
    if ($j -lt 0 -or $vmdkNum -gt $num)
    {
      Write-Error "VMDK number $j is not in range"
      $vmdkNumError = $true
    }
  }
} while ($vmdkNumError -eq $true)

# List out VMDKs chosen
Write-Host "Excluding the following VMDKs"

foreach ($k in $vmdkNumList)
{
  $vmdksList[$k]
}

# Excludes each VMDK in the list
foreach ($k in $vmdkNumList)
{
  $exportJson = New-Object PSObject

  $exportJson | Add-Member -MemberType NoteProperty -Name "excludeFromSnapshots" -Value $true

  $result = Invoke-RubrikRESTCall -Method "Patch" -Body $exportJson -Endpoint "vmware/vm/virtual_disk/$($vmdksList[$k].id)" -verbose
}

Disconnect-Rubrik -Confirm:$false
