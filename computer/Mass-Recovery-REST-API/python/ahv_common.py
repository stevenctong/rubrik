#!/usr/bin/env python3
"""
Shared helpers for the AHV mass recovery scripts: logging, CLI prompting,
credential loading, CSV helpers, and value formatting.

Mirrors the logging and CLI conventions established in
python/host-delete/cdm_delete_hosts.py so all of these scripts behave the
same way at the terminal.

Stdlib only. Python 3.6 compatible.

Updated: 9/9/26 - initial version
"""

import csv
import glob
import json
import os
import re
import sys
import textwrap
import threading
import time
from datetime import datetime

# ---------------------------------------------------------------------------
# Logging infrastructure
# ---------------------------------------------------------------------------

_print_lock = threading.Lock()
_log_file = None


def now_hm():
    return datetime.now().strftime("%H:%M")


def run_timestamp():
    """One timestamp per run, shared by every output file."""
    return datetime.now().strftime("%Y%m%d_%H%M%S")


INVENTORY_DIRNAME = "inventory"


def inventory_dir_for(script_file):
    """inventory/ beside the script -- generated CSVs land here, not loose."""
    path = os.path.join(os.path.dirname(os.path.abspath(script_file)),
                        INVENTORY_DIRNAME)
    os.makedirs(path, exist_ok=True)
    return path


def log_dir_for(script_file):
    """logs/ resolved next to the script, not the cwd."""
    path = os.path.join(os.path.dirname(os.path.abspath(script_file)), "logs")
    os.makedirs(path, exist_ok=True)
    return path


def open_log(path, header_lines):
    """Open the activity log and write its header block."""
    global _log_file
    _log_file = open(path, "w")
    for line in header_lines:
        _log_file.write(line + "\n")
    _log_file.write("\n")
    _log_file.flush()
    return _log_file


def close_log():
    global _log_file
    if _log_file:
        try:
            _log_file.close()
        except Exception:
            pass
        _log_file = None


def log(msg):
    """Write to console and the activity log. Never raises."""
    with _print_lock:
        print(msg)
        if _log_file:
            try:
                _log_file.write(msg + "\n")
                _log_file.flush()
            except Exception:
                pass


def print_lock():
    return _print_lock


# ---------------------------------------------------------------------------
# CLI helpers
# ---------------------------------------------------------------------------

def show_examples_if_bare(script_name, examples, note=None):
    """
    When a script is run with no arguments at all, show a couple of complete
    command lines before dropping into the interactive prompts.

    Interactive mode is a fine default, but it gives no hint of what the
    non-interactive form looks like -- so anyone wanting to script the tool
    has to go read --help first. This prints the shape up front and then
    carries on prompting, rather than exiting.
    """
    if len(sys.argv) > 1:
        return

    print()
    print("  No arguments given, so this run is interactive.")
    print("  To run it without prompts:")
    print()
    for example in examples:
        for line in example:
            print("    %s" % line)
        print()
    if note:
        for line in textwrap.wrap(note, width=70):
            print("  %s" % line)
        print()
    print("  All options:  python3 %s --help" % script_name)
    print("-" * 60)


def prompt_if_missing(value, prompt_text, clean=False, required=False):
    if value:
        return value
    while True:
        result = input(prompt_text).strip()
        if clean:
            from cdm_client import clean_input
            result = clean_input(result)
        if result or not required:
            return result
        print("  Value cannot be empty. Please try again.")


def prompt_int_if_missing(value, prompt_text, default, min_val=None, max_val=None):
    if value is not None:
        result = value
    else:
        raw = input(prompt_text).strip()
        result = int(raw) if raw.isdigit() else default
    if min_val is not None:
        result = max(min_val, result)
    if max_val is not None:
        result = min(max_val, result)
    return result


def confirm(prompt_text):
    """Require the full word 'yes'."""
    answer = input(prompt_text).strip().lower()
    return answer == "yes"


def load_json_credentials(json_path):
    """Read client_id / client_secret from an RSC Service Account JSON."""
    with open(json_path, "r") as f:
        data = json.load(f)
    client_id = data.get("client_id")
    client_secret = data.get("client_secret")
    if not client_id or not client_secret:
        missing = []
        if not client_id:
            missing.append("client_id")
        if not client_secret:
            missing.append("client_secret")
        print("ERROR: JSON file is missing required fields: %s" % ", ".join(missing))
        sys.exit(1)
    return client_id, client_secret


def connect_cdm(args, http_timeout):
    """
    Resolve cluster + credentials from args (prompting for anything missing)
    and return a connected CDMClient. Shared by every script here.
    """
    from cdm_client import CDMClient

    fqdn = prompt_if_missing(args.cluster, "CDM cluster FQDN/IP (e.g., 10.8.48.104): ",
                             required=True)

    json_path = args.svc_json
    if not json_path and not args.svc_client_id:
        json_path = input(
            "Service Account JSON (leave blank if providing client id & secret directly): ").strip()
    if json_path:
        json_path = os.path.expanduser(json_path)
        print("Reading credentials from: %s" % json_path)
        service_account_id, secret = load_json_credentials(json_path)
    else:
        service_account_id = prompt_if_missing(
            args.svc_client_id, "Service Account Client ID: ", clean=True, required=True)
        secret = prompt_if_missing(
            args.svc_secret, "Service Account Secret: ", clean=True, required=True)

    print("\nConnecting to %s..." % fqdn)
    try:
        client = CDMClient(fqdn, service_account_id, secret, timeout=http_timeout)
    except Exception as e:
        print("ERROR: Failed to authenticate: %s" % e)
        sys.exit(1)
    print("Connected!\n")
    return client, fqdn


def add_auth_args(parser, title="authentication"):
    """The standard authentication argument group."""
    auth_group = parser.add_argument_group(title)
    auth_group.add_argument("--svc_json", metavar="FILE",
                            help="RSC Service Account JSON file (contains client_id, client_secret)")
    auth_group.add_argument("--cluster", metavar="FQDN",
                            help="CDM cluster FQDN or IP address")
    auth_group.add_argument("--svc_client_id", metavar="ID",
                            help="Service Account ID (alternative to --svc_json)")
    auth_group.add_argument("--svc_secret",
                            help="Service Account Secret (alternative to --svc_json)")
    return auth_group


# ---------------------------------------------------------------------------
# CSV helpers
# ---------------------------------------------------------------------------

def first_field(row, *names):
    """Tolerant column read: first non-empty match across name variants."""
    for name in names:
        for candidate in (name, name.lower(), name.upper(), name.capitalize()):
            value = row.get(candidate)
            if value and str(value).strip():
                return str(value).strip()
    return ""


def read_csv_rows(csv_file):
    with open(csv_file, "r") as f:
        return list(csv.DictReader(f))


def write_csv(path, fieldnames, rows):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fieldnames})


def init_incremental_csv(path, fieldnames):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        f.flush()


def append_csv_row(path, fieldnames, row):
    with open(path, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writerow({k: row.get(k, "") for k in fieldnames})


def _csv_stamp(path):
    """
    When the CSV was actually generated, from its YYYYMMDD_HHMMSS filename
    suffix. Falls back to mtime when the name does not carry one.

    Filename beats mtime here: copying a three-month-old inventory between
    machines resets its mtime and would otherwise make a stale file look
    freshly generated, which is exactly the case the age warning exists to
    catch.
    """
    name = os.path.basename(path)
    match = re.search(r"(\d{8}_\d{6})", name)
    if match:
        try:
            return time.mktime(datetime.strptime(match.group(1), "%Y%m%d_%H%M%S").timetuple())
        except ValueError:
            pass
    return os.path.getmtime(path)


def wave_name_from(path, default="wave"):
    """
    Derive a wave name from whatever file identifies the wave.

    Every artifact of a run -- state, results, exclusions, activity log --
    is named after the wave, so a directory holding several waves stays
    readable instead of being a wall of interchangeable ahv_* files.

      inventory/wave1.yml            -> wave1
      tier0.csv                      -> tier0
      wave1_state_20260916_062714.csv -> wave1   (already carries the name)
    """
    if not path:
        return default
    base = os.path.basename(str(path).rstrip("/"))
    for suffix in (".csv", ".yml", ".yaml"):
        if base.lower().endswith(suffix):
            base = base[:-len(suffix)]
            break
    # A state file passed back in already has the wave name plus a stamp.
    base = re.sub(r"_(state|results|excluded)_\d{8}_\d{6}$", "", base)
    base = re.sub(r"[^A-Za-z0-9._-]", "_", base).strip("_")
    return base or default


def find_latest_csv(script_file, pattern, label, explicit=None, stale_days=7):
    """
    Resolve a staged CSV: an explicit path always wins; otherwise pick the
    newest file matching pattern next to the script.

    get_ahv_inventory.py writes timestamped filenames, so requiring the full
    path every run means pasting a new one each time. Auto-discovery removes
    that, but silently using a months-old inventory during a real recovery
    would be worse than the friction it saves -- so the chosen file and its
    age are always printed, and anything older than stale_days warns loudly.

    Returns the path, or None when nothing matches.
    """
    if explicit:
        path = os.path.expanduser(explicit)
        if not os.path.isfile(path):
            print("ERROR: %s not found: %s" % (label, path))
            sys.exit(1)
        return path

    base = os.path.dirname(os.path.abspath(script_file))
    # inventory/ is where get_ahv_inventory.py writes now; the bare script dir
    # is checked second so files generated before that change still resolve.
    matches = []
    for directory in (os.path.join(base, INVENTORY_DIRNAME), base):
        matches.extend(glob.glob(os.path.join(directory, pattern)))
    if not matches:
        return None

    path = max(matches, key=_csv_stamp)
    age_seconds = time.time() - _csv_stamp(path)
    age_days = age_seconds / 86400.0

    if age_days >= 1:
        age_text = "%.1f days old" % age_days
    elif age_seconds >= 3600:
        age_text = "%.1f hours old" % (age_seconds / 3600.0)
    else:
        age_text = "%d minutes old" % int(age_seconds / 60)

    print("  Using %s: %s (%s)" % (label, os.path.basename(path), age_text))
    if age_days >= stale_days:
        print("  WARNING: that %s is %s. Re-run get_ahv_inventory.py if the"
              % (label, age_text))
        print("           environment has changed, or pass an explicit path.")
    return path


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def format_bytes(value):
    """Human-readable byte count. Blank for None/empty."""
    if value in (None, "", 0):
        return "" if value in (None, "") else "0 B"
    try:
        size = float(value)
    except (TypeError, ValueError):
        return ""
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if abs(size) < 1024.0:
            return "%.1f %s" % (size, unit)
        size = size / 1024.0
    return "%.1f EiB" % size


def format_duration(seconds):
    """Seconds -> '1h 02m 03s'. Blank for None."""
    if seconds in (None, ""):
        return ""
    try:
        total = int(float(seconds))
    except (TypeError, ValueError):
        return ""
    hours = total // 3600
    minutes = (total % 3600) // 60
    secs = total % 60
    if hours:
        return "%dh %02dm %02ds" % (hours, minutes, secs)
    if minutes:
        return "%dm %02ds" % (minutes, secs)
    return "%ds" % secs


def parse_iso8601(value):
    """
    Parse a Rubrik ISO-8601 UTC timestamp into a naive datetime.
    Accepts trailing 'Z' and optional fractional seconds. Returns None on
    anything unparseable rather than raising.
    """
    if not value:
        return None
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1]
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def to_iso8601_z(dt):
    """datetime -> Rubrik-style '2026-09-09T17:20:27.915Z'."""
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + ("%03d" % (dt.microsecond // 1000)) + "Z"


def banner(title):
    return ["", "=" * 60, title, "=" * 60]


def truncate_list(items, limit=5, indent="  "):
    """The 'first N then ... and X more' preview idiom."""
    lines = []
    for item in items[:limit]:
        lines.append("%s- %s" % (indent, item))
    if len(items) > limit:
        lines.append("%s... and %d more" % (indent, len(items) - limit))
    return lines
