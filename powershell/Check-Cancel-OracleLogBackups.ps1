#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Iterates through a list of Oracle databases to look for and cancel stuck Log Backups jobs

.DESCRIPTION
The Check-Cancel-OracleLogBackups script iterates through a list of Oracle databases to look for and cancel stuck Log Backup jobs.
Stuck jobs are those that are still running > 30 min and at < 13% progress.
If it finds a stuck job, it will cancel that job and decrease the log backup frequency so the next scheduled job will occur sooner.
If the last log backup job was successful then it will set the log backup frequency back to the normal frequency.
An email will be sent out with status details everytime the script is run.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 12/2/20

For authentication, use an API token (recommended), username/password, or credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM and VARIABLES section with config details for this script.

.EXAMPLE
./Check-Cancel-OracleLogBackups.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication

.EXAMPLE
./Check-Cancel-OracleLogBackups.ps1 -server <Rubrik_server> -user <username> - password <password>
Use username/password for authentication

.EXAMPLE
./Check-Cancel-OracleLogBackups.ps1
Checks for credential file and if none found prompts for username/password
#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$false)]
  [string]$server = '',

  # Use API token for authentication
  [Parameter(Mandatory=$false)]
  [string]$token = $null,

  # Use Rubrik username/password for authentication
  [Parameter(Mandatory=$false)]
  [string]$user = $null,

  # Use Rubrik username/password for authentication
  [Parameter(Mandatory=$false)]
  [string]$password = $null,

  # Use credential file for authentication, location of it
  [Parameter(Mandatory=$false)]
  [string]$rubrikCred = 'rubrik_cred.xml'
)

###### VARIABLES - BEGIN #######

# Provide comma separted list of database names
# $oracleDB = @('db1','db2','db3')
$oracleDB = @('')

# $logBackupLong is the regular Oracle log backup frequency, in minutes
# $logBackupShort is the shorter frequency to set it to if the last log backup failed
$logBackupLong = 240
$logBackupShort = 30

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$date = Get-Date
$dateUTC = $date.ToUniversalTime()

$emailSubject = "Rubrik ($server) - Oracle Log Check Script - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Script status<br><br>"

# Set to $true to send out email at the end of the script
$sendEmail = $false

###### VARIABLES - END #######

Import-Module Rubrik

# Rubrik authentication - first try using API token, then username/password if a user is provided, then credential file
try {
  if ($token) { Connect-Rubrik -Server $server -Token $token }
  else {
    if ($user) {
      if ($password) {
        $password = ConvertTo-SecureString $password -AsPlainText -Force
        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $user, $password
      }
      else { $credential = Get-Credential -Username $user }
    }
    elseif (Test-Path $rubrikCred) { $credential  = Import-Clixml -Path $rubrikCred }
    else { $credential = Get-Credential }
    Connect-Rubrik -Server $server -Credential $credential
  }
} catch {
  try {
    Write-Error "Error connecting to cluster or with authentication."
    $html = "Error connecting to cluster or with authentication."
    if ($sendEmail) { Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort }
    Exit
  } catch {
    Exit
  }
}

# Iterate through list of DBs
foreach ($dbname in $oracleDB)
{
  try
  {
    # Get latest events for DB, sorted by most recent event in [0]
    $eventSeries = Invoke-RubrikRESTCall -Method "Get" -Endpoint "event/latest?event_type=Backup&object_type=OracleDb&object_name=$dbname" -Verbose

    # Iterate through list of events starting with most recent
    # Once it processes either a "Running", "Cancel*", "Failure", or "Success*" event, break out of event series processing for this DB
    foreach ($i in $eventSeries.data.latestEvent)
    {
      # If the most recent event is a running log job, check if it's "stuck" - running for > 30 min with < 12% progress
      # If it's stuck, cancel job, increase DB log backup frequency. provde status and process next DB.
      # Otherwise, do nothing but provide status and process next DB.
      if (($i.jobInstanceId -like "CREATE_ORACLE_LOG_SNAPSHOT*") -and ($i.eventStatus -like "Running"))
      {
        # Get the event detail of current event in the series
        $eventDetail = Invoke-RubrikRESTCall -Method "Get" -Endpoint "event_series/$($i.eventSeriesId)" -Verbose

        # The duration is stored in a string, eg "2 hr 15 min" - parse string to pull out hours and minutes
        $durationHour = ($eventDetail.duration | Select-String "\d* hr").matches.value | Select-String "\d*"
        $durationHourInt = [int]($durationHour | Select-String "\d*").matches.value

        $durationMin = ($eventDetail.duration | Select-String "\d* min").matches.value
        $durationMinInt = [int]($durationMin | Select-String "\d*").matches.value

        $totalDuration = ($durationHourInt * 60) + $durationMinInt

        Write-Host "Processing $dbname, total duration: $($eventDetail.duration)."
        Write-Host "Calculated hour: $durationHourInt, calculated min: $durationMinInt, total duration min: $totalDuration."

        # If the event has been running for > 30 min
        if ($totalDuration -gt 30)
        {
          # Need to split out the integer from a ##% string value
          $progress=$eventDetail.progressPercentage.split('%')
          $progressNum=[int]$progress[0]

          # If the event progress is < 13% (along with being > 30 min running) then we should cancel job and increase DB log frequency
          if ($progressNum -lt 13)
          {
            # Cancels this running job
            $cancelJob = Invoke-RubrikRESTCall -Method "Post" -Api "internal" -Endpoint "event_series/$($i.eventSeriesId)/cancel" -verbose

            $exportJson = New-Object PSObject
            $exportJson | Add-Member -MemberType NoteProperty -Name "logBackupFrequencyInMinutes" -Value $logBackupShort

            # Updates the DB log backup frequency to $logBackupShort time
            $updateLogFreq = Invoke-RubrikRESTCall -Method "Patch" -Api "internal" -Body $exportJson -Endpoint "oracle/db/$($i.objectId)" -verbose

            $html += "<b>$dbname</b> log backup running for $($eventDetail.duration) was cancelled. DB log frequency set to $logBackupShort min.<br><br>"

            break
          } # If progress is < 13%
        } # If more time since log started > 30 min

        $html += "<b>$dbname</b> log backup is currently running for $($eventDetail.duration) and is at $progress% since $($eventDetail.startTime)."
        break
      } # If Log Backup job and Running state

      # IF the last log backup was in a cancelled state, just provide status and process next DB
      if (($i.jobInstanceId -like "CREATE_ORACLE_LOG_SNAPSHOT*") -and ($i.eventStatus -like "Cancel*"))
      {
        $dbInfo = Invoke-RubrikRESTCall -Method "Get" -Api "internal" -Endpoint "oracle/db/$($i.objectId)" -verbose

        $html += "<b>$dbname</b> last log backup was canceled or canceling. Log backup frequency remains set to $($dbInfo.logBackupFrequencyInMinutes) min.<br><br>"

        break
      } # If Log Backup job and Canceling state

      # If the last log backup was failed, just provide status and process next DB
      if (($i.jobInstanceId -like "CREATE_ORACLE_LOG_SNAPSHOT*") -and ($i.eventStatus -like "Failure"))
      {
        $dbInfo = Invoke-RubrikRESTCall -Method "Get" -Api "internal" -Endpoint "oracle/db/$($i.objectId)" -verbose

        $html += "<b>$dbname</b> last log backup failed. Log backup frequency remains set to $($dbInfo.logBackupFrequencyInMinutes) min.<br><br>"

        break
      } # If Log Backup job and Failed state

      # If the last log backup was successful, set the log backup frequency back to normal, provide status, and process next DB
      if (($i.jobInstanceId -like "CREATE_ORACLE_LOG_SNAPSHOT*") -and ($i.eventStatus -like "Success*"))
      {
        $eventDetail = Invoke-RubrikRESTCall -Method "Get" -Endpoint "event_series/$($i.eventSeriesId)" -Verbose

        $exportJson = New-Object PSObject
        $exportJson | Add-Member -MemberType NoteProperty -Name "logBackupFrequencyInMinutes" -Value $logBackupLong

        # Updates DB log frequency to $logBackupLong time
        $updateLogFreq = Invoke-RubrikRESTCall -Method "Patch" -Api "internal" -Body $exportJson -Endpoint "oracle/db/$($i.objectId)" -verbose

        $html += "<b>$dbname</b> last log backup succeeded. Start time was $($eventDetail.startTime), duration $($eventDetail.duration). DB log frequency set to $logBackupLong min.<br><br>"

        break
      } # If Log Backup job and Success state
    }
  } catch
  {
    try
    {
      Write-Error $ERROR[0]
      $html += $ERROR[0]
      Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
      Exit
    } catch
    {
      Write-Error $ERROR[0]
      Exit
    }
  }
}

if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}

Disconnect-Rubrik -Confirm:$false
