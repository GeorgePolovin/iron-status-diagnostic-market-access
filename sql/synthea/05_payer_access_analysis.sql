-- @block Inspect payer structure
DESCRIBE synthea.payers;
DESCRIBE synthea.payer_transitions;
SELECT *
From synthea.payers
LIMIT 10;

-- ============================================================
-- a05_payer_access_analysis.sql
--
-- Business questions:
--   1. Which payers appear most often among target patients?
--   2. What is the latest recorded payer mix for the target cohort?
--   3. How much recorded uninsured exposure exists in the cohort?
--   4. Which payers span the most organizations and target segments?
--
-- Important limitations:
--   1. Synthea is synthetic data, not production payer claims.
--   2. payer_transitions describes simulated coverage periods.
--   3. "Latest recorded payer" is not the patient's payer today.
--   4. Payer-level financial fields are retained for QA only because
--      this sample produces implausible coverage relationships.
-- ============================================================

-- @block 1. Confirm required schemas
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS mart;

SELECT
    current_database() AS database_name,
    current_schema() AS active_schema,
    version() AS duckdb_version;

-- @block 2. Validate payer-table grain
SELECT
    COUNT(*) AS payer_rows,
    COUNT(DISTINCT "Id") AS unique_payer_ids,
    COUNT(*) - COUNT(DISTINCT "Id") AS duplicate_payer_ids,
    COUNT_IF("Id" IS NULL) AS missing_payer_ids,
    COUNT_IF(NAME IS NULL OR TRIM(NAME) = '') AS missing_payer_names
FROM synthea.payers;

-- @block 3. Validate payer-transition source
SELECT
    COUNT(*) AS transition_rows,
    COUNT(DISTINCT PATIENT) AS patients_with_transitions,
    COUNT_IF(PATIENT IS NULL) AS missing_patient_ids,
    COUNT_IF(PAYER IS NULL) AS missing_payer_ids,
    COUNT_IF(START_YEAR IS NULL) AS missing_start_years,
    COUNT_IF(END_YEAR IS NULL) AS missing_end_years,
    COUNT_IF(
        START_YEAR IS NOT NULL
        AND END_YEAR IS NOT NULL
        AND END_YEAR < START_YEAR
    ) AS invalid_year_ranges
FROM synthea.payer_transitions;

-- @block 4. Validate payer joins
SELECT
    COUNT(*) AS transition_rows,
    COUNT_IF(pt.PAYER IS NOT NULL AND py."Id" IS NULL)
        AS unmatched_transition_payer_ids,
    COUNT_IF(pt.PATIENT IS NOT NULL AND rf.patient_id IS NULL)
        AS transitions_for_non_target_patients
FROM synthea.payer_transitions AS pt
LEFT JOIN synthea.payers AS py
    ON pt.PAYER = py."Id"
LEFT JOIN analytics.synthea_patient_risk_flags AS rf
    ON pt.PATIENT = rf.patient_id
   AND rf.risk_flag_count > 0;

-- @block 5. Create target-patient payer history
-- Grain: one row per target patient per recorded payer period
CREATE OR REPLACE TABLE analytics.synthea_target_patient_payer_history AS
SELECT
    pt.PATIENT AS patient_id,
    pt.START_YEAR AS coverage_start_year,
    pt.END_YEAR AS coverage_end_year,
    pt.PAYER AS payer_id,
    COALESCE(py.NAME, 'Unknown payer') AS payer_name,
    CASE
        WHEN REPLACE(UPPER(COALESCE(py.NAME, '')), '_', ' ') = 'NO INSURANCE'
            THEN 1
        ELSE 0
    END AS no_insurance_flag,
    COALESCE(NULLIF(TRIM(pt.OWNERSHIP), ''), 'Unknown')
        AS coverage_ownership,
    CASE
        WHEN pt.START_YEAR IS NULL THEN NULL
        WHEN pt.END_YEAR IS NULL THEN 1
        ELSE GREATEST(pt.END_YEAR - pt.START_YEAR + 1, 1)
    END AS recorded_coverage_years,
    ROW_NUMBER() OVER (
        PARTITION BY pt.PATIENT
        ORDER BY
            COALESCE(pt.END_YEAR, pt.START_YEAR) DESC,
            pt.START_YEAR DESC,
            pt.PAYER
    ) AS latest_payer_period_rank
FROM synthea.payer_transitions AS pt
INNER JOIN analytics.synthea_patient_risk_flags AS rf
    ON pt.PATIENT = rf.patient_id
   AND rf.risk_flag_count > 0
LEFT JOIN synthea.payers AS py
    ON pt.PAYER = py."Id";

-- @block 6. Validate target-patient payer history
SELECT
    COUNT(*) AS history_rows,
    COUNT(DISTINCT patient_id) AS target_patients_with_history,
    COUNT_IF(latest_payer_period_rank = 1) AS latest_period_rows,
    COUNT_IF(no_insurance_flag = 1) AS uninsured_period_rows,
    COUNT_IF(recorded_coverage_years < 0) AS negative_coverage_year_rows
FROM analytics.synthea_target_patient_payer_history;

-- @block 7. Reconcile payer history to target cohort
SELECT
    (
        SELECT COUNT(DISTINCT patient_id)
        FROM analytics.synthea_target_patient_payer_history
    ) AS target_patients_with_payer_history,
    (
        SELECT COUNT(DISTINCT patient_id)
        FROM analytics.synthea_patient_risk_flags
        WHERE risk_flag_count > 0
    ) AS expected_target_patients,
    (
        SELECT COUNT(DISTINCT patient_id)
        FROM analytics.synthea_patient_risk_flags
        WHERE risk_flag_count > 0
    )
    -
    (
        SELECT COUNT(DISTINCT patient_id)
        FROM analytics.synthea_target_patient_payer_history
    ) AS target_patients_without_payer_history;

-- @block 8. Create latest recorded payer mart
-- Grain: one row per latest recorded payer
CREATE OR REPLACE TABLE mart.latest_recorded_payer_mix AS
WITH latest_patient_payer AS (
    SELECT
        patient_id,
        payer_id,
        payer_name,
        no_insurance_flag,
        coverage_ownership,
        coverage_start_year,
        coverage_end_year
    FROM analytics.synthea_target_patient_payer_history
    WHERE latest_payer_period_rank = 1
),
payer_summary AS (
    SELECT
        payer_id,
        payer_name,
        no_insurance_flag,
        COUNT(DISTINCT patient_id) AS unique_target_patients,
        COUNT(DISTINCT coverage_ownership) AS ownership_categories,
        MIN(coverage_start_year) AS earliest_latest_period_start_year,
        MAX(coverage_end_year) AS latest_period_end_year
    FROM latest_patient_payer
    GROUP BY payer_id, payer_name, no_insurance_flag
)
SELECT
    payer_id,
    payer_name,
    no_insurance_flag,
    unique_target_patients,
    ROUND(
        100.0 * unique_target_patients
        / NULLIF(SUM(unique_target_patients) OVER (), 0),
        2
    ) AS share_of_target_patients_pct,
    ownership_categories,
    earliest_latest_period_start_year,
    latest_period_end_year,
    DENSE_RANK() OVER (
        ORDER BY unique_target_patients DESC
    ) AS payer_mix_rank
FROM payer_summary;

-- @block 9. Validate latest recorded payer mix
SELECT
    SUM(unique_target_patients) AS summed_latest_payer_patients,
    (
        SELECT COUNT(DISTINCT patient_id)
        FROM analytics.synthea_target_patient_payer_history
    ) AS expected_target_patients,
    SUM(unique_target_patients)
    -
    (
        SELECT COUNT(DISTINCT patient_id)
        FROM analytics.synthea_target_patient_payer_history
    ) AS reconciliation_difference,
    ROUND(SUM(share_of_target_patients_pct), 2) AS summed_share_pct
FROM mart.latest_recorded_payer_mix;

-- @block 10. Preview latest payer mix
SELECT *
FROM mart.latest_recorded_payer_mix
ORDER BY payer_mix_rank, payer_name;

-- @block 11. Create payer encounter-opportunity mart
-- Grain: one row per payer appearing on target-patient encounters
CREATE OR REPLACE TABLE mart.payer_encounter_opportunity AS
WITH payer_encounter_summary AS (
    SELECT
        e.payer_id,
        COALESCE(py.NAME, 'Unknown payer') AS payer_name,
        CASE
            WHEN REPLACE(UPPER(COALESCE(py.NAME, '')), '_', ' ') = 'NO INSURANCE'
                THEN 1
            ELSE 0
        END AS no_insurance_flag,
        COUNT(DISTINCT e.patient_id) AS unique_target_patients,
        COUNT(DISTINCT e.encounter_id) AS all_encounters_for_target_patients,
        COUNT(DISTINCT CASE
            WHEN e.target_condition_encounter_flag = 1
                THEN e.encounter_id
        END) AS target_condition_encounters,
        COUNT(DISTINCT e.organization_id) AS organizations_reached,
        COUNT(DISTINCT e.provider_id) AS providers_reached,
        COUNT(DISTINCT CASE
            WHEN e.anemia_diagnosis_flag = 1 THEN e.patient_id
        END) AS anemia_segment_patients,
        COUNT(DISTINCT CASE
            WHEN e.pregnancy_related_flag = 1 THEN e.patient_id
        END) AS pregnancy_segment_patients,
        COUNT(DISTINCT CASE
            WHEN e.kidney_renal_risk_flag = 1 THEN e.patient_id
        END) AS kidney_segment_patients,
        COUNT(DISTINCT CASE
            WHEN e.heart_failure_flag = 1 THEN e.patient_id
        END) AS heart_failure_segment_patients,
        ROUND(SUM(e.synthea_total_claim_cost), 2)
            AS synthea_total_claim_cost_qa,
        ROUND(SUM(e.synthea_payer_coverage), 2)
            AS synthea_payer_coverage_qa
    FROM analytics.synthea_target_encounter_mart AS e
    LEFT JOIN synthea.payers AS py
        ON e.payer_id = py."Id"
    GROUP BY e.payer_id, payer_name, no_insurance_flag
)
SELECT
    *,
    ROUND(
        100.0 * unique_target_patients
        / NULLIF(
            (
                SELECT COUNT(DISTINCT patient_id)
                FROM analytics.synthea_target_encounter_mart
            ),
            0
        ),
        2
    ) AS share_of_target_patients_with_any_encounter_pct,
    ROUND(
        100.0 * all_encounters_for_target_patients
        / NULLIF(SUM(all_encounters_for_target_patients) OVER (), 0),
        2
    ) AS share_of_target_encounters_pct,
    ROUND(
        100.0 * target_condition_encounters
        / NULLIF(SUM(target_condition_encounters) OVER (), 0),
        2
    ) AS share_of_target_condition_encounters_pct,
    ROUND(
        100.0 * synthea_payer_coverage_qa
        / NULLIF(synthea_total_claim_cost_qa, 0),
        2
    ) AS diagnostic_coverage_to_claim_cost_pct_qa,
    DENSE_RANK() OVER (
        ORDER BY unique_target_patients DESC
    ) AS payer_patient_opportunity_rank,
    DENSE_RANK() OVER (
        ORDER BY target_condition_encounters DESC
    ) AS payer_target_encounter_rank
FROM payer_encounter_summary;

-- @block 12. Validate payer encounter opportunity
SELECT
    COUNT(*) AS payer_rows,
    SUM(unique_target_patients) AS summed_payer_patient_memberships,
    (
        SELECT COUNT(DISTINCT patient_id)
        FROM analytics.synthea_target_encounter_mart
    ) AS unique_target_patients,
    SUM(all_encounters_for_target_patients) AS summed_encounters,
    (
        SELECT COUNT(DISTINCT encounter_id)
        FROM analytics.synthea_target_encounter_mart
    ) AS expected_encounters,
    ROUND(SUM(share_of_target_encounters_pct), 2)
        AS summed_encounter_share_pct
FROM mart.payer_encounter_opportunity;

-- @block 13. Preview payer encounter opportunity
SELECT
    payer_patient_opportunity_rank,
    payer_target_encounter_rank,
    payer_name,
    no_insurance_flag,
    unique_target_patients,
    share_of_target_patients_with_any_encounter_pct,
    all_encounters_for_target_patients,
    share_of_target_encounters_pct,
    target_condition_encounters,
    share_of_target_condition_encounters_pct,
    organizations_reached,
    providers_reached,
    anemia_segment_patients,
    pregnancy_segment_patients,
    kidney_segment_patients,
    heart_failure_segment_patients,
    diagnostic_coverage_to_claim_cost_pct_qa
FROM mart.payer_encounter_opportunity
ORDER BY payer_patient_opportunity_rank, payer_name;

-- @block 14. Create uninsured-exposure mart
-- Grain: one row containing cohort-level access indicators
CREATE OR REPLACE TABLE mart.uninsured_exposure_summary AS
WITH patient_uninsured_summary AS (
    SELECT
        patient_id,
        MAX(no_insurance_flag) AS ever_uninsured_flag,
        MAX(
            CASE
                WHEN latest_payer_period_rank = 1
                    THEN no_insurance_flag
                ELSE 0
            END
        ) AS latest_recorded_uninsured_flag,
        SUM(
            CASE
                WHEN no_insurance_flag = 1
                    THEN COALESCE(recorded_coverage_years, 0)
                ELSE 0
            END
        ) AS recorded_uninsured_years,
        COUNT(DISTINCT payer_id) AS distinct_recorded_payers
    FROM analytics.synthea_target_patient_payer_history
    GROUP BY patient_id
)
SELECT
    COUNT(*) AS target_patients_with_payer_history,
    SUM(ever_uninsured_flag) AS patients_ever_uninsured,
    ROUND(
        100.0 * SUM(ever_uninsured_flag) / NULLIF(COUNT(*), 0),
        2
    ) AS patients_ever_uninsured_pct,
    SUM(latest_recorded_uninsured_flag)
        AS patients_latest_recorded_uninsured,
    ROUND(
        100.0 * SUM(latest_recorded_uninsured_flag)
        / NULLIF(COUNT(*), 0),
        2
    ) AS patients_latest_recorded_uninsured_pct,
    ROUND(
        AVG(
            CASE
                WHEN ever_uninsured_flag = 1
                    THEN recorded_uninsured_years
            END
        ),
        2
    ) AS average_recorded_uninsured_years_among_ever_uninsured,
    ROUND(
        MEDIAN(
            CASE
                WHEN ever_uninsured_flag = 1
                    THEN recorded_uninsured_years
            END
        ),
        2
    ) AS median_recorded_uninsured_years_among_ever_uninsured,
    ROUND(AVG(distinct_recorded_payers), 2)
        AS average_distinct_recorded_payers_per_patient
FROM patient_uninsured_summary;

-- @block 15. Preview uninsured exposure
SELECT *
FROM mart.uninsured_exposure_summary;

-- @block 16. Create ownership mix for latest recorded coverage
CREATE OR REPLACE TABLE mart.latest_coverage_ownership_mix AS
WITH latest_patient_payer AS (
    SELECT
        patient_id,
        coverage_ownership
    FROM analytics.synthea_target_patient_payer_history
    WHERE latest_payer_period_rank = 1
)
SELECT
    coverage_ownership,
    COUNT(DISTINCT patient_id) AS unique_target_patients,
    ROUND(
        100.0 * COUNT(DISTINCT patient_id)
        / NULLIF(
            SUM(COUNT(DISTINCT patient_id)) OVER (),
            0
        ),
        2
    ) AS share_of_target_patients_pct
FROM latest_patient_payer
GROUP BY coverage_ownership;

-- @block 17. Preview ownership mix
SELECT *
FROM mart.latest_coverage_ownership_mix
ORDER BY unique_target_patients DESC;

-- @block 18. Export Tableau-ready latest payer mix
COPY mart.latest_recorded_payer_mix
TO 'outputs/marts/latest_recorded_payer_mix.csv'
WITH (HEADER true, DELIMITER ',');

-- @block 19. Export Tableau-ready payer encounter opportunity
COPY mart.payer_encounter_opportunity
TO 'outputs/marts/payer_encounter_opportunity.csv'
WITH (HEADER true, DELIMITER ',');

-- @block 20. Export Tableau-ready uninsured exposure summary
COPY mart.uninsured_exposure_summary
TO 'outputs/marts/uninsured_exposure_summary.csv'
WITH (HEADER true, DELIMITER ',');

-- @block 21. Export Tableau-ready ownership mix
COPY mart.latest_coverage_ownership_mix
TO 'outputs/marts/latest_coverage_ownership_mix.csv'
WITH (HEADER true, DELIMITER ',');


-- @block Correctly compare encounter and transition uninsured indicators

WITH encounter_status AS (

    SELECT
        e.patient_id,

        MAX(
            CASE
                WHEN REPLACE(
                    UPPER(COALESCE(py.NAME, '')),
                    '_',
                    ' '
                ) = 'NO INSURANCE'
                    THEN 1
                ELSE 0
            END
        ) AS uninsured_encounter_flag

    FROM analytics.synthea_target_encounter_mart AS e

    LEFT JOIN synthea.payers AS py
        ON e.payer_id = py."Id"

    GROUP BY
        e.patient_id
),

transition_status AS (

    SELECT
        patient_id,
        MAX(no_insurance_flag)
            AS uninsured_transition_flag

    FROM analytics.synthea_target_patient_payer_history

    GROUP BY
        patient_id
),

patient_status AS (

    SELECT
        rf.patient_id,

        COALESCE(
            e.uninsured_encounter_flag,
            0
        ) AS uninsured_encounter_flag,

        COALESCE(
            t.uninsured_transition_flag,
            0
        ) AS uninsured_transition_flag

    FROM analytics.synthea_patient_risk_flags AS rf

    LEFT JOIN encounter_status AS e
        ON rf.patient_id = e.patient_id

    LEFT JOIN transition_status AS t
        ON rf.patient_id = t.patient_id

    WHERE rf.risk_flag_count > 0
)

SELECT
    uninsured_encounter_flag,
    uninsured_transition_flag,
    COUNT(*) AS unique_patients

FROM patient_status

GROUP BY
    1,
    2

ORDER BY
    1,
    2;