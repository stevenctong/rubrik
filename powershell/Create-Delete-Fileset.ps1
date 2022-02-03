#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Creates or deletes a fileset from a given list of clusters.

.DESCRIPTION
The Create-Delete-Fileset.ps1 script creates or deletes a fileset from a given list of clusters.
Create a .CSV file with a list of clusters on each line with no header info.
The script will read in the file containing the list of clusters to perform the task on.

- $clusterFile : (required) The CSV file list of clusters

To delete a fileset, provide the following parameter:

- $deleteFilesetName : (required if deleting) Fileset name to delete on all clusters

To create a fileset, provide the following parameters:

$filesetName : (required if creating) Name of the fileset you want to create
$type : (required if creating) Fileset type, either "Windows" or "Linux"
$include : (required if creating) File or folder paths to include
$exclude : (optional if creating)File or folder paths to exclude
$doNotExclude : (optional if creating) File or folder paths to not exclude

The parameters can be defined within the script or passed as command like arguments.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 2/2/22

For authentication, use one of the following methods:
$token - an API token tied to a user account; keep in mind that tokens have an expiration date
$credential - credential file that can be created using: Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
$user and $password - plaintext username and password

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Create-Update-Fileset.ps1 -clusterFile './clusters.csv' -filesetName 'all_files' -type 'Windows' -include '**'
Prompts for authentication. Uses './clusters.csv' as the cluster list and creates a fileset with the arguments provided.

.EXAMPLE
./Create-Update-Fileset.ps1 -clusterFile './clusters.csv' -filesetName 'misc_files' -type 'Linux' -include '**' -exclude "*.mp3" -doNotExclude "fun.mp3"
Prompts for authentication. Uses './clusters.csv' as the cluster list and creates a fileset with the arguments provided.

.EXAMPLE
./Create-Update-Fileset.ps1 -clusterFile './clusters.csv -deleteFilesetName 'misc_files'
Prompts for authentication. Uses './clusters.csv' as the cluster list and deletes the fileset names 'misc_files'

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

  # Fileset name
  [Parameter(Mandatory=$false)]
  [string]$filesetName = '',

  # Fileset type, 'Windows' or 'Linux'
  [Parameter(Mandatory=$false)]
  [string]$type = '',

  # Fileset include list
  [Parameter(Mandatory=$false)]
  [string]$include = '',

  # Fileset exclude list
  [Parameter(Mandatory=$false)]
  [string]$exclude = '',

  # Fileset do not exclude list
  [Parameter(Mandatory=$false)]
  [string]$doNotExclude = '',

  # A name of the Fileset to delete
  [Parameter(Mandatory=$false)]
  [string]$deleteFilesetName = '',

  # CSV list of Rubrik clusters, no header
  [Parameter(Mandatory=$false)]
  [string]$clusterFile = ''
)

Import-Module Rubrik

###### VARIABLES - BEGIN ######

$date = Get-Date

$logPath = "./rubrik_fileset-$($date.ToString("yyyy-MM-dd_HHmm")).log"
$ErrorActionPreference="Continue"

Start-Transcript -path $logPath -append

###### VARIABLES - END #######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if ($token) { Write-Host "Token provided" }
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

$clusterList = Import-CSV $clusterFile -header "Cluster"

if ($deleteFilesetName -ne '') {
  Write-Host "Deleting fileset: $deleteFilesetName" -foregroundcolor green
} else {
  Write-Host "Creating fileset: $filesetName, type: $type" -foregroundcolor green
  Write-Host "Include: $include, Exclude: $exclude, Do Not Exclude: $doNotExclude" -foregroundcolor green
}

Write-Host ""

foreach ($cluster in $clusterList.Cluster) {
  try {
    Write-Host "Connecting to cluster: $cluster" -foregroundcolor green
    $connection = Connect-Rubrik -Server $cluster -Credential $credential

    if ($deleteFilesetName -ne '') {
      $filesets = Get-RubrikFilesetTemplate -name $deleteFilesetName

      $filesetID = ''

      foreach ($fileset in $filesets) {
        if ($fileset.name -eq $deleteFilesetName) {
          $filesetID = $fileset.ID
        }
      }

      if ($filesetID -eq '') {
        Write-Host "No fileset for deletion found on cluster: $cluster"
      } else {
        Write-Host "Deleting fileset on cluster: $cluster" -foregroundcolor green
        Remove-RubrikFilesetTemplate -id $filesetID
      }
    } else
    {
      try {
        Write-Host "Creating fileset on cluster: $cluster" -foregroundcolor green
        if ( ($exclude -eq '') -and ($doNotExclude -eq '') ) {
          New-RubrikFilesetTemplate -Name $filesetName -OperatingSystemType $type -Includes $include
        } elseif ($filesetDoNotExclude -eq '') {
          New-RubrikFilesetTemplate -Name $filesetName -OperatingSystemType $type -Includes $include -Excludes $exclude
        } else {
          New-RubrikFilesetTemplate -Name $filesetName -OperatingSystemType $type -Includes $include -Excludes $exclude -Exceptions $doNotExclude
        }
      } catch {
        Write-Error "Error creating fileset on cluster: $cluster"
      }
    }
  } catch {
    Write-Error "Error connecting to cluster: $cluster"
  }
}

Stop-Transcript
