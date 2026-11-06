-- ============================================================
-- 05_insurance_oop.sql
--
-- PURPOSE
-- -------
-- How do insurance status, income and out-of-pocket (OOP) burden
-- differ across iron-pathway segments? These inform which segments
-- can self-pay for a home test and which need payer, employer or
-- community-health support.
--
-- MEPS expenditures are annual, all-cause, per person (2023 USD);
-- they are NOT costs of iron testing specifically.
-- ============================================================

CREATE OR REPLACE TABLE mart.meps_insurance_oop_by_segment AS
SELECT
    segment_order,
    segment_type,
    population_segment,
    COUNT(*) AS unweighted_n,
    ROUND(100.0 * SUM(CASE WHEN insurance_coverage_code = 1 THEN person_weight ELSE 0 END)
          / SUM(person_weight), 2) AS pct_any_private,
    ROUND(100.0 * SUM(CASE WHEN insurance_coverage_code = 2 THEN person_weight ELSE 0 END)
          / SUM(person_weight), 2) AS pct_public_only,
    ROUND(100.0 * SUM(CASE WHEN insurance_coverage_code = 3 THEN person_weight ELSE 0 END)
          / SUM(person_weight), 2) AS pct_uninsured_all_year,
    ROUND(100.0 * SUM(below_200pct_fpl_flag * person_weight)
          / SUM(person_weight), 2) AS pct_below_200pct_fpl,
    ROUND(SUM(person_weight * total_expenditure) / SUM(person_weight), 0) AS mean_total_expenditure_usd,
    ROUND(SUM(person_weight * out_of_pocket_expenditure) / SUM(person_weight), 0) AS mean_oop_expenditure_usd,
    ROUND(100.0 * SUM(person_weight * out_of_pocket_expenditure)
          / NULLIF(SUM(person_weight * total_expenditure), 0), 2) AS oop_share_of_spend_pct,
    CASE WHEN COUNT(*) < 100 THEN 'Interpret with caution: n < 100'
         ELSE 'Adequate sample' END AS sample_size_note
FROM analytics.meps_segment_membership
GROUP BY segment_order, segment_type, population_segment;

SELECT * FROM mart.meps_insurance_oop_by_segment ORDER BY segment_order;

-- Coverage categories must sum to ~100% in every segment.
SELECT
    MAX(ABS(pct_any_private + pct_public_only + pct_uninsured_all_year - 100)) AS max_coverage_gap,
    CASE WHEN MAX(ABS(pct_any_private + pct_public_only + pct_uninsured_all_year - 100)) <= 0.05
         THEN 'PASS' ELSE 'REVIEW' END AS coverage_mix_status
FROM mart.meps_insurance_oop_by_segment;
