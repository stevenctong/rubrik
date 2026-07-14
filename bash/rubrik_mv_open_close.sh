#!/bin/bash
#
# Author: Steven Tong (Rubrik)
# Updated: 7/13/26
#
# Description:
# Opens or closes a Rubrik Managed Volume (MV) by calling the CDM REST API.
# Opening a MV transitions it to a read-write state (begin_snapshot).
# Closing a MV transitions it to a read-only state and triggers a snapshot
# (end_snapshot).
#
# Authentication uses a Rubrik Security Cloud (RSC) Service Account.
# The service account credentials (client_id, client_secret) are used to
# create a session on the CDM cluster via the service_account/session API.
#
# The MV can be identified by either its ID (MV_ID) or name (MV_NAME).
# If MV_ID is provided, it is used directly. Otherwise, MV_NAME is used
# to look up the ID via the internal API.
#
# Usage:
#   ./rubrik_mv_open_close.sh open             # open MV (begin_snapshot)
#   ./rubrik_mv_open_close.sh close            # close MV (end_snapshot)
#   ./rubrik_mv_open_close.sh open --no-log    # open without logging to file
#
# Setup: Creating an RSC Service Account
# 1. Log in to Rubrik Security Cloud (RSC)
# 2. Create a role to be used with the Service Account with the following permissions:
#    - Managed Volumes > Take On Demand Snapshot
# 3. Create a Service Account and assign the role
# 4. Download the JSON file - it contains the client_id and client_secret
#    that go into the CLIENT_ID and CLIENT_SECRET variables below

### VARIABLES - BEGIN ###

# RSC Service Account credentials (from the downloaded JSON file)
# client_id -> CLIENT_ID, client_secret -> CLIENT_SECRET
CLIENT_ID=""
CLIENT_SECRET=""

# Hostname or IP address of the Rubrik CDM cluster
RUBRIK=""

# Managed Volume identification - provide MV_ID or MV_NAME (ID takes priority)
# MV_ID: grab from the MV URL in the Rubrik UI (e.g. ManagedVolume:::xxxxxxxx-xxxx-...)
# MV_NAME: the display name of the Managed Volume
MV_ID=""
MV_NAME=""

### VARIABLES - END ###

### Derived variables - BEGIN ###

SCRIPTDIR="."
LAUNCHTIME=$(date +%Y-%m-%d_%H%M%S)
LOG_RETENTION_DAYS=60

### Derived variables - END ###

# Parse CLI arguments (--no-log flag and open/close operation)
NO_LOG=false
OPERATION=""
for arg in "$@"; do
  case "$arg" in
    --no-log) NO_LOG=true ;;
    open|close) OPERATION="$arg" ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if [[ -z "$OPERATION" ]]; then
  echo "Usage: $0 [--no-log] <open|close>"
  echo ""
  echo "  open      - Open the MV into read-write state (begin_snapshot)"
  echo "  close     - Close the MV into read-only state and take snapshot (end_snapshot)"
  echo "  --no-log  - Suppress logging to file (output to stdout only)"
  exit 1
fi

# Set up logging unless --no-log is specified
if [[ "$NO_LOG" == false ]]; then
  LOGDIR="${SCRIPTDIR}/logs"
  LOGFILE="${LOGDIR}/mv_open_close-${LAUNCHTIME}.log"
  mkdir -p "${LOGDIR}"
  touch "${LOGFILE}"

  DELETED_LOGS=$(find "${LOGDIR}" -name "mv_open_close-*.log" -type f -mtime +${LOG_RETENTION_DAYS} -print -delete 2>/dev/null)
  if [[ -n "$DELETED_LOGS" ]]; then
    echo "Cleaned up log files older than ${LOG_RETENTION_DAYS} days:"
    echo "$DELETED_LOGS"
    echo ""
  fi

  # Redirect all output to both stdout and the log file
  exec &> >(tee -a "${LOGFILE}")
fi

echo "Starting rubrik_mv_open_close.sh on $(hostname)"
echo "Current date: $(date)"
echo "Operation: ${OPERATION}"
if [[ "$NO_LOG" == false ]]; then
  echo "Log file: ${LOGFILE}"
fi
echo ""

# Check that curl is available
if ! command -v curl &>/dev/null; then
  echo "ERROR: curl is not installed, exiting..."
  exit 1
fi

# Validate required variables
if [[ -z "$RUBRIK" ]]; then
  echo "ERROR: RUBRIK variable is not set, exiting..."
  exit 1
fi

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "ERROR: CLIENT_ID and CLIENT_SECRET must both be set, exiting..."
  exit 1
fi

if [[ -z "$MV_ID" && -z "$MV_NAME" ]]; then
  echo "ERROR: Either MV_ID or MV_NAME must be set, exiting..."
  exit 1
fi

# Define base URL and content type header for API calls
TYPE_HEADER="Content-Type: application/json"
BASE_URL="https://${RUBRIK}/api/"

# Authenticate via RSC Service Account
echo "Authenticating to Rubrik cluster: ${RUBRIK}"
SVC_JSON='{"serviceAccountId": "'"${CLIENT_ID}"'", "secret": "'"${CLIENT_SECRET}"'"}'
SVC_RESULT=$(curl -k1s -X POST -w '\n%{http_code}' -H "${TYPE_HEADER}" -d "${SVC_JSON}" "${BASE_URL}v1/service_account/session")

SVC_HTTP_CODE=$(echo "$SVC_RESULT" | tail -1)
SVC_BODY=$(echo "$SVC_RESULT" | sed '$d')

if [[ "$SVC_HTTP_CODE" -lt 200 || "$SVC_HTTP_CODE" -ge 300 ]]; then
  echo "ERROR: Authentication failed with HTTP status ${SVC_HTTP_CODE}"
  echo "API response: ${SVC_BODY}"
  exit 1
fi

TOKEN=$(echo "$SVC_BODY" | sed -e 's/[{}]/''/g' | sed 's/"//g' | awk -v RS=',' -F: '$1=="token"{print $2}')

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Failed to parse token from authentication response"
  echo "API response: ${SVC_BODY}"
  exit 1
fi

echo "Successfully authenticated"
echo ""

AUTH_HEADER="Authorization:bearer ${TOKEN}"

# Resolve MV_ID if only MV_NAME is provided
if [[ -n "$MV_ID" ]]; then
  echo "Using provided MV_ID: ${MV_ID}"
else
  echo "Looking up MV by name: ${MV_NAME}"
  MV_RESULT=$(curl -k1s -X GET -w '\n%{http_code}' -H "${AUTH_HEADER}" -H "${TYPE_HEADER}" "${BASE_URL}internal/managed_volume?name=${MV_NAME}")

  MV_HTTP_CODE=$(echo "$MV_RESULT" | tail -1)
  MV_BODY=$(echo "$MV_RESULT" | sed '$d')

  if [[ "$MV_HTTP_CODE" -lt 200 || "$MV_HTTP_CODE" -ge 300 ]]; then
    echo "ERROR: MV lookup failed with HTTP status ${MV_HTTP_CODE}"
    echo "API response: ${MV_BODY}"
    exit 1
  fi

  MV_ID=$(echo "$MV_BODY" | sed -e 's/.*"id":"//' | sed -e 's/".*//')

  if [[ -z "$MV_ID" || "$MV_ID" == *"{"* ]]; then
    echo "ERROR: Could not find Managed Volume with name: ${MV_NAME}"
    echo "API response: ${MV_BODY}"
    exit 1
  fi

  echo "Found MV_ID: ${MV_ID}"
fi

echo ""

# Set the API endpoint based on the operation
if [[ "$OPERATION" == "open" ]]; then
  API_ENDPOINT="${BASE_URL}internal/managed_volume/${MV_ID}/begin_snapshot"
  echo "Opening Managed Volume (begin_snapshot)"
else
  API_ENDPOINT="${BASE_URL}internal/managed_volume/${MV_ID}/end_snapshot"
  echo "Closing Managed Volume (end_snapshot)"
fi

echo "API endpoint: ${API_ENDPOINT}"
echo ""

# Execute the open or close API call
OP_RESULT=$(curl -k1s -X POST -w '\n%{http_code}' -H "${AUTH_HEADER}" -H "${TYPE_HEADER}" "${API_ENDPOINT}")

OP_HTTP_CODE=$(echo "$OP_RESULT" | tail -1)
OP_BODY=$(echo "$OP_RESULT" | sed '$d')

if [[ "$OP_HTTP_CODE" -lt 200 || "$OP_HTTP_CODE" -ge 300 ]]; then
  echo "ERROR: ${OPERATION} failed with HTTP status ${OP_HTTP_CODE}"
  echo "Response: ${OP_BODY}"
  exit 1
fi

echo "Response: ${OP_BODY}"
echo ""
echo "Successfully completed ${OPERATION} operation on Managed Volume"
exit 0
