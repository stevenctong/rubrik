#requires -Modules Az.Accounts, Az.Compute, Az.Sql

<#
.SYNOPSIS
Gets all Azure VM Managed Disk and/or Azure SQL info in the specified subscription(s).

.DESCRIPTION
The 'Get-AzureVMSQLInfo.ps1' script gets all VM Managed Disk and/or Azure SQL info in the specified subscription(s).
You can specify one or more subscription to run the script against, or against all subscriptions.
If no subscription is specified then it will gather info against the current subscription context.

If you need to get detailed disk info, there is a flag to do so.

This script requires the Azure Powershell module. That module can be installed by running  `Install-Module Az`
If not already done use the `Connect-AzAccount` command to connect to a specific Azure Tenant to report on.

The script gathers all Azure VMs and associated Managed Disk information.
The script also gathers all Azure SQL DB (independent), Elastic Pool, and Managed Instance size information.

For SQL, the script will gather the Max Size for each SQL DB that is provisioned on an Azure SQL server.
If a SQL DB is in an Elastic Pool, then the script will gather the Elastic Pool Max Size.
If a SQL DB is on a Managed Instance, then the script will gather the Managed Instance Max Size.

A summary of the total # of VMs, Disks, and SQL capacity information will be output to console.
A CSV file will be exported with the details.
Please copy/paste the console output to send along with the CSV.

Update the subscription list ($subscriptions) as needed or pass it in as an argument.

Run in Azure CloudShell or Azure PowerShell connected to your subscription.
See: https://docs.microsoft.com/en-us/azure/cloud-shell/overview

.PARAMETER Subscriptions
A comma separated list of subscriptions to gather data from.

.PARAMETER AllSubscriptions
Flag to find all subscriptions in the tenant and download data.

.PARAMETER CurrentSubscription
Flog to only gather information from the current subscription.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 2/19/22
Updated: 12/8/22

.EXAMPLE
./Get-AzureVMSQLInfo.ps1
Runs the script against the current subscription context.

.EXAMPLE
./Get-AzureVMSQLInfo.ps1 -Subscriptions "sub1,sub2"
Runs the script against subscriptions 'sub1' and 'sub2'.

.EXAMPLE
./Get-AzureVMSQLInfo.ps1 -AllSubscriptions
Runs the script against all subscriptions in the tenant.

.EXAMPLE
./Get-AzureVMSQLInfo.ps1 -DiskDetails
Get info on each disk, one per row, instead of summarized per VM.

.LINK
https://build.rubrik.com
https://github.com/rubrikinc
https://github.com/stevenctong/rubrik


#>

param (
  [CmdletBinding()]

  # User can provide a comma separated list of subscriptions to gather info on
  [string]$Subscriptions = '',

  # Flag to get info on all subscriptions
  [Parameter(Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [switch]$AllSubscriptions,

  # Flag to get all disk details output per row
  [Parameter(Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [switch]$DiskDetails
)

Import-Module Az.Accounts, Az.Compute, Az.Sql

$azConfig = Get-AzConfig -DisplayBreakingChangeWarning
Update-AzConfig -DisplayBreakingChangeWarning $false | Out-Null

$date = Get-Date

# Filenames of the CSVs to output
$outputVmDisk = "azure_vmdisk_info-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
$outputSQL = "azure_sql_info-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

Write-Host "Current identity:" -foregroundcolor green
$context = Get-AzContext
$context | Select-Object -Property Account,Environment,Tenant |  format-table

# Contains list of VMs and SQL DBs with capacity info
$vmList = @()
$sqlList = @()

$vmCount = 0
$diskCount = 0

# If no subscription is specified, only use the current subscription
if ($AllSubscriptions -eq $true) {
  $subs =  $(Get-AzContext -ListAvailable).subscription.name
}
elseif ( $subscriptions -eq '' ) {
  $subs = $context.subscription.name
}
else {
  [string[]]$subs = $subscriptions.split(',')
}

# Get Azure info for all specified subscriptions
foreach ($sub in $subs) {
  Write-Host "Getting VM info for subscription: $sub" -foregroundcolor green

  $setContext = Set-AzContext -SubscriptionName $sub
  if ($null -eq $setContext)
  {
    Write-Error "Error switching to subscription: $sub"
    break
  }

  # Get a list of all VMs in the current subscription
  $vms = Get-AzVM
  $vmCount += $vms.count

  # Summarize VM details if we don't want disk details
  if ($diskDetails -eq $false)
  {
    # Loop through each VM to get all disk info
    foreach ($vm in $vms)
    {
      # Count of and size of all disks attached to the VM
      $diskNum = 0
      $diskSizeGiB = 0
      # Loop through each OS disk on the VM and add to the disk info
      foreach ($osDisk in $vm.StorageProfile.osdisk)
      {
        $diskCount += 1
        $diskNum += 1
        $diskSizeGiB += [int]$osDisk.DiskSizeGB
      }
      # Loop through each data disk on the VM and add to the disk info
      foreach ($dataDisk in $vm.StorageProfile.dataDisks)
      {
        $diskCount += 1
        $diskNum += 1
        $diskSizeGiB += [int]$dataDisk.DiskSizeGB
      }
      $vmObj = [PSCustomObject] @{
        "Name" = $vm.name
        "Disks" = $diskNum
        "SizeGiB" = $diskSizeGiB
        "SizeGB" = [math]::round($($diskSizeGiB * 1.073741824), 3)
        "Subscription" = $sub
        "Region" = $vm.Location
        "ResourceGroup" = $vm.ResourceGroupName
        "vmID" = $vm.vmID
        "InstanceType" = $vm.HardwareProfile.vmSize
        "Status" = $vm.StatusCode
      }
      $vmList += $vmObj
    }
  } else  # Get disk details, output per row
  {
    # Loop through each VM to get all disk info
    foreach ($vm in $vms)
    {
      # Loop through each OS disk on the VM and add to the disk info
      foreach ($osDisk in $vm.StorageProfile.osdisk)
      {
        $diskCount += 1
        $diskSizeGiB = [int]$osDisk.DiskSizeGB

        $vmObj = [PSCustomObject] @{
          "Name" = $vm.name
          "SizeGiB" = $diskSizeGiB
          "SizeGB" = [math]::round($($diskSizeGiB * 1.073741824), 3)
          "diskID" = $osDisk.ManagedDisk.id
          "Subscription" = $sub
          "Region" = $vm.Location
          "ResourceGroup" = $vm.ResourceGroupName
          "vmID" = $vm.vmID
          "InstanceType" = $vm.HardwareProfile.vmSize
          "Status" = $vm.StatusCode
        }
        $vmList += $vmObj
      }
      # Loop through each data disk on the VM and add to the disk info
      foreach ($dataDisk in $vm.StorageProfile.dataDisks)
      {
        $diskCount += 1
        $diskSizeGiB += [int]$dataDisk.DiskSizeGB

        $vmObj = [PSCustomObject] @{
          "Name" = $vm.name
          "Disks" = $diskNum
          "SizeGiB" = $diskSizeGiB
          "SizeGB" = [math]::round($($diskSizeGiB * 1.073741824), 3)
          "diskID" = $dataDisk.ManagedDisk.id
          "Subscription" = $sub
          "Region" = $vm.Location
          "ResourceGroup" = $vm.ResourceGroupName
          "vmID" = $vm.vmID
          "InstanceType" = $vm.HardwareProfile.vmSize
          "Status" = $vm.StatusCode
        }
        $vmList += $vmObj
      }
    }
  }

  # Get all Azure SQL servers
  $sqlServers = Get-AzSqlServer

  # Loop through each SQL server to get size info
  foreach ($sqlServer in $sqlServers)
  {
    # Get all SQL DBs on the current SQL server
    $sqlDBs = Get-AzSqlDatabase -serverName $sqlServer.ServerName -ResourceGroupName $sqlServer.ResourceGroupName
    # Loop through each SQL DB on the current SQL server to gather size info
    foreach ($sqlDB in $sqlDBs)
    {
      # Only count SQL DBs that are not SYSTEM DBs
      if ($sqlDB.SkuName -ne 'System')
      {
        # If SQL DB is in an Elastic Pool, count the max capacity of Elastic Pool and not the DB
        if ($sqlDB.SkuName -eq 'ElasticPool')
        {
          # Get Elastic Pool info for the current DB
          $pool = Get-AzSqlElasticPool -servername $sqlDB.ServerName -ResourceGroupName $sqlDB.ResourceGroupName
          # Check if the current Elastic Pool already exists in the SQL list
          $poolName = $sqlList | Where-Object -Property 'ElasticPool' -eq $pool.ElasticPoolName
          # If Elastic Pool does not exist then add it
          if ($null -eq $poolName)
          {
            $sqlObj = [PSCustomObject] @{
              "Database" = ""
              "Server" = ""
              "ElasticPool" = $pool.ElasticPoolName
              "ManagedInstance" = ""
              "MaxSizeGiB" = [math]::round($($pool.MaxSizeBytes / 1073741824), 0)
              "MaxSizeGB" = [math]::round($($pool.MaxSizeBytes / 1000000000), 3)
              "Subscription" = $sub
              "Region" = $pool.Location
              "ResourceGroup" = $pool.ResourceGroupName
              "DatabaseID" = ""
              "InstanceType" = $pool.SkuName
              "Status" = $pool.Status
            }
            $sqlList += $sqlObj
          }
        } else {
          $sqlObj = [PSCustomObject] @{
            "Database" = $sqlDB.DatabaseName
            "Server" = $sqlDB.ServerName
            "ElasticPool" = ""
            "ManagedInstance" = ""
            "MaxSizeGiB" = [math]::round($($sqlDB.MaxSizeBytes / 1073741824), 0)
            "MaxSizeGB" = [math]::round($($sqlDB.MaxSizeBytes / 1000000000), 3)
            "Subscription" = $sub
            "Region" = $sqlDB.Location
            "ResourceGroup" = $sqlDB.ResourceGroupName
            "DatabaseID" = $sqlDB.DatabaseId
            "InstanceType" = $sqlDB.SkuName
            "Status" = $sqlDB.Status
          }
          $sqlList += $sqlObj
        }  # else not an Elastic Pool but normal SQL DB
      }  # if ($sqlDB.SkuName -ne 'System')
    }  # foreach ($sqlDB in $sqlDBs)
  }  # foreach ($sqlServer in $sqlServers)

  # Get all Azure Managed Instances
  $sqlManagedInstances = Get-AzSqlInstance

  # Loop through each SQL Managed Instances to get size info
  foreach ($MI in $sqlManagedInstances)
  {
    $sqlObj = [PSCustomObject] @{
      "Database" = ""
      "Server" = ""
      "ElasticPool" = ""
      "ManagedInstance" = $MI.ManagedInstanceName
      "MaxSizeGiB" = $MI.StorageSizeInGB
      "MaxSizeGB" = [math]::round($($MI.StorageSizeInGB * 1.073741824), 3)
      "Subscription" = $sub
      "Region" = $MI.Location
      "ResourceGroup" = $MI.ResourceGroupName
      "DatabaseID" = ""
      "InstanceType" = $MI.Sku.Name
      "Status" = $MI.Status
    }
    $sqlList += $sqlObj
  }  # foreach ($MI in $sqlManagedInstances)
}  # foreach ($sub in $subs) {

# Reset subscription context back to original.
$setContext = Set-AzContext -SubscriptionName $context.subscription.Name | Out-Null

$VMtotalGiB = ($vmList.SizeGiB | Measure-Object -Sum).sum
$VMtotalGB = ($vmList.SizeGB | Measure-Object -Sum).sum

$sqlTotalGiB = ($sqlList.MaxSizeGiB | Measure-Object -Sum).sum
$sqlTotalGB = ($sqlList.MaxSizeGB | Measure-Object -Sum).sum
$DBtotalGiB = (($sqlList | Where-Object -Property 'Database' -ne '').MaxSizeGiB | Measure-Object -Sum).sum
$DBtotalGB = (($sqlList | Where-Object -Property 'Database' -ne '').MaxSizeGB | Measure-Object -Sum).sum
$elasticTotalGiB = (($sqlList | Where-Object -Property 'ElasticPool' -ne '').MaxSizeGiB | Measure-Object -Sum).sum
$elasticTotalGB = (($sqlList | Where-Object -Property 'ElasticPool' -ne '').MaxSizeGB | Measure-Object -Sum).sum
$MITotalGiB = (($sqlList | Where-Object -Property 'ManagedInstance' -ne '').MaxSizeGiB | Measure-Object -Sum).sum
$MITotalGB = (($sqlList | Where-Object -Property 'ManagedInstance' -ne '').MaxSizeGB | Measure-Object -Sum).sum

Write-Host
Write-Host "Total # of Azure VMs: $vmCount" -foregroundcolor green
Write-Host "Total # of Managed Disks: $diskCount" -foregroundcolor green
Write-Host "Total capacity of all disks: $VMtotalGiB GiB or $VMtotalGB GB" -foregroundcolor green

Write-Host
if ($sqlList.count -eq 0)
{
  Write-Host "No Azure SQL DBs, ElasticPools, or Managed Instances found" -foregroundcolor green
} else
{
  Write-Host "Total # of SQL DBs (independent): $(($sqlList.Database -ne '').count)" -foregroundcolor green
  Write-Host "Total # of SQL Elastic Pools: $(($sqlList.ElasticPool -ne '').count)" -foregroundcolor green
  Write-Host "Total # of SQL Managed Instances: $(($sqlList.ManagedInstance -ne '').count)" -foregroundcolor green
  Write-Host "Total capacity of all SQL DBs (independent): $DBtotalGiB GiB or $DBtotalGB GB" -foregroundcolor green
  Write-Host "Total capacity of all SQL Elastic Pools: $elasticTotalGiB GiB or $elasticTotalGB GB" -foregroundcolor green
  Write-Host "Total capacity of all SQL Managed Instances: $MITotalGiB GiB or $MITotalGB GB" -foregroundcolor green

  Write-Host
  Write-Host "Total # of SQL DBs, Elastic Pools & Managed Instances: $($sqlList.count)" -foregroundcolor green
  Write-Host "Total capacity of all SQL: $sqlTotalGiB GiB or $sqlTotalGB GB" -foregroundcolor green
}

# Export to CSV
Write-Host ""
Write-Host "VM CSV file output to: $outputVmDisk" -foregroundcolor green
$vmList | Export-CSV -path $outputVmDisk
Write-Host "SQL CSV file output to: $outputSQL" -foregroundcolor green
$sqlList | Export-CSV -path $outputSQL

if ($azConfig.Value -eq $true) {
  Update-AzConfig -DisplayBreakingChangeWarning $true  | Out-Null
}
