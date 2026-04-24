# https://www.rubrik.com/api
<#
.SYNOPSIS
Pulls the full RSC GraphQL schema via the standard introspection query.

.DESCRIPTION
Authenticates to RSC using a Service Account JSON file and executes the
built-in GraphQL introspection query (__schema) to retrieve the complete
API schema — all types, queries, mutations, enums, input types, and their
field definitions. Saves the result as a formatted JSON file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/22/26

The script requires communication to RSC via outbound HTTPS (TCP 443).

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only role
** Download the service account JSON
** Define the service account JSON path in the script: $RscServiceAccountJson

Update this variable to point to your RSC Service Account JSON:
- $RscServiceAccountJson

.PARAMETER RscServiceAccountJson
File path to the RSC Service Account JSON file. The JSON must contain:
client_id, client_secret, and access_token_uri.

.EXAMPLE
./Get-RSC-Schema-Introspection.ps1 -RscServiceAccountJson "./rsc-gaia.json"
Pulls the full schema and saves to ./rsc_schema_introspection-<timestamp>.json
#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]
  [Parameter(Mandatory=$false)]
  [string]$RscServiceAccountJson
)

$date = Get-Date

# Output file path
$jsonOutput = "./rsc_schema_introspection-$($date.ToString("yyyy-MM-dd_HHmm")).json"

### VARIABLES - END ###

###### RUBRIK AUTHENTICATION - BEGIN ######

Write-Host "Reading Service Account file: $RscServiceAccountJson"
try {
  $serviceAccountFile = Get-Content -Path "$RscServiceAccountJson" -ErrorAction Stop | ConvertFrom-Json
} catch {
  throw "Failed to read Service Account JSON at '$RscServiceAccountJson': $($_.Exception.Message)"
}

# Validate required fields
$missingFields = @()
if ($null -eq $serviceAccountFile.client_id) { $missingFields += 'client_id' }
if ($null -eq $serviceAccountFile.client_secret) { $missingFields += 'client_secret' }
if ($null -eq $serviceAccountFile.access_token_uri) { $missingFields += 'access_token_uri' }

if ($missingFields.Count -gt 0) {
  throw "Service Account JSON is missing required fields: $($missingFields -join ', ')"
}

# Exchange credentials for bearer token
$payload = @{
  grant_type    = "client_credentials"
  client_id     = $serviceAccountFile.client_id
  client_secret = $serviceAccountFile.client_secret
}

try {
  $response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri `
    -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop
} catch {
  throw "RSC authentication failed: $($_.Exception.Message)"
}

if ($null -eq $response.access_token) {
  throw "RSC returned a response but no access token was included."
}

# Set connection variables
$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")

$global:rubrikConnection = @{
  accessToken = $response.access_token
  bearer = "Bearer $($response.access_token)"
  rubrikURL   = $rubrikURL
}

$endpoint = $rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json'
  'Accept'        = 'application/json'
  'Authorization' = "Bearer $($response.access_token)"
}

Write-Host "Connected to RSC: $rubrikURL" -ForegroundColor Green

###### RUBRIK AUTHENTICATION - END ######

###### INTROSPECTION QUERY - BEGIN ######

$introspectionQuery = @'
{
  __schema {
    queryType { name }
    mutationType { name }
    subscriptionType { name }
    types {
      name
      kind
      description
      fields(includeDeprecated: true) {
        name
        description
        isDeprecated
        deprecationReason
        type {
          ...TypeRef
        }
        args {
          name
          description
          defaultValue
          type {
            ...TypeRef
          }
        }
      }
      inputFields {
        name
        description
        defaultValue
        type {
          ...TypeRef
        }
      }
      interfaces {
        ...TypeRef
      }
      enumValues(includeDeprecated: true) {
        name
        description
        isDeprecated
        deprecationReason
      }
      possibleTypes {
        ...TypeRef
      }
    }
    directives {
      name
      description
      locations
      args {
        name
        description
        defaultValue
        type {
          ...TypeRef
        }
      }
    }
  }
}

fragment TypeRef on __Type {
  kind
  name
  ofType {
    kind
    name
    ofType {
      kind
      name
      ofType {
        kind
        name
        ofType {
          kind
          name
        }
      }
    }
  }
}
'@

$body = @{
  query = $introspectionQuery
} | ConvertTo-Json -Depth 5

Write-Host "Sending introspection query to: $endpoint"

try {
  $result = Invoke-RestMethod -Method POST -Uri $endpoint -Body $body -Headers $headers -ErrorAction Stop
} catch {
  throw "Introspection query failed: $($_.Exception.Message)"
}

if ($null -ne $result.errors) {
  Write-Host "GraphQL returned errors:" -ForegroundColor Red
  $result.errors | ForEach-Object { Write-Host "  - $($_.message)" -ForegroundColor Red }
  throw "Introspection query returned errors."
}

###### INTROSPECTION QUERY - END ######

# Save schema to JSON file
$result.data | ConvertTo-Json -Depth 100 | Out-File -FilePath $jsonOutput -Encoding utf8

$typeCount = $result.data.__schema.types.Count
$queryFields = ($result.data.__schema.types | Where-Object { $_.name -eq 'Query' }).fields.Count
$mutationFields = ($result.data.__schema.types | Where-Object { $_.name -eq 'Mutation' }).fields.Count

Write-Host ""
Write-Host "Schema introspection complete:" -ForegroundColor Green
Write-Host "  Types:     $typeCount"
Write-Host "  Queries:   $queryFields"
Write-Host "  Mutations: $mutationFields"
Write-Host "  Output:    $jsonOutput"
