-- ============================================================
-- 02_profile_meps.sql
--
-- PURPOSE
-- -------
-- Profile MEPS 2023 before defining target populations:
--   * person-file grain and survey-weight completeness
--   * which iron-pathway ICD-10 codes actually appear in HC-249
--
-- MEPS releases ICD-10 codes collapsed to 3 digits (ICD10CDX), and
-- suppresses rare codes, so the analysis plan's 4-character codes
-- (e.g. D50.9, R53.83) are evaluated at their 3-digit parent.
-- Negative values in MEPS are reserved codes (-1 inapplicable,
-- -7 refused, -8 don't know, -15 cannot be computed).
-- ============================================================

-- BLOCK 1 — PERSON GRAIN AND WEIGHTS
SELECT
    COUNT(*) AS persons,
    COUNT(DISTINCT DUPERSID) AS unique_persons,
    COUNT_IF(PERWT23F > 0) AS persons_with_positive_weight,
    ROUND(SUM(PERWT23F) / 1e6, 1) AS weighted_us_population_millions,
    CASE WHEN COUNT(*) = COUNT(DISTINCT DUPERSID) THEN 'PASS' ELSE 'REVIEW' END
        AS person_grain_status
FROM meps.hc251_person;

-- BLOCK 2 — AGE AND SEX OF WEIGHTED POPULATION
SELECT
    CASE WHEN SEX = 1 THEN 'Male' ELSE 'Female' END AS sex,
    CASE WHEN AGE23X < 18 THEN '<18'
         WHEN AGE23X < 50 THEN '18-49'
         WHEN AGE23X < 65 THEN '50-64'
         ELSE '65+' END AS age_group,
    COUNT(*) AS persons,
    ROUND(SUM(PERWT23F) / 1e6, 1) AS weighted_population_millions
FROM meps.hc251_person
WHERE PERWT23F > 0 AND AGE23X >= 0
GROUP BY ALL
ORDER BY sex, age_group;

-- BLOCK 3 — IRON-PATHWAY ICD-10 CODES PRESENT IN HC-249
SELECT
    ICD10CDX AS icd10_3digit,
    COUNT(*) AS condition_rows,
    COUNT(DISTINCT DUPERSID) AS persons
FROM meps.hc249_conditions
WHERE ICD10CDX IN ('D50', 'D64', 'N92', 'Z34', 'R53', 'R42', 'L65', 'N18', 'I50')
GROUP BY ICD10CDX
ORDER BY ICD10CDX;

-- BLOCK 4 — CONDITION FILE LINKS TO PERSON FILE
SELECT
    COUNT(DISTINCT c.DUPERSID) AS condition_persons,
    COUNT(DISTINCT p.DUPERSID) AS linked_persons,
    CASE WHEN COUNT(DISTINCT c.DUPERSID) = COUNT(DISTINCT p.DUPERSID)
         THEN 'PASS' ELSE 'REVIEW' END AS condition_link_status
FROM meps.hc249_conditions AS c
LEFT JOIN meps.hc251_person AS p ON c.DUPERSID = p.DUPERSID;
