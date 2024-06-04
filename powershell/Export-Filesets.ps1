
param (
  [CmdletBinding()]
  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$false)]
  [string]$server = '',
  # API token - Get this from the Rubrik UI -> User icon in the right -> grab API token
  [Parameter(Mandatory=$false)]
  [string]$token = $null,
  # Target - NAS Host ID, the suffix of "Host:::"
  [Parameter(Mandatory=$false)]
  [string]$hostID = '',
  # Target - NAS Share ID, the suffix of "HostShare:::"
  [Parameter(Mandatory=$false)]
  [string]$shareID = '',
  # First Fileset to initiate a restore for, 0 is the first item
  [Parameter(Mandatory=$false)]
  [int]$firstRestore = 0,
  # Last Fileset to initiate a restore for
  [Parameter(Mandatory=$false)]
  [int]$lastRestore = 0
)

# CSV of the filesets to restore
$restoreCSV = './restore_fileset_v1.csv'

# Path of logging
$logPath = './rubrik_fileset_restore.log'

# CSV export info
$date = Get-Date
$csvOutput = "./rubrik_restore_fileset_log-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

Start-Transcript -path $logPath -append

Connect-Rubrik -server $server -token $token

$filesets = Import-CSV -Path $restoreCSV
$fsCount = $filesets.Count
Write-Host "Found $fsCount filesets" -foregroundcolor green

for ($i = $firstRestore; $i -le $lastRestore; $i++){
  $restoreDirectory = $($filesets[$i]).NewDirName
  Write-Host "Processing [Row: $i]: $restoreDirectory" -foregroundcolor green
  $restoreBody = [PSCustomObject] @{
    "hostId" = $hostID
    "shareId" = $shareID
    "exportPathPairs" = @(
      @{
        "srcPath" = "/"
        "dstPath" = "$restoreDirectory"
      }
    )
    "ignoreErrors" = $true
    "shouldRecreateDirectoryStructure" = $true
  }
  $req = Invoke-RubrikRESTCall -Method 'POST' -Api 'internal' -Body $bodyJson -Endpoint "fileset/snapshot/$restoreFSID/export_files"
  $req
}

Stop-Transcript

# Code to create new directories
# $filesets = Import-CSV -Path $restoreCSV
# foreach ($fs in $filsets) {
#   New-Item -Path $fs.NewDirName -ItemType Directory
# }
