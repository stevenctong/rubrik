
import requests

rubrik_host = ''

base_url = 'https://{}/api/'.format(rubrik_host)

headers = {
    'accept': 'application/json',
    'Authorization': 'Bearer {}'.format(api_token),
    'Content-Type': 'application/json'
}

# VARIABLES
sql_db = 'AdventureWorks2014'
sql_instance = 'MSSQLSERVER'
sql_host = 'am1-stevtong-w1.rubrikdemo.com'
live_mount_name = 'adcopy'


def get_mssql_db_id(sql_host, sql_instance, sql_db):
    """
    Returns the database ID of the given host, instance, and DB.

    :sql_host: SQL DB host
    :sql_instance: SQL DB instance
    :sql_db: SQL DB name
    """

    endpoint = 'v1/mssql/db'
    filters = '?name={}'.format(sql_db)
    url = '{}{}{}'.format(base_url, endpoint, filters)
    resp = requests.get(url, headers=headers, verify=False)

    for db in resp.json()['data']:
        if (db['rootProperties']['rootName'] == sql_host and
                db['instanceName'] == sql_instance):
            sql_id = db['id']

    return sql_id


def get_mssql_instance_id(sql_host, sql_instance):
    """
    Returns the instance ID of the given host and instance.

    :sql_host: SQL DB host
    :sql_instance: SQL DB instance
    """

    endpoint = 'v1/mssql/instance'
    filters = ''
    url = '{}{}{}'.format(base_url, endpoint, filters)
    resp = requests.get(url, headers=headers, verify=False)

    for instance in resp.json()['data']:
        if (instance['rootProperties']['rootName'] == sql_host and instance['name'] == sql_instance):
            instance_id = instance['id']

    return instance_id


def invoke_mssql_live_mount(source_db_id, target_instance_id,
                            recovery_date, live_mount_name):
    """
    Invokes a SQL Live Mount and returns the result of the request.

    :source_db_id: Source SQL DB ID to Live Mount from
    :target_instance_id: Target DB instance to Live Mount to
    :recovery_date: Recovery date & time, use "YYYY-MM-DD HH:MM:SS" format
    :live_mount_name: Name of DB Live Mount
    """

    format_date = '{}T{}.000Z'.format(recovery_date.split()[0],
                                      recovery_date.split()[1])

    endpoint = 'v1/mssql/db/{}/mount'.format(source_db_id)
    filters = ''
    url = '{}{}{}'.format(base_url, endpoint, filters)

    payload = {
        'recoveryPoint': {
            'date': format_date
        },
        'mountedDatabaseName': live_mount_name,
        'targetInstanceId': target_instance_id
    }

    resp = requests.post(url, headers=headers, json=payload, verify=False)

    try:
        status = {
            'http_status_code': resp.status_code,
            'status': resp.json()['status'],
            'start_time': resp.json()['startTime'],
            'href': resp.json()['links'][0]['href'],
            'id': resp.json()['id']
        }
    except:
        status = {
            'http_status_code': resp.status_code,
            'status': resp.json()['message']
        }

    return status


def get_final_task_status(href):
    """
    Loop until task finishes and return status

    :href: Link to the status URL
    """

    resp = requests.get(href, headers=headers, verify=False)

    while (resp.json()['status'] != 'SUCCESS' or
           resp.json()['status'] != 'SUCCESSWITHWARNINGS' or
           resp.json()['status'] != 'FAILURE' or
           resp.json()['status'] != 'CANCELED'):

        resp = requests.get(href, headers=headers, verify=False)

    return resp.json()
