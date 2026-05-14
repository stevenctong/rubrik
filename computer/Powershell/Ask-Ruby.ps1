# https://www.rubrik.com/api
<#
.SYNOPSIS
Sends a question to Ruby (Rubrik's AI assistant) via the RSC API and returns
the streamed response.

.DESCRIPTION
This script authenticates to RSC, creates a Ruby session, sends a user
question, and reads the Server-Sent Events (SSE) response stream. It can
optionally include page context to give Ruby awareness of a specific RSC page.

The script supports two modes:
1. Interactive: run with no parameters to enter questions in a loop
2. Single question: pass -question to ask one question and exit

.PARAMETER question
The question to ask Ruby. If omitted, the script enters interactive mode.

.PARAMETER pageContext
Optional JSON string describing the RSC page context. Ruby uses this to
provide page-aware answers. If omitted, no page context is sent.

.PARAMETER serviceAccountPath
Path to the RSC Service Account JSON file. Defaults to ./rsc-service-account-rr.json.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/14/26

The script requires communication to RSC via outbound HTTPS (TCP 443).
Requires PowerShell 7+.

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a role
** Download the service account JSON
** Define the service account JSON path: -serviceAccountPath

.EXAMPLE
./Ask-Ruby.ps1 -question "What backups failed in the last 24 hours?"
Sends a single question to Ruby and outputs the streamed response.

.EXAMPLE
./Ask-Ruby.ps1 -question "What failure patterns are there?" -serviceAccountPath ../rsc-service-account-rr.json
Sends a single question using a service account JSON at a custom path.

.EXAMPLE
./Ask-Ruby.ps1
Starts interactive mode where you can ask Ruby multiple questions in the
same session. Type 'exit', 'quit', or 'q' to end.

.EXAMPLE
./Ask-Ruby.ps1 -question "Summarize this page" -pageContext '{"url":"/radar/threat_hunts","title":"Threat Hunts"}'
Sends a question with page context so Ruby can provide page-aware answers.

.EXAMPLE
./Ask-Ruby.ps1 -question "What compliance gaps exist?" -Verbose
Runs with verbose output showing raw SSE stream lines for debugging.
#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]
  # The question to ask Ruby (omit for interactive mode)
  [Parameter(Mandatory=$false)]
  [string]$question = '',
  # Optional page context JSON string
  [Parameter(Mandatory=$false)]
  [string]$pageContext = '',
  # File location of the RSC service account json
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = "./rsc-service-account-rr.json"
)

### VARIABLES - END ###

if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Error "PowerShell version is: $($PSVersionTable.PSVersion)"
  Write-Error "Please use PowerShell version 7+"
  exit 1
}

###### RUBRIK AUTHENTICATION - BEGIN ######
Write-Information -Message "Info: Attempting to read the Service Account file located at $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
}
catch {
  $errorMessage = $_.Exception | Out-String
  if($errorMessage.Contains('because it does not exist')) {
    throw "The Service Account JSON secret file was not found. Ensure the file is located at $serviceAccountPath."
  }
  throw $_.Exception
}

$payload = @{
  grant_type = "client_credentials";
  client_id = $serviceAccountFile.client_id;
  client_secret = $serviceAccountFile.client_secret
}

Write-Debug -Message "Determining if the Service Account file contains all required variables."
$missingServiceAccount = @()
if ($null -eq $serviceAccountFile.client_id) {
  $missingServiceAccount += "'client_id'"
}

if ($null -eq $serviceAccountFile.client_secret) {
  $missingServiceAccount += "'client_secret'"
}

if ($null -eq $serviceAccountFile.access_token_uri) {
  $missingServiceAccount += "'access_token_uri'"
}

if ($missingServiceAccount.count -gt 0){
  throw "The Service Account JSON secret file is missing the required parameters: $missingServiceAccount"
}

$headers = @{
  'Content-Type' = 'application/json';
  'Accept' = 'application/json';
}

Write-Verbose -Message "Connecting to the RSC GraphQL API using the Service Account JSON file."
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")
$global:rubrikConnection = @{
  accessToken = $response.access_token;
  rubrikURL = $rubrikURL
}

# Rubrik GraphQL API URL
$endpoint = $rubrikConnection.rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json';
  'Accept' = 'application/json';
  'Authorization' = $('Bearer ' + $rubrikConnection.accessToken);
}

Write-Host "Connected to RSC: $rubrikURL" -ForegroundColor Green
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Create a new Ruby session via GraphQL
function New-RubySession {
  $query = @{
    operationName = "CreateRubySessionMutation"
    variables = @{}
    query = "mutation CreateRubySessionMutation { createRubySession { sessionId } }"
  }
  $result = Invoke-RestMethod -Method POST -Uri $endpoint -Body ($query | ConvertTo-Json -Depth 10) -Headers $headers
  return $result.data.createRubySession.sessionId
}

# Send a question to Ruby and read the SSE stream
function Send-RubyQuestion {
  param (
    [Parameter(Mandatory=$true)]
    [string]$sessionId,
    [Parameter(Mandatory=$true)]
    [string]$userInput,
    [Parameter(Mandatory=$false)]
    [string]$pageContext = ''
  )

  $rubyEndpoint = "$rubrikURL/api/ruby_sessions/$sessionId"

  $body = @{ userInput = $userInput }
  if ($pageContext -ne '') {
    $body.pageContext = $pageContext
  }
  $bodyJson = $body | ConvertTo-Json -Depth 10

  $httpClient = [System.Net.Http.HttpClient]::new()
  $httpClient.Timeout = [System.TimeSpan]::FromMinutes(5)
  $httpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new(
    "Bearer", $rubrikConnection.accessToken
  )
  $httpClient.DefaultRequestHeaders.Accept.Add(
    [System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("text/event-stream")
  )

  $content = [System.Net.Http.StringContent]::new($bodyJson, [System.Text.Encoding]::UTF8, "application/json")

  try {
    $responseMsg = $httpClient.SendAsync(
      [System.Net.Http.HttpRequestMessage]@{
        Method = [System.Net.Http.HttpMethod]::Post
        RequestUri = $rubyEndpoint
        Content = $content
      },
      [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    ).GetAwaiter().GetResult()

    if (-not $responseMsg.IsSuccessStatusCode) {
      $errorBody = $responseMsg.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      throw "Ruby API returned $($responseMsg.StatusCode): $errorBody"
    }

    $stream = $responseMsg.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader = [System.IO.StreamReader]::new($stream)

    Write-Verbose "Ruby endpoint: $rubyEndpoint"
    Write-Verbose "Response status: $($responseMsg.StatusCode)"
    Write-Verbose "Response content type: $($responseMsg.Content.Headers.ContentType)"

    $fullResponse = [System.Text.StringBuilder]::new()
    $lineCount = 0

    while (-not $reader.EndOfStream) {
      $line = $reader.ReadLine()
      $lineCount++

      Write-Verbose "SSE line $lineCount : $line"

      if ([string]::IsNullOrEmpty($line)) { continue }

      # Strip SSE prefix if present
      if ($line.StartsWith("data: ")) {
        $eventData = $line.Substring(6)
      } elseif ($line.StartsWith("event:") -or $line.StartsWith("id:") -or $line.StartsWith("retry:")) {
        continue
      } else {
        $eventData = $line
      }

      if ($eventData -eq "[DONE]") { break }

      try {
        $parsed = $eventData | ConvertFrom-Json -ErrorAction Stop

        foreach ($event in $parsed.events) {
          $eventType = $event.eventType
          foreach ($part in $event.content.parts) {
            if ($part.type -eq 'TEXT' -and $null -ne $part.value) {
              if ($eventType -eq 'FINAL_RESPONSE') {
                Write-Host $part.value -NoNewline
                [void]$fullResponse.Append($part.value)
              } else {
                Write-Host $part.value -ForegroundColor DarkGray
              }
            }
          }
        }
      }
      catch {
        Write-Verbose "Failed to parse SSE data: $eventData"
      }
    }

    Write-Verbose "Stream complete. Total lines read: $lineCount"
    Write-Host ""
    return $fullResponse.ToString()
  }
  finally {
    if ($null -ne $reader) { $reader.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
    if ($null -ne $responseMsg) { $responseMsg.Dispose() }
    $httpClient.Dispose()
  }
}

###### FUNCTIONS - END ######

# Create a Ruby session
Write-Host "Creating Ruby session..." -ForegroundColor Cyan
$sessionId = New-RubySession
Write-Host "Session created: $sessionId" -ForegroundColor Green
Write-Host ""

if ($question -ne '') {
  # Single question mode
  Write-Host "Question: $question" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Ruby: " -ForegroundColor Cyan -NoNewline
  $result = Send-RubyQuestion -sessionId $sessionId -userInput $question -pageContext $pageContext
}
else {
  # Interactive mode
  Write-Host "Interactive mode - type 'exit' or 'quit' to end the session." -ForegroundColor Cyan
  Write-Host ""

  while ($true) {
    $userQuestion = Read-Host "You"
    if ($userQuestion -match '^(exit|quit|q)$') {
      Write-Host "Ending Ruby session." -ForegroundColor Yellow
      break
    }
    if ([string]::IsNullOrWhiteSpace($userQuestion)) { continue }

    Write-Host ""
    Write-Host "Ruby: " -ForegroundColor Cyan -NoNewline
    $result = Send-RubyQuestion -sessionId $sessionId -userInput $userQuestion -pageContext $pageContext
    Write-Host ""
  }
}
