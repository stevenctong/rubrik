#!/usr/bin/env python3
"""
RSC Fileset Delete

Deletes filesets for specified hosts via the Rubrik Security Cloud (RSC)
GraphQL API. Given a CSV of hostname + cluster pairs, looks up each host
in RSC, discovers all its filesets (Linux and Windows), and deletes them.

By default, snapshots are expired immediately (preserveSnapshots=false).
Pass --preserve-snapshots to keep snapshots in Unmanaged Objects instead.

Host Inventory CSV:
  On each run the script pulls the full host inventory from RSC (all Linux
  and Windows hosts, paginated) and saves separate CSVs to the script
  directory:
    linux_host_inventory_<timestamp>.csv
    windows_host_inventory_<timestamp>.csv

  These inventory CSVs contain: hostname, host_id, cluster_name, cluster_id,
  host_root. They can be reused on subsequent runs via --host_inventory to
  skip the RSC host lookup (which can be slow on large environments).
  Pass either file (or both runs with separate --host_inventory calls).

  The script still needs RSC auth even with --host_inventory because
  fileset lookups and delete mutations require API access.

Usage examples:
  # Fully interactive (prompts for everything)
  python3 rsc_delete_filesets.py

  # Non-interactive with RSC Service Account JSON
  python3 rsc_delete_filesets.py --svc_json rsc-sa.json --csv hosts.csv --force

  # Non-interactive with direct credentials
  python3 rsc_delete_filesets.py --rsc_url rubrik-gaia.my.rubrik.com --svc_client_id ABC --svc_secret XYZ --csv hosts.csv --force

  # Preserve snapshots instead of expiring immediately
  python3 rsc_delete_filesets.py --svc_json rsc-sa.json --csv hosts.csv --preserve-snapshots --force

  # Re-run using a previously-saved host inventory (skips RSC host lookup)
  python3 rsc_delete_filesets.py --svc_json rsc-sa.json --csv hosts.csv --host_inventory linux_host_inventory_20260826_143012.csv --force

  # Slow environment -- increase timeout, reduce parallelism, wider stagger
  python3 rsc_delete_filesets.py --svc_json rsc-sa.json --csv hosts.csv --timeout 300 --parallel 2 --stagger 10 --force

  # High throughput -- max parallelism, no stagger
  python3 rsc_delete_filesets.py --svc_json rsc-sa.json --csv hosts.csv --parallel 8 --stagger 0 --force
"""

import argparse
import concurrent.futures
import csv
import json
import os
import socket
import ssl
import sys
import threading
import time
import urllib.request
import urllib.parse
import urllib.error
from datetime import datetime


# ---------------------------------------------------------------------------
# RSC GraphQL client
# ---------------------------------------------------------------------------

class RSCClient:
    """RSC GraphQL API client, authenticated via Service Account credentials."""

    def __init__(self, rsc_url, client_id, client_secret, debug=False, timeout=120):
        if not rsc_url.startswith("http"):
            rsc_url = f"https://{rsc_url}"
        rsc_url = rsc_url.rstrip("/")

        self.graphql_url = f"{rsc_url}/api/graphql"
        self.debug = debug
        self.timeout = timeout
        token_uri = f"{rsc_url}/api/client_token"
        self.token = None
        self._authenticate(token_uri, client_id, client_secret)

    def _authenticate(self, token_uri, client_id, client_secret):
        body = json.dumps({
            "client_id": client_id,
            "client_secret": client_secret,
        }).encode("utf-8")

        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        req = urllib.request.Request(
            token_uri, data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=30) as response:
                result = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8")
            raise Exception(f"RSC auth failed (HTTP {e.code}): {error_body}") from e
        except (urllib.error.URLError, socket.timeout) as e:
            raise Exception(f"RSC auth connection error: {e}") from e

        self.token = result.get("access_token")
        if not self.token:
            raise Exception(f"No access_token in auth response: {result}")

    def graphql(self, query, variables=None):
        payload = {"variables": variables or {}, "query": query}
        body = json.dumps(payload).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
        }
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        if self.debug:
            op_line = next((l.strip() for l in query.strip().splitlines() if l.strip().startswith(("query ", "mutation "))), "")
            print(f"\n[DEBUG] >>> GraphQL request to {self.graphql_url}")
            print(f"[DEBUG]     Operation: {op_line}")
            print(f"[DEBUG]     Variables: {json.dumps(variables or {}, indent=2)}")
            print(f"[DEBUG]     Full query:\n{query.strip()}")

        req = urllib.request.Request(
            self.graphql_url, data=body, headers=headers, method="POST",
        )
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=self.timeout) as response:
                result = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8")
            if self.debug:
                print(f"[DEBUG] <<< HTTP {e.code} error: {error_body}")
            if e.code in (502, 503, 504):
                raise TimeoutError(f"Server timeout (HTTP {e.code}): {error_body}") from e
            raise Exception(f"GraphQL error (HTTP {e.code}): {error_body}") from e
        except (socket.timeout, urllib.error.URLError) as e:
            if self.debug:
                print(f"[DEBUG] <<< Connection error: {e}")
            raise TimeoutError(f"Connection timeout: {e}") from e

        if self.debug:
            print(f"[DEBUG] <<< Response: {json.dumps(result, indent=2)[:3000]}")

        if "errors" in result and result["errors"]:
            raise Exception(f"GraphQL errors: {json.dumps(result['errors'], indent=2)}")
        return result.get("data", {})


# ---------------------------------------------------------------------------
# GraphQL queries
# ---------------------------------------------------------------------------

FIND_HOSTS_QUERY = """
query PhysicalHostListQuery($hostRoot: HostRoot!, $first: Int!, $after: String, $sortBy: HierarchySortByField, $sortOrder: SortOrder, $filter: [Filter!]!) {
  physicalHosts(hostRoot: $hostRoot, filter: $filter, first: $first, after: $after, sortBy: $sortBy, sortOrder: $sortOrder) {
    edges {
      cursor
      node {
        id
        name
        objectType
        cluster {
          id
          name
          __typename
        }
        __typename
      }
      __typename
    }
    pageInfo {
      endCursor
      hasNextPage
      __typename
    }
    __typename
  }
}
"""

FIND_HOST_FILESETS_QUERY = """
query PhysicalHostDetailQuery($id: UUID!, $first: Int!, $after: String, $sortBy: HierarchySortByField, $sortOrder: SortOrder) {
  physicalHost(fid: $id) {
    id
    name
    physicalChildConnection(typeFilter: [LinuxFileset, WindowsFileset], first: $first, after: $after, sortBy: $sortBy, sortOrder: $sortOrder) {
      edges {
        cursor
        node {
          id
          name
          objectType
          __typename
        }
        __typename
      }
      pageInfo {
        endCursor
        hasNextPage
        __typename
      }
      count
      __typename
    }
    __typename
  }
}
"""

DELETE_FILESETS_MUTATION = """
mutation DeleteFilesets($ids: [String!]!, $preserveSnapshots: Boolean) {
  bulkDeleteFileset(input: {ids: $ids, preserveSnapshots: $preserveSnapshots}) {
    success
    __typename
  }
}
"""

CHECK_FILESET_QUERY = """
query CheckFileset($id: UUID!) {
  physicalHost(fid: $id) {
    id
    name
  }
}
"""


def _fileset_exists(client, fileset_id):
    try:
        data = client.graphql(CHECK_FILESET_QUERY, {"id": fileset_id})
        return data.get("physicalHost") is not None
    except Exception:
        return True


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

def load_rsc_json_credentials(json_path):
    with open(json_path, "r") as f:
        data = json.load(f)
    client_id = data.get("client_id")
    client_secret = data.get("client_secret")
    access_token_uri = data.get("access_token_uri")
    missing = []
    if not client_id:
        missing.append("client_id")
    if not client_secret:
        missing.append("client_secret")
    if not access_token_uri:
        missing.append("access_token_uri")
    if missing:
        print(f"ERROR: JSON file is missing required fields: {', '.join(missing)}")
        sys.exit(1)
    rsc_url = access_token_uri.replace("/api/client_token", "")
    return rsc_url, client_id, client_secret


def parse_args():
    parser = argparse.ArgumentParser(
        description="Delete filesets from Rubrik hosts via the RSC GraphQL API. "
                    "Any argument not provided will be prompted for interactively.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  %(prog)s --svc_json rsc-sa.json --csv hosts.csv --force\n"
               "  %(prog)s --rsc_url rubrik-gaia.my.rubrik.com --svc_client_id ABC --svc_secret XYZ --csv hosts.csv --force\n"
               "  %(prog)s   (fully interactive)\n",
    )

    auth_group = parser.add_argument_group("authentication")
    auth_group.add_argument("--svc_json", metavar="FILE",
                            help="RSC Service Account JSON file (client_id, client_secret, access_token_uri)")
    auth_group.add_argument("--rsc_url", metavar="URL",
                            help="RSC URL (e.g., rubrik-gaia.my.rubrik.com) (alt to --svc_json)")
    auth_group.add_argument("--svc_client_id", metavar="ID",
                            help="Service Account Client ID (alt to --svc_json)")
    auth_group.add_argument("--svc_secret",
                            help="Service Account Secret (alt to --svc_json)")

    parser.add_argument("--csv", metavar="FILE",
                        help="CSV file with hostname and cluster columns")
    parser.add_argument("--host_inventory", metavar="FILE",
                        help="Previously-saved host inventory CSV (skips RSC host lookup)")
    parser.add_argument("--preserve-snapshots", action="store_true",
                        help="Keep snapshots (default: expire immediately)")
    parser.add_argument("--parallel", type=int, default=None, metavar="N",
                        help="Max concurrent delete calls (default: 4)")
    parser.add_argument("--stagger", type=int, default=None, metavar="SEC",
                        help="Delay between launching each parallel worker (default: 5)")
    parser.add_argument("--retries", type=int, default=None, metavar="N",
                        help="Max retries per fileset on timeout/5xx (default: 3)")
    parser.add_argument("--timeout", type=int, default=None, metavar="SEC",
                        help="HTTP timeout per API call in seconds (default: 120)")
    parser.add_argument("--force", "-f", action="store_true",
                        help="Skip confirmation and use defaults")
    parser.add_argument("--debug", action="store_true",
                        help="Print full GraphQL requests and responses")
    return parser.parse_args()


def prompt_if_missing(value, prompt_text, required=False):
    if value:
        return value
    while True:
        result = input(prompt_text).strip()
        if result or not required:
            return result
        print("  Value cannot be empty. Please try again.")


def prompt_int_if_missing(value, prompt_text, default, min_val=None, max_val=None):
    if value is not None:
        result = value
    else:
        raw = input(prompt_text).strip()
        result = int(raw) if raw.isdigit() else default
    if min_val is not None:
        result = max(min_val, result)
    if max_val is not None:
        result = min(max_val, result)
    return result


def read_csv_entries(csv_file):
    entries = []
    with open(csv_file, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            hostname = (
                row.get("hostname") or row.get("Hostname")
                or row.get("name") or row.get("Name")
            )
            cluster = (
                row.get("cluster") or row.get("Cluster")
                or row.get("cluster_name") or row.get("Cluster_Name")
            )
            if hostname and hostname.strip() and cluster and cluster.strip():
                entries.append({
                    "hostname": hostname.strip(),
                    "cluster": cluster.strip(),
                })
    return entries


INVENTORY_FIELDS = [
    "hostname", "host_id", "cluster_name", "cluster_id", "host_root",
    "fileset_ids", "fileset_names", "status", "last_updated",
]


def fetch_all_hosts(client, save_dir):
    """
    Paginate the full RSC host inventory (Linux + Windows roots).
    Saves a separate CSV per host root to save_dir and returns all hosts.
    """
    all_hosts = []
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    saved_files = []

    for host_root in ["LINUX_HOST_ROOT", "WINDOWS_HOST_ROOT"]:
        root_label = "linux" if "LINUX" in host_root else "windows"
        root_hosts = []
        after = None
        page = 0
        total_scanned = 0
        while True:
            variables = {
                "hostRoot": host_root,
                "first": 200,
                "sortBy": "NAME",
                "sortOrder": "ASC",
                "filter": [
                    {"field": "IS_RELIC", "texts": ["false"]},
                    {"field": "IS_REPLICATED", "texts": ["false"]},
                    {"field": "IS_KUPR_HOST", "texts": ["false"]},
                ],
            }
            if after:
                variables["after"] = after

            data = client.graphql(FIND_HOSTS_QUERY, variables)
            connection = data.get("physicalHosts", {})
            edges = connection.get("edges", [])
            total_scanned += len(edges)

            for edge in edges:
                node = edge.get("node", {})
                cluster = node.get("cluster", {})
                root_hosts.append({
                    "hostname": node.get("name", ""),
                    "host_id": node.get("id"),
                    "cluster_name": cluster.get("name", ""),
                    "cluster_id": cluster.get("id"),
                    "host_root": host_root,
                })

            page_info = connection.get("pageInfo", {})
            if page_info.get("hasNextPage") and page_info.get("endCursor"):
                after = page_info["endCursor"]
                page += 1
                print(f"  {root_label.capitalize()} hosts: scanned {total_scanned} (page {page + 1})...")
            else:
                print(f"  {root_label.capitalize()} hosts: {total_scanned} total" +
                      (f" across {page + 1} pages" if page > 0 else ""))
                break

        path = os.path.join(save_dir, f"{root_label}_host_inventory_{timestamp}.csv")
        with open(path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=INVENTORY_FIELDS)
            writer.writeheader()
            for host in root_hosts:
                writer.writerow({k: host.get(k, "") for k in INVENTORY_FIELDS})
        saved_files.append(path)
        print(f"  Saved to: {path}")
        all_hosts.extend(root_hosts)

    return all_hosts, saved_files


def load_inventory_csv(csv_path):
    hosts = []
    deleted_count = 0
    with open(csv_path, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            hostname = row.get("hostname") or row.get("Hostname") or row.get("name") or ""
            host_id = row.get("host_id") or row.get("id") or ""
            if not (hostname.strip() and host_id.strip()):
                continue
            status = (row.get("status") or "").strip()
            if status == "DELETED":
                deleted_count += 1
            hosts.append({
                "hostname": hostname.strip(),
                "host_id": host_id.strip(),
                "cluster_name": (row.get("cluster_name") or row.get("cluster") or "").strip(),
                "cluster_id": (row.get("cluster_id") or "").strip(),
                "host_root": (row.get("host_root") or "").strip(),
                "fileset_ids": (row.get("fileset_ids") or "").strip(),
                "fileset_names": (row.get("fileset_names") or "").strip(),
                "status": status,
            })
    if deleted_count:
        print(f"  {deleted_count} host(s) already marked DELETED (will be skipped).")
    return hosts


def save_inventory_csv(hosts, csv_path):
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=INVENTORY_FIELDS)
        writer.writeheader()
        for host in hosts:
            writer.writerow({k: host.get(k, "") for k in INVENTORY_FIELDS})


def get_host_filesets(client, host_id):
    """
    Query RSC for all filesets belonging to a single host.
    Returns a list of fileset dicts.
    """
    filesets = []
    after = None

    while True:
        variables = {"id": host_id, "first": 200, "sortBy": "NAME", "sortOrder": "ASC"}
        if after:
            variables["after"] = after

        data = client.graphql(FIND_HOST_FILESETS_QUERY, variables)
        host_data = data.get("physicalHost", {})
        connection = host_data.get("physicalChildConnection", {})

        for edge in connection.get("edges", []):
            node = edge.get("node", {})
            filesets.append({
                "id": node.get("id"),
                "name": node.get("name"),
                "objectType": node.get("objectType"),
            })

        page_info = connection.get("pageInfo", {})
        if page_info.get("hasNextPage") and page_info.get("endCursor"):
            after = page_info["endCursor"]
        else:
            break

    return filesets


RETRY_DELAY = 5

_print_lock = threading.Lock()
_log_file = None


def _now():
    return datetime.now().strftime("%H:%M")


def _log(msg):
    with _print_lock:
        print(msg)
        if _log_file:
            try:
                _log_file.write(msg + "\n")
                _log_file.flush()
            except Exception:
                pass


def delete_filesets(client, filesets, preserve_snapshots, max_retries,
                    max_workers, stagger_delay, results, on_result=None):
    total = len(filesets)
    started = [0]
    completed = [0]
    stop_event = threading.Event()

    def _worker(fs):
        if stop_event.is_set():
            return None
        with _print_lock:
            started[0] += 1
            seq = started[0]
        result = _delete_single(client, fs, preserve_snapshots, max_retries,
                                total, seq, completed)
        if on_result:
            on_result(result, results)
        else:
            results.append(result)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = []
        try:
            for i, fs in enumerate(filesets):
                if stop_event.is_set():
                    break
                futures.append(pool.submit(_worker, fs))
                if stagger_delay > 0 and i < len(filesets) - 1:
                    time.sleep(stagger_delay)
            for future in concurrent.futures.as_completed(futures):
                future.result()
        except KeyboardInterrupt:
            stop_event.set()
            pool.shutdown(wait=True)
            raise


def _delete_single(client, fs, preserve_snapshots, max_retries,
                   total, seq, completed):
    prefix = "  [%d/%d]" % (seq, total)
    label = "%s / %s" % (fs['hostname'], fs['name'])
    last_error = None

    def _complete(status, message):
        with _print_lock:
            completed[0] += 1
            c = completed[0]
        _log("(%s) Completed %d of %d" % (_now(), c, total))
        return dict(fs, status=status, message=message)

    def _verify_gone():
        _log("%s (%s) %s - Verifying fileset still exists..." % (prefix, _now(), label))
        if not _fileset_exists(client, fs["id"]):
            _log("%s (%s) %s - Fileset gone (prior delete succeeded)" % (prefix, _now(), label))
            return True
        return False

    for attempt in range(1 + max_retries):
        if attempt == 0:
            _log("%s (%s) %s - Issuing Delete..." % (prefix, _now(), label))
        else:
            _log("%s (%s) %s - Issuing Delete (retry %d of %d)..." % (prefix, _now(), label, attempt, max_retries))

        try:
            data = client.graphql(DELETE_FILESETS_MUTATION, {
                "ids": [fs["id"]],
                "preserveSnapshots": preserve_snapshots,
            })
            success = data.get("bulkDeleteFileset", {}).get("success", False)
            if success:
                _log("%s (%s) %s - Deleted OK" % (prefix, _now(), label))
                return _complete("Deleted", "OK")
            else:
                if attempt > 0 and _verify_gone():
                    return _complete("Deleted", "OK (verified gone after retry)")
                _log("%s (%s) %s - FAILED: API returned success=false" % (prefix, _now(), label))
                return _complete("Failed", "API returned success=false")
        except TimeoutError as e:
            last_error = str(e)
            if attempt < max_retries:
                _log("%s (%s) %s - timeout (%d of %d), retrying in %ds..." % (prefix, _now(), label, attempt + 1, max_retries, RETRY_DELAY))
                time.sleep(RETRY_DELAY)
            continue
        except Exception as e:
            if attempt > 0 and _verify_gone():
                return _complete("Deleted", "OK (verified gone after retry)")
            _log("%s (%s) %s - FAILED: %s" % (prefix, _now(), label, e))
            return _complete("Failed", str(e))

    if _verify_gone():
        return _complete("Deleted", "OK (verified gone after timeout)")
    _log("%s (%s) %s - FAILED: timed out after %d attempts" % (prefix, _now(), label, 1 + max_retries))
    return _complete("Failed", "Timed out after %d attempts: %s" % (1 + max_retries, last_error))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    print("=" * 60)
    print("RSC Fileset Delete")
    print("=" * 60)

    if args.preserve_snapshots:
        print("Mode: PRESERVE snapshots (moved to Unmanaged Objects)")
    else:
        print("Mode: EXPIRE snapshots immediately")
    print()

    # --- Resolve credentials ---
    json_path = args.svc_json
    if not json_path and not args.svc_client_id:
        json_path = input("Service Account JSON (leave blank if providing credentials directly): ").strip()
    if json_path:
        json_path = os.path.expanduser(json_path)
        print(f"Reading credentials from: {json_path}")
        rsc_url, client_id, client_secret = load_rsc_json_credentials(json_path)
    else:
        rsc_url = prompt_if_missing(
            args.rsc_url, "RSC URL (e.g., rubrik-gaia.my.rubrik.com): ", required=True)
        client_id = prompt_if_missing(
            args.svc_client_id, "Service Account Client ID: ", required=True)
        client_secret = prompt_if_missing(
            args.svc_secret, "Service Account Secret: ", required=True)

    csv_file = prompt_if_missing(args.csv, "CSV file path (hostname,cluster): ", required=True)
    csv_file = os.path.expanduser(csv_file)

    parallel_workers = args.parallel if args.parallel is not None else 4
    stagger_delay = args.stagger if args.stagger is not None else 10
    max_retries = args.retries if args.retries is not None else 3
    http_timeout = args.timeout if args.timeout is not None else 150

    print(f"\nConnecting to RSC...")
    try:
        client = RSCClient(rsc_url, client_id, client_secret, debug=args.debug, timeout=http_timeout)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)
    print("Connected!\n")

    # --- Read CSV ---
    entries = read_csv_entries(csv_file)
    if not entries:
        print("ERROR: No valid hostname+cluster entries found in CSV")
        print("CSV must have 'hostname' and 'cluster' columns")
        sys.exit(1)
    print(f"Found {len(entries)} hostname+cluster entries in CSV.\n")

    # --- Get host inventory (from RSC or cached CSV) ---
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    if args.host_inventory:
        inv_path = os.path.expanduser(args.host_inventory)
        print(f"Loading host inventory from: {inv_path}")
        all_rsc_hosts = load_inventory_csv(inv_path)
        print(f"Loaded {len(all_rsc_hosts)} hosts from inventory CSV.\n")
    else:
        print("Fetching full host inventory from RSC...")
        all_rsc_hosts, inv_files = fetch_all_hosts(client, script_dir)
        print(f"  Total hosts in RSC: {len(all_rsc_hosts)}\n")

    # --- Match CSV entries to inventory ---
    csv_lookup = {}
    for entry in entries:
        key = (entry["hostname"].lower(), entry["cluster"].lower())
        csv_lookup[key] = entry

    matched_hosts = []
    matched_keys = set()
    skipped_deleted = 0
    for host in all_rsc_hosts:
        key = (host["hostname"].lower(), host["cluster_name"].lower())
        if key in csv_lookup:
            if host.get("status") == "DELETED":
                skipped_deleted += 1
                continue
            matched_keys.add(key)
            matched_hosts.append(host)

    not_found = []
    for key, entry in csv_lookup.items():
        if key not in matched_keys:
            not_found.append(entry)

    print(f"  CSV entries matched:   {len(matched_hosts)}")
    if skipped_deleted:
        print(f"  Already DELETED:       {skipped_deleted} (skipped)")
    print(f"  CSV entries not found: {len(not_found)}")

    if not matched_hosts:
        print("\nNo matching hosts found. Exiting.")
        if not_found:
            print("  Not found (first 5):")
            for entry in not_found[:5]:
                print(f"    - {entry['hostname']} ({entry['cluster']})")
        sys.exit(0)

    # --- Look up filesets per host ---
    print(f"\nLooking up filesets for {len(matched_hosts)} host(s)...")
    matched_filesets = []
    for host in matched_hosts:
        filesets = get_host_filesets(client, host["host_id"])
        fs_ids = []
        fs_names = []
        for fs in filesets:
            fs_ids.append(fs["id"])
            fs_names.append(fs["name"])
            matched_filesets.append({
                "hostname": host["hostname"],
                "cluster": host["cluster_name"],
                "id": fs["id"],
                "name": fs["name"],
                "objectType": fs["objectType"],
            })
        host["fileset_ids"] = ";".join(fs_ids)
        host["fileset_names"] = ";".join(fs_names)

    print(f"  Total filesets found:  {len(matched_filesets)}")

    if not_found:
        print("  Not found (first 5):")
        for entry in not_found[:5]:
            print(f"    - {entry['hostname']} ({entry['cluster']})")

    if not matched_filesets:
        print("\nNo filesets to delete. Exiting.")
        sys.exit(0)

    # --- Preview ---
    print(f"\nFilesets to delete:\n")
    by_host = {}
    for fs in matched_filesets:
        host_key = f"{fs['hostname']} ({fs['cluster']})"
        by_host.setdefault(host_key, []).append(fs)

    shown = 0
    for host_key, filesets in by_host.items():
        if shown >= 10:
            remaining_hosts = len(by_host) - shown
            if remaining_hosts > 0:
                print(f"  ... and {remaining_hosts} more host(s)")
            break
        print(f"  {host_key}:")
        for fs in filesets[:5]:
            print(f"    - {fs['name']} ({fs['objectType']}, {fs['id']})")
        if len(filesets) > 5:
            print(f"    ... and {len(filesets) - 5} more fileset(s)")
        shown += 1

    snap_action = "PRESERVED" if args.preserve_snapshots else "EXPIRED IMMEDIATELY"
    print(f"\nTotal: {len(matched_filesets)} fileset(s) across {len(by_host)} host(s)")
    print(f"Snapshots will be: {snap_action}")

    if not args.force:
        confirm = input(f"\nProceed with deleting {len(matched_filesets)} fileset(s)? (yes/no): ").strip().lower()
        if confirm != "yes":
            print("Aborted.")
            return

    # --- Delete ---
    print("\n" + "=" * 60)
    print("DELETING FILESETS")
    print("=" * 60)
    print("  Parallel: %d workers (stagger %ds), retries: %d (delay %ds), timeout: %ds" % (
        parallel_workers, stagger_delay, max_retries, RETRY_DELAY, http_timeout))

    os.makedirs(log_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    results_file = os.path.join(log_dir, "fileset_delete_results_%s.csv" % timestamp)
    results_fields = ["hostname", "cluster", "id", "name", "objectType", "status", "message"]
    activity_log_file = os.path.join(log_dir, "fileset_delete_log_%s.log" % timestamp)

    print("  Results CSV: %s" % results_file)
    print("  Activity log: %s" % activity_log_file)
    print()

    global _log_file
    _log_file = open(activity_log_file, "w")
    _log_file.write("Fileset Delete Activity Log - %s\n" % datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    _log_file.write("Parallel: %d workers (stagger %ds), retries: %d (delay %ds), timeout: %ds\n" % (
        parallel_workers, stagger_delay, max_retries, RETRY_DELAY, http_timeout))
    _log_file.write("Total filesets: %d\n\n" % len(matched_filesets))
    _log_file.flush()

    delete_start = time.time()

    results_lock = threading.Lock()
    with open(results_file, "w", newline="") as rf:
        writer = csv.DictWriter(rf, fieldnames=results_fields)
        writer.writeheader()
        rf.flush()

    host_by_fs_id = {}
    for host in matched_hosts:
        for fs_id in (host.get("fileset_ids") or "").split(";"):
            if fs_id:
                host_by_fs_id[fs_id] = host

    def _on_result(result, results_list):
        with results_lock:
            results_list.append(result)

            with open(results_file, "a", newline="") as rf:
                writer = csv.DictWriter(rf, fieldnames=results_fields)
                writer.writerow({k: result.get(k, "") for k in results_fields})

            host = host_by_fs_id.get(result["id"])
            if host:
                deleted_ids = set()
                for r in results_list:
                    if r["status"] == "Deleted":
                        deleted_ids.add(r["id"])
                host_fs_ids = set(host.get("fileset_ids", "").split(";")) if host.get("fileset_ids") else set()
                new_status = None
                if host_fs_ids and host_fs_ids.issubset(deleted_ids):
                    new_status = "DELETED"
                elif host_fs_ids & deleted_ids:
                    new_status = "PARTIAL"
                if new_status and host.get("status") != new_status:
                    host["status"] = new_status
                    host["last_updated"] = datetime.now().strftime("%Y-%m-%d %H:%M")

                if args.host_inventory:
                    save_inventory_csv(all_rsc_hosts, inv_path)
                else:
                    for inv_file in inv_files:
                        root_key = "LINUX_HOST_ROOT" if "linux_" in os.path.basename(inv_file) else "WINDOWS_HOST_ROOT"
                        root_hosts = [h for h in all_rsc_hosts if h.get("host_root") == root_key]
                        save_inventory_csv(root_hosts, inv_file)

    results = []
    interrupted = False
    try:
        delete_filesets(
            client, matched_filesets, args.preserve_snapshots,
            max_retries, parallel_workers, stagger_delay, results,
            on_result=_on_result)
    except KeyboardInterrupt:
        interrupted = True
        print("\n\n  Interrupted -- saving partial results (%d/%d processed)..." % (len(results), len(matched_filesets)))

    elapsed = time.time() - delete_start
    elapsed_min = int(elapsed // 60)
    elapsed_sec = int(elapsed % 60)

    success_count = sum(1 for r in results if r["status"] == "Deleted")
    fail_count = sum(1 for r in results if r["status"] == "Failed")

    not_found_file = None
    if not_found:
        not_found_file = os.path.join(log_dir, f"hosts_not_found_{timestamp}.csv")
        with open(not_found_file, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["hostname", "cluster"])
            writer.writeheader()
            writer.writerows(not_found)

    summary_header = "SUMMARY" + (" (PARTIAL - interrupted)" if interrupted else "")
    summary_lines = [
        "",
        "=" * 60,
        summary_header,
        "=" * 60,
        "  CSV entries:           %d" % len(entries),
        "  Entries not found:     %d" % len(not_found),
        "  Hosts matched:         %d" % len(matched_hosts),
        "  Filesets processed:    %d/%d" % (len(results), len(matched_filesets)),
        "  Deleted:               %d" % success_count,
        "  Failed:                %d" % fail_count,
        "  Snapshots:             %s" % ("Preserved" if args.preserve_snapshots else "Expired immediately"),
        "  Total run time:        %dm %ds" % (elapsed_min, elapsed_sec),
        "",
        "  Results CSV:     %s" % results_file,
        "  Activity log:    %s" % activity_log_file,
    ]
    if not_found_file:
        summary_lines.append("  Hosts not found: %s" % not_found_file)

    for line in summary_lines:
        _log(line)

    if _log_file:
        _log_file.close()

    if interrupted:
        sys.exit(1)


if __name__ == "__main__":
    main()
