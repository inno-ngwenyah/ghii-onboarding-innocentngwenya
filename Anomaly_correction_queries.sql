================================================================
#DQA Report Assignment - Anomaly Correction Queries
================================================================
-----------------------------------------------------------------------
#1.Clients missing gender or gender recorded in an inconsistent format
-----------------------------------------------------------------------
-- Identify and update records with non-standard gender values
-- At Facility level, update
UPDATE person
SET gender = CASE
    WHEN LOWER(gender) IN ('male', 'm') THEN 'M'
    WHEN LOWER(gender) IN ('female', 'f') THEN 'F'
    ELSE gender  -- leave for manual review. Includes U for Unknown gender
END
WHERE gender NOT IN ('M', 'F')
AND voided = 0;

-- CDR level  - just flag them out or exclude in the report
SELECT DISTINCT 
    p.patient_id AS patient_id, p2.gender AS gender, p.site_id,
    CASE WHEN p2.gender = 'Male' THEN 'Non-standard Male'
    	WHEN p2.gender = 'Female' THEN 'Non-standard Female'
    	WHEN p2.gender IS NULL THEN 'Gender not recorded'
    ELSE 'Normal' 
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
    and ps.voided = 0
	AND ps.state = 7
    AND ps.end_date IS NULL      
ORDER BY p.patient_id ;


-------------------------------------------------------------------------
#2. Clients with a death date who have subsequent visit records
-------------------------------------------------------------------------
-- If death date is confirmed wrong, update it:
UPDATE person
SET death_date = NULL,
    dead = 0
WHERE person_id = :patient_id  -- supply specific ID after review
AND site_id = :site_id
AND voided = 0;

-- If visits are erroneous (e.g. data entry after patient transfer):
UPDATE encounter
SET voided = 1,
    voided_by = :user_id,
    date_voided = CURRENT_DATE(),
    void_reason = 'Encounter recorded after confirmed death date - under review'
WHERE encounter_id = :encounter_id
    AND site_id = :site_id;

-- CDR level
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
    dc.site_id,
    CASE WHEN e.encounter_datetime > dc.start_date THEN 'Dead clients with subsequent records'
    ELSE 'Normal'
    END AS issue
FROM encounter e 
JOIN encounter_type et ON e.encounter_type = et.encounter_type_id
JOIN dead_clients dc ON dc.patient_id = e.patient_id 
WHERE e.voided = 0
	AND e.encounter_datetime > dc.start_date 
ORDER BY dc.patient_id;
------------------------------------------------------------------------------
#3. Clients initiated on ART before their recorded date of birth
------------------------------------------------------------------------------
-- Identify the specific discrepancy before correcting
SELECT
    p.patient_id,
    p2.birthdate,
    DATE(ps.start_date) AS art_start_date,
    DATEDIFF(DATE(ps.start_date), p2.birthdate) AS days_difference
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
WHERE ps.state = 7
    AND p.voided = 0
    AND ps.voided = 0
    AND pp.voided = 0
    AND p2.birthdate > DATE(ps.start_date);

-- Update Date of birth
UPDATE person p 
SET birthdate = :birthdate
WHERE p.person_id = :patient_id -- The patient_id for the patient
    AND p.site_id = :site_id

-- Or Update obs date
UPDATE obs o
SET obs_datetime = :obs_datetime,
WHERE obs_id = :obs_id
    AND o.site_id = :site_id
    AND o.person_id = :person_id
    AND voided = 0;

-- CDR level
SELECT
    p.patient_id,
    p2.birthdate,
    DATE(ps.start_date) AS art_start_date,
    DATEDIFF(DATE(ps.start_date), p2.birthdate) AS days_difference,
    CASE WHEN p2.birthdate > date(ps.start_date) THEN 'ART initiated before Birth date - please verify'
    	WHEN date(ps.start_date) > current_date() THEN 'ART initial date is in the future - verify'
    ELSE 'Normal'
    END AS issues
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
WHERE ps.state = 7
    AND p.voided = 0
    AND ps.voided = 0
    AND pp.voided = 0
	AND p2.birthdate > date(ps.start_date) ;

-------------------------------------------------------------------------------------
#4. Male clients with pregnant or breastfeeding observations
-------------------------------------------------------------------------------------
-- After review, Update necessary gender for MALES
UPDATE person p
SET gender = 'F'
WHERE p.person_id = :person_id
AND voided = 0
AND p.site_id = :site_id;


-- Void the erroneous observations after clinical verification
UPDATE obs o
SET voided = 1,
    voided_by = :user_id,
    date_voided = CURRENT_DATE(),
    void_reason = 'Pregnancy/breastfeeding observation recorded on male patient - data entry error'
WHERE obs_id = :obs_id
AND voided = 0
AND o.site_id = :site_id;

------------------------------------------------------------------------------------
#5. Female clients with pregnant/breastfeeding observations outside age range BETWEEN 8 & 55 years
-------------------------------------------------------------------------------------
-- Generate a review list with age at observation for facility follow-up
-- Then update records where necessary or void erronous records
-- Update birthdate
UPDATE person p 
SET birthdate = :birthdate 
WHERE p.person_id = :patient_id -- The patient_id for the patient
    AND p.site_id = :site_id

-- CDR level
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
    END AS answer_source,
    CASE WHEN o.value_coded = 1065 OR LOWER(TRIM(o.value_text)) = 'yes' THEN 'Male client with pregnant/breastfeeding obs'
    	ELSE 'Normal'
    	END AS issue_flags
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

-------------------------------------------------------------------------------------
#6. Clients initiated on ART before 1985 (implausible date)
-------------------------------------------------------------------------------------
-- Step 1: Verify what you are about to change BEFORE updating
SELECT
    pp.patient_program_id,
    ps.patient_state_id,
    p.patient_id,
    p.site_id,
    DATE(ps.start_date) AS current_wrong_start_date,
    ps.date_created,
    ps.date_changed
FROM patient p
JOIN patient_program pp 
	ON pp.patient_id = p.patient_id
	AND pp.site_id = p.site_id 
JOIN patient_state ps 
	ON pp.patient_program_id = ps.patient_program_id
	AND pp.site_id = ps.site_id 
WHERE p.patient_id = :patient_id   -- supply specific patient ID
    AND ps.state = 7
    AND ps.voided = 0;

-- Step 2: Once verified, perform the update
UPDATE patient_state
SET
    start_date = ':correct_date',       
    date_changed = CURRENT_DATE(),
    changed_by = :user_id             
WHERE patient_state_id = :patient_state_id  
    AND state = 7
    AND voided = 0
	AND site_id = :site_id;

-------------------------------------------------------------------------------------
#7. Paediatric clients (under 15) missing weight, height, or BMI at any visit
-------------------------------------------------------------------------------------
-- Update obs at the next visit
UPDATE obs
SET value_numeric = :correct_value,
    date_changed = CURRENT_DATE(),
    changed_by = :user_id
WHERE obs_id = :obs_id
AND voided = 0;

-- If the measurement was never taken and cannot be retrieved:
INSERT INTO obs (
    person_id, concept_id, obs_datetime,
    site_id, value_numeric, creator, date_created, voided
)
VALUES (
    :patient_id, 5090, :visit_date,
    :site_id, :height_value, :user_id, CURRENT_DATE(), 0
);

------------------------------------------------------------------------------------
#8 Adult clients with no height recorded across all visits
------------------------------------------------------------------------------------
-- These clients need a one-time height entry at their next scheduled visit
-- After height is obtained clinically, insert the observation:
INSERT INTO obs (
    person_id, concept_id, obs_datetime,
    encounter_id, site_id,
    value_numeric, creator, date_created, voided
)
VALUES (
    :patient_id,
    5090,           -- height concept
    :encounter_datetime,
    :encounter_id,
    :site_id,
    :height_in_cm,  -- height measured
    :user_id,
    CURRENT_DATE(),
    0
);

--------------------------------------------------------------------------------------
#9. Females who were pregnant at ART initiation
--------------------------------------------------------------------------------------
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
SELECT
    fhc.patient_id,
    fhc.site_id,
    DATE(fhc.art_start_date) AS art_start_date,
    pp2.program_id AS pmtct_program_id,
    pp2.date_enrolled AS pmtct_enrolment_date
FROM female_HIV_clients fhc
LEFT JOIN patient_program pp2
    ON fhc.patient_id = pp2.patient_id
    AND fhc.site_id = pp2.site_id 
    AND pp2.program_id = :pmtct_program_id  -- supply PMTCT program ID
    AND pp2.voided = 0
WHERE pp2.patient_id IS NULL;
-- Returns patients pregnant at ART start but NOT enrolled in PMTCT

------------------------------------------------------------------------------------------
#10. Females currently recorded as breastfeeding
------------------------------------------------------------------------------------------
-- For confirmed cases where breastfeeding has ceased,
-- record an updated observation with answer = No (1066)
INSERT INTO obs (
    person_id, concept_id, obs_datetime,
    encounter_id, site_id,
    value_coded, creator, date_created, voided
)
VALUES (
    :patient_id,
    7965,           -- breastfeeding concept
    :current_encounter_datetime,
    :encounter_id,
    :site_id,
    1066,           -- No
    :user_id,
    CURRENT_DATE(),
    0
);

#Ends here


