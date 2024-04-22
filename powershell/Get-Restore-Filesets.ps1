
# Rubrik cluster hostname / IP
$server = ''

# Get this from the Rubrik UI -> User icon in the right -> grab API token
$token = ''

Connect-Rubrik -server $server -token $token

$filesetCSV = './fileset_list_v1.csv'
$directoryCSV = './dir_list_v1.csv'

# To get a specific fileset only, use:
# $filesets = Get-RubrikFileset -name <name>
$filesets = Get-RubrikFileset
$fsCount = $filesets.Count

Write-Host "Found $fsCount filesets" -foregroundcolor green

$objArray = @()
$count = 1

foreach ($fs in $filesets) {
  if ( $count % 10 -eq 0 ) {
    Write-Host "[ $count / $fsCount ] Getting latest snapshot for each fileset..."
  }
  $count++
  $fsInfo = Get-RubrikFileset -id $fs.id
  try {
    $latestBackup = $($fsinfo.snapshots)[-1]
  } catch {
    $latestBackup = ""
  }
  $obj = [PSCustomObject] @{
    "FilesetName" = $fsInfo.name
    "HostName" = $fsInfo.hostName
    "FilesetID" = $fsInfo.id
    "LatestBackupDate" = $latestBackup.date
    "LatestBackupID" = $latestBackup.id
    "isOnDemandSnasphot" = $latestBackup.isOnDemandSnasphot
    "cloudState" = $latestBackup.cloudState
    "slaName" = $latestBackup.slaName
  }
  $objArray += $obj
}

Write-Host "Exporting fileset list to: $filesetCSV" -foregroundcolor green
$objArray | Export-CSV -Path $filesetCSV

$dirArray = @()
$objCount = $objArray.count
$count = 1

foreach ($snap in $objArray) {
  if ( $count % 5 -eq 0 ) {
    Write-Host "[ $count / $objCount ] Getting directory info for each fileset... (last processed: $($snap.FilesetName))"
  }
  $count++
  try {
    $dirPath = '\'
    $query = @{
      'snapshot_id' = $snap.LatestBackupID
      'path' = $dirPath
    }
    $dirList = Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "browse" -query $query
    while ($dirList.data.count -eq 1) {
      if ($dirPath -eq '\') {
        $dirPath = "\$($dirList.data.path)"
      } else {
        $dirPath = "$($dirPath)\$($dirList.data.path)"
      }
      $query = @{
        'snapshot_id' = $snap.LatestBackupID
        'path' = $dirPath
      }
      $dirList = Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "browse" -query $query
    }
    foreach ($dir in $dirList.data) {
      $dir = [PSCustomObject] @{
        "FilesetName" = $snap.FilesetName
        "HostName" = $snap.HostName
        "FilesetID" = $snap.FilesetID
        "LatestBackupDate" = $snap.LatestBackupDate
        "LatestBackupID" = $snap.LatestBackupID
        "RootPath" = $dirPath
        "Filename" = $dir.filename
        "Path" = $dir.path
        "LastModified" = $dir.lastModified
        "FileMode" = $dir.fileMode
        "Size" = $dir.size
        "SizeMiB" = [math]::round($($dir.size) / 1048576, 2)
      }
      $dirArray += $dir
    } ### foreach
  } catch {
    $dir = [PSCustomObject] @{
      "FilesetName" = $snap.FilesetName
      "HostName" = $snap.HostName
      "FilesetID" = $snap.FilesetID
      "LatestBackupDate" = $snap.LatestBackupDate
      "LatestBackupID" = $snap.LatestBackupID
      "RootPath" = ""
      "Filename" = ""
      "Path" = ""
      "LastModified" = ""
      "FileMode" = ""
      "Size" = ""
      "SizeMiB" = ""
    }
    $dirArray += $dir
  }
}

Write-Host "Exporting directory list to: $directoryCSV" -foregroundcolor green
$dirArray | Export-CSV -Path $directoryCSV
