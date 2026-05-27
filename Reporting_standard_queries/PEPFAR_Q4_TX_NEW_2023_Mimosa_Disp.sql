===========================================================================================================
-- PEPFAR Q4 for Mimosa dispensary: 2023-07-01 to 2023-09-30 
===========================================================================================================

-- Q4_2023_TX_NEW_v1_Mimosa_Disp.
WITH transfer_ins AS (
    -- A patient is a transfer-in only if ALL THREE questions are answered Yes
    -- within the reporting period
    SELECT DISTINCT
        o1.person_id AS patient_id,
        o1.site_id
    FROM obs PARTITION (p413) o1
    JOIN obs PARTITION (p413) o2
        ON  o2.person_id = o1.person_id
        AND o2.site_id = o1.site_id
        AND o2.concept_id = 7937  -- Ever registered on ART clinic before?
        AND o2.value_coded = 1065  -- Yes
        AND o2.voided = 0
    JOIN obs PARTITION (p413) o3
        ON  o3.person_id = o1.person_id
        AND o3.site_id  = o1.site_id
        AND o3.concept_id  = 6394 -- Has the patient taken ART in the last two weeks?
        AND o3.value_coded = 1065 -- Yes
        AND o3.voided = 0
    WHERE o1.voided  = 0
      AND o1.concept_id  = 7754 -- Ever received ARVs before?
      AND o1.value_coded = 1065  -- Yes
      AND DATE(o1.obs_datetime) BETWEEN '2023-07-01' AND '2023-09-30'
),
active_clients AS (
-- TX_NEW definition: patients newly initiated on ART within the reporting period
    SELECT
        p.patient_id AS patient_id,
        p.site_id,
        p2.birthdate AS date_of_birth,
        p2.gender,
        ps.start_date AS art_start_date,
        pp.date_enrolled,
        CASE WHEN ti.patient_id IS NOT NULL THEN 1 ELSE 0 END AS is_transfer_in
    FROM patient PARTITION (p413) p
    JOIN person PARTITION (p413) p2
        ON  p2.person_id = p.patient_id
        AND p2.site_id   = p.site_id
    JOIN patient_program PARTITION (p413) pp
        ON  pp.patient_id = p.patient_id
        AND pp.site_id    = p.site_id
        AND pp.program_id = 1
        AND pp.voided = 0
    JOIN patient_state  PARTITION (p413) ps
        ON  ps.patient_program_id = pp.patient_program_id
        AND ps.site_id  = pp.site_id
        AND ps.state = 7
        AND ps.end_date IS NULL
        AND ps.voided = 0
        AND DATE(ps.start_date) BETWEEN '2023-07-01' AND  '2023-09-30'
    LEFT JOIN transfer_ins ti
        ON  ti.patient_id = p.patient_id
        AND ti.site_id = p.site_id
    WHERE p.voided  = 0
      AND p2.voided = 0
),
cd4_obs AS (
-- Most recent CD4 (concept 5497) taken at or within 30 days BEFORE ART start.
    SELECT
        o.person_id,
        o.site_id,
        o.value_numeric,
        o.value_modifier,
        ROW_NUMBER() OVER (PARTITION BY o.person_id, o.site_id ORDER BY o.obs_datetime DESC) AS row_num
    FROM obs PARTITION (p413) o
    JOIN active_clients ac
        ON  ac.patient_id = o.person_id
        AND ac.site_id = o.site_id
        AND o.obs_datetime BETWEEN DATE_SUB(ac.art_start_date, INTERVAL 90 DAY) AND ac.art_start_date
    WHERE o.voided = 0
      AND o.concept_id = 5497
),
pregnant_obs AS (
-- Female patients with a pregnancy flag during the reporting period
    SELECT DISTINCT o.person_id, o.site_id
    FROM obs PARTITION (p413) o
    WHERE o.voided = 0
      AND o.concept_id  IN (1434, 6131, 1755)  -- Is patient pregnant?
      AND o.value_coded = 1065  -- Yes 
      AND DATE(o.obs_datetime) BETWEEN '2023-07-01' AND '2023-09-30'
),
non_pregnant_obs AS (
-- Female patients with a Not pregnant during the reporting period
    SELECT DISTINCT o.person_id, o.site_id
    FROM obs PARTITION (p413) o
    WHERE o.voided = 0
      AND o.concept_id  IN (1434, 6131, 1755) -- Is patient pregnant?
      AND o.value_coded = 1066 -- No
      AND DATE(o.obs_datetime) BETWEEN '2023-07-01' AND '2023-09-30'
),
breastfeeding_obs AS (
-- Female patients with a breastfeeding flag during the reporting period
    SELECT DISTINCT o.person_id, o.site_id
    FROM obs PARTITION (p413) o
    WHERE o.voided = 0
      AND o.concept_id  IN (5632, 7965) -- Is Patient Breastfeeding?
      AND o.value_coded = 1065
      AND DATE(o.obs_datetime) BETWEEN '2023-07-01' AND '2023-09-30'
),
patient_summary AS (
    SELECT
        ac.patient_id,
        ac.site_id,
        ac.is_transfer_in,
        CASE WHEN ac.gender = 'M' THEN 'Male'
             WHEN ac.gender = 'F' THEN 'Female'
             ELSE 'Unknown gender'
        END AS gender,
        TIMESTAMPDIFF(YEAR, DATE(ac.date_of_birth), DATE(ac.art_start_date)) AS age_at_art_start,
        CASE WHEN po.person_id  IS NOT NULL THEN 1 ELSE 0 END AS is_pregnant,
        CASE WHEN npo.person_id  IS NOT NULL THEN 1 ELSE 0 END AS is_not_pregnant,
        CASE WHEN bfo.person_id IS NOT NULL THEN 1 ELSE 0 END AS is_breastfeeding,
        CASE
            WHEN cd4.value_numeric IS NULL THEN 'unknown'
            WHEN cd4.value_numeric < 200 OR (cd4.value_modifier = '<' AND cd4.value_numeric <= 200) THEN 'lt200'
            ELSE 'gtoe200'
        END AS cd4_band
    FROM active_clients ac
    LEFT JOIN cd4_obs cd4
        ON  cd4.person_id = ac.patient_id
        AND cd4.site_id   = ac.site_id
        AND cd4.row_num   = 1
    LEFT JOIN pregnant_obs po
        ON  po.person_id = ac.patient_id
        AND po.site_id   = ac.site_id
    LEFT JOIN non_pregnant_obs npo
    	ON npo.person_id = ac.patient_id 
    	AND npo.site_id = ac.site_id 
    LEFT JOIN breastfeeding_obs bfo
        ON  bfo.person_id = ac.patient_id
        AND bfo.site_id   = ac.site_id
),
patient_bands AS (
    SELECT *,
        CASE
            WHEN age_at_art_start < 1 THEN '<1 year'
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
-- Section 1: Age-band rows — Female
-- ============================================================
SELECT
    pb.site_id,
    pb.age_group,
    'Female' AS gender,
    COUNT(CASE WHEN pb.cd4_band = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.cd4_band = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.cd4_band = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.is_transfer_in = 1   THEN 1 END) AS transfer_ins
FROM patient_bands pb
WHERE pb.gender = 'Female'
GROUP BY pb.site_id, pb.age_group
-- UNION all
UNION ALL
-- ============================================================
-- Section 2: Age-band rows — Male
-- ============================================================
SELECT
    pb.site_id,
    pb.age_group,
    'Male' AS gender,
    COUNT(CASE WHEN pb.cd4_band = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.cd4_band = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.cd4_band = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.is_transfer_in = 1   THEN 1 END) AS transfer_ins
FROM patient_bands pb
WHERE pb.gender = 'Male'
GROUP BY pb.site_id, pb.age_group
-- UNION all
UNION ALL
-- ============================================================
-- Section 3: Summary row — All Male
-- ============================================================
SELECT
    pb.site_id,
    'All' AS age_group,
    'All M' AS gender,
    COUNT(CASE WHEN pb.cd4_band = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.cd4_band = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.cd4_band = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.is_transfer_in = 1   THEN 1 END) AS transfer_ins
FROM patient_bands pb
WHERE pb.gender = 'Male'
GROUP BY pb.site_id
-- UNION all
UNION ALL
-- ============================================================
-- Section 4: Summary row — All Female
-- ============================================================
SELECT
    pb.site_id,
    'All' AS age_group,
    'All F' AS gender,
    COUNT(CASE WHEN pb.cd4_band = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.cd4_band = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.cd4_band = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.is_transfer_in = 1   THEN 1 END) AS transfer_ins
FROM patient_bands pb
WHERE pb.gender = 'Female'
GROUP BY pb.site_id
-- UNION all
UNION ALL
-- ============================================================
-- Section 5: Summary row — All FP (All Female Pregnant)
-- ============================================================
SELECT
    pb.site_id,
    'All' AS age_group,
    'All FP' AS gender,
    COUNT(CASE WHEN pb.cd4_band = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.cd4_band = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.cd4_band = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.is_transfer_in = 1   THEN 1 END) AS transfer_ins
FROM patient_bands pb
WHERE pb.gender  = 'Female'
  AND pb.is_pregnant = 1
  AND pb.is_breastfeeding = 0
GROUP BY pb.site_id
-- UNION all
UNION ALL
-- ============================================================
-- Section 6: Summary row — All FNP (All Female Not Pregnant)
-- ============================================================
SELECT
    pb.site_id,
    'All' AS age_group,
    'All FNP' AS gender,
    COUNT(CASE WHEN pb.cd4_band = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.cd4_band = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.cd4_band = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.is_transfer_in = 1   THEN 1 END) AS transfer_ins
FROM patient_bands pb
WHERE pb.gender  = 'Female'
  AND ((pb.is_not_pregnant = 1  AND pb.is_breastfeeding = 0 )
  OR (pb.is_not_pregnant = 0 AND pb.is_breastfeeding = 0 AND pb.is_pregnant = 0))
GROUP BY pb.site_id
-- UNION all
UNION ALL
-- ============================================================
-- Section 7: Summary row — All FBF (All Female Breastfeeding)
-- ============================================================
SELECT
    pb.site_id,
    'All' AS age_group,
    'All FBF' AS gender,
    COUNT(CASE WHEN pb.cd4_band = 'lt200'   THEN 1 END) AS tx_new_cd4_less_than_200,
    COUNT(CASE WHEN pb.cd4_band = 'gtoe200' THEN 1 END) AS tx_new_cd4_200_or_greater,
    COUNT(CASE WHEN pb.cd4_band = 'unknown' THEN 1 END) AS tx_new_cd4_unknown_or_not_done,
    COUNT(CASE WHEN pb.is_transfer_in = 1   THEN 1 END) AS transfer_ins
FROM patient_bands pb
WHERE pb.gender = 'Female'
  AND pb.is_breastfeeding = 1
GROUP BY pb.site_id
ORDER BY site_id,
    CASE gender WHEN 'Female' THEN 1 WHEN 'Male' THEN 2 ELSE 3 END,
    CASE gender
        WHEN 'All M' THEN 99
        WHEN 'All F' THEN 99
        WHEN 'All FP' THEN 100
        WHEN 'All FBF' THEN 101
        ELSE FIELD(age_group,
            '<1 year','1-4 years','5-9 years','10-14 years','15-19 years',
            '20-24 years','25-29 years','30-34 years','35-39 years','40-44 years',
            '45-49 years','50-54 years','55-59 years','60-64 years','65-69 years',
            '70-74 years','75-79 years','80-84 years','85-89 years','90 plus years')
    END;