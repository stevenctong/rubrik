from input import TOTAL_FETB, DATA_REDUCTION_RATIO, TOTAL_NON_COMPRESSIBLE_FETB, ANNUAL_GROWTH_PERCENT, \
    HOURLY_FREQUENCY, HOURLY_RETENTION_DAYS, HOURLY_CHANGE_RATE_PERCENT, \
    DAILY_FREQUENCY, DAILY_RETENTION_DAYS, DAILY_CHANGE_RATE_PERCENT, \
    WEEKLY_FREQUENCY, WEEKLY_RETENTION_WEEKS, WEEKLY_CHANGE_RATE_PERCENT, \
    MONTHLY_FREQUENCY, MONTHLY_RETENTION_MONTHS, MONTHLY_CHANGE_RATE_PERCENT, \
    QUARTERLY_FREQUENCY, QUARTERLY_RETENTION_QUARTERS, QUARTERLY_CHANGE_RATE_PERCENT, \
    YEARLY_FREQUENCY, YEARLY_RETENTION_YEARS, YEARLY_CHANGE_RATE_PERCENT
from sla import Sla

def main():
    my_sla = Sla(total_fetb = TOTAL_FETB,
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
    print("FETB: %d" % my_sla.total_fetb)
    print("FETB non-compressible: %d" %my_sla.total_non_compressible_fetb)
    print("Data reduction ratio: %f" % my_sla.data_reduction_ratio)
    print("First full: %f" % my_sla.first_full)
    print("")
    print("Hourly retention days: %f" % my_sla.hourlyRetentionDays)
    print("Hourly incremental size: %f" % my_sla.hourlyIncrementalSize)
    print("Hourly total size: %f" % my_sla.hourlyTotalSize)
    print("Hourlies retained: %f" % my_sla.hourlyRetained)
    print("Daily retention days: %f" % my_sla.dailyRetentionDays)
    print("Daily incremental size: %f" % my_sla.dailyIncrementalSize)
    print("Daily total size: %f" % my_sla.dailyTotalSize)
    print("Dailies retained: %f" % my_sla.dailyRetained)
    print("Weekly retention days: %f" % my_sla.weeklyRetentionDays)
    print("Weekly incremental size: %f" % my_sla.weeklyIncrementalSize)
    print("Weekly total size: %f" % my_sla.weeklyTotalSize)
    print("Weeklies retained: %f" % my_sla.weeklyRetained)
    print("Monthly retention days: %f" % my_sla.monthlyRetentionDays)
    print("Monthly incremental size: %f" % my_sla.monthlyIncrementalSize)
    print("Monthly total size: %f" % my_sla.monthlyTotalSize)
    print("Monthlies retained: %f" % my_sla.monthlyRetained)
    print("Yearly retention days: %f" % my_sla.yearlyRetentionDays)
    print("Yearly incremental size: %f" % my_sla.yearlyIncrementalSize)
    print("Yearly total size: %f" % my_sla.yearlyTotalSize)
    print("Yearlies retained: %f" % my_sla.yearlyRetained)
    print("")
    for days in my_sla.days_size_table:
        print("Days - %d: %f" % (days, my_sla.days_size_table[days]))
    return my_sla

main()

# if __name__ == '__main__':
