<#
.SYNOPSIS
This script will initiate a restore of a SQL DB to all hosts in a SQL AG.

.DESCRIPTION
This script will initiate a restore of a SQL DB to all hosts in a SQL AG.

The script currently uses the latest recovery point for the restore job.

.NOTES
Written by Chris Lumnah & Steven Tong for community usage
GitHub: stevenctong
Date: 5/25/23

For authentication, provide a RSC Service Account JSON defined at variable $serviceAccountPath.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Rubrik-SQL-ExportToAG.ps1
#>

###### VARIABLES - BEGIN ######

# Rubrik Connection Information
$ServiceAccountPath = 'rsc_service_account.json'
$ServiceAccountContent = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json

$Server.access_token_uri
$ServiceAccountID = $ServiceAccountContent.client_id
$Secret = $ServiceAccountContent.client_secret

# Primary SQL Server
$PrimarySQLServerInstance = 'ag1host.com'

# Secondary SQL Servers
$SecondarySQLServerInstance = 'ag2host.com', 'ag3host.com'

# Availability Group Name
$AvailabilityGroupName = 'aggroup'
# Source Database Name
$DatabaseName = 'ProductionDatabase'
# Target Database Name
$TargetDatabaseName = 'restoredDB'

# Append the following to the existing filenames to avoid conflicts
$FilenameAppend = '_restoredDB'

###### VARIABLES - END ######

Connect-RubrikSecurityCloud -ServiceAccountPath $ServiceAccountPath

Write-Host "Refreshing the SQL DB Hosts... (45 secs)" -foregroundcolor green

$QueryParms = @{
    "hostname" = "$($PrimarySQLServerInstance)"
    "instance" = "MSSQLSERVER"
}
$RSCMSQLInstance = Invoke-RubrikQuery -Path ./GetMSSQLInstance.gql -QueryParams $QueryParms

$QueryParms = @{
    "id" = "$($RSCMSQLInstance.id)"
}
 Invoke-RubrikQuery -Path ./PhysicalHostRefreshMutation.gql -QueryParams $QueryParms

foreach ($SQLInstance in $SecondarySQLServerInstance){
    $QueryParms = @{
        "hostname" = "$($SQLInstance)"
        "instance" = "MSSQLSERVER"
    }
    $RSCMSQLInstance = Invoke-RubrikQuery -Path ./GetMSSQLInstance.gql -QueryParams $QueryParms

    $QueryParms = @{
        "id" = "$($RSCMSQLInstance.id)"
    }
    Invoke-RubrikQuery -Path ./PhysicalHostRefreshMutation.gql -QueryParams $QueryParms
}
Start-Sleep -Seconds 45

Write-Host "Getting ID of AG: $AvailabilityGroupName" -foregroundcolor green

$QueryParms = @{
    "AvailabilityGroupName" = $($AvailabilityGroupName)
}
$RSCMSSQLAvailabilityGroup = Invoke-RubrikQuery -Path ./GetMSSQLAvailabilityGroup.gql -QueryParams $QueryParms

if ($RSCMSSQLAvailabilityGroup.id -eq $null) {
    Write-Error "No AG found with name: $AvailabilityGroupName"
}

if ($RSCMSSQLAvailabilityGroup.count -gt 1) {
    Write-Error "Multiple AG found with name: $AvailabilityGroupName"
}
$RSCMSSQLAvailabilityGroup

Write-Host "Getting ID of DB: $DatabaseName on the AG."

$QueryParms = @{
    "fid" = "$($RSCMSSQLAvailabilityGroup.id)"
    "DatabaseName" = "$($DatabaseName)"
}
$RSCMSSQLDatabase = Invoke-RubrikQuery -Path ./GetMSSQLDatabaseFromAvailabilityGroup.gql -QueryParams $QueryParms

if ($RSCMSSQLDatabase.logicalChildConnection.nodes.count -eq 0) {
    Write-Error "No database found with name: $DatabaseName, on AG: $AvailabilityGroupName"
}
$RSCMSSQLDatabase.logicalChildConnection.nodes

Write-Host "Getting the latest recovery point." -foregroundcolor green

$QueryParms = @{
    "id" = "$($RSCMSSQLDatabase.logicalChildConnection.nodes[0].id)"
}
$RSCMSSQLRecoverableRange = Invoke-RubrikQuery -Path ./MssqlDatabaseDetailsRecoverableRangesQuery.gql -QueryParams $QueryParms | Sort-Object {$_.data.endTime}
$RSCMSSQLDatabaseLatestRecoveryPoint = ($RSCMSSQLRecoverableRange.data.endTime[-1]).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$RSCMSSQLDatabaseLatestRecoveryPoint

Write-Host "Getting the original DB file locations." -foregroundcolor green

$QueryParms = @{
    "input" = @{
        "id" = "$($RSCMSSQLDatabase.logicalChildConnection.nodes[0].id)"
        "time" = $($RSCMSSQLDatabaseLatestRecoveryPoint)
    }
}
$RSCMSSQLFileLocations = Invoke-RubrikQuery -Path ./AllMssqlDatabaseRestoreFilesQuery.gql -QueryParams $QueryParms

$TargetFilePaths = @()

foreach ($DBfile in $RSCMSSQLFileLocations.items) {
    $originalName = [system.io.fileinfo]$DBFile.originalName
    $newFilename = $originalName.Basename + $FilenameAppend +  $originalName.Extension
    $targetFilePath = @{
        "newFilename" = $newFilename
        "exportPath" = $DBfile.originalPath
        "logicalName" = $DBFile.logicalName
    }
    $TargetFilePaths += $targetFilePath
}

$targetFilePaths

Write-Host "Initiating the restore to the secondary replicas and keeping in restoring mode." -foregroundcolor green

foreach ($SQLInstance in $SecondarySQLServerInstance){
    $QueryParms = @{
        "hostname" = "$($SQLInstance)"
        "instance" = "MSSQLSERVER"
    }
    $RSCMSQLInstance = Invoke-RubrikQuery -Path ./GetMSSQLInstance.gql -QueryParams $QueryParms
    $RSCMSQLInstance

    $QueryParms = @{
        "input" = @{
            "id" = "$($RSCMSSQLDatabase.logicalChildConnection.nodes[0].id)"
            "config" = @{
                "recoveryPoint" = @{
                    "date" = "$($RSCMSSQLDatabaseLatestRecoveryPoint)"
                }
                "targetInstanceId" = "$($RSCMSQLInstance.physicalChildConnection.nodes.id)"
                "targetDatabaseName" = "$($TargetDatabaseName)"
                "targetDataFilePath" = ""
                "targetLogFilePath" = ""
                "targetFilePaths" = $TargetFilePaths
                "allowOverwrite" = $true
                "finishRecovery" = $false
            }
        }
    }
    Invoke-RubrikQuery -Path ./MssqlDatabaseExportMutation.gql -QueryParams $QueryParms
}

Write-Host "Initiating the restore to the primary replica." -foregroundcolor green

$QueryParms = @{
    "hostname" = "$($PrimarySQLServerInstance)"
    "instance" = "MSSQLSERVER"
}
$RSCMSQLInstance = Invoke-RubrikQuery -Path ./GetMSSQLInstance.gql -QueryParams $QueryParms
$RSCMSQLInstance

$QueryParms = @{
    "input" = @{
        "id" = "$($RSCMSSQLDatabase.logicalChildConnection.nodes[0].id)"
        "config" = @{
            "recoveryPoint" = @{"date" = "$($RSCMSSQLDatabaseLatestRecoveryPoint)"}
            "targetInstanceId" = "$($RSCMSQLInstance.physicalChildConnection.nodes.id)"
            "targetDatabaseName" = "$($TargetDatabaseName)"
            "targetDataFilePath" = ""
            "targetLogFilePath" = ""
            "targetFilePaths" = $TargetFilePaths
            "allowOverwrite" = $true
            "finishRecovery" = $true
        }
    }
}
Invoke-RubrikQuery -Path ./MssqlDatabaseExportMutation.gql -QueryParams $QueryParms
