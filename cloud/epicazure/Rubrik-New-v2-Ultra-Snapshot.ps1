<#
.SYNOPSIS
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

.DESCRIPTION
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

This script works with a PSD1 config file (see rubrik_az_config.psd1).

Supports Azure Instant Access Snapshots for Ultra / v2 disks via useInstantSnapshots config flag.

The script supports creating the snapshots from a Prod VM in one subscription
and creating the clone of the disks to a Proxy VM in another subscription.

For v2 / Ultra disks, the performance config depends on disk size. The script has
some error handling to check for a valid config and sets it to the max value
if the disk config throws an error.

The script performs the following tasks:

1. SSH to PROD VM - Freeze IRIS ODB
   ** ssh <user>@<iris_host> 'sudo <instafreeze>'
   ** Also sends command via sleep to automatically 'instathaw' after x minutes
2. Azure - Create v2/Ultra SSD incremental snapshot
3. SSH to PROD VM - Thaw IRIS ODB
   ** ssh <user>@<iris_host> 'sudo <instathaw>'
4. Azure - Wait for snapshot to be ready
   ** Instant access: waits for InstantAccess state (seconds)
   ** Standard: waits for background copy to reach 100% (minutes)
5. Azure - Create new Managed Disks from the snapshots for the Proxy VM
6. Azure - Wait for Managed Disk to be ready
   ** Instant access: skipped, disk is immediately usable (reads served from snapshot)
   ** Standard: waits for background copy to reach 100%
7. Proxy VM - Prep the VM for the refreshed Managed Disks
   ** Checks if mounted/active before unmounting (skips if not present)
   ** unmount <mount_points>
   ** vgchange -an <volume_groups>
8. Azure - Find Managed Disks matching source disk names on the Proxy VM, detach them
9. Azure - Attach the newly cloned Managed Disks onto the Proxy VM
10. Proxy VM - Re-Mount the refreshed Managed Disks
   ** vgchange -ay <volume_groups>
   ** mount <using dev mapper>
11. Rubrik backup begins

The snapshot and the cloned Managed Disks will be the same name as the source disk
but appended with a 'suffix' and datestamped.

.NOTES
Written by Steven Tong for usage with Rubrik
GitHub: stevenctong
Date: 8/30/24
Updated: 7/16/26

PRE-REQUISITES:
1. IRIS PROD VM has the Proxy VM keys as 'authorized_keys' for SSH commands
2. Mount points created on the Proxy VM - we will use dev-mapper to mount
3. Proxy VM is built with option to "Support Premium SSDs" and also placed
   in a specific Availability Zone that supports v2 / Ultra disks
4. Azure authentication - the script runs from the Proxy VM using a
   Managed Identity (MI) with a Custom Role. Setup steps:

   a. Create a User-assigned Managed Identity and attach it to the Proxy VM:
      - Go to Managed Identities -> Create a new User-assigned MI
      - Go to the Proxy VM -> Identity -> User assigned -> Add the MI

   b. Create a Custom Role with the following permissions:

      "actions": [
        "Microsoft.Compute/snapshots/read",
        "Microsoft.Compute/snapshots/write",
        "Microsoft.Compute/snapshots/delete",
        "Microsoft.Compute/virtualMachines/attachDetachDataDisks/action",
        "Microsoft.Compute/disks/read",
        "Microsoft.Compute/disks/write",
        "Microsoft.Compute/disks/delete",
        "Microsoft.Compute/disks/beginGetAccess/action",
        "Microsoft.Compute/virtualMachines/read"
      ]

   c. Assign the Custom Role to the MI on each Resource Group that the
      script needs access to (source RG for snapshots, target RG for
      Proxy VM and cloned disks):
      - Go to the Resource Group -> Access control (IAM) -> Add role
        assignment -> Select the Custom Role -> For Members, choose
        'Managed identity' and select the MI

 .PARAMETER configFile
 Path to the PSD1 config file containing all instance-specific variables.
 See rubrik_az_config.psd1 for an example.

 .EXAMPLE
 ./Rubrik-New-v2-Ultra-Snapshot.ps1 -configFile 'rubrik_az_config.psd1'
 Execute the script according to the variables in the config file. Specify
 variables such as mount points, VG, and LV within the config file.

#>

[CmdletBinding()]
param (
  [Parameter(Mandatory=$true)]
  [string]$configFile
)

$requiredModules = @('Az.Accounts', 'Az.Compute')
$missingModules = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($missingModules) {
  foreach ($mod in $missingModules) {
    Write-Error "Required module '$mod' is not installed. Install it with: Install-Module -Name $mod -Repository PSGallery -Scope AllUsers"
  }
  exit 1
}
Import-Module Az.Accounts
Import-Module Az.Compute

$date = Get-Date
# $dateString will be appended to all snapshots and managed disks
# If this pattern changes, the logic to delete older snapshots and cloned disks
# will need to be updated
$dateString = $date.ToString("yyyy-MM-dd_HHmm")

## If you need to mount an existing disk, set $dateString below
# $dateString = '2024-10-01_1628'


##### BEGIN - VARIABLES #####

if (-Not (Test-Path $configFile)) {
  throw "File not found: $configFile"
}

$configData = Import-PowerShellDataFile -Path $configFile

# Create local variables from all config keys
foreach ($key in $configData.Keys) {
  New-Variable -Name $key -Value $configData[$key] -Force
}

# Log path derived from config values + date
if ($irisName) {
  $logPath = $logDir + '/' + $logFilename + '-' + $irisName + '-' + $dateString + '.log'
} else {
  $logPath = $logDir + '/' + $logFilename + '-' + $dateString + '.log'
}

if (-Not (Test-Path $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Start-Transcript -path $logPath -append

Write-Host ""
Write-Host "Starting Azure snapshot and clone script on $(hostname)"
Write-Host "Config file: $configFile"
Write-Host "Date: $date"
Write-Host "Date string (appended to resources): $dateString"
Write-Host "Log file: $logPath"
if ($irisName) {
  Write-Host "IRIS instance: $irisName"
}
Write-Host ""
Write-Host "Execution flags:"
Write-Host "  Epic commands: $executeEpicCommands"
Write-Host "  Connect to Azure: $executeConnectToAzure"
Write-Host "  Azure cleanup: $executeAzureCleanup"
Write-Host "  Azure snapshot: $executeAzureSnapshot"
Write-Host "  Instant access snapshots: $useInstantSnapshots"
if ($useInstantSnapshots) {
  Write-Host "  Instant access duration: $instantAccessDurationMins minutes"
}
Write-Host "  Managed Disk clone: $executeManagedDiskClone"
Write-Host "  Proxy disk unmount: $executeProxyDiskUnmountCommands"
Write-Host "  Azure disk detach: $executeAzureDiskDetach"
Write-Host "  Azure disk attach: $executeAzureDiskAttach"
Write-Host "  Proxy mount: $executeProxyMountCommands"
Write-Host "  Copy tags from source disk: $copyTagsFromSource"
Write-Host ""

# Delete log files older than 60 days
$logRetentionDays = 60
$logCutoff = $date.AddDays(-$logRetentionDays)
Get-ChildItem -Path $logDir -Filter "${logFilename}*.log" -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt $logCutoff } |
  ForEach-Object {
    Write-Host "Deleting log older than $logRetentionDays days: $($_.Name)"
    Remove-Item $_.FullName -Force
  }

# IRIS freeze / thaw commands - derived from irisName or config
if ($irisName) {
  $EPIC_FREEZE_CMD = "sudo /epic/${irisName}/bin/instfreeze"
  $EPIC_THAW_CMD = "sudo /epic/${irisName}/bin/instthaw"
} else {
  $EPIC_FREEZE_CMD = $EPIC_FREEZE
  $EPIC_THAW_CMD = $EPIC_THAW
}
# Auto-thaw fires after 8 min as a safety net in case the script fails before sending thaw
$EPIC_AUTOTHAW_CMD = "nohup sh -c '(sleep 8m && ${EPIC_THAW_CMD}) > /dev/null 2>&1 &'"

# Email subject derived from config + irisName + date
if ($irisName) {
  $emailSubject = $emailSubject + " - " + $irisName + " - " + $date.ToString("yyyy-MM-dd HH:mm")
} else {
  $emailSubject = $emailSubject + " - " + $date.ToString("yyyy-MM-dd HH:mm")
}

# MOUNT_LIST, VG_LIST, LV_LIST - derived from irisName or config
if ($irisName) {
  $MOUNT_LIST = @('/' + $irisName + '01')
  $VG_LIST = @($irisName + 'vg')
  $LV_LIST = @('lv_' + $irisName)
} else {
  $MOUNT_LIST = $MOUNTS
  $VG_LIST = $VGS
  $LV_LIST = $LVS
}

# Dev-Mapper paths derived from VG and LV lists
$DEVMAPPER_LIST = @(for ($i = 0; $i -lt $VG_LIST.count; $i++) {
  "/dev/mapper/$($VG_LIST[$i])-$($LV_LIST[$i])"
})

##### END - VARIABLES #####

# Deletes Azure snapshots or Managed Disks older than a cutoff date.
# Parses the embedded yyyy-MM-dd_HHmm timestamp from the resource name.
function Remove-ExpiredAzureResources {
  param (
    [string]$ResourceGroup,
    [array]$Resources,
    [string]$NameSuffix,
    [datetime]$CutoffDate,
    [int]$RetentionDays,
    [ValidateSet('snapshot','disk')]
    [string]$ResourceType,
    [array]$SourceDisks
  )
  foreach ($disk in $SourceDisks) {
    $matchName = "${disk}-${NameSuffix}"
    $matched = $Resources | Where-Object { $_.Name -match $matchName }
    foreach ($resource in $matched) {
      if ($resource.Name -match '\d{4}-\d{2}-\d{2}_\d{4}') {
        $dateStamp, $time = $matches[0] -split '_'
        $time = $time.Insert(2, ':')
        $resourceDate = [datetime]::ParseExact("$dateStamp $time", 'yyyy-MM-dd HH:mm', $null)
        if ($resourceDate -lt $CutoffDate) {
          Write-Host "Deleting $ResourceType older than $RetentionDays days: $($resource.Name)"
          try {
            if ($ResourceType -eq 'snapshot') {
              $result = Remove-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName $resource.Name -Force -ErrorAction Stop
            } else {
              $result = Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $resource.Name -Force -ErrorAction Stop
            }
            Write-Host "$ResourceType deletion result: $($result.Status)"
          } catch {
            Write-Host "WARNING: Failed to delete $ResourceType $($resource.Name) - $($_.Exception.Message)" -foregroundcolor red
          }
        }
      }
    }
  }
}

# Sends the IRIS ODB thaw command via SSH if Epic commands are enabled
function Send-EpicThawCommand {
  if ($executeEpicCommands) {
    Write-Host "Sending command to thaw IRIS ODB..." -foregroundcolor cyan
    ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_THAW_CMD} 2>&1
  }
}

# Calls the attachDetachDataDisks REST API to attach/detach disks from a VM.
# Uses Invoke-AzRestMethod instead of Update-AzVM to avoid requiring NIC join permissions.
function Invoke-AttachDetachDataDisks {
  param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$VMName,
    [hashtable]$Body,
    [int]$MaxRetries = 4,
    [string]$Operation = 'attach/detach'
  )
  $apiPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$VMName/attachDetachDataDisks?api-version=2024-03-01"
  $jsonBody = $Body | ConvertTo-Json -Depth 5
  $result = $null
  $retryCount = 0
  while ($null -eq $result) {
    if ($retryCount -ge $MaxRetries) {
      return @{ Success = $false; Error = "Max retries ($MaxRetries) exceeded for $Operation" }
    }
    $retryCount++
    if ($retryCount -gt 1) {
      $randomInterval = Get-Random -Minimum 20 -Maximum 60
      Write-Host "  Retry $retryCount/$MaxRetries - waiting ${randomInterval}s before next attempt..."
      Start-Sleep -Seconds $randomInterval
    }
    try {
      Write-Host "  Calling attachDetachDataDisks REST API (attempt $retryCount/$MaxRetries)..."
      $response = Invoke-AzRestMethod -Method POST -Path $apiPath -Payload $jsonBody -ErrorAction Stop
      if ($response.StatusCode -eq 200) {
        Write-Host "  API returned 200 - operation completed synchronously" -foregroundcolor green
        $result = $response
      } elseif ($response.StatusCode -eq 202) {
        Write-Host "  API returned 202 - operation accepted, polling for completion..."
        $locationUrl = ($response.Headers | Where-Object { $_.Key -eq 'Location' }).Value
        if (-not $locationUrl) {
          $locationUrl = ($response.Headers | Where-Object { $_.Key -eq 'Azure-AsyncOperation' }).Value
        }
        if ($locationUrl) {
          $pollCount = 0
          $pollMax = 60
          while ($pollCount -lt $pollMax) {
            $pollCount++
            Start-Sleep -Seconds 10
            $pollResponse = Invoke-AzRestMethod -Method GET -Uri $locationUrl -ErrorAction Stop
            if ($pollResponse.StatusCode -eq 200) {
              $pollBody = $pollResponse.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
              if ($pollBody.status -eq 'InProgress' -or $pollBody.status -eq 'Running') {
                if ($pollCount % 3 -eq 0) {
                  Write-Host "  Still in progress... ($($pollCount * 10)s elapsed)"
                }
                continue
              }
              Write-Host "  Async operation completed" -foregroundcolor green
              $result = $pollResponse
              break
            } elseif ($pollResponse.StatusCode -eq 204) {
              Write-Host "  Async operation completed (204)" -foregroundcolor green
              $result = $pollResponse
              break
            } else {
              Write-Host "  Poll returned status $($pollResponse.StatusCode), continuing..."
            }
          }
          if ($null -eq $result) {
            Write-Error "  Polling timed out after $($pollMax * 10)s for $Operation"
          }
        } else {
          Write-Host "  No Location/AsyncOperation header in 202 response, treating as success" -foregroundcolor yellow
          $result = $response
        }
      } else {
        $errorContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        $errorMsg = if ($errorContent.error.message) { $errorContent.error.message } else { $response.Content }
        Write-Error "  API returned $($response.StatusCode): $errorMsg"
      }
    } catch {
      Write-Error "  Error during $Operation - $($_.Exception.Message)"
    }
  }
  if ($null -ne $result) {
    return @{ Success = $true; Response = $result }
  }
  return @{ Success = $false; Error = "Failed after $MaxRetries retries" }
}

#### Login to Azure and initialization of some variables ####

$currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
$emailBody = "${currentTime}: Starting Azure snapshot script $irisName `n"

if ($executeConnectToAzure) {
  $azLogin = Connect-AzAccount -Identity -ErrorAction Stop
  Write-Host "Logged in as: $($azLogin.Context.Account.Id), Tenant: $($azLogin.Context.Tenant.Id)" -foregroundcolor green
  $azCtx = Set-AzContext -subscription $sourceSubscriptionId -ErrorAction Stop
  Write-Host "Subscription context set to: $($azCtx.Subscription.Name) ($sourceSubscriptionId)" -foregroundcolor green
  # Name mappings and info caches used across steps
  $sourceDiskToTargetDisk = @{}
  $sourceDiskToSnapshot = @{}
  $sourceDiskInfo = @{}
  $sourceSnapshotInfo = @{}
  foreach ($disk in $sourceDisks) {
    $sourceDiskToSnapshot.$disk = "${disk}-${sourceSnapshotSuffix}-${dateString}"
    $sourceDiskToTargetDisk.$disk = "${disk}-${targetDiskSuffix}-${dateString}"
  }
  $diskCount = $sourceDisks.count
  Write-Host ""
  Write-Host "Date: $date" -foregroundcolor green
  Write-Host "Source Subscription ID: $sourceSubscriptionId" -foregroundcolor green
  Write-Host "Source Resource Group: $sourceResourceGroup" -foregroundcolor green
  Write-Host "Source Snapshot suffix: -${sourceSnapshotSuffix}-${dateString}" -foregroundcolor green
  Write-Host ""
  Write-Host "Target (Proxy VM) Subscription ID: $targetSubscriptionId" -foregroundcolor green
  Write-Host "Target (Proxy VM) Resource Group: $targetResourceGroup" -foregroundcolor green
  Write-Host "Target (Proxy VM) Disk suffix: -${targetDiskSuffix}-${dateString}" -foregroundcolor green
  Write-Host ""
  Write-Host "$diskCount disks will be snapshot and cloned:" -foregroundcolor green
  foreach ($disk in $sourceDisks) {
    Write-Host "Source Disk Name: $disk"
    Write-Host "Source Snapshot Name: $($sourceDiskToSnapshot.$disk)"
    Write-Host "Target Disk Name: $($sourceDiskToTargetDisk.$disk)"
    Write-Host ""
  }
  Write-Host ""
}

#### Cleanup older snapshots and cloned Managed Disks ####

if ($executeAzureCleanup) {
  $stepStart = Get-Date
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Cleaning up older snapshots and cloned disks `n"
  $azCtx = Set-AzContext -subscription $sourceSubscriptionId -ErrorAction Stop
  Write-Host "Subscription context: $($azCtx.Subscription.Name) ($sourceSubscriptionId)"

  $snapCutoff = $date.AddDays(-$snapDaysToKeep)
  Write-Host "Looking for and cleaning up any snapshots older than: $snapCutoff" -foregroundcolor green
  $azSnapshots = Get-AzSnapshot -ResourceGroup $sourceResourceGroup -ErrorAction Stop
  Remove-ExpiredAzureResources -ResourceGroup $sourceResourceGroup -Resources $azSnapshots `
    -NameSuffix $sourceSnapshotSuffix -CutoffDate $snapCutoff -RetentionDays $snapDaysToKeep `
    -ResourceType 'snapshot' -SourceDisks $sourceDisks

  $diskCutoff = $date.AddDays(-$clonedDisksDaysToKeep)
  Write-Host "Looking for and cleaning up Managed Disk clones older than: $diskCutoff" -foregroundcolor green
  if ($sourceSubscriptionId -ne $targetSubscriptionId) {
    $azCtx = Set-AzContext -subscription $targetSubscriptionId -ErrorAction Stop
    Write-Host "Switched subscription context to: $($azCtx.Subscription.Name) ($targetSubscriptionId)"
  }
  $azDisks = Get-AzDisk -ResourceGroup $targetResourceGroup -ErrorAction Stop
  Remove-ExpiredAzureResources -ResourceGroup $targetResourceGroup -Resources $azDisks `
    -NameSuffix $targetDiskSuffix -CutoffDate $diskCutoff -RetentionDays $clonedDisksDaysToKeep `
    -ResourceType 'disk' -SourceDisks $sourceDisks

  if ($sourceSubscriptionId -ne $targetSubscriptionId) {
    $azCtx = Set-AzContext -subscription $sourceSubscriptionId -ErrorAction Stop
    Write-Host "Switched subscription context to: $($azCtx.Subscription.Name) ($sourceSubscriptionId)"
  }
  Write-Host "Cleanup completed in $([math]::Round(((Get-Date) - $stepStart).TotalSeconds))s" -foregroundcolor green
}  # if ($executeAzureCleanup)

#### Create snapshot of each source disk ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/disks-incremental-snapshots?tabs=azure-powershell

# Send command to IRIS PRD server to freeze and set auto-thaw
if ($executeEpicCommands) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Sending command to freeze IRIS ODB `n"
  Write-Host "Sending command to freeze & auto-thaw IRIS ODB..." -foregroundcolor cyan
  Write-Host "Freeze: ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_FREEZE_CMD}"
  $freezeResult = ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_FREEZE_CMD} 2>&1
  Write-Host "Freeze result: $freezeResult"
  Write-Host "Auto-thaw: ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_AUTOTHAW_CMD}"
  $autothawResult = ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_AUTOTHAW_CMD} 2>&1
  Write-Host "Auto-thaw result: $autothawResult"
}

if ($executeAzureSnapshot) {
  $stepStart = Get-Date
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $snapshotMode = if ($useInstantSnapshots) { "instant access" } else { "standard" }
  $emailBody += "${currentTime}: Creating snapshots ($snapshotMode) `n"
  # Create a snapshot for each disk
  $snapshotType = if ($useInstantSnapshots) { "instant access incremental" } else { "incremental" }
  foreach ($snapshot in $sourceDiskToSnapshot.getEnumerator()) {
    $diskName = $snapshot.name
    $snapshotName = $snapshot.value
    Write-Host ""
    Write-Host "Creating $snapshotType snapshot for disk: $diskName" -foregroundcolor green
    Write-Host "  Snapshot name: $snapshotName"
    if ($useInstantSnapshots) {
      Write-Host "  Instant access duration: $instantAccessDurationMins minutes"
    }
    $diskInfo = Get-AzDisk -DiskName $diskName -ResourceGroupName $sourceResourceGroup -ErrorAction Stop
    if (-not $diskInfo) {
      Write-Error "Source disk not found: $diskName in RG $sourceResourceGroup"
      Send-EpicThawCommand
      exit 10
    }
    $sourceDiskInfo.$diskName = $diskInfo
    # Snapshot config clones the source disk's location, zone, and tags
    $snapshotConfigParams = @{
      SourceUri = $diskInfo.Id
      Location = $diskInfo.Location
      CreateOption = "Copy"
      Incremental = $true
    }
    if ($copyTagsFromSource) {
      if ($diskInfo.Tags -and $diskInfo.Tags.Count -gt 0) {
        Write-Host "  Source disk has $($diskInfo.Tags.Count) tag(s):"
        foreach ($tag in $diskInfo.Tags.GetEnumerator()) {
          Write-Host "    $($tag.Key) = $($tag.Value)"
        }
        $snapshotConfigParams.Tag = $diskInfo.Tags
        Write-Host "  Applying $($diskInfo.Tags.Count) tag(s) to snapshot: $snapshotName"
      } else {
        Write-Host "  Source disk has no tags" -foregroundcolor yellow
      }
    }
    if ($useInstantSnapshots) {
      $snapshotConfigParams.InstantAccessDurationMinutes = $instantAccessDurationMins
    }
    $snapshotConfig = New-AzSnapshotConfig @snapshotConfigParams -ErrorAction Stop
    try {
      $result = New-AzSnapshot -ResourceGroupName $sourceResourceGroup -SnapshotName $snapshotName -Snapshot $snapshotConfig -ErrorAction Stop
    } catch {
      Write-Error "Failed to create snapshot $snapshotName - $($_.Exception.Message)"
      Send-EpicThawCommand
      exit 10
    }
    $snapshotState = $result.ProvisioningState
    if ($snapshotState.contains('Succeeded')) {
      Write-Host "Snapshot created successfully (ProvisioningState: $snapshotState)" -foregroundcolor green
    } else {
      Write-Error "Snapshot failed for $snapshotName - ProvisioningState: $snapshotState"
      Send-EpicThawCommand
      exit 11
    }
  } # foreach snapshot

  Send-EpicThawCommand

  Write-Host ""
  # Instant access snapshots reach usable state in seconds, standard need minutes for background copy
  $snapPollSecs = if ($useInstantSnapshots) { 10 } else { $statusCheckSecs }
  if ($useInstantSnapshots) {
    Write-Host "Waiting for $diskCount snapshot(s) to reach InstantAccess state (polling every ${snapPollSecs}s)..." -foregroundcolor green
    Write-Host "  Instant access snapshots are usable immediately once in InstantAccess state"
  } else {
    Write-Host "Waiting for $diskCount snapshot(s) to finish background copy (polling every ${snapPollSecs}s)..." -foregroundcolor green
    Write-Host "  Standard incremental snapshots require background copy to complete before disk creation"
  }
  Write-Host ""

  # Poll until all snapshots are ready (instant: InstantAccess state, standard: 100% copy)
  $snapshotComplete = @{}
  $pollIteration = 0
  $maxPollIterations = if ($useInstantSnapshots) { 60 } else { 120 }

  while ($snapshotComplete.count -lt $diskCount) {
    if ($pollIteration -ge $maxPollIterations) {
      Write-Error "Snapshot timed out after $([math]::Round($pollIteration * $snapPollSecs / 60)) minutes, exiting..."
      exit 12
    }
    $pollIteration++
    $currentTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    foreach ($snapshot in $sourceDiskToSnapshot.getEnumerator()) {
      if ($snapshotComplete.ContainsKey($snapshot)) { continue }
      $snapshotName = $snapshot.value
      $snapshotInfo = Get-AzSnapshot -ResourceGroupName $sourceResourceGroup -SnapshotName $snapshotName
      $sourceSnapshotInfo.$snapshotName = $snapshotInfo
      if ($useInstantSnapshots) {
        $accessState = $snapshotInfo.SnapshotAccessState
        if ($accessState -in @('InstantAccess', 'AvailableWithInstantAccess')) {
          Write-Host "${currentTime}: Snapshot: $($snapshotInfo.name), state: $accessState" -foregroundcolor green
          $snapshotComplete.$snapshot = $true
        } else {
          Write-Host "${currentTime}: Snapshot: $($snapshotInfo.name), state: $accessState, waiting another ${snapPollSecs}s..."
        }
      } else {
        if ($snapshotInfo.CompletionPercent -lt 100) {
          Write-Host "${currentTime}: Snapshot: $($snapshotInfo.name), completion: $($snapshotInfo.CompletionPercent), waiting another ${snapPollSecs}s..."
        } else {
          Write-Host "${currentTime}: Snapshot: $($snapshotInfo.name), completion: $($snapshotInfo.CompletionPercent)" -foregroundcolor green
          $snapshotComplete.$snapshot = $true
        }
      }
    }
    if ($snapshotComplete.count -lt $diskCount) {
      Start-Sleep $snapPollSecs
    }
  }
  $stepElapsed = [math]::Round(((Get-Date) - $stepStart).TotalSeconds)
  if ($useInstantSnapshots) {
    Write-Host "All $diskCount snapshots are in InstantAccess state (${stepElapsed}s)" -foregroundcolor green
  } else {
    Write-Host "All $diskCount snapshots have finished background copy (${stepElapsed}s)" -foregroundcolor green
  }
} # if ($executeAzureSnapshot)

# When snapshot step is skipped, look up existing disk and snapshot info.
# Set $dateString at the top of the script to target a specific snapshot.
if ( $executeManagedDiskClone -and ($executeAzureSnapshot -eq $false) ) {
  foreach ($snapshot in $sourceDiskToSnapshot.getEnumerator()) {
    $diskName = $snapshot.name
    $diskInfo = Get-AzDisk -DiskName $diskName -ResourceGroupName $sourceResourceGroup -ErrorAction Stop
    if (-not $diskInfo) {
      Write-Error "Source disk not found: $diskName in RG $sourceResourceGroup"
      exit 10
    }
    $sourceDiskInfo.$diskName = $diskInfo
    $snapshotName = $snapshot.value
    $snapshotInfo = Get-AzSnapshot -ResourceGroupName $sourceResourceGroup -SnapshotName $snapshotName -ErrorAction Stop
    if (-not $snapshotInfo) {
      Write-Error "Snapshot not found: $snapshotName in RG $sourceResourceGroup (is dateString correct?)"
      exit 12
    }
    $sourceSnapshotInfo.$snapshotName = $snapshotInfo
  }
}

#### Switch Subscription Context ####
# All remaining Azure commands target the Proxy VM's subscription
if ($executeConnectToAzure) {
  if ($sourceSubscriptionId -ne $targetSubscriptionId) {
    Write-Host ""
    $azCtx = Set-AzContext -Subscription $targetSubscriptionId -ErrorAction Stop
    Write-Host "Switched subscription context to target: $($azCtx.Subscription.Name) ($targetSubscriptionId)"
  }
}

#### Create a Managed Disk from the snapshot ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-powershell-sample-create-managed-disk-from-snapshot
# https://learn.microsoft.com/en-us/powershell/module/az.compute/new-azdiskconfig

if ($executeManagedDiskClone) {
  $stepStart = Get-Date
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Creating cloned Managed Disks from snapshots ($snapshotMode) `n"
  Write-Host ""
  if ($useInstantSnapshots) {
    Write-Host "Creating Managed Disks from instant access snapshots (disks are usable immediately after creation)..." -foregroundcolor green
  } else {
    Write-Host "Creating Managed Disks from incremental snapshots (background copy required before use)..." -foregroundcolor green
  }
  foreach ($disk in $sourceDisks) {
    $targetDiskName = $sourceDiskToTargetDisk[$disk]
    $diskInfo = $sourceDiskInfo[$disk]
    $snapshotName = $sourceDiskToSnapshot[$disk]
    $snapshotInfo = $sourceSnapshotInfo[$snapshotName]
    Write-Host ""
    Write-Host "Building disk config for source disk: $disk" -foregroundcolor green
    Write-Host "  Source snapshot: $snapshotName"
    Write-Host "  Target disk name: $targetDiskName"
    $diskConfigParameters = @{
      CreateOption = "Copy"
      SourceResourceId = $snapshotInfo.Id
      DiskSizeGB = $diskInfo.DiskSizeGB
      SkuName = $diskInfo.sku.name
      Zone = $diskInfo.zones[0]
      Location = $diskInfo.location
      DiskIOPSReadWrite = $diskIOPSReadWrite
      DiskIOPSReadOnly = $diskIOPSReadOnly
      DiskMBpsReadWrite = $diskMBpsReadWrite
      DiskMBpsReadOnly = $diskMBpsReadOnly
    }
    if ($copyTagsFromSource) {
      if ($diskInfo.Tags -and $diskInfo.Tags.Count -gt 0) {
        Write-Host "  Source disk has $($diskInfo.Tags.Count) tag(s):"
        foreach ($tag in $diskInfo.Tags.GetEnumerator()) {
          Write-Host "    $($tag.Key) = $($tag.Value)"
        }
        $diskConfigParameters.Tag = $diskInfo.Tags
        Write-Host "  Applying $($diskInfo.Tags.Count) tag(s) to cloned disk: $targetDiskName"
      } else {
        Write-Host "  Source disk has no tags" -foregroundcolor yellow
      }
    }
    Write-Host "  SKU: $($diskInfo.sku.name), Size: $($diskInfo.DiskSizeGB)GB, Zone: $($diskInfo.zones[0]), Location: $($diskInfo.location)"
    Write-Host "  IOPS R/W: $diskIOPSReadWrite, IOPS RO: $diskIOPSReadOnly, MBps R/W: $diskMBpsReadWrite, MBps RO: $diskMBpsReadOnly"
    $diskConfig = New-AzDiskConfig @diskConfigParameters -ErrorAction Stop
    # If MBps is out of range for the disk size, Azure returns the valid max in the error message.
    # Retry loop catches that error, extracts the max, adjusts the config, and retries.
    $regex = "disk\.(diskMBpsReadWrite|diskMBpsReadOnly).*between\s+(?:\d+\s+and\s+)?(\d+)"
    $retry = $true
    $retryCount = 0
    while ($retry -eq $true -and $retryCount -lt 4) {
      $retry = $false
      $retryCount++
      if ($retryCount -ge 4) {
        Write-Error "Too many retries in creating Managed Disk, exiting..."
        exit 20
      }
      try {
        Write-Host ""
        Write-Host "Creating new Managed Disk: $targetDiskName" -foregroundcolor green
        $result = New-AzDisk -Disk $diskConfig -ResourceGroupName $targetResourceGroup -DiskName $targetDiskName -ErrorAction Stop
      } catch {
        $errMsg = $_.Exception.Message
        Write-Error "Error creating Managed Disk $targetDiskName - $errMsg"
        if ($errMsg -match $regex) {
          Write-Host "Found an issue with: $($Matches[1]), setting it to max value of: $($Matches[2])" -foregroundcolor yellow
          $diskConfigParameters.$($Matches[1]) = [int]$Matches[2]
          Write-Host "Retrying creating new Managed Disk: $targetDiskName..." -foregroundcolor yellow
          $diskConfig = New-AzDiskConfig @diskConfigParameters -ErrorAction Stop
          $retry = $true
        } else {
          Write-Error "Unhandled error creating Managed Disk: $targetDiskName, exiting..."
          exit 30
        }
      }
    }
    Write-Host "Managed Disk created (ProvisioningState: $($result.ProvisioningState))" -foregroundcolor green
  } # foreach source disk

  if ($useInstantSnapshots) {
    # With instant access snapshots, the disk is backed by the instant access snapshot data.
    # Reads to any region are served directly from the snapshot, so the disk is usable
    # immediately after ProvisioningState = Succeeded. No need to wait for background copy.
    Write-Host ""
    Write-Host "All $diskCount Managed Disk(s) created from instant access snapshots" -foregroundcolor green
    Write-Host "  Skipping background copy wait - disks are immediately usable (reads served from instant access snapshot)" -foregroundcolor green
  } else {
    Write-Host ""
    $diskPollSecs = $statusCheckSecs
    Write-Host "Waiting for $diskCount Managed Disk(s) to finish background copy (polling every ${diskPollSecs}s)..." -foregroundcolor green
    Write-Host "  Standard incremental snapshots require the background copy to complete before the disk can be attached"
    Write-Host ""

    # Poll until all cloned disks finish background copy (standard snapshots only)
    $diskComplete = @{}
    $pollIteration = 0
    $maxPollIterations = 120

    while ($diskComplete.count -lt $diskCount) {
      if ($pollIteration -ge $maxPollIterations) {
        Write-Error "Managed Disk background copy timed out after $([math]::Round($pollIteration * $diskPollSecs / 60)) minutes, exiting..."
        exit 21
      }
      $pollIteration++
      $currentTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
      foreach ($disk in $sourceDisks) {
        if ($diskComplete.ContainsKey($disk)) { continue }
        $targetDiskName = $sourceDiskToTargetDisk[$disk]
        $diskInfo = Get-AzDisk -DiskName $targetDiskName -ResourceGroupName $targetResourceGroup
        if ($diskInfo.CompletionPercent -lt 100) {
          Write-Host "${currentTime}: Disk copy: $($diskInfo.name), completion: $($diskInfo.CompletionPercent), waiting another ${diskPollSecs}s..."
        } else {
          Write-Host "${currentTime}: Disk copy: $($diskInfo.name), completion: $($diskInfo.CompletionPercent)" -foregroundcolor green
          $diskComplete.$disk = $true
        }
      }
      if ($diskComplete.count -lt $diskCount) {
        Start-Sleep $diskPollSecs
      }
    } # while disk copy polling
    Write-Host "All $diskCount Managed Disk(s) have finished background copy" -foregroundcolor green
  }
  Write-Host "Managed Disk clone step completed in $([math]::Round(((Get-Date) - $stepStart).TotalMinutes, 1)) minutes" -foregroundcolor green
} # if ($executeManagedDiskClone)


#### Detach Managed Disk from the Proxy VM ####
# Uses the attachDetachDataDisks REST API (only requires attachDetachDataDisks/action permission)
# https://learn.microsoft.com/en-us/rest/api/compute/virtual-machines/attach-detach-data-disks

# Unmount file systems and deactivate VGs before detaching disks
if ($executeProxyDiskUnmountCommands) {
  Write-Host ""
  Write-Host "On Proxy VM, unmounting file systems before disk detach" -foregroundcolor green
  Write-Host "Current mounts (df -h):"
  df -h
  Write-Host ""
  foreach ($mountPoint in $MOUNT_LIST) {
    $fullPath = "${MOUNT_BASE}${mountPoint}"
    Write-Host "Unmounting $fullPath..."
    umount $fullPath 2>$null
    Write-Host "umount exit code: $LASTEXITCODE"
  }
  Write-Host ""
  Write-Host "Mounts after unmount (df -h):"
  df -h
  Write-Host ""
  Write-Host "Deactivating volume groups before disk detach" -foregroundcolor green
  Write-Host "Current VGs (vgs):"
  vgs 2>$null
  Write-Host ""
  foreach ($vg_name in $VG_LIST) {
    Write-Host "Deactivating VG: $vg_name..."
    vgchange -an $vg_name 2>$null
    Write-Host "vgchange -an exit code: $LASTEXITCODE"
  }
}

if ($executeAzureDiskDetach) {
  $stepStart = Get-Date
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Detaching disks from Proxy VM `n"
  Write-Host ""
  Write-Host "Detaching existing data disks from the Proxy VM" -foregroundcolor green
  Write-Host "  Proxy VM: $proxyVM (RG: $targetResourceGroup)"

  # Find and detach any pre-existing Managed Disks whose names match the source disks
  $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
  Write-Host "  Current data disks on VM: $($vm.StorageProfile.DataDisks.Count)"
  # Build regex pattern from source disk names to find matching attached disks
  $diskPattern = ($sourceDisks | ForEach-Object { [regex]::Escape($_) }) -join '|'
  $disksToDetach = @($vm.StorageProfile.DataDisks |
    Where-Object { $_.Name -match $diskPattern } |
    ForEach-Object { $_.Name })
  if ($disksToDetach.Count -eq 0) {
    Write-Host "  No matching disks found to detach (pattern: $($sourceDisks -join ', '))" -foregroundcolor yellow
  } else {
    Write-Host "  Found $($disksToDetach.Count) disk(s) to detach: $($disksToDetach -join ', ')"
  }
  # Detach all matched disks in a single REST API call
  if ($disksToDetach.Count -gt 0) {
    $detachList = @()
    foreach ($diskDetach in $disksToDetach) {
      $diskEntry = $vm.StorageProfile.DataDisks | Where-Object { $_.Name -eq $diskDetach }
      if ($diskEntry.ManagedDisk.Id) {
        $detachList += @{ diskId = $diskEntry.ManagedDisk.Id }
        Write-Host "  Will detach: $diskDetach (LUN $($diskEntry.Lun))"
      } else {
        Write-Host "  Could not resolve resource ID for disk: $diskDetach, skipping" -foregroundcolor yellow
      }
    }
    if ($detachList.Count -gt 0) {
      $detachBody = @{ dataDisksToDetach = $detachList }
      Write-Host "Detaching $($detachList.Count) disk(s) via attachDetachDataDisks API..."
      $detachResult = Invoke-AttachDetachDataDisks `
        -SubscriptionId $targetSubscriptionId `
        -ResourceGroup $targetResourceGroup `
        -VMName $proxyVM `
        -Body $detachBody `
        -MaxRetries 4 `
        -Operation 'detach'
      if (-not $detachResult.Success) {
        Write-Error "Failed to detach disks: $($detachResult.Error)"
        exit 40
      }
      Write-Host "Successfully detached $($detachList.Count) disk(s)" -foregroundcolor green
    }
  }
  Write-Host "Detach completed in $([math]::Round(((Get-Date) - $stepStart).TotalSeconds))s" -foregroundcolor green
} # if ($executeAzureDiskDetach)


#### Attach Managed Disk to proxy VM ####
# Uses the attachDetachDataDisks REST API (only requires attachDetachDataDisks/action permission)
# https://learn.microsoft.com/en-us/rest/api/compute/virtual-machines/attach-detach-data-disks

if ($executeAzureDiskAttach) {
  $stepStart = Get-Date
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Attaching cloned disks to Proxy VM `n"
  Write-Host ""
  Write-Host "Attaching new Managed Disks to the Proxy VM" -foregroundcolor green
  Write-Host "  Proxy VM: $proxyVM (RG: $targetResourceGroup)"
  Write-Host "  Disks to attach: $($sourceDisks.Count)"

  # Get all currently used LUNs upfront to assign free slots locally
  $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
  $usedLuns = [System.Collections.ArrayList]@($vm.StorageProfile.DataDisks.Lun)
  Write-Host "  Current data disks on VM: $($vm.StorageProfile.DataDisks.Count), used LUNs: $($usedLuns -join ', ')"

  # Build the attach list with disk IDs and LUN assignments
  $attachList = @()
  foreach ($disk in $sourceDisks) {
    $targetDiskName = $sourceDiskToTargetDisk[$disk]
    # Prefer LUN from disk name if present, otherwise start at 0
    if ($targetDiskName -match 'lun([0-9]+)') {
      [int]$lunNum = $matches[1]
    } else {
      $lunNum = 0
    }
    # Find the next free LUN slot
    while ($usedLuns -contains $lunNum) { $lunNum++ }
    # Track locally so subsequent disks won't collide
    $usedLuns.Add($lunNum) | Out-Null

    Write-Host "  Looking up disk resource: $targetDiskName (RG: $targetResourceGroup)..."
    $diskInfo = Get-AzDisk -DiskName $targetDiskName -ResourceGroupName $targetResourceGroup -ErrorAction Stop
    Write-Host "  Disk found: $($diskInfo.Name), ProvisioningState: $($diskInfo.ProvisioningState), DiskState: $($diskInfo.DiskState)"
    $attachList += @{ diskId = $diskInfo.Id; lun = $lunNum }
    Write-Host "  Will attach: $targetDiskName at LUN $lunNum"
  }

  # Attach all disks in a single REST API call
  if ($attachList.Count -gt 0) {
    $attachBody = @{ dataDisksToAttach = $attachList }
    Write-Host ""
    Write-Host "Attaching $($attachList.Count) disk(s) via attachDetachDataDisks API..." -foregroundcolor green
    $attachResult = Invoke-AttachDetachDataDisks `
      -SubscriptionId $targetSubscriptionId `
      -ResourceGroup $targetResourceGroup `
      -VMName $proxyVM `
      -Body $attachBody `
      -MaxRetries 4 `
      -Operation 'attach'
    if (-not $attachResult.Success) {
      Write-Error "Failed to attach disks: $($attachResult.Error)"
      exit 50
    }
    Write-Host "Successfully attached $($attachList.Count) disk(s)" -foregroundcolor green
  }
  Write-Host "Attach completed in $([math]::Round(((Get-Date) - $stepStart).TotalSeconds))s" -foregroundcolor green
} # if ($executeAzureDiskAttach)

# Reactivate VGs and mount the refreshed disks on the Proxy VM
if ($executeProxyMountCommands) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Mounting file systems on Proxy VM `n"
  Write-Host ""
  Write-Host "Scanning SCSI hosts for newly attached disks..." -foregroundcolor green
  bash -c 'for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$host"; done'
  Write-Host "Waiting for device nodes to settle..."
  udevadm settle
  Write-Host ""
  Write-Host "Block devices after SCSI scan (lsblk):"
  lsblk
  Write-Host ""
  Write-Host "Scanning for new PVs and activating VGs" -foregroundcolor green
  Write-Host "Running pvscan --cache..."
  pvscan --cache 2>$null
  Write-Host "Running vgscan..."
  vgscan 2>$null
  Write-Host ""
  $mountCount = $MOUNT_LIST.count
  for ($mount = 0; $mount -lt $mountCount; $mount++) {
    $vg_name = $VG_LIST[$mount]
    $lv_name = $LV_LIST[$mount]
    $path = $MOUNT_LIST[$mount]
    $devPath = $DEVMAPPER_LIST[$mount]
    Write-Host "Cycling LVM for VG: $vg_name" -foregroundcolor green
    Write-Host "  vgchange -an $vg_name..."
    vgchange -an $vg_name 2>$null
    Write-Host "  vgchange -ay $vg_name..."
    vgchange -ay $vg_name
    if ($LASTEXITCODE -ne 0) {
      Write-Error "Failed to activate VG $vg_name (exit code: $LASTEXITCODE), exiting..."
      exit 61
    }
    Write-Host "  VG $vg_name activated" -foregroundcolor green
    Write-Host ""
    Write-Host "Block devices after VG activation (lsblk):"
    lsblk
    Write-Host ""
    Write-Host "  Mounting $devPath to ${MOUNT_BASE}${path}..."
    mount $devPath ${MOUNT_BASE}${path}
    if ($LASTEXITCODE -ne 0) {
      Write-Error "Failed to mount $devPath to ${MOUNT_BASE}${path} (exit code: $LASTEXITCODE), exiting..."
      exit 63
    }
    Write-Host "  Successfully mounted $devPath to ${MOUNT_BASE}${path}" -foregroundcolor green
  }
  Write-Host ""
  Write-Host "Verifying all mount points (df -h):" -foregroundcolor green
  df -h
}

$endTime = Get-Date
$elapsed = $endTime - $date
$elapsedMins = [math]::Round($elapsed.TotalMinutes, 1)
Write-Host ""
Write-Host "Script completed successfully in $elapsedMins minutes" -foregroundcolor green

Stop-Transcript

# Build email body with summary header and full transcript
$snapshotModeLabel = if ($useInstantSnapshots) { "Instant Access" } else { "Standard" }
$emailBody += "Completed in $elapsedMins minutes | Snapshot mode: $snapshotModeLabel | Disks: $($sourceDisks.count) `n`n"
$emailBody += Get-Content -Path $logPath -Raw
$emailBodyHtml = "<pre>$emailBody</pre>"

if ($sendMail) {
  Send-MailMessage -From $emailFrom -To $emailTo -Subject "$emailSubject ($snapshotModeLabel)" -Body $emailBodyHtml -SmtpServer $smtpServer -BodyAsHtml $true
}

exit 0
