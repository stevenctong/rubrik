<#
.SYNOPSIS
Assigns an SLA Domain to the SQL instances or filesets on a list of hosts in RSC (-action Apply), or times
single (one call per host) versus bulk (one call for all hosts) SLA assignment (-action Test). It can also write
an inventory CSV of hosts and objects (-getSqlInventory, -getFilesetInventory) that Apply can use instead of querying RSC.

.DESCRIPTION
The Set-SLA-SQL-Fileset script resolves a list of hosts to their SQL instances (-sqlHosts, -sqlCsvPath) or to
their filesets (-filesetHosts or -filesetCsvPath, with a fileset template given by -filesetName or
-filesetTemplateId) and assigns an SLA to them.
One SLA (-slaName or -slaID) is applied to every object in the list. -action chooses the pathway.

-action Apply (production)
- Finds the objects on the listed hosts. For filesets, each host must have the fileset template (given by
  -filesetName or -filesetTemplateId) applied to it. The template itself must already exist and is never
  created or changed. Hosts that already have the template applied are left alone. Hosts that do not have it
  get it applied with bulkCreateFilesets (one call per cluster, after confirmation). Then the SLA is assigned
  to the filesets on all of those hosts.
- Gets each object's SLA state in the same lookup that finds it (live from RSC, or from the inventory CSV): its effective
  SLA and any pending SLA. Three things are skipped, and the plan, the console and the Apply CSV say which and why: a host
  that is not in the inventory CSV (in a live run a host that is not found stops the run instead), an object with any
  pending SLA (an assignment is already in flight), and an object whose effective SLA is already the target, directly
  assigned or inherited. A rerun is therefore safe.
- Shows the plan and asks for confirmation (-dryRun shows the plan only, -skipConfirm skips the prompt).
- Creates one Apply CSV with the starting assignment of every object before changing anything, then sends the
  assignments and rewrites the same file with the outcomes.
  -applyMode Bulk (default) sends up to -batchSize objects per call (default 50), never mixing clusters. -applyMode
  Single sends one call per host. A failed call does not stop the remaining calls. -assignLog records every call.
- Unless -skipPolling is used, polls every object until RSC shows the SLA (pendingSla empty and the effective SLA
  matching), printing progress, for up to -timeoutSec. With -skipPolling the assignments are only submitted and each
  object's state is recorded as Submitted.
- Writes a results CSV with one row per object (Applied, AlreadyOnTarget, Submitted, CallFailed, Timeout,
  NotAttempted, TemplateFailed) and exits with 1 if any call failed, timed out, was not attempted, or the
  template could not be applied to a host. Nothing is reverted.
  Use the starting state in the Apply CSV (the before* columns). A fileset template applied to a host stays applied.
- The target SLA can also be DO_NOT_PROTECT or NO_ASSIGNMENT (-slaName). Existing snapshots are retained.

-action Test (timing)
Compares two methods and times each:
- Single: one assignment call per host (all of that host's objects), sent one after the other. This mirrors
          selecting one host at a time in the RSC UI.
- Bulk:   one assignment call containing the objects of every host. This mirrors selecting many hosts at
          once in the RSC UI.
The assignment API returns right away and RSC applies the SLA asynchronously, so call latency alone does not
show how long the change takes. After the calls are sent, every object is polled (one batched query) until
pendingSla is empty and the effective SLA matches. Each method (Single first, then Bulk) runs two timed phases:
1. Assign: DO_NOT_PROTECT to the target SLA.
2. Revert: the target SLA back to DO_NOT_PROTECT.
The clock starts at the first call and stops when the last object is effective. Per-call latency, time until
each object is effective, failures and timeouts are recorded.
- SQL: the instances must start on DO_NOT_PROTECT (the script checks this and stops otherwise). The RSC UI also
  sets the host log retention before each assignment. That is opt-in with -setHostLogRetention because it
  immediately deletes log backup files on the host.
- Fileset: the start SLA is not checked. Hosts that do not have the template get it applied with
  bulkCreateFilesets (one call per cluster, after confirmation, not timed). Created filesets are left on the
  hosts. The revert phase sets the filesets to DO_NOT_PROTECT.
If the test fails or is interrupted (or a revert phase does not complete), every object is set back to
DO_NOT_PROTECT.

Inventory (-getSqlInventory, -getFilesetInventory; read-only, no -action, SLA or confirmation)
- Lists every SQL host with its instances, or every host (under -hostRoot) with its filesets, each fileset's
  template and paths, and every fileset template, with the current SLAs. A host list (-sqlHosts, -sqlCsvPath,
  -filesetHosts, -filesetCsvPath) narrows it. The result is one timestamped CSV per workload and the script exits.
- Use it with -action Apply -inventoryCsv <file>. Apply then takes host, cluster, template and object IDs, and the
  starting SLA state, from the CSV. It does not search RSC for hosts, templates or filesets, and it does not read
  each object's current SLA: the CSV is trusted as the starting state, so an object whose SLA in the CSV already
  matches the target is skipped. It still looks up the SLA name, and it polls to confirm completion. Filesets that
  Apply creates by applying a template are not in the CSV, so their state is read from RSC. Refresh the inventory
  before a run if the SLAs may have changed since it was taken.
- A listed host that is not in the inventory is skipped, with a warning at the end and a row in the Apply CSV.
  A host that is in the inventory but has no fileset from the template gets the template applied first, then the
  SLA is assigned to the full list. With no host list, every host in the inventory is used.
- The inventory age is printed, with a warning if it is older than -inventoryMaxAgeHours (default 24).

The SLA is assigned with the assignSla mutation by default or, with -assignMutation AssignSlasForSnappableHierarchies,
with assignSlasForSnappableHierarchies (what the RSC UI uses). Both take the same object IDs.

IMPORTANT: Both pathways change real SLA assignments. Run with -dryRun first to review what will be touched.

Output (<workload> is sql or fileset):
- Inventory: <prefix>sql_inventory-<timestamp>.csv or <prefix>fileset_inventory-<timestamp>.csv
- Host CSV (-sqlCsvPath / -filesetCsvPath): the same file is updated in place, with the 'executed' column filled in for
  each host. The original is kept once as <file>.bak.
- Apply: <prefix><workload>_sla_apply-<timestamp>.csv, one file per run. It is created before any change with one row
         per object (starting SLA, status Pending) and rewritten at the end with each object's outcome and a hostStatus
         column (Assigned, Partial, Failed or NotInInventory). Hosts with no object, such as one not in the inventory,
         get a row with no object.
- Test:  <prefix><workload>_sla_assign_test_runs-<timestamp>.csv and
         <prefix><workload>_sla_assign_test_instances-<timestamp>.csv, plus a console comparison

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/10/26
Updated: 11/11/26

Requires PowerShell 7+.

Time until effective has a resolution of -pollIntervalSec, since it is detected by polling.
Poll calls are counted separately and are not included in the API call counts.

For authentication, use a RSC Service Account:
** RSC Settings -> Users -> Service Account -> Create one and assign it an appropriate role
** Download the service account JSON
** Define the service account JSON path with -RscServiceAccountJson

.PARAMETER RscServiceAccountJson
Path to the RSC Service Account JSON file (must contain client_id, client_secret, access_token_uri).

.PARAMETER action
Pathway to run: Apply (assign the SLA to the listed objects) or Test (time Single versus Bulk, then revert).
Required.

.PARAMETER sqlHosts
One or more SQL host names (exact name match, case-insensitive).
Provide this or -sqlCsvPath. Cannot be combined with the fileset parameters. If both -sqlHosts and -sqlCsvPath are given,
the CSV wins and -sqlHosts is ignored.

.PARAMETER sqlCsvPath
Path to a host CSV. The CSV needs a header row with one of these columns: hostname, host, name, sqlhost. Any other
columns are kept. The script writes each host's outcome into an 'executed' column of this same file after an Apply run
(a timestamp, and a status such as Assigned, TemplateApplied+Assigned, AlreadyOnTarget, Partial, Failed, Skipped: not in
inventory, or Not run: <reason>). A copy of the original is kept once as <file>.bak. Dry runs, cancelled runs and the
inventory switches never change the file. The SLA and template are given on the command line and apply to every host
in the CSV. If -sqlHosts is also given, the CSV wins.

.PARAMETER filesetHosts
One or more host names (regular hosts, exact name match) whose filesets to use.
Use with -filesetName or -filesetTemplateId. Cannot be combined with -sqlHosts or -sqlCsvPath. If both -filesetHosts
and -filesetCsvPath are given, the CSV wins.

.PARAMETER filesetCsvPath
Path to a host CSV for filesets. Same format as -sqlCsvPath (hostname, host or name column), and the same 'executed'
write-back. The template (-filesetName or -filesetTemplateId) and the SLA on the command line apply to every host in the
CSV. If -filesetHosts is also given, the CSV wins.

.PARAMETER filesetName
Name of the existing fileset template to use (exact name match). On each host the script looks for a fileset
created from this template. Hosts that already have it are left alone, and hosts that do not get the template
applied with bulkCreateFilesets. The template is never created or changed. Use this or -filesetTemplateId.

.PARAMETER filesetTemplateId
ID of the existing fileset template to use, instead of -filesetName. This is the ID of the template itself, not
of a fileset on a host. Same behavior as -filesetName. Use this when the template name is not unique or you
already have the ID (for example from the inventory's Template rows).

.PARAMETER hostRoot
Host type used to look up fileset hosts and templates: WINDOWS_HOST_ROOT or LINUX_HOST_ROOT. Fileset templates belong
to one host type, so a template is only found under the host root it was created for. Default: WINDOWS_HOST_ROOT

.PARAMETER clusterName
Fileset runs and -getFilesetInventory: required. Exact name of the one cluster to work on. The fileset template lookup, the host
lookup and the fileset inventory are limited to that cluster, and the template is applied to hosts on that cluster only. The name is
looked up once at the start and the run stops if no cluster, or more than one cluster, has that name. Not used for SQL.

.PARAMETER recheckFilesetIDs
Apply only, fileset hosts. By default the fileset object IDs returned when the template is applied are added straight to the list of
filesets to assign, with no further lookups. Add this switch to look each of those hosts up again instead (one lookup per host) and
take their filesets from the lookup. That also shows which host each new fileset is on. Without it, a new fileset is shown against a
host only when exactly one host was in the template call.

.PARAMETER assignMutation
GraphQL mutation used to assign the SLA: AssignSla (the default) or AssignSlasForSnappableHierarchies (what the RSC UI
uses). Both take the same object IDs, and objects in one call on one cluster become a single pending action. Only one of
them is used for a given run, so no object is sent to both in the same run. Applies to SQL and filesets, and to both
actions. AssignSla was confirmed on Windows filesets on one cluster. It has not yet been confirmed on SQL instances, so
use -assignLog the first time on SQL. Default: AssignSla

.PARAMETER slaName
Name of the SLA Domain to assign. Provide this or -slaID.
Test: must be a real SLA Domain. Apply: can also be DO_NOT_PROTECT or NO_ASSIGNMENT.

.PARAMETER slaID
ID of the SLA Domain to assign. Provide this or -slaName.

.PARAMETER mode
Test only. Which method(s) to test: Single, Bulk, or Both. Default: Both

.PARAMETER setHostLogRetention
Test only, SQL only. Switch to also call bulkUpdateMssqlPropertiesOnHost (hostLogRetention = -1) before each
assignment, as the RSC UI does. This immediately deletes log files on the host regardless of age.

.PARAMETER applyMode
Apply only. Bulk (default) sends up to -batchSize objects per call, never mixing clusters. Single sends one call per host.

.PARAMETER batchSize
Apply only. Maximum number of objects per call with -applyMode Bulk. Default: 50. A call never mixes clusters, so the
objects on each cluster are split into batches of this size on their own. Objects are batched together because RSC treats
the objects in one call on one cluster as a single pending action and a single cluster job.

.PARAMETER assignLog
Apply only. Switch to write the details of every SLA assignment call to <prefix><sql|fileset>_sla_assign_log-<timestamp>.txt: the mutation
used, the cluster, the object count, the full query and variables, the raw response, the time taken and any error. It is
meant for checking how a mutation behaves (the default is AssignSla; add -assignMutation
AssignSlasForSnappableHierarchies to compare), and for sending the output to someone else, so it contains object IDs. It does not hide anything, and it is appended to if the file already exists.

.PARAMETER skipPolling
Apply only. Switch to submit the assignments and exit without polling for completion (alias: -noWait). Nothing is
checked afterwards, so the state of every accepted object is Submitted in the Apply CSV instead of Applied, and the
host status in the host CSV 'executed' column and in the Apply CSV reads Assigned for hosts whose calls were accepted. Check
the SLA in RSC later, or rerun to see which objects are still pending (they are skipped as SkippedPending).

.PARAMETER pollIntervalSec
Seconds between polls while waiting for the SLA to become effective. Default: 5

.PARAMETER timeoutSec
Maximum seconds to wait for all objects to reach the expected SLA (per phase in Test, in total in Apply).
Default: 600

.PARAMETER getSqlInventory
Read-only switch. Lists every SQL host (or the hosts given with -sqlHosts / -sqlCsvPath) with its SQL instances and
current SLAs, writes <prefix>sql_inventory-<timestamp>.csv, and exits. Needs no -action, SLA or confirmation.

.PARAMETER getFilesetInventory
Read-only switch. Lists every host under -hostRoot (or the hosts given with -filesetHosts / -filesetCsvPath) with
its filesets, each fileset's template, paths and SLA, plus every fileset template, writes
<prefix>fileset_inventory-<timestamp>.csv, and exits. Needs no -action, SLA or confirmation.

.PARAMETER inventoryCsv
Apply only. Path to an inventory CSV written by -getSqlInventory or -getFilesetInventory. Host, cluster, template and
object IDs come from the CSV instead of RSC. With a host list, only those hosts are used and a listed host that is
not in the inventory is skipped and logged. With no host list, every host in the inventory is used. For filesets
also give -filesetName or -filesetTemplateId.

.PARAMETER inventoryMaxAgeHours
With -inventoryCsv, print a warning if the inventory file is older than this many hours. Default: 24

.PARAMETER csvOutputPrefix
Location and prefix for the output CSV files. The report name and timestamp are appended automatically.
Output filenames: see the Output section above.
To write to a subdirectory, include the path (e.g. "./reports/rubrik_"). The directory must already exist.
Default: "./rubrik_"

.PARAMETER dryRun
Switch to resolve the hosts and show the plan, then exit without changing anything.

.PARAMETER skipConfirm
Switch to skip the 'type YES' confirmation prompt.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Apply -sqlHosts sql01,sql02,sql03 -slaName 'Gold' -dryRun
Show which SQL instances would get the 'Gold' SLA, which are already on it, and how many calls would be sent.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Apply -sqlCsvPath "./sql_hosts.csv" -slaName 'Gold'
Assign 'Gold' to all SQL instances on the hosts in the CSV, in bulk calls of up to 50 instances (-batchSize), and wait for completion.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Apply -filesetCsvPath "./fileset_hosts.csv" -filesetName 'Temp' -slaName 'Gold' -batchSize 50 -clusterName 'cluster01'
Assign 'Gold' to the 'Temp' filesets on the listed hosts. Hosts that do not have the template yet get it applied first.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Apply -filesetHosts host01,host02 -filesetTemplateId <template id> -slaName 'Gold' -applyMode Single -clusterName 'cluster01'
Assign 'Gold' using a fileset template ID, one call per host. Hosts without the template get it applied first.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Apply -sqlHosts sql01 -slaName 'DO_NOT_PROTECT' -skipPolling
Set the instances on sql01 to Do Not Protect, submit the assignments and exit without polling for completion. The state of each instance is Submitted.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Test -sqlHosts sql01,sql02,sql03 -slaName 'Gold' -dryRun
Resolve the hosts and show what the SQL timing test would do, without changing anything.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Test -sqlHosts sql01,sql02,sql03 -slaName 'Gold' -setHostLogRetention
Time Single versus Bulk assigning 'Gold' (DO_NOT_PROTECT to Gold) and reverting it, also setting host log retention as the UI does.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Test -filesetHosts host01,host02,host03 -filesetName 'Temp' -slaName 'Gold' -mode Bulk -clusterName 'cluster01'
Time the Bulk method for filesets, applying the 'Temp' template first to hosts that do not have it.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Test -filesetHosts host01,host02,host03 -filesetTemplateId <template id> -slaName 'Gold' -csvOutputPrefix "./reports/rubrik_" -clusterName 'cluster01'
Time Single versus Bulk for a fileset template given by ID, and write the CSVs to ./reports/.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Apply -filesetHosts host01,host02 -filesetName 'Temp' -slaName 'Gold' -assignLog -clusterName 'cluster01'
Assign the SLA (with the default assignSla mutation) and write the full details of each call (variables, response, timing, errors) to a text file you can share.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Apply -filesetHosts host01,host02 -filesetName 'Temp' -slaName 'Gold' -clusterName 'cluster01' -recheckFilesetIDs
After the template is applied, look each of those hosts up again (one lookup per host) instead of using the fileset IDs returned by the template call.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -getSqlInventory
Write an inventory of every SQL host and its instances with their current SLAs to ./rubrik_sql_inventory-<timestamp>.csv.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -getFilesetInventory -hostRoot LINUX_HOST_ROOT -clusterName 'cluster01'
Write an inventory of every Windows host, its filesets with their templates, and all fileset templates.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Apply -inventoryCsv "./rubrik_sql_inventory-2026-11-11_0900.csv" -sqlHosts sql01,sql02 -slaName 'Gold'
Assign 'Gold' to the instances of sql01 and sql02 using the saved IDs, without searching RSC for hosts or instances.

.EXAMPLE
./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson "./rsc-sa.json" -action Apply -inventoryCsv "./rubrik_fileset_inventory-2026-11-11_0900.csv" -filesetCsvPath "./hosts.csv" -filesetName 'Temp' -slaName 'Gold' -clusterName 'cluster01'
Use the fileset inventory for the listed hosts. Hosts in the inventory without the template get it applied first. Hosts not in the inventory are skipped and logged.
#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]

  # Path to the RSC Service Account JSON file
  [Parameter(Mandatory=$false)]
  [string]$RscServiceAccountJson,

  # Pathway: Apply the SLA to the listed objects, or Test (time Single versus Bulk, then revert). Not used with the inventory switches
  [Parameter(Mandatory=$false)]
  [string]$action,

  # SQL host names (exact match)
  [Parameter(Mandatory=$false)]
  [string[]]$sqlHosts,

  # CSV with a hostname/host/name/sqlhost column listing SQL hosts to test with
  [Parameter(Mandatory=$false)]
  [string]$sqlCsvPath,

  # Host names (regular hosts, exact match) whose filesets to use. Use with $filesetName
  [Parameter(Mandatory=$false)]
  [string[]]$filesetHosts,

  # CSV with a hostname/host/name column listing fileset hosts to test with
  [Parameter(Mandatory=$false)]
  [string]$filesetCsvPath,

  # Existing fileset template name. Hosts that do not have it get it applied. The template is never created
  [Parameter(Mandatory=$false)]
  [string]$filesetName,

  # Existing fileset template ID, instead of $filesetName
  [Parameter(Mandatory=$false)]
  [string]$filesetTemplateId,

  # Host type used to look up fileset hosts and templates
  [Parameter(Mandatory=$false)]
  [ValidateSet('WINDOWS_HOST_ROOT', 'LINUX_HOST_ROOT')]
  [string]$hostRoot = 'WINDOWS_HOST_ROOT',

  # Fileset only: limit the fileset template lookup and the host lookup to this cluster (exact cluster name)
  [Parameter(Mandatory=$false)]
  [string]$clusterName,

  # Mutation used to assign the SLA
  [Parameter(Mandatory=$false)]
  [ValidateSet('AssignSla', 'AssignSlasForSnappableHierarchies')]
  [string]$assignMutation = 'AssignSla',

  # SLA name to assign, provide this or $slaID. Test: a real SLA Domain. Apply: can also be DO_NOT_PROTECT or NO_ASSIGNMENT
  [Parameter(Mandatory=$false)]
  [string]$slaName,

  # SLA ID to assign, provide this or $slaName
  [Parameter(Mandatory=$false)]
  [string]$slaID,

  # Test only: method(s) to test
  [Parameter(Mandatory=$false)]
  [ValidateSet('Single', 'Bulk', 'Both')]
  [string]$mode = 'Both',

  # SQL only: also set host log retention (-1) before each assignment, as the RSC UI does
  [Parameter(Mandatory=$false)]
  [switch]$setHostLogRetention,

  # Apply only: Bulk sends up to $batchSize objects per call, Single sends one call per host
  [Parameter(Mandatory=$false)]
  [ValidateSet('Bulk', 'Single')]
  [string]$applyMode = 'Bulk',

  # Apply only: maximum number of objects per call with -applyMode Bulk. A call never mixes clusters: each cluster's objects are batched on their own
  [Parameter(Mandatory=$false)]
  [int]$batchSize = 50,

  # Apply only: write the details of every SLA assignment call (mutation, variables, response, timing, errors) to <prefix>sla_assign_log-<timestamp>.txt
  [Parameter(Mandatory=$false)]
  [switch]$assignLog,

  # Apply only: submit the assignments and exit without polling for completion. The state is recorded as Submitted
  [Parameter(Mandatory=$false)]
  [Alias('noWait')]
  [switch]$skipPolling,

  # Apply only, filesets: after applying the template, look each of those hosts up again to get its fileset IDs (one lookup per host).
  # Without it the fileset IDs returned by the template call are used directly
  [Parameter(Mandatory=$false)]
  [switch]$recheckFilesetIDs,

  # Read-only: list every SQL host and its instances with their SLAs, write a timestamped CSV, and exit
  [Parameter(Mandatory=$false)]
  [switch]$getSqlInventory,

  # Read-only: list every host with its filesets, templates and SLAs, write timestamped CSVs, and exit
  [Parameter(Mandatory=$false)]
  [switch]$getFilesetInventory,

  # Apply only: use an inventory CSV (from -getSqlInventory or -getFilesetInventory) instead of querying RSC for hosts and objects
  [Parameter(Mandatory=$false)]
  [string]$inventoryCsv,

  # With -inventoryCsv: warn if the inventory file is older than this many hours
  [Parameter(Mandatory=$false)]
  [int]$inventoryMaxAgeHours = 24,

  # Seconds between polls while waiting for the SLA to become effective
  [Parameter(Mandatory=$false)]
  [int]$pollIntervalSec = 5,

  # Max seconds to wait for all instances to reach the expected SLA
  [Parameter(Mandatory=$false)]
  [int]$timeoutSec = 600,

  # Location and prefix for output CSV files. Report name and timestamp are appended automatically.
  # To write to a subdirectory, include the path (e.g. "./reports/rubrik_"). Directory must already exist.
  [Parameter(Mandatory=$false)]
  [string]$csvOutputPrefix = './rubrik_',

  # Show the plan and exit without changing anything
  [Parameter(Mandatory=$false)]
  [switch]$dryRun,

  # Skip the confirmation prompt
  [Parameter(Mandatory=$false)]
  [switch]$skipConfirm
)

### VARIABLES - END ###

### INPUT VALIDATION ###

if ($PSBoundParameters.Count -eq 0) {
  Write-Host ""
  Write-Host "Set-SLA-SQL-Fileset" -ForegroundColor Cyan
  Write-Host "Assign an SLA in RSC to SQL instances (on SQL hosts) or to Windows filesets (on fileset hosts)."
  Write-Host "Use -action Apply to assign. Hosts come from a CSV (or a host list), and -action is not needed for an inventory."
  Write-Host ""
  Write-Host "SQL HOSTS" -ForegroundColor Cyan
  Write-Host "  Inventory:  ./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson `"./rsc-sa.json`" -getSqlInventory"
  Write-Host "  Apply:      ./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson `"./rsc-sa.json`" -action Apply -sqlCsvPath `"./sql_hosts.csv`" -slaName `"Gold`""
  Write-Host "  From an inventory: add -inventoryCsv `"./sql_inventory-<time>.csv`" to the Apply command"
  Write-Host "  Creates:    sql_inventory-<time>.csv       from -getSqlInventory (Apply never changes it)"
  Write-Host "              sql_sla_apply-<time>.csv       from each Apply: every instance's starting SLA, then its outcome and host status"
  Write-Host "              sql_sla_assign_log-<time>.txt  from -assignLog: every SLA assignment call"
  Write-Host "  Updates:    your -sqlCsvPath file, in place: the 'executed' column gets each host's result and time,"
  Write-Host "              and the original is kept once as <file>.bak"
  Write-Host ""
  Write-Host "WINDOWS FILESET HOSTS" -ForegroundColor Cyan
  Write-Host "  Inventory:  ./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson `"./rsc-sa.json`" -getFilesetInventory -clusterName `"cluster01`""
  Write-Host "  Apply:      ./Set-SLA-SQL-Fileset.ps1 -RscServiceAccountJson `"./rsc-sa.json`" -action Apply -filesetCsvPath `"./hosts.csv`" -filesetName `"Temp`" -slaName `"Gold`" -clusterName `"cluster01`""
  Write-Host "  From an inventory: add -inventoryCsv `"./fileset_inventory-<time>.csv`" to the Apply command"
  Write-Host "  Template:   -filesetName (or -filesetTemplateId) must already exist. Hosts without it get it applied first."
  Write-Host "  Creates:    fileset_inventory-<time>.csv       from -getFilesetInventory (Apply never changes it)"
  Write-Host "              fileset_sla_apply-<time>.csv       from each Apply: every fileset's starting SLA, then its outcome and host status"
  Write-Host "              fileset_sla_assign_log-<time>.txt  from -assignLog: every SLA assignment call"
  Write-Host "  Updates:    your -filesetCsvPath file, in place: the 'executed' column gets each host's result and time,"
  Write-Host "              and the original is kept once as <file>.bak"
  Write-Host ""
  Write-Host "ALL RUNS" -ForegroundColor Cyan
  Write-Host "  New files go in the current folder, or where -csvOutputPrefix points."
  Write-Host "  Add -dryRun to preview an Apply: it writes nothing. Apply changes real SLAs and never reverts them."
  Write-Host "  Apply asks you to type YES before it changes anything. Add -skipConfirm to skip that and just run it."
  Write-Host "  -sqlHosts / -filesetHosts (a list on the command line) can replace the CSV. Then no host CSV is updated."
  Write-Host "Run 'Get-Help ./Set-SLA-SQL-Fileset.ps1 -Detailed' for every option, more examples, and the timing test (-action Test)."
  Write-Host ""
  exit 0
}

if (-not $RscServiceAccountJson) {
  Write-Error "-RscServiceAccountJson is required."
  exit 1
}

if ($action -and $action -notin @('Apply', 'Test')) {
  Write-Error "-action must be Apply or Test."
  exit 1
}

$inventoryRequested = [bool]($getSqlInventory -or $getFilesetInventory)

if ($getSqlInventory -and $getFilesetInventory) {
  Write-Error "Use either -getSqlInventory or -getFilesetInventory, not both in one run."
  exit 1
}

if (-not $action -and -not $inventoryRequested) {
  Write-Error "-action is required: Apply or Test (or use -getSqlInventory / -getFilesetInventory)."
  exit 1
}

if ($inventoryRequested) {
  # The inventory is read-only, so none of the action, SLA or apply/test parameters apply
  foreach ($p in @('action', 'slaName', 'slaID', 'mode', 'setHostLogRetention', 'applyMode', 'batchSize', 'skipPolling', 'assignLog', 'recheckFilesetIDs', 'dryRun', 'skipConfirm', 'inventoryCsv', 'filesetName', 'filesetTemplateId', 'assignMutation')) {
    if ($PSBoundParameters.ContainsKey($p)) {
      Write-Error "-$p cannot be used with -getSqlInventory or -getFilesetInventory. The inventory only reads RSC and writes CSVs."
      exit 1
    }
  }
  if ($clusterName -and $getSqlInventory) {
    Write-Error "-clusterName only applies to fileset runs."
    exit 1
  }
  if ($getFilesetInventory -and -not $clusterName) {
    Write-Error "-getFilesetInventory needs -clusterName. The fileset inventory covers one cluster."
    exit 1
  }
  if ($getSqlInventory -and ($filesetHosts -or $filesetCsvPath)) {
    Write-Error "-getSqlInventory can be limited with -sqlHosts or -sqlCsvPath, not the fileset host parameters."
    exit 1
  }
  if ($getFilesetInventory -and ($sqlHosts -or $sqlCsvPath)) {
    Write-Error "-getFilesetInventory can be limited with -filesetHosts or -filesetCsvPath, not the SQL host parameters."
    exit 1
  }
  $action = 'Inventory'
}

if ($inventoryCsv -and $action -ne 'Apply') {
  Write-Error "-inventoryCsv only applies to -action Apply."
  exit 1
}

if ($inventoryCsv -and -not (Test-Path -Path $inventoryCsv)) {
  Write-Error "Inventory CSV not found: $inventoryCsv"
  exit 1
}

if ($inventoryMaxAgeHours -lt 1) {
  Write-Error "-inventoryMaxAgeHours must be 1 or greater."
  exit 1
}


# Parameters that only belong to one action are rejected under the other so they are never silently ignored
if ($action -eq 'Apply') {
  foreach ($p in @('mode', 'setHostLogRetention')) {
    if ($PSBoundParameters.ContainsKey($p)) {
      Write-Error "-$p only applies to -action Test."
      exit 1
    }
  }
  if ($batchSize -lt 1) {
    Write-Error "-batchSize must be 1 or greater."
    exit 1
  }
} else {
  foreach ($p in @('applyMode', 'batchSize', 'skipPolling', 'assignLog', 'recheckFilesetIDs')) {
    if ($PSBoundParameters.ContainsKey($p)) {
      Write-Error "-$p only applies to -action Apply."
      exit 1
    }
  }
}

# Read a host name column from a CSV file. Also remembers the file, its rows and the host column in
# $script:hostCsvInfo so the 'executed' column can be written back after an Apply run.
$script:hostCsvInfo = $null
Function Read-HostCsv {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$path,
    [Parameter(Mandatory=$true)]
    [string[]]$columns
  )
  if (-not (Test-Path -Path $path)) {
    Write-Error "CSV file not found: $path"
    exit 1
  }
  $rows = @(Import-Csv -Path $path)
  if ($rows.Count -eq 0) {
    Write-Error "CSV file has no rows: $path"
    exit 1
  }
  $column = $rows[0].PSObject.Properties.Name | Where-Object { $_ -in $columns } | Select-Object -First 1
  if (-not $column) {
    Write-Error "CSV needs a header column named one of: $($columns -join ', ')"
    exit 1
  }
  $script:hostCsvInfo = [pscustomobject]@{ path = (Resolve-Path -Path $path).Path; rows = $rows; column = $column }
  return @($rows.$column)
}  ### Function Read-HostCsv


# Write each host's outcome into the 'executed' column of the host CSV. The file is written to a temporary file and then
# moved into place, and the original is kept once as <file>.bak, so a failure part way cannot leave a half-written CSV.
Function Update-HostCsvExecuted {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [hashtable]$executedByHost
  )
  $info = $script:hostCsvInfo
  if (-not $info) {
    return
  }
  $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  $out = @()
  foreach ($row in $info.rows) {
    $copy = [ordered]@{}
    foreach ($prop in $row.PSObject.Properties) {
      $copy[$prop.Name] = $prop.Value
    }
    $hostValue = "$($row.($info.column))".Trim()
    if ($hostValue -and $executedByHost.ContainsKey($hostValue.ToLower())) {
      $copy['executed'] = "$($executedByHost[$hostValue.ToLower()]) $stamp".Trim()
    } elseif (-not $copy.Contains('executed')) {
      $copy['executed'] = ''
    }
    $out += [pscustomobject]$copy
  }
  $backup = "$($info.path).bak"
  $tmp = "$($info.path).tmp"
  try {
    $out | Export-Csv -Path $tmp -NoTypeInformation -ErrorAction Stop
    if (-not (Test-Path -Path $backup)) {
      Copy-Item -Path $info.path -Destination $backup -ErrorAction Stop
    }
    Move-Item -Path $tmp -Destination $info.path -Force -ErrorAction Stop
    Write-Host "Updated the 'executed' column in: $($info.path)" -ForegroundColor Green
  } catch {
    Write-Host "Could not update the host CSV ($($info.path)): $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "The results are still in the Apply CSV: $csvApplyOutput" -ForegroundColor Yellow
    if (Test-Path -Path $tmp) { Remove-Item -Path $tmp -ErrorAction SilentlyContinue }
  }
}  ### Function Update-HostCsvExecuted


# Write the single Apply CSV. Written to a temporary file and moved into place so a failure part way cannot leave a
# half-written file. Never throws: a problem writing the file must not stop an assignment.
Function Write-ApplyCsv {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    $rows
  )
  $tmpApply = "$csvApplyOutput.tmp"
  try {
    @($rows) | Export-Csv -Path $tmpApply -NoTypeInformation -ErrorAction Stop
    Move-Item -Path $tmpApply -Destination $csvApplyOutput -Force -ErrorAction Stop
  } catch {
    Write-Host "Could not write the Apply CSV ($csvApplyOutput): $($_.Exception.Message)" -ForegroundColor Yellow
    if (Test-Path -Path $tmpApply) { Remove-Item -Path $tmpApply -ErrorAction SilentlyContinue }
  }
}  ### Function Write-ApplyCsv


# When host resolution fails the run stops before any change. Record that in the host CSV: each host named in an error gets
# 'Not run: <error>', and every other host gets 'Not run: stopped before any change', so the user can see which host to fix.
Function Set-HostCsvNotRun {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    [string[]]$errors = @(),
    [Parameter(Mandatory=$false)]
    [string]$reason = 'stopped before any change'
  )
  if (-not $script:hostCsvInfo) {
    return
  }
  $byHost = @{}
  foreach ($hn in $hostNames) {
    $hit = @($errors | Where-Object { $_ -match [regex]::Escape($hn) } | Select-Object -First 1)
    if ($hit.Count -gt 0) {
      $byHost[$hn.ToLower()] = "Not run: $($hit[0])"
    } else {
      $byHost[$hn.ToLower()] = "Not run: $reason"
    }
  }
  Update-HostCsvExecuted -executedByHost $byHost
}  ### Function Set-HostCsvNotRun

$workload = 'SQL'
$hostNames = @()

if ($action -eq 'Inventory') {
  # The inventory lists everything unless a host list narrows it
  if ($getSqlInventory) {
    if ($sqlCsvPath) {
      $hostNames += Read-HostCsv -path $sqlCsvPath -columns @('hostname', 'host', 'name', 'sqlhost')
    } elseif ($sqlHosts) {
      $hostNames += $sqlHosts
    }
  } else {
    $workload = 'Fileset'
    if ($filesetCsvPath) {
      $hostNames += Read-HostCsv -path $filesetCsvPath -columns @('hostname', 'host', 'name')
    } elseif ($filesetHosts) {
      $hostNames += $filesetHosts
    }
  }
  # The inventory only reads RSC, so the host CSV is not updated
  $script:hostCsvInfo = $null
  $hostNames = @($hostNames | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
} else {
  $sqlRequested = [bool]($sqlHosts -or $sqlCsvPath)
  $filesetRequested = [bool]($filesetHosts -or $filesetCsvPath -or $filesetName -or $filesetTemplateId)
  if ($clusterName -and -not $filesetRequested -and $action -ne 'Inventory') {
    Write-Error "-clusterName only applies to fileset runs (-filesetHosts / -filesetCsvPath with a template)."
    exit 1
  }
  if ($filesetRequested -and -not $clusterName) {
    Write-Error "Fileset runs need -clusterName. Every fileset lookup and the template application are done on that one cluster."
    exit 1
  }

  # With an inventory CSV and no host parameters, the inventory itself says which workload this is
  if ($inventoryCsv -and -not $sqlRequested -and -not $filesetRequested) {
    $peek = @(Import-Csv -Path $inventoryCsv | Select-Object -First 1)
    if ($peek.Count -eq 1 -and $peek[0].workload -eq 'SQL') {
      $sqlRequested = $true
    }
  }

  if ($sqlRequested -and $filesetRequested) {
    Write-Error "Use either SQL (-sqlHosts/-sqlCsvPath) or filesets (-filesetHosts/-filesetCsvPath), not both in one run."
    exit 1
  }

  if (-not $sqlRequested -and -not $filesetRequested) {
    Write-Error "Provide SQL hosts with -sqlHosts and/or -sqlCsvPath, or filesets with -filesetHosts/-filesetCsvPath and -filesetName or -filesetTemplateId."
    exit 1
  }

  if ($sqlRequested -and $recheckFilesetIDs) {
    Write-Error "-recheckFilesetIDs only applies to fileset runs."
    exit 1
  }

  if (-not $slaName -and -not $slaID) {
    Write-Error "Provide the target SLA with -slaName or -slaID."
    exit 1
  }

  if ($slaName -and $slaID) {
    Write-Error "Specify either -slaName or -slaID, not both."
    exit 1
  }

  if ($pollIntervalSec -lt 1) {
    Write-Error "-pollIntervalSec must be 1 or greater."
    exit 1
  }

  $workload = 'SQL'
  $hostNames = @()

  if ($sqlRequested) {
    # Build the list of SQL host names. A host CSV (-sqlCsvPath) replaces -sqlHosts when both are given.
    if ($sqlCsvPath) {
      if ($sqlHosts) {
        Write-Host "Both -sqlHosts and -sqlCsvPath were given. Using the hosts in the CSV and ignoring -sqlHosts." -ForegroundColor Yellow
      }
      $hostNames += Read-HostCsv -path $sqlCsvPath -columns @('hostname', 'host', 'name', 'sqlhost')
    } elseif ($sqlHosts) {
      $hostNames += $sqlHosts
    }
  } else {
    $workload = 'Fileset'
    if ($setHostLogRetention) {
      Write-Error "-setHostLogRetention only applies to SQL."
      exit 1
    }
    if (-not $filesetName -and -not $filesetTemplateId) {
      Write-Error "Provide the fileset template with -filesetName or -filesetTemplateId."
      exit 1
    }
    if ($filesetName -and $filesetTemplateId) {
      Write-Error "Specify either -filesetName or -filesetTemplateId, not both."
      exit 1
    }
    if (-not $filesetHosts -and -not $filesetCsvPath -and -not $inventoryCsv) {
      Write-Error "Provide hosts with -filesetHosts and/or -filesetCsvPath."
      exit 1
    }
    if ($filesetCsvPath) {
      if ($filesetHosts) {
        Write-Host "Both -filesetHosts and -filesetCsvPath were given. Using the hosts in the CSV and ignoring -filesetHosts." -ForegroundColor Yellow
      }
      $hostNames += Read-HostCsv -path $filesetCsvPath -columns @('hostname', 'host', 'name')
    } elseif ($filesetHosts) {
      $hostNames += $filesetHosts
    }
  }
  $hostNames = @($hostNames | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)

  if ($hostNames.Count -eq 0 -and -not $inventoryCsv) {
    Write-Error "No host names were provided."
    exit 1
  }
}

$date = Get-Date
$dateString = $date.ToString("yyyy-MM-dd_HHmmss")
$workloadPrefix = $workload.ToLower()
$csvRunsOutput = "${csvOutputPrefix}${workloadPrefix}_sla_assign_test_runs-${dateString}.csv"
$csvInstancesOutput = "${csvOutputPrefix}${workloadPrefix}_sla_assign_test_instances-${dateString}.csv"
$csvApplyOutput = "${csvOutputPrefix}${workloadPrefix}_sla_apply-${dateString}.csv"
$assignLogOutput = "${csvOutputPrefix}${workloadPrefix}_sla_assign_log-${dateString}.txt"

###### RUBRIK AUTHENTICATION - BEGIN ######

# Validate that $RscServiceAccountJson is set via parameter or caller variable
if ([string]::IsNullOrEmpty($RscServiceAccountJson)) {
  throw "`$RscServiceAccountJson must be passed as a parameter or defined before dot-sourcing RSC-Authentication.ps1"
}

# Require PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)"
}

Write-Host "Reading Service Account file: $RscServiceAccountJson"
try {
  $serviceAccountFile = Get-Content -Path "$RscServiceAccountJson" -ErrorAction Stop | ConvertFrom-Json
} catch {
  throw "Failed to read Service Account JSON at '$RscServiceAccountJson': $($_.Exception.Message)"
}

# Validate required fields
$missingFields = @()
if ($null -eq $serviceAccountFile.client_id) { $missingFields += 'client_id' }
if ($null -eq $serviceAccountFile.client_secret) { $missingFields += 'client_secret' }
if ($null -eq $serviceAccountFile.access_token_uri) { $missingFields += 'access_token_uri' }

if ($missingFields.Count -gt 0) {
  throw "Service Account JSON is missing required fields: $($missingFields -join ', ')"
}

# Exchange credentials for bearer token
$payload = @{
  grant_type    = "client_credentials"
  client_id     = $serviceAccountFile.client_id
  client_secret = $serviceAccountFile.client_secret
}

try {
  $response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri `
    -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop
} catch {
  throw "RSC authentication failed: $($_.Exception.Message)"
}

if ($null -eq $response.access_token) {
  throw "RSC returned a response but no access token was included."
}

# Set connection variables accessible to the calling script
$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")

$global:rubrikConnection = @{
  accessToken = $response.access_token
  bearer = "Bearer $($response.access_token)"
  rubrikURL   = $rubrikURL
}

$endpoint = $rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json'
  'Accept'        = 'application/json'
  'Authorization' = "Bearer $($response.access_token)"
}

Write-Host "Connected to RSC: $rubrikURL" -ForegroundColor Green

###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Send a GraphQL request, throw on GraphQL errors, and return the data plus the call duration in seconds
Function Invoke-Rsc {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$query,
    [Parameter(Mandatory=$false)]
    [hashtable]$variables = @{}
  )
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-Json -Depth 100) -Headers $headers
  $sw.Stop()
  if ($response.errors) {
    throw ($response.errors | ConvertTo-Json -Depth 10 -Compress)
  }
  return [pscustomobject]@{
    data = $response.data
    seconds = $sw.Elapsed.TotalSeconds
  }
}  ### Function Invoke-Rsc


# Get SLA Domains matching a name
Function Get-SLADomainByName {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$slaName
  )
  $variables = @{
    "filter" = @(
      @{
        "field" = "NAME"
        "text" = $slaName
      }
    )
  }
  $query = 'query SLADomainsForNameFilterQuery($filter: [GlobalSlaFilterInput!]) {
    slaDomains(filter: $filter) {
      nodes {
        id
        name
        __typename
      }
      __typename
    }
  }'
  $result = Invoke-Rsc -query $query -variables $variables
  return $result.data.slaDomains.nodes
}  ### Function Get-SLADomainByName


# Convert an SLA name or ID into an assignment spec used by the assign mutation
Function Resolve-SlaSpec {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    [string]$name,
    [Parameter(Mandatory=$false)]
    [string]$id
  )
  if ($id) {
    return [pscustomobject]@{ type = 'protectWithSlaId'; slaId = $id; label = $id }
  }
  if ($name -eq 'DO_NOT_PROTECT') {
    return [pscustomobject]@{ type = 'doNotProtect'; slaId = ''; label = 'DO_NOT_PROTECT' }
  }
  if ($name -eq 'NO_ASSIGNMENT') {
    return [pscustomobject]@{ type = 'noAssignment'; slaId = ''; label = 'NO_ASSIGNMENT' }
  }
  Write-Host "Looking up SLA Domain: $name"
  $slaMatches = @(Get-SLADomainByName -slaName $name)
  $exactMatches = @($slaMatches | Where-Object { $_.name -eq $name })
  if ($exactMatches.Count -eq 0) {
    throw "No SLA Domain found with the exact name: $name"
  } elseif ($exactMatches.Count -ge 2) {
    throw "Multiple SLA Domains found with the exact name: $name. Use the SLA ID instead."
  }
  return [pscustomobject]@{ type = 'protectWithSlaId'; slaId = $exactMatches[0].id; label = $exactMatches[0].name }
}  ### Function Resolve-SlaSpec


# Get a SQL host with its SQL instances and each instance's current SLA assignment
Function Get-SqlHostInstances {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$hostName
  )
  $query = 'query MssqlHostInstancesQuery($first: Int!, $after: String, $filter: [Filter!], $instanceFilter: [Filter!]) {
    mssqlTopLevelDescendants(after: $after, first: $first, filter: $filter, sortBy: NAME, sortOrder: ASC, typeFilter: [MSSQL_HOST]) {
      edges {
        cursor
        node {
          id
          name
          objectType
          ... on MssqlHost {
            cluster {
              id
              name
            }
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
  }'
  $nodes = @()
  $afterCursor = ''
  do {
    $variables = @{
      "first" = 100
      "filter" = @(
        @{ "field" = "NAME"; "texts" = @($hostName) },
        @{ "field" = "IS_RELIC"; "texts" = @("false") },
        @{ "field" = "IS_REPLICATED"; "texts" = @("false") }
      )
      "instanceFilter" = @(
        @{ "field" = "IS_ARCHIVED"; "texts" = @("false") }
      )
    }
    if ($afterCursor -ne '') {
      $variables.after = $afterCursor
    }
    $result = (Invoke-Rsc -query $query -variables $variables).data.mssqlTopLevelDescendants
    if ($result.edges) {
      $nodes += $result.edges.node
    }
    $afterCursor = $result.pageInfo.endCursor
  } while ($result.pageInfo.hasNextPage)
  return $nodes
}  ### Function Get-SqlHostInstances


# Convert an instance's current assignment into a spec that restores it
Function Get-OriginalSlaSpec {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    $instance
  )
  if ($instance.slaAssignment -eq 'Direct') {
    if ($instance.effectiveSlaDomain.id -eq 'DO_NOT_PROTECT') {
      return [pscustomobject]@{ type = 'doNotProtect'; slaId = ''; label = 'DO_NOT_PROTECT' }
    }
    return [pscustomobject]@{ type = 'protectWithSlaId'; slaId = $instance.effectiveSlaDomain.id; label = $instance.effectiveSlaDomain.name }
  }
  # Derived or unassigned: remove any direct assignment so it inherits again
  return [pscustomobject]@{ type = 'noAssignment'; slaId = ''; label = 'NO_ASSIGNMENT' }
}  ### Function Get-OriginalSlaSpec


# Append one entry to the assignment log (-assignLog). Never throws: a logging problem must not stop an assignment.
$script:assignCallNumber = 0
Function Write-AssignLog {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$mutation,
    [Parameter(Mandatory=$true)]
    [string]$query,
    [Parameter(Mandatory=$true)]
    $variables,
    [Parameter(Mandatory=$false)]
    $response,
    [Parameter(Mandatory=$false)]
    [string]$errorText = '',
    [Parameter(Mandatory=$false)]
    $seconds = $null
  )
  if (-not $assignLog) {
    return
  }
  try {
    $script:assignCallNumber++
    $lines = @()
    $lines += ('=' * 100)
    $lines += "Call $($script:assignCallNumber)  $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    $lines += "Mutation:  $mutation"
    $lines += "Workload:  $workload"
    $lines += "Target:    $($script:assignLogTarget)"
    $lines += "Cluster:   $($script:assignLogCluster)"
    $lines += "Objects:   $(@($variables.objectIds).Count + @($variables.input.objectIds).Count)"
    if ($null -ne $seconds) {
      $lines += "Seconds:   $([Math]::Round($seconds, 3))"
    }
    $lines += "Result:    $(if ($errorText) { 'FAILED' } else { 'OK' })"
    if ($errorText) {
      $lines += "Error:     $errorText"
    }
    $lines += ''
    $lines += 'Query:'
    $lines += $query
    $lines += ''
    $lines += 'Variables:'
    $lines += ($variables | ConvertTo-Json -Depth 20)
    $lines += ''
    $lines += 'Response:'
    if ($null -ne $response) {
      $lines += ($response | ConvertTo-Json -Depth 20)
    } else {
      $lines += '(none)'
    }
    $lines += ''
    Add-Content -Path $assignLogOutput -Value $lines -ErrorAction Stop
  } catch {
    Write-Host "Could not write the assignment log ($assignLogOutput): $($_.Exception.Message)" -ForegroundColor Yellow
  }
}  ### Function Write-AssignLog


# Assign an SLA spec to a list of objects (SQL instances or filesets) in one call, using the chosen mutation
Function Set-ObjectSla {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string[]]$objectIds,
    [Parameter(Mandatory=$true)]
    $spec
  )
  if ($assignMutation -eq 'AssignSla') {
    $assignInput = @{
      "slaDomainAssignType" = $spec.type
      "slaOptionalId" = $null
      "objectIds" = @($objectIds)
      "existingSnapshotRetention" = $null
      "shouldApplyToExistingSnapshots" = $null
      "shouldApplyToNonPolicySnapshots" = $false
      "userNote" = ""
    }
    if ($spec.type -eq 'protectWithSlaId') {
      $assignInput.slaOptionalId = $spec.slaId
      $assignInput.shouldApplyToExistingSnapshots = $false
    } else {
      $assignInput.existingSnapshotRetention = 'RETAIN_SNAPSHOTS'
    }
    $query = 'mutation AssignSlaMutation($input: AssignSlaInput!) {
      assignSla(input: $input) {
        success
        __typename
      }
    }'
    $callVars = @{ "input" = $assignInput }
    try {
      $result = Invoke-Rsc -query $query -variables $callVars
    } catch {
      Write-AssignLog -mutation 'assignSla' -query $query -variables $callVars -errorText $_.Exception.Message
      throw
    }
    $results = @($result.data.assignSla)
    if ($results.Count -eq 0 -or ($results | Where-Object { $_.success -ne $true })) {
      Write-AssignLog -mutation 'assignSla' -query $query -variables $callVars -response $result.data -seconds $result.seconds -errorText 'assignSla did not return success'
      throw "assignSla did not return success"
    }
    Write-AssignLog -mutation 'assignSla' -query $query -variables $callVars -response $result.data -seconds $result.seconds
    return $result
  }

  $variables = @{
    "objectIds" = @($objectIds)
    "globalSlaAssignType" = $spec.type
    "globalSlaOptionalFid" = $null
    "globalExistingSnapshotRetention" = $null
    "shouldApplyToExistingSnapshots" = $null
    "shouldApplyToNonPolicySnapshots" = $false
    "userNote" = ""
  }
  if ($spec.type -eq 'protectWithSlaId') {
    $variables.globalSlaOptionalFid = $spec.slaId
    $variables.shouldApplyToExistingSnapshots = $false
  } else {
    $variables.globalExistingSnapshotRetention = 'RETAIN_SNAPSHOTS'
  }
  $query = 'mutation AssignSlasForSnappableHierarchiesMutation($globalExistingSnapshotRetention: GlobalExistingSnapshotRetention, $globalSlaOptionalFid: UUID, $globalSlaAssignType: SlaAssignTypeEnum!, $objectIds: [UUID!]!, $applicableSnappableTypes: [WorkloadLevelHierarchy!], $shouldApplyToExistingSnapshots: Boolean, $shouldApplyToNonPolicySnapshots: Boolean, $userNote: String) {
    assignSlasForSnappableHierarchies(globalExistingSnapshotRetention: $globalExistingSnapshotRetention, globalSlaOptionalFid: $globalSlaOptionalFid, globalSlaAssignType: $globalSlaAssignType, objectIds: $objectIds, applicableSnappableTypes: $applicableSnappableTypes, shouldApplyToExistingSnapshots: $shouldApplyToExistingSnapshots, shouldApplyToNonPolicySnapshots: $shouldApplyToNonPolicySnapshots, userNote: $userNote) {
      success
      __typename
    }
  }'
  try {
    $result = Invoke-Rsc -query $query -variables $variables
  } catch {
    Write-AssignLog -mutation 'assignSlasForSnappableHierarchies' -query $query -variables $variables -errorText $_.Exception.Message
    throw
  }
  $results = @($result.data.assignSlasForSnappableHierarchies)
  if ($results.Count -eq 0 -or ($results | Where-Object { $_.success -ne $true })) {
    Write-AssignLog -mutation 'assignSlasForSnappableHierarchies' -query $query -variables $variables -response $result.data -seconds $result.seconds -errorText 'assignSlasForSnappableHierarchies did not return success for all objects'
    throw "assignSlasForSnappableHierarchies did not return success for all objects"
  }
  Write-AssignLog -mutation 'assignSlasForSnappableHierarchies' -query $query -variables $variables -response $result.data -seconds $result.seconds
  return $result
}  ### Function Set-ObjectSla


# Set the host log retention to -1 (delete log files immediately) on a list of SQL hosts in one call
Function Set-HostLogRetention {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string[]]$hostIds
  )
  $hostsUpdateProperties = @()
  foreach ($hostId in $hostIds) {
    $hostsUpdateProperties += @{
      "hostId" = $hostId
      "updateProperties" = @{
        "mssqlSlaRelatedProperties" = @{
          "hostLogRetention" = -1
        }
      }
    }
  }
  $variables = @{
    "input" = @{
      "hostsUpdateProperties" = @($hostsUpdateProperties)
    }
  }
  $query = 'mutation BulkUpdateMssqlPropertiesOnHostMutation($input: BulkUpdateMssqlPropertiesOnHostInput!) {
    bulkUpdateMssqlPropertiesOnHost(input: $input) {
      items {
        mssqlInstanceSummary {
          id
          name
        }
      }
    }
  }'
  return (Invoke-Rsc -query $query -variables $variables)
}  ### Function Set-HostLogRetention


# Get the SLA state of a list of SQL instances using one batched query (chunked at 50 objects)
Function Get-InstanceSlaState {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string[]]$instanceIds
  )
  $states = @()
  for ($start = 0; $start -lt $instanceIds.Count; $start += 50) {
    $chunk = @($instanceIds[$start..([Math]::Min($start + 49, $instanceIds.Count - 1))])
    $varDefs = @()
    $fields = @()
    $variables = @{}
    for ($i = 0; $i -lt $chunk.Count; $i++) {
      $varDefs += "`$id${i}: UUID!"
      $fields += "o${i}: hierarchyObject(fid: `$id${i}) { id slaAssignment effectiveSlaDomain { id name } ... on CdmHierarchyObject { pendingSla { id name } } }"
      $variables["id$i"] = $chunk[$i]
    }
    $query = 'query PendingSlaBatchQuery(' + ($varDefs -join ', ') + ') { ' + ($fields -join ' ') + ' }'
    $result = Invoke-Rsc -query $query -variables $variables
    foreach ($property in $result.data.PSObject.Properties) {
      if ($property.Value) {
        $states += $property.Value
      }
    }
  }
  return $states
}  ### Function Get-InstanceSlaState


# Check if an instance state matches the expected SLA spec with nothing pending
Function Test-SlaEffective {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    $state,
    [Parameter(Mandatory=$true)]
    $spec
  )
  if ($state.pendingSla) {
    return $false
  }
  switch ($spec.type) {
    'protectWithSlaId' { return ($state.slaAssignment -eq 'Direct' -and $state.effectiveSlaDomain.id -eq $spec.slaId) }
    'doNotProtect' { return ($state.slaAssignment -eq 'Direct' -and $state.effectiveSlaDomain.id -eq 'DO_NOT_PROTECT') }
    'noAssignment' { return ($state.slaAssignment -ne 'Direct') }
  }
  return $false
}  ### Function Test-SlaEffective


# Decide what Apply should do with one object, from the state its lookup returned (live from RSC, or from the inventory CSV).
# Skip rules, checked in this order (the third skip rule, a host that is not found, is handled before objects exist):
#   SkippedPending   the object has any pending SLA: an assignment is already in flight, and another would only queue a second
#   AlreadyOnTarget  the object's effective SLA is already the target, whether it was assigned directly or inherited
#   Assign           everything else
# The completion poll keeps using Test-SlaEffective, where any pending SLA really does mean "not finished yet".
Function Get-SlaDecision {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    $state,
    [Parameter(Mandatory=$true)]
    $spec
  )
  if (-not $state) {
    return 'Assign'
  }
  if ($state.pendingSla) {
    return 'SkippedPending'
  }
  switch ($spec.type) {
    'protectWithSlaId' { if ("$($state.effectiveSlaDomain.id)" -eq $spec.slaId) { return 'AlreadyOnTarget' } }
    'doNotProtect' { if ("$($state.effectiveSlaDomain.id)" -eq 'DO_NOT_PROTECT') { return 'AlreadyOnTarget' } }
    'noAssignment' { if ($state.slaAssignment -ne 'Direct') { return 'AlreadyOnTarget' } }
  }
  return 'Assign'
}  ### Function Get-SlaDecision


# Poll until every instance matches the spec or the timeout is hit
# Returns the offset in seconds (on the supplied stopwatch) at which each instance was seen effective
Function Wait-SlaEffective {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string[]]$instanceIds,
    [Parameter(Mandatory=$true)]
    $spec,
    [Parameter(Mandatory=$true)]
    [System.Diagnostics.Stopwatch]$stopwatch
  )
  $effective = @{}
  $pollCount = 0
  $pollErrors = 0
  $timedOut = $false
  $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $remaining = @($instanceIds | Where-Object { -not $effective.ContainsKey($_) })
    if ($remaining.Count -eq 0) {
      break
    }
    if ($waitSw.Elapsed.TotalSeconds -ge $timeoutSec) {
      $timedOut = $true
      break
    }
    $pollCount++
    try {
      $states = Get-InstanceSlaState -instanceIds $remaining
      $offset = $stopwatch.Elapsed.TotalSeconds
      foreach ($state in $states) {
        if (Test-SlaEffective -state $state -spec $spec) {
          $effective[$state.id] = $offset
        }
      }
    } catch {
      $pollErrors++
    }
    if (@($instanceIds | Where-Object { -not $effective.ContainsKey($_) }).Count -gt 0) {
      Start-Sleep -Seconds $pollIntervalSec
    }
  }
  return [pscustomobject]@{
    effective = $effective
    pollCount = $pollCount
    pollErrors = $pollErrors
    timedOut = $timedOut
  }
}  ### Function Wait-SlaEffective


# Perform one timed phase: send the SLA assignment mutations (Single or Bulk), then poll until all instances show it
Function Invoke-TimedPhase {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$runMode,
    [Parameter(Mandatory=$true)]
    [string]$phase,
    [Parameter(Mandatory=$true)]
    $hostObjs,
    [Parameter(Mandatory=$true)]
    $spec
  )
  $allInstances = @(foreach ($h in $hostObjs) { $h.instances })
  $allIds = @($allInstances.instanceId)

  # Define the call groups: Single is one group per host, Bulk is one group of all hosts
  $groups = New-Object System.Collections.ArrayList
  if ($runMode -eq 'Bulk') {
    [void]$groups.Add(@($hostObjs))
  } else {
    foreach ($h in $hostObjs) {
      [void]$groups.Add(@($h))
    }
  }

  Write-Host "  [$runMode $phase] Assigning '$($spec.label)' in $($groups.Count) call group(s), one after the other"
  $runSw = [System.Diagnostics.Stopwatch]::StartNew()
  $instInfo = @{}
  $callSeconds = @()
  $apiCalls = 0
  $groupNum = 0

  # Submit phase: send the call groups one after the other (Single = one call per host, Bulk = one call)
  foreach ($g in $groups) {
    $groupNum++
    $groupStart = $runSw.Elapsed.TotalSeconds
    $groupInstances = @(foreach ($h in $g) { $h.instances })
    $propsSec = $null
    $assignSec = $null
    $callOk = $true
    $callError = ''
    try {
      if ($setHostLogRetention) {
        $apiCalls++
        $propsResult = Set-HostLogRetention -hostIds @($g.id)
        $propsSec = $propsResult.seconds
        $callSeconds += $propsSec
      }
      $apiCalls++
      $assignResult = Set-ObjectSla -objectIds @($groupInstances.instanceId) -spec $spec
      $assignSec = $assignResult.seconds
      $callSeconds += $assignSec
    } catch {
      $callOk = $false
      $callError = $_.Exception.Message
      Write-Host "    Call group $groupNum failed: $callError" -ForegroundColor Yellow
    }
    foreach ($inst in $groupInstances) {
      $instInfo[$inst.instanceId] = [pscustomobject]@{
        hostName = $inst.hostName
        instanceName = $inst.instanceName
        instanceId = $inst.instanceId
        callGroup = $groupNum
        submitOffsetSec = $groupStart
        propsCallSec = $propsSec
        assignCallSec = $assignSec
        callOk = $callOk
        callError = $callError
      }
    }
  }

  # Wait for every successfully submitted instance to become effective
  $submittedIds = @($instInfo.Values | Where-Object { $_.callOk } | ForEach-Object { $_.instanceId })
  $wait = [pscustomobject]@{ effective = @{}; pollCount = 0; pollErrors = 0; timedOut = $false }
  if ($submittedIds.Count -gt 0) {
    $wait = Wait-SlaEffective -instanceIds $submittedIds -spec $spec -stopwatch $runSw
  }
  $runSw.Stop()

  # Build per-instance rows
  $instanceRows = @()
  foreach ($info in ($instInfo.Values | Sort-Object -Property callGroup, hostName, instanceName)) {
    $effectiveOffset = $null
    $secFromSubmit = $null
    if (-not $info.callOk) {
      $status = 'CallFailed'
    } elseif ($wait.effective.ContainsKey($info.instanceId)) {
      $status = 'Effective'
      $effectiveOffset = [Math]::Round($wait.effective[$info.instanceId], 2)
      $secFromSubmit = [Math]::Round($wait.effective[$info.instanceId] - $info.submitOffsetSec, 2)
    } else {
      $status = 'Timeout'
    }
    $instanceRows += [pscustomobject]@{
      workload = $workload
      mode = $runMode
      phase = $phase
      host = $info.hostName
      instance = $info.instanceName
      instanceId = $info.instanceId
      callGroup = $info.callGroup
      submitOffsetSec = [Math]::Round($info.submitOffsetSec, 2)
      propsCallSec = if ($null -ne $info.propsCallSec) { [Math]::Round($info.propsCallSec, 2) } else { $null }
      assignCallSec = if ($null -ne $info.assignCallSec) { [Math]::Round($info.assignCallSec, 2) } else { $null }
      effectiveOffsetSec = $effectiveOffset
      secFromSubmit = $secFromSubmit
      status = $status
      error = $info.callError
    }
  }

  # Build the run summary
  $effectiveRows = @($instanceRows | Where-Object { $_.status -eq 'Effective' })
  $failedCount = @($instanceRows | Where-Object { $_.status -eq 'CallFailed' }).Count
  $timeoutCount = @($instanceRows | Where-Object { $_.status -eq 'Timeout' }).Count
  $callStats = $callSeconds | Measure-Object -Sum -Average -Maximum
  $submitStats = $effectiveRows.secFromSubmit | Measure-Object -Average -Maximum
  $wallSec = if ($effectiveRows.Count -gt 0) { ($effectiveRows.effectiveOffsetSec | Measure-Object -Maximum).Maximum } else { $null }
  if ($failedCount -eq 0 -and $timeoutCount -eq 0) { $runStatus = 'OK' } else { $runStatus = 'Incomplete' }

  $summary = [pscustomobject]@{
    workload = $workload
    assignMutation = $assignMutation
    mode = $runMode
    phase = $phase
    hosts = @($hostObjs).Count
    instances = $allIds.Count
    setHostLogRetention = [bool]$setHostLogRetention
    apiCalls = $apiCalls
    callSecTotal = if ($callStats.Count -gt 0) { [Math]::Round($callStats.Sum, 2) } else { $null }
    callSecAvg = if ($callStats.Count -gt 0) { [Math]::Round($callStats.Average, 2) } else { $null }
    callSecMax = if ($callStats.Count -gt 0) { [Math]::Round($callStats.Maximum, 2) } else { $null }
    wallSecToAllEffective = if ($null -ne $wallSec -and $runStatus -eq 'OK') { [Math]::Round($wallSec, 2) } else { $null }
    instanceSecAvg = if ($submitStats.Count -gt 0) { [Math]::Round($submitStats.Average, 2) } else { $null }
    instanceSecMax = if ($submitStats.Count -gt 0) { [Math]::Round($submitStats.Maximum, 2) } else { $null }
    pollCount = $wait.pollCount
    pollErrors = $wait.pollErrors
    failedInstances = $failedCount
    timedOutInstances = $timeoutCount
    status = $runStatus
  }

  Write-Host ("  [{0} {1}] {2}: {3} API calls, wall {4}s" -f $runMode, $phase, $runStatus, $apiCalls, $summary.wallSecToAllEffective)

  return [pscustomobject]@{
    summary = $summary
    instances = $instanceRows
  }
}  ### Function Invoke-TimedPhase


# Set every instance back to its original assignment (DO_NOT_PROTECT), one call per distinct original assignment
Function Restore-OriginalSla {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    $instances
  )
  Write-Host "Restoring original SLA assignments on $(@($instances).Count) instances"
  $groups = $instances | Group-Object -Property { "$($_.originalSpec.type):$($_.originalSpec.slaId)" }
  foreach ($group in $groups) {
    $spec = $group.Group[0].originalSpec
    $ids = @($group.Group.instanceId)
    try {
      $null = Set-ObjectSla -objectIds $ids -spec $spec
      $restoreSw = [System.Diagnostics.Stopwatch]::StartNew()
      $restoreWait = Wait-SlaEffective -instanceIds $ids -spec $spec -stopwatch $restoreSw
      if ($restoreWait.timedOut) {
        Write-Host "  Timed out waiting for restore to '$($spec.label)' on $($ids.Count) instance(s)" -ForegroundColor Yellow
      } else {
        Write-Host "  Restored $($ids.Count) instance(s) to '$($spec.label)'"
      }
    } catch {
      Write-Host "  FAILED to restore $($ids.Count) instance(s) to '$($spec.label)': $($_.Exception.Message)" -ForegroundColor Red
      Write-Host "  Restore these manually:" -ForegroundColor Red
      $group.Group | ForEach-Object { Write-Host "    $($_.hostName) \ $($_.instanceName) ($($_.instanceId)) -> $($spec.label)" -ForegroundColor Red }
    }
  }
}  ### Function Restore-OriginalSla

# Find a cluster by exact name and return its ID. Stops the run if no cluster, or more than one, has that name.
Function Get-ClusterIdByName {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$name
  )
  $query = 'query ClusterByNameQuery($filter: ClusterFilterInput) {
    allClusterConnection(filter: $filter, sortBy: ClusterName, sortOrder: ASC) {
      nodes {
        id
        name
      }
    }
  }'
  $result = Invoke-Rsc -query $query -variables @{ "filter" = @{ "name" = @($name) } }
  $nodes = @($result.data.allClusterConnection.nodes | Where-Object { $_.name -eq $name })
  if ($nodes.Count -eq 0) {
    throw "No cluster found with the exact name: $name"
  } elseif ($nodes.Count -ge 2) {
    throw "More than one cluster has the name: $name"
  }
  return $nodes[0].id
}  ### Function Get-ClusterIdByName


# Get fileset templates matching a name (the name filter can be a partial match, so check exact names after)
Function Get-FilesetTemplatesByName {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$name
  )
  $query = 'query FilesetTemplatesByNameQuery($hostRoot: HostRoot!, $first: Int!, $after: String, $filter: [Filter!]!) {
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
  }'
  $nodes = @()
  $afterCursor = ''
  do {
    $tmplFilter = @(
      @{ "field" = "NAME"; "texts" = @($name) }
    )
    if ($script:clusterFilterId) {
      $tmplFilter += @{ "field" = "CLUSTER_ID"; "texts" = @($script:clusterFilterId) }
    }
    $variables = @{
      "hostRoot" = $hostRoot
      "first" = 100
      "filter" = $tmplFilter
    }
    if ($afterCursor -ne '') {
      $variables.after = $afterCursor
    }
    $result = (Invoke-Rsc -query $query -variables $variables).data.filesetTemplates
    if ($result.edges) {
      $nodes += $result.edges.node
    }
    $afterCursor = $result.pageInfo.endCursor
  } while ($result.pageInfo.hasNextPage)
  return $nodes
}  ### Function Get-FilesetTemplatesByName


# Get one fileset template by ID with its cluster
Function Get-FilesetTemplateById {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$id
  )
  $query = 'query FilesetTemplateByIdQuery($fid: UUID!) {
    filesetTemplate(fid: $fid) {
      id
      name
      cluster {
        id
        name
      }
    }
  }'
  $result = Invoke-Rsc -query $query -variables @{ "fid" = $id }
  return $result.data.filesetTemplate
}  ### Function Get-FilesetTemplateById


# Get a host (name filter can be a partial match) with its cluster and the filesets on it
Function Get-PhysicalHostFilesets {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$hostName
  )
  $query = 'query PhysicalHostFilesetsQuery($hostRoot: HostRoot!, $first: Int!, $after: String, $filter: [Filter!]!, $childFilter: [Filter!]) {
    physicalHosts(hostRoot: $hostRoot, filter: $filter, first: $first, after: $after, sortBy: NAME, sortOrder: ASC) {
      edges {
        node {
          id
          name
          cluster {
            id
            name
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
  }'
  $nodes = @()
  $afterCursor = ''
  do {
    $hostFilter = @(
      @{ "field" = "NAME"; "texts" = @($hostName) },
      @{ "field" = "IS_RELIC"; "texts" = @("false") },
      @{ "field" = "IS_REPLICATED"; "texts" = @("false") },
      @{ "field" = "IS_KUPR_HOST"; "texts" = @("false") }
    )
    if ($script:clusterFilterId) {
      $hostFilter += @{ "field" = "CLUSTER_ID"; "texts" = @($script:clusterFilterId) }
    }
    $variables = @{
      "hostRoot" = $hostRoot
      "first" = 100
      "filter" = $hostFilter
      "childFilter" = @(
        @{ "field" = "IS_GHOST"; "texts" = @("false") },
        @{ "field" = "IS_RELIC"; "texts" = @("false") }
      )
    }
    if ($afterCursor -ne '') {
      $variables.after = $afterCursor
    }
    $result = (Invoke-Rsc -query $query -variables $variables).data.physicalHosts
    if ($result.edges) {
      $nodes += $result.edges.node
    }
    $afterCursor = $result.pageInfo.endCursor
  } while ($result.pageInfo.hasNextPage)
  return $nodes
}  ### Function Get-PhysicalHostFilesets


# Apply fileset templates to hosts on one cluster with one call. Each definition has hostId and templateId
Function New-FilesetsOnCluster {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$clusterId,
    [Parameter(Mandatory=$true)]
    $definitions
  )
  $defs = @()
  foreach ($d in $definitions) {
    $defs += @{
      "hostId" = $d.hostId
      "templateId" = $d.templateId
      "isPassthrough" = $false
      "enableSymlinkResolution" = $false
      "enableHardlinkSupport" = $false
    }
  }
  $query = 'mutation BulkCreateFilesetsMutation($clusterUuid: String!, $definitions: [FilesetCreateInput!]!) {
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
  }'
  return (Invoke-Rsc -query $query -variables @{ "clusterUuid" = $clusterId; "definitions" = @($defs) })
}  ### Function New-FilesetsOnCluster

# Wait for submitted objects to show the expected SLA, printing progress at every poll
# Returns the elapsed seconds at which each object was seen effective
Function Wait-SlaEffectiveWithProgress {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string[]]$objectIds,
    [Parameter(Mandatory=$true)]
    $spec,
    [Parameter(Mandatory=$true)]
    [System.Diagnostics.Stopwatch]$stopwatch
  )
  $effective = @{}
  $pollCount = 0
  $pollErrors = 0
  $timedOut = $false
  $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $remaining = @($objectIds | Where-Object { -not $effective.ContainsKey($_) })
    if ($remaining.Count -eq 0) {
      break
    }
    if ($waitSw.Elapsed.TotalSeconds -ge $timeoutSec) {
      $timedOut = $true
      break
    }
    $pollCount++
    try {
      $states = Get-InstanceSlaState -instanceIds $remaining
      $offset = $stopwatch.Elapsed.TotalSeconds
      foreach ($state in $states) {
        if (Test-SlaEffective -state $state -spec $spec) {
          $effective[$state.id] = $offset
        }
      }
    } catch {
      $pollErrors++
      Write-Host "    Poll $pollCount failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Write-Host ("  {0}/{1} effective, {2}s elapsed" -f $effective.Count, $objectIds.Count, [Math]::Round($stopwatch.Elapsed.TotalSeconds))
    if (@($objectIds | Where-Object { -not $effective.ContainsKey($_) }).Count -gt 0) {
      Start-Sleep -Seconds $pollIntervalSec
    }
  }
  return [pscustomobject]@{
    effective = $effective
    pollCount = $pollCount
    pollErrors = $pollErrors
    timedOut = $timedOut
  }
}  ### Function Wait-SlaEffectiveWithProgress


# Split a list into chunks of at most $size items
Function Split-IntoBatches {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    $items,
    [Parameter(Mandatory=$true)]
    [int]$size
  )
  $batches = @()
  $items = @($items)
  for ($start = 0; $start -lt $items.Count; $start += $size) {
    $end = [Math]::Min($start + $size - 1, $items.Count - 1)
    $batches += , @($items[$start..$end])
  }
  # The leading comma keeps a single batch from being unrolled into a flat list of items
  return , $batches
}  ### Function Split-IntoBatches


# Split objects into call groups. A call never mixes clusters (objects in one call for one cluster become one pending
# action and one cluster job). Bulk: each cluster's objects are split into batches of $size. Single: one call per host.
# Returns an array of groups, each group an array of objects that all share one cluster.
Function Get-CallGroups {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    $objects,
    [Parameter(Mandatory=$true)]
    [string]$mode,
    [Parameter(Mandatory=$true)]
    [int]$size
  )
  $groups = @()
  $objects = @($objects)
  foreach ($cg in ($objects | Group-Object -Property clusterId)) {
    if ($mode -eq 'Single') {
      foreach ($hg in ($cg.Group | Group-Object -Property hostId)) {
        $groups += , @($hg.Group)
      }
    } else {
      foreach ($batch in (Split-IntoBatches -items $cg.Group -size $size)) {
        $groups += , @($batch)
      }
    }
  }
  return , $groups
}  ### Function Get-CallGroups


# Apply the SLA spec to the objects, send the calls, then wait for completion
# $objects is a flat list of objects (instanceId, instanceName, hostName, hostId, assignment, currentSla, state)
Function Invoke-ApplySla {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    $objects,
    [Parameter(Mandatory=$true)]
    $spec
  )
  $results = @{}
  # Keep a script-level reference so partial results can still be exported if something stops the run
  $script:applyResults = $results
  foreach ($o in $objects) {
    $results[$o.instanceId] = [pscustomobject]@{
      workload = $workload
      assignMutation = $assignMutation
      applyMode = $applyMode
      host = $o.hostName
      object = $o.instanceName
      objectId = $o.instanceId
      beforeAssignment = $o.assignment
      beforeSla = $o.currentSla
      targetSla = $spec.label
      callGroup = $null
      callSec = $null
      effectiveSec = $null
      status = 'NotAttempted'
      error = ''
    }
  }

  # Skip objects that are already on the target SLA, or already have it pending
  $todo = @()
  foreach ($o in $objects) {
    $decision = Get-SlaDecision -state $o.state -spec $spec
    if ($decision -eq 'Assign') {
      $todo += $o
    } else {
      $results[$o.instanceId].status = $decision
    }
  }
  $pendingCount = @($objects | Where-Object { $results[$_.instanceId].status -eq 'SkippedPending' }).Count
  Write-Host "$(@($objects).Count) object(s): $(@($todo).Count) to assign, $(@($objects).Count - @($todo).Count - $pendingCount) already on '$($spec.label)', $pendingCount skipped because an SLA is pending"
  if (@($todo).Count -eq 0) {
    return @($results.Values)
  }

  # An object ID must appear once: the same ID twice in one call can fail validation for the whole batch
  $todo = @($todo | Group-Object -Property instanceId | ForEach-Object { $_.Group[0] })

  # Every object must know its cluster, otherwise it would be grouped with the wrong objects
  $noCluster = @($todo | Where-Object { -not $_.clusterId })
  if ($noCluster.Count -gt 0) {
    throw "$($noCluster.Count) object(s) have no cluster ID, so they cannot be batched safely: $((@($noCluster | Select-Object -First 3 | ForEach-Object { "$($_.hostName)/$($_.instanceName)" })) -join ', ')"
  }

  # Build the call groups: Bulk is batches of $batchSize objects within each cluster, Single is one call per host
  $groups = Get-CallGroups -objects $todo -mode $applyMode -size $batchSize

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $submittedIds = @()
  $groupNum = 0
  foreach ($g in $groups) {
    $groupNum++
    $ids = @($g.instanceId)
    $script:assignLogCluster = "$(@($g | Select-Object -ExpandProperty clusterId -Unique) -join ',')"
    $script:assignLogTarget = $spec.label
    try {
      $assignResult = Set-ObjectSla -objectIds $ids -spec $spec
      Write-Host ("  Call {0}/{1}: {2} object(s) accepted in {3}s" -f $groupNum, $groups.Count, $ids.Count, [Math]::Round($assignResult.seconds, 2))
      foreach ($id in $ids) {
        $results[$id].callGroup = $groupNum
        $results[$id].callSec = [Math]::Round($assignResult.seconds, 2)
        $results[$id].status = 'Submitted'
      }
      $submittedIds += $ids
    } catch {
      Write-Host ("  Call {0}/{1} FAILED for {2} object(s): {3}" -f $groupNum, $groups.Count, $ids.Count, $_.Exception.Message) -ForegroundColor Red
      foreach ($id in $ids) {
        $results[$id].callGroup = $groupNum
        $results[$id].status = 'CallFailed'
        $results[$id].error = $_.Exception.Message
      }
    }
  }

  # Wait for every accepted object to show the SLA
  if (-not $skipPolling -and $submittedIds.Count -gt 0) {
    Write-Host "Waiting for $($submittedIds.Count) object(s) to show '$($spec.label)'"
    $wait = Wait-SlaEffectiveWithProgress -objectIds $submittedIds -spec $spec -stopwatch $sw
    foreach ($id in $submittedIds) {
      if ($wait.effective.ContainsKey($id)) {
        $results[$id].status = 'Applied'
        $results[$id].effectiveSec = [Math]::Round($wait.effective[$id], 2)
      } else {
        $results[$id].status = 'Timeout'
      }
    }
  }
  return @($results.Values)
}  ### Function Invoke-ApplySla

# List SQL hosts with their instances. An empty $hostName lists every SQL host (paginated 100 at a time)
Function Get-AllSqlHostInstances {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    [string]$hostName = ''
  )
  $query = 'query MssqlInventoryQuery($first: Int!, $after: String, $filter: [Filter!], $instanceFilter: [Filter!]) {
    mssqlTopLevelDescendants(after: $after, first: $first, filter: $filter, sortBy: NAME, sortOrder: ASC, typeFilter: [MSSQL_HOST]) {
      edges {
        node {
          id
          name
          objectType
          ... on MssqlHost {
            cluster {
              id
              name
            }
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
  }'
  $nodes = @()
  $afterCursor = ''
  do {
    $filter = @(
      @{ "field" = "IS_RELIC"; "texts" = @("false") },
      @{ "field" = "IS_REPLICATED"; "texts" = @("false") }
    )
    if ($hostName) {
      $filter = @(@{ "field" = "NAME"; "texts" = @($hostName) }) + $filter
    }
    $variables = @{
      "first" = 100
      "filter" = $filter
      "instanceFilter" = @(
        @{ "field" = "IS_ARCHIVED"; "texts" = @("false") }
      )
    }
    if ($afterCursor -ne '') {
      $variables.after = $afterCursor
    }
    $result = (Invoke-Rsc -query $query -variables $variables).data.mssqlTopLevelDescendants
    if ($result.edges) {
      $nodes += $result.edges.node
    }
    $afterCursor = $result.pageInfo.endCursor
  } while ($result.pageInfo.hasNextPage)
  return $nodes
}  ### Function Get-AllSqlHostInstances


# List hosts with their filesets, each with its template and paths. An empty $hostName lists every host
Function Get-AllPhysicalHostFilesets {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    [string]$hostName = ''
  )
  $query = 'query FilesetInventoryQuery($hostRoot: HostRoot!, $first: Int!, $after: String, $filter: [Filter!]!, $childFilter: [Filter!]) {
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
                  pathIncluded
                  pathExcluded
                  pathExceptions
                  filesetTemplate {
                    id
                    name
                  }
                }
                ... on WindowsFileset {
                  pathIncluded
                  pathExcluded
                  pathExceptions
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
  }'
  $nodes = @()
  $afterCursor = ''
  do {
    $filter = @(
      @{ "field" = "IS_RELIC"; "texts" = @("false") },
      @{ "field" = "IS_REPLICATED"; "texts" = @("false") },
      @{ "field" = "IS_KUPR_HOST"; "texts" = @("false") }
    )
    if ($hostName) {
      $filter = @(@{ "field" = "NAME"; "texts" = @($hostName) }) + $filter
    }
    if ($script:clusterFilterId) {
      $filter += @{ "field" = "CLUSTER_ID"; "texts" = @($script:clusterFilterId) }
    }
    $variables = @{
      "hostRoot" = $hostRoot
      "first" = 100
      "filter" = $filter
      "childFilter" = @(
        @{ "field" = "IS_GHOST"; "texts" = @("false") },
        @{ "field" = "IS_RELIC"; "texts" = @("false") }
      )
    }
    if ($afterCursor -ne '') {
      $variables.after = $afterCursor
    }
    $result = (Invoke-Rsc -query $query -variables $variables).data.physicalHosts
    if ($result.edges) {
      $nodes += $result.edges.node
    }
    $afterCursor = $result.pageInfo.endCursor
  } while ($result.pageInfo.hasNextPage)
  return $nodes
}  ### Function Get-AllPhysicalHostFilesets


# List every fileset template under the host root with its cluster and paths (paginated 100 at a time)
Function Get-AllFilesetTemplates {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    [string]$unused = ''
  )
  $query = 'query AllFilesetTemplatesQuery($hostRoot: HostRoot!, $first: Int!, $after: String, $filter: [Filter!]!) {
    filesetTemplates(hostRoot: $hostRoot, first: $first, after: $after, filter: $filter, sortBy: NAME, sortOrder: ASC) {
      edges {
        node {
          id
          name
          includes
          excludes
          exceptions
          numWorkloadDescendants
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
  }'
  $nodes = @()
  $afterCursor = ''
  $allTmplFilter = @(@{ "field" = "NAME"; "texts" = @("") })
  if ($script:clusterFilterId) {
    $allTmplFilter += @{ "field" = "CLUSTER_ID"; "texts" = @($script:clusterFilterId) }
  }
  do {
    $variables = @{
      "hostRoot" = $hostRoot
      "first" = 100
      "filter" = $allTmplFilter
    }
    if ($afterCursor -ne '') {
      $variables.after = $afterCursor
    }
    $result = (Invoke-Rsc -query $query -variables $variables).data.filesetTemplates
    if ($result.edges) {
      $nodes += $result.edges.node
    }
    $afterCursor = $result.pageInfo.endCursor
  } while ($result.pageInfo.hasNextPage)
  return $nodes
}  ### Function Get-AllFilesetTemplates


# Join a list of strings into one CSV cell
Function Join-Cell {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    $items
  )
  return (@($items) -join ' | ')
}  ### Function Join-Cell


# Read an inventory CSV, check it has the columns this workload needs, and report its age
Function Read-InventoryCsv {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [string]$path,
    [Parameter(Mandatory=$true)]
    [string]$expectedWorkload
  )
  $rows = @(Import-Csv -Path $path)
  if ($rows.Count -eq 0) {
    throw "Inventory CSV has no rows: $path"
  }
  $cols = @($rows[0].PSObject.Properties.Name)
  foreach ($c in @('inventoryVersion', 'workload', 'rowType', 'host', 'hostId', 'clusterId', 'objectId', 'templateId', 'templateName', 'collectedAt')) {
    if ($cols -notcontains $c) {
      throw "Inventory CSV is missing the '$c' column. Create it with -getSqlInventory or -getFilesetInventory: $path"
    }
  }
  $wl = @($rows | Select-Object -ExpandProperty workload -Unique)
  if ($wl.Count -ne 1 -or $wl[0] -ne $expectedWorkload) {
    throw "Inventory CSV is for '$($wl -join ',')' but this run is for '$expectedWorkload': $path"
  }
  $collected = $null
  try {
    $collected = [datetime]::Parse($rows[0].collectedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
  } catch {
    Write-Host "Could not read the collection time from the inventory CSV, so its age is unknown." -ForegroundColor Yellow
  }
  if ($collected) {
    $ageHours = ((Get-Date).ToUniversalTime() - $collected.ToUniversalTime()).TotalHours
    Write-Host ("Inventory collected {0} ({1} hour(s) ago): {2}" -f $collected.ToLocalTime().ToString('yyyy-MM-dd HH:mm'), [Math]::Round($ageHours, 1), $path)
    if ($ageHours -gt $inventoryMaxAgeHours) {
      Write-Host "WARNING: the inventory is older than $inventoryMaxAgeHours hour(s). Objects added or removed since then are not reflected. Rerun -getSqlInventory or -getFilesetInventory to refresh it." -ForegroundColor Yellow
    }
  }
  return $rows
}  ### Function Read-InventoryCsv

###### FUNCTIONS - END ######

### INVENTORY PATHWAY ###
if ($action -eq 'Inventory') {
  $collectedAt = (Get-Date).ToUniversalTime().ToString('o')
  $inventoryRows = @()

  if ($getSqlInventory) {
    if ($hostNames.Count -gt 0) {
      Write-Host "Listing SQL instances on $($hostNames.Count) host(s)"
      $sqlHostNodes = @()
      foreach ($hn in $hostNames) {
        $found = @(Get-AllSqlHostInstances -hostName $hn | Where-Object { $_.name -eq $hn })
        if ($found.Count -eq 0) {
          Write-Host "  Host not found (exact name): $hn" -ForegroundColor Yellow
        }
        $sqlHostNodes += $found
      }
    } else {
      Write-Host "Listing every SQL host and its instances"
      $sqlHostNodes = @(Get-AllSqlHostInstances)
    }
    foreach ($hn in $sqlHostNodes) {
      $kids = @()
      if ($hn.instanceDescendantConnection.edges) {
        $kids = @($hn.instanceDescendantConnection.edges.node)
      }
      $base = [ordered]@{
        inventoryVersion = 1; workload = 'SQL'; collectedAt = $collectedAt
        host = $hn.name; hostId = $hn.id; clusterName = $hn.cluster.name; clusterId = $hn.cluster.id
      }
      if ($kids.Count -eq 0) {
        $inventoryRows += [pscustomobject]($base + [ordered]@{ rowType = 'Host'; objectName = ''; objectId = ''; objectType = ''; slaAssignment = ''; effectiveSla = ''; effectiveSlaId = ''; pendingSla = ''; pendingSlaId = ''; templateId = ''; templateName = ''; includes = ''; excludes = ''; exceptions = '' })
      }
      foreach ($k in $kids) {
        $inventoryRows += [pscustomobject]($base + [ordered]@{ rowType = 'Instance'; objectName = $k.name; objectId = $k.id; objectType = 'MssqlInstance'; slaAssignment = $k.slaAssignment; effectiveSla = $k.effectiveSlaDomain.name; effectiveSlaId = $k.effectiveSlaDomain.id; pendingSla = $k.pendingSla.name; pendingSlaId = $k.pendingSla.id; templateId = ''; templateName = ''; includes = ''; excludes = ''; exceptions = '' })
      }
    }
    $inventoryFile = "${csvOutputPrefix}sql_inventory-${dateString}.csv"
    $inventoryRows | Export-Csv -Path $inventoryFile -NoTypeInformation
    $hostCount = @($inventoryRows | Select-Object -ExpandProperty hostId -Unique).Count
    Write-Host ""
    Write-Host "SQL inventory: $hostCount host(s), $(@($inventoryRows | Where-Object { $_.rowType -eq 'Instance' }).Count) instance(s)" -ForegroundColor Green
    Write-Host "  $inventoryFile"
  } else {
    # The fileset inventory covers the one cluster named by -clusterName: resolve it once, the lookups then filter by it
    $script:clusterFilterId = Get-ClusterIdByName -name $clusterName
    Write-Host "Limiting the fileset inventory to cluster '$clusterName' ($script:clusterFilterId)"
    if ($hostNames.Count -gt 0) {
      Write-Host "Listing filesets on $($hostNames.Count) host(s) (host root $hostRoot)"
      $fsHostNodes = @()
      foreach ($hn in $hostNames) {
        $found = @(Get-AllPhysicalHostFilesets -hostName $hn | Where-Object { $_.name -eq $hn })
        if ($found.Count -eq 0) {
          Write-Host "  Host not found (exact name, host root $hostRoot): $hn" -ForegroundColor Yellow
        }
        $fsHostNodes += $found
      }
    } else {
      Write-Host "Listing every host and its filesets (host root $hostRoot)"
      $fsHostNodes = @(Get-AllPhysicalHostFilesets)
    }
    Write-Host "Listing fileset templates (host root $hostRoot)"
    $templateNodes = @(Get-AllFilesetTemplates)

    # One Template row per template, then one Host row per host (so a host with no filesets still carries its cluster),
    # then one Fileset row per fileset
    foreach ($t in $templateNodes) {
      $inventoryRows += [pscustomobject][ordered]@{
        inventoryVersion = 1; workload = 'Fileset'; collectedAt = $collectedAt; rowType = 'Template'
        host = ''; hostId = ''; clusterName = $t.cluster.name; clusterId = $t.cluster.id
        objectName = ''; objectId = ''; objectType = 'FilesetTemplate'; slaAssignment = ''; effectiveSla = ''; effectiveSlaId = ''; pendingSla = ''; pendingSlaId = ''
        templateId = $t.id; templateName = $t.name
        includes = (Join-Cell $t.includes); excludes = (Join-Cell $t.excludes); exceptions = (Join-Cell $t.exceptions)
      }
    }
    foreach ($hn in $fsHostNodes) {
      $kids = @()
      if ($hn.physicalChildConnection.edges) {
        $kids = @($hn.physicalChildConnection.edges.node)
      }
      $inventoryRows += [pscustomobject][ordered]@{
        inventoryVersion = 1; workload = 'Fileset'; collectedAt = $collectedAt; rowType = 'Host'
        host = $hn.name; hostId = $hn.id; clusterName = $hn.cluster.name; clusterId = $hn.cluster.id
        objectName = ''; objectId = ''; objectType = ''; slaAssignment = ''; effectiveSla = ''; effectiveSlaId = ''; pendingSla = ''; pendingSlaId = ''
        templateId = ''; templateName = ''; includes = ''; excludes = ''; exceptions = ''
      }
      foreach ($k in $kids) {
        $inventoryRows += [pscustomobject][ordered]@{
          inventoryVersion = 1; workload = 'Fileset'; collectedAt = $collectedAt; rowType = 'Fileset'
          host = $hn.name; hostId = $hn.id; clusterName = $hn.cluster.name; clusterId = $hn.cluster.id
          objectName = $k.name; objectId = $k.id; objectType = $k.objectType
          slaAssignment = $k.slaAssignment; effectiveSla = $k.effectiveSlaDomain.name; effectiveSlaId = $k.effectiveSlaDomain.id
          pendingSla = $k.pendingSla.name; pendingSlaId = $k.pendingSla.id
          templateId = $k.filesetTemplate.id; templateName = $k.filesetTemplate.name
          includes = (Join-Cell $k.pathIncluded); excludes = (Join-Cell $k.pathExcluded); exceptions = (Join-Cell $k.pathExceptions)
        }
      }
    }
    $inventoryFile = "${csvOutputPrefix}fileset_inventory-${dateString}.csv"
    $inventoryRows | Export-Csv -Path $inventoryFile -NoTypeInformation
    Write-Host ""
    Write-Host "Fileset inventory: $(@($inventoryRows | Where-Object { $_.rowType -eq 'Host' }).Count) host(s), $(@($inventoryRows | Where-Object { $_.rowType -eq 'Fileset' }).Count) fileset(s), $(@($inventoryRows | Where-Object { $_.rowType -eq 'Template' }).Count) template(s)" -ForegroundColor Green
    Write-Host "  $inventoryFile"
  }
  exit 0
}

# Resolve -clusterName once. Template and host lookups then filter by this cluster ID.
$script:clusterFilterId = ''
if ($clusterName) {
  $script:clusterFilterId = Get-ClusterIdByName -name $clusterName
  Write-Host "Limiting fileset lookups to cluster '$clusterName' ($script:clusterFilterId)"
}

# Resolve the target SLA. In Test the objects are returned to DO_NOT_PROTECT after each method.
$targetSpec = Resolve-SlaSpec -name $slaName -id $slaID
$baselineSpec = Resolve-SlaSpec -name 'DO_NOT_PROTECT'

if ($action -eq 'Test' -and $targetSpec.type -ne 'protectWithSlaId') {
  throw "In Test the target SLA must be an SLA Domain, not DO_NOT_PROTECT or NO_ASSIGNMENT."
}

### RESOLVE HOSTS FROM THE INVENTORY CSV ###
# Builds the same $hostObjs / $pendingHosts shape as the live lookups below, without querying RSC for hosts or objects.
# Rules: a listed host that is not in the inventory is skipped and logged. A host in the inventory that has no fileset
# from the template is added to $pendingHosts so the template is applied to it before the SLA.
$inventoryRowsAll = @()
$inventorySkipped = @()
if ($inventoryCsv) {
  $inventoryRowsAll = @(Read-InventoryCsv -path $inventoryCsv -expectedWorkload $workload)
  $invHosts = @($inventoryRowsAll | Where-Object { $_.rowType -in @('Host', 'Instance', 'Fileset') } | Group-Object -Property hostId)

  # The hosts to use: the host list if one was given, otherwise every host in the inventory
  $wantedHosts = @()
  if ($hostNames.Count -gt 0) {
    foreach ($hn in $hostNames) {
      $match = @($invHosts | Where-Object { $_.Group[0].host -eq $hn })
      if ($match.Count -eq 0) {
        $inventorySkipped += $hn
      } elseif ($match.Count -gt 1) {
        throw "Host '$hn' appears more than once in the inventory with different host IDs. Rerun the inventory."
      } else {
        $wantedHosts += $match[0]
      }
    }
  } else {
    $wantedHosts = $invHosts
  }

  $hostObjs = @()
  $hostErrors = @()
  $pendingHosts = @()

  if ($workload -eq 'SQL') {
    foreach ($g in $wantedHosts) {
      $first = $g.Group[0]
      $instRows = @($g.Group | Where-Object { $_.rowType -eq 'Instance' })
      if ($instRows.Count -eq 0) {
        if ($hostNames.Count -gt 0) {
          # The user named this host, so a host with nothing to protect is an error
          $hostErrors += "SQL host has no SQL instances in the inventory: $($first.host)"
        } else {
          # Whole-inventory run: one empty host should not block everything else, so skip it and say so
          Write-Host "Skipping SQL host with no SQL instances in the inventory: $($first.host)" -ForegroundColor Yellow
        }
        continue
      }
      $instances = @(foreach ($r in $instRows) {
        [pscustomobject]@{
          hostName = $first.host; hostId = $first.hostId; clusterId = $first.clusterId; clusterName = $first.clusterName
          instanceName = $r.objectName; instanceId = $r.objectId
          assignment = $r.slaAssignment; currentSla = $r.effectiveSla; currentSlaId = $r.effectiveSlaId
          state = [pscustomobject]@{ id = $r.objectId; slaAssignment = $r.slaAssignment; effectiveSlaDomain = [pscustomobject]@{ id = $r.effectiveSlaId; name = $r.effectiveSla }; pendingSla = $(if ($r.pendingSlaId) { [pscustomobject]@{ id = $r.pendingSlaId; name = $r.pendingSla } } else { $null }) }
          originalSpec = $baselineSpec
        }
      })
      $hostObjs += [pscustomobject]@{ name = $first.host; id = $first.hostId; instances = $instances }
    }
  } else {
    # The template: by ID, or by exact name, from the Template rows
    $invTemplateRows = @($inventoryRowsAll | Where-Object { $_.rowType -eq 'Template' })
    if ($filesetTemplateId) {
      $tmplMatch = @($invTemplateRows | Where-Object { $_.templateId -eq $filesetTemplateId })
      if ($tmplMatch.Count -eq 0) {
        Set-HostCsvNotRun -reason "fileset template ID '$filesetTemplateId' is not in the inventory"
        throw "Fileset template ID '$filesetTemplateId' is not in the inventory. Rerun -getFilesetInventory."
      }
      $filesetName = $tmplMatch[0].templateName
    } else {
      $tmplMatch = @($invTemplateRows | Where-Object { $_.templateName -eq $filesetName })
      if ($tmplMatch.Count -eq 0) {
        Set-HostCsvNotRun -reason "fileset template '$filesetName' is not in the inventory"
        throw "Fileset template '$filesetName' is not in the inventory. Check the name or rerun -getFilesetInventory."
      }
    }
    foreach ($g in $wantedHosts) {
      $first = $g.Group[0]
      $hostTemplate = @($tmplMatch | Where-Object { $_.clusterId -eq $first.clusterId })
      if ($hostTemplate.Count -ne 1) {
        $hostErrors += "Expected 1 fileset template '$filesetName' on cluster '$($first.clusterName)' for host $($first.host), found $($hostTemplate.Count)"
        continue
      }
      $tid = $hostTemplate[0].templateId
      $fsRows = @($g.Group | Where-Object { $_.rowType -eq 'Fileset' -and $_.templateId -eq $tid })
      $instances = @(foreach ($r in $fsRows) {
        [pscustomobject]@{
          hostName = $first.host; hostId = $first.hostId; clusterId = $first.clusterId; clusterName = $first.clusterName
          instanceName = $r.objectName; instanceId = $r.objectId
          assignment = $r.slaAssignment; currentSla = $r.effectiveSla; currentSlaId = $r.effectiveSlaId
          state = [pscustomobject]@{ id = $r.objectId; slaAssignment = $r.slaAssignment; effectiveSlaDomain = [pscustomobject]@{ id = $r.effectiveSlaId; name = $r.effectiveSla }; pendingSla = $(if ($r.pendingSlaId) { [pscustomobject]@{ id = $r.pendingSlaId; name = $r.pendingSla } } else { $null }) }
          action = 'Existing'; originalSpec = $baselineSpec
        }
      })
      $hostObjs += [pscustomobject]@{ name = $first.host; id = $first.hostId; clusterId = $first.clusterId; clusterName = $first.clusterName; templateId = $tid; instances = $instances }
    }
  }

  if ($hostErrors.Count -gt 0) {
    $hostErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Set-HostCsvNotRun -errors $hostErrors
    throw "Could not use all hosts from the inventory. Fix the list above (or rerun the inventory) and try again."
  }
  if ($inventorySkipped.Count -gt 0) {
    Write-Host "Skipping $($inventorySkipped.Count) host(s) that are not in the inventory: $($inventorySkipped -join ', ')" -ForegroundColor Yellow
  }
  if ($workload -eq 'Fileset') {
    $pendingHosts = @($hostObjs | Where-Object { @($_.instances).Count -eq 0 })
  }
  $allInstances = @(foreach ($h in $hostObjs) { $h.instances })
}

if ($inventoryCsv) {
  # Hosts and objects come from the inventory CSV (resolved above), so RSC is not queried for them
} elseif ($workload -eq 'SQL') {
  # Resolve each SQL host to its instances and capture the original assignments
  Write-Host "Resolving $($hostNames.Count) SQL host(s)"
  $hostObjs = @()
  $hostErrors = @()
  foreach ($hostName in $hostNames) {
    $found = @(Get-SqlHostInstances -hostName $hostName | Where-Object { $_.name -eq $hostName })
    if ($found.Count -eq 0) {
      $hostErrors += "No SQL host found with exact name: $hostName"
      continue
    } elseif ($found.Count -ge 2) {
      $hostErrors += "Multiple SQL hosts found with exact name: $hostName"
      continue
    }
    $instanceNodes = @()
    if ($found[0].instanceDescendantConnection.edges) {
      $instanceNodes = @($found[0].instanceDescendantConnection.edges.node)
    }
    if ($instanceNodes.Count -eq 0) {
      $hostErrors += "SQL host has no SQL instances: $hostName"
      continue
    }
    $instances = @()
    foreach ($node in $instanceNodes) {
      $instances += [pscustomobject]@{
        hostName = $found[0].name
        hostId = $found[0].id
        clusterId = $found[0].cluster.id
        clusterName = $found[0].cluster.name
        instanceName = $node.name
        instanceId = $node.id
        assignment = $node.slaAssignment
        currentSla = $node.effectiveSlaDomain.name
        state = [pscustomobject]@{ id = $node.id; slaAssignment = $node.slaAssignment; effectiveSlaDomain = $node.effectiveSlaDomain; pendingSla = $node.pendingSla }
        originalSpec = Get-OriginalSlaSpec -instance $node
      }
    }
    $hostObjs += [pscustomobject]@{
      name = $found[0].name
      id = $found[0].id
      instances = $instances
    }
  }

  if ($hostErrors.Count -gt 0) {
    $hostErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Set-HostCsvNotRun -errors $hostErrors
    throw "Could not resolve all SQL hosts. Fix the list above and rerun."
  }

  $allInstances = @(foreach ($h in $hostObjs) { $h.instances })

  # Test: every instance must start on DO_NOT_PROTECT, since that is what each method returns it to
  $notBaseline = @()
  if ($action -eq 'Test') {
    $notBaseline = @($allInstances | Where-Object { $_.originalSpec.type -ne 'doNotProtect' })
  }
  if ($notBaseline.Count -gt 0) {
    Write-Host "These instances are not on DO_NOT_PROTECT:" -ForegroundColor Red
    $notBaseline | Select-Object hostName, instanceName, assignment, currentSla | Format-Table -AutoSize | Out-String | Write-Host
    throw "All SQL instances must be on DO_NOT_PROTECT before the test. Set them to DO_NOT_PROTECT or remove those hosts."
  }
} else {
  $hostObjs = @()
  $hostErrors = @()
  $pendingHosts = @()

  # Fileset template by name or ID: find the template, then check each host for a fileset using it
  if ($filesetTemplateId) {
    Write-Host "Resolving fileset template ID '$filesetTemplateId'"
    $tmpl = $null
    try {
      $tmpl = Get-FilesetTemplateById -id $filesetTemplateId
    } catch {
      Set-HostCsvNotRun -reason "could not look up fileset template ID $filesetTemplateId"
      throw "Could not look up fileset template ID ${filesetTemplateId}: $($_.Exception.Message)"
    }
    if (-not $tmpl) {
      Set-HostCsvNotRun -reason "no fileset template found with ID $filesetTemplateId"
      throw "No fileset template found with ID: $filesetTemplateId"
    }
    $templates = @($tmpl)
    $filesetName = $tmpl.name
  } else {
    Write-Host "Resolving fileset template '$filesetName'"
    $templates = @(Get-FilesetTemplatesByName -name $filesetName | Where-Object { $_.name -eq $filesetName })
    if ($templates.Count -eq 0) {
      # Say where it looked, and check the other host root so the user is not left guessing
      $searched = $hostRoot
      if ($clusterName) { $searched = "$hostRoot on cluster '$clusterName'" }
      $otherRoot = 'LINUX_HOST_ROOT'
      if ($hostRoot -eq 'LINUX_HOST_ROOT') { $otherRoot = 'WINDOWS_HOST_ROOT' }
      $hint = ''
      try {
        $savedRoot = $hostRoot
        $hostRoot = $otherRoot
        $elsewhere = @(Get-FilesetTemplatesByName -name $filesetName | Where-Object { $_.name -eq $filesetName })
        $hostRoot = $savedRoot
        if ($elsewhere.Count -gt 0) {
          $where = (@($elsewhere | ForEach-Object { $_.cluster.name } | Select-Object -Unique) -join ', ')
          $hint = " A template with that name exists under $otherRoot (cluster: $where). Use -hostRoot $otherRoot."
        }
      } catch {
        $hostRoot = $savedRoot
      }
      Set-HostCsvNotRun -reason "no fileset template named '$filesetName' under $searched"
      throw "No fileset template found with exact name '$filesetName' under $searched.$hint"
    }
  }
  Write-Host "Resolving $($hostNames.Count) host(s)"
  foreach ($hostName in $hostNames) {
    $found = @(Get-PhysicalHostFilesets -hostName $hostName | Where-Object { $_.name -eq $hostName })
    if ($found.Count -eq 0) {
      $hostErrors += "No host found with exact name: $hostName (host root $hostRoot)"
      continue
    } elseif ($found.Count -ge 2) {
      $hostErrors += "Multiple hosts found with exact name: $hostName"
      continue
    }
    $h = $found[0]
    $hostTemplate = @($templates | Where-Object { $_.cluster.id -eq $h.cluster.id })
    if ($hostTemplate.Count -ne 1) {
      $hostErrors += "Expected 1 fileset template named '$filesetName' on cluster '$($h.cluster.name)' for host $hostName, found $($hostTemplate.Count)"
      continue
    }
    $children = @()
    if ($h.physicalChildConnection.edges) {
      $children = @($h.physicalChildConnection.edges.node)
    }
    $matching = @($children | Where-Object { $_.filesetTemplate.id -eq $hostTemplate[0].id })
    $instances = @()
    foreach ($node in $matching) {
      $instances += [pscustomobject]@{
        hostName = $h.name
        hostId = $h.id
        clusterId = $h.cluster.id
        clusterName = $h.cluster.name
        instanceName = $node.name
        instanceId = $node.id
        assignment = $node.slaAssignment
        currentSla = $node.effectiveSlaDomain.name
        state = [pscustomobject]@{ id = $node.id; slaAssignment = $node.slaAssignment; effectiveSlaDomain = $node.effectiveSlaDomain; pendingSla = $node.pendingSla }
        action = 'Existing'
        originalSpec = $baselineSpec
      }
    }
    $hostObjs += [pscustomobject]@{
      name = $h.name
      id = $h.id
      clusterId = $h.cluster.id
      clusterName = $h.cluster.name
      templateId = $hostTemplate[0].id
      instances = $instances
    }
  }

  if ($hostErrors.Count -gt 0) {
    $hostErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Set-HostCsvNotRun -errors $hostErrors
    throw "Could not resolve all hosts or filesets. Fix the list above and rerun."
  }

  # Hosts that do not have the fileset yet will get it created after confirmation
  $pendingHosts = @($hostObjs | Where-Object { @($_.instances).Count -eq 0 })
  $allInstances = @(foreach ($h in $hostObjs) { $h.instances })
}

### APPLY PATHWAY ###
if ($action -eq 'Apply') {
  # Fileset hosts that do not have the template yet get it applied after confirmation (see below)
  $needTemplateHosts = @()
  if ($workload -eq 'Fileset') {
    $needTemplateHosts = @($pendingHosts)
    $hostObjs = @($hostObjs | Where-Object { @($_.instances).Count -gt 0 })
  }
  foreach ($nh in $needTemplateHosts) {
    Write-Host "Host $($nh.name) does not have fileset template '$filesetName'. It will be applied." -ForegroundColor Yellow
  }
  $applyObjects = @(foreach ($h in $hostObjs) { $h.instances })
  if ($applyObjects.Count -eq 0 -and $needTemplateHosts.Count -eq 0) {
    if ($inventorySkipped.Count -gt 0) {
      # Every listed host was missing from the inventory: still write the Apply CSV so the skips are recorded
      Write-ApplyCsv -rows @($inventorySkipped | ForEach-Object {
          [pscustomobject]@{
            workload = $workload; host = $_; object = ''; objectId = ''; hostStatus = 'NotInInventory'; status = 'NotInInventory'
            error = 'Host is not in the inventory CSV, so it was skipped'
          }
        })
      Write-Host "WARNING: none of the $($inventorySkipped.Count) listed host(s) are in the inventory CSV, so nothing was assigned: $($inventorySkipped -join ', ')" -ForegroundColor Yellow
      Write-Host "Rerun the inventory to include them, or check the host names. Details: $csvApplyOutput" -ForegroundColor Yellow
      exit 1
    }
    throw "No objects were found to assign the SLA to."
  }

  # Every object already carries its current SLA state from the lookup in the previous step (live from RSC, or from the
  # inventory CSV), so there is no separate read. Decide which objects are already on the target SLA.
  if ($applyObjects.Count -eq 0) {
    Write-Host "No existing objects: every host needs the template applied first, and the new filesets are read after that"
  }
  $decisionById = @{}
  foreach ($o in $applyObjects) {
    $decisionById[$o.instanceId] = Get-SlaDecision -state $o.state -spec $targetSpec
  }
  $missingState = @($applyObjects | Where-Object { -not $_.state })
  if ($missingState.Count -gt 0) {
    Write-Host "No SLA state for $($missingState.Count) object(s), they will be assigned." -ForegroundColor Yellow
  }
  $todoObjects = @($applyObjects | Where-Object { $decisionById[$_.instanceId] -eq 'Assign' })
  $onTargetCount = @($applyObjects | Where-Object { $decisionById[$_.instanceId] -eq 'AlreadyOnTarget' }).Count
  $pendingCount = @($applyObjects | Where-Object { $decisionById[$_.instanceId] -eq 'SkippedPending' }).Count

  # Get-CallGroups returns the groups wrapped in one extra array (so a single group is not flattened), so take the call count from the inner array
  $plannedGroups = Get-CallGroups -objects $todoObjects -mode $applyMode -size $batchSize
  $callCount = $plannedGroups.Count
  $clusterCount = @($todoObjects | Select-Object -ExpandProperty clusterId -Unique).Count

  # Show the plan
  Write-Host ""
  Write-Host "Plan" -ForegroundColor Cyan
  Write-Host "  Action:                   Apply"
  if ($inventoryCsv) {
    Write-Host "  Source:                   Inventory CSV ($inventoryCsv)"
  } else {
    Write-Host "  Source:                   Live RSC lookup"
  }
  Write-Host "  Workload:                 $workload"
  Write-Host "  Assign mutation:          $assignMutation"
  Write-Host "  Target SLA:               $($targetSpec.label)"
  if ($applyMode -eq 'Bulk') {
    Write-Host "  Apply mode:               Bulk (up to $batchSize objects per call, never mixing clusters)"
  } else {
    Write-Host "  Apply mode:               Single (one call per host)"
  }
  Write-Host "  Poll for completion:      $(-not $skipPolling)"
  if ($inventorySkipped.Count -gt 0) {
    Write-Host "  Not in inventory:         $($inventorySkipped.Count) host(s) will be skipped: $($inventorySkipped -join ', ')" -ForegroundColor Yellow
  }
  if ($workload -eq 'Fileset') {
    Write-Host "  Fileset template:         $filesetName"
    Write-Host "  Hosts:                    $($hostObjs.Count) already have it, $($needTemplateHosts.Count) need it applied"
  } else {
    Write-Host "  Hosts:                    $($hostObjs.Count)"
  }
  Write-Host "  Objects:                  $($applyObjects.Count) existing, $($todoObjects.Count) to assign, $onTargetCount already on target, $pendingCount skipped (SLA pending)"
  if ($needTemplateHosts.Count -gt 0) {
    Write-Host "  Template applications:    $($needTemplateHosts.Count) host(s) in $(@($needTemplateHosts | Select-Object -ExpandProperty clusterId -Unique).Count) bulkCreateFilesets call(s), then the SLA goes on those new filesets too"
  }
  $skippedPendingObjs = @($applyObjects | Where-Object { $decisionById[$_.instanceId] -eq 'SkippedPending' })
  if ($inventorySkipped.Count -gt 0 -or $skippedPendingObjs.Count -gt 0) {
    Write-Host "  Skipped, no SLA will be assigned:" -ForegroundColor Yellow
    if ($inventorySkipped.Count -gt 0) {
      Write-Host "    Hosts not in the inventory ($($inventorySkipped.Count)): $($inventorySkipped -join ', ')" -ForegroundColor Yellow
    }
    if ($skippedPendingObjs.Count -gt 0) {
      Write-Host "    Objects with an SLA already pending ($($skippedPendingObjs.Count)): $((@($skippedPendingObjs | ForEach-Object { "$($_.hostName)/$($_.instanceName) (pending $($_.state.pendingSla.name))" })) -join ', ')" -ForegroundColor Yellow
    }
  }
  Write-Host "  API calls to assign:      $callCount across $clusterCount cluster(s) (plus any for the new filesets)"
  Write-Host ""
  $planRows = @(foreach ($o in $applyObjects) {
    [pscustomobject]@{
      hostName = $o.hostName
      cluster = $o.clusterName
      object = $o.instanceName
      assignment = $o.assignment
      currentSla = $o.currentSla
      pendingSla = $(if ($o.state.pendingSla) { $o.state.pendingSla.name } else { '' })
      action = $(switch ($decisionById[$o.instanceId]) { 'AlreadyOnTarget' { 'Skip: on target' } 'SkippedPending' { 'Skip: pending' } default { 'Assign' } })
    }
  })
  foreach ($nh in $needTemplateHosts) {
    $planRows += [pscustomobject]@{ hostName = $nh.name; cluster = $nh.clusterName; object = $filesetName; assignment = ''; currentSla = ''; pendingSla = ''; action = 'Apply template' }
  }
  $planRows | Select-Object hostName, cluster, object, action, currentSla, pendingSla, assignment | Format-Table -AutoSize -Wrap
  if ($todoObjects.Count -gt 0 -or $needTemplateHosts.Count -gt 0) {
    Write-Host "'$($targetSpec.label)' will be assigned to $($todoObjects.Count + $needTemplateHosts.Count) object(s). Existing snapshots are retained. Nothing is reverted afterwards." -ForegroundColor Yellow
  }
  if ($needTemplateHosts.Count -gt 0) {
    Write-Host "Fileset template '$filesetName' will be applied to $($needTemplateHosts.Count) host(s) with bulkCreateFilesets. The template itself is not changed, and it stays applied to those hosts." -ForegroundColor Yellow
  }
  Write-Host ""

  if ($dryRun) {
    Write-Host "Dry run, no changes made."
    exit 0
  }

  if (($todoObjects.Count -gt 0 -or $needTemplateHosts.Count -gt 0) -and -not $skipConfirm) {
    $answer = Read-Host "Type YES to continue"
    if ($answer -cne 'YES') {
      Write-Host "Cancelled, no changes made."
      exit 0
    }
  }

  # Apply the fileset template to the hosts that do not have it, then add the new filesets to the list.
  # Default: the fileset object IDs returned by the template call are added straight to the list (no lookups).
  # With -recheckFilesetIDs: each of those hosts is looked up again (one lookup per host) to get its filesets.
  $templateRows = @()
  $unverifiedTemplate = $false
  if ($needTemplateHosts.Count -gt 0) {
    Write-Host "Applying fileset template '$filesetName' to $($needTemplateHosts.Count) host(s) on cluster '$clusterName'" -ForegroundColor Cyan
    foreach ($clusterGroup in ($needTemplateHosts | Group-Object -Property clusterId)) {
      $definitions = @($clusterGroup.Group | ForEach-Object { @{ hostId = $_.id; templateId = $_.templateId } })
      $templateError = ''
      $createdIds = @()
      try {
        $createResult = New-FilesetsOnCluster -clusterId $clusterGroup.Name -definitions $definitions
        $createdIds = @(@($createResult.data.bulkCreateFilesets.data) | ForEach-Object { $_.filesetSummary.slaAssignable.id } | Where-Object { $_ })
        Write-Host "  Applied to $($clusterGroup.Count) host(s) in $([Math]::Round($createResult.seconds, 2))s, $($createdIds.Count) fileset ID(s) returned"
      } catch {
        $templateError = $_.Exception.Message
        Write-Host "  FAILED to apply the template to $($clusterGroup.Count) host(s): $templateError" -ForegroundColor Red
      }

      if ($templateError) {
        foreach ($h in $clusterGroup.Group) {
          $templateRows += [pscustomobject]@{
            workload = $workload; assignMutation = $assignMutation; applyMode = $applyMode
            host = $h.name; object = $filesetName; objectId = ''
            beforeAssignment = ''; beforeSla = ''; targetSla = $targetSpec.label
            callGroup = $null; callSec = $null; effectiveSec = $null
            status = 'TemplateFailed'; error = $templateError
          }
        }
        continue
      }

      if ($recheckFilesetIDs) {
        # Opt-in: one lookup per host, which also gives every new fileset its host
        foreach ($h in $clusterGroup.Group) {
          $newObjs = @()
          $found = @(Get-PhysicalHostFilesets -hostName $h.name | Where-Object { $_.id -eq $h.id })
          $children = @()
          if ($found.Count -eq 1 -and $found[0].physicalChildConnection.edges) {
            $children = @($found[0].physicalChildConnection.edges.node)
          }
          foreach ($node in @($children | Where-Object { $_.filesetTemplate.id -eq $h.templateId })) {
            $newObjs += [pscustomobject]@{
              hostName = $h.name
              hostId = $h.id
              clusterId = $h.clusterId
              clusterName = $h.clusterName
              instanceName = $node.name
              instanceId = $node.id
              assignment = $node.slaAssignment
              currentSla = $node.effectiveSlaDomain.name
              state = [pscustomobject]@{ id = $node.id; slaAssignment = $node.slaAssignment; effectiveSlaDomain = $node.effectiveSlaDomain; pendingSla = $node.pendingSla }
              originalSpec = $baselineSpec
            }
          }
          if ($newObjs.Count -eq 0) {
            $templateRows += [pscustomobject]@{
              workload = $workload; assignMutation = $assignMutation; applyMode = $applyMode
              host = $h.name; object = $filesetName; objectId = ''
              beforeAssignment = ''; beforeSla = ''; targetSla = $targetSpec.label
              callGroup = $null; callSec = $null; effectiveSec = $null
              status = 'TemplateFailed'; error = 'The fileset was not found on the host after applying the template'
            }
          } else {
            $applyObjects += $newObjs
          }
        }
      } else {
        # Default: add the returned fileset object IDs as they are. The response does not say which host each ID belongs to, so a
        # host is shown only when exactly one host was in the call. A new fileset has no SLA and nothing pending.
        $singleHost = $null
        if ($clusterGroup.Count -eq 1) { $singleHost = $clusterGroup.Group[0] }
        if ($createdIds.Count -ne $clusterGroup.Count) {
          $unverifiedTemplate = $true
          Write-Host "  WARNING: $($clusterGroup.Count) host(s) were sent but $($createdIds.Count) fileset ID(s) came back. Use -recheckFilesetIDs to confirm each host." -ForegroundColor Yellow
        }
        foreach ($oid in $createdIds) {
          $hostLabel = "(new on $($clusterGroup.Group[0].clusterName))"
          if ($singleHost) { $hostLabel = $singleHost.name }
          $applyObjects += [pscustomobject]@{
            hostName = $hostLabel
            hostId = $(if ($singleHost) { $singleHost.id } else { "new-$($clusterGroup.Name)" })
            clusterId = $clusterGroup.Name
            clusterName = $clusterGroup.Group[0].clusterName
            instanceName = $filesetName
            instanceId = $oid
            assignment = 'Unassigned'
            currentSla = ''
            state = [pscustomobject]@{ id = $oid; slaAssignment = 'Unassigned'; effectiveSlaDomain = [pscustomobject]@{ id = ''; name = '' }; pendingSla = $null }
            originalSpec = $baselineSpec
          }
        }
        # Any host that was in the call but that we cannot show a fileset for is still reported as template applied
      }
    }
  }

  # Create the Apply CSV before changing anything: one row per object with its starting SLA and status Pending. If the run is
  # interrupted this file still holds the starting state. It is rewritten with the results at the end.
  $startRows = @($applyObjects | ForEach-Object {
      [pscustomobject]@{
        workload = $workload
        host = $_.hostName
        cluster = $_.clusterName
        hostStatus = 'Pending'
        object = $_.instanceName
        objectId = $_.instanceId
        beforeAssignment = $_.assignment
        beforeSla = $_.currentSla
        beforeSlaId = $_.state.effectiveSlaDomain.id
        beforePendingSla = $_.state.pendingSla.name
        targetSla = $targetSpec.label
        assignMutation = $assignMutation
        applyMode = $applyMode
        callGroup = $null
        callSec = $null
        effectiveSec = $null
        status = 'Pending'
        error = ''
      }
    })
  Write-ApplyCsv -rows $startRows
  Write-Host "Apply CSV created (starting SLA of every object, rewritten with the results at the end): $csvApplyOutput" -ForegroundColor Green

  # Send the assignments and wait for completion
  $script:applyResults = $null
  $applyError = $null
  $applyRows = @()
  try {
    $applyRows = @(Invoke-ApplySla -objects $applyObjects -spec $targetSpec)
  } catch {
    $applyError = $_
    Write-Host "Apply stopped: $($_.Exception.Message)" -ForegroundColor Red
    if ($script:applyResults) {
      $applyRows = @($script:applyResults.Values)
    }
  }

  $applyRows += $templateRows

  $applyRows = @($applyRows | Sort-Object -Property host, object)

  # Per-host status: how many objects on each host got the SLA and how many did not
  $hostLogRows = @()
  $hostsInRun = @($applyRows | Where-Object { $_.status -ne 'NotInInventory' } | Group-Object -Property host)
  # Filesets returned by a multi-host template call are not tied to a host. They sit under '(new on <cluster>)'. That label is not a
  # host: its outcome is shared by the template-applied hosts that have no row of their own (built after this loop).
  $newOnGroups = @($hostsInRun | Where-Object { $_.Name -like '(new on *' })
  $hostsInRun = @($hostsInRun | Where-Object { $_.Name -notlike '(new on *' })
  foreach ($hg in ($hostsInRun | Sort-Object -Property Name)) {
    $rowsForHost = @($hg.Group)
    $okRows = @($rowsForHost | Where-Object { $_.status -in @('Applied', 'AlreadyOnTarget', 'Submitted') })
    $badRows = @($rowsForHost | Where-Object { $_.status -in @('CallFailed', 'Timeout', 'NotAttempted', 'TemplateFailed') })
    $skipRows = @($rowsForHost | Where-Object { $_.status -eq 'SkippedPending' })
    $tmplApplied = @($needTemplateHosts | Where-Object { $_.name -eq $hg.Name }).Count -gt 0 -and @($rowsForHost | Where-Object { $_.status -eq 'TemplateFailed' }).Count -eq 0
    if ($badRows.Count -eq 0 -and $skipRows.Count -eq 0) { $hostStatus = 'Assigned' }
    elseif ($okRows.Count -gt 0) { $hostStatus = 'Partial' }
    elseif ($badRows.Count -gt 0) { $hostStatus = 'Failed' }
    else { $hostStatus = 'Skipped' }
    $hostLogRows += [pscustomobject]@{
      workload = $workload
      host = $hg.Name
      status = $hostStatus
      templateApplied = $tmplApplied
      objects = $rowsForHost.Count
      slaAssigned = @($rowsForHost | Where-Object { $_.status -in @('Applied', 'Submitted') }).Count
      alreadyOnTarget = @($rowsForHost | Where-Object { $_.status -eq 'AlreadyOnTarget' }).Count
      skippedPending = $skipRows.Count
      notAssigned = $badRows.Count
      detail = (@(@($badRows) + @($skipRows) | ForEach-Object { "$($_.object): $($_.status)" }) -join '; ')
    }
  }
  if ($newOnGroups.Count -gt 0) {
    $sharedRows = @($newOnGroups | ForEach-Object { $_.Group })
    $sharedBad = @($sharedRows | Where-Object { $_.status -in @('CallFailed', 'Timeout', 'NotAttempted') })
    $sharedSkip = @($sharedRows | Where-Object { $_.status -eq 'SkippedPending' })
    $sharedOk = @($sharedRows | Where-Object { $_.status -in @('Applied', 'AlreadyOnTarget', 'Submitted') })
    if ($sharedBad.Count -eq 0 -and $sharedSkip.Count -eq 0) { $sharedStatus = 'Assigned' }
    elseif ($sharedOk.Count -gt 0) { $sharedStatus = 'Partial' }
    elseif ($sharedBad.Count -gt 0) { $sharedStatus = 'Failed' }
    else { $sharedStatus = 'Skipped' }
    $haveRow = @{}
    foreach ($hl in $hostLogRows) { $haveRow[$hl.host.ToLower()] = $true }
    $failedTemplateHosts = @($applyRows | Where-Object { $_.status -eq 'TemplateFailed' } | ForEach-Object { "$($_.host)".ToLower() })
    foreach ($nh in $needTemplateHosts) {
      if ($haveRow.ContainsKey($nh.name.ToLower()) -or $failedTemplateHosts -contains $nh.name.ToLower()) { continue }
      $hostLogRows += [pscustomobject]@{
        workload = $workload
        host = $nh.name
        status = $sharedStatus
        templateApplied = $true
        objects = $sharedRows.Count
        slaAssigned = @($sharedRows | Where-Object { $_.status -in @('Applied', 'Submitted') }).Count
        alreadyOnTarget = @($sharedRows | Where-Object { $_.status -eq 'AlreadyOnTarget' }).Count
        skippedPending = $sharedSkip.Count
        notAssigned = $sharedBad.Count
        detail = $(if ($unverifiedTemplate) { 'unverified: fewer fileset IDs came back than hosts were sent, rerun with -recheckFilesetIDs to confirm this host' } else { 'new filesets on the cluster, shared result (not tied to this host)' })
      }
    }
  }
  foreach ($sk in $inventorySkipped) {
    $hostLogRows += [pscustomobject]@{
      workload = $workload; host = $sk; status = 'NotInInventory'; templateApplied = $false
      objects = 0; slaAssigned = 0; alreadyOnTarget = 0; notAssigned = 0
      detail = 'Host is not in the inventory CSV, so it was skipped'
    }
  }
  $hostStatusByHost = @{}
  foreach ($hl in $hostLogRows) { $hostStatusByHost[$hl.host.ToLower()] = $hl.status }

  # Rewrite the single Apply CSV: each object keeps its starting SLA from the first write and gains its outcome and the host status.
  # Hosts that never produced an object (template failed, not in the inventory) get a row with no object.
  $startById = @{}
  foreach ($r in $startRows) { $startById[$r.objectId] = $r }
  $finalRows = @()
  foreach ($r in $applyRows) {
    $start = $null
    if ($r.objectId -and $startById.ContainsKey($r.objectId)) { $start = $startById[$r.objectId] }
    $hs = ''
    if ($hostStatusByHost.ContainsKey("$($r.host)".ToLower())) { $hs = $hostStatusByHost["$($r.host)".ToLower()] }
    $finalRows += [pscustomobject]@{
      workload = $workload
      host = $r.host
      cluster = $(if ($start) { $start.cluster } else { '' })
      hostStatus = $hs
      object = $r.object
      objectId = $r.objectId
      beforeAssignment = $(if ($start) { $start.beforeAssignment } else { $r.beforeAssignment })
      beforeSla = $(if ($start) { $start.beforeSla } else { $r.beforeSla })
      beforeSlaId = $(if ($start) { $start.beforeSlaId } else { '' })
      beforePendingSla = $(if ($start) { $start.beforePendingSla } else { '' })
      targetSla = $r.targetSla
      assignMutation = $assignMutation
      applyMode = $applyMode
      callGroup = $r.callGroup
      callSec = $r.callSec
      effectiveSec = $r.effectiveSec
      status = $r.status
      error = $r.error
    }
  }
  foreach ($sk in $inventorySkipped) {
    $finalRows += [pscustomobject]@{
      workload = $workload; host = $sk; hostStatus = 'NotInInventory'; object = ''; objectId = ''
      beforeAssignment = ''; beforeSla = ''; beforeSlaId = ''; beforePendingSla = ''
      targetSla = $targetSpec.label; assignMutation = $assignMutation; applyMode = $applyMode
      callGroup = $null; callSec = $null; effectiveSec = $null; status = 'NotInInventory'
      error = 'Host is not in the inventory CSV, so it was skipped'
    }
  }
  Write-ApplyCsv -rows $finalRows

  # Record each host's outcome in the 'executed' column of the host CSV (-sqlCsvPath / -filesetCsvPath)
  if ($script:hostCsvInfo) {
    $executedByHost = @{}
    foreach ($hl in $hostLogRows) {
      switch ($hl.status) {
        'Assigned' {
          if ($hl.templateApplied -and $hl.detail -like 'unverified:*') { $text = 'TemplateApplied+Assigned (unverified, fewer fileset IDs than hosts, use -recheckFilesetIDs)' }
          elseif ($hl.templateApplied) { $text = 'TemplateApplied+Assigned' }
          elseif ($hl.objects -gt 0 -and $hl.alreadyOnTarget -eq $hl.objects) { $text = 'AlreadyOnTarget' }
          else { $text = 'Assigned' }
        }
        'Partial' { $text = "Partial: $($hl.slaAssigned + $hl.alreadyOnTarget) of $($hl.objects) objects, $($hl.detail)" }
        'Failed' { $text = "Failed: $($hl.detail)" }
        'Skipped' { $text = "Skipped: pending SLA, $($hl.detail)" }
        'NotInInventory' { $text = 'Skipped: not in inventory' }
        default { $text = "$($hl.status)" }
      }
      $executedByHost[$hl.host.ToLower()] = $text
    }
    Update-HostCsvExecuted -executedByHost $executedByHost
  }

  Write-Host ""
  Write-Host "Apply CSV (starting SLA, outcome and host status for every object):" -ForegroundColor Green
  Write-Host "  $csvApplyOutput"
  Write-Host ""
  Write-Host "Results" -ForegroundColor Cyan
  $applyRows | Group-Object -Property status | Sort-Object -Property Name | Select-Object @{ Name = 'status'; Expression = { $_.Name } }, Count | Format-Table -AutoSize

  $problemRows = @($applyRows | Where-Object { $_.status -in @('CallFailed', 'Timeout', 'NotAttempted', 'TemplateFailed') })
  if ($problemRows.Count -gt 0) {
    Write-Host "Objects that need attention:" -ForegroundColor Red
    $problemRows | Select-Object host, object, status, error | Format-Table -AutoSize
  }
  Write-Host "Hosts" -ForegroundColor Cyan
  $hostLogRows | Group-Object -Property status | Sort-Object -Property Name | Select-Object @{ Name = 'status'; Expression = { $_.Name } }, Count | Format-Table -AutoSize
  $skippedAtEnd = @($applyRows | Where-Object { $_.status -eq 'SkippedPending' })
  if ($skippedAtEnd.Count -gt 0) {
    Write-Host "NOTE: $($skippedAtEnd.Count) object(s) were skipped because an SLA was already pending on them, so no SLA was assigned. Rerun once the pending SLA has finished:" -ForegroundColor Yellow
    $skippedAtEnd | Select-Object host, object, status | Format-Table -AutoSize
  }
  if ($inventorySkipped.Count -gt 0) {
    Write-Host "WARNING: $($inventorySkipped.Count) host(s) were not in the inventory CSV and were skipped, so no SLA was assigned on them:" -ForegroundColor Yellow
    $inventorySkipped | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host "Rerun the inventory to include them, or check the host names. Details: $csvApplyOutput" -ForegroundColor Yellow
  }
  if ($problemRows.Count -gt 0 -or $applyError) {
    exit 1
  }
  exit 0
}

### TEST PATHWAY ###
# Show the plan
if ($workload -eq 'SQL') {
  $callsPerRun = @{ 'Single' = $hostObjs.Count; 'Bulk' = 1 }
  if ($setHostLogRetention) {
    $callsPerRun['Single'] = $hostObjs.Count * 2
    $callsPerRun['Bulk'] = 2
  }
} else {
  $callsPerRun = @{ 'Single' = $hostObjs.Count; 'Bulk' = 1 }
}
Write-Host ""
Write-Host "Plan" -ForegroundColor Cyan
Write-Host "  Action:                   Test"
Write-Host "  Workload:                 $workload"
Write-Host "  Assign mutation:          $assignMutation"
Write-Host "  Target SLA:               $($targetSpec.label)"
if ($workload -eq 'SQL') {
  Write-Host "  Start / end SLA:          $($baselineSpec.label)"
} else {
  Write-Host "  Start SLA:                not checked"
  Write-Host "  Revert SLA:               $($baselineSpec.label)"
}
Write-Host "  Mode:                     $mode"
if ($workload -eq 'SQL') {
  Write-Host "  Hosts / instances:        $($hostObjs.Count) / $($allInstances.Count)"
  Write-Host "  Set host log retention:   $([bool]$setHostLogRetention)"
} else {
  Write-Host "  Hosts / filesets:         $($hostObjs.Count) / $($allInstances.Count) existing + $($pendingHosts.Count) to create"
}
Write-Host "  API calls per phase:      Single = $($callsPerRun['Single']), Bulk = $($callsPerRun['Bulk'])"
Write-Host ""
if ($workload -eq 'SQL') {
  $allInstances | Select-Object hostName, instanceName, assignment, currentSla | Format-Table -AutoSize
  Write-Host "Each method assigns '$($targetSpec.label)' and then sets the instances back to '$($baselineSpec.label)'. Both phases are timed." -ForegroundColor Yellow
  if ($setHostLogRetention) {
    Write-Host "Host log retention will be set to -1, which immediately deletes log backup files on these hosts." -ForegroundColor Yellow
  }
} else {
  $planRows = @()
  foreach ($h in $hostObjs) {
    if (@($h.instances).Count -eq 0) {
      $planRows += [pscustomobject]@{ hostName = $h.name; fileset = $filesetName; action = 'Will create'; assignment = ''; currentSla = '' }
    } else {
      foreach ($inst in $h.instances) {
        $planRows += [pscustomobject]@{ hostName = $h.name; fileset = $inst.instanceName; action = 'Existing'; assignment = $inst.assignment; currentSla = $inst.currentSla }
      }
    }
  }
  $planRows | Format-Table -AutoSize
  Write-Host "Each method assigns '$($targetSpec.label)' and then sets the filesets to '$($baselineSpec.label)'. Both phases are timed. Filesets are not set back to their starting SLA." -ForegroundColor Yellow
  if ($pendingHosts.Count -gt 0) {
    Write-Host "The fileset template '$filesetName' will be applied to $($pendingHosts.Count) host(s) with bulkCreateFilesets. Those filesets are left on the hosts." -ForegroundColor Yellow
  }
}
Write-Host ""


if ($dryRun) {
  Write-Host "Dry run, no changes made."
  exit 0
}

if (-not $skipConfirm) {
  $answer = Read-Host "Type YES to continue"
  if ($answer -cne 'YES') {
    Write-Host "Cancelled, no changes made."
    exit 0
  }
}

# Fileset mode: apply the template to hosts that do not have it yet, then look the filesets up again
if ($workload -eq 'Fileset' -and $pendingHosts.Count -gt 0) {
  Write-Host "Creating fileset '$filesetName' on $($pendingHosts.Count) host(s)" -ForegroundColor Cyan
  foreach ($clusterGroup in ($pendingHosts | Group-Object -Property clusterId)) {
    $definitions = @($clusterGroup.Group | ForEach-Object { @{ hostId = $_.id; templateId = $_.templateId } })
    $createResult = New-FilesetsOnCluster -clusterId $clusterGroup.Name -definitions $definitions
    $created = @($createResult.data.bulkCreateFilesets.data)
    Write-Host "  Created $($created.Count) fileset(s) on cluster $($clusterGroup.Name) in $([Math]::Round($createResult.seconds, 2))s"
  }
  # The create response may not map each fileset to its host, so look every pending host up again
  foreach ($h in $pendingHosts) {
    $found = @(Get-PhysicalHostFilesets -hostName $h.name | Where-Object { $_.id -eq $h.id })
    $children = @()
    if ($found.Count -eq 1 -and $found[0].physicalChildConnection.edges) {
      $children = @($found[0].physicalChildConnection.edges.node)
    }
    $matching = @($children | Where-Object { $_.filesetTemplate.id -eq $h.templateId })
    if ($matching.Count -eq 0) {
      throw "The fileset was not found on host $($h.name) after bulkCreateFilesets."
    }
    $h.instances = @(foreach ($node in $matching) {
      [pscustomobject]@{
        hostName = $h.name
        hostId = $h.id
        instanceName = $node.name
        instanceId = $node.id
        assignment = $node.slaAssignment
        currentSla = $node.effectiveSlaDomain.name
        action = 'Created'
        originalSpec = $baselineSpec
      }
    })
  }
  $allInstances = @(foreach ($h in $hostObjs) { $h.instances })
}

# Run the test
$allRuns = @()
$allInstanceRows = @()
$runError = $null
$modified = $false

try {
  switch ($mode) {
    'Single' { $modes = @('Single') }
    'Bulk' { $modes = @('Bulk') }
    'Both' { $modes = @('Single', 'Bulk') }
  }
  foreach ($m in $modes) {
    Write-Host "$m" -ForegroundColor Cyan
    $modified = $true
    $assign = Invoke-TimedPhase -runMode $m -phase 'Assign' -hostObjs $hostObjs -spec $targetSpec
    $allRuns += $assign.summary
    $allInstanceRows += $assign.instances
    $revert = Invoke-TimedPhase -runMode $m -phase 'Revert' -hostObjs $hostObjs -spec $baselineSpec
    $allRuns += $revert.summary
    $allInstanceRows += $revert.instances
    # Nothing to restore if every instance is back on the starting SLA
    if ($revert.summary.status -eq 'OK') {
      $modified = $false
    }
  }
} catch {
  $runError = $_
  Write-Host "Test stopped: $($_.Exception.Message)" -ForegroundColor Red
} finally {
  if ($modified) {
    Restore-OriginalSla -instances $allInstances
  }
}

# Export results, including partial results if the test stopped early
if ($allRuns.Count -gt 0) {
  $allRuns | Export-Csv -Path $csvRunsOutput -NoTypeInformation
  $allInstanceRows | Export-Csv -Path $csvInstancesOutput -NoTypeInformation
  Write-Host ""
  Write-Host "CSV files:" -ForegroundColor Green
  Write-Host "  $csvRunsOutput"
  Write-Host "  $csvInstancesOutput"

  Write-Host ""
  Write-Host "Single vs Bulk by phase (wall = first mutation sent until every instance is effective)" -ForegroundColor Cyan
  $allRuns | Select-Object mode, phase, apiCalls, callSecTotal, callSecMax, wallSecToAllEffective, instanceSecAvg, instanceSecMax, failedInstances, timedOutInstances, status | Format-Table -AutoSize

  Write-Host "Total per method (Assign + Revert)" -ForegroundColor Cyan
  $allRuns | Group-Object -Property mode | ForEach-Object {
    $allOk = (@($_.Group | Where-Object { $_.status -ne 'OK' }).Count -eq 0)
    [pscustomobject]@{
      mode = $_.Name
      phases = $_.Count
      apiCalls = ($_.Group.apiCalls | Measure-Object -Sum).Sum
      wallSecTotal = if ($allOk) { [Math]::Round(($_.Group.wallSecToAllEffective | Measure-Object -Sum).Sum, 2) } else { $null }
      status = if ($allOk) { 'OK' } else { 'Incomplete' }
    }
  } | Format-Table -AutoSize
} else {
  Write-Host "No completed runs to export."
}

if ($runError) {
  exit 1
}
