# --------------------------------------------------------
# EXTRACT - Pull obs for a patient initial & followup visits
# --------------------------------------------------------

from sqlalchemy import text
import pandas as pd
from config import mysql_db_con

# Initial visit extract function -------------------------------------------
def extract_initial_visit(concept_route: dict) -> pd.DataFrame:
    # Build concept ID list dynamically from the resolved route
    concept_ids = ", ".join(str(cid) for cid in concept_route.keys())

    # Patient initial visit  query --------------------------   
    initial_visit_query = f"""
    WITH active_clients AS (
    -- Active clients only
    SELECT 
        p.patient_id AS patient_id,
        p.site_id AS site_id,
        p2.gender AS gender,
        p2.birthdate AS date_of_birth,
        p2.birthdate_estimated ,
        ps.start_date AS art_start_date
    FROM patient PARTITION (p413, p207, p611) p 
    JOIN person PARTITION (p413, p207, p611) p2 
        ON p.patient_id = p2.person_id 
        AND p.site_id = p2.site_id 
    JOIN patient_program PARTITION (p413, p207, p611) pp 
        ON pp.patient_id = p.patient_id 
        AND pp.site_id = p.site_id 
    JOIN patient_state PARTITION (p413, p207, p611) ps 
        ON ps.patient_program_id = pp.patient_program_id 
        AND ps.site_id = pp.site_id 
    WHERE pp.program_id = 1  -- HIV program
        AND ps.state = 7  -- Active state
        AND ps.end_date IS NULL 
        AND p.voided = 0
        AND p2.voided = 0
        AND pp.voided = 0
        AND ps.voided = 0 
    ),
    initial_client_encounters AS (
    -- initial encounters 
        SELECT 
            e.patient_id,
            e.site_id ,
            e.encounter_id,
            e.encounter_type ,
            et.name ,
            e.encounter_datetime
        FROM encounter PARTITION (p413, p207, p611) e
        JOIN encounter_type et 
            ON e.encounter_type = et.encounter_type_id 
        WHERE e.encounter_type  IN (5, 6, 9, 52, 53, 54) -- registration, vitals, HIV clinic reg., HIV staging, HIV clinic consult., dispensing
        AND e.voided = 0
    ),
    drug_orders AS (
    -- drug orders on ART initiation
        SELECT
            o.patient_id AS patient_id,
            o.site_id AS site_id,
            d.name AS drug_name,
            o.instructions AS dose_instr,
            do.quantity AS dose_quantity,
            o.start_date AS dosage_start_date,
            o.auto_expire_date AS next_date
        FROM orders PARTITION (p413, p207, p611) o
        JOIN drug_order PARTITION (p413, p207, p611) do
            ON do.order_id = o.order_id
            AND do.site_id = o.site_id
        JOIN drug d
            ON do.drug_inventory_id = d.drug_id
        WHERE o.voided = 0
    )
    SELECT 
        o.person_id ,
        o.site_id ,
        ac.date_of_birth ,
        ac.gender ,
        ac.art_start_date ,
        date(dos.dosage_start_date) AS dosage_start_date,
        date(o.obs_datetime) AS obs_date,
        cn_q.concept_id ,
        o.value_numeric ,
        cn_a.name,
        dos.drug_name ,
        dos.dose_quantity ,
        dos.dose_instr ,
        date(dos.next_date) AS next_visit_date
    FROM obs PARTITION (p413, p207, p611) o
    JOIN initial_client_encounters ice 
        ON o.encounter_id = ice.encounter_id
        AND o.person_id = ice.patient_id 
        AND o.site_id = ice.site_id 
    JOIN active_clients ac 
        ON ac.patient_id = o.person_id 
        AND ac.site_id 	= o.site_id 
    LEFT JOIN drug_orders dos      
        ON  dos.patient_id = o.person_id
        AND dos.site_id    = o.site_id
        AND date(dos.dosage_start_date) = date(ac.art_start_date) -- strictly only doses at ART initiation
    JOIN concept_name cn_q
        ON o.concept_id = cn_q.concept_id
        AND cn_q.locale = 'en'
        AND cn_q.concept_name_type = 'FULLY_SPECIFIED'
    LEFT JOIN concept_name cn_a
        ON o.value_coded = cn_a.concept_id
        AND cn_a.locale = 'en'
        AND cn_a.concept_name_type = 'FULLY_SPECIFIED'
    WHERE DATE(ice.encounter_datetime) = DATE(ac.art_start_date)
        AND o.voided = 0
        AND o.concept_id IN ({concept_ids})
    ORDER BY o.person_id , o.site_id;
    """

    print("Pulling latest obs for a patient initial visit:........")
    engine = mysql_db_con()
    with engine.connect() as conn:
        df = pd.read_sql(text(initial_visit_query), conn)
    print(f"Done. {len(df):,} rows pulled across "
          f"{df['person_id'].nunique():,} patients.")
    return df

# Followup visits extract function -------------------------------------------------------
def extract_followup_visits(concept_route: dict) -> pd.DataFrame:
    concept_ids = ", ".join(str(cid) for cid in concept_route.keys())

# Patient initial visit  query ---------------------------------------------
    followup_query = f"""
    WITH active_clients AS (
    -- Active clients only
        SELECT
            p.patient_id AS patient_id,
            p.site_id    AS site_id,
            ps.start_date AS art_start_date
        FROM patient PARTITION (p413, p207, p611) p
        JOIN person PARTITION (p413, p207, p611) p2
            ON p.patient_id = p2.person_id
            AND p.site_id = p2.site_id
        JOIN patient_program PARTITION (p413, p207, p611) pp
            ON pp.patient_id = p.patient_id
            AND pp.site_id = p.site_id
        JOIN patient_state PARTITION (p413, p207, p611) ps
            ON ps.patient_program_id = pp.patient_program_id
            AND ps.site_id = pp.site_id
        WHERE pp.program_id = 1 -- HIV program
            AND ps.state = 7 -- Active state
            AND ps.end_date IS NULL
            AND p.voided = 0
            AND p2.voided = 0
            AND pp.voided = 0
            AND ps.voided = 0 
    ),
    followup_client_encounters AS (
    -- followup encounters
        SELECT
            e.patient_id AS patient_id,
            e.site_id AS site_id,
            ac.art_start_date AS art_start_date,
            e.encounter_id AS encounter_id,
            e.encounter_datetime AS encounter_date,
            ROW_NUMBER() OVER (PARTITION BY e.patient_id, e.site_id ORDER BY date(e.encounter_datetime) ASC) AS row_num 
        FROM encounter PARTITION (p413, p207, p611) e
        JOIN encounter_type et 
            ON e.encounter_type = et.encounter_type_id 
        JOIN active_clients ac
            ON ac.patient_id = e.patient_id
            AND ac.site_id = e.site_id
        WHERE e.encounter_type  IN (6, 53, 54) -- vitals, HIV clinic consult., dispensing
            AND e.voided = 0
            AND DATE(e.encounter_datetime) > DATE(ac.art_start_date) -- We only get follow-up visits
    ),
    drug_orders AS (
    -- drug orders CTE
        SELECT
            o.patient_id  AS patient_id,
            o.site_id  AS site_id,
            d.name AS drug_name,
            o.instructions  AS dose_instr,
            do.quantity  AS dose_quantity,
            o.start_date AS dosage_start_date,
            o.auto_expire_date  AS next_date
        FROM orders PARTITION (p413, p207, p611) o
        JOIN drug_order PARTITION (p413, p207, p611) do
            ON do.order_id = o.order_id
            AND do.site_id = o.site_id
        JOIN drug d
            ON do.drug_inventory_id = d.drug_id
        WHERE o.voided = 0
    )
    SELECT
        o.person_id,
        o.site_id,
        date(o.obs_datetime)  AS obs_date,
        cn_q.concept_id,
        o.value_numeric,
        cn_a.name,
        dos.drug_name,
        dos.dose_quantity,
        dos.dose_instr,
        date(fce.encounter_date) AS visit_date,
        fce.row_num AS visit_number,
        date(dos.next_date) AS next_visit_date
    FROM obs PARTITION (p413, p207, p611) o
    JOIN followup_client_encounters fce
        ON  o.encounter_id = fce.encounter_id
        AND o.person_id = fce.patient_id
        AND o.site_id = fce.site_id
    JOIN drug_orders dos
        ON  dos.patient_id = o.person_id
        AND dos.site_id = o.site_id
        AND date(dos.dosage_start_date) = date(fce.encounter_date) -- drugs administered on followup visits only
    JOIN concept_name cn_q
        ON  o.concept_id = cn_q.concept_id
        AND cn_q.locale = 'en'
        AND cn_q.concept_name_type = 'FULLY_SPECIFIED'
    LEFT JOIN concept_name cn_a
        ON  o.value_coded = cn_a.concept_id
        AND cn_a.locale = 'en'
        AND cn_a.concept_name_type = 'FULLY_SPECIFIED'
    WHERE o.voided = 0
        AND o.concept_id IN ({concept_ids})
        AND fce.row_num BETWEEN 1 AND 10  -- We only get up to 10 followup visits
    ORDER BY o.person_id, o.site_id, fce.row_num;
    """


    print("Pulling follow-up visit data.....")
    engine = mysql_db_con()
    with engine.connect() as conn:
        df = pd.read_sql(text(followup_query), conn)
    print(f"Done. {len(df):,} rows pulled across "
          f"{df['person_id'].nunique():,} patients.")
    return df

