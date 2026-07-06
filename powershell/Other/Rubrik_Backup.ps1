#NOSQLPS
Import-Module Rubrik
$SLAName = "MSSQL-1d-30d-NoArchive-NoReplication (Managed by Polaris)"

$server = "10.8.49.104"
$SQLServerInstanceName = "rp-sqlsl-02.perf.rubrik.com\MSSQLSERVER"
$DBList = @('TPCC_02TB')
# $ReportDBName = "TPCC_02TB"
# $StageDBName = "Star_Stage"

$user = "client|"
$secret = ""

# How often to check the status of the backup job, in seconds
$secondsToCheck = 15

# How long to timeout the script
$timeoutSeconds = 5400


try {
    Connect-Rubrik -Server $server -Id $user -Secret $secret

    # Holds list of on demand backup results
    $resultList = @()

    foreach ($DB in $DBList) {
        Write-Host "Getting info for: $DB"
        $DBInfo = Get-RubrikDatabase -Name $DB -ServerInstance $SQLServerInstanceName -Relic:$false
        Write-Host "Taking Snapshot for: $DB"
        $DBSnapshot = New-RubrikSnapshot -id $DBInfo.id -SLA $SLAName -Confirm:$false
        $DBSnapshot

        # Get recent backup events and match on jobInstanceId
        $events = Get-RubrikEvent -id $DBInfo.id -eventType 'Backup' -Limit 4
        $matchedEvent = $events | Where-Object { $_.jobInstanceId -eq $DBSnapshot.id } | Select-Object -First 1

        $resultDetail = [PSCustomObject] @{
            "sqlID"         = $DBInfo.id
            "href"          = $DBSnapshot.links.href
            "jobID"         = $DBSnapshot.id
            "status"        = ''
            "name"          = $DBInfo.name
            "instance"      = $DBInfo.instanceName
            "host"          = $DBInfo.rootProperties.rootName
            "eventSeriesId" = if ($matchedEvent) { $matchedEvent.eventSeriesId } else { '' }
        }
        $retryCount = 0
        do {
            $retryCount++
            Start-Sleep -Seconds 2
            Write-Host "[$DB] Attempting to get event series ID (attempt $retryCount)..."
            $events = Get-RubrikEvent -id $resultDetail.sqlID -eventType 'Backup' -Limit 4
            $matchedEvent = $events | Where-Object { $_.jobInstanceId -eq $resultDetail.jobID } | Select-Object -First 1
            if ($matchedEvent) {
                $resultDetail.eventSeriesId = $matchedEvent.eventSeriesId
                Write-Host "[$DB] Found event series ID: $($matchedEvent.eventSeriesId)"
            }
        } while ([string]::IsNullOrEmpty($resultDetail.eventSeriesId) -and $retryCount -lt 15)
        if ([string]::IsNullOrEmpty($resultDetail.eventSeriesId)) {
            throw "[$DB] Failed to get event series ID after $retryCount attempts. Exiting."
        }
        $resultList += $resultDetail
    }

    # Poll event series until all DBs have reached the "Retrieving SQL Server" stage
    $startTime = Get-Date
    do {
        Write-Host "Checking events for all backups for Retrieving SQL Server stage..."
        $allRetrieving = $true

        foreach ($result in $resultList) {
            $eventSeries = Get-RubrikEventSeries -id $result.eventSeriesId
            $result.status = $eventSeries.eventSeriesStatus
            $hasRetrieving = $eventSeries.eventDetailList | Where-Object {
                $_.eventName -eq 'Mssql.BeginFetchBackup'
            }

            if ($hasRetrieving) {
                Write-Host "[$($result.name)] Reached 'Retrieving SQL Server' stage - Status: $($result.status)"
            } else {
                Write-Host "[$($result.name)] Waiting for 'Retrieving SQL Server' stage - Status: $($result.status)"
                $allRetrieving = $false
            }
        }

        $elapsed = (Get-Date) - $startTime
        Write-Host "Elapsed: $([math]::Round($elapsed.TotalSeconds))s / $($timeoutSeconds)s"
        Start-Sleep -Seconds $secondsToCheck
    } while (-not $allRetrieving -and $elapsed.TotalSeconds -lt $timeoutSeconds)

    if (-not $allRetrieving) {
        Write-Warning "Timed out after $timeoutSeconds seconds. Not all DBs reached 'Retrieving SQL Server' stage."
    } else {
        Write-Host "`nAll DBs have reached 'Retrieving SQL Server' stage."
    }

    Write-Host "`nFinal Results:"
    $resultList
}
catch {
    throw $PSItem
}
