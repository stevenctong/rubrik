#!/bin/bash
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 12/23/20

# This function will query RMAN backup stats and write it out to a specified log file.

### backup_stats() ###
# The 'backup_stats()' function will query RMAN backup status and write it to a specified log file.
# Input $1 : '0' if the backup completed successfully, '1' if not
# Input $2 : Description of the backup status, eg "COMPLETED" or "FAILED"
backup_stats() {
  # BACKUP_TYPE should be one of the following: 'DB FULL', 'DB INCR', 'ARCHIVELOG'
  BACKUP_TYPE='DB INCR'
  # Path to write the formatted log results to
  LOG_FILE=''
  RMAN_TABLE="v\$rman_backup_job_details"
  # ${ORACLE_HOME}/bin/sqlplus -s / >> ${1} <<EOF
  # RMAN_STATUS=$(${ORACLE_HOME}/bin/sqlplus -s / >> $RMAN_LOG << EOF
  RMAN_STATUS=$(${ORACLE_HOME}/bin/sqlplus -s / << EOF
  connect /
  set feedback off
  set pagesize 0
  set linesize 200
  alter session set NLS_DATE_FORMAT = 'yyyy-mm-dd HH24:mi:ss';
  col "START_TIME" for a19
  col "STATUS" for a25
  col "INPUT_TYPE" for a10
  col "HOURS" for a9
  col "HOURS" format 9999.99
  col "IN_BYTES" for a10
  col "OUT_BYTES" for a10
  col "IN_RATE" for a10
  col "OUT_RATE" for a10
  col "DURATION" for a8
  col "END_TIME" for a19
  select start_time as "START_TIME",
  status as "STATUS",
  input_type as "INPUT_TYPE",
  elapsed_seconds/3600 as "HOURS",
  input_bytes_display as "IN_BYTES",
  output_bytes_display as "OUT_BYTES",
  input_bytes_per_sec_display as "IN_RATE",
  output_bytes_per_sec_display as "OUT_RATE",
  time_taken_display as "DURATION",
  end_time as "END_TIME"
  from ${RMAN_TABLE}
  where (input_type = 'ARCHIVELOG') and (start_time = (select max(start_time) from ${RMAN_TABLE}))
  order by start_time desc;
EOF
  )

  DB_NAME=$(${ORACLE_HOME}/bin/sqlplus -s / << EOF
  connect /
  set feedback off
  set pagesize 0
  set linesize 200
  select name from v\$database;
EOF
  )

  # Loop through the returned RMAN results and print out each line
  # while read -r line
  # do
  #   echo $line
  # done <<< "$RMAN_STATUS"

  # Format the CSV line and write it out to the log file
  # DB_NAME,START_TIME,GOOD_BACKUP,STATUS,TYPE,HOURS,OUT_BYTES,OUT_RATE,END_TIME
  CSV_OUTPUT="${DB_NAME},"
  CSV_OUTPUT+=$(echo "$DB_RESULT" | awk -F ' ' '{printf "%s %s,", $1, $2;}')
  CSV_OUTPUT+=$(printf "$1,$2,")
  CSV_OUTPUT+=$(echo "$DB_RESULT" | awk -F ' ' '{printf "%s,%s,%s,%s,%s %s", $4, $5, $7, $9, $11, $12;}')
  echo $CSV_OUTPUT >> $LOG_FILE
}
