#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Reads a .CSV file and updates the credentails the NAS shares.

.DESCRIPTION
The Update-RubrikNASShares script reads in a .CSV file containing a list of NAS shares updates them with new credentials.
Shares will fail to be updated if Rubrik cannot mount the share using the new credentials.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/13/20
Updated: 1/3/21

Create a CSV file with the following columns:

** Mandatory columns: hostname, exportPoint, domain, username, password
- hostname - NAS Host that contains the share
- exportPoint - The share name
- shareType - 'SMB' or 'NFS'
- domain - Domain for the username
- username - Username to be set for the share. If blank, the share will be skipped. Set to 'delete' to remove the share-level credentials
- password - If no password is provided for the user the script will prompt for a password

See 'rubriknasshares.csv' as an example

For authentication, use an API token (recommended), username/password, or credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./Set-RubrikNASSharePW.ps1
This will prompt for all input arguments

.EXAMPLE
./Set-RubrikNASSharePW.ps1 -server <rubrik_host> -api <token> -csvInput <csv_filename>
Use an API token for authentication.
Reads in the CSV file and updates the credential of each share.

.EXAMPLE
./Set-RubrikNASSharePW.ps1 -server <rubrik_host> -csvInput <csv_filename>
Checks for credential file and if none found prompts for username/password.
Reads in the CSV file and updates the credential of each share.

.EXAMPLE
./Set-RubrikNASSharePW.ps1 -server <rubrik_host> -username <user> -password <password> -csvInput <csv_filename>
Use the provided username/password for authentication.
Reads in the CSV file and updates the credential of each share.

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
  [string]$csvInput
)

Import-Module Rubrik

$date = Get-Date
$csvOutput = "./rubrik_shares_pw_updated-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
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
  Write-Error "Error connecting to cluster or with authentication."
  Exit
}
###### RUBRIK AUTHENTICATION - END ######

Write-Host ""

# List to keep track of which shares were added successfully or not
$updateList = @()

# Get info from Rubrik cluster
$rubrikLocalId = Get-RubrikClusterInfo | Select-Object -ExpandProperty Id
$rubrikShares = Get-RubrikNASShare -PrimaryClusterID $rubrikLocalId

# Import CSV file which contains shares to add
$shareList = Import-Csv $csvInput

# Build list of unique domain\users
$shareCredList = $shareList | Sort-Object -Property 'domain', 'username' -Unique |
Select-Object 'domain', 'username', 'password'

# List of credentials to use
$credList = @()

# Loop through unique domain\users to prompt for password or encrypt the password in the CSV into a list
foreach ($i in $shareCredList) {
  # If no password is in CSV, prompt password and store into $credList
  # If username is 'delete' skip as that will be handled separately
  if (![string]::IsNullOrEmpty($i.username) -and [string]::IsNullOrEmpty($i.password) -and $i.username -notlike 'delete') {
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
  elseif (![string]::IsNullOrEmpty($i.username) -and $i.username -notlike 'delete') {
    $credList += [PSCustomObject] @{
      domain = $i.domain
      username = $i.username
      password = ConvertTo-SecureString $i.password -AsPlainText -Force
    }
  }
}

# Iterate through share list
foreach ($i in $shareList)
{
  # Keep track of if updating the current share was successful or not
  $status = ''

  # Get shareID
  $shareID = $rubrikShares | Where-Object {$_.hostname -eq $i.hostname -and $_.exportPoint -eq $i.exportPoint -and $_.shareType -eq $i.ShareType} | Select-Object -ExpandProperty 'id'

  # If the share exists update it with new credentials
  if ($shareID -ne $null)
  {
    $req = $null
    try
    {
      # If the new usernaame is 'delete' then create a blank $body to update the share
      if ($i.username -eq 'delete')
      {
        $body = [PSCustomObject] @{
          username = ""
          password = ""
        }

        Invoke-RubrikRESTCall -Method PATCH -Api 'internal' -Body $body -Endpoint "host/share/$($shareID)"

        Write-Host "Updated share with new credential: '$($i.exportPoint)' on host: '$($i.hostname)'" -ForegroundColor Green

        $status = 'Updated'
      }
      # Else if username is not blank then update it with the credentials from $credList
      elseif (![string]::IsNullOrEmpty($i.username))
      {
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
        $req = Set-RubrikNASShare -Id $shareID -Credential $shareCred

        Write-Host "Updated share with new credential: '$($i.exportPoint)' on host: '$($i.hostname)'" -ForegroundColor Green
        $status = 'Updated'
      }
      # Else username was blank so skip updating this share
      else {
        $status = 'Skipped'
      }
    }
    catch
    {
      Write-Warning "Error updating share: '$($i.exportPoint)' on host: '$($i.hostname)'"
      Write-Warning $Error[0]
      $status = 'NotUpdated'
    }
  }
  else
  {
    Write-Warning "Share not found: '$($i.exportPoint)' on host: '$($i.hostname)'"
    $status = 'NotFound'
  }

  $updateList += [PSCustomObject] @{
    status = $status
    hostname = $i.hostname
    exportPoint = $i.exportPoint
    shareType = $i.shareType
    domain = $i.domain
    username = $i.username
    password = $i.password
  }

} # foreach in $shareList

Write-Host ""
Write-Host "# shares updated: " $($updateList | Where-Object Status -eq "Updated" | Measure-Object | Select-Object -ExpandProperty Count)
Write-Host "# shares not updated: " $($updateList | Where-Object Status -eq "NotUpdated" | Measure-Object | Select-Object -ExpandProperty Count)
Write-Host "# shares not found: " $($updateList | Where-Object Status -eq "NotFound" | Measure-Object | Select-Object -ExpandProperty Count)
Write-Host "# shares skipped: " $($updateList | Where-Object Status -eq "Skipped" | Measure-Object | Select-Object -ExpandProperty Count)

$updateList | Export-Csv -NoTypeInformation -Path $csvOutput

Write-Host "`nResults output to: $csvOutput"

$disconnect = Disconnect-Rubrik -Confirm:$false
