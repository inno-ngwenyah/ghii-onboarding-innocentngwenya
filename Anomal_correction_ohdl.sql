================================================================
#DQA Report Assignment - Anomaly Correction Queries for CENTRAL DATA 
================================================================
-----------------------------------------------------------------------
#1.Clients missing gender or gender recorded in an inconsistent format
-----------------------------------------------------------------------
SELECT DISTINCT
    p.patient_id,
    p.site_id,
    p2.gender,
    CASE
        WHEN p2.gender IS NULL THEN 'Gender is NULL'
        WHEN p2.gender NOT IN ('M', 'F') THEN CONCAT('Non-standard gender value: ', p2.gender)
    END AS DQ_flag,
    'Conformance - Value Conformance' AS kahn_category,
    'High' AS severity
FROM patient p
JOIN person p2
    ON p.patient_id = p2.person_id
    AND p.site_id = p2.site_id
JOIN patient_program pp
    ON pp.patient_id = p.patient_id
    AND pp.site_id = p.site_id
JOIN patient_state ps
    ON pp.patient_program_id = ps.patient_program_id
    AND pp.site_id = ps.site_id
WHERE pp.program_id = 1
    AND p.voided = 0
    AND pp.voided = 0
    AND ps.voided = 0
    AND ps.state = 7
    AND ps.end_date IS NULL
    AND (p2.gender IS NULL
        OR p2.gender NOT IN ('M', 'F')
    )
ORDER BY p.site_id, p.patient_id;

-------------------------------------------------------------------------
#2. Clients with a death date who have subsequent visit records
-------------------------------------------------------------------------

WITH dead_clients AS (
    SELECT DISTINCT 
        p.patient_id AS patient_id, 
        ps.state AS state, 
        ps.start_date AS start_date, 
        ps.end_date AS end_date , 
        p.site_id AS site_id
	FROM patient p 
	JOIN person p2 
		ON p.patient_id = p2.person_id 
		AND p.site_id = p2.site_id 
	JOIN patient_program pp 
		ON pp.patient_id = p.patient_id 
		AND pp.site_id = p.site_id 
	JOIN patient_state ps 
		ON pp.patient_program_id = ps.patient_program_id 
		AND pp.site_id = ps.site_id 
	WHERE pp.program_id = 1 
		AND p.voided = 0 
		AND pp.voided = 0 
		AND ps.voided = 0
		AND ps.state = 3
		AND ps.end_date IS NULL
)
SELECT DISTINCT
    dc.patient_id,
    dc.site_id,
    dc.start_date AS death_start_date,
    e.encounter_id,
    DATE(e.encounter_datetime) AS encounter_date,
    et.name AS encounter_type,
    DATEDIFF(DATE(e.encounter_datetime), dc.start_date ) AS days_after_death,
    CONCAT('Encounter recorded ', DATEDIFF(DATE(e.encounter_datetime), dc.start_date ),
        ' day(s) after recorded death date of ',
        dc.start_date) AS  DQ_flag,
    'Plausibility - Temporal Plausibility' AS kahn_category,
    'High' AS severity
FROM encounter e 
JOIN encounter_type et 
	ON e.encounter_type = et.encounter_type_id
JOIN dead_clients dc 
	ON dc.patient_id = e.patient_id 
	AND dc.site_id = e.site_id 
WHERE e.voided = 0
    AND e.encounter_datetime > dc.start_date 
ORDER BY dc.site_id , dc.patient_id, DATE(e.encounter_datetime) ;
------------------------------------------------------------------------------
#3. Clients initiated on ART before their recorded date of birth
------------------------------------------------------------------------------
SELECT DISTINCT
    p.patient_id,
    p.site_id,
    p2.birthdate AS date_of_birth,
    p2.birthdate_estimated,
    DATE(ps.start_date) AS art_start_date,
    DATEDIFF(p2.birthdate, DATE(ps.start_date)) AS days_before_birth,
    CASE
        WHEN p2.birthdate IS NULL THEN 'Birthdate is NULL - cannot verify'
        WHEN ps.start_date IS NULL THEN 'ART start date is NULL - cannot verify'
        WHEN p2.birthdate > DATE(ps.start_date)
            THEN CONCAT('ART initiated ',
                DATEDIFF(p2.birthdate, DATE(ps.start_date)),
                ' day(s) before recorded birthdate'
            ) END AS DQ_flag,
    'Plausibility - Temporal Plausibility' AS kahn_category,
    CASE
        WHEN p2.birthdate IS NULL OR ps.start_date IS NULL THEN 'Medium'
        ELSE 'High'
    END AS severity
FROM patient p
JOIN person p2
    ON p.patient_id = p2.person_id
    AND p.site_id = p2.site_id
JOIN patient_program pp
    ON pp.patient_id = p.patient_id
    AND pp.site_id = p.site_id
JOIN patient_state ps
    ON pp.patient_program_id = ps.patient_program_id
    AND pp.site_id = ps.site_id
WHERE pp.program_id = 1
    AND p.voided = 0
    AND pp.voided = 0
    AND ps.voided = 0
    AND ps.state = 7
    AND ps.end_date IS NULL
    AND (
        p2.birthdate IS NULL
        OR ps.start_date IS NULL
        OR p2.birthdate > DATE(ps.start_date)
    )
ORDER BY p.site_id, p.patient_id;
-------------------------------------------------------------------------------------
#4. Male clients with pregnant or breastfeeding observations
-------------------------------------------------------------------------------------

WITH male_HIV_clients AS (
    SELECT DISTINCT
        p.patient_id,
        p.site_id
    FROM patient p
    JOIN person p2
        ON p.patient_id = p2.person_id
        AND p.site_id = p2.site_id
    JOIN patient_program pp
        ON pp.patient_id = p.patient_id
        AND pp.site_id = p.site_id
    JOIN patient_state ps
        ON pp.patient_program_id = ps.patient_program_id
        AND pp.site_id = ps.site_id
    WHERE pp.program_id = 1
        AND p.voided = 0
        AND pp.voided = 0
        AND ps.voided = 0
        AND ps.state = 7
        AND ps.end_date IS NULL
        AND p2.gender = 'M'
)
SELECT DISTINCT
    mhc.patient_id,
    mhc.site_id,
    o.concept_id,
    cn_q.name AS observation_question,
    DATE(o.obs_datetime) AS obs_date,
    o.value_coded,
    cn_a.name AS observation_answer,
    o.value_text AS obs_answer_text,
    CASE
        WHEN o.value_coded = 1065 THEN 'Coded Yes'
        WHEN LOWER(TRIM(o.value_text)) = 'yes' THEN 'Text Yes'
    END AS answer_source,
    CONCAT('Male patient has: ',
        cn_q.name,
        ' - observation recorded as Yes on ',
        DATE(o.obs_datetime)
    ) AS DQ_flag,
    'Plausibility - Atemporal Plausibility' AS kahn_category,
    'High' AS severity
FROM obs o
JOIN male_HIV_clients mhc
    ON o.person_id = mhc.patient_id
    AND o.site_id = mhc.site_id
JOIN concept_name cn_q
    ON o.concept_id = cn_q.concept_id
    AND cn_q.locale = 'en'
    AND cn_q.concept_name_type = 'FULLY_SPECIFIED'
LEFT JOIN concept_name cn_a
    ON o.value_coded = cn_a.concept_id
    AND cn_a.locale = 'en'
    AND cn_a.concept_name_type = 'FULLY_SPECIFIED'
WHERE o.voided = 0
    AND o.concept_id IN (6131, 7965, 1755, 5632, 5630, 490, 1053)
    AND (
        o.value_coded = 1065
        OR LOWER(TRIM(o.value_text)) = 'yes'
    )
ORDER BY mhc.site_id, mhc.patient_id;
------------------------------------------------------------------------------------
#5. Female clients with pregnant/breastfeeding observations outside age range BETWEEN 8 & 55 years
-------------------------------------------------------------------------------------
WITH female_HIV_clients AS (
    SELECT DISTINCT
        p.patient_id,
        p2.birthdate,
        p.site_id
    FROM patient p
    JOIN person p2
        ON p.patient_id = p2.person_id
        AND p.site_id = p2.site_id
    JOIN patient_program pp
        ON pp.patient_id = p.patient_id
        AND pp.site_id = p.site_id
    JOIN patient_state ps
        ON pp.patient_program_id = ps.patient_program_id
        AND pp.site_id = ps.site_id
    WHERE pp.program_id = 1
        AND p.voided = 0
        AND pp.voided = 0
        AND ps.voided = 0
        AND ps.state = 7
        AND ps.end_date IS NULL
        AND p2.gender = 'F'
)
SELECT DISTINCT
    fhc.patient_id,
    fhc.site_id,
    fhc.birthdate,
    TIMESTAMPDIFF(YEAR, fhc.birthdate, o.obs_datetime) AS age_at_observation,
    o.concept_id,
    cn_q.name AS observation_question,
    DATE(o.obs_datetime) AS obs_date,
    o.value_coded,
    cn_a.name AS observation_answer,
    o.value_text AS obs_answer_text,
    CASE
        WHEN fhc.birthdate IS NULL
            THEN 'Birthdate missing - age at observation unverifiable'
        WHEN TIMESTAMPDIFF(YEAR, fhc.birthdate, o.obs_datetime) < 8
            THEN CONCAT('Patient was ',
                TIMESTAMPDIFF(YEAR, fhc.birthdate, o.obs_datetime),
                ' years old at obs - below minimum reproductive age of 8'
            )
        WHEN TIMESTAMPDIFF(YEAR, fhc.birthdate, o.obs_datetime) > 55
            THEN CONCAT('Patient was ',
                TIMESTAMPDIFF(YEAR, fhc.birthdate, o.obs_datetime),
                ' years old at obs - above maximum reproductive age of 55'
            )  END AS DQ_flag,
    'Plausibility - Atemporal Plausibility' AS kahn_category,
    CASE
        WHEN fhc.birthdate IS NULL THEN 'Medium'
        ELSE 'High'
    END AS severity
FROM obs o
JOIN female_HIV_clients fhc
    ON o.person_id = fhc.patient_id
    AND o.site_id = fhc.site_id
JOIN concept_name cn_q
    ON o.concept_id = cn_q.concept_id
    AND cn_q.locale = 'en'
    AND cn_q.concept_name_type = 'FULLY_SPECIFIED'
LEFT JOIN concept_name cn_a
    ON o.value_coded = cn_a.concept_id
    AND cn_a.locale = 'en'
    AND cn_a.concept_name_type = 'FULLY_SPECIFIED'
WHERE o.voided = 0
    AND o.concept_id IN (6131, 7965, 1755, 5632, 5630, 490, 1053)
    AND (
        o.value_coded = 1065
        OR LOWER(TRIM(o.value_text)) = 'yes'
        OR o.value_datetime IS NOT NULL
        OR o.value_numeric IS NOT NULL
    )
    AND (
        fhc.birthdate IS NULL
        OR TIMESTAMPDIFF(YEAR, fhc.birthdate, o.obs_datetime) NOT BETWEEN 8 AND 55
    )
ORDER BY fhc.site_id, fhc.patient_id;
-------------------------------------------------------------------------------------
#6. Clients initiated on ART before 1985 (implausible date)
-------------------------------------------------------------------------------------

SELECT DISTINCT
    p.patient_id,
    p.site_id,
    DATE(ps.start_date) AS art_start_date,
    CASE
        WHEN ps.start_date IS NULL  THEN 'ART start date is NULL'
        WHEN DATE(ps.start_date) < '1985-01-01' THEN CONCAT('ART start date ',
                DATE(ps.start_date),
                ' is before 1985 - predates existence of ART' )
        WHEN DATE(ps.start_date) > CURRENT_DATE()
            THEN CONCAT('ART start date ',
                DATE(ps.start_date),
                ' is in the future' )
    END AS DQ_flag,
    'Plausibility - Temporal Plausibility' AS kahn_category,
    'High' AS severity
FROM patient p
JOIN patient_program pp
    ON pp.patient_id = p.patient_id
    AND pp.site_id = p.site_id
JOIN patient_state ps
    ON pp.patient_program_id = ps.patient_program_id
    AND pp.site_id = ps.site_id
WHERE pp.program_id = 1
    AND p.voided = 0
    AND pp.voided = 0
    AND ps.voided = 0
    AND ps.state = 7
    AND ps.end_date IS NULL
    AND (ps.start_date IS NULL
        OR DATE(ps.start_date) < '1985-01-01'
        OR DATE(ps.start_date) > CURRENT_DATE() )
ORDER BY p.site_id, p.patient_id;
-------------------------------------------------------------------------------------
#7. Paediatric clients (under 15) missing weight, height, or BMI at any visit
-------------------------------------------------------------------------------------
WITH peds_clients AS (
    SELECT DISTINCT
        p.patient_id,
        p2.birthdate,
        p.site_id
    FROM patient p
    JOIN person p2
        ON p.patient_id = p2.person_id
        AND p.site_id = p2.site_id
    JOIN patient_program pp
        ON pp.patient_id = p.patient_id
        AND pp.site_id = p.site_id
    JOIN patient_state ps
        ON pp.patient_program_id = ps.patient_program_id
        AND pp.site_id = ps.site_id
    WHERE pp.program_id = 1
        AND p.voided = 0
        AND pp.voided = 0
        AND ps.voided = 0
        AND ps.state = 7
        AND ps.end_date IS NULL
)
SELECT
    e.patient_id,
    pc.site_id,
    e.encounter_id,
    DATE(e.encounter_datetime) AS visit_date,
    pc.birthdate,
    TIMESTAMPDIFF(YEAR, pc.birthdate, e.encounter_datetime) AS age_at_visit,
    MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) AS weight,
    MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) AS height_cm,
    MAX(CASE WHEN o.concept_id = 2137 THEN o.value_numeric END) AS bmi,
    CASE
        WHEN MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) IS NULL
            AND MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) IS NULL
            AND MAX(CASE WHEN o.concept_id = 2137 THEN o.value_numeric END) IS NULL
            THEN 'Weight, Height and BMI all missing at this visit'
        WHEN MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) IS NULL
            AND MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) IS NULL
            THEN 'Weight and Height missing at this visit'
        WHEN MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) IS NULL
            THEN 'Weight missing at this visit'
        WHEN MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) IS NULL
            THEN 'Height missing at this visit'
        WHEN MAX(CASE WHEN o.concept_id = 2137 THEN o.value_numeric END) IS NULL
            THEN 'BMI missing at this visit'
    END AS DQ_flag,
    'Completeness' AS kahn_category,
    'High' AS severity
FROM encounter e
JOIN peds_clients pc
    ON e.patient_id = pc.patient_id
    AND e.site_id = pc.site_id
LEFT JOIN obs o
    ON e.encounter_id = o.encounter_id
    AND o.concept_id IN (2137, 5089, 5090)
    AND o.voided = 0
WHERE e.voided = 0
    AND (pc.birthdate IS NULL
        OR TIMESTAMPDIFF(YEAR, pc.birthdate, e.encounter_datetime) < 15
    )
GROUP BY
    e.patient_id,
    pc.site_id,
    e.encounter_id,
    e.encounter_datetime,
    pc.birthdate
HAVING
    MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) IS NULL
    OR MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) IS NULL
    OR MAX(CASE WHEN o.concept_id = 2137 THEN o.value_numeric END) IS NULL
ORDER BY pc.site_id, e.patient_id, e.encounter_datetime;
------------------------------------------------------------------------------------
#8 Adult clients with no height recorded across all visits
------------------------------------------------------------------------------------

WITH adult_clients AS (
    SELECT DISTINCT
        p.patient_id,
        p2.birthdate,
        p.site_id,
        pp.date_enrolled AS program_enrolment_date
    FROM patient p
    JOIN person p2
        ON p.patient_id = p2.person_id
        AND p.site_id = p2.site_id
    JOIN patient_program pp
        ON pp.patient_id = p.patient_id
        AND pp.site_id = p.site_id
    JOIN patient_state ps
        ON pp.patient_program_id = ps.patient_program_id
        AND pp.site_id = ps.site_id
    WHERE pp.program_id = 1
        AND p.voided = 0
        AND pp.voided = 0
        AND ps.voided = 0
        AND ps.state = 7
        AND ps.end_date IS NULL
)
SELECT
    adc.patient_id,
    adc.site_id,
    adc.birthdate AS date_of_birth,
    TIMESTAMPDIFF(YEAR, adc.birthdate, CURRENT_DATE()) AS current_age,
    TIMESTAMPDIFF(YEAR, adc.birthdate, adc.program_enrolment_date) AS age_at_enrolment,
    adc.program_enrolment_date,
    CASE
        WHEN adc.birthdate IS NULL THEN 'Height never recorded - birthdate unknown, age unverifiable'
        WHEN TIMESTAMPDIFF(YEAR, adc.birthdate, CURRENT_DATE()) > 120
            THEN CONCAT('Height never recorded - current age of ',
                TIMESTAMPDIFF(YEAR, adc.birthdate, CURRENT_DATE()),
                ' years is implausible' )
        ELSE CONCAT('Height never recorded for adult patient enrolled on ',
            adc.program_enrolment_date ) END AS DQ_flag,
    'Completeness' AS kahn_category,
    'Medium' AS severity
FROM adult_clients adc
WHERE ( adc.birthdate IS NULL
    OR (TIMESTAMPDIFF(YEAR, adc.birthdate, CURRENT_DATE()) >= 15
        AND TIMESTAMPDIFF(YEAR, adc.birthdate, adc.program_enrolment_date) >= 15 ))
AND NOT EXISTS (
		    SELECT 1
		    FROM obs o
		    WHERE o.person_id = adc.patient_id
		        AND o.site_id = adc.site_id
		        AND o.concept_id = 5090
		        AND o.voided = 0
		        AND o.value_numeric IS NOT NULL
)
ORDER BY adc.site_id, adc.patient_id;
--------------------------------------------------------------------------------------
#9. Females who were pregnant at ART initiation
--------------------------------------------------------------------------------------
WITH female_HIV_clients AS (
    SELECT DISTINCT
        p.patient_id,
        ps.start_date AS art_start_date,
        p.site_id
    FROM patient p
    JOIN person p2
        ON p.patient_id = p2.person_id
        AND p.site_id = p2.site_id
    JOIN patient_program pp
        ON pp.patient_id = p.patient_id
        AND pp.site_id = p.site_id
    JOIN patient_state ps
        ON pp.patient_program_id = ps.patient_program_id
        AND pp.site_id = ps.site_id
    WHERE pp.program_id = 1
        AND p.voided = 0
        AND pp.voided = 0
        AND ps.voided = 0
        AND ps.state = 7
        AND ps.end_date IS NULL
        AND p2.gender = 'F'
)
SELECT
    fhc.patient_id,
    fhc.site_id,
    DATE(fhc.art_start_date) AS art_start_date,
    o.concept_id,
    cn_q.name AS observation_question,
    DATE(o.obs_datetime) AS obs_date,
    o.value_coded,
    cn_a.name AS observation_answer,
    o.value_text AS obs_answer_text,
    CASE
        WHEN o.value_coded = 1065 THEN 'Coded Yes'
        WHEN LOWER(TRIM(o.value_text)) = 'yes' THEN 'Text Yes'
    END AS answer_source,
    DATEDIFF(DATE(o.obs_datetime), DATE(fhc.art_start_date)) AS days_from_art_start,
    CASE
        WHEN fhc.art_start_date IS NULL
            THEN 'ART start date missing - cannot verify pregnancy timing'
        ELSE CONCAT('Pregnancy observation recorded ',
            ABS(DATEDIFF(DATE(o.obs_datetime), DATE(fhc.art_start_date))),
            ' day(s) ',
            CASE
                WHEN DATEDIFF(DATE(o.obs_datetime), DATE(fhc.art_start_date)) < 0
                    THEN 'before'
                ELSE 'after'
            END,
            ' ART initiation date of ',
            DATE(fhc.art_start_date)
        )  END AS DQ_flag,
    'Plausibility - Atemporal Plausibility' AS kahn_category,
    CASE
        WHEN fhc.art_start_date IS NULL THEN 'Medium'
        ELSE 'Low'  -- pregnant at ART start is clinically expected, not an error
    END AS severity
FROM obs o
JOIN female_HIV_clients fhc
    ON o.person_id = fhc.patient_id
    AND o.site_id = fhc.site_id
JOIN concept_name cn_q
    ON o.concept_id = cn_q.concept_id
    AND cn_q.locale = 'en'
    AND cn_q.concept_name_type = 'FULLY_SPECIFIED'
LEFT JOIN concept_name cn_a
    ON o.value_coded = cn_a.concept_id
    AND cn_a.locale = 'en'
    AND cn_a.concept_name_type = 'FULLY_SPECIFIED'
WHERE o.voided = 0
    AND o.concept_id IN (6131, 1755, 5630)
    AND (o.value_coded = 1065
        OR LOWER(TRIM(o.value_text)) = 'yes'
        OR o.value_datetime IS NOT NULL )
    AND (fhc.art_start_date IS NULL
        OR DATE(o.obs_datetime) BETWEEN DATE_SUB(DATE(fhc.art_start_date), INTERVAL 30 DAY)
            AND DATE_ADD(DATE(fhc.art_start_date), INTERVAL 30 DAY) )
ORDER BY fhc.site_id, fhc.patient_id;
------------------------------------------------------------------------------------------
#10. Females currently recorded as breastfeeding
------------------------------------------------------------------------------------------

WITH female_HIV_clients AS (
    SELECT DISTINCT
        p.patient_id,
        p.site_id
    FROM patient p
    JOIN person p2
        ON p.patient_id = p2.person_id
        AND p.site_id = p2.site_id
    JOIN patient_program pp
        ON pp.patient_id = p.patient_id
        AND pp.site_id = p.site_id
    JOIN patient_state ps
        ON pp.patient_program_id = ps.patient_program_id
        AND pp.site_id = ps.site_id
    WHERE pp.program_id = 1
        AND p.voided = 0
        AND pp.voided = 0
        AND ps.voided = 0
        AND ps.state = 7
        AND ps.end_date IS NULL
        AND p2.gender = 'F'
),
latest_breastfeeding_obs AS (
    SELECT
        o.person_id,
        o.site_id,
        o.concept_id,
        o.value_coded,
        o.value_text,
        o.obs_datetime,
        ROW_NUMBER() OVER (PARTITION BY o.person_id, o.concept_id ORDER BY o.obs_datetime DESC ) AS row_num
    FROM obs o
    JOIN female_HIV_clients fhc
        ON o.person_id = fhc.patient_id
        AND o.site_id = fhc.site_id
    WHERE o.voided = 0
        AND o.concept_id IN (7965, 5632)
        AND (o.value_coded = 1065
            OR LOWER(TRIM(o.value_text)) = 'yes' )
)
SELECT
    lbo.person_id AS patient_id,
    lbo.site_id,
    lbo.concept_id,
    cn_q.name AS observation_question,
    DATE(lbo.obs_datetime) AS latest_obs_date,
    lbo.value_coded,
    cn_a.name AS observation_answer,
    lbo.value_text AS obs_answer_text,
    CASE
        WHEN lbo.value_coded = 1065 THEN 'Coded Yes'
        WHEN LOWER(TRIM(lbo.value_text)) = 'yes' THEN 'Text Yes'
    END AS answer_source,
    DATEDIFF(CURRENT_DATE(), DATE(lbo.obs_datetime)) AS days_since_obs,
    CASE
        WHEN DATEDIFF(CURRENT_DATE(), DATE(lbo.obs_datetime)) > 730
            THEN CONCAT('Breastfeeding status last confirmed: ',
                DATEDIFF(CURRENT_DATE(), DATE(lbo.obs_datetime)),
                ' days ago - exceeds 24 month biological limit, verify if still current' )
        ELSE CONCAT('Patient currently recorded as breastfeeding as of ',
            DATE(lbo.obs_datetime) )
    END AS DQ_flag,
    'Plausibility - Temporal Plausibility' AS kahn_category,
    CASE
        WHEN DATEDIFF(CURRENT_DATE(), DATE(lbo.obs_datetime)) > 730 THEN 'High'
        ELSE 'Low'
    END AS severity
FROM latest_breastfeeding_obs lbo
JOIN concept_name cn_q
    ON lbo.concept_id = cn_q.concept_id
    AND cn_q.locale = 'en'
    AND cn_q.concept_name_type = 'FULLY_SPECIFIED'
LEFT JOIN concept_name cn_a
    ON lbo.value_coded = cn_a.concept_id
    AND cn_a.locale = 'en'
    AND cn_a.concept_name_type = 'FULLY_SPECIFIED'
WHERE lbo.row_num  = 1
ORDER BY lbo.site_id, lbo.person_id;

------------------------------------------------------------------------------------------
End 
------------------------------------------------------------------------------------------