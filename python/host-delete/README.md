HOW TO USE -- CDM Host & RSC Fileset Delete Scripts
====================================================

Scripts for bulk-deleting hosts and filesets from Rubrik clusters.

Files:
  cdm_client.py                      Shared CDM REST client. Not run directly.
  cdm_delete_hosts.py                Delete hosts from a CDM cluster (CDM REST API).
  rsc_delete_filesets.py             Delete filesets via RSC GraphQL API.
  hosts_to_delete_example.csv        Example CSV for cdm_delete_hosts.py.
  rsc_filesets_to_delete_example.csv Example CSV for rsc_delete_filesets.py.

Requires Python 3. No third-party packages needed.

All output files are saved to a logs/ subdirectory (created automatically).


IMPORTANT -- HOW HOST DELETION DIFFERS FROM THE TWO-PHASE SCRIPTS
------------------------------------------------------------------
Deleting a host via cdm_delete_hosts.py does NOT delete its snapshots
immediately. Snapshots move to Unmanaged Objects and expire later, on
their original SLA's retention schedule. There is no supported CDM API
to force-purge them sooner once they're there.

Use cdm_delete_hosts.py if you're fine with snapshots aging out naturally.

If you need snapshots deleted immediately (space freed right away), use
'rsc_delete_filesets.py'. This will go through and delete all Filesets
contained in the hosts CSV list with the default option to expire all
snapshots immediately. You can then go through and clean up the hosts later.


========================================================================
cdm_delete_hosts.py -- CDM Host Delete
========================================================================

Deletes hosts directly against a CDM cluster's local REST API.

BEFORE YOU START
-----------------
You'll need:
  - CDM cluster FQDN or IP address
  - Either:
    (a) An RSC Service Account JSON file (contains client_id, client_secret)
    (b) A Service Account Client ID and Secret

Input CSV must have a "name" or "hostname" column:

  name
  linux-server-01.example.com
  win-app-02.example.com

See hosts_to_delete_example.csv for a sample.

RUNNING IT
-----------
Supports both CLI arguments and interactive prompts. Any argument not
provided on the command line will be prompted for.

  # Fully interactive
  python3 cdm_delete_hosts.py

  # Non-interactive with Service Account JSON
  python3 cdm_delete_hosts.py \
    --svc_json rsc-sa.json \
    --cluster 10.8.48.104 \
    --csv hosts.csv \
    --force

  # Non-interactive with direct credentials
  python3 cdm_delete_hosts.py \
    --cluster 10.8.48.104 \
    --svc_client_id "abc-123" \
    --svc_secret "my-secret" \
    --csv hosts.csv \
    --force

  # Hybrid -- provide some args, prompt for the rest
  python3 cdm_delete_hosts.py --svc_json rsc-sa.json --csv hosts.csv

CLI arguments:

  Authentication:
    --svc_json FILE       Service Account JSON file
    --cluster FQDN        CDM cluster FQDN or IP
    --svc_client_id ID    Service Account Client ID (alt to --svc_json)
    --svc_secret SECRET   Service Account Secret (alt to --svc_json)

  Input:
    --csv FILE            CSV file with hostnames

  Tuning:
    --batch-size N        Hosts per batch (default 50, max 100)
    --batch-delay SEC     Delay between batches (default 2s)
    --verify-retries N    Max verification retries (default 3)
    --verify-delay SEC    Delay between retries (default 10s)
    --initial-wait SEC    Wait before verification (default 10s)

  Other:
    --force, -f           Skip confirmation and all timing prompts
                          (uses defaults: batch-size=50, batch-delay=2,
                          verify-retries=3, verify-delay=10, initial-wait=10)

What it does:
  1. Connects and fetches the full host list from the cluster once, then
     resolves each hostname in your CSV to its host ID. Hostnames not
     found on the cluster are skipped and written to a separate CSV.
  2. Prints a preview of matched hosts and requires you to type "yes" to
     confirm before deleting anything (unless --force is used).
  3. Deletes hosts in batches via the CDM bulk-delete endpoint. If a
     batch fails, it falls back to deleting that batch's hosts one at a
     time. (Batch size is capped at 100 because the bulk-delete call
     waits up to ~300s for all jobs in a batch and fails the whole batch
     if any single host ID in it is invalid.)
  4. Waits, then re-checks the cluster's host list to verify each host
     was actually removed, retrying a few times for hosts still pending.
  5. Writes output files to logs/:
       host_delete_results_<timestamp>.csv  - id, name, status, message,
                                               verified
       hosts_not_found_<timestamp>.csv      - hostnames from your input
                                               CSV that didn't match any
                                               host on the cluster (only
                                               written if there were any)


========================================================================
rsc_delete_filesets.py -- RSC Fileset Delete
========================================================================

Deletes filesets for specified hosts via the RSC GraphQL API. For each
host in the input CSV, queries RSC for all its filesets (Linux and
Windows), then deletes them in batches using the bulkDeleteFileset
mutation.

By default, snapshots are expired immediately. Pass --preserve-snapshots
to keep them in Unmanaged Objects instead.

BEFORE YOU START
-----------------
You'll need:
  - Either:
    (a) An RSC Service Account JSON file (contains client_id, client_secret,
        access_token_uri)
    (b) RSC URL, Service Account Client ID, and Secret

Input CSV must have "name" (or "hostname") and "cluster" columns:

  name,cluster
  rp-iris-prod.perf.rubrik.com,vault-r-madison

See rsc_filesets_to_delete_example.csv for a sample.

RUNNING IT
-----------
  # Fully interactive
  python3 rsc_delete_filesets.py

  # Non-interactive with Service Account JSON
  python3 rsc_delete_filesets.py \
    --svc_json rsc-sa.json \
    --csv hosts.csv \
    --force

  # Non-interactive with direct credentials
  python3 rsc_delete_filesets.py \
    --rsc_url rubrik-gaia.my.rubrik.com \
    --svc_client_id "abc-123" \
    --svc_secret "my-secret" \
    --csv hosts.csv \
    --force

  # Hybrid -- provide some args, prompt for the rest
  python3 rsc_delete_filesets.py --svc_json rsc-sa.json --csv hosts.csv

  # Preserve snapshots instead of expiring
  python3 rsc_delete_filesets.py \
    --svc_json rsc-sa.json \
    --csv hosts.csv \
    --preserve-snapshots --force

  # Re-run using a previously-saved host inventory (skips RSC host lookup)
  python3 rsc_delete_filesets.py \
    --svc_json rsc-sa.json \
    --csv hosts.csv \
    --host_inventory linux_host_inventory_20260826_143012.csv \
    --force

  # Slow environment -- increase timeout, reduce parallelism
  python3 rsc_delete_filesets.py \
    --svc_json rsc-sa.json \
    --csv hosts.csv \
    --timeout 300 --parallel 2 \
    --force

  # High throughput -- max parallelism
  python3 rsc_delete_filesets.py \
    --svc_json rsc-sa.json \
    --csv hosts.csv \
    --parallel 8 \
    --force

CLI arguments:

  Authentication:
    --svc_json FILE       Service Account JSON file
    --rsc_url URL         RSC URL (e.g., rubrik-gaia.my.rubrik.com) (alt to --svc_json)
    --svc_client_id ID    Service Account Client ID (alt to --svc_json)
    --svc_secret SECRET   Service Account Secret (alt to --svc_json)

  Input:
    --csv FILE            CSV file with hostname and cluster columns
    --host_inventory FILE Previously-saved host inventory CSV (skips RSC
                          host lookup). Generated automatically on each run
                          as linux_host_inventory_<timestamp>.csv and
                          windows_host_inventory_<timestamp>.csv in the
                          script directory.

  Tuning:
    --parallel N          Max concurrent delete calls (default 4)
    --retries N           Max retries per fileset on timeout/5xx (default 3)
    --timeout SEC         HTTP timeout per API call (default 120s)

  Other:
    --force, -f           Skip confirmation and use defaults
    --preserve-snapshots  Preserve snapshots (default: expire immediately)

What it does:
  1. Authenticates to RSC using the Service Account JSON or direct credentials.
  2. Pulls the full host inventory from RSC (Linux + Windows host roots)
     with pagination and saves separate CSVs to the script directory:
       linux_host_inventory_<timestamp>.csv
       windows_host_inventory_<timestamp>.csv
     If --host_inventory is provided, loads the inventory from that CSV
     instead (skips the RSC lookup). Hosts already marked DELETED in the
     inventory are automatically skipped.
  3. Matches inventory hosts against the input CSV by hostname + cluster name,
     then queries RSC for each matched host's filesets. The inventory CSV
     is enriched with fileset_ids and fileset_names columns.
  4. Previews all matched hosts and filesets, then asks for confirmation.
  5. Deletes filesets in parallel (default 4 concurrent workers) via the
     bulkDeleteFileset GraphQL mutation (single ID per call). On timeout/5xx
     errors, retries up to 3 times (configurable) with 2s between retries.
     Ctrl+C saves partial results before exiting.
  6. Updates the inventory CSV with deletion status per host:
       DELETED  - all filesets for the host were successfully deleted
       PARTIAL  - some filesets deleted, some failed or not yet processed
     On re-run, DELETED hosts are skipped automatically.
  7. Writes output files:
       linux_host_inventory_<timestamp>.csv     - Linux host inventory (script dir)
       windows_host_inventory_<timestamp>.csv   - Windows host inventory (script dir)
       logs/fileset_delete_results_<timestamp>.csv  - per-fileset results
       logs/hosts_not_found_<timestamp>.csv         - unmatched CSV entries
