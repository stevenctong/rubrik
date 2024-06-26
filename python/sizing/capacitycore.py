import math
from typing import List
from error import InputError
from constants.global_constants import HOURS_IN_DAY, DAYS_IN_WEEK, \
    DAYS_IN_MONTH, DAYS_IN_YEAR, DAYS_IN_QUARTER

class CapacityCore:
    def __init__(self,
                 total_fetb: int = None,
                 data_reduction_ratio: float = None,
                 total_non_compressible_fetb: int = None,
                 days_to_size: List[int] = None,
                 hourly_frequency: int = None,
                 hourly_retention: int = None,
                 hourly_change_rate: float = None,
                 daily_frequency: int = None,
                 daily_retention: int = None,
                 daily_change_rate: float = None,
                 weekly_frequency: int = None,
                 weekly_retention: int = None,
                 weekly_change_rate: float = None,
                 monthly_frequency: int = None,
                 monthly_retention: int = None,
                 monthly_change_rate: float = None,
                 quarterly_frequency: int = None,
                 quarterly_retention: int = None,
                 quarterly_change_rate: float = None,
                 yearly_frequency: int = None,
                 yearly_retention: int = None,
                 yearly_change_rate: float = None,
                 replication_days: int = None):

        # If FETB is specified, calculate the first full after data reduction
        if total_fetb:
            assert total_fetb > 0
            assert data_reduction_ratio and data_reduction_ratio > 0
            self.reduced_total_fetb = total_fetb / data_reduction_ratio
            self.total_fetb = total_fetb
            self.data_reduction_ratio = data_reduction_ratio
        else:
            total_fetb = 0

        # If non-compressible capacity is specified, this will not have any
        # data reduction applied
        if total_non_compressible_fetb:
            assert total_non_compressible_fetb > 0
            self.total_non_compressible_fetb = total_non_compressible_fetb
        else:
            self.total_non_compressible_fetb = 0

        self.first_full_tb = self.reduced_total_fetb + self.total_non_compressible_fetb

        # Calculate out what the retention for each frequency is
        if hourly_frequency:
            hourly_retention_days = hourly_retention
            total_max_retention = hourly_retention_days
        if daily_frequency:
            daily_retention_days = daily_retention
            if (daily_retention_days < total_max_retention):
                self.warningMsg = "Dailies are inclusive of %s. " \
                    "Daily retention of %d days should be larger than %s retention of %d days." \
                    % (max_retention_freq, daily_retention_days, max_retention_freq, max_retention)
                raise InputError(self.warningMsg)
            total_max_retention = daily_retention_days
        if weekly_frequency:
            weekly_retention_days = weekly_retention * DAYS_IN_WEEK
            if (weekly_retention_days < total_max_retention):
                self.warningMsg = "Weeklies are inclusive of %s. " \
                    "Weekly retention of %d days should be larger than %s retention of %d days." \
                    % (max_retention_freq, weekly_retention_days, max_retention_freq, max_retention)
                raise InputError(self.warningMsg)
            total_max_retention = weekly_retention_days
        if monthly_frequency:
            monthly_retention_days = monthly_retention * DAYS_IN_MONTH
            if (monthly_retention_days < total_max_retention):
                self.warningMsg = "Monthlies are inclusive of %s. " \
                    "Monthly retention of %d days should be larger than %s retention of %d days." \
                    % (max_retention_freq, monthly_retention_days, max_retention_freq, max_retention)
                raise InputError(self.warningMsg)
            total_max_retention = monthly_retention_days
        if quarterly_frequency:
            quarterly_retention_days = quarterly_retention * DAYS_IN_QUARTER
            if (quarterly_retention_days < total_max_retention):
                self.warningMsg = "Quarterlies are inclusive of %s. " \
                    "Quarterly retention of %d days should be larger than %s retention of %d days." \
                    % (max_retention_freq, quarterly_retention_days, max_retention_freq, max_retention)
                raise InputError(self.warningMsg)
            total_max_retention = quarterly_retention_days
        if yearly_frequency:
            yearly_retention_days = yearly_retention * DAYS_IN_YEAR
            if (yearly_retention_days < total_max_retention):
                self.warningMsg = "Yearlies are inclusive of %s. " \
                    "Yearly retention of %d days should be larger than %s retention of %d days." \
                    % (max_retention_freq, yearly_retention_days, max_retention_freq, max_retention)
                raise InputError(self.warningMsg)
            total_max_retention = yearly_retention_days


        # Hash table where we will store the days we will size for
        # We start with the first full and then add the calculated incrementals
        days_size_table = {}
        for days in days_to_size:
            days_size_table[days] = self.first_full_tb

        # Add the max local retention to the sizing table
        if (total_max_retention not in days_to_size):
            days_to_size.append(total_max_retention)
            days_size_table[total_max_retention] = self.first_full_tb

        # If replication is specified, add the number of replication days to the
        # table to calculate the sizing for
        assert replication_days > 0
        self.replication_days = replication_days
        if (replication_days not in days_to_size):
            days_to_size.append(replication_days)
            days_size_table[replication_days] = self.first_full_tb


        # max_retention used for calculating each sizing frequency
        max_retention: int = 0

        if hourly_frequency:
            # hourly_retention is in days
            assert hourly_frequency > 0
            assert hourly_retention and hourly_retention > 0
            assert hourly_change_rate > 0
            if hourly_frequency == 1:
                freq_str = 'Every hour'
            else:
                freq_str = 'Every %d hours' % hourly_frequency
            num_hourlies = math.ceil(hourly_retention * HOURS_IN_DAY / hourly_frequency)
            self.hourlyFrequency = hourly_frequency
            self.hourlyRetentionDays = hourly_retention_days
            self.hourlyChangeRate = hourly_change_rate
            self.hourlyIncrementalSize = self.first_full_tb * self.hourlyChangeRate / 100
            self.hourlyTotalSize = self.hourlyIncrementalSize * num_hourlies
            self.hourlyRetained = num_hourlies
            # We want to calculate the size for some given days
            for days in days_to_size:
                if days >= hourly_retention_days:
                    days_size_table[days] += self.hourlyTotalSize
                else:
                    num_hourlies_for_days = math.ceil(days * HOURS_IN_DAY / hourly_frequency)
                    days_size_table[days] += num_hourlies_for_days * self.hourlyIncrementalSize
            max_retention = hourly_retention_days
            max_retention_freq = 'hourlies'
        else:
            self.hourlyFrequency = None
            self.hourlyRetentionDays = None
            self.hourlyChangeRate = None
            self.hourlyIncrementalSize = 0
            self.hourlyTotalSize = None
            self.hourlyRetained = None
        if daily_frequency:
            assert daily_frequency > 0
            assert daily_retention and daily_retention > 0
            assert daily_change_rate > 0
            num_dailies_to_keep = daily_retention_days - max_retention
            if daily_frequency == 1:
                freq_str = 'Everyday'
            else:
                freq_str = 'Every %d days' % daily_frequency
            num_dailies = math.ceil(num_dailies_to_keep / daily_frequency)
            self.dailyFrequency = daily_frequency
            self.dailyRetentionDays = daily_retention_days
            self.dailyChangeRate = daily_change_rate
            self.dailyIncrementalSize = self.first_full_tb * self.dailyChangeRate / 100
            self.dailyTotalSize = self.dailyIncrementalSize * num_dailies
            self.dailyRetained = num_dailies
            # We want to calculate the size for some given days
            for days in days_to_size:
                if days >= daily_retention_days:
                    days_size_table[days] += self.dailyTotalSize
                else:
                    num_dailies_for_days = math.ceil((days - max_retention) / daily_frequency)
                    if num_dailies_for_days > 0:
                        days_size_table[days] += num_dailies_for_days * self.dailyIncrementalSize
            max_retention = daily_retention_days
            max_retention_freq = 'dailies'
        else:
            self.dailyFrequency = None
            self.dailyRetentionDays = None
            self.dailyChangeRate = None
            self.dailyIncrementalSize = 0
            self.dailyTotalSize = None
            self.dailyRetained = None

        if weekly_frequency:
            assert weekly_frequency > 0
            assert weekly_retention and weekly_retention > 0
            assert weekly_change_rate > 0
            num_weeklies_to_keep = math.ceil((weekly_retention_days - max_retention) / DAYS_IN_WEEK)
            if weekly_frequency == 1:
                freq_str = 'Every week'
            else:
                freq_str = 'Every %d weeks' % weekly_frequency
            num_weeklies = math.ceil(num_weeklies_to_keep / weekly_frequency)
            self.weeklyFrequency = weekly_frequency
            self.weeklyRetentionDays = weekly_retention_days
            self.weeklyChangeRate = weekly_change_rate
            self.weeklyIncrementalSize = self.first_full_tb * self.weeklyChangeRate / 100
            self.weeklyTotalSize = self.weeklyIncrementalSize * num_weeklies
            self.weeklyRetained = num_weeklies
            # We want to calculate the size for some given days
            for days in days_to_size:
                if days >= weekly_retention_days:
                    days_size_table[days] += self.weeklyTotalSize
                else:
                    num_weeklies_for_days = math.ceil((days - max_retention) / DAYS_IN_WEEK / weekly_frequency)
                    if num_weeklies_for_days > 0:
                        days_size_table[days] += num_weeklies_for_days * self.weeklyIncrementalSize
            max_retention = weekly_retention_days
            max_retention_freq = 'weeklies'
        else:
            self.weeklyFrequency = None
            self.weeklyRetentionDays = None
            self.weeklyChangeRate = None
            self.weeklyIncrementalSize = 0
            self.weeklyTotalSize = None
            self.weeklyRetained = None

        if monthly_frequency:
            assert monthly_frequency > 0
            assert monthly_retention and monthly_retention > 0
            assert monthly_change_rate > 0
            num_monthlies_to_keep = math.ceil((monthly_retention_days - max_retention) / DAYS_IN_MONTH)
            if monthly_frequency == 1:
                freq_str = 'Every month'
            else:
                freq_str = 'Every %d months' % monthly_frequency
            num_monthlies = math.ceil(num_monthlies_to_keep / monthly_frequency)
            self.monthlyFrequency = monthly_frequency
            self.monthlyRetentionDays = monthly_retention_days
            self.monthlyChangeRate = monthly_change_rate
            self.monthlyIncrementalSize = self.first_full_tb * self.monthlyChangeRate / 100
            self.monthlyTotalSize = self.monthlyIncrementalSize * num_monthlies
            self.monthlyRetained = num_monthlies
            # We want to calculate the size for some given days
            for days in days_to_size:
                if days >= monthly_retention_days:
                    days_size_table[days] += self.monthlyTotalSize
                else:
                    num_monthlies_for_days = math.ceil((days - max_retention) / DAYS_IN_MONTH / monthly_frequency)
                    if num_monthlies_for_days > 0:
                        days_size_table[days] += num_monthlies_for_days * self.monthlyIncrementalSize
            max_retention = monthly_retention_days
            max_retention_freq = 'monthlies'
        else:
            self.monthlyFrequency = None
            self.monthlyRetentionDays = None
            self.monthlyChangeRate = None
            self.monthlyIncrementalSize = 0
            self.monthlyTotalSize = None
            self.monthlyRetained = None

        if quarterly_frequency:
            assert quarterly_frequency > 0
            assert quarterly_retention and quarterly_retention > 0
            assert quarterly_change_rate > 0
            num_quarterlies_to_keep = math.ceil((quarterly_retention_days - max_retention) / DAYS_IN_QUARTER)
            if quarterly_frequency == 1:
                freq_str = 'Every quarter'
            else:
                freq_str = 'Every %d quarters' % quarterly_frequency
            num_quarterlies = math.ceil(num_quarterlies_to_keep / quarterly_frequency)
            self.quarterlyFrequency = quarterly_frequency
            self.quarterlyRetentionDays = quarterly_retention_days
            self.quarterlyChangeRate = quarterly_change_rate
            self.quarterlyIncrementalSize = self.first_full_tb * self.quarterlyChangeRate / 100
            self.quarterlyTotalSize = self.quarterlyIncrementalSize * num_quarterlies
            self.quarterlyRetained = num_quarterlies
            # We want to calculate the size for some given days
            for days in days_to_size:
                if days >= quarterly_retention_days:
                    days_size_table[days] += self.quarterlyTotalSize
                else:
                    num_quarterlies_for_days = math.ceil((days - max_retention) / DAYS_IN_QUARTER / quarterly_frequency)
                    if num_quarterlies_for_days > 0:
                        days_size_table[days] += num_quarterlies_for_days * self.quarterlyIncrementalSize
            max_retention = quarterly_retention_days
            max_retention_freq = 'quarterlies'
        else:
            self.quarterlyFrequency = None
            self.quarterlyRetentionDays = None
            self.quarterlyChangeRate = None
            self.quarterlyIncrementalSize = 0
            self.quarterlyTotalSize = None
            self.quarterlyRetained = None

        if yearly_frequency:
            assert yearly_frequency > 0
            assert yearly_retention and yearly_retention > 0
            assert yearly_change_rate > 0
            num_yearlies_to_keep = math.ceil((yearly_retention_days - max_retention) / DAYS_IN_YEAR)
            if yearly_frequency == 1:
                freq_str = 'Every year'
            else:
                freq_str = 'Every %d years' % yearly_frequency
            num_yearlies = math.ceil(num_yearlies_to_keep / yearly_frequency)
            self.yearlyFrequency = yearly_frequency
            self.yearlyRetentionDays = yearly_retention_days
            self.yearlyChangeRate = yearly_change_rate
            self.yearlyIncrementalSize = self.first_full_tb * self.yearlyChangeRate / 100
            self.yearlyTotalSize = self.yearlyIncrementalSize * num_yearlies
            self.yearlyRetained = num_yearlies
            for days in days_to_size:
                if days >= yearly_retention_days:
                    days_size_table[days] += self.yearlyTotalSize
                else:
                    num_yearlies_for_days = math.ceil((days - max_retention) / DAYS_IN_YEAR / yearly_frequency)
                    if num_yearlies_for_days > 0:
                        days_size_table[days] += num_yearlies_for_days * self.yearlyIncrementalSize
            max_retention = yearly_retention_days
            max_retention_freq = 'yearlies'
        else:
            self.yearlyFrequency = None
            self.yearlyRetentionDays = None
            self.yearlyChangeRate = None
            self.yearlyIncrementalSize = 0
            self.yearlyTotalSize = None
            self.yearlyRetained = None

        if (self.replication_days > max_retention):
            self.warningMsg = "Replication retention of %d days should be less than or equal to total retention of %d days. " \
                % (replication_days, max_retention)
            raise InputError(self.warningMsg)

        self.total_incremental_tb = self.hourlyIncrementalSize + \
            self.dailyIncrementalSize + self.weeklyIncrementalSize + \
            self.monthlyIncrementalSize + self.quarterlyIncrementalSize + \
            self.yearlyIncrementalSize
        self.total_max_retention = total_max_retention
        self.days_size_table = days_size_table
        self.replication_capacity = self.days_size_table[replication_days]

        # is_ret_days_not_valid = self.validate_retention_days()
        # if is_ret_days_not_valid:
        #     self.warningMsg = is_ret_days_not_valid

    # def validate_retention_days(self):
    #     """Check if later retention days are > than previous retention days"""
    #     rets_to_compare = []
    #     if self.dailyFrequency and self.dailyFrequency > 0:
    #         rets_to_compare.append({"key": "Daily", "value": self.dailyRetentionDays})
    #     if self.weeklyFrequency and self.weeklyFrequency > 0:
    #         rets_to_compare.append({"key": "Weekly", "value": self.weeklyRetentionDays})
    #     if self.monthlyFrequency and self.monthlyFrequency > 0:
    #         rets_to_compare.append({"key": "Monthly", "value": self.monthlyRetentionDays})
    #     if self.quarterlyFrequency and self.quarterlyFrequency > 0:
    #         rets_to_compare.append({"key": "Quarterly", "value": self.quarterlyRetentionDays})
    #     if self.yearlyFrequency and self.yearlyFrequency > 0:
    #         rets_to_compare.append({"key": "Yearly", "value": self.yearlyRetentionDays})
    #
    #     for i in range(len(rets_to_compare) - 1):
    #         if rets_to_compare[i]["value"] > rets_to_compare[i + 1]["value"]:
    #             err = f'{rets_to_compare[i + 1]["key"]} retention days cannot be less than {rets_to_compare[i]["key"]} retention days.'
    #             return err
    #
    #     return None
