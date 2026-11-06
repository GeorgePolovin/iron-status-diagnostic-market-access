-- ============================================================
-- a02_profile_synthea.sql
--
-- Purpose:
--   1. Validate the Synthea patient table
--   2. Create a clean patient-level analytics table
--   3. Create Tableau-ready demographic and geographic summaries
--   4. Preserve Synthea financial fields as QA diagnostics only
--
-- Source grain:
--   synthea.patients = one row per synthetic patient
--
-- Financial limitation:
--   HEALTHCARE_EXPENSES and HEALTHCARE_COVERAGE are cumulative
--   outputs from the Synthea simulation. In this sample, their
--   relationship is not plausible as a real-world insurance
--   coverage benchmark. Financial ratios are therefore labeled
--   as diagnostics and excluded from final opportunity charts.
-- ============================================================


-- @block 1. Confirm environment and schemas

CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS mart;

SELECT
    current_database() AS database_name,
    current_schema() AS active_schema,
    version() AS duckdb_version;


-- @block 2. Validate source patient grain
-- Expected:
--   patient_rows = unique_patient_ids
--   duplicate_patient_ids = 0
--   missing_patient_ids = 0

SELECT
    COUNT(*) AS patient_rows,
    COUNT(DISTINCT "Id") AS unique_patient_ids,
    COUNT(*) - COUNT(DISTINCT "Id") AS duplicate_patient_ids,
    COUNT_IF("Id" IS NULL) AS missing_patient_ids
FROM synthea.patients;


-- @block 3. Profile missing patient information

SELECT
    COUNT(*) AS total_patients,
    COUNT_IF(BIRTHDATE IS NULL) AS missing_birthdate,
    COUNT_IF(GENDER IS NULL OR TRIM(GENDER) = '') AS missing_gender,
    COUNT_IF(RACE IS NULL OR TRIM(RACE) = '') AS missing_race,
    COUNT_IF(ETHNICITY IS NULL OR TRIM(ETHNICITY) = '') AS missing_ethnicity,
    COUNT_IF(STATE IS NULL OR TRIM(STATE) = '') AS missing_state,
    COUNT_IF(COUNTY IS NULL OR TRIM(COUNTY) = '') AS missing_county,
    COUNT_IF(HEALTHCARE_EXPENSES IS NULL) AS missing_patient_expenses,
    COUNT_IF(HEALTHCARE_COVERAGE IS NULL) AS missing_payer_coverage
FROM synthea.patients;


-- @block 4. Profile raw Synthea financial fields
-- These results are QA diagnostics, not real-world insurance metrics.

SELECT
    ROUND(MIN(HEALTHCARE_EXPENSES), 2)
        AS minimum_synthea_patient_expenses,
    ROUND(MEDIAN(HEALTHCARE_EXPENSES), 2)
        AS median_synthea_patient_expenses,
    ROUND(MAX(HEALTHCARE_EXPENSES), 2)
        AS maximum_synthea_patient_expenses,

    ROUND(MIN(HEALTHCARE_COVERAGE), 2)
        AS minimum_synthea_payer_coverage,
    ROUND(MEDIAN(HEALTHCARE_COVERAGE), 2)
        AS median_synthea_payer_coverage,
    ROUND(MAX(HEALTHCARE_COVERAGE), 2)
        AS maximum_synthea_payer_coverage,

    COUNT_IF(HEALTHCARE_EXPENSES < 0)
        AS negative_patient_expense_rows,
    COUNT_IF(HEALTHCARE_COVERAGE < 0)
        AS negative_payer_coverage_rows,

    ROUND(SUM(HEALTHCARE_EXPENSES), 2)
        AS total_synthea_patient_expenses,
    ROUND(SUM(HEALTHCARE_COVERAGE), 2)
        AS total_synthea_payer_coverage,

    ROUND(
        SUM(COALESCE(HEALTHCARE_EXPENSES, 0))
        + SUM(COALESCE(HEALTHCARE_COVERAGE, 0)),
        2
    ) AS total_synthea_recorded_amount,

    ROUND(
        100.0 * SUM(COALESCE(HEALTHCARE_COVERAGE, 0))
        / NULLIF(
            SUM(COALESCE(HEALTHCARE_EXPENSES, 0))
            + SUM(COALESCE(HEALTHCARE_COVERAGE, 0)),
            0
        ),
        2
    ) AS diagnostic_payer_coverage_share_pct

FROM synthea.patients;


-- @block 5. Remove obsolete mart from the earlier draft

DROP TABLE IF EXISTS mart.patient_financial_by_geography;


-- @block 6. Create clean patient-level analytics table
--
-- Grain:
--   One row per synthetic patient
--
-- Data minimization:
--   Names, SSN, passport, driver ID and street address are excluded.
--
-- Financial fields:
--   Retained with "synthea_" prefixes so they are not mistaken for
--   validated claims, reimbursement or patient-responsibility measures.

CREATE OR REPLACE TABLE analytics.synthea_patient_profile AS

SELECT
    "Id" AS patient_id,
    BIRTHDATE AS birth_date,
    DEATHDATE AS death_date,

    CASE
        WHEN DEATHDATE IS NULL
            THEN 'No recorded death date'
        ELSE 'Recorded death date'
    END AS mortality_record_status,

    COALESCE(NULLIF(TRIM(GENDER), ''), 'Unknown') AS gender,
    COALESCE(NULLIF(TRIM(RACE), ''), 'Unknown') AS race,
    COALESCE(NULLIF(TRIM(ETHNICITY), ''), 'Unknown') AS ethnicity,
    COALESCE(NULLIF(TRIM(MARITAL), ''), 'Unknown') AS marital_status,

    COALESCE(NULLIF(TRIM(CITY), ''), 'Unknown') AS city,
    COALESCE(NULLIF(TRIM(STATE), ''), 'Unknown') AS state,
    COALESCE(NULLIF(TRIM(COUNTY), ''), 'Unknown') AS county,
    NULLIF(TRIM(ZIP), '') AS zip_code,
    LAT AS latitude,
    LON AS longitude,

    HEALTHCARE_EXPENSES AS synthea_patient_expenses,
    HEALTHCARE_COVERAGE AS synthea_payer_coverage,

    CASE
        WHEN HEALTHCARE_EXPENSES IS NULL
             AND HEALTHCARE_COVERAGE IS NULL
            THEN NULL
        ELSE
            COALESCE(HEALTHCARE_EXPENSES, 0)
            + COALESCE(HEALTHCARE_COVERAGE, 0)
    END AS synthea_recorded_amount

FROM synthea.patients;


-- @block 7. Validate and reconcile patient profile

SELECT
    COUNT(*) AS profile_rows,
    COUNT(DISTINCT patient_id) AS unique_patient_ids,
    COUNT(*) - COUNT(DISTINCT patient_id)
        AS duplicate_patient_ids,
    COUNT_IF(patient_id IS NULL) AS missing_patient_ids,

    COUNT_IF(synthea_patient_expenses < 0)
        AS negative_patient_expense_rows,
    COUNT_IF(synthea_payer_coverage < 0)
        AS negative_payer_coverage_rows,

    ROUND(SUM(synthea_patient_expenses), 2)
        AS profile_patient_expenses,
    ROUND(SUM(synthea_payer_coverage), 2)
        AS profile_payer_coverage,

    (
        SELECT COUNT(*)
        FROM synthea.patients
    ) AS expected_source_rows

FROM analytics.synthea_patient_profile;


-- @block 8. Create Tableau-ready patient dimension summary
--
-- Grain:
--   One row per dimension type and dimension value
--
-- This mart intentionally excludes financial fields.

CREATE OR REPLACE TABLE mart.patient_population_dimensions AS

WITH dimension_counts AS (

    SELECT
        'Gender' AS dimension_type,
        gender AS dimension_value,
        COUNT(DISTINCT patient_id) AS patient_count
    FROM analytics.synthea_patient_profile
    GROUP BY gender

    UNION ALL

    SELECT
        'Race',
        race,
        COUNT(DISTINCT patient_id)
    FROM analytics.synthea_patient_profile
    GROUP BY race

    UNION ALL

    SELECT
        'Ethnicity',
        ethnicity,
        COUNT(DISTINCT patient_id)
    FROM analytics.synthea_patient_profile
    GROUP BY ethnicity

    UNION ALL

    SELECT
        'State',
        state,
        COUNT(DISTINCT patient_id)
    FROM analytics.synthea_patient_profile
    GROUP BY state

    UNION ALL

    SELECT
        'County',
        county,
        COUNT(DISTINCT patient_id)
    FROM analytics.synthea_patient_profile
    GROUP BY county
)

SELECT
    dimension_type,
    dimension_value,
    patient_count,

    ROUND(
        100.0 * patient_count
        / NULLIF(
            SUM(patient_count) OVER (
                PARTITION BY dimension_type
            ),
            0
        ),
        2
    ) AS patient_share_pct

FROM dimension_counts;


-- @block 9. Preview patient dimension summary

SELECT *
FROM mart.patient_population_dimensions
ORDER BY
    dimension_type,
    patient_count DESC,
    dimension_value;


-- @block 10. Create Tableau-ready geographic patient summary
--
-- Grain:
--   One row per state and county

CREATE OR REPLACE TABLE mart.patient_population_by_geography AS

WITH geography_counts AS (

    SELECT
        state,
        county,
        COUNT(DISTINCT patient_id) AS patient_count
    FROM analytics.synthea_patient_profile
    GROUP BY
        state,
        county
)

SELECT
    state,
    county,
    patient_count,

    ROUND(
        100.0 * patient_count
        / NULLIF(SUM(patient_count) OVER (), 0),
        2
    ) AS patient_share_pct,

    DENSE_RANK() OVER (
        ORDER BY patient_count DESC
    ) AS patient_volume_rank

FROM geography_counts;


-- @block 11. Validate geographic summary
-- Because each patient has one row in the patient table,
-- summed county counts should reconcile to the patient profile.

SELECT
    SUM(patient_count) AS summed_patient_count,

    (
        SELECT COUNT(*)
        FROM analytics.synthea_patient_profile
    ) AS expected_patient_count,

    SUM(patient_count)
        - (
            SELECT COUNT(*)
            FROM analytics.synthea_patient_profile
        ) AS reconciliation_difference,

    COUNT(*) AS geographic_rows

FROM mart.patient_population_by_geography;


-- @block 12. Validate encounter financial fields and payer join
-- These fields are retained for source QA only.

SELECT
    COUNT(*) AS encounter_rows,
    COUNT(DISTINCT e."Id") AS unique_encounter_ids,
    COUNT(*) - COUNT(DISTINCT e."Id")
        AS duplicate_encounter_ids,

    COUNT_IF(e.PAYER IS NULL) AS missing_payer_ids,
    COUNT_IF(
        e.PAYER IS NOT NULL
        AND py."Id" IS NULL
    ) AS unmatched_payer_ids,

    COUNT_IF(e.TOTAL_CLAIM_COST < 0)
        AS negative_total_claim_cost_rows,
    COUNT_IF(e.PAYER_COVERAGE < 0)
        AS negative_payer_coverage_rows,
    COUNT_IF(e.PAYER_COVERAGE > e.TOTAL_CLAIM_COST)
        AS payer_coverage_exceeds_claim_cost_rows

FROM synthea.encounters AS e

LEFT JOIN synthea.payers AS py
    ON e.PAYER = py."Id";


-- @block 13. Create encounter financial QA summary by payer
--
-- Grain:
--   One row per synthetic payer
--
-- Important:
--   claim_cost_minus_payer_coverage is NOT labeled patient
--   responsibility because the source does not support that
--   interpretation reliably in this sample.

CREATE OR REPLACE TABLE analytics.synthea_encounter_financial_by_payer_qa AS

WITH payer_summary AS (

    SELECT
        COALESCE(py.NAME, 'Unknown payer') AS payer_name,

        CASE
            WHEN REPLACE(
                UPPER(COALESCE(py.NAME, '')),
                '_',
                ' '
            ) = 'NO INSURANCE'
                THEN 1
            ELSE 0
        END AS no_insurance_flag,

        COUNT(*) AS encounter_count,
        COUNT(DISTINCT e.PATIENT) AS unique_patients,

        SUM(COALESCE(e.TOTAL_CLAIM_COST, 0))
            AS total_claim_cost,

        SUM(COALESCE(e.PAYER_COVERAGE, 0))
            AS payer_coverage_recorded,

        SUM(
            GREATEST(
                COALESCE(e.TOTAL_CLAIM_COST, 0)
                - COALESCE(e.PAYER_COVERAGE, 0),
                0
            )
        ) AS claim_cost_minus_payer_coverage

    FROM synthea.encounters AS e

    LEFT JOIN synthea.payers AS py
        ON e.PAYER = py."Id"

    GROUP BY
        COALESCE(py.NAME, 'Unknown payer'),
        no_insurance_flag
)

SELECT
    payer_name,
    no_insurance_flag,
    encounter_count,
    unique_patients,

    ROUND(total_claim_cost, 2)
        AS total_claim_cost,

    ROUND(
        100.0 * total_claim_cost
        / NULLIF(SUM(total_claim_cost) OVER (), 0),
        2
    ) AS claim_cost_share_pct,

    ROUND(payer_coverage_recorded, 2)
        AS payer_coverage_recorded,

    ROUND(claim_cost_minus_payer_coverage, 2)
        AS claim_cost_minus_payer_coverage,

    ROUND(
        100.0 * payer_coverage_recorded
        / NULLIF(total_claim_cost, 0),
        2
    ) AS diagnostic_coverage_to_claim_cost_pct

FROM payer_summary;


-- @block 14. Preview and validate payer financial QA summary

SELECT *
FROM analytics.synthea_encounter_financial_by_payer_qa
ORDER BY total_claim_cost DESC;


SELECT
    COUNT(*) AS payer_rows,
    ROUND(SUM(claim_cost_share_pct), 2)
        AS summed_claim_cost_share_pct,
    COUNT_IF(no_insurance_flag = 1)
        AS no_insurance_rows,
    COUNT_IF(
        diagnostic_coverage_to_claim_cost_pct < 5
    ) AS payers_below_five_pct_coverage_diagnostic
FROM analytics.synthea_encounter_financial_by_payer_qa;


-- @block 15. Export Tableau-ready patient dimension table

COPY mart.patient_population_dimensions
TO 'outputs/marts/patient_population_dimensions.csv'
WITH (
    HEADER true,
    DELIMITER ','
);


-- @block 16. Export Tableau-ready geographic patient table

COPY mart.patient_population_by_geography
TO 'outputs/marts/patient_population_by_geography.csv'
WITH (
    HEADER true,
    DELIMITER ','
);


-- @block 17. Optional export of financial QA table
-- Keep this in a QA folder rather than using it as a final commercial chart.

COPY analytics.synthea_encounter_financial_by_payer_qa
TO 'outputs/qa/synthea_encounter_financial_by_payer_qa.csv'
WITH (
    HEADER true,
    DELIMITER ','
);
