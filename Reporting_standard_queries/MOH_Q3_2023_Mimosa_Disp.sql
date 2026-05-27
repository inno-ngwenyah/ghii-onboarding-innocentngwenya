# =====================================================================================================================
-- MOH Q3 for Mimosa dispensary: 2023-07-01 to 2023-09-30
# =====================================================================================================================
-- MOH Q2 (25 - 28) & (33 - 38) for Mimosa dispensary: 2023-07-01 to 2023-09-30
-- (25 - 28) Total Registered, Patients initiated on ART for the first time (FT)
-- FT (Males, Females Pregnant, Females Non-pregnant
-- (33 - 38) M Males (all ages) ,FNP Non-pregnant Females (all ages) , FP Pregnant Females (all ages) 
-- A Children below 24 m at ART initiation, B Children 24 m - 14 yrs at ART initiation, C Adults 15 years+ at ART initiation

-- MOH_2023_Q3_v1_Mimosa_Disp.
WITH transfer_ins AS (
    -- TI: must answer YES to all three questions (obs can be any time up to period end)
    SELECT DISTINCT o1.person_id AS patient_id, o1.site_id
    FROM obs PARTITION (p413) o1
    JOIN obs PARTITION (p413) o2
        ON  o2.person_id  = o1.person_id
        AND o2.site_id    = o1.site_id
        AND o2.concept_id = 7937   -- Ever registered at an ART clinic before?
        AND o2.value_coded = 1065  -- Yes
        AND o2.voided = 0
    JOIN obs PARTITION (p413) o3
        ON  o3.person_id  = o1.person_id
        AND o3.site_id = o1.site_id
        AND o3.concept_id = 6394   -- Has the patient taken ART in the last two weeks?
        AND o3.value_coded = 1065  -- Yes
        AND o3.voided = 0
    WHERE o1.voided = 0
      AND o1.concept_id = 7754   -- Ever received ARVs before?
      AND o1.value_coded = 1065   -- Yes
      AND DATE(o1.obs_datetime) <= '2023-09-30'
),
re_initiated AS (
    -- Re-initiated: YES to "ever on ARVs" + YES to "ever registered at ART clinic"
    -- but NOT YES to "taken ART in last 2 weeks" (distinguishes from TI)
    SELECT DISTINCT o1.person_id AS patient_id, o1.site_id
    FROM obs PARTITION (p413) o1
    JOIN obs PARTITION (p413) o2
        ON  o2.person_id  = o1.person_id
        AND o2.site_id = o1.site_id
        AND o2.concept_id = 7937   -- Ever registered at an ART clinic before?
        AND o2.value_coded = 1065  -- Yes
        AND o2.voided = 0
-- Exclude anyone who said Yes to "taken ART in last 2 weeks" (those are TIs)
    JOIN obs PARTITION (p413) o3
		ON  o3.person_id  = o1.person_id
		AND o3.site_id = o1.site_id
		AND o3.concept_id = 6394   -- Has the patient taken ART in the last two weeks?
		AND o3.value_coded = 1066  -- No
		AND o3.voided = 0
    WHERE o1.voided = 0
	  AND o1.concept_id = 7754   -- Ever received ARVs before?
	  AND o1.value_coded = 1065   -- Yes
	  AND DATE(o1.obs_datetime) <= '2023-09-30'
),
all_enrolled AS (
    -- Everyone ever enrolled at this facility up to 2023-09-30
    -- (no date filter on start_date — cumulative baseline)
    SELECT
        p.patient_id,
        p.site_id,
        p2.birthdate  AS date_of_birth,
        p2.gender,
        ps.start_date AS art_start_date,
        pp.date_enrolled,
        CASE WHEN ti.patient_id  IS NOT NULL THEN 1 ELSE 0 END  AS is_transfer_in,
        CASE WHEN ri.patient_id  IS NOT NULL THEN 1 ELSE 0 END AS is_re_initiated
    FROM patient PARTITION (p413) p
    JOIN person   PARTITION (p413) p2
        ON  p2.person_id = p.patient_id
        AND p2.site_id   = p.site_id
    JOIN patient_program PARTITION (p413) pp
        ON  pp.patient_id  = p.patient_id
        AND pp.site_id = p.site_id
        AND pp.program_id  = 1
        AND pp.voided = 0
    JOIN patient_state PARTITION (p413) ps
        ON  ps.patient_program_id = pp.patient_program_id
        AND ps.site_id  = pp.site_id
        AND ps.state = 7           -- On ART
        AND ps.end_date IS NULL
        AND ps.voided  = 0
        AND DATE(ps.start_date)   <= '2023-09-30'   -- Cumulative: all time up to period end
    LEFT JOIN transfer_ins ti
        ON  ti.patient_id = p.patient_id
        AND ti.site_id = p.site_id
    LEFT JOIN re_initiated ri
        ON  ri.patient_id = p.patient_id
        AND ri.site_id    = p.site_id
    WHERE p.voided = 0
      AND p2.voided = 0
    GROUP BY
        p.patient_id, p.site_id, p2.birthdate, p2.gender,
        ps.start_date, pp.date_enrolled, ti.patient_id, ri.patient_id
),
pregnant_obs AS (
    -- Pregnancy flag = Yes, any time up to period end (for cumulative)
    SELECT DISTINCT o.person_id, o.site_id
    FROM obs PARTITION (p413) o
    WHERE o.voided = 0
      AND o.concept_id IN (1434, 6131, 1755)
      AND o.value_coded = 1065                  -- Yes
      AND DATE(o.obs_datetime) <= '2023-09-30'
),
non_pregnant_obs AS (
    -- Pregnancy flag = No
    SELECT DISTINCT o.person_id, o.site_id
    FROM obs PARTITION (p413) o
    WHERE o.voided = 0
      AND o.concept_id  IN (1434, 6131, 1755)
      AND o.value_coded = 1066                  -- No
      AND DATE(o.obs_datetime) <= '2023-09-30'
),
patient_summary AS (
    -- Attach pregnancy status and compute age bands for every enrolled patient
    SELECT
        ae.patient_id,
        ae.site_id,
        ae.is_transfer_in,
        ae.is_re_initiated,
        ae.gender,
        ae.art_start_date,
        -- FT = not a TI and not a re-initiate
        CASE WHEN ae.is_transfer_in = 0  OR ae.is_re_initiated = 0 THEN 1 ELSE 0 END AS is_first_time,
        TIMESTAMPDIFF(MONTH, ae.date_of_birth, ae.art_start_date) AS age_months_at_art,
        TIMESTAMPDIFF(YEAR,  ae.date_of_birth, ae.art_start_date)  AS age_years_at_art,
        CASE WHEN po.person_id  IS NOT NULL THEN 1 ELSE 0 END AS is_pregnant
    FROM all_enrolled ae
    LEFT JOIN pregnant_obs po  
    	ON po.person_id  = ae.patient_id 
    	AND po.site_id  = ae.site_id
    LEFT JOIN non_pregnant_obs npo 
    	ON npo.person_id = ae.patient_id 
    	AND npo.site_id = ae.site_id
),
-- Quarter slice: FT patients initiated in Q3 2023 only (rows 25–28)
ft_quarter AS (
    SELECT *
    FROM patient_summary
    WHERE is_first_time = 1
      AND DATE(art_start_date) BETWEEN '2023-07-01' AND '2023-09-30'
),
-- Cumulative slice: all client types, all time up to 2023-09-30 (rows 33–38)
cumulative AS (
    SELECT *
    FROM patient_summary
)
-- ============================================================
-- Row 25: Total registered in quarter (FT only, Q3 2023)
-- ============================================================
SELECT
    25 AS row_num,
    'Total registered (First Time, Q3 2023)' AS Item,
    COUNT(*) AS Newly_enrolled_in_quarter,
    (SELECT COUNT(*) FROM cumulative) AS  Cumulative          
FROM ft_quarter
-- UNION ALL
UNION ALL
-- ============================================================
-- Row 26: FT Males initiated on ART first time (quarter)
-- ============================================================
SELECT
    26,
    'FT Patients – Male',
    COUNT(CASE WHEN gender = 'M' THEN 1 END),
    (SELECT COUNT(CASE WHEN gender = 'M' THEN 1 END) FROM cumulative )
FROM ft_quarter
-- UNION all
UNION ALL
-- ============================================================
-- Row 27: FT Female Non-pregnant (quarter)
-- ============================================================
SELECT
    27,
    'FT Patients – Female Non-pregnant',
    COUNT(CASE WHEN gender = 'F' AND is_pregnant = 0 THEN 1 END),
    (SELECT COUNT(CASE WHEN gender = 'F' AND is_pregnant = 0 THEN 1 END) FROM cumulative)
FROM ft_quarter
-- UNION all
UNION ALL
-- ============================================================
-- Row 28: FT Female Pregnant (quarter)
-- ============================================================
SELECT
    28,
    'FT Patients – Female Pregnant',
    COUNT(CASE WHEN gender = 'F' AND is_pregnant = 1 THEN 1 END),
    (SELECT COUNT(CASE WHEN gender = 'F' AND is_pregnant = 1 THEN 1 END) FROM cumulative)
FROM ft_quarter
-- UNION all
UNION ALL
-- ============================================================
-- Row 33: M Males all ages — cumulative (FT + TI + Re-initiated)
-- ============================================================
SELECT
    33,
    'M Males (all ages)',
    (SELECT COUNT(CASE WHEN gender = 'M' THEN 1 END)
     FROM patient_summary
     WHERE DATE(art_start_date) BETWEEN '2023-07-01' AND '2023-09-30'),
    COUNT(CASE WHEN gender = 'M' THEN 1 END)
FROM cumulative
-- UNION all
UNION ALL
-- ============================================================
-- Row 34: FNP Non-pregnant Females all ages — cumulative
-- ============================================================
SELECT
    34,
    'FNP Non-pregnant Females (all ages)',
    (SELECT COUNT(CASE WHEN gender = 'F' AND is_pregnant = 0 THEN 1 END)
     FROM patient_summary
     WHERE DATE(art_start_date) BETWEEN '2023-07-01' AND '2023-09-30'),
    COUNT(CASE WHEN gender = 'F' AND is_pregnant = 0 THEN 1 END)
FROM cumulative
-- UNION all
UNION ALL
-- ============================================================
-- Row 35: FP Pregnant Females all ages — cumulative
-- ============================================================
SELECT
    35,
    'FP Pregnant Females (all ages)',
    (SELECT COUNT(CASE WHEN gender = 'F' AND is_pregnant = 1 THEN 1 END)
     FROM patient_summary
     WHERE DATE(art_start_date) BETWEEN '2023-07-01' AND '2023-09-30'),
    COUNT(CASE WHEN gender = 'F' AND is_pregnant = 1 THEN 1 END)
FROM cumulative
-- UNION all
UNION ALL
-- ============================================================
-- Row 36: A Children below 24 months — cumulative
-- ============================================================
SELECT
    36,
    'A Children below 24 m at ART initiation',
    (SELECT COUNT(CASE WHEN age_months_at_art < 24 THEN 1 END)
     FROM patient_summary
     WHERE DATE(art_start_date) BETWEEN '2023-07-01' AND '2023-09-30'),
    COUNT(CASE WHEN age_months_at_art < 24 THEN 1 END)
FROM cumulative
-- UNION all
UNION ALL
-- ============================================================
-- Row 37: B Children 24m–14yrs — cumulative
-- ============================================================
SELECT
    37,
    'B Children 24 m – 14 yrs at ART initiation',
    (SELECT COUNT(CASE WHEN age_months_at_art >= 24 AND age_years_at_art <= 14 THEN 1 END)
     FROM patient_summary
     WHERE DATE(art_start_date) BETWEEN '2023-07-01' AND '2023-09-30'),
    COUNT(CASE WHEN age_months_at_art >= 24 AND age_years_at_art <= 14 THEN 1 END)
FROM cumulative
-- UNION all
UNION ALL
-- ============================================================
-- Row 38: C Adults 15 years+ — cumulative
-- ============================================================
SELECT
    38,
    'C Adults 15 years+ at ART initiation',
    (SELECT COUNT(CASE WHEN age_years_at_art >= 15 THEN 1 END)
     FROM patient_summary
     WHERE DATE(art_start_date) BETWEEN '2023-07-01' AND '2023-09-30'),
    COUNT(CASE WHEN age_years_at_art >= 15 THEN 1 END)
FROM cumulative
ORDER BY row_num;