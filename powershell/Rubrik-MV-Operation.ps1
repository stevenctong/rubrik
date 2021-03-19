<#
.SYNOPSIS
Opens or closes a MV according to the command line arguments.

.DESCRIPTION
Opens or closes a MV according to the command line arguments.
Define a hash table of hosts to Managed Volumes IDs within the script.
Pass in the the host using the "-mvHost" argument.
Pass in either "open" or "close" in the "-op" argument to open or close the MV.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/18/21

For authentication, fill in the API token variable.

Fill out the VARIABLES section with config details for this script.

.EXAMPLE
./Rubrik-MV-Operation.ps1 -mvHost <host> -op <open or close>
Opens or closes the MV according to -op to the -mvHost

#>

param (
  [CmdletBinding()]

  # Host
  [Parameter(Mandatory=$true)]
  [string]$mvHost,

  # Managed Volume action - open or close
  [Parameter(Mandatory=$true)]
  [string]$op
)


###### VARIABLES - BEGIN ######

$date = Get-Date

# Rubrik cluster information
$server = ''
$apiToken = ''

# Host to Managed Volume Mapping
$mvHosts = @{
  "" = ""
}

#Log directory
$logDir = 'C:\Rubrik\log'

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Body<br><br>"

# Set to $true to send out email in the script
$sendEmail = $false

###### VARIABLES - END #######

# Starg logging
$log = $logDir + "\rubrik-" + $date.ToString("yyyy-MM-dd") + "@" + $date.ToString("HHmmss") + ".log"
Start-Transcript -Path $log -NoClobber

$baseMVURL = "https://" + $server + "/api/internal/managed_volume/"
$header = @{"Authorization" = "Bearer "+$apiToken}
$type = "application/json"

if ($mvHosts.$mvHost -eq $null)
{
  Write-Error "Host not defined in script, exiting"
  Stop-Transcript
  exit 98
}

if ($op -eq 'open')
{
  $opURL = "/begin_snapshot"
} elseif ($op -eq 'close') {
  $opURL = "/end_snapshot"
} else {
  Write-Error "Invalid argument for -op: should either be open or close, exiting"
  Stop-Transcript
  exit 99
}

$mvURL = $baseMVURL + $mvHosts.$mvHost + $opURL

Invoke-RestMethod -Uri $mvURL -Headers $header -Method POST -ContentType $type -verbose

# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}

# Stopping logging
Stop-Transcript
