'''Class Constants '''

class GlobalConstants:
    '''Global Constant'''
    URL_PREFIX = '/'

class HttpResponseCode:
    '''Http Response Code'''
    HTTP_SUCCESS_REQUEST = 200
    HTTP_CREATED_REQUEST = 201
    HTTP_UPDATED_REQUEST = 202
    HTTP_NOCONTENT_REQUEST = 200
    HTTP_BAD_REQUEST = 400
    HTTP_UNAUTHORIZED_REQUEST = 401
    HTTP_NOTALLOWED_REQUEST = 405
    HTTP_INTERNAL_SERVER_ERROR = 500

class Message:
    '''Common Message'''

HOURS_IN_DAY = 24
DAYS_IN_WEEK = 7
DAYS_IN_MONTH = 30
DAYS_IN_QUARTER = 91
DAYS_IN_YEAR = 365
MONTHS_IN_YEAR = 12
SECONDS_IN_HOUR = 3600

SIZE_CONVERSION_BASE = 1000

PRINT_CSV_OUTPUT = 0
DAILY_USAGE_REPORT_FILE = "./daily_usage_summary.csv"

# Key names used in dictionary management
TARGET_STORAGE_CLASS = 'target_storage_class'
CHAIN_ID = 'chain_id'

DOWNLOAD_CSV_OUTPUT = 1
