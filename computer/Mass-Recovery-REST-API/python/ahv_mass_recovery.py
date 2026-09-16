#!/usr/bin/env python3
"""
Rubrik AHV (Nutanix) Mass Recovery

Triggers export or live mount for a wave of AHV VMs against a Rubrik CDM
cluster, then writes a durable wave-state CSV so monitoring can be resumed
at any time -- including after a crash, a closed terminal, or from a
different machine.

The CDM recovery API is natively batched, so the trigger is roughly four
calls regardless of whether the wave is 2 VMs or 500:

  1. Resolve VM names to ids   GET  /api/internal/nutanix/vm  (or --inventory)
  2. Pick the snapshot         POST /api/v1/snapshot/closest_to_point_in_time
  3. Resolve the target        GET  /api/internal/nutanix/cluster{,/{id}/container}
  4. Trigger                   POST /api/v1/nutanix/vm/batch_export | batch_mount

Steps 2 and 4 are chunked (--chunk_size) because a single very large batch
can exceed the cluster's request timeout.

VMs with no snapshot at the requested point in time are excluded and
reported; they are never silently dropped.

Monitoring is optional here (--monitor). For long waves prefer running
ahv_monitor_recovery.py against the wave-state CSV, which is resumable.

Usage examples:
  # Dry run first -- resolves everything and prints the request bodies, POSTs nothing
  python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --csv wave1.csv --method mount --container default-container --recovered_vm_prefix dr --dry_run

  # Live mount a wave from the newest snapshot, then watch it to completion
  python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --csv wave1.csv --method mount --container default-container --recovered_vm_prefix dr --monitor

  # Export to a point in time (UTC), trigger only, monitor separately
  python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --csv wave1.csv --method export --point_in_time "2026-09-08 23:00:00" \
      --container default-container --recovered_vm_prefix dr --force

  # Large cluster -- resolve everything from staged CSVs, no lookup API calls
  python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
      --csv wave1.csv --inventory ahv_inventory_20260909_120000.csv \
      --containers ahv_containers_20260909_120000.csv --method mount --force

  # Fully interactive
  python3 ahv_mass_recovery.py

Staged CSVs from get_ahv_inventory.py are picked up automatically: the newest
ahv_inventory_*.csv and ahv_containers_*.csv sitting next to this script are
used unless --inventory / --containers name a specific file. The file chosen
and its age are always printed, and anything a week old warns. Pass
--no_auto_csv to turn discovery off entirely.

Wave CSV columns (from get_ahv_inventory.py; only the name is required):
  vm_name                required
  vm_id                  optional, skips name resolution
  target_container_name  optional, overrides --container for that VM
  recovered_vm_prefix         optional, overrides --recovered_vm_prefix for that VM

Updated: 9/9/26 - initial version
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

import monitor_core
from ahv_common import (add_auth_args, append_csv_row, banner, close_log, confirm,
                        connect_cdm, find_latest_csv, first_field, format_bytes,
                        init_incremental_csv, log, log_dir_for, now_hm, open_log,
                        parse_iso8601, prompt_if_missing, read_csv_rows,
                        run_timestamp, show_examples_if_bare, to_iso8601_z,
                        truncate_list, wave_name_from, write_csv)

# Defined in monitor_core so the monitor can patch resolved event series ids
# back into the wave-state CSV without importing this script.
def _utcnow():
    """
    Naive UTC now. datetime.utcnow() is deprecated from Python 3.12, and
    datetime.now(timezone.utc) is available from 3.2, so this stays inside
    the 3.6 floor while staying warning-free on modern interpreters.
    """
    return datetime.now(timezone.utc).replace(tzinfo=None)


WAVE_STATE_FIELDS = monitor_core.WAVE_STATE_FIELDS

EXCLUDED_FIELDS = ["vm_name", "vm_id", "reason"]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Trigger AHV (Nutanix) mass recovery -- export or live mount -- against a "
                    "Rubrik CDM cluster. Anything in the REQUIRED groups below is prompted "
                    "for interactively if omitted; --force turns a missing value into an "
                    "error instead.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  Dry run -- resolves everything, sends nothing:\n"
               "    %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 \\\n"
               "        --csv wave1.csv --method mount \\\n"
               "        --container default-container --recovered_vm_prefix dr- --dry_run\n"
               "\n"
               "  Live mount a wave and watch it finish, fully non-interactive:\n"
               "    %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 \\\n"
               "        --csv wave1.csv --method mount --point_in_time latest \\\n"
               "        --container default-container --recovered_vm_prefix dr- \\\n"
               "        --monitor --force\n"
               "\n"
               "  Export from a point in time (UTC):\n"
               "    %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 \\\n"
               "        --csv wave1.csv --method export \\\n"
               "        --point_in_time '2026-09-08 23:00:00' \\\n"
               "        --container default-container --recovered_vm_prefix dr- --force\n"
               "\n"
               "  Fully interactive:\n"
               "    %(prog)s\n",
    )

    add_auth_args(parser, title="REQUIRED -- authentication")

    req = parser.add_argument_group(
        "REQUIRED -- what to recover, and where it lands")
    req.add_argument("--csv", metavar="FILE",
                     help="Recovery wave CSV. This is what selects WHICH VMs are "
                          "recovered -- one row per VM, needs a vm_name or name column.")
    req.add_argument("--method", choices=["export", "mount"], default=None,
                     help="export = build new VMs from the snapshot. "
                          "mount = live mount (non-destructive, easy to unwind).")
    req.add_argument("--container", metavar="NAME",
                     help="Target storage container name. Per-VM override: the "
                          "target_container_name column in the wave CSV.")
    req.add_argument("--recovered_vm_prefix", metavar="PREFIX", default=None,
                     help="Prefix applied to the NAME of each recovered VM, so they are "
                          "distinguishable from production. CDM inserts its own hyphen, so "
                          "a prefix of 'dr' yields 'dr-myvm' -- do NOT add a trailing "
                          "hyphen or you get 'dr--myvm'. NOT a filter: use --csv to choose "
                          "which VMs to recover. Maps to vmNamePrefix in the CDM API. "
                          "Per-VM override: the recovered_vm_prefix column.")

    snap = parser.add_argument_group("snapshot selection")
    snap.add_argument("--point_in_time", metavar="TIME", default=None,
                      help="Recover from the newest snapshot at or before this UTC time. "
                           "Accepts latest, 'YYYY-MM-DD HH:MM:SS', or full "
                           "ISO-8601. (default: latest)")

    tgt = parser.add_argument_group("recovery target -- optional")
    tgt.add_argument("--nutanix_cluster", metavar="NAME", default=None,
                     help="Target AHV cluster name. (default: each VM's own AHV cluster)")
    tgt.add_argument("--migrate_immediately", action="store_true",
                     help="Live mount only: begin storage migration immediately")
    tgt.add_argument("--disable_migration", action="store_true",
                     help="Live mount only: disallow migration of the mounted VM")

    staged = parser.add_argument_group("staged lookups -- optional")
    staged.add_argument("--inventory", metavar="FILE",
                        help="AHV inventory CSV from get_ahv_inventory.py. Avoids the VM "
                             "listing calls. (default: newest match in inventory/)")
    staged.add_argument("--containers", metavar="FILE",
                        help="Storage container CSV from get_ahv_inventory.py. Avoids the "
                             "per-AHV-cluster container listing, measured at 5.3s on a cold "
                             "cache. (default: newest match in inventory/)")
    staged.add_argument("--no_auto_csv", action="store_true",
                        help="Do not auto-discover staged CSVs. Without this the newest "
                             "matching file is used and its age is reported.")

    mon = parser.add_argument_group("monitoring -- optional")
    mon.add_argument("--monitor", action="store_true",
                     help="Poll to terminal state after triggering. For long waves prefer "
                          "ahv_monitor_recovery.py, which is resumable.")
    mon.add_argument("--poll_interval", type=int, default=None, metavar="SEC",
                     help="Seconds between monitor polls (default: 30)")

    beh = parser.add_argument_group("behaviour -- optional")
    beh.add_argument("--dry_run", action="store_true",
                     help="Resolve everything and print the request bodies without POSTing")
    beh.add_argument("--force", "-f", action="store_true",
                     help="Skip the confirmation prompt and use default timings. Also makes "
                          "any missing required value an error rather than a prompt.")

    tun = parser.add_argument_group("tuning -- optional")
    tun.add_argument("--chunk_size", type=int, default=None, metavar="N",
                     help="VMs per batch API call (default: 25)")
    tun.add_argument("--timeout", type=int, default=None, metavar="SEC",
                     help="HTTP timeout in seconds (default: 300)")

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Input resolution
# ---------------------------------------------------------------------------

def read_wave_csv(csv_file):
    """Read the recovery wave list. Only a VM name is required per row."""
    rows = []
    for row in read_csv_rows(csv_file):
        name = first_field(row, "vm_name", "name", "vmname", "hostname")
        if not name:
            continue
        rows.append({
            "vm_name": name,
            "vm_id": first_field(row, "vm_id", "id"),
            "target_container_name": first_field(row, "target_container_name", "container"),
            "recovered_vm_prefix": first_field(row, "recovered_vm_prefix",
                                              "vm_name_prefix", "prefix"),
        })
    return rows


def load_inventory_map(csv_file):
    """lowercased vm_name -> {vm_id, nutanix_cluster_id, nutanix_cluster_name}."""
    mapping = {}
    for row in read_csv_rows(csv_file):
        name = first_field(row, "vm_name", "name")
        vm_id = first_field(row, "vm_id", "id")
        if name and vm_id:
            mapping[name.lower()] = {
                "vm_id": vm_id,
                "nutanix_cluster_id": first_field(row, "nutanix_cluster_id"),
                "nutanix_cluster_name": first_field(row, "nutanix_cluster_name"),
                "provisioned_bytes": first_field(row, "total_provisioned_bytes"),
            }
    return mapping


def resolve_point_in_time(value):
    """Return an ISO-8601 UTC 'Z' string for the closest_to_point_in_time call."""
    if not value or str(value).strip().lower() == "latest":
        return to_iso8601_z(_utcnow())

    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1]
    text = text.replace("T", " ")
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return to_iso8601_z(datetime.strptime(text, fmt))
        except ValueError:
            continue
    print("ERROR: could not parse --point_in_time '%s'. Use 'latest', "
          "'YYYY-MM-DD HH:MM:SS', or ISO-8601." % value)
    sys.exit(1)


def load_container_csv(csv_file):
    """
    Load a staged containers CSV from get_ahv_inventory.py.

    Returns the same three structures build_container_index() produces:
      containers          (nutanix_cluster_id, lowercased name) -> naturalId
      cluster_ids_by_name lowercased AHV cluster name -> nutanix_cluster_id
      display             lowercased container name -> original casing
    """
    containers = {}
    cluster_ids_by_name = {}
    display = {}
    for row in read_csv_rows(csv_file):
        cluster_id = first_field(row, "nutanix_cluster_id")
        cluster_name = first_field(row, "nutanix_cluster_name")
        name = first_field(row, "container_name")
        natural_id = first_field(row, "container_natural_id")
        if cluster_id and name and natural_id:
            containers[(cluster_id, name.lower())] = natural_id
            display[name.lower()] = name
        if cluster_name and cluster_id:
            cluster_ids_by_name[cluster_name.lower()] = cluster_id
    return containers, cluster_ids_by_name, display


def build_container_index(client, clusters):
    """
    (nutanix_cluster_id, lowercased container name) -> naturalId
    plus cluster name -> id for --nutanix_cluster.
    """
    containers = {}
    cluster_ids_by_name = {}
    display = {}
    for cluster in clusters:
        cluster_id = cluster.get("id")
        cluster_ids_by_name[(cluster.get("name") or "").lower()] = cluster_id
        try:
            for container in client.list_containers(cluster_id):
                name = container.get("name") or ""
                containers[(cluster_id, name.lower())] = container.get("naturalId", "")
                display[name.lower()] = name
        except Exception as e:
            log("  WARNING: could not list containers for %s: %s" % (cluster.get("name"), e))
    return containers, cluster_ids_by_name, display


# ---------------------------------------------------------------------------
# Trigger
# ---------------------------------------------------------------------------

def _pretty_time(value):
    """2026-09-06T11:03:44.222Z -> 2026-09-06 11:03:44 UTC."""
    stamp = parse_iso8601(value)
    if not stamp:
        return value or ""
    return stamp.strftime("%Y-%m-%d %H:%M:%S UTC")


def build_snapshot_payload(record, method, migrate_immediately, disable_migration):
    """One entry of the batch_export / batch_mount snapshots array."""
    if method == "export":
        return {
            "exportConfig": {
                "nutanixClusterId": record["nutanix_cluster_id"],
                "containerNaturalId": record["container_natural_id"],
            },
            "snapshotId": record["snapshot_id"],
            "vmId": record["vm_id"],
            "vmNamePrefix": record["recovered_vm_prefix"],
        }
    return {
        "mountConfig": {
            "shouldMigrateImmediately": bool(migrate_immediately),
            "vmNamePrefix": record["recovered_vm_prefix"],
            "shouldDisableMigration": bool(disable_migration),
            "nutanixClusterId": record["nutanix_cluster_id"],
            "containerNaturalId": record["container_natural_id"],
        },
        "snapshotId": record["snapshot_id"],
        "vmId": record["vm_id"],
        "vmNamePrefix": record["recovered_vm_prefix"],
    }


def trigger_batches(client, records, method, chunk_size, migrate_immediately,
                    disable_migration, state_path):
    """
    POST the wave in chunks. Records are updated in place with the returned
    jobInstanceId, and each is appended to the wave-state CSV as soon as its
    chunk returns -- so an interrupt still leaves a usable state file.
    """
    total = len(records)
    triggered = 0
    call = client.batch_export if method == "export" else client.batch_mount

    for start in range(0, total, chunk_size):
        chunk = records[start:start + chunk_size]
        batch_num = (start // chunk_size) + 1
        total_batches = (total + chunk_size - 1) // chunk_size
        log("  [%d/%d] (%s) Submitting %d VM(s)..."
            % (batch_num, total_batches, now_hm(), len(chunk)))

        payload = [build_snapshot_payload(r, method, migrate_immediately, disable_migration)
                   for r in chunk]
        by_vm = dict((r["vm_id"], r) for r in chunk)
        stamp = to_iso8601_z(_utcnow())

        try:
            response = call(payload)
        except Exception as e:
            log("  [%d/%d] (%s) Batch FAILED: %s" % (batch_num, total_batches, now_hm(), e))
            for record in chunk:
                record["triggered_at"] = stamp
                record["status"] = "failed"
                record["status_updated"] = stamp
                record["raw_status"] = "TriggerFailed"
                record["message"] = str(e)
                append_csv_row(state_path, WAVE_STATE_FIELDS, record)
            continue

        for item in response.get("successfulRequests") or []:
            record = by_vm.get(item.get("vmId"))
            if record is None:
                continue
            async_status = item.get("asyncRequestStatus") or {}
            record["job_instance_id"] = async_status.get("id", "")
            record["status_updated"] = stamp
            record["triggered_at"] = async_status.get("startTime") or stamp
            record["start_time"] = async_status.get("startTime") or stamp
            record["status"] = monitor_core.classify_status(async_status.get("status"))
            record["raw_status"] = async_status.get("status", "")
            record["message"] = ""
            triggered += 1

        for item in response.get("failedRequests") or []:
            record = by_vm.get(item.get("vmId"))
            if record is None:
                continue
            record["triggered_at"] = stamp
            record["status"] = "failed"
            record["status_updated"] = stamp
            record["raw_status"] = "TriggerFailed"
            record["message"] = json.dumps(item)[:500]

        for record in chunk:
            if not record.get("status"):
                record["triggered_at"] = stamp
                record["status"] = "failed"
                record["status_updated"] = stamp
                record["raw_status"] = "NotInResponse"
                record["message"] = "VM was not present in the batch response"
            append_csv_row(state_path, WAVE_STATE_FIELDS, record)

        log("  [%d/%d] (%s) %d succeeded, %d failed"
            % (batch_num, total_batches, now_hm(),
               len(response.get("successfulRequests") or []),
               len(response.get("failedRequests") or [])))

    return triggered


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()
    start = time.time()

    http_timeout = args.timeout if args.timeout is not None else 300
    chunk_size = args.chunk_size if args.chunk_size is not None else 25
    poll_interval = args.poll_interval if args.poll_interval is not None else 30

    print("\n" + "=" * 60)
    print("RUBRIK AHV MASS RECOVERY")
    print("=" * 60)

    show_examples_if_bare("ahv_mass_recovery.py", [
        ["# Dry run -- resolves everything, sends nothing",
         "python3 ahv_mass_recovery.py \\",
         "    --svc_json ~/rsc-sa.json --cluster 10.8.48.104 \\",
         "    --csv wave1.csv --method mount --point_in_time latest \\",
         "    --container default-container --recovered_vm_prefix dr- \\",
         "    --dry_run"],
        ["# For real, no prompts, watch it to completion",
         "python3 ahv_mass_recovery.py \\",
         "    --svc_json ~/rsc-sa.json --cluster 10.8.48.104 \\",
         "    --csv wave1.csv --method mount --point_in_time latest \\",
         "    --container default-container --recovered_vm_prefix dr- \\",
         "    --monitor --force"],
    ], note="--csv picks WHICH VMs. --recovered_vm_prefix only names the "
            "recovered copies.")

    csv_file = prompt_if_missing(args.csv, "Recovery wave CSV: ", required=True)
    csv_file = os.path.expanduser(csv_file)
    if not os.path.isfile(csv_file):
        print("ERROR: wave CSV not found: %s" % csv_file)
        sys.exit(1)

    method = args.method
    while method not in ("export", "mount"):
        method = input("Recovery method (export/mount): ").strip().lower()

    point_in_time = args.point_in_time
    if point_in_time is None and not args.force:
        point_in_time = input(
            "Point in time in UTC (blank for latest): ").strip() or "latest"
    before_date = resolve_point_in_time(point_in_time)

    wave = read_wave_csv(csv_file)
    if not wave:
        print("ERROR: no VM names found in %s" % csv_file)
        sys.exit(1)
    print("\nRead %d VM(s) from %s" % (len(wave), csv_file))

    # Validate the recovery target BEFORE connecting.
    #
    # Both of these used to surface as per-VM exclusions at the very end of
    # resolution, after the VM lookup, the snapshot call and the container
    # listing had already run -- so forgetting one flag cost the full round
    # trip just to be told nothing was recoverable. Check them up front.
    container_name = args.container
    if not container_name and not any(r["target_container_name"] for r in wave):
        if args.force:
            print("\nERROR: no target storage container.")
            print("       Pass --container, or add a target_container_name column to")
            print("       %s." % csv_file)
            sys.exit(1)
        container_name = input("Target storage container name: ").strip()
        if not container_name:
            print("ERROR: a target storage container is required.")
            sys.exit(1)

    recovered_prefix = args.recovered_vm_prefix
    if not recovered_prefix and not any(r["recovered_vm_prefix"] for r in wave):
        if args.force:
            print("\nERROR: no recovered VM name prefix.")
            print("       Pass --recovered_vm_prefix, or add a recovered_vm_prefix column")
            print("       to %s." % csv_file)
            sys.exit(1)
        recovered_prefix = input(
            "Prefix for recovered VM names (e.g. dr-): ").strip()
        if not recovered_prefix:
            print("ERROR: a recovered VM name prefix is required.")
            sys.exit(1)

    client, fqdn = connect_cdm(args, http_timeout)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = log_dir_for(__file__)
    timestamp = run_timestamp()
    wave_name = wave_name_from(csv_file)
    state_file = os.path.join(script_dir, "%s_state_%s.csv" % (wave_name, timestamp))
    excluded_file = os.path.join(log_dir, "%s_excluded_%s.csv" % (wave_name, timestamp))
    results_file = os.path.join(log_dir, "%s_results_%s.csv" % (wave_name, timestamp))
    activity_log = os.path.join(log_dir, "%s_recovery_log_%s.log" % (wave_name, timestamp))

    open_log(activity_log, [
        "AHV Mass Recovery Activity Log - %s" % time.strftime("%Y-%m-%d %H:%M:%S"),
        "Cluster: %s" % fqdn,
        "Method: %s, point in time: %s, chunk size: %d, timeout: %ds"
        % (method, before_date, chunk_size, http_timeout),
        "Wave CSV: %s" % csv_file,
        "Total VMs requested: %d" % len(wave),
    ])

    excluded = []

    # Staged CSVs from get_ahv_inventory.py. An explicit path always wins;
    # otherwise pick the newest match next to this script. Filenames are
    # timestamped, so requiring the full path every run means pasting a new
    # one each time -- but the chosen file and its age are always printed so a
    # stale inventory can never be used silently.
    if args.no_auto_csv:
        inventory_path = os.path.expanduser(args.inventory) if args.inventory else None
        containers_path = os.path.expanduser(args.containers) if args.containers else None
    else:
        inventory_path = find_latest_csv(__file__, "*_inventory_*.csv",
                                         "inventory CSV", explicit=args.inventory)
        containers_path = find_latest_csv(__file__, "*_containers_*.csv",
                                          "containers CSV", explicit=args.containers)
    if inventory_path or containers_path:
        print()

    try:
        # --- Resolve VM ids ---
        inventory = {}
        if inventory_path:
            inventory = load_inventory_map(inventory_path)
            log("(%s) Loaded %d VM(s) from inventory CSV" % (now_hm(), len(inventory)))

        need_lookup = [r for r in wave if not r["vm_id"] and r["vm_name"].lower() not in inventory]
        cluster_by_vm = {}
        if need_lookup:
            log("(%s) Listing AHV VMs to resolve %d name(s)..." % (now_hm(), len(need_lookup)))
            for vm in client.list_nutanix_vms():
                inventory.setdefault((vm.get("name") or "").lower(), {
                    "vm_id": vm.get("id", ""),
                    "nutanix_cluster_id": vm.get("nutanixClusterId", ""),
                    "nutanix_cluster_name": vm.get("nutanixClusterName", ""),
                })
        for vm in inventory.values():
            if vm.get("vm_id"):
                cluster_by_vm[vm["vm_id"]] = vm.get("nutanix_cluster_id", "")

        records = []
        not_resolved_count = 0
        for row in wave:
            entry = inventory.get(row["vm_name"].lower(), {})
            vm_id = row["vm_id"] or entry.get("vm_id", "")
            if not vm_id:
                not_resolved_count += 1
                excluded.append({"vm_name": row["vm_name"], "vm_id": "",
                                 "reason": "VM not found on cluster"})
                continue
            records.append({
                "vm_name": row["vm_name"],
                "vm_id": vm_id,
                "method": method,
                "nutanix_cluster_id": entry.get("nutanix_cluster_id",
                                                cluster_by_vm.get(vm_id, "")),
                "target_container_name": row["target_container_name"] or container_name or "",
                "recovered_vm_prefix": row["recovered_vm_prefix"] or recovered_prefix or "",
                "provisioned_bytes": entry.get("provisioned_bytes", ""),
                "snapshot_id": "", "snapshot_date": "", "container_natural_id": "",
                "job_instance_id": "", "event_series_id": "", "status_updated": "",
                "triggered_at": "", "message": "", "status": "", "raw_status": "",
                "progress_pct": "", "start_time": "", "end_time": "",
                "duration_seconds": "", "logical_size_bytes": "",
                "data_transferred_bytes": "", "throughput_bytes_per_sec": "",
            })

        if not records:
            log("ERROR: none of the requested VMs could be resolved on the cluster.")
            sys.exit(1)

        # High-level picture before any of the heavy lifting, so the operator
        # can sanity check scope and target before a single VM is touched.
        wave_bytes = 0
        sized = 0
        for record in records:
            try:
                wave_bytes += int(record.get("provisioned_bytes") or 0)
                if record.get("provisioned_bytes"):
                    sized += 1
            except (TypeError, ValueError):
                pass

        for line in banner("RECOVERY WAVE"):
            log(line)
        log("  Wave CSV:                  %s" % csv_file)
        log("  VMs in wave:               %d" % len(records))
        if not_resolved_count:
            log("  Not found on cluster:      %d" % not_resolved_count)
        if sized:
            suffix = "" if sized == len(records) else "  (%d of %d VMs sized)" % (
                sized, len(records))
            log("  Total provisioned:         %s%s" % (format_bytes(wave_bytes), suffix))
        elif inventory_path:
            log("  Total provisioned:         not in the inventory CSV -- rebuild it with")
            log("                             get_ahv_inventory.py --detail for disk sizes")
        else:
            log("  Total provisioned:         unknown (no inventory CSV in play)")
        log("  Method:                    %s" % method)
        log("  Point in time (UTC):       %s" % before_date)
        log("  Target container:          %s" % (container_name or "per-VM from the CSV"))
        log("  Recovered VM prefix:       %s" % (recovered_prefix or "per-VM from the CSV"))
        log("  Cluster:                   %s" % fqdn)

        # --- Resolve snapshots ---
        log("")
        log("(%s) Resolving snapshots at or before %s..." % (now_hm(), before_date))

        # The API resolves snapshots for a whole chunk in one call, so progress
        # is reported per chunk on the way out and per VM on the way back.
        total = len(records)
        chunks = (total + chunk_size - 1) // chunk_size
        width = min(34, max(len(r["vm_name"]) for r in records))

        snapshots = {}
        ids = [r["vm_id"] for r in records]
        for i in range(0, len(ids), chunk_size):
            batch = ids[i:i + chunk_size]
            log("  [chunk %d/%d] (%s) Requesting snapshots for %d VM(s)..."
                % ((i // chunk_size) + 1, chunks, now_hm(), len(batch)))
            for snap in client.closest_to_point_in_time(batch, before_date):
                snapshots[snap.get("snappableId")] = snap

        kept = []
        for index, record in enumerate(records, 1):
            label = record["vm_name"][:width].ljust(width)
            snap = snapshots.get(record["vm_id"])
            if not snap:
                log("  [%d/%d] %s  NO SNAPSHOT at or before %s"
                    % (index, total, label, before_date))
                excluded.append({"vm_name": record["vm_name"], "vm_id": record["vm_id"],
                                 "reason": "No snapshot at or before %s" % before_date})
                continue
            record["snapshot_id"] = snap.get("snapshotId", "")
            record["snapshot_date"] = snap.get("snapshotDate", "")
            log("  [%d/%d] %s  snapshot %s" % (
                index, total, label, _pretty_time(record["snapshot_date"])))
            kept.append(record)
        records = kept
        log("  Found snapshots for %d of %d VM(s)" % (len(records), total))

        # --- Resolve target cluster and container ---
        #
        # Prefer a staged containers CSV. The per-AHV-cluster container listing
        # is a Prism passthrough and was measured at 5.3s on a cold cache, so
        # skipping it is worth doing -- but only when the staged file actually
        # covers every container this wave targets. Anything it misses falls
        # through to a live lookup, so a stale file degrades rather than fails.
        log("")
        log("(%s) Resolving target AHV cluster and storage container..." % now_hm())

        containers = {}
        cluster_ids_by_name = {}
        container_display = {}
        if containers_path:
            containers, cluster_ids_by_name, container_display = \
                load_container_csv(containers_path)
            log("  Loaded %d container(s) across %d AHV cluster(s) from the staged CSV"
                % (len(containers), len(cluster_ids_by_name)))

        staged_cluster_ids = set(cid for (cid, _name) in containers.keys())
        override_cluster_id = None
        if args.nutanix_cluster:
            override_cluster_id = cluster_ids_by_name.get(args.nutanix_cluster.lower())
        elif len(staged_cluster_ids) == 1:
            override_cluster_id = list(staged_cluster_ids)[0]

        needed = set()
        for record in records:
            cluster_id = override_cluster_id or record.get("nutanix_cluster_id")
            container_name = record["target_container_name"] or ""
            if cluster_id and container_name:
                needed.add((cluster_id, container_name.lower()))

        need_live = (not containers) or any(key not in containers for key in needed)
        if args.nutanix_cluster and not override_cluster_id:
            need_live = True
        if not override_cluster_id and not args.nutanix_cluster:
            if not all(r.get("nutanix_cluster_id") for r in records):
                need_live = True

        clusters = []
        if need_live:
            if containers:
                log("  Staged CSV does not cover every target -- querying the cluster")
            clusters = client.list_nutanix_clusters()
            live_containers, live_names, live_display = build_container_index(
                client, clusters)
            merged = dict(containers)
            merged.update(live_containers)
            containers = merged
            merged_names = dict(cluster_ids_by_name)
            merged_names.update(live_names)
            cluster_ids_by_name = merged_names
            merged_display = dict(container_display)
            merged_display.update(live_display)
            container_display = merged_display
        else:
            log("  Resolved entirely from the staged CSV -- no container API calls")

        if args.nutanix_cluster:
            override_cluster_id = cluster_ids_by_name.get(args.nutanix_cluster.lower())
            if not override_cluster_id:
                available = sorted(cluster_ids_by_name.keys()) or \
                    [c.get("name", "") for c in clusters]
                log("ERROR: AHV cluster '%s' not found. Available: %s"
                    % (args.nutanix_cluster, ", ".join(available)))
                sys.exit(1)
        elif override_cluster_id is None and len(clusters) == 1:
            override_cluster_id = clusters[0].get("id")

        if container_name and container_name.lower() not in container_display:
            available = sorted(container_display.values())
            log("")
            log("ERROR: storage container '%s' was not found on any AHV cluster."
                % container_name)
            if available:
                log("       Available containers:")
                for name in available:
                    log("         %s" % name)
            sys.exit(1)

        kept = []
        for record in records:
            cluster_id = override_cluster_id or record.get("nutanix_cluster_id")
            if not cluster_id:
                excluded.append({"vm_name": record["vm_name"], "vm_id": record["vm_id"],
                                 "reason": "Could not determine target AHV cluster"})
                continue
            record["nutanix_cluster_id"] = cluster_id

            container_name = record["target_container_name"]
            if not container_name:
                excluded.append({"vm_name": record["vm_name"], "vm_id": record["vm_id"],
                                 "reason": "No target container (use --container or the "
                                           "target_container_name column)"})
                continue

            natural_id = containers.get((cluster_id, container_name.lower()))
            if not natural_id:
                excluded.append({"vm_name": record["vm_name"], "vm_id": record["vm_id"],
                                 "reason": "Container '%s' not found on the target AHV cluster"
                                           % container_name})
                continue
            record["container_natural_id"] = natural_id

            if not record["recovered_vm_prefix"]:
                excluded.append({"vm_name": record["vm_name"], "vm_id": record["vm_id"],
                                 "reason": "No recovered VM name prefix (use "
                                           "--recovered_vm_prefix or the "
                                           "recovered_vm_prefix column)"})
                continue
            kept.append(record)
        records = kept

        # --- Preview ---
        log("")
        for line in banner("RECOVERY PREVIEW"):
            log(line)
        log("  Method:                    %s" % method)
        log("  Point in time (UTC):       %s" % before_date)
        log("  VMs ready to recover:      %d" % len(records))
        log("  VMs excluded:              %d" % len(excluded))
        if excluded:
            log("")
            log("  Excluded:")
            for line in truncate_list(
                    ["%s -- %s" % (e["vm_name"], e["reason"]) for e in excluded], indent="    "):
                log(line)
        if records:
            log("")
            log("  Ready (first 5):")
            for line in truncate_list(
                    ["%s -> %s-%s (snapshot %s)"
                     % (r["vm_name"], r["recovered_vm_prefix"], r["vm_name"],
                        _pretty_time(r["snapshot_date"]))
                     for r in records], indent="    "):
                log(line)

        if excluded:
            write_csv(excluded_file, EXCLUDED_FIELDS, excluded)
            log("")
            log("  Excluded CSV: %s" % excluded_file)

        if not records:
            log("")
            log("Nothing to recover. Exiting.")
            sys.exit(1)

        if args.dry_run:
            log("")
            for line in banner("DRY RUN -- REQUEST BODIES (nothing was sent)"):
                log(line)
            sample = records[:min(len(records), chunk_size)]
            payload = {"snapshots": [
                build_snapshot_payload(r, method, args.migrate_immediately,
                                       args.disable_migration) for r in sample]}
            endpoint = "batch_export" if method == "export" else "batch_mount"
            log("  POST /api/v1/nutanix/vm/%s   (chunk 1 of %d)"
                % (endpoint, (len(records) + chunk_size - 1) // chunk_size))
            for line in json.dumps(payload, indent=2).splitlines():
                log("  %s" % line)
            log("")
            log("Dry run complete. Re-run without --dry_run to trigger.")
            return

        if not args.force:
            log("")
            if not confirm("Proceed with %s for %d VM(s)? (yes/no): " % (method, len(records))):
                log("Aborted.")
                return

        # --- Trigger ---
        log("")
        for line in banner("TRIGGERING RECOVERY"):
            log(line)
        init_incremental_csv(state_file, WAVE_STATE_FIELDS)
        triggered = trigger_batches(client, records, method, chunk_size,
                                    args.migrate_immediately, args.disable_migration,
                                    state_file)

        log("")
        log("  Triggered %d of %d VM(s)" % (triggered, len(records)))
        log("  Wave state CSV: %s" % state_file)

        # --- Optional monitor ---
        if args.monitor and triggered:
            log("")
            for line in banner("MONITORING"):
                log(line)
            log("  Resolving event series (this can lag the trigger by a few seconds)...")
            time.sleep(5)
            init_incremental_csv(results_file, monitor_core.RESULT_FIELDS)
            try:
                monitor_core.monitor(client, records, poll_interval=poll_interval,
                                    results_path=results_file, state_path=state_file)
            except KeyboardInterrupt:
                log("")
                log("  Monitoring interrupted. Resume with:")
                log("    python3 ahv_monitor_recovery.py --svc_json <json> --cluster %s "
                    "--state %s" % (fqdn, state_file))
                raise
            for line in monitor_core.build_summary(records, time.time() - start):
                log(line)
            log("")
            log("  Results CSV: %s" % results_file)
        elif triggered:
            log("")
            log("  Not monitoring (pass --monitor, or run separately -- resumable):")
            log("    python3 ahv_monitor_recovery.py --svc_json <json> --cluster %s "
                "--state %s" % (fqdn, state_file))

        log("")
        log("  Activity log: %s" % activity_log)

    except KeyboardInterrupt:
        print("\n\n  Interrupted -- partial state saved.")
        sys.exit(1)
    finally:
        close_log()


if __name__ == "__main__":
    main()
