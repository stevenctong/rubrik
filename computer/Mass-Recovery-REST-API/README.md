# Rubrik AHV Mass Recovery Toolkit

Tooling to trigger and monitor **hundreds of Nutanix AHV VM recoveries** against a
Rubrik CDM cluster from a CSV wave list, instead of clicking through the UI one VM
at a time.

Two front ends, one shared design:

- **Python** (`python/`) -- triggers, monitors, and unwinds. Stdlib only.
- **Ansible** (`ansible/`) -- triggers only, driven from per-wave inventory files.

Both write the same durable **wave-state CSV**, and the Python monitor reads either
one. That handoff has now been exercised against a live cluster -- see
[Status: verified against a live cluster](#status-verified-against-a-live-cluster).

Detailed references:

- [`python/README.md`](python/README.md) -- per-script arguments, CSV schemas, worked examples
- [`ansible/README.md`](ansible/README.md) -- role layout, every variable, worked examples

---

## When to use this

- **DR tests.** Live mount a tier of AHV VMs, prove RTO, capture per-VM durations,
  then tear the mounts down.
- **Ransomware / mass recovery.** Export a wave of VMs from a known-good point in
  time to a target AHV cluster and storage container.
- **Recovery rehearsals at scale.** Anything where "recover these 200 VMs and tell
  me how long each one took" is the actual requirement.

It is not a general Rubrik CLI. It does one workload (AHV) and one job (mass
recovery plus its teardown).

---

## Read this first: CDM adds its own hyphen to the prefix

Every recovered VM is named `<prefix>-<source VM name>`. **CDM inserts that hyphen
itself**, so a prefix that already ends in one produces a double hyphen. Confirmed
on a live cluster:

| You set | CDM produced |
|---|---|
| `dr-` | `dr--sh2-ntnx-w1` |
| `dr` | `dr-sh2-ntnx-w1` |

So use `dr`, not `dr-`. This applies everywhere the prefix is expressed: the
`--recovered_vm_prefix` flag, the `recovered_vm_prefix` column in a wave CSV, and
`ahv_recovered_vm_prefix` in Ansible. All of them land in `vmNamePrefix` in the API
body, and the cluster does the joining.

The prefix is also **not a filter**. It only names the recovered copies. Which VMs
get recovered is decided entirely by the wave CSV (`--csv`) or the wave inventory
group.

---

## Directory layout

```
Mass-Recovery-REST-API/
  README.md                            This file.
  ahv-mass-recovery.html               Rendered overview of the toolkit.
  PLAN-graphql-inventory.md            Design for the planned RSC GraphQL
                                       inventory backend (not implemented).
  rest_api-ahv_export_live_mount.json  Captured API trace of a real AHV export and
                                       live mount driven through the Rubrik UI
                                       (52 calls). This is the ground truth the
                                       whole toolkit was built from -- every
                                       endpoint, request body, and response field
                                       used below was verified against it first,
                                       and most have since been confirmed live.

  python/
    README.md
    cdm_client.py             CDM REST client + AHV endpoint methods. Not run directly.
    ahv_common.py             Logging, prompting, credentials, CSV, wave naming,
                              staged-CSV discovery, formatting. Not run directly.
    monitor_core.py           Generic CDM event-series engine: resolution, polling,
                              status classification, metrics, and the recovery CSV
                              schemas. Not run directly.
    get_ahv_inventory.py      Walk every AHV VM -> inventory CSV + containers CSV.
                              Both are staged lookups the trigger step can reuse.
    ahv_mass_recovery.py      Trigger export or live mount -> wave-state CSV.
    ahv_monitor_recovery.py   Resumable monitor, plus --cancel.
    ahv_cleanup_mounts.py     List and tear down AHV live mounts.
    inventory/                Generated inventory + container CSVs land here,
                              including the stable *_latest.csv copies.
    logs/                     Created automatically on first run.

  ansible/
    README.md
    ansible.cfg                               No default inventory, deliberately.
    requirements.yml                          Empty -- no external collections needed.
    ahv_mass_recovery.yml                     The trigger play (hosts: localhost).
    inventory/ahv_wave1_example.yml           Example wave inventory.
    vars/example-recovery-vars.yml            Committed template for an extra-vars
                                              file. Copy it, edit the copy, pass it
                                              with -e @vars/<file>. Everything else
                                              in vars/ is gitignored.
    roles/rubrik_cdm_auth/                    Reusable CDM authentication role.
      defaults/main.yml
      tasks/main.yml
    roles/rubrik_ahv_recovery/
      defaults/main.yml
      tasks/main.yml                          Validate -> resolve -> trigger -> state -> wait.
      tasks/resolve.yml
      tasks/trigger.yml
      tasks/state.yml
      tasks/monitor.yml                       Optional bounded wait, off by default.
      templates/wave_state.csv.j2
    state/                                    Created automatically; holds wave-state CSVs.
```

One packaging note: the repo `.gitignore` still ignores Python-side state files by
the old `ahv_wave_state_*.csv` pattern. State files are now named after the wave
(`wave1_state_<ts>.csv`), so one written next to `ahv_mass_recovery.py` shows up as
untracked until that pattern is widened. Nothing functional depends on it.

---

## End-to-end workflow

```
  1. get_ahv_inventory.py
        |
        |  inventory/ahv_inventory_<ts>.csv   (every AHV VM, two blank trailing columns)
        |  inventory/ahv_containers_<ts>.csv  (valid target container names + naturalIds)
        |  inventory/ahv_inventory_latest.csv   } stable copies, for Ansible
        |  inventory/ahv_containers_latest.csv  } (which does not auto-discover)
        v
  2. Operator filters the inventory CSV down to one wave and fills in
     target_container_name and recovered_vm_prefix (or passes --container and
     --recovered_vm_prefix and leaves both columns blank)
        |
        |  wave1.csv
        v
  3. TRIGGER  -- pick one:
        (a) python3 ahv_mass_recovery.py --csv wave1.csv --method mount ...
        (b) ansible-playbook -i inventory/wave1.yml ahv_mass_recovery.yml ...
        |
        |  wave1_state_<ts>.csv   <-- the durable contract
        v
  4. ahv_monitor_recovery.py --state wave1_state_<ts>.csv
        |
        |  logs/wave1_results_<ts>.csv  (per-VM status, duration, transfer)
        |  ...and the wave-state CSV itself, refreshed on every poll
        v
  5. ahv_cleanup_mounts.py --state wave1_state_<ts>.csv --list_only   (live mounts only)
     then the same command again without --list_only
```

Step 2 is the only manual step, and it is manual on purpose: choosing which VMs go
in which wave, where they land, and what they get named is a human decision during
a recovery event.

Both CSVs from step 1 are **staged lookups**, not just references. The trigger step
reads VM ids out of the inventory CSV and container `naturalId`s out of the
containers CSV, and skips the equivalent API calls for everything they cover. The
Python trigger picks up the newest of each automatically (`--inventory` /
`--containers` to name a specific file, `--no_auto_csv` to switch discovery off);
Ansible takes them as explicit paths (`ahv_inventory_csv` / `ahv_containers_csv`),
which is exactly what the stable `*_latest.csv` copies exist for. Either way a stale
file degrades rather than fails -- anything it does not cover falls through to a
live lookup.

### Everything is named after the wave

`ahv_common.wave_name_from()` derives a wave name from whatever file identifies the
wave, and every artifact of that run carries it. A directory holding several waves
stays readable instead of being a wall of interchangeable `ahv_*` files.

| Input | Artifacts |
|---|---|
| `--csv wave1.csv` | `wave1_state_<ts>.csv`, `logs/wave1_recovery_log_<ts>.log`, `logs/wave1_excluded_<ts>.csv`, `logs/wave1_results_<ts>.csv` |
| `--state wave1_state_<ts>.csv` | `logs/wave1_results_<ts>.csv`, `logs/wave1_monitor_log_<ts>.log` |
| `-i inventory/wave1.yml` (Ansible) | `state/wave1_state_<ts>.csv` |

The name is the basename with its extension stripped and any trailing
`_state_<ts>` / `_results_<ts>` / `_excluded_<ts>` removed, so feeding a state file
back in does not stack suffixes. Ansible derives `ahv_wave_name` from the inventory
filename the same way, and it can be overridden.

---

## Python or Ansible?

Both trigger. Only Python monitors.

| | Python | Ansible |
|---|---|---|
| Trigger export / live mount | Yes | Yes |
| Monitor to completion | Yes, resumable | No (bounded wait only, off by default) |
| Cancel in-flight recoveries | Yes (`--cancel`) | No |
| Live mount teardown | Yes | No |
| Wave list source | CSV file | Inventory group |
| Per-VM container / prefix override | Yes (CSV columns) | No, wave-wide |
| Staged inventory / container CSVs | Yes (`--inventory`, `--containers`) | Yes (`ahv_inventory_csv`, `ahv_containers_csv`) |
| Auto-discovers the newest staged CSV | Yes (off with `--no_auto_csv`) | No, deliberately |
| Dry run | `--dry_run` | `--check` |
| Per-VM metrics and summary | Yes | No |

**Use Python** for anything end to end, and for every real recovery event. It is
the only path that monitors, reports metrics, cancels, and cleans up.

**Use Ansible** when the team already runs Ansible and wants waves expressed as
inventory files under source control, or when the trigger needs to sit inside an
existing playbook or change-control workflow. Trigger with Ansible, then hand the
wave-state CSV it writes to `ahv_monitor_recovery.py`. That handoff is the intended
pattern, not a workaround, and it has been run end to end against a live cluster.

---

## How it works against the API

### Trigger: four calls, regardless of wave size

The CDM AHV recovery API is natively batched, so a 500-VM wave costs about the same
number of calls as a 2-VM wave.

| Step | Call |
|---|---|
| 1. Resolve VM names to ids | `GET /api/internal/nutanix/vm?primary_cluster_id=local&is_relic=false` (paginated) |
| 2. Pick the snapshot | `POST /api/v1/snapshot/closest_to_point_in_time` with `{snappableIds, beforeDate}` |
| 3. Resolve the target | `GET /api/internal/nutanix/cluster` then `GET /api/internal/nutanix/cluster/{id}/container` -- both skipped when a staged containers CSV covers the wave |
| 4. Trigger | `POST /api/v1/nutanix/vm/batch_export` or `POST /api/v1/nutanix/vm/batch_mount` |

The trigger response carries `successfulRequests[]` and `failedRequests[]`, which is
the per-VM success gate, and an `asyncRequestStatus` object per VM.

Step 1 is the only step whose *mechanism* differs between the two front ends. Python
paginates the bulk VM list, or skips it entirely when the inventory CSV covers every
name in the wave. The Ansible role never issues an unfiltered listing: it reads ids
from `ahv_inventory_csv` when one is supplied, and otherwise falls back to one small
name-filtered GET per VM, so it is never exposed to pagination.

Steps 2 and 4 are identical in both. Step 3 is identical in shape, and in both front
ends it is skipped entirely when a staged containers CSV covers every container the
wave targets.

### Monitoring chain

```
  batch_export / batch_mount
        |
        |  asyncRequestStatus.id  ==  jobInstanceId
        v
  GET /api/v1/event/latest?object_ids=<vmId>&limit=50
        |
        |  match latestEvent.jobInstanceId -> read latestEvent.eventSeriesId
        v
  POST /api/internal/event_series/status   body [{id, jobInstanceId}, ...]
        |
        |  BATCHED. Primary poll and the metrics source:
        |  progress, terminatedEventSeriesStatus, logicalSize,
        |  dataTransferred, throughput
        v
  GET /api/v1/event_series/{id}
           Per-VM detail once a job goes terminal: startTime, eventDetailList
           (end time and any failure message)
```

`asyncRequestStatus.id` **is** the `jobInstanceId`. That single fact is what makes
the whole chain work, and it is why the trigger phase can hand off to a completely
separate monitoring process. A live mount returns ids of the form
`MOUNT_NUTANIX_SNAPSHOT_<uuid>_<uuid>:::0`; the captured UI export produced
`MULTI_NODE_EXPORT_NUTANIX_SNAPSHOT_...`.

Cancel is `POST /api/internal/event_series/{id}/cancel`. Existing live mounts are
`GET /api/v1/nutanix/vm/snapshot/mount`.

---

## Design decisions and why

### Batch endpoints, not per-VM calls

The obvious shape for a mass-recovery tool is a thread pool issuing one call per VM.
That is the wrong shape here, because the API is already batched: `batch_export` and
`batch_mount` take an array of snapshots, and `closest_to_point_in_time` takes an
array of snappable ids. A 200-VM wave is roughly four calls plus chunking, not 800
calls. Less load on the cluster, fewer failure modes, no thundering herd, and the
per-VM success or failure still comes back in one response.

The one place parallelism does appear is per-VM detail fetches, event-series
resolution fallbacks, event-series detail on completion, and unmounts -- exactly the
calls the API does not batch.

### What is worth staging, and what is not

`get_ahv_inventory.py` writes two CSVs, and both are consumed by the trigger step
rather than being operator references only. Which calls got a staged path was decided
from the response times measured in the captured API trace, not from a guess:

| Call | Measured | Staged? |
|---|---|---|
| `GET /internal/nutanix/cluster/{id}/container` | **5296ms cold**, then 210ms and 133ms warm | Yes -- `--containers` / `ahv_containers_csv` |
| `GET /internal/nutanix/cluster` (the AHV cluster list) | 120ms, 127ms, 222ms, 260ms, 403ms | No, deliberately |
| `POST /v1/snapshot/closest_to_point_in_time` | 67ms, 73ms, 81ms, 138ms | Cannot be staged |

The container listing is a Prism passthrough, and the cost is **per AHV cluster**, so
a Rubrik cluster with several registered AHV clusters pays it several times. A cold
5.3s is the single slowest read in the whole trigger path, which is what earns it a
staged path.

The AHV cluster list is cheap and returns one small array, so giving it its own
staging variable would add config surface for a fraction of a second. It rides along
in the same live lookup when one is needed, and is otherwise skipped as a side effect
of the containers CSV covering the wave.

`closest_to_point_in_time` is already batched, and it is inherently runtime-only: the
point in time varies per run, so there is no stable answer to cache. It can never be
staged, however fast or slow it is.

Staging is always **best effort, never a contract**. The staged containers file is
used only when it covers every container the wave targets; anything it misses falls
through to a live lookup, and when a live lookup runs, live values win on merge. A
stale file therefore degrades to the old behaviour rather than producing a wrong
answer. The fast path has been exercised live: a wave resolved from the staged CSVs
logged `Resolved entirely from the staged CSV -- no container API calls` and made
zero lookup calls.

### CSV auto-discovery is a Python convenience, not an Ansible one

`get_ahv_inventory.py` writes timestamped filenames, so always passing full paths
meant pasting a new path into the command line on every run. `ahv_mass_recovery.py`
discovers the newest `*_inventory_*.csv` and `*_containers_*.csv` instead, looking in
`python/inventory/` first and then in the script directory, so files generated before
the `inventory/` layout existed still resolve.

The guardrails matter more than the convenience:

- An explicit `--inventory` / `--containers` always wins, and an explicit path that
  does not exist is a hard error rather than a silent fall back to discovery.
- The file chosen and its age are **always** printed, even when fresh.
- Anything `stale_days` (default `7`) or older prints a WARNING telling the operator
  to re-run the inventory or pass an explicit path.
- Age comes from the `YYYYMMDD_HHMMSS` stamp in the filename, **not** mtime. Copying
  a months-old inventory between machines resets its mtime and would otherwise make a
  stale file look freshly generated -- which is exactly the case the warning exists
  to catch.
- `--no_auto_csv` turns discovery off entirely.

Ansible deliberately does **not** auto-discover. Implicit file selection is defensible
in a CLI, where the operator sees the chosen file and its age printed on the terminal
in front of them and can re-run with an explicit path in seconds. Inside a playbook it
is worse: the same run can be launched from a scheduler, a change-control pipeline, or
a different working directory, and a variable that quietly resolves to whatever
happens to be newest on that host is the wrong kind of surprise during a recovery
event. So `ahv_inventory_csv` and `ahv_containers_csv` stay explicit and default to
empty -- and `get_ahv_inventory.py` writes the stable `ahv_inventory_latest.csv` /
`ahv_containers_latest.csv` copies precisely so those variables can point at a path
that never goes stale.

### The wave-state CSV is the durable contract

This is the central design idea in the toolkit.

The trigger writes `<wave>_state_<ts>.csv` the instant each batch returns. That file
carries every `jobInstanceId`, snapshot id, target, and status. The monitor reads it
and needs nothing else.

The consequence: **resilience becomes a property of the file, not the process.**

- Kill the monitor with Ctrl-C, restart it later -- it resumes.
- Close the laptop lid, come back after lunch -- it resumes.
- The monitoring process crashes -- nothing is lost, because the job ids were never
  only in memory.
- Copy the CSV to another machine and monitor from there -- it resumes.
- Trigger from Ansible on a jump host and monitor from a workstation -- it resumes.

That last case has been run for real: the CSV rendered by the Ansible template
(`roles/rubrik_ahv_recovery/templates/wave_state.csv.j2`) was monitored to completion
by `ahv_monitor_recovery.py --state` against a live cluster.

#### Columns: human-readable left, identifiers right

```
triggered_at, status, status_updated, vm_name, method, snapshot_date,
recovered_vm_prefix, duration_seconds, data_transferred_bytes, end_time,
message, vm_id, snapshot_id, nutanix_cluster_id, container_natural_id,
job_instance_id, event_series_id
```

The opaque ids -- managed ids with `:::` in them, snapshot UUIDs, job instance ids --
are pushed to the right so the file is scannable in a terminal or a spreadsheet
without horizontal hunting. The left-hand block answers "when did it start, how is it
going, which VM, from what snapshot, under what name, how long did it take".

There is no separate `trigger_status` column any more. The trigger outcome writes
`status` directly, and the monitor updates the same column in place, with
`status_updated` recording when it was last checked. One column, one meaning.

#### The monitor writes back into it, on every poll

The contract is not read-only. `monitor_core.persist_state()` patches
`event_series_id`, `status`, `status_updated`, `end_time`, `duration_seconds`,
`data_transferred_bytes`, and `message` back into the file after **every** poll, not
once at the end. Three things follow:

- **No repeated event-series resolution.** `event_series_id` is empty at trigger time
  because the event series does not exist yet. The monitor resolves it with a per-VM
  `GET /api/v1/event/latest` lookup on its first poll and caches it, so a restart
  skips N lookups that get slower the larger the wave.
- **The file is a live progress view.** It is small, it is rewritten each poll, and it
  outlives the monitor process. Another operator can read it and see where the wave
  is without touching the cluster.
- **A restarted monitor keeps what already finished.** Records that come back terminal
  are not re-polled, and their durations and outcomes still appear in the final
  summary instead of leaving holes.

The write-back is deliberately conservative. It patches the existing file cell by
cell rather than rewriting it from the monitor's in-memory records, so columns the
monitor does not track -- `container_natural_id`, `recovered_vm_prefix`,
`snapshot_id` -- are preserved untouched. Rows are matched on `job_instance_id`
first, falling back to `vm_id`. A state file written before these columns existed is
upgraded in place: any missing column is appended to the header, so the 13-column
files the earlier trigger wrote still work. It only writes non-empty values, it skips
rows that would not change, and it never raises -- a read or write failure is logged
and the monitor carries on, because a caching optimisation must never be able to take
down a live recovery.

`WAVE_STATE_FIELDS` lives in `monitor_core.py` for this reason -- the monitor needs
the schema to patch the file, and importing the trigger script to get it would be
backwards. `ahv_mass_recovery.py` re-exports the same list, so both writers stay in
lockstep by construction rather than by convention.

### The monitoring engine is generic, the schemas are not

`monitor_core.py` (formerly `ahv_monitor.py`) is a CDM **event-series** engine, not an
AHV one. Resolution, polling, status classification, terminal detection, metrics
aggregation and the summary all work for any snappable and any task type;
`discover_from_vm_ids()` even takes an `event_type` parameter, defaulting to
`"Recovery"`. The only AHV-recovery-specific things in the module are the two column
lists, `WAVE_STATE_FIELDS` and `RESULT_FIELDS`, which live there so the trigger and
the monitor share one definition. Nothing else in the module depends on their
contents.

### Fail fast on a missing container or prefix

A missing target container or recovered-VM prefix used to surface as a per-VM
exclusion at the very *end* of resolution -- after the VM lookup, the snapshot call
and the container listing had all run -- so forgetting one flag cost a full round trip
just to be told nothing was recoverable.

Both are now checked immediately after the wave CSV is read and **before the cluster
is even connected to**. With `--force` a missing value is a hard error naming the flag
and the CSV column; without it, the operator is prompted. An unrecognised container
name is also a hard error rather than a silent per-VM exclusion, and it prints the
list of container names that do exist.

### Trigger and monitor are separate programs

They have completely different lifetimes. Triggering a 200-VM wave takes seconds and
either works or does not. Monitoring it takes hours and must survive interruption.
Fusing them into one long-lived process means a monitoring failure looks like a
recovery failure, and an interrupted terminal means losing track of jobs that are
still perfectly healthy on the cluster.

Separating them also means the monitor can be pointed at recoveries that this
toolkit did not start (`ahv_monitor_recovery.py --csv`, the discovery path), and can
be run repeatedly, from a cron, or with `--once` for a quick status snapshot.

`ahv_mass_recovery.py --monitor` exists for convenience on small waves, and even
then it prints the exact resume command if it gets interrupted.

### Why Ansible triggers but does not monitor

Ansible is an excellent trigger and a poor monitor, for concrete reasons:

- **`until` / `retries` / `delay` is an in-memory loop.** There is no checkpoint and
  no resume. If the process dies, every tracked `jobInstanceId` dies with it.
- **`.retry` files do not help.** They record failed host names, not job state. There
  is no job id in them to resume from.
- **`async` / `async_status` is the wrong tool.** It is designed for long-running
  commands *on a remote host*. Our `uri` call returns in milliseconds; wrapping it in
  `async` adds machinery without adding durability.
- **Task output is buffered.** A `retries: 480` poll prints absolutely nothing for
  hours, then dumps everything at the end. During a live recovery event that is worse
  than useless.
- **Closing the terminal sends SIGHUP and kills the run.** No resume, no record.

So Ansible does the part it is good at (declarative wave definitions, idempotent
resolution, `--check` as a real dry run, one POST per chunk) and stops. An optional
bounded wait exists for smoke tests (`ahv_monitor_wait_minutes`, default `0`), and
its own task file documents why you should leave it at `0`.

### Ansible's per-VM name lookup is serial, and that shapes the advice

When no `ahv_inventory_csv` is supplied, the role resolves VM names with one small
name-filtered GET per VM. That loop is **serial**. Ansible parallelises across hosts
via `forks`, never across `loop` items, and this play runs on a single host
(`localhost`), so `forks` buys nothing here -- the requests go out one at a time.

Rough guidance, and these are estimates rather than measurements: fine for tens of
VMs, and minutes of wall clock for 500 or more. Setting `ahv_inventory_csv` reduces
resolution to **zero API calls**, which is the intended path at scale. The per-VM
lookup exists so the role still works without a current inventory CSV, not as the
recommended way to run a large wave.

Only a two-VM wave has been run against a live cluster, which says nothing useful
about 500.

### Ansible settings belong in an extra-vars file, and the inventory must be named

A real invocation needs cluster, credentials, container, and prefix at minimum, and
retyping `-e` flags per run is both tedious and a good way to fire a wave at the wrong
container. So `vars/example-recovery-vars.yml` ships as a committed template:

```bash
cp vars/example-recovery-vars.yml vars/my-recovery.yml
$EDITOR vars/my-recovery.yml
ansible-playbook -i inventory/<wave>.yml ahv_mass_recovery.yml -e @vars/my-recovery.yml
```

`.gitignore` covers `ansible/vars/*.yml` with a negation that keeps the example file,
so personal copies are never committed by accident. A later `-e` overrides the file
(`-e @vars/my-recovery.yml -e ahv_method=export`), which makes one reviewed settings
file plus one deliberate override the normal shape of a run. For inline credentials
rather than a service-account JSON path, `ansible-vault encrypt vars/my-recovery.yml`
and run with `--ask-vault-pass`. The playbook header leads with this pattern.

`ansible.cfg` deliberately does **not** set `inventory = inventory/`. Ansible merges
every file in an inventory directory, so a bare run would silently combine `wave1`,
`wave2` and `tier0` into one group and recover all of them. The wave has to be named
on the command line: `-i inventory/<wave>.yml`. That is also what gives the run its
wave name, and therefore the name of its state file.

### Status is classified by prefix, not a hardcoded enum

The reference capture contains no failed or cancelled run, so the exact terminal
strings this CDM version emits were unknown when the classifier was written.

Hardcoding an enum from an incomplete sample would mean silently misclassifying the
one case that matters most during a recovery event. Instead, `classify_status()`
matches on prefix:

| Prefix (case-insensitive) | Classified as |
|---|---|
| `Success...` (`Success`, `SuccessWithWarnings`) | succeeded |
| `Fail...` | failed |
| `Cancel...` | cancelled |
| `Queued`, `Scheduled` | queued |
| anything else, including empty | running (still in flight) |

That decision has already paid off. The first terminal string seen live beyond
`Success` was `Canceled`, spelled with one `l` -- an enum written as `Cancelled` would
have classified a cancelled export as still running.

The raw string is preserved verbatim in the `raw_status` column of the results CSV,
so an unexpected value is visible rather than swallowed. A job with no
`terminatedEventSeriesStatus` yet is `running` when its progress is above zero and
`queued` otherwise.

### Chunking

A 2-VM `batch_export` took **6.7 seconds** in the reference capture. Extrapolating,
a single 50-VM call is a plausible way to hit a request timeout and lose visibility
into whether the cluster accepted the batch. So both the snapshot-resolution call
and the trigger call are chunked, default 25 VMs per call, configurable
(`--chunk_size` / `ahv_chunk_size`). Each chunk's results are written to the
wave-state CSV as soon as it returns, so a timeout on chunk 4 does not cost you
chunks 1 through 3.

### Stdlib only, Python 3.6 compatible

These scripts get copied onto jump hosts, bastion VMs, and whatever machine happens
to have network access to the cluster during an incident. "Please pip install
requests first" is not an acceptable prerequisite in the middle of a recovery.
Everything uses `urllib.request`, `ssl`, `csv`, `argparse`, `concurrent.futures`,
and `threading`. Formatting is percent-style and there are no type hints, so the
scripts run on the older Python 3 shipped with long-lived enterprise Linux images.

The one place that needed care is timestamps. `datetime.utcnow()` is deprecated from
Python 3.12, so both the trigger and the monitor use a small helper built on
`datetime.now(timezone.utc).replace(tzinfo=None)`, which exists from 3.2 and is
therefore warning-free on modern interpreters while staying inside the 3.6 floor.

### A bare run teaches you the flags

Running any of the four scripts with **no arguments** is still fully interactive, but
before the first prompt it prints two complete, copy-pasteable commands and a one-line
note, then carries on prompting (`ahv_common.show_examples_if_bare()`). Interactive
mode is a fine default, but on its own it gives no hint what the non-interactive form
looks like, so anyone wanting to script the tool had to go and read `--help` first.

`--help` itself is grouped rather than being one flat wall of flags. For
`ahv_mass_recovery.py` the groups are `REQUIRED -- authentication`,
`REQUIRED -- what to recover, and where it lands`, `snapshot selection`,
`recovery target -- optional`, `staged lookups -- optional`,
`monitoring -- optional`, `behaviour -- optional`, and `tuning -- optional`. The two
REQUIRED groups are the ones that decide what happens to the cluster.

`get_ahv_inventory.py` goes one step further and ends its run by printing two
ready-to-run `ahv_mass_recovery.py` commands built from that run's real values -- the
cluster it just talked to, the service-account path it was given, and an actual
container name off the cluster -- one `--dry_run` and one for real.

### The inventory CSV doubles as the wave template

`get_ahv_inventory.py` writes 21 columns, and the last two --
`target_container_name` and `recovered_vm_prefix` -- are **deliberately blank**.
Nothing on the cluster can fill them in, because they are recovery decisions.

That turns one file into two jobs. The operator opens the inventory CSV, filters it
to the VMs in this wave, optionally types the target container and name prefix into
the two empty columns, saves it as `wave1.csv`, and feeds it straight to
`ahv_mass_recovery.py`. No format conversion, no second template to keep in sync.
Both values can also be supplied globally with `--container` and
`--recovered_vm_prefix`, in which case the columns act as per-VM overrides.

### VMs with no snapshot are excluded, never dropped

`closest_to_point_in_time` simply omits snappables that have no snapshot at or
before the requested time. Treating that silence as "nothing to do" would mean a VM
quietly missing from a DR test.

Instead every excluded VM is written to `logs/<wave>_excluded_<ts>.csv` with a reason
(`No snapshot at or before <time>`, `VM not found on cluster`, `Container '<name>'
not found on the target AHV cluster`, and so on), counted in the preview, and shown
before the confirmation prompt. You always know exactly what is not being recovered
and why.

The snapshot phase also reports per VM rather than only in aggregate: a
`[chunk N/M] Requesting snapshots for K VM(s)...` line for each batched call, then
one `[i/total] <vm name>  snapshot <date>` line -- or
`NO SNAPSHOT at or before ...` -- per VM as the results are unpacked.

### Cleanup is scoped by source VM, and shows you what else is mounted

`ahv_cleanup_mounts.py --state` / `--csv` matches **every** live mount whose source VM
is named in the file. It does not filter by prefix, and that is deliberate: one source
VM can carry mounts from several recovery runs plus hand-made mounts somebody created
in the UI, and they all share the same source VM id. Hiding the ones this wave did not
create would leave the operator tearing down a DR test while stale mounts of the same
VMs quietly survive.

So the preview lists them all with an `ORIGIN` column, labelling each mount
`this wave` when its name matches a `recovered_vm_prefix` recorded in the wave file
and `other` when it does not, and it warns when any are `other`. Exactly this happened
on the live test: three mounts across two source VMs, two `this wave` and one `other`,
the last being a pre-existing UI mount. `--mounted_name_prefix` narrows the set
explicitly when you really do want only the mounts matching a name prefix.

`--list_only` is read-only, so it no longer demands the "Unmount ALL?" confirmation;
with no scope given it simply shows every AHV live mount on the cluster.

---

## Status: verified against a live cluster

The toolkit has been run end to end against a real Rubrik CDM cluster with one
registered AHV cluster, five storage containers, and a small VM estate.

### Verified working

- Service-account authentication against `POST /api/v1/service_account/session`.
- AHV cluster listing, storage container listing, and the full paginated VM listing.
- Parallel per-VM detail fetch (`--detail`), including provisioned-capacity totals.
- Snapshot resolution via `closest_to_point_in_time`.
- `batch_mount` triggered from the **Ansible** role: 2 of 2 VMs accepted, 0 failed.
  A `batch_export` wave was later triggered the same way and ran for ten minutes
  before being cancelled.
- The whole monitoring chain: `event/latest` -> `event_series/status` ->
  `event_series/{id}`.
- Per-VM durations computed from event timestamps: **1m 06s** and **1m 08s** for the
  two mounted VMs, **10m 40s** and **10m 43s** for the cancelled exports.
- Terminal status classification against a real terminal string: the cluster returned
  `Canceled` (one `l`), which the prefix matcher mapped to `cancelled`. A hardcoded
  enum spelled `Cancelled` would have missed it.
- The live per-VM table, including `ELAPSED` ticking up for in-flight VMs and the
  `SIZE` column populated from the inventory CSV.
- The Ansible-to-Python wave-state handoff: the CSV the Jinja template rendered was
  read and monitored by `ahv_monitor_recovery.py --state` without modification.
- The monitor patching `event_series_id`, `status`, `status_updated`, `end_time` and
  `duration_seconds` back into that Ansible-written CSV.
- The staged-CSV path: a wave resolved with **zero** VM-lookup and container-lookup
  API calls, logging `Resolved entirely from the staged CSV`.
- Live mount listing via `GET /api/v1/nutanix/vm/snapshot/mount`, including the
  `ORIGIN` labelling of mounts that did not come from the wave.

### Transfer metrics are job-type dependent

Whether the cluster reports transferred bytes depends on the job type, and both
answers have now been observed:

| Job type | `dataTransferred` | Observed |
|---|---|---|
| `MOUNT_NUTANIX_SNAPSHOT` (live mount) | **Not reported** | Neither is `logicalSize` or `throughput`, across a completed two-VM mount wave. |
| `MULTI_NODE_EXPORT_NUTANIX_SNAPSHOT` (export) | **Reported** | `42949672960` (40.0 GiB) on one VM of a two-VM export wave. It was absent on the first polls and appeared partway through the run; the second VM of the same wave never reported one at all. |

So the metrics are best effort per job, not universally absent and not universally
present. When nothing in the wave reports a byte count, the results CSV columns stay
blank, the `TRANSFERRED` column is dropped from the live table, the longest and
shortest lines read `n/a transferred`, and the summary prints
`Transfer metrics: not reported by the cluster for this job type` instead of a
misleading zero. That behaviour was observed working on the mount wave.

One more wrinkle from the export run: a cancelled job reported a **negative**
throughput (`-162142765`). Negative `logicalSize`, `dataTransferred` and `throughput`
values are now discarded rather than recorded or displayed.

Durations do not depend on any of this. They are computed from event-series
timestamps and are always available, for every job type.

### Still unverified

- **The unmount `DELETE /api/v1/nutanix/vm/snapshot/mount/{mountId}` path.** Mount
  *listing* works; the delete is still inferred from Rubrik CDM mount API convention
  and has not been executed. Run `ahv_cleanup_mounts.py --list_only` first. If listing
  works but deletes return 404 or 405, the path needs correcting in
  `cdm_client.delete_vm_mount()`.
- **A successful export.** An export wave was triggered, ran, and was cancelled before
  it finished, so the trigger and monitoring paths for `export` are exercised but a
  completed export is not.
- **`ahv_monitor_recovery.py --cancel` itself.** A cancellation was observed and
  classified correctly, but nothing in the toolkit's logs records this script as the
  thing that issued it.
- **The batched comma-joined `object_ids` form of `/api/v1/event/latest`.** Event
  series resolved correctly on the live wave, but the monitor's fallback to per-VM
  calls is silent inside the poll loop, so the logs do not record which form
  succeeded. Correctness never depends on it: the batched form is attempted once and
  anything missing falls through to parallel per-VM lookups.
- **Anything at scale.** The live wave was two VMs. Chunking, pagination and the
  serial Ansible lookup loop are all untested above single digits.
- **Any failure path.** Nothing has failed yet, so no terminal *failure* string has
  been observed from this CDM version. The cancelled case is now on record
  (`Canceled`).

### Operational warning: recovered VMs come back in the inventory

**Live-mounted VMs appear in the AHV inventory as first-class VMs.** After the two-VM
test recovery the inventory went from 8 VMs to 11, now including `dr--sh2-ntnx-w1`,
`dr--sh2-ntnx-w2`, and a pre-existing mount created through the UI.

The consequence is direct: a wave built from an inventory taken *after* a recovery,
without filtering, will happily recover the recovered VMs. Before building the next
wave, either rebuild the inventory after tearing the mounts down, or filter out
anything carrying a recovery prefix. Nothing in the toolkit does this for you --
`get_ahv_inventory.py` reports what the cluster reports.

---

## Known limitations

### No NIC, vCPU, memory, or per-disk storage container from CDM REST

`GET /api/internal/nutanix/vm/{id}` returns SLA fields, cluster name and id,
`operatingSystemType`, `agentStatus`, `isPaused`, `isAgentRegistered`,
`excludedDiskIds`, `snapshotConsistencyMandate`, and
`virtualDisks[{sizeInBytes, deviceType, isSnapshottable, vmDiskUuid, label}]`.

It does not return NICs, VLANs, vCPU count, memory, or each disk's storage
container. Across the entire 52-call capture, `networkName`, `vlan`, `numVcpus`, and
`memory` appear zero times.

This does not block recovery -- `exportConfig` and `mountConfig` accept only
`nutanixClusterId`, `containerNaturalId`, and `vmNamePrefix`, and Rubrik restores NIC
configuration from the snapshot itself. It does limit the inventory report.

Those fields **do** exist in the RSC GraphQL schema (`NutanixVm.metadata.vmNics`,
`numVcpus`, `memoryInMb`, and `NutanixVmDisk.storageContainerId`), and an RSC GraphQL
inventory backend is planned as the default source. See
[`PLAN-graphql-inventory.md`](PLAN-graphql-inventory.md) and the
`PLANNED: RSC GraphQL backend` block in the header of `python/get_ahv_inventory.py`,
including the trap that the VM id embeds the Nutanix cluster's CDM UUID and not its
`naturalId`.

### Power state, guest IP, and MAC addresses are unavailable from BOTH sources

Not a CDM gap -- a genuine gap. `powerStatus` was verified absent from `NutanixVm` in
the RSC GraphQL schema; it exists only on mount-side types (`NutanixLiveMount`,
`NutanixVmMountSummary`). Guest IP and MAC addresses are likewise unavailable from
CDM REST and from RSC GraphQL. No inventory column will ever carry them from either
backend, so the scripts do not pretend otherwise.

---

## Requirements

- Python 3.6 or later. No third-party packages.
- Ansible core only, if using the Ansible path. No external collections needed.
- An RSC Service Account JSON file (`client_id` + `client_secret`), or those two
  values directly. The session token is issued by the **CDM cluster**, not by RSC --
  `access_token_uri` in the JSON is ignored.
- Network access to the CDM cluster on HTTPS. Self-signed certificates are expected
  and certificate validation is off by default.
