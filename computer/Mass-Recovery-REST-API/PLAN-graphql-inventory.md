# Plan: RSC GraphQL backend for `get_ahv_inventory.py`

Status: **planned, not implemented.** Cycle 1 (CDM REST) is built. This is cycle 2.

Goal: make RSC GraphQL the DEFAULT inventory source, with CDM REST behind
`--source cdm`. One paginated GraphQL call returns strictly more than the CDM
REST N+1 path -- including NICs, vCPU, memory, and per-disk storage container.

All schema facts below were verified against
`computer/Core/rsc_schema_introspection-2026-07-29_1624.json` (7,636 types,
targeted queries only). Items that could NOT be verified offline are called out
explicitly in the last section.

---

## 1. The critical correctness issue: FID vs CDM id

RSC identifies a VM by FID (`NutanixVm.id`, a plain UUID). CDM recovery needs
`NutanixVirtualMachine:::<clusterUuid>-vm-<vmUuid>`. The inventory CSV must
carry the CDM form or the recovery scripts break.

**The embedded `<clusterUuid>` is the UUID segment of the Nutanix cluster's CDM
id -- NOT its `naturalId`.** These are different values. From the captured API
(`rest_api-ahv_export_live_mount.json`, calls 6 and 11), for one cluster:

```
CDM id     NutanixCluster:::21fb4363-2510-4ce3-bca2-d4c2ad0f50ab
naturalId  0005f79a-13b0-68d3-1ddc-7cc255215058
VM id      NutanixVirtualMachine:::21fb4363-...-vm-469b8bac-...
                                   ^^^^^^^^ the CDM id UUID, not naturalId
```

Building ids from `naturalId` produces ids that never resolve. Add a code
comment citing this so nobody "fixes" it later.

Whether `NutanixVm.cdmId` already returns the full `NutanixVirtualMachine:::`
form cannot be settled from introspection (it carries types, not values).
Strong indirect evidence says yes: `NutanixLiveMount` deliberately carries both
forms as separate fields (`sourceVmId` "CDM ID of the source virtual machine"
vs `sourceVmFid` "ID of the source virtual machine"), so RSC uses "CDM ID" to
mean the managed-id string throughout.

Implement a defensive normalizer handling three cases, and record which fired
in a `cdm_id_source` CSV column:

1. `cdmId` already starts with `NutanixVirtualMachine:::` -- use as is.
2. `cdmId` is a bare `<clusterUuid>-vm-<vmUuid>` body -- prefix it.
3. Neither -- reconstruct from the `physicalPath` node whose
   `objectType == "NutanixCluster"`, mapping its `fid` to that cluster's CDM id
   UUID, joined with `vmUuid`. Lowercase both UUID segments.

### Validation, cheapest first

- **L1 structural (always on, free).** Every emitted `vm_id` must match
  `^NutanixVirtualMachine:::([0-9a-f-]{36})-vm-([0-9a-f-]{36})$`, and group 1
  must equal the UUID segment of that row's `nutanix_cluster_id`. Failures go
  to `ahv_inventory_unmapped_<ts>.csv` and are excluded, never silently kept.
- **L2 live-mount cross-check (always on, one query).** `nutanixMounts` returns
  `sourceVmFid` AND `sourceVmId` on the same object -- an authoritative
  FID-to-CDM-id pairing from RSC itself. Any mismatch is a hard failure.
- **L3 CDM spot-check (opt-in, definitive).** `--verify_cdm <fqdn>` reuses the
  existing `connect_cdm()` and `GET /internal/nutanix/vm/{id}` on a sample of
  emitted ids, asserting name and cluster match. Also compares RSC
  `storageContainers[].uuid` against CDM `container.naturalId`.
- **L4 `--debug`** dumps the first raw node so a human can read `cdmId` once.

---

## 2. Queries

Root signature (VERIFIED): `nutanixVms(first: Int, after: String, sortBy:
HierarchySortByField, sortOrder: SortOrder, filter: [Filter!])`. Note `filter`
is singular. Use `nodes` rather than `edges { node }`. `PageInfo` exposes
`hasNextPage` and `endCursor`.

Filter values (VERIFIED on `HierarchyFilterField`): `IS_RELIC`,
`IS_REPLICATED`, `IS_ACTIVE`, `CLUSTER_ID`, `NAME`. Default filter:
`IS_RELIC=false`, `IS_REPLICATED=false`, `IS_ACTIVE=true`.

### VM query -- base selection (all fields VERIFIED on `NutanixVm`)

```
id cdmId name vmUuid isRelic osType hypervisorType currentHostId
isAgentRegistered nutanixVmMountCount snapshotConsistencyMandate
slaAssignment slaPauseStatus excludedDisks
agentStatus { connectionStatus disconnectReason }
metadata { memoryInMb numVcpus numCoresPerVcpu
           vmNics { networkUuid networkName } }
vmDisks { uuid label deviceType vmDiskUuid sizeInBytes isSnapshottable
          storageContainerId storageContainerName }
cluster { id name version status }
physicalPath { fid name objectType }
effectiveSlaDomain { id name }
configuredSlaDomain { id name }
effectiveSlaSourceObject { fid name objectType }
```

`SlaDomain` is an interface exposing only `id`, `name`, `version`,
`objectSpecificConfigs` -- so `{ id name }` needs no inline fragment.

### Cluster query (VERIFIED on `NutanixCluster`)

```
id cdmId name naturalId hostName nosVersion
connectionStatus { status message }
cluster { id name version status }
storageContainers { uuid name totalBytes freeBytes usedBytes }
clusterNetworks { uuid name }
```

Run this FIRST -- it builds the cluster FID to CDM id map that the VM id
normalizer depends on, and produces the containers and networks CSVs.

### Opt-in extras (spliced into the query at build time)

- `--include_snapshots`: `onDemandSnapshotCount`, `snapshotDistribution
  { totalCount scheduledCount onDemandCount retrievedCount }`,
  `newestSnapshot { id date }`, `oldestSnapshot { id date }`,
  `newestArchivedSnapshot { id date }`, `newestReplicatedSnapshot { id date }`
- `--include_storage`: `reportSnappable { physicalBytes logicalBytes
  localStorage archiveStorage replicaStorage provisionedBytes lastSnapshot
  totalSnapshots complianceStatus protectionStatus }`
- `--include_tags`: `allOrgs { fullName }`, `allTags { key value }`

These are the expensive selections and the most likely cause of timeouts or
complexity rejections on a large tenant. Keep them off by default.

### NOT available on `NutanixVm` -- verified absent

Power state, guest IP, MAC address, and `isPaused`. `powerStatus` exists only
on mount-side types (`NutanixLiveMount`, `NutanixVmMountSummary`).
`NutanixVmNic` has only `networkUuid` and `networkName`. Use `slaPauseStatus`
as the nearest read-only equivalent to a pause flag.

---

## 3. New module: `rsc_client.py`

Sibling to `cdm_client.py`. Stdlib only, Python 3.6, percent-formatting, no
type hints. Auth differs from CDM: the service account JSON supplies
`access_token_uri` (`https://<tenant>.my.rubrik.com/api/client_token`); POST
`client_id` / `client_secret`, read `access_token`, then POST queries to
`/api/graphql`.

```
class RSCClient:
    __init__(rsc_url, client_id, client_secret, timeout=150,
             verify_ssl=True, debug=False)
    graphql(query, variables=None, timeout=None)
    paginate(query, variables, connection_key, page_size=100,
             retries=3, retry_delay=15)     # generator over nodes
    list_nutanix_vms / list_nutanix_clusters / list_nutanix_mounts

def load_rsc_credentials(json_path)   # -> (rsc_url, client_id, client_secret)
```

Deliberate divergences from `cdm_client.py`, each for a reason:

- **TLS verification defaults ON.** CDM uses self-signed certs so
  `cdm_client.py` sets `CERT_NONE`; `*.my.rubrik.com` uses a public CA. Expose
  `--insecure` for TLS-inspecting proxies. Do not copy the unconditional
  `CERT_NONE` from `python/host-delete/rsc_delete_filesets.py`.
- **`debug` flag** -- GraphQL failures are opaque without the query and the
  `errors` array.
- Map 502/503/504 and socket timeouts to `TimeoutError`, matching
  `cdm_client.py`, so retry logic behaves identically across both clients.
- A non-empty `result["errors"]` raises.

Also add `cdm_client.get_cluster_me()` (`GET /v1/cluster/me`) and
`ahv_common.connect_rsc()` / `add_rsc_auth_args()`.

---

## 4. CLI

`--source {rsc,cdm}`, default `rsc` (matches the promise already written into
the `get_ahv_inventory.py` docstring).

New arguments: `--rsc_url`, `--insecure`, `--cluster_filter`,
`--nutanix_cluster_filter`, `--include_relics`, `--include_replicas`,
`--include_snapshots`, `--include_storage`, `--include_tags`,
`--split_by_cluster`, `--page_size` (default 100), `--verify_cdm`,
`--verify_sample` (default 5), `--debug`.

Cross-backend validation runs before any prompt or network call. A flag that
changes what data you get is a hard error when it cannot apply; a merely
redundant flag is a warning. `--force` does not bypass these -- they are
argument-shape errors, not confirmations.

- Hard error: `--source rsc` with `--cluster`; `--source cdm` with any
  rsc-only flag; `--source rsc` with a JSON lacking `access_token_uri`.
- Warning: `--source rsc` with `--detail` (no-op, GraphQL always returns disks)
  or `--parallel` (pagination is sequential); `--source cdm` without `--detail`
  (disk columns will be blank).

---

## 5. Unified CSV schema

One header, both backends. GraphQL-only columns are emitted BLANK in CDM mode,
never omitted, so either backend produces a CSV the recovery scripts accept.

Load-bearing columns that must always be populated: `vm_name`, `vm_id` (CDM
form), `nutanix_cluster_id` (CDM form). `target_container_name` and
`vm_name_prefix` must remain the last two columns.

Added over cycle 1: `vm_fid`, `vm_uuid`, `nutanix_cluster_fid`,
`nutanix_cluster_natural_id`, `rubrik_cluster_name`, `rubrik_cluster_id`,
`configured_sla_domain_name`, `sla_pause_status`, `disk_container_names`,
`disk_container_ids`, `num_vcpus`, `num_cores_per_vcpu`, `memory_mb`,
`nic_count`, `nic_network_names`, `nic_network_uuids`, `snapshot_count`,
`newest_snapshot_date`, `oldest_snapshot_date`,
`newest_archived_snapshot_date`, `on_demand_snapshot_count`, `mount_count`,
`physical_bytes`, `archive_bytes`, `current_host_id`, `inventory_source`,
`cdm_id_source`.

Semantic caveat to document: CDM `isPaused` (object pause) and RSC
`slaPauseStatus` (SLA pause) are NOT the same thing despite sharing a column.

Companion CSVs: the containers CSV gains `container_total_bytes`,
`container_free_bytes`, `container_used_bytes` (blank in CDM mode -- free space
on the target container is exactly what an operator needs before staging a
wave). New `ahv_networks_<ts>.csv` (RSC only) and
`ahv_inventory_unmapped_<ts>.csv` (only when validation rejects rows).

Normalize enums (uppercase, strip the
`REFRESHABLE_OBJECT_CONNECTION_STATUS_TYPE_` prefix) so a CDM row and an RSC
row for the same VM are byte-identical in those cells.

---

## 6. Multi-cluster hazard

`nutanixVms` is tenant-wide; `ahv_mass_recovery.py` connects to ONE cluster.
Feeding a tenant-wide CSV into a single-cluster run means rows for other
clusters fail opaquely -- or worse, are dropped from a wave the operator
believes is complete.

Mitigations, in order of value:

1. Always emit `rubrik_cluster_name` / `rubrik_cluster_id`. Non-negotiable.
2. **Guard in `ahv_mass_recovery.py`:** after `connect_cdm()`, call
   `get_cluster_me()` and exclude any wave row whose non-empty
   `rubrik_cluster_id` differs, with reason "row belongs to Rubrik cluster X,
   connected to Y". Rows with a blank value pass through, so this stays
   backward compatible with cycle 1 CSVs. Highest-value safety net here.
3. Loud multi-cluster summary block listing per-cluster VM counts.
4. `--split_by_cluster` writes one CSV per Rubrik cluster alongside the
   combined file, making the safe path the easy path.

`--cluster_filter` resolves names to UUIDs from the cluster query, then pushes
`CLUSTER_ID` into the server-side filter. `--nutanix_cluster_filter` filters
CLIENT-side in v1: `NUTANIX_VM_BY_NUTANIX_CLUSTER_CDMID` exists but takes a CDM
id whose exact form is the very thing under verification, and a wrong
server-side filter returns zero rows, which looks like "no VMs" rather than
"wrong filter". Switch to server-side once L2/L3 confirms the format.

---

## 7. Implementation order

1. `rsc_client.py` standalone (testable with a `{ __typename }` query).
2. `ahv_common.py`: `connect_rsc()`, `add_rsc_auth_args()`,
   `add_auth_args(backends=...)`, `_norm_enum()`.
3. `cdm_client.py`: `get_cluster_me()`.
4. `get_ahv_inventory.py`: query constants, id normalizer, `rsc_row()`.
5. `get_ahv_inventory.py`: new CSV schema. **Regression gate -- confirm
   `ahv_mass_recovery.py` still round-trips a CDM-mode CSV before any RSC code
   runs.**
6. CLI: `--source`, new argument groups, `validate_args()`.
7. RSC main path: cluster query, filters, paginated VM query, row build, L1,
   L2, write CSVs.
8. L3 `--verify_cdm`, L4 `--debug`, multi-cluster summary,
   `--split_by_cluster`.
9. `ahv_mass_recovery.py` cluster guard.
10. Docs: promote the `PLANNED` docstring block to shipped behaviour.

Rollback: `--source cdm` reproduces cycle 1 exactly, with the new columns
blank. A field problem is one flag, not a revert.

---

## 8. Needs live verification

| # | Item | Why it matters |
|---|---|---|
| V1 | Does `NutanixVm.cdmId` return the full `NutanixVirtualMachine:::` form? | Decides whether reconstruction ever runs. Wrong means every recovery fails. Settled automatically by L2. |
| V2 | Does `NutanixCluster.cdmId` return `NutanixCluster:::<uuid>`? | Feeds `exportConfig.nutanixClusterId`. |
| V3 | Is `vmUuid` exactly the `-vm-` tail of the CDM id? | The reconstruction fallback depends on it. |
| V4 | Is `NutanixStorageContainer.uuid` equal to CDM `container.naturalId`? | Feeds `exportConfig.containerNaturalId`. |
| V5 | Largest reliable `first`; is there a query-complexity cap? | Sets the `--page_size` default. |
| V6 | Are `storageContainers` / `clusterNetworks` cached or a live Prism passthrough? | Determines behaviour when a Nutanix cluster is disconnected. |
| V7 | Does `physicalPath` always hold exactly one `NutanixCluster` node, including under Prism Central? | The fallback and the cluster name both key on it. |
| V8 | Does `IS_ACTIVE=true` exclude anything an operator would want? | Silent omission from a recovery inventory is the worst failure mode. |
| V9 | Is `readOnlyAdmin` enough for `nutanixVms`, `reportSnappable`, `nutanixMounts`? | Partial permissions return per-field `errors`. |
| V10 | Can `pageInfo.endCursor` be empty on the last page despite being typed `String!`? | An empty cursor can restart pagination. Guard regardless. |
| V11 | Is `osType` well populated versus CDM `operatingSystemType`? | Cosmetic regression risk against the CDM backend. |
| V12 | Wall clock: RSC single query versus CDM `--detail` N+1. | The whole justification for defaulting to GraphQL. Record the numbers. |
