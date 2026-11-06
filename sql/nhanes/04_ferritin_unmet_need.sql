-- ============================================================
-- 04_ferritin_unmet_need.sql
--
-- PURPOSE
-- -------
-- Quantify the first real-world unmet-need signal using
-- NHANES ferritin data.
--
-- PRIMARY BUSINESS QUESTION
-- -------------------------
-- How common are low iron stores in the U.S. population, and which
-- demographic groups show the strongest signal?
--
-- PRIMARY CLINICAL DEFINITION
-- ---------------------------
-- WHO depleted iron stores:
--   ferritin <15 µg/L (equivalent to <15 ng/mL)
--   for people older than 5 years, men, and NON-PREGNANT women.
--
-- IMPORTANT:
-- WHO does not provide a general ferritin deficiency cutoff for
-- pregnant women because ferritin falls physiologically during
-- pregnancy. Pregnancy is therefore analyzed descriptively here,
-- not classified using the primary <15 threshold.
--
-- SENSITIVITY / PRODUCT-SCENARIO THRESHOLDS
-- -----------------------------------------
-- We also report ferritin <30 and <50 ng/mL.
--
-- These are NOT labeled WHO iron-deficiency definitions.
-- They are sensitivity thresholds that help quantify how the
-- addressable population changes if the test ultimately uses a
-- broader "low / borderline / adequate" decision framework.
--
-- SURVEY WEIGHTING
-- ----------------
-- Weighted point estimates use WTMECPRP (renamed mec_exam_weight).
--
-- DuckDB is used here to calculate weighted point estimates.
-- Design-based confidence intervals require SDMVSTRA + SDMVPSU and
-- should later be validated with survey-aware R/Python software.
--
-- INFLAMMATION LIMITATION
-- -----------------------
-- Ferritin is an acute-phase reactant and can be elevated by
-- inflammation, which may hide iron deficiency.
--
-- This file does NOT yet adjust ferritin for inflammation because
-- hs-CRP has not yet been incorporated into the analytical table.
-- A later sensitivity analysis should add P_HSCRP / LBXHSCRP.
--
-- Therefore, the <15 estimate should be treated as a conservative
-- estimate of depleted iron stores, not the final prevalence of all
-- iron deficiency.
--
-- OUTPUT GRAIN
-- ------------
-- analytics.nhanes_ferritin_flags
--     one row per participant in the core analysis population
--
-- mart.nhanes_ferritin_threshold_by_segment
--     one row per population segment + ferritin threshold
--
-- ============================================================


-- ============================================================
-- BLOCK 1 — CREATE FERRITIN ANALYTIC FLAGS
--
-- PURPOSE:
-- Add transparent threshold flags and analysis subgroup flags to the
-- cleaned NHANES participant-level table.
--
-- GRAIN:
-- One row per participant.
--
-- IMPORTANT:
-- The <15 flag is the primary WHO depleted-stores indicator for
-- applicable non-pregnant populations.
--
-- <30 and <50 are sensitivity flags only.
-- ============================================================

CREATE OR REPLACE TABLE analytics.nhanes_ferritin_flags AS

SELECT
    p.*,

    CASE
        WHEN ferritin_ng_ml < 15 THEN 1
        ELSE 0
    END AS ferritin_lt15_flag,

    CASE
        WHEN ferritin_ng_ml < 30 THEN 1
        ELSE 0
    END AS ferritin_lt30_sensitivity_flag,

    CASE
        WHEN ferritin_ng_ml < 50 THEN 1
        ELSE 0
    END AS ferritin_lt50_sensitivity_flag,

    CASE
        WHEN ferritin_ng_ml < 15
            THEN '<15: WHO depleted stores'

        WHEN ferritin_ng_ml < 30
            THEN '15-29.9'

        WHEN ferritin_ng_ml < 50
            THEN '30-49.9'

        ELSE '50+'
    END AS ferritin_sensitivity_band,

    -- Pregnancy status is publicly available only for females 20-44.
    CASE
        WHEN sex = 'Female'
         AND age_years BETWEEN 20 AND 44
         AND pregnancy_status = 'Not pregnant'
            THEN 1
        ELSE 0
    END AS female_20_44_nonpregnant_flag,

    CASE
        WHEN sex = 'Female'
         AND age_years BETWEEN 20 AND 44
         AND pregnancy_status = 'Pregnant'
            THEN 1
        ELSE 0
    END AS female_20_44_pregnant_flag

FROM analytics.nhanes_core_analysis_population AS p;


-- ============================================================
-- BLOCK 2 — VALIDATE FERRITIN FLAG TABLE
--
-- PURPOSE:
-- Confirm the new table preserves the original participant grain and
-- that the threshold flags are logically nested.
--
-- EXPECTED:
--   rows = 10,546
--   duplicate_participant_rows = 0
--   lt15 <= lt30 <= lt50
-- ============================================================

SELECT
    COUNT(*) AS rows,
    COUNT(DISTINCT patient_id) AS unique_participants,

    COUNT(*) - COUNT(DISTINCT patient_id)
        AS duplicate_participant_rows,

    SUM(ferritin_lt15_flag)
        AS participants_lt15,

    SUM(ferritin_lt30_sensitivity_flag)
        AS participants_lt30,

    SUM(ferritin_lt50_sensitivity_flag)
        AS participants_lt50,

    CASE
        WHEN SUM(ferritin_lt15_flag)
             <= SUM(ferritin_lt30_sensitivity_flag)

         AND SUM(ferritin_lt30_sensitivity_flag)
             <= SUM(ferritin_lt50_sensitivity_flag)

            THEN 'PASS'
        ELSE 'REVIEW'
    END AS threshold_nesting_status

FROM analytics.nhanes_ferritin_flags;


-- ============================================================
-- BLOCK 3 — ADULT FERRITIN DISTRIBUTION BY SEX
--
-- PURPOSE:
-- Establish the ferritin distribution among adults before focusing on
-- the highest-priority female population.
--
-- IMPORTANT:
-- Quantiles shown here are unweighted descriptive statistics.
-- Weighted prevalence estimates appear in later blocks.
-- ============================================================

SELECT
    sex,

    COUNT(*) AS unweighted_n,

    ROUND(
        QUANTILE_CONT(ferritin_ng_ml, 0.05),
        2
    ) AS ferritin_p05,

    ROUND(
        QUANTILE_CONT(ferritin_ng_ml, 0.25),
        2
    ) AS ferritin_p25,

    ROUND(
        MEDIAN(ferritin_ng_ml),
        2
    ) AS ferritin_median,

    ROUND(
        QUANTILE_CONT(ferritin_ng_ml, 0.75),
        2
    ) AS ferritin_p75,

    ROUND(
        QUANTILE_CONT(ferritin_ng_ml, 0.95),
        2
    ) AS ferritin_p95

FROM analytics.nhanes_ferritin_flags

WHERE age_years >= 18

GROUP BY sex

ORDER BY sex;


-- ============================================================
-- BLOCK 4 — PRIMARY WHO <15 PREVALENCE BY ADULT SEX
--
-- PURPOSE:
-- Calculate the survey-weighted point estimate for depleted iron
-- stores among adults using ferritin <15 ng/mL.
--
-- IMPORTANT:
-- Because pregnancy is a special physiologic state, the female-adult
-- row is a broad descriptive population. The cleaner primary female
-- subgroup is non-pregnant females 20-44 in Block 5.
--
-- weighted_population_millions is a provisional survey-weighted
-- population estimate, NOT a product market-size estimate.
-- ============================================================

SELECT
    sex,

    COUNT(*) AS unweighted_n,

    SUM(ferritin_lt15_flag)
        AS unweighted_lt15_n,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight * ferritin_lt15_flag
        )
        / NULLIF(
            SUM(mec_exam_weight),
            0
        ),
        2
    ) AS weighted_lt15_pct,

    ROUND(
        SUM(
            mec_exam_weight * ferritin_lt15_flag
        ) / 1000000.0,
        2
    ) AS weighted_lt15_population_millions

FROM analytics.nhanes_ferritin_flags

WHERE age_years >= 18

GROUP BY sex

ORDER BY sex;


-- ============================================================
-- BLOCK 5 — PRIMARY FEMALE SEGMENT: NON-PREGNANT 20-44
--
-- PURPOSE:
-- Quantify depleted iron stores and threshold sensitivity among the
-- cleanest currently available proxy for reproductive-age women.
--
-- WHY 20-44:
-- Public-use NHANES pregnancy status is available for this age range,
-- allowing pregnant participants to be explicitly excluded.
--
-- IMPORTANT:
-- This is NOT equivalent to "menstruating women."
-- Menstrual-history questionnaire data are needed for that label.
--
-- <15 = WHO depleted-stores threshold.
-- <30 and <50 = sensitivity / product-scenario thresholds.
-- ============================================================

SELECT
    COUNT(*) AS unweighted_n,

    SUM(ferritin_lt15_flag)
        AS unweighted_lt15_n,

    SUM(ferritin_lt30_sensitivity_flag)
        AS unweighted_lt30_n,

    SUM(ferritin_lt50_sensitivity_flag)
        AS unweighted_lt50_n,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight * ferritin_lt15_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt15_pct,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight
            * ferritin_lt30_sensitivity_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt30_pct,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight
            * ferritin_lt50_sensitivity_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt50_pct,

    ROUND(
        SUM(
            mec_exam_weight * ferritin_lt15_flag
        ) / 1000000.0,
        2
    ) AS weighted_lt15_population_millions,

    ROUND(
        SUM(
            mec_exam_weight
            * ferritin_lt30_sensitivity_flag
        ) / 1000000.0,
        2
    ) AS weighted_lt30_population_millions,

    ROUND(
        SUM(
            mec_exam_weight
            * ferritin_lt50_sensitivity_flag
        ) / 1000000.0,
        2
    ) AS weighted_lt50_population_millions

FROM analytics.nhanes_ferritin_flags

WHERE female_20_44_nonpregnant_flag = 1;


-- ============================================================
-- BLOCK 6 — FEMALE 20-44 NON-PREGNANT BY AGE BAND
--
-- PURPOSE:
-- Test whether the low-ferritin signal is concentrated within
-- particular age bands rather than treating ages 20-44 as homogeneous.
--
-- BUSINESS USE:
-- A concentrated age group could inform the first consumer
-- persona, clinical validation recruitment, and messaging.
-- ============================================================

WITH female_age_bands AS (

    SELECT
        *,

        CASE
            WHEN age_years BETWEEN 20 AND 29
                THEN '20-29'

            WHEN age_years BETWEEN 30 AND 39
                THEN '30-39'

            ELSE '40-44'
        END AS female_age_band

    FROM analytics.nhanes_ferritin_flags

    WHERE female_20_44_nonpregnant_flag = 1
)

SELECT
    female_age_band,

    COUNT(*) AS unweighted_n,

    SUM(ferritin_lt15_flag)
        AS unweighted_lt15_n,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight * ferritin_lt15_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt15_pct,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight
            * ferritin_lt30_sensitivity_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt30_pct,

    ROUND(
        MEDIAN(ferritin_ng_ml),
        2
    ) AS unweighted_median_ferritin

FROM female_age_bands

GROUP BY female_age_band

ORDER BY
    CASE female_age_band
        WHEN '20-29' THEN 1
        WHEN '30-39' THEN 2
        ELSE 3
    END;


-- ============================================================
-- BLOCK 7 — PREGNANCY DESCRIPTIVE ANALYSIS
--
-- PURPOSE:
-- Describe ferritin among pregnant females ages 20-44 WITHOUT
-- classifying them as iron deficient using the general <15 cutoff.
--
-- WHY:
-- WHO notes that ferritin declines during pregnancy and does not
-- provide a general ferritin cutoff for pregnant women.
--
-- This population may be commercially important later, but it
-- requires pregnancy-specific clinical interpretation.
-- ============================================================

SELECT
    COUNT(*) AS pregnant_unweighted_n,

    ROUND(
        QUANTILE_CONT(ferritin_ng_ml, 0.25),
        2
    ) AS ferritin_p25,

    ROUND(
        MEDIAN(ferritin_ng_ml),
        2
    ) AS ferritin_median,

    ROUND(
        QUANTILE_CONT(ferritin_ng_ml, 0.75),
        2
    ) AS ferritin_p75,

    MIN(ferritin_ng_ml)
        AS minimum_ferritin,

    MAX(ferritin_ng_ml)
        AS maximum_ferritin

FROM analytics.nhanes_ferritin_flags

WHERE female_20_44_pregnant_flag = 1;


-- ============================================================
-- BLOCK 8 — INCOME GRADIENT AMONG NON-PREGNANT FEMALES 20-44
--
-- PURPOSE:
-- Test whether depleted iron stores are concentrated by household
-- income-to-poverty ratio.
--
-- BUSINESS QUESTION:
-- Is biological need disproportionately concentrated among groups
-- that may also face affordability/access barriers?
--
-- IMPORTANT:
-- Income is missing for some participants. "Missing" remains an
-- explicit category rather than silently deleting those respondents.
-- ============================================================

SELECT
    income_poverty_ratio_band,

    COUNT(*) AS unweighted_n,

    SUM(ferritin_lt15_flag)
        AS unweighted_lt15_n,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight * ferritin_lt15_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt15_pct,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight
            * ferritin_lt30_sensitivity_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt30_pct

FROM analytics.nhanes_ferritin_flags

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
-- BLOCK 9 — RACE / ETHNICITY SEGMENTATION
--
-- PURPOSE:
-- Explore whether ferritin <15 varies across demographic groups among
-- non-pregnant females ages 20-44.
--
-- IMPORTANT:
-- This is descriptive segmentation, not a causal interpretation.
-- Sample size should always be reviewed before interpreting subgroup
-- percentages.
-- ============================================================

SELECT
    race_ethnicity,

    COUNT(*) AS unweighted_n,

    SUM(ferritin_lt15_flag)
        AS unweighted_lt15_n,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight * ferritin_lt15_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt15_pct,

    ROUND(
        100.0
        * SUM(
            mec_exam_weight
            * ferritin_lt30_sensitivity_flag
        )
        / SUM(mec_exam_weight),
        2
    ) AS weighted_lt30_pct

FROM analytics.nhanes_ferritin_flags

WHERE female_20_44_nonpregnant_flag = 1

GROUP BY race_ethnicity

ORDER BY weighted_lt15_pct DESC;


-- ============================================================
-- BLOCK 10 — FERRITIN SENSITIVITY BANDS: NON-PREGNANT FEMALES 20-44
--
-- PURPOSE:
-- Show how the target population is distributed across mutually
-- exclusive ferritin bands.
--
-- BUSINESS USE:
-- This is more informative for future test threshold design than
-- looking at a single cutoff alone.
--
-- IMPORTANT:
-- Only the <15 band is labeled WHO depleted iron stores.
-- The remaining bands are analytic sensitivity bands.
-- ============================================================

SELECT
    ferritin_sensitivity_band,

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

FROM analytics.nhanes_ferritin_flags

WHERE female_20_44_nonpregnant_flag = 1

GROUP BY ferritin_sensitivity_band

ORDER BY
    CASE ferritin_sensitivity_band
        WHEN '<15: WHO depleted stores' THEN 1
        WHEN '15-29.9' THEN 2
        WHEN '30-49.9' THEN 3
        ELSE 4
    END;


-- ============================================================
-- BLOCK 11 — CREATE SEGMENT × THRESHOLD MART
--
-- PURPOSE:
-- Create a compact output table for future reporting and comparison.
--
-- GRAIN:
-- One row per population segment + ferritin threshold.
--
-- SEGMENTS:
--   Adults 18+
--   Adult women 18+
--   Adult men 18+
--   Non-pregnant females 20-44
--
-- Pregnancy is intentionally excluded from threshold classification.
-- ============================================================

CREATE OR REPLACE TABLE mart.nhanes_ferritin_threshold_by_segment AS

WITH segment_membership AS (

    SELECT
        patient_id,
        'Adults 18+' AS population_segment,
        ferritin_ng_ml,
        mec_exam_weight
    FROM analytics.nhanes_ferritin_flags
    WHERE age_years >= 18
      AND NOT (
          sex = 'Female'
          AND age_years BETWEEN 20 AND 44
          AND pregnancy_status = 'Pregnant'
      )

    UNION ALL

    SELECT
        patient_id,
        'Adult women 18+',
        ferritin_ng_ml,
        mec_exam_weight
    FROM analytics.nhanes_ferritin_flags
    WHERE sex = 'Female'
      AND age_years >= 18
      AND NOT (
          age_years BETWEEN 20 AND 44
          AND pregnancy_status = 'Pregnant'
      )

    UNION ALL

    SELECT
        patient_id,
        'Adult men 18+',
        ferritin_ng_ml,
        mec_exam_weight
    FROM analytics.nhanes_ferritin_flags
    WHERE sex = 'Male'
      AND age_years >= 18

    UNION ALL

    SELECT
        patient_id,
        'Non-pregnant females 20-44',
        ferritin_ng_ml,
        mec_exam_weight
    FROM analytics.nhanes_ferritin_flags
    WHERE female_20_44_nonpregnant_flag = 1
),

thresholds AS (

    SELECT 15.0 AS ferritin_threshold_ng_ml,
           '<15 WHO depleted stores' AS threshold_label,
           1 AS threshold_order

    UNION ALL

    SELECT 30.0,
           '<30 sensitivity',
           2

    UNION ALL

    SELECT 50.0,
           '<50 sensitivity',
           3
)

SELECT
    s.population_segment,
    t.threshold_label,
    t.ferritin_threshold_ng_ml,

    COUNT(*) AS unweighted_denominator,

    COUNT_IF(
        s.ferritin_ng_ml
        < t.ferritin_threshold_ng_ml
    ) AS unweighted_below_threshold_n,

    ROUND(
        100.0
        * SUM(
            CASE
                WHEN s.ferritin_ng_ml
                     < t.ferritin_threshold_ng_ml
                    THEN s.mec_exam_weight
                ELSE 0
            END
        )
        / SUM(s.mec_exam_weight),
        2
    ) AS weighted_below_threshold_pct,

    ROUND(
        SUM(
            CASE
                WHEN s.ferritin_ng_ml
                     < t.ferritin_threshold_ng_ml
                    THEN s.mec_exam_weight
                ELSE 0
            END
        ) / 1000000.0,
        2
    ) AS weighted_population_millions,

    t.threshold_order

FROM segment_membership AS s

CROSS JOIN thresholds AS t

GROUP BY
    s.population_segment,
    t.threshold_label,
    t.ferritin_threshold_ng_ml,
    t.threshold_order;


-- ============================================================
-- BLOCK 12 — REVIEW SEGMENT × THRESHOLD MART
--
-- PURPOSE:
-- Compare how estimated prevalence changes across populations and
-- threshold scenarios.
--
-- This is likely the most commercially useful output from 04.
-- ============================================================

SELECT
    population_segment,
    threshold_label,
    unweighted_denominator,
    unweighted_below_threshold_n,
    weighted_below_threshold_pct,
    weighted_population_millions

FROM mart.nhanes_ferritin_threshold_by_segment

ORDER BY
    CASE population_segment
        WHEN 'Adults 18+' THEN 1
        WHEN 'Adult women 18+' THEN 2
        WHEN 'Adult men 18+' THEN 3
        ELSE 4
    END,
    threshold_order;


-- ============================================================
-- BLOCK 13 — QA: WEIGHTED PERCENTAGES MUST BE LOGICALLY NESTED
--
-- PURPOSE:
-- Ensure that broader thresholds never produce a smaller prevalence
-- estimate than narrower thresholds within the same population.
--
-- EXPECTED:
-- validation_status = PASS for every segment.
-- ============================================================

WITH pivoted AS (

    SELECT
        population_segment,

        MAX(
            CASE
                WHEN ferritin_threshold_ng_ml = 15
                    THEN weighted_below_threshold_pct
            END
        ) AS pct_lt15,

        MAX(
            CASE
                WHEN ferritin_threshold_ng_ml = 30
                    THEN weighted_below_threshold_pct
            END
        ) AS pct_lt30,

        MAX(
            CASE
                WHEN ferritin_threshold_ng_ml = 50
                    THEN weighted_below_threshold_pct
            END
        ) AS pct_lt50

    FROM mart.nhanes_ferritin_threshold_by_segment

    GROUP BY population_segment
)

SELECT
    population_segment,
    pct_lt15,
    pct_lt30,
    pct_lt50,

    CASE
        WHEN pct_lt15 <= pct_lt30
         AND pct_lt30 <= pct_lt50
            THEN 'PASS'
        ELSE 'REVIEW'
    END AS validation_status

FROM pivoted

ORDER BY population_segment;


-- ============================================================
-- BLOCK 14 — COMPLETION CHECK
--
-- PURPOSE:
-- Confirm the ferritin analysis is technically ready to move to the
-- next file: low ferritin without anemia.
--
-- PASS requires:
--   - preserved participant grain
--   - nested threshold logic
--   - a non-empty segment-threshold mart
-- ============================================================

WITH qa AS (

    SELECT
        (
            SELECT COUNT(*)
            FROM analytics.nhanes_ferritin_flags
        ) AS flag_rows,

        (
            SELECT COUNT(DISTINCT patient_id)
            FROM analytics.nhanes_ferritin_flags
        ) AS unique_participants,

        (
            SELECT COUNT(*)
            FROM mart.nhanes_ferritin_threshold_by_segment
        ) AS mart_rows,

        (
            SELECT COUNT(*)
            FROM (
                SELECT population_segment
                FROM mart.nhanes_ferritin_threshold_by_segment
                GROUP BY population_segment
                HAVING
                    MAX(
                        CASE WHEN ferritin_threshold_ng_ml = 15
                             THEN weighted_below_threshold_pct END
                    )
                    <=
                    MAX(
                        CASE WHEN ferritin_threshold_ng_ml = 30
                             THEN weighted_below_threshold_pct END
                    )
                AND
                    MAX(
                        CASE WHEN ferritin_threshold_ng_ml = 30
                             THEN weighted_below_threshold_pct END
                    )
                    <=
                    MAX(
                        CASE WHEN ferritin_threshold_ng_ml = 50
                             THEN weighted_below_threshold_pct END
                    )
            )
        ) AS segments_passing_nesting
)

SELECT
    flag_rows,
    unique_participants,
    mart_rows,
    segments_passing_nesting,

    CASE
        WHEN flag_rows = 10546
         AND flag_rows = unique_participants
         AND mart_rows = 12
         AND segments_passing_nesting = 4
            THEN 'PASS'
        ELSE 'REVIEW'
    END AS ferritin_analysis_status

FROM qa;
