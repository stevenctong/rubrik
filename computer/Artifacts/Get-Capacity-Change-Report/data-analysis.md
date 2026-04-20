# Source Data Analysis

## Source CSVs

Both CSVs share the same schema (31 columns) and come from the RSC "Object Capacity Over Time" report.

### rsc_object_capacity_over_time_past_30_days.csv
- **Rows:** 87,174
- **Distinct objects:** 3,102
- **Time granularity:** Daily (29 days: Mar 21 - Apr 18, 2026)
- **Time format:** `"MMM DD, YYYY"` (e.g. `"Apr 01, 2026"`)

### rsc_object_capacity_over_time_past_12_months.csv
- **Rows:** 7,872
- **Distinct objects:** 3,201
- **Time granularity:** Monthly (2 months: Feb 2026, Mar 2026 — only 2 months available in demo env)
- **Time format:** `"MMM YYYY"` (e.g. `"Feb 2026"`)

### Object types (50 types across both)
AHV VM, AWS DynamoDB Table, AWS EBS Volume, AWS RDS Instance, AWS S3 Bucket, Active Directory Domain Controller, Azure DevOps Repository, Azure Managed Disk, Azure SQL Database, Azure Storage Account, Azure VM, Db2 Database, EC2 instance, Exchange Database, Exchange Mailbox, GCP Cloud SQL Instance, GCP Disk, GCP GCE Instance, GitHub Repository, Google Workspace Shared Drive, Google Workspace User Drive, Google Workspace User Mailbox, Hyper-V VM, Jira Project, Jira Settings, K8s Protection Set, K8s Virtual Machine, Linux fileset, Managed Volume, Microsoft 365 file, Microsoft Entra ID, MongoDB Database, MongoDB Source, MySQL Instance, NAS Cloud Direct, NAS Fileset, OLVM Virtual Machine, OneDrive, Oracle DB, Postgres Database Cluster, SAP HANA Database, SAP HANA System, SQL Server DB, Salesforce Metadata, Salesforce Object, Site, Teams, Windows fileset, Windows volumes, vSphere VM

---

## Schema (31 columns)

| # | Column | Description |
|---|--------|-------------|
| 1 | Time | Date of the data point |
| 2 | Cluster Name | Rubrik cluster or "Rubrik Security Cloud" |
| 3 | Object Name | Name of the protected object |
| 4 | Location | Host/vCenter/etc |
| 5 | Object Type | Workload type (vSphere VM, SQL Server DB, etc.) |
| 6 | **Logical Bytes** | Front-end provisioned size of object (raw bytes) |
| 7 | **Data Stored** | Data on Rubrik after reduction, across retention (raw bytes) |
| 8 | **Local Storage** | Same as Data Stored — local Rubrik storage used (raw bytes) |
| 9 | Data Transferred | Data transferred during backups |
| 10 | SLA Domain | Assigned SLA policy |
| 11 | **Archive Storage** | Data stored in archive target (raw bytes) |
| 12 | **Replica Storage** | Data stored on replication target (raw bytes) |
| 13 | Local Metered Data | Metered data for billing |
| 14 | **Used Size** | Consumed/written bytes on disk (raw bytes) |
| 15 | **Provisioned Size** | Provisioned capacity of object (raw bytes) |
| 16 | Local Protected Data | Protected data size |
| 17 | Local Effective Storage | Effective storage after reduction |
| 18 | Local CDP Log Storage | CDP log storage |
| 19 | Local CDP Throughput | CDP throughput |
| 20 | Archive Effective Data Transferred | Effective data transferred to archive |
| 21 | Archive Effective Logical Data | Effective logical data in archive |
| 22 | Local Data Reduction | Percentage string (e.g. "51%") |
| 23 | Local Dedup Ratio | Ratio string (e.g. "2.05 x") |
| 24 | Local Logical Data Reduction | Percentage string |
| 25 | Local Logical Dedup Ratio | Ratio string |
| 26 | Archive Data Reduction | Percentage string |
| 27 | Archive Dedup Ratio | Ratio string |
| 28 | Archive Logical Data Reduction | Percentage string |
| 29 | Archive Logical Dedup Ratio | Ratio string |
| 30 | Protected On | Date first protected |
| 31 | NCD Snapshot Type | NAS Cloud Direct snapshot type |

---

## Key Capacity Fields & Equivalences

Per Steven's definitions, these are the capacity metrics that matter:

### 1. Front-End Size (Logical/Provisioned)
- **Logical Bytes** = total provisioned size of all disks/data for the object
- **Provisioned Size** = equivalent meaning
- **Reality:** These are NOT always equal in the data. When both are populated, they differ in 11,641 of 14,456 rows (80%). Logical Bytes tends to be the larger "total provisioned" value; Provisioned Size can be a subset.
- **Fill logic:** If one is populated and the other is 0/empty, copy the populated value to the other.

### 2. Consumed Size on Source
- **Used Size** = bytes actually written/consumed on disk
- Populated in ~24% of rows. No equivalent column to backfill from.

### 3. Rubrik Local Storage (after data reduction, across retention)
- **Data Stored** = data on Rubrik for the object
- **Local Storage** = equivalent meaning
- **Reality:** Very closely aligned. When both > 0, they match in 24,427 of 25,175 rows (97%). Data Stored is a superset — 1,724 rows have DS only, 0 rows have LS only.
- **Fill logic:** If one is populated and the other is 0/empty, copy the populated value to the other.

### 4. Archive Storage
- **Archive Storage** = data in archive target
- Populated in ~10% of rows.

### 5. Replica Storage
- **Replica Storage** = data on replication target
- Populated in ~5% of rows.

---

## Data Characteristics

- **Units:** All size fields are in raw bytes (not GB/TB)
- **Missing values:** Empty string or `"N/A"` — both mean "not applicable/available"
- **Zero vs missing:** Many objects report 0 for fields that don't apply (e.g. cloud workloads show 0 for Used Size/Provisioned Size). This is distinct from N/A.
- **Object identity:** Unique key is likely `(Object Name, Location, Object Type)` or `(Object Name, Cluster Name)` — Object Name alone can have duplicates across clusters.
- **Time coverage:** Not all objects appear at every time point — objects can appear/disappear as protection changes.

---

## Important Note on Logical Bytes vs Provisioned Size

These fields are described as "equivalent" but behave differently in practice:
- **Logical Bytes** is populated more often (29% vs 18% of rows)
- When both are populated, they frequently differ
- Example: `sh1-ad02.rubrikgaia.lab` (AD DC) — Logical Bytes: 497 GB, Provisioned Size: 134 GB
- Example: `sh2-tenant-a-lin01` (vSphere VM) — Logical Bytes: 446 GB, Provisioned Size: 17 GB

For the backfill logic, we should only fill in the empty one when the other has data — we should NOT overwrite when both already have values.
