#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Reads a .CSV file and assigns a fileset and SLA to a NAS share.

.DESCRIPTION
The Set-RubrikNASShareSLA script reads a .CSV file containing a list of NAS shares, filesets, and SLAs.
The script assumes a fileset template for the appropriate share type (SMB or NFS) is already configured on the cluster.
The script adds a fileset template to the NAS share if it has not been added yet.
If the share fileset already exists it will just attempt to update the SLA.
It may take a minute or two to add the share fileset and assign the SLA for each share.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/13/20
Updated: 1/2/21

Create a CSV file with the following columns:

** Mandatory columns: hostname, exportPoint, shareType
- hostname - NAS Host that contains the share
- exportPoint - The share name
- shareType - 'SMB' or 'NFS'
- fileset - Fileset template to add for the share
- sla - SLA to update the share fileset with

See 'rubriknasshares.csv' as an example

For authentication, use an API token (recommended), username/password, or credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./Set-RubrikNASShareSLA.ps1
This will prompt for all input arguments

.EXAMPLE
./Set-RubrikNASShareSLA.ps1 -server <rubrik_host> -api <token> -csvInput <csv_filename>
Use an API token for authentication.
Reads in the CSV file and assigns a fileset and SLA to a NAS share.

.EXAMPLE
./Set-RubrikNASShareSLA.ps1 -server <rubrik_host> -csvInput <csv_filename>
Checks for credential file and if none found prompts for username/password.
Reads in the CSV file and assigns a fileset and SLA to a NAS share.

.EXAMPLE
./Set-RubrikNASShareSLA.ps1 -server <rubrik_host> -username <user> -password <password> -csvInput <csv_filename>
Use the provided username/password for authentication.
Reads in the CSV file and assigns a fileset and SLA to a NAS share.

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

  # CSV File containing the following: hostname, exportPoint, shareType, sla, fileset
  [Parameter(Mandatory=$true)]
  [string]$csvInput
)

Import-Module Rubrik

$apiVer = '1'

$date = Get-Date
$csvOutput = "./rubrik_shares_sla_updated-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

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

# List to keep track of which shares were updated successfully or not
$updateList = @()

# Get info from Rubrik cluster and filter by local cluster ID
$rubrikLocalId = Get-RubrikClusterInfo | Select-Object -ExpandProperty Id
# $rubrikHosts = Get-RubrikHost -PrimaryClusterID $rubrikLocalId | Where -Property operatingSystem -eq $null
$rubrikShares = Get-RubrikNASShare -PrimaryClusterID $rubrikLocalId
$rubrikFilesetTemplates = Get-RubrikFilesetTemplate -PrimaryClusterID $rubrikLocalId
$rubrikFilesets = Get-RubrikFileset -PrimaryClusterID $rubrikLocalId
$rubrikSLAs = Get-RubrikSLA -PrimaryClusterID $rubrikLocalId

# Import CSV file which contains shares to update
$shareList = Import-Csv $csvInput

# Iterate through share list
foreach ($i in $shareList)
{
  # Keep track of if updating the current share was successful or not
  $status = ''

  # Check if the share, sla, and fileset exists on current Rubrik cluster
  $share = $rubrikShares | Where-Object { $_.hostname -eq $i.hostname -and $_.exportPoint -eq $i.exportPoint }
  $sla = $rubrikSLAs | Where-Object "Name" -eq $i.sla
  $fileset = $rubrikFilesetTemplates | Where-Object { $_.name -eq $i.fileset -and $_.shareType -eq $i.ShareType }

  # If the share, sla, or fileset does not exist, then ERROR
  if ($share -eq $null)
  {
    Write-Warning "Error updating share: '$($i.exportPoint)' on host: '$($i.hostname)' - Share not found"
    $status = 'ErrorShareNotFound'
  }
  elseif ($sla -eq $null)
  {
    Write-Warning "Error updating share: '$($i.exportPoint)' on host: '$($i.hostname)' - SLA not found: '$($i.sla)'"
    $status = 'ErrorSlaNotFound'
  }
  elseif ($fileset -eq $null)
  {
    Write-Warning "Error updating share: '$($i.exportPoint)' on host: '$($i.hostname) - Fileset not found: '$($i.fileset)'"
    $status = 'ErrorFilesetNotFound'
  }
  # Else if all share, sla, and fileset exist, try updating the share
  else
  {
    $hostFileset = $rubrikFilesets | Where-Object { $_.hostname -eq $i.hostname -and $_.name -eq $i.fileset}

    # If the share doesn't have a fileset then add a fileset template to the share
    if ($hostFileset -eq $null)
    {
      try {
        Write-Host "For share: '$($i.exportPoint)' on host: '$($i.hostname) - Trying to add fileset: '$($i.fileset)'"
        $hostFileset = New-RubrikFileset -templateID $fileset.id -shareID $share.id

        Write-Host "For share: '$($i.exportPoint)' on host: '$($i.hostname) - Added fileset: '$($i.fileset)'" -ForegroundColor Green
        $status = 'AddedFileset'
      }
      catch {
        Write-Warning "For share: '$($i.exportPoint)' on host: '$($i.hostname) - Error adding fileset: '$($i.fileset)'"
      }
    } # If no share fileset then add to the share

    # Try updating the SLA to the share
    try {
      $bodyJson = [PSCustomObject] @{
        configuredSlaDomainId = $sla.id
      }

      Write-Host "For share: '$($i.exportPoint)' on host: '$($i.hostname) - Trying to update SLA '$($i.sla)' for fileset: '$($i.fileset)'"
      $reqProtect = Invoke-RubrikRESTCall -Method "Patch" -Api $apiVer -Body $bodyJson -Endpoint "fileset/$($hostFileset.id)"

      Write-Host "For share: '$($i.exportPoint)' on host: '$($i.hostname) - Updated SLA '$($i.sla)' for fileset: '$($i.fileset)'" -ForegroundColor Green
      $status = $status + 'UpdatedSLA'
    }
    catch {
      if ($reqProtect.configuredSlaDomainName -eq $i.sla)
      {
        Write-Host "For share: '$($i.exportPoint)' on host: '$($i.hostname) - Updated SLA '$($i.sla)' for fileset: '$($i.fileset)'" -ForegroundColor Green
        $status = $status + 'UpdatedSLA'
      }
      else
      {
        Write-Warning "For share: '$($i.exportPoint)' on host: '$($i.hostname) - Error updating SLA '$($i.sla)' for fileset: '$($i.fileset)'"
        $status = $status + 'ErrorUpdatingSLA'
      }
    }
  } # Else try to updating the share

  $updateList += [PSCustomObject] @{
    status = $status
    hostname = $i.hostname
    exportPoint = $i.exportPoint
    shareType = $i.shareType
    sla = $i.sla
    fileset = $i.fileset
  }
} # Foreach in $shareList

Write-Host ""
Write-Host "# shares ErrorShareNotFound: " $(($updateList | Where-Object Status -eq "ErrorShareNotFound" | Measure-Object | Select-Object -ExpandProperty Count))
Write-Host "# shares ErrorSlaNotFound: " $(($updateList | Where-Object Status -eq "ErrorSlaNotFound" | Measure-Object | Select-Object -ExpandProperty Count))
Write-Host "# shares ErrorFilesetNotFound: " $(($updateList | Where-Object Status -eq "ErrorFilesetNotFound" | Measure-Object | Select-Object -ExpandProperty Count))
Write-Host "# shares ErrorUpdatingSLA: " $(($updateList | Where-Object Status -eq "ErrorUpdatingSLA" | Measure-Object | Select-Object -ExpandProperty Count))
Write-Host "# shares AddedFilesetErrorUpdatingSLA: " $(($updateList | Where-Object Status -eq "AddedFilesetErrorUpdatingSLA" | Measure-Object | Select-Object -ExpandProperty Count))
Write-Host "# shares AddedFilesetUpdatedSLA: " $(($updateList | Where-Object Status -eq "AddedFilesetUpdatedSLA" | Measure-Object | Select-Object -ExpandProperty Count))
Write-Host "# shares UpdatedSLA: " $(($updateList | Where-Object Status -eq "UpdatedSLA" | Measure-Object | Select-Object -ExpandProperty Count))
Write-Host "Total # shares: " $(($updateList | Measure-Object | Select-Object -ExpandProperty Count))

$updateList | Export-Csv -NoTypeInformation -Path $csvOutput

Write-Host "`nResults output to: $csvOutput"

$disconnect = Disconnect-Rubrik -Confirm:$false
