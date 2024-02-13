from input import TOTAL_FETB, DATA_REDUCTION_RATIO, TOTAL_NON_COMPRESSIBLE_FETB, ANNUAL_GROWTH_PERCENT, \
    HOURLY_FREQUENCY, HOURLY_RETENTION_DAYS, HOURLY_CHANGE_RATE_PERCENT, \
    DAILY_FREQUENCY, DAILY_RETENTION_DAYS, DAILY_CHANGE_RATE_PERCENT, \
    WEEKLY_FREQUENCY, WEEKLY_RETENTION_WEEKS, WEEKLY_CHANGE_RATE_PERCENT, \
    MONTHLY_FREQUENCY, MONTHLY_RETENTION_MONTHS, MONTHLY_CHANGE_RATE_PERCENT, \
    QUARTERLY_FREQUENCY, QUARTERLY_RETENTION_QUARTERS, QUARTERLY_CHANGE_RATE_PERCENT, \
    YEARLY_FREQUENCY, YEARLY_RETENTION_YEARS, YEARLY_CHANGE_RATE_PERCENT
from capacityCore import CapacityCore

def main():
    my_capacity_core = CapacityCore(total_fetb = TOTAL_FETB,
        data_reduction_ratio = DATA_REDUCTION_RATIO,
        total_non_compressible_fetb = TOTAL_NON_COMPRESSIBLE_FETB,
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
        yearly_change_rate=YEARLY_CHANGE_RATE_PERCENT
    )
    print("FETB: %d" % my_capacity_core.total_fetb)
    print("FETB non-compressible: %d" %my_capacity_core.total_non_compressible_fetb)
    print("Data reduction ratio: %f" % my_capacity_core.data_reduction_ratio)
    print("First full: %f" % my_capacity_core.first_full)
    print("")
    print("Hourly retention days: %f" % my_capacity_core.hourlyRetentionDays)
    print("Hourly incremental size: %f" % my_capacity_core.hourlyIncrementalSize)
    print("Hourly total size: %f" % my_capacity_core.hourlyTotalSize)
    print("Hourlies retained: %f" % my_capacity_core.hourlyRetained)
    print("Daily retention days: %f" % my_capacity_core.dailyRetentionDays)
    print("Daily incremental size: %f" % my_capacity_core.dailyIncrementalSize)
    print("Daily total size: %f" % my_capacity_core.dailyTotalSize)
    print("Dailies retained: %f" % my_capacity_core.dailyRetained)
    print("Weekly retention days: %f" % my_capacity_core.weeklyRetentionDays)
    print("Weekly incremental size: %f" % my_capacity_core.weeklyIncrementalSize)
    print("Weekly total size: %f" % my_capacity_core.weeklyTotalSize)
    print("Weeklies retained: %f" % my_capacity_core.weeklyRetained)
    print("Monthly retention days: %f" % my_capacity_core.monthlyRetentionDays)
    print("Monthly incremental size: %f" % my_capacity_core.monthlyIncrementalSize)
    print("Monthly total size: %f" % my_capacity_core.monthlyTotalSize)
    print("Monthlies retained: %f" % my_capacity_core.monthlyRetained)
    print("Yearly retention days: %f" % my_capacity_core.yearlyRetentionDays)
    print("Yearly incremental size: %f" % my_capacity_core.yearlyIncrementalSize)
    print("Yearly total size: %f" % my_capacity_core.yearlyTotalSize)
    print("Yearlies retained: %f" % my_capacity_core.yearlyRetained)
    print("")
    for days in my_capacity_core.days_size_table:
        print("Days - %d: %f" % (days, my_capacity_core.days_size_table[days]))
    return my_capacity_core

main()

# if __name__ == '__main__':
