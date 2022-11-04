#! /usr/bin/env python
# https://build.rubrik.com

# Title: oracle_live_mount.py
# Description: Initiates Oracle Live Mount for automated test restores.

# Author: Steven Tong
# GitHub: stevenctong
# Date: 11/4/22

import requests
import time
import json
import sys
from calendar import timegm
from random import randrange

# Rubrik cluster hostname or IP
rubrik_ip = ''

# Rubrik user API token
api_token = ''

# Array of Oracle IDs to choose from
oracle_ids = [ '' ]

# Target Host ID or 'same_host'
target_host_id = 'same_host'

# Target host mount path, with no trailing /, eg '/rubrikmount'
target_host_path = ''

# Pick a random Oracle DB
random_pick = randrange(len(oracle_ids))
oracle_id = oracle_ids[random_pick]

# REST API header including authorization
header = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'Authorization': 'Bearer {}'.format(api_token)
}

# Base REST API URL
base_url = "https://{}/api/".format(rubrik_ip)

# Get Oracle DB info, especially latest recovery point
req_url  = "{}v1/oracle/db/{}".format(base_url,oracle_id)
req_db = requests.get(req_url, verify=False, headers=header)

# Grab target Host ID if same host
if target_host_id == 'same_host':
    target_host_id = req_db.json()['infraPath'][0]['id']

# Grab host information
if 'Host' in target_host_id:
    req_url  = "{}internal/oracle/host/{}".format(base_url,target_host_id)
else:
    req_url  = "{}internal/oracle/rac/{}".format(base_url,target_host_id)

req_host = requests.get(req_url, verify=False, headers=header)

# Format latest recovery point as epoch time  in milliseconds
latest_recovery_point = req_db.json()['latestRecoveryPoint']
utc_recovery_point = time.strptime("{}".format(latest_recovery_point), "%Y-%m-%dT%H:%M:%S.%fZ")
epoch_recovery_point = timegm(utc_recovery_point)
epoch_recovery_point_ms = epoch_recovery_point * 1000

# Oracle Live Mount payload
payload = {
    "recoveryPoint": {
        "timestampMs": epoch_recovery_point_ms
    },
    "targetOracleHostOrRacId": "{}".format(target_host_id),
    "shouldMountFilesOnly": True,
    "targetMountPath": "{}".format(target_host_path),
    "advancedRecoveryConfigMap": {}
}

json_payload = json.dumps(payload)

# Live Mount info
lm_info = {
    'db': req_db.json()['name'],
    'db_id': req_db.json()['id'],
    'host': req_host.json()['name'],
    'host_id': req_host.json()['id'],
    'latest_recovery_point': req_db.json()['latestRecoveryPoint'],
    'latest_recovery_point_epochms': epoch_recovery_point_ms
}

print("\n\n\nPlease review the following Oracle DB to be Live Mounted\n")
print (json.dumps(lm_info, indent=2, sort_keys=True))

# Prompt to continue, can remove when fully automting
if sys.version_info >= (3, 0):
    ask = input("Input y to continue, any other characters to exit:\n")
else:
    ask = raw_input("Input y to continue, any other characters to exit:\n")

# Initiate Oracle Live Mount if user answers 'y'
if ask == 'y':
    print('Initiating Oracle Live Mount')
    # Initiate Oracle Live Mount
    req_url  = "{}internal/oracle/db/{}/mount".format(base_url,oracle_id)
    req_lm = requests.post(req_url, verify=False, headers=header, data=json_payload)
else:
    print('Exiting...')



# # To get list of Oracle RAC hosts for the DB
# req_url  = "{}internal/oracle/hierarchy/root/children?primary_cluster_id=local&sort_by=name&sort_order=asc".format(base_url)
# req = requests.get(req_url, verify=False, headers=header)
#
# hosts = []
#
# for x in req.json()['data']:
#     db_host = {
#         "host": x['name'],
#         "host_id":  x['id']
#     }
#     hosts.append(db_host)
