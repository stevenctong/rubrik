#!/bin/bash
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 10/15/21

# This script will run 'iperf3' against several source-target host pairs using specified iPerf parameters.
# The results will output to a JSON file which can then be parsed using:
# - https://github.com/rubrikinc/rubrik-scripts-for-powershell/blob/master/MISC/Parse-iPerfResults.ps1
# The script can log into each TARGET host to put it in '-s' mode,
# or you can manually put all TARGETS in '-s'.
# The script will cycle through all the SOURCE hosts and run iPerf to the TARGET hosts.
# iPerf parameters should be specified and each parameter will be a test run.
# You will need passwordless SSH in order for this script to work.
# The script is setup to use Rubrik nodes as the source and ESXi hosts as a target as an example.

# File results will be appended to
RESULTS="./iperf_results_$(date +%Y-%m-%d)_$(date +%H%M).json"
# Log file
LOGPATH="./iperf_test.log"
# iPerf command to run on source side (Tx, executes -c with arguments)
SOURCE_IPERF3="network iperf -3"
# iPerf command to run on target side (Rx, executes -s)
TARGET_IPERF3="/usr/lib/vmware/vsan/bin/iperf3.copy"
# SSH user for source hosts
SOURCE_USERNAME="admin"
# SSH user for target hosts
TARGET_USERNAME="root"
# Service name to kill on target host when finished testing
TARGET_IPERF3_SERVICE="iperf3.copy"

# Array of source hosts, iPerf Tx, these use '-c' and send traffic
SOURCE_IPERF=('rubrik1' 'rubrik2' 'rubrik3' 'rubrik4')

# Array of target hosts, iPerf Rx, these are put in server mode (-s) and receive traffic
# Use the following if you want to specify different targets
TARGET_IPERF=('esxi1' 'esxi2' 'esxi3')

# Use the following if you want to test between all source pairs
# TARGET_IPERF=("${SOURCE_IPERF[@]}")

# Whether to SSH to each TARGET to put it in iperf server (-s) mode
# '1' or non-zero to put the TARGET in -s mode
# '0' to not put the TARGET in -s mode
# If '0' then you will manually login to each target host and put into 'iperf3 -s' mode
TARGET_SERVER_MODE=1

# iPerf parameters to use, below are some common ones
# -J : Always include to output results to JSON
# -t <#> : # of seconds to run each test for
# -P <#> : # of parallel threads, default 1, recommend also testing w/4
# -w <#> : TCP window size
# -R : Reverse the direction of source / target (send and receive)
IPERF_PARAMS=('-t 15 -J' '-t 15 -P 4 -J' '-t 15 -R -J' '-t 15 -P 4 -R -J')

echo -e "\n\nLogging started: $(date +%m-%d-%y) $(date +%H:%M:%S)" >> $LOGPATH

# Make a copy of iperf3 to use if testing ESXi hosts
echo -e "\n\nMaking a copy of iperf3: $(date +%m-%d-%y) $(date +%H:%M:%S)" | tee -a $LOGPATH
COMMAND="cp /usr/lib/vmware/vsan/bin/iperf3 $IPERF3"
# for i in "${SOURCE_IPERF[@]}"; do
#   ssh -t $SOURCE_USERNAME@$i -- $COMMAND >> $LOGPATH
# done
for i in "${TARGET_IPERF[@]}"; do
  ssh -t $TARGET_USERNAME@$i -- $COMMAND >> $LOGPATH
done

# Run iperf3 test matrix for each host
echo -e "\n\nRunning iperf3 test matrix: $(date +%m-%d-%y) $(date +%H:%M:%S)" | tee -a $LOGPATH

# Loop through each host as the target
for target in "${TARGET_IPERF[@]}"; do
  # Put the target into iPerf '-s' server mode
  if [ $TARGET_SERVER_MODE != 0 ]; then
    echo -e "\n${target}: Putting into iperf3 server mode (-s): $(date +%m-%d-%y) $(date +%H:%M:%S)" | tee -a $LOGPATH
    COMMAND="hostname;$TARGET_IPERF3 -s"
    ssh -f $TARGET_USERNAME@$target -- $COMMAND >> $LOGPATH
  fi

  # Loop through each host as a source
  for source in "${SOURCE_IPERF[@]}"; do
    # Loop through each param and perform an iperf for each source-target-param pairing
    for param in "${IPERF_PARAMS[@]}"; do
      # Run test if the source and target host are different
      if [ $source != $target ]; then
        echo -e "\nSource: $source; Target: $target; $SOURCE_IPERF3 -c $param" | tee -a $LOGPATH
        COMMAND="$SOURCE_IPERF3 -c $target $param"
        ssh -t $SOURCE_USERNAME@$source -- $COMMAND >> $RESULTS

        SLEEP 3
      fi
    done
  done

  if [ $TARGET_SERVER_MODE != 0 ]; then
    # Kill iPerf3 service on the target host
    echo -e "\n${target}: Killing iperf3 service: $(date +%m-%d-%y) $(date +%H:%M:%S)" | tee -a $LOGPATH
    COMMAND="hostname;pkill $TARGET_IPERF3_SERVICE"
    ssh -t $TARGET_USERNAME@$target -- $COMMAND >> $LOGPATH
  fi

done


# Put iperf3 in server mode on all hosts
# echo -e "\n\nPutting all hosts into iperf3 server mode: $(date +%m-%d-%y) $(date +%H:%M:%S)" | tee -a $LOGPATH
# COMMAND="hostname;$IPERF3 -s"
#
# for i in "${SOURCE_IPERF[@]}"; do
#   ssh -f $SOURCE_USERNAME@$i -- $COMMAND >> $LOGPATH
# done

# Kill any running iPerf3 process
# echo -e "\n\nKilling iperf3 service on all hosts: $(date +%m-%d-%y) $(date +%H:%M:%S)" | tee -a $LOGPATH
# COMMAND="hostname;pkill $IPERF3_SERVICE"
# for i in "${SOURCE_IPERF[@]}"; do
#   ssh -t $SOURCE_USERNAME@$i -- $COMMAND >> $LOGPATH
# done
