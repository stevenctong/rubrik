#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
This script gathers metrics for one or more Rubrik clusters and appends the data to a json log file.

.DESCRIPTION
This script gathers metrics for one or more Rubrik clusters and appends the data to a json log file.
The log file can be picked up by Filebeat and shipped to an ELK stack.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 2/18/21

$logpath - path that Filebeat will monitor to ship the log file to ELK stack
$rubrikClusters - array of Rubrik clusters to pull metrics for
$rubrikTokens - array of API tokens to use for authentication

Alternatively, you can use a credential file or username and password for authentication by modifying the script

It is recommended to create a read-only user on the Rubrik cluster for this script

.EXAMPLE
./get_rubrik_stats.ps1
Runs the script with the variables defined within

#>

Import-Module Rubrik

# Path where the json metrics will be written to
$logpath = '/var/log/rubrikelk'

# Array of Rubrik clusters to gather metrics for
$rubrikClusters=@(
  '',
  ''
)

###### RUBRIK AUTHENTICATION - BEGIN ######

# Array of API tokens if using for authentication
$rubrikTokens=@(
  '',
  ''
)

# To create and use a credential file (note: only the user who creates it can use it):
# Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
# $credential  = Import-Clixml -Path ./rubrik_cred.xml

# To use a username and password for authentication
# $user = ''
# $password = '' | ConvertTo-SecureString -AsPlainText -Force

###### RUBRIK AUTHENTICATION - END ######

$date = Get-Date

# If using API token for authentication, check that the # of tokens defined matches the # of Rubrik clusters
if ($rubrikClusters.count -ne $rubrikTokens.count)
{
  Write-Error "Number of Rubrik clusters defined is not equal to number of API tokens provided, exiting script"
  exit
}

# Loop through all Rubrik clusters to gather metrics
for ($i = 0; $i -lt $rubrikClusters.count; $i++)
{
  Write-Host "Gathering stats for $($rubrikClusters[$i])" -foregroundcolor green

  # If using an API token for authentication, grab the corresponding one
  try
  {
    Connect-Rubrik -server $rubrikClusters[$i] -token $rubrikTokens[$i]

    # If using a credential file:
    # Connect-Rubrik -Server $rubrikClusters[$i] -Credential $credential

    # If using a username and password:
    # Connect-Rubrik -Server $rubrikClusters[$i] -Username $user -Password $password

    $clusterInfo = Get-RubrikClusterInfo
    $clusterStorage = Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "stats/system_storage"
    $clusterCompliance = Invoke-RubrikRESTCall -Method GET -Api '1' -Endpoint "report/compliance_summary_sla?snapshot_range=LastSnapshot"

    $clusterNodes = Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "cluster/me/node"
    $goodNodes = 0
    $badNodes = 0
    $totalNodes =0

    foreach ($j in $clusterNodes.data)
    {
      $totalNodes += 1

      if ($j.status -eq 'OK')
      {
        $goodNodes += 1
      } else {
        $badNodes += 1
      }
    }

    $rubrikMetrics = [PSCustomObject] @{
      rubrikClusterName = $clusterInfo.name
      scriptRunTime = $($date.ToString("yyyy-MM-ddTHH:mm:ssZ"))
      lastUpdateTime = $($clusterStorage.lastUpdateTime.ToString("yyyy-MM-ddTHH:mm:ssZ"))

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
      rubrikComplianceTime = $($clusterCompliance.updatedTime.ToString("yyyy-MM-ddTHH:mm:ssZ"))

      rubrikNodesGood = $goodNodes
      rubrikNodesBad = $badNodes
      rubrikNodesTotal = $totalNodes
    }

    # Use -Compress to remove whitespace in the JSON and output to a single line
    $rubrikMetrics | ConvertTo-Json -Compress | Out-File -append "$logpath\rubrik_stats_$($date.ToString("yyyy-MM-dd")).log"
  } catch {
    Write-Error "Error gathering metrics for $($rubrikClusters[$i])"
    $_
  }
}
