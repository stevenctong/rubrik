#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

# Written by Steven Tong for community usage
# GitHub: stevenctong
# Date: 1/3/20

# A collection of functions to help check Rubrik task status


# Check and return task status
Function Check-RubrikRequest($req) {
  $reqURL = $req.links.href -split 'api\/[a-z0-9]*\/'
  $req = Invoke-RubrikRESTCall -Method "Get" -Endpoint "$($reqURL[1])"
  return $req
}


# Wait until task completes and return state
Function Wait-RubrikRequests($req) {
  do {
    $reqURL = $req.links.href -split 'api\/[a-z0-9]*\/'
    $req = Invoke-RubrikRESTCall -Method "Get" -Endpoint "$($reqURL[1])"
    $reqState = @('QUEUED','ACQUIRING','RUNNING','FINISHING','TO_CANCEL') -contains $req.status
    if ($reqState) { Start-Sleep -Seconds 30 }
  } while ( $reqState )
  return $req
}


# Regex to match behind 'api/*/'
# api\/[a-z0-1]*\/\K.*
