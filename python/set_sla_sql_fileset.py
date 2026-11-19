#!/usr/bin/env python3
"""
Title: set_sla_sql_fileset.py
Description: Assigns an SLA Domain to the SQL instances or filesets on a list of hosts in
Rubrik Security Cloud (RSC). Python port of the "-action Apply" path of
computer/Powershell/Set-SLA-SQL-Fileset.ps1. The timing test (-action Test) and the inventory
writers (-getSqlInventory / -getFilesetInventory) are not part of this script, they stay in the
PowerShell script, and this script can read the inventory CSVs they write (--inventory-csv).
Works against RSC-P and RSC (see SQL hosts on RSC-P and RSC below).

--assign (required, except with --check-apply-csv-status) chooses the workload: sqlOnly, filesetOnly or both.
With --assign both, ONE host list (--hosts or --host-csv-path) is used for SQL and for filesets, and
the run is two independent passes, SQL first and then filesets. Each pass resolves its objects, shows
its own plan, asks for its own confirmation, assigns, and writes its own Apply CSV. A failure in one pass does
not stop the other, and the exit code is 1 if either pass had a problem. The same host list is used for both, so
a host that is only a SQL host, or only a fileset host, is skipped (with the reason) in the other pass.

Author: Steven Tong
GitHub: stevenctong
Date: 11/17/26
Updated: 11/19/26

Requires Python 3.9+ and the 'requests' package.

How it works
- Finds the objects on the listed hosts, live from RSC or from an inventory CSV (--inventory-csv).
  For filesets, each host must have the fileset template (--fileset-name or --fileset-template-id)
  applied. The template must already exist and is never created or changed. Hosts that do not have
  it get it applied with bulkCreateFilesets (one call per cluster, after confirmation).
- Skips what it cannot or should not change, says which and why, and carries on with the rest: a host that
  cannot be used (see Skipped hosts below), an object with any pending SLA, and an object whose effective SLA is
  already the target. A rerun is therefore safe.
- Shows the plan and asks you to confirm with y or yes in any case (--dry-run shows the plan only, --skip-confirm skips the prompt).
- Writes the Apply CSV with the starting SLA of every object before changing anything, sends the
  assignments, then rewrites the same file with the outcomes. It is written twice per pass and not in between,
  so if the run is interrupted (Ctrl+C) while polling, the file still shows the starting state (every object
  Pending) even for assignments RSC already accepted. Nothing is reverted by an interrupt. Use
  --check-apply-csv-status afterwards to see where each object is now.
  --apply-mode Bulk (default) sends up to --batch-size objects per call, all on --cluster-name.
  --apply-mode Single sends one call per host. A failed call does not stop the remaining calls.
- Unless --skip-polling is used, polls every object until RSC shows the SLA, for up to --timeout-sec.
- Exits 1 if any call failed, timed out, was not attempted, or a template could not be applied.
  Nothing is reverted. The target SLA can also be DO_NOT_PROTECT or NO_ASSIGNMENT (--sla-name).

SLA per workload
- --sla-name (or --sla-id) is the SLA for every workload in the run. With --assign both, SQL and filesets
  usually need different SLAs, so give --sql-sla-name and --fileset-sla-name (or the -id versions). Each applies
  to its own pass only and overrides --sla-name / --sla-id for that workload. You can also give --sla-name for one
  workload and a specific option for the other. A workload with no SLA at all is an error.
- All SLAs are looked up before the first pass starts, so a wrong SLA name stops the run before anything changes.

IMPORTANT: This changes real SLA assignments. Run with --dry-run first to review what will be touched.

SQL hosts on RSC-P and RSC
- RSC-P returns SQL hosts as PhysicalHost objects and RSC returns them as MssqlHost objects (typeFilter MSSQL_HOST),
  and a query for the wrong one returns no hosts. The SQL host lookup tries PhysicalHost (RSC-P) first, then
  MSSQL_HOST (RSC), uses the first that returns hosts for the rest of the run, and prints which one it used. The
  fileset lookup is the same on both. --debug reports how many hosts each type returned.

RBS state (the rbsState column)
- Every host's RBS connection state is read from RSC in the same lookup that finds the host (no extra query): the
  connectionStatus on a PhysicalHost, or physicalHostMetadata.connectionStatus on an MssqlHost. It is shown as RSC
  reports it, for example CONNECTED, DISCONNECTED, BADLY_CONFIGURED or UNAUTHORIZED, and as unknown when RSC
  returned none (or when an --inventory-csv written before this column existed is used).
- It is a column in the plan table, in every Apply CSV row (including skipped hosts, when RSC returned the host)
  and in the host CSV (--host-csv-path). A warning lists hosts known not to be CONNECTED. The SLA is still assigned
  to them, but they will not back up until they reconnect. Nothing is skipped because of the state.
- With --inventory-csv the state comes from the inventory's rbsState column, as of when it was taken.
- The host CSV has one rbsState column. A later pass overwrites it only for hosts it actually read, so --assign
  both never replaces a state with unknown. A dry run or a cancelled run refreshes this column and nothing else.

Polling
- After the assignment calls are accepted, one query per 50 objects reads each object's SLA state by ID
  (no host, template or inventory lookups). An object is done when nothing is pending and its effective
  SLA is the target. Only objects whose call was accepted are polled.
- Default is every 30 seconds (--poll-interval-sec), for up to 3600 seconds, 60 minutes (--timeout-sec). Each round
  prints progress and when the next poll is, for example: 3/5 effective, 40s elapsed, next poll in 30s
- The timeout is counted per pass, so --assign both can wait up to twice as long. When polling starts the script
  prints the timeout and how to change it (--timeout-sec <seconds>).
- Done objects get status Applied (with effectiveSec). Objects not done by the timeout get Timeout and
  the run exits 1. Timeout does not mean the assignment failed: RSC accepted the call and may still apply the SLA
  after the script stopped waiting. A host whose objects all timed out is Unconfirmed (not Failed) in the host
  summary and in its host CSV cell, and the Apply CSV error column says so. Use --check-apply-csv-status to see
  where they are now. The time to effective is only accurate to within one poll interval.
- --skip-polling (alias --no-wait) submits and exits. Accepted objects are recorded as Submitted, and a
  rerun skips any that are still pending (SkippedPending).

Checking an Apply CSV later (--check-apply-csv-status, read-only)
- Reads the objects in an Apply CSV, looks up each one's current SLA in RSC by ID, and writes the same file name
  with _checked added (rubrik_sql_sla_apply-<time>_checked.csv), in the same folder. The original is not changed,
  and an existing _checked file is overwritten, so you can check again as often as you like.
- Adds three columns: currentPendingSLA, currentEffectiveSLA (SLA names) and checkResult, which is one of
  Effective on target, Pending, Different SLA (compared with the row's targetSla), Not found (RSC no longer
  returns the object) or Lookup failed. Rows with no object (skipped hosts) are left blank.
- It needs only --rsc-service-account-json. Use it after a cancelled run, when the file still says Pending or
  Submitted, or to see where a run got to. The exit code is 1 only if a lookup failed.

Skipped hosts (the default, nothing to turn on)
- A host that cannot be used is skipped, not fatal. The rest are applied. A host is skipped when it is not found by
  exact name on --cluster-name, when more than one host has the name, when a SQL host has no SQL instances (for
  example a cluster node, whose instances sit under the cluster), when a fileset host's cluster does not have
  exactly one fileset template of that name, or when a host is not in the --inventory-csv.
- Every skipped host is listed in the plan (grouped by reason) and again at the end. In the Apply CSV it gets a row
  with no object, its skip status in status and hostStatus, and the reason in the error column. In the host CSV its
  executed_sql / executed_fileset cell reads: Skipped: <reason> <time>
- The exit code is 1 if any host was skipped. If every listed host is skipped, nothing is assigned. A dry run
  shows the skips, writes no Apply CSV, changes no SLA and exits 0 (it does refresh the host CSV's rbsState).
- A problem that affects every host (the fileset template does not exist) still stops the pass, and every host's
  cell reads: Not run: <reason>

Debug (--debug, SQL pass, read-only)
- Before resolving hosts, lists every SQL host RSC returns once with no cluster filter and once with the
  --cluster-name filter (same relic and replicated filters as the real lookup, no name filter). Nothing is
  listed on screen. Only the counts and the file locations are printed.
- Writes <prefix>sql_debug_hosts_all_clusters-<timestamp>.csv, <prefix>sql_debug_hosts_cluster-<timestamp>.csv,
  <prefix>sql_debug_listed_hosts-<timestamp>.csv (for each listed host: returned exactly, a similar name such as a
  short name versus an FQDN, or not returned) and <prefix>sql_debug_raw-<timestamp>.json (the exact filters sent
  and the raw response). The host files include each host's rbsState. The run then continues
  as normal, so add --dry-run to look without changing any SLA.

Statuses in the Apply CSV
  Applied          SLA assigned and RSC shows it
  Submitted        call accepted, not checked (--skip-polling)
  AlreadyOnTarget  effective SLA was already the target, skipped
  SkippedPending   an SLA was already pending, skipped, rerun later
  CallFailed       the assignment call failed (error column has the reason)
  Timeout          call accepted but RSC did not show the SLA within --timeout-sec (it may still apply it)
  NotAttempted     the run stopped before this object was sent
  TemplateFailed   the fileset template could not be applied to the host
  SkippedNotFound     host not found by exact name on the cluster, skipped (no object row, reason in error)
  SkippedNoInstances  SQL host with no SQL instances, skipped
  SkippedAmbiguous    more than one host has the name, skipped
  SkippedNoTemplate   fileset template missing or not unique on the host's cluster, skipped
  NotInInventory      host is not in the --inventory-csv, skipped

Examples (add --dry-run to any of them to see the plan without changing any SLA)

  # SQL instances on three hosts, hosts on the command line
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign sqlOnly \\
    --hosts sql01 sql02 sql03 --sla-name Gold --cluster-name cluster01

  # SQL and filesets in one run, each with its own SLA
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign both \\
    --host-csv-path ./hosts.csv --fileset-name Temp --sql-sla-name MSSQL_Gold --fileset-sla-name WIN_Gold \\
    --cluster-name cluster01

  # SQL and filesets, hosts from a CSV (hostname, host, name or sqlhost column)
  # Writes the last status and time into executed_sql and executed_fileset in hosts.csv, and keeps hosts.csv.bak
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign both \\
    --host-csv-path ./hosts.csv --fileset-name Temp --sla-name Gold --cluster-name cluster01

  # Linux filesets only. --host-root must match where the template was created
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign filesetOnly \\
    --hosts linux01,linux02 --host-root LINUX_HOST_ROOT --fileset-name Temp --sla-name Gold \\
    --cluster-name cluster01

  # Use a fileset template ID instead of its name
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign filesetOnly \\
    --hosts host01 host02 --fileset-template-id <template id> --sla-name Gold --cluster-name cluster01

  # Submit and exit without waiting, then rerun later to see what is still pending
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign sqlOnly \\
    --hosts sql01 --sla-name Gold --cluster-name cluster01 --skip-polling

  # Hosts not found? Show what RSC returns for SQL hosts with and without the cluster filter
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign sqlOnly \\
    --hosts sql01 --sla-name Gold --cluster-name cluster01 --debug --dry-run

  # TLS certificate verification is off by default, so a self-signed certificate works. Turn it on with:
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign sqlOnly \\
    --hosts sql01 --sla-name Gold --cluster-name cluster01 --verify-ssl

  # Check an Apply CSV later: current SLA of every object, written to rubrik_sql_sla_apply-<time>_checked.csv
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --check-apply-csv-status ./rubrik_sql_sla_apply-<time>.csv

  # Set instances to Do Not Protect (existing snapshots are retained)
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign sqlOnly \\
    --hosts sql01 --sla-name DO_NOT_PROTECT --cluster-name cluster01

  # Use SQL and fileset inventory CSVs from the PowerShell script, no host or object searches in RSC
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign both \\
    --inventory-csv ./rubrik_sql_inventory-<time>.csv ./rubrik_fileset_inventory-<time>.csv \\
    --host-csv-path ./hosts.csv --fileset-name Temp --sla-name Gold --cluster-name cluster01

  # Large run: 100 objects per call, poll every 60 seconds, log every call, skip the confirmation prompt
  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign sqlOnly \\
    --host-csv-path ./hosts.csv --sla-name Gold --cluster-name cluster01 --batch-size 100 \\
    --poll-interval-sec 60 --assign-log --skip-confirm

Output (<workload> is sql or fileset), same names and columns as the PowerShell script:
- <prefix><workload>_sla_apply-<timestamp>.csv, one per pass per run (a run with --assign both writes two). It has
  the PowerShell script's columns plus rbsState after hostStatus.
- <prefix><workload>_sla_apply-<timestamp>_checked.csv (only with --check-apply-csv-status, overwritten each check)
- <prefix><workload>_sla_assign_log-<timestamp>.txt (only with --assign-log)
- Host CSV (--host-csv-path): updated in place. It always gets three columns: executed_sql and executed_fileset,
  each holding the host's last status and time for that workload, for example: Assigned 2026-11-17 14:05, and
  rbsState, the host's RBS connection state (state only, no time). A run changes only the executed column for its
  own workload (sqlOnly leaves executed_fileset as it was), so each column keeps the result of its last run.
  The original is kept once as <file>.bak. A dry run or a cancelled run changes no SLA and never writes an executed
  cell, but it does refresh the rbsState column, since it read each host's state.

Inventory CSVs are written by the PowerShell script (-getSqlInventory / -getFilesetInventory).
With --assign both, give two files after --inventory-csv, one SQL and one fileset, in either order.

Authentication uses an RSC Service Account JSON (client_id, client_secret, access_token_uri):
  RSC Settings -> Users -> Service Account -> create one with an appropriate role, download the JSON.
"""

import argparse
import csv
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

import requests

### CONSTANTS ###

PAGE_SIZE = 100
POLL_CHUNK = 50
OK_STATUSES = ('Applied', 'AlreadyOnTarget', 'Submitted')
BAD_STATUSES = ('CallFailed', 'Timeout', 'NotAttempted', 'TemplateFailed')

COLORS = {'red': '31', 'green': '32', 'yellow': '33', 'cyan': '36'}

APPLY_COLUMNS = [
    'workload', 'host', 'cluster', 'hostStatus', 'rbsState', 'object', 'objectId', 'beforeAssignment',
    'beforeSla', 'beforeSlaId', 'beforePendingSla', 'targetSla', 'assignMutation', 'applyMode',
    'callGroup', 'callSec', 'effectiveSec', 'status', 'error'
]
# Hosts that are skipped (and recorded) instead of stopping the run: status -> label used on the console
SKIP_HOST_LABELS = {
    'SkippedNotFound': 'Not found',
    'SkippedNoInstances': 'No SQL instances',
    'SkippedAmbiguous': 'More than one host with that name',
    'SkippedNoTemplate': 'Fileset template not usable on the host cluster',
    'NotInInventory': 'Not in the inventory CSV',
}

INVENTORY_REQUIRED_COLUMNS = [
    'inventoryVersion', 'workload', 'rowType', 'host', 'hostId', 'clusterId', 'objectId',
    'templateId', 'templateName', 'collectedAt'
]

# SQL host object types, tried in this order until one returns hosts:
#   (typeFilter value, GraphQL type of the host node, product)
# RSC-P (the primary) returns SQL hosts as PhysicalHost, and RSC returns them as MssqlHost (MSSQL_HOST)
SQL_HOST_TYPES = [('PhysicalHost', 'PhysicalHost', 'RSC-P'), ('MSSQL_HOST', 'MssqlHost', 'RSC')]

# Where each SQL host type keeps its RBS connection status (replaces __HOST_STATUS__ in the SQL host query)
SQL_HOST_STATUS_FIELDS = {
    'PhysicalHost': 'connectionStatus {\n              connectivity\n            }',
    'MssqlHost': 'physicalHostMetadata {\n              connectionStatus {\n                connectivity\n              }\n            }',
}

HOST_COLUMNS = ['hostname', 'host', 'name', 'sqlhost']
ASSIGN_CHOICES = ['sqlOnly', 'filesetOnly', 'both']

### GRAPHQL ###

Q_CLUSTER_BY_NAME = '''query ClusterByNameQuery($filter: ClusterFilterInput) {
    allClusterConnection(filter: $filter, sortBy: ClusterName, sortOrder: ASC) {
      nodes {
        id
        name
      }
    }
  }'''

Q_SLA_BY_NAME = '''query SLADomainsForNameFilterQuery($filter: [GlobalSlaFilterInput!]) {
    slaDomains(filter: $filter) {
      nodes {
        id
        name
        __typename
      }
      __typename
    }
  }'''

# SQL hosts. __HOST_TYPE__ is replaced with the object type of the host: PhysicalHost (what the RSC UI sends, and
# the only type some RSC deployments return) or MssqlHost (typeFilter MSSQL_HOST), see SQL_HOST_TYPES
Q_SQL_HOST_INSTANCES = '''query MssqlHostInstancesQuery($first: Int!, $after: String, $filter: [Filter!], $instanceFilter: [Filter!], $typeFilter: [HierarchyObjectTypeEnum!]) {
    mssqlTopLevelDescendants(after: $after, first: $first, filter: $filter, sortBy: NAME, sortOrder: ASC, typeFilter: $typeFilter) {
      edges {
        cursor
        node {
          id
          name
          objectType
          ... on __HOST_TYPE__ {
            cluster {
              id
              name
            }
            __HOST_STATUS__
            instanceDescendantConnection: descendantConnection(filter: $instanceFilter, typeFilter: [MssqlInstance]) {
              edges {
                node {
                  id
                  name
                  slaAssignment
                  effectiveSlaDomain {
                    id
                    name
                  }
                  pendingSla {
                    id
                    name
                  }
                }
              }
            }
          }
        }
      }
      pageInfo {
        endCursor
        hasNextPage
      }
    }
  }'''

Q_TEMPLATES_BY_NAME = '''query FilesetTemplatesByNameQuery($hostRoot: HostRoot!, $first: Int!, $after: String, $filter: [Filter!]!) {
    filesetTemplates(hostRoot: $hostRoot, first: $first, after: $after, filter: $filter, sortBy: NAME, sortOrder: ASC) {
      edges {
        node {
          id
          name
          cluster {
            id
            name
          }
        }
      }
      pageInfo {
        endCursor
        hasNextPage
      }
    }
  }'''

Q_TEMPLATE_BY_ID = '''query FilesetTemplateByIdQuery($fid: UUID!) {
    filesetTemplate(fid: $fid) {
      id
      name
      cluster {
        id
        name
      }
    }
  }'''

Q_HOST_FILESETS = '''query PhysicalHostFilesetsQuery($hostRoot: HostRoot!, $first: Int!, $after: String, $filter: [Filter!]!, $childFilter: [Filter!]) {
    physicalHosts(hostRoot: $hostRoot, filter: $filter, first: $first, after: $after, sortBy: NAME, sortOrder: ASC) {
      edges {
        node {
          id
          name
          cluster {
            id
            name
          }
          connectionStatus {
            connectivity
          }
          physicalChildConnection(typeFilter: [LinuxFileset, WindowsFileset], filter: $childFilter) {
            edges {
              node {
                id
                name
                objectType
                slaAssignment
                effectiveSlaDomain {
                  id
                  name
                }
                pendingSla {
                  id
                  name
                }
                ... on LinuxFileset {
                  filesetTemplate {
                    id
                    name
                  }
                }
                ... on WindowsFileset {
                  filesetTemplate {
                    id
                    name
                  }
                }
              }
            }
          }
        }
      }
      pageInfo {
        endCursor
        hasNextPage
      }
    }
  }'''

Q_BULK_CREATE_FILESETS = '''mutation BulkCreateFilesetsMutation($clusterUuid: String!, $definitions: [FilesetCreateInput!]!) {
    bulkCreateFilesets(input: {clusterUuid: $clusterUuid, definitions: $definitions}) {
      data {
        filesetSummary {
          hostId
          templateId
          slaAssignable {
            id
          }
        }
      }
    }
  }'''

Q_ASSIGN_SLA = '''mutation AssignSlaMutation($input: AssignSlaInput!) {
      assignSla(input: $input) {
        success
        __typename
      }
    }'''

Q_ASSIGN_SLAS_HIERARCHIES = '''mutation AssignSlasForSnappableHierarchiesMutation($globalExistingSnapshotRetention: GlobalExistingSnapshotRetention, $globalSlaOptionalFid: UUID, $globalSlaAssignType: SlaAssignTypeEnum!, $objectIds: [UUID!]!, $applicableSnappableTypes: [WorkloadLevelHierarchy!], $shouldApplyToExistingSnapshots: Boolean, $shouldApplyToNonPolicySnapshots: Boolean, $userNote: String) {
    assignSlasForSnappableHierarchies(globalExistingSnapshotRetention: $globalExistingSnapshotRetention, globalSlaOptionalFid: $globalSlaOptionalFid, globalSlaAssignType: $globalSlaAssignType, objectIds: $objectIds, applicableSnappableTypes: $applicableSnappableTypes, shouldApplyToExistingSnapshots: $shouldApplyToExistingSnapshots, shouldApplyToNonPolicySnapshots: $shouldApplyToNonPolicySnapshots, userNote: $userNote) {
      success
      __typename
    }
  }'''

### HELPERS ###


class Ctx(object):
    """Run state shared by the functions below."""

    def __init__(self, args):
        self.args = args
        # Shared by every pass
        self.workloads = []
        self.sla_by_workload = {}
        self.host_names = []
        self.host_csv = None
        self.inventory_by_workload = {}
        self.session = requests.Session()
        self.verify = False
        self.endpoint = None
        self.headers = None
        self.cluster_id = None
        self.sql_host_type = None
        self.date_string = ''
        # Set at the start of each pass (SQL, then Fileset)
        self.workload = 'SQL'
        self.inventory_path = None
        self.fileset_name = args.fileset_name
        self.csv_apply_output = None
        self.assign_log_output = None
        self.assign_call_number = 0
        self.assign_log_cluster = ''
        self.assign_log_target = ''

    def executed_column(self):
        """Host CSV column this pass writes: 'executed_sql' or 'executed_fileset'."""
        return 'executed_%s' % self.workload.lower()


class Stop(Exception):
    """A run-stopping error with a message meant for the user."""


def say(text='', color=None):
    if color and sys.stdout.isatty():
        print('\033[%sm%s\033[0m' % (COLORS[color], text))
    else:
        print(text)
    sys.stdout.flush()


def die(text):
    print(text, file=sys.stderr)
    sys.exit(1)


def ieq(a, b):
    """Case-insensitive equality, the way PowerShell -eq compares strings."""
    return ('' if a is None else str(a)).casefold() == ('' if b is None else str(b)).casefold()


def ikey(value):
    return ('' if value is None else str(value)).lower()


def dig(obj, *keys):
    for key in keys:
        if isinstance(obj, dict):
            obj = obj.get(key)
        else:
            return None
    return obj


def fmt_cell(value):
    if value is None:
        return ''
    if isinstance(value, bool):
        return 'True' if value else 'False'
    if isinstance(value, float):
        text = repr(value)
        return text[:-2] if text.endswith('.0') else text
    return str(value)


def write_csv(path, rows, columns):
    with open(path, 'w', newline='', encoding='utf-8') as handle:
        writer = csv.writer(handle, quoting=csv.QUOTE_ALL, lineterminator='\n')
        writer.writerow(columns)
        for row in rows:
            writer.writerow([fmt_cell(row.get(col)) for col in columns])


def read_csv_rows(path):
    with open(path, newline='', encoding='utf-8-sig') as handle:
        reader = csv.DictReader(handle, restval='')
        fieldnames = list(reader.fieldnames or [])
        rows = []
        for raw in reader:
            rows.append({k: ('' if v is None else v) for k, v in raw.items() if k is not None})
    return fieldnames, rows


def print_table(rows, columns):
    if not rows:
        return
    cells = [{c: fmt_cell(r.get(c)) for c in columns} for r in rows]
    widths = {c: max([len(c)] + [len(r[c]) for r in cells]) for c in columns}
    say(' '.join(c.ljust(widths[c]) for c in columns).rstrip())
    say(' '.join('-' * len(c) for c in columns))
    for r in cells:
        say(' '.join(r[c].ljust(widths[c]) for c in columns).rstrip())
    say('')


def group_by(items, key_func):
    """Group items in order of first appearance. Returns a list of (name, [items])."""
    groups = {}
    order = []
    for item in items:
        key = key_func(item)
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(item)
    return [(key, groups[key]) for key in order]


def unique_ordered(values):
    seen = set()
    out = []
    for value in values:
        if value not in seen:
            seen.add(value)
            out.append(value)
    return out


def split_names(values):
    """Accept '--hosts a b' and '--hosts a,b'."""
    out = []
    for value in values or []:
        out.extend(part.strip() for part in str(value).split(','))
    return [v for v in out if v]


### RSC ACCESS ###


def authenticate(ctx):
    path = ctx.args.rsc_service_account_json
    say('Reading Service Account file: %s' % path)
    try:
        with open(path, encoding='utf-8-sig') as handle:
            sa = json.load(handle)
        if not isinstance(sa, dict):
            raise ValueError('the JSON is not an object')
    except Exception as exc:
        raise Stop("Failed to read Service Account JSON at '%s': %s" % (path, exc))

    missing = [k for k in ('client_id', 'client_secret', 'access_token_uri') if sa.get(k) is None]
    if missing:
        raise Stop('Service Account JSON is missing required fields: %s' % ', '.join(missing))

    payload = {
        'grant_type': 'client_credentials',
        'client_id': sa['client_id'],
        'client_secret': sa['client_secret'],
    }
    try:
        resp = ctx.session.post(sa['access_token_uri'], json=payload, timeout=(15, 60), verify=ctx.verify)
        resp.raise_for_status()
        token = resp.json().get('access_token')
    except Exception as exc:
        raise Stop('RSC authentication failed: %s' % exc)
    if token is None:
        raise Stop('RSC returned a response but no access token was included.')

    rubrik_url = sa['access_token_uri'].replace('/api/client_token', '')
    ctx.endpoint = rubrik_url + '/api/graphql'
    ctx.headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer %s' % token,
    }
    say('Connected to RSC: %s' % rubrik_url, 'green')


def invoke_rsc(ctx, query, variables=None):
    """Send a GraphQL request, raise on HTTP or GraphQL errors, return the data and the call seconds."""
    payload = {'query': query, 'variables': variables or {}}
    start = time.monotonic()
    resp = ctx.session.post(ctx.endpoint, json=payload, headers=ctx.headers, timeout=(15, 300), verify=ctx.verify)
    seconds = time.monotonic() - start
    if resp.status_code >= 400:
        raise RuntimeError('RSC returned HTTP %d: %s' % (resp.status_code, resp.text[:500]))
    body = resp.json()
    if body.get('errors'):
        raise RuntimeError(json.dumps(body['errors'], separators=(',', ':')))
    return {'data': body.get('data') or {}, 'seconds': seconds}


def paginate(ctx, query, base_variables, root_key):
    nodes = []
    after = None
    while True:
        variables = dict(base_variables)
        if after:
            variables['after'] = after
        result = invoke_rsc(ctx, query, variables)['data'].get(root_key) or {}
        for edge in result.get('edges') or []:
            nodes.append(edge.get('node'))
        page = result.get('pageInfo') or {}
        after = page.get('endCursor')
        if not page.get('hasNextPage') or not after:
            break
    return nodes


def get_cluster_id_by_name(ctx, name):
    data = invoke_rsc(ctx, Q_CLUSTER_BY_NAME, {'filter': {'name': [name]}})['data']
    nodes = [n for n in (dig(data, 'allClusterConnection', 'nodes') or []) if ieq(n.get('name'), name)]
    if not nodes:
        raise Stop('No cluster found with the exact name: %s' % name)
    if len(nodes) >= 2:
        raise Stop('More than one cluster has the name: %s' % name)
    return nodes[0]['id']


def resolve_sla_spec(ctx, name=None, sla_id=None):
    """Turn an SLA name or ID into the spec the assign mutation needs."""
    if sla_id:
        return {'type': 'protectWithSlaId', 'slaId': sla_id, 'label': sla_id}
    if ieq(name, 'DO_NOT_PROTECT'):
        return {'type': 'doNotProtect', 'slaId': '', 'label': 'DO_NOT_PROTECT'}
    if ieq(name, 'NO_ASSIGNMENT'):
        return {'type': 'noAssignment', 'slaId': '', 'label': 'NO_ASSIGNMENT'}
    say('Looking up SLA Domain: %s' % name)
    data = invoke_rsc(ctx, Q_SLA_BY_NAME, {'filter': [{'field': 'NAME', 'text': name}]})['data']
    exact = [n for n in (dig(data, 'slaDomains', 'nodes') or []) if ieq(n.get('name'), name)]
    if not exact:
        raise Stop('No SLA Domain found with the exact name: %s' % name)
    if len(exact) >= 2:
        raise Stop('Multiple SLA Domains found with the exact name: %s. Use the SLA ID instead.' % name)
    return {'type': 'protectWithSlaId', 'slaId': exact[0]['id'], 'label': exact[0]['name']}


def fetch_sql_hosts(ctx, host_filter):
    """Get SQL hosts with their instances. Tries each host type in SQL_HOST_TYPES and returns the first
    that returns hosts. Returns (nodes, type_used, attempts, variables), where attempts lists
    (typeFilter, host count) for every type tried and type_used is None when none returned hosts."""
    attempts = []
    variables = None
    # Once a host type has returned hosts, use only that one for the rest of the run
    types = [t for t in SQL_HOST_TYPES if t[0] == ctx.sql_host_type] or SQL_HOST_TYPES
    for type_filter, fragment_type, product in types:
        query = Q_SQL_HOST_INSTANCES.replace('__HOST_TYPE__', fragment_type).replace('__HOST_STATUS__', SQL_HOST_STATUS_FIELDS[fragment_type])
        variables = {
            'first': PAGE_SIZE,
            'filter': host_filter,
            'instanceFilter': [{'field': 'IS_ARCHIVED', 'texts': ['false']}],
            'typeFilter': [type_filter],
        }
        nodes = paginate(ctx, query, variables, 'mssqlTopLevelDescendants')
        attempts.append((type_filter, len(nodes)))
        if nodes:
            if ctx.sql_host_type != type_filter:
                ctx.sql_host_type = type_filter
                say('SQL hosts are returned as %s (%s)' % (type_filter, product))
            return nodes, type_filter, attempts, variables
    return [], None, attempts, variables


def get_sql_host_instances(ctx, host_name):
    host_filter = [
        {'field': 'NAME', 'texts': [host_name]},
        {'field': 'IS_RELIC', 'texts': ['false']},
        {'field': 'IS_REPLICATED', 'texts': ['false']},
        {'field': 'CLUSTER_ID', 'texts': [ctx.cluster_id]},
    ]
    return fetch_sql_hosts(ctx, host_filter)[0]


def get_filesets_for_host(ctx, host_name):
    host_filter = [
        {'field': 'NAME', 'texts': [host_name]},
        {'field': 'IS_RELIC', 'texts': ['false']},
        {'field': 'IS_REPLICATED', 'texts': ['false']},
        {'field': 'IS_KUPR_HOST', 'texts': ['false']},
        {'field': 'CLUSTER_ID', 'texts': [ctx.cluster_id]},
    ]
    variables = {
        'hostRoot': ctx.args.host_root,
        'first': PAGE_SIZE,
        'filter': host_filter,
        'childFilter': [
            {'field': 'IS_GHOST', 'texts': ['false']},
            {'field': 'IS_RELIC', 'texts': ['false']},
        ],
    }
    return paginate(ctx, Q_HOST_FILESETS, variables, 'physicalHosts')


def get_templates_by_name(ctx, name, host_root):
    variables = {
        'hostRoot': host_root,
        'first': PAGE_SIZE,
        'filter': [
            {'field': 'NAME', 'texts': [name]},
            {'field': 'CLUSTER_ID', 'texts': [ctx.cluster_id]},
        ],
    }
    return paginate(ctx, Q_TEMPLATES_BY_NAME, variables, 'filesetTemplates')


def get_template_by_id(ctx, template_id):
    data = invoke_rsc(ctx, Q_TEMPLATE_BY_ID, {'fid': template_id})['data']
    return data.get('filesetTemplate')


def new_filesets_on_cluster(ctx, cluster_id, definitions):
    defs = [{
        'hostId': d['hostId'],
        'templateId': d['templateId'],
        'isPassthrough': False,
        'enableSymlinkResolution': False,
        'enableHardlinkSupport': False,
    } for d in definitions]
    return invoke_rsc(ctx, Q_BULK_CREATE_FILESETS, {'clusterUuid': cluster_id, 'definitions': defs})


def get_sla_states(ctx, object_ids):
    """Current SLA state of objects, 50 per query."""
    states = []
    for start in range(0, len(object_ids), POLL_CHUNK):
        chunk = object_ids[start:start + POLL_CHUNK]
        var_defs = []
        fields = []
        variables = {}
        for i, object_id in enumerate(chunk):
            var_defs.append('$id%d: UUID!' % i)
            fields.append('o%d: hierarchyObject(fid: $id%d) { id slaAssignment effectiveSlaDomain { id name } '
                          '... on CdmHierarchyObject { pendingSla { id name } } }' % (i, i))
            variables['id%d' % i] = object_id
        query = 'query PendingSlaBatchQuery(' + ', '.join(var_defs) + ') { ' + ' '.join(fields) + ' }'
        data = invoke_rsc(ctx, query, variables)['data']
        for value in data.values():
            if value:
                states.append(value)
    return states


### SLA LOGIC ###


def is_sla_effective(state, spec):
    """True when nothing is pending and the object shows the target SLA."""
    if state.get('pendingSla'):
        return False
    assignment = state.get('slaAssignment')
    effective_id = dig(state, 'effectiveSlaDomain', 'id')
    if spec['type'] == 'protectWithSlaId':
        return ieq(assignment, 'Direct') and ieq(effective_id, spec['slaId'])
    if spec['type'] == 'doNotProtect':
        return ieq(assignment, 'Direct') and ieq(effective_id, 'DO_NOT_PROTECT')
    if spec['type'] == 'noAssignment':
        return not ieq(assignment, 'Direct')
    return False


def get_sla_decision(state, spec):
    """Assign, SkippedPending (any pending SLA) or AlreadyOnTarget (effective SLA is already the target)."""
    if state is None:
        return 'Assign'
    if state.get('pendingSla'):
        return 'SkippedPending'
    effective_id = dig(state, 'effectiveSlaDomain', 'id')
    if spec['type'] == 'protectWithSlaId' and ieq(effective_id, spec['slaId']):
        return 'AlreadyOnTarget'
    if spec['type'] == 'doNotProtect' and ieq(effective_id, 'DO_NOT_PROTECT'):
        return 'AlreadyOnTarget'
    if spec['type'] == 'noAssignment' and not ieq(state.get('slaAssignment'), 'Direct'):
        return 'AlreadyOnTarget'
    return 'Assign'


def write_assign_log(ctx, mutation, query, variables, response=None, error_text='', seconds=None):
    """Append one entry to the assignment log (--assign-log). Never raises."""
    if not ctx.args.assign_log:
        return
    try:
        ctx.assign_call_number += 1
        ids = variables.get('objectIds') or dig(variables, 'input', 'objectIds') or []
        lines = ['=' * 100]
        lines.append('Call %d  %s' % (ctx.assign_call_number, datetime.now().strftime('%Y-%m-%d %H:%M:%S')))
        lines.append('Mutation:  %s' % mutation)
        lines.append('Workload:  %s' % ctx.workload)
        lines.append('Target:    %s' % ctx.assign_log_target)
        lines.append('Cluster:   %s' % ctx.assign_log_cluster)
        lines.append('Objects:   %d' % len(ids))
        if seconds is not None:
            lines.append('Seconds:   %s' % fmt_cell(round(seconds, 3)))
        lines.append('Result:    %s' % ('FAILED' if error_text else 'OK'))
        if error_text:
            lines.append('Error:     %s' % error_text)
        lines.append('')
        lines.append('Query:')
        lines.append(query)
        lines.append('')
        lines.append('Variables:')
        lines.append(json.dumps(variables, indent=2))
        lines.append('')
        lines.append('Response:')
        lines.append(json.dumps(response, indent=2) if response is not None else '(none)')
        lines.append('')
        with open(ctx.assign_log_output, 'a', encoding='utf-8') as handle:
            handle.write('\n'.join(lines) + '\n')
    except Exception as exc:
        say('Could not write the assignment log (%s): %s' % (ctx.assign_log_output, exc), 'yellow')


def set_object_sla(ctx, object_ids, spec):
    """Assign an SLA spec to a list of objects in one call, using the chosen mutation."""
    protect = spec['type'] == 'protectWithSlaId'
    if ctx.args.assign_mutation == 'AssignSla':
        mutation = 'assignSla'
        query = Q_ASSIGN_SLA
        assign_input = {
            'slaDomainAssignType': spec['type'],
            'slaOptionalId': spec['slaId'] if protect else None,
            'objectIds': list(object_ids),
            'existingSnapshotRetention': None if protect else 'RETAIN_SNAPSHOTS',
            'shouldApplyToExistingSnapshots': False if protect else None,
            'shouldApplyToNonPolicySnapshots': False,
            'userNote': '',
        }
        variables = {'input': assign_input}
        fail_text = 'assignSla did not return success'
    else:
        mutation = 'assignSlasForSnappableHierarchies'
        query = Q_ASSIGN_SLAS_HIERARCHIES
        variables = {
            'objectIds': list(object_ids),
            'globalSlaAssignType': spec['type'],
            'globalSlaOptionalFid': spec['slaId'] if protect else None,
            'globalExistingSnapshotRetention': None if protect else 'RETAIN_SNAPSHOTS',
            'shouldApplyToExistingSnapshots': False if protect else None,
            'shouldApplyToNonPolicySnapshots': False,
            'userNote': '',
        }
        fail_text = 'assignSlasForSnappableHierarchies did not return success for all objects'

    try:
        result = invoke_rsc(ctx, query, variables)
    except Exception as exc:
        write_assign_log(ctx, mutation, query, variables, error_text=str(exc))
        raise
    returned = result['data'].get(mutation)
    results = returned if isinstance(returned, list) else ([returned] if returned is not None else [])
    if not results or any((r or {}).get('success') is not True for r in results):
        write_assign_log(ctx, mutation, query, variables, response=result['data'],
                         seconds=result['seconds'], error_text=fail_text)
        raise RuntimeError(fail_text)
    write_assign_log(ctx, mutation, query, variables, response=result['data'], seconds=result['seconds'])
    return result


def split_into_batches(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


def get_call_groups(objects, mode, size):
    """Split objects into call groups. Bulk is batches of size, Single is one call per host.
    A call never mixes clusters."""
    groups = []
    for _, cluster_objects in group_by(objects, lambda o: o['clusterId']):
        if mode == 'Single':
            for _, host_objects in group_by(cluster_objects, lambda o: o['hostId']):
                groups.append(host_objects)
        else:
            groups.extend(split_into_batches(cluster_objects, size))
    return groups


def format_duration(seconds):
    """3600 -> '60 minutes', 90 -> '1 minute 30 seconds'."""
    minutes, secs = divmod(int(seconds), 60)
    parts = []
    if minutes:
        parts.append('%d minute%s' % (minutes, '' if minutes == 1 else 's'))
    if secs or not parts:
        parts.append('%d second%s' % (secs, '' if secs == 1 else 's'))
    return ' '.join(parts)


def wait_sla_effective(ctx, object_ids, spec, t_start):
    """Poll until every object shows the SLA or the timeout is hit. Prints progress at every poll."""
    effective = {}
    poll_count = 0
    timed_out = False
    wait_start = time.monotonic()
    while True:
        remaining = [i for i in object_ids if ikey(i) not in effective]
        if not remaining:
            break
        if time.monotonic() - wait_start >= ctx.args.timeout_sec:
            timed_out = True
            break
        poll_count += 1
        try:
            states = get_sla_states(ctx, remaining)
            offset = time.monotonic() - t_start
            for state in states:
                if is_sla_effective(state, spec):
                    effective[ikey(state.get('id'))] = offset
        except Exception as exc:
            say('    Poll %d failed: %s' % (poll_count, exc), 'yellow')
        progress = '  %d/%d effective, %ds elapsed' % (len(effective), len(object_ids), round(time.monotonic() - t_start))
        if any(ikey(i) not in effective for i in object_ids):
            say('%s, next poll in %ds' % (progress, ctx.args.poll_interval_sec))
            time.sleep(ctx.args.poll_interval_sec)
        else:
            say(progress)
    return {'effective': effective, 'timedOut': timed_out}


def invoke_apply_sla(ctx, objects, spec, results):
    """Send the SLA assignments for the objects, then wait for completion.
    results is filled in place so partial results survive if something stops the run."""
    args = ctx.args
    for o in objects:
        results[ikey(o['instanceId'])] = {
            'workload': ctx.workload, 'assignMutation': args.assign_mutation, 'applyMode': args.apply_mode,
            'host': o['hostName'], 'object': o['instanceName'], 'objectId': o['instanceId'],
            'beforeAssignment': o['assignment'], 'beforeSla': o['currentSla'], 'targetSla': spec['label'],
            'callGroup': None, 'callSec': None, 'effectiveSec': None, 'status': 'NotAttempted', 'error': '',
        }

    todo = []
    for o in objects:
        decision = get_sla_decision(o.get('state'), spec)
        if decision == 'Assign':
            todo.append(o)
        else:
            results[ikey(o['instanceId'])]['status'] = decision
    pending_count = sum(1 for o in objects if results[ikey(o['instanceId'])]['status'] == 'SkippedPending')
    say("%d object(s): %d to assign, %d already on '%s', %d skipped because an SLA is pending" % (
        len(objects), len(todo), len(objects) - len(todo) - pending_count, spec['label'], pending_count))
    if not todo:
        return

    # An object ID must appear once: the same ID twice in one call can fail validation for the whole batch
    todo = [group[0] for _, group in group_by(todo, lambda o: ikey(o['instanceId']))]

    no_cluster = [o for o in todo if not o.get('clusterId')]
    if no_cluster:
        sample = ', '.join('%s/%s' % (o['hostName'], o['instanceName']) for o in no_cluster[:3])
        raise Stop('%d object(s) have no cluster ID, so they cannot be batched safely: %s' % (len(no_cluster), sample))

    groups = get_call_groups(todo, args.apply_mode, args.batch_size)
    t_start = time.monotonic()
    submitted_ids = []
    for number, group in enumerate(groups, 1):
        ids = [o['instanceId'] for o in group]
        ctx.assign_log_cluster = ','.join(unique_ordered(o['clusterId'] for o in group))
        ctx.assign_log_target = spec['label']
        try:
            assign_result = set_object_sla(ctx, ids, spec)
            call_sec = round(assign_result['seconds'], 2)
            say('  Call %d/%d: %d object(s) accepted in %ss' % (number, len(groups), len(ids), fmt_cell(call_sec)))
            for object_id in ids:
                row = results[ikey(object_id)]
                row['callGroup'] = number
                row['callSec'] = call_sec
                row['status'] = 'Submitted'
            submitted_ids.extend(ids)
        except Exception as exc:
            say('  Call %d/%d FAILED for %d object(s): %s' % (number, len(groups), len(ids), exc), 'red')
            for object_id in ids:
                row = results[ikey(object_id)]
                row['callGroup'] = number
                row['status'] = 'CallFailed'
                row['error'] = str(exc)

    if not args.skip_polling and submitted_ids:
        say("Waiting for %d object(s) to show '%s'" % (len(submitted_ids), spec['label']))
        say('  Polling every %ds for up to %ds (%s). Objects not confirmed by then are recorded as Timeout, which does not mean the'
            % (args.poll_interval_sec, args.timeout_sec, format_duration(args.timeout_sec)))
        say('  assignment failed, RSC may still apply it. To change the wait, rerun with --timeout-sec <seconds>, for example'
            ' --timeout-sec 7200. To change how often it polls, use --poll-interval-sec <seconds>.')
        wait = wait_sla_effective(ctx, submitted_ids, spec, t_start)
        for object_id in submitted_ids:
            row = results[ikey(object_id)]
            if ikey(object_id) in wait['effective']:
                row['status'] = 'Applied'
                row['effectiveSec'] = round(wait['effective'][ikey(object_id)], 2)
            else:
                row['status'] = 'Timeout'
                row['error'] = ('accepted by RSC, not seen effective within %ds. RSC may still apply it, check later '
                                'with --check-apply-csv-status' % args.timeout_sec)


### HOST CSV ###


def read_host_csv(ctx, path, columns):
    """Read the host name column. Also remembers the file so the executed column can be written back."""
    if not os.path.isfile(path):
        die('CSV file not found: %s' % path)
    fieldnames, rows = read_csv_rows(path)
    if not rows:
        die('CSV file has no rows: %s' % path)
    column = next((c for c in fieldnames if c.casefold() in columns), None)
    if not column:
        die('CSV needs a header column named one of: %s' % ', '.join(columns))
    ctx.host_csv = {'path': os.path.abspath(path), 'fieldnames': fieldnames, 'rows': rows, 'column': column}
    return [r.get(column, '') for r in rows]


def update_host_csv_executed(ctx, executed_by_host, rbs_by_host=None):
    """Write each host's last status and time into this pass's column ('executed_sql' or 'executed_fileset'),
    and its RBS state into the 'rbsState' column. executed_by_host=None writes only rbsState (a dry run).
    The file always gets all three columns. A run only changes the executed column of its own workload, so the
    other keeps the result of its last run. rbsState is overwritten only for hosts whose state this pass read,
    so a pass that cannot find a host keeps the state an earlier pass read. A host never read shows 'unknown'. The file is written to a temporary file and moved into place, and the
    original is kept once as <file>.bak. The rows are kept in memory so the next pass (--assign both)
    builds on the file the first pass already wrote."""
    info = ctx.host_csv
    if not info:
        return
    stamp = datetime.now().strftime('%Y-%m-%d %H:%M')
    columns = list(info['fieldnames'])
    col_names = {}
    for wanted in ('executed_sql', 'executed_fileset'):
        col_names[wanted] = next((c for c in columns if c.casefold() == wanted), wanted)
        if col_names[wanted] not in columns:
            columns.append(col_names[wanted])
    executed_col = col_names[ctx.executed_column()]
    rbs_col = next((c for c in columns if c.casefold() == 'rbsstate'), 'rbsState')
    if rbs_col not in columns:
        columns.append(rbs_col)
    rbs_by_host = rbs_by_host or {}
    out = []
    for row in info['rows']:
        copy = dict(row)
        for name in col_names.values():
            copy.setdefault(name, '')
        copy.setdefault(rbs_col, '')
        host_value = str(row.get(info['column'], '')).strip()
        if executed_by_host is not None and host_value and host_value.lower() in executed_by_host:
            copy[executed_col] = ('%s %s' % (executed_by_host[host_value.lower()], stamp)).strip()
        if host_value and host_value.lower() in rbs_by_host:
            copy[rbs_col] = rbs_by_host[host_value.lower()]
        elif not copy[rbs_col]:
            copy[rbs_col] = 'unknown'
        out.append(copy)
    backup = info['path'] + '.bak'
    tmp = info['path'] + '.tmp'
    try:
        write_csv(tmp, out, columns)
        if not os.path.exists(backup):
            with open(info['path'], 'rb') as src, open(backup, 'wb') as dst:
                dst.write(src.read())
        os.replace(tmp, info['path'])
        info['rows'] = out
        info['fieldnames'] = columns
        say("Updated the '%s' and '%s' columns in: %s" % (rbs_col, executed_col, info['path']) if executed_by_host is not None
            else "Updated the '%s' column in: %s" % (rbs_col, info['path']), 'green')
    except Exception as exc:
        say('Could not update the host CSV (%s): %s' % (info['path'], exc), 'yellow')
        if executed_by_host is not None:
            say('The results are still in the Apply CSV: %s' % ctx.csv_apply_output, 'yellow')
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def set_host_csv_not_run(ctx, reason='stopped before any change'):
    """The pass stopped before any change for a reason that affects every host (for example the fileset template
    does not exist). Record 'Not run: <reason>' for every host in the host CSV."""
    if not ctx.host_csv:
        return
    update_host_csv_executed(ctx, {h.lower(): 'Not run: %s' % reason for h in ctx.host_names})


def write_apply_csv(ctx, rows, columns):
    """Write the Apply CSV through a temporary file. Never raises: a problem writing it must not stop an assignment."""
    tmp = ctx.csv_apply_output + '.tmp'
    try:
        write_csv(tmp, rows, columns)
        os.replace(tmp, ctx.csv_apply_output)
    except Exception as exc:
        say('Could not write the Apply CSV (%s): %s' % (ctx.csv_apply_output, exc), 'yellow')
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


### INVENTORY CSV ###


def parse_collected_at(text):
    match = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})?$', text.strip())
    if not match:
        raise ValueError('unrecognized timestamp')
    base = match.group(1)
    if match.group(2):
        base += '.' + match.group(2).ljust(6, '0')[:6]
    tz = match.group(3)
    if tz == 'Z':
        parsed = datetime.fromisoformat(base).replace(tzinfo=timezone.utc)
    elif tz:
        parsed = datetime.fromisoformat(base + tz)
    else:
        parsed = datetime.fromisoformat(base)
    return parsed.astimezone(timezone.utc)


def read_inventory_csv(ctx, path, expected_workload):
    fieldnames, rows = read_csv_rows(path)
    if not rows:
        raise Stop('Inventory CSV has no rows: %s' % path)
    for col in INVENTORY_REQUIRED_COLUMNS:
        if col not in fieldnames:
            raise Stop("Inventory CSV is missing the '%s' column. Create it with -getSqlInventory or "
                       "-getFilesetInventory in the PowerShell script: %s" % (col, path))
    workloads = unique_ordered(r['workload'] for r in rows)
    if len(workloads) != 1 or not ieq(workloads[0], expected_workload):
        raise Stop("Inventory CSV is for '%s' but this run is for '%s': %s" % (','.join(workloads), expected_workload, path))
    collected = None
    try:
        collected = parse_collected_at(rows[0]['collectedAt'])
    except Exception:
        say('Could not read the collection time from the inventory CSV, so its age is unknown.', 'yellow')
    if collected:
        age_hours = (datetime.now(timezone.utc) - collected).total_seconds() / 3600
        say('Inventory collected %s (%s hour(s) ago): %s' % (
            collected.astimezone().strftime('%Y-%m-%d %H:%M'), fmt_cell(round(age_hours, 1)), path))
        if age_hours > ctx.args.inventory_max_age_hours:
            say('WARNING: the inventory is older than %d hour(s). Objects added or removed since then are not '
                'reflected. Rerun -getSqlInventory or -getFilesetInventory in the PowerShell script to refresh it.'
                % ctx.args.inventory_max_age_hours, 'yellow')
    return rows


### OBJECT BUILDERS ###


def rbs_state_of(node):
    """RBS connection status of a host node, for example CONNECTED or DISCONNECTED. RSC-P and the fileset host
    query keep it on connectionStatus, RSC keeps it under physicalHostMetadata. 'unknown' when RSC returned none."""
    return (dig(node, 'connectionStatus', 'connectivity')
            or dig(node, 'physicalHostMetadata', 'connectionStatus', 'connectivity') or 'unknown')


def collect_rbs(host_objs, need_template_hosts, skipped_hosts):
    """Host name (lower case) -> RBS state for every host whose state was actually read. Hosts whose state is
    unknown are left out so they never overwrite a state an earlier pass read."""
    out = {}
    for h in list(host_objs) + list(need_template_hosts):
        if h.get('rbsState') and h['rbsState'] != 'unknown':
            out[str(h['name']).lower()] = h['rbsState']
    for x in skipped_hosts:
        if x.get('rbsState') and x['rbsState'] != 'unknown':
            out[str(x['host']).lower()] = x['rbsState']
    return out


def object_from_node(host_name, host_id, cluster_id, cluster_name, node, rbs_state='unknown'):
    return {
        'hostName': host_name, 'hostId': host_id, 'clusterId': cluster_id, 'clusterName': cluster_name,
        'rbsState': rbs_state,
        'instanceName': node.get('name'), 'instanceId': node.get('id'),
        'assignment': node.get('slaAssignment'), 'currentSla': dig(node, 'effectiveSlaDomain', 'name'),
        'state': {
            'id': node.get('id'), 'slaAssignment': node.get('slaAssignment'),
            'effectiveSlaDomain': node.get('effectiveSlaDomain'), 'pendingSla': node.get('pendingSla'),
        },
    }


def object_from_inventory_row(first, row):
    pending = None
    if row.get('pendingSlaId'):
        pending = {'id': row['pendingSlaId'], 'name': row.get('pendingSla')}
    return {
        'hostName': first['host'], 'hostId': first['hostId'], 'clusterId': first['clusterId'],
        'clusterName': first.get('clusterName'), 'rbsState': first.get('rbsState') or 'unknown',
        'instanceName': row.get('objectName'), 'instanceId': row['objectId'],
        'assignment': row.get('slaAssignment'), 'currentSla': row.get('effectiveSla'),
        'state': {
            'id': row['objectId'], 'slaAssignment': row.get('slaAssignment'),
            'effectiveSlaDomain': {'id': row.get('effectiveSlaId'), 'name': row.get('effectiveSla')},
            'pendingSla': pending,
        },
    }


def debug_sql_inventory(ctx):
    """--debug: list every SQL host RSC returns, once with no cluster filter and once with the --cluster-name
    filter, to show what the host lookup can see. Uses the same relic and replicated filters as the real
    lookup but no name filter. Writes everything to files (one CSV per variant, a comparison CSV for the listed
    hosts, and one raw JSON file) and prints only the counts and the file paths. Never stops the run."""
    args = ctx.args
    base_filter = [
        {'field': 'IS_RELIC', 'texts': ['false']},
        {'field': 'IS_REPLICATED', 'texts': ['false']},
    ]
    variants = [
        ('all_clusters', 'No cluster filter', base_filter),
        ('cluster', "Cluster filter '%s' (%s)" % (args.cluster_name, ctx.cluster_id),
         base_filter + [{'field': 'CLUSTER_ID', 'texts': [ctx.cluster_id]}]),
    ]
    columns = ['host', 'hostId', 'cluster', 'clusterId', 'objectType', 'rbsState', 'instanceCount', 'instances']
    say('')
    say('=' * 100)
    say('DEBUG: SQL host inventory from RSC (written to files, not printed)', 'cyan')
    say('=' * 100)
    raw = {}
    rows_by_variant = {}
    for key, label, host_filter in variants:
        say('')
        say(label, 'cyan')
        say('  filter sent: %s' % json.dumps(host_filter))
        try:
            nodes, type_used, attempts, variables = fetch_sql_hosts(ctx, host_filter)
        except Exception as exc:
            say('  query failed: %s' % exc, 'red')
            raw[key] = {'label': label, 'filter': host_filter, 'error': str(exc)}
            continue
        say('  host types tried: %s' % ', '.join('%s=%d' % a for a in attempts))
        raw[key] = {'label': label, 'typeUsed': type_used, 'attempts': attempts, 'variables': variables, 'nodes': nodes}
        rows = []
        for node in nodes:
            cluster = node.get('cluster') or {}
            instances = [e.get('node') or {} for e in (dig(node, 'instanceDescendantConnection', 'edges') or [])]
            rows.append({
                'host': node.get('name'), 'hostId': node.get('id'), 'cluster': cluster.get('name'),
                'clusterId': cluster.get('id'), 'objectType': node.get('objectType'), 'rbsState': rbs_state_of(node),
                'instanceCount': len(instances),
                'instances': ' | '.join('%s (%s)' % (i.get('name'), dig(i, 'effectiveSlaDomain', 'name')) for i in instances),
            })
        rows.sort(key=lambda r: str(r['host']).casefold())
        rows_by_variant[key] = rows
        say('  %d SQL host(s) returned%s' % (len(rows), (' (typeFilter %s)' % type_used) if type_used else ''))
        csv_path = '%ssql_debug_hosts_%s-%s.csv' % (args.csv_output_prefix, key, ctx.date_string)
        try:
            write_csv(csv_path, rows, columns)
            say('  CSV: %s' % csv_path)
        except Exception as exc:
            say('  Could not write %s: %s' % (csv_path, exc), 'yellow')

    if ctx.host_names:
        say('')
        say('Listed hosts versus what RSC returned (details in the CSV)', 'cyan')
        check_rows = []
        for name in ctx.host_names:
            row = {'listedHost': name}
            short = name.casefold().split('.')[0]
            for key, _, _ in variants:
                rows = rows_by_variant.get(key)
                if rows is None:
                    row[key] = 'query failed'
                    continue
                exact = [r for r in rows if ieq(r['host'], name)]
                if exact:
                    row[key] = 'exact match on ' + ', '.join(unique_ordered(str(r['cluster']) for r in exact))
                    continue
                near = [str(r['host']) for r in rows if short and short in str(r['host']).casefold()]
                row[key] = ('similar: ' + ', '.join(near[:3])) if near else 'not returned'
            check_rows.append(row)
        compare_path = '%ssql_debug_listed_hosts-%s.csv' % (args.csv_output_prefix, ctx.date_string)
        try:
            write_csv(compare_path, check_rows, ['listedHost', 'all_clusters', 'cluster'])
            say('  CSV: %s' % compare_path)
        except Exception as exc:
            say('  Could not write %s: %s' % (compare_path, exc), 'yellow')
        for key, label, _ in variants:
            found = sum(1 for r in check_rows if str(r[key]).startswith('exact match'))
            say('  %d of %d listed host(s) returned with: %s' % (found, len(check_rows), label))

    raw_path = '%ssql_debug_raw-%s.json' % (args.csv_output_prefix, ctx.date_string)
    try:
        with open(raw_path, 'w', encoding='utf-8') as handle:
            json.dump(raw, handle, indent=2)
        say('Raw responses (exact filters sent and the full reply): %s' % raw_path)
    except Exception as exc:
        say('Could not write %s: %s' % (raw_path, exc), 'yellow')
    say('Debug files are in: %s' % os.path.abspath(os.path.dirname(args.csv_output_prefix) or '.'), 'green')
    say('=' * 100)
    say('')


### HOST RESOLUTION ###


def resolve_from_inventory(ctx):
    """Build host_objs and pending_hosts from the inventory CSV, without querying RSC for hosts or objects.
    A listed host that cannot be used (not in the inventory, appears twice, no SQL instances, no usable template)
    is skipped and returned in the skipped list as {'host', 'status', 'reason'}. A host in the inventory that has
    no fileset from the template is returned in pending_hosts so the template is applied before the SLA."""
    args = ctx.args
    rows_all = read_inventory_csv(ctx, ctx.inventory_path, ctx.workload)
    host_rows = [r for r in rows_all if r['rowType'].casefold() in ('host', 'instance', 'fileset')]
    inv_hosts_all = [group for _, group in group_by(host_rows, lambda r: r['hostId'])]

    # Only hosts on the --cluster-name cluster are used
    inv_hosts = [g for g in inv_hosts_all if ieq(g[0]['clusterId'], ctx.cluster_id)]
    other_cluster = [g for g in inv_hosts_all if not ieq(g[0]['clusterId'], ctx.cluster_id)]
    if other_cluster:
        say("The inventory has %d host(s) on other clusters, which are not used because --cluster-name is '%s'."
            % (len(other_cluster), args.cluster_name), 'yellow')

    skipped = []
    wanted = []
    if ctx.host_names:
        for host_name in ctx.host_names:
            match = [g for g in inv_hosts if ieq(g[0]['host'], host_name)]
            if not match:
                if any(ieq(g[0]['host'], host_name) for g in other_cluster):
                    reason = "in the inventory on another cluster, not '%s'" % args.cluster_name
                else:
                    reason = 'not in the inventory CSV'
                skipped.append({'host': host_name, 'status': 'NotInInventory', 'reason': reason})
            elif len(match) > 1:
                skipped.append({'host': host_name, 'status': 'SkippedAmbiguous',
                                'reason': 'appears more than once in the inventory with different host IDs, rerun the inventory'})
            else:
                wanted.append(match[0])
    else:
        wanted = inv_hosts

    host_objs = []

    if ctx.workload == 'SQL':
        for group in wanted:
            first = group[0]
            inst_rows = [r for r in group if ieq(r['rowType'], 'Instance')]
            if not inst_rows:
                skipped.append({'host': first['host'], 'status': 'SkippedNoInstances', 'rbsState': first.get('rbsState') or 'unknown',
                                'reason': 'SQL host has no SQL instances in the inventory'})
                continue
            instances = [object_from_inventory_row(first, r) for r in inst_rows]
            host_objs.append({'name': first['host'], 'id': first['hostId'], 'rbsState': first.get('rbsState') or 'unknown', 'instances': instances})
    else:
        template_rows = [r for r in rows_all if ieq(r['rowType'], 'Template')]
        if args.fileset_template_id:
            match = [r for r in template_rows if ieq(r['templateId'], args.fileset_template_id)]
            if not match:
                set_host_csv_not_run(ctx, "fileset template ID '%s' is not in the inventory" % args.fileset_template_id)
                raise Stop("Fileset template ID '%s' is not in the inventory. Rerun -getFilesetInventory in the PowerShell script." % args.fileset_template_id)
            ctx.fileset_name = match[0]['templateName']
        else:
            match = [r for r in template_rows if ieq(r['templateName'], ctx.fileset_name)]
            if not match:
                set_host_csv_not_run(ctx, "fileset template '%s' is not in the inventory" % ctx.fileset_name)
                raise Stop("Fileset template '%s' is not in the inventory. Check the name or rerun -getFilesetInventory in the PowerShell script." % ctx.fileset_name)
        for group in wanted:
            first = group[0]
            host_template = [r for r in match if ieq(r['clusterId'], first['clusterId'])]
            if len(host_template) != 1:
                skipped.append({'host': first['host'], 'status': 'SkippedNoTemplate', 'rbsState': first.get('rbsState') or 'unknown',
                                'reason': "expected 1 fileset template '%s' on cluster '%s', found %d" % (
                                    ctx.fileset_name, first.get('clusterName'), len(host_template))})
                continue
            tid = host_template[0]['templateId']
            fs_rows = [r for r in group if ieq(r['rowType'], 'Fileset') and ieq(r['templateId'], tid)]
            instances = [object_from_inventory_row(first, r) for r in fs_rows]
            host_objs.append({
                'name': first['host'], 'id': first['hostId'], 'clusterId': first['clusterId'], 'rbsState': first.get('rbsState') or 'unknown',
                'clusterName': first.get('clusterName'), 'templateId': tid, 'instances': instances,
            })

    if skipped:
        say('Skipping %d host(s) that cannot be used from the inventory (reasons below and in the CSVs)' % len(skipped), 'yellow')
    pending_hosts = []
    if ctx.workload == 'Fileset':
        pending_hosts = [h for h in host_objs if not h['instances']]
    return host_objs, pending_hosts, skipped


def resolve_live_sql(ctx):
    say('Resolving %d SQL host(s)' % len(ctx.host_names))
    host_objs = []
    skipped = []
    for host_name in ctx.host_names:
        found = [n for n in get_sql_host_instances(ctx, host_name) if ieq(n.get('name'), host_name)]
        if not found:
            skipped.append({'host': host_name, 'status': 'SkippedNotFound',
                            'reason': "no SQL host with this exact name on cluster '%s'" % ctx.args.cluster_name})
            continue
        if len(found) >= 2:
            skipped.append({'host': host_name, 'status': 'SkippedAmbiguous',
                            'reason': 'more than one SQL host has this exact name'})
            continue
        node = found[0]
        instance_nodes = [e.get('node') for e in (dig(node, 'instanceDescendantConnection', 'edges') or [])]
        if not instance_nodes:
            skipped.append({'host': host_name, 'status': 'SkippedNoInstances', 'rbsState': rbs_state_of(node),
                            'reason': 'SQL host has no SQL instances'})
            continue
        cluster = node.get('cluster') or {}
        rbs = rbs_state_of(node)
        instances = [object_from_node(node['name'], node['id'], cluster.get('id'), cluster.get('name'), n, rbs)
                     for n in instance_nodes]
        host_objs.append({'name': node['name'], 'id': node['id'], 'rbsState': rbs, 'instances': instances})
    say('Resolved %d of %d SQL host(s), skipping %d' % (len(host_objs), len(ctx.host_names), len(skipped)),
        'yellow' if skipped else None)
    return host_objs, [], skipped


def resolve_live_fileset(ctx):
    args = ctx.args
    if args.fileset_template_id:
        say("Resolving fileset template ID '%s'" % args.fileset_template_id)
        try:
            tmpl = get_template_by_id(ctx, args.fileset_template_id)
        except Exception as exc:
            set_host_csv_not_run(ctx, 'could not look up fileset template ID %s' % args.fileset_template_id)
            raise Stop('Could not look up fileset template ID %s: %s' % (args.fileset_template_id, exc))
        if not tmpl:
            set_host_csv_not_run(ctx, 'no fileset template found with ID %s' % args.fileset_template_id)
            raise Stop('No fileset template found with ID: %s' % args.fileset_template_id)
        templates = [tmpl]
        ctx.fileset_name = tmpl['name']
    else:
        say("Resolving fileset template '%s'" % ctx.fileset_name)
        templates = [t for t in get_templates_by_name(ctx, ctx.fileset_name, args.host_root)
                     if ieq(t.get('name'), ctx.fileset_name)]
        if not templates:
            searched = "%s on cluster '%s'" % (args.host_root, args.cluster_name)
            other_root = 'WINDOWS_HOST_ROOT' if args.host_root == 'LINUX_HOST_ROOT' else 'LINUX_HOST_ROOT'
            hint = ''
            try:
                elsewhere = [t for t in get_templates_by_name(ctx, ctx.fileset_name, other_root)
                             if ieq(t.get('name'), ctx.fileset_name)]
                if elsewhere:
                    where = ', '.join(unique_ordered(dig(t, 'cluster', 'name') for t in elsewhere))
                    hint = ' A template with that name exists under %s (cluster: %s). Use --host-root %s.' % (
                        other_root, where, other_root)
            except Exception:
                pass
            set_host_csv_not_run(ctx, "no fileset template named '%s' under %s" % (ctx.fileset_name, searched))
            raise Stop("No fileset template found with exact name '%s' under %s.%s" % (ctx.fileset_name, searched, hint))

    say('Resolving %d host(s)' % len(ctx.host_names))
    host_objs = []
    skipped = []
    for host_name in ctx.host_names:
        found = [h for h in get_filesets_for_host(ctx, host_name) if ieq(h.get('name'), host_name)]
        if not found:
            skipped.append({'host': host_name, 'status': 'SkippedNotFound',
                            'reason': "no host with this exact name under %s on cluster '%s'" % (args.host_root, args.cluster_name)})
            continue
        if len(found) >= 2:
            skipped.append({'host': host_name, 'status': 'SkippedAmbiguous', 'reason': 'more than one host has this exact name'})
            continue
        host = found[0]
        cluster = host.get('cluster') or {}
        host_template = [t for t in templates if ieq(dig(t, 'cluster', 'id'), cluster.get('id'))]
        if len(host_template) != 1:
            skipped.append({'host': host_name, 'status': 'SkippedNoTemplate', 'rbsState': rbs_state_of(host),
                            'reason': "expected 1 fileset template '%s' on cluster '%s', found %d" % (
                                ctx.fileset_name, cluster.get('name'), len(host_template))})
            continue
        children = [e.get('node') for e in (dig(host, 'physicalChildConnection', 'edges') or [])]
        matching = [c for c in children if ieq(dig(c, 'filesetTemplate', 'id'), host_template[0]['id'])]
        rbs = rbs_state_of(host)
        instances = [object_from_node(host['name'], host['id'], cluster.get('id'), cluster.get('name'), n, rbs)
                     for n in matching]
        host_objs.append({
            'name': host['name'], 'id': host['id'], 'clusterId': cluster.get('id'), 'rbsState': rbs,
            'clusterName': cluster.get('name'), 'templateId': host_template[0]['id'], 'instances': instances,
        })
    say('Resolved %d of %d host(s), skipping %d' % (len(host_objs), len(ctx.host_names), len(skipped)),
        'yellow' if skipped else None)
    pending_hosts = [h for h in host_objs if not h['instances']]
    return host_objs, pending_hosts, skipped


### TEMPLATE APPLICATION ###


def apply_templates(ctx, need_template_hosts, apply_objects, spec):
    """Apply the fileset template to hosts that do not have it, and add the new filesets to apply_objects.
    Default: the fileset IDs returned by the template call are used as they are. With --recheck-fileset-ids
    each host is looked up again. Returns (template_rows, unverified)."""
    args = ctx.args
    template_rows = []
    unverified = False
    say("Applying fileset template '%s' to %d host(s) on cluster '%s'" % (
        ctx.fileset_name, len(need_template_hosts), args.cluster_name), 'cyan')

    def failed_row(host_name, error):
        return {
            'workload': ctx.workload, 'assignMutation': args.assign_mutation, 'applyMode': args.apply_mode,
            'host': host_name, 'object': ctx.fileset_name, 'objectId': '',
            'beforeAssignment': '', 'beforeSla': '', 'targetSla': spec['label'],
            'callGroup': None, 'callSec': None, 'effectiveSec': None,
            'status': 'TemplateFailed', 'error': error,
        }

    for cluster_id, hosts in group_by(need_template_hosts, lambda h: h['clusterId']):
        definitions = [{'hostId': h['id'], 'templateId': h['templateId']} for h in hosts]
        template_error = ''
        created_ids = []
        try:
            create_result = new_filesets_on_cluster(ctx, cluster_id, definitions)
            created = dig(create_result['data'], 'bulkCreateFilesets', 'data') or []
            created_ids = [i for i in (dig(c, 'filesetSummary', 'slaAssignable', 'id') for c in created) if i]
            say('  Applied to %d host(s) in %ss, %d fileset ID(s) returned' % (
                len(hosts), fmt_cell(round(create_result['seconds'], 2)), len(created_ids)))
        except Exception as exc:
            template_error = str(exc)
            say('  FAILED to apply the template to %d host(s): %s' % (len(hosts), template_error), 'red')

        if template_error:
            for h in hosts:
                template_rows.append(failed_row(h['name'], template_error))
            continue

        if args.recheck_fileset_ids:
            for h in hosts:
                found = [x for x in get_filesets_for_host(ctx, h['name']) if ieq(x.get('id'), h['id'])]
                children = []
                if len(found) == 1:
                    children = [e.get('node') for e in (dig(found[0], 'physicalChildConnection', 'edges') or [])]
                new_objs = [object_from_node(h['name'], h['id'], h['clusterId'], h['clusterName'], c, rbs_state_of(found[0]) if len(found) == 1 else h.get('rbsState') or 'unknown')
                            for c in children if ieq(dig(c, 'filesetTemplate', 'id'), h['templateId'])]
                if not new_objs:
                    template_rows.append(failed_row(h['name'], 'The fileset was not found on the host after applying the template'))
                else:
                    apply_objects.extend(new_objs)
        else:
            # The response does not say which host each ID belongs to, so a host is shown only when exactly
            # one host was in the call. A new fileset has no SLA and nothing pending.
            single_host = hosts[0] if len(hosts) == 1 else None
            if len(created_ids) != len(hosts):
                unverified = True
                say('  WARNING: %d host(s) were sent but %d fileset ID(s) came back. Use --recheck-fileset-ids '
                    'to confirm each host.' % (len(hosts), len(created_ids)), 'yellow')
            for oid in created_ids:
                host_label = single_host['name'] if single_host else '(new on %s)' % hosts[0]['clusterName']
                apply_objects.append({
                    'hostName': host_label,
                    'rbsState': single_host.get('rbsState') or 'unknown' if single_host else 'unknown',
                    'hostId': single_host['id'] if single_host else 'new-%s' % cluster_id,
                    'clusterId': cluster_id, 'clusterName': hosts[0]['clusterName'],
                    'instanceName': ctx.fileset_name, 'instanceId': oid,
                    'assignment': 'Unassigned', 'currentSla': '',
                    'state': {'id': oid, 'slaAssignment': 'Unassigned',
                              'effectiveSlaDomain': {'id': '', 'name': ''}, 'pendingSla': None},
                })
    return template_rows, unverified


### HOST STATUS ###


def classify(rows, bad_statuses):
    """Host status from its object rows. Failed objects (bad_statuses) are failures. A Timeout is not: RSC accepted
    the call and the script only stopped waiting, so a host with only Timeout objects is Unconfirmed, not Failed.
    Returns (status, ok, bad, skip) where bad holds the failed and the unconfirmed rows, so the detail lists both."""
    ok = [r for r in rows if r['status'] in OK_STATUSES]
    failed = [r for r in rows if r['status'] in bad_statuses and r['status'] != 'Timeout']
    unconfirmed = [r for r in rows if r['status'] == 'Timeout']
    skip = [r for r in rows if r['status'] == 'SkippedPending']
    if not failed and not unconfirmed and not skip:
        status = 'Assigned'
    elif ok:
        status = 'Partial'
    elif failed:
        status = 'Failed' if not unconfirmed else 'Partial'
    elif unconfirmed:
        status = 'Unconfirmed'
    else:
        status = 'Skipped'
    return status, ok, failed + unconfirmed, skip


def skip_row(ctx, spec, skip):
    """Apply CSV row for a skipped host: no object, the skip status, and the reason in the error column."""
    return {
        'workload': ctx.workload, 'host': skip['host'], 'hostStatus': skip['status'], 'rbsState': skip.get('rbsState', 'unknown'),
        'object': '', 'objectId': '',
        'targetSla': spec['label'], 'assignMutation': ctx.args.assign_mutation, 'applyMode': ctx.args.apply_mode,
        'status': skip['status'], 'error': skip['reason'],
    }


def print_skipped_hosts(skipped_hosts, indent='    '):
    """Print the skipped hosts grouped by why they were skipped. The reason for each host is in the CSVs."""
    for status, group in group_by(skipped_hosts, lambda x: x['status']):
        say('%s%s (%d): %s' % (indent, SKIP_HOST_LABELS.get(status, status), len(group), ', '.join(x['host'] for x in group)), 'yellow')


def build_host_log_rows(ctx, apply_rows, need_template_hosts, skipped_hosts, unverified):
    rows_in_run = list(apply_rows)
    host_groups = group_by(rows_in_run, lambda r: ('' if r['host'] is None else str(r['host'])).casefold())
    new_on_groups = [g for g in host_groups if g[1][0]['host'].casefold().startswith('(new on ')]
    host_groups = [g for g in host_groups if not g[1][0]['host'].casefold().startswith('(new on ')]
    template_host_names = set(h['name'].casefold() for h in need_template_hosts)

    host_log_rows = []
    for _, rows_for_host in sorted(host_groups, key=lambda g: g[0]):
        name = rows_for_host[0]['host']
        status, ok, bad, skip = classify(rows_for_host, BAD_STATUSES)
        template_applied = (name.casefold() in template_host_names
                            and not any(r['status'] == 'TemplateFailed' for r in rows_for_host))
        host_log_rows.append({
            'workload': ctx.workload, 'host': name, 'status': status, 'templateApplied': template_applied,
            'objects': len(rows_for_host),
            'slaAssigned': sum(1 for r in rows_for_host if r['status'] in ('Applied', 'Submitted')),
            'alreadyOnTarget': sum(1 for r in rows_for_host if r['status'] == 'AlreadyOnTarget'),
            'skippedPending': len(skip), 'notAssigned': len(bad),
            'detail': '; '.join('%s: %s' % (r['object'], r['status']) for r in bad + skip),
        })

    if new_on_groups:
        shared_rows = [r for _, rows in new_on_groups for r in rows]
        shared_status, _, shared_bad, shared_skip = classify(shared_rows, ('CallFailed', 'Timeout', 'NotAttempted'))
        have_row = set(h['host'].lower() for h in host_log_rows)
        failed_template_hosts = set(str(r['host']).lower() for r in apply_rows if r['status'] == 'TemplateFailed')
        if unverified:
            detail = 'unverified: fewer fileset IDs came back than hosts were sent, rerun with --recheck-fileset-ids to confirm this host'
        else:
            detail = 'new filesets on the cluster, shared result (not tied to this host)'
        for nh in need_template_hosts:
            if nh['name'].lower() in have_row or nh['name'].lower() in failed_template_hosts:
                continue
            host_log_rows.append({
                'workload': ctx.workload, 'host': nh['name'], 'status': shared_status, 'templateApplied': True,
                'objects': len(shared_rows),
                'slaAssigned': sum(1 for r in shared_rows if r['status'] in ('Applied', 'Submitted')),
                'alreadyOnTarget': sum(1 for r in shared_rows if r['status'] == 'AlreadyOnTarget'),
                'skippedPending': len(shared_skip), 'notAssigned': len(shared_bad), 'detail': detail,
            })

    for skip in skipped_hosts:
        host_log_rows.append({
            'workload': ctx.workload, 'host': skip['host'], 'status': skip['status'], 'templateApplied': False,
            'objects': 0, 'slaAssigned': 0, 'alreadyOnTarget': 0, 'skippedPending': 0, 'notAssigned': 0,
            'detail': skip['reason'],
        })
    return host_log_rows


def executed_text(row):
    status = row['status']
    if status == 'Assigned':
        if row['templateApplied'] and row['detail'].casefold().startswith('unverified:'):
            return 'TemplateApplied+Assigned (unverified, fewer fileset IDs than hosts, use --recheck-fileset-ids)'
        if row['templateApplied']:
            return 'TemplateApplied+Assigned'
        if row['objects'] > 0 and row['alreadyOnTarget'] == row['objects']:
            return 'AlreadyOnTarget'
        return 'Assigned'
    if status == 'Partial':
        return 'Partial: %d of %d objects, %s' % (row['slaAssigned'] + row['alreadyOnTarget'], row['objects'], row['detail'])
    if status == 'Failed':
        return 'Failed: %s' % row['detail']
    if status == 'Unconfirmed':
        return 'Unconfirmed: accepted by RSC, not seen effective before the timeout, check later (%s)' % row['detail']
    if status == 'Skipped':
        return 'Skipped: pending SLA, %s' % row['detail']
    if status in SKIP_HOST_LABELS:
        return 'Skipped: %s' % row['detail']
    return str(status)


### CHECK AN APPLY CSV ###

CHECK_COLUMNS = ['currentPendingSLA', 'currentEffectiveSLA', 'checkResult']


def check_result(row, state):
    """Compare an object's current SLA with the target SLA recorded in its Apply CSV row."""
    if state is None:
        return 'Not found'
    if dig(state, 'pendingSla', 'name') or dig(state, 'pendingSla', 'id'):
        return 'Pending'
    target = str(row.get('targetSla') or '').strip()
    if not target:
        return 'Checked'
    eff_id = dig(state, 'effectiveSlaDomain', 'id')
    eff_name = dig(state, 'effectiveSlaDomain', 'name')
    if ieq(target, 'NO_ASSIGNMENT'):
        on_target = not ieq(state.get('slaAssignment'), 'Direct')
    elif ieq(target, 'DO_NOT_PROTECT'):
        on_target = ieq(eff_id, 'DO_NOT_PROTECT')
    else:
        on_target = ieq(eff_name, target) or ieq(eff_id, target)
    return 'Effective on target' if on_target else 'Different SLA'


def run_check_apply_csv_status(ctx):
    """--check-apply-csv-status: read the objects in an Apply CSV, look up their current SLA in RSC, and write
    <name>_checked.csv with currentPendingSLA, currentEffectiveSLA and checkResult added. Read-only in RSC."""
    args = ctx.args
    path = args.check_apply_csv_status
    for attr, flag in (('assign', '--assign'), ('hosts', '--hosts'), ('host_csv_path', '--host-csv-path'),
                       ('inventory_csv', '--inventory-csv'), ('sla_name', '--sla-name'), ('sla_id', '--sla-id'),
                       ('sql_sla_name', '--sql-sla-name'), ('sql_sla_id', '--sql-sla-id'),
                       ('fileset_sla_name', '--fileset-sla-name'), ('fileset_sla_id', '--fileset-sla-id'),
                       ('fileset_name', '--fileset-name'), ('fileset_template_id', '--fileset-template-id')):
        if getattr(args, attr):
            die('--check-apply-csv-status only reads an Apply CSV and checks it, so it cannot be combined with %s.' % flag)
    if not args.rsc_service_account_json:
        die('--rsc-service-account-json is required.')
    if not os.path.isfile(path):
        die('Apply CSV not found: %s' % path)
    base, ext = os.path.splitext(path)
    if base.endswith('_checked'):
        die('That file is already a checked file. Give the original Apply CSV: %s' % path)
    out_path = '%s_checked%s' % (base, ext or '.csv')

    fieldnames, rows = read_csv_rows(path)
    if not rows or 'objectId' not in fieldnames:
        die("Not an Apply CSV (it needs an 'objectId' column and at least one row): %s" % path)

    object_ids = unique_ordered(r['objectId'].strip() for r in rows if r.get('objectId', '').strip())
    say('Apply CSV: %s (%d row(s), %d object(s) to look up)' % (path, len(rows), len(object_ids)))

    configure_tls(ctx)
    authenticate(ctx)

    states = {}
    failed = {}
    for start in range(0, len(object_ids), POLL_CHUNK):
        chunk = object_ids[start:start + POLL_CHUNK]
        try:
            for state in get_sla_states(ctx, chunk):
                states[ikey(state.get('id'))] = state
        except Exception as exc:
            for object_id in chunk:
                failed[ikey(object_id)] = str(exc)
            say('  Lookup failed for %d object(s): %s' % (len(chunk), exc), 'yellow')

    columns = list(fieldnames) + [c for c in CHECK_COLUMNS if c not in fieldnames]
    out_rows = []
    for row in rows:
        new = dict(row)
        object_id = row.get('objectId', '').strip()
        if not object_id:
            new.update({'currentPendingSLA': '', 'currentEffectiveSLA': '', 'checkResult': ''})
        elif ikey(object_id) in failed:
            new.update({'currentPendingSLA': '', 'currentEffectiveSLA': '', 'checkResult': 'Lookup failed'})
        else:
            state = states.get(ikey(object_id))
            new['currentPendingSLA'] = dig(state, 'pendingSla', 'name') or '' if state else ''
            new['currentEffectiveSLA'] = dig(state, 'effectiveSlaDomain', 'name') or '' if state else ''
            new['checkResult'] = check_result(row, state)
        out_rows.append(new)

    tmp = out_path + '.tmp'
    try:
        write_csv(tmp, out_rows, columns)
        os.replace(tmp, out_path)
    except Exception as exc:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
        die('Could not write %s: %s' % (out_path, exc))

    say('')
    say('Checked at %s' % datetime.now().strftime('%Y-%m-%d %H:%M:%S'), 'cyan')
    counts = [{'checkResult': name, 'Count': len(group)}
              for name, group in sorted(group_by([r for r in out_rows if r['checkResult']], lambda r: r['checkResult']),
                                        key=lambda g: g[0].casefold())]
    print_table(counts, ['checkResult', 'Count'])
    no_object = sum(1 for r in out_rows if not r.get('objectId', '').strip())
    if no_object:
        say('%d row(s) have no object (skipped hosts) and are left blank.' % no_object)
    say('Checked CSV (the same file is overwritten on each check): %s' % out_path, 'green')
    return 1 if failed else 0


### ARGUMENTS ###


def ci_choice(options):
    def convert(value):
        for option in options:
            if option.casefold() == value.casefold():
                return option
        raise argparse.ArgumentTypeError('invalid choice: %r (choose from %s)' % (value, ', '.join(options)))
    return convert


def print_usage_summary():
    say('')
    say('set_sla_sql_fileset.py', 'cyan')
    say('Assign an SLA in RSC to SQL instances, to filesets, or to both, on a list of hosts.')
    say('Python port of the Apply path of Set-SLA-SQL-Fileset.ps1. Hosts come from a CSV or a host list.')
    say('')
    say('--assign is required: sqlOnly, filesetOnly or both', 'cyan')
    say('  sqlOnly:      python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign sqlOnly --host-csv-path ./hosts.csv --sla-name Gold --cluster-name cluster01')
    say('  filesetOnly:  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign filesetOnly --host-csv-path ./hosts.csv --fileset-name Temp --sla-name Gold --cluster-name cluster01')
    say('  both:         python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --assign both --host-csv-path ./hosts.csv --fileset-name Temp --sql-sla-name MSSQL_Gold --fileset-sla-name WIN_Gold --cluster-name cluster01')
    say('  SLA:          --sla-name is for every workload. With both, use --sql-sla-name and --fileset-sla-name (or the -id versions).')
    say('  both = two independent passes on the same host list, SQL first and then filesets. Each has its own plan,')
    say('  its own confirmation, and its own Apply CSV. A failure in one pass does not stop the other.')
    say('')
    say('FILESETS', 'cyan')
    say('  --fileset-name (or --fileset-template-id) must already exist. Hosts without it get it applied first.')
    say('')
    say('FROM AN INVENTORY', 'cyan')
    say('  Add --inventory-csv <file> (written by the PowerShell script, -getSqlInventory / -getFilesetInventory).')
    say('  With --assign both give two files, one SQL and one fileset.')
    say('')
    say('FILES', 'cyan')
    say('  Creates:    sql_sla_apply-<time>.csv, fileset_sla_apply-<time>.csv   starting SLA of every object, then its outcome and host status')
    say('              sql_sla_assign_log-<time>.txt, fileset_sla_assign_log-<time>.txt   from --assign-log: every SLA assignment call')
    say("  Updates:    your --host-csv-path file, in place: 'executed_sql' and 'executed_fileset' get each host's last status")
    say("              and time for that workload (a run changes only its own column), and 'rbsState' gets its RBS connection")
    say("              state. The original is kept once as <file>.bak.")
    say('  New files go in the current folder, or where --csv-output-prefix points.')
    say('')
    say('CHECK A RUN LATER', 'cyan')
    say('  python3 set_sla_sql_fileset.py --rsc-service-account-json ./rsc-sa.json --check-apply-csv-status ./rubrik_sql_sla_apply-<time>.csv')
    say('  Writes rubrik_sql_sla_apply-<time>_checked.csv with currentPendingSLA, currentEffectiveSLA and checkResult. Read-only.')
    say('')
    say('ALL RUNS', 'cyan')
    say('  --cluster-name is required: every lookup and every assignment call is on that one cluster.')
    say('  Add --dry-run to preview: it changes no SLA and writes no Apply CSV (it refreshes the host CSV rbsState column).')
    say('  Apply changes real SLAs and never reverts them.')
    say('  You are asked to confirm (y or yes, any case) before anything changes. Add --skip-confirm to skip that.')
    say('  --hosts (a list on the command line) can replace the CSV. Then no host CSV is updated.')
    say('  A host that cannot be used is skipped, not fatal: the rest are applied. Each skip and its reason is in the plan, the')
    say('  Apply CSV (error column) and the host CSV, and the exit code is 1 if any host was skipped.')
    say('  Hosts not found? Add --debug: it writes the SQL hosts RSC returns, with and without the cluster filter, to files.')
    say('  TLS certificate verification is off by default (self-signed certificates work). Add --verify-ssl to verify.')
    say("  Run 'python3 set_sla_sql_fileset.py --help' for every option.")
    say('')


def build_parser():
    parser = argparse.ArgumentParser(
        description='Assign an SLA Domain to the SQL instances or filesets on a list of hosts in RSC. '
                    'Python port of the Apply path of Set-SLA-SQL-Fileset.ps1.',
        epilog='IMPORTANT: this changes real SLA assignments and never reverts them. Run with --dry-run first.',
        allow_abbrev=False)
    parser.add_argument('--rsc-service-account-json', help='Path to the RSC Service Account JSON (client_id, client_secret, access_token_uri). Required.')
    parser.add_argument('--cluster-name', help='Exact name of the one cluster to work on. Required. Every lookup and every assignment call is on this cluster.')
    parser.add_argument('--assign', type=ci_choice(ASSIGN_CHOICES), help='What to assign: sqlOnly (SQL instances), filesetOnly (filesets of --fileset-name) or both (SQL pass, then fileset pass, on the same host list). Required, except with --check-apply-csv-status.')
    parser.add_argument('--check-apply-csv-status', metavar='APPLY_CSV', help='Read-only. Look up the current SLA of every object in an Apply CSV and write <name>_checked.csv next to it with currentPendingSLA, currentEffectiveSLA and checkResult columns added (an existing _checked file is overwritten). Needs only --rsc-service-account-json. Use it after a cancelled run, or to see where a run got to.')
    parser.add_argument('--hosts', nargs='+', metavar='HOST', help='Host names (exact match, case-insensitive). Space or comma separated. Used for SQL and for filesets. The CSV wins if both are given.')
    parser.add_argument('--host-csv-path', help='Host CSV with a hostname, host, name or sqlhost column. Updated in place with executed_sql and executed_fileset (the last status and time for each host in that workload) and rbsState (the host RBS connection state). The original is kept once as <file>.bak.')
    parser.add_argument('--fileset-name', help='Name of the existing fileset template (exact match). Hosts without it get it applied. Never created or changed.')
    parser.add_argument('--fileset-template-id', help='ID of the existing fileset template, instead of --fileset-name.')
    parser.add_argument('--host-root', type=ci_choice(['WINDOWS_HOST_ROOT', 'LINUX_HOST_ROOT']), default='WINDOWS_HOST_ROOT', help='Host type for fileset hosts and templates. Default: WINDOWS_HOST_ROOT')
    parser.add_argument('--sla-name', help='SLA Domain name to assign (exact match). Can also be DO_NOT_PROTECT or NO_ASSIGNMENT. Use this or --sla-id. With --assign both it is used for both passes unless --sql-sla-* or --fileset-sla-* is given. SQL and filesets usually need different SLAs, so with both use the workload-specific options.')
    parser.add_argument('--sla-id', help='SLA Domain ID to assign. Use this or --sla-name.')
    parser.add_argument('--sql-sla-name', help='SLA Domain name for the SQL pass only. Overrides --sla-name / --sla-id for SQL. Same values as --sla-name.')
    parser.add_argument('--sql-sla-id', help='SLA Domain ID for the SQL pass only. Overrides --sla-name / --sla-id for SQL.')
    parser.add_argument('--fileset-sla-name', help='SLA Domain name for the fileset pass only. Overrides --sla-name / --sla-id for filesets. Same values as --sla-name.')
    parser.add_argument('--fileset-sla-id', help='SLA Domain ID for the fileset pass only. Overrides --sla-name / --sla-id for filesets.')
    parser.add_argument('--assign-mutation', type=ci_choice(['AssignSla', 'AssignSlasForSnappableHierarchies']), default='AssignSla', help='GraphQL mutation used to assign the SLA. Default: AssignSla')
    parser.add_argument('--apply-mode', type=ci_choice(['Bulk', 'Single']), default='Bulk', help='Bulk sends up to --batch-size objects per call, Single sends one call per host. Default: Bulk')
    parser.add_argument('--batch-size', type=int, default=50, help='Maximum objects per call with --apply-mode Bulk. Default: 50')
    parser.add_argument('--assign-log', action='store_true', help='Write the details of every assignment call to <prefix><workload>_sla_assign_log-<timestamp>.txt')
    parser.add_argument('--skip-polling', '--no-wait', dest='skip_polling', action='store_true', help='Submit the assignments and exit without polling. The state is recorded as Submitted.')
    parser.add_argument('--recheck-fileset-ids', action='store_true', help='Fileset hosts: after applying the template, look each host up again instead of using the returned fileset IDs.')
    parser.add_argument('--inventory-csv', nargs='+', metavar='CSV', help='Inventory CSV from the PowerShell script (-getSqlInventory / -getFilesetInventory). Host, cluster, template and object IDs and SLA state come from it instead of RSC. With --assign both give two files, one SQL and one fileset (matched by the workload in each file).')
    parser.add_argument('--inventory-max-age-hours', type=int, default=24, help='With --inventory-csv, warn if the file is older than this. Default: 24')
    parser.add_argument('--poll-interval-sec', type=int, default=30, help='Seconds between polls. Default: 30')
    parser.add_argument('--timeout-sec', type=int, default=3600, help='Maximum seconds to wait for all objects to show the SLA, counted per pass. Default: 3600 (60 minutes). An object not confirmed by then is recorded as Timeout, which does not mean the assignment failed.')
    parser.add_argument('--csv-output-prefix', default='./rubrik_', help='Location and prefix for output files. The report name and timestamp are appended. The directory must exist. Default: ./rubrik_')
    parser.add_argument('--verify-ssl', action='store_true', help='Verify the TLS certificate. Off by default, so self-signed certificates work. With verification off the token and every API call could be intercepted, so add this on a network you do not trust.')
    parser.add_argument('--debug', action='store_true', help='SQL pass only: before resolving hosts, get every SQL host RSC returns with no cluster filter and with the --cluster-name filter, compare with the listed hosts, and write the results to sql_debug_*.csv and sql_debug_raw-*.json (nothing is listed on screen). Read-only.')
    parser.add_argument('--dry-run', action='store_true', help='Show the plan and exit without changing any SLA. No Apply CSV is written. The host CSV (--host-csv-path) rbsState column is refreshed, since the run reads each host state.')
    parser.add_argument('--skip-confirm', action='store_true', help='Skip the confirmation prompt (y or yes).')
    return parser


def validate_and_collect_hosts(ctx):
    """Validate the arguments and build the shared host list. Sets ctx.workloads, ctx.host_names and
    ctx.inventory_by_workload."""
    args = ctx.args
    if not args.rsc_service_account_json:
        die('--rsc-service-account-json is required.')
    if args.inventory_max_age_hours < 1:
        die('--inventory-max-age-hours must be 1 or greater.')
    if args.batch_size < 1:
        die('--batch-size must be 1 or greater.')
    if not args.cluster_name:
        die('Runs need --cluster-name. Every lookup, and every assignment call, is on that one cluster.')
    if args.poll_interval_sec < 1:
        die('--poll-interval-sec must be 1 or greater.')

    # --assign chooses the workloads, in the order the passes run
    ctx.workloads = {'sqlonly': ['SQL'], 'filesetonly': ['Fileset'], 'both': ['SQL', 'Fileset']}[args.assign.lower()]

    # The SLA for each workload: its own option, otherwise the shared --sla-name / --sla-id
    def pick_sla(prefix, label, shared_only_ok):
        own_name = getattr(args, '%s_sla_name' % prefix)
        own_id = getattr(args, '%s_sla_id' % prefix)
        if own_name and own_id:
            die('Specify either --%s-sla-name or --%s-sla-id, not both.' % (prefix, prefix))
        if own_name or own_id:
            return own_name, own_id
        if args.sla_name and args.sla_id:
            die('Specify either --sla-name or --sla-id, not both.')
        if args.sla_name or args.sla_id:
            return args.sla_name, args.sla_id
        die('Provide the %s SLA with --%s-sla-name or --%s-sla-id%s.' % (
            label, prefix, prefix, ' (or --sla-name / --sla-id for every workload)' if shared_only_ok else ''))

    ctx.sla_by_workload = {}
    for workload in ctx.workloads:
        prefix = 'sql' if workload == 'SQL' else 'fileset'
        ctx.sla_by_workload[workload] = pick_sla(prefix, 'SQL' if workload == 'SQL' else 'fileset', True)
    # A workload-specific SLA for a workload this run does not cover would be silently ignored, so refuse it
    for prefix, label, workload in (('sql', 'SQL', 'SQL'), ('fileset', 'fileset', 'Fileset')):
        if workload not in ctx.workloads and (getattr(args, '%s_sla_name' % prefix) or getattr(args, '%s_sla_id' % prefix)):
            die('--%s-sla-name / --%s-sla-id only apply when --assign includes %s (--assign %s).' % (
                prefix, prefix, label, args.assign))

    # Fileset-only options are rejected for sqlOnly so they are never silently ignored
    if 'Fileset' not in ctx.workloads:
        for flag, used in (('--fileset-name', args.fileset_name), ('--fileset-template-id', args.fileset_template_id),
                           ('--recheck-fileset-ids', args.recheck_fileset_ids)):
            if used:
                die('%s only applies with --assign filesetOnly or both.' % flag)
        if args.host_root != 'WINDOWS_HOST_ROOT':
            die('--host-root only applies with --assign filesetOnly or both.')
    else:
        if not args.fileset_name and not args.fileset_template_id:
            die('Provide the fileset template with --fileset-name or --fileset-template-id.')
        if args.fileset_name and args.fileset_template_id:
            die('Specify either --fileset-name or --fileset-template-id, not both.')

    # Inventory CSVs: one per workload, matched by the workload column in each file
    for path in args.inventory_csv or []:
        if not os.path.isfile(path):
            die('Inventory CSV not found: %s' % path)
    if args.inventory_csv:
        for path in args.inventory_csv:
            _, peek_rows = read_csv_rows(path)
            if not peek_rows or not peek_rows[0].get('workload'):
                die("Inventory CSV has no rows or no 'workload' column: %s" % path)
            workload = 'SQL' if ieq(peek_rows[0]['workload'], 'SQL') else 'Fileset'
            if workload not in ctx.workloads:
                die("Inventory CSV %s is for %s, which --assign %s does not run." % (path, workload, args.assign))
            if workload in ctx.inventory_by_workload:
                die('Two %s inventory CSVs were given. Give at most one per workload.' % workload)
            ctx.inventory_by_workload[workload] = path
        missing = [w for w in ctx.workloads if w not in ctx.inventory_by_workload]
        if missing and len(ctx.workloads) > 1:
            die('--inventory-csv with --assign both needs one file for each workload. Missing: %s.' % ', '.join(missing))

    hosts = split_names(args.hosts)
    if args.host_csv_path:
        if hosts:
            say('Both --hosts and --host-csv-path were given. Using the hosts in the CSV and ignoring --hosts.', 'yellow')
        names = read_host_csv(ctx, args.host_csv_path, HOST_COLUMNS)
    else:
        names = hosts
    ctx.host_names = unique_ordered([str(n).strip() for n in names if str(n).strip()])
    if not ctx.host_names and not args.inventory_csv:
        die('Provide hosts with --hosts and/or --host-csv-path.')


### MAIN ###


def configure_tls(ctx):
    """TLS certificate verification is off unless --verify-ssl is given."""
    if ctx.args.verify_ssl:
        ctx.verify = True
    else:
        ctx.verify = False
        requests.packages.urllib3.disable_warnings(requests.packages.urllib3.exceptions.InsecureRequestWarning)
        say('Note: TLS certificate verification is off (add --verify-ssl to turn it on).', 'yellow')


def run(ctx):
    """Shared setup, then one pass per workload (SQL first, then Fileset for --assign both).
    Each pass is independent: a failure in one does not stop the next. Returns 1 if any pass had a problem."""
    args = ctx.args
    validate_and_collect_hosts(ctx)
    ctx.date_string = datetime.now().strftime('%Y-%m-%d_%H%M%S')

    configure_tls(ctx)

    authenticate(ctx)

    # Resolve --cluster-name once. Template and host lookups then filter by this cluster ID.
    ctx.cluster_id = get_cluster_id_by_name(ctx, args.cluster_name)
    say("Limiting lookups to cluster '%s' (%s)" % (args.cluster_name, ctx.cluster_id))

    # Resolve every SLA before any pass runs, so a wrong SLA name stops the run before anything changes.
    # Workloads that share the same SLA are looked up once.
    specs = {}
    cache = {}
    for workload in ctx.workloads:
        name, sla_id = ctx.sla_by_workload[workload]
        key = (name, sla_id)
        if key not in cache:
            try:
                cache[key] = resolve_sla_spec(ctx, name, sla_id)
            except Stop as exc:
                raise Stop('%s SLA: %s' % (workload, exc))
        specs[workload] = cache[key]

    exit_code = 0
    for workload in ctx.workloads:
        if len(ctx.workloads) > 1:
            say('')
            say('=' * 100)
            say('Pass %d of %d: %s' % (ctx.workloads.index(workload) + 1, len(ctx.workloads), workload), 'cyan')
            say('=' * 100)
        try:
            code = run_pass(ctx, workload, specs[workload])
        except Stop as exc:
            say('ERROR (%s pass): %s' % (workload, exc), 'red')
            code = 1
        except KeyboardInterrupt:
            raise
        except Exception as exc:
            say('ERROR (%s pass): %s' % (workload, exc), 'red')
            code = 1
        if code:
            exit_code = 1
    if len(ctx.workloads) > 1:
        say('')
        say('Both passes finished. Exit code %d (1 means a pass had a problem, see the pass above).' % exit_code)
    return exit_code


def dry_run_refresh_rbs(ctx, rbs_by_host):
    """A dry run or a cancelled run changes no SLA, but it did read each host's RBS state, so the host CSV's
    rbsState column is refreshed. The executed columns are not touched."""
    if ctx.host_csv:
        update_host_csv_executed(ctx, None, rbs_by_host)


def run_pass(ctx, workload, target_spec):
    """Resolve, plan, confirm, assign and report for one workload."""
    args = ctx.args
    ctx.workload = workload
    ctx.inventory_path = ctx.inventory_by_workload.get(workload)
    ctx.fileset_name = args.fileset_name
    ctx.assign_call_number = 0
    workload_prefix = workload.lower()
    ctx.csv_apply_output = '%s%s_sla_apply-%s.csv' % (args.csv_output_prefix, workload_prefix, ctx.date_string)
    ctx.assign_log_output = '%s%s_sla_assign_log-%s.txt' % (args.csv_output_prefix, workload_prefix, ctx.date_string)

    if args.debug and workload == 'SQL':
        try:
            debug_sql_inventory(ctx)
        except Exception as exc:
            say('DEBUG inventory failed: %s' % exc, 'yellow')

    if ctx.inventory_path:
        host_objs, pending_hosts, skipped_hosts = resolve_from_inventory(ctx)
    elif ctx.workload == 'SQL':
        host_objs, pending_hosts, skipped_hosts = resolve_live_sql(ctx)
    else:
        host_objs, pending_hosts, skipped_hosts = resolve_live_fileset(ctx)

    # Fileset hosts that do not have the template yet get it applied after confirmation
    need_template_hosts = []
    if ctx.workload == 'Fileset':
        need_template_hosts = list(pending_hosts)
        host_objs = [h for h in host_objs if h['instances']]
    for nh in need_template_hosts:
        say("Host %s does not have fileset template '%s'. It will be applied." % (nh['name'], ctx.fileset_name), 'yellow')
    apply_objects = [o for h in host_objs for o in h['instances']]

    if not apply_objects and not need_template_hosts:
        if skipped_hosts:
            # Every listed host was skipped: nothing to assign. Record the skips in the Apply CSV and the host CSV
            say('WARNING: all %d listed host(s) were skipped, so nothing will be assigned:' % len(skipped_hosts), 'yellow')
            print_skipped_hosts(skipped_hosts, '  ')
            if args.dry_run:
                dry_run_refresh_rbs(ctx, collect_rbs(host_objs, need_template_hosts, skipped_hosts))
                say('Dry run, no SLA changes made.')
                return 0
            write_apply_csv(ctx, [skip_row(ctx, target_spec, x) for x in skipped_hosts], APPLY_COLUMNS)
            if ctx.host_csv:
                update_host_csv_executed(ctx, {x['host'].lower(): 'Skipped: %s' % x['reason'] for x in skipped_hosts}, collect_rbs(host_objs, need_template_hosts, skipped_hosts))
            say('The reason for each host is in the Apply CSV (error column): %s' % ctx.csv_apply_output, 'yellow')
            return 1
        raise Stop('No objects were found to assign the SLA to.')

    # Every object already carries its current SLA state from the lookup, so there is no separate read
    if not apply_objects:
        say('No existing objects: every host needs the template applied first, and the new filesets are read after that')
    decision_by_id = {ikey(o['instanceId']): get_sla_decision(o.get('state'), target_spec) for o in apply_objects}
    missing_state = [o for o in apply_objects if o.get('state') is None]
    if missing_state:
        say('No SLA state for %d object(s), they will be assigned.' % len(missing_state), 'yellow')
    todo_objects = [o for o in apply_objects if decision_by_id[ikey(o['instanceId'])] == 'Assign']
    on_target_count = sum(1 for v in decision_by_id.values() if v == 'AlreadyOnTarget')
    pending_count = sum(1 for v in decision_by_id.values() if v == 'SkippedPending')
    call_count = len(get_call_groups(todo_objects, args.apply_mode, args.batch_size))

    # Show the plan
    say('')
    say('Plan', 'cyan')
    say('  Action:                   Apply')
    if ctx.inventory_path:
        say('  Source:                   Inventory CSV (%s)' % ctx.inventory_path)
    else:
        say('  Source:                   Live RSC lookup')
    say('  Workload:                 %s' % ctx.workload)
    say('  Assign mutation:          %s' % args.assign_mutation)
    say('  Target SLA:               %s' % target_spec['label'])
    if args.apply_mode == 'Bulk':
        say('  Apply mode:               Bulk (up to %d objects per call)' % args.batch_size)
    else:
        say('  Apply mode:               Single (one call per host)')
    say('  Poll for completion:      %s' % (not args.skip_polling))
    if skipped_hosts:
        say('  Skipped hosts:            %d host(s) will get no SLA, listed below' % len(skipped_hosts), 'yellow')
    if ctx.workload == 'Fileset':
        say('  Fileset template:         %s' % ctx.fileset_name)
        say('  Hosts:                    %d already have it, %d need it applied' % (len(host_objs), len(need_template_hosts)))
    else:
        say('  Hosts:                    %d' % len(host_objs))
    say('  Objects:                  %d existing, %d to assign, %d already on target, %d skipped (SLA pending)' % (
        len(apply_objects), len(todo_objects), on_target_count, pending_count))
    if need_template_hosts:
        cluster_count = len(unique_ordered(h['clusterId'] for h in need_template_hosts))
        say('  Template applications:    %d host(s) in %d bulkCreateFilesets call(s), then the SLA goes on those new filesets too'
            % (len(need_template_hosts), cluster_count))
    skipped_pending_objs = [o for o in apply_objects if decision_by_id[ikey(o['instanceId'])] == 'SkippedPending']
    if skipped_hosts or skipped_pending_objs:
        say('  Skipped, no SLA will be assigned:', 'yellow')
        if skipped_hosts:
            print_skipped_hosts(skipped_hosts)
        if skipped_pending_objs:
            listing = ', '.join('%s/%s (pending %s)' % (o['hostName'], o['instanceName'], dig(o, 'state', 'pendingSla', 'name'))
                                for o in skipped_pending_objs)
            say('    Objects with an SLA already pending (%d): %s' % (len(skipped_pending_objs), listing), 'yellow')
    say('  API calls to assign:      %d (plus any for the new filesets)' % call_count)
    say('')
    action_text = {'AlreadyOnTarget': 'Skip: on target', 'SkippedPending': 'Skip: pending'}
    plan_rows = [{
        'hostName': o['hostName'], 'cluster': o['clusterName'], 'rbsState': o.get('rbsState') or 'unknown', 'object': o['instanceName'],
        'assignment': o['assignment'], 'currentSla': o['currentSla'],
        'pendingSla': dig(o, 'state', 'pendingSla', 'name') or '',
        'action': action_text.get(decision_by_id[ikey(o['instanceId'])], 'Assign'),
    } for o in apply_objects]
    for nh in need_template_hosts:
        plan_rows.append({'hostName': nh['name'], 'cluster': nh['clusterName'], 'rbsState': nh.get('rbsState') or 'unknown', 'object': ctx.fileset_name,
                          'assignment': '', 'currentSla': '', 'pendingSla': '', 'action': 'Apply template'})
    print_table(plan_rows, ['hostName', 'cluster', 'rbsState', 'object', 'action', 'currentSla', 'pendingSla', 'assignment'])
    not_connected = unique_ordered((str(r['hostName']), r['rbsState']) for r in plan_rows if r['rbsState'] not in ('CONNECTED', 'unknown') and not str(r['hostName']).startswith('(new on'))
    if not_connected:
        say('WARNING: %d host(s) are not CONNECTED (see the rbsState column). An SLA can still be assigned to them, but they will not back up until they reconnect:' % len(not_connected), 'yellow')
        for state, group in group_by(not_connected, lambda x: x[1]):
            say('  %s (%d): %s' % (state, len(group), ', '.join(x[0] for x in group)), 'yellow')
        say('')
    if todo_objects or need_template_hosts:
        say("'%s' will be assigned to %d object(s). Existing snapshots are retained. Nothing is reverted afterwards."
            % (target_spec['label'], len(todo_objects) + len(need_template_hosts)), 'yellow')
    if need_template_hosts:
        say("Fileset template '%s' will be applied to %d host(s) with bulkCreateFilesets. The template itself is not "
            "changed, and it stays applied to those hosts." % (ctx.fileset_name, len(need_template_hosts)), 'yellow')
    say('')

    if args.dry_run:
        dry_run_refresh_rbs(ctx, collect_rbs(host_objs, need_template_hosts, skipped_hosts))
        say('Dry run, no SLA changes made.')
        return 0

    if (todo_objects or need_template_hosts) and not args.skip_confirm:
        try:
            answer = input('Continue? Type y or yes (any case) to proceed: ')
        except EOFError:
            answer = ''
        if answer.strip().lower() not in ('y', 'yes'):
            dry_run_refresh_rbs(ctx, collect_rbs(host_objs, need_template_hosts, skipped_hosts))
            say('Cancelled, no SLA changes made.')
            return 0

    template_rows = []
    unverified = False
    if need_template_hosts:
        template_rows, unverified = apply_templates(ctx, need_template_hosts, apply_objects, target_spec)

    # Create the Apply CSV before changing anything: one row per object with its starting SLA and status Pending.
    # If the run is interrupted this file still holds the starting state. It is rewritten with the results at the end.
    start_rows = [{
        'workload': ctx.workload, 'host': o['hostName'], 'cluster': o['clusterName'], 'hostStatus': 'Pending',
        'rbsState': o.get('rbsState') or 'unknown', 'object': o['instanceName'], 'objectId': o['instanceId'], 'beforeAssignment': o['assignment'],
        'beforeSla': o['currentSla'], 'beforeSlaId': dig(o, 'state', 'effectiveSlaDomain', 'id'),
        'beforePendingSla': dig(o, 'state', 'pendingSla', 'name'), 'targetSla': target_spec['label'],
        'assignMutation': args.assign_mutation, 'applyMode': args.apply_mode,
        'callGroup': None, 'callSec': None, 'effectiveSec': None, 'status': 'Pending', 'error': '',
    } for o in apply_objects]
    write_apply_csv(ctx, start_rows + [skip_row(ctx, target_spec, x) for x in skipped_hosts], APPLY_COLUMNS)
    say('Apply CSV created (starting SLA of every object, rewritten with the results at the end): %s' % ctx.csv_apply_output, 'green')

    # Send the assignments and wait for completion
    results = {}
    apply_error = None
    try:
        invoke_apply_sla(ctx, apply_objects, target_spec, results)
    except Exception as exc:
        apply_error = exc
        say('Apply stopped: %s' % exc, 'red')
    apply_rows = list(results.values()) + template_rows
    apply_rows = sorted(apply_rows, key=lambda r: (str(r['host']).casefold(), str(r['object']).casefold()))

    host_log_rows = build_host_log_rows(ctx, apply_rows, need_template_hosts, skipped_hosts, unverified)
    rbs_by_host_name = collect_rbs(host_objs, need_template_hosts, skipped_hosts)
    host_status_by_host = {h['host'].lower(): h['status'] for h in host_log_rows}

    # Rewrite the single Apply CSV: each object keeps its starting SLA from the first write and gains its
    # outcome and the host status. Hosts that never produced an object get a row with no object.
    start_by_id = {ikey(r['objectId']): r for r in start_rows}
    final_rows = []
    for r in apply_rows:
        start = start_by_id.get(ikey(r['objectId'])) if r['objectId'] else None
        final_rows.append({
            'workload': ctx.workload, 'host': r['host'], 'cluster': start['cluster'] if start else '',
            'hostStatus': host_status_by_host.get(str(r['host']).lower(), ''),
            'rbsState': start['rbsState'] if start else rbs_by_host_name.get(str(r['host']).lower(), 'unknown'),
            'object': r['object'], 'objectId': r['objectId'],
            'beforeAssignment': start['beforeAssignment'] if start else r['beforeAssignment'],
            'beforeSla': start['beforeSla'] if start else r['beforeSla'],
            'beforeSlaId': start['beforeSlaId'] if start else '',
            'beforePendingSla': start['beforePendingSla'] if start else '',
            'targetSla': r['targetSla'], 'assignMutation': args.assign_mutation, 'applyMode': args.apply_mode,
            'callGroup': r['callGroup'], 'callSec': r['callSec'], 'effectiveSec': r['effectiveSec'],
            'status': r['status'], 'error': r['error'],
        })
    final_rows.extend(skip_row(ctx, target_spec, x) for x in skipped_hosts)
    write_apply_csv(ctx, final_rows, APPLY_COLUMNS)

    # Record each host's last status and time in this workload's column of the host CSV
    if ctx.host_csv:
        update_host_csv_executed(ctx, {h['host'].lower(): executed_text(h) for h in host_log_rows}, rbs_by_host_name)

    say('')
    say('Apply CSV (starting SLA, outcome and host status for every object):', 'green')
    say('  %s' % ctx.csv_apply_output)
    say('')
    say('Results', 'cyan')
    status_rows = [{'status': name, 'Count': len(rows)}
                   for name, rows in sorted(group_by(apply_rows, lambda r: r['status']), key=lambda g: g[0].casefold())]
    print_table(status_rows, ['status', 'Count'])

    problem_rows = [r for r in apply_rows if r['status'] in BAD_STATUSES]
    if problem_rows:
        say('Objects that need attention:', 'red')
        print_table(problem_rows, ['host', 'object', 'status', 'error'])
        timed_out = [r for r in problem_rows if r['status'] == 'Timeout']
        if timed_out:
            say('NOTE: %d object(s) timed out. RSC accepted the assignment, the script just stopped waiting. It may still be applied.'
                % len(timed_out), 'yellow')
            say('Check later with: --check-apply-csv-status %s' % ctx.csv_apply_output, 'yellow')
            say('To wait longer next time, use --timeout-sec <seconds>.', 'yellow')
    say('Hosts', 'cyan')
    host_status_rows = [{'status': name, 'Count': len(rows)}
                        for name, rows in sorted(group_by(host_log_rows, lambda r: r['status']), key=lambda g: g[0].casefold())]
    print_table(host_status_rows, ['status', 'Count'])
    skipped_at_end = [r for r in apply_rows if r['status'] == 'SkippedPending']
    if skipped_at_end:
        say('NOTE: %d object(s) were skipped because an SLA was already pending on them, so no SLA was assigned. '
            'Rerun once the pending SLA has finished:' % len(skipped_at_end), 'yellow')
        print_table(skipped_at_end, ['host', 'object', 'status'])
    if skipped_hosts:
        say('WARNING: %d host(s) were skipped, so no SLA was assigned on them:' % len(skipped_hosts), 'yellow')
        print_skipped_hosts(skipped_hosts, '  ')
        say('The reason for each host is in the Apply CSV (error column)%s: %s' % (
            ' and the host CSV' if ctx.host_csv else '', ctx.csv_apply_output), 'yellow')
    if problem_rows or apply_error or skipped_hosts:
        return 1
    return 0


def main():
    if len(sys.argv) == 1:
        print_usage_summary()
        return 0
    parser = build_parser()
    args = parser.parse_args()
    if not args.assign and not args.check_apply_csv_status:
        parser.error('the following arguments are required: --assign')
    ctx = Ctx(args)
    try:
        if args.check_apply_csv_status:
            return run_check_apply_csv_status(ctx)
        return run(ctx)
    except Stop as exc:
        say('ERROR: %s' % exc, 'red')
        return 1
    except KeyboardInterrupt:
        say('Interrupted.', 'yellow')
        return 130


if __name__ == '__main__':
    sys.exit(main())
