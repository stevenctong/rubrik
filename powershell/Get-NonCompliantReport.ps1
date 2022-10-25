#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Calculates the replication and archive lag for a cluster and generates a CSV report.

.DESCRIPTION
The Get-NonCompliantReport.ps1 script calculates the replication and archive lag of a cluster.
The results are exported to a CSV file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 1/26/22

For authentication, use one of the following methods:
$token - an API token tied to a user account; keep in mind that tokens have an expiration date
$credential - credential file that can be created using: Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
$user and $password - plaintext username and password

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Get-NonCompliantReport.ps1 -server <Rubrik_server> -token $token
Run the script against the Rubrik cluster using a token.

.EXAMPLE
./Get-NonCompliantReport.ps1
Run the script and prompt for all parameters.

#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$false)]
  [string]$server = '',

  # Use API token for authentication
  [Parameter(Mandatory=$false)]
  [string]$token = '',

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

Import-Module Rubrik

###### VARIABLES - BEGIN ######

$date = Get-Date

$replicationLagBuffer = 1

$reportBaseFilename = "./rubrik_compliance_report"
$reportFilename = $reportBaseFilename + "-" + $date.ToString("yyyy-MM-dd") + ".csv"

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Body<br><br>"

# Set to $true to send out email in the script
$sendEmail = $false

# $csvOutput variable is after the authentication block

###### VARIABLES - END #######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if (!$server) { $server = Read-Host "Rubrik hostname or IP" }
  if ($token) { Connect-Rubrik -Server $server -Token $token }
  else {
    if ($user) {
      if ($password) {
        [SecureString]$password = ConvertTo-SecureString -String  $password -AsPlainText -Force
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
    Exit 1
  } catch { Exit 1 }
}
###### RUBRIK AUTHENTICATION - END ######

# CSV file info
$cluster = (Get-RubrikClusterInfo).Name
$csvOutput = "./rubrik-$cluster-lagged_objects-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

$SLAs = Get-RubrikSLA -PrimaryClusterID local
$slaHash = @{}

Write-Host "Gathering SLA information..." -foregroundcolor green

foreach ($SLA in $SLAs)
{
  $archiveThresholdDays = [math]::round([int]$SLA.archivalSpecs.archivalThreshold / 86400, 1)

  if ($SLA.frequencies.daily.retention -ge $archiveThresholdDays) {
    $baseFreq = $SLA.frequencies.daily.frequency
  } elseif ( ($SLA.frequencies.weekly.retention * 7) -ge $archiveThresholdDays) {
    $baseFreq = [int]$SLA.frequencies.weekly.frequency * 7
  } elseif ( ($SLA.frequencies.monthly.retention * 30) -ge $archiveThresholdDays) {
    $baseFreq = [int]$SLA.frequencies.monthly.frequency * 30
  } elseif ( ($SLA.frequencies.quarterly.retention * 90) -ge $archiveThresholdDays) {
    $baseFreq = [int]$SLA.frequencies.quarterly.frequency * 90
  } elseif ( ($SLA.frequencies.yearly.retention * 365) -ge $archiveThresholdDays) {
    $baseFreq = [int]$SLA.frequencies.yearly.frequency * 365
  } else {
    $baseFreq = 0
  }

  $SLA = [PSCustomObject] @{
      "Name" = $SLA.name
      "BaseFreq" = $baseFreq
      "Replication" = $SLA.replicationSpecs.locationName
      "Archive" = $SLA.archivalSpecs.locationName
      "ArchiveThresholdDays" = $archiveThresholdDays
      "MaxArchiveDays" = $archiveThresholdDays + $baseFreq
  }

  $slaHash.($SLA.Name) = $SLA
}

# Write-Host "Downloading Compliance Report to `"$reportFilename`"" -foregroundcolor green
Write-Host "Downloading Compliance Report..." -foregroundcolor green
$reportLink = Invoke-RubrikRESTCall -Method Get -Api 'internal' -Endpoint 'report/data_source/FrequentDataSource/csv'

if ($PSVersionTable.PSVersion.Major -gt 5) {
  $complianceReport = Invoke-WebRequest -Uri $reportLink -SkipCertificateCheck
} else {
  Invoke-WebRequest -Uri $reportLink -OutFile $reportFileName
}

$report = $complianceReport.content | ConvertFrom-CSV

$laggedObjects = @()
$total = $report.count
$count = 1

foreach ($i in $report)
{
  $latestLocal = ''
  $latestReplicated = ''
  $latestArchived = ''

  Write-Host "[$count / $total] Processing: $($i.'Object Name'), $($i.'Location')"
  $count += 1

  if ($i.'Latest Local Snapshot' -ne '') {
    $latestLocal = [DateTime]::ParseExact($i.'Latest Local Snapshot', "yyyy-MM-dd HH:mm:ss", $null)
  }

  if ($i.'Latest Replicated Snapshot' -ne '') {
    $latestReplicated = [DateTime]::ParseExact($i.'Latest Replicated Snapshot', "yyyy-MM-dd HH:mm:ss", $null)
  }

  if ($i.'Latest Archived Snapshot' -ne '') {
    $latestArchived = [DateTime]::ParseExact($i.'Latest Archived Snapshot', "yyyy-MM-dd HH:mm:ss", $null)
  }

  $iSLA = $i.'SLA Domain'
  $replicationLagDays = ''
  $archiveLagDays = ''
  $oldestRecoveryPoint = $null

  if ($slaHash."$iSLA".Replication -ne $null) {
    if ($latestReplicated -ne '') {
      $replicationLagDays = ($latestLocal - $latestReplicated).Days
    } else {
      $replicationLagDays = 999
    }
  }

  if ($slaHash."$iSLA".Archive -ne $null) {
    if ($latestArchived -ne '') {
      $archiveLagDays = ($latestLocal - $latestArchived).Days
      $archiveLagDays = $archiveLagDays - $slaHash."$iSLA".MaxArchiveDays
    } else
    {
      if ($i.'Object Type' -eq 'vSphere VM') {
        $oldestRecoveryPoint = (Get-RubrikVM -id $i.'Object ID').oldestRecoveryPoint
      } elseif ($i.'Object Type' -eq 'SQL Server DB') {
        $oldestRecoveryPoint = (Get-RubrikDatabase -id $i.'Object Id').oldestRecoveryPoint
      }

      $dateDiff = 999

      if ($oldestRecoveryPoint -ne $null) {
        $dateDiff = ($date - $oldestRecoveryPoint).Days
      }

      if ($dateDiff -gt $slaHash."$iSLA".MaxArchiveDays) {
        $archiveLagDays = 999
      }
    }
  }

  if ( ($replicationLagDays - $replicationLagBuffer) -gt 0 ) {
    $replicationLag = $replicationLagDays - $replicationLagBuffer
  } else {
    $replicationLag = ''
  }

  if ( $archiveLagDays -gt 0 ) {
    $archiveLag = $archiveLagDays
  } else {
    $archiveLag = ''
  }

  if ( ($replicationLag -gt 0) -or ($archiveLag -gt 0) )
  {
    if ( ($oldestRecoveryPoint -eq '') -or ($oldestRecoveryPoint -eq $null) )
    {
      if ($i.'Object Type' -eq 'vSphere VM') {
        $oldestRecoveryPoint = (Get-RubrikVM -id $i.'Object ID').oldestRecoveryPoint
      } elseif ($i.'Object Type' -eq 'SQL Server DB') {
        $oldestRecoveryPoint = (Get-RubrikDatabase -id $i.'Object Id').oldestRecoveryPoint
      }
    }

    $laggedObj = [PSCustomObject] @{
        "Cluster" = $cluster
        "Name" = $i.'Object Name'
        "Loction" = $i.'Location'
        "Type" = $i.'Object Type'
        "SLA" = $i.'SLA Domain'
        "Replication Lag Days" = $replicationLag
        "Archive Lag Days" = $archiveLag
        "Awaiting First Full" = $i.'Awaiting First Full'
        "Latest Local Snapshot" = $i.'Latest Local Snapshot'
        "Latest Replicated Snapshot" = $i.'Latest Replicated Snapshot'
        "Latest Archived Snapshot" = $i.'Latest Archived Snapshot'
        "Replication Target" = $slaHash."$iSLA".Replication
        "Archive Location" = $slaHash."$iSLA".Archive
        "Oldest Recovery Point" = $oldestRecoveryPoint
    }
    $laggedObjects += $laggedObj
  }
}

# Export lagged objects list to a CSV file
$laggedObjects | Export-Csv -NoTypeInformation -Path $csvOutput
Write-Host "`nResults output to: $csvOutput"

# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}
