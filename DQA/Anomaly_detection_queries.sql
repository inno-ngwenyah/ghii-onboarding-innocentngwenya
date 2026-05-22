================================================================
#DQA Report Assignment - Anomaly Detection Queries 
================================================================
#1.Clients missing gender or gender recorded in an inconsistent format
SELECT DISTINCT 
    p.patient_id AS patient_id, p2.gender AS gender, p.site_id 
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
    and ps.voided = 0
	AND (p2.gender IS NULL OR p2.gender NOT IN ('M', 'F', 'U'))
	AND ps.state = 7
    AND ps.end_date IS NULL      
ORDER BY p.patient_id ;

#2. Clients with a death date who have subsequent visit records
WITH dead_clients AS (
    SELECT DISTINCT 
        p.patient_id AS patient_id, ps.state AS state, 
        ps.start_date AS start_date, ps.end_date AS end_date , p.site_id AS site_id
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
SELECT 
    dc.patient_id, dc.state , dc.start_date , dc.end_date , e.encounter_datetime, et.name AS encounter_type,
    dc.site_id 
FROM encounter e 
JOIN encounter_type et ON e.encounter_type = et.encounter_type_id
JOIN dead_clients dc ON dc.patient_id = e.patient_id 
WHERE e.voided = 0
    AND e.encounter_datetime > dc.start_date 
ORDER BY dc.patient_id;

#3. Clients initiated on ART before their recorded date of birth
SELECT DISTINCT
    p.patient_id AS patient_id,
    p.site_id AS site_id,
    p2.birthdate AS date_of_birth,
    p2.birthdate_estimated,
    DATE(ps.start_date) AS art_start_date,
    CASE
        WHEN p2.birthdate IS NULL THEN 'Missing birthdate'
        WHEN ps.start_date IS NULL THEN 'Missing ART start date'
        WHEN p2.birthdate > DATE(ps.start_date) THEN 'ART started before birth'
    END AS issue
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
	AND (p2.birthdate IS NULL
            OR ps.start_date IS NULL
            OR p2.birthdate > DATE(ps.start_date)) 
ORDER BY p.patient_id ;


#4. Male clients with pregnant or breastfeeding observations
WITH male_HIV_clients AS (
    SELECT DISTINCT
        p.patient_id AS patient_id,
        p2.gender AS gender,
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
        AND ps.state = 7
        AND ps.end_date IS NULL
        AND p2.gender = 'M'
)
SELECT DISTINCT
    mhc.patient_id,
    mhc.site_id,
    o.concept_id,
    cn_q.name AS observation_question,
    o.obs_datetime,
    o.value_coded,
    cn_a.name AS observation_answer,
    o.value_text AS obs_answer_text,
    CASE
        WHEN o.value_coded = 1065 THEN 'Coded Yes'
        WHEN LOWER(TRIM(o.value_text)) = 'yes' THEN 'Text Yes'
    END AS answer_source
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
    AND (o.value_coded = 1065                    -- coded Yes
        OR LOWER(TRIM(o.value_text)) = 'yes')   -- text Yes, any capitalisation
ORDER BY mhc.patient_id;


#5. Female clients with pregnant/breastfeeding observations outside age range BETWEEN 8 & 55 years
WITH female_HIV_clients AS (
    SELECT DISTINCT
        p.patient_id AS patient_id, p2.gender AS gender, p2.birthdate AS birthdate, p.site_id AS site_id
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
    fhc.patient_id,  fhc.site_id, fhc.birthdate,
    TIMESTAMPDIFF(YEAR, fhc.birthdate, o.obs_datetime) AS age_at_observation,
    o.concept_id, cn_q.name AS observation_question,  o.obs_datetime,  o.value_coded,  o.value_datetime, o.value_numeric,
    cn_a.name AS observation_answer,
    o.value_text AS obs_answer_text,
    CASE
        WHEN fhc.birthdate IS NULL THEN 'Missing birthdate'
        ELSE 'Age outside 8-55 at time of observation'
    END AS issue
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
    AND (o.value_coded = 1065  -- value coded yes
    	OR LOWER(TRIM(o.value_text)) = 'yes'   
        OR o.value_datetime IS NOT NULL
        OR o.value_numeric IS NOT NULL)
    AND (fhc.birthdate IS NULL
        OR TIMESTAMPDIFF(YEAR, fhc.birthdate, o.obs_datetime) NOT BETWEEN 8 AND 55)
ORDER BY fhc.patient_id;

#6. Clients initiated on ART before 1985 (implausible date)
SELECT DISTINCT
    p.patient_id AS patient_id, p.site_id AS site_id,
    DATE(ps.start_date) AS art_start_date,
    CASE
        WHEN ps.start_date IS NULL THEN 'Missing ART start date'
        WHEN DATE(ps.start_date) < '1985-01-01' THEN 'ART start date before 1985'
        WHEN DATE(ps.start_date) > CURRENT_DATE() THEN 'ART start date in the future'
    END AS issue
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
    AND (ps.start_date IS NULL
        OR DATE(ps.start_date) < '1985-01-01'
        OR DATE(ps.start_date) > CURRENT_DATE())
ORDER BY p.patient_id;


#7. Paediatric clients (under 15) missing weight, height, or BMI at any visit
WITH peds_clients AS (
    SELECT DISTINCT
        p.patient_id AS patient_id, p2.birthdate AS date_of_birth, p.site_id AS site_id
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
    e.patient_id, pc.site_id, e.encounter_id, e.encounter_datetime AS visit_date, pc.date_of_birth,
    TIMESTAMPDIFF(YEAR, pc.date_of_birth, e.encounter_datetime) AS age_at_visit,    
    MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) AS weight,
    MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) AS height_cm,
    MAX(CASE WHEN o.concept_id = 2137 THEN o.value_numeric END) AS bmi,
    CASE
        WHEN MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) IS NULL
            AND MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) IS NULL
            AND MAX(CASE WHEN o.concept_id = 2137 THEN o.value_numeric END) IS NULL
            THEN 'Weight, Height and BMI all missing'
        WHEN MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) IS NULL
            AND MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) IS NULL
            THEN 'Weight and Height missing'
        WHEN MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) IS NULL
            THEN 'Weight missing'
        WHEN MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) IS NULL
            THEN 'Height missing'
        WHEN MAX(CASE WHEN o.concept_id = 2137 THEN o.value_numeric END) IS NULL
            THEN 'BMI missing'
    END AS issue
FROM encounter e
JOIN peds_clients pc 
	ON e.patient_id = pc.patient_id
	AND e.site_id = pc.site_id 
LEFT JOIN obs o 
	ON e.encounter_id = o.encounter_id
	AND e.site_id = o.site_id 
    AND o.concept_id IN (2137, 5089, 5090)
    AND o.voided = 0
WHERE e.voided = 0
    AND (pc.date_of_birth IS NULL
        OR TIMESTAMPDIFF(YEAR, pc.date_of_birth, e.encounter_datetime) < 15)
GROUP BY
    e.patient_id, e.encounter_id, e.encounter_datetime, pc.date_of_birth, pc.site_id
HAVING
    MAX(CASE WHEN o.concept_id = 5089 THEN o.value_numeric END) IS NULL
    OR MAX(CASE WHEN o.concept_id = 5090 THEN o.value_numeric END) IS NULL
    OR MAX(CASE WHEN o.concept_id = 2137 THEN o.value_numeric END) IS NULL
ORDER BY e.patient_id, e.encounter_datetime;

#8 Adult clients with no height recorded across all visits
WITH adult_clients AS (
    SELECT DISTINCT
        p.patient_id AS patient_id, p.site_id AS site_id, p2.birthdate AS date_of_birth,
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
    adc.patient_id, adc.site_id, adc.date_of_birth,
    TIMESTAMPDIFF(YEAR, adc.date_of_birth, CURRENT_DATE()) AS current_age,
    TIMESTAMPDIFF(YEAR, adc.date_of_birth, adc.program_enrolment_date) AS age_at_enrolment,
    CASE
        WHEN adc.date_of_birth IS NULL
            THEN 'Height missing - birthdate unknown, age unverifiable'
        WHEN TIMESTAMPDIFF(YEAR, adc.date_of_birth, CURRENT_DATE()) > 120
            THEN 'Height missing - implausible age'
        ELSE 'Height never recorded'
    END AS issue
FROM adult_clients adc
WHERE (
    adc.date_of_birth IS NULL
    OR (TIMESTAMPDIFF(YEAR, adc.date_of_birth, CURRENT_DATE()) >= 15
        AND TIMESTAMPDIFF(YEAR, adc.date_of_birth, adc.program_enrolment_date) >= 15)
)
AND NOT EXISTS (
    SELECT 1
    FROM obs o
    WHERE o.person_id = adc.patient_id
        AND o.site_id = adc.site_id
        AND o.concept_id = 5090
        AND o.voided = 0
        AND o.value_numeric IS NOT NULL
)
ORDER BY adc.patient_id;


#9. Females who were pregnant at ART initiation
WITH female_HIV_clients AS (
    SELECT DISTINCT
        p.patient_id AS patient_id,
        p2.gender AS gender,
        ps.start_date AS art_start_date, p.site_id AS site_id 
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
        AND ps.start_date IS NOT NULL
        AND ps.end_date IS NULL
        AND p2.gender = 'F'
)
SELECT DISTINCT 
    fhc.patient_id,
    fhc.site_id,
    DATE(fhc.art_start_date) AS art_start_date,
    o.concept_id,
    cn_q.name AS observation_question,
    o.obs_datetime AS obs_date,
    o.value_coded,
    cn_a.name AS observation_answer,
    o.value_text as obs_answer_text,
    o.value_datetime AS value_datetime,
    CASE
        WHEN fhc.art_start_date IS NULL THEN 'Missing ART start date'
        ELSE 'Pregnant at ART initiation'
    END AS issue
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
        OR o.value_datetime IS NOT NULL
        OR o.value_numeric IS NOT NULL)
    AND (fhc.art_start_date IS NULL
        OR DATE(o.obs_datetime) BETWEEN
            DATE_SUB(DATE(fhc.art_start_date), INTERVAL 30 DAY)
            AND DATE_ADD(DATE(fhc.art_start_date), INTERVAL 30 DAY)
    )
ORDER BY fhc.patient_id;

#10. Females currently recorded as breastfeeding
WITH female_HIV_clients AS (
    SELECT DISTINCT
        p.patient_id AS patient_id, p.site_id
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
        AND ps.start_date IS NOT NULL 
        AND ps.end_date IS NULL 
        AND p2.gender = 'F'
),
latest_breastfeeding_obs AS (
    SELECT
        o.person_id, o.concept_id, o.value_coded, o.obs_datetime, fhc.site_id, o.value_text AS obs_anser_text,
        ROW_NUMBER() OVER (PARTITION BY o.person_id, o.concept_id ORDER BY o.obs_datetime DESC) AS row_num
    FROM obs o
    JOIN female_HIV_clients fhc 
    	ON o.person_id = fhc.patient_id
    	AND o.site_id = fhc.site_id 
    WHERE o.voided = 0
        AND o.concept_id = 7965
        AND (o.value_coded = 1065  -- Yes answers only, filtered early
        	OR LOWER(TRIM(o.value_text)) = 'yes')
)
SELECT
    lbo.person_id AS patient_id,
    lbo.site_id,
    cn_q.name AS observation_question,
    DATE(lbo.obs_datetime) AS latest_obs_date,
    lbo.value_coded,
    cn_a.name AS observation_answer,
    lbo.obs_anser_text ,
    DATEDIFF(CURRENT_DATE(), DATE(lbo.obs_datetime)) AS days_since_obs,
    CASE
        WHEN DATEDIFF(CURRENT_DATE(), DATE(lbo.obs_datetime)) > 730  THEN 'Breastfeeding obs older than 24 months - verify'
        ELSE 'Currently breastfeeding'
    END AS issue
FROM latest_breastfeeding_obs lbo
JOIN concept_name cn_q
    ON lbo.concept_id = cn_q.concept_id
    AND cn_q.locale = 'en'
    AND cn_q.concept_name_type = 'FULLY_SPECIFIED'
LEFT JOIN concept_name cn_a
    ON lbo.value_coded = cn_a.concept_id
    AND cn_a.locale = 'en'
    AND cn_a.concept_name_type = 'FULLY_SPECIFIED'
WHERE lbo.row_num = 1
ORDER BY lbo.person_id;


#Ends here


