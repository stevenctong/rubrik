<#
.SYNOPSIS
Opens or closes a MV according to the defined variables.

.DESCRIPTION
Opens or closes a MV according to the defined variables.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/18/21
Updated: 4/12/22

For the MV, be sure to apply a SLA domain policy to it.

For authentication, use a CDM Service Account assigned to a Custom Role.
The Custom Role needs access to the MVs and the "Take On Demand Snapshot' permission.

You can create a .json file with the Rubrik cluster IP/hostname and service account ID & secret.
The .json should look like:

{
  "rubrikServer": "",
  "svcID": "User:::abc-def",
  "svcSecret": "abc"
}

Pass the .json filename as a parameter.

Fill out the PARAMTERS and VARIABLES section as needed.

.EXAMPLE
./Invoke-MV-Open-Close.ps1 -op 'open'
Open the MV using hard coded variables in the script.

./Invoke-MV-Open-Close..ps1 -mvName 'mvsql_data '-op 'close' -rubrikJson './rubrikcreds.json'
Close the MV using the info provided in the .json file.

#>

param (
  [CmdletBinding()]

  # Json file containing the Rubrik cluster info and service account details
  [Parameter(Mandatory=$false)]
  [string]$rubrikJson = '',

  # MV operation: 'open' for read-write, 'close' to read-only
  [Parameter(Mandatory=$false)]
  [string]$op = '',

  # Managed Volume ID
  [Parameter(Mandatory=$false)]
  [string]$mvID = '',

  # Managed Volume name - optionally use MV ID instead of MV name
  [Parameter(Mandatory=$false)]
  [string]$mvName = ''
)

###### VARIABLES - BEGIN ######

# If Rubrik JSON is specified in parameters, use its information
if ($rubrikJson -ne '')
{
  # Get the Rubrik cluster and service account details from the .json file
  $rubrikSvc = Get-Content -Raw -Path $rubrikJson | ConvertFrom-Json
  $server = $rubrikSvc.rubrikServer
  $svcID = $rubrikSvc.svcID
  $svcSecret = $rubrikSvc.svcSecret
} else {
  # Rubrik cluster IP, use a Floating IP for more resiliency
  $server = ''

  # Service Account ID and Secret
  $svcID = ''
  $svcSecret = ''
}

# $apiToken = ''  # older method of authentication with user API token

$date = Get-Date

#Log directory
# $logDir = 'C:\Rubrik\log'

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

$psVer = $PSVersionTable.psversion.major

if ([System.Net.ServicePointManager]::CertificatePolicy -notlike 'TrustAllCertsPolicy' -and $psVer -le 5) {
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

[System.Net.ServicePointManager]::SecurityProtocol =[System.Net.SecurityProtocolType]::Tls12

# Start logging
# $log = $logDir + "\rubrik-" + $date.ToString("yyyy-MM-dd") + "@" + $date.ToString("HHmmss") + ".log"
# Start-Transcript -Path $log -NoClobber

if ($rubrikJson -eq '' -and $server -eq '') {
  Write-Error "You must pass either a .json containing the Rubrik cluster details or define the details in the script."
  Write-Error "Exiting..."
  exit 99
}

if ($op -eq 'open')
{
  $opURL = "/begin_snapshot"
} elseif ($op -eq 'close') {
  $opURL = "/end_snapshot"
} else {
  Write-Error "Invalid argument for -op: should either be open or close, exiting."
  Stop-Transcript
  exit 99
}

$delSessionURL = "https://" + $server + "/api/v1/session/me"

Write-Host "Connecting to Rubrik cluster: $server"

$type = "application/json"
$auth_body = @{
  "serviceAccountId" = $svcID
  "secret" = $svcSecret
} | ConvertTo-Json

$authURL = "https://" + $server + "/api/v1/service_account/session"
if ($psVer -ge 6)
{
  $rubrik_token = Invoke-RestMethod -Method Post -uri $authURL -ContentType $type -body $auth_body -SkipCertificateCheck
} else {
  $rubrik_token = Invoke-RestMethod -Method Post -uri $authURL -ContentType $type -body $auth_body
}

$header = @{"Authorization" = "Bearer "+ $rubrik_token.token}

if ($mvName -ne '') {
  Write-Host "Getting the MV ID of: $mvName"
  $getURL = "https://" + $server + "/api/internal/managed_volume?name=" + $mvName
  if ($psVer -ge 6) {
    $mvID = $(Invoke-RestMethod -Uri $getURL -Headers $header -Method GET -ContentType $type -SkipCertificateCheck).data.id
  } else {
    $mvID = $(Invoke-RestMethod -Uri $getURL -Headers $header -Method GET -ContentType $type).data.id
  }
  if ($mvID -eq $null -or $mvID -eq '') {
    Write-Error "Could not get MV ID for: $mvName, exiting"
    # Delete Rubrik session
    if ($psVer -ge 6)
    {
      Invoke-RestMethod -uri $delSessionURL -Headers $header -Method Delete -ContentType $type -SkipCertificateCheck
    } else {
      Invoke-RestMethod -uri $delSessionURL -Headers $header -Method Delete -ContentType $type
    }
    exit 99
  }
  Write-Host "MV ID: $mvID"
} else {
  Write-Host "MV ID: $mvID"
}

Write-Host "Performing MV operation: $op"
$baseMVURL = "https://" + $server + "/api/v1/managed_volume/"

$mvURL = $baseMVURL + $mvID + $opURL

try {
  if ($psVer -ge 6) {
    Invoke-RestMethod -Uri $mvURL -Headers $header -Method POST -ContentType $type -SkipCertificateCheck
  } else {
    Invoke-RestMethod -Uri $mvURL -Headers $header -Method POST -ContentType $type
  }
} catch {
  Write-Error "Error with MV operation $op $resp"
  Write-Error "Exiting."
  # Delete Rubrik session
  if ($psVer -ge 6)
  {
    Invoke-RestMethod -uri $delSessionURL -Headers $header -Method Delete -ContentType $type -SkipCertificateCheck
  } else {
    Invoke-RestMethod -uri $delSessionURL -Headers $header -Method Delete -ContentType $type
  }
  exit 99
}

# Delete Rubrik session
if ($psVer -ge 6)
{
  Invoke-RestMethod -uri $delSessionURL -Headers $header -Method Delete -ContentType $type -SkipCertificateCheck
} else {
  Invoke-RestMethod -uri $delSessionURL -Headers $header -Method Delete -ContentType $type
}

# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}

# Stopping logging
# Stop-Transcript

exit 0
