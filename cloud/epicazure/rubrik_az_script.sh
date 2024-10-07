#! /bin/bash
#
# This script excutes the Rubrik Azure Powershell snap / clone script.
# This script assumes that all the config variables within the Powershell
# script have been set.
#
# Use absolute paths if possible.
#
# Pass the IRIS instance name and Azure Managed Disks for that instance
# to the Rubrik script in order to run the script.

# Main script config fine
CONFIGFILE="./rubrik_az_config.yml"

pwsh ./Rubrik-New-v2-Ultra-Snapshot.ps1 -configFile "$CONFIGFILE"

# Capture the PowerShell exit code
exit_code=$?

exit $exit_code
