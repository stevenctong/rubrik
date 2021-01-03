#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

# Written by Steven Tong for community usage
# GitHub: stevenctong
# Date: 10/24/20

# Updates the password for a list of Rubrik clusters
# The script will prompt for the list of Rubrik clusters or you can define $rubrikClustersList
# The script will prompt for credentials to log into the clusters with
# The script will prompt for the username and new password you want to update the user with

Import-Module Rubrik

# Prompt for Rubrik clusters to update passwords
[string]$rubrikClusters = Read-Host -Prompt "Provide comma separated list of Rubrik clusters"
[array]$rubrikClustersList = $RubrikClusters.Split(",")

# Provide a list of Rubrik clusters in the script
# $rubrikClustersList = @('cluster1','cluster2')

Write-Host "`nProvide credentials to login to the Rubrik clusters"
$credential = Get-Credential

$updateUsername = Read-Host -Prompt "`nWhat is the username you want to update"

$updatePW = Read-Host -Prompt "What is the new password you want to set (must be complex)" -AsSecureString
$updatePWcheck = Read-Host -Prompt "Enter the password again" -AsSecureString

$updateUserPW = ConvertFrom-SecureString -SecureString $updatePW -AsPlainText
$updateUserPWcheck = ConvertFrom-SecureString -SecureString $updatePWcheck -AsPlainText

do {
  if ($updateUserPW -notMatch $updateUserPWcheck)
  {
    Write-Host "`nPasswords entered do not match, please try again" -ForegroundColor Red

    $updatePW = Read-Host -Prompt "What is the new password you want to set (must be complex)" -AsSecureString
    $updatePWcheck = Read-Host -Prompt "Enter the password again" -AsSecureString

    $updateUserPW = ConvertFrom-SecureString -SecureString $updatePW -AsPlainText
    $updateUserPWcheck = ConvertFrom-SecureString -SecureString $updatePWcheck -AsPlainText
  }
} while ($updateUserPW -notMatch $updateUserPWcheck)

# Build JSON with password to update the user with
$exportJson = New-Object PSObject
$exportJson | Add-Member -MemberType NoteProperty -Name "password" -Value $updateUserPW

foreach ($i in $rubrikClustersList)
{
  try
  {
    Connect-Rubrik -server $i -Credential $credential

    $rubrikUser = Get-RubrikUser -username $updateUsername

    $userName = $rubrikUser | Select -ExpandProperty "Username"
    $userID = $rubrikUser | Select -ExpandProperty "ID"

    Write-Host "`nUpdating user: $UserName on Cluster: $i`n" -ForegroundColor Green

    $result = Invoke-RubrikRESTCall -Method "Patch" -Api "internal" -Body $exportJson -Endpoint "user/$userID" -Verbose
  }
  catch
  {
    Write-Error "`ERROR updating user: $UserName on Cluster: $i`n"
  }
  $disconnect = Disconnect-Rubrik -Confirm:$false
}

Clear-Variable exportJson
Clear-Variable updatePW
Clear-Variable updateUserPWcheck
