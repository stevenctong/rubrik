#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Gets the all snapshots and their expiration dates for a particular particular object.

.DESCRIPTION
The Get-RubrikSnapshots.ps1 script gets all snapshots and their expiration dates for a particular object.
Provide the following to run the script:

-name : VM name or hostname
-type : 'vmware' or 'fileset'

The results will be output to a CSV file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 1/20/22
Updated: 4/4/22

For authentication, use one of the following methods:
$token - an API token tied to a user account; keep in mind that tokens have an expiration date
$credential - credential file that can be created using: Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
$user and $password - plaintext username and password

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Get-RubrikSnapshots.ps1 -server <Rubrik_server> -name 'vm1' -type 'vmware'
The script will prompt for a username and password for the Rubrik cluster

./Get-RubrikSnapshots.ps1 -server <Rubrik_server> -name 'hostname1' -type 'fileset'
The script will prompt for a username and password for the Rubrik cluster

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

  # VM name or physical host name to get snapshot details for
  [Parameter(Mandatory=$false)]
  [string]$name = '',

  # Object type: vmware, fileset
  [Parameter(Mandatory=$false)]
  [string]$type = ''
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
$csvOutput = "./$($name)_snapshotList-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

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

# Holds the list of snapshots
$snapshotList = @()

switch ($type)
{
  "vmware" {
    $objInfo = Get-RubrikVM -name $name -DetailedObject

    foreach ($snap in $objInfo.snapshots)
    {
      $locationCount = $snap.snapshotRetentionInfo.localInfo.name.count +
        $snap.snapshotRetentionInfo.archivalInfos.name.count +
        $snap.snapshotRetentionInfo.replicationInfos.name.count

      $snapshotInfo = [PSCustomObject]@{
        Name = $objInfo.name
        vmID = $objInfo.id
        DateUTC = $snap.date
        IsOnDemand = $snap.isOnDemandSnapshot
        CloudState = $snap.cloudState
        SLA = $snap.SlaName
        locationCount = $locationCount
        snapID = $snap.id
        Local = $snap.snapshotRetentionInfo.localInfo.name
        LocalExpirationUTC = $snap.snapshotRetentionInfo.localInfo.expirationTime
        Archive = $snap.snapshotRetentionInfo.archivalInfos.name
        ArchiveExpirationUTC = $snap.snapshotRetentionInfo.archivalInfos.expirationTime
        Replication = $snap.snapshotRetentionInfo.replicationInfos.name
        ReplicationExpirationUTC = $snap.snapshotRetentionInfo.replicationInfos.expirationTime
      }

      $snapshotInfo
      $snapshotList += $snapshotInfo
    }
  }
  "fileset" {
    $filesetList = Get-RubrikFileset -hostName $name

    foreach ($fileset in $filesetList)
    {
      $objInfo = Get-RubrikFileset -id $fileset.id

      foreach ($snap in $objInfo.snapshots)
      {
        $locationCount = $snap.snapshotRetentionInfo.localInfo.name.count +
          $snap.snapshotRetentionInfo.archivalInfos.name.count +
          $snap.snapshotRetentionInfo.replicationInfos.name.count

        $snapshotInfo = [PSCustomObject]@{
          Name = $objInfo.name
          vmID = $objInfo.id
          DateUTC = $snap.date
          IsOnDemand = $snap.isOnDemandSnapshot
          CloudState = $snap.cloudState
          SLA = $snap.SlaName
          locationCount = $locationCount
          snapID = $snap.id
          Local = $snap.snapshotRetentionInfo.localInfo.name
          LocalExpirationUTC = $snap.snapshotRetentionInfo.localInfo.expirationTime
          Archive = $snap.snapshotRetentionInfo.archivalInfos.name
          ArchiveExpirationUTC = $snap.snapshotRetentionInfo.archivalInfos.expirationTime
          Replication = $snap.snapshotRetentionInfo.replicationInfos.name
          ReplicationExpirationUTC = $snap.snapshotRetentionInfo.replicationInfos.expirationTime
        }

        $snapshotInfo
        $snapshotList += $snapshotInfo
      }
    }
  }
  default { Write-Error "No matching type provided"; exit }
}

# Export some list to a CSV file
$snapshotList | Export-Csv -NoTypeInformation -Path $csvOutput
Write-Host "`nResults output to: $csvOutput"

# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}
