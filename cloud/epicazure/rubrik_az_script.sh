#! /bin/bash
#
# This script executes the Rubrik Azure PowerShell snap / clone script.
# Configure the PSD1 config file with instance-specific variables before running.
#
# Use absolute paths if possible.

# Main script config file
CONFIGFILE="./rubrik_az_config.psd1"

pwsh ./Rubrik-New-v2-Ultra-Snapshot.ps1 -configFile "$CONFIGFILE"

# Capture the PowerShell exit code
exit_code=$?

exit $exit_code
