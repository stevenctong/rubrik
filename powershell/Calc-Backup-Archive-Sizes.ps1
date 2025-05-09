
$reportCSV = './report.csv'

$dataAll = Import-CSV $reportCSV

$dataArchival =  $dataAll | Where { $_.'Task Type' -like 'Archival' -and
  $_.'SLA Domain' -ne 'Unprotected' -and $_.'Task Status' -ne 'Failed' -and
  $_.'Task Status' -ne 'Canceled' }

$archivalTotal = $dataArchival.count
$count = 1

foreach ($i in $dataArchival) {
  Write-Host "Processing $count of $archivalTotal"
  $count += 1
  $objID = $i.'Object Name' + "+" + $i.'Location'
  $i | Add-Member -MemberType NoteProperty -Name "ObjID" -Value $objID
  $i.'Start Time' = [datetime]($i.'Start Time')
  $i.'End Time' = [datetime]($i.'End Time')
  $i.'Logical Bytes' = [decimal]$i.'Logical bytes'
  $i.'Data Stored' = [decimal]$i.'Data stored'
  $i.'Data Transferred' = [decimal]$i.'Data transferred'
}

$dataArchival = $dataArchival | Sort-Object -property 'ObjID','Data Stored' -Descending

# $dataArchival | Export-CSV './see_raw.csv' -NoTypeInformation

$dataHash = @{}
$currentObj = ""
$count = 1

foreach ($i in $dataArchival) {
  if ($currentObj -notlike $i.objID) {
    Write-Host "[$count] Processing $($i.ObjID)"
    $currentObj = $($i.ObjID)
    $count += 1
    $i | Add-Member -MemberType NoteProperty -Name "Max Full Data Stored" -Value $i.'Data Stored'
    $i | Add-Member -MemberType NoteProperty -Name "Fulls Sum Data Stored" -Value $i.'Data Stored'
    $i | Add-Member -MemberType NoteProperty -Name "Fulls Count" -Value 1
    $fullThreshold = $i.'Data Stored' - ($i.'Data Stored' * 0.05)
    $i | Add-Member -MemberType NoteProperty -Name "Full Threshold " -Value $fullThreshold
    $i | Add-Member -MemberType NoteProperty -Name "Inc Sum Data Stored" -Value $([decimal]0)
    $i | Add-Member -MemberType NoteProperty -Name "Inc Count" -Value $([decimal]0)
    # If we detect a lot of fulls, then it's likely the object uploads all fulls
    $i | Add-Member -MemberType NoteProperty -Name "IncFull Sum Data Stored" -Value $([decimal]0)
    $i | Add-Member -MemberType NoteProperty -Name "IncFull Count" -Value $([decimal]0)
    $dataHash.add($i.ObjID, $i)
  } else {
    if ($i.'Data Stored' -gt $fullThreshold) {
      if ($dataHash[$currentObj].'Fulls Count' -le 3) {
        $dataHash[$currentObj].'Fulls Sum Data Stored' += $i.'Data Stored'
        $dataHash[$currentObj].'Fulls Count' += 1
      } else {
        # If we detect a lot of fulls, then just add to IncFull
        $dataHash[$currentObj].'IncFull Sum Data Stored' += $i.'Data Stored'
        $dataHash[$currentObj].'IncFull Count' += 1
      }
    } else {
      $dataHash[$currentObj].'Inc Sum Data Stored' += $i.'Data Stored'
      $dataHash[$currentObj].'Inc Count' += 1
    }
  }
}

[decimal]$totalMaxFull = 0
[decimal]$totalAvgFull = 0
[decimal]$totalAvgInc = 0
[decimal]$totalAvgIncFull = 0

foreach ($h in $dataHash.getEnumerator() ) {
  $avgFull = $h.value.'Fulls Sum Data Stored' / $h.value.'Fulls Count'
  if ($h.value.'Inc Count' -gt 0) {
    $avgInc = $h.value.'Inc Sum Data Stored' / $h.value.'Inc Count'
  } else {
    $avgInc = 0
  }
  if ($h.value.'IncFull Count' -gt 0) {
    $avgIncFull = $h.value.'IncFull Sum Data Stored' / $h.value.'IncFull Count'
  } else {
    $avgIncFull = 0
  }
  $h.value | Add-Member -MemberType NoteProperty -Name "Avg Full" -Value $avgFull
  $h.value | Add-Member -MemberType NoteProperty -Name "Avg Inc" -Value $avgInc
  $h.value | Add-Member -MemberType NoteProperty -Name "Avg IncFull" -Value $avgIncFull
  $totalMaxFull += $h.value.'Max Full Data Stored'
  $totalAvgFull += $avgFull
  $totalAvgInc += $avgInc
  $totalAvgIncFull += $avgIncFull
}

$totalMaxFullTB = [math]::Round($totalMaxFull/1000000000000, 2)
$totalAvgFullTB = [math]::Round($totalAvgFull/1000000000000, 2)
$totalAvgIncTB = [math]::Round($totalAvgInc/1000000000000, 2)
$totalAvgIncFullTB = [math]::Round($totalAvgIncFull/1000000000000, 2)

Write-Host "Total number of objects Archived: $count"
Write-Host "Total sum of max full uploads: $totalMaxFullTB TB"
Write-Host "Total sum of average full uploads: $totalAvgFullTB TB"
Write-Host "Total sum of incremental uploads: $totalAvgIncTB TB"
Write-Host "Total sum of incremental-full uploads: $totalAvgIncFullTB TB"






#### END
#
# foreach ($h in $dataHash.getEnumerator() ) {
#   Write-Host "$($h.value.'Fulls Count') / $($h.value.'ObjID')"
# }
#
#
#
# Write-Host "1 Full + 30 dailies + 10%: $(($totalAvgFullTB + (30 * $totalAvgIncTB)) * 1.1) TB"
# Write-Host "2 Fulls + 90 dailies + 10%: $(((2 * $totalAvgFullTB) + (90 * $totalAvgIncTB)) * 1.1) TB"
#
#
# $dataArray = [PSCustomObject] @()
#
# foreach ($h in $dataHash.getEnumerator() ) {
#   $dataArray += $h.value
# }
#
#
#
#
#
#
#
#
#
#
# foreach ($h in $dataHash.getEnumerator() ) {
#   if ($h.value.'Fulls Count' -gt 2) {
#     $h.key
#     $h.value
#     # $totalAvgFull += $h.value.'Avg Full'
#   }
# }
#
#
#
#
#
#
# $dataLogArchival = $dataAll | Where -property 'Task Type' -like 'Log Archival'
#
# $logArchivalTotal = $dataLogArchival.count
# $count = 1
#
# foreach ($i in $dataLogArchival) {
#   Write-Host "Processing $count of $logArchivalTotal"
#   $count += 1
#   $objID = $i.'Object Name' + "+" + $i.'Location'
#   $i | Add-Member -MemberType NoteProperty -Name "ObjID" -Value $objID
#   $i.'Start Time' = ([datetime]($i.'Start Time'.replace("UTC", "GMT"))).ToUniversalTime()
#   $i.'End Time' = ([datetime]($i.'End Time'.replace("UTC", "GMT"))).ToUniversalTime()
#   $i.'Logical bytes' = [decimal]$i.'Logical bytes'
#   $i.'Data stored' = [decimal]$i.'Data stored'
#   $i.'Data Transferred' = [decimal]$i.'Data transferred'
# }
#
# $dataLogArchival = $dataLogArchival | Sort-Object -property 'ObjID','Start Time' -Descending
#
# $logHash = @{}
# $currentObj = ""
# $count = 1
# $logSum = 0
#
# foreach ($i in $dataLogArchival) {
#   $logSum += $i.'Data Stored'
#   if ($currentObj -notlike $i.objID) {
#     Write-Host "[$count] Processing $($i.ObjID)"
#     $currentObj = $($i.ObjID)
#     $count += 1
#     $i | Add-Member -MemberType NoteProperty -Name "Latest Date" -Value $i.'Start Time'
#     $i | Add-Member -MemberType NoteProperty -Name "Earliest Date" -Value $i.'Start Time'
#     $i | Add-Member -MemberType NoteProperty -Name "Sum Data Stored" -Value $i.'Data Stored'
#     $logHash.add($i.ObjID, $i)
#   } else {
#     $logHash[$currentObj].'Earliest Date' = $i.'Start Time'
#     $logHash[$currentObj].'Sum Data Stored' += $i.'Data Stored'
#   }
# }
#
# $totalLogDailySize = 0
#
# foreach ($h in $logHash.getEnumerator() ) {
#   $dateDiff = $h.value.'Latest Date' - $h.value.'Earliest Date'
#   $dateDiff.days
#   try {
#     $avgLogSize = $h.value.'Sum Data Stored' / $dateDiff.Days
#   } catch {
#     $avgLogSize = $h.value.'Sum Data Stored'
#   }
#   $h.value | Add-Member -MemberType NoteProperty -Name "AvgLogSize" -Value $avgLogSize
#   $totalLogDailySize += $avgLogSize
# }
#
# $totalLogDailySizeTB = [math]::round($totalLogDailySize / 1000000000000, 2)
#
# Write-Host "Total number of DBs with Logs Archived: $count"
# Write-Host "Avg daily log upload: $totalLogDailySizeTB TB"
# Write-Host "14 days of logs uploaded: $(14 * $totalLogDailySizeTB) TB"
#
#
#
# foreach ($h in $logHash.getEnumerator() ) {
#   $h.avgLogSize
#   $totalLogDailySize += $avgLogSize
# }
