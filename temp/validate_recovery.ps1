# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will un-zip a file and calculate md5 checksums for recovery validation.

.DESCRIPTION
This script will un-zip a file and calculate md5 checksums for recovery validation.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/19/23

.EXAMPLE
./valdate_recovery.ps1
Runs the script with the parameters defined within.
#>

# Directory path where the .zip file will be stored in
$filePath = "."
# Filename of the .zip file, can use wildcards
$fileName = "RUBRIKTEST*"
# Staging directory to un-zip the files into
$stagingDir = "$filePath/Staging"
# Log file
$logFile = "./validate_recovery.log"

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$date = Get-Date
$emailSubject = "Mainframe recovery test - " + $date.ToString("yyyy-MM-dd")

# Set to $true to send out email in the script
$sendEmail = $false

Start-Transcript -Path "$logFile" -Append

Write-Host "Getting a list of all files in designated directory" -ForegroundColor Green
$fileList = Get-ChildItem -Path "$filePath/" -Filter "$fileName" |
  Sort-Object -Property 'LastWriteTime' -Descending

if ($fileList.count -eq 0) {
  Write-Error "No file found in path: $filePath, name: $fileName"
  Write-Error "Exiting..."
  if ($sendEmail)
  {
    $emailBody = "No file found in path: $filePath, name: $fileName"
    Write-Host "Sending email to: $emailTo, from: $emailFrom, subject: $emailSubject" -ForegroundColor Green
    Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $emailbody -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
  }
  Stop-Transcript
  exit
}

Write-Host "Newest file is:" -ForegroundColor Green
$fileList[0]
Write-Host ""

$fileTime = $($fileList[0].LastWriteTime).ToString("yyyy-MM-dd-HHmm")

# Expand the .zip file into the $stagingDir directory
Expand-Archive -Path $fileList[0].fullName -DestinationPath "$stagingDir"
# Get a list of all extracted files
$extractedFiles = Get-ChildItem -Path "$stagingDir" -File
if ($extractedFiles.count -eq 0) {
  Write-Error "No files were extracted... Exiting"
  if ($sendEmail)
  {
    $emailBody = "No files were extracted... Exiting"
    Write-Host "Sending email to: $emailTo, from: $emailFrom, subject: $emailSubject" -ForegroundColor Green
    Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $emailbody -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
  }
  Stop-Transcript
  exit
}
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

# Deleting all files in the staging directory
Get-ChildItem -Path $stagingDir | Remove-Item -Force

# Send an email
if ($sendEmail)
{
  Write-Host "Sending email to: $emailTo, from: $emailFrom, subject: $emailSubject" -ForegroundColor Green
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $emailbody -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
}

Stop-Transcript
