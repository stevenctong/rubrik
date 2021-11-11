#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
This script gathers metrics for one or more Rubrik clusters and appends the data to a JSON file.

.DESCRIPTION
This script gathers metrics for one or more Rubrik clusters and appends the data to a JSON file.
The log file can be picked up by Filebeat and shipped to an ELK stack.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 2/18/21
Updated: 10/20/21

The following variables can be modified in the script:
$outFile - file that the JSON file will be written to. Filebeat should monitor the file directory to ship to ELK
$rubrikClusters - array of Rubrik clusters to pull metrics for
$longJobThreshold - threshold for considering a job to be long running, in hours

For authentication, use one of the following methods and edit the script accordingly:
$rubrikTokens - array of API tokens to use for authentication, positions should match $rubrikClusters
$credential - credential file that can be created using: Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
$user and $password - plaintext username and password

Update the credentials in the authentication block and also update where the script performs the authentication.

It is recommended to create a read-only user on the Rubrik cluster for this script

.EXAMPLE
./Get-RubrikStats.ps1
Runs the script with the variables defined within to gather Rubrik data and ouptut it

#>

Import-Module Rubrik

$date = Get-Date
$dateUTC = $date.ToUniversalTime()

# Path and filename of the JSON file that will be appended. Filebeat should monitor the path to ship to ELK.
$outFile = "/var/log/rubrikelk/rubrik_stats_$($date.ToString("yyyy-MM-dd")).log"

# Threshold for considering a job to be long running, in hours
$longJobThreshold = 8

# Array of Rubrik clusters to gather metrics for
$rubrikClusters=@(
  '',
  ''
)

###### RUBRIK AUTHENTICATION - BEGIN ######

# Uncomment to use one of the following methods for authentication:

# An array of API tokens for authentication, array position should match $rubrikClusters
# $rubrikTokens=@(
#   '',
#   ''
# )

# Credential file for authentication (note: only the user who creates it can use it)
# Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
# $credential  = Import-Clixml -Path ./rubrik_cred.xml

# Plaintext username and password for authentication
# $user = ''
# $password = '' | ConvertTo-SecureString -AsPlainText -Force

###### RUBRIK AUTHENTICATION - END ######

# If using API token for authentication, check that the # of tokens defined matches the # of Rubrik clusters
if ($rubrikClusters.count -ne $rubrikTokens.count)
{
  Write-Error "Number of Rubrik clusters defined is not equal to number of API tokens provided, exiting script"
  exit
}

# Loop through all Rubrik clusters to gather data
for ($i = 0; $i -lt $rubrikClusters.count; $i++)
{
  Write-Host "Gathering stats for $($rubrikClusters[$i])" -foregroundcolor green

  try
  {
    # If using an API token for authentication, grab the corresponding token
    # Connect-Rubrik -server $rubrikClusters[$i] -token $rubrikTokens[$i]

    # If using a credential file:
    # Connect-Rubrik -Server $rubrikClusters[$i] -Credential $credential

    # If using a username and password:
    Connect-Rubrik -Server $rubrikClusters[$i] -Username $user -Password $password

    # Get general Rubrik cluster info, storage, and compliance numbers
    $clusterInfo = Get-RubrikClusterInfo
    $clusterStorage = Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "stats/system_storage"
    $clusterCompliance = Invoke-RubrikRESTCall -Method GET -Api '1' -Endpoint "report/compliance_summary_sla?snapshot_range=LastSnapshot"

    # If there are non-compliant objects then build a list of the objects
    if ($clusterCompliance.numberOfOutOfComplianceSnapshots -gt 0)
    {
      # Format JSON body to pull a list of objects that are non-compliant since their last snapshot
      $nonCompliantJSON = [PSCustomObject] @{
        dataSource = "FrequentDataSource"
        reportTableRequest = @{
          sortBy = "ObjectName"
          sortOrder = "asc"
          requestFilters = @{
            complianceStatus =  "NonCompliance"
          }
          limit = 250
        }
        snapshotRange = "LastSnapshot"
      }

      # Get a list of objects that are non-compliant since their last snapshot
      $objectsNonCompliant = Invoke-RubrikRESTCall -Method POST -Api 'internal' -Endpoint "report/data_source/table" -Body $nonCompliantJSON

      # The list of non-compliant objects is returned as separate arrays. Find the position corresponding to object name and location
      $namePosition = $objectsNonCompliant.columns.indexof('object_name')
      $locationPosition = $objectsNonCompliant.columns.indexof('location')

      # Build a string (list) of non-compliant objects by looping through the non-compliant objects that were returned
      $nonCompliantList = ""
      $nonCompliantCount = 1
      foreach ($obj in $objectsNonCompliant.dataGrid) {
        $nonCompliantObject = "[$nonCompliantCount]: $($obj[$namePosition]), $($obj[$locationPosition])  "
        $nonCompliantList += $nonCompliantObject
        $nonCompliantCount += 1
      }
    } else {
      # If there was no count of non-compliant objects then the non-compliant string (list) should be blank
      $nonCompliantList = ""
    }

    # Get a list of cluster nodes and their status
    $clusterNodes = Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "cluster/me/node"
    $goodNodes = 0
    $badNodes = 0

    # Loop through each node to check their status and count the status accordingly
    foreach ($node in $clusterNodes.data)
    {
      if ($node.status -eq 'OK')
      {
        $goodNodes += 1
      } else {
        $badNodes += 1
      }
    }

    # Get a list of currently Running Recovery events
    $events = Get-RubrikEvent -Status Running -EventType Recovery

    # Build a string (list) of recovery events
    $recoveryEventList = ""
    $eventCount = 1
    if ($events.count -gt 0)
    {
      foreach ($task in $events.data.latestEvent) {
        $eventDetails = Get-RubrikEventSeries -id $task.eventSeriesId
        $eventItem = "[$eventCount]: $($eventDetails.objectName), $($eventDetails.location), duration: $($eventDetails.duration), progress: $($eventDetails.progressPercentage)  "
        $recoveryEventList += $eventItem
        $eventCount += 1
      }
    }

    # Get a list of currently Running events sorted by oldest first
    $events = Invoke-RubrikRESTCall -Method GET -Api '1' -Endpoint "event/latest?limit=50&order_by_time=asc&event_status=Running"

    # Build a string (list) of long running events
    $longRunningEventList = ""
    $eventCount = 1
    if ($events.count -gt 0)
    {
      foreach ($task in $events.data.latestEvent) {
        # Calculate how long the event has been running for in hours
        $taskDuration = $dateUTC - [DateTime]$task.time
        $taskHours = ($taskDuration.days * 24) + ($taskDuration.hours)

        # If the event has been running for longer than $longJobThreshold, add it to the long running events list
        if ($taskHours -gt $longJobThreshold) {
          $eventDetails = Get-RubrikEventSeries -id $task.eventSeriesId
          $eventItem = "[$eventCount]: $($eventDetails.objectName), $($eventDetails.location), duration: $($eventDetails.duration), progress: $($eventDetails.progressPercentage)  "
          $longRunningEventList += $eventItem
          $eventCount += 1
        }
      }
    }
    # The actual count of long running events is $eventCount - 1 since $eventCount started at 1
    $longRunningEventCount = $eventCount - 1

    # Count the number of Live Mounts on the cluster by getting each individual Live Mount type count and adding it
    $liveMountCount = 0
    $liveMountCount += (Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "vmware/vm/snapshot/mount/count").count
    $liveMountCount += (Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "hyperv/vm/snapshot/mount").total
    $liveMountCount += (Invoke-RubrikRESTCall -Method GET -Api '1' -Endpoint "volume_group/snapshot/mount").total
    $liveMountCount += (Invoke-RubrikRESTCall -Method GET -Api '1' -Endpoint "mssql/db/mount").total
    $liveMountCount += (Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "oracle/db/mount").total
    $liveMountCount += (Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "managed_volume/snapshot/export").total

    # Create the object with all the data that will be appended to the output file
    # Typecast [DateTime] to maintain Powershell compatabilty
    $rubrikMetrics = [PSCustomObject] @{
      rubrikClusterName = $clusterInfo.name
      scriptRunTime = $($date.ToString("yyyy-MM-ddTHH:mm:ssZ"))
      lastUpdateTime =  $([DateTime]($clusterStorage.lastUpdateTime)).ToString("yyyy-MM-ddTHH:mm:ssZ")

      rubrikSpaceTotal = $clusterStorage.total
      rubrikSpaceUsed = $clusterStorage.used
      rubrikSpaceAvailable = $clusterStorage.available
      rubrikSpaceSnapshot = $clusterStorage.snapshot
      rubrikSpaceLiveMount = $clusterStorage.liveMount
      rubrikSpacePendingSnapshot = $clusterStorage.pendingSnapshot
      rubrikSpaceCDP = $clusterStorage.cdp
      rubrikSpaceMisc = $clusterStorage.miscellaneous
      rubrikUsedPct = $($clusterStorage.used / $clusterStorage.total * 100)

      rubrikTotalProtected = $clusterCompliance.totalProtected
      rubrikInCompliance = $clusterCompliance.numberOfInComplianceSnapshots
      rubrikOutCompliance = $clusterCompliance.numberOfOutOfComplianceSnapshots
      rubrikPctInCompliance = $clusterCompliance.percentOfInComplianceSnapshots
      rubrikPctOutCompliance = $clusterCompliance.percentOfOutOfComplianceSnapshots
      rubrikComplianceTime =  $([DateTime]($clusterCompliance.updatedTime)).ToString("yyyy-MM-ddTHH:mm:ssZ")

      rubrikNodesGood = $goodNodes
      rubrikNodesBad = $badNodes
      rubrikNodesTotal = $clusterNodes.total

      rubrikRecoveryEventCount = $runningRecoveryEvents.count
      rubrikLongRunningEventCount = $longRunningEventCount
      rubrikLiveMountCount = $liveMountCount

      rubrikRecoveryEvents = $recoveryEventList
      rubrikLongRunningEvents = $longRunningEventList
      rubrikNonCompliantObjects = $nonCompliantList
    }

    # Use -Compress to remove whitespace in the JSON and append the data as a single line to the file
    $rubrikMetrics | ConvertTo-Json -Compress | Out-File -append $outFile
    Write-Host "Appending data to: $outFile"
  } catch {
    Write-Error "Error gathering data for $($rubrikClusters[$i])"
    $_
  }
}
