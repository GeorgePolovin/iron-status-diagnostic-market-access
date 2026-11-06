-- ============================================================
-- a03_define_target_cohort.sql
--
-- Business question:
-- Which patient segments represent the potential opportunity
-- for an iron-status diagnostic?
--
-- Important:
-- Confirmed iron-related diagnoses will be distinguished from
-- clinical risk factors and nonspecific symptom proxies.
-- ============================================================


-- @block 1. Inspect conditions-table structure

DESCRIBE synthea.conditions;

-- @block 2. Identify available iron-related diagnoses and risk proxies
--
-- Purpose:
-- Find relevant condition codes and descriptions actually present
-- in the Synthea dataset before building the cohort definition.

SELECT
    CODE AS condition_code,
    DESCRIPTION AS condition_description,
    COUNT(*) AS condition_records,
    COUNT(DISTINCT PATIENT) AS unique_patients,
    MIN(START) AS earliest_start_date,
    MAX(START) AS latest_start_date
FROM synthea.conditions
WHERE REGEXP_MATCHES(
    LOWER(DESCRIPTION),
    'iron|anemia|anaemia|fatigue|dizz|hair loss|alopecia|pregnan|menstr|blood loss|hemorrhage|haemorrhage|kidney|renal|heart failure'
)
GROUP BY
    CODE,
    DESCRIPTION
ORDER BY
    unique_patients DESC,
    condition_records DESC,
    condition_description;


-- @block 3. Review the most common condition descriptions

SELECT
    CODE AS condition_code,
    DESCRIPTION AS condition_description,
    COUNT(*) AS condition_records,
    COUNT(DISTINCT PATIENT) AS unique_patients
FROM synthea.conditions
GROUP BY
    CODE,
    DESCRIPTION
ORDER BY
    unique_patients DESC,
    condition_records DESC
LIMIT 100;


-- @block 4. Create patient-level risk flags
--
-- Grain:
--   One row per synthetic patient
--
-- Important:
--   Flags can overlap. A patient may have anemia and pregnancy,
--   CKD and heart failure, or another combination.

CREATE OR REPLACE TABLE analytics.synthea_patient_risk_flags AS

WITH condition_flags AS (

    SELECT
        c.PATIENT AS patient_id,

        MAX(
            CASE
                WHEN c.CODE = 271737000
                    THEN 1
                ELSE 0
            END
        ) AS anemia_diagnosis_flag,

        MAX(
            CASE
                WHEN c.CODE IN (
                    72892002,       -- Normal pregnancy
                    79586000,       -- Tubal pregnancy
                    19169002,       -- Miscarriage in first trimester
                    156073000,      -- Fetus with unknown complication
                    198992004,      -- Antepartum eclampsia
                    398254007,      -- Preeclampsia
                    35999006        -- Blighted ovum
                )
                    THEN 1
                ELSE 0
            END
        ) AS pregnancy_related_flag,

        MAX(
            CASE
                WHEN c.CODE IN (
                    127013003,      -- Diabetic renal disease
                    431855005,      -- CKD stage 1
                    431856006,      -- CKD stage 2
                    90781000119102  -- Microalbuminuria due to T2DM
                )
                    THEN 1
                ELSE 0
            END
        ) AS kidney_renal_risk_flag,

        MAX(
            CASE
                WHEN c.CODE = 88805009
                    THEN 1
                ELSE 0
            END
        ) AS heart_failure_flag,

        COUNT(*) FILTER (
            WHERE c.CODE IN (
                271737000,

                72892002,
                79586000,
                19169002,
                156073000,
                198992004,
                398254007,
                35999006,

                127013003,
                431855005,
                431856006,
                90781000119102,

                88805009
            )
        ) AS target_condition_records,

        COUNT(
            DISTINCT CASE
                WHEN c.CODE IN (
                    271737000,

                    72892002,
                    79586000,
                    19169002,
                    156073000,
                    198992004,
                    398254007,
                    35999006,

                    127013003,
                    431855005,
                    431856006,
                    90781000119102,

                    88805009
                )
                    THEN c.ENCOUNTER
            END
        ) AS target_condition_encounters,

        MIN(
            CASE
                WHEN c.CODE IN (
                    271737000,

                    72892002,
                    79586000,
                    19169002,
                    156073000,
                    198992004,
                    398254007,
                    35999006,

                    127013003,
                    431855005,
                    431856006,
                    90781000119102,

                    88805009
                )
                    THEN c.START
            END
        ) AS first_target_condition_date,

        MAX(
            CASE
                WHEN c.CODE IN (
                    271737000,

                    72892002,
                    79586000,
                    19169002,
                    156073000,
                    198992004,
                    398254007,
                    35999006,

                    127013003,
                    431855005,
                    431856006,
                    90781000119102,

                    88805009
                )
                    THEN c.START
            END
        ) AS latest_target_condition_date

    FROM synthea.conditions AS c

    GROUP BY
        c.PATIENT
),

encounter_utilization AS (

    SELECT
        e.PATIENT AS patient_id,
        COUNT(DISTINCT e."Id") AS total_encounters,
        MIN(e.START) AS first_encounter_date,
        MAX(e.START) AS latest_encounter_date
    FROM synthea.encounters AS e
    GROUP BY
        e.PATIENT
)

SELECT
    p.patient_id,
    p.gender,
    p.race,
    p.ethnicity,
    p.state,
    p.county,

    COALESCE(f.anemia_diagnosis_flag, 0)
        AS anemia_diagnosis_flag,

    COALESCE(f.pregnancy_related_flag, 0)
        AS pregnancy_related_flag,

    COALESCE(f.kidney_renal_risk_flag, 0)
        AS kidney_renal_risk_flag,

    COALESCE(f.heart_failure_flag, 0)
        AS heart_failure_flag,

    COALESCE(f.anemia_diagnosis_flag, 0)
        + COALESCE(f.pregnancy_related_flag, 0)
        + COALESCE(f.kidney_renal_risk_flag, 0)
        + COALESCE(f.heart_failure_flag, 0)
        AS risk_flag_count,

    COALESCE(f.target_condition_records, 0)
        AS target_condition_records,

    COALESCE(f.target_condition_encounters, 0)
        AS target_condition_encounters,

    f.first_target_condition_date,
    f.latest_target_condition_date,

    COALESCE(u.total_encounters, 0)
        AS total_encounters,

    u.first_encounter_date,
    u.latest_encounter_date

FROM analytics.synthea_patient_profile AS p

LEFT JOIN condition_flags AS f
    ON p.patient_id = f.patient_id

LEFT JOIN encounter_utilization AS u
    ON p.patient_id = u.patient_id;


-- @block 5. Validate patient-risk table

SELECT
    COUNT(*) AS risk_table_rows,
    COUNT(DISTINCT patient_id) AS unique_patients,
    COUNT(*) - COUNT(DISTINCT patient_id)
        AS duplicate_patient_ids,

    SUM(anemia_diagnosis_flag)
        AS patients_with_anemia,

    SUM(pregnancy_related_flag)
        AS patients_with_pregnancy_related_condition,

    SUM(kidney_renal_risk_flag)
        AS patients_with_kidney_or_renal_risk,

    SUM(heart_failure_flag)
        AS patients_with_heart_failure,

    COUNT_IF(risk_flag_count > 1)
        AS patients_in_multiple_segments

FROM analytics.synthea_patient_risk_flags;


-- @block 6. Create mutually exclusive target cohort
--
-- Grain:
--   One row per target patient
--
-- Priority hierarchy:
--   1. Anemia diagnosis
--   2. Pregnancy-related risk
--   3. Kidney/renal risk
--   4. Heart failure

CREATE OR REPLACE TABLE analytics.synthea_target_cohort AS

SELECT
    *,

    CASE
        WHEN anemia_diagnosis_flag = 1
            THEN 'Anemia diagnosis (not iron-specific)'

        WHEN pregnancy_related_flag = 1
            THEN 'Pregnancy-related risk'

        WHEN kidney_renal_risk_flag = 1
            THEN 'Kidney or renal disease risk'

        WHEN heart_failure_flag = 1
            THEN 'Congestive heart failure'

        ELSE NULL
    END AS priority_risk_segment,

    CASE
        WHEN anemia_diagnosis_flag = 1
            THEN 'Relevant diagnosis; anemia etiology unspecified'

        WHEN pregnancy_related_flag = 1
            THEN 'Clinical risk population'

        WHEN kidney_renal_risk_flag = 1
            THEN 'Clinical risk population'

        WHEN heart_failure_flag = 1
            THEN 'Clinical risk population'

        ELSE NULL
    END AS evidence_category

FROM analytics.synthea_patient_risk_flags

WHERE
    anemia_diagnosis_flag = 1
    OR pregnancy_related_flag = 1
    OR kidney_renal_risk_flag = 1
    OR heart_failure_flag = 1;


-- @block 7. Validate target-cohort grain and classification

SELECT
    COUNT(*) AS target_patient_rows,
    COUNT(DISTINCT patient_id) AS unique_target_patients,
    COUNT(*) - COUNT(DISTINCT patient_id)
        AS duplicate_target_patients,

    COUNT_IF(priority_risk_segment IS NULL)
        AS unclassified_target_patients,

    COUNT_IF(risk_flag_count > 1)
        AS target_patients_with_overlapping_risks

FROM analytics.synthea_target_cohort;


-- @block 8. Create risk-segment opportunity mart
--
-- Grain:
--   One row per mutually exclusive priority risk segment

CREATE OR REPLACE TABLE mart.risk_segment_opportunity AS

WITH segment_summary AS (

    SELECT
        priority_risk_segment,
        evidence_category,

        COUNT(DISTINCT patient_id)
            AS unique_patients,

        SUM(target_condition_records)
            AS target_condition_records,

        SUM(target_condition_encounters)
            AS target_condition_encounters,

        SUM(total_encounters)
            AS all_encounters_for_target_patients,

        ROUND(
            AVG(total_encounters),
            2
        ) AS average_encounters_per_patient,

        COUNT_IF(risk_flag_count > 1)
            AS patients_with_overlapping_risks,

        COUNT(DISTINCT state)
            AS states_represented

    FROM analytics.synthea_target_cohort

    GROUP BY
        priority_risk_segment,
        evidence_category
)

SELECT
    priority_risk_segment,
    evidence_category,
    unique_patients,

    ROUND(
        100.0 * unique_patients
        / NULLIF(SUM(unique_patients) OVER (), 0),
        2
    ) AS share_of_target_patients_pct,

    target_condition_records,
    target_condition_encounters,
    all_encounters_for_target_patients,
    average_encounters_per_patient,
    patients_with_overlapping_risks,
    states_represented,

    DENSE_RANK() OVER (
        ORDER BY unique_patients DESC
    ) AS opportunity_rank

FROM segment_summary;


-- @block 9. Review patient-segment opportunity

SELECT *
FROM mart.risk_segment_opportunity
ORDER BY opportunity_rank;

-- @block 10. Create overlapping risk-segment summary

CREATE OR REPLACE TABLE mart.risk_segment_overlap AS

SELECT
    'Anemia diagnosis (not iron-specific)'
        AS risk_segment,
    SUM(anemia_diagnosis_flag)
        AS unique_patients
FROM analytics.synthea_patient_risk_flags

UNION ALL

SELECT
    'Pregnancy-related risk',
    SUM(pregnancy_related_flag)
FROM analytics.synthea_patient_risk_flags

UNION ALL

SELECT
    'Kidney or renal disease risk',
    SUM(kidney_renal_risk_flag)
FROM analytics.synthea_patient_risk_flags

UNION ALL

SELECT
    'Congestive heart failure',
    SUM(heart_failure_flag)
FROM analytics.synthea_patient_risk_flags;


-- @block 11. Export risk-segment opportunity table

COPY mart.risk_segment_opportunity
TO 'outputs/marts/risk_segment_opportunity.csv'
WITH (
    HEADER true,
    DELIMITER ','
);

-- @block 11. Create overlapping clinical opportunity mart
--
-- Grain:
--   One row per clinical risk segment
--
-- Important:
--   Patients may appear in more than one segment.
--   Percentages use all distinct target patients as the denominator,
--   so segment percentages are not expected to sum to 100%.

CREATE OR REPLACE TABLE mart.risk_segment_clinical_opportunity AS

WITH segment_membership AS (

    SELECT
        patient_id,
        'Anemia diagnosis (not iron-specific)' AS risk_segment,
        'Relevant diagnosis; anemia etiology unspecified'
            AS evidence_category,
        total_encounters,
        risk_flag_count,
        state
    FROM analytics.synthea_patient_risk_flags
    WHERE anemia_diagnosis_flag = 1

    UNION ALL

    SELECT
        patient_id,
        'Pregnancy-related risk',
        'Clinical risk population',
        total_encounters,
        risk_flag_count,
        state
    FROM analytics.synthea_patient_risk_flags
    WHERE pregnancy_related_flag = 1

    UNION ALL

    SELECT
        patient_id,
        'Kidney or renal disease risk',
        'Clinical risk population',
        total_encounters,
        risk_flag_count,
        state
    FROM analytics.synthea_patient_risk_flags
    WHERE kidney_renal_risk_flag = 1

    UNION ALL

    SELECT
        patient_id,
        'Congestive heart failure',
        'Clinical risk population',
        total_encounters,
        risk_flag_count,
        state
    FROM analytics.synthea_patient_risk_flags
    WHERE heart_failure_flag = 1
),

target_population AS (

    SELECT
        COUNT(DISTINCT patient_id) AS total_target_patients
    FROM analytics.synthea_patient_risk_flags
    WHERE risk_flag_count > 0
),

segment_summary AS (

    SELECT
        s.risk_segment,
        s.evidence_category,

        COUNT(DISTINCT s.patient_id)
            AS unique_patients,

        ROUND(
            AVG(s.total_encounters),
            2
        ) AS average_encounters_per_patient,

        SUM(s.total_encounters)
            AS total_encounters,

        COUNT_IF(s.risk_flag_count > 1)
            AS patients_with_multiple_risk_segments,

        COUNT(DISTINCT s.state)
            AS states_represented,

        MAX(t.total_target_patients)
            AS total_unique_target_patients

    FROM segment_membership AS s

    CROSS JOIN target_population AS t

    GROUP BY
        s.risk_segment,
        s.evidence_category
)

SELECT
    risk_segment,
    evidence_category,
    unique_patients,

    ROUND(
        100.0 * unique_patients
        / NULLIF(total_unique_target_patients, 0),
        2
    ) AS share_of_unique_target_patients_pct,

    average_encounters_per_patient,
    total_encounters,
    patients_with_multiple_risk_segments,
    total_unique_target_patients,
    states_represented,

    DENSE_RANK() OVER (
        ORDER BY unique_patients DESC
    ) AS opportunity_rank

FROM segment_summary;

-- @block 12. Validate overlapping opportunity table

SELECT
    MAX(total_unique_target_patients)
        AS unique_target_patients,

    SUM(unique_patients)
        AS total_segment_memberships,

    SUM(unique_patients)
        - MAX(total_unique_target_patients)
        AS additional_memberships_due_to_overlap,

    ROUND(
        SUM(share_of_unique_target_patients_pct),
        2
    ) AS summed_segment_share_pct

FROM mart.risk_segment_clinical_opportunity;

-- @block 13. Review clinical opportunity segments

SELECT *
FROM mart.risk_segment_clinical_opportunity
ORDER BY opportunity_rank;

-- @block Distribution of overlapping risk segments

SELECT
    risk_flag_count,
    COUNT(DISTINCT patient_id) AS unique_patients,

    ROUND(
        100.0 * COUNT(DISTINCT patient_id)
        / NULLIF(
            SUM(COUNT(DISTINCT patient_id)) OVER (),
            0
        ),
        2
    ) AS share_of_target_patients_pct

FROM analytics.synthea_patient_risk_flags

WHERE risk_flag_count > 0

GROUP BY risk_flag_count
ORDER BY risk_flag_count;

-- @block Export clinical opportunity table for Tableau

COPY mart.risk_segment_clinical_opportunity
TO 'outputs/marts/risk_segment_clinical_opportunity.csv'
WITH (
    HEADER true,
    DELIMITER ','
);





---EXPLORATORY

-- @block Examine encounter distribution for CKD patients
--
-- This tests whether the 312.14 average is driven by
-- unusually high-utilization patients.

SELECT
    COUNT(*) AS ckd_patients,

    MIN(total_encounters)
        AS minimum_encounters,

    ROUND(
        QUANTILE_CONT(total_encounters, 0.25),
        2
    ) AS p25_encounters,

    ROUND(
        MEDIAN(total_encounters),
        2
    ) AS median_encounters,

    ROUND(
        AVG(total_encounters),
        2
    ) AS average_encounters,

    ROUND(
        QUANTILE_CONT(total_encounters, 0.75),
        2
    ) AS p75_encounters,

    ROUND(
        QUANTILE_CONT(total_encounters, 0.90),
        2
    ) AS p90_encounters,

    MAX(total_encounters)
        AS maximum_encounters

FROM analytics.synthea_patient_risk_flags

WHERE kidney_renal_risk_flag = 1;

-- @block Review highest-utilization CKD patients

SELECT
    patient_id,
    total_encounters,
    target_condition_encounters,
    risk_flag_count,
    first_encounter_date,
    latest_encounter_date,

    ROUND(
        DATE_DIFF(
            'day',
            CAST(first_encounter_date AS DATE),
            CAST(latest_encounter_date AS DATE)
        ) / 365.25,
        2
    ) AS observed_years,

    ROUND(
        total_encounters
        / GREATEST(
            DATE_DIFF(
                'day',
                CAST(first_encounter_date AS DATE),
                CAST(latest_encounter_date AS DATE)
            ) / 365.25,
            1
        ),
        2
    ) AS encounters_per_observed_year

FROM analytics.synthea_patient_risk_flags

WHERE kidney_renal_risk_flag = 1

ORDER BY total_encounters DESC
LIMIT 10;

