<#
.SYNOPSIS
This script will process a Protection Task Detail report and pull the first
backup as the 'first full' and average out all subsequent backups as incrementals.

.DESCRIPTION
This script will process a Protection Task Detail report and pull the first
backup as the 'first full' and average out all subsequent backups as incrementals.

Feed in a Protection Task Detail report CSV with the following columns:
1. Time Range - enough to cover the first full
2. Object Name
3. Object Type
4. Start Time
5. Duration
6. Data Transferred
7. Data Stored

Note: Throughput (MB/s) is not calculated for Incrementals because it is not valid.
      Small changes take more time to setup the backup job than to complete the transfer.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/1/25

.EXAMPLE
./Process-Protection_Task_Report.ps1 -csvInput <prot_task_detail_report.csv>
Runs the script to process the stats and outputs it to a file
#>

param (
  [CmdletBinding()]
  # CSV to process
  [Parameter(Mandatory=$false)]
  [string]$csvInput = ''
)

$date = Get-Date
$csvOutput = "./rubrik_prot_summary-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

$tasks = Import-CSV -Path $csvInput
$tasks = $tasks | Where { $_.'Task Status' -match 'Succeed' }
$tasks = $tasks | Sort-Object -Property 'Object Name', 'Start Time'

$taskHash = @{}

foreach ($task in $tasks) {
  $key = $task.'Object Name'
  if (-not $taskHash.ContainsKey($key)) {
    $taskDetail = [PSCustomObject] @{
      "Object Name" = $task.'Object Name'
      "Object Type" = $task.'Object Type'
      "First Full Start" = $task.'Start Time'
      "First Full Duration (Min)" = [Math]::Round($($task.Duration / 60), 2)
      "First Full Data Trans (GB)" = [Math]::Round($($task.'Data Transferred' / 1000000000), 2)
      "First Full Data Stored (GB)" = [Math]::Round($($task.'Data Stored' / 1000000000), 2)
      "First Full Throughput (MB/s)" = [Math]::Round($(($task.'Data Transferred' / 1000000) / $task.Duration), 2)
      "Inc Num Of" = 0
      "Inc Avg Duration (Min)" = 0
      "Inc Avg Data Trans (GB)" = 0
      "Inc Avg Data Stored (GB)" = 0
      "Inc Total Duration (Min)" = 0
      "Inc Total Data Trans (GB)" = 0
      "Inc Total Data Stored (GB)" = 0
    }
    $taskHash[$key] = $taskDetail
  } else {
    $taskHash[$key].'Inc Num Of' += 1
    $taskHash[$key].'Inc Total Duration (Min)' += [Math]::Round($($task.Duration / 60), 2)
    $taskHash[$key].'Inc Total Data Trans (GB)' += [Math]::Round($($task.'Data Transferred' / 1000000000), 2)
    $taskHash[$key].'Inc Total Data Stored (GB)' += [Math]::Round($($task.'Data Stored' / 1000000000), 2)
    $taskHash[$key].'Inc Avg Duration (Min)' =
      [Math]::Round($($taskHash[$key].'Inc Total Duration (Min)' / $taskHash[$key].'Inc Num Of'), 2)
    $taskHash[$key].'Inc Avg Data Trans (GB)' =
      [Math]::Round($($taskHash[$key].'Inc Total Data Trans (GB)' / $taskHash[$key].'Inc Num Of'), 2)
    $taskHash[$key].'Inc Avg Data Stored (GB)' =
      [Math]::Round($($taskHash[$key].'Inc Total Data Stored (GB)' / $taskHash[$key].'Inc Num Of'), 2)
  }
}

$taskArray = @()

foreach ($key in $taskHash.Keys) {
  $taskArray += $taskHash[$key]
}

$taskArray | Export-CSV -Path $csvOutput -NoTypeInformation
Write-Host "CSV for $csvInput output to $csvOutput" -foregroundcolor green
