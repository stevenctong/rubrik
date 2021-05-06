#! /usr/bin/env python
# https://build.rubrik.com
# https://github.com/rubrikinc/rubrik-sdk-for-python

# Title: get_out_of_compliance.py
# Description: Downloads the Dashboard -> Compliance Report and generates a list of objects that are out of compliance

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

# Local path to download compliance report CSV
compliance_csv_dir = './'
compliance_csv_filename = 'compliance_report_{}.csv'.format(today)
compliance_csv = '{}{}'.format(compliance_csv_dir, compliance_csv_filename)

# Local path to write non-compliant objects report CSV
non_compliant_csv_dir = './'
non_compliant_csv_filename = 'non_compliant_objects_{}.csv'.format(today)
non_compliant_csv = '{}{}'.format(non_compliant_csv_dir, non_compliant_csv_filename)

# Use one of the following to connect to the Rubrik cluster
# rubrik = rubrik_cdm.Connect(node_ip, username, password)
rubrik = rubrik_cdm.Connect(node_ip, api_token=api_token)

# Get Dashboard -> Compliance Report CSV link
print("Downloading Dashboard -> Compliance Report to file: {}".format(compliance_csv))
compliance_url = rubrik.get('internal', '/report/data_source/FrequentDataSource/csv')

# Replace any spaces in URL with %20
compliance_file = urllib2.urlopen(compliance_url.replace(" ","%20"))

# Download CSV to local path
with open(compliance_csv, 'wb') as local_file:
    local_file.write(compliance_file.read())

non_compliant_objects = []

print("The following objects are out of compliance:\n")

# Read CSV again and build list of non-compliant objects (ones that missed the last snapshot)
with open(compliance_csv, 'r') as csv_file:
    csv_reader = csv.DictReader(csv_file, delimiter=',')
    non_compliant_objects_headers = csv_reader.fieldnames
    for row in csv_reader:
        if (row['Last Snapshot Status'] == 'Out of Compliance'):
            print('Name: {:22s}, Location: {:27s}, Type: {}'.format(row['Object Name'], row['Location'], row['Object Type']))
            non_compliant_objects.append(row.copy())

print("\nTotal number of non-compliant objects: {}".format(len(non_compliant_objects)))
print("Writing non-compliant objects to CSV file: {}".format(non_compliant_csv))

# Write CSV of non-compliant objects for review
with open(non_compliant_csv, 'w') as csv_file:
    csv_writer = csv.DictWriter(csv_file, fieldnames = non_compliant_objects_headers)
    csv_writer.writeheader()
    csv_writer.writerows(non_compliant_objects)
