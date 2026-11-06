-- ============================================================
-- 04_utilization_access.sql
--
-- PURPOSE
-- -------
-- Where do iron-pathway patients receive care, how much do they use,
-- and which segments report access barriers?
--
-- All estimates are weighted with PERWT23F. Access items (round 4/2
-- of the panel) use only persons with a valid yes/no answer.
-- ============================================================

CREATE OR REPLACE TABLE mart.meps_utilization_access_by_segment AS
SELECT
    segment_order,
    segment_type,
    population_segment,
    COUNT(*) AS unweighted_n,
    ROUND(SUM(person_weight) / 1e6, 2) AS weighted_population_millions,
    ROUND(SUM(person_weight * office_visits) / SUM(person_weight), 2) AS mean_office_visits,
    ROUND(SUM(person_weight * outpatient_visits) / SUM(person_weight), 2) AS mean_outpatient_visits,
    ROUND(100.0 * SUM(CASE WHEN er_visits > 0 THEN person_weight ELSE 0 END)
          / SUM(person_weight), 2) AS pct_any_er_visit,
    ROUND(100.0 * SUM(CASE WHEN inpatient_discharges > 0 THEN person_weight ELSE 0 END)
          / SUM(person_weight), 2) AS pct_any_inpatient_stay,
    ROUND(100.0 * SUM(CASE WHEN usual_source_of_care_flag = 1 THEN person_weight ELSE 0 END)
          / NULLIF(SUM(CASE WHEN usual_source_of_care_flag IS NOT NULL THEN person_weight END), 0), 2)
        AS pct_usual_source_of_care,
    ROUND(100.0 * SUM(CASE WHEN delayed_medical_care_flag = 1 THEN person_weight ELSE 0 END)
          / NULLIF(SUM(CASE WHEN delayed_medical_care_flag IS NOT NULL THEN person_weight END), 0), 2)
        AS pct_delayed_medical_care,
    ROUND(100.0 * SUM(CASE WHEN could_not_afford_care_flag = 1 THEN person_weight ELSE 0 END)
          / NULLIF(SUM(CASE WHEN could_not_afford_care_flag IS NOT NULL THEN person_weight END), 0), 2)
        AS pct_could_not_afford_care,
    CASE WHEN COUNT(*) < 100 THEN 'Interpret with caution: n < 100'
         ELSE 'Adequate sample' END AS sample_size_note
FROM analytics.meps_segment_membership
GROUP BY segment_order, segment_type, population_segment;

SELECT * FROM mart.meps_utilization_access_by_segment ORDER BY segment_order;

SELECT
    COUNT(*) AS segments,
    COUNT_IF(pct_usual_source_of_care NOT BETWEEN 0 AND 100) AS out_of_range,
    CASE WHEN COUNT(*) = 9 AND COUNT_IF(pct_usual_source_of_care NOT BETWEEN 0 AND 100) = 0
         THEN 'PASS' ELSE 'REVIEW' END AS utilization_status
FROM mart.meps_utilization_access_by_segment;
