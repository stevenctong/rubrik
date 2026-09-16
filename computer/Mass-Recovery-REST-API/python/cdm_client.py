#!/usr/bin/env python3
"""
Shared CDM (Cluster Data Management) REST API client and helpers for AHV
mass recovery.

Talks directly to a CDM cluster's local REST API using a service account
session token. Adapted from python/host-delete/cdm_client.py with Nutanix
AHV endpoints added (VM inventory, snapshot selection, batch export, batch
live mount, event series monitoring, and mount teardown).

Stdlib only. Python 3.6 compatible.

Updated: 9/9/26 - initial AHV mass recovery client
"""

import json
import socket
import ssl
import time
import urllib.request
import urllib.parse
import urllib.error


def _enc(value):
    """URL-encode a path segment. Rubrik managed ids contain ':::'."""
    return urllib.parse.quote(str(value), safe="")


class CDMClient:
    """Simple CDM REST API client, authenticated via a service account."""

    def __init__(self, fqdn, service_account_id, secret, timeout=150):
        self.fqdn = fqdn
        self.base_url = "https://%s" % fqdn
        self.timeout = timeout
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
            raise Exception("Failed to authenticate: no token in response: %s" % result)

    def _request(self, method, path, params=None, body=None, auth=True, timeout=None):
        url = "%s%s" % (self.base_url, path)
        if params:
            url = "%s?%s" % (url, urllib.parse.urlencode(params))

        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if auth:
            headers["Authorization"] = "Bearer %s" % self.token

        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, headers=headers, method=method)

        try:
            with urllib.request.urlopen(req, context=self.ssl_context,
                                        timeout=timeout or self.timeout) as response:
                raw = response.read()
                if not raw:
                    return {}
                return json.loads(raw.decode("utf-8"))
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8")
            if e.code in (502, 503, 504):
                raise TimeoutError("Server timeout (HTTP %d) on %s %s: %s" % (
                    e.code, method, path, error_body)) from e
            raise Exception("HTTP %d on %s %s: %s" % (e.code, method, path, error_body)) from e
        except (socket.timeout, urllib.error.URLError) as e:
            raise TimeoutError("Connection timeout on %s %s: %s" % (method, path, e)) from e

    def get(self, path, params=None, timeout=None):
        return self._request("GET", path, params=params, timeout=timeout)

    def post(self, path, body=None, timeout=None):
        return self._request("POST", path, body=body, timeout=timeout)

    def delete(self, path, timeout=None):
        return self._request("DELETE", path, timeout=timeout)

    # -----------------------------------------------------------------------
    # Nutanix AHV inventory
    # -----------------------------------------------------------------------

    def list_nutanix_vms(self, include_relics=False, page_size=1000,
                         retries=3, retry_delay=15, timeout=None):
        """
        Fetch every AHV VM on the cluster (offset-paginated) and return a list
        of VM summary dicts. Retries a timed-out page before giving up.
        """
        vms = []
        offset = 0

        while True:
            params = {
                "primary_cluster_id": "local",
                "limit": page_size,
                "offset": offset,
            }
            if not include_relics:
                params["is_relic"] = "false"

            attempt = 0
            while True:
                try:
                    result = self.get("/api/internal/nutanix/vm", params=params, timeout=timeout)
                    break
                except TimeoutError:
                    attempt += 1
                    if attempt > retries:
                        raise TimeoutError(
                            "list_nutanix_vms: page at offset %d timed out %d/%d times "
                            "after collecting %d VMs" % (offset, attempt, retries, len(vms)))
                    time.sleep(retry_delay)

            page = result.get("data", [])
            vms.extend(page)

            if not result.get("hasMore") or not page:
                break
            offset += len(page)

        return vms

    def get_nutanix_vm(self, vm_id, timeout=None):
        """Full detail for one AHV VM, including virtualDisks."""
        return self.get("/api/internal/nutanix/vm/%s" % _enc(vm_id), timeout=timeout)

    def list_nutanix_clusters(self, timeout=None):
        """AHV (Prism) clusters registered with this Rubrik cluster."""
        params = {"primary_cluster_id": "local", "include_prism_clusters": "true"}
        result = self.get("/api/internal/nutanix/cluster", params=params, timeout=timeout)
        return result.get("data", [])

    def list_containers(self, nutanix_cluster_id, timeout=None):
        """Storage containers on an AHV cluster: [{naturalId, name}, ...]."""
        result = self.get("/api/internal/nutanix/cluster/%s/container" % _enc(nutanix_cluster_id),
                          timeout=timeout)
        return result.get("data", [])

    # -----------------------------------------------------------------------
    # Snapshot selection
    # -----------------------------------------------------------------------

    def closest_to_point_in_time(self, snappable_ids, before_date, timeout=None):
        """
        Resolve the newest snapshot at or before before_date for each snappable.

        before_date is an ISO-8601 UTC string, e.g. 2026-09-09T17:20:27.915Z.
        Returns [{snappableId, snapshotId, snapshotDate}, ...]. Snappables with
        no snapshot in range are simply absent from the response.
        """
        body = {"snappableIds": list(snappable_ids), "beforeDate": before_date}
        result = self.post("/api/v1/snapshot/closest_to_point_in_time", body=body, timeout=timeout)
        return result.get("snapshots", [])

    # -----------------------------------------------------------------------
    # Recovery triggers
    # -----------------------------------------------------------------------

    def batch_export(self, snapshots, timeout=None):
        """
        POST /api/v1/nutanix/vm/batch_export

        snapshots is a list of:
          {"exportConfig": {"nutanixClusterId": ..., "containerNaturalId": ...},
           "snapshotId": ..., "vmId": ..., "vmNamePrefix": ...}

        Returns {"successfulRequests": [...], "failedRequests": [...]}.
        """
        return self.post("/api/v1/nutanix/vm/batch_export",
                         body={"snapshots": snapshots}, timeout=timeout)

    def batch_mount(self, snapshots, timeout=None):
        """
        POST /api/v1/nutanix/vm/batch_mount

        snapshots is a list of:
          {"mountConfig": {"shouldMigrateImmediately": bool, "vmNamePrefix": ...,
                           "shouldDisableMigration": bool, "nutanixClusterId": ...,
                           "containerNaturalId": ...},
           "snapshotId": ..., "vmId": ..., "vmNamePrefix": ...}

        Returns {"successfulRequests": [...], "failedRequests": [...]}.
        """
        return self.post("/api/v1/nutanix/vm/batch_mount",
                         body={"snapshots": snapshots}, timeout=timeout)

    # -----------------------------------------------------------------------
    # Event / job monitoring
    # -----------------------------------------------------------------------

    def event_latest(self, object_ids=None, limit=50, event_type=None,
                     before_date=None, timeout=None):
        """
        GET /api/v1/event/latest -- most recent event per event series.

        object_ids may be a single id or a list. The batched (comma-joined)
        form is unverified against all CDM versions, so callers should be
        prepared to fall back to one call per object id.
        """
        params = {"limit": limit}
        if object_ids:
            if isinstance(object_ids, (list, tuple, set)):
                params["object_ids"] = ",".join(object_ids)
            else:
                params["object_ids"] = object_ids
        if event_type:
            params["event_type"] = event_type
        if before_date:
            params["before_date"] = before_date
        result = self.get("/api/v1/event/latest", params=params, timeout=timeout)
        return result.get("data", [])

    def get_event_series(self, event_series_id, timeout=None):
        """Full detail for one event series, including eventDetailList."""
        return self.get("/api/v1/event_series/%s" % _enc(event_series_id), timeout=timeout)

    def event_series_status(self, pairs, timeout=None):
        """
        POST /api/internal/event_series/status -- batched status lookup.

        pairs is [{"id": <eventSeriesId>, "jobInstanceId": <jobInstanceId>}, ...].
        Returns a list of dicts carrying progress, terminatedEventSeriesStatus,
        and (where the job type reports them) logicalSize, dataTransferred and
        throughput.
        """
        result = self.post("/api/internal/event_series/status", body=list(pairs), timeout=timeout)
        return result.get("data", [])

    def cancel_event_series(self, event_series_id, timeout=None):
        """POST /api/internal/event_series/{id}/cancel -- returns 204 (empty)."""
        return self.post("/api/internal/event_series/%s/cancel" % _enc(event_series_id),
                         body={}, timeout=timeout)

    # -----------------------------------------------------------------------
    # Live mount teardown
    # -----------------------------------------------------------------------

    def list_vm_mounts(self, vm_id=None, page_size=1000, timeout=None):
        """
        GET /api/v1/nutanix/vm/snapshot/mount -- existing AHV live mounts.
        Pass vm_id to scope to a single source VM.
        """
        params = {"limit": page_size}
        if vm_id:
            params["vm_id"] = vm_id
        result = self.get("/api/v1/nutanix/vm/snapshot/mount", params=params, timeout=timeout)
        return result.get("data", [])

    def delete_vm_mount(self, mount_id, force=False, timeout=None):
        """
        DELETE /api/v1/nutanix/vm/snapshot/mount/{mountId} -- unmount.

        NOT PRESENT IN THE REFERENCE API CAPTURE. This path is inferred from
        the Rubrik CDM mount API convention and must be confirmed against a
        live cluster before being relied on. Callers should surface failures
        rather than treating them as "already gone".
        """
        path = "/api/v1/nutanix/vm/snapshot/mount/%s" % _enc(mount_id)
        if force:
            path = "%s?force=true" % path
        return self.delete(path, timeout=timeout)


def clean_input(value):
    """Clean up common input errors from copy/paste."""
    value = value.strip()
    for prefix in ['serviceAccountId": "', 'secret": "', 'organizationId": "']:
        if prefix in value:
            value = value.split(prefix)[-1]
    value = value.rstrip('",')
    return value
