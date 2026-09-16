#!/usr/bin/env python3
"""
Rubrik AHV (Nutanix) VM Inventory

Walks every AHV VM known to a Rubrik CDM cluster and writes a per-VM
inventory CSV, plus a storage container reference CSV. The inventory CSV is
the input contract for ahv_mass_recovery.py: filter it down to a recovery
wave, fill in the two trailing target columns, and feed it straight back in.

The inventory CSV ends with two intentionally blank columns --
target_container_name and recovered_vm_prefix -- for the operator to populate.
Everything else is read from the cluster.

Data source note: this script uses the CDM REST API. The CDM VM detail
endpoint does NOT expose NICs, vCPU, memory, power state, or per-disk
storage container.

Of those, NICs, vCPU, memory and per-disk storage container DO exist in the
RSC GraphQL schema (NutanixVm.metadata.vmNics / numVcpus / memoryInMb, and
NutanixVmDisk.storageContainerId), and an RSC GraphQL backend is planned as
the default source -- see "PLANNED: RSC GraphQL backend" below.

Power state is NOT available from either source. It was verified absent from
NutanixVm in the RSC schema; powerStatus exists only on mount-side types
(NutanixLiveMount, NutanixVmMountSummary). Guest IP and MAC addresses are
likewise unavailable from both.

Both CSVs are written to an inventory/ subfolder beside this script, so
generated files stay out of the way, and each is also copied to a stable
<prefix>_inventory_latest.csv / <prefix>_containers_latest.csv.

ahv_mass_recovery.py auto-discovers the newest timestamped file. The Ansible
role does not auto-discover, so point ahv_inventory_csv and ahv_containers_csv
at the _latest.csv copies -- those paths never go stale.

Usage examples:
  # Fully interactive (prompts for everything)
  python3 get_ahv_inventory.py

  # Basic inventory from the VM list endpoint only (one paginated call)
  python3 get_ahv_inventory.py --svc_json rsc-sa.json --cluster 10.8.48.104

  # Add per-VM disk detail (one extra GET per VM, run in parallel)
  python3 get_ahv_inventory.py --svc_json rsc-sa.json --cluster 10.8.48.104 --detail

  # Include relics (deleted VMs that still have snapshots)
  python3 get_ahv_inventory.py --svc_json rsc-sa.json --cluster 10.8.48.104 --include_relics

  # Slow cluster -- longer timeout, fewer parallel detail calls
  python3 get_ahv_inventory.py --svc_json rsc-sa.json --cluster 10.8.48.104 --detail --timeout 300 --parallel 4

PLANNED: RSC GraphQL backend
  A --source rsc|cdm flag will select the backend, defaulting to rsc. The RSC
  GraphQL nutanixVms query returns in a single paginated call what CDM needs
  N+1 calls for, and additionally returns vmNics (networkName, networkUuid),
  numVcpus, memoryInMb, and per-disk storageContainerId/storageContainerName.
  The CDM columns below stay identical so both backends produce a CSV that
  the recovery scripts can consume; GraphQL-only columns will be blank in CDM
  mode. The RSC path needs its own auth (service account access_token_uri ->
  /api/client_token -> /api/graphql) and must emit the CDM-form vm_id, since
  RSC identifies VMs by FID while CDM recovery needs
  NutanixVirtualMachine:::<clusterUuid>-vm-<vmUuid>.

  Note when implementing: that <clusterUuid> is the UUID segment of the
  Nutanix cluster's CDM id (NutanixCluster:::<uuid>), NOT its naturalId.
  Those are different values -- in the reference capture the cluster CDM id
  is NutanixCluster:::21fb4363-... while its naturalId is 0005f79a-..., and
  it is 21fb4363 that appears inside every VM id. Building ids from
  naturalId produces ids that do not resolve.

Updated: 9/9/26 - initial version
"""

import argparse
import concurrent.futures
import os
import sys
import time

from ahv_common import (add_auth_args, banner, close_log, connect_cdm, format_bytes,
                        inventory_dir_for, log, log_dir_for, now_hm, open_log,
                        run_timestamp, show_examples_if_bare, write_csv)

INVENTORY_FIELDS = [
    "vm_name",
    "vm_id",
    "nutanix_cluster_name",
    "nutanix_cluster_id",
    "operating_system_type",
    "agent_connect_status",
    "is_relic",
    "effective_sla_domain_name",
    "effective_sla_domain_id",
    "sla_assignment",
    "snapshot_consistency_mandate",
    # --detail only
    "is_paused",
    "is_agent_registered",
    "excluded_disk_ids",
    "disk_count",
    "total_provisioned_bytes",
    "total_provisioned_gib",
    "disk_labels",
    "disk_uuids",
    # operator-populated recovery targets
    "target_container_name",
    "recovered_vm_prefix",
]

CONTAINER_FIELDS = [
    "nutanix_cluster_name",
    "nutanix_cluster_id",
    "container_name",
    "container_natural_id",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build a Rubrik AHV (Nutanix) VM inventory CSV from a CDM cluster. "
                    "Any argument not provided will be prompted for interactively.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 --detail\n"
               "  %(prog)s --svc_json rsc-sa.json --cluster 10.8.48.104 --include_relics --detail\n"
               "  %(prog)s   (fully interactive)\n",
    )

    add_auth_args(parser)

    parser.add_argument("--detail", action="store_true",
                        help="Fetch per-VM detail (disks, excluded disks, paused state). "
                             "Costs one extra GET per VM.")
    parser.add_argument("--include_relics", action="store_true",
                        help="Include relic VMs (deleted but still holding snapshots)")
    parser.add_argument("--output_prefix", metavar="PREFIX", default=None,
                        help="Output filename prefix. The report name and timestamp are "
                             "appended automatically (default: ahv)")
    parser.add_argument("--parallel", type=int, default=None, metavar="N",
                        help="Max concurrent detail calls (default: 8)")
    parser.add_argument("--timeout", type=int, default=None, metavar="SEC",
                        help="HTTP timeout in seconds (default: 150)")
    parser.add_argument("--force", "-f", action="store_true",
                        help="Skip prompts and use defaults")

    return parser.parse_args()


def build_container_rows(client, clusters):
    """Storage containers for every AHV cluster, for target lookup."""
    rows = []
    for cluster in clusters:
        cluster_id = cluster.get("id")
        cluster_name = cluster.get("name", "")
        try:
            containers = client.list_containers(cluster_id)
        except Exception as e:
            log("  WARNING: could not list containers for %s: %s" % (cluster_name, e))
            continue
        for container in containers:
            rows.append({
                "nutanix_cluster_name": cluster_name,
                "nutanix_cluster_id": cluster_id,
                "container_name": container.get("name", ""),
                "container_natural_id": container.get("naturalId", ""),
            })
    return rows


def summary_row(vm):
    """Map a CDM VM summary object onto the inventory columns."""
    agent = vm.get("agentStatus") or {}
    return {
        "vm_name": vm.get("name", ""),
        "vm_id": vm.get("id", ""),
        "nutanix_cluster_name": vm.get("nutanixClusterName", ""),
        "nutanix_cluster_id": vm.get("nutanixClusterId", ""),
        "operating_system_type": vm.get("operatingSystemType", ""),
        "agent_connect_status": vm.get("agentConnectStatus") or agent.get("agentStatus", ""),
        "is_relic": vm.get("isRelic", ""),
        "effective_sla_domain_name": vm.get("effectiveSlaDomainName", ""),
        "effective_sla_domain_id": vm.get("effectiveSlaDomainId", ""),
        "sla_assignment": vm.get("slaAssignment", ""),
        "snapshot_consistency_mandate": vm.get("snapshotConsistencyMandate", ""),
        "is_paused": "",
        "is_agent_registered": "",
        "excluded_disk_ids": "",
        "disk_count": "",
        "total_provisioned_bytes": "",
        "total_provisioned_gib": "",
        "disk_labels": "",
        "disk_uuids": "",
        "target_container_name": "",
        "recovered_vm_prefix": "",
    }


def apply_detail(row, detail):
    """Merge GET /internal/nutanix/vm/{id} fields into an inventory row."""
    row["is_paused"] = detail.get("isPaused", "")
    row["is_agent_registered"] = detail.get("isAgentRegistered", "")
    row["excluded_disk_ids"] = ";".join(detail.get("excludedDiskIds") or [])

    disks = detail.get("virtualDisks") or []
    # Only DISK devices carry capacity; CDROM entries have no sizeInBytes.
    sized = [d for d in disks if d.get("sizeInBytes")]
    total = sum(int(d.get("sizeInBytes") or 0) for d in sized)

    row["disk_count"] = len(sized)
    row["total_provisioned_bytes"] = total
    row["total_provisioned_gib"] = "%.2f" % (total / float(1024 ** 3)) if total else "0.00"
    row["disk_labels"] = ";".join(d.get("label", "") for d in disks if d.get("label"))
    row["disk_uuids"] = ";".join(d.get("vmDiskUuid", "") for d in disks if d.get("vmDiskUuid"))
    return row


def fetch_details(client, rows, max_workers):
    """Parallel per-VM detail fetch. Failures downgrade to a warning."""
    total = len(rows)
    done = [0]
    failed = [0]

    def _one(row):
        try:
            detail = client.get_nutanix_vm(row["vm_id"])
            apply_detail(row, detail)
        except Exception as e:
            failed[0] += 1
            log("  (%s) %s - detail fetch failed: %s" % (now_hm(), row["vm_name"], e))
        finally:
            done[0] += 1
            if done[0] % 25 == 0 or done[0] == total:
                log("  (%s) Detail fetched for %d of %d VM(s)" % (now_hm(), done[0], total))

    workers = min(max_workers, max(1, total))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(_one, row) for row in rows]
        try:
            for future in concurrent.futures.as_completed(futures):
                future.result()
        except KeyboardInterrupt:
            pool.shutdown(wait=True)
            raise

    return failed[0]


def main():
    args = parse_args()
    start = time.time()

    http_timeout = args.timeout if args.timeout is not None else 150
    max_workers = args.parallel if args.parallel is not None else 8
    prefix = args.output_prefix if args.output_prefix else "ahv"

    print("\n" + "=" * 60)
    print("RUBRIK AHV VM INVENTORY")
    print("=" * 60)

    show_examples_if_bare("get_ahv_inventory.py", [
        ["# Inventory every AHV VM, including disk detail",
         "python3 get_ahv_inventory.py \\",
         "    --svc_json ~/rsc-sa.json --cluster 10.8.48.104 --detail"],
        ["# Include relics, skip all prompts",
         "python3 get_ahv_inventory.py \\",
         "    --svc_json ~/rsc-sa.json --cluster 10.8.48.104 \\",
         "    --detail --include_relics --force"],
    ], note="Output lands in inventory/ and is picked up automatically by "
            "ahv_mass_recovery.py.")

    client, fqdn = connect_cdm(args, http_timeout)

    inventory_dir = inventory_dir_for(__file__)
    log_dir = log_dir_for(__file__)
    timestamp = run_timestamp()

    inventory_file = os.path.join(inventory_dir, "%s_inventory_%s.csv" % (prefix, timestamp))
    containers_file = os.path.join(inventory_dir, "%s_containers_%s.csv" % (prefix, timestamp))
    activity_log = os.path.join(log_dir, "%s_inventory_log_%s.log" % (prefix, timestamp))

    print("  Inventory CSV:  %s" % inventory_file)
    print("  Containers CSV: %s" % containers_file)
    print("  Activity log:   %s" % activity_log)
    print()

    open_log(activity_log, [
        "AHV Inventory Activity Log - %s" % time.strftime("%Y-%m-%d %H:%M:%S"),
        "Cluster: %s" % fqdn,
        "Detail mode: %s, include relics: %s, parallel: %d, timeout: %ds"
        % (args.detail, args.include_relics, max_workers, http_timeout),
    ])

    try:
        # --- AHV clusters and storage containers ---
        log("(%s) Listing AHV clusters..." % now_hm())
        try:
            clusters = client.list_nutanix_clusters()
        except Exception as e:
            log("ERROR: could not list AHV clusters: %s" % e)
            sys.exit(1)
        log("  Found %d AHV cluster(s)" % len(clusters))

        container_rows = build_container_rows(client, clusters)
        write_csv(containers_file, CONTAINER_FIELDS, container_rows)
        log("  Wrote %d storage container(s)" % len(container_rows))

        # --- VMs ---
        log("")
        log("(%s) Listing AHV VMs (this can take a while on large clusters)..." % now_hm())
        try:
            vms = client.list_nutanix_vms(include_relics=args.include_relics)
        except Exception as e:
            log("ERROR: could not list AHV VMs: %s" % e)
            sys.exit(1)
        log("  Found %d AHV VM(s)" % len(vms))

        rows = [summary_row(vm) for vm in vms]
        rows.sort(key=lambda r: (r["nutanix_cluster_name"], r["vm_name"].lower()))

        detail_failures = 0
        if args.detail and rows:
            log("")
            log("(%s) Fetching per-VM detail with %d worker(s)..." % (now_hm(), max_workers))
            detail_failures = fetch_details(client, rows, max_workers)

        write_csv(inventory_file, INVENTORY_FIELDS, rows)

        # Stable-named copies. The timestamped files are the audit trail; these
        # give the Ansible role (which does not auto-discover) a fixed path that
        # does not go stale every time the inventory is rebuilt.
        latest_inventory = os.path.join(inventory_dir, "%s_inventory_latest.csv" % prefix)
        latest_containers = os.path.join(inventory_dir, "%s_containers_latest.csv" % prefix)
        write_csv(latest_inventory, INVENTORY_FIELDS, rows)
        write_csv(latest_containers, CONTAINER_FIELDS, container_rows)

        # --- Summary ---
        total_bytes = sum(int(r["total_provisioned_bytes"] or 0)
                          for r in rows if r["total_provisioned_bytes"])

        lines = banner("SUMMARY")
        lines.append("  AHV clusters:              %d" % len(clusters))
        lines.append("  Storage containers:        %d" % len(container_rows))
        lines.append("  AHV VMs:                   %d" % len(rows))
        if args.detail:
            lines.append("  Detail fetch failures:     %d" % detail_failures)
            lines.append("  Total provisioned:         %s" % format_bytes(total_bytes))
        else:
            lines.append("  Detail:                    skipped (pass --detail for disk data)")
        lines.append("  Total run time:            %s" % _elapsed(start))
        lines.append("")
        lines.append("  Inventory CSV:  %s" % inventory_file)
        lines.append("  Containers CSV: %s" % containers_file)
        lines.append("  Stable copies:  %s" % os.path.basename(latest_inventory))
        lines.append("                  %s" % os.path.basename(latest_containers))
        lines.append("  Activity log:   %s" % activity_log)
        # Emit a copy-pasteable next command using this run's real values --
        # cluster, credentials, and an actual container name off the cluster --
        # so nothing has to be typed at a prompt.
        svc = args.svc_json if args.svc_json else "<service-account>.json"
        sample_container = _suggest_container(container_rows)

        lines.append("")
        lines.append("  Next: copy the inventory CSV to a wave file, delete the rows you do not")
        lines.append("  want, and fill in target_container_name and recovered_vm_prefix. Or pass")
        lines.append("  --container and --recovered_vm_prefix and leave those columns blank.")
        lines.append("")
        lines.append("  Containers available on %s:" % (clusters[0].get("name", "the AHV cluster")
                                                        if clusters else "the AHV cluster"))
        for row in container_rows[:6]:
            lines.append("    %s" % row["container_name"])
        lines.append("")
        lines.append("  Dry run (resolves everything, sends nothing):")
        lines.append("    python3 ahv_mass_recovery.py \\")
        lines.append("        --svc_json %s --cluster %s \\" % (svc, fqdn))
        lines.append("        --csv wave1.csv \\")
        lines.append("        --method mount \\")
        lines.append("        --point_in_time latest \\")
        lines.append("        --container %s \\" % sample_container)
        lines.append("        --recovered_vm_prefix dr \\")
        lines.append("        --dry_run")
        lines.append("")
        lines.append("  For real, fully non-interactive (--force skips the confirmation):")
        lines.append("    python3 ahv_mass_recovery.py \\")
        lines.append("        --svc_json %s --cluster %s \\" % (svc, fqdn))
        lines.append("        --csv wave1.csv \\")
        lines.append("        --method mount \\")
        lines.append("        --point_in_time latest \\")
        lines.append("        --container %s \\" % sample_container)
        lines.append("        --recovered_vm_prefix dr \\")
        lines.append("        --monitor --force")
        lines.append("")
        lines.append("  The inventory and container CSVs above are picked up automatically.")
        lines.append("  --point_in_time also takes a UTC time, e.g. \"2026-09-08 23:00:00\".")

        for line in lines:
            log(line)

    except KeyboardInterrupt:
        print("\n\n  Interrupted.")
        sys.exit(1)
    finally:
        close_log()


def _suggest_container(container_rows):
    """
    Pick a plausible target container for the example command. Prefers one
    that looks like a general VM datastore over ISO or system shares, which
    are never sensible recovery targets.
    """
    if not container_rows:
        return "<container-name>"
    names = [r["container_name"] for r in container_rows if r.get("container_name")]
    if not names:
        return "<container-name>"
    skip = ("iso", "template", "managementshare", "selfservice")
    for name in names:
        if "default" in name.lower():
            return name
    for name in names:
        if not any(s in name.lower().replace("_", "").replace("-", "") for s in skip):
            return name
    return names[0]


def _elapsed(start):
    seconds = int(time.time() - start)
    return "%dm %ds" % (seconds // 60, seconds % 60)


if __name__ == "__main__":
    main()
