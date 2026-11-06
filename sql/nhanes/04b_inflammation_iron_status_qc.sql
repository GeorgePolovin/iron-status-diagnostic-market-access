-- ============================================================
-- 04b_inflammation_iron_status_qc.sql
--
-- PURPOSE
-- -------
-- Add participant-level inflammation and serum iron-status QC to the
-- NHANES ferritin analysis before defining low ferritin without anemia.
--
-- Ferritin can rise with inflammation, potentially masking depleted
-- iron stores. This file therefore LEFT JOINs hs-CRP and the serum
-- iron panel to EACH participant by SEQN rather than comparing only
-- group averages.
--
-- INPUTS
-- ------
-- analytics.nhanes_ferritin_flags
-- nhanes.hscrp_raw
-- nhanes.fetib_raw
--
-- KEY SOURCE VARIABLES
-- --------------------
-- LBXHSCRP = high-sensitivity CRP (mg/L)
-- LBXIRN   = serum iron (ug/dL)
-- LBXUIB   = unsaturated iron-binding capacity / UIBC (ug/dL)
-- LBDTIB   = total iron-binding capacity / TIBC (ug/dL)
-- LBDPCT   = transferrin saturation (%)
--
-- CLINICAL / QC FRAMEWORK
-- -----------------------
-- CRP >=5 mg/L is used as the inflammation flag.
--
-- Primary analysis remains:
--     ferritin <15 ng/mL
--
-- CRP sensitivity scenario for non-pregnant adults:
--     CRP <5  AND ferritin <15
--     OR
--     CRP >=5 AND ferritin <70
--
-- IMPORTANT:
-- The <70 rule is retained only as a WHO inflammation-sensitive
-- scenario. WHO recommends considering CRP and AGP at the population
-- level; this project currently has CRP but not AGP.
--
-- OUTPUT GRAIN
-- ------------
-- analytics.nhanes_iron_status_qc
--     one row per participant from analytics.nhanes_ferritin_flags
--
-- mart.nhanes_ferritin_inflammation_sensitivity
--     one row per analysis approach for the primary female segment
-- ============================================================


-- ============================================================
-- BLOCK 1 — VERIFY SOURCE TABLE GRAIN
--
-- PURPOSE:
-- Confirm hs-CRP and serum-iron tables contain one row per SEQN before
-- joining them to the participant-level ferritin analysis.
--
-- EXPECTED:
-- duplicate_participant_rows = 0 for both tables.
-- ============================================================

SELECT
    'hscrp_raw' AS source_table,
    COUNT(*) AS rows,
    COUNT(DISTINCT SEQN) AS unique_participants,
    COUNT(*) - COUNT(DISTINCT SEQN) AS duplicate_participant_rows
FROM nhanes.hscrp_raw

UNION ALL

SELECT
    'fetib_raw',
    COUNT(*),
    COUNT(DISTINCT SEQN),
    COUNT(*) - COUNT(DISTINCT SEQN)
FROM nhanes.fetib_raw;


-- ============================================================
-- BLOCK 2 — PROFILE SOURCE COMPLETENESS
--
-- PURPOSE:
-- Inspect hs-CRP and serum iron-panel availability before joining.
--
-- NOTE:
-- P_FETIB is limited to examined participants age 12+, so missing
-- iron-panel values are expected among younger participants.
-- ============================================================

SELECT
    'hs-CRP' AS source_measure,
    COUNT(*) AS source_rows,
    COUNT(LBXHSCRP) AS nonmissing_primary_value,
    COUNT_IF(LBXHSCRP IS NULL) AS missing_primary_value
FROM nhanes.hscrp_raw

UNION ALL

SELECT
    'Serum iron',
    COUNT(*),
    COUNT(LBXIRN),
    COUNT_IF(LBXIRN IS NULL)
FROM nhanes.fetib_raw

UNION ALL

SELECT
    'TIBC',
    COUNT(*),
    COUNT(LBDTIB),
    COUNT_IF(LBDTIB IS NULL)
FROM nhanes.fetib_raw

UNION ALL

SELECT
    'Transferrin saturation',
    COUNT(*),
    COUNT(LBDPCT),
    COUNT_IF(LBDPCT IS NULL)
FROM nhanes.fetib_raw;


-- ============================================================
-- BLOCK 3 — CHECK OVERLAP WITH CORE FERRITIN ANALYSIS
--
-- PURPOSE:
-- Determine how many of the 10,546 core participants also have hs-CRP
-- and complete serum iron-panel data.
--
-- LEFT JOIN preserves the existing ferritin denominator.
-- ============================================================

SELECT
    COUNT(*) AS core_ferritin_participants,

    COUNT_IF(h.SEQN IS NOT NULL)
        AS participants_in_hscrp_file,

    COUNT_IF(h.LBXHSCRP IS NOT NULL)
        AS participants_with_hscrp,

    COUNT_IF(i.SEQN IS NOT NULL)
        AS participants_in_fetib_file,

    COUNT_IF(i.LBXIRN IS NOT NULL)
        AS participants_with_serum_iron,

    COUNT_IF(
        i.LBXIRN IS NOT NULL
        AND i.LBXUIB IS NOT NULL
        AND i.LBDTIB IS NOT NULL
        AND i.LBDPCT IS NOT NULL
    ) AS participants_with_complete_iron_panel,

    COUNT_IF(
        h.LBXHSCRP IS NOT NULL
        AND i.LBXIRN IS NOT NULL
        AND i.LBXUIB IS NOT NULL
        AND i.LBDTIB IS NOT NULL
        AND i.LBDPCT IS NOT NULL
    ) AS participants_with_hscrp_and_complete_iron_panel

FROM analytics.nhanes_ferritin_flags AS p

LEFT JOIN nhanes.hscrp_raw AS h
    ON p.patient_id = h.SEQN

LEFT JOIN nhanes.fetib_raw AS i
    ON p.patient_id = i.SEQN;


-- ============================================================
-- BLOCK 4 — CREATE PARTICIPANT-LEVEL IRON STATUS QC TABLE
--
-- PURPOSE:
-- Attach hs-CRP and serum iron-panel values to each participant.
--
-- GRAIN:
-- One row per participant.
--
-- This table also recalculates TIBC and transferrin saturation to
-- verify the derived NHANES variables at the participant level.
-- ============================================================

CREATE OR REPLACE TABLE analytics.nhanes_iron_status_qc AS

SELECT
    p.*,

    h.LBXHSCRP AS hs_crp_mg_l,

    CASE
        WHEN h.LBXHSCRP IS NULL THEN NULL
        WHEN h.LBXHSCRP >= 5 THEN 1
        ELSE 0
    END AS inflammation_crp_ge5_flag,

    CASE
        WHEN h.LBXHSCRP IS NULL THEN 'CRP missing'
        WHEN h.LBXHSCRP >= 5 THEN 'CRP >=5 mg/L'
        ELSE 'CRP <5 mg/L'
    END AS crp_category,

    i.LBXIRN AS serum_iron_ug_dl,
    i.LBXUIB AS uibc_ug_dl,
    i.LBDTIB AS tibc_ug_dl,
    i.LBDPCT AS transferrin_saturation_pct,

    CASE
        WHEN i.LBXIRN IS NOT NULL
         AND i.LBXUIB IS NOT NULL
         AND i.LBDTIB IS NOT NULL
         AND i.LBDPCT IS NOT NULL
            THEN 1
        ELSE 0
    END AS iron_panel_complete_flag,

    CASE
        WHEN i.LBXIRN IS NOT NULL
         AND i.LBXUIB IS NOT NULL
            THEN i.LBXIRN + i.LBXUIB
        ELSE NULL
    END AS recalculated_tibc_ug_dl,

    CASE
        WHEN i.LBDTIB IS NOT NULL
         AND i.LBXIRN IS NOT NULL
         AND i.LBXUIB IS NOT NULL
            THEN i.LBDTIB - (i.LBXIRN + i.LBXUIB)
        ELSE NULL
    END AS tibc_difference_qc,

    CASE
        WHEN i.LBXIRN IS NOT NULL
         AND i.LBDTIB IS NOT NULL
         AND i.LBDTIB > 0
            THEN 100.0 * i.LBXIRN / i.LBDTIB
        ELSE NULL
    END AS recalculated_transferrin_saturation_pct,

    CASE
        WHEN i.LBDPCT IS NOT NULL
         AND i.LBXIRN IS NOT NULL
         AND i.LBDTIB IS NOT NULL
         AND i.LBDTIB > 0
            THEN
                i.LBDPCT
                - (100.0 * i.LBXIRN / i.LBDTIB)
        ELSE NULL
    END AS transferrin_saturation_difference_qc,

    CASE
        WHEN h.LBXHSCRP IS NULL
            THEN 'CRP unavailable'

        WHEN h.LBXHSCRP < 5
         AND p.ferritin_ng_ml < 15
            THEN 'Ferritin <15; CRP <5'

        WHEN h.LBXHSCRP < 5
         AND p.ferritin_ng_ml >= 15
            THEN 'Ferritin >=15; CRP <5'

        WHEN h.LBXHSCRP >= 5
         AND p.ferritin_ng_ml < 15
            THEN 'Ferritin <15; CRP >=5'

        WHEN h.LBXHSCRP >= 5
         AND p.ferritin_ng_ml >= 15
         AND p.ferritin_ng_ml < 70
            THEN 'Ferritin 15-69.9; CRP >=5'

        ELSE 'Ferritin >=70; CRP >=5'
    END AS ferritin_crp_qc_category,

    CASE
        WHEN p.age_years < 18
            THEN NULL

        WHEN p.sex = 'Female'
         AND p.age_years BETWEEN 20 AND 44
         AND p.pregnancy_status = 'Pregnant'
            THEN NULL

        WHEN h.LBXHSCRP IS NULL
            THEN NULL

        WHEN h.LBXHSCRP < 5
         AND p.ferritin_ng_ml < 15
            THEN 1

        WHEN h.LBXHSCRP >= 5
         AND p.ferritin_ng_ml < 70
            THEN 1

        ELSE 0
    END AS who_crp_only_ferritin_sensitivity_flag

FROM analytics.nhanes_ferritin_flags AS p

LEFT JOIN nhanes.hscrp_raw AS h
    ON p.patient_id = h.SEQN

LEFT JOIN nhanes.fetib_raw AS i
    ON p.patient_id = i.SEQN;


-- ============================================================
-- BLOCK 5 — VALIDATE PARTICIPANT GRAIN
--
-- PURPOSE:
-- Ensure the joins did not add or remove participant rows.
--
-- EXPECTED:
-- rows = 10,546
-- unique_participants = 10,546
-- duplicate_participant_rows = 0
-- ============================================================

SELECT
    COUNT(*) AS rows,
    COUNT(DISTINCT patient_id) AS unique_participants,
    COUNT(*) - COUNT(DISTINCT patient_id)
        AS duplicate_participant_rows
FROM analytics.nhanes_iron_status_qc;


-- ============================================================
-- BLOCK 6 — VALIDATE FETIB DERIVED-VARIABLE MATH
--
-- PURPOSE:
-- Verify the formulas documented by NHANES:
--
-- TIBC = serum iron + UIBC
-- % saturation = serum iron / TIBC * 100
--
-- Small % saturation differences are expected from rounding.
-- ============================================================

SELECT
    COUNT_IF(iron_panel_complete_flag = 1)
        AS complete_iron_panel_rows,

    COUNT_IF(
        iron_panel_complete_flag = 1
        AND ABS(tibc_difference_qc) > 0.001
    ) AS tibc_formula_mismatches,

    MAX(
        ABS(tibc_difference_qc)
    ) AS maximum_absolute_tibc_difference,

    ROUND(
        AVG(
            ABS(transferrin_saturation_difference_qc)
        ),
        4
    ) AS average_absolute_tsat_rounding_difference,

    ROUND(
        MAX(
            ABS(transferrin_saturation_difference_qc)
        ),
        4
    ) AS maximum_absolute_tsat_rounding_difference

FROM analytics.nhanes_iron_status_qc;


-- ============================================================
-- BLOCK 7 — CRP COVERAGE IN PRIMARY FEMALE SEGMENT
--
-- PURPOSE:
-- Check whether hs-CRP coverage is adequate among non-pregnant
-- females ages 20-44.
-- ============================================================

SELECT
    COUNT(*) AS nonpregnant_females_20_44,

    COUNT(hs_crp_mg_l)
        AS participants_with_hscrp,

    COUNT_IF(hs_crp_mg_l IS NULL)
        AS participants_missing_hscrp,

    ROUND(
        100.0
        * COUNT(hs_crp_mg_l)
        / COUNT(*),
        2
    ) AS hscrp_coverage_pct,

    COUNT_IF(inflammation_crp_ge5_flag = 1)
        AS participants_with_crp_ge5,

    ROUND(
        100.0
        * SUM(
            CASE
                WHEN inflammation_crp_ge5_flag = 1
                    THEN mec_exam_weight
                ELSE 0
            END
        )
        / NULLIF(
            SUM(
                CASE
                    WHEN hs_crp_mg_l IS NOT NULL
                        THEN mec_exam_weight
                    ELSE 0
                END
            ),
            0
        ),
        2
    ) AS weighted_crp_ge5_pct_among_crp_measured

FROM analytics.nhanes_iron_status_qc

WHERE female_20_44_nonpregnant_flag = 1;


-- ============================================================
-- BLOCK 8 — FERRITIN × CRP QC CATEGORIES
--
-- PURPOSE:
-- Summarize the participant-level ferritin/CRP combinations for
-- non-pregnant females ages 20-44.
--
-- KEY CATEGORY:
-- Ferritin 15-69.9 + CRP >=5 identifies participants whose ferritin
-- is above the primary <15 cutoff but whose inflammation status could
-- alter interpretation.
-- ============================================================

SELECT
    ferritin_crp_qc_category,

    COUNT(*) AS unweighted_n,

    ROUND(
        100.0
        * SUM(mec_exam_weight)
        / SUM(SUM(mec_exam_weight)) OVER (),
        2
    ) AS weighted_share_pct,

    ROUND(
        SUM(mec_exam_weight) / 1000000.0,
        2
    ) AS weighted_population_millions

FROM analytics.nhanes_iron_status_qc

WHERE female_20_44_nonpregnant_flag = 1

GROUP BY ferritin_crp_qc_category

ORDER BY
    CASE ferritin_crp_qc_category
        WHEN 'Ferritin <15; CRP <5' THEN 1
        WHEN 'Ferritin <15; CRP >=5' THEN 2
        WHEN 'Ferritin 15-69.9; CRP >=5' THEN 3
        WHEN 'Ferritin >=15; CRP <5' THEN 4
        WHEN 'Ferritin >=70; CRP >=5' THEN 5
        ELSE 6
    END;


-- ============================================================
-- BLOCK 9 — COMPARE PRIMARY RESULT WITH CRP QC
--
-- PURPOSE:
-- Compare three transparent approaches in non-pregnant females 20-44:
--
-- A. Primary: ferritin <15 regardless of CRP
-- B. QC subset: ferritin <15 only among CRP <5
-- C. CRP-only WHO sensitivity:
--      CRP <5 + ferritin <15
--      OR
--      CRP >=5 + ferritin <70
--
-- Approach C is explicitly a sensitivity analysis because AGP is not
-- currently available in the project.
-- ============================================================

WITH target AS (

    SELECT *
    FROM analytics.nhanes_iron_status_qc
    WHERE female_20_44_nonpregnant_flag = 1
),

analysis_rows AS (

    SELECT
        1 AS analysis_order,
        'Primary: ferritin <15, all CRP statuses'
            AS analysis_approach,
        COUNT(*) AS unweighted_denominator,
        SUM(ferritin_lt15_flag) AS unweighted_flagged_n,
        SUM(mec_exam_weight) AS denominator_weight,
        SUM(mec_exam_weight * ferritin_lt15_flag)
            AS flagged_weight
    FROM target

    UNION ALL

    SELECT
        2,
        'QC subset: ferritin <15 among CRP <5',
        COUNT(*),
        SUM(ferritin_lt15_flag),
        SUM(mec_exam_weight),
        SUM(mec_exam_weight * ferritin_lt15_flag)
    FROM target
    WHERE hs_crp_mg_l < 5

    UNION ALL

    SELECT
        3,
        'Sensitivity: WHO CRP-only inflammation-aware ferritin',
        COUNT(*),
        SUM(who_crp_only_ferritin_sensitivity_flag),
        SUM(mec_exam_weight),
        SUM(
            mec_exam_weight
            * who_crp_only_ferritin_sensitivity_flag
        )
    FROM target
    WHERE who_crp_only_ferritin_sensitivity_flag IS NOT NULL
)

SELECT
    analysis_order,
    analysis_approach,
    unweighted_denominator,
    unweighted_flagged_n,

    ROUND(
        100.0
        * flagged_weight
        / NULLIF(denominator_weight, 0),
        2
    ) AS weighted_flagged_pct,

    ROUND(
        flagged_weight / 1000000.0,
        2
    ) AS weighted_flagged_population_millions

FROM analysis_rows

ORDER BY analysis_order;


-- ============================================================
-- BLOCK 10 — IRON PANEL PROFILE BY PRIMARY FERRITIN STATUS
--
-- PURPOSE:
-- Check whether participants with ferritin <15 also show a different
-- serum iron / TIBC / transferrin-saturation profile.
--
-- These medians are supporting QC, not separate diagnostic criteria.
-- ============================================================

SELECT
    CASE
        WHEN ferritin_lt15_flag = 1
            THEN 'Ferritin <15'
        ELSE 'Ferritin >=15'
    END AS ferritin_group,

    COUNT(*) AS participants,

    COUNT_IF(iron_panel_complete_flag = 1)
        AS participants_with_complete_iron_panel,

    ROUND(
        MEDIAN(
            CASE
                WHEN iron_panel_complete_flag = 1
                    THEN serum_iron_ug_dl
            END
        ),
        2
    ) AS median_serum_iron_ug_dl,

    ROUND(
        MEDIAN(
            CASE
                WHEN iron_panel_complete_flag = 1
                    THEN tibc_ug_dl
            END
        ),
        2
    ) AS median_tibc_ug_dl,

    ROUND(
        MEDIAN(
            CASE
                WHEN iron_panel_complete_flag = 1
                    THEN transferrin_saturation_pct
            END
        ),
        2
    ) AS median_transferrin_saturation_pct

FROM analytics.nhanes_iron_status_qc

WHERE female_20_44_nonpregnant_flag = 1

GROUP BY ferritin_group

ORDER BY
    CASE ferritin_group
        WHEN 'Ferritin <15' THEN 1
        ELSE 2
    END;


-- ============================================================
-- BLOCK 11 — INDIVIDUAL QC RECORDS FOR LOW-FERRITIN WOMEN
--
-- PURPOSE:
-- Inspect ferritin, hemoglobin, CRP, and the iron panel together for
-- each low-ferritin non-pregnant female age 20-44.
--
-- This is QA / drill-down output, not a public-facing summary.
-- ============================================================

SELECT
    patient_id,
    age_years,

    ferritin_ng_ml,
    hemoglobin_g_dl,

    hs_crp_mg_l,
    crp_category,

    serum_iron_ug_dl,
    uibc_ug_dl,
    tibc_ug_dl,
    transferrin_saturation_pct,

    iron_panel_complete_flag,
    ferritin_crp_qc_category,
    who_crp_only_ferritin_sensitivity_flag

FROM analytics.nhanes_iron_status_qc

WHERE female_20_44_nonpregnant_flag = 1
  AND ferritin_lt15_flag = 1

ORDER BY
    ferritin_ng_ml ASC,
    patient_id;


-- ============================================================
-- BLOCK 12 — CREATE CRP SENSITIVITY MART
--
-- PURPOSE:
-- Save the three primary/QC approaches in one compact comparison table.
--
-- GRAIN:
-- One row per analysis approach.
-- ============================================================

CREATE OR REPLACE TABLE mart.nhanes_ferritin_inflammation_sensitivity AS

WITH target AS (

    SELECT *
    FROM analytics.nhanes_iron_status_qc
    WHERE female_20_44_nonpregnant_flag = 1
),

analysis_rows AS (

    SELECT
        1 AS analysis_order,
        'Non-pregnant females 20-44' AS population_segment,
        'Primary: ferritin <15, all CRP statuses'
            AS analysis_approach,
        COUNT(*) AS unweighted_denominator,
        SUM(ferritin_lt15_flag) AS unweighted_flagged_n,
        SUM(mec_exam_weight) AS denominator_weight,
        SUM(mec_exam_weight * ferritin_lt15_flag) AS flagged_weight
    FROM target

    UNION ALL

    SELECT
        2,
        'Non-pregnant females 20-44',
        'QC subset: ferritin <15 among CRP <5',
        COUNT(*),
        SUM(ferritin_lt15_flag),
        SUM(mec_exam_weight),
        SUM(mec_exam_weight * ferritin_lt15_flag)
    FROM target
    WHERE hs_crp_mg_l < 5

    UNION ALL

    SELECT
        3,
        'Non-pregnant females 20-44',
        'Sensitivity: WHO CRP-only inflammation-aware ferritin',
        COUNT(*),
        SUM(who_crp_only_ferritin_sensitivity_flag),
        SUM(mec_exam_weight),
        SUM(
            mec_exam_weight
            * who_crp_only_ferritin_sensitivity_flag
        )
    FROM target
    WHERE who_crp_only_ferritin_sensitivity_flag IS NOT NULL
)

SELECT
    analysis_order,
    population_segment,
    analysis_approach,
    unweighted_denominator,
    unweighted_flagged_n,

    ROUND(
        100.0
        * flagged_weight
        / NULLIF(denominator_weight, 0),
        2
    ) AS weighted_flagged_pct,

    ROUND(
        flagged_weight / 1000000.0,
        2
    ) AS weighted_flagged_population_millions

FROM analysis_rows;


-- ============================================================
-- BLOCK 13 — REVIEW CRP SENSITIVITY MART
--
-- PURPOSE:
-- Determine whether inflammation materially changes the apparent
-- unmet-need signal.
-- ============================================================

SELECT *
FROM mart.nhanes_ferritin_inflammation_sensitivity
ORDER BY analysis_order;


-- ============================================================
-- BLOCK 14 — FINAL 04B COMPLETION CHECK
--
-- PURPOSE:
-- Confirm participant grain, hs-CRP/iron-panel overlap, and FETIB
-- formula QC before moving to 05_low_ferritin_without_anemia.sql.
-- ============================================================

WITH qa AS (

    SELECT
        COUNT(*) AS rows,

        COUNT(DISTINCT patient_id)
            AS unique_participants,

        COUNT(hs_crp_mg_l)
            AS participants_with_hscrp,

        COUNT_IF(iron_panel_complete_flag = 1)
            AS complete_iron_panel_rows,

        COUNT_IF(
            iron_panel_complete_flag = 1
            AND ABS(tibc_difference_qc) > 0.001
        ) AS tibc_formula_mismatches

    FROM analytics.nhanes_iron_status_qc
)

SELECT
    rows,
    unique_participants,

    rows - unique_participants
        AS duplicate_participant_rows,

    participants_with_hscrp,
    complete_iron_panel_rows,
    tibc_formula_mismatches,

    CASE
        WHEN rows = 10546
         AND rows = unique_participants
         AND participants_with_hscrp > 0
         AND complete_iron_panel_rows > 0
         AND tibc_formula_mismatches = 0
            THEN 'PASS'
        ELSE 'REVIEW'
    END AS inflammation_iron_qc_status

FROM qa;
