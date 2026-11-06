-- ============================================================
-- 05_low_ferritin_without_anemia.sql
--
-- PURPOSE
-- -------
-- Test the central unmet-need hypothesis:
--
--   A meaningful population may have depleted / low iron stores
--   BEFORE hemoglobin falls into the anemic range.
--
-- PRIMARY BUSINESS QUESTION
-- -------------------------
-- Among non-pregnant females ages 20-44:
--
--   1. How common is ferritin <15 ng/mL WITHOUT anemia?
--   2. What share of participants with ferritin <15 still have
--      hemoglobin in the non-anemic range?
--   3. Does the same pattern remain under broader ferritin sensitivity
--      thresholds (<30 and the CRP-only inflammation-aware scenario)?
--   4. Do serum iron / TIBC / transferrin saturation support the
--      biological plausibility of the low-ferritin, non-anemic group?
--
-- PRIMARY DEFINITIONS
-- -------------------
-- Ferritin:
--   Primary depleted-stores threshold = ferritin <15 ng/mL.
--
-- Anemia:
--   WHO 2024 cutoff for non-pregnant women age 15-65:
--       hemoglobin <12.0 g/dL (<120 g/L)
--
-- Therefore:
--   LOW FERRITIN WITHOUT ANEMIA =
--       ferritin <15 ng/mL
--       AND hemoglobin >=12.0 g/dL
--
-- SENSITIVITY DEFINITIONS
-- -----------------------
--   ferritin <30 ng/mL + hemoglobin >=12.0 g/dL
--
--   CRP-only inflammation-aware ferritin sensitivity flag
--       + hemoglobin >=12.0 g/dL
--
-- IMPORTANT LIMITATIONS
-- ---------------------
--   1. Hemoglobin has NOT been adjusted for smoking or altitude.
--      WHO population anemia estimates are ideally adjusted for both.
--
--   2. The CRP-only inflammation-aware ferritin scenario is a
--      sensitivity analysis, not the primary prevalence definition.
--      AGP is not currently available in this project.
--
--   3. "Without anemia" means hemoglobin is above the WHO anemia
--      cutoff. It does NOT mean the participant is asymptomatic or
--      clinically healthy.
--
--   4. NHANES is cross-sectional. This analysis cannot prove that an
--      individual participant will later develop anemia.
--
-- INPUT
-- -----
-- analytics.nhanes_iron_status_qc
--
-- OUTPUTS
-- -------
-- analytics.nhanes_early_iron_depletion_flags
-- mart.nhanes_low_ferritin_without_anemia_summary
-- mart.nhanes_iron_status_stage_distribution
--
-- ============================================================


-- ============================================================
-- BLOCK 1 — CREATE EARLY IRON-DEPLETION FLAGS
--
-- PURPOSE:
-- Add anemia and combined ferritin/hemoglobin status flags at the
-- participant level.
--
-- GRAIN:
-- One row per NHANES participant.
--
-- The primary analysis later filters to non-pregnant
-- females ages 20-44.
-- ============================================================

CREATE OR REPLACE TABLE analytics.nhanes_early_iron_depletion_flags AS

SELECT
    q.*,

    CASE
        WHEN sex = 'Female'
         AND age_years BETWEEN 15 AND 65
         AND NOT (
             age_years BETWEEN 20 AND 44
             AND pregnancy_status = 'Pregnant'
         )
            THEN
                CASE
                    WHEN hemoglobin_g_dl < 12.0 THEN 1
                    ELSE 0
                END

        WHEN sex = 'Male'
         AND age_years BETWEEN 15 AND 65
            THEN
                CASE
                    WHEN hemoglobin_g_dl < 13.0 THEN 1
                    ELSE 0
                END

        ELSE NULL
    END AS who_anemia_flag,

    CASE
        WHEN female_20_44_nonpregnant_flag = 1
         AND hemoglobin_g_dl < 12.0
            THEN 1
        WHEN female_20_44_nonpregnant_flag = 1
            THEN 0
        ELSE NULL
    END AS anemia_nonpregnant_female_20_44_flag,

    CASE
        WHEN female_20_44_nonpregnant_flag = 1
         AND ferritin_ng_ml < 15
         AND hemoglobin_g_dl >= 12.0
            THEN 1
        WHEN female_20_44_nonpregnant_flag = 1
            THEN 0
        ELSE NULL
    END AS ferritin_lt15_without_anemia_flag,

    CASE
        WHEN female_20_44_nonpregnant_flag = 1
         AND ferritin_ng_ml < 30
         AND hemoglobin_g_dl >= 12.0
            THEN 1
        WHEN female_20_44_nonpregnant_flag = 1
            THEN 0
        ELSE NULL
    END AS ferritin_lt30_without_anemia_sensitivity_flag,

    CASE
        WHEN female_20_44_nonpregnant_flag = 1
         AND who_crp_only_ferritin_sensitivity_flag = 1
         AND hemoglobin_g_dl >= 12.0
            THEN 1

        WHEN female_20_44_nonpregnant_flag = 1
         AND who_crp_only_ferritin_sensitivity_flag IS NOT NULL
            THEN 0

        ELSE NULL
    END AS crp_sensitive_low_iron_without_anemia_flag,

    CASE
        WHEN female_20_44_nonpregnant_flag <> 1
            THEN NULL

        WHEN ferritin_ng_ml < 15
         AND hemoglobin_g_dl < 12.0
            THEN 'Ferritin <15 + anemia'

        WHEN ferritin_ng_ml < 15
         AND hemoglobin_g_dl >= 12.0
            THEN 'Ferritin <15 + no anemia'

        WHEN ferritin_ng_ml >= 15
         AND hemoglobin_g_dl < 12.0
            THEN 'Ferritin >=15 + anemia'

        ELSE 'Ferritin >=15 + no anemia'
    END AS primary_iron_anemia_status

FROM analytics.nhanes_iron_status_qc AS q;


-- ============================================================
-- BLOCK 2 — VALIDATE OUTPUT GRAIN AND FLAG LOGIC
--
-- PURPOSE:
-- Confirm that adding anemia/combined-status flags preserves one row
-- per participant.
--
-- EXPECTED:
-- rows = unique_participants = 10,546
-- duplicate_participant_rows = 0
-- ============================================================

SELECT
    COUNT(*) AS rows,
    COUNT(DISTINCT patient_id) AS unique_participants,

    COUNT(*) - COUNT(DISTINCT patient_id)
        AS duplicate_participant_rows,

    COUNT_IF(
        female_20_44_nonpregnant_flag = 1
    ) AS primary_female_segment_n,

    COUNT_IF(
        ferritin_lt15_without_anemia_flag = 1
    ) AS unweighted_lt15_without_anemia_n

FROM analytics.nhanes_early_iron_depletion_flags;


-- ============================================================
-- BLOCK 3 — PRIMARY 2×2 FERRITIN × ANEMIA DISTRIBUTION
--
-- PURPOSE:
-- Divide non-pregnant females 20-44 into four mutually exclusive
-- biological states:
--
--   1. Ferritin <15 + anemia
--   2. Ferritin <15 + no anemia
--   3. Ferritin >=15 + anemia
--   4. Ferritin >=15 + no anemia
--
-- BUSINESS VALUE:
-- The "Ferritin <15 + no anemia" group is the clearest current
-- upstream-identification opportunity.
-- ============================================================

SELECT
    primary_iron_anemia_status,

    COUNT(*) AS unweighted_n,

    ROUND(
        100.0
        * SUM(mec_exam_weight)
        / SUM(SUM(mec_exam_weight)) OVER (),
        2
    ) AS weighted_population_pct,

    ROUND(
        SUM(mec_exam_weight) / 1000000.0,
        2
    ) AS weighted_population_millions

FROM analytics.nhanes_early_iron_depletion_flags

WHERE female_20_44_nonpregnant_flag = 1

GROUP BY primary_iron_anemia_status

ORDER BY
    CASE primary_iron_anemia_status
        WHEN 'Ferritin <15 + no anemia' THEN 1
        WHEN 'Ferritin <15 + anemia' THEN 2
        WHEN 'Ferritin >=15 + anemia' THEN 3
        ELSE 4
    END;


-- ============================================================
-- BLOCK 4 — CENTRAL UNMET-NEED RESULT
--
-- PURPOSE:
-- Quantify ferritin <15 WITHOUT anemia among non-pregnant females
-- ages 20-44.
--
-- TWO DENOMINATORS ARE SHOWN:
--
-- Population prevalence:
--   Share of ALL non-pregnant females 20-44 with ferritin <15 and
--   hemoglobin >=12.
--
-- Share of depleted-store group still non-anemic:
--   Among participants with ferritin <15, what percentage have not
--   crossed the WHO anemia threshold?
--
-- The second metric directly addresses whether low ferritin commonly
-- appears before anemia in this cross-sectional population.
-- ============================================================

WITH target AS (

    SELECT *
    FROM analytics.nhanes_early_iron_depletion_flags

    WHERE female_20_44_nonpregnant_flag = 1
),

low_ferritin AS (

    SELECT *
    FROM target

    WHERE ferritin_lt15_flag = 1
)

SELECT
    (SELECT COUNT(*) FROM target)
        AS total_unweighted_n,

    (SELECT COUNT(*) FROM low_ferritin)
        AS ferritin_lt15_unweighted_n,

    (
        SELECT COUNT_IF(
            ferritin_lt15_without_anemia_flag = 1
        )
        FROM target
    ) AS lt15_without_anemia_unweighted_n,

    ROUND(
        100.0
        * (
            SELECT SUM(
                mec_exam_weight
                * ferritin_lt15_without_anemia_flag
            )
            FROM target
        )
        / (
            SELECT SUM(mec_exam_weight)
            FROM target
        ),
        2
    ) AS weighted_population_lt15_without_anemia_pct,

    ROUND(
        (
            SELECT SUM(
                mec_exam_weight
                * ferritin_lt15_without_anemia_flag
            )
            FROM target
        ) / 1000000.0,
        2
    ) AS weighted_population_lt15_without_anemia_millions,

    ROUND(
        100.0
        * (
            SELECT SUM(
                CASE
                    WHEN hemoglobin_g_dl >= 12.0
                        THEN mec_exam_weight
                    ELSE 0
                END
            )
            FROM low_ferritin
        )
        / NULLIF(
            (
                SELECT SUM(mec_exam_weight)
                FROM low_ferritin
            ),
            0
        ),
        2
    ) AS weighted_pct_of_lt15_group_without_anemia

;


-- ============================================================
-- BLOCK 5 — COMPARE PRIMARY AND SENSITIVITY DEFINITIONS
--
-- PURPOSE:
-- Show how the size of the "low iron stores without anemia" population
-- changes under three transparent definitions.
--
-- A. Primary ferritin <15
-- B. Sensitivity ferritin <30
-- C. CRP-only inflammation-aware ferritin scenario
--
-- All require hemoglobin >=12.0 g/dL.
-- ============================================================

WITH target AS (

    SELECT *
    FROM analytics.nhanes_early_iron_depletion_flags

    WHERE female_20_44_nonpregnant_flag = 1
),

definitions AS (

    SELECT
        1 AS definition_order,
        'Ferritin <15 + no anemia' AS definition_name,

        COUNT(*) AS denominator_n,

        SUM(
            ferritin_lt15_without_anemia_flag
        ) AS flagged_n,

        SUM(mec_exam_weight) AS denominator_weight,

        SUM(
            mec_exam_weight
            * ferritin_lt15_without_anemia_flag
        ) AS flagged_weight

    FROM target

    UNION ALL

    SELECT
        2,
        'Ferritin <30 sensitivity + no anemia',

        COUNT(*),

        SUM(
            ferritin_lt30_without_anemia_sensitivity_flag
        ),

        SUM(mec_exam_weight),

        SUM(
            mec_exam_weight
            * ferritin_lt30_without_anemia_sensitivity_flag
        )

    FROM target

    UNION ALL

    SELECT
        3,
        'CRP-only inflammation-aware sensitivity + no anemia',

        COUNT_IF(
            crp_sensitive_low_iron_without_anemia_flag IS NOT NULL
        ),

        SUM(
            crp_sensitive_low_iron_without_anemia_flag
        ),

        SUM(
            CASE
                WHEN crp_sensitive_low_iron_without_anemia_flag
                     IS NOT NULL
                    THEN mec_exam_weight
                ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN crp_sensitive_low_iron_without_anemia_flag = 1
                    THEN mec_exam_weight
                ELSE 0
            END
        )

    FROM target
)

SELECT
    definition_order,
    definition_name,

    denominator_n,
    flagged_n,

    ROUND(
        100.0
        * flagged_weight
        / NULLIF(denominator_weight, 0),
        2
    ) AS weighted_prevalence_pct,

    ROUND(
        flagged_weight / 1000000.0,
        2
    ) AS weighted_population_millions

FROM definitions

ORDER BY definition_order;


-- ============================================================
-- BLOCK 6 — HOW MUCH LOW FERRITIN OCCURS WITHOUT ANEMIA?
--
-- PURPOSE:
-- For each ferritin definition, calculate the share of the
-- low-ferritin / low-iron group that remains non-anemic.
--
-- BUSINESS INTERPRETATION:
-- A high percentage supports the proposed upstream placement:
-- iron-store depletion may be detectable before hemoglobin crosses the
-- anemia threshold.
--
-- IMPORTANT:
-- Cross-sectional NHANES cannot establish temporal progression within
-- an individual person.
-- ============================================================

WITH target AS (

    SELECT *
    FROM analytics.nhanes_early_iron_depletion_flags

    WHERE female_20_44_nonpregnant_flag = 1
),

definition_rows AS (

    SELECT
        1 AS definition_order,
        'Ferritin <15' AS low_iron_definition,

        SUM(
            CASE
                WHEN ferritin_ng_ml < 15
                    THEN mec_exam_weight
                ELSE 0
            END
        ) AS low_iron_weight,

        SUM(
            CASE
                WHEN ferritin_ng_ml < 15
                 AND hemoglobin_g_dl >= 12.0
                    THEN mec_exam_weight
                ELSE 0
            END
        ) AS low_iron_nonanemic_weight,

        COUNT_IF(
            ferritin_ng_ml < 15
        ) AS low_iron_unweighted_n,

        COUNT_IF(
            ferritin_ng_ml < 15
            AND hemoglobin_g_dl >= 12.0
        ) AS low_iron_nonanemic_unweighted_n

    FROM target

    UNION ALL

    SELECT
        2,
        'Ferritin <30 sensitivity',

        SUM(
            CASE
                WHEN ferritin_ng_ml < 30
                    THEN mec_exam_weight
                ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN ferritin_ng_ml < 30
                 AND hemoglobin_g_dl >= 12.0
                    THEN mec_exam_weight
                ELSE 0
            END
        ),

        COUNT_IF(
            ferritin_ng_ml < 30
        ),

        COUNT_IF(
            ferritin_ng_ml < 30
            AND hemoglobin_g_dl >= 12.0
        )

    FROM target

    UNION ALL

    SELECT
        3,
        'CRP-only inflammation-aware sensitivity',

        SUM(
            CASE
                WHEN who_crp_only_ferritin_sensitivity_flag = 1
                    THEN mec_exam_weight
                ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN who_crp_only_ferritin_sensitivity_flag = 1
                 AND hemoglobin_g_dl >= 12.0
                    THEN mec_exam_weight
                ELSE 0
            END
        ),

        COUNT_IF(
            who_crp_only_ferritin_sensitivity_flag = 1
        ),

        COUNT_IF(
            who_crp_only_ferritin_sensitivity_flag = 1
            AND hemoglobin_g_dl >= 12.0
        )

    FROM target

    WHERE who_crp_only_ferritin_sensitivity_flag IS NOT NULL
)

SELECT
    definition_order,
    low_iron_definition,

    low_iron_unweighted_n,
    low_iron_nonanemic_unweighted_n,

    ROUND(
        100.0
        * low_iron_nonanemic_weight
        / NULLIF(low_iron_weight, 0),
        2
    ) AS weighted_pct_low_iron_without_anemia

FROM definition_rows

ORDER BY definition_order;


-- ============================================================
-- BLOCK 7 — IRON PANEL VALIDATION OF THE 2×2 STATES
--
-- PURPOSE:
-- Compare serum iron / TIBC / transferrin saturation across the four
-- primary ferritin + anemia states.
--
-- KEY QUESTION:
-- Does the "Ferritin <15 + no anemia" group already show an iron-panel
-- profile consistent with lower iron availability compared with
-- ferritin-normal, non-anemic participants?
--
-- These are unweighted medians for biological QC.
-- ============================================================

SELECT
    primary_iron_anemia_status,

    COUNT(*) AS participants,

    COUNT_IF(
        iron_panel_complete_flag = 1
    ) AS participants_with_complete_iron_panel,

    ROUND(
        MEDIAN(
            CASE
                WHEN iron_panel_complete_flag = 1
                    THEN ferritin_ng_ml
            END
        ),
        2
    ) AS median_ferritin_ng_ml,

    ROUND(
        MEDIAN(
            CASE
                WHEN iron_panel_complete_flag = 1
                    THEN hemoglobin_g_dl
            END
        ),
        2
    ) AS median_hemoglobin_g_dl,

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

FROM analytics.nhanes_early_iron_depletion_flags

WHERE female_20_44_nonpregnant_flag = 1

GROUP BY primary_iron_anemia_status

ORDER BY
    CASE primary_iron_anemia_status
        WHEN 'Ferritin <15 + no anemia' THEN 1
        WHEN 'Ferritin <15 + anemia' THEN 2
        WHEN 'Ferritin >=15 + anemia' THEN 3
        ELSE 4
    END;


-- ============================================================
-- BLOCK 8 — AGE PROFILE OF LOW FERRITIN WITHOUT ANEMIA
--
-- PURPOSE:
-- Determine whether the early-depletion signal is concentrated in
-- particular age bands within non-pregnant females 20-44.
-- ============================================================

WITH target AS (

    SELECT
        *,

        CASE
            WHEN age_years BETWEEN 20 AND 29
                THEN '20-29'

            WHEN age_years BETWEEN 30 AND 39
                THEN '30-39'

            ELSE '40-44'
        END AS age_band

    FROM analytics.nhanes_early_iron_depletion_flags

    WHERE female_20_44_nonpregnant_flag = 1
)

SELECT
    age_band,

    COUNT(*) AS unweighted_n,

    COUNT_IF(
        ferritin_lt15_without_anemia_flag = 1
    ) AS lt15_without_anemia_unweighted_n,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight
            * ferritin_lt15_without_anemia_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt15_without_anemia_pct

FROM target

GROUP BY age_band

ORDER BY
    CASE age_band
        WHEN '20-29' THEN 1
        WHEN '30-39' THEN 2
        ELSE 3
    END;


-- ============================================================
-- BLOCK 9 — INCOME PROFILE OF LOW FERRITIN WITHOUT ANEMIA
--
-- PURPOSE:
-- Test whether early iron depletion without anemia is concentrated
-- among lower-income groups.
--
-- BUSINESS RELEVANCE:
-- This connects biological need with a potential future access /
-- affordability hypothesis that can later be examined with MEPS.
-- ============================================================

SELECT
    income_poverty_ratio_band,

    COUNT(*) AS unweighted_n,

    COUNT_IF(
        ferritin_lt15_without_anemia_flag = 1
    ) AS lt15_without_anemia_unweighted_n,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight
            * ferritin_lt15_without_anemia_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt15_without_anemia_pct

FROM analytics.nhanes_early_iron_depletion_flags

WHERE female_20_44_nonpregnant_flag = 1

GROUP BY income_poverty_ratio_band

ORDER BY
    CASE income_poverty_ratio_band
        WHEN '<1.0' THEN 1
        WHEN '1.0-1.99' THEN 2
        WHEN '2.0-3.99' THEN 3
        WHEN '4.0+' THEN 4
        ELSE 5
    END;


-- ============================================================
-- BLOCK 10 — CREATE PRIMARY SUMMARY MART
--
-- PURPOSE:
-- Save the main low-ferritin-without-anemia results in a compact,
-- report-ready structure.
--
-- GRAIN:
-- One row per iron-status definition.
-- ============================================================

CREATE OR REPLACE TABLE mart.nhanes_low_ferritin_without_anemia_summary AS

WITH target AS (

    SELECT *
    FROM analytics.nhanes_early_iron_depletion_flags

    WHERE female_20_44_nonpregnant_flag = 1
),

definitions AS (

    SELECT
        1 AS definition_order,
        'Ferritin <15' AS iron_status_definition,

        COUNT(*) AS population_unweighted_n,

        COUNT_IF(
            ferritin_ng_ml < 15
        ) AS low_iron_unweighted_n,

        COUNT_IF(
            ferritin_ng_ml < 15
            AND hemoglobin_g_dl >= 12.0
        ) AS low_iron_without_anemia_unweighted_n,

        SUM(mec_exam_weight)
            AS population_weight,

        SUM(
            CASE
                WHEN ferritin_ng_ml < 15
                    THEN mec_exam_weight
                ELSE 0
            END
        ) AS low_iron_weight,

        SUM(
            CASE
                WHEN ferritin_ng_ml < 15
                 AND hemoglobin_g_dl >= 12.0
                    THEN mec_exam_weight
                ELSE 0
            END
        ) AS low_iron_without_anemia_weight

    FROM target

    UNION ALL

    SELECT
        2,
        'Ferritin <30 sensitivity',

        COUNT(*),

        COUNT_IF(
            ferritin_ng_ml < 30
        ),

        COUNT_IF(
            ferritin_ng_ml < 30
            AND hemoglobin_g_dl >= 12.0
        ),

        SUM(mec_exam_weight),

        SUM(
            CASE
                WHEN ferritin_ng_ml < 30
                    THEN mec_exam_weight
                ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN ferritin_ng_ml < 30
                 AND hemoglobin_g_dl >= 12.0
                    THEN mec_exam_weight
                ELSE 0
            END
        )

    FROM target

    UNION ALL

    SELECT
        3,
        'CRP-only inflammation-aware sensitivity',

        COUNT_IF(
            who_crp_only_ferritin_sensitivity_flag IS NOT NULL
        ),

        COUNT_IF(
            who_crp_only_ferritin_sensitivity_flag = 1
        ),

        COUNT_IF(
            who_crp_only_ferritin_sensitivity_flag = 1
            AND hemoglobin_g_dl >= 12.0
        ),

        SUM(
            CASE
                WHEN who_crp_only_ferritin_sensitivity_flag
                     IS NOT NULL
                    THEN mec_exam_weight
                ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN who_crp_only_ferritin_sensitivity_flag = 1
                    THEN mec_exam_weight
                ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN who_crp_only_ferritin_sensitivity_flag = 1
                 AND hemoglobin_g_dl >= 12.0
                    THEN mec_exam_weight
                ELSE 0
            END
        )

    FROM target
)

SELECT
    definition_order,
    iron_status_definition,

    population_unweighted_n,
    low_iron_unweighted_n,
    low_iron_without_anemia_unweighted_n,

    ROUND(
        100.0
        * low_iron_weight
        / NULLIF(population_weight, 0),
        2
    ) AS weighted_low_iron_prevalence_pct,

    ROUND(
        100.0
        * low_iron_without_anemia_weight
        / NULLIF(population_weight, 0),
        2
    ) AS weighted_low_iron_without_anemia_population_pct,

    ROUND(
        100.0
        * low_iron_without_anemia_weight
        / NULLIF(low_iron_weight, 0),
        2
    ) AS weighted_pct_of_low_iron_group_without_anemia,

    ROUND(
        low_iron_without_anemia_weight
        / 1000000.0,
        2
    ) AS weighted_low_iron_without_anemia_population_millions

FROM definitions;


-- ============================================================
-- BLOCK 11 — REVIEW PRIMARY SUMMARY MART
--
-- PURPOSE:
-- Display the main answer to the early-detection hypothesis.
-- ============================================================

SELECT *
FROM mart.nhanes_low_ferritin_without_anemia_summary

ORDER BY definition_order;


-- ============================================================
-- BLOCK 12 — CREATE MUTUALLY EXCLUSIVE STAGE DISTRIBUTION
--
-- PURPOSE:
-- Create a simple four-stage population view using the primary
-- ferritin <15 / hemoglobin <12 definitions.
--
-- BUSINESS USE:
-- This makes the early-identification opportunity visually intuitive:
--
--   depleted stores without anemia
--   depleted stores with anemia
--   anemia without ferritin <15
--   neither
-- ============================================================

CREATE OR REPLACE TABLE mart.nhanes_iron_status_stage_distribution AS

SELECT
    primary_iron_anemia_status AS iron_status_stage,

    COUNT(*) AS unweighted_n,

    ROUND(
        100.0
        * SUM(mec_exam_weight)
        / SUM(SUM(mec_exam_weight)) OVER (),
        2
    ) AS weighted_population_pct,

    ROUND(
        SUM(mec_exam_weight)
        / 1000000.0,
        2
    ) AS weighted_population_millions

FROM analytics.nhanes_early_iron_depletion_flags

WHERE female_20_44_nonpregnant_flag = 1

GROUP BY primary_iron_anemia_status;


-- ============================================================
-- BLOCK 13 — REVIEW STAGE DISTRIBUTION
--
-- PURPOSE:
-- Check the four mutually exclusive states sum to approximately 100%.
-- ============================================================

SELECT
    iron_status_stage,
    unweighted_n,
    weighted_population_pct,
    weighted_population_millions

FROM mart.nhanes_iron_status_stage_distribution

ORDER BY
    CASE iron_status_stage
        WHEN 'Ferritin <15 + no anemia' THEN 1
        WHEN 'Ferritin <15 + anemia' THEN 2
        WHEN 'Ferritin >=15 + anemia' THEN 3
        ELSE 4
    END;


-- ============================================================
-- BLOCK 14 — FINAL VALIDATION
--
-- PURPOSE:
-- Confirm the participant grain and mutually exclusive stage
-- distribution before moving to broader risk-segment analysis.
--
-- EXPECTED:
--   rows = 10,546
--   no duplicate participant IDs
--   four primary stage rows
--   weighted stage share approximately 100%
-- ============================================================

WITH qa AS (

    SELECT
        (
            SELECT COUNT(*)
            FROM analytics.nhanes_early_iron_depletion_flags
        ) AS participant_rows,

        (
            SELECT COUNT(DISTINCT patient_id)
            FROM analytics.nhanes_early_iron_depletion_flags
        ) AS unique_participants,

        (
            SELECT COUNT(*)
            FROM mart.nhanes_iron_status_stage_distribution
        ) AS stage_rows,

        (
            SELECT SUM(weighted_population_pct)
            FROM mart.nhanes_iron_status_stage_distribution
        ) AS summed_stage_pct
)

SELECT
    participant_rows,
    unique_participants,

    participant_rows - unique_participants
        AS duplicate_participant_rows,

    stage_rows,

    ROUND(
        summed_stage_pct,
        2
    ) AS summed_stage_pct,

    CASE
        WHEN participant_rows = 10546
         AND participant_rows = unique_participants
         AND stage_rows = 4
         AND summed_stage_pct BETWEEN 99.95 AND 100.05
            THEN 'PASS'
        ELSE 'REVIEW'
    END AS early_depletion_analysis_status

FROM qa;
