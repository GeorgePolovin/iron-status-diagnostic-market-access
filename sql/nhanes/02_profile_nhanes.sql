-- ============================================================
-- 02_profile_nhanes.sql
--
-- PURPOSE
-- -------
-- Profile the imported NHANES 2017–March 2020 pre-pandemic files and
-- determine how many participants have the core information required
-- for the first unmet-need analysis.
--
-- PRIMARY BUSINESS QUESTION
-- -------------------------
-- How much usable NHANES data do we have to evaluate:
--   1. Ferritin / iron stores
--   2. Hemoglobin / anemia status
--   3. Age, sex, pregnancy status, and income
--   4. Nationally representative weighted estimates
--
-- THIS FILE DOES NOT YET DEFINE:
--   - low ferritin
--   - anemia
--   - low ferritin without anemia
--   - final target segments
--
-- SOURCE GRAIN
-- ------------
-- nhanes.demo_raw      = one row per NHANES participant
-- nhanes.cbc_raw       = one row per NHANES participant in CBC file
-- nhanes.ferritin_raw  = one row per NHANES participant in ferritin file
--
-- JOIN KEY
-- --------
-- SEQN = NHANES respondent sequence number / participant identifier.
-- ============================================================

-- BLOCK 1 — SOURCE TABLE GRAIN
SELECT 'demo_raw' AS table_name, COUNT(*) AS rows,
       COUNT(DISTINCT SEQN) AS unique_participants,
       COUNT(*) - COUNT(DISTINCT SEQN) AS duplicate_participant_rows
FROM nhanes.demo_raw
UNION ALL
SELECT 'cbc_raw', COUNT(*), COUNT(DISTINCT SEQN),
       COUNT(*) - COUNT(DISTINCT SEQN)
FROM nhanes.cbc_raw
UNION ALL
SELECT 'ferritin_raw', COUNT(*), COUNT(DISTINCT SEQN),
       COUNT(*) - COUNT(DISTINCT SEQN)
FROM nhanes.ferritin_raw;

-- BLOCK 2 — SOURCE PARTICIPANT OVERLAP
WITH participant_inventory AS (
    SELECT SEQN FROM nhanes.demo_raw
    UNION
    SELECT SEQN FROM nhanes.cbc_raw
    UNION
    SELECT SEQN FROM nhanes.ferritin_raw
),
availability AS (
    SELECT p.SEQN,
           CASE WHEN d.SEQN IS NOT NULL THEN 1 ELSE 0 END AS has_demo,
           CASE WHEN c.SEQN IS NOT NULL THEN 1 ELSE 0 END AS has_cbc,
           CASE WHEN f.SEQN IS NOT NULL THEN 1 ELSE 0 END AS has_ferritin
    FROM participant_inventory p
    LEFT JOIN nhanes.demo_raw d ON p.SEQN = d.SEQN
    LEFT JOIN nhanes.cbc_raw c ON p.SEQN = c.SEQN
    LEFT JOIN nhanes.ferritin_raw f ON p.SEQN = f.SEQN
)
SELECT has_demo, has_cbc, has_ferritin, COUNT(*) AS participants
FROM availability
GROUP BY has_demo, has_cbc, has_ferritin
ORDER BY has_demo DESC, has_cbc DESC, has_ferritin DESC;

-- BLOCK 3 — PARTICIPANTS PRESENT IN ALL THREE FILES
SELECT COUNT(*) AS participants_in_all_three_sources
FROM nhanes.demo_raw d
INNER JOIN nhanes.cbc_raw c ON d.SEQN = c.SEQN
INNER JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN;

-- BLOCK 4 — FERRITIN VARIABLE QA
SELECT COUNT(*) AS ferritin_file_rows,
       COUNT(LBXFER) AS nonmissing_lbxfer,
       COUNT(LBDFERSI) AS nonmissing_lbdfersi,
       COUNT_IF(LBXFER IS NULL) AS missing_lbxfer,
       COUNT_IF(LBDFERSI IS NULL) AS missing_lbdfersi,
       COUNT_IF(LBXFER IS NOT NULL AND LBDFERSI IS NOT NULL
                AND ABS(LBXFER - LBDFERSI) > 0.001)
           AS ferritin_unit_value_mismatches,
       MIN(LBXFER) AS minimum_ferritin_ng_ml,
       MEDIAN(LBXFER) AS median_ferritin_ng_ml,
       AVG(LBXFER) AS average_ferritin_ng_ml,
       MAX(LBXFER) AS maximum_ferritin_ng_ml
FROM nhanes.ferritin_raw;

-- BLOCK 5 — HEMOGLOBIN VARIABLE QA
SELECT COUNT(*) AS cbc_file_rows,
       COUNT(LBXHGB) AS nonmissing_hemoglobin,
       COUNT_IF(LBXHGB IS NULL) AS missing_hemoglobin,
       MIN(LBXHGB) AS minimum_hemoglobin_g_dl,
       MEDIAN(LBXHGB) AS median_hemoglobin_g_dl,
       AVG(LBXHGB) AS average_hemoglobin_g_dl,
       MAX(LBXHGB) AS maximum_hemoglobin_g_dl
FROM nhanes.cbc_raw;

-- BLOCK 6 — CORE LAB COMPLETENESS AFTER JOIN
SELECT COUNT(*) AS participants_in_join,
       COUNT_IF(f.LBXFER IS NOT NULL) AS participants_with_ferritin,
       COUNT_IF(c.LBXHGB IS NOT NULL) AS participants_with_hemoglobin,
       COUNT_IF(f.LBXFER IS NOT NULL AND c.LBXHGB IS NOT NULL)
           AS participants_with_ferritin_and_hemoglobin,
       COUNT_IF(f.LBXFER IS NULL OR c.LBXHGB IS NULL)
           AS participants_missing_one_or_both_core_labs
FROM nhanes.demo_raw d
INNER JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN
LEFT JOIN nhanes.cbc_raw c ON d.SEQN = c.SEQN;

-- BLOCK 7 — AGE COVERAGE OF FERRITIN DATA
SELECT CAST(d.RIDAGEYR AS INTEGER) AS age_years,
       COUNT(*) AS participants_in_ferritin_file,
       COUNT_IF(f.LBXFER IS NOT NULL) AS participants_with_ferritin,
       ROUND(100.0 * COUNT_IF(f.LBXFER IS NOT NULL)
             / NULLIF(COUNT(*), 0), 2) AS ferritin_nonmissing_pct
FROM nhanes.demo_raw d
INNER JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN
GROUP BY CAST(d.RIDAGEYR AS INTEGER)
ORDER BY age_years;

-- BLOCK 8 — SEX AND AGE PROFILE OF CORE LAB COHORT
SELECT d.RIAGENDR AS sex_code,
       CASE
           WHEN d.RIDAGEYR < 12 THEN 'Under 12'
           WHEN d.RIDAGEYR BETWEEN 12 AND 17 THEN '12-17'
           WHEN d.RIDAGEYR BETWEEN 18 AND 29 THEN '18-29'
           WHEN d.RIDAGEYR BETWEEN 30 AND 44 THEN '30-44'
           WHEN d.RIDAGEYR BETWEEN 45 AND 64 THEN '45-64'
           ELSE '65+'
       END AS age_group,
       COUNT(*) AS participants
FROM nhanes.demo_raw d
INNER JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN
INNER JOIN nhanes.cbc_raw c ON d.SEQN = c.SEQN
WHERE f.LBXFER IS NOT NULL AND c.LBXHGB IS NOT NULL
GROUP BY d.RIAGENDR, age_group
ORDER BY d.RIAGENDR, MIN(d.RIDAGEYR);

-- BLOCK 9 — PREGNANCY VARIABLE PROFILE
SELECT d.RIDEXPRG AS pregnancy_status_code,
       COUNT(*) AS participants,
       COUNT_IF(f.LBXFER IS NOT NULL AND c.LBXHGB IS NOT NULL)
           AS participants_with_core_labs
FROM nhanes.demo_raw d
LEFT JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN
LEFT JOIN nhanes.cbc_raw c ON d.SEQN = c.SEQN
WHERE d.RIAGENDR = 2
  AND d.RIDAGEYR BETWEEN 20 AND 44
GROUP BY d.RIDEXPRG
ORDER BY d.RIDEXPRG;

-- BLOCK 10 — FAMILY INCOME-TO-POVERTY RATIO PROFILE
SELECT COUNT(*) AS participants_with_core_labs,
       COUNT(INDFMPIR) AS participants_with_income_ratio,
       COUNT_IF(INDFMPIR IS NULL) AS participants_missing_income_ratio,
       ROUND(100.0 * COUNT_IF(INDFMPIR IS NULL)
             / NULLIF(COUNT(*), 0), 2) AS income_ratio_missing_pct,
       MIN(INDFMPIR) AS minimum_income_poverty_ratio,
       MEDIAN(INDFMPIR) AS median_income_poverty_ratio,
       AVG(INDFMPIR) AS average_income_poverty_ratio,
       MAX(INDFMPIR) AS maximum_income_poverty_ratio
FROM nhanes.demo_raw d
INNER JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN
INNER JOIN nhanes.cbc_raw c ON d.SEQN = c.SEQN
WHERE f.LBXFER IS NOT NULL AND c.LBXHGB IS NOT NULL;

-- BLOCK 11 — SURVEY DESIGN VARIABLE COMPLETENESS
SELECT COUNT(*) AS participants_with_core_labs,
       COUNT_IF(d.WTMECPRP IS NULL) AS missing_mec_weight,
       COUNT_IF(d.WTMECPRP <= 0) AS nonpositive_mec_weight,
       COUNT_IF(d.SDMVSTRA IS NULL) AS missing_variance_stratum,
       COUNT_IF(d.SDMVPSU IS NULL) AS missing_variance_psu
FROM nhanes.demo_raw d
INNER JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN
INNER JOIN nhanes.cbc_raw c ON d.SEQN = c.SEQN
WHERE f.LBXFER IS NOT NULL AND c.LBXHGB IS NOT NULL;

-- BLOCK 12 — RAW VS CORE-LAB COHORT SUMMARY
WITH counts AS (
    SELECT
        (SELECT COUNT(*) FROM nhanes.demo_raw) AS demographic_participants,
        (SELECT COUNT(*) FROM nhanes.cbc_raw) AS cbc_file_participants,
        (SELECT COUNT(*) FROM nhanes.ferritin_raw) AS ferritin_file_participants,
        (
            SELECT COUNT(*)
            FROM nhanes.demo_raw d
            INNER JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN
            INNER JOIN nhanes.cbc_raw c ON d.SEQN = c.SEQN
        ) AS participants_in_all_three,
        (
            SELECT COUNT(*)
            FROM nhanes.demo_raw d
            INNER JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN
            INNER JOIN nhanes.cbc_raw c ON d.SEQN = c.SEQN
            WHERE f.LBXFER IS NOT NULL AND c.LBXHGB IS NOT NULL
        ) AS participants_with_core_labs
)
SELECT *
FROM counts;

-- BLOCK 13 — PROFILE COMPLETION CHECK
WITH qa AS (
    SELECT
        (SELECT COUNT(*) - COUNT(DISTINCT SEQN) FROM nhanes.demo_raw)
            AS demo_duplicates,
        (SELECT COUNT(*) - COUNT(DISTINCT SEQN) FROM nhanes.cbc_raw)
            AS cbc_duplicates,
        (SELECT COUNT(*) - COUNT(DISTINCT SEQN) FROM nhanes.ferritin_raw)
            AS ferritin_duplicates,
        (
            SELECT COUNT(*)
            FROM nhanes.demo_raw d
            INNER JOIN nhanes.ferritin_raw f ON d.SEQN = f.SEQN
            INNER JOIN nhanes.cbc_raw c ON d.SEQN = c.SEQN
            WHERE f.LBXFER IS NOT NULL AND c.LBXHGB IS NOT NULL
        ) AS core_lab_participants
)
SELECT demo_duplicates, cbc_duplicates, ferritin_duplicates,
       core_lab_participants,
       CASE
           WHEN demo_duplicates = 0
            AND cbc_duplicates = 0
            AND ferritin_duplicates = 0
            AND core_lab_participants > 0
           THEN 'PASS'
           ELSE 'REVIEW'
       END AS profile_status
FROM qa;
