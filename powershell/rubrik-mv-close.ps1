<#
.SYNOPSIS
Opens or closes a MV according to the command line arguments.

.DESCRIPTION
Opens or closes a MV according to the command line arguments.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 10/25/22

For authentication, fill in the API token variable.

Fill out the VARIABLES section with config details for this script.

.EXAMPLE

#>

# Rubrik cluster information
$server = ''
$apiToken = ''

$mvName = ''
$op = 'close'

if ([System.Net.ServicePointManager]::CertificatePolicy -notlike 'TrustAllCertsPolicy') {
  # Added try catch block to resolve issue #613
  $ErrorActionPreference = 'Stop'
  try {
    Add-Type -TypeDefinition @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
      public bool CheckValidationResult(
          ServicePoint srvPoint, X509Certificate certificate,
          WebRequest request, int certificateProblem) {
          return true;
      }
    }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object -TypeName TrustAllCertsPolicy
  } catch {
    Write-Warning 'An error occured while attempting to allow self-signed certificates'
    Write-Debug ($Error[0] | ConvertTo-Json | Out-String)
  }
}

try {
  if ([Net.ServicePointManager]::SecurityProtocol -notlike '*Tls12*') {
    Write-Verbose -Message 'Adding TLS 1.2'
    [Net.ServicePointManager]::SecurityProtocol = ([Net.ServicePointManager]::SecurityProtocol).tostring() + ', Tls12'
  }
}
catch {
  Write-Verbose -Message $_
  Write-Verbose -Message $_.Exception.InnerException.Message
}

###### VARIABLES - BEGIN ######

$date = Get-Date

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
# Start-Transcript -Path $log -NoClobber

$header = @{"Authorization" = "Bearer "+$apiToken}
$type = "application/json"

$getURL = "https://" + $server + "/api/internal/managed_volume?name=" + $mvName

$mvID = $(Invoke-RestMethod -Uri $getURL -Headers $header -Method GET -ContentType $type -verbose).data.id

$baseMVURL = "https://" + $server + "/api/v1/managed_volume/"

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

$mvURL = $baseMVURL + $mvID + $opURL

Invoke-RestMethod -Uri $mvURL -Headers $header -Method POST -ContentType $type -verbose

# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}

# Stopping logging
# Stop-Transcript
