#! /bin/bash
#
# This script executes the Rubrik Azure PowerShell snap / clone script.
# Pass the PSD1 config file as an argument or define it as the default below.
#
# Usage:
#   ./rubrik_az_script.sh rubrik_az_config.psd1   # pass config file as argument
#   ./rubrik_az_script.sh                          # use default CONFIGFILE variable

### VARIABLES - BEGIN ###

CONFIGFILE="./rubrik_az_config.psd1"

### VARIABLES - END ###

# Use argument if provided, otherwise use default
if [[ -n "$1" ]]; then
  CONFIGFILE="$1"
fi

if [[ ! -f "$CONFIGFILE" ]]; then
  echo "ERROR: Config file not found: $CONFIGFILE"
  exit 1
fi

pwsh ./Rubrik-New-v2-Ultra-Snapshot.ps1 -configFile "$CONFIGFILE"

exit_code=$?

exit $exit_code
