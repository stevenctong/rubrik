from constants.global_constants import Gbps_TO_TB_PER_HOUR, Gbps_TO_TB_PER_DAY, \
    NETWORK_OVERHEAD_FACTOR

class Replication:
    def __init__(self,
                 core_first_full_tb: float = None,
                 core_total_incremental_tb: float = None,
                 log_daily_ingest_tb: float = None,
                 replication_first_full_days: int = None,
                 replication_incremental_hours: int = None):

        self.core_first_full_tb = core_first_full_tb
        self.core_total_incremental_tb = core_total_incremental_tb
        self.log_daily_ingest_tb = log_daily_ingest_tb
        self.replication_first_full_days = replication_first_full_days
        self.replication_incremental_hours = replication_incremental_hours

        replication_first_full = core_first_full_tb + log_daily_ingest_tb
        self.seeding_gbps = replication_first_full / replication_first_full_days / \
            Gbps_TO_TB_PER_DAY * NETWORK_OVERHEAD_FACTOR

        replication_incremental = core_total_incremental_tb + log_daily_ingest_tb
        self.incremental_gbps = replication_incremental / replication_incremental_hours / \
            Gbps_TO_TB_PER_HOUR * NETWORK_OVERHEAD_FACTOR
