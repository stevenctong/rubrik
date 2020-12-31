#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Reads a .CSV file and adds the NAS shares to the Rubrik cluster.
Assumes the NAS Host has already been added to the cluster.

.DESCRIPTION
The Add-RubrikNASShares script reads in a .CSV file containing a list of NAS shares and adds them to the Rubrik cluster.
This script assumes that the NAS Host has already been added to the Rubrik cluster.
You can use the same CSV file with the 'Set-RubrikNASShare' script to add a new fileset + SLA to the NAS shares.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/13/20

For authentication, use an API token (recommended), username/password, or credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

You must create a CSV file with the following columns:
- Mandatory columns: hostname, exportPoint, shareType
** hostname - NAS Host that contains the share
** exportPoint - sharename
** shareType - 'SMB' or 'NFS'

- Optional columns: domain, username, password
** If a username (and domain) is provided the script will set the credential at the share level
** If no password is provided for the username (and domain) the script will prompt for a password

See 'rubriknasshares.csv' as an example

Fill out the PARAM section with config details for this script.

.EXAMPLE
Add-RubrikNASShares.ps1
This will prompt for all input arguments

.EXAMPLE
Add-RubrikNASShares.ps1 -server <rubrik_host> -csvfile <csv_filename>
Reads in CSV file and adds each share to the associated NAS Host

.EXAMPLE
Add-RubrikNASShares.ps1 -server <rubrik_host> -username <user> -password <password> -csvfile <csv_filename>
Reads in CSV file and adds each share to the associated NAS Host

.EXAMPLE
Add-RubrikNASShares.ps1 -server <rubrik_host> -api <token> -csvfile <csv_filename>
Reads in CSV file and adds each share to the associated NAS Host

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

  # CSV File containing the following: hostname, exportPoint, shareType; optional: domain, username, password
  [Parameter(Mandatory=$true)]
  [string]$csvfile
)

$curDateTime = Get-Date -Format "yyyy-MM-dd_HHmm"
$csvFile = "./shares_added-$curDateTime.csv"

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

Write-Host ""

# List to keep track of which shares were added successfully or not
$addList = @()

# Get info from Rubrik cluster
$rubrikLocalId = Get-RubrikClusterInfo | Select-Object -ExpandProperty Id
$rubrikHosts = Get-RubrikHost -PrimaryClusterID $rubrikLocalId
$rubrikShares = Get-RubrikNASShare -PrimaryClusterID $rubrikLocalId

# Import CSV file which contains shares to add
$shareList = Import-Csv $csvfile

# Build list of unique domain\users
$shareCredList = $shareList | Sort-Object -Property 'domain', 'username' -Unique |
Select-Object 'domain', 'username', 'password'

# List of credentials to use
$credList = @()

# Loop through unique domain\users to prompt for password or encrypt password to use later
foreach ($i in $shareCredList) {
  # If no password is in CSV, prompt password and store into $credList
  if (![string]::IsNullOrEmpty($i.username) -and [string]::IsNullOrEmpty($i.password)) {
    Write-Host "Please supply password for domain: '$($i.domain)', user: '$($i.username)'"
    # Join domain\user if domain is specified
    if ([string]::IsNullOrEmpty($i.domain)) {
      $cred = Get-Credential -Username $i.username
    }
    else {
      $cred = Get-Credential -Username "$($i.domain)\$($i.username)"
    }

    $credList += [PSCustomObject] @{
      domain = $i.domain
      username = $i.username
      password = $cred.password
    }
  }
  # If password is provided in CSV encrypt it and store into $credList
  elseif (![string]::IsNullOrEmpty($i.username)) {
    $credList += [PSCustomObject] @{
      domain = $i.domain
      username = $i.username
      password = ConvertTo-SecureString $i.password -AsPlainText -Force
    }
  }
}

# Iterate through share list
foreach ($i in $shareList) {

  # Get the Host ID of associated share
  $hostID = $rubrikHosts | Where-Object "Name" -eq $i.hostname | Select-Object -ExpandProperty "ID"

  # Skip if NAS Host does not exist - script assumes Host pre-exists
  if ($hostID -eq $null) {
    Write-Warning "Error adding share: '$($i.exportPoint)' - host not found: '$($i.hostname)'"

    $addList += [PSCustomObject] @{
      status = 'NotAdded'
      hostname = $i.hostname
      exportPoint = $i.exportPoint
      shareType = $i.shareType
    }
  }
  # If NAS Host exists - continue
  else {
    # See if share already exists on cluster
    $shareID = $rubrikShares | Where-Object {$_.hostname -eq $i.hostname -and $_.exportPoint -eq $i.exportPoint -and $_.shareType -eq $i.ShareType} | Select-Object -ExpandProperty 'id'

    # If share doesn't exist, try adding the share to the cluster
    if ($shareID -eq $null) {

      $req = $null
      try {
        # If a username and password is specified for the share then use it
        if (![string]::IsNullOrEmpty($i.username)) {
          if ([string]::IsNullOrEmpty($i.domain)) {
            $shareUser = $i.username
          }
          else {
            $shareUser = $i.domain + '\' + $i.username
          }

          # New-RubrikNASShare uses credential as $PSCredential
          # Looks up the domain\user and password to use in $credList to use
          $userCred = $credList | Where-Object {$_.domain -eq $i.domain -and $_.username -eq $i.username}
          $shareCred = New-Object System.Management.Automation.PSCredential($shareUser, $userCred.password)

          # Add NAS share to Rubrik with share credential
          $req = New-RubrikNASShare -HostID $hostID -ShareType $i.shareType -ExportPoint $i.exportPoint -Credential $shareCred
        }
        else {
          # Add NAS share without share credential
          $req = New-RubrikNASShare -HostID $hostID -ShareType $i.shareType -ExportPoint $i.exportPoint
        }
        Write-Host "Added share: '$($i.exportPoint)' on host: '$($i.hostname)'" -ForegroundColor Green

        $addList += [PSCustomObject] @{
          status = 'Added'
          hostname = $i.hostname
          exportPoint = $i.exportPoint
          shareType = $i.shareType
        }
      }
      catch {
        Write-Warning "Error adding share: '$($i.exportPoint)' on host: '$($i.hostname)'"
        Write-Warning $Error[0]

        $addList = [PSCustomObject] @{
          status = 'NotAdded'
          hostname = $i.hostname
          exportPoint = $i.exportPoint
          shareType = $i.shareType
        }
      }
    }
    # If share exists, skip adding share
    else {
      Write-Warning "Skipping adding share: '$($i.exportPoint)' on host: '$($i.hostname)' - share already exists"

      $addList += [PSCustomObject] @{
        status = 'PreExisting'
        hostname = $i.hostname
        exportPoint = $i.exportPoint
        shareType = $i.shareType
      }
    }
  } # else to try adding share
} # foreach

Write-Host ""
Write-Host "# shares added: " $($addList | Where-Object Status -eq "Added" | Measure-Object | Select-Object -ExpandProperty Count)
Write-Host "# shares not added: " $($addList | Where-Object Status -eq "NotAdded" | Measure-Object | Select-Object -ExpandProperty Count)
Write-Host "# shares pre-existing: " $($addList | Where-Object Status -eq "PreExisting" | Measure-Object | Select-Object -ExpandProperty Count)

$curDateTime = Get-Date -Format "yyyy-MM-dd_HHmm"
$addList | Export-Csv -NoTypeInformation -Path $csvFile

Write-Host "`nResults output to: $csvFile"

$disconnect = Disconnect-Rubrik -Confirm:$false
