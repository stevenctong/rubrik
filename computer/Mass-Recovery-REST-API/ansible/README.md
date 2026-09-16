# AHV Mass Recovery -- Ansible Reference

Ansible half of the Rubrik AHV mass recovery toolkit. **Triggers only.** It resolves
a wave, submits the batched recovery calls, writes a durable wave-state CSV, and
exits. Monitoring is the Python script's job.

- Toolkit overview and design rationale: [`../README.md`](../README.md)
- Python reference (inventory, trigger, monitor, cleanup): [`../python/README.md`](../python/README.md)

Requires **Ansible core only** -- everything here is `ansible.builtin`.

This path has been run against a live cluster: a two-VM live mount triggered here
(2 of 2 accepted, 0 failed) was monitored to completion by
`ahv_monitor_recovery.py --state`, and a later export wave was triggered the same way.

---

## Layout

```
ansible/
  README.md
  ansible.cfg
  requirements.yml                       Empty -- no external collections needed.
  ahv_mass_recovery.yml                  The play. hosts: localhost, connection: local.
  inventory/
    ahv_wave1_example.yml                Example wave inventory.
  vars/
    example-recovery-vars.yml            Committed template for an extra-vars file.
                                         Everything else in vars/ is gitignored.
  roles/
    rubrik_cdm_auth/                     Reusable. Any Rubrik playbook can include it.
      defaults/main.yml
      tasks/main.yml
    rubrik_ahv_recovery/
      defaults/main.yml
      tasks/main.yml                     Validate -> resolve -> trigger -> state -> optional wait.
      tasks/resolve.yml
      tasks/trigger.yml
      tasks/state.yml
      tasks/monitor.yml                  Optional bounded wait. Off by default.
      templates/wave_state.csv.j2
  state/                                 Created on first run. Holds wave-state CSVs.
```

### `ansible.cfg`

| Setting | Value | Why |
|---|---|---|
| `inventory` | **not set, deliberately** | See below. |
| `roles_path` | `roles` | |
| `host_key_checking` | `False` | No SSH happens at all; this just avoids noise. |
| `result_format` | `yaml` | `community.general.yaml` was removed in that collection's v12; the built-in default callback with `result_format=yaml` supersedes it, with no collection dependency. |
| `forks` | `5` | Irrelevant here. Batching happens inside the API, not across Ansible forks. |

**There is no default inventory, and that is the point.** Ansible merges *every* file
in an inventory directory into one inventory, so defaulting `inventory = inventory/`
meant a bare run silently combined `wave1`, `wave2` and `tier0` into a single
`ahv_recovery_wave` group and recovered all of them. Always name the wave:

```bash
ansible-playbook -i inventory/<wave>.yml ahv_mass_recovery.yml ...
```

That file name is also what the run is named after -- see
[Wave naming](#wave-naming).

### `requirements.yml` -- empty on purpose

The file declares `collections: []`. Everything here runs on `ansible.builtin`,
which ships with `ansible-core`, so there is nothing to install and the role works
on a host that has only the minimal Ansible package.

Tasks use fully-qualified names (`ansible.builtin.uri`, `ansible.builtin.set_fact`,
and so on) throughout.

---

## The four variables you actually have to set

Everything else has a working default. These do not:

| Variable | What it is |
|---|---|
| `rubrik_cdm_cluster` | CDM cluster FQDN or IP. |
| `rubrik_cdm_svc_json` | Path to the RSC Service Account JSON -- **or** `rubrik_cdm_client_id` plus `rubrik_cdm_client_secret` instead. |
| `ahv_container_name` | Target storage container name. |
| `ahv_recovered_vm_prefix` | Prefix for recovered VM names. |

`ahv_method` defaults to `mount`, `ahv_point_in_time` to `latest`, and
`ahv_wave_group` to `ahv_recovery_wave`, so a minimal run is those four plus `-i`.

### The prefix: CDM adds its own hyphen

`ahv_recovered_vm_prefix` (formerly `ahv_vm_name_prefix`) becomes `vmNamePrefix` in
the API body, and **CDM inserts the hyphen between prefix and VM name itself**.
Confirmed live from this role:

| `ahv_recovered_vm_prefix` | Resulting VM |
|---|---|
| `dr-` | `dr--sh2-ntnx-w1` |
| `dr` | `dr-sh2-ntnx-w1` |

Use `dr`. Unlike the Python path, this value is wave-wide with no per-VM override.

---

## Settings live in an extra-vars file

A real run needs cluster, credentials, container, and prefix at minimum. Retyping
`-e` flags every time is tedious and a good way to fire a wave at the wrong container,
so `vars/example-recovery-vars.yml` ships as a committed template. Copy it, edit the
copy, and pass the copy:

```bash
cp vars/example-recovery-vars.yml vars/my-recovery.yml
$EDITOR vars/my-recovery.yml
ansible-playbook -i inventory/ahv_wave1_example.yml ahv_mass_recovery.yml \
    -e @vars/my-recovery.yml
```

The example file covers connection (`rubrik_cdm_cluster`, `rubrik_cdm_svc_json`,
`rubrik_cdm_validate_certs`, `rubrik_cdm_timeout`), the wave group, method and point
in time, target container / prefix / AHV cluster, the two live-mount flags, the
staged-CSV variables (pointed at the `_latest.csv` copies), and tuning plus output.

Three things make this the recommended shape:

- **`.gitignore` covers `ansible/vars/*.yml` with a negation that keeps the example
  file**, so your own copies are never committed by accident.
- **A later `-e` overrides the file**, so one reviewed settings file plus one
  deliberate override is a normal invocation:
  `-e @vars/my-recovery.yml -e ahv_method=export`.
- **The whole file can be encrypted.** If you want credentials inline
  (`rubrik_cdm_client_id` / `rubrik_cdm_client_secret`) rather than a service-account
  JSON path, run `ansible-vault encrypt vars/my-recovery.yml` and add
  `--ask-vault-pass` to the playbook command.

The playbook header in `ahv_mass_recovery.yml` leads with this pattern; fully inline
`-e` invocations still work and are shown further down in the worked examples.

---

## The wave-inventory model

A recovery wave is an Ansible inventory file. Each host in the group is an **AHV VM
name as Rubrik knows it** -- Ansible never connects to any of them.

```yaml
# inventory/wave1.yml
all:
  children:
    ahv_recovery_wave:
      hosts:
        sh2-ntnx-w1:
        sh2-ntnx-w2:
```

The play itself runs `hosts: localhost`, `connection: local`, `gather_facts: false`,
and reads the VM list out of `groups[ahv_wave_group]`. So the group is used purely as
a list of names; there is no fork-per-VM, no SSH, no `ansible_host`, and no
credentials on those entries.

Why this shape:

- Waves become files -- `wave1.yml`, `wave2.yml`, `tier0.yml` -- that live in source
  control, get reviewed, and get reused between DR tests.
- Execution stays a single local play making a handful of API calls, which is what the
  batched API wants. Forking one process per VM would fight the API design.
- Names that do not resolve to a VM on the cluster are reported by name and skipped,
  never silently dropped. The API lookup matches exactly but case-insensitively; the
  inventory CSV path matches the name as written.

Generate wave files from the inventory CSV that
[`../python/get_ahv_inventory.py`](../python/README.md) produces. Be aware that live
mounts appear in that inventory as ordinary VMs, so filter recovery prefixes out
before building the next wave from a post-recovery inventory.

### Wave naming

`ahv_wave_name` defaults to the inventory filename with its extension stripped and
anything outside `A-Za-z0-9._-` replaced with `_`, derived from
`ansible_inventory_sources | first | basename`. It names the state file:

| `-i` | State file |
|---|---|
| `inventory/wave1.yml` | `state/wave1_state_<ts>.csv` |
| `inventory/tier0.yml` | `state/tier0_state_<ts>.csv` |
| no inventory source | `state/wave_state_<ts>.csv` |

Override it with `-e ahv_wave_name=whatever` when the file name is not the name you
want on the artifacts. The Python side derives the same name from `--csv`, so a wave
keeps one identity across both front ends.

---

## Role: `rubrik_cdm_auth`

Deliberately **generic and reusable**. It knows nothing about AHV or recovery -- it
authenticates to a Rubrik CDM cluster and hands the rest of the play a ready-to-use
headers dict. Any future Rubrik CDM playbook in this repo should include this role
rather than re-implementing session auth.

```yaml
- ansible.builtin.include_role:
    name: rubrik_cdm_auth
  vars:
    rubrik_cdm_cluster: 10.8.48.104
    rubrik_cdm_svc_json: ~/rsc-sa.json
```

### The three facts it sets

| Fact | Value | Use |
|---|---|---|
| `rubrik_cdm_base_url` | `https://<rubrik_cdm_cluster>` | Prefix for every API URL. |
| `rubrik_cdm_token` | The bearer token from the session call. | Rarely needed directly. |
| `rubrik_cdm_headers` | `{Content-Type, Accept, Authorization: Bearer <token>}` | Pass straight to `ansible.builtin.uri`'s `headers:`. |

### Variables (`roles/rubrik_cdm_auth/defaults/main.yml`)

| Variable | Default | Meaning |
|---|---|---|
| `rubrik_cdm_cluster` | `""` | CDM cluster FQDN or IP. **Required** -- asserted before anything else runs. |
| `rubrik_cdm_svc_json` | `""` | Path to an RSC Service Account JSON. Only `client_id` and `client_secret` are read; `access_token_uri` is ignored, because the token is issued by the CDM cluster and not by RSC. `~` is expanded. |
| `rubrik_cdm_client_id` | `""` | Alternative to the JSON file. Supply with `rubrik_cdm_client_secret`. |
| `rubrik_cdm_client_secret` | `""` | Alternative to the JSON file. Keep both of these in Ansible Vault, never in plain group_vars. |
| `rubrik_cdm_validate_certs` | `false` | CDM clusters commonly run self-signed certificates. |
| `rubrik_cdm_timeout` | `300` | Seconds. Recovery API calls can be slow on large clusters. |

### What it does

1. Assert `rubrik_cdm_cluster` is set.
2. Read the service account JSON, if one was given.
3. Resolve credentials -- explicit `rubrik_cdm_client_id` / `rubrik_cdm_client_secret`
   win over the JSON file.
4. Assert both resolved to something non-empty.
5. `POST https://<cluster>/api/v1/service_account/session` with
   `{serviceAccountId, secret}`, accepting `200` or `201`. Marked
   `check_mode: false`, so it runs during `--check` too.
6. Set the three facts above.
7. Clear the resolved credentials back out of play scope.
8. Print `Authenticated to Rubrik CDM cluster <cluster>`.

Every task that touches a credential or the token carries `no_log: true`.

---

## Role: `rubrik_ahv_recovery`

Mirrors the Python trigger flow: validate, resolve, trigger, write state, optionally
wait.

### `tasks/main.yml`

| Step | File | Notes |
|---|---|---|
| Validate the recovery request | inline `assert` | Requires a valid `ahv_method`, a non-empty `ahv_container_name` and `ahv_recovered_vm_prefix`, and a defined non-empty `groups[ahv_wave_group]`. |
| Resolve VMs, snapshots, and target | `resolve.yml` | Read-only API calls. |
| Trigger the recovery | `trigger.yml` | One POST per chunk. |
| Write the wave-state CSV | `state.yml` | The durable handoff. |
| Wait for recoveries to finish | `monitor.yml` | Only when `ahv_monitor_wait_minutes > 0`. |

### Variables (`roles/rubrik_ahv_recovery/defaults/main.yml`)

#### Which VMs

| Variable | Default | Meaning |
|---|---|---|
| `ahv_wave_group` | `ahv_recovery_wave` | Inventory group holding the AHV VM names for this wave. Each host in the group is treated as a VM name, not as a machine to connect to. |
| `ahv_wave_name` | derived from the `-i` filename | Names the state file: `state/<ahv_wave_name>_state_<ts>.csv`. Overridable. |

#### What kind of recovery

| Variable | Default | Meaning |
|---|---|---|
| `ahv_method` | `mount` | `export` creates new VMs from the snapshot; `mount` live mounts it (non-destructive, easy to unwind). |
| `ahv_point_in_time` | `latest` | Recover from the newest snapshot at or before this UTC time. Accepts `latest`, `2026-09-08T23:00:00.000Z`, or `2026-09-08 23:00:00`. Normalised to ISO-8601 UTC with a trailing `Z` before the API call. |

#### Where it lands

| Variable | Default | Meaning |
|---|---|---|
| `ahv_container_name` | `""` | Target storage container name. **Required.** Matched case-insensitively against the containers on the target AHV cluster. |
| `ahv_nutanix_cluster_name` | `""` | Target AHV cluster name. Blank means use each VM's own AHV cluster, which is also the only sensible choice when exactly one AHV cluster is registered -- in that case its id is used for everything. |
| `ahv_recovered_vm_prefix` | `""` | Prefix applied to every recovered VM name. **Required.** CDM adds its own hyphen, so use `dr`, not `dr-`. Wave-wide, with no per-VM override. |
| `ahv_should_migrate_immediately` | `false` | Live mount only. Sets `mountConfig.shouldMigrateImmediately`. |
| `ahv_should_disable_migration` | `false` | Live mount only. Sets `mountConfig.shouldDisableMigration`. |

#### Tuning

| Variable | Default | Meaning |
|---|---|---|
| `ahv_chunk_size` | `25` | VMs per batch API call. A single very large batch can exceed the cluster request timeout -- a 2-VM export took about 6.7s in the reference capture. Applies to both the snapshot lookup and the trigger. |
| `ahv_inventory_csv` | `""` | Optional AHV inventory CSV from `get_ahv_inventory.py`. When set, VM ids are read straight out of it and no name-lookup API calls are made for the names it covers. Strongly recommended for large environments. A stale CSV degrades gracefully -- any name it does not cover falls through to the per-VM API lookup. |
| `ahv_containers_csv` | `""` | Optional storage container CSV from `get_ahv_inventory.py`. When it covers every container this wave targets, both the AHV cluster listing and the per-AHV-cluster container listing are skipped entirely. That container call is a Prism passthrough measured at **5296ms cold** (210ms and 133ms warm) in the reference capture, and the cost is per AHV cluster. Anything the file does not cover falls through to a live lookup, and live values win on merge. |

Neither CSV path is auto-discovered -- see
[Why the CSVs are explicit here](#why-the-csvs-are-explicit-here). Point them at the
stable copies that `get_ahv_inventory.py` rewrites on every run, which is what the
example vars file does:

```yaml
ahv_inventory_csv: ../python/inventory/ahv_inventory_latest.csv
ahv_containers_csv: ../python/inventory/ahv_containers_latest.csv
```

Those `_latest.csv` files exist precisely so an Ansible variable can name a path that
never goes stale, while the timestamped files remain the audit trail.

#### Output

| Variable | Default | Meaning |
|---|---|---|
| `ahv_state_dir` | `{{ playbook_dir }}/state` | Directory for the wave-state CSV. This file is the durable handoff to `ahv_monitor_recovery.py` -- keep it. |

#### Optional bounded wait

| Variable | Default | Meaning |
|---|---|---|
| `ahv_monitor_wait_minutes` | `0` | `0` means trigger and exit immediately, which is the recommended setting. Anything above `0` runs `monitor.yml` as a bounded `until` loop. |
| `ahv_monitor_poll_seconds` | `30` | Poll interval within that wait. The retry count is derived as `ceil(ahv_monitor_wait_minutes * 60 / ahv_monitor_poll_seconds)`. |

---

## `resolve.yml` -- read-only resolution

1. Normalise `ahv_point_in_time` into `ahv_before_date` (ISO-8601 UTC, trailing `Z`).
2. Collect the wave VM names from `groups[ahv_wave_group]` into `ahv_wave_names`.
3. **Resolve names to VM ids** using the two bounded strategies below, producing
   `ahv_resolved` and `ahv_unmatched`; print a warning naming every unmatched VM,
   then assert at least one VM resolved.
4. `POST /api/v1/snapshot/closest_to_point_in_time`, looped over
   `ahv_resolved | batch(ahv_chunk_size)`; index the results by `snappableId`.
5. **Resolve storage containers**, preferring the staged CSV -- see below. When a live
   lookup is still needed it is
   `GET /api/internal/nutanix/cluster?primary_cluster_id=local&include_prism_clusters=true`
   to resolve `ahv_target_cluster_id`, then
   `GET /api/internal/nutanix/cluster/{id}/container` for each AHV cluster. Staged and
   live results are merged into `ahv_container_index`, keyed
   `<clusterId>|<lowercased container name>` to `naturalId`. A named
   `ahv_nutanix_cluster_name` that does not resolve fails the play with the list of
   names that do exist.
6. Build `ahv_records` (recoverable) and `ahv_skipped` (with a reason: no snapshot at
   the point in time, or container not found on that VM's AHV cluster).
7. Print the preview, then assert `ahv_records` is not empty.

Each record in `ahv_records` carries `vm_name`, `vm_id`, `snapshot_id`,
`snapshot_date`, `nutanix_cluster_id`, and `container_natural_id`.

Every `uri` task in this file is `changed_when: false` and `check_mode: false`, so
resolution is real even under `--check`.

### Why name resolution is not a bulk VM listing

The role deliberately avoids `GET /api/internal/nutanix/vm` with no filter. That call
is paginated, and in a large environment it either truncates silently or forces a
paging loop that Ansible expresses badly. Two bounded strategies are used instead,
and they compose:

| Strategy | Cost | When |
|---|---|---|
| 1. `ahv_inventory_csv` | Zero API calls | Large environments and repeat runs. Ids are read out of the CSV that `get_ahv_inventory.py` produces, via the `ansible.builtin.csvfile` lookup: column index 1 is `vm_id` and column index 3 is `nutanix_cluster_id`, which is exactly the inventory CSV's column order. |
| 2. Per-VM API lookup (fallback) | One small GET per unresolved name | Anything the CSV does not cover, and the default when no CSV is supplied. |

The fallback issues
`GET /api/internal/nutanix/vm?primary_cluster_id=local&is_relic=false&name=<name>`
per name. Each returns a handful of rows, so there is no pagination exposure -- N
small calls instead of one huge one. The `name` query parameter is a **substring**
match, so the result is filtered to an exact case-insensitive hit before any row is
trusted.

A stale CSV therefore degrades gracefully rather than failing: names it misses simply
fall through to the API lookup. The role prints which split it used:
`Resolving N VM name(s): X from the inventory CSV, Y via a per-VM API lookup.`

The CSV lookups pass `delimiter=','` explicitly. This matters:
`ansible.builtin.csvfile` defaults its delimiter to **TAB**, so without it a
comma-separated inventory silently matches nothing and every VM falls through to the
API path. That was reproduced and fixed -- a probe confirmed the default delimiter
returns no match while `delimiter=','` resolves correctly.

The resolution logic is covered by an offline test that extracts the shipped
`set_fact` tasks from this role and runs them against stubbed API responses, asserting
that the CSV path hits, that only CSV misses reach the API, that a substring decoy
(`NTNX-sh2-afs-01-10` when looking up `NTNX-sh2-afs-01-1`) is rejected, and that an
unknown name lands in `ahv_unmatched`.

### Why container resolution also prefers a staged CSV

`ahv_containers_csv` gets the same treatment, for a measured reason. In the reference
API capture, `GET /internal/nutanix/cluster/{id}/container` took **5296ms on a cold
cache**, then 210ms and 133ms warm. It is a Prism passthrough, and the cost is paid
**per AHV cluster**, so a Rubrik cluster with several registered AHV clusters pays it
several times. That is the single slowest read in the trigger path.

The role therefore:

1. Parses `ahv_containers_csv` into `ahv_staged_containers`
   (`<clusterId>|<lowercased name>` to `naturalId`) and `ahv_staged_cluster_ids`
   (lowercased AHV cluster name to id). It reads the file positionally -- column 0
   cluster name, 1 cluster id, 2 container name, 3 `naturalId` -- which is exactly the
   column order `get_ahv_inventory.py` writes.
2. Works out a provisional cluster id: the one matching `ahv_nutanix_cluster_name`, or
   the only one in the staged file if it holds exactly one.
3. Sets `ahv_containers_need_live` to true if there is no staged data, if
   `ahv_nutanix_cluster_name` was given but is not in the staged file, or if **any** VM
   in the wave needs a `(cluster id, container name)` pair the staged file does not
   have.
4. Prints which path it took: `Resolved entirely from the staged CSV -- no cluster or
   container API calls`, or `Querying the cluster for AHV clusters and storage
   containers (staged CSV did not cover every target)`.
5. Skips both `uri` tasks entirely when no live lookup is needed -- the cluster listing
   is guarded by `when: ahv_containers_need_live`, and the container listing loops over
   an empty list.
6. Merges staged and live into `ahv_container_index`, applying live values **after**
   staged ones so live wins on any key present in both.

So the staged file is an accelerator, never an authority: it is used only when it
covers the whole wave, and a stale file costs a live lookup rather than a wrong
target.

The AHV cluster list itself (measured at 120-403ms) gets no separate staging variable
on purpose. It is cheap, and the cluster-name-to-id mapping it provides is already in
the containers CSV, so a dedicated variable would add config surface for a fraction of
a second. `closest_to_point_in_time` (67-138ms) is already batched and cannot be
staged at all -- the point in time varies per run, so there is no stable answer to
cache.

### Why the CSVs are explicit here

`ahv_mass_recovery.py` auto-discovers the newest `*_inventory_*.csv` and
`*_containers_*.csv` from its `inventory/` folder. The Ansible role deliberately does
not: both variables default to `""` and must be set.

Implicit file selection is defensible in a CLI, where the operator sees the chosen
file and its age printed on the terminal in front of them and can re-run with an
explicit path in seconds. Inside a playbook it is worse. The same play can be launched
by a scheduler, from a change-control pipeline, or from a different working directory,
and a variable that quietly resolves to whatever file happens to be newest on that
host is the wrong kind of surprise during a recovery event. Put the path in
`vars/my-recovery.yml` and it is reviewable, diffable, and the same on every run --
which is what the stable `ahv_inventory_latest.csv` / `ahv_containers_latest.csv`
copies are for.

### Performance note: the per-VM lookup loop is serial

The per-VM lookup loop is **serial**. Ansible parallelises across hosts via `forks`,
never across `loop` items, and this play runs on a single host (`localhost`), so
`forks` buys nothing here -- requests go out one at a time.

Rough guidance, and these are estimates rather than measurements: fine for tens of
VMs, and minutes of wall clock for 500 or more.

For large waves set `ahv_inventory_csv` -- resolution then costs **zero API calls**.
That is the intended path at scale; the per-VM lookup exists so the role still works
without a current inventory CSV. Setting `ahv_containers_csv` alongside it removes the
container lookups too, at which point the whole resolve phase is snapshot selection
and nothing else. That fully-staged path has been confirmed working live.

Only a two-VM wave has been run against a live cluster, so nothing above single digits
has actually been timed.

## `trigger.yml`

Builds `ahv_payload` -- one `exportConfig` or `mountConfig` entry per record -- then
POSTs it to `/api/v1/nutanix/vm/batch_export` or `/api/v1/nutanix/vm/batch_mount`,
looped over `ahv_payload | batch(ahv_chunk_size)`, accepting `200` or `202`. The POST
is the one task guarded by `when: not ansible_check_mode`.

The response is indexed into `ahv_job_by_vm`, keyed by `vmId`:

- `successfulRequests[]` gives `job_instance_id` (from `asyncRequestStatus.id`),
  `status: queued`, and `triggered_at` (from `asyncRequestStatus.startTime`).
- `failedRequests[]` gives an empty `job_instance_id`, `status: failed`, and the
  failed request JSON as `message`.

Finally it prints how many were triggered and how many failed. A live run reported
`Triggered 2 of 2 VM(s). Failed: 0.`

## `state.yml` -- the durable handoff

Creates `ahv_state_dir` and renders `templates/wave_state.csv.j2` to
`<ahv_state_dir>/<ahv_wave_name>_state_<YYYYMMDD_HHMMSS>.csv` (UTC timestamp), then
prints the path and the exact Python command to monitor it. Both tasks are skipped in
check mode, so a `--check` run leaves nothing behind.

The template emits the same 17 columns, in the same order, as the Python writer's
`WAVE_STATE_FIELDS` -- human-readable first, identifiers last:

```
triggered_at, status, status_updated, vm_name, method, snapshot_date,
recovered_vm_prefix, duration_seconds, data_transferred_bytes, end_time,
message, vm_id, snapshot_id, nutanix_cluster_id, container_natural_id,
job_instance_id, event_series_id
```

That list is defined in `monitor_core.py` (and re-exported by `ahv_mass_recovery.py`),
so the monitor can patch the file without importing the trigger script. There is no
`trigger_status` column: the trigger outcome is written straight into `status`, as
`queued`, `failed`, or `unknown` for a VM present in the batch but absent from both
response arrays.

The role fills the columns it can know at trigger time and leaves the rest empty:
`status_updated`, `duration_seconds`, `data_transferred_bytes`, `end_time` and
`event_series_id` are all blank, because none of them exist yet. Every value is quoted
and embedded double quotes in `message` are doubled, so a failure payload containing
JSON does not break the CSV.

The Python monitor then fills those blanks in place, on every poll -- resolving
`event_series_id` from `/api/v1/event/latest` once and caching it, and writing status,
end time, duration and any transferred bytes back into this same file. Verified live:
a CSV written by this template was monitored to completion by
`ahv_monitor_recovery.py --state`, ending up with `status,succeeded`,
`duration_seconds,65` and a populated `event_series_id` on rows this role had written
as `queued`. Triggering from Ansible and monitoring with Python is the intended
workflow, not a workaround.

## `monitor.yml` -- optional, off by default

Runs only when `ahv_monitor_wait_minutes > 0`. It pauses 10 seconds for the event
series to register, looks up `/api/v1/event/latest` per VM to pair each
`jobInstanceId` with its `eventSeriesId`, then polls
`POST /api/internal/event_series/status` with `until` / `retries` / `delay` and
prints a completion summary. Unfinished work is `failed_when: false`, so an expired
wait window is never treated as a recovery failure.

Note that it re-resolves the event series from scratch every time it runs, and does
not write the ids back into the wave-state CSV. The Python monitor does persist them,
so a wave handed to `ahv_monitor_recovery.py --state` pays the per-VM
`/api/v1/event/latest` lookup once rather than on every restart. Unlike the resolve
tasks, the tasks in this file are not marked `check_mode: false` -- another reason it
is not part of the `--check` story.

**Leave it at `0` for anything but a smoke test.** The task file says so itself, and
the reasoning is in [`../README.md`](../README.md): `until` / `retries` is an
in-memory loop with no checkpoint and no resume, task output is buffered so a long
poll prints nothing at all until it finishes, and closing the terminal sends SIGHUP
and kills the run. None of that is true of the Python monitor, which checkpoints to
the results CSV and to the wave-state CSV, prints a live table every poll, and resumes
after any interruption.

---

## `--check` is a genuine dry run

Running the play with `--check` is a real dry run of the whole trigger:

- Every read-only `uri` task carries **`check_mode: false`** as well as
  `changed_when: false`, so you get real authentication, real VM matching, real
  snapshot selection, and real container resolution against the live cluster.
- The trigger POST is guarded by `when: not ansible_check_mode` and does not run.
- Instead, a debug task prints exactly what would have been sent: the VM count, the
  target endpoint, the number of batches, and the full request body via
  `to_nice_json`.
- Writing the state directory and the wave-state CSV is skipped too, so a check run
  leaves nothing behind.

Those `check_mode: false` markers are what make this work. Without them Ansible skips
every `uri` task in check mode, starting with the authentication call -- so
`rubrik_cdm_headers` was never set and the play collapsed on the next task instead of
previewing anything. `--check` genuinely works now.

This is the Ansible equivalent of `ahv_mass_recovery.py --dry_run`. Run it first,
every time.

---

## Handoff to the Python monitor

The playbook prints the command when it finishes. It is:

```bash
python3 ../python/ahv_monitor_recovery.py \
    --svc_json ~/rsc-sa.json \
    --cluster 10.8.48.104 \
    --state state/wave1_state_20260916_120000.csv
```

That command is resumable. Ctrl-C it, close the terminal, come back tomorrow, or copy
the CSV to another machine and run it there -- the job ids live in the file, not in
the process, and anything that already finished stays finished. See
[`../python/README.md`](../python/README.md) for the results CSV columns, the live
per-VM table, and the metrics summary it produces.

To unwind live mounts afterwards, point the cleanup script at the same state file:

```bash
python3 ../python/ahv_cleanup_mounts.py \
    --svc_json ~/rsc-sa.json --cluster 10.8.48.104 \
    --state state/wave1_state_20260916_120000.csv --list_only
```

That matches every mount of the VMs named in the wave, labelling each one `this wave`
or `other`, so pre-existing mounts of the same source VMs are visible before anything
is deleted. Re-run without `--list_only` to tear them down.

---

## Worked examples

### With an extra-vars file (the recommended shape)

```bash
# One-time setup -- copy the committed template and edit your copy
cp vars/example-recovery-vars.yml vars/my-recovery.yml
$EDITOR vars/my-recovery.yml

# Dry run -- resolves everything against the live cluster, prints the request
# body, sends nothing, writes nothing
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e @vars/my-recovery.yml --check

# Live mount the wave
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e @vars/my-recovery.yml

# Same settings, export instead -- a later -e wins over the file
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e @vars/my-recovery.yml -e ahv_method=export

# Staged CSVs for a large wave -- zero VM-name and container lookup API calls.
# Point at the stable copies, which never go stale.
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e @vars/my-recovery.yml \
    -e ahv_inventory_csv=../python/inventory/ahv_inventory_latest.csv \
    -e ahv_containers_csv=../python/inventory/ahv_containers_latest.csv

# Credentials inline in the vars file -- encrypt it first
ansible-vault encrypt vars/my-recovery.yml
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e @vars/my-recovery.yml --ask-vault-pass
```

### Fully inline

```bash
# Dry run -- resolves everything against the live cluster, prints the request
# body, sends nothing, writes nothing
ansible-playbook -i inventory/ahv_wave1_example.yml ahv_mass_recovery.yml --check \
    -e rubrik_cdm_cluster=10.8.48.104 \
    -e rubrik_cdm_svc_json=~/rsc-sa.json \
    -e ahv_method=mount \
    -e ahv_container_name=default-container \
    -e ahv_recovered_vm_prefix=dr

# Live mount a wave from the newest snapshot
ansible-playbook -i inventory/ahv_wave1_example.yml ahv_mass_recovery.yml \
    -e rubrik_cdm_cluster=10.8.48.104 \
    -e rubrik_cdm_svc_json=~/rsc-sa.json \
    -e ahv_method=mount \
    -e ahv_container_name=default-container \
    -e ahv_recovered_vm_prefix=dr

# Export to a point in time (quote the -e because the value contains a space)
ansible-playbook -i inventory/ahv_wave1_example.yml ahv_mass_recovery.yml \
    -e rubrik_cdm_cluster=10.8.48.104 \
    -e rubrik_cdm_svc_json=~/rsc-sa.json \
    -e ahv_method=export \
    -e 'ahv_point_in_time=2026-09-08 23:00:00' \
    -e ahv_container_name=default-container \
    -e ahv_recovered_vm_prefix=dr

# A different wave file, and a differently named inventory group. The state
# file is named after the inventory file: state/ahv_tier0_state_<ts>.csv
ansible-playbook -i inventory/ahv_tier0.yml ahv_mass_recovery.yml \
    -e rubrik_cdm_cluster=10.8.48.104 \
    -e rubrik_cdm_svc_json=~/rsc-sa.json \
    -e ahv_wave_group=ahv_tier0_wave \
    -e ahv_method=mount \
    -e ahv_container_name=default-container \
    -e ahv_recovered_vm_prefix=tier0dr

# Large environment -- resolve VM ids and storage containers from the staged CSVs
# instead of one API lookup per VM name and a 5.3s container listing per AHV cluster
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e rubrik_cdm_cluster=10.8.48.104 \
    -e rubrik_cdm_svc_json=~/rsc-sa.json \
    -e ahv_inventory_csv=../python/inventory/ahv_inventory_latest.csv \
    -e ahv_containers_csv=../python/inventory/ahv_containers_latest.csv \
    -e ahv_method=mount \
    -e ahv_container_name=default-container \
    -e ahv_recovered_vm_prefix=dr

# Target a specific AHV cluster, smaller chunks, longer HTTP timeout
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e rubrik_cdm_cluster=10.8.48.104 \
    -e rubrik_cdm_svc_json=~/rsc-sa.json \
    -e ahv_method=mount \
    -e ahv_nutanix_cluster_name=ntnx-prod-01 \
    -e ahv_container_name=default-container \
    -e ahv_recovered_vm_prefix=dr \
    -e ahv_chunk_size=10 \
    -e rubrik_cdm_timeout=600

# Credentials inline instead of a JSON file (use Ansible Vault in practice)
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e rubrik_cdm_cluster=10.8.48.104 \
    -e rubrik_cdm_client_id=User:::abc-123 \
    -e rubrik_cdm_client_secret=my-secret \
    -e ahv_method=mount \
    -e ahv_container_name=default-container \
    -e ahv_recovered_vm_prefix=dr

# Two-VM smoke test with a 15-minute bounded wait (NOT for real waves)
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e rubrik_cdm_cluster=10.8.48.104 \
    -e rubrik_cdm_svc_json=~/rsc-sa.json \
    -e ahv_method=mount \
    -e ahv_container_name=default-container \
    -e ahv_recovered_vm_prefix=dr \
    -e ahv_monitor_wait_minutes=15

# Write the wave-state CSV somewhere shared, under a custom wave name
ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml \
    -e rubrik_cdm_cluster=10.8.48.104 \
    -e rubrik_cdm_svc_json=~/rsc-sa.json \
    -e ahv_method=mount \
    -e ahv_container_name=default-container \
    -e ahv_recovered_vm_prefix=dr \
    -e ahv_wave_name=dr-test-jan \
    -e ahv_state_dir=/srv/dr/wave-state
```
