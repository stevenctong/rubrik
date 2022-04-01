# !/bin/bash
# Backup DB2 with Rubrik SLA MV
# Version 2.0
# Tested with Rubrik 5.3 and DB2 11.5
# Credit: Rafaela Martuchelli & Ganesh Balabharathi
####################################################################################
# How to use the Rubrik DB2 Backup Script:
# 1. Put the script to the db2inst1 home directory
# 2. Set the right paramters for the variables
# 3. Set the retention to the number of days you want to have the backups in the aktive MV
# 4. Define on which day you want to run a full backup
# 5. Define the Channel mount points
# Configuration required for DB2
# 1. Enable Online Backup
# 2. Enable Incremental backup
# Configuration on Rubrik
# 1. Create a SLA MV
# 2. Include the mountpoints you have
# 3. Add the path of this script
####################################################################################
# Source profile
. /u01/app/db2inst1/sqllib/db2profile
# VARIABLES DEFINITION
DBNAME=TPCC01
CURRENT_DAY=$(date +"%a")
CURRENT_DATE=$(date)
# Files older X day will be removed from the MV. This includes also the log files
# Deleted Files are still in the existing backups, so SLA retention will manage this
RETENTION=14
# Day of Full backup - Sun,Mon,...
FULL_BACKUP=Sun
# Checkfile - will be created if a FULL was allready done on the selected day
FULL_CREATED=/u01/app/db2inst1/scripts/rubrik-full-created-true
# Log file
LOG=/u01/app/db2inst1/scripts/logs/tpcc01_db2_backup.log
# LOCAL MV MOUNTPOINTS
RBKMV0=/mnt/rubrik/rpdb2demo03_tpcc01_mv01-ch0
RBKMV1=/mnt/rubrik/rpdb2demo03_tpcc01_mv01-ch0

# Write date to log
echo "------------------------------------------------------------------------------------------------" >> $LOG
echo "------------------------------------------------------------------------------------------------" >> $LOG
echo "Today is: $CURRENT_DAY , exact date is: $CURRENT_DATE" >> $LOG
echo "Running as User $(whoami)" >> $LOG
# MV house keeping - remove backups older then defined in RETENTION
echo "This files will be deleted" >> $LOG
find $RBKMV0 -path $RBKMV0/lost+found -prune -o -type f -mtime +$RETENTION >> $LOG
find $RBKMV1 -path $RBKMV1/lost+found -prune -o -type f -mtime +$RETENTION >> $LOG
find $RBKMV0 -path $RBKMV0/lost+found -prune -o -type f -mtime +$RETENTION -exec rm -f {} \; >> $LOG
find $RBKMV1 -path $RBKMV1/lost+found -prune -o -type f -mtime +$RETENTION -exec rm -f {} \; >> $LOG
# Keep last 1000 lines in log file
sed -i -e :a -e '$q;N;1000,$D;ba' $LOG
function run_full_backup {
echo "RUN FULL BACKUP" >> $LOG
db2 "connect to $DBNAME" >> $LOG
db2 "backup database $DBNAME online to $RBKMV0, $RBKMV1 parallelism 2 INCLUDE LOGS WITHOUT PROMPTING" >> $LOG
               # Error handling block
               if [ $? -eq 0 ]
               then
                 echo "RUN FULL BACKUP successfull" >> $LOG
               else
                 echo "RUN FULL BACKUP failed" >> $LOG
                 exit 1
               fi
}
function run_incremental_backup {
echo "RUN INC BACKUP" >> $LOG
db2 "connect to $DBNAME" >> $LOG
db2 "backup database $DBNAME online INCREMENTAL to $RBKMV0, $RBKMV1 parallelism 2 INCLUDE LOGS WITHOUT PROMPTING" >> $LOG
               # Error handling block
               if [ $? -eq 0 ]
               then
                 echo "RUN INC BACKUP successfull" >> $LOG
               else
                 echo "RUN INC BACKUP failed" >> $LOG
                 exit 1
               fi
}
if [ "$CURRENT_DAY" == "$FULL_BACKUP" ]; then
 if [ -f "$FULL_CREATED" ]; then
  run_incremental_backup
 else
  run_full_backup
  touch "$FULL_CREATED"
 fi
else
  run_incremental_backup
if [ -f "$FULL_CREATED" ]; then
  rm "$FULL_CREATED"
 fi
fi
