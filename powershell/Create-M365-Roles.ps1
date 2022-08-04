<#
.SYNOPSIS
This script will automatically create a Rubrik role with a SharePoint site
prefix and OneDrive email addresses based on a mapping file.

.DESCRIPTION
This script will automatically create a Rubrik role with a SharePoint site
prefix and OneDrive email addresses based on a mapping file.

Requires a mapping file with the following columns:
- Department: Departmental prefix to look for in the SharePoint site names
- User: Rubrik user account email address to add to a role

This script will create a custom role with the department prefix if not found.
The script will add all SharePoint Sites the department prefix to the custom role.
The script will add all user email addresses to the custom role.

To get the M365 Subscription ID, visit the M365 dashboard and the subscription ID
will be in the URL.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 8/4/22

For authentication, it looks for a Rubrik credential file located here:
- $rubrikCredFile = "./RubrikCloudCredentials.xml"

If the credential file is not found it will prompt for login usernames
and password and save it as a credential file.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Create-M365-Roles.ps1 -rubrikURL <rubrik_url>  -subscriptionID <M365_ID> -mappingFile <mapping.csv>
The script will prompt for a username and password for the Rubrik cluster

#>


param (
  [CmdletBinding()]

  # Rubrik Security Cloud URL
  [Parameter(Mandatory=$false)]
  [string]$rubrikURL = '',

  # M365 Subscription ID
  [Parameter(Mandatory=$false)]
  [string]$subscriptionID = '12345678-d57e-451c-a40a-abcdefghijk',

  # Mapping file
  [Parameter(Mandatory=$false)]
  [string]$mappingFile = 'mapping.csv'
)


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
$csvOutput = "./<name>-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

###### RUBRIK AUTHENTICATION - BEGIN ######

# Alternative authentication using Rubrik M365 SDK
# Connect-Polaris

# Setting credential file
$rubrikCredFile = "./RubrikCloudCredentials.xml"

# Testing if file exists
$rubrikCredFileTest =  Test-Path $rubrikCredFile

# If doesn't exist, prompting and saving credentials
If ($rubrikCredFileTest -eq $False)
{
  $rubrikCreds = Get-Credential -Message "Enter Rubrik Security Cloud login credentials"
  $rubrikCreds | Export-CLIXML $rubrikCredFile -Force
} else {
  # Importing credentials
  $rubrikCreds = Import-CLIXML $rubrikCredFile
}

# Getting Rubrik Cloud credentials
$payload = @{
  username = $rubrikCreds.userName
  password = $rubrikCreds.GetNetworkCredential().Password
  domain_type = 'localOrSSO'
  mfa_remember_token = ''
}
# $bodyJson = $body | ConvertTo-Json

# Rubrik Cloud API authenticate for a session token
Write-Host "Authenticating to Rubrik Cloud"
$sessionURL = "https://" + $rubrikURL + "/api/session"
$type = "application/json"
$rubrikSessionResponse = Invoke-RestMethod -Method POST -Uri $sessionURL -Body $($payload | ConvertTo-JSON -Depth 100) -ContentType $type -SkipCertificateCheck

# Rubrik Cloud GraphQL API URL
$endpoint = "https://" + $rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json';
  'Accept' = 'application/json';
  'Authorization' = $('Bearer ' + $rubrikSessionResponse.access_token);
}

###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Return a list of M365 SharePoint sites
Function Get-M365SharePoint {
  param (
    [CmdletBinding()]
    # M365 Subscription ID
    [Parameter(Mandatory=$true)]
    [string]$subscriptionID
    # M365 SharePoint object types: O365Site, O365SharepointDrive, O365SharepointList
    # [Parameter(Mandatory=$false)]
    # [string[]]$objectTypes = @( 'O365Site', 'O365SharepointDrive', 'O365SharepointList')
  )
  $variableso365Sites = @{
    "o365OrgId" = "$subscriptionID"
  }
  $payloado365Sites = @{
    "query" = "";
    "variables" = $variableso365Sites
  }
  $queryo365Sites = "query (`$after:String, `$o365OrgId:UUID!) {
    o365Sites (after:`$after, o365OrgId:`$o365OrgId) {
      nodes {
        id
        name
        objectType
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }"
  $payloado365Sites.query = $queryo365Sites
  $spSiteList = @()
  $spSiteNodes = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payloado365Sites | ConvertTo-JSON -Depth 100) -Headers $headers).data.o365Sites
  $spSiteList += $spSiteNodes.nodes
  while ($spSiteNodes.pageInfo.hasNextPage -eq 'True')
  {
    $payloado365Sites.variables.after = $spSiteNodes.pageInfo.endCursor
    $spSiteNodes = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payloado365Sites | ConvertTo-JSON -Depth 100) -Headers $headers).data.o365Sites
    $spSiteList += $spSiteNodes.nodes
  }
  return $spSiteList
}  ### Function Create-Role


# Create a new role
Function Create-Role {
  param (
    [CmdletBinding()]
    # Role name
    [Parameter(Mandatory=$true)]
    [string]$roleName,
    # Array of Sharepoint Site IDs
    [Parameter(Mandatory=$true)]
    [string[]]$spIDs
  )
  $permissionList = @( "ViewInventory", "RefreshDataSource", "ManageProtection",
    "TakeOnDemandSnapshot", "DeleteSnapshot", "ExportFiles", "ExportSnapshots",
    "Download", "RestoreToOrigin", "ManageDataSource")
  $permissions = @()
  $objIds = @(
    "O365_ROOT"
  )
  $permissionObj = @{
    "operation" = "ProvisionOnInfrastructure"
    "objectsForHierarchyTypes" = @(
      @{
        "objectIds" = @($objIds);
        "snappableType" = "AllSubHierarchyType"
      }
    )
  }
  $permissions += $permissionObj
  $objIds = @(
    "Inherit",
    "DoNotProtect",
    "d5a08769-a6ad-450e-8110-7ad47f36495d"
  )
  $permissionObj = @{
    "operation" = "ViewSLA"
    "objectsForHierarchyTypes" = @(
      @{
        "objectIds" = @($objIds);
        "snappableType" = "AllSubHierarchyType"
      }
    )
  }
  $permissions += $permissionObj
  foreach ($permAdd in $permissionList) {
    $permissionObj = @{
      "operation" = "$permAdd"
      "objectsForHierarchyTypes" = @(
        @{
          "objectIds" = @($spIDs);
          "snappableType" = "AllSubHierarchyType"
        }
      )
    }
    $permissions += $permissionObj
  }
  $variablesMutateRole = @{
    "name" = "$roleName";
    "description" = "Custom role for M365";
    "protectableClusters" = @();
    "permissions" = $permissions
  }
  $payloadMutateRole = @{
    "query" = "mutation mutateRoleTest (`$name: String!, `$description: String!, `$permissions: [PermissionInput!]!, `$protectableClusters: [String!]!) {
      mutateRole(name: `$name, description: `$description, permissions: `$permissions, protectableClusters: `$protectableClusters)
      }";
    "variables" = $variablesMutateRole
  }
  Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payloadMutateRole | ConvertTo-JSON -Depth 100) -Headers $headers
}  ### Function Create-Role

# Add a role to a user
Function Add-User-Role {
  param (
    [CmdletBinding()]
    # User ID
    [Parameter(Mandatory=$true)]
    [string[]]$userIDs,
    # Role ID
    [Parameter(Mandatory=$true)]
    [string[]]$roleIDs
  )
  $variablesAppendRoleMutation = @{
    "adGroupIds" = @();
    "userIds" = $userIDs;
    "roleIds" = $roleIDs;
  }
  $payloadAppendRoleMutation = @{
    "query" = "mutation AppendRoleMutation(`$userIds: [String!]!, `$adGroupIds: [String!], `$roleIds: [String!]!) {
      addRoleAssignments(userIds: `$userIds, adGroupIds: `$adGroupIds, roleIds: `$roleIds)
      }";
    "variables" = $variablesAppendRoleMutation
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payloadAppendRoleMutation | ConvertTo-JSON -Depth 100) -Headers $headers
}  ### Function Create-Role


###### FUNCTIONS - END ######


# Import mapping file info
Write-Host "Importing mapping file"
Write-Host ""
$mapping = Import-CSV -path $mappingFile

# Get list of all SharePoint Sites
Write-Host "Getting list of all SharePoint Sites"
Write-Host ""
$spSites = Get-M365SharePoint -SubscriptionId $subscriptionID

# Get list of all roles
Write-Host "Getting a list of all roles"
Write-Host ""
$payloadRoleList = @{
  "query" = "";
}
$queryRoleList = "query {
  getAllRolesInOrgConnection {
    edges {
      node {
        id
        name
        description
        permissions {
          objectsForHierarchyTypes {
            objectIds
            snappableType
          }
        }
      }
    }
  }
}"
$payloadRoleList.query = $queryRoleList
$roleList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payloadRoleList | ConvertTo-JSON -Depth 100) -Headers $headers).data.getAllRolesInOrgConnection.edges.node

# Check if there a role already created for the department
# If no role is found, create a new one
Write-Host "Checking if there is an existing role for each department."
Write-Host "If a role does not exist, it will be created."
Write-Host ""

# Get the unique department names
$deptList = $mapping.Department | Sort-Object -Property 'Department' | Get-Unique
foreach ($dept in $deptList)
{
  # Try to get an existing Rubrik role for the department
  $rubrikRole = $roleList | Where-Object { $_.name -eq "$dept-M365Role" }
  # Get list of SharePoint Sites that match the department name prefix
  $spIDs =  $($spSites | Where-Object { $_.name -like "$dept*" }).id
  if ($rubrikRole)
  {
    Write-Host "Found existing custom role: $dept-M365Role" -foregroundcolor green
  } else {
    Write-Host "No existing custom role found for: $dept-M365Role"
    Write-Host "Creating a new custom role: $dept-M365Role" -foregroundcolor green
    Create-Role -roleName "$dept-M365Role" -spIDs $spIDs
  }
}

# Get the current list of roles
Write-Host ""
Write-Host "Getting updated list of roles"
Write-Host ""
$roleList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payloadRoleList | ConvertTo-JSON -Depth 100) -Headers $headers).data.getAllRolesInOrgConnection.edges.node

#Get a list of all users
Write-Host "Getting list of users"
Write-Host ""
$payloadUserList = @{
  "query" = "";
}
$queryUserList = "query {
  allUsersOnAccountConnection {
    edges {
      cursor
      node {
        id
        email
        domain
        roles {
          id
          name
          description
        }
      }
    }
  }
}"
$payloadUserList.query = $queryUserList
$userList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payloadUserList | ConvertTo-JSON -Depth 100) -Headers $headers).data.allUsersOnAccountConnection.edges.node

foreach ($user in $mapping) {
  $rubrikUser = $userList | Where-Object { $_.email -eq $($user.user) -and $_.domain -eq "LOCAL" }
  $dept = $user.Department
  if ($rubrikUser)
  {
    if ($rubrikUser.roles.name -notcontains "$dept-M365Role")
    {
      Write-Host "Role not found for user: $dept-M365Role for $($user.user)"
      Write-Host "Adding role to user: $dept-M365Role for $($user.user)" -foregroundcolor green
      Write-Host ""
      $roleIDs = @( $($roleList | Where-Object { $_.name -eq "$dept-M365Role" }).id )
      $userIDs = @( $rubrikUser.id )
      Add-User-Role -userIDs $userIDs -roleIDs $roleIDs
    } else {
      Write-Host "User already has role assigned: $dept-M365Role for $($user.user)"
    }
  } else {
    Write-Host "Local user not found to add a role to: $($user.user) for department $dept" -foregroundcolor yellow
    Write-Host ""
  }
}



# # Export the list to a CSV file
# $list | Export-Csv -NoTypeInformation -Path $csvOutput
# Write-Host "`nResults output to: $csvOutput"
#
# # Send an email with CSV attachment
# if ($sendEmail)
# {
#   Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
# }
#
