#!/usr/bin/env python3
"""
Rubrik CDM event-series monitoring engine.

Generic to any CDM event series, not just AHV recovery: the resolution,
polling, status classification and metrics aggregation here work for any
snappable and any task type. Callers supply records and choose the event type
they care about.

A record is a plain dict. The engine reads and writes these keys:

    vm_id                   object id, used to look up events
    vm_name                 label for output only
    job_instance_id         from the trigger response
    event_series_id         resolved here, then cached by the caller
    status                  queued | running | succeeded | failed | cancelled
    status_updated          when the status was last checked
    start_time, end_time, duration_seconds
    logical_size_bytes, data_transferred_bytes, throughput_bytes_per_sec

The monitoring chain, verified against the reference API capture:

  1. A trigger call returns asyncRequestStatus.id, which IS the jobInstanceId.
  2. GET /api/v1/event/latest?object_ids=<id> -- match on
     latestEvent.jobInstanceId to learn the eventSeriesId.
  3. POST /api/internal/event_series/status with [{id, jobInstanceId}, ...] --
     batched poll returning progress, terminatedEventSeriesStatus, and the
     metrics fields logicalSize / dataTransferred / throughput.
  4. GET /api/v1/event_series/{id} -- fetched once per object on transition to
     a terminal state, for the end time and any failure message.

WAVE_STATE_FIELDS and RESULT_FIELDS below are the AHV recovery schemas. They
live here so the trigger and the monitor share one definition; nothing else in
this module depends on their contents.

Stdlib only. Python 3.6 compatible.

Updated: 9/11/26 - renamed from ahv_monitor.py; generic event-series engine
"""

import concurrent.futures
import csv
import os
import time
from datetime import datetime, timezone

from ahv_common import (log, now_hm, parse_iso8601, format_bytes, format_duration,
                        append_csv_row, banner)

# Columns of the wave-state CSV -- the durable handoff between the trigger
# phase (Python or Ansible) and any later monitor run. Defined here rather
# than in ahv_mass_recovery.py so the monitor can patch the file in place
# without importing the trigger script.
# Human-readable columns first so the file is scannable in a terminal or a
# spreadsheet; opaque identifiers are pushed to the right.
#
# status starts as the trigger outcome and is then updated in place by the
# monitor, with status_updated recording when it was last checked. Persisting
# the outcome is what lets a restarted monitor keep the results of VMs that
# finished before the restart, instead of re-polling them and reporting a
# summary with holes in it.
WAVE_STATE_FIELDS = [
    # When, what, and how it is going
    "triggered_at",
    "status",
    "status_updated",
    "vm_name",
    "method",
    "snapshot_date",
    "recovered_vm_prefix",
    "duration_seconds",
    "data_transferred_bytes",
    "end_time",
    "message",
    # Identifiers
    "vm_id",
    "snapshot_id",
    "nutanix_cluster_id",
    "container_natural_id",
    "job_instance_id",
    "event_series_id",
]

# Columns written to the recovery results CSV.
RESULT_FIELDS = [
    "vm_name", "vm_id", "method", "snapshot_id", "snapshot_date",
    "job_instance_id", "event_series_id", "status", "raw_status",
    "progress_pct", "start_time", "end_time", "duration_seconds",
    "logical_size_bytes", "data_transferred_bytes", "throughput_bytes_per_sec",
    "message",
]

TERMINAL_STATES = ("succeeded", "failed", "cancelled")


def classify_status(value):
    """
    Map a Rubrik status string to one of:
    queued | running | succeeded | failed | cancelled

    The reference capture contains no failed or cancelled run, so this
    matches on prefix rather than a hardcoded enum. Anything unrecognised is
    treated as still in flight and logged verbatim by the caller.
    """
    if not value:
        return "running"
    text = str(value).strip().lower()
    if text.startswith("success"):
        return "succeeded"
    if text.startswith("fail"):
        return "failed"
    if text.startswith("cancel"):
        return "cancelled"
    if text in ("queued", "scheduled"):
        return "queued"
    return "running"


def is_terminal(record):
    return record.get("status") in TERMINAL_STATES


# ---------------------------------------------------------------------------
# Event series resolution
# ---------------------------------------------------------------------------

def resolve_event_series(client, records, max_workers=8, event_limit=50, quiet=False):
    """
    Fill in event_series_id for any record that has a job_instance_id but no
    event series yet, by scanning that VM's latest events for a matching
    jobInstanceId.

    Tries the batched (comma-joined) object_ids form once; if that fails or
    comes back short, falls back to one parallel call per VM. Returns the
    number of records resolved.
    """
    pending = [r for r in records
               if r.get("job_instance_id") and not r.get("event_series_id")]
    if not pending:
        return 0

    wanted = {}
    for record in pending:
        wanted[record["job_instance_id"]] = record

    def _absorb(entries):
        found = 0
        for entry in entries or []:
            latest = entry.get("latestEvent") or {}
            job_id = latest.get("jobInstanceId")
            record = wanted.get(job_id)
            if record and not record.get("event_series_id"):
                record["event_series_id"] = latest.get("eventSeriesId") or ""
                if not record.get("start_time"):
                    record["start_time"] = latest.get("time") or ""
                if record["event_series_id"]:
                    found += 1
        return found

    resolved = 0
    vm_ids = [r["vm_id"] for r in pending if r.get("vm_id")]

    # Attempt the batched form first -- unverified across CDM versions.
    if len(vm_ids) > 1:
        try:
            resolved += _absorb(client.event_latest(object_ids=vm_ids,
                                                    limit=event_limit))
        except Exception as e:
            if not quiet:
                log("  (%s) Batched event lookup unavailable, falling back per VM: %s"
                    % (now_hm(), e))

    still_pending = [r for r in pending if not r.get("event_series_id")]
    if not still_pending:
        return resolved

    def _lookup(record):
        try:
            return client.event_latest(object_ids=record["vm_id"], limit=event_limit)
        except Exception as e:
            if not quiet:
                log("  (%s) %s - event lookup failed: %s"
                    % (now_hm(), record.get("vm_name", record.get("vm_id")), e))
            return []

    workers = min(max_workers, len(still_pending))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for entries in pool.map(_lookup, still_pending):
            resolved += _absorb(entries)

    return resolved


def persist_state(state_path, records):
    """
    Write live status and finished outcomes back into the wave-state CSV.

    Three things depend on this. Persisting event_series_id means a restarted
    monitor skips the per-VM /v1/event/latest lookup for the whole wave.
    Persisting status and status_updated makes the file a live progress view
    that survives the monitor being killed. Persisting end time, duration and
    bytes means a restarted monitor keeps the results of VMs that finished
    before the restart.

    Patches the file cell by cell rather than rewriting from the in-memory
    records, so columns the monitor does not track (container id, name prefix)
    survive untouched. A state file written before these columns existed is
    upgraded in place. Returns the number of rows changed; never raises.
    """
    if not state_path or not os.path.isfile(state_path):
        return 0

    PERSIST = ("event_series_id", "status", "status_updated", "end_time",
               "duration_seconds", "data_transferred_bytes", "message")

    by_job = {}
    by_vm = {}
    for record in records:
        patch = dict((k, record.get(k)) for k in PERSIST
                     if record.get(k) not in (None, ""))
        if not patch:
            continue
        if record.get("job_instance_id"):
            by_job[record["job_instance_id"]] = patch
        if record.get("vm_id"):
            by_vm[record["vm_id"]] = patch
    if not by_job and not by_vm:
        return 0

    try:
        with open(state_path, "r") as f:
            reader = csv.DictReader(f)
            fields = reader.fieldnames
            rows = list(reader)
    except Exception as e:
        log("  (%s) Could not read the wave-state CSV: %s" % (now_hm(), e))
        return 0

    if not fields:
        return 0

    # Upgrade a state file written before these columns existed.
    fields = list(fields)
    for column in WAVE_STATE_FIELDS:
        if column not in fields:
            fields.append(column)

    updated = 0
    for row in rows:
        patch = by_job.get((row.get("job_instance_id") or "").strip())
        if patch is None:
            patch = by_vm.get((row.get("vm_id") or "").strip())
        if not patch:
            continue
        changed = False
        for key, value in patch.items():
            if str(row.get(key) or "").strip() != str(value):
                row[key] = value
                changed = True
        if changed:
            updated += 1

    if not updated:
        return 0

    try:
        with open(state_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields)
            writer.writeheader()
            for row in rows:
                writer.writerow(dict((k, row.get(k, "")) for k in fields))
    except Exception as e:
        log("  (%s) Could not write the wave-state CSV: %s" % (now_hm(), e))
        return 0

    return updated


def discover_from_vm_ids(client, records, event_limit=50, max_workers=8,
                         quiet=False, event_type="Recovery"):
    """
    Discovery path for when no wave-state file exists: find the most recent
    event series of event_type per object and adopt it. Populates job_instance_id,
    event_series_id and start_time on each record.
    """
    def _lookup(record):
        try:
            return record, client.event_latest(object_ids=record["vm_id"], limit=event_limit)
        except Exception as e:
            if not quiet:
                log("  (%s) %s - event lookup failed: %s"
                    % (now_hm(), record.get("vm_name", record.get("vm_id")), e))
            return record, []

    found = 0
    workers = min(max_workers, max(1, len(records)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for record, entries in pool.map(_lookup, records):
            best = None
            best_time = None
            for entry in entries or []:
                latest = entry.get("latestEvent") or {}
                if event_type and (latest.get("eventType") or "") != event_type:
                    continue
                stamp = parse_iso8601(latest.get("time"))
                if best is None:
                    best, best_time = latest, stamp
                elif stamp is not None and (best_time is None or stamp > best_time):
                    best, best_time = latest, stamp
            if best:
                record["job_instance_id"] = best.get("jobInstanceId") or ""
                record["event_series_id"] = best.get("eventSeriesId") or ""
                record["start_time"] = best.get("time") or ""
                record["message"] = "discovered from event history"
                found += 1
    return found


# ---------------------------------------------------------------------------
# Polling
# ---------------------------------------------------------------------------

def poll_once(client, records, chunk_size=100):
    """
    One batched status poll across every record that has both ids. Updates
    each record in place. Returns the list of records that newly reached a
    terminal state during this poll.
    """
    pairs = []
    by_job = {}
    for record in records:
        if is_terminal(record):
            continue
        job_id = record.get("job_instance_id")
        series_id = record.get("event_series_id")
        if not job_id or not series_id:
            continue
        pairs.append({"id": series_id, "jobInstanceId": job_id})
        by_job[job_id] = record

    stamp = _iso_now()
    newly_terminal = []
    for i in range(0, len(pairs), chunk_size):
        chunk = pairs[i:i + chunk_size]
        try:
            entries = client.event_series_status(chunk)
        except Exception as e:
            log("  (%s) Status poll failed for %d job(s): %s" % (now_hm(), len(chunk), e))
            continue

        for entry in entries or []:
            record = by_job.get(entry.get("jobInstanceId"))
            if record is None:
                continue

            terminated = entry.get("terminatedEventSeriesStatus")
            record["status_updated"] = stamp
            record["progress_pct"] = _clean_progress(entry.get("progress"))

            # A cancelled job can report a negative throughput (observed
            # -162142765), which is meaningless -- drop it rather than print it.
            for field, dest in (("logicalSize", "logical_size_bytes"),
                                ("dataTransferred", "data_transferred_bytes"),
                                ("throughput", "throughput_bytes_per_sec")):
                value = entry.get(field)
                if value is None:
                    continue
                try:
                    if float(value) < 0:
                        continue
                except (TypeError, ValueError):
                    pass
                record[dest] = value

            if terminated:
                record["raw_status"] = terminated
                record["status"] = classify_status(terminated)
                if is_terminal(record):
                    newly_terminal.append(record)
            else:
                progress = record.get("progress_pct")
                try:
                    started = float(progress) > 0
                except (TypeError, ValueError):
                    started = False
                record["status"] = "running" if started else "queued"
                record["raw_status"] = "InProgress"

    return newly_terminal


def _clean_progress(value):
    """CDM returns progress as a string like '.00' or '100.00'."""
    if value in (None, ""):
        return ""
    try:
        return "%.2f" % float(value)
    except (TypeError, ValueError):
        return str(value)


def finalize_records(client, records, max_workers=8):
    """
    For records that just reached a terminal state, fetch the event series
    detail to capture the end time, computed duration, and any failure
    message from eventDetailList.
    """
    if not records:
        return

    def _detail(record):
        try:
            return record, client.get_event_series(record["event_series_id"])
        except Exception as e:
            log("  (%s) %s - could not read event series detail: %s"
                % (now_hm(), record.get("vm_name", ""), e))
            return record, None

    workers = min(max_workers, len(records))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for record, detail in pool.map(_detail, records):
            if not detail:
                continue
            if detail.get("startTime"):
                record["start_time"] = detail["startTime"]

            events = detail.get("eventDetailList") or []
            end_stamp = None
            for event in events:
                stamp = parse_iso8601(event.get("time"))
                if stamp and (end_stamp is None or stamp > end_stamp):
                    end_stamp = stamp
            if end_stamp:
                record["end_time"] = _iso(end_stamp)

            start_stamp = parse_iso8601(record.get("start_time"))
            if start_stamp and end_stamp:
                record["duration_seconds"] = int((end_stamp - start_stamp).total_seconds())

            message = _last_message(events, record.get("status"))
            if message:
                record["message"] = message


def _iso_now():
    """Naive UTC now in Rubrik's ISO-8601 Z form."""
    return _iso(datetime.now(timezone.utc).replace(tzinfo=None))


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + ("%03d" % (dt.microsecond // 1000)) + "Z"


def _last_message(events, status):
    """Pull a human-readable message out of eventDetailList, failures first."""
    import json as _json

    chosen = None
    for event in events:
        severity = (event.get("eventSeverity") or "").lower()
        estatus = (event.get("eventStatus") or "").lower()
        if status == "failed" and (severity in ("critical", "error") or estatus.startswith("fail")):
            chosen = event
            break
    if chosen is None and events:
        chosen = events[-1]
    if chosen is None:
        return ""

    info = chosen.get("eventInfo")
    if isinstance(info, str) and info.strip().startswith("{"):
        try:
            return (_json.loads(info).get("message") or "").strip()
        except ValueError:
            return info.strip()
    return (chosen.get("eventName") or "").strip()


# ---------------------------------------------------------------------------
# Monitor loop
# ---------------------------------------------------------------------------

def monitor(client, records, poll_interval=30, once=False, results_path=None,
            max_polls=None, state_path=None):
    """
    Poll until every record is terminal (or one pass if once=True).

    Writes each record to results_path as it finalizes, so a crash mid-run
    still leaves a usable results CSV. When state_path is supplied, the
    wave-state CSV is refreshed on every poll, so it doubles as a live
    progress view and a restarted monitor resumes without re-resolving event
    series or losing already-finished results. Returns True if everything
    reached a terminal state.
    """
    written = set()
    polls = 0

    while True:
        polls += 1
        resolve_event_series(client, records, quiet=True)
        newly_terminal = poll_once(client, records)
        finalize_records(client, newly_terminal)

        # Refresh the wave-state CSV every poll. It is small, and keeping it
        # current means the file doubles as a live progress view that outlives
        # the monitor process.
        if state_path:
            persist_state(state_path, records)

        if results_path:
            for record in newly_terminal:
                key = record.get("job_instance_id") or record.get("vm_id")
                if key not in written:
                    append_csv_row(results_path, RESULT_FIELDS, record)
                    written.add(key)

        counts = count_by_status(records)
        render_table(records)
        log("  (%s) queued %d | running %d | succeeded %d | failed %d | cancelled %d"
            % (now_hm(), counts["queued"], counts["running"], counts["succeeded"],
               counts["failed"], counts["cancelled"]))

        outstanding = [r for r in records if not is_terminal(r)]
        if not outstanding:
            return True
        if once:
            return False
        if max_polls is not None and polls >= max_polls:
            log("  (%s) Reached the poll limit with %d recovery(s) still in flight."
                % (now_hm(), len(outstanding)))
            return False

        log("  (%s) %d still running. Next poll in %ds. Ctrl-C is safe -- state is on disk."
            % (now_hm(), len(outstanding), poll_interval))
        time.sleep(poll_interval)


def count_by_status(records):
    counts = {"queued": 0, "running": 0, "succeeded": 0, "failed": 0,
              "cancelled": 0, "unknown": 0}
    for record in records:
        status = record.get("status") or "unknown"
        if status not in counts:
            status = "unknown"
        counts[status] += 1
    return counts


def elapsed_seconds(record):
    """
    How long this VM has been going.

    Terminal records carry a real duration computed from event timestamps.
    In-flight ones get now-minus-start, so the table shows a live clock
    instead of a blank column -- and it costs nothing, because start_time is
    already known from the trigger response.
    """
    if record.get("duration_seconds") not in (None, ""):
        try:
            return int(float(record["duration_seconds"]))
        except (TypeError, ValueError):
            return None
    start = parse_iso8601(record.get("start_time"))
    if not start:
        return None
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    return max(0, int((now - start).total_seconds()))


def _clock(value):
    """ISO timestamp -> HH:MM:SS for the table."""
    stamp = parse_iso8601(value)
    return stamp.strftime("%H:%M:%S") if stamp else ""


def render_table(records, limit=40):
    """Per-VM status table. Truncated so a 500-VM wave stays readable."""
    # Only show columns the cluster actually populates. dataTransferred is not
    # reported for AHV recovery jobs, so the column would be dead weight.
    show_transferred = any(r.get("data_transferred_bytes") not in (None, "")
                           for r in records)
    show_size = any(r.get("provisioned_bytes") not in (None, "") for r in records)

    header = "  %-26s %-11s %7s %9s %10s" % ("VM", "STATUS", "PROGR", "STARTED", "ELAPSED")
    if show_size:
        header += " %10s" % "SIZE"
    if show_transferred:
        header += " %13s" % "TRANSFERRED"
    log("")
    log(header)
    log("  %s" % ("-" * (len(header) - 2)))

    for record in records[:limit]:
        name = (record.get("vm_name") or record.get("vm_id") or "")[:26]
        progress = record.get("progress_pct")
        progress = ("%s%%" % progress) if progress not in (None, "") else ""
        line = "  %-26s %-11s %7s %9s %10s" % (
            name,
            record.get("status") or "pending",
            progress,
            _clock(record.get("start_time")),
            format_duration(elapsed_seconds(record)),
        )
        if show_size:
            line += " %10s" % (format_bytes(record.get("provisioned_bytes")) or "")
        if show_transferred:
            line += " %13s" % (format_bytes(record.get("data_transferred_bytes")) or "--")
        log(line)

    if len(records) > limit:
        log("  ... and %d more" % (len(records) - limit))


# ---------------------------------------------------------------------------
# Metrics summary
# ---------------------------------------------------------------------------

def build_summary(records, monitor_seconds, title="SUMMARY"):
    """
    Aggregate metrics across the wave. Returns a list of lines for log().

    Duration and transfer stats are computed only over records that actually
    reported those values, so a missing dataTransferred never silently skews
    an average.
    """
    total = len(records)
    counts = count_by_status(records)
    succeeded = counts["succeeded"]
    in_flight = counts["queued"] + counts["running"] + counts["unknown"]

    lines = banner(title)
    lines.append("  Total VMs:                 %d" % total)
    lines.append("  Succeeded:                 %d" % succeeded)
    lines.append("  Failed:                    %d" % counts["failed"])
    lines.append("  Cancelled:                 %d" % counts["cancelled"])
    lines.append("  Still in progress:         %d" % in_flight)

    finished = succeeded + counts["failed"] + counts["cancelled"]
    if finished:
        lines.append("  Success rate:              %.1f%% (%d of %d completed)"
                     % (100.0 * succeeded / finished, succeeded, finished))
    else:
        lines.append("  Success rate:              n/a (nothing completed yet)")

    timed = [r for r in records if _num(r.get("duration_seconds")) is not None]
    if timed:
        timed.sort(key=lambda r: _num(r.get("duration_seconds")))
        shortest, longest = timed[0], timed[-1]
        avg = sum(_num(r.get("duration_seconds")) for r in timed) / float(len(timed))
        lines.append("")
        lines.append("  Longest VM:                %s (%s, %s transferred)" % (
            longest.get("vm_name", ""),
            format_duration(longest.get("duration_seconds")),
            format_bytes(longest.get("data_transferred_bytes")) or "n/a"))
        lines.append("  Shortest VM:               %s (%s, %s transferred)" % (
            shortest.get("vm_name", ""),
            format_duration(shortest.get("duration_seconds")),
            format_bytes(shortest.get("data_transferred_bytes")) or "n/a"))
        lines.append("  Average duration:          %s (over %d VM(s))"
                     % (format_duration(avg), len(timed)))

    sized = [r for r in records if _num(r.get("data_transferred_bytes")) is not None]
    if sized:
        sized.sort(key=lambda r: _num(r.get("data_transferred_bytes")))
        smallest, largest = sized[0], sized[-1]
        total_bytes = sum(_num(r.get("data_transferred_bytes")) for r in sized)
        lines.append("")
        lines.append("  Largest transfer:          %s (%s)" % (
            largest.get("vm_name", ""), format_bytes(largest.get("data_transferred_bytes"))))
        lines.append("  Smallest transfer:         %s (%s)" % (
            smallest.get("vm_name", ""), format_bytes(smallest.get("data_transferred_bytes"))))
        lines.append("  Average transferred:       %s"
                     % format_bytes(total_bytes / float(len(sized))))
        lines.append("  Total transferred:         %s (over %d VM(s))"
                     % (format_bytes(total_bytes), len(sized)))
    else:
        lines.append("")
        lines.append("  Transfer metrics:          not reported by the cluster for this job type")

    starts = [parse_iso8601(r.get("start_time")) for r in records]
    starts = [s for s in starts if s]
    ends = [parse_iso8601(r.get("end_time")) for r in records]
    ends = [e for e in ends if e]
    lines.append("")
    if starts:
        first = min(starts)
        last = max(ends) if len(ends) == len(records) and ends else \
            datetime.now(timezone.utc).replace(tzinfo=None)
        lines.append("  Wave started:              %s UTC" % first.strftime("%Y-%m-%d %H:%M:%S"))
        if ends and len(ends) == len(records):
            lines.append("  Wave finished:             %s UTC"
                         % max(ends).strftime("%Y-%m-%d %H:%M:%S"))
        lines.append("  Wave elapsed:              %s (first trigger to %s)"
                     % (format_duration((last - first).total_seconds()),
                        "last finish" if (ends and len(ends) == len(records)) else "now"))
    lines.append("  Monitor ran for:           %s" % format_duration(monitor_seconds))
    return lines


def _num(value):
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None
