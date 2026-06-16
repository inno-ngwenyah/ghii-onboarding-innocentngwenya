# =============================================================================
# FILE: sql.py
# LOCATION: ~/airflow/plugins/paeds_vitals/sql.py
#
# PURPOSE:
#   All SQL statements for the paeds_vitals ETL pipeline.
#   No Python logic, no Airflow imports, no task definitions here —
#   just SQL strings consumed by the DAG operators and dq.py.
#
# HOW TO USE:
#   from paeds_vitals.sql import (
#       SQL_CREATE_SCHEMA,
#       SQL_CREATE_STAGING,
#       SQL_CREATE_FINAL,
#       SQL_TRUNCATE_STAGING,
#       SQL_LOAD_FINAL,
#       build_extract_sql,
#   )
#
# HOW TO TEST A QUERY IN DBEAVER:
#   Copy the SQL string, replace any {variable} placeholders manually,
#   and paste into DBeaver. All queries are self-contained.
#
# KEY DESIGN DECISIONS:
#
#   1. ONE STATEMENT PER SETUP TASK
#      SQLExecuteQueryOperator is unreliable with multi-statement strings.
#      Splitting CREATE SCHEMA / CREATE STAGING / CREATE FINAL into separate
#      tasks gives one clear pass/fail per step in the Airflow UI.
#
#   2. SITE FILTERING VIA WHERE site_id = X (not PARTITION clause)
#      Hardcoded PARTITION (p207, p413, p611) does not scale beyond a handful
#      of sites and breaks if a partition name is wrong.
#      WHERE site_id = X with a proper index is portable, safe for any number
#      of sites, and never breaks when new sites are added.
#
#   3. AGE FILTER PER VISIT ROW
#      TIMESTAMPDIFF(YEAR, birthdate, visit_date) is evaluated on each obs row
#      independently. A child who turns 15 mid-period is automatically excluded
#      from post-15 visits while all earlier visits remain included.
#
#   4. PATIENT STATE OVERLAP LOGIC
#      ps.end_date IS NULL alone excluded patients who transferred out or died
#      mid-period but had valid visits during the window. The overlap filter:
#          ps.start_date <= DATE_TO
#          AND (ps.end_date IS NULL OR ps.end_date >= DATE_FROM)
#      correctly includes anyone whose ON ART state touched the window.
#
#   5. DE-IDENTIFICATION
#      person_name is not joined. given_name and family_name are not selected.
#      Patient identity is carried only by patient_id.
# =============================================================================

from paeds_vitals_etl.config import (
    STAGING_TABLE,
    FINAL_TABLE,
    TARGET_SCHEMA,
    DATE_FROM,
    DATE_TO,
)

# =============================================================================
# SETUP — three separate single-statement strings (one task each)
# All use IF NOT EXISTS — safe to re-run without dropping existing data.
# =============================================================================

SQL_CREATE_SCHEMA = f"CREATE SCHEMA IF NOT EXISTS {TARGET_SCHEMA};"
# Creates the target database. Must succeed before table creation tasks run.


SQL_CREATE_STAGING = f"""
CREATE TABLE IF NOT EXISTS {STAGING_TABLE} (
    id                INT AUTO_INCREMENT PRIMARY KEY,
    site_id           INT,
    facility_district VARCHAR(100),
    facility_name     VARCHAR(200),
    patient_id        INT,
    gender            CHAR(1),
    birth_date        DATE,
    visit_date        DATE,
    age_at_visit      INT,
    weight_kgs        DECIMAL(5,1),
    height_cm         DECIMAL(5,1),
    loaded_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    -- DECIMAL(5,1) stores up to 999.9 — avoids floating-point rounding noise.
    -- site_id included for per-site filtering and debugging.
    -- loaded_at records insertion time — useful for auditing re-runs.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"""
# Staging table: raw extracted data lands here.
# Truncated at the start of each run — always holds only fresh data.
# DE-IDENTIFICATION: first_name and last_name deliberately excluded.


SQL_CREATE_FINAL = f"""
CREATE TABLE IF NOT EXISTS {FINAL_TABLE} (
    id                INT AUTO_INCREMENT PRIMARY KEY,
    site_id           INT,
    facility_district VARCHAR(100),
    facility_name     VARCHAR(200),
    patient_id        INT NOT NULL,
    gender            CHAR(1),
    birth_date        DATE,
    visit_date        DATE,
    age_at_visit      INT,
    weight_kgs        DECIMAL(5,1),
    height_cm         DECIMAL(5,1),
    etl_loaded_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    -- UNIQUE KEY prevents the same patient+visit from being inserted twice.
    -- The load SQL uses ON DUPLICATE KEY UPDATE to refresh vitals on re-runs
    -- instead of throwing a duplicate key error.
    UNIQUE KEY uq_patient_visit (patient_id, visit_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"""
# Final table: receives only validated, deduplicated rows after DQ passes.
# This is the table downstream tools (Superset, reports) should query.


# =============================================================================
# TRUNCATE STAGING
# Clears staging before each extract so re-runs always start fresh.
# The final table is protected independently by its UNIQUE KEY constraint.
# =============================================================================

SQL_TRUNCATE_STAGING = f"TRUNCATE TABLE {STAGING_TABLE};"


# =============================================================================
# EXTRACT — one function that builds SQL for a single site
#
# Called by extract_one_site() in the DAG for each site in the site list.
# Each call produces a complete INSERT ... SELECT for that site_id only.
# This is what enables parallel execution — each site runs its own query
# independently against the database.
# =============================================================================

def build_extract_sql(site: dict) -> str:
    """
    Builds the extract SQL for a single site using explicit PARTITION clauses.

    Receives the full site dict from fetch_active_sites() which contains
    both the partition name (e.g. 'p207') from CONCAT('p', site_id) and
    the integer site_id (207). Both are needed:
        partition → used in PARTITION (p207) clauses for performance
        site_id   → used as a literal value in SELECT and GROUP BY

    PARTITION clause benefit:
        MySQL reads only the relevant partition pages rather than scanning
        the full table. On large multi-site tables this is significantly
        faster than WHERE site_id = X even with an index.

    Parameters
    ----------
    site : dict
        One element from the list returned by fetch_active_sites().
        Required keys: 'partition' (str e.g. 'p207'), 'site_id' (int e.g. 207).

    Returns
    -------
    str
        A complete INSERT INTO ... SELECT statement for this site.
        Safe to execute directly via MySqlHook.run().
    """
    partition = site["partition"]   # e.g. "p207" — used in PARTITION clauses
    site_id   = site["site_id"]     # e.g. 207    — used as literal value

    return f"""
    INSERT INTO {STAGING_TABLE} (
        site_id, facility_district, facility_name,
        patient_id, gender, birth_date,
        visit_date, age_at_visit, weight_kgs, height_cm
    )

    -- CTE: paeds_clients
    -- PARTITION ({partition}) on every table tells MySQL to read only
    -- this site's partition — no full table scans, no cross-site reads.
    -- person_name is NOT joined — excluded for de-identification.
    -- Age is NOT filtered here — evaluated per obs row in the outer WHERE.
    --
    -- PATIENT STATE OVERLAP LOGIC:
    --   ps.end_date IS NULL alone excluded patients who transferred out
    --   or died mid-period but had valid visits during the window.
    --   The overlap filter correctly includes anyone whose ON ART state
    --   touched any part of the extract window.
    WITH paeds_clients AS (
        SELECT
            pp.patient_id,
            pp.site_id,
            p.birthdate,
            p.gender
        FROM patient_program PARTITION ({partition}) pp
        JOIN person PARTITION ({partition}) p
            ON  p.person_id = pp.patient_id
            AND p.site_id   = pp.site_id
            AND p.voided    = 0
        JOIN patient_state PARTITION ({partition}) ps
            ON  ps.patient_program_id = pp.patient_program_id
            AND ps.site_id  = pp.site_id
            AND ps.voided  = 0
            AND ps.state  = 7               -- ON ART state ID
            AND ps.start_date <= '{DATE_TO}'     -- ART started before period ended
            AND (
                ps.end_date IS NULL                     -- still active on ART
                OR ps.end_date >= '{DATE_FROM}'         -- OR state overlapped the window
            )
        WHERE pp.program_id = 1     -- 1 = HIV programme
          AND pp.voided     = 0
    )
    SELECT
        {site_id} AS site_id,
        COALESCE(sml.district,  'Unknown District')  AS facility_district,
        COALESCE(sml.sites_site_name, 'Unknown Facility')       AS facility_name,
        -- COALESCE ensures rows with no matching facility record still appear,
        -- labelled clearly rather than silently dropped by an INNER JOIN.

        o.person_id   AS patient_id,
        UPPER(TRIM(pc.gender))  AS gender,
        pc.birthdate AS birth_date,
        DATE(o.obs_datetime) AS visit_date,

        -- AGE AT THIS VISIT (not today, not at enrolment):
        -- Each obs row is evaluated independently. A child who turns 15
        -- mid-period is automatically excluded from post-15 visits while
        -- all earlier visits remain included.
        TIMESTAMPDIFF(YEAR, pc.birthdate, DATE(o.obs_datetime)) AS age_at_visit,

        -- EAV PIVOT: OpenMRS stores weight and height as separate obs rows.
        -- MAX(CASE WHEN ...) with GROUP BY collapses them into one row per visit.
        -- concept_id 5089 = Weight (kg), concept_id 5090 = Height (cm).
        -- ROUND to 1 decimal avoids float noise e.g. 23.4999999.
        ROUND(MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END), 1) AS weight_kgs,
        ROUND(MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END), 1) AS height_cm

    FROM obs PARTITION ({partition}) o
    -- PARTITION ({partition}) scopes obs reads to this site only.
    -- No o.site_id filter needed — the partition already handles it.

    -- LEFT JOIN on pc.site_id since obs is partition-scoped, not site_id-filtered.
    LEFT JOIN analytics.sites_master_list sml
           ON sml.sites_site_id = {site_id}

    -- INNER JOIN to client roster on person_id only.
    -- Partition scoping on obs + CTE scoping on paeds_clients together
    -- ensure results are restricted to this site's data.
    JOIN paeds_clients pc
           ON pc.patient_id = o.person_id

    WHERE
        -- AGE FILTER per visit row — self-adjusting across the 5-year window.
        TIMESTAMPDIFF(YEAR, pc.birthdate, DATE(o.obs_datetime)) < 15

        -- Only weight and height obs — all other concept IDs excluded.
        AND o.concept_id IN (5089, 5090)

        -- Date window from Airflow Variables — change in UI, no code edit needed.
        AND DATE(o.obs_datetime) BETWEEN '{DATE_FROM}' AND '{DATE_TO}'

        -- Exclude soft-deleted observations.
        AND o.voided = 0

    -- GROUP BY collapses the two obs rows (weight + height) per patient+visit
    -- into one row. Required by the MAX(CASE...) EAV pivot above.
    GROUP BY
        pc.site_id, sml.district, sml.sites_site_name, o.person_id, pc.gender, pc.birthdate,o.obs_datetime

    ORDER BY o.person_id;
    """


# =============================================================================
# LOAD FINAL TABLE
# Moves clean, deduplicated rows from staging into the final table.
#
# ROW_NUMBER() deduplication:
#   Ranks rows within each patient+visit group by completeness of vitals.
#   Only row_num=1 (the best row) is inserted. Defensive against edge cases
#   where staging has more than one row per patient+visit.
#
# ON DUPLICATE KEY UPDATE:
#   If patient+visit already exists in the final table (from a previous run),
#   the vitals and timestamp are refreshed instead of raising a duplicate error.
#   Makes every re-run safe without manual cleanup.
# =============================================================================

SQL_LOAD_FINAL = f"""
INSERT INTO {FINAL_TABLE} (
    site_id, facility_district, facility_name,
    patient_id, gender, birth_date,
    visit_date, age_at_visit, weight_kgs, height_cm
)
WITH deduped AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY patient_id, visit_date
            ORDER BY
                (weight_kgs IS NOT NULL) DESC,  -- prefer rows that have weight
                (height_cm  IS NOT NULL) DESC,  -- prefer rows that have height
                id DESC                         -- tiebreak: keep the latest insert
        ) AS row_num
    FROM {STAGING_TABLE}
    -- Exclude rows where BOTH vitals are null — no clinical value.
    -- Rows with only weight or only height are still useful — kept.
    WHERE NOT (weight_kgs IS NULL AND height_cm IS NULL)
)
SELECT
    site_id, facility_district, facility_name,
    patient_id, gender, birth_date,
    visit_date, age_at_visit, weight_kgs, height_cm
FROM deduped
WHERE row_num = 1
ON DUPLICATE KEY UPDATE
    weight_kgs    = VALUES(weight_kgs),
    height_cm     = VALUES(height_cm),
    facility_name = VALUES(facility_name),
    site_id       = VALUES(site_id),
    etl_loaded_at = CURRENT_TIMESTAMP;
"""