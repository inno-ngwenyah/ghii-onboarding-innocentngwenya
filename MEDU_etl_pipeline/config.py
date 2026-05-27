# ---------------------------------------------------------------------------------
# CONFIGURATION FILE - DB engines, concept map, output paths
# ---------------------------------------------------------------------------------

import os
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

load_dotenv()  # reads .env into os.environ

# Database connection - MySQL -------------------------------------------------------
def mysql_db_con():
    return create_engine(
        "mysql+pymysql://{user}:{pw}@{host}:{port}/{db}".format(
            user=os.environ["OMRS_DB_USER"],
            pw=os.environ["OMRS_DB_PASSWORD"],
            host=os.environ.get("OMRS_DB_HOST", "localhost"),
            port=os.environ.get("OMRS_DB_PORT", "3306"),
            db=os.environ.get("OMRS_DB_NAME", "ohdl_db"),
        ),
        pool_pre_ping=True,
    )

# Database connection  - PostgreSQL -------------------------------------------------
def postgresql_db_con():
    return create_engine(
        "postgresql+psycopg2://{user}:{pw}@{host}:{port}/{db}".format(
            user=os.environ["PG_USER"],
            pw=os.environ["PG_PASSWORD"],
            host=os.environ.get("PG_HOST", "localhost"),
            port=os.environ.get("PG_PORT", "5432"),
            db=os.environ["PG_DB"],
        ),
        pool_pre_ping=True,
    )

# 1. Stable concept definitions — names, not IDs -------------------------------------------------------------
# Keys are FULLY_SPECIFIED names from your concept_name table.
# If a concept name changes, update it here only.
CONCEPT_DEFINITIONS = {
    "Weight (kg)": {"source": "value_numeric", "target": "weight_kg"},
    "Height (cm)": {"source": "value_numeric", "target": "height_cm"},
    "Body mass index, measured":{"source": "value_numeric", "target": "bmi"},
    "Is patient pregnant?": {"source": "name",  "target": "patient_pregnant"},
    "Is patient breast feeding?":{"source": "name", "target": "patient_breastfeeding"},
}  

# 2. GENDER STANDARDISATION MAP -------------------------------------------------
GENDER_MAP    = {
    "m": "M", "male": "M", "man": "M",
    "f": "F", "female": "F", "woman": "F",
} 

OUTPUT_DIR = "output"

# Initial visit output settings -------------------------------------------------
INITIAL_OUTPUT_PATH = os.path.join(OUTPUT_DIR, "MEDU_initial_visit_flat.csv")

# Follow-up visit output settings -----------------------------------------------
FOLLOWUP_OUTPUT_PATH  = os.path.join(OUTPUT_DIR, "MEDU_followup_visits_flat.csv")
# ------------------------------------------------------------------------------

def build_concept_route(engine) -> dict:
    """
    Dynamically resolves concept IDs from the OpenMRS concept_name table.
    Returns a dict of {concept_id: {source, target}} ready for use in
    extract and transform functions.
    """
    names = list(CONCEPT_DEFINITIONS.keys())
    placeholders = ", ".join([f"'{n}'" for n in names])
# Pull concept IDs and their names that we want to use
    concept_name_query = text(f"""
        SELECT 
            cn.concept_id, 
            cn.name
        FROM concept_name cn
        WHERE name IN ({placeholders})
          AND cn.locale  = 'en'
          AND cn.concept_name_type = 'FULLY_SPECIFIED'
          AND cn.voided = 0
    """)

    with engine.connect() as conn:
        rows = conn.execute(concept_name_query).fetchall()

    concept_route = {}
    found_names = set()

    for row in rows:
        concept_id = row[0]
        name = row[1]
        if name in CONCEPT_DEFINITIONS:
            concept_route[concept_id] = CONCEPT_DEFINITIONS[name]
            found_names.add(name)

    # Warn about any concepts not found in the source database
    missing = [n for n in names if n not in found_names]
    if missing:
        print("  ⚠ WARNING: These concepts were not found in concept_name:")
        for m in missing:
            print(f" - {m}")
    else:
        print(f"  ✓ All {len(concept_route)} concepts resolved successfully.")

    return concept_route