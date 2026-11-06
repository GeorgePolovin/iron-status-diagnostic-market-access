-- ============================================================
-- 06_risk_segment_analysis.sql
--
-- PURPOSE
-- -------
-- Answer the analysis plan's segment questions with real NHANES data:
--
--   How does iron-store risk differ among menstruating women,
--   highly active people, pregnant people, lower-income families,
--   people with chronic kidney disease and people with heart failure?
--
--   Which populations combine HIGH clinical need with LIMITED access
--   to testing (no insurance / no routine place of care)?
--
-- SEGMENT DEFINITIONS (self-reported questionnaire + measured labs)
-- -------------------
--   Menstruating women 18-49   RHQ031 = 1 (regular periods, past 12 mo),
--                              not pregnant
--   Highly active women 18-49  >=150 min/week vigorous recreational
--                              activity (PAQ655 x PAD660), not pregnant.
--                              150 vigorous min = 2x the US guideline
--                              minimum; a proxy for "athlete-like", not
--                              a measure of competitive sport.
--   Highly active men 18+      same activity definition (comparison)
--   Pregnant women 20-44       RIDEXPRG = 1 (only ages 20-44 released)
--   Lower-income women 18-49   family income-to-poverty ratio < 1.0,
--                              not pregnant
--   Adults with weak/failing   KIQ022 = 1
--   kidneys
--   Adults with heart failure  MCQ160B = 1
--   Reference groups           all non-pregnant adults 18+,
--                              non-pregnant women 18-49, men 18+
--
-- Segments overlap by design (a woman can be menstruating, highly
-- active and lower income); each row answers a separate question.
--
-- IRON-STATUS DEFINITIONS
-- -----------------------
--   ferritin <15 ng/mL        WHO depleted iron stores (primary)
--   ferritin <30 ng/mL        common clinical sensitivity threshold
--   chronic-disease ID        ferritin <100, or ferritin 100-299 with
--                             transferrin saturation <20%. This is the
--                             definition used in heart-failure and CKD
--                             guidance, where inflammation raises ferritin.
--   anemia (WHO)              Hb <12.0 g/dL non-pregnant women,
--                             <11.0 pregnant women, <13.0 men
--   low ferritin without      ferritin <15 AND Hb at/above the cutoff
--   anemia
--
-- ACCESS INDICATORS
-- -----------------
--   uninsured                 HIQ011 = 2
--   no routine place of care  HUQ030 = 2
--   below poverty             family income-to-poverty ratio < 1.0
--
-- WEIGHTING
-- ---------
-- Percentages and population counts use the MEC exam weight WTMECPRP
-- (2017-March 2020 pre-pandemic combined). Design-based 95% confidence
-- intervals for the headline estimates are computed in
-- scripts/build_tfl.py using strata/PSU (Taylor linearization).
--
-- OUTPUTS
-- -------
-- analytics.nhanes_segment_participants   one row per participant
-- mart.nhanes_risk_segment_summary        one row per segment
-- ============================================================


-- ============================================================
-- BLOCK 1 — PARTICIPANT-LEVEL SEGMENT AND ACCESS FLAGS
-- ============================================================

CREATE OR REPLACE TABLE analytics.nhanes_segment_participants AS
WITH base AS (
    SELECT
        f.*,
        r.RHQ031 AS regular_periods_code,
        p.PAQ650 AS vigorous_recreation_code,
        CASE
            WHEN p.PAQ650 = 2 THEN 0
            WHEN p.PAQ650 = 1
             AND p.PAQ655 BETWEEN 1 AND 7
             AND p.PAD660 BETWEEN 10 AND 1440
                THEN p.PAQ655 * p.PAD660
            ELSE NULL
        END AS vigorous_recreation_min_week,
        m.MCQ160B AS heart_failure_code,
        k.KIQ022 AS weak_kidneys_code,
        h.HIQ011 AS insured_code,
        u.HUQ030 AS routine_place_code
    FROM analytics.nhanes_early_iron_depletion_flags AS f
    LEFT JOIN nhanes.rhq_raw AS r ON f.patient_id = r.SEQN
    LEFT JOIN nhanes.paq_raw AS p ON f.patient_id = p.SEQN
    LEFT JOIN nhanes.mcq_raw AS m ON f.patient_id = m.SEQN
    LEFT JOIN nhanes.kiq_raw AS k ON f.patient_id = k.SEQN
    LEFT JOIN nhanes.hiq_raw AS h ON f.patient_id = h.SEQN
    LEFT JOIN nhanes.huq_raw AS u ON f.patient_id = u.SEQN
    WHERE f.age_years >= 18
)
SELECT
    *,

    CASE WHEN sex = 'Female' AND pregnancy_status = 'Pregnant'
         THEN 1 ELSE 0 END AS pregnant_flag,

    -- WHO anemia cutoffs applied to every adult
    CASE
        WHEN sex = 'Female' AND pregnancy_status = 'Pregnant'
            THEN CASE WHEN hemoglobin_g_dl < 11.0 THEN 1 ELSE 0 END
        WHEN sex = 'Female'
            THEN CASE WHEN hemoglobin_g_dl < 12.0 THEN 1 ELSE 0 END
        ELSE CASE WHEN hemoglobin_g_dl < 13.0 THEN 1 ELSE 0 END
    END AS adult_anemia_flag,

    CASE
        WHEN ferritin_ng_ml < 100 THEN 1
        WHEN ferritin_ng_ml < 300 AND transferrin_saturation_pct < 20 THEN 1
        WHEN ferritin_ng_ml < 300 AND transferrin_saturation_pct IS NULL THEN NULL
        ELSE 0
    END AS chronic_disease_iron_deficiency_flag,

    CASE WHEN vigorous_recreation_min_week >= 150 THEN 1
         WHEN vigorous_recreation_min_week IS NOT NULL THEN 0
         END AS highly_active_flag,

    CASE WHEN insured_code = 2 THEN 1
         WHEN insured_code = 1 THEN 0 END AS uninsured_flag,

    CASE WHEN routine_place_code = 2 THEN 1
         WHEN routine_place_code IN (1, 3) THEN 0 END AS no_routine_place_flag,

    CASE WHEN family_income_poverty_ratio < 1.0 THEN 1
         WHEN family_income_poverty_ratio IS NOT NULL THEN 0 END AS below_poverty_flag
FROM base;


-- BLOCK 2 — GRAIN CHECK
SELECT
    COUNT(*) AS adult_participants,
    COUNT(DISTINCT patient_id) AS unique_participants,
    CASE WHEN COUNT(*) = COUNT(DISTINCT patient_id) AND COUNT(*) > 0
         THEN 'PASS' ELSE 'REVIEW' END AS segment_grain_status
FROM analytics.nhanes_segment_participants;


-- ============================================================
-- BLOCK 3 — SEGMENT MEMBERSHIP (long format; segments overlap)
-- ============================================================

CREATE OR REPLACE TABLE analytics.nhanes_segment_membership AS
SELECT 1 AS segment_order, 'Reference' AS segment_type,
       'All non-pregnant adults 18+' AS population_segment, *
FROM analytics.nhanes_segment_participants WHERE pregnant_flag = 0
UNION ALL
SELECT 2, 'Reference', 'Men 18+', *
FROM analytics.nhanes_segment_participants WHERE sex = 'Male'
UNION ALL
SELECT 3, 'Reference', 'Non-pregnant women 18-49', *
FROM analytics.nhanes_segment_participants
WHERE sex = 'Female' AND age_years <= 49 AND pregnant_flag = 0
UNION ALL
SELECT 4, 'Priority segment', 'Menstruating women 18-49', *
FROM analytics.nhanes_segment_participants
WHERE sex = 'Female' AND age_years <= 49 AND pregnant_flag = 0
  AND regular_periods_code = 1
UNION ALL
SELECT 5, 'Priority segment', 'Highly active women 18-49', *
FROM analytics.nhanes_segment_participants
WHERE sex = 'Female' AND age_years <= 49 AND pregnant_flag = 0
  AND highly_active_flag = 1
UNION ALL
SELECT 6, 'Priority segment', 'Lower-income women 18-49', *
FROM analytics.nhanes_segment_participants
WHERE sex = 'Female' AND age_years <= 49 AND pregnant_flag = 0
  AND below_poverty_flag = 1
UNION ALL
SELECT 7, 'Comparison', 'Highly active men 18+', *
FROM analytics.nhanes_segment_participants
WHERE sex = 'Male' AND highly_active_flag = 1
UNION ALL
SELECT 8, 'Clinician-supervised', 'Pregnant women 20-44', *
FROM analytics.nhanes_segment_participants WHERE pregnant_flag = 1
UNION ALL
SELECT 9, 'Clinician-supervised', 'Adults with weak/failing kidneys', *
FROM analytics.nhanes_segment_participants WHERE weak_kidneys_code = 1
UNION ALL
SELECT 10, 'Clinician-supervised', 'Adults with heart failure', *
FROM analytics.nhanes_segment_participants WHERE heart_failure_code = 1;


-- ============================================================
-- BLOCK 4 — SEGMENT SUMMARY MART
--
-- Weighted percentages use only participants with a known value for
-- the indicator in the denominator (e.g. TSAT-dependent flags).
-- ============================================================

CREATE OR REPLACE TABLE mart.nhanes_risk_segment_summary AS
SELECT
    segment_order,
    segment_type,
    population_segment,
    COUNT(*) AS unweighted_n,
    ROUND(SUM(mec_exam_weight) / 1e6, 2) AS weighted_population_millions,

    SUM(ferritin_lt15_flag) AS unweighted_ferritin_lt15_n,
    ROUND(100.0 * SUM(mec_exam_weight * ferritin_lt15_flag)
          / SUM(mec_exam_weight), 2) AS weighted_ferritin_lt15_pct,
    ROUND(SUM(mec_exam_weight * ferritin_lt15_flag) / 1e6, 2)
        AS weighted_ferritin_lt15_millions,

    ROUND(100.0 * SUM(mec_exam_weight * ferritin_lt30_sensitivity_flag)
          / SUM(mec_exam_weight), 2) AS weighted_ferritin_lt30_pct,

    ROUND(100.0 * SUM(mec_exam_weight * adult_anemia_flag)
          / SUM(mec_exam_weight), 2) AS weighted_anemia_pct,

    ROUND(100.0 * SUM(mec_exam_weight
                      * CASE WHEN ferritin_lt15_flag = 1 AND adult_anemia_flag = 0
                             THEN 1 ELSE 0 END)
          / SUM(mec_exam_weight), 2) AS weighted_lt15_without_anemia_pct,

    ROUND(100.0 * SUM(mec_exam_weight
                      * CASE WHEN ferritin_lt15_flag = 1 AND adult_anemia_flag = 0
                             THEN 1 ELSE 0 END)
          / NULLIF(SUM(mec_exam_weight * ferritin_lt15_flag), 0), 2)
        AS weighted_pct_of_lt15_without_anemia,

    ROUND(100.0 * SUM(CASE WHEN chronic_disease_iron_deficiency_flag = 1
                           THEN mec_exam_weight ELSE 0 END)
          / NULLIF(SUM(CASE WHEN chronic_disease_iron_deficiency_flag IS NOT NULL
                            THEN mec_exam_weight ELSE 0 END), 0), 2)
        AS weighted_chronic_disease_id_pct,

    ROUND(100.0 * SUM(CASE WHEN uninsured_flag = 1 THEN mec_exam_weight ELSE 0 END)
          / NULLIF(SUM(CASE WHEN uninsured_flag IS NOT NULL
                            THEN mec_exam_weight ELSE 0 END), 0), 2)
        AS weighted_uninsured_pct,

    ROUND(100.0 * SUM(CASE WHEN no_routine_place_flag = 1 THEN mec_exam_weight ELSE 0 END)
          / NULLIF(SUM(CASE WHEN no_routine_place_flag IS NOT NULL
                            THEN mec_exam_weight ELSE 0 END), 0), 2)
        AS weighted_no_routine_place_pct,

    ROUND(100.0 * SUM(CASE WHEN below_poverty_flag = 1 THEN mec_exam_weight ELSE 0 END)
          / NULLIF(SUM(CASE WHEN below_poverty_flag IS NOT NULL
                            THEN mec_exam_weight ELSE 0 END), 0), 2)
        AS weighted_below_poverty_pct,

    ROUND(100.0 * SUM(CASE WHEN family_income_poverty_ratio >= 4 THEN mec_exam_weight ELSE 0 END)
          / NULLIF(SUM(CASE WHEN family_income_poverty_ratio IS NOT NULL
                            THEN mec_exam_weight ELSE 0 END), 0), 2)
        AS weighted_income_4x_poverty_plus_pct,

    ROUND(MEDIAN(ferritin_ng_ml), 1) AS unweighted_median_ferritin_ng_ml,

    CASE WHEN COUNT(*) < 100 THEN 'Interpret with caution: n < 100'
         ELSE 'Adequate sample' END AS sample_size_note
FROM analytics.nhanes_segment_membership
GROUP BY segment_order, segment_type, population_segment;


-- BLOCK 5 — REVIEW
SELECT *
FROM mart.nhanes_risk_segment_summary
ORDER BY segment_order;


-- ============================================================
-- BLOCK 6 — VALIDATION
--   * 10 segments
--   * the women 18-49 reference group contains every women-only
--     priority segment (subset logic)
--   * nested thresholds: <15 never exceeds <30
-- ============================================================

WITH checks AS (
    SELECT
        (SELECT COUNT(*) FROM mart.nhanes_risk_segment_summary) AS segments,
        (SELECT COUNT(*) FROM mart.nhanes_risk_segment_summary
          WHERE weighted_ferritin_lt15_pct > weighted_ferritin_lt30_pct) AS nesting_violations,
        (SELECT MAX(unweighted_n) FROM mart.nhanes_risk_segment_summary
          WHERE population_segment IN ('Menstruating women 18-49',
                                       'Highly active women 18-49',
                                       'Lower-income women 18-49'))
        <= (SELECT unweighted_n FROM mart.nhanes_risk_segment_summary
             WHERE population_segment = 'Non-pregnant women 18-49') AS subset_ok
)
SELECT
    segments,
    nesting_violations,
    subset_ok,
    CASE WHEN segments = 10 AND nesting_violations = 0 AND subset_ok
         THEN 'PASS' ELSE 'REVIEW' END AS risk_segment_status
FROM checks;
