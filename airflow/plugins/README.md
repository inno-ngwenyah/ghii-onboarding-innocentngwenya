# Paediatric Vitals ETL Pipeline

An Apache Airflow pipeline that extracts weight and height observations
for HIV-enrolled clients aged under 15 years from the ohdl Clinical
Data Repository (CDR), covering multiple sites across Malawi.

Built by the MEDU Data Team.

---

## Table of Contents

- [Overview](#overview)
- [Pipeline Architecture](#pipeline-architecture)
- [Folder Structure](#folder-structure)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Airflow Setup](#airflow-setup)
- [Running the Pipeline](#running-the-pipeline)
- [Site Filter Behaviour](#site-filter-behaviour)
- [Data Quality Checks](#data-quality-checks)
- [Post-Load Summary Report](#post-load-summary-report)
- [Output Tables](#output-tables)
- [Design Decisions](#design-decisions)
- [Troubleshooting](#troubleshooting)
- [Future Improvements](#future-improvements)

---

## Overview

| Item | Detail |
|---|---|
| **DAG ID** | `paeds_vitals_etl` |
| **Schedule** | `@monthly` |
| **Source** | ohdl_db — `obs`, `patient_program`, `person`, `patient_state` |
| **Target** | `ghii_etl.dr_paed_vitals_per_visit_innocent` |
| **Date window** | 2020-01-01 → 2024-12-31 (configurable via Variables) |
| **Population** | HIV-enrolled clients with at least one ON ART state overlapping the window, aged < 15 at time of visit |
| **Variables extracted** | Facility District, Facility Name, Patient ID, Gender, Birth Date, Visit Date, Age at Visit, Weight (kg), Height (cm) |
| **De-identification** | First name and last name deliberately excluded |
| **Parallelism** | One Airflow task per site, up to `MAX_CONCURRENT_SITES` running simultaneously |

---

## Pipeline Architecture

```
create_schema
      │
create_staging_table
      │
create_final_table
      │
truncate_staging
      │
get_sites
  (queries obs to discover which sites have data in the window)
      │
      ├── extract_one_site [0]  ─ site 207 (Kalikumbi HC)     ┐
      ├── extract_one_site [1]  ─ site 413 (Mimosa Dispensary) ├─ parallel
      └── extract_one_site [2]  ─ site 611 (Police Area 30)   ┘
      │
dq_checks
  (validates staging — blocks load if critical issues found)
      │
load_final
  (deduplicates and loads into final table)
      │
post_load_summary
  (logs row counts, site breakdown, vitals coverage, age/gender split)
```

**Total tasks:** 9 (3 setup + 1 truncate + 1 site discovery + N extracts + 1 DQ + 1 load + 1 summary)

---

## Folder Structure

```
~/airflow/
├── dags/
│   └── paeds_vitals_etl.py        ← DAG definition (tasks + dependency chain only)
│
└── plugins/
    └── paeds_vitals/
        ├── __init__.py             ← makes the folder a Python package
        ├── config.py               ← all Variables, settings, fetch_active_sites()
        ├── sql.py                  ← all SQL statements and build_extract_sql()
        └── dq.py                   ← DQ checks, run_dq_checks(), log_load_summary()
```

**Rule:** The DAG file imports everything and defines nothing. All logic
lives in the package under `plugins/paeds_vitals_etl/`.

---

## Prerequisites

**System packages (Ubuntu 24.04):**
```bash
sudo apt update
sudo apt install -y pkg-config default-libmysqlclient-dev build-essential
```

**Python packages:**
```bash
pip install apache-airflow
pip install apache-airflow-providers-mysql
pip install apache-airflow-providers-common-sql
pip install mysqlclient
pip install pandas
```

**Airflow version:** 2.8+ (uses `SQLExecuteQueryOperator` and `@task` dynamic mapping)

---

## Installation

**1. Start Airflow (first time):**
```bash
airflow standalone
```
This initialises the database and creates `~/airflow/airflow.cfg`.

**2. Create the plugins package folder:**
```bash
mkdir -p ~/airflow/plugins/paeds_vitals
```

**3. Copy files to the correct locations:**
```bash
# Package files
cp __init__.py  ~/airflow/plugins/paeds_vitals/
cp config.py    ~/airflow/plugins/paeds_vitals/
cp sql.py       ~/airflow/plugins/paeds_vitals/
cp dq.py        ~/airflow/plugins/paeds_vitals/

# DAG file
cp paeds_vitals_etl.py  ~/airflow/dags/
```

**4. Verify the package imports correctly:**
```bash
source ~/airflow/airflow_env/bin/activate
export PYTHONPATH="/home/$USER/airflow/plugins:$PYTHONPATH"
python3 -c "from paeds_vitals.config import CONN_ID; print('Package OK — CONN_ID:', CONN_ID)"
```

**5. Verify the DAG parses cleanly:**
```bash
python3 ~/airflow/dags/paeds_vitals_etl.py
```
No output = no errors.

**6. Silence VS Code Pylance import warnings:**

Create `~/airflow/.vscode/settings.json`:
```json
{
    "python.analysis.extraPaths": [
        "/home/innocent/airflow/plugins"
    ]
}
```

---

## Configuration

All runtime settings are controlled via **Admin → Variables** in the Airflow UI.
No code changes are needed to adjust dates, sites, schema, or email.

### Airflow Variables

| Key | Example Value | Purpose |
|---|---|---|
| `paeds_date_from` | `2020-01-01` | Extract window start date |
| `paeds_date_to` | `2024-12-31` | Extract window end date |
| `etl_target_schema` | `ghii_etl` | MySQL schema for staging and final tables |
| `alert_email` | `ngwenyahinnocent@gmail.com` | Email address for failure notifications |
| `paeds_site_filter` | `207,413,611` | Comma-separated site IDs to process (empty = all sites) |

**To add a Variable:** Admin → Variables → + Add a new record

**To edit a Variable:** Admin → Variables → click the pencil icon on the row

### Hardcoded settings (edit in `config.py`)

| Setting | Default | Purpose |
|---|---|---|
| `CONN_ID` | `mysql_ohdl_database` | Airflow Connection Id for the ohdl_db database |
| `MAX_CONCURRENT_SITES` | `10` | Maximum parallel site extract tasks |

---

## Airflow Setup

### 1. Enable connection testing
In `~/airflow/airflow.cfg`, find and set:
```ini
test_connection = Enabled
```
Restart Airflow after saving.

### 2. Create the MySQL connection

Admin → Connections → + Add a new record:

| Field | Value |
|---|---|
| Connection Id | `mysql_ohdl_database` |
| Connection Type | `MySQL` |
| Host | `localhost` |
| Port | `3306` |
| Schema | `ohdl_db` |
| Login | root |
| Password | root |

Click **Test** to confirm, then **Save**.

### 3. Create the database pool

Admin → Pools → + Add:

| Field | Value |
|---|---|
| Pool | `ghii_etl_db_pool` |
| Slots | `10` |
| Description | Max concurrent ohdl_db extract tasks |

Adjust slots up or down based on your MySQL server's capacity.

### 4. Configure email alerts (optional)

In `~/airflow/airflow.cfg`:
```ini
[smtp]
smtp_host = smtp.gmail.com
smtp_starttls = True
smtp_ssl = False
smtp_port = 587
smtp_mail_from = your@email.com
```

Add an SMTP connection in Admin → Connections:

| Field | Value |
|---|---|
| Connection Id | `smtp_default` |
| Connection Type | `Email` |
| Host | `smtp.gmail.com` |
| Port | `587` |
| Login | your Gmail address |
| Password | your Gmail App Password |

> Gmail requires a 16-character App Password — generate one at
> myaccount.google.com → Security → App Passwords.

---

## Running the Pipeline

**Trigger manually from the UI:**
1. Go to `http://localhost:8080`
2. Find `paeds_vitals_etl` in the DAGs list
3. Click the ▶ (Trigger DAG) button

**Trigger from the terminal:**
```bash
airflow dags trigger paeds_vitals_etl
```

**Watch progress:**
- Click the DAG name → **Graph** tab
- Tasks change colour as they run:

| Colour | Status |
|---|---|
| Grey | Not yet run |
| Light green | Running |
| Dark green | Success |
| Red | Failed |
| Yellow/orange | Retrying |

**Read task logs:**
Click any task box → **Log** tab. Your `log.info()` and `log.warning()`
messages appear here.

**Re-run a failed task without restarting the whole pipeline:**
Click the failed task → **Clear** → select **Failed** → **Confirm**.

---

## Site Filter Behaviour

The `paeds_site_filter` Variable controls which sites are processed.

The pipeline runs a **two-step site discovery process** on every run:

**Step 1 — Candidate sites:**
If `paeds_site_filter` is set, those site IDs are the candidates.
If empty, all ohdl_db sites in `sites_master_list` are candidates.

**Step 2 — Data discovery:**
The pipeline queries `obs` directly to find which candidate sites actually
have weight or height observations (`concept_id IN (5089, 5090)`) in the
configured date window. Sites with no qualifying data are automatically
skipped — no wasted extract tasks.

**Step 3 — Intersect:**
Only sites present in both the candidate list and the discovery result
are processed. The task log for `get_sites` shows exactly what was found,
what was skipped, and which sites will run.

### Examples

| `paeds_site_filter` value | Behaviour |
|---|---|
| `207,413,611` | Process only these 3 sites |
| *(empty)* | Process all ohdl_db sites that have data in the window |
| `207` | Process a single site — useful for debugging |
| `207,413,611,999` | Process 207, 413, 611 — warn that 999 was not found |

---

## Data Quality Checks

Run automatically after all site extracts complete (`dq_checks` task).
Results are visible in the task log and pushed to XCom.

### Check reference

| Check | Type | Blocks load if fails? |
|---|---|---|
| `null_patient_id` | Critical | Yes |
| `null_visit_date` | Critical | Yes |
| `age_out_of_range` | Critical | Yes |
| `null_site_id` | Critical | Yes |
| `null_birth_date` | Warning | No |
| `null_gender` | Warning | No |
| `invalid_gender` | Warning | No |
| `no_vitals_at_all` | Warning | No |
| `implausible_weight` | Warning | No |
| `implausible_height` | Warning | No |
| `duplicate_visits` | Warning | No |
| `visits_outside_window` | Warning | No |

**To add a new check:** add one entry to `SQL_DQ_CHECKS` in `dq.py`.

**To promote a warning to critical:** add its key to `CRITICAL_CHECKS` in `dq.py`.

---

## Post-Load Summary Report

The `post_load_summary` task runs after every successful load and writes
a structured report to the task log. Click the task → **Logs** to read it.

### Report sections

**Overall totals**
============================================================
POST-LOAD SUMMARY  |  run date: 2026-06-08
============================================================
Total rows loaded      : 3248
Unique patients        : 289
Sites loaded           : 3
Distinct visit dates   : 853
Visit date range       : 2020-01-02  →  2024-01-17
Last etl_loaded_at     : 2026-06-08 09:31:17 
============================================================


**Per-site breakdown** — rows and unique patients per site with facility name and district.

**Vitals coverage** — how many rows have weight only, height only, both, or neither.

**Age band breakdown** — unique patients and total visits per 5-year band (0–4, 5–9, 10–14).

**Gender split** — unique patients and total visits by M / F / Unknown.

All key figures are also pushed to XCom under the key `load_summary`
(visible in Admin → XComs after a successful run).

---

## Output Tables

Both tables are created automatically on first run in the schema defined
by the `etl_target_schema` Variable (default: `ghii_etl`).

### `ghii_etl.dr_paed_vitals_per_visit_staging`
Temporary table — truncated and refilled on every run.
Used for intermediate storage between extract and load.
Do not use for reporting.

### `ghii_etl.dr_paed_vitals_per_visit_innocent`
Final clean table — the source of truth for downstream tools.
Use this for Superset dashboards, reports, and further analysis.

**Schema:**

| Column | Type | Notes |
|---|---|---|
| `id` | INT AUTO_INCREMENT | Primary key |
| `site_id` | INT | Numeric site identifier |
| `facility_district` | VARCHAR(100) | From `sites_master_list` |
| `facility_name` | VARCHAR(200) | From `sites_master_list` |
| `patient_id` | INT NOT NULL | ohdl_db `person_id` |
| `gender` | CHAR(1) | `M` or `F` |
| `birth_date` | DATE | |
| `visit_date` | DATE | Date of the obs record |
| `age_at_visit` | INT | Age in years at `visit_date` |
| `weight_kgs` | DECIMAL(5,1) | `concept_id = 5089` |
| `height_cm` | DECIMAL(5,1) | `concept_id = 5090` |
| `etl_loaded_at` | TIMESTAMP | Set on insert, refreshed on update |

**Unique constraint:** `(patient_id, visit_date)` — re-runs update
existing rows rather than inserting duplicates.

---

## Design Decisions

### Why SQL-first, not pandas?
All transformations (name standardisation, rounding, EAV pivot, deduplication)
happen inside MySQL. Python only orchestrates — it never holds patient data
in memory. This is faster, uses less RAM, and works on any dataset size.

### Why PARTITION clauses?
Explicit `PARTITION (p207)` clauses tell MySQL to read only the relevant
partition pages, avoiding full table scans. The partition name is derived
from the site_id in Python (`f"p{site_id}"`).

### Why a staging table?
The staging table acts as a buffer between extract and load.
DQ checks run against staging — if critical issues are found, the final
table is never touched. Re-runs truncate staging and start fresh.

### Why dynamic task mapping?
`extract_one_site.expand(site=sites)` spawns one Airflow task per site.
Each task is independently retryable — a failure at site 207 does not
affect site 413. All tasks are visible individually in the UI Graph view.

### Why `ON DUPLICATE KEY UPDATE`?
Makes every pipeline re-run safe without manual cleanup. If a visit row
already exists in the final table, the vitals are refreshed rather than
raising a duplicate key error.

### Why no first_name / last_name?
De-identification. Patient identity is carried only by `patient_id`.
The `person_name` table is never joined.

### Patient state overlap logic
`ps.end_date IS NULL` alone excluded patients who transferred out or died
mid-period but had valid visits during the window. The overlap filter:
```sql
AND ps.start_date <= DATE_TO
AND (ps.end_date IS NULL OR ps.end_date >= DATE_FROM)
```
correctly includes anyone whose ON ART state touched any part of the extract window.

---

## Troubleshooting

### DAG does not appear in the UI
```bash
# Check for import errors
airflow dags list-import-errors

# Verify the package is importable
export PYTHONPATH="/home/$USER/airflow/plugins:$PYTHONPATH"
python3 -c "from paeds_vitals_etl.config import CONN_ID; print('OK')"

# Verify DAG syntax
python3 ~/airflow/dags/paeds_vitals_etl.py
```

### `Unknown database 'ghii_etl'`
The `create_schema` task did not run or failed silently.
Run manually in DBeaver: `CREATE SCHEMA IF NOT EXISTS ghii_etl;`
Then clear and re-run from `create_schema`.

### `Unknown column 'site_id' in field list`
The staging or final table was created before `site_id` was added to the
table definition. Drop both tables and re-run from `create_staging_table`:
```sql
DROP TABLE IF EXISTS ghii_etl.dr_paed_vitals_per_visit_staging;
DROP TABLE IF EXISTS ghii_etl.dr_paed_vitals_per_visit_innocent;
```

### `mysqlclient` not installed
```bash
sudo apt install -y pkg-config default-libmysqlclient-dev build-essential
pip install mysqlclient
```

### Connection test disabled
In `~/airflow/airflow.cfg` set `test_connection = Enabled` and restart Airflow.

### `extract_one_site` retrying repeatedly
Check the task log for the exact MySQL error.
Common causes: wrong partition name, concept IDs not present for that site,
or date window returning no data.

### `get_sites` returns 0 sites
The discovery query found no obs with `concept_id IN (5089, 5090)` in
the date window. Check:
- `paeds_date_from` and `paeds_date_to` Variables are correct
- The obs table has data for those concept IDs in that period
- `paeds_site_filter` does not contain site IDs that have no obs data

---

## Future Improvements

- **Incremental loads** — extract only the previous month instead of
  truncating and reloading the full window on every run
- **Git version control** — track changes to DAG and plugin files
- **Unit tests** — test `build_extract_sql()` and DQ checks in isolation
- **Second pipeline** — reuse the package structure for TX_CURR, viral
  load, or regimen distribution extracts
- **Secrets management** — move MySQL credentials from the Airflow UI
  to environment variables for shared server deployments
- **Pool auto-tuning** — monitor MySQL query concurrency and adjust
  `ghii_etl_db_pool` slots based on observed server load

---

*MEDU Team — maintained by Innocent Ngwenya*
