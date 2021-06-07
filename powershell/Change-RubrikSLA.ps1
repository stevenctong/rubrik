#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
The 'Change-RubrikSLA.ps1' script reads a CSV file with a list of VMware VMs and SLAs and assigns a SLA to each VM.

.DESCRIPTION
The 'Change-RubrikSLA.ps1' script reads a CSV file with a list of VMware VMs and SLAs and assigns a SLA to each VM.
Create a CSV file with the following column headers:

1) 'VM' - list of VMware VMs to change the SLA
2) 'New SLA' - new SLA to change the SLA to

The default CSV filename is 'vm_sla_list.csv' and can be changed by modifying $csvInput.


.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 6/3/21

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM and VARIABLES section with config details for this script.

.EXAMPLE
./Change-RubrikSLA.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication

.EXAMPLE
./Change-RubrikSLA.ps1 -server <Rubrik_server>
Checks for credential file and if none found prompts for username/password

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
  [string]$rubrikCred = 'rubrik_cred.xml'
)

Import-Module Rubrik

###### VARIABLES - BEGIN ######

$date = Get-Date

# CSV input file
$csvInput = "vm_sla_list.csv"

# CSV file info
# $csvOutput = "./<name>-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

###### VARIABLES - END #######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if (!$server) { $server = Read-Host "Rubrik hostname or IP" }
  if ($token) { Connect-Rubrik -Server $server -Token $token }
  else {
    if ($user) {
      if ($password) {
        $password = ConvertTo-SecureString $password -AsPlainText -Force
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

$vmlist = Import-Csv -Path $csvInput

foreach ($i in $vmList)
{
  Write-Host "Assigning VM: $($i.VM) to SLA: $($i.'New SLA')" -foregroundcolor Green
  try
  {
    $sla = Get-RubrikSLA -PrimaryClusterID local -Name $i.'New SLA'
    Get-RubrikVM $i.VM | Protect-RubrikVM -slaid $sla.id -Confirm:$False
  } catch {
    Write-Error "Error assigning VM: $($i.VM) to SLA: $($i.'New SLA')"
  }
}


# Export some list to a CSV file
# $list | Export-Csv -NoTypeInformation -Path $csvOutput
# Write-Host "`nResults output to: $csvOutput"
