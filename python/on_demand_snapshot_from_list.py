#! /usr/bin/env python
# https://build.rubrik.com
# https://github.com/rubrikinc/rubrik-sdk-for-python

# Title: on_demand_snapshot_from_list.py
# Description: Reads a CSV file containing a list of Object IDs + SLA Domains and takes an On Demand Snapshot for each

# Author: Steven Tong
# GitHub: stevenctong
# Date: 5/3/21

import rubrik_cdm
import urllib3
import urllib2
import csv
from datetime import datetime
# Use to import Rubrik login variables from another file
from rubrik_info import *

urllib3.disable_warnings()

# Rubrik cluster login info - use either username/password or API token (recommended)
# node_ip = ""
# username = ""
# password = ""
# api_token = ""

today = datetime.today()
today = today.strftime("%Y-%m-%d_%H%M")

# CSV of Object IDs + SLA Domains to trigger an on demand snapshot for
object_csv_dir = './'
object_csv_filename = 'list.csv'
object_csv = '{}{}'.format(object_csv_dir, object_csv_filename)

# Use one of the following to connect to the Rubrik cluster
# rubrik = rubrik_cdm.Connect(node_ip, username, password)
rubrik = rubrik_cdm.Connect(node_ip, api_token=api_token)

object_list = []

# Read CSV containing list of Object IDs + SLAs to take an on demand snasphot of
with open(object_csv, 'r') as csv_file:
    csv_reader = csv.DictReader(csv_file, delimiter=',')
    object_list_headers = csv_reader.fieldnames

    # For each object
    for row in csv_reader:
        object_list.append(row.copy())
        print("Taking on demand snapshot of object: {}, Location: {} to SLA: {}, Type: {}".format(row['Object Name'], row['Location'], row['SLA Domain'], row['Object Type']))

        # Get the a list of local SLAs matching the SLA name, filter for exact match, and grab SLA ID
        sla_info = rubrik.get('v1', '/sla_domain?primary_cluster_id=local&name={}'.format(row['SLA Domain']))
        sla_data = sla_info['data']
        sla_id = ''
        # Filter for exact SLA name match
        for i in sla_data:
            if (i['name'] == row['SLA Domain']):
                sla_id = i['id']
        # Proceed if we found a matching SLA
        if (sla_id != ''):
            if (row['Object Type'] == 'vSphere VM'):
                snapshot_json = {}
                snapshot_json['slaId'] = sla_id
                try:
                    snapshot = rubrik.post('v1', '/vmware/vm/{}/snapshot'.format(row['Object ID']), snapshot_json)
                except Exception:
                    print("Error taking on demand snapshot of {}, continuing to next".format(row['Object Name']))
                    pass
        else:
            print("SLA {} not found, skipping {}".format(row['SLA Domain'], row['Object Name']))
