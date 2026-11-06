-- ============================================================
-- 06_meps_validation_exports.sql
-- Final MEPS reconciliation and exports for scripts/build_tfl.py.
-- ============================================================

CREATE OR REPLACE TABLE mart.meps_final_validation_summary AS
SELECT 1 AS check_order, 'Adults 18+ with positive person weight' AS check_name,
       CAST(COUNT(*) AS VARCHAR) AS observed_value,
       'equals reference segment n' AS expected_value,
       CASE WHEN COUNT(*) = (SELECT unweighted_n FROM mart.meps_utilization_access_by_segment
                              WHERE population_segment = 'All adults 18+')
            THEN 'PASS' ELSE 'REVIEW' END AS status
FROM analytics.meps_person_flags
UNION ALL
SELECT 2, 'Weighted adult population (millions)',
       CAST(ROUND(SUM(person_weight) / 1e6, 1) AS VARCHAR), '240-275 (US adults, 2023)',
       CASE WHEN SUM(person_weight) / 1e6 BETWEEN 240 AND 275 THEN 'PASS' ELSE 'REVIEW' END
FROM analytics.meps_person_flags
UNION ALL
SELECT 3, 'Segment marts aligned (utilization vs insurance)',
       CAST(COUNT(*) AS VARCHAR), '9 matching segments',
       CASE WHEN COUNT(*) = 9 THEN 'PASS' ELSE 'REVIEW' END
FROM mart.meps_utilization_access_by_segment AS u
INNER JOIN mart.meps_insurance_oop_by_segment AS i
    ON u.population_segment = i.population_segment AND u.unweighted_n = i.unweighted_n;

SELECT * FROM mart.meps_final_validation_summary ORDER BY check_order;

COPY (SELECT * FROM mart.meps_utilization_access_by_segment ORDER BY segment_order)
TO 'outputs/marts/meps_utilization_access_by_segment.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM mart.meps_insurance_oop_by_segment ORDER BY segment_order)
TO 'outputs/marts/meps_insurance_oop_by_segment.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM mart.meps_final_validation_summary ORDER BY check_order)
TO 'outputs/qa/meps_final_validation_summary.csv' (HEADER, DELIMITER ',');
