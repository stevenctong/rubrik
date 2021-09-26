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
from datetime import datetime, timezone, timedelta
# Use to import Rubrik login variables from another file
from rubrik_info import *

urllib3.disable_warnings()

# ---- VARIABLES - BEGIN ----

# Rubrik cluster login variables - use either username/password or API token
# node_ip = ''
# username = ''
# password = ''
# api_token = ''

# SLA to check VMs that don't have an on demand snapshot
source_sla = '12hr-30d-AWS'

# Target SLA to use for the On Demand Snapshots
target_sla = ''

# ---- VARIABLES - END ----


# Use one of the following methods to connect to the Rubrik cluster (login variables are defined previously)
# rubrik = rubrik_cdm.Connect(node_ip, username, password)
rubrik = rubrik_cdm.Connect(node_ip, api_token=api_token)


# For source_sla, get a list of SLAs with like match, filter for exact match, and grab SLA ID
source_sla_info = rubrik.get('v1', '/sla_domain?primary_cluster_id=local&name={}'.format(source_sla))
source_sla_data = source_sla_info['data']
source_sla_id = ''
# Filter for exact SLA name match
for slas in source_sla_data:
    if (slas['name'] == source_sla):
        source_sla_id = slas['id']

# Get a list of VMware VMs from the source SLA
object_list = {}
object_list = rubrik.get('v1', '/vmware/vm?primary_cluster_id=local&effective_sla_domain_id={}'.format(source_sla_id))

total_count = object_list['total']
print("Total number of objects found in {}: {}\n".format(source_sla, total_count))

# Build a list of VMs that have zero snapshots
snapshot_list = []

for objects in object_list['data']:
    snapshots = rubrik.get_vsphere_vm_snapshot(objects['name'])

    # If no snapshots are returned for the VM, add the VM to the snapshot list
    if (snapshots['total'] == 0):
        snapshot_list.append(objects)
        print("Found VM with no snapshots: {}".format(objects['name']))

print("Total # of VMs that needs an immediate snapshot: {}\n".format(len(snapshot_list)))

# For target_sla, get a list of SLAs with like match, filter for exact match, and grab SLA ID
target_sla_info = rubrik.get('v1', '/sla_domain?primary_cluster_id=local&name={}'.format(target_sla))
target_sla_data = target_sla_info['data']
target_sla_id = ''
# Filter for exact SLA name match
for slas in target_sla_data:
    if (slas['name'] == target_sla):
        target_sla_id = slas['id']

# Create the POST json for the on demand snapshot
snapshot_json = {}
snapshot_json['slaId'] = target_sla_id

# Take on demand snapshot for each VM that needs it
for objects in snapshot_list:
    print("Taking a snapshot of: {}".format(objects['name']))
    result = rubrik.post('v1', '/vmware/vm/{}/snapshot'.format(objects['id']), snapshot_json)
