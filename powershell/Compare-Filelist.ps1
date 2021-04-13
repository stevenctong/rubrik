#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS

.DESCRIPTION


.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/12/23

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./

.EXAMPLE
./

#>

param (
  [CmdletBinding()]

  # 1st CSV file to compare
  [Parameter(Mandatory=$false)]
  [string]$csvfile1 = '',

  # 2nd CSV file to diff against
  [Parameter(Mandatory=$false)]
  [string]$csvfile2 = ''
)

$date = Get-Date
$csvOutput = "./rubrik-filelist_diff-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

$csv1 = Import-CSV $csvfile1
$csv2 = Import-CSV $csvfile2

$comp = Compare-Object -ReferenceObject $csv1.fullfilename -differenceobject $csv2.fullfilename

$inCSV1 = @()
$inCSV2 = @()

foreach ($i in $comp)
{
  $i
  if ($i.SideIndicator -eq '=>')
  {
    $inCSV2 += $i.InputObject
  } else {
    $inCSV1 += $i.InputObject
  }
}

$inCSV1 | Export-Csv -NoTypeInformation -Path "./rubrik-in_CSV1-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
$inCSV2 | Export-Csv -NoTypeInformation -Path "./rubrik-in_CSV2-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
