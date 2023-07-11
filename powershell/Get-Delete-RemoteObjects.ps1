<#
.SYNOPSIS
This script will get a list of all VM + Snapshots under "Remote SLAs" older than
the specified # of days and export it out to a CSV. You can then run the script
against the CSV to delete the snapshots.

.DESCRIPTION
This script will get a list of all VM + Snapshots under "Remote SLAs" older than
the specified # of days and export it out to a CSV. You can then run the script
against the CSV to delete the snapshots.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/10/23

For authentication, use a CDM Service Account assigned to a Custom Role.

Create .json file with the Rubrik cluster IP/hostname and service account ID & secret.
The .json should look like:

{
  "rubrikServer": "",
  "svcID": "User:::abc-def",
  "svcSecret": "abc"
}

Pass the .json filename with the $rubrikJson parameter.

Fill out the PARAMTERS and VARIABLES section as needed.

.EXAMPLE
./Get-Delete-RemoteObjects.ps1 -rubrikJson './cdm_svc_creds.json' -daysOld 15
Get a list of VMs + Snapshots that are replicas older than 15 days and write
it to a CSV file.

.EXAMPLE
./Get-Delete-RemoteObjects.ps1 -rubrikJson './cdm_svc_creds.json' -csvDelete './snapshots_to_delete.csv'
Delete the list of snapshots in the csv file.
#>

param (
  [CmdletBinding()]

  # Json file containing the Rubrik cluster info and service account details
  [Parameter(Mandatory=$false)]
  [string]$rubrikJson = '',

  # Get snapshots older than this number of days back
  [Parameter(Mandatory=$false)]
  [int]$daysOld,

  # CSV file with snapshots to delete
  [Parameter(Mandatory=$false)]
  [string]$csvDelete = ''
)

###### VARIABLES - BEGIN ######

# If Rubrik JSON is specified in parameters, use its information
if ($rubrikJson -ne '')
{
  # Get the Rubrik cluster and service account details from the .json file
  $rubrikSvc = Get-Content -Raw -Path $rubrikJson | ConvertFrom-Json
  $server = $rubrikSvc.rubrikServer
  $id = $rubrikSvc.svcID
  $secret = $rubrikSvc.svcSecret
} else {
  # Rubrik cluster IP, use a Floating IP for more resiliency
  $server = ''
  # Service Account ID and Secret
  $id = ''
  $secret = ''
}

$date = Get-Date
$csvFile = "./rubrik_snapshot_list-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

#Log directory
# $logDir = 'C:\Rubrik\log'

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Body<br><br>"

# Set to $true to send out email in the script
$sendEmail = $false

###### VARIABLES - END #######


###### RUBRIK AUTHENTICATION - BEGIN ######

$psVer = $PSVersionTable.psversion.major

if ([System.Net.ServicePointManager]::CertificatePolicy -notlike 'TrustAllCertsPolicy' -and $psVer -le 5) {
  # Added try catch block to resolve issue #613
  $ErrorActionPreference = 'Stop'
  try {
    Add-Type -TypeDefinition @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
      public bool CheckValidationResult(
          ServicePoint srvPoint, X509Certificate certificate,
          WebRequest request, int certificateProblem) {
          return true;
      }
    }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object -TypeName TrustAllCertsPolicy
  } catch {
    Write-Warning 'An error occured while attempting to allow self-signed certificates'
    Write-Debug ($Error[0] | ConvertTo-Json | Out-String)
  }
}
try {
  if ([Net.ServicePointManager]::SecurityProtocol -notlike '*Tls12*') {
    Write-Verbose -Message 'Adding TLS 1.2'
    [Net.ServicePointManager]::SecurityProtocol = ([Net.ServicePointManager]::SecurityProtocol).tostring() + ', Tls12'
  }
}
catch {
  Write-Verbose -Message $_
  Write-Verbose -Message $_.Exception.InnerException.Message
}

[System.Net.ServicePointManager]::SecurityProtocol =[System.Net.SecurityProtocolType]::Tls12

# Start logging
# $log = $logDir + "\rubrik-" + $date.ToString("yyyy-MM-dd") + "@" + $date.ToString("HHmmss") + ".log"
# Start-Transcript -Path $log -NoClobber

Connect-Rubrik -server $server -id $id -secret $secret

###### RUBRIK AUTHENTICATION - END ######

# If no CSV is provided to identify snapshots for deletion, generate a list based on the filters specified
if ($csvDelete -eq '')
{
  # Get Rubrik cluster info
  $clusterInfo = Invoke-RubrikRESTCall -Method 'GET' -Api '1' -Endpoint 'cluster/me'

  # Get a list of all SLAs on the cluster and then filter by remote SLAs
  $slas = Get-RubrikSLA
  $remoteSLAs = $slas | Where { $_.replicationSpecs.locationId -eq $($clusterInfo.id) }

  # Loop through each remote SLA and get a list of objects that are remote
  foreach ($remoteSLA in $remoteSLAs) {
    $remoteSLA.primaryClusterId
    $remoteVMs = Get-RubrikVM -PrimaryClusterID $remoteSLA.primaryClusterId -DetailedObject
  }

  # Holds the list of snapshots
  $snapshotList = @()

  $dateUTC = $(Get-Date).ToUniversalTime()
  $dateUTC = $dateUTC.addDays($(0-$daysOld))

  # Loop through each object and then grab the snapshots for each object
  foreach ($obj in $remoteVMs)
  {
    foreach ($snap in $obj.snapshots)
    {
      if ([DateTime]$snap.Date -lt $dateUTC)
      {
        $locationCount = $snap.snapshotRetentionInfo.localInfo.name.count +
          $snap.snapshotRetentionInfo.archivalInfos.name.count +
          $snap.snapshotRetentionInfo.replicationInfos.name.count
        $snapshotInfo = [PSCustomObject]@{
          Name = $obj.name
          ObjectID = $obj.id
          DateUTC = $snap.date
          IsOnDemand = $snap.isOnDemandSnapshot
          CloudState = $snap.cloudState
          SLA = $snap.SlaName
          locationCount = $locationCount
          snapshotID = $snap.id
          Local = $snap.snapshotRetentionInfo.localInfo.name
          LocalExpirationUTC = $snap.snapshotRetentionInfo.localInfo.expirationTime
          Archive = $snap.snapshotRetentionInfo.archivalInfos.name
          ArchiveExpirationUTC = $snap.snapshotRetentionInfo.archivalInfos.expirationTime
          Replication = $snap.snapshotRetentionInfo.replicationInfos.name
          ReplicationExpirationUTC = $snap.snapshotRetentionInfo.replicationInfos.expirationTime
        }
        $snapshotList += $snapshotInfo
      }  # IF
    }  # FOREACH ($snap in $obj.snapshots)
  }  #FOREACH ($obj in $remoteVMs)

  $snapshotList | Export-Csv -NoTypeInformation -Path $csvFile
  Write-Host "`nResults output to: $csvFile"
} # Else if a CSV is provided, read the CSV to generate the object list for deletion, and delete
else
{
  $deleteList = Import-CSV $csvDelete
  $deleteList = $deleteList | Sort-Object -Property 'objectName, objectID'

  $delete = $true
}

# If $delete -eq $true then try to delete all the snapshots in $snapshostList immediately
if ($delete -eq $true)
{
  # $currentObject is the current object that is being processed
  $currentObject = ''

  # $deleteArray is the an array of snapshot IDs to delete for an identical object
  $deleteArray = @()

  # Iterate through $deleteList which contains the filtered snapshot IDs
  foreach ($i in $deleteList) {
    # If processing a new object ID then delete the previous object's snapshots and start processing current one
    if ($currentObject -ne '' -and $currentObject -notlike $i.objectID) {

      Write-Host "Deleting object: $currentObject, snapshots $deleteArray" -ForegroundColor Green

      # First assign the snapshot to "UNPROTECTED" in order to delete it, try v2 endpoint
      try {
        $assignBody = [PSCustomObject] @{
          objectId = $currentObject
          slaDomainId = "UNPROTECTED"
          snapshotIds = $deleteArray
        }
        $req = Invoke-RubrikRESTCall -Method POST -Api 2 -Endpoint "sla_domain/assign_to_snapshot" -Body $assignBody
      }
      catch {
        # If v2 endpoint not there or fails, use $apiVer endpoint
        try {
          $assignBody = [PSCustomObject] @{
            slaDomainId = "UNPROTECTED"
            snapshotIds = $deleteArray
          }
          $req = Invoke-RubrikRESTCall -Method POST -Api $apiVer -Endpoint "unmanaged_object/snapshot/assign_sla" -Body $assignBody
        }
        catch
        {
          Write-Error "Error assigning SLA UNPROTECTED to object $currentObject, snapshots $deleteArray"
        }
      }

      # Snapshot SLA assignment is async, wait a little before attempting deletion
      Start-Sleep -s 1

      # Delete the snapshot
      try
      {
        $deleteBody = [PSCustomObject] @{
          snapshotIds = $deleteArray
        }
        Invoke-RubrikRESTCall -Method POST -Api 1 -Endpoint "data_source/$($currentObject)/snapshot/bulk_delete" -Body $deleteBody
      } catch { Write-Error "Error deleting object $currentObject, snapshots $deleteArray" }

      $currentObject = $i.objectID
      $deleteArray = @($i.snapshotID)
    }
    # Else if the current object ID is the same, add the current object's snapshot IDs to the list for deletion
    else
    {
      $currentObject = $i.objectID
      $deleteArray += @($i.snapshotID)
    }
  }  # foreach in $allSnapshotManagement

  # Delete the last processed object and associated snapshots
  Write-Host "Deleting object: $currentObject, snapshots $deleteArray" -ForegroundColor Green

  # First assign the snapshot to "UNPROTECTED" in order to delete it, try v2 endpoint
  try {
    $assignBody = [PSCustomObject] @{
      objectId = $currentObject
      slaDomainId = "UNPROTECTED"
      snapshotIds = $deleteArray
    }
    $req = Invoke-RubrikRESTCall -Method POST -Api 2 -Endpoint "sla_domain/assign_to_snapshot" -Body $assignBody
  }
  catch {
    # If v2 endpoint not there or fails, use $apiVer endpoint
    try {
      $assignBody = [PSCustomObject] @{
        slaDomainId = "UNPROTECTED"
        snapshotIds = $deleteArray
      }
      $req = Invoke-RubrikRESTCall -Method POST -Api $apiVer -Endpoint "unmanaged_object/snapshot/assign_sla" -Body $assignBody
    }
    catch
    {
      Write-Error "Error assigning SLA UNPROTECTED to object $currentObject, snapshots $deleteArray"
    }
  }

  # Snapshot SLA assignment is async, wait a little before attempting deletion
  Start-Sleep -s 1

  # Delete the snapshot
  try
  {
    $deleteBody = [PSCustomObject] @{
      snapshotIds = $deleteArray
    }
    Invoke-RubrikRESTCall -Method POST -Api 1 -Endpoint "data_source/$($currentObject)/snapshot/bulk_delete" -Body $deleteBody
  } catch { Write-Error "Error deleting object $currentObject, snapshots $deleteArray" }

  Write-Host ""
  Write-Host "Finished attempting to delete snapshots. You may see warnings which are ok."
  Write-Host "Snapshot SLA assignment is async which may have stalled some deletions from occurring."
  Write-Host "Run script again if needed and generate another list of the snapshots to verify if still exist on the cluster or not."
}  # if $delete is $true

$delete = $false

$disconnect = Disconnect-Rubrik -Confirm:$false
