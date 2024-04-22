
def check_capacity_core(my_capacity_core):
    print("")
    print("***** Core Capacity Calcuations *****")
    print("FETB: %f" % my_capacity_core.total_fetb)
    print("FETB non-compressible: %f" % my_capacity_core.total_non_compressible_fetb)
    print("Data reduction ratio: %f" % my_capacity_core.data_reduction_ratio)
    print("First full: %f" % my_capacity_core.first_full_tb)
    print("")
    try:
        print("Hourly retention days: %d, frequency: %d" % (my_capacity_core.hourlyRetentionDays, my_capacity_core.hourlyFrequency))
        print("Hourlies retained: %d" % my_capacity_core.hourlyRetained)
        print("Hourly incremental size (TB): %f" % my_capacity_core.hourlyIncrementalSize)
        print("Hourly total size (TB): %f" % my_capacity_core.hourlyTotalSize)
        print("")
    except:
        pass
    try:
        print("Daily retention days: %d, frequency: %d" % (my_capacity_core.dailyRetentionDays, my_capacity_core.dailyFrequency))
        print("Dailies retained: %d" % my_capacity_core.dailyRetained)
        print("Daily incremental size (TB): %f" % my_capacity_core.dailyIncrementalSize)
        print("Daily total size (TB): %f" % my_capacity_core.dailyTotalSize)
        print("")
    except:
        pass
    try:
        print("Weekly retention days: %d, frequency: %d" % (my_capacity_core.weeklyRetentionDays, my_capacity_core.weeklyFrequency))
        print("Weeklies retained: %f" % my_capacity_core.weeklyRetained)
        print("Weekly incremental size (TB): %f" % my_capacity_core.weeklyIncrementalSize)
        print("Weekly total size (TB): %f" % my_capacity_core.weeklyTotalSize)
        print("")
    except:
        pass
    try:
        print("Monthly retention days: %d, frequency: %d" % (my_capacity_core.monthlyRetentionDays, my_capacity_core.monthlyFrequency))
        print("Monthlies retained: %d" % my_capacity_core.monthlyRetained)
        print("Monthly incremental size (TB): %f" % my_capacity_core.monthlyIncrementalSize)
        print("Monthly total size (TB): %f" % my_capacity_core.monthlyTotalSize)
        print("")
    except:
        pass
    try:
        print("Quarterly retention days: %d, frequency: %d" % (my_capacity_core.quarterlyRetentionDays, my_capacity_core.quarterlyFrequency))
        print("Quarterlies retained: %f" % my_capacity_core.quarterlyRetained)
        print("Quarterly incremental size (TB): %f" % my_capacity_core.quarterlyIncrementalSize)
        print("Quarterly total size (TB): %f" % my_capacity_core.quarterlyTotalSize)
        print("")
    except:
        pass
    try:
        print("Yearly retention days: %d, frequency: %d" % (my_capacity_core.yearlyRetentionDays, my_capacity_core.yearlyFrequency))
        print("Yearlies retained: %d" % my_capacity_core.yearlyRetained)
        print("Yearly incremental size: %f" % my_capacity_core.yearlyIncrementalSize)
        print("Yearly total size: %f" % my_capacity_core.yearlyTotalSize)
        print("")
    except:
        pass
    for days in my_capacity_core.days_size_table:
        print("Days - %d: %f" % (days, my_capacity_core.days_size_table[days]))
    print("")
    print("Max retention: %d days" % my_capacity_core.total_max_retention)
    print("")
    print("Days to replicate: %d" % my_capacity_core.replication_days)
    print("Replication capacity: %f" % my_capacity_core.replication_capacity)

def check_capacity_db_logs(my_capacity_db_logs):
    print("")
    print("***** DB Log Capacity Calculations *****")
    print("Daily log FETB: %f" % my_capacity_db_logs.log_daily_fetb)
    print("Daily log FETB non-compressible: %f" % my_capacity_db_logs.log_daily_non_compressible_fetb)
    print("Log data reduction ratio: %f" % my_capacity_db_logs.log_data_reduction_ratio)
    print("Total log daily ingest (TB): %f" % my_capacity_db_logs.log_daily_ingest_tb)
    print("")
    print("Log retention (days): %d" % my_capacity_db_logs.log_retention_days)
    for days in my_capacity_db_logs.days_size_table:
        print("Days - %d: %f" % (days, my_capacity_db_logs.days_size_table[days]))

def check_total_capcity(capacity_table):
    print("")
    print("***** Yearly Capacity Sizing *****")
    for days in capacity_table:
        print("Days - %d: %f" % (days, capacity_table[days]))

def check_replication(my_replication):
    print("")
    print("***** Replication Calculations *****")
    print("Replication Full Size (TB): %f" % my_replication.core_first_full_tb)
    print("Replication Incremental Size (TB): %f" % my_replication.core_total_incremental_tb)
    print("Replication DB Log Size (TB): %f" % my_replication.log_daily_ingest_tb)
    print("Replication target seeding in days: %d" % my_replication.replication_first_full_days)
    print("Replication target incremental in hours: %d" % my_replication.replication_incrmental_hours)
    print("")
    print("Replication seeding Gbps: %f" % my_replication.seeding_gbps)
    print("Replication incremental Gbps: %f" % my_replication.incremental_gbps)
