-- ============================================================
-- 03_define_target_population.sql
--
-- PURPOSE
-- -------
-- Build one person-level MEPS table with iron-pathway segment flags,
-- then a long segment-membership table (segments overlap).
--
-- SEGMENTS (adults 18+, MEPS 2023, self/household-reported conditions)
--   Anemia diagnosis (D50/D64)    iron-deficiency or unspecified anemia
--   Iron-deficiency anemia (D50)
--   Heavy/irregular menstruation (N92), women
--   Pregnancy care (Z34), women
--   Symptom proxy (R53/R42/L65)   fatigue, dizziness, hair loss
--   Chronic kidney disease (N18)
--   Heart failure (I50)
--   References: all adults 18+, women 18-49
--
-- OUTPUTS
-- -------
-- analytics.meps_person_flags        one row per adult person
-- analytics.meps_segment_membership  one row per person + segment
-- ============================================================

CREATE OR REPLACE TABLE analytics.meps_person_flags AS
WITH condition_flags AS (
    SELECT
        DUPERSID,
        MAX(CASE WHEN ICD10CDX IN ('D50', 'D64') THEN 1 ELSE 0 END) AS anemia_flag,
        MAX(CASE WHEN ICD10CDX = 'D50' THEN 1 ELSE 0 END) AS iron_deficiency_anemia_flag,
        MAX(CASE WHEN ICD10CDX = 'N92' THEN 1 ELSE 0 END) AS heavy_menstruation_flag,
        MAX(CASE WHEN ICD10CDX = 'Z34' THEN 1 ELSE 0 END) AS pregnancy_care_flag,
        MAX(CASE WHEN ICD10CDX IN ('R53', 'R42', 'L65') THEN 1 ELSE 0 END) AS symptom_proxy_flag,
        MAX(CASE WHEN ICD10CDX = 'N18' THEN 1 ELSE 0 END) AS ckd_flag,
        MAX(CASE WHEN ICD10CDX = 'I50' THEN 1 ELSE 0 END) AS heart_failure_flag
    FROM meps.hc249_conditions
    GROUP BY DUPERSID
)
SELECT
    p.DUPERSID AS person_id,
    CASE WHEN p.SEX = 1 THEN 'Male' ELSE 'Female' END AS sex,
    p.AGE23X AS age_years,
    p.PERWT23F AS person_weight,
    p.VARSTR AS variance_stratum,
    p.VARPSU AS variance_psu,
    p.POVCAT23 AS poverty_category,
    CASE WHEN p.POVCAT23 IN (1, 2, 3) THEN 1 ELSE 0 END AS below_200pct_fpl_flag,
    p.INSCOV23 AS insurance_coverage_code,
    CASE p.INSCOV23 WHEN 1 THEN 'Any private' WHEN 2 THEN 'Public only'
                    WHEN 3 THEN 'Uninsured all year' END AS insurance_coverage,
    p.OBTOTV23 AS office_visits,
    p.OPTOTV23 AS outpatient_visits,
    p.ERTOT23 AS er_visits,
    p.IPDIS23 AS inpatient_discharges,
    p.TOTEXP23 AS total_expenditure,
    p.TOTSLF23 AS out_of_pocket_expenditure,
    CASE WHEN p.HAVEUS42 = 1 THEN 1 WHEN p.HAVEUS42 = 2 THEN 0 END AS usual_source_of_care_flag,
    CASE WHEN p.DLAYCA42 = 1 THEN 1 WHEN p.DLAYCA42 = 2 THEN 0 END AS delayed_medical_care_flag,
    CASE WHEN p.AFRDCA42 = 1 THEN 1 WHEN p.AFRDCA42 = 2 THEN 0 END AS could_not_afford_care_flag,
    COALESCE(c.anemia_flag, 0) AS anemia_flag,
    COALESCE(c.iron_deficiency_anemia_flag, 0) AS iron_deficiency_anemia_flag,
    COALESCE(c.heavy_menstruation_flag, 0) AS heavy_menstruation_flag,
    COALESCE(c.pregnancy_care_flag, 0) AS pregnancy_care_flag,
    COALESCE(c.symptom_proxy_flag, 0) AS symptom_proxy_flag,
    COALESCE(c.ckd_flag, 0) AS ckd_flag,
    COALESCE(c.heart_failure_flag, 0) AS heart_failure_flag
FROM meps.hc251_person AS p
LEFT JOIN condition_flags AS c ON p.DUPERSID = c.DUPERSID
WHERE p.PERWT23F > 0
  AND p.AGE23X >= 18;

CREATE OR REPLACE TABLE analytics.meps_segment_membership AS
SELECT 1 AS segment_order, 'Reference' AS segment_type, 'All adults 18+' AS population_segment, *
FROM analytics.meps_person_flags
UNION ALL
SELECT 2, 'Reference', 'Women 18-49', *
FROM analytics.meps_person_flags WHERE sex = 'Female' AND age_years <= 49
UNION ALL
SELECT 3, 'Iron pathway', 'Anemia diagnosis (D50/D64)', *
FROM analytics.meps_person_flags WHERE anemia_flag = 1
UNION ALL
SELECT 4, 'Iron pathway', 'Iron-deficiency anemia (D50)', *
FROM analytics.meps_person_flags WHERE iron_deficiency_anemia_flag = 1
UNION ALL
SELECT 5, 'Women''s health', 'Heavy/irregular menstruation (N92)', *
FROM analytics.meps_person_flags WHERE heavy_menstruation_flag = 1 AND sex = 'Female'
UNION ALL
SELECT 6, 'Women''s health', 'Pregnancy care (Z34)', *
FROM analytics.meps_person_flags WHERE pregnancy_care_flag = 1 AND sex = 'Female'
UNION ALL
SELECT 7, 'Symptom proxy', 'Fatigue / dizziness / hair loss', *
FROM analytics.meps_person_flags WHERE symptom_proxy_flag = 1
UNION ALL
SELECT 8, 'Chronic condition', 'Chronic kidney disease (N18)', *
FROM analytics.meps_person_flags WHERE ckd_flag = 1
UNION ALL
SELECT 9, 'Chronic condition', 'Heart failure (I50)', *
FROM analytics.meps_person_flags WHERE heart_failure_flag = 1;

-- VALIDATION
SELECT
    (SELECT COUNT(*) FROM analytics.meps_person_flags) AS adult_persons,
    (SELECT COUNT(DISTINCT person_id) FROM analytics.meps_person_flags) AS unique_adults,
    (SELECT COUNT(DISTINCT population_segment) FROM analytics.meps_segment_membership) AS segments,
    CASE WHEN (SELECT COUNT(*) FROM analytics.meps_person_flags)
            = (SELECT COUNT(DISTINCT person_id) FROM analytics.meps_person_flags)
          AND (SELECT COUNT(DISTINCT population_segment) FROM analytics.meps_segment_membership) = 9
          AND (SELECT COUNT(*) FROM analytics.meps_segment_membership
                WHERE population_segment = 'Iron-deficiency anemia (D50)')
           <= (SELECT COUNT(*) FROM analytics.meps_segment_membership
                WHERE population_segment = 'Anemia diagnosis (D50/D64)')
         THEN 'PASS' ELSE 'REVIEW' END AS meps_population_status;

SELECT population_segment, COUNT(*) AS persons,
       ROUND(SUM(person_weight) / 1e6, 2) AS weighted_population_millions
FROM analytics.meps_segment_membership
GROUP BY segment_order, population_segment
ORDER BY segment_order;
