-- ============================================================
-- MOH COHORT REPORT FOR MIMOSA DISPENSARY 2023 Q3
-- ============================================================
WITH params AS (
    SELECT
        DATE('2023-07-01') AS quarter_start,
        DATE('2023-09-30') AS quarter_end
),
-- ============================================================
-- First ever ART dispensation
-- ============================================================
first_art_start AS (
    SELECT
        od.patient_id,
        od.site_id,
        MIN(DATE(od.start_date)) AS art_start_date
    FROM orders PARTITION (p413) od
    INNER JOIN drug_order do
        ON do.order_id = od.order_id
       AND do.site_id  = od.site_id
    INNER JOIN arv_drug ad
        ON ad.drug_id = do.drug_inventory_id
    WHERE od.voided = 0
    GROUP BY od.patient_id, od.site_id
),
-- ============================================================
-- Excluded patients
-- ============================================================
excluded_patient_types AS (
SELECT
    person_id,
    site_id,
    x.row_num 
FROM (
    SELECT
        o.person_id,
        o.site_id,
        cn2.name,
        ROW_NUMBER() OVER (PARTITION BY o.person_id, o.site_id ORDER BY date(o.obs_datetime)) AS row_num
    FROM obs PARTITION (p413) o
    INNER JOIN concept_name cn2
        ON cn2.concept_id = o.value_coded
    WHERE o.voided = 0
      AND o.concept_id = 3289  -- patient_type
) x
WHERE row_num = 1
  AND name IN ('External consultation','Emergency Supply','Drug refill')
),
-- ============================================================
-- All enrolled cumulatively up to quarter end
-- ============================================================
all_enrolled_cumulative AS (
    SELECT
        fas.patient_id,
        fas.site_id,
        fas.art_start_date,
        p.birthdate,
        p.gender
    FROM first_art_start fas
    INNER JOIN person PARTITION (p413) p
        ON p.person_id = fas.patient_id
       AND p.site_id   = fas.site_id
    LEFT JOIN excluded_patient_types ept
        ON ept.person_id = fas.patient_id
       AND ept.site_id   = fas.site_id
    CROSS JOIN params prm
    WHERE ept.person_id IS NULL
      AND fas.art_start_date <= prm.quarter_end
),
-- ============================================================
-- First-time patients
-- ============================================================
first_time_patients AS (
    SELECT
        aec.patient_id,
        aec.site_id
    FROM all_enrolled_cumulative aec
    CROSS JOIN params prm
    WHERE aec.art_start_date
          BETWEEN prm.quarter_start
              AND prm.quarter_end
),
-- ============================================================
-- Transfer-ins
-- ============================================================
transfer_ins AS (
    SELECT DISTINCT
        o.person_id AS patient_id,
        o.site_id
    FROM obs PARTITION (p413) o
    CROSS JOIN params prm
    WHERE o.voided = 0
      AND o.concept_id IN (7937, 6394)  -- ever registered at ART clinic / Has the patient taken ART in the last two weeks
      AND (o.value_coded = 1065 OR LOWER(o.value_text) = 'yes')
      AND DATE(o.obs_datetime) BETWEEN prm.quarter_start AND prm.quarter_end
),
-- ============================================================
-- Quarter dispensing encounters
-- ============================================================
quarter_dispensations AS (
    SELECT
        od.patient_id,
        od.site_id,
        od.order_id,
        DATE(od.start_date) AS dispensation_date
    FROM orders PARTITION (p413) od
    INNER JOIN encounter PARTITION (p413) e
        ON e.encounter_id = od.encounter_id
       AND e.site_id      = od.site_id
    CROSS JOIN params prm
    WHERE od.voided = 0
      AND e.encounter_type = 54 -- dispensing
      AND DATE(od.start_date)
          BETWEEN prm.quarter_start
              AND prm.quarter_end
),
-- ============================================================
-- Last dispensation before quarter dispensation
-- ============================================================
last_dispensation_before_restart AS (
    SELECT
        ranked.patient_id,
        ranked.site_id,
        DATE_ADD(
            DATE(ranked.start_date),
            INTERVAL CEIL(
                (
                    ranked.quantity
                    + COALESCE(ranked.brought_forward,0)
                ) / NULLIF(ranked.equivalent_daily_dose,0)
            ) DAY
        ) AS expected_next_appointment
    FROM (
        SELECT
            qd.patient_id,
            qd.site_id,
            od.start_date,
            do.quantity,
            do.equivalent_daily_dose,
            COALESCE(
                pbf.value_numeric,
                CAST(pbf.value_text AS DECIMAL(10,2)),
                0
            ) AS brought_forward,
            ROW_NUMBER() OVER (PARTITION BY qd.patient_id, qd.site_id ORDER BY od.start_date DESC) AS row_num
        FROM quarter_dispensations qd
        INNER JOIN orders PARTITION (p413) od
            ON od.patient_id = qd.patient_id
           AND od.site_id = qd.site_id
           AND DATE(od.start_date) < qd.dispensation_date
           AND od.voided = 0
        INNER JOIN drug_order do
            ON do.order_id = od.order_id
           AND do.site_id  = od.site_id
        INNER JOIN arv_drug ad
            ON ad.drug_id = do.drug_inventory_id
        LEFT JOIN obs PARTITION (p413) pbf
            ON pbf.person_id  = od.patient_id
           AND pbf.site_id = od.site_id
           AND pbf.order_id = od.order_id
           AND pbf.concept_id = 2540 -- Amount of drug brought to clinic
           AND pbf.voided = 0
    ) ranked
    WHERE ranked.row_num = 1
),
-- ============================================================
-- Re-initiated
-- ============================================================
re_initiated AS (
    SELECT DISTINCT
        qd.patient_id,
        qd.site_id
    FROM quarter_dispensations qd
    INNER JOIN last_dispensation_before_restart ldr
        ON ldr.patient_id = qd.patient_id
       AND ldr.site_id = qd.site_id
    LEFT JOIN transfer_ins ti
        ON ti.patient_id = qd.patient_id
       AND ti.site_id = qd.site_id
    WHERE DATEDIFF(qd.dispensation_date,ldr.expected_next_appointment) >= 30
      AND ti.patient_id IS NULL
),
-- ============================================================
-- Quarter registered
-- ============================================================
quarter_registered AS (
    SELECT
        patient_id,  site_id
    FROM first_time_patients
    UNION
    SELECT
        patient_id, site_id
    FROM transfer_ins
    UNION
    SELECT
        patient_id, site_id
    FROM re_initiated
),
-- ============================================================
-- Final classification for the Quarter
-- ============================================================
patient_classification_quarter AS (
    SELECT
        qr.patient_id,
        qr.site_id,
        CASE
            WHEN ti.patient_id IS NOT NULL THEN 'TRANSFER_IN'
            WHEN ri.patient_id IS NOT NULL THEN 'RE_INITIATED'
            WHEN ft.patient_id IS NOT NULL THEN 'FIRST_TIME'
            ELSE 'UNCLASSIFIED'
        END AS patient_type
    FROM quarter_registered qr
    LEFT JOIN transfer_ins ti
        ON ti.patient_id = qr.patient_id
       AND ti.site_id = qr.site_id
    LEFT JOIN re_initiated ri
        ON ri.patient_id = qr.patient_id
       AND ri.site_id = qr.site_id
    LEFT JOIN first_time_patients ft
        ON ft.patient_id = qr.patient_id
       AND ft.site_id = qr.site_id
),
-- ============================================================
-- Transfer-ins cumulative
-- ============================================================
transfer_ins_cumulative AS (
    SELECT DISTINCT
        o.person_id AS patient_id,
        o.site_id
    FROM obs PARTITION (p413) o
    CROSS JOIN params prm
    WHERE o.voided = 0
      AND o.concept_id IN (7937, 6394) -- ever registered at ART clinic / Has the patient taken ART in the last two weeks
      AND (o.value_coded = 1065 OR LOWER(o.value_text) = 'yes')
      AND DATE(o.obs_datetime) <= prm.quarter_end
),
-- ============================================================
-- All dispensing encounters up to quarter end
-- ============================================================
dispensations_cumulative AS (
    SELECT
        od.patient_id,
        od.site_id,
        od.order_id,
        DATE(od.start_date) AS dispensation_date
    FROM orders PARTITION (p413) od
    INNER JOIN encounter PARTITION (p413) e
        ON e.encounter_id = od.encounter_id
       AND e.site_id = od.site_id
    CROSS JOIN params prm
    WHERE od.voided = 0
      AND e.encounter_type = 54
      AND DATE(od.start_date) <= prm.quarter_end
),
-- ============================================================
-- Last dispensation before each dispensing event
-- ============================================================
last_dispensation_before_restart_cumulative AS (
    SELECT
        ranked.patient_id,
        ranked.site_id,
        ranked.dispensation_date,
        DATE_ADD(
            DATE(ranked.start_date),
            INTERVAL CEIL(
                (ranked.quantity
                    + COALESCE(ranked.brought_forward,0)
                ) / NULLIF(ranked.equivalent_daily_dose,0)
            ) DAY
        ) AS expected_next_appointment
    FROM (
        SELECT
            dc.patient_id,
            dc.site_id,
            dc.dispensation_date,
            od.start_date,
            do.quantity,
            do.equivalent_daily_dose,
            COALESCE(pbf.value_numeric, CAST(pbf.value_text AS DECIMAL(10,2)), 0) AS brought_forward,
            ROW_NUMBER() OVER (PARTITION BY dc.patient_id, dc.site_id, dc.dispensation_date ORDER BY od.start_date DESC) AS row_num
        FROM dispensations_cumulative dc
        INNER JOIN orders PARTITION (p413) od
            ON od.patient_id = dc.patient_id
           AND od.site_id    = dc.site_id
           AND DATE(od.start_date) < dc.dispensation_date
           AND od.voided = 0
        INNER JOIN drug_order do
            ON do.order_id = od.order_id
           AND do.site_id  = od.site_id
        INNER JOIN arv_drug ad
            ON ad.drug_id = do.drug_inventory_id
        LEFT JOIN obs PARTITION (p413) pbf
            ON pbf.person_id  = od.patient_id
           AND pbf.site_id    = od.site_id
           AND pbf.order_id   = od.order_id
           AND pbf.concept_id = 2540
           AND pbf.voided     = 0
    ) ranked
    WHERE ranked.row_num = 1
),
-- ============================================================
-- Re-initiated cumulative
-- ============================================================
re_initiated_cumulative AS (
    SELECT DISTINCT
        dc.patient_id,
        dc.site_id
    FROM dispensations_cumulative dc
    INNER JOIN last_dispensation_before_restart_cumulative ldr
        ON ldr.patient_id = dc.patient_id
       AND ldr.site_id = dc.site_id
       AND ldr.dispensation_date = dc.dispensation_date
    LEFT JOIN transfer_ins_cumulative ti
        ON ti.patient_id = dc.patient_id
       AND ti.site_id    = dc.site_id
    WHERE DATEDIFF(dc.dispensation_date,ldr.expected_next_appointment) >= 30
      AND ti.patient_id IS NULL
),
-- ============================================================
-- First-time cumulative
-- ============================================================
first_time_patients_cumulative AS (
    SELECT
        patient_id,
        site_id
    FROM all_enrolled_cumulative
),
-- ============================================================
-- Registered cumulative
-- ============================================================
registered_cumulative AS (
    SELECT
        patient_id,  site_id
    FROM first_time_patients_cumulative
    UNION
    SELECT
        patient_id, site_id
    FROM transfer_ins_cumulative
    UNION
    SELECT
        patient_id, site_id
    FROM re_initiated_cumulative
),
-- ============================================================
-- Final cumulative classification
-- ============================================================
patient_classification_cumulative AS (
    SELECT
        rc.patient_id,
        rc.site_id,
        CASE
            WHEN ti.patient_id IS NOT NULL THEN 'TRANSFER_IN'
            WHEN ri.patient_id IS NOT NULL THEN 'RE_INITIATED'
            WHEN ft.patient_id IS NOT NULL THEN 'FIRST_TIME'
            ELSE 'UNCLASSIFIED'
        END AS patient_type
    FROM registered_cumulative rc
    LEFT JOIN transfer_ins_cumulative ti
        ON ti.patient_id = rc.patient_id
       AND ti.site_id = rc.site_id
    LEFT JOIN re_initiated_cumulative ri
        ON ri.patient_id = rc.patient_id
       AND ri.site_id = rc.site_id
    LEFT JOIN first_time_patients_cumulative ft
        ON ft.patient_id = rc.patient_id
       AND ft.site_id = rc.site_id
),
reproductive_status_quarter AS (
    SELECT
        person_id,
        site_id,
        MAX(CASE WHEN (value_coded = 1065 OR LOWER(value_text)='yes') THEN 1 ELSE 0 END) AS is_pregnant,
        MAX(CASE WHEN (value_coded = 1066 OR LOWER(value_text)='no') THEN 1 ELSE 0 END) AS is_not_pregnant
    FROM (
        SELECT
            o.person_id,
            o.site_id,
            o.concept_id,
            o.value_coded,
            o.value_text,
            ROW_NUMBER() OVER (PARTITION BY o.person_id,o.site_id,o.concept_id ORDER BY o.obs_datetime DESC) AS row_num
        FROM obs PARTITION (p413) o
        INNER JOIN patient_classification_quarter pcq
            ON pcq.patient_id = o.person_id
           AND pcq.site_id    = o.site_id
        INNER JOIN person PARTITION (p413) p
            ON p.person_id = o.person_id
           AND p.site_id   = o.site_id
           AND p.gender    = 'F'
        CROSS JOIN params prm
        WHERE o.voided = 0
          AND o.concept_id IN (1434,6131,1755)
          AND DATE(o.obs_datetime)
                BETWEEN prm.quarter_start
                    AND prm.quarter_end
    ) x
    WHERE row_num = 1
    GROUP BY person_id, site_id
),
reproductive_status_cumulative AS (
    SELECT
        person_id,
        site_id,
        MAX(CASE WHEN (value_coded = 1065 OR LOWER(value_text)='yes') THEN 1 ELSE 0 END) AS is_pregnant,
        MAX(CASE WHEN (value_coded = 1066 OR LOWER(value_text)='no') THEN 1 ELSE 0 END) AS is_not_pregnant
    FROM (
        SELECT
            o.person_id,
            o.site_id,
            o.concept_id,
            o.value_coded,
            o.value_text,
            ROW_NUMBER() OVER (PARTITION BY o.person_id, o.site_id,o.concept_id ORDER BY o.obs_datetime DESC) AS row_num
        FROM obs PARTITION (p413) o
        INNER JOIN patient_classification_cumulative pcc
            ON pcc.patient_id = o.person_id
           AND pcc.site_id    = o.site_id
        INNER JOIN person PARTITION (p413) p
            ON p.person_id = o.person_id
           AND p.site_id   = o.site_id
           AND p.gender = 'F'
        CROSS JOIN params prm
        WHERE o.voided = 0
          AND o.concept_id IN (1434,6131,1755)
          AND DATE(o.obs_datetime) <= prm.quarter_end
    ) x
    WHERE row_num = 1
    GROUP BY person_id,  site_id
),
patient_summary_quarter AS (
    SELECT
        pcq.patient_id,
        pcq.site_id,
        aec.gender,
        aec.birthdate,
        aec.art_start_date,
        TIMESTAMPDIFF(MONTH, aec.birthdate, aec.art_start_date) AS age_months_at_art,
        TIMESTAMPDIFF(YEAR, aec.birthdate, aec.art_start_date) AS age_years_at_art,
        CASE WHEN pcq.patient_type = 'FIRST_TIME' THEN 1 ELSE 0 END AS is_first_time,
        CASE WHEN pcq.patient_type = 'TRANSFER_IN' THEN 1 ELSE 0 END AS is_transfer_in,
        CASE WHEN pcq.patient_type = 'RE_INITIATED' THEN 1 ELSE 0 END AS is_re_initiated,
        COALESCE(rs.is_pregnant,0) AS is_pregnant,
        COALESCE(rs.is_not_pregnant,0) AS is_not_pregnant
    FROM patient_classification_quarter pcq
    INNER JOIN all_enrolled_cumulative aec
        ON aec.patient_id = pcq.patient_id
       AND aec.site_id    = pcq.site_id
    LEFT JOIN reproductive_status_quarter rs
        ON rs.person_id = pcq.patient_id
       AND rs.site_id   = pcq.site_id
),
patient_summary_cumulative AS (
    SELECT
        pcc.patient_id,
        pcc.site_id,
        aec.gender,
        aec.birthdate,
        aec.art_start_date,
        TIMESTAMPDIFF(MONTH, aec.birthdate, aec.art_start_date) AS age_months_at_art,
        TIMESTAMPDIFF(YEAR, aec.birthdate, aec.art_start_date) AS age_years_at_art,
        CASE WHEN pcc.patient_type = 'FIRST_TIME' THEN 1 ELSE 0 END AS is_first_time,
        CASE WHEN pcc.patient_type = 'TRANSFER_IN' THEN 1 ELSE 0 END AS is_transfer_in,
        CASE WHEN pcc.patient_type = 'RE_INITIATED' THEN 1 ELSE 0 END AS is_re_initiated,
        COALESCE(rs.is_pregnant,0) AS is_pregnant,
        COALESCE(rs.is_not_pregnant,0) AS is_not_pregnant
    FROM patient_classification_cumulative pcc
    INNER JOIN all_enrolled_cumulative aec
        ON aec.patient_id = pcc.patient_id
       AND aec.site_id = pcc.site_id    
    LEFT JOIN reproductive_status_cumulative rs
        ON rs.person_id = pcc.patient_id
       AND rs.site_id = pcc.site_id
)
-- ============================================================
-- MOH Cohort Report Rows 25 - 38
-- ============================================================
SELECT
    25 AS row_num,
    'Total registered' AS item,
    COUNT(*) AS quarter_count,
    (SELECT COUNT(*) FROM patient_summary_cumulative) AS cumulative_count
FROM patient_summary_quarter
UNION ALL
-- ============================================================
-- FT Patients
-- ============================================================
SELECT
    26,
    'FT Patients initiated on ART first time - Male',
    SUM(CASE WHEN is_first_time = 1 AND gender = 'M' THEN 1 ELSE 0 END),
    (SELECT SUM(CASE WHEN is_first_time = 1 AND gender = 'M' THEN 1 ELSE 0 END) FROM patient_summary_cumulative)
FROM patient_summary_quarter
UNION ALL
SELECT
    27,
    'FT Patients initiated on ART first time - Female Non-pregnant',
    SUM(CASE WHEN is_first_time = 1 AND gender = 'F' AND is_pregnant = 0 THEN 1 ELSE 0 END),
    (SELECT SUM(CASE WHEN is_first_time = 1 AND gender = 'F' AND is_pregnant = 0 THEN 1 ELSE 0 END) FROM patient_summary_cumulative)
FROM patient_summary_quarter
UNION ALL
SELECT
    28,
    'FT Patients initiated on ART first time - Female Pregnant',
    SUM(CASE WHEN is_first_time = 1 AND gender = 'F' AND is_pregnant = 1 THEN 1 ELSE 0 END),
    (SELECT SUM(CASE WHEN is_first_time = 1 AND gender = 'F' AND is_pregnant = 1 THEN 1 ELSE 0 END) FROM patient_summary_cumulative)
FROM patient_summary_quarter
UNION ALL
SELECT
    30,
    'CHECK: Total FT',
    SUM(is_first_time),
    (SELECT SUM(is_first_time) FROM patient_summary_cumulative )
FROM patient_summary_quarter
UNION ALL
-- ============================================================
-- Re-Initiated
-- ============================================================
-- SELECT
--     31,
--     'Patients re-initiated on ART',
--     SUM(is_re_initiated),
--     (SELECT SUM(is_re_initiated) FROM patient_summary_cumulative )
-- FROM patient_summary_quarter
-- UNION ALL
-- ============================================================
-- Transfer In
-- ============================================================
-- SELECT
--     32,
--     'Patients transferred in on ART',
--     SUM(is_transfer_in),
--     (SELECT SUM(is_transfer_in) FROM patient_summary_cumulative )
-- FROM patient_summary_quarter
-- UNION ALL
-- ============================================================
-- ALL REGISTERED (FT + TI + RE)
-- ============================================================
SELECT
    33,
    'M Males (all ages)',
    SUM(CASE WHEN gender = 'M' THEN 1 ELSE 0 END),
    (SELECT SUM(CASE WHEN gender = 'M' THEN 1 ELSE 0 END) FROM patient_summary_cumulative )
FROM patient_summary_quarter
UNION ALL
SELECT
    34,
    'FNP Non-pregnant Females (all ages)',
    SUM(CASE WHEN gender = 'F' AND is_pregnant = 0 THEN 1 ELSE 0 END),
    (SELECT SUM(CASE WHEN gender = 'F' AND is_pregnant = 0 THEN 1 ELSE 0 END)  FROM patient_summary_cumulative )
FROM patient_summary_quarter
UNION ALL
SELECT
    35,
    'FP Pregnant Females (all ages)',
    SUM(CASE WHEN gender = 'F' AND is_pregnant = 1  THEN 1 ELSE 0  END ),
    (   SELECT SUM(
            CASE
                WHEN gender = 'F'
                 AND is_pregnant = 1
                THEN 1 ELSE 0
            END
        )
        FROM patient_summary_cumulative
    )
FROM patient_summary_quarter
UNION ALL
SELECT
    36,
    'A Children below 24 months at ART initiation',
    SUM(
        CASE
            WHEN age_months_at_art < 24
            THEN 1 ELSE 0
        END
    ),
    (
        SELECT SUM(
            CASE
                WHEN age_months_at_art < 24
                THEN 1 ELSE 0
            END
        )
        FROM patient_summary_cumulative
    )
FROM patient_summary_quarter
UNION ALL
SELECT
    37,
    'B Children 24 months - 14 years at ART initiation',
    SUM(
        CASE
            WHEN age_months_at_art >= 24
             AND age_years_at_art <= 14
            THEN 1 ELSE 0
        END
    ),
    (
        SELECT SUM(
            CASE
                WHEN age_months_at_art >= 24
                 AND age_years_at_art <= 14
                THEN 1 ELSE 0
            END
        )
        FROM patient_summary_cumulative
    )
FROM patient_summary_quarter
UNION ALL
SELECT
    38,
    'C Adults 15 years+ at ART initiation',
    SUM(
        CASE
            WHEN age_years_at_art >= 15
            THEN 1 ELSE 0
        END
    ),
    (
        SELECT SUM(
            CASE
                WHEN age_years_at_art >= 15
                THEN 1 ELSE 0
            END
        )
        FROM patient_summary_cumulative
    )
FROM patient_summary_quarter
ORDER BY row_num;





