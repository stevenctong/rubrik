#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Iterates through a list of SQL databases and pauses/unpauses log backups by enabling/disabling Copy Only

.DESCRIPTION
The Pause-SQLBackups script iterates through a list of SQL databases and pauses/unpauses log backups by enabling/disabling Copy Only
Pass the argument (-logAction) to either 'pause' or 'unpause' depending on what you want to do
An email will be sent out with status details everytime the script is run.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/12/20

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM and VARIABLES section with config details for this script.

.EXAMPLE
./Pause-SQLBackups.ps1 -server <Rubrik_server> -token <API_token> -logAction pause
Use an API token for authentication and pauses the listed databases by setting to Copy Only

.EXAMPLE
./Pause-SQLBackups.ps1 -server <Rubrik_server> -logAction unpause
Checks for credential file and if none found prompts for username/password. Unpauses the listed databases by disabling Copy Only

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
  [string]$rubrikCred = 'rubrik_cred.xml',

  # Set $logAction to either "pause" or "unpause"
  [Parameter(Mandatory=$false)]
  [string]$logAction = 'unpause'
)

Import-Module Rubrik

###### VARIABLES - BEGIN ######

# Provide list of database IDs to modify the log backups
$databases = @('MssqlDatabase:::4598cff6-20af-46fe-9605-474cf37c0145')

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$date = Get-Date

$emailSubject = 'Rubrik SQL DB Log Paused/Unpaused - ' + $date.ToString("MM-dd-yyyy")
$html = "Set to $logAction log backups<br><br>"

# Set to $true to send out email at the end of the script
$sendEmail = $false

###### VARIABLES - END ######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
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
###### RUBRIK AUTHENTICATION - END ######

foreach ($i in $databases)
{
  $result = ""

  # If $logAction is to pause log backups, sets the DB to Copy Only
  if ($logAction -eq "pause")
  {
    try
    {
      $result = Set-RubrikDatabase -id $i -CopyOnly:$true -confirm:$false

      if ($result.copyOnly -eq $true)
      {
        $message = "$i ($($result.name)) set to enable Copy Only"
      } else
      {
        $message = "$i had error setting to Copy Only"
      }
    } catch
    {
      $message = "$i had error setting to Copy Only - check that the SQL ID is valid"
    }

    Write-Host $message
    $html += "$message<br>"

  # Else if $logAction is to unpause log backups, disables Copy Only for the DB
  } elseif ($logAction -eq "unpause")
  {
    try
    {
    $result = Set-RubrikDatabase -id $i -CopyOnly:$false -confirm:$false

    if ($result.copyOnly -eq $false)
    {
      $message = "$i ($($result.name)) set to disable Copy Only"
    } else
    {
      $message = "$i had error setting to disable Copy Only"
    }
    } catch {
      $message = "$i had error setting to disable Copy Only - check that the SQL ID is valid"
    }

    Write-Host $message
    $html += "$message<br>"

  }
}

if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}

Disconnect-Rubrik -Confirm:$false
