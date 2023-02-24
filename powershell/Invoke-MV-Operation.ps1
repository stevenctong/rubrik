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

  # MV Name
  [Parameter(Mandatory=$true)]
  [string]$mvName,

  # Managed Volume action - open or close
  [Parameter(Mandatory=$true)]
  [string]$op
)


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

# Rubrik cluster information
$server = 'amer1-rbk01.rubrikdemo.com'
$apiToken = 'eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI1YTc1YWU5Yy0zMzdkLTQ3ZDMtYjUxNS01MmFmNzE5MTcxMmNfMTgxMDI1OTctYTZiNS00YWQ1LWFiM2QtMDc5Y2M5MzQ5ZjJlIiwiaXNNZmFSZW1lbWJlclRva2VuIjpmYWxzZSwiaXNzIjoiNWE3NWFlOWMtMzM3ZC00N2QzLWI1MTUtNTJhZjcxOTE3MTJjIiwiaWF0IjoxNjY2NjQ0NDkxLCJqdGkiOiIwNzQ4NzNhYS1kMmQ5LTRiZmQtYTcyYy1lNDBkOWQ3MTAxOTkifQ.ZD5ajuk__fAcw_FmFLBJuG-p4PoogB662XrpvvjtwGA'

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
