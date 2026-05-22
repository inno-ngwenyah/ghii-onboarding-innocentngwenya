# -----------------------------------------------------------------------------------------------
# MEDU HIV Programme — Python ETL Pipeline
# -----------------------------------------------------------------------------------------------

A modular Python ETL pipeline that extracts patient data from an **ohdl_db MySQL** database, transforms it into clean analytical flat tables, and loads it into a **cdr_db PostgreSQL** data warehouse.

---

## Table of Contents

- [Overview](#overview)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running the Pipeline](#running-the-pipeline)
- [Pipeline Stages](#pipeline-stages)
- [Database Schema](#database-schema)

---

## Overview

The pipeline covers two clinical datasets:

| Pipeline | Description | PostgreSQL Table |
|---|---|---|
| Initial visit | One row per patient — demographics, ART initiation details, baseline vitals, drugs on ART start date | `patient_initial_visit` |
| Follow-up visits | One row per visit per patient (up to 10 visits) — visit vitals, drugs, next appointment | `patient_followup_visits` |

Both pipelines share the same modular architecture — `extract → transform → load` — with all configuration centralised in `config.py`.

---

## Project Structure

```
MEDU_etl_pipeline/
│
├── .env                    # Database credentials 
├── .gitignore              # Excludes .env, output/, and .venv/
├── README.md               # This file
│
├── config.py               # DB engines, concept map, output paths, constants
├── extract.py              # extract_initial_visit() + extract_followup_visits()
├── transform.py            # transform_initial_visit() + transform_followup_visits()
├── load.py                 # Generic load() — works for any table
├── main.py                 # Orchestrates both pipelines E → T → L
│
├── test_pg_connection.py   # Standalone PostgreSQL connectivity test
├── test_mysql_connection.py # Standalone mysql connectivity test
│
└── output/                 # CSV outputs 
    ├── ghii_initial_visit_flat.csv
    └── ghii_followup_visits_flat.csv
```

---

## Prerequisites

| Requirement | Details |
|---|---|
| Operating System | Ubuntu 24.04 LTS (or any Linux/macOS) |
| Python | 3.12+ |
| MySQL source | OpenMRS MySQL 8.0 — port 3306 |
| PostgreSQL target | PostgreSQL — port 5432 |

---

## Installation

### 1. Clone or copy the project

```bash
git clone <repository-url>
cd MEDU_etl_pipeline
```

### 2. Create and activate a virtual environment

```bash
python3 -m venv .venv
source .venv/bin/activate
```

> On Windows: `.venv\Scripts\activate`

### 3. Install dependencies

```bash
pip install sqlalchemy pymysql psycopg2-binary pandas python-dotenv
```

### 4. Create the PostgreSQL target database

```bash
psql -U postgres -c "CREATE DATABASE cdr_db;"
```

---

## Configuration

### Create your .env file

Create a `.env` file in the project root with the following variables:

```bash
# OpenMRS MySQL source
OMRS_DB_USER=your_mysql_username
OMRS_DB_PASSWORD=your_mysql_password
OMRS_DB_HOST=localhost
OMRS_DB_PORT=3306
OMRS_DB_NAME=ohdl_db

# PostgreSQL target
PG_USER=your_postgres_username
PG_PASSWORD=your_postgres_password
PG_HOST=localhost
PG_PORT=5432
PG_DB=cdr_db
```

> ⚠️ Never commit `.env` to version control. It is already listed in `.gitignore`.

### Test your PostgreSQL connection

```bash
python test_mysql_connection.py
python test_pg_connection.py
```

---

## Running the Pipeline

### Activate the virtual environment

```bash
source .venv/bin/activate
```

### Run the full pipeline

```bash
python main.py
```

### Expected output

```
==================================================
  MEDU HIV Programme — ETL Pipeline
==================================================

--- INITIAL VISIT PIPELINE ---
Pulling latest obs for a patient initial visit:.......
Done. 5,858 rows pulled across 968 patients.
Transforming data.....
Done. 1,000 patients in flat table.
Saved to output/ghii_initial_visit_flat.csv
  Table 'patient_initial_visit' ready.
  Loaded 1,000 new rows into 'patient_initial_visit'.

--- FOLLOW-UP VISITS PIPELINE ---
Pulling follow-up visit data.....
Done. [N] rows pulled across [N] patients.
Transforming data.....
Done. [N] visit rows in flat table.
Saved to output/ghii_followup_visits_flat.csv
  Table 'patient_followup_visits' ready.
  Loaded [N] new rows into 'patient_followup_visits'.

==================================================
  Pipeline complete.
==================================================
```

---

## Pipeline Stages

### Extract

Two functions in `extract.py`:

- **`extract_initial_visit()`** — pulls obs from each patient's ART initiation day using a multi-CTE SQL query. Encounters are matched by `DATE(encounter_datetime) = DATE(art_start_date)` to capture all encounter types on that day.
- **`extract_followup_visits()`** — pulls obs from up to 10 follow-up encounters per patient after ART start, ordered chronologically using `ROW_NUMBER()`.

### Transform

Two functions in `transform.py`:

- **`transform_initial_visit(df)`** — standardises gender, parses dates, routes each concept to its correct value column, pivots from long to wide format, aggregates drugs as pipe-separated values.
- **`transform_followup_visits(df)`** — same logic but groups by `(person_id, site_id, visit_date)` instead of `(person_id, site_id)`.

### Concepts extracted (both pipelines)

| Concept ID | Meaning | Value type |
|---|---|---|
| 5089 | Weight (kg) | Numeric |
| 5090 | Height (cm) | Numeric |
| 2137 | BMI | Numeric |
| 6131 | Patient pregnant | Coded (Yes/No) |
| 7965 | Patient breastfeeding | Coded (Yes/No) |

### Load

A single generic `load()` function in `load.py` that works for any table:

1. Creates the table if it does not exist
2. Reads existing primary keys from PostgreSQL
3. Anti-joins to identify new rows only
4. Inserts new rows using `to_sql(if_exists='append')`

**Load strategy: insert new rows only — existing records are never overwritten.**

---

## Database Schema

### patient_initial_visit

```sql
CREATE TABLE patient_initial_visit (
    person_id               INTEGER,
    site_id                 INTEGER,
    gender                  VARCHAR(1),
    date_of_birth           DATE,
    art_start_date          DATE,
    dosage_start_date       DATE,
    drugs_at_initiation     TEXT,
    dose_quantity           NUMERIC,
    dose_instr              TEXT,
    weight_kg               NUMERIC,
    height_cm               NUMERIC,
    bmi                     NUMERIC,
    patient_pregnant        VARCHAR(50),
    patient_breastfeeding   VARCHAR(50),
    next_visit_date         DATE,
    PRIMARY KEY (person_id, site_id)
);
```

### patient_followup_visits

```sql
CREATE TABLE patient_followup_visits (
    person_id               INTEGER,
    site_id                 INTEGER,
    visit_date              DATE,
    visit_number            INTEGER,
    drugs_at_visit          TEXT,
    dose_quantity           NUMERIC,
    dose_instr              TEXT,
    weight_kg               NUMERIC,
    height_cm               NUMERIC,
    bmi                     NUMERIC,
    patient_pregnant        VARCHAR(50),
    patient_breastfeeding   VARCHAR(50),
    next_visit_date         DATE,
    PRIMARY KEY (person_id, site_id, visit_date)
);
```

### Truncating tables for a clean re-run

Always truncate the child table before the parent:

```sql
-- Option A: in order (child first)
TRUNCATE TABLE patient_followup_visits;
TRUNCATE TABLE patient_initial_visit;

-- Option B: cascade
TRUNCATE TABLE patient_initial_visit CASCADE;
```

---

## Moving or Renaming the Project

The pipeline is fully portable — no hardcoded paths exist in any Python file. After moving the folder:

```bash
# Recreate the virtual environment in the new location
cd /new/project/location
rm -rf .venv
python3 -m venv .venv
source .venv/bin/activate
pip install sqlalchemy pymysql psycopg2-binary pandas python-dotenv
```

Then reselect the Python interpreter in VS Code:
`Ctrl+Shift+P` → **Python: Select Interpreter** → choose `.venv` in the new location.

> The `.env` file, all Python files, and the PostgreSQL database are unaffected by moving the folder.

---

## Dependencies

| Package | Purpose |
|---|---|
| `sqlalchemy` | Database connection abstraction |
| `pymysql` | MySQL driver |
| `psycopg2-binary` | PostgreSQL driver |
| `pandas` | Data manipulation and transformation |
| `python-dotenv` | Loads credentials from `.env` |

---

*MEDU HIV Programme  | ghii.org*