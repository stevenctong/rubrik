# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will un-zip a file and calculate md5 checksums for validation.

.DESCRIPTION
This script will un-zip a file and calculate md5 checksums for validation.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/15/23

.EXAMPLE
./valdate_zip.ps1
Runs the script with the parameters defined within.
#>

# Directory path where the .zip file will be stored in
$filePath = "."
# Filename of the .zip file, can use wildcards
$fileName = "RUBRIKTEST*"
# Staging directory to un-zip the files into
$stagingDir = "$filePath/Staging"
# CSV file to store results in
$csvOutput = "./md5_history.csv"

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$date = Get-Date
$emailSubject = "Mainframe validation checksums - " + $date.ToString("yyyy-MM-dd")

# Set to $true to send out email in the script
$sendEmail = $false

Write-Host "Importing existing MD5 history CSV" -ForegroundColor Green
$md5History = Import-CSV -Path $csvOutput

Write-Host "Getting a list of all files in designated directory" -ForegroundColor Green
$fileList = Get-ChildItem -Path "./" -Filter "$fileName" |
  Sort-Object -Property 'LastWriteTime' -Descending

Write-Host "Newest file is:" -ForegroundColor Green
$fileList[0]
Write-Host ""

$fileTime = $($fileList[0].LastWriteTime).ToString("yyyy-MM-dd-HHmm")

if ($md5History.Date -contains $fileTime) {
  Write-Host "Newest already has a md5 sum calculated, skipping calculations..." -ForegroundColor Yellow
  $emailBody = "Newest already has a md5 sum calculated, skipping calculations..."
  $emailbody += $fileList[0]
} else {
  # Expand the .zip file into the $stagingDir directory
  Expand-Archive -Path $fileList[0].fullName -DestinationPath "$filePath/$stagingDir"
  # Get a list of all extracted files
  $extractedFiles = Get-ChildItem -Path "$stagingDir" -File
  $md5List = @()
  # Calculate the md5 of each file and add to $md5List
  foreach ($file in $extractedFiles) {
      $md5 = Get-FileHash -Path $file.FullName -Algorithm MD5
      Write-Host "File: $($file.Name) / MD5: $($md5.Hash)" -ForegroundColor Cyan
      $fileDetail = [PSCustomObject] @{
        "Date" = $fileTime
        "Filename" = $($file.Name)
        "MD5" = $($md5.Hash)
      }
      $md5List += $fileDetail
      # Use this block if you want to just append to an existing CSV file
      # $csvString = $fileDetail | ConvertTo-Csv -NoTypeInformation
      # $csvString | Out-File -FilePath $csvOutput -Append
  }
  $emailBody = $md5List
  # Concatenate the newly calculated list with the older list
  $newMD5List = $md5List + $md5History
  # Export to CSV
  Write-Host "Exporting to CSV: $csvOutput" -ForegroundColor Green
  $newMD5List | Export-Csv -Path $csvOutput -NoTypeInformation -Force
  # Deleting all files in the staging directory
  Get-ChildItem -Path $stagingDir | Remove-Item -Force
}

# Send an email
if ($sendEmail)
{
  Write-Host "Sending email to: $emailTo, from: $emailFrom" -ForegroundColor Green
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $emailbody -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
}
