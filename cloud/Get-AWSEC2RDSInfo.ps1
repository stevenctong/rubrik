#requires -modules AWSPowerShell.NetCore

# https://build.rubrik.com

<#
.SYNOPSIS
Gets all EC2 and RDS instances with the # of attached volumes and provisioned sizes.

.DESCRIPTION
The 'Get-AWSEC2RDSInfo.ps1' script gets all EC2 instance and RDS info in the specified region(s).
For each EC2 instance it grabs the total number of volumes and total size for all volumes.
For each RDS instance it grabs the total provisioned size.
A summary of the total # of instances, # of volumes, RDS instance, and capacity will be output to console.

A CSV file will be exported with the details.
You should copy/paste the console output to send along with the CSV.

Update the region list ($regions) with the regions you want to pull info from.

Run in AWS CloudShell or use 'Set-AWSCredential' to set the AWS credentials to run with.
See: https://docs.aws.amazon.com/powershell/latest/userguide/pstools-getting-started.html

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/8/21
Updated: 2/24/21

.EXAMPLE
./Get-AWSEC2RDSInfo.ps1
Runs the script to get all EC2 and associated volume info and output to a CSV file.

#>

$date = Get-Date

# Filenames of the CSVs output
$outputEc2Disk = "aws_vol_info-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
$outputRDS = "aws_rds_info-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# List of AWS regions for reference, get current regions using 'Get-AWSRegion'
$regionsUS = @( 'us-east-1', 'us-east-2', 'us-west-1', 'us-west-2')
$regionsISO = @( 'us-iso-east-1', 'us-isob-east-1')
$regionsEU = @( 'eu-central-1', 'eu-north-1', 'eu-south-1', 'eu-west-1', 'eu-west-2', 'eu-west-3')
$regionsAPAC = @( 'ap-east-1', 'ap-northeast-1', 'ap-northeast-2', 'ap-northeast-3',
                  'ap-south-1', 'ap-southeast-1', 'ap-southeast-2')
$regionsCAN = @( 'ca-central-1' )
$regionsME = @( 'me-south-1' )
$regionsSA = @( 'sa-east-1' )

# Set the regions that you want to get EC2 instance and volume details for
$regions = @()

# This adds the US Regions to the regions list
$regions += $regionsUS

Write-Host "Importing AWS Powershell module" -foregroundcolor green
Import-Module AWSPowerShell.NetCore

Write-Host "Current identity:" -foregroundcolor green
Get-STSCallerIdentity | format-table

# Contains list of EC2 instances and RDS with capacity info
$ec2list = @()
$rdsList = @()

# For all specified regions get the EC2 instance and RDS info
foreach ($region in $regions) {
  Write-Host "Getting EC2 instance info for region: $region" -foregroundcolor green
  $ec2instances = (Get-EC2Instance -region $region).instances

  foreach ($ec2 in $ec2instances) {
    $volSize = 0
    # Contains list of attached volumes to the current EC2 instance
    $volumes = $ec2.BlockDeviceMappings.ebs

    # Iterate through each volume and sum up the volume size
    foreach ($vol in $volumes) {
      $volSize += (Get-EC2Volume -VolumeId $vol.VolumeId -region $region).size
    }

    $ec2obj = [PSCustomObject] @{
      "InstanceId" = $ec2.InstanceId
      "Name" = $ec2.tags.name
      "Volumes" = $volumes.count
      "SizeGiB" = $volSize
      "SizeGB" = [math]::round($($volSize * 1.073741824), 3)
      "Region" = $region
      "InstanceType" = $ec2.InstanceType
      "Platform" = $ec2.Platform
    }

    $ec2list += $ec2obj
  }

  Write-Host "Getting RDS info for region: $region" -foregroundcolor green
  $rdsDBs = Get-RDSDBInstance -region $region

  foreach ($rds in $rdsDBs) {
    $rdsObj = [PSCustomObject] @{
      "RDSInstance" = $rds.DBInstanceIdentifier
      "SizeGiB" = $rds.AllocatedStorage
      "SizeGB" = [math]::round($($rds.AllocatedStorage * 1.073741824), 3)
      "RDSInstanceARN" = $rds.DBInstanceArn
      "Region" = $region
      "InstanceType" = $rds.DBInstanceClass
      "Platform" = $rds.Engine
    }

    $rdsList += $rdsObj
  }
}

$ec2TotalGiB = ($ec2list.sizeGiB | Measure -Sum).sum
$ec2TotalGB = ($ec2list.sizeGB | Measure -Sum).sum

$rdsTotalGiB = ($rdsList.sizeGiB | Measure -Sum).sum
$rdsTotalGB = ($rdsList.sizeGB | Measure -Sum).sum

Write-Host
Write-Host "Total # of EC2 instances: $($ec2list.count)" -foregroundcolor green
Write-Host "Total # of volumes: $(($ec2list.volumes | Measure -Sum).sum)" -foregroundcolor green
Write-Host "Total capacity of all volumes: $ec2TotalGiB GiB or $ec2TotalGB GB" -foregroundcolor green

Write-Host
Write-Host "Total # of RDS instances: $(($rdsList.Database -ne '').count)" -foregroundcolor green
Write-Host "Total provisioned capacity of all RDS instances: $rdsTotalGiB GiB or $rdsTotalGB GB" -foregroundcolor green

# Export to CSV
Write-Host ""
Write-Host "CSV file output to: $outputRDS" -foregroundcolor green
$rdsList | Export-CSV -path $outputRDS
Write-Host "CSV file output to: $outputEc2Disk" -foregroundcolor green
$ec2List | Export-CSV -path $outputEc2Disk
