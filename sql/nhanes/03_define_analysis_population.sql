-- ============================================================
-- 03_define_analysis_population.sql
--
-- PURPOSE
-- -------
-- Create a clean NHANES participant-level analysis table for the
-- unmet-need project.
--
-- PRIMARY OBJECTIVE
-- -----------------
-- Build a defensible denominator containing participants with:
--   - a measured ferritin value
--   - a measured hemoglobin value
--   - demographic variables
--   - NHANES survey-design variables
--
-- IMPORTANT
-- ---------
-- This file DOES NOT define:
--   - low ferritin
--   - anemia
--   - iron deficiency
--   - low ferritin without anemia
--
-- Those clinical definitions belong in later analysis files.
--
-- SOURCE GRAIN
-- ------------
-- Each raw NHANES source table has one row per participant (SEQN).
--
-- OUTPUT GRAIN
-- ------------
-- analytics.nhanes_core_analysis_population
--   = one row per participant with non-missing ferritin + hemoglobin.
--
-- JOIN KEY
-- --------
-- SEQN = NHANES respondent sequence number.
--
-- ============================================================


-- ============================================================
-- BLOCK 1 — CREATE ANALYTICS SCHEMA
--
-- PURPOSE:
-- Keep cleaned analytical tables separate from untouched NHANES
-- source tables in the nhanes schema.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS analytics;


-- ============================================================
-- BLOCK 2 — CREATE CORE NHANES ANALYSIS POPULATION
--
-- PURPOSE:
-- Join demographics, ferritin, and CBC data into one participant-level
-- table and retain only participants with BOTH ferritin and hemoglobin.
--
-- GRAIN:
-- One row per participant.
--
-- WHY THESE TWO LABS ARE REQUIRED:
-- Ferritin is needed to evaluate iron stores.
-- Hemoglobin is needed later to distinguish low ferritin with versus
-- without anemia.
--
-- NOTE:
-- SEQN is renamed patient_id only in the analytical layer for easier
-- reading. Raw NHANES tables keep the original variable name.
-- ============================================================

CREATE OR REPLACE TABLE analytics.nhanes_core_analysis_population AS

SELECT
    d.SEQN AS patient_id,

    -- Demographics
    CAST(d.RIAGENDR AS INTEGER) AS sex_code,

    CASE
        WHEN d.RIAGENDR = 1 THEN 'Male'
        WHEN d.RIAGENDR = 2 THEN 'Female'
        ELSE 'Unknown'
    END AS sex,

    CAST(d.RIDAGEYR AS INTEGER) AS age_years,

    CASE
        WHEN d.RIDAGEYR < 12 THEN 'Under 12'
        WHEN d.RIDAGEYR BETWEEN 12 AND 17 THEN '12-17'
        WHEN d.RIDAGEYR BETWEEN 18 AND 29 THEN '18-29'
        WHEN d.RIDAGEYR BETWEEN 30 AND 44 THEN '30-44'
        WHEN d.RIDAGEYR BETWEEN 45 AND 64 THEN '45-64'
        ELSE '65+'
    END AS age_group,

    -- Useful population flags.
    -- These are descriptive eligibility flags, NOT claims that a person
    -- is menstruating, physically active, or otherwise clinically at risk.
    CASE
        WHEN d.RIDAGEYR >= 18 THEN 1
        ELSE 0
    END AS adult_18_plus_flag,

    CASE
        WHEN d.RIAGENDR = 2
         AND d.RIDAGEYR BETWEEN 18 AND 49
            THEN 1
        ELSE 0
    END AS female_18_49_flag,

    CASE
        WHEN d.RIAGENDR = 2
         AND d.RIDAGEYR BETWEEN 20 AND 44
            THEN 1
        ELSE 0
    END AS female_20_44_flag,

    -- Pregnancy status is publicly released only for females 20-44.
    CAST(d.RIDEXPRG AS INTEGER) AS pregnancy_status_code,

    CASE
        WHEN d.RIDEXPRG = 1 THEN 'Pregnant'
        WHEN d.RIDEXPRG = 2 THEN 'Not pregnant'
        WHEN d.RIDEXPRG = 3 THEN 'Cannot ascertain'
        ELSE 'Not publicly available / not applicable'
    END AS pregnancy_status,

    -- Race / Hispanic origin using RIDRETH3 because it includes
    -- a separate Non-Hispanic Asian category.
    CAST(d.RIDRETH3 AS INTEGER) AS race_ethnicity_code,

    CASE
        WHEN d.RIDRETH3 = 1 THEN 'Mexican American'
        WHEN d.RIDRETH3 = 2 THEN 'Other Hispanic'
        WHEN d.RIDRETH3 = 3 THEN 'Non-Hispanic White'
        WHEN d.RIDRETH3 = 4 THEN 'Non-Hispanic Black'
        WHEN d.RIDRETH3 = 6 THEN 'Non-Hispanic Asian'
        WHEN d.RIDRETH3 = 7 THEN 'Other / Multi-Racial'
        ELSE 'Unknown'
    END AS race_ethnicity,

    -- Socioeconomic variable
    d.INDFMPIR AS family_income_poverty_ratio,

    CASE
        WHEN d.INDFMPIR IS NULL THEN 'Missing'
        WHEN d.INDFMPIR < 1 THEN '<1.0'
        WHEN d.INDFMPIR < 2 THEN '1.0-1.99'
        WHEN d.INDFMPIR < 4 THEN '2.0-3.99'
        ELSE '4.0+'
    END AS income_poverty_ratio_band,

    -- Core laboratory variables
    f.LBXFER AS ferritin_ng_ml,
    f.LBDFERSI AS ferritin_ug_l,
    c.LBXHGB AS hemoglobin_g_dl,

    -- Additional CBC fields retained for later descriptive / sensitivity work
    c.LBXHCT AS hematocrit_pct,
    c.LBXMCVSI AS mcv_fl,
    c.LBXMCHSI AS mch_pg,
    c.LBXMC AS mchc_g_dl,
    c.LBXRBCSI AS rbc_million_cells_ul,
    c.LBXRDW AS rdw_pct,

    -- NHANES combined pre-pandemic survey design variables
    d.WTMECPRP AS mec_exam_weight,
    d.SDMVSTRA AS variance_stratum,
    d.SDMVPSU AS variance_psu,

    -- Source-cycle identifier
    d.SDDSRVYR AS survey_release_cycle

FROM nhanes.demo_raw AS d

INNER JOIN nhanes.ferritin_raw AS f
    ON d.SEQN = f.SEQN

INNER JOIN nhanes.cbc_raw AS c
    ON d.SEQN = c.SEQN

WHERE f.LBXFER IS NOT NULL
  AND c.LBXHGB IS NOT NULL;


-- ============================================================
-- BLOCK 3 — VALIDATE OUTPUT GRAIN
--
-- PURPOSE:
-- Confirm the output contains exactly one row per participant.
--
-- EXPECTED:
--   rows = 10,546
--   unique_participants = 10,546
--   duplicate_participant_rows = 0
-- ============================================================

SELECT
    COUNT(*) AS rows,
    COUNT(DISTINCT patient_id) AS unique_participants,

    COUNT(*)
    -
    COUNT(DISTINCT patient_id)
        AS duplicate_participant_rows

FROM analytics.nhanes_core_analysis_population;


-- ============================================================
-- BLOCK 4 — VALIDATE REQUIRED CORE VARIABLES
--
-- PURPOSE:
-- Confirm there are no missing ferritin, hemoglobin, or survey-design
-- variables in the analytical denominator.
--
-- EXPECTED:
-- All missing/nonpositive counts should be 0.
-- ============================================================

SELECT
    COUNT(*) AS participants,

    COUNT_IF(ferritin_ng_ml IS NULL)
        AS missing_ferritin,

    COUNT_IF(hemoglobin_g_dl IS NULL)
        AS missing_hemoglobin,

    COUNT_IF(mec_exam_weight IS NULL)
        AS missing_mec_weight,

    COUNT_IF(mec_exam_weight <= 0)
        AS nonpositive_mec_weight,

    COUNT_IF(variance_stratum IS NULL)
        AS missing_variance_stratum,

    COUNT_IF(variance_psu IS NULL)
        AS missing_variance_psu

FROM analytics.nhanes_core_analysis_population;


-- ============================================================
-- BLOCK 5 — PROFILE AGE / SEX COMPOSITION
--
-- PURPOSE:
-- Understand the composition of the core-lab denominator before
-- applying any clinical definition.
--
-- IMPORTANT:
-- These are UNWEIGHTED participant counts for QA and planning.
-- They are not U.S. population prevalence estimates.
-- ============================================================

SELECT
    sex,
    age_group,
    COUNT(*) AS participants

FROM analytics.nhanes_core_analysis_population

GROUP BY
    sex,
    age_group

ORDER BY
    sex,
    MIN(age_years);


-- ============================================================
-- BLOCK 6 — PROFILE POTENTIAL PRODUCT-RELEVANT AGE/SEX GROUPS
--
-- PURPOSE:
-- Quantify the available sample for broad age/sex groups that may
-- later be useful for product segmentation.
--
-- IMPORTANT:
-- "Female 18-49" is only an age/sex descriptor.
-- It must NOT be labeled "menstruating women" without questionnaire
-- evidence confirming menstrual status.
-- ============================================================

SELECT
    COUNT(*) AS core_lab_participants,

    COUNT_IF(adult_18_plus_flag = 1)
        AS adults_18_plus,

    COUNT_IF(female_18_49_flag = 1)
        AS females_18_49,

    COUNT_IF(female_20_44_flag = 1)
        AS females_20_44

FROM analytics.nhanes_core_analysis_population;


-- ============================================================
-- BLOCK 7 — PROFILE PREGNANCY STATUS
--
-- PURPOSE:
-- Quantify pregnancy-status categories among females ages 20-44 with
-- core laboratory data.
--
-- NHANES public-use coding:
--   1 = pregnant
--   2 = not pregnant
--   3 = cannot ascertain
--
-- ============================================================

SELECT
    pregnancy_status,
    COUNT(*) AS participants

FROM analytics.nhanes_core_analysis_population

WHERE female_20_44_flag = 1

GROUP BY
    pregnancy_status

ORDER BY
    CASE pregnancy_status
        WHEN 'Pregnant' THEN 1
        WHEN 'Not pregnant' THEN 2
        WHEN 'Cannot ascertain' THEN 3
        ELSE 4
    END;


-- ============================================================
-- BLOCK 8 — PROFILE INCOME AVAILABILITY
--
-- PURPOSE:
-- Preserve lower-income participants in the denominator rather than
-- dropping everyone with a missing poverty ratio.
--
-- WHY:
-- Income will later be used as a segmentation/access variable.
-- Missing income should be handled explicitly rather than silently
-- excluding those participants from the biological analysis.
-- ============================================================

SELECT
    income_poverty_ratio_band,
    COUNT(*) AS participants,

    ROUND(
        100.0 * COUNT(*)
        / SUM(COUNT(*)) OVER (),
        2
    ) AS unweighted_participant_pct

FROM analytics.nhanes_core_analysis_population

GROUP BY
    income_poverty_ratio_band

ORDER BY
    CASE income_poverty_ratio_band
        WHEN '<1.0' THEN 1
        WHEN '1.0-1.99' THEN 2
        WHEN '2.0-3.99' THEN 3
        WHEN '4.0+' THEN 4
        ELSE 5
    END;


-- ============================================================
-- BLOCK 9 — CORE LAB DISTRIBUTION QA
--
-- PURPOSE:
-- Inspect ferritin and hemoglobin distributions before applying
-- clinical cutoffs.
--
-- WHY:
-- Ferritin is expected to be right-skewed. Extreme high values should
-- not automatically be deleted as "outliers" without a defensible
-- clinical/data-quality reason.
-- ============================================================

SELECT
    'Ferritin (ng/mL)' AS measure,

    MIN(ferritin_ng_ml) AS minimum,
    QUANTILE_CONT(ferritin_ng_ml, 0.01) AS p01,
    QUANTILE_CONT(ferritin_ng_ml, 0.05) AS p05,
    QUANTILE_CONT(ferritin_ng_ml, 0.25) AS p25,
    MEDIAN(ferritin_ng_ml) AS median,
    QUANTILE_CONT(ferritin_ng_ml, 0.75) AS p75,
    QUANTILE_CONT(ferritin_ng_ml, 0.95) AS p95,
    QUANTILE_CONT(ferritin_ng_ml, 0.99) AS p99,
    MAX(ferritin_ng_ml) AS maximum

FROM analytics.nhanes_core_analysis_population

UNION ALL

SELECT
    'Hemoglobin (g/dL)',

    MIN(hemoglobin_g_dl),
    QUANTILE_CONT(hemoglobin_g_dl, 0.01),
    QUANTILE_CONT(hemoglobin_g_dl, 0.05),
    QUANTILE_CONT(hemoglobin_g_dl, 0.25),
    MEDIAN(hemoglobin_g_dl),
    QUANTILE_CONT(hemoglobin_g_dl, 0.75),
    QUANTILE_CONT(hemoglobin_g_dl, 0.95),
    QUANTILE_CONT(hemoglobin_g_dl, 0.99),
    MAX(hemoglobin_g_dl)

FROM analytics.nhanes_core_analysis_population;


-- ============================================================
-- BLOCK 10 — WEIGHTED DENOMINATOR CHECK
--
-- PURPOSE:
-- Confirm that the analytical cohort has positive MEC weights and
-- inspect the total survey-weight mass.
--
-- IMPORTANT:
-- SUM(weight) is a QA value, not yet a product market-size estimate.
-- Later prevalence calculations must apply the correct population
-- restrictions and survey design.
-- ============================================================

SELECT
    COUNT(*) AS unweighted_participants,

    SUM(mec_exam_weight)
        AS summed_mec_weight,

    MIN(mec_exam_weight)
        AS minimum_mec_weight,

    MEDIAN(mec_exam_weight)
        AS median_mec_weight,

    MAX(mec_exam_weight)
        AS maximum_mec_weight

FROM analytics.nhanes_core_analysis_population;


-- ============================================================
-- BLOCK 11 — FINAL ANALYSIS-POPULATION CHECK
--
-- PURPOSE:
-- Provide a go/no-go result before defining ferritin and anemia
-- thresholds in the next analysis file.
--
-- PASS requires:
--   - 10,546 participant rows
--   - no duplicate participant IDs
--   - no missing core labs
--   - no missing or nonpositive MEC weights
-- ============================================================

WITH qa AS (

    SELECT
        COUNT(*) AS rows,
        COUNT(DISTINCT patient_id) AS unique_participants,

        COUNT_IF(ferritin_ng_ml IS NULL)
            AS missing_ferritin,

        COUNT_IF(hemoglobin_g_dl IS NULL)
            AS missing_hemoglobin,

        COUNT_IF(mec_exam_weight IS NULL OR mec_exam_weight <= 0)
            AS invalid_mec_weight

    FROM analytics.nhanes_core_analysis_population
)

SELECT
    rows,
    unique_participants,

    rows - unique_participants
        AS duplicate_participant_rows,

    missing_ferritin,
    missing_hemoglobin,
    invalid_mec_weight,

    CASE
        WHEN rows = 10546
         AND rows = unique_participants
         AND missing_ferritin = 0
         AND missing_hemoglobin = 0
         AND invalid_mec_weight = 0
            THEN 'PASS'
        ELSE 'REVIEW'
    END AS analysis_population_status

FROM qa;
