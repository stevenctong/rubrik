<#
.SYNOPSIS
The 'Calc-Backups.ps1' script splits out the backup jobs for each object in a Protection Task Details report.

.DESCRIPTION
The 'Calc-Backups.ps1' script splits out the backup jobs for each object in a Protection Task Details report.
You can generate a report with many days and this will split out each object with the following columns:
- Name
- Logical (GB)
- [$day] Date
- [$day] Data Trans (GB)
- [$day] Data Stored (GB)

The number of days to break out can be set with the $calcDays variable.

The default sort is oldest backup first which can be changed by setting: "-desc $true"

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/8/21

.EXAMPLE
./Calc-Backups.ps1 -file <prot_task_details.csv> -output <results.csv>
Run the script passing in a file and specifying the output filename.

.EXAMPLE
./Calc-Backups.ps1 -file <prot_task_details.csv> -output <results.csv> -desc $true
Run the script passing in a file and specifying the output filename with the latest backup date first.

#>

param (
  [CmdletBinding()]

  # Input filename to calculate backups using a Rubrik Protection Task Details report
  [Parameter(Mandatory=$true)]
  [string]$file = '',

  # CSV file to output the results to
  [Parameter(Mandatory=$true)]
  [string]$output = '',

  # Set to true to pull the most recent backups first
  [Parameter(Mandatory=$false)]
  [bool]$desc = $false,

  # Number of days to break out the individual backups for
  [Parameter(Mandatory=$false)]
  [int]$calcDays = 3,

  # Set to $true to group the columns by category instead of date
  [Parameter(Mandatory=$false)]
  [bool]$group = $false
)

# Default sort order is oldest backups first, checks if user wants newest backups first and import the report
if ($desc -ne $true)
{
  $jobs = Import-CSV -path $file | Sort-Object -Property 'Hour'
} else {
  $jobs = Import-CSV -path $file | Sort-Object -Property 'Hour' -Descending
}

# Total number of rows to process from the report
$jobsCount = $jobs.count
$count = 0

# Each object name will be a key in a hash table
# Value will be hash table containing the backup job details for that object
$jobHash = @{}

# Iterate through each job in the Protection Job Report to pull out object details
foreach ($job in $jobs) {
  $count += 1
  Write-Host "Processing [ $count / $jobsCount ] : $($job.'Object Name')"

  # If the object key doesn't exist, then create it along with initial details of the object
  if ($jobHash.containsKey($job.'Object Name') -eq $false)
  {
    $jobHash.($job.'Object Name') = @{}
    $jobHash.($job.'Object Name').'Name' = $job.'Object Name'
    $jobHash.($job.'Object Name').'Object ID' = $job.'Object ID'
    $jobHash.($job.'Object Name').'Logical (GB)' = $([float]($job.'Logical Data Protected (B)') / 1000000000)
    $jobHash.($job.'Object Name').'[1] Date' = $job.'Hour'
    $jobHash.($job.'Object Name').'[1] Data Trans (GB)' = $([float]$job.'Data Transferred (B)' / 1000000000)
    $jobHash.($job.'Object Name').'[1] Data Stored (GB)' = $([float]$job.'Data Stored (B)' / 1000000000)
  } else
  {
    # Each object's value has 2 initial values (Name, Logical (GB)) while adding 3 more
    # Divide by 3 to calculate which job # we are adding
    $num = [math]::ceiling($jobHash.($job.'Object Name').count / 3)

    $jobHash.($job.'Object Name')."[$num] Date" = $job.'Hour'
    $jobHash.($job.'Object Name')."[$num] Data Trans (GB)" = $([float]$job.'Data Transferred (B)' / 1000000000)
    $jobHash.($job.'Object Name')."[$num] Data Stored (GB)" = $([float]$job.'Data Stored (B)' / 1000000000)
  }
}

# Holds final list of objects along with their corresponding backup jobs we want
$objList = @()

# Total number of objects to process
$objCount = $jobHash.count
$count = 0

# Iterate through the hash table that has key for each object, along with backup details
foreach ($i in $jobHash.getEnumerator())
{
  $count += 1
  Write-Host "Processing [ $count / $objCount ] : $($i.Value.Name)"

  # Create initial object details
  $obj = [PSCustomObject] @{
      "Name" = $i.value.Name
      "Logical (GB)" = [math]::round($i.value.'Logical (GB)', 3)
  }

  # If default grouping is by date, loop through each date and put the columns together
  if ($group -eq $false)
  {
    # For each date we want to pull, add the backup details to the object
    $day = 0
    while ($day -lt $calcDays)
    {
        $day += 1
        $obj | Add-Member -MemberType NoteProperty -Name "[$day] Date" -Value $i.value."[$day] Date"
        $obj | Add-Member -MemberType NoteProperty -Name "[$day] Data Trans (GB)" -Value ([math]::round($i.value."[$day] Data Trans (GB)", 3))
        $obj | Add-Member -MemberType NoteProperty -Name "[$day] Data Stored (GB)" -Value ([math]::round($i.value."[$day] Data Stored (GB)", 3))
    }
    $objList += $obj
  # Otherwise, only add a single column each time we loop through date
  } else {
    # For each date we want to pull, add a single column
    $day = 0
    while ($day -lt $calcDays)
    {
      $day += 1
      $obj | Add-Member -MemberType NoteProperty -Name "[$day] Data Trans (GB)" -Value ([math]::round($i.value."[$day] Data Trans (GB)", 3))
    }
    # For each date we want to pull, add a single column
    $day = 0
    while ($day -lt $calcDays)
    {
      $day += 1
      $obj | Add-Member -MemberType NoteProperty -Name "[$day] Data Stored (GB)" -Value ([math]::round($i.value."[$day] Data Stored (GB)", 3))
    }
    # For each date we want to pull, add a single column
    $day = 0
    while ($day -lt $calcDays)
    {
      $day += 1
      $obj | Add-Member -MemberType NoteProperty -Name "[$day] Date" -Value $i.value."[$day] Date"
    }
    $objList += $obj
  }
}

$objList | Export-CSV -path $output
Write-Host "Results output to: $output" -foregroundcolor green
