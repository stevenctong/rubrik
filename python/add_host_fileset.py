#!/usr/bin/env python3
"""
Title: add_host_fileset.py
Description: Registers hosts in Rubrik Security Cloud (RSC) that are not on a cluster yet, updates the certificate of
the hosts it just registered and of listed hosts already on the cluster that are not CONNECTED, and creates a fileset
from an existing fileset template on the new hosts and on any listed host already on the cluster that has no fileset
from that template. Everything is done in bulk, one call per batch of hosts, and each step can also be run on its own.

Author: Steven Tong
GitHub: stevenctong
Date: 11/20/26

Requires Python 3.9+ and the 'requests' package.

Quick start (run with --dry-run first, it shows the plan and the status CSV and changes nothing in RSC):
  python3 add_host_fileset.py --rsc-service-account-json ./rscp_tong.json --host-csv-path ./winhosts.csv \\
    --cluster-name gp1-alpha --fileset-name 'Windows File Share' --dry-run
  A template name with a space must be in straight quotes ('Windows File Share'). Curly quotes copied from a document
  split it into separate arguments and give: error: unrecognized arguments.

The host CSV needs a header row with a column named hostname, host, name or sqlhost, for example:
  hostname
  gp1-fs-01.rubrikdemo.com
  gp1-fs-02.rubrikdemo.com
Any other columns are ignored, and the file is never modified.

How it works
1. The hosts come from --host-csv-path (a CSV with a hostname, host, name or sqlhost column) or --hosts.
2. The host inventory is read once from RSC for ALL clusters (--host-root, WINDOWS_HOST_ROOT by default), with each
   host's RBS state, cluster, and filesets with the template each fileset came from.
3. The fileset template (--fileset-name or --fileset-template-id) is looked up on --cluster-name. It must already
   exist and is never created or changed.
4. Each listed host goes into one of these lists:
     Not registered   not in the inventory on any cluster. It is registered to --cluster-name (bulkRegisterHost), has its
                      certificate updated (bulkUpdateHost), and then gets the fileset.
     On the cluster   already registered to --cluster-name. It is not registered again. If it has no fileset from
                      the template it gets one, and if it already has one it is skipped.
     Different cluster  registered only to another cluster. It is reported and nothing is done for it, so a host is
                      never registered to two clusters by mistake.
     Ambiguous        more than one host on --cluster-name has that name. It is reported and skipped.
5. Shows the plan, with the lists highlighted, and asks you to confirm with y or yes in any case (--dry-run shows the
   plan only, --skip-confirm skips the prompt).
6. Runs three steps in this order, each one call per --batch-size hosts, and a failed call does not stop the others:
     1. Register the hosts in the Not registered list (bulkRegisterHost). RSC returns each host's id. With
        --register-host-async the asynchronous call (bulkRegisterHostAsync) is used instead, see below.
     2. Update the certificate (bulkUpdateHost with isUpdateCertAndAgentIdEnabled) of: the hosts that were just
        registered (only those whose registration was confirmed), and the listed hosts already on --cluster-name whose
        RBS state is not CONNECTED. A host already on the cluster that is CONNECTED is left alone, and so is one whose
        state RSC did not return (unknown). With --force-rbs-update every listed host on --cluster-name is updated,
        CONNECTED or not. A failed certificate update does not stop the fileset step, the host still gets its fileset
        call and the failure is recorded.
     3. Create the fileset on every host that needs it (bulkCreateFilesets): the newly registered hosts and the
        hosts already on the cluster that lack it. A host whose registration failed or was not confirmed is skipped.
Asynchronous registration (--register-host-async): RSC accepts the request and registers the hosts in the background, so
the call returns quickly. If the reply lists the hosts with ids, they are Added and the certificate and fileset steps run as
normal. If it does not, the hosts are marked Add submitted (not yet confirmed), their certificate and fileset steps are
Not done (rerun later), and the run exits 0 (nothing went wrong, it is only unfinished). Nothing is polled or retried: rerun
the script later and the hosts that registered are then on the cluster and get their certificate update and fileset. A host
that never appears usually has no Rubrik Backup Service running, or cannot be reached from the cluster. The reply shape of
bulkRegisterHostAsync was not in any capture, so try it on one or two hosts first.
CDM REST API (--cdm-api): instead of RSC, the whole run talks to one CDM cluster node. Any node of the cluster answers, and the
script finds one itself: it logs in to RSC, resolves --cluster-name, reads the cluster's node IP addresses and uses the first node
whose status is OK (the next one if the login fails). RSC is used for that and nothing else. --cdm-cluster-address names a node
yourself and then RSC is not contacted at all and --cluster-name is not needed.
It logs in to the node with the same service account JSON (POST /api/v1/service_account/session), reads the Windows hosts and the live
filesets of that cluster, and then:
     register   POST /v1/host/bulk_background, one bulk call per batch. It is asynchronous: the cluster accepts the hosts, which
                show Refreshing and then Connected.
     refresh    PUT /v1/host/certificate/<host id>, one call per host (there is no bulk call), --cdm-pause-sec (1 second)
                apart. Goes to the newly registered hosts and to listed hosts on the cluster that are not Connected. A host that is
                already Refreshing is left alone. --force-rbs-update refreshes every listed host.
     fileset    POST /v1/fileset {templateId, hostId}, one call per host, --cdm-pause-sec apart, for the new hosts and the hosts
                that have no live fileset from the template. Relic (deleted) filesets do not count.
It works with the full run and with each --do-only flag, and --batch-size, --batch-delay-sec, the timeouts, --dry-run and the status
CSV all apply. The CDM host list covers only the cluster of the node, so a
host that is registered to a different cluster is NOT detected: it looks unregistered and registration is attempted. The final
check reads the host and fileset lists again from the cluster. The template is looked up on the cluster by name
(GET /v1/fileset_template, the CDM id looks like FilesetTemplate:::<uuid>, not the RSC id), or --fileset-template-id with that id.
One step only: --do-only-register-host, --do-only-update-rbs or --do-only-create-fileset run just that step, and they
cannot be combined.
  --do-only-register-host   register the Not registered hosts and stop. No fileset template is needed.
  --do-only-update-rbs      update the certificate of the listed hosts that are already on --cluster-name and are not
                            CONNECTED, and stop. No fileset template is needed. Add --force-rbs-update to update every
                            listed host on the cluster whatever its state.
  --do-only-create-fileset  create the fileset on every listed host that is already on --cluster-name and lacks it, and
                            stop.
  Both of these read the host inventory first and act only on hosts that are already registered. A listed host that is
  not registered yet is flagged (hostStatus Not registered, nothing done for it, and the exit code is 1), and nothing is
  registered. Use --do-only-register-host, or a run with no --do-only flag, to register it.
After the last change a fresh inventory is read once (all clusters) and the status CSV is updated with what RSC shows
now for each listed host, in three columns: finalHostState (Registered on <cluster>, Not found, or On a different
cluster), finalRbsState (the RBS state, for example CONNECTED) and finalFileset (Has fileset, No fileset, or n/a when no
template was used). It is a snapshot taken right after the last call, not a wait: a host just registered, or one whose
certificate was just updated, may not show CONNECTED yet, so rerun the script later to see where it settled. It does not
change the exit code. It is skipped for a dry run, a cancelled run, and a run that sent nothing.
No SLA is assigned, so the new filesets are unprotected. Assign one afterwards, for example with set_sla_sql_fileset.py.

IMPORTANT: This registers real hosts and creates filesets. Run with --dry-run first to see the lists.

What a full run prints (two new hosts, one call per step, then the final check):
  Plan
    Cluster:                  gp1-alpha
    Steps:                    register hosts -> update certificate -> create fileset
    Fileset template:         Windows File Share
    Hosts listed:             2
    Hosts to register:        2 (in 1 call(s) of up to 50)
    Certificates to update:   2 (2 newly registered, 0 already on the cluster that are not CONNECTED), in 1 call(s) ...
    Filesets to create:       2 (2 on new hosts, 0 on hosts already on the cluster), in 1 call(s) of up to 50
    Already have the fileset: 0
    On a different cluster:   0 (not touched)
    NOT REGISTERED, will be added to gp1-alpha and given the fileset (2):
      gp1-fs-01.rubrikdemo.com, gp1-fs-02.rubrikdemo.com
  Continue? Type y or yes (any case) to make these changes: y
  Registering 2 host(s) to gp1-alpha
    Register call 1/1: 2 host(s) sent, RSC listed 2
  Updating the certificate of 2 host(s)
    Certificate call 1/1: 2 host(s) sent, RSC listed 2
  Creating the fileset on 2 host(s)
    Fileset call 1/1: 2 host(s) sent, RSC returned 2 fileset id(s)
  Final check: reading a fresh inventory (a snapshot, ...)
  Host add:           Added 2
  Certificate update: Update requested 2
  Fileset:            Created 2
  Status CSV: ./rubrik_host_fileset_status-<time>.csv
  Final state (from a fresh inventory): finalHostState Registered on gp1-alpha 2, finalRbsState CONNECTED 2,
  finalFileset Has fileset 2
  (each of those is a small count table, shown here on one line)

Status CSV (one new file per run): <prefix>host_fileset_status-<timestamp>.csv, one row per host, written before
anything is sent (so a dry run shows what WOULD be done), rewritten after the registration step, and rewritten at the
end. If the run is interrupted (Ctrl+C) the file is finalized first, and anything not confirmed says so.
  host             the host as you listed it
  cluster          the cluster the host is on (or will be added to). For a host on a different cluster, that cluster
  hostStatus       Not registered, On cluster, Different cluster, or Ambiguous on cluster
  rbsState         RBS connection state from the inventory read at the start (CONNECTED, DISCONNECTED ...), blank for
                   a host that was not registered yet. The state after the run is finalRbsState
  hostAddStatus    Already added, To be added, Added, Add submitted (not yet confirmed) with --register-host-async, Add
                   failed, Add not confirmed, Add not confirmed (timed out: RSC
                   did not answer in time and may still have registered the host, see finalHostState), Cancelled (not sent), Interrupted
                   (not confirmed), or Not added (different cluster / more than one host with this name / this run does
                   not register hosts, which is a host that is not registered in a --do-only-update-rbs or
                   --do-only-create-fileset run)
  certUpdateStatus To be updated, Update requested, Update failed, Update not confirmed, Update not confirmed (timed out),
                   Cancelled (not sent),
                   Interrupted (not confirmed), or one of the Not updated reasons:
                     Not updated (host add failed / not confirmed)   the host was not registered, so nothing was sent
                     Not updated (CONNECTED)                          already on the cluster and connected
                     Not updated (state unknown)                      already on the cluster, RSC returned no state
                   or n/a (not part of this run), or n/a for a host on a different cluster.
                   Update requested means RSC accepted the call and listed the host. The host replaces its certificate
                   afterwards, so its RBS state may take a while to show CONNECTED.
  filesetStatus    Already has fileset, To be created, Created, Create failed, Create not confirmed, Create not confirmed
                   (timed out), or Not created
                   with the reason (host add failed, different cluster, ambiguous host)
  filesetTemplate  the template name
  filesetId        the id of the fileset the host already had, or the one that was created
  otherClusters    on an On cluster row, other clusters the same host name is also registered to
  finalHostState   from the final inventory: Registered on <cluster>, Not found, On a different cluster, or blank when
                   no final check was made
  finalRbsState    from the final inventory: the RBS state now, for example CONNECTED or DISCONNECTED
  finalFileset     from the final inventory: Has fileset, No fileset, or n/a when no template was used
  osType, hostId, clusterId, detail (the reason for a failure or a note)
The source host CSV is not modified.

Exit code: 0 when every step that was sent succeeded. 1 if any call failed, a host was not confirmed in RSC's reply, or a
listed host was not touched (registered to a different cluster, more than one host with that name, or, in a
--do-only-update-rbs or --do-only-create-fileset run, not registered at all). The final
inventory check never changes it, so a host that is still CONNECTING or DISCONNECTED is not an error. A dry run and a
cancelled run exit 0, and Ctrl+C exits 130 after finalizing the status CSV. A single-step run (--do-only-...) follows
the same rules for the step it ran.

Things to know
- The inventory is read for one host root (WINDOWS_HOST_ROOT, or --host-root LINUX_HOST_ROOT). A host with the same name
  registered under the other root is not seen, so it looks Not registered. Use the right --host-root.
- Hosts are matched by exact name (case-insensitive). List them the way RSC names them, for example the full domain
  name, or a host that is already registered looks Not registered.
- The certificate update goes to the hosts registered in this run and to listed hosts already on the cluster that are
  not CONNECTED (all listed hosts on the cluster with --force-rbs-update). It does not wait for the hosts to reconnect
  before creating the filesets. The captured certificate updates were all on hosts that had just been registered, so
  re-issuing one on a host that is CONNECTED (--force-rbs-update) is untested: try it on one host first, for example
  --hosts host01 --do-only-update-rbs --force-rbs-update --dry-run.
- Between the batches of one step the script waits --batch-delay-sec (60 seconds by default, 0 for none) before each batch
  after the first, so RSC can finish one call before the next arrives. The first batch of a step never waits, and a step with
  one batch never pauses. Each call's result line also shows how long it took.
- How long each bulk call waits for RSC to answer: registration 1800 seconds (30 minutes), certificate update 900 (15
  minutes), fileset creation 900 (15 minutes). The plan shows them and the console repeats the one in use before each call.
  --timeout-sec <seconds> sets all three at once, and --register-host-timeout-sec, --update-rbs-timeout-sec and
  --create-fileset-timeout-sec set one step (a step flag wins over --timeout-sec). If a call times out its hosts are marked
  not confirmed (timed out), not failed, because RSC may still do it: check finalHostState, finalRbsState or finalFileset in
  the status CSV (or RSC) and rerun. A smaller --batch-size makes each call shorter. The inventory and lookup calls wait 300
  seconds and are not affected.
- bulkRegisterHost returns a host id for every host it registered. bulkCreateFilesets returns the new fileset ids
  but not which host each belongs to, so they are matched to hosts by the order sent, and a count mismatch is flagged.

Examples (add --dry-run to any of them to see the plan without sending anything)

  # Full run: register the new hosts, update their certificates, create the fileset, then check. Hosts from a CSV, and a
  # template name with a space in straight quotes (this is the run shown above)
  python3 add_host_fileset.py --rsc-service-account-json ./rscp_tong.json --host-csv-path ./winhosts.csv \\
    --cluster-name gp1-alpha --fileset-name 'Windows File Share'

  # The same run, but only look: shows the plan and writes the status CSV, nothing is sent to RSC
  python3 add_host_fileset.py --rsc-service-account-json ./rscp_tong.json --host-csv-path ./winhosts.csv \\
    --cluster-name gp1-alpha --fileset-name 'Windows File Share' --dry-run

  # Hosts from a CSV, fileset from a template name with no spaces
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --fileset-name Windows_Share

  # Hosts on the command line, template by ID (instead of --fileset-name, for example when two templates share a name)
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --hosts host01.example.com host02.example.com --fileset-template-id <template id>

  # One step at a time. Only register the hosts (no fileset name needed) ...
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --do-only-register-host
  # ... then only update the certificate of the listed hosts already on the cluster that are not CONNECTED ...
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --do-only-update-rbs
  # ... or of every listed host on the cluster, CONNECTED or not (also works on the full run)
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --do-only-update-rbs --force-rbs-update
  # ... then only create the fileset on the listed hosts that lack it
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --fileset-name Windows_Share --do-only-create-fileset

  # A host list on the command line instead of a CSV (space or comma separated)
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --hosts host01.example.com,host02.example.com --fileset-name Windows_Share

  # Register with the asynchronous call: RSC registers the hosts in the background and the call returns quickly. Rerun
  # later (this same command) to update their certificates and create the fileset once they are registered
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --fileset-name Windows_Share --register-host-async

  # CDM REST API: the node address is read from RSC for the cluster name. Register in bulk, refresh each host that is not
  # Connected, create the fileset
  python3 add_host_fileset.py --rsc-service-account-json ./rscp_tong.json --host-csv-path ./winhosts.csv \\
    --cluster-name gp1-alpha --cdm-api --fileset-name 'Windows File Share' --dry-run

  # The same, naming the CDM node yourself (RSC is then not contacted)
  python3 add_host_fileset.py --rsc-service-account-json ./rscp_tong.json --host-csv-path ./winhosts.csv \\
    --cdm-api --cdm-cluster-address 172.24.37.14 --fileset-name 'Windows File Share' --dry-run

  # CDM REST API, only refresh the hosts that are not Connected, or every listed host
  python3 add_host_fileset.py --rsc-service-account-json ./rscp_tong.json --host-csv-path ./winhosts.csv \\
    --cluster-name gp1-alpha --cdm-api --do-only-update-rbs
  python3 add_host_fileset.py --rsc-service-account-json ./rscp_tong.json --host-csv-path ./winhosts.csv \\
    --cluster-name gp1-alpha --cdm-api --do-only-update-rbs --force-rbs-update

  # No pause between batches (the default is 60 seconds), or a longer one for a struggling cluster
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --fileset-name Windows_Share --batch-delay-sec 0
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --fileset-name Windows_Share --batch-size 10 --batch-delay-sec 180

  # A slow cluster: wait up to 1 hour for RSC to answer each registration call
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --fileset-name Windows_Share --register-host-timeout-sec 3600

  # Wait up to 20 minutes for every call, and send smaller batches so each call is shorter
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --fileset-name Windows_Share --timeout-sec 1200 --batch-size 10

  # Only update the certificates, waiting up to 30 minutes for each call
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --do-only-update-rbs --update-rbs-timeout-sec 1800

  # Linux hosts, 25 hosts per call, no confirmation prompt
  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\
    --host-csv-path ./hosts.csv --fileset-name Linux_Share --host-root LINUX_HOST_ROOT --batch-size 25 --skip-confirm

Authentication uses an RSC Service Account JSON (client_id, client_secret, access_token_uri):
  RSC Settings -> Users -> Service Account -> create one with an appropriate role, download the JSON.
"""

import argparse
import csv
import json
import os
import sys
import time
import urllib.parse
from datetime import datetime

import requests

### CONSTANTS ###

PAGE_SIZE = 100
COLORS = {'red': '31', 'green': '32', 'yellow': '33', 'cyan': '36'}
HOST_COLUMNS = ['hostname', 'host', 'name', 'sqlhost']
OUT_COLUMNS = ['host', 'cluster', 'hostStatus', 'rbsState', 'hostAddStatus', 'certUpdateStatus', 'filesetStatus',
               'filesetTemplate', 'filesetId', 'otherClusters', 'finalHostState', 'finalRbsState', 'finalFileset', 'osType',
               'hostId', 'clusterId', 'detail']
PLAN_LIST_LIMIT = 50
IN_PROGRESS_STATES = ('CONNECTED', 'unknown', 'REFRESHING')   # a certificate update is not needed for these without --force-rbs-update
DEFAULT_REGISTER_TIMEOUT = 1800   # seconds to wait for each bulkRegisterHost call
DEFAULT_CDM_PAUSE = 1             # seconds between the per-host CDM calls (refresh, fileset creation)
DEFAULT_BATCH_DELAY = 60           # seconds to pause between the batches of one step
DEFAULT_CALL_TIMEOUT = 900        # seconds to wait for each bulkUpdateHost and bulkCreateFilesets call

### GRAPHQL ###

Q_CLUSTER_BY_NAME = '''query ClusterByNameQuery($filter: ClusterFilterInput) {
    allClusterConnection(filter: $filter, sortBy: ClusterName, sortOrder: ASC) {
      nodes {
        id
        name
      }
    }
  }'''

Q_HOST_INVENTORY = '''query HostInventoryQuery($hostRoot: HostRoot!, $first: Int!, $after: String, $filter: [Filter!]!, $childFilter: [Filter!]) {
    physicalHosts(hostRoot: $hostRoot, filter: $filter, first: $first, after: $after, sortBy: NAME, sortOrder: ASC) {
      edges {
        node {
          id
          name
          osType
          cluster {
            id
            name
          }
          connectionStatus {
            connectivity
            timestampMillis
          }
          physicalChildConnection(typeFilter: [LinuxFileset, WindowsFileset], filter: $childFilter) {
            edges {
              node {
                id
                name
                objectType
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

Q_CLUSTER_NODES = '''query ClusterNodesListQuery($uuid: UUID!) {
    cluster(clusterUuid: $uuid) {
      id
      clusterNodeConnection {
        nodes {
          id
          status
          ipAddress
        }
      }
    }
  }'''

M_REGISTER_HOSTS = '''mutation AddPhysicalHostMutation($clusterUuid: String!, $hosts: [HostRegisterInput!]!) {
    bulkRegisterHost(input: {clusterUuid: $clusterUuid, hosts: $hosts}) {
      data {
        hostSummary {
          id
          hostname
        }
      }
    }
  }'''

M_REGISTER_HOSTS_ASYNC = '''mutation AddPhysicalHostAsyncMutation($clusterUuid: String!, $hosts: [HostRegisterInput!]!) {
    bulkRegisterHostAsync(input: {clusterUuid: $clusterUuid, hosts: $hosts}) {
      output {
        items {
          hostSummary {
            id
            hostname
          }
        }
      }
    }
  }'''

M_UPDATE_HOST_CERT = '''mutation EditPhysicalHostMutation($hostUpdateProperties: [HostUpdateIdInput!]!) {
    bulkUpdateHost(input: {hostUpdateProperties: $hostUpdateProperties}) {
      output {
        items {
          hostSummary {
            id
            hostname
            name
          }
        }
      }
    }
  }'''

M_CREATE_FILESETS = '''mutation BulkCreateFilesetsMutation($clusterUuid: String!, $definitions: [FilesetCreateInput!]!) {
    bulkCreateFilesets(input: {clusterUuid: $clusterUuid, definitions: $definitions}) {
      data {
        filesetSummary {
          slaAssignable {
            id
          }
        }
      }
    }
  }'''

### HELPERS ###


class Stop(Exception):
    """A run-stopping error with a message meant for the user."""


class Ctx(object):
    def __init__(self, args):
        self.args = args
        self.session = requests.Session()
        self.verify = False
        self.endpoint = None
        self.headers = None
        self.out_path = None
        self.timeouts = {}
        self.cdm_base = None        # https://<cluster node>/api  when --cdm-api is used
        self.cdm_session = None     # CDM session id, deleted when the run ends
        self.cdm_address = None     # the CDM node the run is talking to


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
    return '' if value is None else str(value)


def unique_ordered(values):
    seen = set()
    out = []
    for value in values:
        if value not in seen:
            seen.add(value)
            out.append(value)
    return out


def group_by(items, key_func):
    groups = {}
    order = []
    for item in items:
        key = key_func(item)
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(item)
    return [(key, groups[key]) for key in order]


def split_names(values):
    """Accept '--hosts a b' and '--hosts a,b'."""
    out = []
    for value in values or []:
        out.extend(part.strip() for part in str(value).split(','))
    return [v for v in out if v]


def write_csv(path, rows, columns):
    with open(path, 'w', newline='', encoding='utf-8') as handle:
        writer = csv.writer(handle, quoting=csv.QUOTE_ALL, lineterminator='\n')
        writer.writerow(columns)
        for row in rows:
            writer.writerow([fmt_cell(row.get(col)) for col in columns])


def read_host_csv(path):
    """The host names from the first of the columns hostname, host, name or sqlhost."""
    if not os.path.isfile(path):
        die('CSV file not found: %s' % path)
    with open(path, newline='', encoding='utf-8-sig') as handle:
        reader = csv.DictReader(handle, restval='')
        fieldnames = list(reader.fieldnames or [])
        rows = list(reader)
    if not rows:
        die('CSV file has no rows: %s' % path)
    column = next((c for c in fieldnames if c.casefold() in HOST_COLUMNS), None)
    if not column:
        die('CSV needs a header column named one of: %s' % ', '.join(HOST_COLUMNS))
    return [r.get(column) or '' for r in rows]


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


### RSC ACCESS ###


def configure_tls(ctx):
    """TLS certificate verification is off unless --verify-ssl is given."""
    if ctx.args.verify_ssl:
        ctx.verify = True
    else:
        ctx.verify = False
        requests.packages.urllib3.disable_warnings(requests.packages.urllib3.exceptions.InsecureRequestWarning)
        say('Note: TLS certificate verification is off (add --verify-ssl to turn it on).', 'yellow')


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


def invoke_rsc(ctx, query, variables=None, read_timeout=300):
    """Send a GraphQL request, raise on HTTP or GraphQL errors, return the data. read_timeout is how many seconds to wait
    for RSC to answer once the request is sent (300 unless a caller needs longer, as the host registration does)."""
    payload = {'query': query, 'variables': variables or {}}
    resp = ctx.session.post(ctx.endpoint, json=payload, headers=ctx.headers, timeout=(15, read_timeout), verify=ctx.verify)
    if resp.status_code >= 400:
        raise RuntimeError('RSC returned HTTP %d: %s' % (resp.status_code, resp.text[:500]))
    body = resp.json()
    if body.get('errors'):
        raise RuntimeError(json.dumps(body['errors'], separators=(',', ':')))
    return body.get('data') or {}


def paginate(ctx, query, base_variables, root_key):
    nodes = []
    after = None
    while True:
        variables = dict(base_variables)
        if after:
            variables['after'] = after
        result = invoke_rsc(ctx, query, variables).get(root_key) or {}
        for edge in result.get('edges') or []:
            nodes.append(edge.get('node'))
        page = result.get('pageInfo') or {}
        after = page.get('endCursor')
        if not page.get('hasNextPage') or not after:
            break
    return nodes


def get_cluster(ctx, name):
    data = invoke_rsc(ctx, Q_CLUSTER_BY_NAME, {'filter': {'name': [name]}})
    nodes = [n for n in (dig(data, 'allClusterConnection', 'nodes') or []) if ieq(n.get('name'), name)]
    if not nodes:
        raise Stop('No cluster found with the exact name: %s' % name)
    if len(nodes) >= 2:
        raise Stop('More than one cluster has the name: %s' % name)
    return nodes[0]['id'], nodes[0]['name']


def get_inventory(ctx):
    """Every host under the host root on every cluster, with its filesets (relic, replicated and KUPR hosts and
    ghost or relic filesets excluded)."""
    variables = {
        'hostRoot': ctx.args.host_root,
        'first': PAGE_SIZE,
        'filter': [
            {'field': 'IS_RELIC', 'texts': ['false']},
            {'field': 'IS_REPLICATED', 'texts': ['false']},
            {'field': 'IS_KUPR_HOST', 'texts': ['false']},
        ],
        'childFilter': [
            {'field': 'IS_GHOST', 'texts': ['false']},
            {'field': 'IS_RELIC', 'texts': ['false']},
        ],
    }
    return paginate(ctx, Q_HOST_INVENTORY, variables, 'physicalHosts')


def templates_by_name(ctx, cluster_id, name, host_root):
    variables = {
        'hostRoot': host_root,
        'first': PAGE_SIZE,
        'filter': [
            {'field': 'NAME', 'texts': [name]},
            {'field': 'CLUSTER_ID', 'texts': [cluster_id]},
        ],
    }
    return [t for t in paginate(ctx, Q_TEMPLATES_BY_NAME, variables, 'filesetTemplates') if ieq(t.get('name'), name)]


def get_template(ctx, cluster_id, cluster_name):
    """The fileset template on the cluster, by --fileset-template-id or --fileset-name. Returns (id, name)."""
    args = ctx.args
    if args.fileset_template_id:
        say("Looking up fileset template ID '%s'" % args.fileset_template_id)
        tmpl = invoke_rsc(ctx, Q_TEMPLATE_BY_ID, {'fid': args.fileset_template_id}).get('filesetTemplate')
        if not tmpl:
            raise Stop('No fileset template found with ID: %s' % args.fileset_template_id)
        if not ieq(dig(tmpl, 'cluster', 'id'), cluster_id):
            raise Stop("Fileset template '%s' is on cluster '%s', not on '%s'." % (
                tmpl.get('name'), dig(tmpl, 'cluster', 'name'), cluster_name))
        return tmpl['id'], tmpl['name']
    say("Looking up fileset template '%s' on %s" % (args.fileset_name, cluster_name))
    found = templates_by_name(ctx, cluster_id, args.fileset_name, args.host_root)
    if not found:
        other_root = 'WINDOWS_HOST_ROOT' if args.host_root == 'LINUX_HOST_ROOT' else 'LINUX_HOST_ROOT'
        hint = ''
        try:
            if templates_by_name(ctx, cluster_id, args.fileset_name, other_root):
                hint = ' A template with that name exists under %s. Use --host-root %s.' % (other_root, other_root)
        except Exception:
            pass
        raise Stop("No fileset template named '%s' under %s on cluster '%s'.%s" % (
            args.fileset_name, args.host_root, cluster_name, hint))
    if len(found) >= 2:
        raise Stop("More than one fileset template is named '%s' on cluster '%s'. Use --fileset-template-id." % (
            args.fileset_name, cluster_name))
    return found[0]['id'], found[0]['name']


### CDM REST API (--cdm-api) ###

# The CDM path talks to one CDM cluster node directly instead of RSC. It reads the Windows hosts and the filesets of that
# cluster, registers hosts in bulk (asynchronous), refreshes the certificate of hosts that are not connected, and creates
# the fileset. The refresh and the fileset creation are one call per host, there is no bulk version of either.
# Everything it reads is turned into the same shape the RSC path uses, so the host classification and the plan,
# the status CSV and the final check are shared.

CDM_PAGE_SIZE = 100
CDM_CLUSTER_ID = 'local'   # every host read from the CDM node is on that one cluster (primary_cluster_id=local), so all share this id


def cdm_url(ctx, path):
    return '%s%s' % (ctx.cdm_base, path)


def cdm_find_node_addresses(ctx):
    """The IP addresses of the nodes of --cluster-name, read from RSC (any node of a CDM cluster can answer the REST API), the
    nodes whose status is OK first. Logs in to RSC only for this."""
    authenticate(ctx)
    cluster_id, cluster_name = get_cluster(ctx, ctx.args.cluster_name)
    say("Cluster '%s' (%s): reading its nodes from RSC" % (cluster_name, cluster_id))
    data = invoke_rsc(ctx, Q_CLUSTER_NODES, {'uuid': cluster_id})
    nodes = dig(data, 'cluster', 'clusterNodeConnection', 'nodes') or []
    usable = [n for n in nodes if n.get('ipAddress')]
    if not usable:
        raise Stop("RSC returned no node IP addresses for cluster '%s'. Give a node with --cdm-cluster-address." % cluster_name)
    usable.sort(key=lambda n: 0 if ieq(n.get('status'), 'OK') else 1)
    addresses = [n['ipAddress'] for n in usable]
    say('  Nodes: %s' % ', '.join('%s (%s)' % (n['ipAddress'], n.get('status')) for n in usable))
    return addresses


def cdm_authenticate(ctx):
    """Log in to the CDM cluster node with the same service account JSON, as CDM-Authentication.ps1 does:
    POST /api/v1/service_account/session with the client_id and client_secret. Sets the bearer token and the session id."""
    args = ctx.args
    path = args.rsc_service_account_json
    say('Reading Service Account file: %s' % path)
    try:
        with open(path, encoding='utf-8-sig') as handle:
            sa = json.load(handle)
        if not isinstance(sa, dict):
            raise ValueError('the JSON is not an object')
    except Exception as exc:
        raise Stop("Failed to read Service Account JSON at '%s': %s" % (path, exc))
    missing = [k for k in ('client_id', 'client_secret') if sa.get(k) is None]
    if missing:
        raise Stop('Service Account JSON is missing required fields: %s' % ', '.join(missing))
    if args.cdm_cluster_address:
        addresses = [args.cdm_cluster_address.strip()]
        say('Using the CDM node given with --cdm-cluster-address: %s' % addresses[0])
    else:
        addresses = cdm_find_node_addresses(ctx)
    errors = []
    body = None
    address = None
    for candidate in addresses:
        ctx.cdm_base = 'https://%s/api' % candidate
        try:
            resp = ctx.session.post(cdm_url(ctx, '/v1/service_account/session'),
                                    json={'serviceAccountId': sa['client_id'], 'secret': sa['client_secret']},
                                    timeout=(15, 60), verify=ctx.verify)
            resp.raise_for_status()
            body = resp.json()
            if not body.get('token'):
                raise RuntimeError('the cluster answered but returned no bearer token')
            address = candidate
            break
        except Exception as exc:
            errors.append('%s: %s' % (candidate, exc))
            say('  CDM login failed on %s: %s' % (candidate, exc), 'yellow')
            body = None
    if body is None:
        raise Stop('CDM authentication failed on every node tried (%s).' % '; '.join(errors))
    ctx.cdm_address = address
    token = body.get('token')
    ctx.cdm_session = body.get('sessionId')
    ctx.headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer %s' % token,
    }
    say('Connected to the CDM cluster through node %s' % address, 'green')


def cdm_logout(ctx):
    """Delete the CDM session. Never raises: a failed logout must not change the result of the run."""
    if not ctx.cdm_session or not ctx.cdm_base:
        return
    try:
        ctx.session.delete(cdm_url(ctx, '/v1/session/%s' % urllib.parse.quote(str(ctx.cdm_session), safe='')),
                           headers=ctx.headers, timeout=(15, 60), verify=ctx.verify)
        say('CDM session deleted.')
    except Exception as exc:
        say('Could not delete the CDM session: %s' % exc, 'yellow')
    ctx.cdm_session = None


def cdm_call(ctx, method, path, params=None, body=None, read_timeout=300):
    """One CDM REST call. Raises RuntimeError with the HTTP status and the start of the reply on an error, and returns the
    parsed JSON (or None for an empty reply). Gateway timeouts and read timeouts are raised as they are, so the callers can
    word them as not confirmed."""
    resp = ctx.session.request(method, cdm_url(ctx, path), params=params, json=body, headers=ctx.headers,
                               timeout=(15, read_timeout), verify=ctx.verify)
    if resp.status_code >= 400:
        raise RuntimeError('CDM returned HTTP %d: %s' % (resp.status_code, resp.text[:500]))
    if not resp.content:
        return None
    try:
        return resp.json()
    except ValueError:
        return None


def cdm_paged(ctx, path, params):
    """Every entry of a CDM list call that returns {hasMore, data, total}, using limit and offset."""
    out = []
    offset = 0
    while True:
        query = dict(params)
        query['limit'] = CDM_PAGE_SIZE
        query['offset'] = offset
        reply = cdm_call(ctx, 'GET', path, params=query) or {}
        data = reply.get('data') or []
        out.extend(data)
        if not reply.get('hasMore') or not data:
            break
        offset += len(data)
    return out


def cdm_get_cluster(ctx):
    """The CDM cluster id and a display name. The host list reports primaryClusterId, and 'local' in the query means this
    cluster, so the id comes from the hosts. Returns (id or 'local', the address shown to the user)."""
    return CDM_CLUSTER_ID, ctx.cdm_address


def cdm_get_template(ctx):
    """The fileset template on the CDM cluster, by --fileset-name (exact name) or --fileset-template-id. Returns (id, name)."""
    args = ctx.args
    if args.fileset_template_id:
        say("Looking up fileset template '%s' on the CDM cluster" % args.fileset_template_id)
        found = [t for t in cdm_paged(ctx, '/v1/fileset_template', {}) if ieq(t.get('id'), args.fileset_template_id)]
        if not found:
            raise Stop('No fileset template with ID %s on the CDM cluster. CDM ids look like FilesetTemplate:::<uuid>, not the RSC id.'
                       % args.fileset_template_id)
        return found[0]['id'], found[0]['name']
    say("Looking up fileset template '%s' on the CDM cluster" % args.fileset_name)
    found = [t for t in cdm_paged(ctx, '/v1/fileset_template', {'name': args.fileset_name}) if ieq(t.get('name'), args.fileset_name)]
    os_wanted = 'Windows' if args.host_root == 'WINDOWS_HOST_ROOT' else 'Linux'
    same_os = [t for t in found if not t.get('operatingSystemType') or ieq(t.get('operatingSystemType'), os_wanted)]
    if not same_os:
        hint = ''
        if found:
            hint = ' A template with that name exists for %s. Use --host-root to match.' % ', '.join(
                unique_ordered(str(t.get('operatingSystemType')) for t in found))
        raise Stop("No %s fileset template named '%s' on the CDM cluster.%s" % (os_wanted, args.fileset_name, hint))
    if len(same_os) >= 2:
        raise Stop("More than one %s fileset template is named '%s' on the CDM cluster. Use --fileset-template-id." % (
            os_wanted, args.fileset_name))
    return same_os[0]['id'], same_os[0]['name']


def cdm_status_to_state(status):
    """CDM reports Connected, Refreshing and so on. The RSC path says CONNECTED, so the CDM status is shown in upper case.
    A host that is Refreshing is working its way to Connected, so classify_hosts does not queue it for another refresh
    (see IN_PROGRESS_STATES) unless --force-rbs-update is given."""
    return str(status or 'unknown').upper().replace(' ', '_')


def cdm_inventory(ctx, template_id):
    """The Windows (or Linux) hosts of the CDM cluster, each with its live filesets from the template, in the shape the RSC
    path reads: id, name, osType, cluster, connectionStatus and physicalChildConnection. Relic filesets are left out, since a
    deleted fileset must not count as one the host still has."""
    os_type = 'Windows' if ctx.args.host_root == 'WINDOWS_HOST_ROOT' else 'Linux'
    hosts = cdm_paged(ctx, '/v1/host', {'operating_system_type': os_type, 'primary_cluster_id': 'local',
                                       'sort_by': 'hostname', 'sort_order': 'asc'})
    filesets = []
    if template_id:
        filesets = [f for f in cdm_paged(ctx, '/v1/fileset', {'is_relic': 'false', 'name': ctx.args.cdm_fileset_filter or ''})
                    if not f.get('isRelic')]
    by_host = {}
    for f in filesets:
        by_host.setdefault(ikey(f.get('hostId')), []).append(f)
    out = []
    for h in hosts:
        kids = [{'node': {'id': f.get('id'), 'filesetTemplate': {'id': f.get('templateId'), 'name': f.get('templateName')}}}
                for f in by_host.get(ikey(h.get('id')), [])]
        out.append({
            'id': h.get('id'), 'name': h.get('hostname') or h.get('name'), 'osType': h.get('operatingSystemType'),
            'cluster': {'id': CDM_CLUSTER_ID, 'name': ctx.cdm_address},
            'connectionStatus': {'connectivity': cdm_status_to_state(h.get('statusEnum') or h.get('status')),
                                 'timestampMillis': h.get('lastRefreshTimeStamp')},
            'physicalChildConnection': {'edges': kids},
        })
    return out


def cdm_register_hosts(ctx, rows, cluster_id):
    """Register the hosts with POST /v1/host/bulk_background (asynchronous, one call per batch). The reply lists each host
    that was accepted with its id and its status, usually Refreshing. A host the reply does not list is not confirmed."""
    calls = chunks(rows, ctx.args.batch_size)
    timeout = ctx.timeouts['register']
    os_type = 'Windows' if ctx.args.host_root == 'WINDOWS_HOST_ROOT' else 'Linux'
    say('  Registering through the CDM REST API: POST /v1/host/bulk_background (asynchronous, hosts finish registering in the background).')
    say('  Each registration call waits up to %ds (%s) for the cluster to answer. To change it, rerun with --register-host-timeout-sec <seconds>, or --timeout-sec <seconds> for every step.'
        % (timeout, format_duration(timeout)))
    for number, batch in enumerate(calls, 1):
        started = pause_before_batch(ctx, number, len(calls), 'registration')
        try:
            reply = cdm_call(ctx, 'POST', '/v1/host/bulk_background', body=[{'hostname': r['host'], 'osType': os_type} for r in batch],
                             read_timeout=timeout)
            items = reply if isinstance(reply, list) else ((reply or {}).get('data') or [])
            by_name = {ikey(i.get('hostname') or i.get('name')): i for i in items}
            for r in batch:
                item = by_name.get(ikey(r['host']))
                if item and item.get('id'):
                    r['hostId'] = item['id']
                    r['hostAddStatus'] = 'Added'
                    r['rbsState'] = cdm_status_to_state(item.get('statusEnum') or item.get('status'))
                else:
                    r['hostAddStatus'] = 'Add not confirmed'
                    r['certUpdateStatus'] = 'Not updated (host add not confirmed)'
                    r['filesetStatus'] = 'Not created (host add not confirmed)'
                    r['detail'] = 'The CDM cluster accepted the call but did not list this host in its reply (it listed %d host(s))' % len(items)
            say('  Register call %d/%d (CDM): %d host(s) sent, the cluster listed %d%s' % (number, len(calls), len(batch), len(items), took(started)))
        except requests.exceptions.ReadTimeout:
            for r in batch:
                r['hostAddStatus'] = 'Add not confirmed (timed out)'
                r['certUpdateStatus'] = 'Not updated (host add not confirmed)'
                r['filesetStatus'] = 'Not created (host add not confirmed)'
                r['detail'] = ('The CDM cluster did not answer the registration within %ds. It may still have registered the host: check '
                               'finalHostState or the cluster, and rerun to continue.' % timeout)
            say('  Register call %d/%d TIMED OUT after %ds for %d host(s). The cluster may still register them.%s'
                % (number, len(calls), timeout, len(batch), took(started)), 'yellow')
        except Exception as exc:
            for r in batch:
                r['hostAddStatus'] = 'Add failed'
                r['certUpdateStatus'] = 'Not updated (host add failed)'
                r['filesetStatus'] = 'Not created (host add failed)'
                r['detail'] = str(exc)
            say('  Register call %d/%d FAILED for %d host(s)%s: %s' % (number, len(calls), len(batch), took(started), exc), 'red')


def cdm_refresh_hosts(ctx, rows):
    """Refresh the certificate of each host with PUT /v1/host/certificate/<host id>. There is no bulk call, so this is one
    call per host, with a pause between them (--cdm-pause-sec, 1 second by default). A failed host does not stop the others."""
    timeout = ctx.timeouts['cert']
    pause = ctx.args.cdm_pause_sec
    say('  Refreshing through the CDM REST API: PUT /v1/host/certificate/<host id>, one host at a time, %ds between hosts (--cdm-pause-sec).' % pause)
    say('  Each call waits up to %ds (%s) for the cluster to answer. To change it, rerun with --update-rbs-timeout-sec <seconds>, or --timeout-sec <seconds> for every step.'
        % (timeout, format_duration(timeout)))
    total = len(rows)
    for number, r in enumerate(rows, 1):
        if number > 1 and pause > 0:
            time.sleep(pause)
        started = time.monotonic()
        try:
            reply = cdm_call(ctx, 'PUT', '/v1/host/certificate/%s' % urllib.parse.quote(str(r['hostId']), safe=''), read_timeout=timeout) or {}
            r['certUpdateStatus'] = 'Update requested'
            state = cdm_status_to_state(reply.get('statusEnum') or reply.get('status'))
            say('  Refresh %d/%d %s: %s%s' % (number, total, r['host'], state if reply else 'accepted', took(started)))
        except requests.exceptions.ReadTimeout:
            r['certUpdateStatus'] = 'Update not confirmed (timed out)'
            add_detail(r, 'refresh: the CDM cluster did not answer within %ds. It may still apply it: check finalRbsState, and rerun later.' % timeout)
            say('  Refresh %d/%d %s TIMED OUT after %ds%s' % (number, total, r['host'], timeout, took(started)), 'yellow')
        except Exception as exc:
            r['certUpdateStatus'] = 'Update failed'
            add_detail(r, 'refresh: %s' % exc)
            say('  Refresh %d/%d %s FAILED%s: %s' % (number, total, r['host'], took(started), exc), 'red')


def cdm_create_filesets(ctx, rows, template_id):
    """Create the fileset on each host with POST /v1/fileset {templateId, hostId}. There is no bulk call, so this is one call
    per host, with a pause between them (--cdm-pause-sec). A failed host does not stop the others."""
    timeout = ctx.timeouts['fileset']
    pause = ctx.args.cdm_pause_sec
    say('  Creating filesets through the CDM REST API: POST /v1/fileset, one host at a time, %ds between hosts (--cdm-pause-sec).' % pause)
    say('  Each call waits up to %ds (%s) for the cluster to answer. To change it, rerun with --create-fileset-timeout-sec <seconds>, or --timeout-sec <seconds> for every step.'
        % (timeout, format_duration(timeout)))
    total = len(rows)
    for number, r in enumerate(rows, 1):
        if number > 1 and pause > 0:
            time.sleep(pause)
        started = time.monotonic()
        try:
            reply = cdm_call(ctx, 'POST', '/v1/fileset', body={'templateId': template_id, 'hostId': r['hostId']}, read_timeout=timeout) or {}
            r['filesetStatus'] = 'Created'
            r['filesetId'] = reply.get('id') or ''
            if not reply.get('id'):
                r['filesetStatus'] = 'Create not confirmed'
                r['detail'] = 'The CDM cluster accepted the call but returned no fileset id: check the cluster, the final check shows if it exists.'
            say('  Fileset %d/%d %s: %s%s' % (number, total, r['host'], r['filesetId'] or 'no id returned', took(started)))
        except requests.exceptions.ReadTimeout:
            r['filesetStatus'] = 'Create not confirmed (timed out)'
            r['detail'] = ('The CDM cluster did not answer within %ds. It may still create it: check finalFileset, and rerun later.' % timeout)
            say('  Fileset %d/%d %s TIMED OUT after %ds%s' % (number, total, r['host'], timeout, took(started)), 'yellow')
        except Exception as exc:
            r['filesetStatus'] = 'Create failed'
            r['detail'] = str(exc)
            say('  Fileset %d/%d %s FAILED%s: %s' % (number, total, r['host'], took(started), exc), 'red')


### PLAN ###


def state_of(host):
    return dig(host, 'connectionStatus', 'connectivity') or 'unknown'


def classify_hosts(inventory, names, cluster_id, cluster_name, template_id, template_name, steps, force=False):
    """One row per listed host (one per cluster for a host that is only on other clusters). Returns
    (rows, groups) where groups maps a list name to its rows. steps is the set of steps this run does (any of
    'register', 'cert', 'fileset'), which decides what each host's status says it is waiting for. A host already on the
    cluster gets a certificate update when its RBS state is something other than CONNECTED or unknown (for example
    DISCONNECTED), or always with force. A host whose state RSC did not return (unknown) is skipped without force."""
    do_register, do_cert, do_fileset = 'register' in steps, 'cert' in steps, 'fileset' in steps
    by_name = {}
    for host in inventory:
        by_name.setdefault(ikey(host.get('name')), []).append(host)

    groups = {'new': [], 'needs_fileset': [], 'has_fileset': [], 'other': [], 'ambiguous': [], 'not_registered': [],
              'cert_existing': [], 'nothing': []}
    rows = []

    def row(name, host, status, add, fileset, other='', detail='', fileset_id='', cert='n/a'):
        if not do_fileset and fileset.startswith('To be created'):
            fileset = 'n/a (not part of this run)'
        if not do_register and add == 'To be added':
            add = 'Not added (this run does not register hosts)'
        if not do_cert and cert == 'To be updated':
            cert = 'n/a (not part of this run)'
        return {
            'host': name, 'cluster': dig(host, 'cluster', 'name') if host else cluster_name, 'hostStatus': status,
            'rbsState': state_of(host) if host else '', 'hostAddStatus': add, 'certUpdateStatus': cert,
            'filesetStatus': fileset,
            'filesetTemplate': template_name, 'filesetId': fileset_id, 'otherClusters': other,
            'osType': (host.get('osType') or '') if host else '', 'hostId': host.get('id') if host else '',
            'clusterId': dig(host, 'cluster', 'id') if host else cluster_id, 'detail': detail,
        }

    for name in names:
        matches = by_name.get(ikey(name), [])
        here = [h for h in matches if ieq(dig(h, 'cluster', 'id'), cluster_id)]
        other = [h for h in matches if not ieq(dig(h, 'cluster', 'id'), cluster_id)]
        other_names = ', '.join(unique_ordered(str(dig(h, 'cluster', 'name')) for h in other))
        if not matches:
            if do_register:
                r = row(name, None, 'Not registered', 'To be added', 'To be created', cert='To be updated',
                        detail='Not in the inventory on any cluster, will be registered to %s' % cluster_name)
                groups['new'].append(r)
            else:
                r = row(name, None, 'Not registered', 'Not added (this run does not register hosts)',
                        'Not created (host is not registered)' if do_fileset else 'n/a (not part of this run)',
                        cert='Not updated (host is not registered)' if do_cert else 'n/a (not part of this run)',
                        detail='Not registered on any cluster, so this step cannot be done for it. Register it first: run with --do-only-register-host, or without any --do-only flag.')
                groups['not_registered'].append(r)
            rows.append(r)
        elif len(here) > 1:
            r = row(name, here[0], 'Ambiguous on cluster', 'Not added (more than one host with this name)',
                    'Not created (ambiguous host)', other_names, 'More than one host named %s on %s' % (name, cluster_name))
            rows.append(r)
            groups['ambiguous'].append(r)
        elif len(here) == 1:
            h = here[0]
            children = [e.get('node') for e in (dig(h, 'physicalChildConnection', 'edges') or [])]
            existing = [c for c in children if template_id and ieq(dig(c, 'filesetTemplate', 'id'), template_id)]
            state = state_of(h)
            detail = ''
            if not do_cert:
                cert = 'n/a (not part of this run)'
            elif force or state not in IN_PROGRESS_STATES:
                cert = 'To be updated'
                if force and state in IN_PROGRESS_STATES:
                    detail = 'Certificate update forced by --force-rbs-update, the host is %s' % (
                        {'CONNECTED': 'CONNECTED', 'REFRESHING': 'REFRESHING'}.get(state, 'in an unknown state'))
            elif state == 'CONNECTED':
                cert = 'Not updated (CONNECTED)'
            elif state == 'REFRESHING':
                cert = 'Not updated (REFRESHING, already in progress)'
            else:
                cert = 'Not updated (state unknown)'
            if not do_fileset:
                fileset, fileset_id = 'n/a (not part of this run)', ''
            elif existing:
                fileset, fileset_id = 'Already has fileset', existing[0].get('id')
            else:
                fileset, fileset_id = 'To be created', ''
            r = row(name, h, 'On cluster', 'Already added', fileset, other_names, detail=detail, fileset_id=fileset_id, cert=cert)
            rows.append(r)
            if cert == 'To be updated':
                groups['cert_existing'].append(r)
            if do_fileset:
                groups['has_fileset' if existing else 'needs_fileset'].append(r)
            elif cert != 'To be updated':
                groups['nothing'].append(r)
        else:
            for h in other:
                r = row(name, h, 'Different cluster', 'Not added (registered to a different cluster)',
                        'Not created (different cluster)',
                        detail='Registered to %s, not on %s. Not changed.' % (dig(h, 'cluster', 'name'), cluster_name))
                rows.append(r)
            groups['other'].append(rows[-1])
    return rows, groups


def print_group(title, rows, color):
    if not rows:
        return
    names = unique_ordered(str(r['host']) for r in rows)
    say('  %s (%d):' % (title, len(names)), color)
    shown = ', '.join(names[:PLAN_LIST_LIMIT])
    more = ' ... and %d more, see the CSV' % (len(names) - PLAN_LIST_LIMIT) if len(names) > PLAN_LIST_LIMIT else ''
    say('    %s%s' % (shown, more), color)


def needs_attention(row):
    add = row['hostAddStatus']
    fileset = row['filesetStatus']
    cert = row.get('certUpdateStatus') or ''
    # 'Add submitted (not yet confirmed)' is an asynchronous registration still in progress: not an error, a rerun finishes it
    return (add in ('Add failed', 'Add not confirmed', 'Add not confirmed (timed out)', 'Interrupted (not confirmed)') or add.startswith('Not added')
            or cert in ('Update failed', 'Update not confirmed', 'Update not confirmed (timed out)', 'Interrupted (not confirmed)')
            or fileset in ('Create failed', 'Create not confirmed', 'Create not confirmed (timed out)', 'Interrupted (not confirmed)')
            or fileset.startswith('Not created'))


### CSV OUTPUT ###


def write_output(ctx, rows):
    """Write the status CSV through a temporary file. Never raises: a problem writing it must not stop the run."""
    tmp = ctx.out_path + '.tmp'
    try:
        write_csv(tmp, rows, OUT_COLUMNS)
        os.replace(tmp, ctx.out_path)
        return True
    except Exception as exc:
        say('Could not write %s: %s' % (ctx.out_path, exc), 'yellow')
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
        return False


def print_summary(ctx, rows):
    say('')
    say('Host add', 'cyan')
    print_table([{'hostAddStatus': k, 'Count': len(g)} for k, g in
                 sorted(group_by(rows, lambda r: r['hostAddStatus']), key=lambda x: x[0].casefold())], ['hostAddStatus', 'Count'])
    say('Certificate update', 'cyan')
    print_table([{'certUpdateStatus': k, 'Count': len(g)} for k, g in
                 sorted(group_by(rows, lambda r: r['certUpdateStatus']), key=lambda x: x[0].casefold())], ['certUpdateStatus', 'Count'])
    say('Fileset', 'cyan')
    print_table([{'filesetStatus': k, 'Count': len(g)} for k, g in
                 sorted(group_by(rows, lambda r: r['filesetStatus']), key=lambda x: x[0].casefold())], ['filesetStatus', 'Count'])
    waiting = [r for r in rows if r['hostAddStatus'] == 'Add submitted (not yet confirmed)']
    if waiting:
        say('%d host(s) were submitted for registration in the background and are not confirmed yet. Rerun later to give them their certificate update and fileset.' % len(waiting), 'yellow')
    problems = [r for r in rows if needs_attention(r)]
    if problems:
        say('%d host row(s) need attention (failed, not confirmed, or not touched). See the detail column.' % len(problems), 'yellow')
    say('Status CSV: %s' % ctx.out_path, 'green')


### FINAL CHECK ###


def final_check(ctx, rows, cluster_id, cluster_name, template_id):
    """Read a fresh inventory (all clusters, once) and record what RSC shows now for every listed host in the
    finalHostState, finalRbsState and finalFileset columns. A snapshot right after the last call, not a wait. Never
    stops the run: if the read fails the columns say so."""
    say('')
    say('Final check: reading a fresh inventory%s (a snapshot, a host that was just registered or updated may not show CONNECTED yet, rerun later to see it settled)'
        % (' from the CDM cluster' if ctx.args.cdm_api else ''), 'cyan')
    try:
        inventory = cdm_inventory(ctx, template_id) if ctx.args.cdm_api else get_inventory(ctx)
    except Exception as exc:
        for r in rows:
            r['finalHostState'] = 'Final check failed'
            r['finalRbsState'] = ''
            r['finalFileset'] = ''
        say('Final check failed, the inventory could not be read: %s' % exc, 'red')
        return False
    by_name = {}
    for host in inventory:
        by_name.setdefault(ikey(host.get('name')), []).append(host)
    for r in rows:
        matches = by_name.get(ikey(r['host']), [])
        here = [h for h in matches if ieq(dig(h, 'cluster', 'id'), cluster_id)]
        if len(here) == 1:
            h = here[0]
            r['finalHostState'] = 'Registered on %s' % cluster_name
            r['finalRbsState'] = state_of(h)
            r['hostId'] = r['hostId'] or h.get('id')
            if template_id:
                children = [e.get('node') for e in (dig(h, 'physicalChildConnection', 'edges') or [])]
                found = [c for c in children if ieq(dig(c, 'filesetTemplate', 'id'), template_id)]
                r['finalFileset'] = 'Has fileset' if found else 'No fileset'
                if found and not r['filesetId']:
                    r['filesetId'] = found[0].get('id')
            else:
                r['finalFileset'] = 'n/a'
        elif len(here) > 1:
            r['finalHostState'] = 'More than one host with this name on %s' % cluster_name
            r['finalRbsState'] = ''
            r['finalFileset'] = 'n/a' if not template_id else ''
        elif matches:
            r['finalHostState'] = 'On a different cluster: %s' % ', '.join(unique_ordered(str(dig(h, 'cluster', 'name')) for h in matches))
            r['finalRbsState'] = ''
            r['finalFileset'] = 'n/a' if not template_id else ''
        else:
            r['finalHostState'] = 'Not found'
            r['finalRbsState'] = ''
            r['finalFileset'] = 'n/a' if not template_id else ''
    return True


def print_final_summary(rows):
    checked = [r for r in rows if r.get('finalHostState')]
    if not checked:
        return
    say('Final state (from a fresh inventory)', 'cyan')
    print_table([{'finalHostState': k, 'Count': len(g)} for k, g in
                 sorted(group_by(checked, lambda r: r['finalHostState']), key=lambda x: x[0].casefold())], ['finalHostState', 'Count'])
    here = [r for r in checked if r['finalHostState'].startswith('Registered on')]
    if here:
        print_table([{'finalRbsState': k, 'Count': len(g)} for k, g in
                     sorted(group_by(here, lambda r: r['finalRbsState']), key=lambda x: x[0].casefold())], ['finalRbsState', 'Count'])
        if any(r['finalFileset'] in ('Has fileset', 'No fileset') for r in here):
            print_table([{'finalFileset': k, 'Count': len(g)} for k, g in
                         sorted(group_by(here, lambda r: r['finalFileset']), key=lambda x: x[0].casefold())], ['finalFileset', 'Count'])


### CHANGES ###


def first_set(*values):
    """The first value that is not None."""
    for value in values:
        if value is not None:
            return value
    return None


def format_duration(seconds):
    """1800 -> '30 minutes', 90 -> '1 minute 30 seconds'."""
    minutes, secs = divmod(int(seconds), 60)
    parts = []
    if minutes:
        parts.append('%d minute%s' % (minutes, '' if minutes == 1 else 's'))
    if secs or not parts:
        parts.append('%d second%s' % (secs, '' if secs == 1 else 's'))
    return ' '.join(parts)


def pause_before_batch(ctx, number, total, step):
    """Wait --batch-delay-sec before every batch after the first of a step, so RSC can finish one call before the next
    arrives. Returns the time the batch started, for the elapsed time printed with its result."""
    delay = ctx.args.batch_delay_sec
    if number > 1 and delay > 0:
        say('  Waiting %ds before %s call %d/%d (--batch-delay-sec, to give RSC time to finish the last one)' % (delay, step, number, total))
        time.sleep(delay)
    return time.monotonic()


def took(start):
    """' (took 12s)' for the time since start."""
    return ' (took %ds)' % round(time.monotonic() - start)


def chunks(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


def register_hosts(ctx, rows, cluster_id):
    """Register the hosts in one bulkRegisterHost call per batch. A failed call does not stop the others."""
    calls = chunks(rows, ctx.args.batch_size)
    timeout = ctx.timeouts['register']
    is_async = ctx.args.register_host_async
    if is_async:
        say('  Registering with the asynchronous call (--register-host-async): RSC accepts the request and registers the hosts in the background.')
    say('  Each registration call waits up to %ds (%s) for RSC to answer. To change it, rerun with --register-host-timeout-sec <seconds>, or --timeout-sec <seconds> for every step.'
        % (timeout, format_duration(timeout)))
    for number, batch in enumerate(calls, 1):
        started = pause_before_batch(ctx, number, len(calls), 'registration')
        try:
            data = invoke_rsc(ctx, M_REGISTER_HOSTS_ASYNC if is_async else M_REGISTER_HOSTS,
                              {'clusterUuid': cluster_id, 'hosts': [{'hostname': r['host']} for r in batch]}, read_timeout=timeout)
            items = (dig(data, 'bulkRegisterHostAsync', 'output', 'items') if is_async else dig(data, 'bulkRegisterHost', 'data')) or []
            by_name = {ikey(dig(i, 'hostSummary', 'hostname')): dig(i, 'hostSummary', 'id') for i in items}
            for r in batch:
                host_id = by_name.get(ikey(r['host']))
                if host_id:
                    r['hostId'] = host_id
                    r['hostAddStatus'] = 'Added'
                    r['rbsState'] = 'unknown'
                elif is_async:
                    # The request was accepted and RSC registers the host in the background. Nothing more can be done until
                    # the host shows up as registered, so its certificate and fileset steps wait for a rerun.
                    r['hostAddStatus'] = 'Add submitted (not yet confirmed)'
                    r['certUpdateStatus'] = 'Not done (registration still in the background, rerun later)'
                    r['filesetStatus'] = 'Not done (registration still in the background, rerun later)'
                    r['detail'] = ('Asynchronous registration submitted. The reply did not give this host id, so it is not confirmed. '
                                   'Rerun later: once it is registered it is "on the cluster" and gets its certificate update and fileset. '
                                   'If it never appears, check the Rubrik Backup Service on the host and its network path to the cluster.')
                else:
                    r['hostAddStatus'] = 'Add not confirmed'
                    r['certUpdateStatus'] = 'Not updated (host add not confirmed)'
                    r['filesetStatus'] = 'Not created (host add not confirmed)'
                    r['detail'] = 'RSC accepted the call but did not list this host in its reply (it listed %d host(s))' % len(items)
            say('  Register call %d/%d%s: %d host(s) sent, RSC listed %d%s%s' % (
                number, len(calls), ' (async)' if is_async else '', len(batch), len(items),
                ', so the rest are submitted and will register in the background' if is_async and len(items) < len(batch) else '', took(started)))
        except requests.exceptions.ReadTimeout:
            # The request was sent and RSC did not answer in time. The hosts may well have been registered anyway.
            for r in batch:
                r['hostAddStatus'] = 'Add not confirmed (timed out)'
                r['certUpdateStatus'] = 'Not updated (host add not confirmed)'
                r['filesetStatus'] = 'Not created (host add not confirmed)'
                r['detail'] = ('RSC did not answer the registration within %ds. It may still have registered the host: check the '
                               'final inventory (finalHostState) or RSC, and rerun to continue. Use --register-host-timeout-sec or --timeout-sec to wait longer.'
                               % timeout)
            say('  Register call %d/%d TIMED OUT after %ds for %d host(s). RSC may still register them, see the final check below.%s'
                % (number, len(calls), timeout, len(batch), took(started)), 'yellow')
        except Exception as exc:
            for r in batch:
                r['hostAddStatus'] = 'Add failed'
                r['certUpdateStatus'] = 'Not updated (host add failed)'
                r['filesetStatus'] = 'Not created (host add failed)'
                r['detail'] = str(exc)
            say('  Register call %d/%d FAILED for %d host(s)%s: %s' % (number, len(calls), len(batch), took(started), exc), 'red')


def add_detail(row, text):
    row['detail'] = ('%s; %s' % (row['detail'], text)) if row.get('detail') else text


def update_certs(ctx, rows):
    """Update the certificate of the hosts in one bulkUpdateHost call per batch (the UI sends the same call, with one
    host). The caller chooses the hosts: those just registered, those on the cluster that are not CONNECTED, or all
    of them with --force-rbs-update. A failed call does not stop the others, and a failed update does not stop the
    fileset step."""
    calls = chunks(rows, ctx.args.batch_size)
    timeout = ctx.timeouts['cert']
    say('  Each certificate update call waits up to %ds (%s) for RSC to answer. To change it, rerun with --update-rbs-timeout-sec <seconds>, or --timeout-sec <seconds> for every step.'
        % (timeout, format_duration(timeout)))
    for number, batch in enumerate(calls, 1):
        started = pause_before_batch(ctx, number, len(calls), 'certificate update')
        variables = {'hostUpdateProperties': [
            {'hostId': r['hostId'], 'updateProperties': {'isUpdateCertAndAgentIdEnabled': True}} for r in batch]}
        try:
            data = invoke_rsc(ctx, M_UPDATE_HOST_CERT, variables, read_timeout=timeout)
            listed = set(ikey(dig(i, 'hostSummary', 'id')) for i in (dig(data, 'bulkUpdateHost', 'output', 'items') or []))
            for r in batch:
                if ikey(r['hostId']) in listed:
                    r['certUpdateStatus'] = 'Update requested'
                else:
                    r['certUpdateStatus'] = 'Update not confirmed'
                    add_detail(r, 'certificate update: RSC accepted the call but did not list this host in its reply')
            say('  Certificate call %d/%d: %d host(s) sent, RSC listed %d%s' % (number, len(calls), len(batch), len(listed), took(started)))
        except requests.exceptions.ReadTimeout:
            # The request was sent and RSC did not answer in time. It may still be applying the update.
            for r in batch:
                r['certUpdateStatus'] = 'Update not confirmed (timed out)'
                add_detail(r, 'certificate update: RSC did not answer within %ds. It may still apply it: check finalRbsState or RSC, '
                              'and rerun later. Use --update-rbs-timeout-sec or --timeout-sec to wait longer, or a smaller --batch-size.' % timeout)
            say('  Certificate call %d/%d TIMED OUT after %ds for %d host(s). RSC may still apply it, see the final check below.%s'
                % (number, len(calls), timeout, len(batch), took(started)), 'yellow')
        except Exception as exc:
            for r in batch:
                r['certUpdateStatus'] = 'Update failed'
                add_detail(r, 'certificate update: %s' % exc)
            say('  Certificate call %d/%d FAILED for %d host(s)%s: %s' % (number, len(calls), len(batch), took(started), exc), 'red')


def create_filesets(ctx, rows, cluster_id, template_id):
    """Create the fileset on the hosts in one bulkCreateFilesets call per batch. The reply carries the new fileset ids
    but not their hosts, so they are matched to the hosts by the order sent."""
    calls = chunks(rows, ctx.args.batch_size)
    timeout = ctx.timeouts['fileset']
    say('  Each fileset call waits up to %ds (%s) for RSC to answer. To change it, rerun with --create-fileset-timeout-sec <seconds>, or --timeout-sec <seconds> for every step.'
        % (timeout, format_duration(timeout)))
    for number, batch in enumerate(calls, 1):
        started = pause_before_batch(ctx, number, len(calls), 'fileset')
        definitions = [{
            'hostId': r['hostId'], 'templateId': template_id, 'isPassthrough': False,
            'enableSymlinkResolution': False, 'enableHardlinkSupport': False,
        } for r in batch]
        try:
            data = invoke_rsc(ctx, M_CREATE_FILESETS, {'clusterUuid': cluster_id, 'definitions': definitions}, read_timeout=timeout)
            items = dig(data, 'bulkCreateFilesets', 'data') or []
            ids = [i for i in (dig(x, 'filesetSummary', 'slaAssignable', 'id') for x in items) if i]
            if len(ids) == len(batch):
                for r, fileset_id in zip(batch, ids):
                    r['filesetStatus'] = 'Created'
                    r['filesetId'] = fileset_id
            else:
                for r in batch:
                    r['filesetStatus'] = 'Create not confirmed'
                    r['detail'] = 'RSC returned %d fileset id(s) for %d host(s), so they cannot be matched to hosts' % (len(ids), len(batch))
            say('  Fileset call %d/%d: %d host(s) sent, RSC returned %d fileset id(s)%s' % (number, len(calls), len(batch), len(ids), took(started)))
        except requests.exceptions.ReadTimeout:
            # The request was sent and RSC did not answer in time. It may still create the filesets.
            for r in batch:
                r['filesetStatus'] = 'Create not confirmed (timed out)'
                r['detail'] = ('RSC did not answer the fileset creation within %ds. It may still create it: check finalFileset or RSC, '
                               'and rerun later. Use --create-fileset-timeout-sec or --timeout-sec to wait longer, or a smaller --batch-size.' % timeout)
            say('  Fileset call %d/%d TIMED OUT after %ds for %d host(s). RSC may still create it, see the final check below.%s'
                % (number, len(calls), timeout, len(batch), took(started)), 'yellow')
        except Exception as exc:
            for r in batch:
                r['filesetStatus'] = 'Create failed'
                r['detail'] = str(exc)
            say('  Fileset call %d/%d FAILED for %d host(s)%s: %s' % (number, len(calls), len(batch), took(started), exc), 'red')


### ARGUMENTS ###


def print_usage_summary():
    say('')
    say('add_host_fileset.py', 'cyan')
    say('Register hosts that are not in RSC yet, update certificates, and create a fileset on the new hosts and on listed hosts that lack it.')
    say('')
    say('  python3 add_host_fileset.py --rsc-service-account-json ./rsc-sa.json --cluster-name cluster01 \\')
    say('    --host-csv-path ./hosts.csv --fileset-name Windows_Share')
    say('')
    say('  Hosts come from --host-csv-path or --hosts. The inventory is read once for ALL clusters.')
    say('  Not in the inventory: registered to --cluster-name, its certificate updated, then the fileset is created.')
    say('  Already on --cluster-name: not registered again. Its fileset is created only if it lacks it, and its certificate')
    say('  is updated only if its RBS state is not CONNECTED.')
    say('  On a different cluster: reported, not touched. No SLA is assigned.')
    say('  Output: <prefix>host_fileset_status-<time>.csv, written every run (also on --dry-run).')
    say('  The steps run in this order: register hosts, update certificates, create the fileset. After the last change a fresh')
    say('  inventory is read (a snapshot, not a wait) and the status CSV gets each host final RBS state and whether it has the fileset.')
    say('  --force-rbs-update updates the certificate of every listed host on the cluster, CONNECTED or not.')
    say('  --register-host-async registers in the background and returns quickly. Rerun later for the certificate and fileset steps.')
    say('  --cdm-api (with --cluster-name, the node address is read from RSC) does the whole run through the CDM REST API instead of RSC:')
    say('  bulk register, then refresh each host that is not Connected and create the fileset one host at a time (--cdm-pause-sec).')
    say('  One step only: --do-only-register-host, --do-only-update-rbs (no fileset name needed) or --do-only-create-fileset.')
    say('  The last two read the inventory first and act only on hosts already registered: a listed host that is not registered is')
    say('  flagged in the CSV and the exit code is 1, nothing is registered.')
    say("  A template name with a space needs straight quotes: --fileset-name 'Windows File Share'")
    say('  Add --dry-run to see the plan without sending anything. You are asked to confirm (y or yes) unless --skip-confirm.')
    say("  Run 'python3 add_host_fileset.py --help' for every option.")
    say('')


def build_parser():
    parser = argparse.ArgumentParser(
        description='Register hosts that are not in RSC yet, update the certificate of the new hosts and of listed hosts '
                    'on the cluster that are not CONNECTED, and create a fileset from an existing template on the new hosts '
                    'and on listed hosts on the cluster that lack it. Any one step can be run alone with --do-only-...',
        epilog='IMPORTANT: this registers real hosts, updates certificates and creates filesets. Run with --dry-run first.',
        allow_abbrev=False)
    parser.add_argument('--rsc-service-account-json', help='Path to the RSC Service Account JSON (client_id, client_secret, access_token_uri). Required.')
    parser.add_argument('--cluster-name', '--clusterName', dest='cluster_name', help='Exact name of the cluster to work on. Hosts are registered to it, and certificates are updated and filesets created for hosts on it. A host registered only to another cluster is never changed. Required.')
    parser.add_argument('--hosts', nargs='+', metavar='HOST', help='Host names (exact match, case-insensitive). Space or comma separated. The CSV wins if both are given.')
    parser.add_argument('--host-csv-path', help='Host CSV with a hostname, host, name or sqlhost column. It is not modified.')
    parser.add_argument('--fileset-name', help="Name of the existing fileset template on --cluster-name (exact match, case-insensitive). Put a name with a space in straight quotes, for example --fileset-name 'Windows File Share'. Never created or changed. Not needed with --do-only-register-host or --do-only-update-rbs.")
    parser.add_argument('--fileset-template-id', help='ID of the existing fileset template, instead of --fileset-name.')
    parser.add_argument('--host-root', choices=['WINDOWS_HOST_ROOT', 'LINUX_HOST_ROOT'], default='WINDOWS_HOST_ROOT', help='Host type to read the inventory and the template for. Default: WINDOWS_HOST_ROOT')
    parser.add_argument('--batch-size', type=int, default=50, help='Hosts per bulk call, used for each of the three steps. A failed call does not stop the others. Default: 50')
    parser.add_argument('--batch-delay-sec', type=int, default=DEFAULT_BATCH_DELAY, help='Seconds to wait before each batch after the first, within each step (register, certificate update, fileset creation), so RSC can finish one call before the next arrives. Default: 60. Use 0 for no pause. The first batch of a step never waits, and a step with only one batch never pauses.')
    parser.add_argument('--timeout-sec', type=int, default=None, help='How many seconds to wait for RSC to answer each bulk call, for all three steps (register, update certificate, create fileset). The default is 1800 for the registration and 900 for the other two. A step flag below (--register-host-timeout-sec, --update-rbs-timeout-sec, --create-fileset-timeout-sec) overrides this for that step. A timeout does not mean the call failed, RSC may still do it, so check the final state and rerun.')
    parser.add_argument('--register-host-async', action='store_true', help='Register the hosts with the asynchronous call (bulkRegisterHostAsync) instead of the default synchronous one. RSC accepts the request and completes the registration in the background, so the call returns quickly. If the reply lists the hosts with their ids they are treated as added and the certificate and fileset steps run. If it does not, the hosts are marked Add submitted (not yet confirmed) and their certificate and fileset steps are left for a rerun, once the hosts show up as registered. Nothing is polled or retried. Registration still needs the Rubrik Backup Service installed and reachable on each host.')
    parser.add_argument('--register-host-timeout-sec', type=int, default=None, help='How many seconds to wait for RSC to answer each host registration call (bulkRegisterHost). Default: 1800 (30 minutes), or --timeout-sec if given. A timeout does not mean the registration failed, RSC may still register the hosts, so check the final inventory or the status CSV.')
    parser.add_argument('--update-rbs-timeout-sec', type=int, default=None, help='How many seconds to wait for RSC to answer each certificate update call (bulkUpdateHost). Default: 900 (15 minutes), or --timeout-sec if given. A timeout does not mean the update failed, RSC may still apply it.')
    parser.add_argument('--create-fileset-timeout-sec', type=int, default=None, help='How many seconds to wait for RSC to answer each fileset creation call (bulkCreateFilesets). Default: 900 (15 minutes), or --timeout-sec if given. A timeout does not mean the creation failed, RSC may still create it.')
    parser.add_argument('--csv-output-prefix', default='./rubrik_', help='Location and prefix for the status CSV. The name and timestamp are appended. The directory must exist. Default: ./rubrik_')
    parser.add_argument('--do-only-register-host', dest='do_only_register', action='store_true', help='Only register the hosts that are not in RSC yet, then stop. No certificate update and no fileset, so no fileset template is needed. Cannot be combined with the other --do-only flags.')
    parser.add_argument('--do-only-update-rbs', dest='do_only_cert', action='store_true', help='Only update the certificate of the listed hosts that are already on --cluster-name and are not CONNECTED, then stop (add --force-rbs-update for all of them). No registration and no fileset, so no fileset template is needed. The inventory is read first, and a listed host that is not registered yet is flagged (exit code 1), not registered. Cannot be combined with the other --do-only flags.')
    parser.add_argument('--do-only-create-fileset', dest='do_only_fileset', action='store_true', help='Only create the fileset on the listed hosts that are already on --cluster-name and lack it, then stop. Nothing is registered. The inventory is read first, and a listed host that is not registered yet is flagged (exit code 1), not registered. Needs --fileset-name or --fileset-template-id. Cannot be combined with the other --do-only flags.')
    parser.add_argument('--force-rbs-update', action='store_true', help='Send the certificate update to EVERY listed host on --cluster-name, CONNECTED or not, including hosts whose RBS state RSC did not return. Without it the update goes only to the hosts just registered and to listed hosts on the cluster whose state is not CONNECTED (a host in an unknown state is skipped). Applies to the full run and to --do-only-update-rbs, not to --do-only-register-host or --do-only-create-fileset. A host registered to a different cluster, or not registered, is never updated.')
    parser.add_argument('--cdm-api', action='store_true', help='Use the CDM REST API of one cluster node instead of RSC for the whole run: read the Windows hosts and filesets, register hosts in bulk (POST /v1/host/bulk_background, asynchronous), refresh the certificate of hosts that are not Connected (PUT /v1/host/certificate/<id>, one host per call) and create the fileset (POST /v1/fileset, one host per call). The node is found from --cluster-name through RSC, or given with --cdm-cluster-address. Works with the full run and with every --do-only flag. The inventory covers only that cluster, so a host registered to a different cluster is not detected.')
    parser.add_argument('--cdm-cluster-address', help='Optional, with --cdm-api: the IP address or host name of the CDM node to talk to (for example 172.24.37.14). Without it the node address is read from RSC for --cluster-name (the first node whose status is OK, then the others if the login fails), which needs the service account to be allowed in RSC. With it, RSC is not contacted at all and --cluster-name is not needed. Authentication to the node uses the same service account JSON (client_id and client_secret).')
    parser.add_argument('--cdm-pause-sec', type=int, default=DEFAULT_CDM_PAUSE, help='With --cdm-api, seconds to pause between the one-host-at-a-time calls (the certificate refresh and the fileset creation). Default: 1. Registration is one bulk call per batch and uses --batch-delay-sec instead.')
    parser.add_argument('--cdm-fileset-filter', default='', help='With --cdm-api, narrow the fileset list read from the cluster to filesets whose name matches this text (the CDM name filter). Default: no name filter, all live filesets are read and matched to the template by its id, so this is rarely needed, and it only speeds up a cluster with very many filesets.')
    parser.add_argument('--verify-ssl', action='store_true', help='Verify the TLS certificate. Off by default, so self-signed certificates work.')
    parser.add_argument('--dry-run', action='store_true', help='Show the plan and write the status CSV (it shows what WOULD be done), but send nothing to RSC. No final check is made.')
    parser.add_argument('--skip-confirm', action='store_true', help='Skip the confirmation prompt (y or yes).')
    return parser


### MAIN ###


def run(ctx):
    args = ctx.args
    if not args.rsc_service_account_json:
        die('--rsc-service-account-json is required.')
    if args.cdm_api:
        if not args.cdm_cluster_address and not args.cluster_name:
            die('--cdm-api needs --cluster-name (the node address is then read from RSC) or --cdm-cluster-address (a node of the CDM cluster).')
        if args.register_host_async:
            die('--register-host-async is the RSC asynchronous call. With --cdm-api the registration is already asynchronous (POST /v1/host/bulk_background), so drop it.')
        if args.cdm_pause_sec < 0:
            die('--cdm-pause-sec must be 0 or greater.')
    elif not args.cluster_name:
        die('--cluster-name is required. Every change is made on that one cluster.')
    if args.batch_size < 1:
        die('--batch-size must be 1 or greater.')
    if args.batch_delay_sec < 0:
        die('--batch-delay-sec must be 0 or greater.')
    for flag, value in (('--timeout-sec', args.timeout_sec), ('--register-host-timeout-sec', args.register_host_timeout_sec),
                        ('--update-rbs-timeout-sec', args.update_rbs_timeout_sec),
                        ('--create-fileset-timeout-sec', args.create_fileset_timeout_sec)):
        if value is not None and value < 1:
            die('%s must be 1 or greater.' % flag)
    # The wait for each step: its own flag, else --timeout-sec, else the step's default
    ctx.timeouts = {
        'register': first_set(args.register_host_timeout_sec, args.timeout_sec, DEFAULT_REGISTER_TIMEOUT),
        'cert': first_set(args.update_rbs_timeout_sec, args.timeout_sec, DEFAULT_CALL_TIMEOUT),
        'fileset': first_set(args.create_fileset_timeout_sec, args.timeout_sec, DEFAULT_CALL_TIMEOUT),
    }
    only = [f for f, on in (('--do-only-register-host', args.do_only_register), ('--do-only-update-rbs', args.do_only_cert),
                            ('--do-only-create-fileset', args.do_only_fileset)) if on]
    if len(only) > 1:
        die('Use only one of --do-only-register-host, --do-only-update-rbs and --do-only-create-fileset, not %s.' % ' and '.join(only))
    if args.force_rbs_update and (args.do_only_register or args.do_only_fileset):
        die('--force-rbs-update only applies when the certificate update runs (the full run or --do-only-update-rbs), not with %s.' % only[0])
    do_register = not (args.do_only_cert or args.do_only_fileset)
    do_cert = not (args.do_only_register or args.do_only_fileset)
    do_fileset = not (args.do_only_register or args.do_only_cert)
    steps = set(s_ for s_, on in (('register', do_register), ('cert', do_cert), ('fileset', do_fileset)) if on)
    if do_fileset and not args.fileset_name and not args.fileset_template_id:
        die('Provide the fileset template with --fileset-name or --fileset-template-id.')
    if args.fileset_name and args.fileset_template_id:
        die('Specify either --fileset-name or --fileset-template-id, not both.')
    if not do_fileset and (args.fileset_name or args.fileset_template_id):
        say('A fileset template was given but %s does not create filesets, so it is ignored.' % only[0], 'yellow')

    hosts_arg = split_names(args.hosts)
    if not hosts_arg and not args.host_csv_path:
        die('Provide hosts with --hosts and/or --host-csv-path.')
    if args.host_csv_path:
        if hosts_arg:
            say('Both --hosts and --host-csv-path were given. Using the hosts in the CSV and ignoring --hosts.', 'yellow')
        listed = read_host_csv(args.host_csv_path)
    else:
        listed = hosts_arg
    names = []
    seen = set()
    for n in listed:
        n = str(n).strip()
        if n and n.lower() not in seen:
            seen.add(n.lower())
            names.append(n)
    if not names:
        die('No host names were provided.')

    ctx.out_path = '%shost_fileset_status-%s.csv' % (args.csv_output_prefix, datetime.now().strftime('%Y-%m-%d_%H%M%S'))

    configure_tls(ctx)
    if args.cdm_api:
        cdm_authenticate(ctx)
        try:
            return run_after_login(ctx, names, only, do_register, do_cert, do_fileset, steps)
        finally:
            cdm_logout(ctx)
    authenticate(ctx)
    return run_after_login(ctx, names, only, do_register, do_cert, do_fileset, steps)


def run_after_login(ctx, names, only, do_register, do_cert, do_fileset, steps):
    """Everything after the login: the cluster and template lookups, the inventory, the plan, the three steps and the final
    check. With --cdm-api these go to the CDM REST API of one cluster node, otherwise to RSC."""
    args = ctx.args
    if args.cdm_api:
        cluster_id, cluster_name = cdm_get_cluster(ctx)
        say("CDM cluster '%s'" % cluster_name)
    else:
        cluster_id, cluster_name = get_cluster(ctx, args.cluster_name)
        say("Cluster '%s' (%s)" % (cluster_name, cluster_id))
    template_id, template_name = None, ''
    if do_fileset:
        if args.cdm_api:
            template_id, template_name = cdm_get_template(ctx)
        else:
            template_id, template_name = get_template(ctx, cluster_id, cluster_name)
        say("Fileset template '%s' (%s)" % (template_name, template_id))

    if args.cdm_api:
        say('Reading the %s hosts and filesets of the CDM cluster (this cluster only)' % ('Windows' if args.host_root == 'WINDOWS_HOST_ROOT' else 'Linux'))
        inventory = cdm_inventory(ctx, template_id)
        say('%d host(s) on the CDM cluster' % len(inventory))
    else:
        say('Reading the host inventory for all clusters (host root %s)' % args.host_root)
        inventory = get_inventory(ctx)
        say('%d host(s) on %d cluster(s)' % (len(inventory), len(unique_ordered(dig(h, 'cluster', 'id') for h in inventory))))

    rows, groups = classify_hosts(inventory, names, cluster_id, cluster_name, template_id, template_name, steps,
                                  args.force_rbs_update)
    new_rows = groups['new']
    cert_rows = [r for r in rows if r['certUpdateStatus'] == 'To be updated']
    fileset_rows = (new_rows + groups['needs_fileset']) if do_fileset else []
    to_change = bool(new_rows or cert_rows or fileset_rows)

    # Plan
    say('')
    say('Plan', 'cyan')
    say('  Cluster:                  %s%s' % (cluster_name, ' (CDM REST API, --cdm-api)' if args.cdm_api else ''))
    say('  Steps:                    %s' % (' -> '.join(n for n, on in (('register hosts', do_register), ('update certificate', do_cert), ('create fileset', do_fileset)) if on)
                                                + ('  (only this step: %s)' % only[0] if only else '')))
    if do_fileset:
        say('  Fileset template:         %s' % template_name)
    say('  Hosts listed:             %d' % len(names))
    say('  Pause between batches:    %s' % (('%ds before each batch after the first in a step (--batch-delay-sec)' % args.batch_delay_sec) if args.batch_delay_sec else 'none (--batch-delay-sec 0)'))
    say('  Wait per call:            %s (change with --timeout-sec, or a step flag, see --help)' % ', '.join(
        '%s %s' % (label, format_duration(ctx.timeouts[key])) for label, key, on in (
            ('register', 'register', do_register), ('certificate', 'cert', do_cert), ('fileset', 'fileset', do_fileset)) if on))
    if do_register:
        say('  Hosts to register:        %d (in %d call(s) of up to %d)%s' % (
            len(new_rows), (len(new_rows) + args.batch_size - 1) // args.batch_size, args.batch_size,
            ', asynchronous: submitted and registered in the background' if args.register_host_async else ''))
    if do_cert:
        if args.cdm_api:
            say('  Certificates to refresh:  %d (%d newly registered, %d already on the cluster%s), one call per host, %ds apart' % (
                len(cert_rows), len(new_rows) if do_register else 0, len(groups['cert_existing']),
                ' that are not Connected' if not args.force_rbs_update else ', all of them forced', args.cdm_pause_sec))
        else:
            say('  Certificates to update:   %d (%d newly registered, %d already on the cluster%s), in %d call(s) of up to %d' % (
                len(cert_rows), len(new_rows) if do_register else 0, len(groups['cert_existing']),
                ' that are not CONNECTED' if not args.force_rbs_update else ', all of them forced',
                (len(cert_rows) + args.batch_size - 1) // args.batch_size, args.batch_size))
    if do_fileset:
        if args.cdm_api:
            say('  Filesets to create:       %d (%d on new hosts, %d on hosts already on the cluster), one call per host, %ds apart' % (
                len(fileset_rows), len(new_rows), len(groups['needs_fileset']), args.cdm_pause_sec))
        else:
            say('  Filesets to create:       %d (%d on new hosts, %d on hosts already on the cluster), in %d call(s) of up to %d' % (
                len(fileset_rows), len(new_rows), len(groups['needs_fileset']),
                (len(fileset_rows) + args.batch_size - 1) // args.batch_size, args.batch_size))
        say('  Already have the fileset: %d' % len(groups['has_fileset']))
    if groups['not_registered']:
        say('  Not registered, skipped:  %d (this run does not register hosts)' % len(groups['not_registered']))
    if args.cdm_api:
        say('  Note:                     the CDM inventory covers only this cluster, so a host registered to another cluster is not detected.')
    else:
        say('  On a different cluster:   %d (not touched)' % len(groups['other']))
    say('')
    print_group('NOT REGISTERED, will be added to %s%s' % (cluster_name, ' and given the fileset' if do_fileset else ''), new_rows, 'yellow')
    print_group('Already on %s, certificate will be updated%s' % (
        cluster_name, ' (--force-rbs-update, whatever their state)' if args.force_rbs_update else ' (not CONNECTED)'),
        groups['cert_existing'], 'yellow')
    print_group('Already on %s, fileset will be created' % cluster_name, groups['needs_fileset'], 'yellow')
    if do_fileset:
        print_group('Already on %s and already have the fileset, fileset skipped' % cluster_name, groups['has_fileset'], None)
    print_group('Already on %s, nothing to do in this run%s' % (
        cluster_name, ' (CONNECTED, REFRESHING or unknown state, add --force-rbs-update to update them too)' if do_cert else ''),
        groups['nothing'], None)
    print_group('NOT REGISTERED anywhere, FLAGGED and skipped (this run does not register hosts, exit code 1)', groups['not_registered'], 'red')
    if args.force_rbs_update and do_cert:
        say('--force-rbs-update: every listed host on %s, CONNECTED or not, WILL get the certificate update.' % cluster_name, 'yellow')
    print_group('Registered to a DIFFERENT cluster, not touched', groups['other'], 'red')
    print_group('More than one host with this name on %s, skipped' % cluster_name, groups['ambiguous'], 'red')
    say('')

    # The status CSV exists before anything is sent, so a dry run shows what would be done
    write_output(ctx, rows)
    say('Status CSV (rewritten as the run progresses, and updated with a final inventory check at the end): %s' % ctx.out_path, 'green')

    if args.dry_run:
        print_summary(ctx, rows)
        say('Dry run, nothing changed in %s.' % ('the CDM cluster' if args.cdm_api else 'RSC'))
        return 0

    if to_change and not args.skip_confirm:
        try:
            answer = input('Continue? Type y or yes (any case) to make these changes: ')
        except EOFError:
            answer = ''
        if answer.strip().lower() not in ('y', 'yes'):
            for r in rows:
                if r['hostAddStatus'] == 'To be added':
                    r['hostAddStatus'] = 'Cancelled (not sent)'
                if r['certUpdateStatus'] == 'To be updated':
                    r['certUpdateStatus'] = 'Cancelled (not sent)'
                if r['filesetStatus'] == 'To be created':
                    r['filesetStatus'] = 'Cancelled (not sent)'
            write_output(ctx, rows)
            print_summary(ctx, rows)
            say('Cancelled, nothing changed in %s.' % ('the CDM cluster' if args.cdm_api else 'RSC'))
            return 0
    if not to_change:
        say('Nothing to do for this run.')

    try:
        if new_rows:
            say('Registering %d host(s) to %s' % (len(new_rows), cluster_name), 'cyan')
            if args.cdm_api:
                cdm_register_hosts(ctx, new_rows, cluster_id)
            else:
                register_hosts(ctx, new_rows, cluster_id)
            write_output(ctx, rows)
        if do_cert:
            cert_ready = [r for r in cert_rows if r['certUpdateStatus'] == 'To be updated' and r['hostId']
                          and r['hostAddStatus'] in ('Added', 'Already added')]
            if cert_ready:
                say('Updating the certificate of %d host(s)' % len(cert_ready), 'cyan')
                if args.cdm_api:
                    cdm_refresh_hosts(ctx, cert_ready)
                else:
                    update_certs(ctx, cert_ready)
                write_output(ctx, rows)
        if do_fileset:
            ready = [r for r in fileset_rows if r['filesetStatus'] == 'To be created' and r['hostId']]
            if ready:
                say('Creating the fileset on %d host(s)' % len(ready), 'cyan')
                if args.cdm_api:
                    cdm_create_filesets(ctx, ready, template_id)
                else:
                    create_filesets(ctx, ready, cluster_id, template_id)
                write_output(ctx, rows)
    except KeyboardInterrupt:
        for r in rows:
            if r['hostAddStatus'] == 'To be added':
                r['hostAddStatus'] = 'Interrupted (not confirmed)'
            if r['certUpdateStatus'] == 'To be updated':
                r['certUpdateStatus'] = 'Interrupted (not confirmed)'
            if r['filesetStatus'] == 'To be created':
                r['filesetStatus'] = 'Interrupted (not confirmed)'
        write_output(ctx, rows)
        say('')
        say('Interrupted. Anything marked Interrupted (not confirmed) may or may not have been done in %s, check it there.' % ('the CDM cluster' if args.cdm_api else 'RSC'), 'yellow')
        say('Status CSV: %s' % ctx.out_path, 'green')
        return 130

    write_output(ctx, rows)
    # The final step: a fresh inventory, then the status CSV is updated with what RSC shows now. Only when this run
    # sent something, since otherwise nothing could have changed.
    if to_change:
        try:
            if final_check(ctx, rows, cluster_id, cluster_name, template_id):
                write_output(ctx, rows)
        except KeyboardInterrupt:
            say('Final check interrupted, the status CSV has the results of the changes but no final state.', 'yellow')
    print_summary(ctx, rows)
    print_final_summary(rows)
    return 1 if any(needs_attention(r) for r in rows) else 0


def main():
    if len(sys.argv) == 1:
        print_usage_summary()
        return 0
    ctx = Ctx(build_parser().parse_args())
    try:
        return run(ctx)
    except Stop as exc:
        say('ERROR: %s' % exc, 'red')
        return 1
    except KeyboardInterrupt:
        say('Interrupted.', 'yellow')
        return 130


if __name__ == '__main__':
    sys.exit(main())
