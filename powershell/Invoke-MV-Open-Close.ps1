<#
.SYNOPSIS
Opens or closes a MV according to the defined variables.

.DESCRIPTION
Opens or closes a MV according to the defined variables.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/18/21
Updated: 4/4/22

For authentication, use a CDM Service Account.

Fill out the VARIABLES section with config details for this script.

.EXAMPLE
./Rubrik-MV-Operation.ps1
Opens or closes the MV according to defined variables

#>

###### VARIABLES - BEGIN ######

$date = Get-Date

# MV ID, grab from the MV URL, looks like 'ManagedVolumes:::<ID>' - grab the whole thing
$mvID = ''

# Optionally, instead of using MV ID use the MV Name
# $mvName = ''

# MV operation, to either 'open' or 'close'
$op = ''

# Rubrik cluster IP, use a Floating IP for more resiliency
$server = ''

# Service Account ID and Secret
$svcID = ''
$svcSecret = ''

# $apiToken = ''  # older method of authentication with user API token

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

# Start logging
# $log = $logDir + "\rubrik-" + $date.ToString("yyyy-MM-dd") + "@" + $date.ToString("HHmmss") + ".log"
# Start-Transcript -Path $log -NoClobber

$type = "application/json"
$auth_body = @{
  "serviceAccountId" = $svcID
  "secret" = $svcSecret
} | ConvertTo-Json

$authURL = "https://" + $server + "/api/v1/service_account/session"
$rubrik_token = Invoke-RestMethod -Method Post -uri $authURL -ContentType $type -body $auth_body -SkipCertificateCheck

$header = @{"Authorization" = "Bearer "+ $rubrik_token.token}



if ($mvName -ne '') {
  $getURL = "https://" + $server + "/api/internal/managed_volume?name=" + $mvName
  $mvID = $(Invoke-RestMethod -Uri $getURL -Headers $header -Method GET -ContentType $type -verbose -SkipCertificateCheck).data.id
}

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

Invoke-RestMethod -Uri $mvURL -Headers $header -Method POST -ContentType $type -verbose -SkipCertificateCheck

# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}

# Stopping logging
# Stop-Transcript
