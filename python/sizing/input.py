"""
Define input parameters for sizing in this file when using this
package as standalone for sizing, where main.py is the driver.
The contents of this file should be imported only from main.py file.
"""

# Specify the workload type to size
# Types: VMS
WORKLOAD_TYPE = "VMS"

# Specify total used Front End TB (in TB, base 10) and data reduction ratio
TOTAL_FETB = 100
DATA_REDUCTION_RATIO = 2.5

# Specify total non-compressible FETB (in TB, base 10)
TOTAL_NON_COMPRESSIBLE_FETB = 20

# Specify which days to model sizing for. Put into an array, with number of days.
DAYS_TO_SIZE = [365, 730, 1095, 1460, 1825]

# Specify the total size of DB logs that will be ingested (in TB, base 10) and data reduction ratio
LOG_DAILY_FETB = 5
LOG_DATA_REDUCTION_RATIO = 2

# Specify total non-compressible daliy log FETB (in TB, base 10)
LOG_DAILY_NON_COMPRESSIBLE_FETB = 2

# Specify number of days to retention the DB logs for
LOG_RETENTION_DAYS = 14

# Specify the object count for the workload
OBJECT_COUNT = 500

# Specify the annual growth percentage. We model the growth by distributing
# it on a daily basis (using compounding formula) to calculate the new full
# and incremental size each day with this growth factor.
ANNUAL_GROWTH_PERCENT = 10

# Specify the number of days to replicate. If no replication, use '0' days.
# If replication is specified, you can also specify how quickly you need
# replication first fulls to complete in (DAYS) and incrementals to complete
# in (HOURS).
REPLICATION_DAYS = 7
REPLICATION_FIRST_FULL_DAYS = 2
REPLICATION_INCREMENTAL_HOURS = 8

# Hourly snapshot parameters
# - HOURLY_FREQUENCY specifies every how many hours to take a hourly frequency
# snapshot. Specify one for snapshot every hour. Specify zero to not take
# hourly snapshots.
# - HOURLY_RETENTION_HOURS specifies the total retention of daily snapshots.
# If HOURLY_FREQUENCY is specified, then this retention must also be specified.
HOURLY_FREQUENCY = 1
HOURLY_RETENTION_DAYS = 3
HOURLY_CHANGE_RATE_PERCENT = 0.2

# Daily snapshot parameters
# - DAILY_FREQUENCY specifies every how many days to take a daily frequency
# snapshot. Specify one for snapshot everyday. Specify zero to not take
# daily snapshots.
# - DAILY_RETENTION_DAYS specifies the total retention of daily snapshots.
# If DAILY_FREQUENCY is specified, then this retention must also be specified.
DAILY_FREQUENCY = 1
DAILY_RETENTION_DAYS = 30
DAILY_CHANGE_RATE_PERCENT = 2

# Weekly snapshot parameters
# - WEEKLY_FREQUENCY specifies every how many weeks to take a weekly frequency
# snapshot. Specify one for snapshot every week. Specify zero to not take
# weekly snapshots.
# - WEEKLY_RETENTION_DAYS specifies the total retention of weekly snapshots. If
# the WEEKLY_FREQUENCY is specified, then this retention must also be specified.
# - WEEKLY_CHANGE_RATE_PERCENT specifies the change rate between two weekly
# snapshots. It should be greater than DAILY_CHANGE_RATE_PERCENT if specified.
# If no daily snapshots are taken, the size of each taken incremental snapshot
# will be governed by this parameter.
WEEKLY_FREQUENCY = 1
WEEKLY_RETENTION_WEEKS = 8
WEEKLY_CHANGE_RATE_PERCENT = 4

# Monthly snapshot parameters:
# - MONTHLY_FREQUENCY specifies every how many months to take a monthly
# frequency snapshot. Specify one for snapshot every month. Specify zero to
# not take monthly snapshots. A month is considered every 30 days.
# - MONTHLY_RETENTION_DAYS specifies the total retention of monthly snapshots.
# If the MONTHLY_FREQUENCY is specified, then this retention must also be
# specified.
# - MONTHLY_CHANGE_RATE_PERCENT specifies the change rate between two monthly
# snapshots. It should be greater than DAILY or WEEKLY change rates if
# specified. If no daily or weekly snapshots are taken, the size of each taken
# incremental snapshot will be governed by this parameter.
MONTHLY_FREQUENCY = 1
MONTHLY_RETENTION_MONTHS = 12
MONTHLY_CHANGE_RATE_PERCENT = 10

# Quarterly snapshot parameters
# - QUARTERLY_FREQUENCY specifies every how many quarters to take a quarterly
# frequency snapshot. Specify one for snapshot every quarter. Specify zero
# to not take quarterly snapshots. A quarter is considered every 91 days.
# - QUARTERLY_RETENTION_DAYS specifies the total retention of monthly snapshots.
# If the QUARTERLY_FREQUENCY is specified, then this retention must also be
# specified.
# - QUARTERLY_CHANGE_RATE_PERCENT specifies the change rate between two
# quarterly snapshots. It should be greater than faster frequency change rates
# if specified. If no faster frequency snapshots are taken, the size of each
# taken incremental snapshot will be governed by this parameter.
QUARTERLY_FREQUENCY = 0
QUARTERLY_RETENTION_QUARTERS = 0
QUARTERLY_CHANGE_RATE_PERCENT = 20

# Yearly snapshot parameters
# - YEARLY_FREQUENCY specifies every how many years to take a yearly
# frequency snapshot. Specify one for snapshot every year. Specify zero
# to not take yearly snapshots. A year is considered every 365 days. We
# don't expect to see a value higher than one for this.
# - YEARLY_RETENTION_DAYS specifies the total retention of yearly snapshots.
# If the YEARLY_FREQUENCY is specified, then this retention must also be
# specified.
# - YEARLY_CHANGE_RATE_PERCENT specifies the change rate between two
# yearly snapshots. It should be greater than faster frequency change rates
# if specified. If no faster frequency snapshots are taken, the size of each
# taken incremental snapshot will be governed by this parameter.
YEARLY_FREQUENCY = 0
YEARLY_RETENTION_YEARS = 3
YEARLY_CHANGE_RATE_PERCENT = 30

# WORKLOAD SPECIFIC INPUTS BELOW

# VMS - Inputs for VMS - VMware, Hyper-V, and Nutanix AHV
CDP_BOOL = False
CDP_RETENTION_HOURS = 24
CDP_TOTAL_VMS = 50
CDP_AVG_VMDKS_PER_VM = 2
CDP_AVG_WRITE_MBPS = 10
CDP_PEAK_WRITE_MBPS = 40
LM_BOOL = False
LM_TOTAL_VMS = 25
LM_TOTAL_SIZE_TB = 5
LM_LARGEST_VM_TB = 10
LM_DURATION_DAYS = 2

# SQL - Inputs for SQL
