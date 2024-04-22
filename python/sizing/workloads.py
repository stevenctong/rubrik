import math

"""
This file defines the list of supported workloads for sizing and which
modules to use for sizing the workload.
It also contains workload-specific functions to complete all the sizing
outputs for each workload.
"""

# List of workloads that should be input to the CapacityCore class.
CAPACITYCOREWORKLOADS = ["VMS"]

# List of workloads that should be input to the CapacityDBLogs class.
CAPACITYDBLOGSWORKLOADS = ["VMS"]


class VMS:
    def __init__(self,
                 object_count: int = None,
                 cdp_bool: bool = False,
                 cdp_retention_hours: int = None,
                 cdp_total_vms: int = None,
                 cdp_avg_vmdks_per_vm: int = None,
                 cdp_avg_write_MBPS: int = None,
                 cdp_peak_write_MBPS: int = None,
                 lm_bool: int = False,
                 lm_total_vms: int = None,
                 lm_total_size_tb: float = None,
                 lm_largest_vm_tb: float = None,
                 lm_duration_days: int = None):

        self.cdp_bool = cdp_bool
        self.lm_bool = lm_bool

        if cdp_bool == True:
            self.cdp_total_vmdks = cdp_total_vms * cdp_avg_vmdks_per_vm
            MBPS_TO_TBHR = 60 * 60 / 1000 / 1000
            # Multiply by 2 since we need to retain data until the previous snap expires
            self.cdp_briks_num_vmdks = math.ceil(self.cdp_total_vmdks / 200)
            self.cdp_briks_avg_write_throughput = math.ceil(self.cdp_total_vmdks * cdp_avg_write_MBPS / 200)
            self.cdp_size_tb = self.cdp_total_vmdks * cdp_avg_write_MBPS * MBPS_TO_TBHR * 2
            if cdp_retention_hours > 24:
                self.cdp_warning_retention = "Swimlane exceeded: CDP retention must be <= 24 hours"
            if cdp_avg_write_MBPS > 50:
                self.cdp_warning_avg_throughput = "Swimlane exceeded: average VMDK throughput of 50 MB/s sustained is exceeded."
            if cdp_peak_write_MBPS > 50:
                self.cdp_warning_peak_throughput = "Swimlane exceeded: single VMDK peak throughput of 50 MB/s sustained is exceeded."
        else:
            self.cdp_size_tb = 0

        if lm_bool == True:
            # Calculate # of regular Briks based on # of LM VMs
            regular_briks_per_lm_vm
            if lm_largest_vm_tb > 30:
                self.lm_brik_type = "Swimlane limit of 30 TB exceeded."
            elif lm_largest_vm_tb > 3:
                self.lm_brik_type = "Enhanced flash briks (SE) recommended."
            else:
                self.lm_brik_type = "Regular Briks recommended."
