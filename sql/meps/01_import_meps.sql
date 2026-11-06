-- ============================================================
-- 01_import_meps.sql
--
-- PURPOSE
-- -------
-- Import the two public MEPS 2023 files used in this project.
--
--   HC-251  2023 Full-Year Consolidated file
--           one row per person; utilization, expenditure,
--           insurance, income and survey-design variables
--
--   HC-249  2023 Medical Conditions file
--           one row per person + reported condition (ICD-10 3-digit)
--
-- Both files are loaded unchanged. Paths are relative to the repo root.
-- ============================================================

INSTALL excel;
LOAD excel;

CREATE SCHEMA IF NOT EXISTS meps;

CREATE OR REPLACE TABLE meps.hc251_person AS
SELECT * FROM read_xlsx('data/raw/meps/h251/h251.xlsx', header = true);

CREATE OR REPLACE TABLE meps.hc249_conditions AS
SELECT * FROM read_xlsx('data/raw/meps/h249/h249.xlsx', header = true);

-- Grain checks: HC-251 = one row per person; HC-249 = one row per condition.
SELECT
    (SELECT COUNT(*) FROM meps.hc251_person)                AS person_rows,
    (SELECT COUNT(DISTINCT DUPERSID) FROM meps.hc251_person) AS unique_people,
    (SELECT COUNT(*) FROM meps.hc249_conditions)             AS condition_rows,
    (SELECT COUNT(DISTINCT CONDIDX) FROM meps.hc249_conditions) AS unique_condition_ids,
    CASE WHEN (SELECT COUNT(*) FROM meps.hc251_person)
            = (SELECT COUNT(DISTINCT DUPERSID) FROM meps.hc251_person)
          AND (SELECT COUNT(*) FROM meps.hc249_conditions)
            = (SELECT COUNT(DISTINCT CONDIDX) FROM meps.hc249_conditions)
         THEN 'PASS' ELSE 'REVIEW' END AS import_status;
