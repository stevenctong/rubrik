#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS


.DESCRIPTION


.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date:

For authentication, use an API token (recommended), username/password, or credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM and VARIABLES section with config details for this script.

.EXAMPLE
./.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication

.EXAMPLE
./Get-.ps1 -server <Rubrik_server>
Checks for credential file and if none found prompts for username/password.

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

$date = Get-Date

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Body<br><br>"

# Set to $true to send out email in the script
$sendEmail = $false

# CSV file info
$csvFile = "./<name>-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

###### VARIABLES - END #######

Import-Module Rubrik

# Rubrik authentication - first try using API token, then username/password if a user is provided, then credential file
try
{
  if ($token) {
    Connect-Rubrik -Server $server -Token $token
  }
  # Else if a username is provided, use username/password for authentication
  elseif ($user) {
    if ($password) {
      $password = ConvertTo-SecureString $password -AsPlainText -Force

      Connect-Rubrik -Server $server -Username $user -Password $password
    }
    # If username provided but no password, prompt for a password
    else {
      $credential = Get-Credential -Username $user

      Connect-Rubrik -Server $server -Credential $credential
    }
  }
  # Else if a credential file is found then use for authentication
  elseif (Test-Path $rubrikCred) {

    # Import Credential file
    $credential  = Import-Clixml -Path $rubrikCred

    Connect-Rubrik -Server $server -Credential $credential
  }
  # Else if no authentication method is provided then prompt for username/password
  else {
    Write-Host "`nNo API token or credential file found ($rubrikCred), please provide Rubrik credentials"

    $credential = Get-Credential
    Connect-Rubrik -Server $server -Credential $credential
  }
} catch
{
  try
  {
    $ERROR[0]
    $html += $ERROR[0]
    if ($sendEmail)
    {
      Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
    }
    Exit
  } catch
  {
    $ERROR[0]
    Exit
  }
}

# Export some list to CSV file
# $list | Export-Csv -NoTypeInformation -Path $csvFile
# Write-Host "`nResults output to: $csvFile"

# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}
