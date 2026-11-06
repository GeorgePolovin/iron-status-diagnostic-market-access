-- ============================================================
-- 07_nhanes_validation_exports.sql
--
-- PURPOSE
-- -------
-- Final reconciliation of the NHANES layer and export of the marts
-- used by scripts/build_tfl.py.
--
-- Every check returns PASS/REVIEW; run_pipeline.py stops on REVIEW.
-- ============================================================

CREATE OR REPLACE TABLE mart.nhanes_final_validation_summary AS
SELECT 1 AS check_order, 'Core analysis population (ferritin + Hb)' AS check_name,
       CAST(COUNT(*) AS VARCHAR) AS observed_value, '10546' AS expected_value,
       CASE WHEN COUNT(*) = 10546 THEN 'PASS' ELSE 'REVIEW' END AS status
FROM analytics.nhanes_core_analysis_population
UNION ALL
SELECT 2, 'Primary segment: non-pregnant females 20-44',
       CAST(COUNT(*) AS VARCHAR), '1517',
       CASE WHEN COUNT(*) = 1517 THEN 'PASS' ELSE 'REVIEW' END
FROM analytics.nhanes_early_iron_depletion_flags
WHERE female_20_44_nonpregnant_flag = 1
UNION ALL
SELECT 3, 'Iron/anemia stages sum to 100%',
       CAST(ROUND(SUM(weighted_population_pct), 2) AS VARCHAR), '100 +/- 0.05',
       CASE WHEN ABS(SUM(weighted_population_pct) - 100) <= 0.05 THEN 'PASS' ELSE 'REVIEW' END
FROM mart.nhanes_iron_status_stage_distribution
UNION ALL
SELECT 4, 'Stage counts reconcile to primary segment',
       CAST(SUM(unweighted_n) AS VARCHAR), '1517',
       CASE WHEN SUM(unweighted_n) = 1517 THEN 'PASS' ELSE 'REVIEW' END
FROM mart.nhanes_iron_status_stage_distribution
UNION ALL
SELECT 5, 'Threshold mart rows (4 segments x 3 thresholds)',
       CAST(COUNT(*) AS VARCHAR), '12',
       CASE WHEN COUNT(*) = 12 THEN 'PASS' ELSE 'REVIEW' END
FROM mart.nhanes_ferritin_threshold_by_segment
UNION ALL
SELECT 6, 'Risk segment mart rows',
       CAST(COUNT(*) AS VARCHAR), '10',
       CASE WHEN COUNT(*) = 10 THEN 'PASS' ELSE 'REVIEW' END
FROM mart.nhanes_risk_segment_summary
UNION ALL
SELECT 7, 'Adult segment table: one row per participant',
       CAST(COUNT(*) - COUNT(DISTINCT patient_id) AS VARCHAR), '0 duplicates',
       CASE WHEN COUNT(*) = COUNT(DISTINCT patient_id) THEN 'PASS' ELSE 'REVIEW' END
FROM analytics.nhanes_segment_participants;

SELECT * FROM mart.nhanes_final_validation_summary ORDER BY check_order;

COPY (SELECT * FROM mart.nhanes_ferritin_threshold_by_segment
      ORDER BY population_segment, threshold_order)
TO 'outputs/marts/nhanes_ferritin_threshold_by_segment.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM mart.nhanes_ferritin_inflammation_sensitivity ORDER BY analysis_order)
TO 'outputs/marts/nhanes_ferritin_inflammation_sensitivity.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM mart.nhanes_low_ferritin_without_anemia_summary ORDER BY definition_order)
TO 'outputs/marts/nhanes_low_ferritin_without_anemia_summary.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM mart.nhanes_iron_status_stage_distribution ORDER BY iron_status_stage)
TO 'outputs/marts/nhanes_iron_status_stage_distribution.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM mart.nhanes_risk_segment_summary ORDER BY segment_order)
TO 'outputs/marts/nhanes_risk_segment_summary.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM mart.nhanes_final_validation_summary ORDER BY check_order)
TO 'outputs/qa/nhanes_final_validation_summary.csv' (HEADER, DELIMITER ',');
