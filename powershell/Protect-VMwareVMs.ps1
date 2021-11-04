#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
The 'Protect-VMwareVMs.ps1' script accepts a CSV list of VMs to protect by assigning a SLA.

.DESCRIPTION
The 'Protect-VMwareVMs.ps1' script accepts a CSV list of VMs to protect by assigning a SLA.
The script will read in a CSV with the following headers:
- 'Object Name'
- 'Object Logical Size (GB)'
- 'Local Storage (GB)'

Pass in the CSV with this mandatory parameter: -vmCSV <CSV_file_of_VMs>
Pass in either SLA name with '-slaName <sla_name>' or SLA ID '-slaID <sla_id>'

Once read, the script will list out all the VMs with summary information.
Press "Y" to Protect the list of VMs by assigning it the SLA.

A CSV will be output with the status of executing the API calls to protect the VMs.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/4/21

For authentication, use one of the following methods:
$token - an API token tied to a user account; keep in mind that tokens have an expiration date
$credential - credential file that can be created using: Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
$user and $password - plaintext username and password

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Protect-VMwareVMs.ps1 -server <Rubrik_server> -vmCSV <CSV_file_of_VMs> -slaName 'Gold SLA'
The script will prompt for a username and password for the Rubrik cluster

.EXAMPLE
./Unprotect-VMwareVMs.ps1 -server <Rubrik_server> -token <API_token> -vmCSV <CSV_file_of_VMs> -slaID 'bf93a9de-9815-47f9-aa19-0a7e6083ea42'
Use an API token for authentication

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

  # CSV list of VMs to delete
  [Parameter(Mandatory=$true)]
  [string]$vmCSV = '',

  # SLA Name to assign for protection
  [Parameter(Mandatory=$false)]
  [string]$slaName = '',

  # SLA ID to assign for protection
  [Parameter(Mandatory=$false)]
  [string]$slaID = ''
)

Import-Module Rubrik

###### VARIABLES - BEGIN ######

$date = Get-Date

# Log file info
$logOutput = "./protect_vm-$($date.ToString("yyyy-MM-dd_HHmm")).log"

###### VARIABLES - END #######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if (!$server) { $server = Read-Host "Rubrik hostname or IP" }
  if ($token) { Connect-Rubrik -Server $server -Token $token }
  else {
    if ($user) {
      if ($password) {
        [SecureString]$password = ConvertTo-SecureString -String  $password -AsPlainText -Force
        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $user, $password
      }
      else { $credential = Get-Credential -Username $user }
    }
    elseif (Test-Path $rubrikCred) { $credential  = Import-Clixml -Path $rubrikCred }
    else { $credential = Get-Credential }
    Connect-Rubrik -Server $server -Credential $credential
  }
} catch {
  try {
    Write-Error "Error connecting to cluster or with authentication."
    $html = "Error connecting to cluster or with authentication."
    if ($sendEmail) { Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort }
    Exit 1
  } catch { Exit 1 }
}
###### RUBRIK AUTHENTICATION - END ######

if ($slaName -eq '' -and $slaID -eq '')
{
  Write-Host "`nError : Please pass in either the SLA name or SLA ID for assignment" -foregroundcolor yellow
  Write-Host "Use -slaName <sla_name> or -slaID <sla_id>" -foregroundcolor yellow
  exit
}

if ($slaID -ne '') {
  $slaName = $(Get-RubrikSLA -id $slaID).name
} else {
  $slaID = ''
  Write-Host 'here'
  $slaID = $(Get-RubrikSLA -name $slaName -PrimaryClusterID local).id

  if ($slaID -eq '') {
    Write-Host "`nError : Could note find SLA with name: $slaName" -foregroundcolor yellow
    exit
  }
}

$vmList = Import-CSV $vmCSV

Write-Host "`nList of VMs to protect:" -foregroundcolor green

$vmList | Format-Table
$vmCount = $vmList.count
$vmLogicalSize = [math]::Round($($VMlist.'Object Logical Size (GB)' | Measure -Sum).sum / 1000, 2)
$vmRubrikSize = [math]::Round($($VMlist.'Local Storage (GB)' | Measure -Sum).sum / 1000, 2)

Write-Host "Total # of VMs: $vmCount" -foregroundcolor green
Write-Host "Total Logical Size (TB): $vmLogicalSize TB" -foregroundcolor green
Write-Host "Total Rubrik Local Used Size (TB): $vmRubrikSize TB" -foregroundcolor green
Write-Host "SLA to assign to the VMs: $slaName" -foregroundcolor green
$proceed = Read-Host "Are you sure you want to proceed - type Y "

$vmResult = @()
$count = 0

if ($proceed -eq 'Y') {
  foreach ($vm in $vmList)
  {
    $count += 1

    $vmID = $(Get-RubrikVM -name $vm.'Object Name').id

    if ($vmID) {
      $result = Protect-RubrikVM -id $vmID -slaID $slaID
      Add-Content -Path $logOutput "[ $count / $vmCount ] Protected VM to $slaName : $($vm.'Object Name')"
      Write-Host "[ $count / $vmCount ] Protected VM to $slaName : $($vm.'Object Name')"
    } else {
      Add-Content -Path $logOutput "[ $count / $vmCount ] ERROR - No VM found: $($vm.'Object Name')"
      Write-Host "[ $count / $vmCount ] ERROR - No VM found: $($vm.'Object Name')" -foregroundcolor red
    }
  }
}

Write-Host "`nResults output to: $logOutput"
