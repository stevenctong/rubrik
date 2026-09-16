#!/usr/bin/env python3
"""
Rubrik AHV (Nutanix) Recovery Monitor

Monitors AHV recovery jobs to a terminal state and reports per-VM metrics.
Runs independently of whatever triggered the recovery, so it can be started,
stopped, and restarted at will -- including after a crash or a closed
terminal, or from a different machine entirely.

Two input modes:

  --state <wave-state CSV>   The normal path. Reads the CSV written by
                             ahv_mass_recovery.py (or by the Ansible
                             playbook), which already carries every
                             jobInstanceId. Fully resumable.

  --csv <wave list>          Discovery path, for when no state file exists.
                             Finds each VM's most recent Recovery event
                             series and adopts it. Less precise -- it will
                             pick up a recovery someone else started.

Metrics come from POST /api/internal/event_series/status, which reports
logicalSize, dataTransferred and throughput. Those fields are populated by
some CDM job types and not others, so transfer figures are best effort and
blank where the cluster does not report them. Durations are always computed
from event series timestamps and are therefore always available.

Usage examples:
  # Monitor a wave to completion (the normal path)
  python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --state ahv_wave_state_20260909_120000.csv

  # One status snapshot, no polling -- good for a cron or a quick check
  python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --state ahv_wave_state_20260909_120000.csv --once

  # Poll faster
  python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --state ahv_wave_state_20260909_120000.csv --poll_interval 15

  # No state file -- discover recent recoveries for a list of VMs
  python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --csv wave1.csv --inventory ahv_inventory_20260909_120000.csv

  # Abort every in-flight recovery in the wave
  python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --state ahv_wave_state_20260909_120000.csv --cancel

  # Fully interactive
  python3 ahv_monitor_recovery.py

Updated: 9/9/26 - initial version
"""

import argparse
import os
import sys
import time

import monitor_core
from ahv_common import (add_auth_args, banner, close_log, confirm, connect_cdm,
                        find_latest_csv, first_field, init_incremental_csv, log,
                        log_dir_for, now_hm, open_log, read_csv_rows, run_timestamp,
                        show_examples_if_bare, truncate_list, wave_name_from, write_csv)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Monitor Rubrik AHV recovery jobs to a terminal state and report per-VM "
                    "metrics. Any argument not provided will be prompted for interactively.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 "
               "--state ahv_wave_state_20260909_120000.csv\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 "
               "--state ahv_wave_state_20260909_120000.csv --once\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 "
               "--csv wave1.csv --inventory ahv_inventory_20260909_120000.csv\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 "
               "--state ahv_wave_state_20260909_120000.csv --cancel\n"
               "  %(prog)s   (fully interactive)\n",
    )

    add_auth_args(parser)

    parser.add_argument("--state", metavar="FILE",
                        help="Wave-state CSV from ahv_mass_recovery.py (preferred)")
    parser.add_argument("--csv", metavar="FILE",
                        help="Recovery wave CSV -- discovery mode when no state file exists")
    parser.add_argument("--inventory", metavar="FILE",
                        help="AHV inventory CSV. Resolves VM names to ids in discovery mode, "
                             "and supplies each VM's provisioned size for the SIZE column. "
                             "(default: newest match in inventory/)")
    parser.add_argument("--poll_interval", type=int, default=None, metavar="SEC",
                        help="Seconds between polls (default: 30)")
    parser.add_argument("--once", action="store_true",
                        help="Print one status snapshot and exit instead of polling")
    parser.add_argument("--max_polls", type=int, default=None, metavar="N",
                        help="Give up after N polls (default: unlimited)")
    parser.add_argument("--cancel", action="store_true",
                        help="Cancel every in-flight recovery in the wave, then exit")
    parser.add_argument("--timeout", type=int, default=None, metavar="SEC",
                        help="HTTP timeout in seconds (default: 150)")
    parser.add_argument("--force", "-f", action="store_true",
                        help="Skip confirmation prompts")

    return parser.parse_args()


def add_provisioned_sizes(records, inventory_path):
    """
    Annotate each record with the VM's provisioned size from the inventory CSV.

    The cluster reports no dataTransferred for AHV recovery jobs, so without
    this the table has no sense of scale at all -- a 40 GiB VM and a 600 GiB
    VM look identical while they run. This is provisioned size, not bytes
    moved, which is why the column is headed SIZE and not TRANSFERRED.
    """
    if not inventory_path:
        return 0
    sizes = {}
    try:
        for row in read_csv_rows(inventory_path):
            name = first_field(row, "vm_name", "name")
            vm_id = first_field(row, "vm_id", "id")
            size = first_field(row, "total_provisioned_bytes")
            if not size:
                continue
            if name:
                sizes[name.lower()] = size
            if vm_id:
                sizes[vm_id] = size
    except Exception:
        return 0

    found = 0
    for record in records:
        size = sizes.get(record.get("vm_id")) or \
            sizes.get((record.get("vm_name") or "").lower())
        if size:
            record["provisioned_bytes"] = size
            found += 1
    return found


def blank_record():
    return {
        "vm_name": "", "vm_id": "", "method": "", "snapshot_id": "", "snapshot_date": "",
        "job_instance_id": "", "event_series_id": "", "status": "", "raw_status": "",
        "status_updated": "", "provisioned_bytes": "",
        "progress_pct": "", "start_time": "", "end_time": "", "duration_seconds": "",
        "logical_size_bytes": "", "data_transferred_bytes": "",
        "throughput_bytes_per_sec": "", "message": "",
    }


def load_state(csv_file):
    """Load records from a wave-state CSV written by the trigger phase."""
    records = []
    for row in read_csv_rows(csv_file):
        vm_id = first_field(row, "vm_id", "id")
        if not vm_id:
            continue
        record = blank_record()
        record.update({
            "vm_name": first_field(row, "vm_name", "name"),
            "vm_id": vm_id,
            "method": first_field(row, "method"),
            "snapshot_id": first_field(row, "snapshot_id"),
            "snapshot_date": first_field(row, "snapshot_date"),
            "job_instance_id": first_field(row, "job_instance_id"),
            "event_series_id": first_field(row, "event_series_id"),
            "start_time": first_field(row, "triggered_at"),
            # Outcome from an earlier monitor run, if there was one. Records
            # already terminal are skipped by the poll loop and still counted
            # in the final summary.
            "status": first_field(row, "status"),
            "status_updated": first_field(row, "status_updated"),
            "end_time": first_field(row, "end_time"),
            "duration_seconds": first_field(row, "duration_seconds"),
            "data_transferred_bytes": first_field(row, "data_transferred_bytes"),
        })
        if (record.get("status") or "").lower() == "failed" and not record.get("end_time"):
            record["raw_status"] = "TriggerFailed"
            record["message"] = first_field(row, "message") or "trigger failed"
        records.append(record)
    return records


def load_wave_for_discovery(csv_file, inventory_file):
    """Discovery mode: wave list of VM names, resolved to ids."""
    inventory = {}
    if inventory_file:
        for row in read_csv_rows(inventory_file):
            name = first_field(row, "vm_name", "name")
            vm_id = first_field(row, "vm_id", "id")
            if name and vm_id:
                inventory[name.lower()] = vm_id

    records = []
    unresolved = []
    for row in read_csv_rows(csv_file):
        name = first_field(row, "vm_name", "name", "vmname", "hostname")
        if not name:
            continue
        vm_id = first_field(row, "vm_id", "id") or inventory.get(name.lower(), "")
        record = blank_record()
        record["vm_name"] = name
        record["vm_id"] = vm_id
        if vm_id:
            records.append(record)
        else:
            unresolved.append(name)
    return records, unresolved


def resolve_missing_ids(client, records, unresolved_names):
    """Fall back to the bulk VM listing for names the inventory did not cover."""
    if not unresolved_names:
        return [], unresolved_names
    log("(%s) Listing AHV VMs to resolve %d name(s)..." % (now_hm(), len(unresolved_names)))
    by_name = {}
    for vm in client.list_nutanix_vms():
        by_name[(vm.get("name") or "").lower()] = vm.get("id", "")

    resolved = []
    still_missing = []
    for name in unresolved_names:
        vm_id = by_name.get(name.lower())
        if vm_id:
            record = blank_record()
            record["vm_name"] = name
            record["vm_id"] = vm_id
            resolved.append(record)
        else:
            still_missing.append(name)
    return resolved, still_missing


def do_cancel(client, records, force):
    """Cancel every non-terminal event series in the wave."""
    monitor_core.resolve_event_series(client, records)
    monitor_core.poll_once(client, records)

    targets = [r for r in records
               if r.get("event_series_id") and not monitor_core.is_terminal(r)]
    if not targets:
        log("No in-flight recoveries to cancel.")
        return 0

    log("")
    log("  %d recovery(s) would be cancelled:" % len(targets))
    for line in truncate_list(["%s (%s)" % (r["vm_name"], r.get("status") or "pending")
                               for r in targets], indent="    "):
        log(line)

    if not force:
        log("")
        if not confirm("Cancel %d in-flight recovery(s)? (yes/no): " % len(targets)):
            log("Aborted.")
            return 0

    cancelled = 0
    for record in targets:
        try:
            client.cancel_event_series(record["event_series_id"])
            record["message"] = "cancel requested"
            cancelled += 1
            log("  (%s) %s - cancel requested" % (now_hm(), record["vm_name"]))
        except Exception as e:
            log("  (%s) %s - cancel FAILED: %s" % (now_hm(), record["vm_name"], e))
    return cancelled


def main():
    args = parse_args()
    start = time.time()

    http_timeout = args.timeout if args.timeout is not None else 150
    poll_interval = args.poll_interval if args.poll_interval is not None else 30

    print("\n" + "=" * 60)
    print("RUBRIK AHV RECOVERY MONITOR")
    print("=" * 60)

    show_examples_if_bare("ahv_monitor_recovery.py", [
        ["# Watch a wave to completion -- safe to Ctrl-C and restart",
         "python3 ahv_monitor_recovery.py \\",
         "    --svc_json ~/rsc-sa.json --cluster 10.8.48.104 \\",
         "    --state ahv_wave_state_20260911_120000.csv"],
        ["# One snapshot of status and exit",
         "python3 ahv_monitor_recovery.py \\",
         "    --svc_json ~/rsc-sa.json --cluster 10.8.48.104 \\",
         "    --state ahv_wave_state_20260911_120000.csv --once"],
    ], note="The wave-state CSV is refreshed every poll, so it is also a live "
            "progress view.")

    state_file = args.state
    wave_file = args.csv
    if not state_file and not wave_file:
        state_file = input(
            "Wave-state CSV (blank to use a wave list instead): ").strip()
        if not state_file:
            wave_file = input("Recovery wave CSV: ").strip()
    if not state_file and not wave_file:
        print("ERROR: one of --state or --csv is required.")
        sys.exit(1)

    unresolved = []
    if state_file:
        # Resolved event series ids get cached back into this file so a
        # restarted monitor skips the per-VM lookup entirely.
        state_file = os.path.expanduser(state_file)
        if not os.path.isfile(state_file):
            print("ERROR: state CSV not found: %s" % state_file)
            sys.exit(1)
        records = load_state(state_file)
        source = state_file
    else:
        wave_file = os.path.expanduser(wave_file)
        if not os.path.isfile(wave_file):
            print("ERROR: wave CSV not found: %s" % wave_file)
            sys.exit(1)
        records, unresolved = load_wave_for_discovery(
            wave_file, os.path.expanduser(args.inventory) if args.inventory else None)
        source = wave_file
        state_file = None

    if not records and not unresolved:
        print("ERROR: no VMs found in %s" % source)
        sys.exit(1)
    print("\nRead %d VM(s) from %s" % (len(records), source))

    client, fqdn = connect_cdm(args, http_timeout)

    log_dir = log_dir_for(__file__)
    timestamp = run_timestamp()
    wave_name = wave_name_from(state_file or wave_file)
    results_file = os.path.join(log_dir, "%s_results_%s.csv" % (wave_name, timestamp))
    activity_log = os.path.join(log_dir, "%s_monitor_log_%s.log" % (wave_name, timestamp))

    open_log(activity_log, [
        "AHV Recovery Monitor Activity Log - %s" % time.strftime("%Y-%m-%d %H:%M:%S"),
        "Cluster: %s" % fqdn,
        "Source: %s" % source,
        "Mode: %s, poll interval: %ds"
        % ("cancel" if args.cancel else ("once" if args.once else "poll"), poll_interval),
        "Total VMs: %d" % len(records),
    ])

    completed = False
    try:
        if unresolved:
            extra, still_missing = resolve_missing_ids(client, records, unresolved)
            records.extend(extra)
            if still_missing:
                log("  WARNING: %d VM name(s) not found on the cluster:" % len(still_missing))
                for line in truncate_list(still_missing, indent="    "):
                    log(line)

        if not records:
            log("ERROR: no VMs could be resolved on the cluster.")
            sys.exit(1)

        if wave_file and not state_file:
            log("")
            log("(%s) Discovering recent Recovery event series..." % now_hm())
            found = monitor_core.discover_from_vm_ids(client, records)
            log("  Adopted %d recovery(s) from event history" % found)
            if not found:
                log("")
                log("No recent recoveries found for these VMs.")
                sys.exit(1)

        if args.cancel:
            for line in banner("CANCEL IN-FLIGHT RECOVERIES"):
                log(line)
            cancelled = do_cancel(client, records, args.force)
            log("")
            log("  Cancel requested for %d recovery(s)." % cancelled)
            log("  Activity log: %s" % activity_log)
            return

        # Provisioned size gives the table a sense of scale, since the cluster
        # reports no transferred bytes for AHV recovery jobs.
        inventory_path = find_latest_csv(
            __file__, "*_inventory_*.csv", "inventory CSV", explicit=args.inventory)
        sized = add_provisioned_sizes(records, inventory_path)
        if sized:
            log("  Sized %d of %d VM(s) from the inventory CSV" % (sized, len(records)))

        for line in banner("MONITORING"):
            log(line)
        init_incremental_csv(results_file, monitor_core.RESULT_FIELDS)
        completed = monitor_core.monitor(
            client, records, poll_interval=poll_interval, once=args.once,
            results_path=results_file, max_polls=args.max_polls,
            state_path=state_file)

    except KeyboardInterrupt:
        log("")
        log("  Interrupted -- writing partial results.")
        _finish(records, results_file, activity_log, start, partial=True)
        sys.exit(1)
    finally:
        close_log()

    _finish(records, results_file, activity_log, start, partial=not completed)


def _finish(records, results_file, activity_log, start, partial):
    """Rewrite the full results CSV and print the metrics summary."""
    write_csv(results_file, monitor_core.RESULT_FIELDS, records)
    title = "SUMMARY (PARTIAL - still in progress)" if partial else "SUMMARY"
    for line in monitor_core.build_summary(records, time.time() - start, title=title):
        log(line)
    log("")
    log("  Results CSV:  %s" % results_file)
    log("  Activity log: %s" % activity_log)


if __name__ == "__main__":
    main()
