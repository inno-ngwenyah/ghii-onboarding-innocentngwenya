===========================================================================================================
-- PEPFAR Q4 for Mimosa dispensary: 2023-07-01 to 2023-09-30 
===========================================================================================================
WITH all_enrolled AS (
    SELECT
        person_id  AS patient_id,
        site_id,
        DATE(value_datetime) AS art_start_date
    FROM (
        SELECT
            o.person_id,
            o.site_id,
            o.value_datetime,
            ROW_NUMBER() OVER (PARTITION BY o.person_id, o.site_id ORDER BY o.obs_datetime DESC) AS row_num
        FROM obs PARTITION (p413) o
        WHERE o.concept_id = 2516          -- date_art_started
          AND o.voided = 0
          AND o.value_datetime IS NOT NULL
          AND DATE(o.value_datetime) BETWEEN '2023-07-01' AND '2023-09-30'
    ) ranked
    WHERE row_num = 1
),
-- ============================================================
-- CTE 2 : ever_dispensed_in_quarter
-- Patients who received an ARV dispensation during the quarter.
-- Used as the entry gate — only patients appearing here are
-- counted. Prevents phantom initiations with no drug record.
-- ============================================================
ever_dispensed_in_quarter AS ( 
    SELECT DISTINCT
        e.patient_id,
        e.site_id
    FROM encounter PARTITION (p413) e
    JOIN obs o
        ON  o.person_id = e.patient_id
        AND o.site_id   = e.site_id
    JOIN orders PARTITION (p413) od
        ON  od.patient_id = o.person_id
        AND od.site_id    = o.site_id
        AND od.order_id   = o.order_id
        AND od.voided     = 0
    JOIN drug_order do
        ON  do.order_id = od.order_id
    JOIN arv_drug ad
        ON  ad.drug_id  = do.drug_inventory_id
    WHERE e.voided        = 0
      AND e.encounter_type = 54              -- ARV dispensing encounter
      AND do.quantity      > 0
      AND DATE(od.start_date) BETWEEN '2023-07-01' AND '2023-09-30'
),
-- ============================================================
-- CTE 3 : first_arv_dispensation
-- Earliest ARV dispensation date per patient across ALL history
-- (not just the quarter). This is the dispensation-side truth
-- for TX_NEW vs transfer-in classification.
-- Only evaluated for patients active in the quarter (via join
-- to ever_dispensed_in_quarter).
-- ============================================================
first_arv_dispensation AS (
    SELECT
        od.patient_id,
        od.site_id,
        MIN(DATE(od.start_date)) AS first_arv_date
    FROM orders PARTITION (p413) od
    JOIN drug_order do
        ON  do.order_id = od.order_id
    JOIN arv_drug ad
        ON  ad.drug_id  = do.drug_inventory_id
    JOIN ever_dispensed_in_quarter edq
        ON  edq.patient_id = od.patient_id
        AND edq.site_id    = od.site_id
    WHERE od.voided    = 0
      AND do.quantity  > 0
    GROUP BY od.patient_id, od.site_id
),
-- ============================================================
-- CTE 4 : art_last_taken
-- Most recent patient-reported date of last ARV intake
-- (concept 7751). Used to compute the transfer-in gap when
-- ever_registered = 'yes'.
-- ============================================================
art_last_taken AS (
    SELECT
        person_id,
        site_id,
        DATE(value_datetime) AS art_last_taken_date
    FROM (
        SELECT
            o.person_id,
            o.site_id,
            o.value_datetime,
            ROW_NUMBER() OVER (PARTITION BY o.person_id, o.site_id ORDER BY o.obs_datetime DESC) AS row_num
        FROM obs PARTITION (p413) o
        WHERE o.concept_id = 7751          -- art_last_taken
          AND o.voided = 0
          AND o.value_datetime IS NOT NULL
    ) ranked
    WHERE row_num = 1
),
-- ============================================================
-- CTE 5 : ever_registered
-- Patient self-report: have you ever registered on ART?
-- (concept 7937). Secondary signal — dispensation overrides
-- when the two conflict.
-- ============================================================
ever_registered AS (
    SELECT
        person_id,
        site_id,
        CASE
            WHEN value_coded = 1065 OR LOWER(value_text) = 'yes' THEN 'yes'
            WHEN value_coded = 1066 OR LOWER(value_text) = 'no'  THEN 'no'
            ELSE NULL
        END AS ever_registered_on_art
    FROM (
        SELECT
            o.person_id,
            o.site_id,
            o.value_coded,
            o.value_text,
            ROW_NUMBER() OVER (PARTITION BY o.person_id, o.site_id ORDER BY o.obs_datetime DESC) AS row_num
        FROM obs PARTITION (p413) o
        WHERE o.concept_id = 7937
          AND o.voided     = 0
    ) ranked
    WHERE row_num = 1
),
-- ============================================================
-- CTE 6 : cd4_obs
-- Most recent CD4 count (concept 5497) recorded within 90 days
-- before or on ART start date. Used for TX_NEW CD4 disaggregation.
-- ============================================================
cd4_obs AS (
    SELECT
        person_id,
        site_id,
        value_numeric,
        value_modifier
    FROM (
        SELECT
            o.person_id,
            o.site_id,
            o.value_numeric,
            o.value_modifier,
            ROW_NUMBER() OVER (PARTITION BY o.person_id, o.site_id ORDER BY o.obs_datetime DESC) AS row_num
        FROM obs PARTITION (p413) o
        JOIN all_enrolled ae
            ON  ae.patient_id = o.person_id
            AND ae.site_id = o.site_id
            -- CD4 must fall within 90 days before ART start
            AND DATE(o.obs_datetime) BETWEEN DATE_SUB(ae.art_start_date, INTERVAL 90 DAY) AND ae.art_start_date
        WHERE o.voided     = 0
          AND o.concept_id = 5497              -- CD4 count
    ) ranked
    WHERE row_num = 1
),
-- ============================================================
-- CTE 7 : reproductive_status
-- Latest pregnancy / breastfeeding obs per patient within the
-- reporting quarter. Restricted to enrolled cohort only.
-- Concepts:
--   Pregnant     : 1434, 6131, 1755  (yes = 1065, no = 1066)
--   Breastfeeding: 5632, 7965        (yes = 1065)
-- ============================================================
reproductive_status AS (
    SELECT
        person_id,
        site_id,
        MAX(CASE
            WHEN concept_id IN (1434, 6131, 1755)
             AND (value_coded = 1065 OR LOWER(value_text) = 'yes')
            THEN 1 ELSE 0
        END) AS is_pregnant,
        MAX(CASE
            WHEN concept_id IN (1434, 6131, 1755)
             AND (value_coded = 1066 OR LOWER(value_text) = 'no')
            THEN 1 ELSE 0
        END) AS is_not_pregnant,
        MAX(CASE
            WHEN concept_id IN (5632, 7965)
             AND (value_coded = 1065 OR LOWER(value_text) = 'yes')
            THEN 1 ELSE 0
        END) AS is_breastfeeding
    FROM (
        SELECT
            o.person_id,
            o.site_id,
            o.concept_id,
            o.value_coded,
            o.value_text,
            ROW_NUMBER() OVER (PARTITION BY o.person_id, o.site_id, o.concept_id ORDER BY o.obs_datetime DESC) AS row_num
        FROM obs PARTITION (p413) o
        JOIN all_enrolled ae
            ON  ae.patient_id = o.person_id
            AND ae.site_id    = o.site_id
        WHERE o.voided     = 0
          AND o.concept_id IN (1434, 6131, 1755, 5632, 7965)
          AND DATE(o.obs_datetime) BETWEEN '2023-07-01' AND '2023-09-30'
    ) latest_per_concept
    WHERE row_num = 1
    GROUP BY person_id, site_id
),
-- ============================================================
-- CTE 8 : patient_summary
-- Joins all CTEs above into one row per patient.
-- Applies the classification hierarchy:
--
--   CONFLICT RULE (dispensation wins):
--     A) ever_registered = 'no' BUT first_arv_date < '2023-07-01'
--        → not_specified  (dispensation history predates quarter,
--          self-report is unreliable)
--     B) ever_registered = 'yes' AND art_last_taken IS NULL
--        → fall back to DATEDIFF(art_start_date, first_arv_date)
--          if gap > 14 → is_transfer_in, else not_specified
--
--   NORMAL FLOW:
--     newly_enrolled : first_arv_date IN quarter
--                      AND (ever_registered = 'no' OR NULL)
--     is_transfer_in : ever_registered = 'yes'
--                      AND gap > 14 (art_last_taken preferred,
--                          first_arv_date as fallback)
--     not_specified  : everything else
-- ============================================================
patient_summary AS (
    SELECT
        ae.patient_id,
        ae.site_id,
        ae.art_start_date,
        p.gender,
        TIMESTAMPDIFF(YEAR, p.birthdate, ae.art_start_date) AS age_at_art_start,
        -- CD4 band for disaggregation
        CASE
            WHEN cd.value_numeric IS NOT NULL AND (cd.value_modifier = '<' OR cd.value_numeric < 200) THEN 'lt200'
            WHEN cd.value_numeric >= 200 THEN 'gtoe200'
            ELSE 'unknown'
        END AS cd4_band,
        -- Reproductive flags (NULL-safe defaults)
        COALESCE(rs.is_pregnant,      0) AS is_pregnant,
        COALESCE(rs.is_not_pregnant,  0) AS is_not_pregnant,
        COALESCE(rs.is_breastfeeding, 0) AS is_breastfeeding,
        -- -------------------------------------------------------
        -- Patient type classification
        -- Priority order:
        --   1. Conflict check  — dispensation overrides self-report
        --   2. Transfer-in     — ever_registered yes + gap > 14
        --   3. Newly enrolled  — first ARV in quarter, no prior ART
        --   4. Not specified   — cannot cleanly classify
        -- -------------------------------------------------------
        CASE
            -- CONFLICT A: self-reports no prior ART but dispensation
            -- history predates the quarter — override to not_specified
            WHEN er.ever_registered_on_art = 'no'
             AND fad.first_arv_date < '2023-07-01'
            THEN 'not_specified'
            -- TRANSFER-IN (primary path):
            -- ever_registered = 'yes' AND art_last_taken gap > 14 days
            WHEN er.ever_registered_on_art = 'yes'
             AND alt.art_last_taken_date   IS NOT NULL
             AND DATEDIFF(ae.art_start_date, alt.art_last_taken_date) > 14
            THEN 'is_transfer_in'
            -- TRANSFER-IN (fallback path — CONFLICT B):
            -- ever_registered = 'yes' BUT art_last_taken IS NULL
            -- use dispensation gap as proxy
            WHEN er.ever_registered_on_art = 'yes'
             AND alt.art_last_taken_date IS NULL
             AND fad.first_arv_date IS NOT NULL
             AND DATEDIFF(ae.art_start_date, fad.first_arv_date) > 14
            THEN 'is_transfer_in'
            -- NEWLY ENROLLED:
            -- first ARV dispensation falls inside the quarter
            -- AND no credible prior ART history
            WHEN fad.first_arv_date BETWEEN '2023-07-01' AND '2023-09-30'
             AND (er.ever_registered_on_art = 'no' OR er.ever_registered_on_art IS NULL)
            THEN 'newly_enrolled'
            -- NOT SPECIFIED: all remaining cases
            ELSE 'not_specified'
        END AS patient_type
    FROM all_enrolled ae
    -- Gender from person table
    JOIN person p
        ON  p.person_id = ae.patient_id
        AND p.voided    = 0
    -- Dispensation gate — only patients with a quarter dispensation count
    JOIN ever_dispensed_in_quarter edq
        ON  edq.patient_id = ae.patient_id
        AND edq.site_id    = ae.site_id
    -- All downstream CTEs are LEFT JOINed; a missing obs row
    -- should never exclude a patient from the report
    LEFT JOIN first_arv_dispensation fad
        ON  fad.patient_id = ae.patient_id
        AND fad.site_id    = ae.site_id
    LEFT JOIN art_last_taken alt
        ON  alt.person_id = ae.patient_id
        AND alt.site_id   = ae.site_id
    LEFT JOIN ever_registered er
        ON  er.person_id = ae.patient_id
        AND er.site_id   = ae.site_id
    LEFT JOIN cd4_obs cd
        ON  cd.person_id = ae.patient_id
        AND cd.site_id   = ae.site_id
    LEFT JOIN reproductive_status rs
        ON  rs.person_id = ae.patient_id
        AND rs.site_id   = ae.site_id
),
-- ============================================================
-- CTE 9 : patient_bands
-- Assigns 5-year age bands based on age at ART start.
-- Passes all patient_summary columns through unchanged.
-- ============================================================
patient_bands AS (
    SELECT
        *,
        CASE
            WHEN age_at_art_start <  1 THEN '<1 year'
            WHEN age_at_art_start BETWEEN  1 AND  4 THEN '1-4 years'
            WHEN age_at_art_start BETWEEN  5 AND  9 THEN '5-9 years'
            WHEN age_at_art_start BETWEEN 10 AND 14 THEN '10-14 years'
            WHEN age_at_art_start BETWEEN 15 AND 19 THEN '15-19 years'
            WHEN age_at_art_start BETWEEN 20 AND 24 THEN '20-24 years'
            WHEN age_at_art_start BETWEEN 25 AND 29 THEN '25-29 years'
            WHEN age_at_art_start BETWEEN 30 AND 34 THEN '30-34 years'
            WHEN age_at_art_start BETWEEN 35 AND 39 THEN '35-39 years'
            WHEN age_at_art_start BETWEEN 40 AND 44 THEN '40-44 years'
            WHEN age_at_art_start BETWEEN 45 AND 49 THEN '45-49 years'
            WHEN age_at_art_start BETWEEN 50 AND 54 THEN '50-54 years'
            WHEN age_at_art_start BETWEEN 55 AND 59 THEN '55-59 years'
            WHEN age_at_art_start BETWEEN 60 AND 64 THEN '60-64 years'
            WHEN age_at_art_start BETWEEN 65 AND 69 THEN '65-69 years'
            WHEN age_at_art_start BETWEEN 70 AND 74 THEN '70-74 years'
            WHEN age_at_art_start BETWEEN 75 AND 79 THEN '75-79 years'
            WHEN age_at_art_start BETWEEN 80 AND 84 THEN '80-84 years'
            WHEN age_at_art_start BETWEEN 85 AND 89 THEN '85-89 years'
            WHEN age_at_art_start >= 90 THEN '90 plus years'
            ELSE 'Age Unknown'
        END AS age_group
    FROM patient_summary
)
-- ============================================================
-- FINAL OUTPUT — 7 sections UNIONed
-- Sections 1–2 : age-band rows by sex
-- Sections 3–4 : all-ages totals by sex
-- Sections 5–7 : female reproductive status totals
-- ============================================================
-- Section 1: Age-band rows — Female
SELECT
    pb.site_id,
    pb.age_group,
    'Female' AS gender,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.patient_type = 'is_transfer_in'  THEN 1 END)   AS transfer_ins,
    COUNT(CASE WHEN pb.patient_type = 'not_specified'   THEN 1 END)   AS not_specified
FROM patient_bands pb
WHERE pb.gender = 'F'
GROUP BY pb.site_id, pb.age_group
UNION ALL
-- Section 2: Age-band rows — Male
SELECT
    pb.site_id,
    pb.age_group,
    'Male' AS gender,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.patient_type = 'is_transfer_in'  THEN 1 END)   AS transfer_ins,
    COUNT(CASE WHEN pb.patient_type = 'not_specified'   THEN 1 END)   AS not_specified
FROM patient_bands pb
WHERE pb.gender = 'M'
GROUP BY pb.site_id, pb.age_group
UNION ALL
-- Section 3: Summary row — All Male
SELECT
    pb.site_id,
    'All' AS age_group,
    'All M' AS gender,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'unknown' THEN 1 END)  AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.patient_type = 'is_transfer_in'  THEN 1 END)   AS transfer_ins,
    COUNT(CASE WHEN pb.patient_type = 'not_specified'   THEN 1 END)   AS not_specified
FROM patient_bands pb
WHERE pb.gender = 'M'
GROUP BY pb.site_id
UNION ALL
-- Section 4: Summary row — All Female
SELECT
    pb.site_id,
    'All' AS age_group,
    'All F'  AS gender,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.patient_type = 'is_transfer_in'  THEN 1 END)   AS transfer_ins,
    COUNT(CASE WHEN pb.patient_type = 'not_specified'   THEN 1 END)   AS not_specified
FROM patient_bands pb
WHERE pb.gender = 'F'
GROUP BY pb.site_id
UNION ALL
-- ============================================================
-- Section 5: Summary row — All FP (Female Pregnant)
-- Pregnant = 1, breastfeeding = 0 (mutually exclusive).
-- CD4 < 200 column omitted — not disaggregated for repro rows.
-- ============================================================
SELECT
    pb.site_id,
    'All' AS age_group,
    'All FP' AS gender,
    NULL  AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.patient_type = 'is_transfer_in'  THEN 1 END)   AS transfer_ins,
    COUNT(CASE WHEN pb.patient_type = 'not_specified'   THEN 1 END)   AS not_specified
FROM patient_bands pb
WHERE pb.gender = 'F'
  AND pb.is_pregnant = 1
  AND pb.is_breastfeeding = 0
GROUP BY pb.site_id
UNION ALL
-- ============================================================
-- Section 6: Summary row — All FNP (Female Not Pregnant)
-- Requires explicit documented NOT pregnant obs.
-- Conflict guard in patient_summary ensures is_not_pregnant
-- is never 1 when is_pregnant is also 1.
-- ============================================================
SELECT
    pb.site_id,
    'All' AS age_group,
    'All FNP'AS gender,
    NULL  AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.patient_type = 'is_transfer_in' THEN 1 END)   AS transfer_ins,
    COUNT(CASE WHEN pb.patient_type = 'not_specified' THEN 1 END) AS not_specified
FROM patient_bands pb
WHERE pb.gender = 'F'
  AND pb.is_not_pregnant  = 1
  AND pb.is_breastfeeding = 0
GROUP BY pb.site_id
UNION ALL
-- ============================================================
-- Section 7: Summary row — All FBF (Female Breastfeeding)
-- ============================================================
SELECT
    pb.site_id,
    'All' AS age_group,
    'All FBF' AS gender,
    NULL AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.patient_type = 'newly_enrolled'
               AND  pb.cd4_band    = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.patient_type = 'is_transfer_in'  THEN 1 END)   AS transfer_ins,
    COUNT(CASE WHEN pb.patient_type = 'not_specified'   THEN 1 END)   AS not_specified
FROM patient_bands pb
WHERE pb.gender = 'F'
  AND pb.is_breastfeeding = 1
GROUP BY pb.site_id
ORDER BY
    site_id,
    -- Female rows first, then Male, then repro summaries
    CASE gender
        WHEN 'Female'  THEN 1
        WHEN 'All F'   THEN 2
        WHEN 'All FP'  THEN 3
        WHEN 'All FNP' THEN 4
        WHEN 'All FBF' THEN 5
        WHEN 'Male'    THEN 6
        WHEN 'All M'   THEN 7
        ELSE 8
    END,
    -- Within age-band sections, sort bands chronologically
    CASE gender
        WHEN 'Female' THEN
            FIELD(age_group,
                '<1 year','1-4 years','5-9 years','10-14 years','15-19 years',
                '20-24 years','25-29 years','30-34 years','35-39 years','40-44 years',
                '45-49 years','50-54 years','55-59 years','60-64 years','65-69 years',
                '70-74 years','75-79 years','80-84 years','85-89 years','90 plus years',
                'Age Unknown')
        WHEN 'Male' THEN
            FIELD(age_group,
                '<1 year','1-4 years','5-9 years','10-14 years','15-19 years',
                '20-24 years','25-29 years','30-34 years','35-39 years','40-44 years',
                '45-49 years','50-54 years','55-59 years','60-64 years','65-69 years',
                '70-74 years','75-79 years','80-84 years','85-89 years','90 plus years',
                'Age Unknown')
        ELSE 0
    END;