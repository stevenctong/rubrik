#!/usr/bin/env python3
"""
RSC Fileset Delete

Deletes filesets for specified hosts via the Rubrik Security Cloud (RSC)
GraphQL API. Given a CSV of hostname + cluster pairs, looks up each host
in RSC, discovers all its filesets (Linux and Windows), and deletes them.

By default, snapshots are expired immediately (preserveSnapshots=false).
Pass --preserve-snapshots to keep snapshots in Unmanaged Objects instead.

Usage examples:
  # Fully interactive (prompts for everything)
  python3 rsc_delete_filesets.py

  # Non-interactive with RSC Service Account JSON
  python3 rsc_delete_filesets.py --svc_json rsc-sa.json --csv hosts.csv --force

  # Non-interactive with direct credentials
  python3 rsc_delete_filesets.py --rsc_url rubrik-gaia.my.rubrik.com --svc_client_id ABC --svc_secret XYZ --csv hosts.csv --force

  # Preserve snapshots instead of expiring immediately
  python3 rsc_delete_filesets.py --svc_json rsc-sa.json --csv hosts.csv --preserve-snapshots --force
"""

import argparse
import csv
import json
import os
import ssl
import sys
import time
import urllib.request
import urllib.parse
import urllib.error
from datetime import datetime

from cdm_client import run_in_batches, clean_input


# ---------------------------------------------------------------------------
# RSC GraphQL client
# ---------------------------------------------------------------------------

class RSCClient:
    """RSC GraphQL API client, authenticated via Service Account credentials."""

    def __init__(self, rsc_url, client_id, client_secret):
        if not rsc_url.startswith("http"):
            rsc_url = f"https://{rsc_url}"
        rsc_url = rsc_url.rstrip("/")

        self.graphql_url = f"{rsc_url}/api/graphql"
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
            with urllib.request.urlopen(req, context=ctx) as response:
                result = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8")
            raise Exception(f"RSC auth failed (HTTP {e.code}): {error_body}") from e

        self.token = result.get("access_token")
        if not self.token:
            raise Exception(f"No access_token in auth response: {result}")

    def graphql(self, query, variables=None):
        body = json.dumps({"query": query, "variables": variables or {}}).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
        }
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        req = urllib.request.Request(
            self.graphql_url, data=body, headers=headers, method="POST",
        )
        try:
            with urllib.request.urlopen(req, context=ctx) as response:
                result = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8")
            raise Exception(f"GraphQL error (HTTP {e.code}): {error_body}") from e

        if "errors" in result and result["errors"]:
            raise Exception(f"GraphQL errors: {json.dumps(result['errors'], indent=2)}")
        return result.get("data", {})


# ---------------------------------------------------------------------------
# GraphQL queries
# ---------------------------------------------------------------------------

FIND_HOSTS_QUERY = """
query FindHosts($hostRoot: HostRoot!, $first: Int!, $after: String, $filter: [Filter!]!) {
  physicalHosts(hostRoot: $hostRoot, filter: $filter, first: $first, after: $after) {
    edges {
      node {
        id
        name
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
query FindHostFilesets($id: UUID!, $first: Int!, $after: String) {
  physicalHost(fid: $id) {
    id
    name
    physicalChildConnection(typeFilter: [LinuxFileset, WindowsFileset], first: $first, after: $after) {
      edges {
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
    parser.add_argument("--preserve-snapshots", action="store_true",
                        help="Keep snapshots (default: expire immediately)")
    parser.add_argument("--batch-size", type=int, default=None, metavar="N",
                        help="Fileset IDs per delete call (default: 50)")
    parser.add_argument("--batch-delay", type=int, default=None, metavar="SEC",
                        help="Delay between batches in seconds (default: 2)")
    parser.add_argument("--force", "-f", action="store_true",
                        help="Skip confirmation and use default timings (batch-size=50, batch-delay=2)")
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


def find_hosts(client, hostnames):
    """
    Query RSC for hosts matching the given hostnames (both Linux and Windows
    host roots). Returns a list of dicts with basic host info.
    """
    all_hosts = []

    for host_root in ["LINUX_HOST_ROOT", "WINDOWS_HOST_ROOT"]:
        variables = {
            "hostRoot": host_root,
            "first": 200,
            "filter": [
                {"field": "NAME", "texts": list(hostnames)},
            ],
        }

        after = None
        while True:
            if after:
                variables["after"] = after

            data = client.graphql(FIND_HOSTS_QUERY, variables)
            connection = data.get("physicalHosts", {})

            for edge in connection.get("edges", []):
                node = edge.get("node", {})
                cluster = node.get("cluster", {})
                all_hosts.append({
                    "host_id": node.get("id"),
                    "hostname": node.get("name", ""),
                    "cluster_id": cluster.get("id"),
                    "cluster_name": cluster.get("name", ""),
                })

            page_info = connection.get("pageInfo", {})
            if page_info.get("hasNextPage") and page_info.get("endCursor"):
                after = page_info["endCursor"]
            else:
                break

    return all_hosts


def get_host_filesets(client, host_id):
    """
    Query RSC for all filesets belonging to a single host.
    Returns a list of fileset dicts.
    """
    filesets = []
    after = None

    while True:
        variables = {"id": host_id, "first": 200}
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


def delete_filesets(client, fileset_ids, preserve_snapshots, batch_size, delay_seconds):
    def process_batch(batch):
        ids = [fs["id"] for fs in batch]
        results = []
        try:
            data = client.graphql(DELETE_FILESETS_MUTATION, {
                "ids": ids,
                "preserveSnapshots": preserve_snapshots,
            })
            success = data.get("bulkDeleteFileset", {}).get("success", False)
            if success:
                print(f"  Batch successful ({len(ids)} filesets)")
                for fs in batch:
                    results.append({**fs, "status": "Deleted", "message": "OK"})
            else:
                print(f"  Batch returned success=false, falling back to individual deletes...")
                for fs in batch:
                    results.append(_delete_single(client, fs, preserve_snapshots))
        except Exception as e:
            print(f"  Batch failed: {e}")
            print("  Falling back to individual deletions...")
            for fs in batch:
                results.append(_delete_single(client, fs, preserve_snapshots))
        return results

    return run_in_batches(fileset_ids, batch_size, delay_seconds, process_batch, label="Delete batch")


def _delete_single(client, fs, preserve_snapshots):
    try:
        data = client.graphql(DELETE_FILESETS_MUTATION, {
            "ids": [fs["id"]],
            "preserveSnapshots": preserve_snapshots,
        })
        success = data.get("bulkDeleteFileset", {}).get("success", False)
        if success:
            print(f"    OK  {fs['hostname']} / {fs['name']}")
            return {**fs, "status": "Deleted", "message": "OK"}
        else:
            print(f"    FAIL {fs['hostname']} / {fs['name']}: success=false")
            return {**fs, "status": "Failed", "message": "API returned success=false"}
    except Exception as e:
        print(f"    FAIL {fs['hostname']} / {fs['name']}: {e}")
        return {**fs, "status": "Failed", "message": str(e)}


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

    if args.force:
        batch_size = args.batch_size if args.batch_size is not None else 50
        delay_seconds = args.batch_delay if args.batch_delay is not None else 2
    else:
        batch_size = prompt_int_if_missing(
            args.batch_size, "Batch size (default 50): ", default=50, min_val=1, max_val=100)
        delay_seconds = prompt_int_if_missing(
            args.batch_delay, "Delay between batches in seconds (default 2): ", default=2)
    batch_size = max(1, min(100, batch_size))

    print(f"\nConnecting to RSC...")
    try:
        client = RSCClient(rsc_url, client_id, client_secret)
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

    # --- Look up hosts ---
    unique_hostnames = list({e["hostname"].lower() for e in entries})
    print(f"Looking up {len(unique_hostnames)} unique hostnames in RSC...")
    rsc_hosts = find_hosts(client, unique_hostnames)
    print(f"RSC returned {len(rsc_hosts)} matching host(s).\n")

    # --- Match CSV entries to RSC hosts ---
    csv_lookup = {}
    for entry in entries:
        key = (entry["hostname"].lower(), entry["cluster"].lower())
        csv_lookup[key] = entry

    matched_hosts = []
    matched_keys = set()
    for host in rsc_hosts:
        key = (host["hostname"].lower(), host["cluster_name"].lower())
        if key in csv_lookup:
            matched_keys.add(key)
            matched_hosts.append(host)

    not_found = []

    for key, entry in csv_lookup.items():
        if key not in matched_keys:
            not_found.append(entry)

    print(f"  CSV entries matched:   {len(matched_hosts)}")
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
        for fs in filesets:
            matched_filesets.append({
                "hostname": host["hostname"],
                "cluster": host["cluster_name"],
                "id": fs["id"],
                "name": fs["name"],
                "objectType": fs["objectType"],
            })

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
    print(f"\n{'=' * 60}")
    print("DELETING FILESETS")
    print(f"{'=' * 60}")

    results = delete_filesets(
        client, matched_filesets, args.preserve_snapshots, batch_size, delay_seconds)

    success_count = sum(1 for r in results if r["status"] == "Deleted")
    fail_count = sum(1 for r in results if r["status"] == "Failed")

    # --- Write output ---
    log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(log_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    results_file = os.path.join(log_dir, f"fileset_delete_results_{timestamp}.csv")
    with open(results_file, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "hostname", "cluster", "id", "name", "objectType", "status", "message"])
        writer.writeheader()
        writer.writerows(results)

    not_found_file = None
    if not_found:
        not_found_file = os.path.join(log_dir, f"hosts_not_found_{timestamp}.csv")
        with open(not_found_file, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["hostname", "cluster"])
            writer.writeheader()
            writer.writerows(not_found)

    print(f"\n{'=' * 60}")
    print("SUMMARY")
    print(f"{'=' * 60}")
    print(f"  CSV entries:           {len(entries)}")
    print(f"  Entries not found:     {len(not_found)}")
    print(f"  Hosts matched:         {hosts_matched}")
    print(f"  Filesets processed:    {len(matched_filesets)}")
    print(f"  Deleted:               {success_count}")
    print(f"  Failed:                {fail_count}")
    print(f"  Snapshots:             {'Preserved' if args.preserve_snapshots else 'Expired immediately'}")
    print(f"\n  Results saved to: {results_file}")
    if not_found_file:
        print(f"  Hosts not found saved to: {not_found_file}")


if __name__ == "__main__":
    main()
