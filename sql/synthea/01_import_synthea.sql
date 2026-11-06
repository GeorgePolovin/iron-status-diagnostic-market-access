-- ============================================================
-- 01_import_synthea.sql
--
-- PURPOSE
-- -------
-- Import the public Synthea sample dataset (April 2020 CSV export,
-- ~1,170 fully synthetic patients) into the synthea schema.
--
-- DE-IDENTIFICATION OF SYNTHETIC NAMES
-- ------------------------------------
-- Synthea patients and clinicians are fictional, but Synthea assigns
-- encounters to REAL facility names and addresses taken from public
-- directories. Because every utilization number in this project is
-- synthetic, ranking real facilities would be misleading. Organization
-- and provider names are therefore replaced with stable pseudonyms,
-- and street address / phone fields are dropped at import.
--
-- Paths are relative to the repository root (run_pipeline.py sets it).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS synthea;

CREATE OR REPLACE TABLE synthea.patients AS
SELECT * EXCLUDE (SSN, DRIVERS, PASSPORT, PREFIX, FIRST, LAST, SUFFIX, MAIDEN, ADDRESS)
FROM read_csv('data/raw/synthea/csv/patients.csv', header = true, sample_size = -1);

CREATE OR REPLACE TABLE synthea.encounters AS
SELECT * FROM read_csv('data/raw/synthea/csv/encounters.csv', header = true, sample_size = -1);

CREATE OR REPLACE TABLE synthea.conditions AS
SELECT * FROM read_csv('data/raw/synthea/csv/conditions.csv', header = true, sample_size = -1);

CREATE OR REPLACE TABLE synthea.procedures AS
SELECT * FROM read_csv('data/raw/synthea/csv/procedures.csv', header = true, sample_size = -1);

CREATE OR REPLACE TABLE synthea.observations AS
SELECT * FROM read_csv('data/raw/synthea/csv/observations.csv', header = true, sample_size = -1);

CREATE OR REPLACE TABLE synthea.medications AS
SELECT * FROM read_csv('data/raw/synthea/csv/medications.csv', header = true, sample_size = -1);

-- Payers: government programs keep their program names; the six
-- commercial insurers Synthea names after real companies are relabeled
-- "Commercial plan A-F" (stable alphabetical order of the source ID).
CREATE OR REPLACE TABLE synthea.payers AS
WITH src AS (
    SELECT * FROM read_csv('data/raw/synthea/csv/payers.csv', header = true, sample_size = -1)
)
SELECT * REPLACE (
    CASE
        WHEN NAME IN ('Medicare', 'Medicaid', 'Dual Eligible', 'NO_INSURANCE') THEN NAME
        ELSE 'Commercial plan ' || CHR(64 + CAST(ROW_NUMBER() OVER (
                 PARTITION BY NAME IN ('Medicare', 'Medicaid', 'Dual Eligible', 'NO_INSURANCE')
                 ORDER BY Id) AS INTEGER))
    END AS NAME,
    CAST(NULL AS VARCHAR) AS ADDRESS,
    CAST(NULL AS VARCHAR) AS PHONE
)
FROM src;

CREATE OR REPLACE TABLE synthea.payer_transitions AS
SELECT * FROM read_csv('data/raw/synthea/csv/payer_transitions.csv', header = true, sample_size = -1);

-- Organizations: pseudonymous name, city/state/ZIP kept for geography.
CREATE OR REPLACE TABLE synthea.organizations AS
SELECT
    Id,
    'Organization ' || LPAD(CAST(ROW_NUMBER() OVER (ORDER BY Id) AS VARCHAR), 4, '0') AS NAME,
    CAST(NULL AS VARCHAR) AS ADDRESS,
    CITY, STATE, ZIP, LAT, LON,
    CAST(NULL AS VARCHAR) AS PHONE,
    REVENUE, UTILIZATION
FROM read_csv('data/raw/synthea/csv/organizations.csv', header = true, sample_size = -1);

-- Providers: pseudonymous name; specialty and organization link kept.
CREATE OR REPLACE TABLE synthea.providers AS
SELECT
    Id, ORGANIZATION,
    'Provider ' || LPAD(CAST(ROW_NUMBER() OVER (ORDER BY Id) AS VARCHAR), 5, '0') AS NAME,
    GENDER, SPECIALITY,
    CAST(NULL AS VARCHAR) AS ADDRESS,
    CITY, STATE, ZIP, LAT, LON, UTILIZATION
FROM read_csv('data/raw/synthea/csv/providers.csv', header = true, sample_size = -1);

-- Import validation: expected counts for the April 2020 sample.
SELECT
    (SELECT COUNT(*) FROM synthea.patients)          AS patients,
    (SELECT COUNT(*) FROM synthea.encounters)        AS encounters,
    (SELECT COUNT(*) FROM synthea.conditions)        AS conditions,
    (SELECT COUNT(*) FROM synthea.observations)      AS observations,
    (SELECT COUNT(*) FROM synthea.organizations)     AS organizations,
    (SELECT COUNT(*) FROM synthea.providers)         AS providers,
    CASE WHEN (SELECT COUNT(*) FROM synthea.patients) = 1171
          AND (SELECT COUNT(*) FROM synthea.encounters) = 53346
          AND (SELECT COUNT(DISTINCT Id) FROM synthea.encounters) = 53346
         THEN 'PASS' ELSE 'REVIEW' END AS import_status;
