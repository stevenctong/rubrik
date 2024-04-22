import math
from typing import List
from error import InputError
from constants.global_constants import HOURS_IN_DAY, DAYS_IN_WEEK, \
    DAYS_IN_MONTH, DAYS_IN_YEAR, DAYS_IN_QUARTER

class CapacityDBLogs:
    def __init__(self,
                 log_daily_fetb: int = None,
                 log_data_reduction_ratio: float = None,
                 log_daily_non_compressible_fetb: int = None,
                 log_retention_days: int = None,
                 days_to_size: List[int] = None,
                 replication_days: int = None,
                 total_max_retention: int = None):

        if log_daily_fetb:
            assert log_daily_fetb > 0
            assert log_data_reduction_ratio and log_data_reduction_ratio > 0
            log_daily_fetb_after_reduction = log_daily_fetb / log_data_reduction_ratio
            self.log_daily_fetb = log_daily_fetb
            self.log_data_reduction_ratio = log_data_reduction_ratio

        if log_daily_non_compressible_fetb:
            assert log_daily_non_compressible_fetb > 0
            self.log_daily_non_compressible_fetb = log_daily_non_compressible_fetb

        assert log_retention_days and log_retention_days > 0
        self.log_retention_days = log_retention_days

        self.log_daily_ingest_tb = log_daily_fetb_after_reduction + log_daily_non_compressible_fetb

        assert total_max_retention > 0
        if (total_max_retention not in days_to_size):
            days_to_size.append(total_max_retention)

        if replication_days:
            assert replication_days > 0
            if (replication_days not in days_to_size):
                days_to_size.append(replication_days)

        # Hash table where we will store the days we will size for
        # DB log sizing is just the # of days * log capacity per day
        days_size_table = {}
        for days in days_to_size:
            if days >= log_retention_days:
                days_size_table[days] = log_retention_days * self.log_daily_ingest_tb
            else:
                days_size_table[days] = days * self.log_daily_ingest_tb

        self.days_size_table = days_size_table
