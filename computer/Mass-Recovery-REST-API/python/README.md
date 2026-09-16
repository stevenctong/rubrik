# AHV Mass Recovery -- Python Reference

Python half of the Rubrik AHV mass recovery toolkit. Triggers, monitors, and unwinds
mass AHV recovery against a Rubrik CDM cluster.

- Toolkit overview and design rationale: [`../README.md`](../README.md)
- Ansible trigger path: [`../ansible/README.md`](../ansible/README.md)

Requires **Python 3.6 or later**. No third-party packages -- everything is stdlib
(`urllib.request`, `ssl`, `csv`, `argparse`, `concurrent.futures`, `threading`).

---

## Files

| File | Run directly? | Purpose |
|---|---|---|
| `cdm_client.py` | No | CDM REST client with AHV endpoint methods. |
| `ahv_common.py` | No | Logging, prompting, credential loading, CSV helpers, wave naming, staged-CSV discovery, formatting. |
| `monitor_core.py` | No | Generic CDM event-series engine: resolution, polling, status classification, metrics, summary, plus the wave-state and results schemas and the state write-back. |
| `get_ahv_inventory.py` | Yes | Build the AHV inventory CSV and the storage containers CSV. |
| `ahv_mass_recovery.py` | Yes | Trigger export or live mount, write the wave-state CSV. |
| `ahv_monitor_recovery.py` | Yes | Monitor a wave to completion (resumable), or cancel it. |
| `ahv_cleanup_mounts.py` | Yes | List and tear down AHV live mounts. |

`monitor_core.py` was previously `ahv_monitor.py`, and the rename reflects what it is:
a CDM **event-series** engine, not an AHV-specific one. Everything in it works for any
snappable and any task type -- `discover_from_vm_ids()` even takes an `event_type`
parameter, defaulting to `"Recovery"`. The only AHV-recovery-specific content is the
two column lists, `WAVE_STATE_FIELDS` and `RESULT_FIELDS`, which live there so the
trigger and the monitor share one definition of the wave-state CSV.

---

## Conventions shared by all four runnable scripts

### Authentication

Every script takes the same authentication argument group (defined in
`ahv_common.add_auth_args`; `ahv_mass_recovery.py` titles it
`REQUIRED -- authentication`, the others `authentication`):

| Argument | Meaning |
|---|---|
| `--svc_json FILE` | RSC Service Account JSON containing `client_id` and `client_secret` |
| `--cluster FQDN` | CDM cluster FQDN or IP address |
| `--svc_client_id ID` | Service Account ID, as an alternative to `--svc_json` |
| `--svc_secret SECRET` | Service Account Secret, as an alternative to `--svc_json` |

The token is obtained from `POST /api/v1/service_account/session` on the **CDM
cluster**. The `access_token_uri` field in an RSC Service Account JSON is ignored --
only `client_id` and `client_secret` are read. TLS verification is disabled, because
CDM clusters commonly run self-signed certificates.

HTTP `502`, `503`, and `504` responses, plus socket and URL errors, are normalised to
Python's `TimeoutError` so retry logic can distinguish "the cluster is busy" from "the
request was wrong".

### The recovered VM prefix: CDM adds its own hyphen

Recovered VMs are named `<prefix>-<source VM name>`, and **CDM inserts that hyphen**.
Confirmed live:

| `--recovered_vm_prefix` | Resulting VM |
|---|---|
| `dr-` | `dr--sh2-ntnx-w1` |
| `dr` | `dr-sh2-ntnx-w1` |

Use `dr`. The same value can be set per VM in the `recovered_vm_prefix` column of the
wave CSV. It reaches the API as `vmNamePrefix`.

The prefix names the copies; it does **not** select which VMs are recovered. That is
`--csv` alone. There is no `--prefix` flag -- it was renamed to
`--recovered_vm_prefix` precisely because "prefix" kept reading like a filter.

### Interactive prompts and bare runs

Any argument not supplied on the command line is prompted for. Running a script with
no arguments at all is a supported, fully interactive mode -- not an error. Passing
some arguments and letting the rest be prompted (hybrid mode) works too.

Running a script with **no arguments at all** first prints two complete,
copy-pasteable commands and a one-line note, then drops into the prompts
(`ahv_common.show_examples_if_bare()`), so the non-interactive form is discoverable
without reading `--help`.

`--force` / `-f` skips confirmations and uses defaults throughout. It is not a blanket
"never prompt" switch: in `ahv_mass_recovery.py` it turns a missing `--container` or
`--recovered_vm_prefix` into an error, and defaults `--point_in_time` to `latest`, but
a missing `--csv` or `--method` is still prompted for. In `ahv_cleanup_mounts.py` it
does not skip the scope question (see that script's section).

### Typed-`yes` confirmations

Anything that changes cluster state requires the operator to type the full word
`yes`. `y`, `Y`, and pressing Enter all count as "no". The confirmations are:

| Script | Prompt | Skipped by `--force`? |
|---|---|---|
| `ahv_mass_recovery.py` | `Proceed with <method> for N VM(s)? (yes/no):` | Yes |
| `ahv_monitor_recovery.py --cancel` | `Cancel N in-flight recovery(s)? (yes/no):` | Yes |
| `ahv_cleanup_mounts.py` | `Unmount N live mount(s)? This is not reversible. (yes/no):` | Yes |
| `ahv_cleanup_mounts.py` (no scope given) | `Unmount ALL AHV live mounts on the cluster? (yes/no):` | **No** |

`--list_only` is read-only and asks nothing at all.

### Every artifact is named after the wave

`ahv_common.wave_name_from()` turns whatever file identifies the wave into a name, and
every output of that run carries it:

| Input | Artifacts |
|---|---|
| `--csv wave1.csv` | `wave1_state_<ts>.csv`, `logs/wave1_recovery_log_<ts>.log`, `logs/wave1_excluded_<ts>.csv`, `logs/wave1_results_<ts>.csv` |
| `--state wave1_state_<ts>.csv` | `logs/wave1_results_<ts>.csv`, `logs/wave1_monitor_log_<ts>.log` |
| `--state`/`--csv` on the cleanup script | `logs/<wave>_unmount_results_<ts>.csv`, `logs/<wave>_unmount_log_<ts>.log` |
| nothing (cleanup `--all`) | falls back to the `ahv` prefix |

The rule: basename, extension stripped, any trailing `_state_<ts>`, `_results_<ts>` or
`_excluded_<ts>` removed, and anything outside `A-Za-z0-9._-` replaced with `_`. So
feeding a state file back into the monitor does not stack suffixes.

### Logging and output files

- A `logs/` directory is created next to the scripts, and `get_ahv_inventory.py`
  additionally creates `inventory/`. Both are resolved from the script's own path,
  not from the current working directory.
- One run timestamp (`YYYYMMDD_HHMMSS`) is generated per run and shared by every
  output file that run produces, so the activity log, results CSV, and any excluded
  CSV from a single run always match.
- Each script writes an **activity log** that mirrors console output with a header
  block naming the cluster, the mode, and the tuning values in effect. Every write is
  flushed immediately, and log write failures are swallowed rather than crashing a
  recovery.
- Results CSVs are written **incrementally** (open, append one row, close) as work
  completes, so partial progress survives a crash.
- Summaries use `=` banners with ALL-CAPS titles, two-space indentation, aligned
  label columns, and echo absolute output paths last.

### Ctrl-C behaviour

Ctrl-C never leaves you with nothing:

| Script | On Ctrl-C |
|---|---|
| `get_ahv_inventory.py` | Waits for in-flight detail fetches, prints `Interrupted.`, exits 1. |
| `ahv_mass_recovery.py` | Prints `Interrupted -- partial state saved.`, exits 1. The wave-state CSV already holds every chunk that returned. If interrupted while monitoring, prints the exact `ahv_monitor_recovery.py --state ...` resume command first. |
| `ahv_monitor_recovery.py` | Writes the full results CSV, prints `SUMMARY (PARTIAL - still in progress)`, exits 1. Re-running against the same `--state` file resumes -- and anything that had already finished stays finished. |
| `ahv_cleanup_mounts.py` | Stops launching new unmounts, waits for in-flight ones, prints `SUMMARY (PARTIAL - interrupted)`, exits 1. |

The monitor says so itself: after each poll it prints
`N still running. Next poll in 30s. Ctrl-C is safe -- state is on disk.`

---

## `get_ahv_inventory.py`

Walks every AHV VM known to the cluster and writes the inventory CSV that the rest of
the toolkit consumes, plus a storage-container CSV.

Both files serve two jobs. They tell the operator which VM names and container names
are valid, and they are **staged lookups** that `ahv_mass_recovery.py` reads instead
of making the equivalent API calls -- the inventory CSV replaces the bulk VM listing,
and the containers CSV replaces the per-AHV-cluster container listing. The inventory
CSV also supplies provisioned sizes to the recovery preview and to the monitor's SIZE
column. Ansible consumes the same two files as `ahv_inventory_csv` and
`ahv_containers_csv`.

### Arguments

| Argument | Default | Meaning |
|---|---|---|
| `--detail` | off | Fetch per-VM detail (disks, excluded disks, paused state). Costs one extra GET per VM, run in parallel. |
| `--include_relics` | off | Include relic VMs (deleted, but still holding snapshots). |
| `--output_prefix PREFIX` | `ahv` | Output filename prefix. Report name and timestamp are appended automatically. |
| `--parallel N` | `8` | Max concurrent detail calls. |
| `--timeout SEC` | `150` | HTTP timeout. |
| `--force`, `-f` | off | Skip prompts and use defaults. |

Plus the shared authentication group.

### API calls

1. `GET /api/internal/nutanix/cluster?primary_cluster_id=local&include_prism_clusters=true`
2. `GET /api/internal/nutanix/cluster/{clusterId}/container` once per AHV cluster
3. `GET /api/internal/nutanix/vm?primary_cluster_id=local&limit=1000&offset=N`
   (offset-paginated, `is_relic=false` unless `--include_relics`, with retry on a
   timed-out page: 3 retries, 15s apart)
4. `GET /api/internal/nutanix/vm/{id}` once per VM, only with `--detail`

### Outputs

| File | Location |
|---|---|
| `<prefix>_inventory_<ts>.csv` | `inventory/` |
| `<prefix>_containers_<ts>.csv` | `inventory/` |
| `<prefix>_inventory_latest.csv` | `inventory/` -- stable copy, rewritten every run |
| `<prefix>_containers_latest.csv` | `inventory/` -- stable copy, rewritten every run |
| `<prefix>_inventory_log_<ts>.log` | `logs/` |

The CSVs land in an `inventory/` subfolder rather than `logs/` because they are inputs
to the next step, not run artifacts. The timestamped files are the audit trail; the
`_latest.csv` copies exist for the Ansible role, which deliberately does not
auto-discover and therefore needs a path that does not change every time the inventory
is rebuilt.

#### Inventory CSV columns (`INVENTORY_FIELDS`, 21 columns)

| Column | Source |
|---|---|
| `vm_name` | VM list `name` |
| `vm_id` | VM list `id` (the `NutanixVirtualMachine:::...` managed id) |
| `nutanix_cluster_name` | VM list `nutanixClusterName` |
| `nutanix_cluster_id` | VM list `nutanixClusterId` |
| `operating_system_type` | VM list `operatingSystemType` |
| `agent_connect_status` | VM list `agentConnectStatus`, falling back to `agentStatus.agentStatus` |
| `is_relic` | VM list `isRelic` |
| `effective_sla_domain_name` | VM list |
| `effective_sla_domain_id` | VM list |
| `sla_assignment` | VM list |
| `snapshot_consistency_mandate` | VM list |
| `is_paused` | detail `isPaused` -- **`--detail` only** |
| `is_agent_registered` | detail `isAgentRegistered` -- **`--detail` only** |
| `excluded_disk_ids` | detail `excludedDiskIds`, semicolon-joined -- **`--detail` only** |
| `disk_count` | count of `virtualDisks[]` entries that have a `sizeInBytes` -- **`--detail` only** |
| `total_provisioned_bytes` | sum of `virtualDisks[].sizeInBytes` -- **`--detail` only** |
| `total_provisioned_gib` | the same total in GiB, 2 decimal places -- **`--detail` only** |
| `disk_labels` | `virtualDisks[].label`, semicolon-joined -- **`--detail` only** |
| `disk_uuids` | `virtualDisks[].vmDiskUuid`, semicolon-joined -- **`--detail` only** |
| `target_container_name` | **blank -- operator fills this in** |
| `recovered_vm_prefix` | **blank -- operator fills this in** |

Without `--detail` the eight detail columns are present but empty, and anything that
wants provisioned sizes (the `RECOVERY WAVE` summary, the monitor's SIZE column) has
nothing to work with -- which is why both say so explicitly rather than reporting
zero. CDROM entries in `virtualDisks[]` carry no `sizeInBytes`, so they are excluded
from `disk_count` and the provisioned totals but still contribute to `disk_labels` and
`disk_uuids`.

Rows are sorted by `nutanix_cluster_name`, then by lowercased `vm_name`.

> **Live mounts show up here as ordinary VMs.** After a two-VM live mount, a re-run of
> this script reported 11 VMs where it previously reported 8 -- the two recovered
> copies plus a pre-existing mount created in the UI. Filter recovery prefixes out
> before building the next wave from a post-recovery inventory, or you will recover the
> recovered VMs.

#### Containers CSV columns (`CONTAINER_FIELDS`, 4 columns)

| Column | Source |
|---|---|
| `nutanix_cluster_name` | cluster list `name` |
| `nutanix_cluster_id` | cluster list `id` |
| `container_name` | container list `name` -- this is the value for `--container` |
| `container_natural_id` | container list `naturalId` -- what actually goes into the API body |

Column order matters for the Ansible path: `resolve.yml` parses this file positionally
(index 0 cluster name, 1 cluster id, 2 container name, 3 `naturalId`).

### What it prints at the end

The summary counts AHV clusters, containers, VMs, detail-fetch failures and total
provisioned capacity, echoes every output path -- then prints the **next command**,
built from this run's real values: the cluster it just talked to, the service-account
path it was given, and an actual container name off the cluster. Two variants, one
`--dry_run` and one for real with `--monitor --force`, plus the first six container
names so the right one can be pasted in. Nothing has to be typed at a prompt to get
from inventory to recovery.

The suggested container prefers a name containing `default`, and otherwise the first
name that does not look like an ISO, template, management or self-service share --
none of which are sensible recovery targets.

### Examples

```bash
# Fully interactive
python3 get_ahv_inventory.py

# Basic inventory -- one paginated VM list call, no per-VM detail
python3 get_ahv_inventory.py --svc_json rsc-sa.json --cluster 10.8.48.104

# With per-VM disk detail (needed for provisioned sizes)
python3 get_ahv_inventory.py --svc_json rsc-sa.json --cluster 10.8.48.104 --detail

# Include relics
python3 get_ahv_inventory.py --svc_json rsc-sa.json --cluster 10.8.48.104 --include_relics

# Slow cluster -- longer timeout, fewer parallel detail calls
python3 get_ahv_inventory.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --detail --timeout 300 --parallel 4
```

---

## `ahv_mass_recovery.py`

Triggers export or live mount for a wave of AHV VMs, then writes the durable
wave-state CSV.

### Arguments

`--help` is organised into labelled groups rather than one flat list. The two
**REQUIRED** groups are the ones that decide what happens to the cluster.

**`REQUIRED -- authentication`** -- the shared auth group described above.

**`REQUIRED -- what to recover, and where it lands`**

| Argument | Default | Meaning |
|---|---|---|
| `--csv FILE` | prompted | Recovery wave CSV. This is what selects WHICH VMs are recovered. |
| `--method export\|mount` | prompted | `export` builds new VMs from the snapshot; `mount` live mounts it (non-destructive, easy to unwind). |
| `--container NAME` | prompted | Target storage container name. Per-VM override: the `target_container_name` column. |
| `--recovered_vm_prefix PREFIX` | prompted | Prefix applied to the NAME of each recovered VM. CDM adds its own hyphen, so use `dr`, not `dr-`. Per-VM override: the `recovered_vm_prefix` column. |

**`snapshot selection`**

| Argument | Default | Meaning |
|---|---|---|
| `--point_in_time TIME` | `latest` | Newest snapshot at or before this UTC time. Accepts `latest`, `YYYY-MM-DD HH:MM:SS`, `YYYY-MM-DD HH:MM`, `YYYY-MM-DD`, or full ISO-8601 with a trailing `Z`. |

**`recovery target -- optional`**

| Argument | Default | Meaning |
|---|---|---|
| `--nutanix_cluster NAME` | each VM's own AHV cluster | Target AHV cluster name. An unknown name is a hard error listing the ones that exist. If the Rubrik cluster has exactly one AHV cluster registered, that one is used. |
| `--migrate_immediately` | off | Live mount only: `mountConfig.shouldMigrateImmediately`. |
| `--disable_migration` | off | Live mount only: `mountConfig.shouldDisableMigration`. |

**`staged lookups -- optional`**

| Argument | Default | Meaning |
|---|---|---|
| `--inventory FILE` | newest match in `inventory/` | AHV inventory CSV from `get_ahv_inventory.py`. Avoids the bulk VM listing call, which can time out on large clusters, and supplies provisioned sizes. |
| `--containers FILE` | newest match in `inventory/` | Storage container CSV. Avoids the per-AHV-cluster container listing, measured at 5296ms on a cold cache. Anything it does not cover is looked up live. |
| `--no_auto_csv` | off | Do not auto-discover staged CSVs; only explicit paths are used. |

**`monitoring -- optional`**

| Argument | Default | Meaning |
|---|---|---|
| `--monitor` | off | Poll to terminal state after triggering. For long waves prefer `ahv_monitor_recovery.py`, which is resumable. |
| `--poll_interval SEC` | `30` | Seconds between monitor polls. |

**`behaviour -- optional`**

| Argument | Default | Meaning |
|---|---|---|
| `--dry_run` | off | Resolve everything and print the first chunk's request body without POSTing. |
| `--force`, `-f` | off | Skip the confirmation prompt and use defaults. Also turns a missing container or prefix into an error rather than a prompt. |

**`tuning -- optional`**

| Argument | Default | Meaning |
|---|---|---|
| `--chunk_size N` | `25` | VMs per batch API call. |
| `--timeout SEC` | `300` | HTTP timeout. Higher than the other scripts because batch calls are slow. |

### Staged CSVs and auto-discovery

Generated CSVs are written to an `inventory/` subfolder beside the scripts, so the
working directory stays clean. Auto-discovery looks in `inventory/` first and falls
back to the script directory, so CSVs generated before that layout change still
resolve.

| Staged file | Replaces | Measured cost of the live call |
|---|---|---|
| `--inventory` | `GET /api/internal/nutanix/vm` (paginated bulk listing) | can time out on large clusters |
| `--containers` | `GET /api/internal/nutanix/cluster/{id}/container`, once per AHV cluster | **5296ms cold**, then 210ms and 133ms warm |

Because `get_ahv_inventory.py` writes timestamped filenames, both are
**auto-discovered**: the newest `*_inventory_*.csv` and `*_containers_*.csv` are used
automatically (`ahv_common.find_latest_csv`). The rules:

- An explicit `--inventory` / `--containers` always wins over discovery.
- An explicit path that does not exist is a **hard error**, never a silent fall back.
- The file chosen and its age are **always** printed, fresh or not, as
  `Using inventory CSV: <name> (<age>)`.
- A file `stale_days` (default `7`) or older additionally prints a WARNING.
- Age is derived from the `YYYYMMDD_HHMMSS` stamp in the filename, **not** from
  mtime. Copying an old inventory between machines resets mtime, which would
  otherwise make a stale file look freshly generated.
- `--no_auto_csv` disables discovery entirely; only explicit paths are then used.

One thing to watch: a filtered wave file is usually a copy of the inventory CSV, so if
it is saved under a name still containing `_inventory_` it becomes a candidate for
discovery. Name wave files something else (`wave1.csv`), or pass `--inventory`
explicitly.

Staging is best effort. The containers CSV is used only when it covers every
container the wave targets; if anything is missing, the script logs `Staged CSV does
not cover every target -- querying the cluster`, does the live lookup, and merges the
two with **live values winning**. When the staged file does cover the wave it logs
`Resolved entirely from the staged CSV -- no container API calls` -- which is what a
live run against a single-AHV-cluster environment produced, with zero lookup calls.

The AHV cluster list (`GET /api/internal/nutanix/cluster`, measured at 120-403ms) has
no separate staging flag on purpose -- it is cheap, and cluster-name-to-id mapping
comes out of the containers CSV anyway. `POST /api/v1/snapshot/closest_to_point_in_time`
(67-138ms) is already batched and is inherently runtime-only, since the point in time
varies per run.

### Input: the wave CSV

Read tolerantly and case-insensitively. Only a VM name is required per row; the other
three columns are optional.

| Column (accepted aliases) | Required | Meaning |
|---|---|---|
| `vm_name` (`name`, `vmname`, `hostname`) | Yes | AHV VM name as Rubrik knows it. |
| `vm_id` (`id`) | No | Skips name resolution for that row. |
| `target_container_name` (`container`) | No | Overrides `--container` for that row. |
| `recovered_vm_prefix` (`prefix`) | No | Overrides `--recovered_vm_prefix` for that row. |

An inventory CSV from `get_ahv_inventory.py` already has all four columns, which is
the point -- filter its rows, optionally fill in the last two, save, use.

Note the alias list for the prefix column: this script accepts `recovered_vm_prefix`
or `prefix`, but **not** the older `vm_name_prefix`. A wave file left over from an
earlier inventory will have its prefix column ignored, and the run then falls back to
`--recovered_vm_prefix` (or fails the up-front check if that is missing too).
`ahv_cleanup_mounts.py` is the more forgiving reader and accepts all three spellings.

Rows with no recognisable VM name are skipped silently. Every other extra column in
the file is ignored, so you can leave the full inventory columns in place.

### Flow

1. Read and validate the wave CSV.
2. **Validate the target before connecting.** A missing storage container or
   recovered-VM prefix is caught here, immediately after the CSV is read and before
   any API call. Under `--force` it is a hard error naming both the flag and the CSV
   column; otherwise the operator is prompted. This used to surface as a per-VM
   exclusion only after the VM lookup, the snapshot call and the container listing had
   already run.
3. Authenticate, then resolve the staged CSVs (explicit paths, or auto-discovery
   unless `--no_auto_csv`), printing each chosen file and its age.
4. Resolve VM names to ids -- from the inventory CSV if there is one, otherwise by
   listing VMs on the cluster. Names are matched case-insensitively.
5. Print the `RECOVERY WAVE` block (below) before any of the heavy lifting.
6. `POST /api/v1/snapshot/closest_to_point_in_time`, chunked by `--chunk_size`, with a
   `[chunk N/M]` line per request and a `[i/total] <vm>  snapshot <date>` line per VM.
7. Resolve `(cluster id, container name)` to a `containerNaturalId`: from the
   containers CSV when it covers every target, otherwise by listing AHV clusters and
   their containers live and merging the two, live values winning. An unknown
   container name is a hard error that lists the valid ones.
8. Print the `RECOVERY PREVIEW`: method, point in time, VMs ready, VMs excluded (with
   reasons, first five listed), and the first five recovery targets rendered as
   `source -> prefix-source (snapshot <date>)`.
9. Write the excluded CSV if anything was excluded.
10. On `--dry_run`, print the first chunk's full JSON request body and stop.
11. Otherwise confirm (typed `yes`, unless `--force`), then POST `batch_export` or
    `batch_mount` chunk by chunk, appending each chunk to the wave-state CSV as it
    returns.
12. Optionally monitor (`--monitor`); otherwise print the resume command.

### The `RECOVERY WAVE` block

Printed before any work, so scope and target can be sanity-checked before a single VM
is touched:

```
============================================================
RECOVERY WAVE
============================================================
  Wave CSV:                  wave1.csv
  VMs in wave:               2
  Total provisioned:         120.0 GiB
  Method:                    mount
  Point in time (UTC):       2026-09-16T06:40:43.757Z
  Target container:          default-container-96009868769486
  Recovered VM prefix:       dr
  Cluster:                   10.8.48.104
```

`Not found on cluster: N` appears only when some names did not resolve. The total
provisioned line comes from `total_provisioned_bytes` in the inventory CSV, and it is
honest about why it is missing: `not in the inventory CSV -- rebuild it with
get_ahv_inventory.py --detail for disk sizes` when an inventory CSV is loaded but has
no disk data, versus `unknown (no inventory CSV in play)` when there is no CSV at all.
When only some VMs are sized it says so: `(3 of 8 VMs sized)`.

### Exclusion reasons

A VM is excluded, never silently dropped, for any of:

- `VM not found on cluster`
- `No snapshot at or before <before_date>`
- `Could not determine target AHV cluster`
- `No target container (use --container or the target_container_name column)`
- `Container '<name>' not found on the target AHV cluster`
- `No VM name prefix (use --prefix or the recovered_vm_prefix column)`

If nothing survives, the script writes the excluded CSV, says `Nothing to recover.`,
and exits 1.

That last message still names `--prefix`, which no longer exists; the flag is
`--recovered_vm_prefix`. In practice the path is nearly unreachable now, because a
wave with no prefix at all is rejected up front, before connecting.

### Outputs

| File | Location |
|---|---|
| `<wave>_state_<ts>.csv` | script directory |
| `<wave>_excluded_<ts>.csv` | `logs/` (only written if something was excluded) |
| `<wave>_results_<ts>.csv` | `logs/` (only with `--monitor`) |
| `<wave>_recovery_log_<ts>.log` | `logs/` |

#### Wave-state CSV columns (`WAVE_STATE_FIELDS`, 17 columns)

```
triggered_at, status, status_updated, vm_name, method, snapshot_date,
recovered_vm_prefix, duration_seconds, data_transferred_bytes, end_time,
message, vm_id, snapshot_id, nutanix_cluster_id, container_natural_id,
job_instance_id, event_series_id
```

Human-readable columns first, opaque identifiers last, so the file is scannable in a
terminal or a spreadsheet. The list is defined in `monitor_core.py` and re-exported
here as `WAVE_STATE_FIELDS = monitor_core.WAVE_STATE_FIELDS`, so the monitor can patch
the file without importing this script.

There is no `trigger_status` column any more. The trigger writes `status` directly and
the monitor updates the same column in place:

| `status` at trigger time | Meaning |
|---|---|
| whatever `asyncRequestStatus.status` classifies to (typically `queued`) | The VM appeared in `successfulRequests[]`. `job_instance_id` comes from `asyncRequestStatus.id`, `triggered_at` from `asyncRequestStatus.startTime`. |
| `failed`, `raw_status` `TriggerFailed` | The VM appeared in `failedRequests[]` (message is the failed request JSON, truncated to 500 characters), or the whole chunk POST raised (message is the error). |
| `failed`, `raw_status` `NotInResponse` | The VM was in the chunk but absent from both arrays. `message` reads `VM was not present in the batch response`. |

`event_series_id`, `status_updated`, `duration_seconds`, `data_transferred_bytes` and
`end_time` are empty at trigger time and are filled in by the monitor.

#### Excluded CSV columns (`EXCLUDED_FIELDS`, 3 columns)

```
vm_name, vm_id, reason
```

#### Results CSV columns

Written only with `--monitor`. Same 17 columns as `ahv_monitor_recovery.py` -- see
below.

### Examples

```bash
# Dry run first -- resolves everything, prints the request body, POSTs nothing
python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --csv wave1.csv --method mount --container default-container \
    --recovered_vm_prefix dr --dry_run

# Live mount a wave from the newest snapshot, then watch it to completion
python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --csv wave1.csv --method mount --container default-container \
    --recovered_vm_prefix dr --monitor

# Export to a point in time (UTC), trigger only, monitor separately
python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --csv wave1.csv --method export --point_in_time "2026-09-08 23:00:00" \
    --container default-container --recovered_vm_prefix dr --force

# Large cluster -- resolve VM ids and containers from named staged CSVs
python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --csv wave1.csv --inventory inventory/ahv_inventory_20260916_120000.csv \
    --containers inventory/ahv_containers_20260916_120000.csv \
    --method mount --container default-container --recovered_vm_prefix dr --force

# Same thing, letting auto-discovery pick the newest staged CSVs. The files
# chosen and their ages are printed before anything is resolved.
python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --csv wave1.csv --method mount --container default-container \
    --recovered_vm_prefix dr

# Ignore any staged CSVs lying around and resolve everything from the cluster
python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --csv wave1.csv --method mount --container default-container \
    --recovered_vm_prefix dr --no_auto_csv

# Smaller chunks on a slow cluster
python3 ahv_mass_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --csv wave1.csv --method mount --container default-container \
    --recovered_vm_prefix dr --chunk_size 10 --timeout 600

# Fully interactive (prints two example commands first)
python3 ahv_mass_recovery.py
```

---

## `ahv_monitor_recovery.py`

Monitors AHV recovery jobs to a terminal state and reports per-VM metrics. Runs
independently of whatever triggered the recovery, so it can be started, stopped, and
restarted at will -- after a crash, after closing the terminal, or from a different
machine.

### Arguments

| Argument | Default | Meaning |
|---|---|---|
| `--state FILE` | prompted | Wave-state CSV from `ahv_mass_recovery.py` or from the Ansible playbook. The normal path. |
| `--csv FILE` | prompted | Wave list CSV. Discovery mode, for when no state file exists. |
| `--inventory FILE` | newest match in `inventory/` | AHV inventory CSV. Two jobs: it resolves VM names to ids in discovery mode, and it supplies each VM's provisioned size for the SIZE column. |
| `--poll_interval SEC` | `30` | Seconds between polls. |
| `--once` | off | Print one status snapshot and exit instead of polling. |
| `--max_polls N` | unlimited | Give up after N polls. |
| `--cancel` | off | Cancel every in-flight recovery in the wave, then exit. |
| `--timeout SEC` | `150` | HTTP timeout. |
| `--force`, `-f` | off | Skip confirmation prompts. |

Plus the shared authentication group. Exactly one of `--state` or `--csv` is needed;
if neither is given, the script prompts for a state CSV first and falls back to
prompting for a wave CSV if that is left blank.

One wrinkle in `--inventory`: auto-discovery applies to the **sizing** pass, which
runs after records are loaded and after discovery mode has already resolved names. For
name-to-id resolution in `--csv` mode, only an explicitly passed `--inventory` is
consulted; anything it misses falls back to the bulk VM listing.

### Two input modes

**`--state` (preferred).** Reads the wave-state CSV, which already carries every
`jobInstanceId`. Fully resumable and precise. Any row without a `vm_id` is skipped. A
row whose `status` is already `failed` with no `end_time` is loaded as a trigger
failure and never polled. Rows that are already terminal from an earlier monitor run
keep their status, end time, duration and transferred bytes, are not re-polled, and
still appear in the final summary. This is also the only mode that writes resolved
values back into the state file.

**`--csv` (discovery).** For when the trigger ran somewhere that did not leave a state
file. Resolves each VM name to an id (from `--inventory`, or by listing VMs on the
cluster), then finds that VM's most recent event series with
`eventType == "Recovery"` and adopts it, filling in `job_instance_id`,
`event_series_id`, and `start_time`, with `message` set to
`discovered from event history`. Less precise -- it will happily pick up a recovery
someone else started. If nothing is found for any VM, the script exits 1.
(`monitor_core.discover_from_vm_ids()` takes the event type as a parameter; the
recovery monitor uses the default.)

### Poll loop

Each pass:

1. Resolve any missing `event_series_id` via `/api/v1/event/latest`. The batched
   comma-joined `object_ids` form is attempted once; on failure or a short response
   it falls back to parallel per-VM calls (8 workers, `limit=50`).
2. `POST /api/internal/event_series/status` with up to 100 `{id, jobInstanceId}`
   pairs per call. This is the primary poll and the metrics source.
3. For each VM that just went terminal, `GET /api/v1/event_series/{id}` (8 workers)
   for `startTime`, the latest `eventDetailList[].time` as the end time, the computed
   duration, and a human-readable message. Failure messages are preferred when the
   status is `failed`; the message is pulled from `eventInfo` JSON if present,
   otherwise from `eventName`.
4. Refresh the wave-state CSV (see below) -- **every poll**, not just at the end.
5. Append each newly terminal VM to the results CSV.
6. Redraw the per-VM table and the counts line
   `queued N | running N | succeeded N | failed N | cancelled N`.
7. Print `N still running. Next poll in <interval>s. Ctrl-C is safe -- state is on
   disk.`, then sleep and repeat until everything is terminal.

A VM with no `terminatedEventSeriesStatus` is classified `running` if its progress is
above zero and `queued` otherwise.

### The per-VM table

```
  VM                         STATUS        PROGR   STARTED    ELAPSED       SIZE   TRANSFERRED
  --------------------------------------------------------------------------------------------
  sh2-ntnx-w1                cancelled            06:53:34    10m 40s   60.0 GiB      40.0 GiB
  sh2-ntnx-w2                cancelled            06:53:34    10m 43s   60.0 GiB            --
```

- **STARTED** is the job start time as `HH:MM:SS`.
- **ELAPSED** is live for in-flight VMs -- now minus `start_time`, which costs no extra
  API call because the start time already came back with the trigger -- and switches
  to the real computed duration once the VM is terminal.
- **SIZE** is the VM's **provisioned** size, read from the inventory CSV. It is not
  bytes moved, and the column is named SIZE rather than TRANSFERRED for exactly that
  reason. It exists because the cluster reports no transferred bytes at all for live
  mount jobs, and without it a 40 GiB VM and a 600 GiB VM look identical while they
  run. The column only appears when at least one record has a size, so it needs an
  inventory CSV built with `--detail`.
- **TRANSFERRED** only appears when at least one record actually has a value.

The table is truncated to the first 40 rows so a 500-VM wave stays readable.

### Write-back into the wave-state CSV

`monitor_core.persist_state(state_path, records)` patches the wave-state CSV after
every poll. It persists `event_series_id`, `status`, `status_updated`, `end_time`,
`duration_seconds`, `data_transferred_bytes` and `message`. Three things depend on it:

- **Event-series resolution is paid once.** Resolving `event_series_id` costs one
  `/api/v1/event/latest` lookup per VM; without persistence that cost is paid again in
  full on every restart.
- **The file is a live progress view.** It is refreshed each poll, so it reflects
  current state even while the monitor is running, and it outlives the process.
- **A restarted monitor keeps finished results.** VMs that completed before the
  restart are not re-polled and still count in the summary.

Properties worth knowing:

- It patches the file **cell by cell** rather than rewriting it from the in-memory
  records, so `container_natural_id`, `recovered_vm_prefix`, `snapshot_id` and any
  other column the monitor does not track are preserved untouched.
- Rows are matched on `job_instance_id` first, falling back to `vm_id`.
- Only non-empty values are written, and rows that would not change are skipped, so
  re-running the monitor rewrites nothing.
- A state file written before these columns existed is **upgraded in place** -- any
  missing column from `WAVE_STATE_FIELDS` is appended to the header, so the older
  13-column files still work.
- It never raises. A read failure, a write failure, a missing file, or a CSV with no
  matching rows all return `0` and let monitoring continue.

`monitor()` takes the `state_path` parameter that drives it, and both entry points
pass it -- `ahv_monitor_recovery.py --state` and `ahv_mass_recovery.py --monitor`.
Discovery mode (`--csv`) has no state file and passes `None`, which disables the
write-back.

### Metrics: what the cluster does and does not report

Transfer metrics come straight from `POST /api/internal/event_series/status` and are
**job-type dependent**. Observed on a live cluster:

| Job type | `dataTransferred` | Notes |
|---|---|---|
| `MOUNT_NUTANIX_SNAPSHOT` (live mount) | Not reported | Neither is `logicalSize` or `throughput`. Confirmed across a completed two-VM mount wave. |
| `MULTI_NODE_EXPORT_NUTANIX_SNAPSHOT` (export) | Reported | Observed `42949672960` (40.0 GiB) on one VM of a two-VM export wave. It was absent on the first polls and appeared partway through the run; the second VM of the same wave never reported one at all. |

So: best effort, never assumed. When no record in the wave reports a transferred byte
count, the summary prints `Transfer metrics: not reported by the cluster for this job
type` rather than a misleading zero, the TRANSFERRED column is dropped from the table,
and the longest/shortest lines read `n/a transferred`.

Two related details:

- **Negative values are discarded.** A cancelled export reported a throughput of
  `-162142765`, which is meaningless. Any negative `logicalSize`, `dataTransferred` or
  `throughput` is dropped rather than recorded or displayed.
- **Durations never depend on any of this.** They are computed from event-series
  timestamps and are always available, for every job type.

### `--cancel`

Resolves event series, polls once to establish current state, lists every non-terminal
recovery, requires a typed `yes` (unless `--force`), then issues
`POST /api/internal/event_series/{id}/cancel` for each. Cancel failures are logged and
counted, not swallowed.

A cancelled export has been observed end to end from the monitoring side: the cluster
returned the terminal status string `Canceled` (one `l`), which the prefix-based
classifier mapped to `cancelled` -- a case a hardcoded enum spelled `Cancelled` would
have got wrong. What is not yet on record is this script being the thing that issued
the cancel.

### Outputs

| File | Location |
|---|---|
| `<wave>_results_<ts>.csv` | `logs/` |
| `<wave>_monitor_log_<ts>.log` | `logs/` |

#### Results CSV columns (`RESULT_FIELDS`, 17 columns)

| Column | Notes |
|---|---|
| `vm_name` | |
| `vm_id` | |
| `method` | `export` or `mount`, carried over from the state CSV |
| `snapshot_id` | |
| `snapshot_date` | |
| `job_instance_id` | `asyncRequestStatus.id` |
| `event_series_id` | resolved from `/api/v1/event/latest` |
| `status` | classified: `queued`, `running`, `succeeded`, `failed`, `cancelled` |
| `raw_status` | the cluster's verbatim status string, e.g. `Success`, `Canceled` |
| `progress_pct` | 2 decimal places |
| `start_time` | |
| `end_time` | latest `eventDetailList[].time` |
| `duration_seconds` | computed from start and end; always available |
| `logical_size_bytes` | best effort -- may be blank |
| `data_transferred_bytes` | best effort -- may be blank |
| `throughput_bytes_per_sec` | best effort -- may be blank; negatives discarded |
| `message` | failure text, or the last event name |

Provisioned size is deliberately not a results column -- it describes the source VM,
not the job.

The CSV is appended to incrementally as VMs finalize, then rewritten in full at exit
so it always reflects final state including non-terminal rows.

### Summary block

Printed at exit, titled `SUMMARY` or `SUMMARY (PARTIAL - still in progress)`:

- Total VMs, succeeded, failed, cancelled, still in progress
- Success rate as a percentage of completed jobs
- Longest and shortest VM by duration, with transferred bytes (`n/a` when unreported)
- Average duration, over the VMs that reported one
- Largest and smallest transfer, average transferred, total transferred -- or the
  single `Transfer metrics: not reported...` line when nothing reported any
- `Wave started` -- earliest start time across the wave
- `Wave finished` -- latest end time, shown only once every VM is terminal
- `Wave elapsed` -- first trigger to last finish, or to now while work is outstanding
- `Monitor ran for` -- how long this monitor process was up, which is a different
  question from how long the wave took

Duration and transfer statistics are computed only over records that actually
reported those values, so a missing metric never skews a statistic.

### Examples

```bash
# Monitor a wave to completion (the normal path)
python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state wave1_state_20260916_120000.csv

# Resume after a Ctrl-C, a crash, or from a different machine -- same command.
# Anything that already finished stays finished.
python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state wave1_state_20260916_120000.csv

# Monitor a wave the Ansible playbook triggered
python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state ../ansible/state/wave1_state_20260916_120000.csv

# One status snapshot, no polling -- good for a cron or a quick check
python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state wave1_state_20260916_120000.csv --once

# Poll faster
python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state wave1_state_20260916_120000.csv --poll_interval 15

# No state file -- discover recent recoveries for a list of VMs
python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --csv wave1.csv --inventory inventory/ahv_inventory_latest.csv

# Abort every in-flight recovery in the wave
python3 ahv_monitor_recovery.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state wave1_state_20260916_120000.csv --cancel
```

---

## `ahv_cleanup_mounts.py`

Lists AHV live mounts and tears them down. A mass live mount is usually a DR test, so
this is the unwind step.

> **The unmount DELETE path is unverified.** Mount *listing* has been confirmed against
> a live cluster, but the reference API capture contains no unmount and none has been
> executed, so `DELETE /api/v1/nutanix/vm/snapshot/mount/{mountId}` is inferred from
> the Rubrik CDM mount API convention. **Run `--list_only` first.** If listing works
> but deletes return 404 or 405, correct the path in `cdm_client.delete_vm_mount()`.
> The script reports unmount failures verbatim and never treats one as "already gone";
> if every unmount fails it prints a note pointing at exactly this.

### Scope, and why it is by source VM

Scope (pick one):

| Argument | Meaning |
|---|---|
| `--state FILE` | Wave-state CSV -- every mount whose source VM is named in it. |
| `--csv FILE` | Wave list CSV -- same, resolved by `vm_id`, or by name via `--inventory`. |
| `--all` | Every AHV live mount on the cluster. |

If none is given, the script asks `Unmount ALL AHV live mounts on the cluster?` and
aborts unless the answer is `yes`. That question is **not** skipped by `--force`. It is
skipped by `--list_only`, which is read-only and simply lists everything.

`--state` and `--csv` match **every** mount of the VMs they name. They do **not**
filter by prefix, and that is deliberate: one source VM can carry mounts from several
recovery runs plus mounts somebody made by hand in the UI, all sharing the same source
VM id. Hiding the ones this wave did not create would leave stale mounts of the same
VMs quietly alive after a DR test was supposedly torn down.

Instead the preview labels them. The `ORIGIN` column reads `this wave` when the mounted
VM name starts with a `recovered_vm_prefix` recorded in the wave file, and `other`
otherwise, and a warning line names the count and the prefix when any are `other`:

```
  Found 3 live mount(s) in scope (cluster reported 3 total)
  1 of them do NOT match this wave's prefix (dr-) -- check the ORIGIN
  column below before confirming.

  MOUNTED VM                         SOURCE VM                    ORIGIN
  ------------------------------------------------------------------------------
  dr--sh2-ntnx-w1                    sh2-ntnx-w1                  this wave
  sh2-ntnx-w1 09-15 21:16 0          sh2-ntnx-w1                  other
  dr--sh2-ntnx-w2                    sh2-ntnx-w2                  this wave
```

That is real output from a live cluster: two mounts from the wave and one pre-existing
UI mount on the same source VM. The operator decides. There is no `--any_mount_name`
flag, because matching every mount of the named VMs is already the default;
`--mounted_name_prefix` exists for the opposite job, narrowing the set explicitly.

The prefix used for labelling is read tolerantly -- `recovered_vm_prefix`,
`vm_name_prefix` or `prefix` -- so state files from older runs still label correctly.

### Other arguments

| Argument | Default | Meaning |
|---|---|---|
| `--inventory FILE` | none | AHV inventory CSV, to resolve VM names to ids with `--csv`. Not auto-discovered here. |
| `--mounted_name_prefix PREFIX` | none | Narrow to mounts whose MOUNTED VM name starts with this. Comma-separated for several. Logs how many mounts it dropped. |
| `--list_only` | off | List mounts and exit without deleting anything. |
| `--force_unmount` | off | Pass `force=true` on the unmount call. |
| `--parallel N` | `4` | Max concurrent unmount calls. |
| `--stagger SEC` | `5` | Delay between launching each worker. |
| `--retries N` | `2` | Max retries per unmount on timeout. |
| `--retry_delay SEC` | `20` | Wait between unmount retries. |
| `--timeout SEC` | `150` | HTTP timeout. |
| `--force`, `-f` | off | Skip the unmount confirmation and use default timings. |

Plus the shared authentication group.

Note that `--force_unmount` and `--force` are different things: the first is an API
parameter, the second skips the confirmation prompt.

### Flow

1. Resolve the scope to a set of source VM ids, plus the wave's recorded prefixes for
   labelling. With `--csv` and no `vm_id` column, names are resolved through
   `--inventory`; any name that cannot be resolved is warned about and left out of
   scope.
2. `GET /api/v1/nutanix/vm/snapshot/mount` and filter to the scope (unless `--all`),
   then apply `--mounted_name_prefix` if given.
3. Label each mount `this wave` or `other` and warn if any are `other`.
4. Print a table of MOUNTED VM, SOURCE VM and ORIGIN, first 20 rows.
5. Stop here with `--list_only`.
6. Otherwise confirm (typed `yes`, unless `--force`), then unmount in parallel:
   `--parallel` workers launched `--stagger` seconds apart, retrying on timeout only.
   A non-timeout error fails that mount immediately rather than retrying.
7. Append each result to the results CSV as it completes.

Timeouts retry; anything else does not. Retry exhaustion is recorded as
`Timed out after N attempts: <last error>`.

### Outputs

| File | Location |
|---|---|
| `<wave>_unmount_results_<ts>.csv` | `logs/` |
| `<wave>_unmount_log_<ts>.log` | `logs/` |

With `--all` and no scope file there is no wave to name the files after, so they fall
back to the `ahv` prefix.

#### Unmount results CSV columns (`RESULT_FIELDS`, 7 columns)

```
mount_id, mounted_vm_name, source_vm_name, source_vm_id, origin, status, message
```

`status` is `Unmounted` or `Failed`. `origin` carries the same `this wave` / `other`
label shown in the preview. The mount object's field names vary by CDM version, so
`source_vm_id` is read from the first of `nutanixVmId`, `vmId`, `sourceVmId`;
`mounted_vm_name` from the first of `mountedVmName`, `newVmName`, `name`; and
`source_vm_name` from the first of `sourceVmName`, `vmName`.

### Examples

```bash
# Show every AHV live mount on the cluster and exit -- always do this first.
# No scope and no confirmation needed: listing is read-only.
python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 --list_only

# Show every mount belonging to the VMs in a wave, labelled by origin
python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state wave1_state_20260916_120000.csv --list_only

# Show only mounts whose source VMs are in a wave list
python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --csv wave1.csv --inventory inventory/ahv_inventory_latest.csv --list_only

# Tear down every mount of the VMs in a recovery wave
python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state wave1_state_20260916_120000.csv

# ...or only the ones this wave created
python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state wave1_state_20260916_120000.csv --mounted_name_prefix dr-

# Tear down every AHV live mount on the cluster (careful)
python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 --all

# Gentler on a busy cluster
python3 ahv_cleanup_mounts.py --svc_json rsc-sa.json --cluster 10.8.48.104 \
    --state wave1_state_20260916_120000.csv \
    --parallel 2 --stagger 15 --retries 3 --retry_delay 60

# Fully interactive
python3 ahv_cleanup_mounts.py
```

---

## Module reference (not run directly)

### `cdm_client.py`

`CDMClient(fqdn, service_account_id, secret, timeout=150)` authenticates on
construction and exposes generic `get()`, `post()`, `delete()` plus these AHV
methods:

| Method | Endpoint |
|---|---|
| `list_nutanix_vms(include_relics=False, page_size=1000, retries=3, retry_delay=15)` | `GET /api/internal/nutanix/vm` (offset-paginated) |
| `get_nutanix_vm(vm_id)` | `GET /api/internal/nutanix/vm/{id}` |
| `list_nutanix_clusters()` | `GET /api/internal/nutanix/cluster` |
| `list_containers(nutanix_cluster_id)` | `GET /api/internal/nutanix/cluster/{id}/container` |
| `closest_to_point_in_time(snappable_ids, before_date)` | `POST /api/v1/snapshot/closest_to_point_in_time` |
| `batch_export(snapshots)` | `POST /api/v1/nutanix/vm/batch_export` |
| `batch_mount(snapshots)` | `POST /api/v1/nutanix/vm/batch_mount` |
| `event_latest(object_ids, limit=50, event_type, before_date)` | `GET /api/v1/event/latest` |
| `get_event_series(event_series_id)` | `GET /api/v1/event_series/{id}` |
| `event_series_status(pairs)` | `POST /api/internal/event_series/status` |
| `cancel_event_series(event_series_id)` | `POST /api/internal/event_series/{id}/cancel` |
| `list_vm_mounts(vm_id=None, page_size=1000)` | `GET /api/v1/nutanix/vm/snapshot/mount` |
| `delete_vm_mount(mount_id, force=False)` | `DELETE /api/v1/nutanix/vm/snapshot/mount/{id}` -- **unverified** |

Rubrik managed ids contain `:::`, so every id used in a path is URL-encoded with
`safe=""`.

### `ahv_common.py`

Logging (`open_log`, `log`, `close_log`, `now_hm`, `run_timestamp`, `log_dir_for`,
`inventory_dir_for`, `print_lock`), prompting (`show_examples_if_bare`,
`prompt_if_missing`, `prompt_int_if_missing`, `confirm`), credentials
(`load_json_credentials`, `connect_cdm`, `add_auth_args`), CSV helpers
(`first_field`, `read_csv_rows`, `write_csv`, `init_incremental_csv`,
`append_csv_row`, `find_latest_csv`, `wave_name_from`), and formatting
(`format_bytes`, `format_duration`, `parse_iso8601`, `to_iso8601_z`, `banner`,
`truncate_list`).

`first_field(row, *names)` is the tolerant CSV read: it tries each name in its given,
lower, upper, and capitalized forms and returns the first non-empty match. It does not
do fuzzy matching, which is why `vm_name_prefix` and `recovered_vm_prefix` are
different columns and each reader lists the aliases it accepts.

`find_latest_csv(script_file, pattern, label, explicit=None, stale_days=7)` resolves a
staged CSV. An explicit path wins and must exist (otherwise it exits 1); otherwise it
globs `pattern` in `inventory/` and then next to `script_file`, and picks the newest,
returning `None` when nothing matches. It always prints the chosen file and its age,
and warns at `stale_days` or older. Age comes from `_csv_stamp()`, which reads the
`YYYYMMDD_HHMMSS` stamp out of the filename and only falls back to mtime when the
name has no stamp.

`wave_name_from(path, default="wave")` derives the wave name that every artifact of a
run is named after.

`show_examples_if_bare(script_name, examples, note=None)` prints the example commands
when `sys.argv` has no arguments, then returns so the run continues interactively.

### `monitor_core.py`

`classify_status`, `is_terminal`, `resolve_event_series`, `persist_state`,
`discover_from_vm_ids`, `poll_once`, `finalize_records`, `monitor`, `count_by_status`,
`elapsed_seconds`, `render_table`, `build_summary`, and the `RESULT_FIELDS` and
`WAVE_STATE_FIELDS` column lists. Shared by `ahv_mass_recovery.py --monitor` and
`ahv_monitor_recovery.py` so there is exactly one implementation of the monitoring
logic.

Renamed from `ahv_monitor.py`, and generic by design: everything here works for any
CDM event series. `persist_state()` was `persist_event_series()` and now persists the
whole live outcome, not just the id.

`WAVE_STATE_FIELDS` lives here rather than in `ahv_mass_recovery.py` so that
`persist_state()` can patch the wave-state CSV without the monitor importing the
trigger script. `ahv_mass_recovery.py` re-exports it under the same name.

`monitor(client, records, poll_interval=30, once=False, results_path=None,
max_polls=None, state_path=None)` -- passing `state_path` enables the state
write-back; leaving it `None` disables it.
