#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
The Search-Events.ps1 script gets Rubrik events and searches for a particular phrase.

.DESCRIPTION
The Search-Events.ps1 script gets Rubrik events and searches for a particular phrase.
You can pass arguments on what to search for or edit within the script.

A CSV file is created with all the events that match the search phrase.
The CSV file can also be emailed if SMTP info is provided.

Required:
- $phrase: The phrase you want to search for, this can be a regex

Option:
- $hours: Number of hours back to look within the events, default 24 hours

Event filters:
- $eventType: Filter by an event type
- $eventStatus: Filter by an event status
- $objectType: Filter by an object type

The event filters are case sensitive. To get a list of filters, you can
use tab completion for "Get-RubrikEvent -<event_filter>"

Get-RubrikEvent -EventType "Archive,Audit,AuthDomain,AwsEvent,Backup,
Classification,CloudNativeSource,CloudNativeVm,Configuration,Connection,
Conversion,Diagnostic,Discovery,Failover,Fileset,Hardware,HostEvent,HypervScvmm,
HypervServer,Instantiate,LegalHold,Maintenance,NutanixCluster,Recovery,Replication,
Storage,StorageArray,StormResource,Support,System,TestFailover,Upgrade,VCenter,
Vcd,VolumeGroup,UnknownEventType"

Get-RubrikEvent -EventStatus "Failure,Warning,Running,Success,Canceled,Canceling,Queued"

Get-RubrikEvent -ObjectType "AggregateAhvVm,AggregateAwsAzure,AggregateHypervVm,
AggregateLinuxUnixHosts,AggregateNasShares,AggregateOracleDb,AggregateStorageArrays,
AggregateVcdVapps,AggregateVsphereVm,AggregateWindowsHosts,AppBlueprint,AuthDomain,
AwsAccount,AwsEventType,Certificate,Cluster,DataLocation,Ec2Instance,Host,HypervScvmm,
HypervServer,HypervVm,JobInstance,Ldap,LinuxHost,LinuxFileset,ManagedVolume,Mssql,
NasHost,NutanixCluster,NutanixVm,OracleDb,OracleHost,OracleRac,PublicCloudMachineInstance,
SamlSso,ShareFileset,SlaDomain,SmbDomain,StorageArray,StorageArrayVolumeGroup,Storm,
SupportBundle,UnknownObjectType,Upgrade,UserActionAudit,Vcd,VcdVapp,Vcenter,VmwareVm,
VolumeGroup,WindowsHost,WindowsFileset"


.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/7/22

For authentication, use one of the following methods:
$token - an API token tied to a user account; keep in mind that tokens have an expiration date
$credential - credential file that can be created using: Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
$user and $password - plaintext username and password

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Search-Events.ps1 -server <Rubrik_server> -phrase "Completed backup of vSphere VM"
The script will prompt for a username and password for the Rubrik cluster.
Returns all events in the last 24 hours containing the end phrase:
"Completed backup of vSphere VM"

.EXAMPLE
./Search-Events.ps1 -server <Rubrik_server> -token <API_token> -phrase "above the throttling threshold" -hours 12
Use an API token for authentication
Returns all events containing the end phrase "above the throttling threshold" for the last 12 hours

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

  # Search phrase to find within eventInfo field
  [Parameter(Mandatory=$false)]
  [string]$phrase = '',

  # Search within an event type
  [Parameter(Mandatory=$false)]
  [string]$eventType = '',

  # Search within an event status
  [Parameter(Mandatory=$false)]
  [string]$eventStatus = '',

  # Search within an object type, for example: 'VmwareVm' (case sensitive)
  [Parameter(Mandatory=$false)]
  [string]$objectType = '',

  # Search for a particular eventName
  # [Parameter(Mandatory=$false)]
  # [string]$eventName = '',

  # How many hours back to search for
  [Parameter(Mandatory=$false)]
  [int]$hours = 24
)

Import-Module Rubrik

###### VARIABLES - BEGIN ######

$date = Get-Date

# Get current date in UTC and calculate the UTC offset in minutes
$utcDate = $date.ToUniversalTime()
$utcDiff = $date - $utcDate
$utcDiffMinutes = $utcDiff.TotalMinutes

# Number of events to get in each API call
$eventLimit = 100

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
$csvOutput = "./rubrik_events_results-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

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

# Create a hash file of parameters to pass into Rubrik Events API call
$splat = @{}

$splat.add("limit",$eventLimit)

if ($eventType -ne '') {
  $splat.add("eventType",$eventType)
}

if ($eventStatus -ne '') {
  $splat.add("status",$eventStatus)
}

if ($objectType -ne '') {
  $splat.add("objectType",$objectType)
}

Write-Host ""
Write-Host "Current time is: $date" -foregroundcolor green
Write-Host "Current UTC time is: $utcDate" -foregroundcolor green
Write-Host "UTC offset: $utcDiffMinutes minutes" -foregroundcolor green
Write-Host "Searching for phrase: $phrase" -foregroundcolor green
Write-Host ""
Write-Host "Getting latest events for the last $hours hour(s)"

# List of events that match the phrase we are looking for
$eventList = @()

# Get Rubrik Events as long as it is less than the number of hours to search for
do {
  # Get Rubrik Events via API call
  $events = Get-RubrikEvent @splat
  Write-Host "Processing $($events.count) events with last event time: $($events[-1].time.addMinutes($utcDiffMinutes))"
  # For each event that is returned, check if it matches the phrase and add to list if it does
  foreach ($eventItem in $events)
  {
    if ( ($eventItem.eventInfo -match $phrase) -and ($eventItem.time -lt $utcDate) )
    {
      $eventList += $eventItem
    }
  }
  # Update the Rubrik Events API to get events after the last one we already got it for
  $splat.afterId = $events[-1].afterId
  # While we still have new events or the events are still within the hours we want
} while ( ($events -ne $null) -and (($utcDate - $events[-1].time).hours -lt $hours) )


# Export the list to a CSV file
$eventList | Export-Csv -NoTypeInformation -Path $csvOutput
Write-Host "`nResults output to: $csvOutput"

# Send an email with CSV attachment
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
}
