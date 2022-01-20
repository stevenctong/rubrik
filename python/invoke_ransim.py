#! /usr/bin/env python
# https://build.rubrik.com
# https://github.com/rubrikinc/rubrik-sdk-for-python

# Title: invoke_ransim.py
# Description: For a list of VMs, triggers ransim scripts on the host if there are
#              greater than some number of existing backups for the VM.

# Author: Steven Tong
# GitHub: stevenctong
# Date: 1/19/22

import rubrik_cdm
import urllib3
import csv
from datetime import datetime
# Use to import Rubrik login variables from another file
# from rubrik_info import *

urllib3.disable_warnings()

# Rubrik cluster login info - use either username/password or API token (recommended)
node_ip = ""
username = ""
password = ""
# api_token = ""

ssh_username = ''
ssh_password = ''
ssh_command = '/root/ransim.sh'

# VM list : Hostname/IP of VMs to check and hostname/IP to execute SSH comamnds against
vm_list = {
    '': '',
    '': ''
}

backup_count = 6

def get_vm_snapshot_num(vm_name):
    """
    get_vm_snapshot_num returns the total # of backups taken.
    :vm_name: VM name to return the number of snapshots taken.
    """
    vm_info = rubrik.get_vsphere_vm_details(vm_name)
    return vm_info['snapshotCount']

# Use one of the following to connect to the Rubrik cluster
rubrik = rubrik_cdm.Connect(node_ip, username, password)
# rubrik = rubrik_cdm.Connect(node_ip, api_token=api_token)

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

for vm in vm_list:
    vm_snapcount = get_vm_snapshot_num(vm)
    if (vm_snapcount > backup_count):
        client.connect(hostname=vm_list[vm], username=ssh_username,
            password=ssh_password)
