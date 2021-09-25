#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Create multiple Exports for a specified VM.

.DESCRIPTION
The Invoke-ExportVM.ps1 script creates multiple Exports for a specified VM.
Specify the VM name, count, datastore, and ESXi host to recover to with variables.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 9/24/21

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./Invoke-ExportVM.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication.

.EXAMPLE
./Invoke-ExportVM.ps1 -server <Rubrik_server>
Checks for credential file and if none found prompts for username/password.

.EXAMPLE
./Invoke-ExportVM.ps1 -server <Rubrik_server> -vmname 'vmstats' -exportcount 3 -recoveryDate '09/21/2021 12:00' -datastore 'nfsds1'
Checks for credential file and if none found prompts for username/password.
Creates 3 exports of VM 'vmstats' using the snapshot closest to 9/21/21 12:00 onto datastore 'nfsds1'.

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

  # VM name to Live Mount
  [Parameter(Mandatory=$false)]
  [string]$vmName = '',

  # The number of exports to restore
  [Parameter(Mandatory=$false)]
  [int32]$exportCount = 1,

  # UTC time for the nearest snapshot to export, use 'MM/DD/YYYY HH:MM' format
  [Parameter(Mandatory=$false)]
  [string]$recoveryDate = '09/21/2021 12:00',

  # Datastore name that you want to export the VM to
  [Parameter(Mandatory=$false)]
  [string]$datastore = '',

  # ESXi host to restore the exported VM on
  [Parameter(Mandatory=$false)]
  [string]$esxiHost = ''
)

Import-Module Rubrik


###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if ($token) { Connect-Rubrik -Server $server -Token $token }
  else {
    if ($user) {
      if ($password) {
        [SecureString]$password = ConvertTo-SecureString $password -AsPlainText -Force
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


$count = 0

while ($count -lt $exportCount)
{

  Get-RubrikVM $vmName | Get-RubrikSnapshot -Date $recoveryDate |
    Export-RubrikVM -HostId (Get-RubrikVMwareHost -name $esxiHost -PrimaryClusterID local).id -DatastoreId (Get-RubrikVMwareDatastore -name $datastore).id

  $count += 1
}
