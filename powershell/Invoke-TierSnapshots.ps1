#requires -modules Rubrik
<#
.SYNOPSIS
This script gets all objects under Snapshot Management and initiates tiering
the snapshots from the specified archive location ID.

.DESCRIPTION
This script gets all objects under Snapshot Management and initiates tiering
the snapshots from the specified archive location ID.

Please specify the archive location ID in this script.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/20/24

Fill out the PARAM and VARIABLES section with config details for this script.

.EXAMPLE
./Invoke-TierSnapshots.ps1

#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$false)]
  [string]$server = '',

  # Use API token for authentication
  [Parameter(Mandatory=$false)]
  [string]$token = ''
)

Import-Module Rubrik

###### VARIABLES - BEGIN ######

# Archive location ID to tier snapshots for
$archiveLocationID = '449a285d-9b6c-487f-9767-3bdbd9d430a3'

# Depending on cluster version, set to either '1' or 'internal'
# Use '1' for later cluster versions (v5.1+)
$apiVer = '1'

# CSV file info
$date = Get-Date
$csvFile = "./rubrk_tier_object_list-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

###### VARIABLES - END ######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if (!$server) { $server = Read-Host "Rubrik hostname or IP" }
  if ($token) { Connect-Rubrik -Server $server -Token $token } else {
    Write-Error "No token supplied."
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


# Get all objects under Snapshot Management (On Demands, Relics, Unmanaged Objects)
try {
  $query = '{"query":"query UnmanagedObjectV1{unmanagedObjectV1Connection{nodes{id name objectType physicalLocation{name}unmanagedStatus isRemote snapshotCount localStorage archiveStorage retentionSlaDomainName}}}"}'
  $allSnapshotManagement = (Invoke-RubrikGraphQLCall -Body $query).unmanagedObjectV1Connection.nodes
} catch {
  $allSnapshotManagement = Get-RubrikUnmanagedObject
}

$allCount = $allSnapshotManagement.count
$count = 1
$csvArray = @()

foreach ($obj in $allSnapshotManagement) {
  Write-Host "[$count / $allCount] Tiering $($obj.name)"
  $count++
  $bodyJson = [PSCustomObject] @{
    "objectIds" = @(
      $obj.id
    )
    "locationId" = $archiveLocationID
  }
  try {
    $objCSV = [PSCustomObject] @{
      "Name" = $obj.name
      "ID" = $obj.id
      "Status" = $req.id
      "Time" = $req.startTime
      "Type" = $obj.objectType
      "SnapshotCount" = $obj.snapshotCount
    }
    $req = Invoke-RubrikRESTCall -Method 'POST' -Api '1' -Body $bodyJson -Endpoint "unmanaged_object/snapshot/bulk_archive_tier"
  } catch {
    $objCSV = [PSCustomObject] @{
      "Name" = $obj.name
      "ID" = $obj.id
      "Status" = ""
      "Time" = ""
      "Type" = $obj.objectType
      "SnapshotCount" = $obj.snapshotCount
    }
  }
  $csvArray += $objCSV
}

$csvArray | Export-CSV -NoTypeInformation -path $csvFile
Write-Host "CSV output to: $csvOutput"

$disconnect = Disconnect-Rubrik -Confirm:$false
