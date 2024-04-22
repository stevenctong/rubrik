from input import *
from capacityCore import CapacityCore
from capacityDBLogs import CapacityDBLogs
from replication import Replication
from workloads import *
from tests.test0 import *
from tests.test1 import *

def main():
    # Use the capacity core calculations for most workloads
    if WORKLOAD_TYPE in CAPACITYCOREWORKLOADS:
        my_capacity_core = CapacityCore(total_fetb = TOTAL_FETB,
            data_reduction_ratio = DATA_REDUCTION_RATIO,
            total_non_compressible_fetb = TOTAL_NON_COMPRESSIBLE_FETB,
            days_to_size = DAYS_TO_SIZE,
            hourly_frequency=HOURLY_FREQUENCY,
            hourly_retention=HOURLY_RETENTION_DAYS,
            hourly_change_rate=HOURLY_CHANGE_RATE_PERCENT,
            daily_frequency=DAILY_FREQUENCY,
            daily_retention=DAILY_RETENTION_DAYS,
            daily_change_rate=DAILY_CHANGE_RATE_PERCENT,
            weekly_frequency=WEEKLY_FREQUENCY,
            weekly_retention=WEEKLY_RETENTION_WEEKS,
            weekly_change_rate=WEEKLY_CHANGE_RATE_PERCENT,
            monthly_frequency=MONTHLY_FREQUENCY,
            monthly_retention=MONTHLY_RETENTION_MONTHS,
            monthly_change_rate=MONTHLY_CHANGE_RATE_PERCENT,
            quarterly_frequency=QUARTERLY_FREQUENCY,
            quarterly_retention=QUARTERLY_RETENTION_QUARTERS,
            quarterly_change_rate=QUARTERLY_CHANGE_RATE_PERCENT,
            yearly_frequency=YEARLY_FREQUENCY,
            yearly_retention=YEARLY_RETENTION_YEARS,
            yearly_change_rate=YEARLY_CHANGE_RATE_PERCENT,
            replication_days = REPLICATION_DAYS
        )

    total_max_retention = my_capacity_core.total_max_retention

    # Use the capacity DB logs calculations for database workloads
    if WORKLOAD_TYPE in CAPACITYDBLOGSWORKLOADS:
        my_capacity_db_logs = CapacityDBLogs(log_daily_fetb = LOG_DAILY_FETB,
            log_data_reduction_ratio = LOG_DATA_REDUCTION_RATIO,
            log_daily_non_compressible_fetb = LOG_DAILY_NON_COMPRESSIBLE_FETB,
            log_retention_days = LOG_RETENTION_DAYS,
            days_to_size = DAYS_TO_SIZE,
            replication_days = REPLICATION_DAYS,
            total_max_retention = total_max_retention
        )
        log_daily_ingest_tb = my_capacity_db_logs.log_daily_ingest_tb
    else:
        log_daily_ingest_tb = 0

    # Create final capacity table
    capacity_table = {}
    if (total_max_retention > 180):
        days_for_year0 = 180
    else:
        days_for_year0 = total_max_retention

    for days in DAYS_TO_SIZE:
        if WORKLOAD_TYPE in CAPACITYDBLOGSWORKLOADS:
            capacity_table[days] = my_capacity_core.days_size_table[days] + my_capacity_db_logs.days_size_table[days]
        else:
            capacity_table[days] = my_capacity_core.days_size_table[days]



    # Calculate replication throughput requirements
    if REPLICATION_DAYS > 0:
        my_replication = Replication(core_first_full_tb = my_capacity_core.first_full_tb,
            core_total_incremental_tb = my_capacity_core.total_incremental_tb,
            log_daily_ingest_tb = log_daily_ingest_tb,
            replication_first_full_days = REPLICATION_FIRST_FULL_DAYS,
            replication_incremental_hours = REPLICATION_INCREMENTAL_HOURS)

    if WORKLOAD_TYPE == "VMS":
        my_vms = VMS(object_count = OBJECT_COUNT,
            cdp_bool = CDP_BOOL, cdp_retention_hours = CDP_RETENTION_HOURS,
            cdp_total_vms = CDP_TOTAL_VMS,
            cdp_avg_vmdks_per_vm = CDP_AVG_VMDKS_PER_VM,
            cdp_avg_write_MBPS = CDP_AVG_WRITE_MBPS,
            cdp_peak_write_MBPS = CDP_PEAK_WRITE_MBPS,
            lm_bool = LM_BOOL, lm_total_vms = LM_TOTAL_VMS,
            lm_total_size_tb = LM_TOTAL_SIZE_TB, lm_largest_vm_tb = LM_LARGEST_VM_TB,
            lm_duration_days = LM_DURATION_DAYS)

    try:
        check_total_capcity(capacity_table)
    except:
        pass
    try:
        check_capacity_core(my_capacity_core)
    except:
        pass
    try:
        check_capacity_db_logs(my_capacity_db_logs)
    except:
        pass
    try:
        check_replication(my_replication)
    except:
        pass
    try:
        check_vms(my_vms)
    except:
        pass

    return

main()

# if __name__ == '__main__':
