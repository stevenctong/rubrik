#! /usr/bin/env python
# https://build.rubrik.com
# https://github.com/rubrikinc/rubrik-sdk-for-python

# Title: assign_user_to_org_role.py
# Description: Assigns a Rubrik user to an organization role

# Author: Steven Tong
# GitHub: stevenctong
# Date: 5/4/21

import rubrik_cdm
import urllib3
from rubrik_info import *

urllib3.disable_warnings()

# Rubrik cluster login info - use either username/password or API token (recommended)
# node_ip = ""
# username = ""
# password = ""
# api_token = ""

# Username you want to assign to an organization name and organization role
# The organization and organization role should already be created
username = "steven.tong@rubrikdemo.com"
org_name = "ST - DBAs"
org_role = "User Admin"

# Use one of the following to connect to the Rubrik cluster
rubrik = rubrik_cdm.Connect(node_ip, username, password)
# rubrik = rubrik_cdm.Connect(node_ip, api_token)

# Get LDAP list and Local authorization providers
ldap_service = rubrik.get('v1', '/ldap_service')
ldap_data = ldap_service['data']

# Find LDAP ID. If a domain ID, username should be in <user>@<domain> format.
username_split = username.split('@')

if (len(username_split) == 1):
    for i in ldap_data:
        if (i['name'] == 'local'):
            ldap_id = i['id']
            ldap_name = 'local'
else:
    for i in ldap_data:
        if (i['name'] == username_split[1]):
            ldap_id = i['id']
            ldap_name = i['name']

try:
    print("Found domain: {}, ID: {}".format(ldap_name, ldap_id))
except NameError:
    print("Unable to find LDAP {}".format(ldap_name))
    raise

username_info = rubrik.get('v1', '/principal?auth_domain_id={}&name={}'.format(ldap_id, username_split[0]))

try:
    user_id = username_info['data'][0]['id']
    print("Found username: {}, ID: {}".format(username, user_id))
except NameError:
    print("Unable to find username {}".format(username))
    raise

# Find organization ID
org_info = rubrik.get('internal', '/organization?name={}'.format(org_name))
org_data = org_info['data']
for i in org_data:
    if (i['name'] == org_name):
        org_id = i['id']
        org_roleid = i['roleId']

try:
    print("Found organization: {}, ID: {}, roleID: {}".format(org_name, org_id, org_roleid))
except NameError:
    print("Unable to find organization: {}".format(org_name))
    raise

# Find organization role ID
org_role_info = rubrik.get('v1', '/role?organization_id={}'.format(org_id))
org_role_data = org_role_info['data']
for i in org_role_data:
    if (i['name'] == org_role):
        org_role_id = i['roleId']

try:
    print("Found org role: {}, ID: {}".format(org_role, org_role_id))
except NameError:
    print("Unable to find org role: {}".format(org_role))
    raise

# Grant user authorization in the organization
grant_auth_json = {}
grant_auth_json['authorizationSpecifications'] = [ { 'privilege':'ManageAccess', 'resources' : [ user_id ] } ]
grant_auth_json['roleTemplate'] = 'Organization'
grant_auth = rubrik.post('internal', '/role/{}/authorization'.format(org_roleid), grant_auth_json)

# Assign user the organization role
assign_json = {}
assign_json['principals'] = [ user_id ]
assign_json['roles'] = [ org_role_id ]
assign_role = rubrik.post('v1', '/principal/role', assign_json)

print("""Assigned user: "{}", to organization: "{}", role: "{}""""".format(username, org_name, org_role))
