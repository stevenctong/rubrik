:: https://build.rubrik.com
:: This batch script can open a MV for rw or close a MV back to read-only

# Author: Steven Tong
# GitHub: stevenctong
# Date: 9/16/21

:: Rubrik cluster hostname/IP
set rubrikserver=rubrikhost.rubrik.com

:: Managed Volume ID to open/close
set mvid=ManagedVolume:::2696e03e-7388-45ed-aea6-50d4e30ff37e

:: Authorization if using Base64 encoded username:password
:: You can encode a username:password on a Linux host: echo -n "username@domain:password" | base64
:: set header=authorization: Basic
:: set token=

:: Authorization if using API token
:: set header=authorization: Bearer
:: set token=

:: Open the Managed Volume to rw
:: curl -k -H "accept: application/json" -H "%header% %token%" -X POST "https://%rubrikserver%/api/internal/managed_volume/%mvid%/begin_snapshot"

:: Close the Managed Volume to read-only
:: curl -k -H "accept: application/json" -H "%header% %token%" -X POST "https://%rubrikserver%/api/internal/managed_volume/%mvid%/end_snapshot"

:: Get list of Managed Volumes
:: curl -k -H "accept: application/json" -H "%header% %token%" -X GET "https://%rubrikserver%/api/internal/managed_volume"
