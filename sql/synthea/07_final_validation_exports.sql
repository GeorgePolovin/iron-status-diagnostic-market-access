-- ============================================================
-- a07_final_validation_exports.sql
--
-- PURPOSE
-- -------
-- Final QA and handoff layer for the market-access /
-- provider-group analytics project.
--
-- This file does NOT create new clinical assumptions. It verifies that
-- the major marts built in a03-a06 preserve their intended grains,
-- reconcile to the expected target cohort, and are ready for Tableau.
--
-- FINAL BUSINESS STORY SUPPORTED BY THE SQL
-- -----------------------------------------
-- UNMET NEED
--   - Define overlapping clinical-risk populations.
--   - Quantify target-patient volume and utilization patterns.
--   - Preserve the distinction between anemia and iron deficiency.
--
-- PROVIDER / ADOPTION
--   - Identify organizations with concentrated target-patient volume.
--   - Identify the care settings where target-condition encounters occur.
--   - Show that CBC/red-cell workflows exist in the synthetic record.
--
-- PAYER / ACCESS
--   - Describe the last observed synthetic payer-period mix.
--   - Quantify recorded uninsured history.
--   - Separate patient coverage history from encounter-level payer fields.
--
-- ECONOMIC HYPOTHESIS
--   - Compare fixed 365-day utilization before and after segment diagnosis.
--   - Use this only to motivate later real-world MEPS economic analysis.
--
-- DATASET ROLES
-- -------------
--   Synthea = synthetic longitudinal workflow / provider / payer analysis
--   NHANES  = real laboratory-defined unmet need
--   MEPS    = real utilization / expenditure / insurance burden
--
-- IMPORTANT LIMITATIONS
-- ---------------------
--   1. Synthea is synthetic and should not be presented as real-world
--      prevalence, testing rates, reimbursement, or economic burden.
--   2. Ferritin / iron-study observations are absent from this export.
--      That is a dataset limitation, not proof of a real-world testing gap.
--   3. Anemia diagnosis is not specific to iron deficiency.
--   4. Overlapping risk-segment patient counts must not be summed as if
--      they were mutually exclusive.
--   5. Synthetic cost and payer-coverage fields are excluded from final
--      commercial conclusions because earlier QA showed implausible ratios.
--
-- OUTPUTS
-- -------
--   mart.final_validation_summary
--   mart.dashboard_kpi_summary
--   mart.dashboard_data_manifest
--
--   outputs/qa/final_validation_summary.csv
--   outputs/tableau/dashboard_kpi_summary.csv
--   outputs/qa/dashboard_data_manifest.csv
--
-- ============================================================


-- ============================================================
-- BLOCK 1 — ENVIRONMENT CHECK
--
-- PURPOSE:
-- Confirm the active database and create output schemas if needed.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS mart;

SELECT
    current_database() AS database_name,
    current_schema() AS active_schema,
    version() AS duckdb_version;


-- ============================================================
-- BLOCK 2 — CONFIRM REQUIRED ANALYTICAL OBJECTS EXIST
--
-- PURPOSE:
-- Verify that all major upstream tables/marts needed for the final
-- dashboard and QA layer are present.
--
-- EXPECTED:
-- Every required object should return exactly one row below.
-- ============================================================

WITH required_objects AS (

    SELECT *
    FROM (
        VALUES
            ('analytics', 'synthea_patient_risk_flags'),
            ('analytics', 'synthea_target_encounter_mart'),
            ('analytics', 'synthea_target_patient_payer_history'),
            ('analytics', 'synthea_target_segment_index_date'),
            ('analytics', 'synthea_target_encounter_workflow_signals'),
            ('mart', 'risk_segment_clinical_opportunity'),
            ('mart', 'organization_opportunity'),
            ('mart', 'provider_opportunity'),
            ('mart', 'target_market_by_city'),
            ('mart', 'latest_recorded_payer_mix'),
            ('mart', 'payer_encounter_opportunity'),
            ('mart', 'uninsured_exposure_summary'),
            ('mart', 'utilization_pathway_by_segment'),
            ('mart', 'target_condition_encounter_setting'),
            ('mart', 'workflow_signal_by_segment')
    ) AS t(table_schema, table_name)
),

available_objects AS (

    SELECT
        table_schema,
        table_name
    FROM information_schema.tables
)

SELECT
    r.table_schema,
    r.table_name,

    CASE
        WHEN a.table_name IS NOT NULL
            THEN 'PASS'
        ELSE 'MISSING'
    END AS object_status

FROM required_objects AS r

LEFT JOIN available_objects AS a
    ON r.table_schema = a.table_schema
   AND r.table_name = a.table_name

ORDER BY
    r.table_schema,
    r.table_name;


-- ============================================================
-- BLOCK 3 — CREATE FINAL VALIDATION SUMMARY
--
-- PURPOSE:
-- Put the most important grain and reconciliation checks into one
-- compact QA table.
--
-- GRAIN:
--   one row per QA check
--
-- STATUS:
--   PASS = expected relationship holds
--   REVIEW = result requires attention before dashboard use
--
-- NOTE:
-- A few expected counts are dataset-specific because this analysis is
-- being finalized against the current Synthea export:
--   563 unique target patients
--   726 patient-segment memberships
--   36,706 target-patient encounters
--   1,143 target-condition encounters
-- ============================================================

CREATE OR REPLACE TABLE mart.final_validation_summary AS

WITH target_cohort AS (

    SELECT
        COUNT(DISTINCT patient_id) AS unique_target_patients
    FROM analytics.synthea_patient_risk_flags
    WHERE risk_flag_count > 0
),

segment_membership AS (

    SELECT
        COUNT(*) AS patient_segment_memberships,
        COUNT(
            DISTINCT patient_id || '|' || risk_segment
        ) AS unique_patient_segment_memberships
    FROM analytics.synthea_target_segment_index_date
),

target_encounters AS (

    SELECT
        COUNT(*) AS encounter_rows,
        COUNT(DISTINCT encounter_id) AS unique_encounters,
        COUNT_IF(target_condition_encounter_flag = 1)
            AS target_condition_encounters
    FROM analytics.synthea_target_encounter_mart
),

organization_qa AS (

    SELECT
        COUNT(*) AS organization_rows,
        COUNT(DISTINCT organization_id) AS unique_organizations
    FROM mart.organization_opportunity
),

latest_payer AS (

    SELECT
        SUM(unique_target_patients) AS summed_latest_payer_patients,
        SUM(share_of_target_patients_pct) AS summed_latest_payer_share
    FROM mart.latest_recorded_payer_mix
),

payer_history AS (

    SELECT
        COUNT(DISTINCT patient_id) AS patients_with_payer_history
    FROM analytics.synthea_target_patient_payer_history
),

payer_encounter AS (

    SELECT
        SUM(share_of_target_encounters_pct)
            AS summed_payer_encounter_share
    FROM mart.payer_encounter_opportunity
),

segment_pathway AS (

    SELECT
        COUNT(*) AS pathway_rows,
        COUNT(
            DISTINCT patient_id || '|' || risk_segment
        ) AS unique_pathway_rows
    FROM mart.segment_patient_pathway_summary
),

workflow_encounter AS (

    SELECT
        COUNT(*) AS workflow_rows,
        COUNT(DISTINCT encounter_id) AS unique_workflow_encounters
    FROM analytics.synthea_target_encounter_workflow_signals
),

segment_marts AS (

    SELECT
        (SELECT COUNT(*) FROM mart.utilization_pathway_by_segment)
            AS utilization_segment_rows,

        (SELECT COUNT(*) FROM mart.workflow_signal_by_segment)
            AS workflow_segment_rows
),

setting_share AS (

    SELECT
        SUM(share_of_target_condition_encounters_pct)
            AS summed_setting_share_pct
    FROM mart.target_condition_encounter_setting
),

hematology AS (

    SELECT
        COUNT(DISTINCT patient_id)
            AS target_patients_with_cbc_signal
    FROM analytics.synthea_target_hematology_observation_events
),

iron_studies AS (

    SELECT
        COUNT(*) AS iron_study_rows
    FROM synthea.observations
    WHERE REGEXP_MATCHES(
        LOWER(COALESCE(DESCRIPTION, '')),
        'ferritin|transferrin|iron binding|total iron binding|tibc|serum iron|iron saturation|transferrin saturation|(^|[^a-z])iron([^a-z]|$)'
    )
)

SELECT
    1 AS check_order,
    'Unique target patients' AS check_name,
    CAST(unique_target_patients AS VARCHAR) AS observed_value,
    '563' AS expected_value,
    CASE
        WHEN unique_target_patients = 563 THEN 'PASS'
        ELSE 'REVIEW'
    END AS status
FROM target_cohort

UNION ALL

SELECT
    2,
    'Patient-segment membership grain',
    CAST(patient_segment_memberships AS VARCHAR),
    '726 memberships; no duplicate patient-segment rows',
    CASE
        WHEN patient_segment_memberships = 726
         AND patient_segment_memberships = unique_patient_segment_memberships
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM segment_membership

UNION ALL

SELECT
    3,
    'Target encounter mart grain',
    CAST(encounter_rows AS VARCHAR),
    '36,706 rows = 36,706 unique encounters',
    CASE
        WHEN encounter_rows = 36706
         AND encounter_rows = unique_encounters
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM target_encounters

UNION ALL

SELECT
    4,
    'Target-condition encounter count',
    CAST(target_condition_encounters AS VARCHAR),
    '1,143',
    CASE
        WHEN target_condition_encounters = 1143
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM target_encounters

UNION ALL

SELECT
    5,
    'Organization mart grain',
    CAST(organization_rows AS VARCHAR),
    'One row per organization',
    CASE
        WHEN organization_rows = unique_organizations
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM organization_qa

UNION ALL

SELECT
    6,
    'Latest payer mix reconciliation',
    CAST(summed_latest_payer_patients AS VARCHAR),
    CAST(patients_with_payer_history AS VARCHAR)
        || ' patients with payer history',
    CASE
        WHEN summed_latest_payer_patients = patients_with_payer_history
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM latest_payer
CROSS JOIN payer_history

UNION ALL

SELECT
    7,
    'Latest payer mix share',
    CAST(ROUND(summed_latest_payer_share, 2) AS VARCHAR) || '%',
    'Approximately 100%',
    CASE
        WHEN summed_latest_payer_share BETWEEN 99.95 AND 100.05
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM latest_payer

UNION ALL

SELECT
    8,
    'Payer encounter share',
    CAST(ROUND(summed_payer_encounter_share, 2) AS VARCHAR) || '%',
    'Approximately 100%',
    CASE
        WHEN summed_payer_encounter_share BETWEEN 99.95 AND 100.05
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM payer_encounter

UNION ALL

SELECT
    9,
    'Patient-segment pathway grain',
    CAST(pathway_rows AS VARCHAR),
    'One row per patient + risk segment',
    CASE
        WHEN pathway_rows = unique_pathway_rows
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM segment_pathway

UNION ALL

SELECT
    10,
    'Encounter workflow mart grain',
    CAST(workflow_rows AS VARCHAR),
    'One row per encounter',
    CASE
        WHEN workflow_rows = unique_workflow_encounters
         AND workflow_rows = 36706
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM workflow_encounter

UNION ALL

SELECT
    11,
    'Utilization segment mart',
    CAST(utilization_segment_rows AS VARCHAR),
    '4 risk segments',
    CASE
        WHEN utilization_segment_rows = 4
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM segment_marts

UNION ALL

SELECT
    12,
    'Workflow segment mart',
    CAST(workflow_segment_rows AS VARCHAR),
    '4 risk segments',
    CASE
        WHEN workflow_segment_rows = 4
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM segment_marts

UNION ALL

SELECT
    13,
    'Encounter-setting share',
    CAST(ROUND(summed_setting_share_pct, 2) AS VARCHAR) || '%',
    'Approximately 100%',
    CASE
        WHEN summed_setting_share_pct BETWEEN 99.95 AND 100.05
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM setting_share

UNION ALL

SELECT
    14,
    'Target patients with CBC/red-cell signal',
    CAST(target_patients_with_cbc_signal AS VARCHAR),
    '563 synthetic target patients',
    CASE
        WHEN target_patients_with_cbc_signal = 563
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM hematology

UNION ALL

SELECT
    15,
    'Ferritin / iron-study observation availability',
    CAST(iron_study_rows AS VARCHAR),
    '0 rows expected in this Synthea export',
    CASE
        WHEN iron_study_rows = 0
            THEN 'PASS'
        ELSE 'REVIEW'
    END
FROM iron_studies;


-- ============================================================
-- BLOCK 4 — REVIEW FINAL VALIDATION SUMMARY
--
-- PURPOSE:
-- This should be the final QA gate before Tableau.
--
-- EXPECTED:
-- Every row should have status = PASS.
-- ============================================================

SELECT *
FROM mart.final_validation_summary
ORDER BY check_order;


-- ============================================================
-- BLOCK 5 — CREATE EXECUTIVE DASHBOARD KPI SUMMARY
--
-- PURPOSE:
-- Create a small Tableau-ready KPI table containing only metrics that
-- are defensible within the context of the synthetic analysis.
--
-- GRAIN:
--   one row per KPI
--
-- IMPORTANT:
-- These are descriptive metrics from Synthea, not real-world market
-- size or economic estimates.
-- ============================================================

CREATE OR REPLACE TABLE mart.dashboard_kpi_summary AS

SELECT
    1 AS display_order,
    'Target patients' AS metric_name,
    CAST(
        COUNT(DISTINCT patient_id)
        AS DOUBLE
    ) AS metric_value,
    'patients' AS metric_unit,
    'Synthetic target cohort; clinical segments overlap'
        AS interpretation
FROM analytics.synthea_patient_risk_flags
WHERE risk_flag_count > 0

UNION ALL

SELECT
    2,
    'Clinical segment memberships',
    CAST(COUNT(*) AS DOUBLE),
    'memberships',
    'Overlapping anemia, pregnancy, kidney/renal, and CHF segments'
FROM analytics.synthea_target_segment_index_date

UNION ALL

SELECT
    3,
    'Target-condition encounters',
    CAST(
        COUNT_IF(target_condition_encounter_flag = 1)
        AS DOUBLE
    ),
    'encounters',
    'Mapped target-condition encounters in synthetic longitudinal history'
FROM analytics.synthea_target_encounter_mart

UNION ALL

SELECT
    4,
    'Patients with payer history',
    CAST(
        COUNT(DISTINCT patient_id)
        AS DOUBLE
    ),
    'patients',
    'Patients with at least one recorded synthetic payer-transition period'
FROM analytics.synthea_target_patient_payer_history

UNION ALL

SELECT
    5,
    'Ever recorded uninsured',
    CAST(patients_ever_uninsured_pct AS DOUBLE),
    'percent',
    'Share of target patients with payer history who had at least one recorded uninsured period'
FROM mart.uninsured_exposure_summary

UNION ALL

SELECT
    6,
    'Last observed period uninsured',
    CAST(patients_latest_recorded_uninsured_pct AS DOUBLE),
    'percent',
    'Synthetic last-observed payer period; not current insurance status'
FROM mart.uninsured_exposure_summary

UNION ALL

SELECT
    7,
    'Ambulatory + wellness target encounters',
    CAST(
        SUM(
            CASE
                WHEN encounter_class IN ('ambulatory', 'wellness')
                    THEN share_of_target_condition_encounters_pct
                ELSE 0
            END
        )
        AS DOUBLE
    ),
    'percent',
    'Share of mapped target-condition encounters occurring in routine ambulatory/wellness settings'
FROM mart.target_condition_encounter_setting;


-- ============================================================
-- BLOCK 6 — REVIEW EXECUTIVE KPI SUMMARY
--
-- PURPOSE:
-- Check that the small KPI table contains only clearly interpretable
-- synthetic metrics before exporting to Tableau.
-- ============================================================

SELECT *
FROM mart.dashboard_kpi_summary
ORDER BY display_order;


-- ============================================================
-- BLOCK 7 — CREATE DASHBOARD DATA MANIFEST
--
-- PURPOSE:
-- Document which dataset powers each planned visualization, its grain,
-- the business question it answers, and how prominently it should be
-- used in the final dashboard.
--
-- This functions as a compact handoff/reference while building Tableau.
-- ============================================================

CREATE OR REPLACE TABLE mart.dashboard_data_manifest AS

SELECT *
FROM (
    VALUES
        (
            1,
            'Patient Segment Opportunity',
            'mart.risk_segment_clinical_opportunity',
            'One row per overlapping clinical risk segment',
            'Unmet need / segmentation',
            'Which clinical populations create the largest potential diagnostic opportunity?',
            'HEADLINE'
        ),
        (
            2,
            'Top Provider Organizations',
            'mart.organization_opportunity',
            'One row per organization',
            'Provider-group targeting',
            'Which organizations encounter the greatest number of target patients?',
            'HEADLINE'
        ),
        (
            3,
            'Organization Opportunity Matrix',
            'mart.organization_opportunity',
            'One row per organization',
            'Provider-group targeting',
            'Which organizations combine high target-patient volume with high target-condition encounter volume?',
            'HEADLINE'
        ),
        (
            4,
            'Last Observed Payer-Period Mix',
            'mart.latest_recorded_payer_mix',
            'One row per payer',
            'Access',
            'How fragmented is the last observed synthetic payer mix among target patients with payer history?',
            'HEADLINE'
        ),
        (
            5,
            'Payer Target-Condition Encounters',
            'mart.payer_encounter_opportunity',
            'One row per payer',
            'Access / adoption',
            'Which payers touch the greatest number of target-condition encounters?',
            'SUPPORTING'
        ),
        (
            6,
            'Recorded Uninsured Exposure',
            'mart.uninsured_exposure_summary',
            'One row for the target cohort',
            'Access',
            'How many target patients had a recorded uninsured coverage period?',
            'SUPPORTING'
        ),
        (
            7,
            'Utilization Around Segment Diagnosis',
            'mart.utilization_pathway_by_segment',
            'One row per overlapping clinical risk segment',
            'Economic hypothesis',
            'How does 365-day utilization change before versus after the first segment-specific diagnosis?',
            'HEADLINE'
        ),
        (
            8,
            'Target Encounters by Care Setting',
            'mart.target_condition_encounter_setting',
            'One row per encounter class',
            'Adoption / workflow',
            'Where do mapped target-condition encounters occur?',
            'HEADLINE'
        ),
        (
            9,
            'CBC / Iron-Treatment Workflow',
            'mart.workflow_signal_by_segment',
            'One row per overlapping clinical risk segment',
            'Workflow',
            'Which target segments interact with CBC/red-cell and iron-treatment workflows?',
            'APPENDIX'
        ),
        (
            10,
            'City Concentration',
            'mart.target_market_by_city',
            'One row per city',
            'Geographic concentration',
            'Where are synthetic target-patient encounters geographically concentrated?',
            'SUPPORTING'
        ),
        (
            11,
            'Provider Detail',
            'mart.provider_opportunity',
            'One row per provider-within-organization',
            'Drill-down',
            'Which individual synthetic providers appear within higher-opportunity organizations?',
            'APPENDIX'
        )
) AS t(
    display_order,
    visualization_name,
    source_table,
    source_grain,
    commercial_theme,
    business_question,
    recommended_use
);


-- ============================================================
-- BLOCK 8 — REVIEW DASHBOARD DATA MANIFEST
--
-- PURPOSE:
-- Confirm the final dashboard source plan before returning to Tableau.
-- ============================================================

SELECT *
FROM mart.dashboard_data_manifest
ORDER BY display_order;


-- ============================================================
-- BLOCK 9 — EXPORT FINAL VALIDATION SUMMARY
--
-- PURPOSE:
-- Save the final QA report.
-- ============================================================

COPY mart.final_validation_summary
TO 'outputs/qa/final_validation_summary.csv'
WITH (
    HEADER true,
    DELIMITER ','
);


-- ============================================================
-- BLOCK 10 — EXPORT EXECUTIVE KPI SUMMARY
--
-- PURPOSE:
-- Save the Tableau-ready KPI card source.
-- ============================================================

COPY mart.dashboard_kpi_summary
TO 'outputs/marts/dashboard_kpi_summary.csv'
WITH (
    HEADER true,
    DELIMITER ','
);


-- ============================================================
-- BLOCK 11 — EXPORT DASHBOARD DATA MANIFEST
--
-- PURPOSE:
-- Save a compact reference describing the final visualization plan,
-- source grain, and business question for each chart.
-- ============================================================

COPY mart.dashboard_data_manifest
TO 'outputs/qa/dashboard_data_manifest.csv'
WITH (
    HEADER true,
    DELIMITER ','
);


-- ============================================================
-- BLOCK 12 — FINAL SQL-PHASE COMPLETION CHECK
--
-- PURPOSE:
-- Return a one-row go/no-go result.
--
-- SQL_COMPLETE = YES only when every final validation check passes.
-- ============================================================

SELECT
    COUNT(*) AS total_validation_checks,

    COUNT_IF(status = 'PASS')
        AS passed_validation_checks,

    COUNT_IF(status <> 'PASS')
        AS checks_requiring_review,

    CASE
        WHEN COUNT_IF(status <> 'PASS') = 0
            THEN 'YES'
        ELSE 'NO'
    END AS sql_phase_complete

FROM mart.final_validation_summary;
