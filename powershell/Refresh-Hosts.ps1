#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Reads in a CSV file of hosts and refreshes them

.DESCRIPTION
Reads in a CSV file of hosts and refreshes them

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 1/16/21

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the VARIABLES section with config details for this script.

.EXAMPLE
./Refresh-Hosts.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication.

.EXAMPLE
./Refresh-Hosts.ps1 -server <Rubrik_server>
Checks for credential file and if none found prompts for username/password.

#>

Import-Module Rubrik

###### VARIABLES - BEGIN ######

# CSV File containing a comma separated list of hosts to refresh
$csvInput = 'hostlist.csv'

# CSV file info
$csvOutput = "./refreshed_hosts-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

###### VARIABLES - END #######

###### RUBRIK AUTHENTICATION - BEGIN ######

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

$hostlist = Import-CSV $csvInput -Header 'host'
$csvList = @()

foreach ($i in $hostList.host)
{
  Write-Host "Refreshing host $i" -foregroundcolor "green"

  try {
    Get-RubrikHost -Name $i | Update-RubrikHost -verbose
    $csvList += $i
  } catch {
    Write-Error "Error refreshing host $i"
  }
}

# Export some list to a CSV file
$csvList | Export-Csv -NoTypeInformation -Path $csvOutput
Write-Host "`nResults output to: $csvOutput"
