#! /usr/bin/env python
# https://build.rubrik.com

# Title: get_report_csv.py
# Description: Download the Rubrik CSV for a specific report. Report name should be unique.

# Author: Steven Tong
# GitHub: stevenctong
# Date: 11/6/22

import requests
from datetime import datetime

# Rubrik cluster hostname or IP
rubrik_ip = ''

# Rubrik user API token
api_token = ''

# Name of the Rubrik report to get the CSV, it should be fully unique
report_name = 'Custom - Protection Task Details'

timestamp = datetime.now().strftime("%Y-%m-%d_%Hh%Mm")

# Filename to write the CSV to
csv_filename = "rubrik_report_{}.csv".format(timestamp)

# REST API header including authorization
header = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'Authorization': 'Bearer {}'.format(api_token)
}

# Base REST API URL
base_url = "https://{}/api/".format(rubrik_ip)

# Get report info
req_url  = "{}internal/report?name={}".format(base_url,report_name)
req_report = requests.get(req_url, verify=False, headers=header)

if (len(req_report.json()['data']) == 1):
    report_id = req_report.json()['data'][0]['id']
elif (len(req_report.json()['data']) == 0):
    print("No report found by name: {}".format(report_name))
    print("Exiting...")
    exit()
else:
    print("Report name is not unique - multiple reports found by name: {}".format(report_name))
    print("Exiting...")
    exit()

# Get report CSV link
req_url  = "{}internal/report/{}/csv_link".format(base_url,report_id)
req_csvlink = requests.get(req_url, verify=False, headers=header)

# Download CSV and write to a file
req_download = requests.get(req_csvlink.json(), verify=False, stream=True)

with open(csv_filename, "wb") as output:
    output.write(req_download.content)
