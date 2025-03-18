# https://www.rubrik.com/api
# https://github.com/rubrikinc/rubrik-powershell-sdk
<#
.SYNOPSIS
This script can add a host to a Rubrik cluster and add the host to a
Custom Role based on a SSO user's group.

.DESCRIPTION
This script can add a host to a Rubrik cluster and add the host to a
Custom Role based on a SSO user's group.

To add a Host to a Rubrik cluster:
1. Set $addHost to $true
2. Provide the Rubrik cluster and hostname/IP as parameters

The script will use the RSC PowerShell SDK in order to add the host to RSC for
the given Rubrik cluster.

To update a Custom Role based on SSO user:
1. Set $updateRole to $true
2. Provide the user email to lookup SSO Group membership for. Additional logic
   may need to be added if the SSO Group user is only similar to the user email
   that is provided.
3. Provide the hostname and OS type of the Host - either Windows or Linux

The script will lookup all SSO Group and SSO User information, find the
Custom Role(s) that the given user email is assigned to. The script currently
assumes that the user email only has a single Custom Role assigned to it.
The script will then update that Custom Role to add the Hostname.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 2/28/25

This script requires communication to RSC via outbound HTTPS (TCP 443).

This script requires the Rubrik PowerShell SDK:
- https://github.com/rubrikinc/rubrik-powershell-sdk

For authentication, use a RSC Service Account:
** RSC Settings -> Users -> Service Account -> Create one and assign it an appropriate role
** Download the service account JSON
** Use Set-RscServiceAccountFile to configure the RSC Service Account for the SDK

.EXAMPLE
./Add-Host-Update-RBAC.ps1 -addHost $true -cluster <cluster> -hostname <hostname_or_ip>
Add the host to the Rubrik cluster.

./Add-Host-Update-RBAC.ps1 -updateRole $true -hostname <hostname_or_ip> -userEmail 'user@rubrik.com'
  -osType 'Windows'
Add the host to the Rubrik cluster.
#>

### VARIABLES - START ###

param (
  [CmdletBinding()]
  # Rubrik Security Cloud url
  [Parameter(Mandatory=$false)]
  [string]$rubrikURL = '',
  # Add Host - Rubrik cluster name
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # Add Host - Hostnames or IPs to add
  [Parameter(Mandatory=$false)]
  [string]$hostname = '',
  # Update Role - User email address to match
  [Parameter(Mandatory=$false)]
  [string]$userEmail = '',
  # Update Role - OS type of the host, either 'Windows' or 'Linux'
  [Parameter(Mandatory=$false)]
  [string]$osType = '',
  # Bool - Whether to add the host or not
  [Parameter(Mandatory=$false)]
  [string]$addHost = $false,
  # Bool - Whether to update the role or not
  [Parameter(Mandatory=$false)]
  [string]$updateRole = $false
)
### VARIABLES - END ###

### FUNCTIONS - BEGIN ###

# Get SSO users and groups
Function Get-SSOUsers {
  $variables = @{
    "shouldIncludeUserWithoutRole" = $false
    "sortBy" = @{
      "field" = "LAST_LOGIN"
      "sortOrder" = "DESC"
    }
    "filter" = @{
      "lockoutStateFilter" = "ALL"
      "hiddenStateFilter" = "NOT_HIDDEN"
      "domainFilter" = @(
        "SSO"
      )
      "authDomainIdsFilter" = @()
    }
    "first" = 200
  }
  $query = "query UsersOrgQuery(`$after: String, `$first: Int, `$sortBy: UserSortByParam, `$filter: UserFilterInput, `$shouldIncludeUserWithoutRole: Boolean = false) {
  usersInCurrentAndDescendantOrganization(
    after: `$after
    first: `$first
    sortBy: `$sortBy
    filter: `$filter
    shouldIncludeUserWithoutRole: `$shouldIncludeUserWithoutRole
  ) {
    edges {
      cursor
      node {
        id
        email
        domain
        lastLogin
        status
        isAccountOwner
        groups
        domainName
        assignedRoles {
          role {
            id
            name
            description
            __typename
          }
        }
      }
    }
    pageInfo {
      endCursor
      hasNextPage
      hasPreviousPage
      __typename
    }
  }
}
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.usersInCurrentAndDescendantOrganization.edges.node
}  ### Function Get-SSOUsers

# Get SSO Group info - SSO Groups and role assignments
Function Get-SSOGroups {
  $variables = @{
    "shouldIncludeGroupsWithoutRole" = $false
    "filter" = @{
    }
  }
  $query = "query UserGroupsOrgQuery(`$after: String, `$before: String, `$first: Int, `$last: Int, `$filter: GroupFilterInput, `$sortBy: GroupSortByParam, `$shouldIncludeGroupsWithoutRole: Boolean = false) {
  groupsInCurrentAndDescendantOrganization(
    after: `$after
    before: `$before
    first: `$first
    last: `$last
    filter: `$filter
    sortBy: `$sortBy
    shouldIncludeGroupsWithoutRole: `$shouldIncludeGroupsWithoutRole
  ) {
    edges {
      node {
        groupId
        groupName
        domainName
        roles {
          id
          name
          description
        }
        users {
          email
        }
      }
    }
  }
}
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.groupsInCurrentAndDescendantOrganization.edges.node
}  ### Function Get-SSOGroups

# Get Roles and Role Permissions
Function Get-Roles {
  $variables = @{
    "sortBy" = "Name"
    "sortOrder" = "ASC"
    "first" = 100
  }
  $query = "query RolesQuery(`$after: String, `$first: Int, `$sortBy: RoleFieldEnum, `$sortOrder: SortOrder, `$nameSearch: String, `$roleSyncedFilter: Boolean) {
  getAllRolesInOrgConnection(
    after: `$after
    first: `$first
    sortBy: `$sortBy
    sortOrder: `$sortOrder
    nameFilter: `$nameSearch
    roleSyncedFilter: `$roleSyncedFilter
  ) {
    edges {
      cursor
      node {
        id
        isReadOnly
        name
        description
        explicitlyAssignedPermissions {
          operation
          objectsForHierarchyTypes {
            objectIds
            snappableType
          }
        }
        isOrgAdmin
      }
    }
    pageInfo {
      startCursor
      endCursor
      hasNextPage
      hasPreviousPage
    }
  }
}
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.getAllRolesInOrgConnection.edges.node
}  ### Function Get-Roles


# Return the detail of a role
Function Get-RoleDetail {
  param (
    [CmdletBinding()]
    # Role ID
    [Parameter(Mandatory=$true)]
    [string]$roleID
  )
  $variables = @{
    "roleIds" = @(
      "$roleID"
    )
  }
  $payload = @{
    "query" = "";
    "variables" = $variables
  }
  $query = "query (`$roleIds: [String!]!) {
    getRolesByIds(roleIds: `$roleIds) {
      id
      name
      description
      isReadOnly
      protectableClusters
      permissions {
        ... on Permission {
          operation
          objectsForHierarchyTypes {
            objectIds
            snappableType
          }
        }
      }
    }
  }"
  $payload.query = $query
  $roleDetail = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.getRolesByIds
  return $roleDetail
}  ### Function Get-RoleDetail

# Update a role
Function Update-Role {
  param (
    [CmdletBinding()]
    # Host ID to add to the custom role
    [Parameter(Mandatory=$true)]
    [string]$hostID,
    # Role ID to update
    [Parameter(Mandatory=$true)]
    [string]$roleID,
    # List of permissions to update with the host
    [Parameter(Mandatory=$true)]
    [array]$permissionList = @()
  )
  # To update a Custom Role we have to first get the current config of the Custom Role
  $roleDetail = Get-RoleDetail -roleID $roleID
  # To add a Host ID to the Custom Role, we have to add it along with each
  # explicit permission that the Host ID has permissions to perform.
  # The permissions list must match the current list.
  # Note: There is probably a dynamic way to check if a permission currently
  # contains any Host IDs and automatically add the new Host ID if so.
  foreach ($perm in $roleDetail.permissions) {
    # $perm.objectsForHierarchyTypes[0].objectIds = $perm.objectsForHierarchyTypes[0].objectIds | Sort-Object
    if ($perm.operation -in $permissionList) {
      $perm.operation
      $perm.objectsForHierarchyTypes[0].objectIds += $hostID
    }
  }
  $variables = @{
    "roleId" = $roleDetail.id
    "name" = $roleDetail.name
    "description" = $roleDetail.description
    "protectableClusters" = @()
  }
  $variables.permissions = $roleDetail.permissions
  $payload = @{
    "query" = "mutation MutateRoleMutation(`$roleId: String, `$name: String!, `$description: String!, `$permissions: [PermissionInput!]!, `$protectableClusters: [String!]!, `$isSynced: Boolean) {
      mutateRole(roleId: `$roleId, name: `$name, description: `$description, permissions: `$permissions, protectableClusters: `$protectableClusters, isSynced: `$isSynced)
    }"
    "variables" = $variables
  }
  $result = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  return $result
}  ### Function Update-Role

### FUNCTIONS - END ###

# Load RSC PowerShell SDK and connect to RSC
Import-Module RubrikSecurityCloud
$connection = Connect-Rsc

# For the non-SDK calls, build the RSC URL and Bearer token
$endpoint = "https://" + $rubrikURL + "/api/graphql"
$headers = @{
  'Content-Type'  = 'application/json'
  'Accept' = 'application/json'
  'Authorization' = $('Bearer ' + $RscConnectionClient.AccessToken)
}

# Permissions to add when updating role - this must contain everything that
# is within the current custom role.
$permissionList = @('DOWNLOAD_FROM_ARCHIVAL_LOCATION', 'VIEW_INVENTORY',
  'DOWNLOAD', 'DOWNLOAD_SNAPSHOT_FROM_REPLICATION_TARGET',
  'MOUNT', 'TAKE_ON_DEMAND_SNAPSHOT', 'REFRESH_DATA_SOURCE',
  'MANAGE_DATA_SOURCE', 'EXPORT_FILES', 'MANAGE_PROTECTION',
  'DELETE_SNAPSHOT', 'RESTORE_TO_ORIGIN')

# Get the Rubrik Cluster ID
$rscCluster = Get-RscCluster -Name $cluster
$clusterUuid = $rscCluster.Id

# Add / register a Host to RSC using the SDK
if ($addHost -eq $true) {
  $hosts = @( @{ Hostname = $hostname } )
  $registerHost = New-RscMutationHost -operation BulkRegister
  $registerHost.var.input = New-Object -TypeName RubrikSecurityCloud.Types.BulkRegisterHostInput
  $registerHost.var.input.clusterUuid = $clusteruuid
  $registerHost.var.input.hosts = $hosts
  $result = Invoke-Rsc $registerHost
  if ($result -eq $null -or $result.count -eq 0) {
    Write-Error "Error adding host: $hostname"
  } else {
    Write-Host "Successfully added host: $hostname"
  }
}

# Update the custom role assigned to the SSO user with the hostname
if ($updateRole = $true) {
  # Get list of all SSO users
  $ssoUsers = Get-SSOUsers
  # Get the SSO login details of the user we are working on
  $userSSOlogin = $ssoUsers | Where { $_.email -eq $userEmail }
  # Check if user is found or not
  if ($userSSOlogin.count -eq 1) {
    Write-Host "User found:" -foregroundcolor Green
    $userSSOlogin
  } else {
    Write-Error "User not found or too many users: $userEmail"
    # exit
  }
  # Get all SSO Group info
  $ssoGroups = Get-SSOGroups
  # Holds list of roles that the user is assigned
  $userRoles = @()
  # Loop through all the SSO groups that the user is a part of and grab their role
  # However, we assume a SSO Group is only assigned one Role
  foreach ($g in $userSSOLogin.groups) {
    $ssoGroupInfo = $ssoGroups | Where { $_.groupName -eq $g }
    $userRoles += $ssoGroupInfo.roles
  }
  Write-Host "List of roles assigned to the user:" -foregroundcolor Green
  $userRoles
  # We assume that the SSO Group is only assigned one custom role
  # Grab the name of the custom role we need to update
  $roleName = $($userRoles[0].name)
  # Get list of all roles and their permissions and details
  $roleList = Get-Roles
  # Select the role that we want to update
  $roleDetail = $roleList | Where { $_.name -eq $roleName }
  # Get the Host ID of the host that we want to add to the custom role
  # This requires passing in the OS type
  $hostInfo = Get-RscHost -OsType $osType -name $hostname
  if ($hostInfo.count -eq 1) {
    $hostID = $hostInfo.id
  } else {
    Write-Error "No host found for: $hostName"
  }
  # Update the custom role by adding the Host ID to it
  $result = Update-Role -roleID $roleDetail.id -permissionList $permissionList -hostID $hostID
}
