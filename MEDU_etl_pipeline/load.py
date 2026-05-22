# -------------------------------------------------------------------------------------
# LOAD - into postgres CDR_db
# --------------------------------------------------------------------------------------

import pandas as pd
from sqlalchemy import text
from config import postgresql_db_con


def load(df: pd.DataFrame,
         table_name: str,
         pk_cols: list,
         create_sql: str) -> None:

    engine = postgresql_db_con()

    # 1. CREATE TABLE IF NOT EXISTS ---------------------------------------------------
    with engine.begin() as conn:
        conn.execute(text(create_sql))
    print(f"  Table '{table_name}' ready.")

    # 2. FIND EXISTING KEYS -----------------------------------------------------------
    with engine.connect() as conn:
        existing = pd.read_sql(
            text(f"SELECT {', '.join(pk_cols)} FROM {table_name}"),
            conn
        )

    #3. ALIGN TYPES BEFORE MERGE -----------------------------------------------------
    for col in pk_cols:
        if col in df.columns and col in existing.columns:
            existing[col] = existing[col].astype(df[col].dtype)

    # 4. ANTI-JOIN — new rows only ---------------------------------------------------
    if len(existing) > 0:
        df_new = df.merge(
            existing, on=pk_cols, how="left", indicator=True
        )
        df_new = df_new[df_new["_merge"] == "left_only"].drop(
            columns=["_merge"]
        )
    else:
        df_new = df

    # 5. INSERT ----------------------------------------------------------------------
    if len(df_new) == 0:
        print(f"  No new rows — all {len(df):,} records already exist.")
        return

    df_new.to_sql(
        table_name, engine,
        if_exists="append",   # never overwrites existing rows
        index=False,
        method="multi",
        chunksize=10000,   # batches inserts — faster than row by row
    )
    print(f"  Loaded {len(df_new):,} new rows into '{table_name}'.")
    if len(df) - len(df_new) > 0:
        print(f"  Skipped {len(df) - len(df_new):,} existing rows.")