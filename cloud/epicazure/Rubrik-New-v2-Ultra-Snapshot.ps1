<#
.SYNOPSIS
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

.DESCRIPTION
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

This script works with a PSD1 config file (see rubrik_az_config.psd1).

Supports Azure Instant Access Snapshots for Ultra / v2 disks via useInstantSnapshots config flag.

When useRestorePoints is enabled in the config, the script uses Azure VM Restore Points
(ApplicationConsistent mode) for cross-disk consistency instead of individual disk snapshots.
ApplicationConsistent is required for Premium SSD v2 and Ultra disks (CrashConsistent is not
supported for these disk types). All source disks must belong to the same Azure VM. The script
derives the source VM from the disks' ManagedBy property. When 2+ disks are configured without
restore points enabled, the script outputs a recommendation to enable them.
Note: ApplicationConsistent restore points require the Azure VM Agent running in the guest OS.
Azure throttles restore point creation to 3 per VM per hour (HTTP 429).

The script supports creating the snapshots from a Prod VM in one subscription
and creating the clone of the disks to a Proxy VM in another subscription.

For v2 / Ultra disks, the performance config depends on disk size. The script has
some error handling to check for a valid config and sets it to the max value
if the disk config throws an error.

The script performs the following tasks:

1. SSH to PROD VM - Freeze IRIS ODB
   ** ssh <user>@<iris_host> 'sudo <instafreeze>'
   ** Also sends command via sleep to automatically 'instathaw' after x minutes
2. Azure - Create snapshots
   2a. (default) Create individual incremental snapshot per disk
   2b. (useRestorePoints) Create ApplicationConsistent VM Restore Point for cross-disk consistency
3. SSH to PROD VM - Thaw IRIS ODB
   ** ssh <user>@<iris_host> 'sudo <instathaw>'
4. Azure - Wait for snapshot/restore point to be ready
   ** Instant access: waits for InstantAccess state (seconds)
   ** Standard: waits for background copy to reach 100% (minutes)
   ** Restore points: creation is synchronous, then polls each disk restore
      point until completionPercent 100% and accessState Available
5. Azure - Create new Managed Disks from the snapshots/disk restore points for the Proxy VM
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
Updated: 7/29/26

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
        "Microsoft.Compute/snapshots/read",                     // Contributor, Disk Snapshot Contributor
        "Microsoft.Compute/snapshots/write",                    // Contributor, Disk Snapshot Contributor
        "Microsoft.Compute/snapshots/delete",                   // Contributor, Disk Snapshot Contributor
        "Microsoft.Compute/virtualMachines/attachDetachDataDisks/action",  // Contributor, Virtual Machine Contributor
        "Microsoft.Compute/disks/read",                         // Contributor, Virtual Machine Contributor
        "Microsoft.Compute/disks/write",                        // Contributor, Virtual Machine Contributor
        "Microsoft.Compute/disks/delete",                       // Contributor, Virtual Machine Contributor
        "Microsoft.Compute/disks/beginGetAccess/action",        // Contributor, Disk Snapshot Contributor
        "Microsoft.Compute/virtualMachines/read"                // Contributor, Virtual Machine Contributor, Reader
      ]

      // Additional permissions required when useRestorePoints is enabled:
      "actions": [
        "Microsoft.Compute/restorePointCollections/read",       // Contributor
        "Microsoft.Compute/restorePointCollections/write",      // Contributor
        "Microsoft.Compute/restorePointCollections/delete",     // Contributor
        "Microsoft.Compute/restorePointCollections/restorePoints/read",    // Contributor
        "Microsoft.Compute/restorePointCollections/restorePoints/write",   // Contributor
        "Microsoft.Compute/restorePointCollections/restorePoints/delete",  // Contributor
        "Microsoft.Compute/restorePointCollections/restorePoints/diskRestorePoints/read"  // Contributor
      ]

      Note: Virtual Machine Contributor does NOT include snapshot or restorePointCollection
      permissions. Disk Snapshot Contributor does NOT include restorePointCollection permissions.
      For a custom role, add all permissions above explicitly.
      The Contributor built-in role covers all permissions listed.

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

# Default optional restore point config values
if (-not (Test-Path variable:useRestorePoints)) {
  $useRestorePoints = $false
}
if (-not (Test-Path variable:restorePointCollectionSuffix)) {
  $restorePointCollectionSuffix = 'rubrik-rpc'
}
if (-not (Test-Path variable:restorePointDaysToKeep)) {
  $restorePointDaysToKeep = 7
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
Write-Host "  Use Restore Points: $useRestorePoints (source disks: $($sourceDisks.Count))"
if ($useRestorePoints) {
  Write-Host "  Restore Point consistency: ApplicationConsistent"
  Write-Host "  Restore Point collection suffix: $restorePointCollectionSuffix"
  Write-Host "  Restore Point days to keep: $restorePointDaysToKeep"
}
Write-Host ""

if (-not $useRestorePoints -and $sourceDisks.Count -ge 2) {
  Write-Host "  RECOMMENDATION: $($sourceDisks.Count) source disks detected. Consider setting" -foregroundcolor yellow
  Write-Host "  useRestorePoints = `$true in the config file for cross-disk write-order" -foregroundcolor yellow
  Write-Host "  consistency via Azure VM Restore Points." -foregroundcolor yellow
  Write-Host ""
}

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
  $deletedCount = 0
  $keptCount = 0
  $groupedResources = @{}
  foreach ($disk in $SourceDisks) {
    $matchName = "${disk}-${NameSuffix}"
    $matched = $Resources | Where-Object { $_.Name -match $matchName }
    foreach ($resource in $matched) {
      if ($resource.Name -match '(\d{4}-\d{2}-\d{2}_\d{4})') {
        $dateKey = $matches[1]
        $dateStamp, $time = $dateKey -split '_'
        $time = $time.Insert(2, ':')
        $resourceDate = [datetime]::ParseExact("$dateStamp $time", 'yyyy-MM-dd HH:mm', $null)
        if (-not $groupedResources.ContainsKey($dateKey)) {
          $groupedResources[$dateKey] = @{ Date = $resourceDate; Items = @() }
        }
        $groupedResources[$dateKey].Items += @{ Name = $resource.Name; Date = $resourceDate }
      }
    }
  }
  foreach ($dateKey in ($groupedResources.Keys | Sort-Object)) {
    $group = $groupedResources[$dateKey]
    $resourceDate = $group.Date
    $expired = $resourceDate -lt $CutoffDate
    if ($expired) {
      Write-Host "  $dateKey (expired):" -foregroundcolor yellow
    } else {
      Write-Host "  $dateKey (keeping):" -foregroundcolor green
    }
    foreach ($item in $group.Items) {
      if ($expired) {
        Write-Host "    Deleting: $($item.Name)"
        try {
          if ($ResourceType -eq 'snapshot') {
            $result = Remove-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName $item.Name -Force -ErrorAction Stop
          } else {
            $result = Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $item.Name -Force -ErrorAction Stop
          }
          Write-Host "    Deletion result: $($result.Status)"
          $deletedCount++
        } catch {
          Write-Host "    WARNING: Failed to delete $($item.Name) - $($_.Exception.Message)" -foregroundcolor red
        }
      } else {
        Write-Host "    $($item.Name)"
        $keptCount++
      }
    }
  }
  Write-Host "${ResourceType} cleanup summary: $deletedCount deleted, $keptCount kept" -foregroundcolor green
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
  $apiPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$VMName/attachDetachDataDisks?api-version=2026-04-01"
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

  #### Restore Points - Source VM Validation ####
  if ($useRestorePoints) {
    $diskRestorePointMap = @{}
    $sourceVMId = $null
    foreach ($disk in $sourceDisks) {
      $diskInfo = Get-AzDisk -DiskName $disk -ResourceGroupName $sourceResourceGroup -ErrorAction Stop
      if (-not $diskInfo.ManagedBy) {
        Write-Error "Source disk '$disk' is not attached to any VM (ManagedBy is empty). All source disks must be attached to the same VM for Restore Points."
        exit 5
      }
      if ($null -eq $sourceVMId) {
        $sourceVMId = $diskInfo.ManagedBy
      } elseif ($diskInfo.ManagedBy -ne $sourceVMId) {
        Write-Error "Source disks belong to different VMs. Disk '$disk' is attached to '$($diskInfo.ManagedBy)' but expected '$sourceVMId'. All source disks must belong to the same VM."
        exit 5
      }
    }

    $sourceVMName = ($sourceVMId -split '/')[-1]
    Write-Host "Source VM for Restore Points: $sourceVMName" -foregroundcolor green
    Write-Host "  VM ARM ID: $sourceVMId"

    $restorePointCollectionName = "${sourceVMName}-${restorePointCollectionSuffix}"
    Write-Host "  Restore Point Collection: $restorePointCollectionName"

    $sourceVMResourceGroup = ($sourceVMId -split '/')[4]
    $vmInfo = Get-AzVM -ResourceGroupName $sourceVMResourceGroup -Name $sourceVMName -ErrorAction Stop
    $vmSize = $vmInfo.HardwareProfile.VmSize
    Write-Host "  VM Size: $vmSize"

    # ApplicationConsistent restore points require the Azure VM Agent
    $vmStatus = Get-AzVM -ResourceGroupName $sourceVMResourceGroup -Name $sourceVMName -Status -ErrorAction Stop
    $agentStatus = ($vmStatus.VMAgent.Statuses | Where-Object { $_.Code -like "ProvisioningState/*" }).DisplayStatus
    if ($agentStatus -eq 'Ready') {
      Write-Host "  VM Agent status: $agentStatus" -foregroundcolor green
    } else {
      Write-Error "Azure VM Agent is not ready (status: '$agentStatus'). ApplicationConsistent restore points require the VM Agent to be running. Check that the agent is installed and the VM can reach 168.63.129.16 on ports 80 and 32526."
      exit 8
    }
    $boostPattern = '(Dsv6|Ddsv6|Edsv6|Esv6|Dasv7|Dadsv7|Easv7|Eadsv7|Faldsv7|Falsv7)'
    if ($vmSize -match $boostPattern) {
      Write-Host ""
      Write-Host "  NOTE: VM size '$vmSize' uses Azure Boost. ApplicationConsistent mode" -foregroundcolor yellow
      Write-Host "  uses the Azure VM Agent to quiesce I/O before snapshotting, providing" -foregroundcolor yellow
      Write-Host "  consistency across all disks regardless of VM SKU." -foregroundcolor yellow
      Write-Host ""
    }

    $vmDataDisks = $vmInfo.StorageProfile.DataDisks
    foreach ($disk in $sourceDisks) {
      $vmDisk = $vmDataDisks | Where-Object { $_.Name -eq $disk }
      if ($vmDisk -and $vmDisk.Caching -eq 'ReadWrite') {
        Write-Host "  NOTE: Disk '$disk' has ReadWrite host caching. ApplicationConsistent mode" -foregroundcolor yellow
        Write-Host "  handles this via VM Agent quiescence." -foregroundcolor yellow
      }
    }

    $osDiskName = $vmInfo.StorageProfile.OsDisk.Name
    Write-Host ""
    Write-Host "  VM disk inventory:" -foregroundcolor green
    Write-Host "    OS disk: $osDiskName (always included)"
    $excludeDiskIds = @()
    foreach ($dataDisk in $vmDataDisks) {
      if ($sourceDisks -contains $dataDisk.Name) {
        Write-Host "    Data disk: $($dataDisk.Name) (LUN $($dataDisk.Lun)) - INCLUDED"
      } else {
        Write-Host "    Data disk: $($dataDisk.Name) (LUN $($dataDisk.Lun)) - EXCLUDED"
        $excludeDiskIds += $dataDisk.ManagedDisk.Id
      }
    }
    Write-Host "  Total disks on VM: $(1 + $vmDataDisks.Count) (1 OS + $($vmDataDisks.Count) data)"
    Write-Host "  Included in restore point: $(1 + $sourceDisks.Count) (1 OS + $($sourceDisks.Count) data)"
    Write-Host "  Excluded from restore point: $($excludeDiskIds.Count)"

    # Check Azure throttle limit: max 3 restore points per VM per hour
    try {
      $existingRpc = Get-AzRestorePointCollection -ResourceGroupName $sourceResourceGroup -Name $restorePointCollectionName -ErrorAction Stop
      # Construct ARM path manually (Get-AzRestorePointCollection .Id is null)
      $rpcArmId = "/subscriptions/$sourceSubscriptionId/resourceGroups/$sourceResourceGroup/providers/Microsoft.Compute/restorePointCollections/$restorePointCollectionName"
      $rpListUri = "${rpcArmId}/restorePoints?api-version=2026-04-01"
      $rpListResponse = Invoke-AzRestMethod -Path $rpListUri -Method GET
      $existingRPs = ($rpListResponse.Content | ConvertFrom-Json).value
      if ($existingRPs -and $existingRPs.Count -gt 0) {
        $oneHourAgo = (Get-Date).AddHours(-1)
        $recentRPs = foreach ($rp in $existingRPs) {
          if ($rp.name -match '(\d{4}-\d{2}-\d{2}_\d{4})') {
            $rpTime = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd_HHmm', $null)
            if ($rpTime -gt $oneHourAgo) {
              [PSCustomObject]@{ Name = $rp.name; Date = $rpTime }
            }
          }
        }
        $recentCount = @($recentRPs).Count
        if ($recentCount -ge 3) {
          $oldest = @($recentRPs) | Sort-Object Date | Select-Object -First 1
          $nextAllowed = $oldest.Date.AddHours(1)
          Write-Error "Azure limits restore points to 3 per VM per hour (HTTP 429 throttle). $recentCount created in the last hour: $((@($recentRPs) | ForEach-Object { $_.Name }) -join ', '). Next allowed at approximately: $nextAllowed"
          exit 7
        }
        Write-Host "  Restore points in last hour: $recentCount / 3" -foregroundcolor green
      }
    } catch {
      Write-Host "  No existing Restore Point Collection found (will be created)" -foregroundcolor green
    }
  }
}

#### Cleanup older snapshots and cloned Managed Disks ####

if ($executeAzureCleanup) {
  $stepStart = Get-Date
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Cleaning up older snapshots and cloned disks `n"
  $azCtx = Set-AzContext -subscription $sourceSubscriptionId -ErrorAction Stop
  Write-Host "Subscription context: $($azCtx.Subscription.Name) ($sourceSubscriptionId)"

  if ($useRestorePoints) {
    # Clean up old restore points (individual snapshots won't exist in restore point mode)
    $rpCutoff = $date.AddDays(-$restorePointDaysToKeep)
    Write-Host "Looking for and cleaning up restore points older than: $rpCutoff" -foregroundcolor green

    try {
      $rpc = Get-AzRestorePointCollection -ResourceGroupName $sourceResourceGroup -Name $restorePointCollectionName -ErrorAction Stop
    } catch {
      Write-Host "  Restore Point Collection '$restorePointCollectionName' not found, skipping cleanup"
      $rpc = $null
    }

    if ($rpc) {
      # Construct ARM path manually (Get-AzRestorePointCollection .Id is null)
      $rpcArmId = "/subscriptions/$sourceSubscriptionId/resourceGroups/$sourceResourceGroup/providers/Microsoft.Compute/restorePointCollections/$restorePointCollectionName"
      $rpListUri = "${rpcArmId}/restorePoints?api-version=2026-04-01"
      $rpListResponse = Invoke-AzRestMethod -Path $rpListUri -Method GET
      $rpList = ($rpListResponse.Content | ConvertFrom-Json).value

      $rpDeletedCount = 0
      $rpKeptCount = 0
      foreach ($rp in $rpList) {
        if ($rp.name -match '(\d{4}-\d{2}-\d{2}_\d{4})') {
          $rpDate = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd_HHmm', $null)
          if ($rpDate -lt $rpCutoff) {
            Write-Host "  Deleting restore point: $($rp.name) (created: $rpDate)"
            Remove-AzRestorePoint -ResourceGroupName $sourceResourceGroup `
              -RestorePointCollectionName $restorePointCollectionName `
              -Name $rp.name -ErrorAction Stop
            $rpDeletedCount++
          } else {
            Write-Host "  Keeping restore point: $($rp.name) (created: $rpDate)"
            $rpKeptCount++
          }
        }
      }
      Write-Host "Restore point cleanup summary: $rpDeletedCount deleted, $rpKeptCount kept" -foregroundcolor green
    }
  } else {
    # Clean up old individual snapshots (only when not using restore points)
    $snapCutoff = $date.AddDays(-$snapDaysToKeep)
    Write-Host "Looking for and cleaning up any snapshots older than: $snapCutoff" -foregroundcolor green
    $azSnapshots = Get-AzSnapshot -ResourceGroup $sourceResourceGroup -ErrorAction Stop
    Remove-ExpiredAzureResources -ResourceGroup $sourceResourceGroup -Resources $azSnapshots `
      -NameSuffix $sourceSnapshotSuffix -CutoffDate $snapCutoff -RetentionDays $snapDaysToKeep `
      -ResourceType 'snapshot' -SourceDisks $sourceDisks
  }

  # Clean up old cloned Managed Disks (always runs regardless of restore point mode)
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

if ($executeAzureSnapshot -and $useRestorePoints) {
  #### Create VM Restore Point (ApplicationConsistent, cross-disk consistency) ####
  $stepStart = Get-Date
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Creating VM Restore Point (ApplicationConsistent) `n"

  # Ensure Restore Point Collection exists
  $rpc = $null
  try {
    $rpc = Get-AzRestorePointCollection -ResourceGroupName $sourceResourceGroup -Name $restorePointCollectionName -ErrorAction Stop
    Write-Host "Using existing Restore Point Collection: $restorePointCollectionName" -foregroundcolor green
    if ($rpc.Source.Id -ne $sourceVMId) {
      Write-Error "Existing collection '$restorePointCollectionName' references VM '$($rpc.Source.Id)' but source disks belong to '$sourceVMId'"
      exit 6
    }
  } catch {
    Write-Host "Creating new Restore Point Collection: $restorePointCollectionName" -foregroundcolor green
    $rpcParams = @{
      ResourceGroupName = $sourceResourceGroup
      Name              = $restorePointCollectionName
      VmId              = $sourceVMId
      Location          = (Get-AzDisk -DiskName $sourceDisks[0] -ResourceGroupName $sourceResourceGroup).Location
    }
    if ($copyTagsFromSource) {
      $firstDiskInfo = Get-AzDisk -DiskName $sourceDisks[0] -ResourceGroupName $sourceResourceGroup
      if ($firstDiskInfo.Tags -and $firstDiskInfo.Tags.Count -gt 0) {
        $rpcParams.Tag = $firstDiskInfo.Tags
        Write-Host "  Applying $($firstDiskInfo.Tags.Count) tag(s) to collection"
      }
    }
    $rpc = New-AzRestorePointCollection @rpcParams -ErrorAction Stop
    Write-Host "  Collection created successfully"
  }

  $restorePointName = "rubrik-rp-${dateString}"
  Write-Host ""
  Write-Host "Creating ApplicationConsistent Restore Point: $restorePointName" -foregroundcolor green
  if ($excludeDiskIds.Count -gt 0) {
    Write-Host "  Excluding $($excludeDiskIds.Count) disk(s) not in source config"
  }

  $rpParams = @{
    ResourceGroupName          = $sourceResourceGroup
    RestorePointCollectionName = $restorePointCollectionName
    Name                       = $restorePointName
  }
  if ($excludeDiskIds.Count -gt 0) {
    $rpParams.DisksToExclude = $excludeDiskIds
  }

  # New-AzRestorePoint is synchronous - blocks until Azure responds with success or error
  Write-Host "Creating restore point (this call blocks until Azure completes)..." -foregroundcolor green

  try {
    $rpResult = New-AzRestorePoint @rpParams -ErrorAction Stop
  } catch {
    Send-EpicThawCommand
    $errMsg = $_.Exception.Message
    if ($errMsg -match '429' -or $errMsg -match 'throttle' -or $errMsg -match 'TooManyRequests' -or $errMsg -match 'RetryAfter') {
      Write-Error "Azure throttle limit hit (HTTP 429): max 3 restore points per VM per hour. Wait and retry. Details: $errMsg"
    } else {
      Write-Error "Failed to create restore point: $errMsg"
    }
    exit 10
  }

  Send-EpicThawCommand
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
  Write-Host "${currentTime}: Restore point '$restorePointName' created (ProvisioningState: $($rpResult.ProvisioningState))" -foregroundcolor green

  # Extract disk restore point IDs for managed disk creation
  $rpDetail = Get-AzRestorePoint -ResourceGroupName $sourceResourceGroup `
    -RestorePointCollectionName $restorePointCollectionName `
    -Name $restorePointName -InstanceView -ErrorAction Stop

  foreach ($dataDisk in $rpDetail.SourceMetadata.StorageProfile.DataDisks) {
    $diskName = $dataDisk.ManagedDisk.Id.Split('/')[-1]
    if ($sourceDisks -contains $diskName) {
      $diskRestorePointMap[$diskName] = $dataDisk.DiskRestorePoint.Id
      Write-Host "  Disk restore point for '$diskName': $($dataDisk.DiskRestorePoint.Id)"
    }
  }

  # Poll until disk restore points are ready for disk creation
  $drpPollSecs = 60
  Write-Host ""
  Write-Host "Waiting for disk restore points to be ready (polling every ${drpPollSecs}s)..." -foregroundcolor green
  $allDiskRPsReady = $false
  $drpPollIteration = 0
  $drpMaxPollIterations = 60
  $drpStartTime = Get-Date

  while (-not $allDiskRPsReady) {
    if ($drpPollIteration -ge $drpMaxPollIterations) {
      Write-Error "Disk restore points timed out after $([math]::Round($drpPollIteration * $drpPollSecs / 60)) minutes"
      exit 12
    }
    $drpPollIteration++
    $allReady = $true
    $rpCheck = Get-AzRestorePoint -ResourceGroupName $sourceResourceGroup `
      -RestorePointCollectionName $restorePointCollectionName `
      -Name $restorePointName -InstanceView -ErrorAction Stop

    $pendingDisks = @()
    $readyDisks = @()
    foreach ($dataDisk in $rpCheck.SourceMetadata.StorageProfile.DataDisks) {
      $diskName = $dataDisk.ManagedDisk.Id.Split('/')[-1]
      if ($sourceDisks -contains $diskName) {
        $drpId = $dataDisk.DiskRestorePoint.Id
        $drpUri = "${drpId}?api-version=2026-03-02"
        $drpResponse = Invoke-AzRestMethod -Path $drpUri -Method GET
        $drpJson = $drpResponse.Content | ConvertFrom-Json
        $drpProps = $drpJson.properties
        $completionPct = $drpProps.completionPercent
        $accessState = $drpProps.snapshotAccessState
        if ($completionPct -eq 100 -and $accessState -eq 'Available') {
          $readyDisks += $diskName
        } else {
          $allReady = $false
          $pendingDisks += @{ Name = $diskName; Pct = $completionPct; Access = $accessState }
        }
      }
    }

    $currentTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $elapsed = [math]::Round(((Get-Date) - $drpStartTime).TotalSeconds)
    if ($allReady) {
      Write-Host "${currentTime}: All disk restore points ready ($($readyDisks.Count) disks, ${elapsed}s elapsed)" -foregroundcolor green
      $allDiskRPsReady = $true
    } else {
      Write-Host "${currentTime}: Waiting for disk restore points (${elapsed}s elapsed, next poll in ${drpPollSecs}s)..."
      foreach ($pd in $pendingDisks) {
        Write-Host "  $($pd.Name): $($pd.Pct)% complete, access: $($pd.Access)"
      }
      Start-Sleep $drpPollSecs
    }
  }

  foreach ($disk in $sourceDisks) {
    $diskInfo = Get-AzDisk -DiskName $disk -ResourceGroupName $sourceResourceGroup -ErrorAction Stop
    $sourceDiskInfo[$disk] = $diskInfo
  }

  $stepElapsed = [math]::Round(((Get-Date) - $stepStart).TotalSeconds)
  Write-Host "Restore point creation completed in ${stepElapsed}s" -foregroundcolor green
} # if ($executeAzureSnapshot -and $useRestorePoints)

if ($executeAzureSnapshot -and -not $useRestorePoints) {
  #### Create individual snapshot of each source disk ####
  $stepStart = Get-Date
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $snapshotMode = if ($useInstantSnapshots) { "instant access" } else { "standard" }
  $emailBody += "${currentTime}: Creating snapshots ($snapshotMode) `n"
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
  $snapPollSecs = if ($useInstantSnapshots) { 10 } else { $statusCheckSecs }
  if ($useInstantSnapshots) {
    Write-Host "Waiting for $diskCount snapshot(s) to reach InstantAccess state (polling every ${snapPollSecs}s)..." -foregroundcolor green
    Write-Host "  Instant access snapshots are usable immediately once in InstantAccess state"
  } else {
    Write-Host "Waiting for $diskCount snapshot(s) to finish background copy (polling every ${snapPollSecs}s)..." -foregroundcolor green
    Write-Host "  Standard incremental snapshots require background copy to complete before disk creation"
  }
  Write-Host ""

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
} # if ($executeAzureSnapshot -and -not $useRestorePoints)

# When snapshot step is skipped, look up existing disk and snapshot/restore point info.
# Set $dateString at the top of the script to target a specific snapshot.
if ( $executeManagedDiskClone -and ($executeAzureSnapshot -eq $false) ) {
  if ($useRestorePoints) {
    $restorePointName = "rubrik-rp-${dateString}"
    Write-Host "Looking up existing restore point: $restorePointName" -foregroundcolor green
    $rpDetail = Get-AzRestorePoint -ResourceGroupName $sourceResourceGroup `
      -RestorePointCollectionName $restorePointCollectionName `
      -Name $restorePointName -InstanceView -ErrorAction Stop
    if (-not $rpDetail) {
      Write-Error "Restore point not found: $restorePointName (is dateString correct?)"
      exit 12
    }
    foreach ($dataDisk in $rpDetail.SourceMetadata.StorageProfile.DataDisks) {
      $diskName = $dataDisk.ManagedDisk.Id.Split('/')[-1]
      if ($sourceDisks -contains $diskName) {
        $diskRestorePointMap[$diskName] = $dataDisk.DiskRestorePoint.Id
      }
    }
    foreach ($disk in $sourceDisks) {
      $sourceDiskInfo[$disk] = Get-AzDisk -DiskName $disk -ResourceGroupName $sourceResourceGroup -ErrorAction Stop
    }
  } else {
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

#### Create a Managed Disk from the snapshot or disk restore point ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-powershell-sample-create-managed-disk-from-snapshot
# https://learn.microsoft.com/en-us/powershell/module/az.compute/new-azdiskconfig

if ($executeManagedDiskClone) {
  $stepStart = Get-Date
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  if ($useRestorePoints) {
    $emailBody += "${currentTime}: Creating cloned Managed Disks from disk restore points `n"
    Write-Host ""
    Write-Host "Creating Managed Disks from disk restore points (CreateOption: Restore)..." -foregroundcolor green
  } else {
    $snapshotMode = if ($useInstantSnapshots) { "instant access" } else { "standard" }
    $emailBody += "${currentTime}: Creating cloned Managed Disks from snapshots ($snapshotMode) `n"
    Write-Host ""
    if ($useInstantSnapshots) {
      Write-Host "Creating Managed Disks from instant access snapshots (disks are usable immediately after creation)..." -foregroundcolor green
    } else {
      Write-Host "Creating Managed Disks from incremental snapshots (background copy required before use)..." -foregroundcolor green
    }
  }
  foreach ($disk in $sourceDisks) {
    $targetDiskName = $sourceDiskToTargetDisk[$disk]
    $diskInfo = $sourceDiskInfo[$disk]
    Write-Host ""
    Write-Host "Building disk config for source disk: $disk" -foregroundcolor green
    Write-Host "  Target disk name: $targetDiskName"
    if ($useRestorePoints) {
      $drpName = $diskRestorePointMap[$disk].Split('/')[-1]
      Write-Host "  Source: disk restore point (CreateOption: Restore)"
      Write-Host "  Disk restore point: $drpName"
      $diskConfigParameters = @{
        CreateOption      = "Restore"
        SourceResourceId  = $diskRestorePointMap[$disk]
        DiskSizeGB        = $diskInfo.DiskSizeGB
        SkuName           = $diskInfo.sku.name
        Zone              = $diskInfo.zones[0]
        Location          = $diskInfo.location
        DiskIOPSReadWrite = $diskIOPSReadWrite
        DiskIOPSReadOnly  = $diskIOPSReadOnly
        DiskMBpsReadWrite = $diskMBpsReadWrite
        DiskMBpsReadOnly  = $diskMBpsReadOnly
      }
    } else {
      $snapshotName = $sourceDiskToSnapshot[$disk]
      $snapshotInfo = $sourceSnapshotInfo[$snapshotName]
      Write-Host "  Source snapshot: $snapshotName"
      $diskConfigParameters = @{
        CreateOption      = "Copy"
        SourceResourceId  = $snapshotInfo.Id
        DiskSizeGB        = $diskInfo.DiskSizeGB
        SkuName           = $diskInfo.sku.name
        Zone              = $diskInfo.zones[0]
        Location          = $diskInfo.location
        DiskIOPSReadWrite = $diskIOPSReadWrite
        DiskIOPSReadOnly  = $diskIOPSReadOnly
        DiskMBpsReadWrite = $diskMBpsReadWrite
        DiskMBpsReadOnly  = $diskMBpsReadOnly
      }
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

  if ($useInstantSnapshots -and -not $useRestorePoints) {
    # With instant access snapshots, the disk is backed by the instant access snapshot data.
    # Reads to any region are served directly from the snapshot, so the disk is usable
    # immediately after ProvisioningState = Succeeded. No need to wait for background copy.
    Write-Host ""
    Write-Host "All $diskCount Managed Disk(s) created from instant access snapshots" -foregroundcolor green
    Write-Host "  Skipping background copy wait - disks are immediately usable (reads served from instant access snapshot)" -foregroundcolor green
  } else {
    Write-Host ""
    $diskPollSecs = $statusCheckSecs
    $sourceLabel = if ($useRestorePoints) { "disk restore points" } else { "incremental snapshots" }
    Write-Host "Waiting for $diskCount Managed Disk(s) to finish background copy (polling every ${diskPollSecs}s)..." -foregroundcolor green
    Write-Host "  Managed Disks created from $sourceLabel require the background copy to complete before the disk can be attached"
    Write-Host ""

    # Poll until all cloned disks finish background copy (standard snapshots and restore points)
    $diskComplete = @{}
    $pollIteration = 0
    $maxPollIterations = 120
    $diskCopyStartTime = Get-Date

    while ($diskComplete.count -lt $diskCount) {
      if ($pollIteration -ge $maxPollIterations) {
        Write-Error "Managed Disk background copy timed out after $([math]::Round($pollIteration * $diskPollSecs / 60)) minutes, exiting..."
        exit 21
      }
      $pollIteration++
      $currentTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
      $elapsed = [math]::Round(((Get-Date) - $diskCopyStartTime).TotalSeconds)
      $pendingCopyDisks = @()
      foreach ($disk in $sourceDisks) {
        if ($diskComplete.ContainsKey($disk)) { continue }
        $targetDiskName = $sourceDiskToTargetDisk[$disk]
        $diskInfo = Get-AzDisk -DiskName $targetDiskName -ResourceGroupName $targetResourceGroup
        if ($diskInfo.CompletionPercent -lt 100) {
          $pendingCopyDisks += @{ Name = $diskInfo.name; Pct = $diskInfo.CompletionPercent }
        } else {
          Write-Host "${currentTime}: Disk copy complete: $($diskInfo.name) (100%)" -foregroundcolor green
          $diskComplete.$disk = $true
        }
      }
      if ($diskComplete.count -lt $diskCount) {
        Write-Host "${currentTime}: Waiting for disk background copy (${elapsed}s elapsed, next poll in ${diskPollSecs}s)..."
        foreach ($pd in $pendingCopyDisks) {
          Write-Host "  $($pd.Name): $($pd.Pct)% complete"
        }
        Start-Sleep $diskPollSecs
      }
    } # while disk copy polling
    $diskCopyElapsed = [math]::Round(((Get-Date) - $diskCopyStartTime).TotalSeconds)
    Write-Host "All $diskCount Managed Disk(s) have finished background copy (${diskCopyElapsed}s elapsed)" -foregroundcolor green
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
  Write-Host "Block devices before unmount (lsblk):"
  lsblk
  Write-Host ""
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
  Write-Host "Sleeping 60s after unmount..." -foregroundcolor yellow
  Start-Sleep -Seconds 60
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
  # Clean up stale SCSI device nodes from detached disks
  Write-Host ""
  Write-Host "Rescanning SCSI hosts to clean up detached disk nodes..." -foregroundcolor green
  bash -c 'for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$host"; done'
  Write-Host "Waiting for device nodes to settle..."
  udevadm settle
  Write-Host ""
  Write-Host "Block devices after detach cleanup (lsblk):"
  lsblk
  Write-Host ""
  Write-Host "Sleeping 60s after detach..." -foregroundcolor yellow
  Start-Sleep -Seconds 60
  Write-Host ""
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
  Write-Host "Sleeping 60s after disk attach..." -foregroundcolor yellow
  Start-Sleep -Seconds 60
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
  Write-Host "Running vgscan --mknodes..."
  vgscan --mknodes 2>$null
  Write-Host ""
  $mountCount = $MOUNT_LIST.count
  for ($mount = 0; $mount -lt $mountCount; $mount++) {
    $vg_name = $VG_LIST[$mount]
    $lv_name = $LV_LIST[$mount]
    $path = $MOUNT_LIST[$mount]
    $devPath = $DEVMAPPER_LIST[$mount]
    $dmName = "${vg_name}-${lv_name}"
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
    Write-Host "  Waiting for device nodes to settle..."
    udevadm settle
    Write-Host "  Sleeping 60s after VG activation..." -foregroundcolor yellow
    Start-Sleep -Seconds 60
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
    Write-Host "  Sleeping 60s after mount..." -foregroundcolor yellow
    Start-Sleep -Seconds 60
    Write-Host ""
    Write-Host "Block devices after mount (lsblk):"
    lsblk
    Write-Host ""
    # Check if the dev-mapper device is still visible after mount
    $lsblkOutput = lsblk -l -o NAME 2>$null
    if (-not ($lsblkOutput | Where-Object { $_ -match $dmName })) {
      Write-Host "  WARNING: $dmName disappeared after mount, waiting 30s and retrying..." -foregroundcolor yellow
      umount ${MOUNT_BASE}${path} 2>$null
      Start-Sleep -Seconds 30
      Write-Host "  Retrying vgchange -an $vg_name..."
      vgchange -an $vg_name 2>$null
      Write-Host "  Retrying vgchange -ay $vg_name..."
      vgchange -ay $vg_name
      udevadm settle
      Write-Host ""
      Write-Host "Block devices after retry (lsblk):"
      lsblk
      Write-Host ""
      Write-Host "  Retrying mount $devPath to ${MOUNT_BASE}${path}..."
      mount $devPath ${MOUNT_BASE}${path}
      if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to mount $devPath on retry (exit code: $LASTEXITCODE), exiting..."
        exit 64
      }
      Write-Host "  Successfully mounted on retry" -foregroundcolor green
      Write-Host ""
      Write-Host "Block devices after retry mount (lsblk):"
      lsblk
    }
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
$snapshotModeLabel = if ($useRestorePoints) { "Restore Points (ApplicationConsistent)" } elseif ($useInstantSnapshots) { "Instant Access" } else { "Standard" }
$emailBody += "Completed in $elapsedMins minutes | Snapshot mode: $snapshotModeLabel | Disks: $($sourceDisks.count) `n`n"
$emailBody += Get-Content -Path $logPath -Raw
$emailBodyHtml = "<pre>$emailBody</pre>"

if ($sendMail) {
  Send-MailMessage -From $emailFrom -To $emailTo -Subject "$emailSubject ($snapshotModeLabel)" -Body $emailBodyHtml -SmtpServer $SMTPServer -BodyAsHtml $true
}

exit 0
