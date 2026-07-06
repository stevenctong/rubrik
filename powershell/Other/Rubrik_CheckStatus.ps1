#NOSQLPS
Import-Module Rubrik

$server = "10.8.49.104"
$SQLServerInstanceName = "rp-sqlsl-02.perf.rubrik.com\MSSQLSERVER"
$DBList = @('TPCC_02TB')
# $ReportDBName = "TPCC_02TB"
# $StageDBName = "Star_Stage"

$user = "client"
$secret = ""

# How often to check the status of the backup job, in seconds
$secondsToCheck = 30

# How long to timeout the script
$timeoutSeconds = 5400


try {
  Connect-Rubrik -Server $server -Id $user -Secret $secret

  $resultList = @()

  foreach ($DB in $DBList) {
      Write-Host "Getting info for: $DB"
      $DBInfo = Get-RubrikDatabase -Name $DB -ServerInstance $SQLServerInstanceName -Relic:$false

      $events = Get-RubrikEvent -id $DBInfo.id -eventType 'Backup' -Limit 4
      $latestEvent = $events | Where-Object { $_.eventStatus -ne 'Queued' } | Select-Object -First 1

      if (-not $latestEvent) {
          Write-Warning "[$DB] No non-queued events found, skipping."
          continue
      }

      Write-Host "[$DB] Found event series ID: $($latestEvent.eventSeriesId)"

      $resultDetail = [PSCustomObject] @{
          "sqlID"         = $DBInfo.id
          "jobID"         = $latestEvent.jobInstanceId
          "status"        = ''
          "name"          = $DBInfo.name
          "instance"      = $DBInfo.instanceName
          "host"          = $DBInfo.rootProperties.rootName
          "eventSeriesId" = $latestEvent.eventSeriesId
      }
      $resultList += $resultDetail
  }

  # Job states where the job is still running
  $runningStates = @('QUEUED','ACQUIRING','RUNNING','FINISHING','TO_CANCEL', 'CANCEL')

  $totalCount = $timeoutSeconds / $secondsToCheck
  $currentCount = 0

  # Wait until task completes and return state
  do {
    # Contains state information, starts false.
    # Sets to $true if we detect any non-terminating state
    $reqState = $false
    foreach ($db in $resultList) {
      $req = Get-RubrikEventSeries -id $db.eventSeriesId
      $db.status = $req.status
      Write-Host "Current status for $($db.name) / $($db.host): $($req.status), checking again in $secondsToCheck seconds..."
      if ($runningStates -contains $req.status) {
        $reqState = $true
      }
    }
    # Check if we are greater than the timeout, if so exit
    $currentCount += 1
    if ($currentCount -gt $totalCount) {
      Write-Error "Timeout of $timeoutSeconds seconds reached, exiting..."
      exit 300
    }
    if ($reqState) { Start-Sleep -Seconds $secondsToCheck }
  } while ( $reqState )

  $fullySuccessful = $true
  foreach ($res in $resultList) {
    $eventSeries = Get-RubrikEventSeries -id $res.eventSeriesId
    if ($res.status -match 'SUCC') {
      Write-Host "[$($res.name)] Successful - Status: $($eventSeries.eventSeriesStatus)"
    } elseif ($res.status -match 'CANCEL') {
      Write-Host "[$($res.name)] Canceled - Status: $($eventSeries.eventSeriesStatus)"
    } elseif ($res.status -match 'FAIL') {
      Write-Error "[$($res.name)] Failed - Status: $($eventSeries.eventSeriesStatus)"
      $fullySuccessful = $false
    } else {
      Write-Error "[$($res.name)] Non-terminal state - Status: $($res.status)"
      $fullySuccessful = $false
    }
    Write-Host "  Start:    $($eventSeries.startTime)"
    Write-Host "  End:      $($eventSeries.endTime)"
    Write-Host "  Duration: $($eventSeries.duration)"
  }

  if ($fullySuccessful) {
    exit 0
  } else {
    exit 500
  }

}
catch {
    throw $PSItem
}




