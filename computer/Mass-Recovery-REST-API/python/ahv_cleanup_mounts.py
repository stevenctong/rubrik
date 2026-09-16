#!/usr/bin/env python3
"""
Rubrik AHV (Nutanix) Live Mount Cleanup

Lists AHV live mounts on a Rubrik CDM cluster and tears them down. A mass
live mount is usually a DR test, so this is the unwind step.

Runs in two stages by design:

  1. LIST   Always safe. Shows every mount the cluster reports, optionally
            filtered to a wave list or a wave-state CSV. Run it on its own
            with --list_only to see what exists.
  2. DELETE Requires a typed 'yes'. Unmounts in parallel with retry.

IMPORTANT -- the unmount endpoint is unverified.
  The reference API capture used to build this toolkit contains the mount
  LIST call but never an unmount, so the DELETE path below is inferred from
  the Rubrik CDM mount API convention:
      DELETE /api/v1/nutanix/vm/snapshot/mount/{mountId}
  Confirm it against your cluster before relying on it in a real recovery.
  Run --list_only first; if the listing works but deletes return 404/405,
  the path needs correcting in cdm_client.delete_vm_mount(). Failures are
  reported verbatim and are never swallowed as "already gone".

Usage examples:
  # Show every AHV live mount on the cluster and exit
  python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 --list_only

  # Show only mounts whose source VMs are in a wave list
  python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --csv wave1.csv --inventory ahv_inventory_20260909_120000.csv --list_only

  # Tear down the mounts created by a specific recovery wave
  python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --state ahv_wave_state_20260909_120000.csv

  # Tear down every AHV live mount on the cluster (careful)
  python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 --all

  # Fully interactive
  python3 ahv_cleanup_mounts.py

Updated: 9/9/26 - initial version
"""

import argparse
import concurrent.futures
import os
import sys
import threading
import time

from ahv_common import (add_auth_args, append_csv_row, banner, close_log, confirm,
                        connect_cdm, first_field, init_incremental_csv, log,
                        log_dir_for, now_hm, open_log, print_lock, read_csv_rows,
                        run_timestamp, show_examples_if_bare, wave_name_from)

RESULT_FIELDS = ["mount_id", "mounted_vm_name", "source_vm_name", "source_vm_id",
                 "origin", "status", "message"]


def parse_args():
    parser = argparse.ArgumentParser(
        description="List and tear down Rubrik AHV (Nutanix) live mounts. Any argument not "
                    "provided will be prompted for interactively.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 --list_only\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 "
               "--state ahv_wave_state_20260909_120000.csv\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 --all\n"
               "  %(prog)s   (fully interactive)\n",
    )

    add_auth_args(parser)

    scope = parser.add_argument_group("scope (pick one)")
    scope.add_argument("--state", metavar="FILE",
                       help="Wave-state CSV -- unmount only these source VMs")
    scope.add_argument("--csv", metavar="FILE",
                       help="Wave list CSV -- unmount only these source VMs")
    scope.add_argument("--all", action="store_true",
                       help="Every AHV live mount on the cluster")

    parser.add_argument("--inventory", metavar="FILE",
                        help="AHV inventory CSV, to resolve VM names to ids with --csv")
    parser.add_argument("--mounted_name_prefix", metavar="PREFIX",
                        help="Narrow to mounts whose MOUNTED VM name starts with this "
                             "(comma-separated for several). Off by default: --state and "
                             "--csv match every mount of the VMs they name, and the preview "
                             "labels which ones came from that wave.")
    parser.add_argument("--list_only", action="store_true",
                        help="List mounts and exit without deleting anything")
    parser.add_argument("--force_unmount", action="store_true",
                        help="Pass force=true on the unmount call")
    parser.add_argument("--parallel", type=int, default=None, metavar="N",
                        help="Max concurrent unmount calls (default: 4)")
    parser.add_argument("--stagger", type=int, default=None, metavar="SEC",
                        help="Delay between launching each worker (default: 5)")
    parser.add_argument("--retries", type=int, default=None, metavar="N",
                        help="Max retries per unmount on timeout (default: 2)")
    parser.add_argument("--retry_delay", type=int, default=None, metavar="SEC",
                        help="Wait between unmount retries (default: 20)")
    parser.add_argument("--timeout", type=int, default=None, metavar="SEC",
                        help="HTTP timeout in seconds (default: 150)")
    parser.add_argument("--force", "-f", action="store_true",
                        help="Skip confirmation and use default timings")

    return parser.parse_args()


def load_scope_vm_ids(args):
    """
    Source VM ids to filter mounts by, plus the recovered-VM name prefixes
    recorded in the wave.

    Scope is by source VM: every mount of a VM named in the file is offered
    as a cleanup candidate. That is the useful default -- the file says which
    VMs you care about, and a source VM can easily carry mounts from several
    runs that all deserve tearing down.

    The prefixes are returned for LABELLING only, so the preview can show
    which mounts match the wave's own recovered_vm_prefix and which came from
    somewhere else. Pass --mounted_name_prefix to turn that into a real
    filter.

    An empty vm_ids set means 'no filter'.
    """
    vm_ids = set()
    names = set()
    prefixes = set()

    if args.state:
        for row in read_csv_rows(os.path.expanduser(args.state)):
            vm_id = first_field(row, "vm_id", "id")
            if vm_id:
                vm_ids.add(vm_id)
            prefix = first_field(row, "recovered_vm_prefix", "vm_name_prefix", "prefix")
            if prefix:
                prefixes.add(prefix)
    if args.csv:
        for row in read_csv_rows(os.path.expanduser(args.csv)):
            vm_id = first_field(row, "vm_id", "id")
            name = first_field(row, "vm_name", "name", "vmname")
            if vm_id:
                vm_ids.add(vm_id)
            elif name:
                names.add(name.lower())

    if names and args.inventory:
        for row in read_csv_rows(os.path.expanduser(args.inventory)):
            name = first_field(row, "vm_name", "name")
            vm_id = first_field(row, "vm_id", "id")
            if name and vm_id and name.lower() in names:
                vm_ids.add(vm_id)
                names.discard(name.lower())

    filter_prefixes = set()
    if args.mounted_name_prefix:
        filter_prefixes = set(
            p.strip() for p in args.mounted_name_prefix.split(",") if p.strip())

    return vm_ids, names, prefixes, filter_prefixes


def describe_mount(mount):
    """Normalise a mount object into the fields we report on."""
    source_id = (mount.get("nutanixVmId") or mount.get("vmId")
                 or mount.get("sourceVmId") or "")
    source_name = (mount.get("sourceVmName") or mount.get("vmName") or "")
    mounted_name = (mount.get("mountedVmName") or mount.get("newVmName")
                    or mount.get("name") or "")
    return {
        "mount_id": mount.get("id", ""),
        "mounted_vm_name": mounted_name,
        "source_vm_name": source_name,
        "source_vm_id": source_id,
        "origin": "",
        "status": "",
        "message": "",
    }


def unmount_one(client, row, max_retries, retry_delay, force_unmount, total, seq,
                completed, lock):
    prefix = "  [%d/%d]" % (seq, total)
    label = row["mounted_vm_name"] or row["mount_id"]
    last_error = None

    def _complete(status, message):
        with lock:
            completed[0] += 1
            count = completed[0]
        row["status"] = status
        row["message"] = message
        log("(%s) Completed %d of %d" % (now_hm(), count, total))
        return row

    for attempt in range(1 + max_retries):
        if attempt == 0:
            log("%s (%s) %s - Issuing unmount..." % (prefix, now_hm(), label))
        else:
            log("%s (%s) %s - Issuing unmount (retry %d of %d)..."
                % (prefix, now_hm(), label, attempt, max_retries))
        try:
            client.delete_vm_mount(row["mount_id"], force=force_unmount)
            log("%s (%s) %s - unmount accepted" % (prefix, now_hm(), label))
            return _complete("Unmounted", "OK")
        except TimeoutError as e:
            last_error = str(e)
            log("%s (%s) %s - unmount timed out, waiting %ds..."
                % (prefix, now_hm(), label, retry_delay))
            time.sleep(retry_delay)
            continue
        except Exception as e:
            log("%s (%s) %s - unmount FAILED: %s" % (prefix, now_hm(), label, e))
            return _complete("Failed", str(e))

    return _complete("Failed", "Timed out after %d attempts: %s"
                     % (1 + max_retries, last_error))


def unmount_all(client, rows, max_retries, retry_delay, force_unmount, max_workers,
                stagger, results_path):
    total = len(rows)
    started = [0]
    completed = [0]
    lock = print_lock()
    stop_event = threading.Event()
    results_lock = threading.Lock()

    def _worker(row):
        if stop_event.is_set():
            return None
        with lock:
            started[0] += 1
            seq = started[0]
        result = unmount_one(client, row, max_retries, retry_delay, force_unmount,
                             total, seq, completed, lock)
        with results_lock:
            append_csv_row(results_path, RESULT_FIELDS, result)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = []
        try:
            for i, row in enumerate(rows):
                if stop_event.is_set():
                    break
                futures.append(pool.submit(_worker, row))
                if stagger > 0 and i < len(rows) - 1:
                    time.sleep(stagger)
            for future in concurrent.futures.as_completed(futures):
                future.result()
        except KeyboardInterrupt:
            stop_event.set()
            pool.shutdown(wait=True)
            raise


def main():
    args = parse_args()
    start = time.time()

    http_timeout = args.timeout if args.timeout is not None else 150
    max_workers = args.parallel if args.parallel is not None else 4
    stagger = args.stagger if args.stagger is not None else 5
    max_retries = args.retries if args.retries is not None else 2
    retry_delay = args.retry_delay if args.retry_delay is not None else 20

    print("\n" + "=" * 60)
    print("RUBRIK AHV LIVE MOUNT CLEANUP")
    print("=" * 60)

    show_examples_if_bare("ahv_cleanup_mounts.py", [
        ["# List every AHV live mount and exit -- always safe",
         "python3 ahv_cleanup_mounts.py \\",
         "    --svc_json ~/rsc-sa.json --cluster 10.8.48.104 --list_only"],
        ["# Tear down only the mounts from one recovery wave",
         "python3 ahv_cleanup_mounts.py \\",
         "    --svc_json ~/rsc-sa.json --cluster 10.8.48.104 \\",
         "    --state ahv_wave_state_20260911_120000.csv"],
    ], note="Run --list_only first: the unmount call is inferred from API "
            "convention and is not yet verified.")

    if args.list_only and not (args.state or args.csv):
        # Listing is read-only, so there is nothing to confirm. Show everything.
        args.all = True

    if not (args.state or args.csv or args.all):
        print("\nScope: pass --state, --csv, or --all.")
        choice = input("Unmount ALL AHV live mounts on the cluster? (yes/no): ").strip().lower()
        if choice != "yes":
            print("Aborted. Re-run with --state or --csv to scope to a wave.")
            sys.exit(0)
        args.all = True

    vm_ids, unresolved_names, wave_prefixes, filter_prefixes = load_scope_vm_ids(args)
    if not args.all and not vm_ids:
        print("ERROR: no source VM ids resolved from the supplied scope. "
              "Pass --inventory alongside --csv, or use --state.")
        sys.exit(1)

    client, fqdn = connect_cdm(args, http_timeout)

    log_dir = log_dir_for(__file__)
    timestamp = run_timestamp()
    wave_name = wave_name_from(args.state or args.csv, default="ahv")
    results_file = os.path.join(log_dir, "%s_unmount_results_%s.csv" % (wave_name, timestamp))
    activity_log = os.path.join(log_dir, "%s_unmount_log_%s.log" % (wave_name, timestamp))

    open_log(activity_log, [
        "AHV Live Mount Cleanup Activity Log - %s" % time.strftime("%Y-%m-%d %H:%M:%S"),
        "Cluster: %s" % fqdn,
        "Scope: %s" % ("all mounts" if args.all else "%d source VM(s)" % len(vm_ids)),
        "Parallel: %d workers (stagger %ds), retries: %d, timeout: %ds"
        % (max_workers, stagger, max_retries, http_timeout),
    ])

    try:
        if unresolved_names:
            log("  WARNING: %d VM name(s) could not be resolved to ids and are not in scope:"
                % len(unresolved_names))
            log("    %s" % ", ".join(sorted(unresolved_names)[:5]))

        # --- List ---
        log("")
        log("(%s) Listing AHV live mounts..." % now_hm())
        try:
            mounts = client.list_vm_mounts()
        except Exception as e:
            log("ERROR: could not list live mounts: %s" % e)
            sys.exit(1)

        rows = [describe_mount(m) for m in mounts]
        rows = [r for r in rows if r["mount_id"]]
        total_seen = len(rows)

        if not args.all:
            rows = [r for r in rows if r["source_vm_id"] in vm_ids]

        # Optional explicit narrowing. Off unless asked for.
        if filter_prefixes:
            before = len(rows)
            rows = [r for r in rows
                    if any((r["mounted_vm_name"] or "").startswith(p)
                           for p in filter_prefixes)]
            log("  --mounted_name_prefix %s dropped %d mount(s)"
                % (",".join(sorted(filter_prefixes)), before - len(rows)))

        # Label each mount against the wave's own prefix so the operator can
        # tell what this wave created from what was already there.
        for row in rows:
            name = row["mounted_vm_name"] or ""
            if wave_prefixes and any(name.startswith(p) for p in wave_prefixes):
                row["origin"] = "this wave"
            elif wave_prefixes:
                row["origin"] = "other"
            else:
                row["origin"] = ""

        log("  Found %d live mount(s) in scope (cluster reported %d total)"
            % (len(rows), total_seen))
        other = sum(1 for r in rows if r.get("origin") == "other")
        if other:
            log("  %d of them do NOT match this wave's prefix (%s) -- check the ORIGIN"
                % (other, ", ".join(sorted(wave_prefixes))))
            log("  column below before confirming.")

        if not rows:
            log("")
            log("Nothing to unmount.")
            return

        log("")
        log("  %-34s %-28s %s" % ("MOUNTED VM", "SOURCE VM", "ORIGIN"))
        log("  %s" % ("-" * 78))
        for row in rows[:20]:
            log("  %-34s %-28s %s" % (row["mounted_vm_name"][:34],
                                      row["source_vm_name"][:28],
                                      row.get("origin", "")))
        if len(rows) > 20:
            log("  ... and %d more" % (len(rows) - 20))

        if args.list_only:
            log("")
            log("List only -- nothing was deleted.")
            log("  Activity log: %s" % activity_log)
            return

        # --- Delete ---
        if not args.force:
            log("")
            if not confirm("Unmount %d live mount(s)? This is not reversible. (yes/no): "
                           % len(rows)):
                log("Aborted.")
                return

        log("")
        for line in banner("UNMOUNTING"):
            log(line)
        init_incremental_csv(results_file, RESULT_FIELDS)

        interrupted = False
        try:
            unmount_all(client, rows, max_retries, retry_delay, args.force_unmount,
                        max_workers, stagger, results_file)
        except KeyboardInterrupt:
            interrupted = True
            log("")
            log("  Interrupted -- saving partial results.")

        succeeded = sum(1 for r in rows if r["status"] == "Unmounted")
        failed = sum(1 for r in rows if r["status"] == "Failed")

        title = "SUMMARY (PARTIAL - interrupted)" if interrupted else "SUMMARY"
        for line in banner(title):
            log(line)
        log("  Mounts in scope:           %d" % len(rows))
        log("  Unmounted:                 %d" % succeeded)
        log("  Failed:                    %d" % failed)
        log("  Total run time:            %dm %ds"
            % (int(time.time() - start) // 60, int(time.time() - start) % 60))
        log("")
        log("  Results CSV:  %s" % results_file)
        log("  Activity log: %s" % activity_log)

        if failed:
            log("")
            log("  NOTE: if every unmount failed with a 404 or 405, the DELETE path is")
            log("  wrong for this CDM version -- see the header of this script.")

        if interrupted:
            sys.exit(1)

    except KeyboardInterrupt:
        print("\n\n  Interrupted.")
        sys.exit(1)
    finally:
        close_log()


if __name__ == "__main__":
    main()
