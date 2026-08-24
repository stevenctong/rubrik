#!/usr/bin/env python3
"""
Shared CDM (Cluster Data Management) REST API client and helpers.

Used by cdm_delete_hosts.py to talk directly to a CDM cluster's local REST
API instead of RSC/Polaris GraphQL.
"""

import json
import ssl
import time
import urllib.request
import urllib.parse
import urllib.error


class CDMClient:
    """Simple CDM REST API client, authenticated via a service account."""

    def __init__(self, fqdn, service_account_id, secret):
        self.fqdn = fqdn
        self.base_url = f"https://{fqdn}"
        self.token = None
        # CDM clusters commonly run self-signed certs.
        self.ssl_context = ssl.create_default_context()
        self.ssl_context.check_hostname = False
        self.ssl_context.verify_mode = ssl.CERT_NONE
        self._authenticate(service_account_id, secret)

    def _authenticate(self, service_account_id, secret):
        body = {
            "serviceAccountId": service_account_id,
            "secret": secret,
        }
        result = self._request("POST", "/api/v1/service_account/session", body=body, auth=False)
        self.token = result.get("token")
        if not self.token:
            raise Exception(f"Failed to authenticate: no token in response: {result}")

    def _request(self, method, path, params=None, body=None, auth=True):
        url = f"{self.base_url}{path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"

        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if auth:
            headers["Authorization"] = f"Bearer {self.token}"

        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, headers=headers, method=method)

        try:
            with urllib.request.urlopen(req, context=self.ssl_context) as response:
                raw = response.read()
                if not raw:
                    return {}
                return json.loads(raw.decode("utf-8"))
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8")
            raise Exception(f"HTTP {e.code} on {method} {path}: {error_body}") from e

    def get(self, path, params=None):
        return self._request("GET", path, params=params)

    def post(self, path, body=None):
        return self._request("POST", path, body=body)

    def delete(self, path):
        return self._request("DELETE", path)

    def list_all_hosts(self):
        """
        Fetch every host on the cluster once and return a dict keyed by
        lowercased hostname -> host summary dict (id, name, operatingSystemType, ...).

        Avoids doing one lookup call per hostname when checking existence
        for thousands of hosts.
        """
        hosts_by_name = {}
        params = {"primary_cluster_id": "local", "limit": 1000}
        cursor = None

        while True:
            if cursor:
                params["cursor"] = cursor
            result = self.get("/api/v1/host", params=params)
            for host in result.get("data", []):
                name = (host.get("name") or "").strip().lower()
                if name:
                    hosts_by_name[name] = host

            has_more = result.get("hasMore", False)
            cursor = result.get("cursor")
            if not has_more or not cursor:
                break

        return hosts_by_name


def run_in_batches(items, batch_size, delay_seconds, fn, label="batch"):
    """
    Chunk items into batch_size groups, call fn(batch) on each, and sleep
    delay_seconds between batches. fn should return a list of per-item
    result dicts. Returns the concatenated list of all results.
    """
    total = len(items)
    all_results = []
    total_batches = (total + batch_size - 1) // batch_size if batch_size else 1

    for i in range(0, total, batch_size):
        batch = items[i:i + batch_size]
        batch_num = (i // batch_size) + 1
        print(f"\n[{label} {batch_num}/{total_batches}] Processing {len(batch)} item(s)...")

        results = fn(batch)
        all_results.extend(results)

        if i + batch_size < total and delay_seconds > 0:
            print(f"  Waiting {delay_seconds}s before next batch...")
            time.sleep(delay_seconds)

    return all_results


def clean_input(value):
    """Clean up common input errors from copy/paste."""
    value = value.strip()
    for prefix in ['serviceAccountId": "', 'secret": "', 'organizationId": "']:
        if prefix in value:
            value = value.split(prefix)[-1]
    value = value.rstrip('",')
    return value
