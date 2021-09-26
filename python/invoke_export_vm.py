#! /usr/bin/env python
# https://build.rubrik.com
# https://github.com/rubrikinc/rubrik-sdk-for-python

# Title: invoke_export_vm.py
# Description: Create multiple Exports for a specified VM

# Author: Steven Tong
# GitHub: stevenctong
# Date: 9/25/21

import rubrik_cdm
import urllib3
from datetime import datetime
# Use to import Rubrik variables info from another file
from rubrik_info import *

urllib3.disable_warnings()

# ---- VARIABLES - BEGIN ----

# Rubrik cluster login variables - use either username/password or API token
# node_ip = ''
# username = ''
# password = ''
# api_token = ''

# Name of the VMware VM to export
vm_name = ''

# Whether to power on the VM after export - True or False
vm_poweron = True

# The number of VM exports to perform
export_count = 1

# UTC time for the nearest snapshot you want to export - use 'MM/DD/YYYY HH:MM' format
recovery_date = '09/15/2021 12:00'

# ESXi hostname to export to
esxi_host = ''

# Datastore accessible to the ESXi host to export to - make sure there is enough capacity on the datastore
datastore = ''

# ---- VARIABLES - END ----


def get_closest_snapshot(snapshot_list, recovery_datetime):
    """
    get_closest_snapshot finds the snapshot closest to a date and returns it.

    :snapshot_list: A list of snapshots
    :recovery_datetime: Find the snapshot in the list closest to this date
    """

    # Initiate the closest_snapshot as the current one to process
    closest_snapshot = snapshot_list[0]
    closest_snapshot_datetime = datetime.strptime(snapshot_list[0]['date'], '%Y-%m-%dT%H:%M:%S.%fZ')

    # Loop through the snapshot list and compare the recovery date with the current snapshot in the list
    # If it is closer than the closest_snapshot, then replace it as the closest_snapshot
    for snapshots in snapshot_list:
        snapshot_datetime = datetime.strptime(snapshots['date'], '%Y-%m-%dT%H:%M:%S.%fZ')
        if (abs(recovery_datetime - snapshot_datetime) < abs(closest_snapshot_datetime - snapshot_datetime)):
            closest_snapshot = snapshots
            closest_snapshot_datetime = datetime.strptime(snapshots['date'], '%Y-%m-%dT%H:%M:%S.%fZ')
    return closest_snapshot


# Use one of the following methods to connect to the Rubrik cluster (login varaibles are defined previously)
# rubrik = rubrik_cdm.Connect(node_ip, username, password)
rubrik = rubrik_cdm.Connect(node_ip, api_token=api_token)

# Get a list of snapshots for the given VM
vm_snapshots = rubrik.get_vsphere_vm_snapshot(vm_name)

# Convert the recovery date to a datetime object
recovery_datetime = datetime.strptime(recovery_date, '%m/%d/%Y %H:%M')

# Get the closest snapshot to the recovery date in the list of snapshots on the VM
snapshot = get_closest_snapshot(vm_snapshots['data'], recovery_datetime)

# Get the a list of ESXi hosts, filter for exact match, and grab Host ID
esxi_host_info = rubrik.get('v1', '/vmware/host?primary_cluster_id=local')
esxi_host_data = esxi_host_info['data']
esxi_host_id = ''
# Filter for exact ESXi host name match
for hosts in esxi_host_data:
    if (hosts['name'] == esxi_host):
        esxi_host_id = hosts['id']

# Get the a list of datastores accessible to the ESXi host, filter for exact match, and grab datastore ID
datastore_info = rubrik.get('v1', '/vmware/host/{}/datastore?primary_cluster_id=local'.format(esxi_host_id))
datastore_info_data = datastore_info['datastores']
datastore_id = ''
# Filter for exact datastore name match
for datastores in datastore_info_data:
    if (datastores['name'] == datastore):
        datastore_id = datastores['id']

# Create the POST json for the export
export_json = {}
export_json['vmName'] = vm_name
export_json['powerOn'] = vm_poweron
export_json['hostId'] = esxi_host_id
export_json['datastoreId'] = datastore_id

count = 1

# Export VMs based on number required
while (count <= export_count):
    print("Exporting # {} of {}: VM: {}, from snapshot date (UTC): {}".format(count, export_count, vm_name, snapshot['date']))
    count += 1
    result = rubrik.post('v1', '/vmware/vm/snapshot/{}/export'.format(snapshot['id']), export_json)
