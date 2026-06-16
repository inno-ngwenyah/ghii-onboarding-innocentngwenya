# =============================================================================
# FILE: paeds_vitals_etl.py
# LOCATION: ~/airflow/dags/paeds_vitals_etl.py
#
# PURPOSE:
#   Apache Airflow DAG for the paediatric vitals ETL pipeline.
#   Extracts weight and height observations for HIV-enrolled clients
#   aged under 15 years from the ohdl_db (2020-01-01 to 2024-12-31).
#
# WHAT THIS FILE CONTAINS:
#   ONLY the task definitions and the dependency chain.
#   Everything else lives in the supporting modules under plugins/paeds_vitals/:
#
#       config.py  — Variables, connection name, table names, default_args
#       sql.py     — all SQL statements (setup, extract, load)
#       dq.py      — DQ check queries, critical check set, run_dq_checks()
#
# PIPELINE FLOW (7 tasks):
#   create_schema → create_staging_table → create_final_table
#       → truncate_staging → extract_to_staging → dq_checks → load_final
#
# TO DEPLOY:
#   1. Copy this file to   ~/airflow/dags/
#   2. Copy the package to ~/airflow/plugins/paeds_vitals_etl/
#      (must contain __init__.py, config.py, sql.py, dq.py)
#   3. Confirm Variables exist in Admin → Variables:
#         paeds_date_from, paeds_date_to, etl_target_schema, alert_email
#   4. Confirm connection exists in Admin → Connections: mysql_ohdl_database
#   5. Verify with: python3 ~/airflow/dags/paeds_vitals_etl.py
#   6. Trigger from the UI or: airflow dags trigger paeds_vitals_etl
# =============================================================================
# -----------------------------------------------------------------------------
# AIRFLOW IMPORTS
# -----------------------------------------------------------------------------
from airflow import DAG
from airflow.decorators import task
from airflow.operators.python import PythonOperator
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from datetime import datetime, timedelta


# -----------------------------------------------------------------------------
# PIPELINE MODULE IMPORTS
# Everything that is not Airflow orchestration comes from the package.
# -----------------------------------------------------------------------------
from paeds_vitals_etl.config import (
    CONN_ID,
    default_args,
    MAX_CONCURRENT_SITES,
    fetch_active_sites,
)
from paeds_vitals_etl.sql import (
    SQL_CREATE_SCHEMA,
    SQL_CREATE_STAGING,
    SQL_CREATE_FINAL,
    SQL_TRUNCATE_STAGING,
    SQL_LOAD_FINAL,
    build_extract_sql,
)
from paeds_vitals_etl.dq import run_dq_checks, log_load_summary


# =============================================================================
# DAG DEFINITION
# =============================================================================

with DAG(
    dag_id  = "paeds_vitals_etl",
    default_args = default_args,         # retries, email, owner — from config.py
    start_date   = datetime(2026, 5, 31),
    schedule     = "@monthly",
    catchup   = False,
    # Cap on simultaneous tasks across the whole DAG run.
    # Works together with the openmrs_db_pool to protect the database.
    max_active_tasks = MAX_CONCURRENT_SITES + 4,
    # +4 accounts for the non-extract tasks (setup, dq, load) that may
    # run alongside the tail end of the extract tasks.
    tags = ["paeds", "vitals", "HIV", "etl"],
    doc_md = """
## Paediatric Vitals ETL

Extracts weight and height for HIV-enrolled clients aged **< 15 years**
from the OpenMRS CDR.

### Controlled entirely via Airflow Variables:
| Variable | Purpose |
|---|---|
| `paeds_date_from` | Extract window start |
| `paeds_date_to` | Extract window end |
| `etl_target_schema` | Target MySQL schema |
| `alert_email` | Failure notification address |
| `paeds_site_filter` | Comma-separated site IDs (empty = all sites) |
""",
) as dag:

    # -------------------------------------------------------------------------
    # TASK 1 — create_schema
    # Creates the target database/schema if it doesn't exist.
    # Schema name comes from the etl_target_schema Variable via config.py.
    # -------------------------------------------------------------------------
    t_create_schema = SQLExecuteQueryOperator(
        task_id = "create_schema",
        conn_id = CONN_ID,
        sql     = SQL_CREATE_SCHEMA,
    )

    # -------------------------------------------------------------------------
    # TASK 2 — create_staging_table
    # Creates the staging table inside the target schema.
    # IF NOT EXISTS — safe to re-run, will not drop existing data.
    # -------------------------------------------------------------------------
    t_create_staging = SQLExecuteQueryOperator(
        task_id = "create_staging_table",
        conn_id = CONN_ID,
        sql     = SQL_CREATE_STAGING,
    )

    # -------------------------------------------------------------------------
    # TASK 3 — create_final_table
    # Creates the final clean table. Downstream tools query this table.
    # -------------------------------------------------------------------------
    t_create_final = SQLExecuteQueryOperator(
        task_id = "create_final_table",
        conn_id = CONN_ID,
        sql     = SQL_CREATE_FINAL,
    )

    # -------------------------------------------------------------------------
    # TASK 4 — truncate_staging
    # Empties staging before each new extract so re-runs always start clean.
    # The final table is protected by its UNIQUE KEY independently.
    # -------------------------------------------------------------------------
    t_truncate = SQLExecuteQueryOperator(
        task_id = "truncate_staging",
        conn_id = CONN_ID,
        sql     = SQL_TRUNCATE_STAGING,
    )

    # -------------------------------------------------------------------------
    # TASK 5 — get_sites
    # Fetches the live site list from sites_master_list at runtime.
    # Behaviour controlled by the paeds_site_filter Variable:
    #   "207,413,611" → those 3 sites only
    #   ""  (empty)   → all OpenMRS sites
    # The @task decorator automatically pushes the return value to XCom
    # so the dynamic mapping in TASK 6 can consume it.
    # -------------------------------------------------------------------------
    @task
    def get_sites():
        sites = fetch_active_sites()
        print(f"Sites to process ({len(sites)}): {[s['site_id'] for s in sites]}")
        return sites


    # -------------------------------------------------------------------------
    # TASK 6 — extract_one_site  (DYNAMIC — one instance per site)
    # Runs build_extract_sql(site_id) for a single site and inserts results
    # into the staging table.
    #
    # .expand(site=sites) tells Airflow to call this task once for every
    # element in the list returned by get_sites(). Each instance runs
    # independently — a failure at one site does not affect others.
    #
    # pool="ghii_etl_db_pool" limits how many instances run simultaneously.
    # Set the pool slot count in Admin → Pools → openmrs_db_pool.
    # -------------------------------------------------------------------------
    @task(
        pool        = "ghii_etl_db_pool",
        retries     = 3,
        retry_delay = timedelta(minutes=3),
        retry_exponential_backoff = True,
    )

    
    def extract_one_site(site: dict):
        """
        Extracts paediatric vitals for one site into the staging table.

        Parameters
        ----------
        site : dict
            One element from the list returned by get_sites().
            Required keys: site_id (int), site_name (str), partition (str).
            The partition key (e.g. 'p207') is passed directly to
            build_extract_sql() for use in PARTITION clauses.
        """
        from airflow.providers.mysql.hooks.mysql import MySqlHook

        site_id   = site["site_id"]
        site_name = site["site_name"]
        partition = site["partition"]

        print(f"START extract — site_id: {site_id} | partition: {partition} | site_name: {site_name}")
        hook = MySqlHook(mysql_conn_id=CONN_ID)
        hook.run(build_extract_sql(site))   # pass full site dict — partition + site_id both needed
        print(f"DONE  extract — site_id: {site_id} | partition: {partition} | site_name: {site_name}")


    # -------------------------------------------------------------------------
    # TASK 7 — dq_checks
    # Validates all rows in staging (across all sites combined).
    # Runs AFTER all site extracts complete.
    # Raises ValueError on critical failures — blocks load_final from running.
    # Edit check queries and critical thresholds in dq.py.
    # -------------------------------------------------------------------------
    t_dq = PythonOperator(
        task_id         = "dq_checks",
        python_callable = run_dq_checks,
    )

    # -------------------------------------------------------------------------
    # TASK 8 — load_final
    # Deduplicates staging rows and inserts into the final table.
    # ON DUPLICATE KEY UPDATE makes every re-run safe — no manual cleanup needed.
    # -------------------------------------------------------------------------
    t_load = SQLExecuteQueryOperator(
        task_id = "load_final",
        conn_id = CONN_ID,
        sql     = SQL_LOAD_FINAL,
    )

    # -------------------------------------------------------------------------
    # TASK 9 — post_load_summary
    # Runs after load_final completes successfully.
    # Queries the FINAL table and logs a structured report covering:
    #   - Overall totals (rows, unique patients, sites loaded)
    #   - Per-site breakdown (rows and patients per site with names)
    #   - Vitals coverage (weight only / height only / both / neither)
    #   - Age band breakdown (0-4, 5-9, 10-14)
    #   - Gender split (M / F / unknown)
    #   - Visit date range in the final table
    #
    # Read the report: click this task in the UI → Logs tab.
    # All key figures are also pushed to XCom (Admin → XComs → load_summary).
    # Logic lives in dq.py → log_load_summary().
    # -------------------------------------------------------------------------
    t_summary = PythonOperator(
        task_id         = "post_load_summary",
        python_callable = log_load_summary,
    )


    # =========================================================================
    # DEPENDENCY CHAIN
    #
    # >> means "must succeed before the next task starts".
    # If any task fails, all tasks to its right are skipped for that run.
    #
    # Reading top to bottom:
    #   1. Create schema, staging table, final table (sequential, once each)
    #   2. Truncate staging (once)
    #   3. Fetch site list (once) → returns list to XCom
    #   4. Extract each site (parallel, N at a time via pool)
    #      All site extracts must complete before dq_checks starts.
    #   5. DQ checks (once, across all sites combined)
    #   6. Load final (once)
    #   7. Post-load summary (once) — always the last task to run
    #
    # Airflow draws the Graph view in the UI directly from these lines.
    # =========================================================================

    sites_list = get_sites()
    extracted  = extract_one_site.expand(site=sites_list)

    (
        t_create_schema
        >> t_create_staging
        >> t_create_final
        >> t_truncate
        >> sites_list
        >> extracted
        >> t_dq
        >> t_load
        >> t_summary
    )