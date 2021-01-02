#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Gets a list of on demand snapshots from the cluster, filterable by last # of hours/days

.DESCRIPTION
The Get-RubrikOnDemandSnapshots script gets a list of on demand snapshots from the cluster.
The list can be filtered by the last # of days OR hours by setting the $days OR $hours variables.
If $days is set, then $hours will not be used.
If $days and $hours are both set to '-1' then it will pull a list of ALL on demand snapshots.
The list is output to a CSV file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 9/29/20

For authentication, use an API token (recommended), username/password, or credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./Get-RubrikOnDemandSnapshots.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication and gets a list of all on demand snapshots

.EXAMPLE
./Get-RubrikOnDemandSnapshots.ps1 -server <Rubrik_server> -days 3
Checks for credential file and if none found prompts for username/password.
Gets a list of on demand snapshots taken over the last 3 days.

.EXAMPLE
./Get-RubrikOnDemandSnapshots.ps1 -server <Rubrik_server> -hours 12
Checks for credential file and if none found prompts for username/password.
Gets a list of on demand snapshots taken over the last 12 hours.

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

  # Get snapshots from last $days days
  [Parameter(Mandatory=$false)]
  [int]$days = -1,

  # Get snapshots from last $hours hours. If $days is defined, $hours will not be used
  [Parameter(Mandatory=$false)]
  [int]$hours = -1
)

$curDateTime = Get-Date -Format "yyyy-MM-dd_HHmm"
$csvFile = "./on_demand_snapshot_list-$curDateTime-$server.csv"

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

# Calculate $time the number of hours/days back to generate the list from
$time = (Get-Date).ToUniversalTime()

if ($days -gt 0)
{
  $time = $time.addDays(-$days)
} elseif ($hours -gt 0)
{
  $time = $time.addHours(-$hours)
}

# Change $time to format we can pass to Rubrik API as a filter
$timeStr = $time.ToString("yyyy-MM-ddThh:mm:ss")

# Get all objects under Snapshot Management area (On Demands, Relics, Unmanaged Objects)
$allSnapshotManagement = Get-RubrikUnmanagedObject

# Holds list of On Demand Snapshots
$snapshotList = @()

# Loop through each object and get list of On Demand Snapshots for that object
foreach ($i in $allSnapshotManagement)
{
  # If $days and $hours is set to -1 then get a list of all on demand snapshots
  if ($days -lt 0 -and $hours -lt 0)
  {
    $result = Invoke-RubrikRESTCall -Method "Get" -Api internal -Endpoint "unmanaged_object/$($i.id)/snapshot?snapshot_type=OnDemand"
  } else  # Else, get a list filtered by the last # of hours/days specified
  {
    $result = Invoke-RubrikRESTCall -Method "Get" -Api internal -Endpoint "unmanaged_object/$($i.id)/snapshot?snapshot_type=OnDemand&after_date=$timeStr"
  }

  $result.data
  Write-Host "Number of On Demand Snapshots found: $($result.data.count) for $($i.name), $($i.physicalLocation[0].name)" -ForegroundColor Green

  # $result.data holds a list of on demand snapshots for the object; loop through it and build an array with the relevant details
  foreach ($j in $result.data)
  {
    $snapshot = New-Object PSObject
    $snapshot | Add-Member -MemberType NoteProperty -Name "name" -Value $i.name
    $snapshot | Add-Member -MemberType NoteProperty -Name "location" -Value $i.physicalLocation[0].name
    $snapshot | Add-Member -MemberType NoteProperty -Name "objectType" -Value $i.objectType
    $snapshot | Add-Member -MemberType NoteProperty -Name "snapshotDateUTC" -Value $j.date
    $snapshot | Add-Member -MemberType NoteProperty -Name "snapshotType" -Value $j.snapshotType
    $snapshot | Add-Member -MemberType NoteProperty -Name "snapshotID" -Value $j.id
    $snapshot | Add-Member -MemberType NoteProperty -Name "objectID" -Value $i.id

    $snapshotList += $snapshot
  }
}

# Sort list and output as CSV
$snapshotList = $snapshotList | Sort-Object "location", "name"
$snapshotList | Export-Csv -NoTypeInformation -Path $csvFile

Write-Host "`nResults output to: $csvFile"

Disconnect-Rubrik -Confirm:$false
