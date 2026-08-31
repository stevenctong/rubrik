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

  # Slow environment -- increase timeout, reduce parallelism, wider stagger
  python3 cdm_delete_hosts.py --svc_json rsc-sa.json --cluster 10.8.48.104 --csv hosts.csv --timeout 300 --parallel 2 --stagger 15 --force

Updated: 8/31/26
"""

import argparse
import concurrent.futures
import csv
import json
import os
import sys
import threading
import time
from datetime import datetime

from cdm_client import CDMClient, clean_input


# ---------------------------------------------------------------------------
# Logging infrastructure (mirrors rsc_delete_filesets.py)
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Host existence verification
# ---------------------------------------------------------------------------

def _host_still_exists(client, host_id):
    try:
        client.get("/api/v1/host/%s" % host_id)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Deletion engine
# ---------------------------------------------------------------------------

def delete_hosts(client, hosts, max_retries, max_workers, stagger_delay,
                 results, on_result=None):
    total = len(hosts)
    started = [0]
    completed = [0]
    stop_event = threading.Event()

    def _worker(host):
        if stop_event.is_set():
            return None
        with _print_lock:
            started[0] += 1
            seq = started[0]
        result = _delete_single_host(client, host, max_retries, total, seq, completed)
        if on_result:
            on_result(result, results)
        else:
            results.append(result)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = []
        try:
            for i, host in enumerate(hosts):
                if stop_event.is_set():
                    break
                futures.append(pool.submit(_worker, host))
                if stagger_delay > 0 and i < len(hosts) - 1:
                    time.sleep(stagger_delay)
            for future in concurrent.futures.as_completed(futures):
                future.result()
        except KeyboardInterrupt:
            stop_event.set()
            pool.shutdown(wait=True)
            raise


def _delete_single_host(client, host, max_retries, total, seq, completed):
    prefix = "  [%d/%d]" % (seq, total)
    label = host["name"]
    last_error = None

    def _complete(status, message):
        with _print_lock:
            completed[0] += 1
            c = completed[0]
        _log("(%s) Completed %d of %d" % (_now(), c, total))
        return {"id": host["id"], "name": host["name"], "status": status, "message": message}

    def _verify_gone():
        _log("%s (%s) %s - Verifying host still exists..." % (prefix, _now(), label))
        if not _host_still_exists(client, host["id"]):
            _log("%s (%s) %s - Host gone (prior delete succeeded)" % (prefix, _now(), label))
            return True
        return False

    for attempt in range(1 + max_retries):
        if attempt == 0:
            _log("%s (%s) %s - Issuing Delete..." % (prefix, _now(), label))
        else:
            _log("%s (%s) %s - Issuing Delete (retry %d of %d)..." % (prefix, _now(), label, attempt, max_retries))

        try:
            client.delete("/api/v1/host/%s" % host["id"])
            _log("%s (%s) %s - Deleted OK" % (prefix, _now(), label))
            return _complete("Removed", "OK")
        except TimeoutError as e:
            last_error = str(e)
            if attempt < max_retries:
                _log("%s (%s) %s - timeout (%d of %d), retrying in %ds..." % (prefix, _now(), label, attempt + 1, max_retries, RETRY_DELAY))
                time.sleep(RETRY_DELAY)
            continue
        except Exception as e:
            if attempt > 0 and _verify_gone():
                return _complete("Removed", "OK (verified gone after retry)")
            _log("%s (%s) %s - FAILED: %s" % (prefix, _now(), label, e))
            return _complete("Failed", str(e))

    if _verify_gone():
        return _complete("Removed", "OK (verified gone after timeout)")
    _log("%s (%s) %s - FAILED: timed out after %d attempts" % (prefix, _now(), label, 1 + max_retries))
    return _complete("Failed", "Timed out after %d attempts: %s" % (1 + max_retries, last_error))


# ---------------------------------------------------------------------------
# Post-deletion verification pass
# ---------------------------------------------------------------------------

def verify_hosts_removed(client, host_ids, max_retries=3, retry_delay=10):
    removed = []
    pending = list(host_ids)

    for attempt in range(max_retries):
        if not pending:
            break

        if attempt > 0:
            _log("  Retry %d/%d: waiting %ds before re-checking %d host(s)..." % (attempt, max_retries - 1, retry_delay, len(pending)))
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
            _log("  Check %d: %d removed, %d still pending..." % (attempt + 1, len(removed), len(pending)))

    return removed, pending


# ---------------------------------------------------------------------------
# CLI helpers
# ---------------------------------------------------------------------------

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
    parser.add_argument("--parallel", type=int, default=None, metavar="N",
                        help="Max concurrent delete calls (default: 4)")
    parser.add_argument("--stagger", type=int, default=None, metavar="SEC",
                        help="Delay between launching each parallel worker (default: 10)")
    parser.add_argument("--retries", type=int, default=None, metavar="N",
                        help="Max retries per host on timeout/5xx (default: 3)")
    parser.add_argument("--timeout", type=int, default=None, metavar="SEC",
                        help="HTTP timeout per API call in seconds (default: 150)")
    parser.add_argument("--verify-retries", type=int, default=None, metavar="N",
                        help="Max verification retries (default: 3)")
    parser.add_argument("--verify-delay", type=int, default=None, metavar="SEC",
                        help="Delay between verification retries in seconds (default: 10)")
    parser.add_argument("--initial-wait", type=int, default=None, metavar="SEC",
                        help="Initial wait before verification in seconds (default: 10)")
    parser.add_argument("--force", "-f", action="store_true",
                        help="Skip confirmation and use default timings")

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
        print("ERROR: JSON file is missing required fields: %s" % ", ".join(missing))
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


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

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
        print("Reading credentials from: %s" % json_path)
        service_account_id, secret = load_json_credentials(json_path)
    else:
        service_account_id = prompt_if_missing(
            args.svc_client_id, "Service Account Client ID: ", clean=True, required=True)
        secret = prompt_if_missing(
            args.svc_secret, "Service Account Secret: ", clean=True, required=True)
    csv_file = prompt_if_missing(args.csv, "CSV file path with hostnames: ", required=True)
    csv_file = os.path.expanduser(csv_file)

    parallel_workers = args.parallel if args.parallel is not None else 4
    stagger_delay = args.stagger if args.stagger is not None else 10
    max_retries = args.retries if args.retries is not None else 3
    http_timeout = args.timeout if args.timeout is not None else 150

    if args.force:
        verify_retries = args.verify_retries if args.verify_retries is not None else 3
        verify_delay = args.verify_delay if args.verify_delay is not None else 10
        initial_wait = args.initial_wait if args.initial_wait is not None else 10
    else:
        if args.verify_retries is None and args.verify_delay is None and args.initial_wait is None:
            print("\nVerification settings (for slow clusters):")
        verify_retries = prompt_int_if_missing(
            args.verify_retries, "  Max verification retries (default 3): ", default=3, min_val=1, max_val=10)
        verify_delay = prompt_int_if_missing(
            args.verify_delay, "  Delay between verification retries in seconds (default 10): ", default=10, min_val=5, max_val=60)
        initial_wait = prompt_int_if_missing(
            args.initial_wait, "  Initial wait before verification in seconds (default 10): ", default=10, min_val=5, max_val=120)

    # --- Connect ---
    print("\nConnecting to %s..." % fqdn)
    try:
        client = CDMClient(fqdn, service_account_id, secret, timeout=http_timeout)
    except Exception as e:
        print("ERROR: Failed to authenticate: %s" % e)
        sys.exit(1)
    print("Connected!\n")

    # --- Read and resolve hostnames ---
    hostnames = read_hostnames_from_csv(csv_file)
    if not hostnames:
        print("ERROR: No hostnames found in CSV file")
        print("CSV must have a 'name' or 'hostname' column")
        sys.exit(1)
    print("Found %d hostnames in input CSV.\n" % len(hostnames))

    print("Fetching full host list from cluster (single bulk lookup)...")
    hosts_by_name = client.list_all_hosts()
    print("Cluster reports %d total hosts.\n" % len(hosts_by_name))

    hosts = []
    not_found = []
    for hostname in hostnames:
        host = hosts_by_name.get(hostname.lower())
        if host and host.get("id"):
            hosts.append({"id": host["id"], "name": hostname})
        else:
            not_found.append(hostname)

    print("  Hosts matched on cluster: %d" % len(hosts))
    print("  Hostnames not found:      %d" % len(not_found))
    if not_found:
        print("  Not found (first 5): " + ", ".join(not_found[:5]))

    if not hosts:
        print("\nNo matching hosts to delete. Exiting.")
        sys.exit(0)

    print("\nFound %d hosts to delete:\n" % len(hosts))
    for h in hosts[:5]:
        print("  - %s (%s)" % (h["name"], h["id"]))
    if len(hosts) > 5:
        print("  ... and %d more" % (len(hosts) - 5))

    print("\nReminder: existing snapshots for these hosts will move to")
    print("Unmanaged Objects and are NOT deleted immediately.")

    if not args.force:
        confirm = input("\nProceed with deleting %d hosts? (yes/no): " % len(hosts)).strip().lower()
        if confirm != "yes":
            print("Aborted.")
            return

    # --- Delete ---
    print("\n" + "=" * 60)
    print("DELETING HOSTS")
    print("=" * 60)
    print("  Parallel: %d workers (stagger %ds), retries: %d (delay %ds), timeout: %ds" % (
        parallel_workers, stagger_delay, max_retries, RETRY_DELAY, http_timeout))

    log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(log_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    results_file = os.path.join(log_dir, "host_delete_results_%s.csv" % timestamp)
    results_fields = ["id", "name", "status", "message"]
    activity_log_file = os.path.join(log_dir, "host_delete_log_%s.log" % timestamp)

    print("  Results CSV: %s" % results_file)
    print("  Activity log: %s" % activity_log_file)
    print()

    global _log_file
    _log_file = open(activity_log_file, "w")
    _log_file.write("Host Delete Activity Log - %s\n" % datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    _log_file.write("Cluster: %s\n" % fqdn)
    _log_file.write("Parallel: %d workers (stagger %ds), retries: %d (delay %ds), timeout: %ds\n" % (
        parallel_workers, stagger_delay, max_retries, RETRY_DELAY, http_timeout))
    _log_file.write("Total hosts: %d\n\n" % len(hosts))
    _log_file.flush()

    delete_start = time.time()

    results_lock = threading.Lock()
    with open(results_file, "w", newline="") as rf:
        writer = csv.DictWriter(rf, fieldnames=results_fields)
        writer.writeheader()
        rf.flush()

    def _on_result(result, results_list):
        with results_lock:
            results_list.append(result)
            with open(results_file, "a", newline="") as rf:
                writer = csv.DictWriter(rf, fieldnames=results_fields)
                writer.writerow({k: result.get(k, "") for k in results_fields})

    results = []
    interrupted = False
    try:
        delete_hosts(
            client, hosts, max_retries, parallel_workers, stagger_delay,
            results, on_result=_on_result)
    except KeyboardInterrupt:
        interrupted = True
        print("\n\n  Interrupted -- saving partial results (%d/%d processed)..." % (len(results), len(hosts)))

    # --- Verify ---
    if not interrupted:
        _log("\n" + "=" * 60)
        _log("VALIDATING REMOVALS")
        _log("=" * 60)
        _log("")
        _log("Waiting %ds for deletions to process..." % initial_wait)
        time.sleep(initial_wait)

        host_ids = [h["id"] for h in hosts]
        _log("Verifying %d hosts were removed (max %d retries, %ds delay)..." % (len(host_ids), verify_retries, verify_delay))
        removed_ids, still_exists_ids = verify_hosts_removed(client, host_ids, verify_retries, verify_delay)

        for r in results:
            if r["id"] in removed_ids:
                r["verified"] = "Yes"
            elif r["id"] in still_exists_ids:
                r["verified"] = "No - Still exists"
            else:
                r["verified"] = "Unknown"

        _log("")
        _log("  Verified removed: %d" % len(removed_ids))
        _log("  Still exists:     %d" % len(still_exists_ids))

        if still_exists_ids:
            _log("")
            _log("  Hosts that still exist (may need more time or manual check):")
            for host_id in still_exists_ids[:5]:
                host_name = next((h["name"] for h in hosts if h["id"] == host_id), "Unknown")
                _log("    - %s (%s)" % (host_name, host_id))
            if len(still_exists_ids) > 5:
                _log("    ... and %d more" % (len(still_exists_ids) - 5))

        # Rewrite results CSV with verified column
        verified_fields = ["id", "name", "status", "message", "verified"]
        with open(results_file, "w", newline="") as rf:
            writer = csv.DictWriter(rf, fieldnames=verified_fields)
            writer.writeheader()
            for r in results:
                writer.writerow({k: r.get(k, "") for k in verified_fields})

    elapsed = time.time() - delete_start
    elapsed_min = int(elapsed // 60)
    elapsed_sec = int(elapsed % 60)

    success_count = sum(1 for r in results if r["status"] == "Removed")
    fail_count = sum(1 for r in results if r["status"] == "Failed")

    not_found_file = None
    if not_found:
        not_found_file = os.path.join(log_dir, "hosts_not_found_%s.csv" % timestamp)
        with open(not_found_file, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["hostname"])
            for h in not_found:
                writer.writerow([h])

    summary_header = "SUMMARY" + (" (PARTIAL - interrupted)" if interrupted else "")
    summary_lines = [
        "",
        "=" * 60,
        summary_header,
        "=" * 60,
        "  Total hostnames in input:  %d" % len(hostnames),
        "  Hostnames not found:       %d" % len(not_found),
        "  Total hosts processed:     %d/%d" % (len(results), len(hosts)),
        "  Deletion requested:        %d" % success_count,
        "  Deletion failed:           %d" % fail_count,
    ]
    if not interrupted:
        summary_lines.append("  Verified removed:          %d" % len(removed_ids))
        summary_lines.append("  Still exists:              %d" % len(still_exists_ids))
    summary_lines.extend([
        "  Total run time:            %dm %ds" % (elapsed_min, elapsed_sec),
        "",
        "  Results CSV:     %s" % results_file,
        "  Activity log:    %s" % activity_log_file,
    ])
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
