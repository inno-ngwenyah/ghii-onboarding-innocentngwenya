# ---------------------------------------------------------------------------------------
# TRANSFORM - Includes all transform functions
# ---------------------------------------------------------------------------------------

import pandas as pd
from config import  GENDER_MAP


def standardise_gender(val):
    if pd.isna(val):
        return None
    return GENDER_MAP.get(str(val).strip().lower(), None)

#Transform function for initial visit ---------------------------------------------------
def transform_initial_visit(df: pd.DataFrame, concept_route: dict) -> pd.DataFrame:

    # 1. PARSE DATES --------------------------------------------------------------------
    df["date_of_birth"]  = pd.to_datetime(df["date_of_birth"],  errors="coerce")
    df["art_start_date"] = pd.to_datetime(df["art_start_date"], errors="coerce")

    # 2. STANDARDISE GENDER -------------------------------------------------------------
    df["gender"] = df["gender"].apply(standardise_gender)

    # 3. EXTRACT THE RIGHT VALUE PER CONCEPT ROW ----------------------------------------
    def extract_value(row):
        route = concept_route.get(row["concept_id"])
        if route is None:
            return None
        return row[route["source"]]

    df["obs_value"]  = df.apply(extract_value, axis=1)
    df["obs_column"] = df["concept_id"].map(
        {cid: r["target"] for cid, r in concept_route.items()}
    )

    # 4. PIVOT OBS MANUALLY — one column per concept -----------------------------------
    obs_cols = {}
    for cid, route in concept_route.items():
        col_name = route["target"]
        subset = (
            df[df["concept_id"] == cid][["person_id", "site_id", "obs_value"]]
            .drop_duplicates(subset=["person_id", "site_id"])
            .rename(columns={"obs_value": col_name})
        )
        obs_cols[col_name] = subset

    # 5. COLLAPSE STATIC PATIENT FIELDS -------------------------------------------------
    static_cols = [
        "person_id", "site_id", "gender", "date_of_birth", "art_start_date",
        "dosage_start_date",
    ]
    flat = (
        df[static_cols]
        .drop_duplicates(subset=["person_id", "site_id"])
        .reset_index(drop=True)
    )

    # 6. AGGREGATE DRUGS — pipe-separated per patient -----------------------------------
    drugs = (
        df.groupby(["person_id", "site_id"])
        .agg(
            drugs_at_initiation=("drug_name", lambda x: " | ".join(
                sorted(x.dropna().unique())
            )),
            dose_quantity=("dose_quantity", "first"),
            dose_instr=("dose_instr", "first"),
            next_visit_date=("next_visit_date", "first"),
        )
        .reset_index()
    )

    # 7. MERGE STATIC + DRUGS ----------------------------------------------------------
    flat = flat.merge(drugs, on=["person_id", "site_id"], how="left")

    # 8. MERGE EACH OBS COLUMN ---------------------------------------------------------
    for col_name, subset in obs_cols.items():
        flat = flat.merge(subset, on=["person_id", "site_id"], how="left")

    # 9. DROP DUPLICATES (safety net) --------------------------------------------------
    before = len(flat)
    flat = flat.drop_duplicates(subset=["person_id", "site_id"])
    after = len(flat)
    if before != after:
        print(f"  Warning: Dropped {before - after} duplicate rows after merge")

    # 10. PREFERRED COLUMN ORDER -------------------------------------------------------
    preferred_order = [
        "person_id", "site_id", "gender", "date_of_birth", "art_start_date",
        "dosage_start_date", "drugs_at_initiation", "dose_quantity",
        "dose_instr",  "weight_kg", "height_cm", "bmi", "patient_pregnant", 
        "patient_breastfeeding", "next_visit_date", 
    ]
    final_cols = [c for c in preferred_order if c in flat.columns]
    flat = flat[final_cols]

    return flat

# Transform function for followup visits
def transform_followup_visits(df: pd.DataFrame, concept_route: dict) -> pd.DataFrame:

    # 1. PARSE DATES --------------------------------------------------------------------
    df["visit_date"] = pd.to_datetime(df["visit_date"], errors="coerce")

    # 2. EXTRACT THE RIGHT VALUE PER CONCEPT ROW ---------------------------------------
    def extract_value(row):
        route = concept_route.get(row["concept_id"])
        if route is None:
            return None
        return row[route["source"]]

    df["obs_value"]  = df.apply(extract_value, axis=1)
    df["obs_column"] = df["concept_id"].map(
        {cid: r["target"] for cid, r in concept_route.items()}
    )

    # 3. PIVOT OBS WIDE ----------------------------------------------------------------
    # Group key is now (person_id, site_id, visit_date) — one row per visit
    obs_cols = {}
    for cid, route in concept_route.items():
        col_name = route["target"]
        subset = (
            df[df["concept_id"] == cid][
                ["person_id", "site_id", "visit_date", "obs_value"]
            ]
            .drop_duplicates(subset=["person_id", "site_id", "visit_date"])
            .rename(columns={"obs_value": col_name})
        )
        obs_cols[col_name] = subset

    # 4. AGGREGATE DRUGS — pipe-separated per patient per visit ------------------------
    drugs = (
        df.groupby(["person_id", "site_id", "visit_date"])
        .agg(
            drugs_at_visit  =("drug_name",    lambda x: " | ".join(
                                sorted(x.dropna().unique()))),
            dose_quantity   =("dose_quantity", "first"),
            dose_instr      =("dose_instr",    "first"),
            next_visit_date =("next_visit_date","first"),
            visit_number    =("visit_number",  "first"),
        )
        .reset_index()
    )

    # 5. COLLAPSE STATIC VISIT FIELDS --------------------------------------------------
    static_cols = ["person_id", "site_id", "visit_date"]
    flat = (
        df[static_cols]
        .drop_duplicates(subset=["person_id", "site_id", "visit_date"])
        .reset_index(drop=True)
    )

    # 6. MERGE DRUGS ONTO FLAT ----------------------------------------------------------
    flat = flat.merge(drugs, on=["person_id", "site_id", "visit_date"], how="left")

    # 7. MERGE EACH OBS COLUMN ----------------------------------------------------------
    for col_name, subset in obs_cols.items():
        flat = flat.merge(
            subset, on=["person_id", "site_id", "visit_date"], how="left"
        )

    # 8. DROP DUPLICATES (safety net) ---------------------------------------------------
    before = len(flat)
    flat = flat.drop_duplicates(subset=["person_id", "site_id", "visit_date"])
    after = len(flat)
    if before != after:
        print(f"  Warning: Dropped {before - after} duplicate rows after merge")

    # 9. PREFERRED COLUMN ORDER --------------------------------------------------------
    preferred_order = [
        "person_id", "site_id", "visit_date", "visit_number",
        "drugs_at_visit", "dose_quantity", "dose_instr", "weight_kg", "height_cm", "bmi",
        "patient_pregnant", "patient_breastfeeding", "next_visit_date",
    ]
    final_cols = [c for c in preferred_order if c in flat.columns]
    flat = flat[final_cols]

    return flat

if __name__ == "__main__":
    from extract import extract_initial_visit
    df_raw = extract_initial_visit()
    print("Transforming data.....")
    df_flat = transform_initial_visit(df_raw)
    print(f"Done. {len(df_flat):,} patients in flat table.")
    print(f"\nColumns: {list(df_flat.columns)}")
    print("\n--- Sample output ---")
    print(df_flat.head(10).to_string())