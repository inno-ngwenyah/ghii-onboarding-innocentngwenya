# =============================================================================
# FILE: dq.py
# LOCATION: ~/airflow/plugins/paeds_vitals_etl/dq.py
#
# PURPOSE:
#   Data quality checks for the paeds_vitals_etl ETL pipeline.
#   Contains the SQL check queries, critical check definitions, and the
#   Python function that runs all checks against the staging table.
#
# HOW TO USE:
#   from paeds_vitals_etl.dq import run_dq_checks
#
#   Then pass to a PythonOperator in the DAG:
#       t_dq = PythonOperator(
#           task_id         = "dq_checks",
#           python_callable = run_dq_checks,
#       )
#
# HOW TO ADD A NEW CHECK:
#   Add one entry to SQL_DQ_CHECKS. If it should block the load on failure,
#   add its key to CRITICAL_CHECKS. Nothing else changes.
#
# HOW TO PROMOTE A WARNING TO CRITICAL:
#   Add its key name to the CRITICAL_CHECKS set below.
# =============================================================================

import logging
from airflow.providers.mysql.hooks.mysql import MySqlHook
from paeds_vitals_etl.config import CONN_ID, STAGING_TABLE, FINAL_TABLE, DATE_FROM, DATE_TO

log = logging.getLogger(__name__)


# =============================================================================
# DQ CHECK QUERIES
# Each entry is a named SQL query returning a single integer — the count of
# rows with that specific problem in the staging table.
# =============================================================================

SQL_DQ_CHECKS = {

    # ---- CRITICAL CHECKS ----------------------------------------------------
    # These block the load task if count > 0. A row missing patient_id,
    # visit_date or with an impossible age cannot be reported on and must
    # not reach the final table.

    "null_patient_id":
        f"SELECT COUNT(*) FROM {STAGING_TABLE} WHERE patient_id IS NULL",

    "null_visit_date":
        f"SELECT COUNT(*) FROM {STAGING_TABLE} WHERE visit_date IS NULL",

    "null_birth_date":
        f"SELECT COUNT(*) FROM {STAGING_TABLE} WHERE birth_date IS NULL",

    "age_out_of_range":
        # Should always be zero given the TIMESTAMPDIFF filter in the extract.
        # A non-zero result means the extract SQL has a logic error.
        f"""SELECT COUNT(*)
            FROM {STAGING_TABLE}
            WHERE age_at_visit < 0 OR age_at_visit >= 15""",

    # ---- WARNING CHECKS -----------------------------------------------------
    # Logged as warnings — do not stop the pipeline. Flag source data issues
    # for the M&E team to investigate.

    "null_gender":
        f"SELECT COUNT(*) FROM {STAGING_TABLE} WHERE gender IS NULL",

    "invalid_gender":
        # Only 'M' and 'F' are valid in ohdl_db.
        f"""SELECT COUNT(*)
            FROM {STAGING_TABLE}
            WHERE gender NOT IN ('M', 'F')""",

    "no_vitals_at_all":
        # A row with no weight AND no height has no clinical value.
        # Rows with only one of the two are still useful — kept.
        f"""SELECT COUNT(*)
            FROM {STAGING_TABLE}
            WHERE weight_kgs IS NULL AND height_cm IS NULL""",

    "implausible_weight":
        # Physiologically impossible — likely a data entry error.
        f"""SELECT COUNT(*)
            FROM {STAGING_TABLE}
            WHERE weight_kgs IS NOT NULL AND weight_kgs <= 0""",

    "implausible_height":
        f"""SELECT COUNT(*)
            FROM {STAGING_TABLE}
            WHERE height_cm IS NOT NULL AND height_cm <= 0""",

    "duplicate_visits":
        # Staging should have one row per patient+visit_date after GROUP BY.
        # Duplicates here suggest an upstream data issue.
        f"""SELECT COUNT(*) FROM (
                SELECT patient_id, visit_date
                FROM {STAGING_TABLE}
                GROUP BY patient_id, visit_date
                HAVING COUNT(*) > 1
            ) AS dups""",

    "visits_outside_window":
        # Should always be zero given the date filter in the extract.
        # Confirms the extract SQL is honouring the date window.
        f"""SELECT COUNT(*)
            FROM {STAGING_TABLE}
            WHERE visit_date < '{DATE_FROM}'
               OR visit_date > '{DATE_TO}'""",

    "null_site_id":
        # Every row must have a site_id — it is the partition key.
        f"SELECT COUNT(*) FROM {STAGING_TABLE} WHERE site_id IS NULL",
}


# =============================================================================
# CRITICAL CHECKS
# Any key listed here causes run_dq_checks() to raise ValueError if count > 0.
# This marks the dq_checks task FAILED and prevents load_final from running.
# To promote a warning to critical: add its key here.
# To demote a critical to warning: remove its key here.
# =============================================================================

CRITICAL_CHECKS = {
    "null_patient_id",
    "null_visit_date",
    "age_out_of_range",
    "null_site_id",
}


# =============================================================================
# RUN DQ CHECKS
# The Python function passed to PythonOperator in the DAG.
# =============================================================================

def run_dq_checks(**ctx):
    """
    Runs all SQL DQ checks against the staging table.

    For each check in SQL_DQ_CHECKS:
      - Executes the query via MySqlHook (data stays in MySQL).
      - Reads back a single integer (problem row count).
      - Logs WARNING if count > 0, INFO if count = 0.

    After all checks:
      - If any CRITICAL_CHECKS have count > 0, raises ValueError.
        This marks the task FAILED and blocks load_final.
      - Pushes a summary to XCom (visible in Admin → XComs).

    Parameters
    ----------
    **ctx : dict
        Airflow context injected automatically in Airflow 2.x.
        ctx["ti"] is the task instance, used for xcom_push.
    """
    hook   = MySqlHook(mysql_conn_id=CONN_ID)
    issues = {}

    for check_name, sql in SQL_DQ_CHECKS.items():
        # get_first() returns the first row as a tuple e.g. (42,).
        # [0] extracts the integer count.
        count = hook.get_first(sql)[0]

        if count > 0:
            log.warning("DQ ISSUE — %s: %d rows affected", check_name, count)
            issues[check_name] = count
        else:
            log.info("DQ OK    — %s", check_name)

    # Summary counts
    total = hook.get_first(f"SELECT COUNT(*) FROM {STAGING_TABLE}")[0]
    log.info("Staging row total     : %d", total)
    log.info("DQ checks with issues : %d / %d", len(issues), len(SQL_DQ_CHECKS))

    # Identify critical failures
    critical_failures = {k: v for k, v in issues.items() if k in CRITICAL_CHECKS}

    if critical_failures:
        # Raising here marks this task FAILED in the UI.
        # Because t_dq >> t_load, the load task is automatically skipped.
        # Fix the upstream data issue then clear and re-run from this task.
        raise ValueError(
            f"Critical DQ failures — load blocked. Issues: {critical_failures}"
        )

    # Push summary to XCom for audit and debugging.
    # Visible in Admin → XComs after a run completes.
    ctx["ti"].xcom_push(key="dq_issues",  value=issues)
    ctx["ti"].xcom_push(key="total_rows", value=total)


# =============================================================================
# POST-LOAD SUMMARY
# Runs after load_final completes successfully.
# Queries the FINAL table (not staging) and logs a breakdown of what
# actually landed — total rows, per-site counts, vitals coverage, and
# age/gender distribution.
#
# Everything stays in MySQL — Python only reads summary integers and strings.
# The full report is visible in the task log in the Airflow UI.
# All figures are also pushed to XCom for downstream use or alerting.
# =============================================================================

def log_load_summary(**ctx):
    """
    Queries the final table after a successful load and logs a structured
    summary report covering:

      1. Overall totals       — total rows, unique patients, sites loaded
      2. Per-site breakdown   — rows and unique patients per site
      3. Vitals coverage      — how many rows have weight, height, both, neither
      4. Age band breakdown   — patient counts by 5-year age band
      5. Gender split         — M / F / unknown counts
      6. Date window coverage — earliest and latest visit_date in the table

    Parameters
    ----------
    **ctx : dict
        Airflow context injected automatically in Airflow 2.x.
        ctx["ti"] is the task instance used for xcom_push.
        ctx["ds"] is the execution date string (YYYY-MM-DD).
    """
    hook    = MySqlHook(mysql_conn_id=CONN_ID)
    run_date = ctx.get("ds", "unknown")

    # -------------------------------------------------------------------------
    # 1. OVERALL TOTALS
    # Single query — one round trip to the database.
    # -------------------------------------------------------------------------
    totals = hook.get_first(f"""
        SELECT
            COUNT(*) AS total_rows,
            COUNT(DISTINCT patient_id)      AS unique_patients,
            COUNT(DISTINCT site_id)         AS sites_loaded,
            COUNT(DISTINCT visit_date)      AS distinct_visit_dates,
            MIN(visit_date)                 AS earliest_visit,
            MAX(visit_date)                 AS latest_visit,
            MAX(etl_loaded_at)              AS last_loaded_at
        FROM {FINAL_TABLE}
    """)

    total_rows, unique_patients, sites_loaded, \
    distinct_dates, earliest, latest, last_loaded = totals

    # Separator line makes the report easy to find when scrolling the task log
    sep = "=" * 60
    log.info(sep)
    log.info("POST-LOAD SUMMARY  |  run date: %s", run_date)
    log.info(sep)
    log.info("Total rows loaded      : %d", total_rows)
    log.info("Unique patients        : %d", unique_patients)
    log.info("Sites loaded           : %d", sites_loaded)
    log.info("Distinct visit dates   : %d", distinct_dates)
    log.info("Visit date range       : %s  →  %s", earliest, latest)
    log.info("Last etl_loaded_at     : %s", last_loaded)
    log.info(sep)

    # -------------------------------------------------------------------------
    # 2. PER-SITE BREAKDOWN
    # Shows rows and unique patients for each site so you can spot
    # sites that extracted 0 rows or unexpectedly low counts immediately.
    # Joined to sites_master_list so you see names, not just IDs.
    # -------------------------------------------------------------------------
    site_rows = hook.get_records(f"""
        SELECT
            f.site_id,
            COALESCE(sml.sites_site_name, 'Unknown')  AS site_name,
            COALESCE(sml.district,  'Unknown')  AS district,
            COUNT(*) AS rows_loaded,
            COUNT(DISTINCT f.patient_id) AS unique_patients,
            MIN(f.visit_date) AS earliest_visit,
            MAX(f.visit_date) AS latest_visit
        FROM {FINAL_TABLE} f
        LEFT JOIN analytics.sites_master_list sml
               ON sml.sites_site_id = f.site_id
        GROUP BY f.site_id, sml.sites_site_name, sml.district
        ORDER BY f.site_id ASC
    """)

    log.info("PER-SITE BREAKDOWN:")
    log.info("  %-6s  %-30s  %-15s  %8s  %8s  %s  →  %s",
             "SiteID", "Site Name", "District",
             "Rows", "Patients", "Earliest", "Latest")
    log.info("  " + "-" * 95)
    for row in site_rows:
        log.info("  %-6s  %-30s  %-15s  %8d  %8d  %s  →  %s", *row)
    log.info(sep)

    # -------------------------------------------------------------------------
    # 3. VITALS COVERAGE
    # Shows how many rows have weight, height, both, or neither.
    # "Neither" rows should be 0 — the load SQL excludes them.
    # Low "both" % is a data quality signal worth flagging.
    # -------------------------------------------------------------------------
    vitals = hook.get_first(f"""
        SELECT
            COUNT(*)  AS total,
            SUM(CASE WHEN weight_kgs IS NOT NULL
                      AND height_cm  IS NOT NULL THEN 1 ELSE 0 END)   AS both_present,
            SUM(CASE WHEN weight_kgs IS NOT NULL
                      AND height_cm  IS NULL     THEN 1 ELSE 0 END)   AS weight_only,
            SUM(CASE WHEN weight_kgs IS NULL
                      AND height_cm  IS NOT NULL THEN 1 ELSE 0 END)   AS height_only,
            SUM(CASE WHEN weight_kgs IS NULL
                      AND height_cm  IS NULL     THEN 1 ELSE 0 END)   AS neither
        FROM {FINAL_TABLE}
    """)

    total_v, both, wt_only, ht_only, neither = vitals
    pct = lambda n: f"{(n / total_v * 100):.1f}%" if total_v > 0 else "0.0%"

    log.info("VITALS COVERAGE:")
    log.info("  Both weight & height : %6d  (%s)", both,    pct(both))
    log.info("  Weight only          : %6d  (%s)", wt_only, pct(wt_only))
    log.info("  Height only          : %6d  (%s)", ht_only, pct(ht_only))
    log.info("  Neither (unexpected) : %6d  (%s)", neither, pct(neither))
    if neither > 0:
        log.warning("  ⚠ Rows with no vitals present — investigate source data")
    log.info(sep)

    # -------------------------------------------------------------------------
    # 4. AGE BAND BREAKDOWN
    # Groups patients into standard paediatric bands: 0-4, 5-9, 10-14.
    # Counts unique patients per band (not rows) to avoid visit inflation.
    # -------------------------------------------------------------------------
    age_rows = hook.get_records(f"""
        SELECT
            CASE
                WHEN age_at_visit BETWEEN 0  AND 4  THEN '00-04'
                WHEN age_at_visit BETWEEN 5  AND 9  THEN '05-09'
                WHEN age_at_visit BETWEEN 10 AND 14 THEN '10-14'
                ELSE 'Unknown'
            END  AS age_band,
            COUNT(DISTINCT patient_id) AS unique_patients,
            COUNT(*) AS total_visits
        FROM {FINAL_TABLE}
        GROUP BY age_band
        ORDER BY age_band ASC
    """)

    log.info("AGE BAND BREAKDOWN  (unique patients | total visits):")
    for row in age_rows:
        log.info("  Age %s : %6d patients  |  %6d visits", *row)
    log.info(sep)

    # -------------------------------------------------------------------------
    # 5. GENDER SPLIT
    # -------------------------------------------------------------------------
    gender_rows = hook.get_records(f"""
        SELECT
            CASE
                WHEN gender = 'M' THEN 'Male'
                WHEN gender = 'F' THEN 'Female'
                ELSE 'Unknown / Invalid'
            END AS gender_label,
            COUNT(DISTINCT patient_id)  AS unique_patients,
            COUNT(*) AS total_visits
        FROM {FINAL_TABLE}
        GROUP BY gender_label
        ORDER BY gender_label ASC
    """)

    log.info("GENDER SPLIT  (unique patients | total visits):")
    for row in gender_rows:
        log.info("  %-20s : %6d patients  |  %6d visits", *row)
    log.info(sep)

    # -------------------------------------------------------------------------
    # Push key figures to XCom so they can be read by alerting or
    # downstream tasks in the future.
    # Visible in Admin → XComs after a successful run.
    # -------------------------------------------------------------------------
    summary = {
        "run_date":        run_date,
        "total_rows":      total_rows,
        "unique_patients": unique_patients,
        "sites_loaded":    sites_loaded,
        "earliest_visit":  str(earliest),
        "latest_visit":    str(latest),
        "vitals_both":     both,
        "vitals_wt_only":  wt_only,
        "vitals_ht_only":  ht_only,
        "vitals_neither":  neither,
    }
    ctx["ti"].xcom_push(key="load_summary", value=summary)
    log.info("Summary pushed to XCom (key: load_summary)")
    log.info(sep)