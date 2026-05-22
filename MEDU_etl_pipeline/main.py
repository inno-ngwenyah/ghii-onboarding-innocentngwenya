# -----------------------------------------------------------
# MAIN PIPELINE - Orchestrates both pipelines E→T→L
# -----------------------------------------------------------

import os
from extract import extract_initial_visit, extract_followup_visits
from transform import transform_initial_visit, transform_followup_visits
from load import load
from config import build_concept_route, mysql_db_con, OUTPUT_DIR, INITIAL_OUTPUT_PATH, FOLLOWUP_OUTPUT_PATH

# ----- DDL for patient Initial Visit table ----------------------------------
INITIAL_VISIT_DDL = """
CREATE TABLE IF NOT EXISTS patient_initial_visit (
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
"""
# ----- DDL for patient Followup Visit table ----------------------------------
FOLLOWUP_VISIT_DDL = """
CREATE TABLE IF NOT EXISTS patient_followup_visits (
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
"""

# ── Resolve concept IDs once at startup ───────────────
print("\nResolving concept IDs from source database.....")
engine = mysql_db_con()
concept_route = build_concept_route(engine)
os.makedirs(OUTPUT_DIR, exist_ok=True)

# ------------------------------------------------------------------------------
print("=" * 50)
print("  MEDU HIV Programme — ETL Pipeline")
print("=" * 50)

# ----- PIPELINE 1: Initial Visit ----------------------------------------------
print("\n--- INITIAL VISIT PIPELINE ---")
df_raw  = extract_initial_visit(concept_route)
print("Transforming data.....")
df_flat = transform_initial_visit(df_raw, concept_route)
print(f"Done. {len(df_flat):,} patients in flat table.")
df_flat.to_csv(INITIAL_OUTPUT_PATH, index=False)
print(f"Saved to {INITIAL_OUTPUT_PATH}")
load(df_flat, "patient_initial_visit",
     pk_cols=["person_id", "site_id"],
     create_sql=INITIAL_VISIT_DDL)

# ------- PIPELINE 2: Follow-up Visits ---------------------------------------
# ── Follow-up visits pipeline ─────────────────────────
print("\n--- FOLLOW-UP VISITS PIPELINE ---")
df_raw_fu  = extract_followup_visits(concept_route)
print("Transforming data.....")
df_flat_fu = transform_followup_visits(df_raw_fu, concept_route)
print(f"Done. {len(df_flat_fu):,} visit rows in flat table.")
df_flat_fu.to_csv(FOLLOWUP_OUTPUT_PATH, index=False)
print(f"Saved to {FOLLOWUP_OUTPUT_PATH}")
load(df_flat_fu, "patient_followup_visits",
     pk_cols=["person_id", "site_id", "visit_date"],
     create_sql=FOLLOWUP_VISIT_DDL)

# ---------------------------------------------------------------------------
print("\n" + "=" * 50)
print("  Pipeline complete.")
print("=" * 50)
#-----------------------------------------------------------------------------

