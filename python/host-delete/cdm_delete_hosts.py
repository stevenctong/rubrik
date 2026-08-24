#!/usr/bin/env python3
"""
CDM Direct Host Delete (single phase)

Deletes hosts directly against a CDM cluster's local REST API. CDM's
host-delete endpoints automatically unassign SLA and move any existing
snapshots to Unmanaged Objects before removing the host object.

IMPORTANT: this does NOT delete snapshots immediately. They land in
Unmanaged Objects and expire later, on their original SLA's retention
schedule - there is no supported way to force-purge them sooner.

If you need snapshots gone immediately, use the two-phase scripts in
../rsc-bulk-host-removal/ (cdm_unprotect_hosts.py then
cdm_bulk_delete_hosts.py) instead of this script.

Usage examples:
  # Fully interactive (prompts for everything)
  python3 cdm_delete_hosts.py

  # Non-interactive with RSC Service Account JSON
  python3 cdm_delete_hosts.py --svc_json rsc-sa.json --cluster 10.8.48.104 --csv hosts.csv --force

  # Non-interactive with direct credentials
  python3 cdm_delete_hosts.py --cluster 10.8.48.104 --svc_client_id ABC --svc_secret XYZ --csv hosts.csv --force

  # Hybrid (some args, prompts for the rest)
  python3 cdm_delete_hosts.py --svc_json rsc-sa.json --csv hosts.csv
"""

import argparse
import csv
import json
import os
import sys
import time
from datetime import datetime

from cdm_client import CDMClient, run_in_batches, clean_input


def parse_args():
    parser = argparse.ArgumentParser(
        description="Delete hosts from a Rubrik CDM cluster. "
                    "Any argument not provided will be prompted for interactively.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 --csv hosts.csv --force\n"
               "  %(prog)s --cluster 10.8.48.104 --svc_client_id ABC --svc_secret XYZ --csv hosts.csv --force\n"
               "  %(prog)s   (fully interactive)\n",
    )

    auth_group = parser.add_argument_group("authentication")
    auth_group.add_argument("--svc_json", metavar="FILE",
                            help="RSC Service Account JSON file (contains client_id, client_secret)")
    auth_group.add_argument("--cluster", metavar="FQDN",
                            help="CDM cluster FQDN or IP address")
    auth_group.add_argument("--svc_client_id", metavar="ID",
                            help="Service Account ID (alternative to --svc_json)")
    auth_group.add_argument("--svc_secret",
                            help="Service Account Secret (alternative to --svc_json)")

    parser.add_argument("--csv", metavar="FILE",
                        help="CSV file with hostnames (must have a 'name' or 'hostname' column)")
    parser.add_argument("--batch-size", type=int, default=None, metavar="N",
                        help="Hosts per batch (default: 50, max: 100)")
    parser.add_argument("--batch-delay", type=int, default=None, metavar="SEC",
                        help="Delay between batches in seconds (default: 2)")
    parser.add_argument("--verify-retries", type=int, default=None, metavar="N",
                        help="Max verification retries (default: 3)")
    parser.add_argument("--verify-delay", type=int, default=None, metavar="SEC",
                        help="Delay between verification retries in seconds (default: 10)")
    parser.add_argument("--initial-wait", type=int, default=None, metavar="SEC",
                        help="Initial wait before verification in seconds (default: 10)")
    parser.add_argument("--force", "-f", action="store_true",
                        help="Skip confirmation and use default timings (batch-size=50, "
                             "batch-delay=2, verify-retries=3, verify-delay=10, initial-wait=10)")

    return parser.parse_args()


def load_json_credentials(json_path):
    with open(json_path, "r") as f:
        data = json.load(f)
    client_id = data.get("client_id")
    client_secret = data.get("client_secret")
    if not client_id or not client_secret:
        missing = []
        if not client_id:
            missing.append("client_id")
        if not client_secret:
            missing.append("client_secret")
        print(f"ERROR: JSON file is missing required fields: {', '.join(missing)}")
        sys.exit(1)
    return client_id, client_secret


def prompt_if_missing(value, prompt_text, clean=False, required=False):
    if value:
        return value
    while True:
        result = input(prompt_text).strip()
        if clean:
            result = clean_input(result)
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


def read_hostnames_from_csv(csv_file):
    hostnames = []
    with open(csv_file, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = (
                row.get("name") or row.get("Name")
                or row.get("hostname") or row.get("Hostname")
            )
            if name and name.strip():
                hostnames.append(name.strip())
    return hostnames


def bulk_delete_hosts(client, host_ids):
    try:
        client.post("/api/internal/host/bulk-delete", body=host_ids)
        return True, "Bulk deletion successful"
    except Exception as e:
        return False, str(e)


def delete_single_host(client, host_id):
    try:
        client.delete(f"/api/v1/host/{host_id}")
        return True, "Deleted successfully"
    except Exception as e:
        return False, str(e)


def delete_in_batches(client, hosts, batch_size, delay_seconds):
    def process_batch(batch):
        batch_ids = [h["id"] for h in batch]
        success, message = bulk_delete_hosts(client, batch_ids)
        results = []
        if success:
            print(f"  Batch successful")
            for h in batch:
                results.append({"id": h["id"], "name": h["name"], "status": "Removed", "message": message})
        else:
            print(f"  Batch failed: {message}")
            print("  Falling back to individual deletions...")
            for h in batch:
                ind_success, ind_message = delete_single_host(client, h["id"])
                if ind_success:
                    print(f"    OK  {h['name']}")
                    results.append({"id": h["id"], "name": h["name"], "status": "Removed", "message": ind_message})
                else:
                    print(f"    FAIL {h['name']}: {ind_message}")
                    results.append({"id": h["id"], "name": h["name"], "status": "Failed", "message": ind_message})
                time.sleep(0.5)
        return results

    results = run_in_batches(hosts, batch_size, delay_seconds, process_batch, label="Delete batch")
    success_count = sum(1 for r in results if r["status"] == "Removed")
    fail_count = sum(1 for r in results if r["status"] == "Failed")
    return results, success_count, fail_count


def verify_hosts_removed(client, host_ids, max_retries=3, retry_delay=10):
    removed = []
    pending = list(host_ids)

    for attempt in range(max_retries):
        if not pending:
            break

        if attempt > 0:
            print(f"  Retry {attempt}/{max_retries - 1}: waiting {retry_delay}s before re-checking {len(pending)} host(s)...")
            time.sleep(retry_delay)

        hosts_by_name = client.list_all_hosts()
        existing_ids = {h.get("id") for h in hosts_by_name.values()}

        still_pending = []
        for host_id in pending:
            if host_id in existing_ids:
                still_pending.append(host_id)
            else:
                removed.append(host_id)
        pending = still_pending

        if pending and attempt < max_retries - 1:
            print(f"  Check {attempt + 1}: {len(removed)} removed, {len(pending)} still pending...")

    return removed, pending


def main():
    args = parse_args()

    print("=" * 60)
    print("CDM Direct Host Delete (single phase)")
    print("=" * 60)
    print("NOTE: This deletes hosts directly. CDM automatically unassigns")
    print("SLA and moves existing snapshots to Unmanaged Objects as part of")
    print("host deletion - snapshots are NOT deleted immediately, they")
    print("expire later on their original SLA retention schedule.")
    print()

    # --- Resolve cluster and credentials ---
    fqdn = prompt_if_missing(args.cluster, "CDM cluster FQDN/IP (e.g., 10.8.48.104): ", required=True)

    json_path = args.svc_json
    if not json_path and not args.svc_client_id:
        json_path = input("Service Account JSON (leave blank if providing client id & secret directly): ").strip()
    if json_path:
        json_path = os.path.expanduser(json_path)
        print(f"Reading credentials from: {json_path}")
        service_account_id, secret = load_json_credentials(json_path)
    else:
        service_account_id = prompt_if_missing(
            args.svc_client_id, "Service Account Client ID: ", clean=True, required=True)
        secret = prompt_if_missing(
            args.svc_secret, "Service Account Secret: ", clean=True, required=True)
    csv_file = prompt_if_missing(args.csv, "CSV file path with hostnames: ", required=True)
    csv_file = os.path.expanduser(csv_file)

    if args.force:
        batch_size = args.batch_size if args.batch_size is not None else 50
        delay_seconds = args.batch_delay if args.batch_delay is not None else 2
        max_retries = args.verify_retries if args.verify_retries is not None else 3
        retry_delay = args.verify_delay if args.verify_delay is not None else 10
        initial_wait = args.initial_wait if args.initial_wait is not None else 10
    else:
        batch_size = prompt_int_if_missing(
            args.batch_size, "Batch size (default 50, max 100): ", default=50, min_val=1, max_val=100)
        delay_seconds = prompt_int_if_missing(
            args.batch_delay, "Delay between batches in seconds (default 2): ", default=2)

        if args.verify_retries is None and args.verify_delay is None and args.initial_wait is None:
            print("\nVerification settings (for slow clusters):")
        max_retries = prompt_int_if_missing(
            args.verify_retries, "  Max verification retries (default 3): ", default=3, min_val=1, max_val=10)
        retry_delay = prompt_int_if_missing(
            args.verify_delay, "  Delay between verification retries in seconds (default 10): ", default=10, min_val=5, max_val=60)
        initial_wait = prompt_int_if_missing(
            args.initial_wait, "  Initial wait before verification in seconds (default 10): ", default=10, min_val=5, max_val=120)

    batch_size = max(1, min(100, batch_size))

    # --- Connect ---
    print(f"\nConnecting to {fqdn}...")
    try:
        client = CDMClient(fqdn, service_account_id, secret)
    except Exception as e:
        print(f"ERROR: Failed to authenticate: {e}")
        sys.exit(1)
    print("Connected!\n")

    # --- Read and resolve hostnames ---
    hostnames = read_hostnames_from_csv(csv_file)
    if not hostnames:
        print("ERROR: No hostnames found in CSV file")
        print("CSV must have a 'name' or 'hostname' column")
        sys.exit(1)
    print(f"Found {len(hostnames)} hostnames in input CSV.\n")

    print("Fetching full host list from cluster (single bulk lookup)...")
    hosts_by_name = client.list_all_hosts()
    print(f"Cluster reports {len(hosts_by_name)} total hosts.\n")

    hosts = []
    not_found = []
    for hostname in hostnames:
        host = hosts_by_name.get(hostname.lower())
        if host and host.get("id"):
            hosts.append({"id": host["id"], "name": hostname})
        else:
            not_found.append(hostname)

    print(f"  Hosts matched on cluster: {len(hosts)}")
    print(f"  Hostnames not found:      {len(not_found)}")
    if not_found:
        print("  Not found (first 5): " + ", ".join(not_found[:5]))

    if not hosts:
        print("\nNo matching hosts to delete. Exiting.")
        sys.exit(0)

    print(f"\nFound {len(hosts)} hosts to delete:\n")
    for h in hosts[:5]:
        print(f"  - {h['name']} ({h['id']})")
    if len(hosts) > 5:
        print(f"  ... and {len(hosts) - 5} more")

    total_batches = (len(hosts) + batch_size - 1) // batch_size
    print(f"\nWill process {len(hosts)} hosts in {total_batches} batches of up to {batch_size}")
    print(f"NOTE: the CDM bulk-delete endpoint waits up to ~300s for all jobs")
    print(f"in a batch to finish and fails the whole batch on any invalid host ID -")
    print(f"this is why batch size is capped at 100 and failures fall back to")
    print(f"per-host deletion.")
    print(f"\nReminder: existing snapshots for these hosts will move to")
    print(f"Unmanaged Objects and are NOT deleted immediately.")

    if not args.force:
        confirm = input(f"\nProceed with deleting {len(hosts)} hosts? (yes/no): ").strip().lower()
        if confirm != "yes":
            print("Aborted.")
            return

    # --- Delete ---
    print(f"\n{'=' * 60}")
    print("DELETING HOSTS (BATCHED)")
    print(f"{'=' * 60}")
    results, success_count, fail_count = delete_in_batches(client, hosts, batch_size, delay_seconds)

    # --- Verify ---
    print(f"\n{'=' * 60}")
    print("VALIDATING REMOVALS")
    print(f"{'=' * 60}\n")
    print(f"Waiting {initial_wait}s for deletions to process...")
    time.sleep(initial_wait)

    host_ids = [h["id"] for h in hosts]
    print(f"Verifying {len(host_ids)} hosts were removed (max {max_retries} retries, {retry_delay}s delay)...")
    removed_ids, still_exists_ids = verify_hosts_removed(client, host_ids, max_retries, retry_delay)

    for r in results:
        if r["id"] in removed_ids:
            r["verified"] = "Yes"
        elif r["id"] in still_exists_ids:
            r["verified"] = "No - Still exists"
        else:
            r["verified"] = "Unknown"

    print(f"\n  Verified removed: {len(removed_ids)}")
    print(f"  Still exists:     {len(still_exists_ids)}")

    if still_exists_ids:
        print("\n  Hosts that still exist (may need more time or manual check):")
        for host_id in still_exists_ids[:5]:
            host_name = next((h["name"] for h in hosts if h["id"] == host_id), "Unknown")
            print(f"    - {host_name} ({host_id})")
        if len(still_exists_ids) > 5:
            print(f"    ... and {len(still_exists_ids) - 5} more")

    # --- Write output ---
    log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(log_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    results_file = os.path.join(log_dir, f"host_delete_results_{timestamp}.csv")
    with open(results_file, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["id", "name", "status", "message", "verified"])
        writer.writeheader()
        writer.writerows(results)

    not_found_file = None
    if not_found:
        not_found_file = os.path.join(log_dir, f"hosts_not_found_{timestamp}.csv")
        with open(not_found_file, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["hostname"])
            for h in not_found:
                writer.writerow([h])

    print(f"\n{'=' * 60}")
    print("SUMMARY")
    print(f"{'=' * 60}")
    print(f"  Total hostnames in input:  {len(hostnames)}")
    print(f"  Hostnames not found:       {len(not_found)}")
    print(f"  Total hosts processed:     {len(hosts)}")
    print(f"  Batches processed:         {total_batches}")
    print(f"  Deletion requested:        {success_count}")
    print(f"  Deletion failed:           {fail_count}")
    print(f"  Verified removed:          {len(removed_ids)}")
    print(f"  Still exists:              {len(still_exists_ids)}")
    print(f"\n  Results saved to: {results_file}")
    if not_found_file:
        print(f"  Hosts not found saved to: {not_found_file}")


if __name__ == "__main__":
    main()
