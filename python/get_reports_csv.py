import requests
import json
import time
from datetime import datetime

# Variables
report_id = 5  # Set your desired report ID here
service_account_path = './rsc-service-account-rr.json'  # Path to service account JSON
csv_report_filename = f"rubrik_report_csv-{datetime.utcnow().strftime('%Y-%m-%d_%H%M')}.csv"

# Rubrik Authentication
def authenticate_rsc(service_account_path):
    try:
        with open(service_account_path, 'r') as f:
            service_account = json.load(f)
        
        required_keys = ['client_id', 'client_secret', 'access_token_uri']
        missing_keys = [key for key in required_keys if key not in service_account]
        
        if missing_keys:
            raise ValueError(f"The Service Account JSON file is missing required keys: {missing_keys}")
        
        url = service_account['access_token_uri']
        payload = {
            "grant_type": "client_credentials",
            "client_id": service_account['client_id'],
            "client_secret": service_account['client_secret']
        }
        headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
        }
        
        response = requests.post(url, json=payload, headers=headers)
        response.raise_for_status()
        data = response.json()
        access_token = data['access_token']
        rubrik_url = url.replace("/api/client_token", "")
        
        return {
            "access_token": access_token,
            "rubrik_url": rubrik_url
        }
    except Exception as e:
        raise Exception(f"Failed to authenticate: {e}")

# Function: Generate Report CSV
def generate_report_csv(endpoint, headers, report_id):
    query = """
    mutation ($id: Int!, $config: CustomReportCreate) {
        downloadReportCsvAsync(input: {id: $id, config: $config}) {
            jobId
            referenceId
        }
    }
    """
    payload = {
        "query": query,
        "variables": {"id": report_id}
    }
    response = requests.post(endpoint, json=payload, headers=headers)
    response.raise_for_status()
    data = response.json()
    if 'errors' in data:
        raise Exception(data['errors'])
    return data['data']['downloadReportCsvAsync']

# Function: Get Report Name
def get_report_name(endpoint, headers, report_id):
    query = """
    query ($polarisReportsFilters: [PolarisReportsFilterInput!]) {
        allRscReportConfigs(polarisReportsFilters: $polarisReportsFilters) {
            id
            name
        }
    }
    """
    variables = {
        "polarisReportsFilters": [{"field": "FILTER_UNSPECIFIED", "reportRooms": ["REPORT_ROOM_NONE"]}]
    }
    payload = {"query": query, "variables": variables}
    response = requests.post(endpoint, json=payload, headers=headers)
    response.raise_for_status()
    data = response.json()
    reports = data['data']['allRscReportConfigs']
    report_name = next((report['name'] for report in reports if report['id'] == report_id), None)
    return report_name

# Function: Get Download Status
def get_download_status(endpoint, headers):
    query = """
    query {
        allUserFiles {
            downloads {
                externalId
                state
                filename
            }
        }
    }
    """
    payload = {"query": query}
    response = requests.post(endpoint, json=payload, headers=headers)
    response.raise_for_status()
    data = response.json()
    return data['data']['allUserFiles']['downloads']

# Function: Get Report CSV Link
def get_report_csv_link(auth, report_id):
    rubrik_url = auth['rubrik_url']
    endpoint = f"{rubrik_url}/api/graphql"
    headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': f"Bearer {auth['access_token']}"
    }
    
    report_name = get_report_name(endpoint, headers, report_id)
    if not report_name:
        raise Exception(f"No report found for report ID: {report_id}")
    
    print(f"Generating CSV for report: {report_name} (report ID: {report_id})")
    generate_report_csv(endpoint, headers, report_id)
    
    while True:
        download_status = get_download_status(endpoint, headers)
        matching_report = next((d for d in download_status if report_name in d['filename']), None)
        if matching_report and matching_report['state'] == 'READY':
            break
        print(f"Waiting for CSV to be ready, current status: {matching_report['state'] if matching_report else 'UNKNOWN'}")
        time.sleep(10)
    
    download_url = f"{rubrik_url}/file-downloads/{matching_report['externalId']}"
    return download_url

# Main Execution
try:
    print("Authenticating...")
    auth = authenticate_rsc(service_account_path)
    csv_link = get_report_csv_link(auth, report_id)
    print(f"Generated report CSV download link: {csv_link}")
except Exception as e:
    print(f"Error: {str(e)}")
