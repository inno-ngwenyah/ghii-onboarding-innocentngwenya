# =============================================================================
# FILE: config.py
# LOCATION: ~/airflow/plugins/paeds_vitals/config.py
#
# PURPOSE:
#   Central configuration for the paeds_vitals ETL pipeline.
#   All runtime settings, connection names, table names, and DAG defaults
#   live here. No SQL and no task logic belongs in this file.
#
# HOW TO USE THIS FILE:
#   In your DAG file (or any other module), import what you need:
#
#       from paeds_vitals.config import CONN_ID, STAGING_TABLE, default_args
#
#   Then use those names directly in your operators and DAG definition.
#
# HOW TO CHANGE A SETTING:
#   - For dates, schema, or email  → update the Variable in Admin → Variables.
#     The new value takes effect within ~30 seconds (next scheduler parse).
#   - For connection name          → update CONN_ID here AND rename/create the
#     matching connection in Admin → Connections.
#   - For retry behaviour          → edit default_args below.

# VARIABLES TO SET IN Admin → Variables BEFORE RUNNING:
# ┌──────────────────────────┬──────────────────────────────────────────────┐
# │ Key                      │ Example value                                │
# ├──────────────────────────┼──────────────────────────────────────────────┤
# │ paeds_date_from          │ 2020-01-01                                   │
# │ paeds_date_to            │ 2024-12-31                                   │
# │ etl_target_schema        │ etl_staging                                  │
# │ alert_email              │ ngwenyahinnocent@gmail.com                   │
# │ paeds_site_filter        │ 207,413,611  (empty = all sites)             │
# └──────────────────────────┴──────────────────────────────────────────────┘
# =============================================================================
# =============================================================================

import logging
from datetime import timedelta

from airflow.models import Variable
from airflow.providers.mysql.hooks.mysql import MySqlHook

log = logging.getLogger(__name__)


# =============================================================================
# CONNECTION
# =============================================================================

CONN_ID = "mysql_ohdl_database"
# Must exactly match the Connection Id in Admin → Connections.
# Both SQLExecuteQueryOperator (conn_id=) and MySqlHook (mysql_conn_id=)
# use this string to look up credentials. Kept hardcoded — changing the
# connection name also requires updating the actual connection in the UI,
# so a Variable wouldn't reduce friction here.


# =============================================================================
# DATE WINDOW
# Read from Airflow Variables so the range can be updated from the UI
# without touching any code file.
# =============================================================================

DATE_FROM = Variable.get("paeds_date_from", default_var="")
DATE_TO   = Variable.get("paeds_date_to",   default_var="")
# default_var is a safety net — if the Variable hasn't been created yet,
# the DAG still loads without a KeyError. Remove it once Variables are confirmed.


# =============================================================================
# TARGET SCHEMA AND TABLE NAMES
# All table references in sql.py and dq.py are built from these two constants.
# Changing target_schema in the UI propagates to every SQL statement
# automatically — you never need to find-and-replace table names.
# =============================================================================

TARGET_SCHEMA = Variable.get("target_schema", default_var="")
# The MySQL database (schema) where ETL tables will be created.
# Change this Variable to point the pipeline at a different schema —
# e.g. "etl_staging_dev" for testing — without editing any SQL.

STAGING_TABLE = f"{TARGET_SCHEMA}.dr_paed_vitals_per_visit_staging"
# Receives raw extracted data. Truncated at the start of each run.
# Think of it as a temporary inbox — not a place for permanent storage.

FINAL_TABLE   = f"{TARGET_SCHEMA}.dr_paed_vitals_per_visit_innocent"
# Receives only clean, deduplicated rows after DQ checks pass.
# This is the table downstream tools (Superset, reports) should query.


# =============================================================================
# ALERT EMAIL
# If set, Airflow emails this address when any task fails permanently.
# Requires an SMTP connection in Admin → Connections (conn_id: smtp_default).
# Also requires [smtp] section configured in airflow.cfg.
# Empty string = email alerts silently disabled.
# =============================================================================

ALERT_EMAIL = Variable.get("alert_email", default_var="")


# =============================================================================
# PARALLELISM
# Maximum number of site extract tasks that run simultaneously.
# Also set a matching Pool in Admin → Pools → ghii_etl_db_pool with this
# many slots to prevent overloading the MySQL server.
# Start at 5-10 and increase if the database handles it comfortably.
# =============================================================================

MAX_CONCURRENT_SITES = 10

# =============================================================================
# DAG DEFAULT ARGUMENTS
# Applied to every task in the DAG. Individual tasks can override any key.
# Imported into the DAG file as: from paeds_vitals.config import default_args
# =============================================================================

default_args = {
    "owner": "MEDU_Team",
    # Label shown in the Airflow UI. Useful when multiple teams share one instance.

    "retries": 3,
    # Number of automatic retry attempts before a task is marked permanently failed.

    "retry_delay": timedelta(seconds=30),
    # Wait time between retries. Gives the database time to recover from
    # temporary connection issues.

    "retry_exponential_backoff": True,
    # Each retry waits longer: 5 min → 10 min → 20 min.
    # Avoids hammering a struggling database at fixed intervals.

    "email_on_failure": bool(ALERT_EMAIL),
    # True only if ALERT_EMAIL is non-empty. bool("") = False, bool("x@y.com") = True.

    "email_on_retry": False,
    # Retries are expected — only alert on final failure, not each attempt.

    "email": [ALERT_EMAIL] if ALERT_EMAIL else [],
    # Airflow expects a list. Conditional prevents passing [""] on empty string.
    # To alert multiple people, set the Variable to "a@org.org,b@org.org" and use:
    #   Variable.get("alert_email").split(",")
}

# =============================================================================
# SITE FETCHING
# Called by the get_sites task at DAG runtime — not at parse time.
# This ensures the site list is always current when the pipeline runs.
# =============================================================================

def fetch_active_sites():
    """
    Returns the list of sites to process in this ETL run.

    THREE-STEP PROCESS:
    -------------------
    STEP 1 — CANDIDATE SITES (from sites_master_list):
        If paeds_site_filter is set  → use only those site IDs as candidates.
        If paeds_site_filter is empty → use all OpenMRS sites as candidates.

    STEP 2 — DATA DISCOVERY (from obs):
        Queries obs directly to find which candidate site_ids actually have
        weight or height observations in the configured date window.
        This is Option B — lightweight, fast, no age join needed.
        Sites with zero qualifying obs are silently skipped.

        SQL used:
            SELECT DISTINCT site_id
            FROM obs
            WHERE concept_id IN (5089, 5090)
              AND DATE(obs_datetime) BETWEEN DATE_FROM AND DATE_TO
              AND voided = 0

        WHY THIS MATTERS:
        - sites_master_list may list 50 sites but only 3 have paediatric data.
        - Without this step, Airflow spawns 50 extract tasks — 47 return 0 rows.
        - With this step, Airflow spawns only the tasks that will produce data.

    STEP 3 — INTERSECT:
        Returns only sites that appear in BOTH the candidate list AND the
        obs discovery result. Enriched with metadata from sites_master_list.

    Returns
    -------
    list of dict:
        [{"site_id": 207, "site_name": "Mimosa Dispensary",
          "district": "Lilongwe", "region": "...",
          "partner_name": "...", "partition": "p207"}, ...]

    Raises
    ------
    ValueError
        If the site filter contains non-integer values.
        If after discovery, 0 sites have qualifying data in the date window.
    """
    hook = MySqlHook(mysql_conn_id=CONN_ID)

    # ------------------------------------------------------------------
    # STEP 1 — CANDIDATE SITES
    # Read the site filter Variable.
    # default_var="" means: treat as empty (all-sites mode) if not set.
    # ------------------------------------------------------------------
    site_filter_raw = Variable.get("paeds_site_filter", default_var="").strip()

    if site_filter_raw:
        # ---------------------------------------------------------------
        # FILTER MODE — specific site IDs requested
        # ---------------------------------------------------------------
        try:
            requested_ids = [
                int(s.strip())
                for s in site_filter_raw.split(",")
                if s.strip()
            ]
        except ValueError:
            raise ValueError(
                f"paeds_site_filter contains non-integer values: '{site_filter_raw}'. "
                f"Expected format: '207,413,611'"
            )

        if not requested_ids:
            raise ValueError(
                "paeds_site_filter is set but contains no valid site IDs."
            )

        placeholders = ", ".join(["%s"] * len(requested_ids))
        candidate_sql = f"""
            SELECT
                CONCAT('p', sml.sites_site_id)  AS partition_name,
                sml.sites_site_id AS site_id,
                sml.sites_site_name,
                sml.district,
                sml.region,
                sml.partner_name,
                sml.emr_type,
                sml.funding_agency
            FROM analytics.sites_master_list sml
            WHERE sml.sites_site_id IN ({placeholders})
            ORDER BY sml.sites_site_id ASC
        """
        candidate_rows = hook.get_records(candidate_sql, parameters=requested_ids)

        # Warn about requested IDs not found in the master list at all.
        # row[1] is now the integer site_id (second column after partition_name).
        found_ids = {row[1] for row in candidate_rows}
        missing   = set(requested_ids) - found_ids
        if missing:
            log.warning(
                "paeds_site_filter: requested IDs not in sites_master_list "
                "and will be skipped: %s", sorted(missing)
            )

        filter_label = f"FILTER MODE ({len(requested_ids)} requested)"

    else:
        # ---------------------------------------------------------------
        # ALL-SITES MODE — every OpenMRS site is a candidate
        # ---------------------------------------------------------------
        candidate_sql = """
            SELECT
                CONCAT('p', sml.sites_site_id)  AS partition_name,
                sml.sites_site_id AS site_id,
                sml.sites_site_name,
                sml.district,
                sml.region,
                sml.partner_name,
                sml.emr_type,
                sml.funding_agency
            FROM analytics.sites_master_list sml
            ORDER BY sml.sites_site_id ASC
        """
        candidate_rows = hook.get_records(candidate_sql)
        filter_label   = f"ALL-SITES MODE ({len(candidate_rows)} candidates)"

    # Build a dict of candidate sites keyed by integer site_id for fast lookup.
    # Row structure is now:
    #   row[0] = partition_name  e.g. "p207"
    #   row[1] = site_id         e.g. 207   (integer)
    #   row[2] = site_name
    #   row[3] = district
    #   row[4] = region
    #   row[5] = partner_name
    #   row[6] = emr_type
    #   row[7] = funding_agency

    
    candidate_map = {
        row[1]: row     # key = integer site_id
        for row in candidate_rows
    }
    log.info(
        "Step 1 — %s → candidate site_ids: %s",
        filter_label, sorted(candidate_map.keys())
    )

    # ------------------------------------------------------------------
    # STEP 2 — DATA DISCOVERY (Option B: lightweight obs check)
    # Finds which site_ids actually have weight/height obs in the window.
    # No age join — fast and cheap. The full age filter runs in the extract.
    # concept_id 5089 = Weight (kg), 5090 = Height (cm).
    # ------------------------------------------------------------------
    discovery_sql = f"""
        SELECT DISTINCT site_id
        FROM obs
        WHERE concept_id IN (5089, 5090)
          AND DATE(obs_datetime) BETWEEN '{DATE_FROM}' AND '{DATE_TO}'
          AND voided = 0
        ORDER BY site_id ASC
    """
    discovery_rows  = hook.get_records(discovery_sql)
    active_site_ids = {row[0] for row in discovery_rows}

    log.info(
        "Step 2 — Data discovery: %d site_ids have obs in %s → %s → site_ids: %s",
        len(active_site_ids), DATE_FROM, DATE_TO, sorted(active_site_ids)
    )

    # ------------------------------------------------------------------
    # STEP 3 — INTERSECT candidate sites with discovered active sites.
    # Only sites present in BOTH lists get processed.
    # Sites in candidates but not in obs are skipped (no data to extract).
    # ------------------------------------------------------------------
    skipped = sorted(set(candidate_map.keys()) - active_site_ids)
    if skipped:
        log.info(
            "Step 3 — Skipping %d candidate site(s) with no qualifying obs "
            "in the date window: %s", len(skipped), skipped
        )

    # Build the final site list — only active candidates, enriched with
    # metadata from sites_master_list. partition_name comes directly from
    # the DB via CONCAT('p', site_id) — used in PARTITION clauses in sql.py.
    sites = [
        {
            "partition":      row[0],   # "p207" — used in PARTITION (p207)
            "site_id":        row[1],   # 207    — used in WHERE and INSERT
            "site_name":      row[2],
            "district":       row[3],
            "region":         row[4],
            "partner_name":   row[5],
            "emr_type":       row[6],
            "funding_agency": row[7],
        }
        for site_id, row in candidate_map.items()
        if site_id in active_site_ids
    ]

    # Sort by site_id for consistent ordering across runs.
    sites.sort(key=lambda s: s["site_id"])

    if not sites:
        raise ValueError(
            f"fetch_active_sites() returned 0 sites after discovery. "
            f"No qualifying obs found in {DATE_FROM} → {DATE_TO} "
            f"for any candidate site. Check the date window Variables "
            f"and that concept_ids 5089/5090 exist in obs."
        )

    log.info(
        "Step 3 — Final site list: %d site(s) to process → site_ids: %s",
        len(sites), [s["site_id"] for s in sites]
    )
    return sites