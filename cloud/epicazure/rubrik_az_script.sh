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

# The name of the IRIS instance you want to execute against
# This is used to build the VG, LVM, and mount point names
IRISNAME="ply"

# Source disk names in Azure associated with the instance
# If multiple disks, separate with a comma
AZDISKNAMES="datadisk-ply-01"

# Main script config fine
CONFIGFILE="./rubrik_az_config.yml"

pwsh ./Rubrik-New-v2-Ultra-Snapshot.ps1 -configFile "$CONFIGFILE" -irisName "$IRISNAME" -azDiskNames "$AZDISKNAMES"

# Capture the PowerShell exit code
exit_code=$?

exit $exit_code
