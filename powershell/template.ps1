#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS


.DESCRIPTION


.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date:

For authentication, use one of the following methods:
$token - an API token tied to a user account; keep in mind that tokens have an expiration date
$credential - credential file that can be created using: Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
$user and $password - plaintext username and password

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./.ps1 -server <Rubrik_server>
The script will prompt for a username and password for the Rubrik cluster

.EXAMPLE
./.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication



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

Import-Module Rubrik

###### VARIABLES - BEGIN ######

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
$csvOutput = "./<name>-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

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


# Alternative authentication options
###### RUBRIK AUTHENTICATION - BEGIN ######
# $server = ''

# Connect to Rubrik cluster - prompt for all arguments
# Connect-Rubrik

# Option 1) Use an API token for authentication
# $token = ''
# Connect-Rubrik -Server $server -Token $token

# Option 2) Use a credential file for authentication
# To create a credential file (note: only the user who creates it can use it):
# Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
# $credential  = Import-Clixml -Path ./rubrik_cred.xml
# Connect-Rubrik -Server $server -Credential $credential

# Option 3) Use a username and password for authentication
# $user = ''
# $password = '' | ConvertTo-SecureString -AsPlainText -Force
# Connect-Rubrik -Server $server -Username $user -Password $password

###### RUBRIK AUTHENTICATION - END ######


# Send a REST API call to some endpoint
$bodyJson = [PSCustomObject] @{
  arg = ''
}
$req = Invoke-RubrikRESTCall -Method 'Patch' -Api '1' -Body $bodyJson -Endpoint "vmware/vm)"


# Export the list to a CSV file
$list | Export-Csv -NoTypeInformation -Path $csvOutput
Write-Host "`nResults output to: $csvOutput"

# Send an email with CSV attachment
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
}

# Format a timeSpan object to a string when calculating difference between two times
Function Format-TimeStr($time) {
  $timeStr = ''
  if ($time.Days -gt 0) { $timeStr += "$($time.Days) day(s) " }
  if ($time.Hours -gt 0) { $timeStr += "$($time.Hours) hr " }
  if ($time.Minutes -gt 0) { $timeStr += "$($time.Minutes) min " }
  if ($time.Seconds -gt 0) { $timeStr += "$($time.Seconds) sec " }
  return $timeStr.trim()
}
