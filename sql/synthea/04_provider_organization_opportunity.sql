DESCRIBE synthea.encounters;
DESCRIBE synthea.providers;
DESCRIBE synthea.organizations;


-- ============================================================
-- a04_provider_organization_opportunity.sql
-- Business question:
-- Which organizations and providers concentrate the greatest
-- number of synthetic patients with potential need for an
-- iron-status diagnostic?
--
-- Important:
-- * Synthea is synthetic, not production claims data.
-- * "Target-condition encounters" are encounters linked to one
--   of the selected target-condition codes.
-- * "All encounters for target patients" includes every encounter
--   in those patients' synthetic histories.
-- * Financial fields are retained only as synthetic QA fields and
--   are not used to rank provider opportunities.
-- ============================================================

-- @block 1. Confirm schemas
CREATE SCHEMA IF NOT EXISTS reference;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS mart;

SELECT
    current_database() AS database_name,
    current_schema() AS active_schema,
    version() AS duckdb_version;

-- @block 2. Create reusable target-condition reference map
-- Grain: one row per selected Synthea condition code
CREATE OR REPLACE TABLE reference.synthea_target_condition_map AS
SELECT *
FROM (
    VALUES
        (271737000::BIGINT, 'Anemia diagnosis (not iron-specific)', 'Relevant diagnosis; anemia etiology unspecified', 1),
        (72892002::BIGINT, 'Pregnancy-related risk', 'Clinical risk population', 2),
        (79586000::BIGINT, 'Pregnancy-related risk', 'Clinical risk population', 2),
        (19169002::BIGINT, 'Pregnancy-related risk', 'Clinical risk population', 2),
        (156073000::BIGINT, 'Pregnancy-related risk', 'Clinical risk population', 2),
        (198992004::BIGINT, 'Pregnancy-related risk', 'Clinical risk population', 2),
        (398254007::BIGINT, 'Pregnancy-related risk', 'Clinical risk population', 2),
        (35999006::BIGINT, 'Pregnancy-related risk', 'Clinical risk population', 2),
        (127013003::BIGINT, 'Kidney or renal disease risk', 'Clinical risk population', 3),
        (431855005::BIGINT, 'Kidney or renal disease risk', 'Clinical risk population', 3),
        (431856006::BIGINT, 'Kidney or renal disease risk', 'Clinical risk population', 3),
        (90781000119102::BIGINT, 'Kidney or renal disease risk', 'Clinical risk population', 3),
        (88805009::BIGINT, 'Congestive heart failure', 'Clinical risk population', 4)
) AS mapped_conditions (
    condition_code,
    risk_segment,
    evidence_category,
    priority_order
);

-- @block 3. Validate map
SELECT
    COUNT(*) AS mapped_code_rows,
    COUNT(DISTINCT condition_code) AS unique_mapped_codes,
    COUNT(*) - COUNT(DISTINCT condition_code) AS duplicate_mapped_codes,
    COUNT(DISTINCT risk_segment) AS risk_segments
FROM reference.synthea_target_condition_map;

-- @block 4. Validate source grains
SELECT
    'encounters' AS table_name,
    COUNT(*) AS row_count,
    COUNT(DISTINCT "Id") AS distinct_ids,
    COUNT(*) - COUNT(DISTINCT "Id") AS duplicate_ids,
    COUNT_IF("Id" IS NULL) AS missing_ids
FROM synthea.encounters
UNION ALL
SELECT
    'providers', COUNT(*), COUNT(DISTINCT "Id"),
    COUNT(*) - COUNT(DISTINCT "Id"), COUNT_IF("Id" IS NULL)
FROM synthea.providers
UNION ALL
SELECT
    'organizations', COUNT(*), COUNT(DISTINCT "Id"),
    COUNT(*) - COUNT(DISTINCT "Id"), COUNT_IF("Id" IS NULL)
FROM synthea.organizations;

-- @block 5. Validate encounter joins
SELECT
    COUNT(*) AS encounter_rows,
    COUNT_IF(e.PATIENT IS NULL) AS missing_patient_ids,
    COUNT_IF(e.PROVIDER IS NULL) AS missing_provider_ids,
    COUNT_IF(e.PROVIDER IS NOT NULL AND p."Id" IS NULL) AS unmatched_provider_ids,
    COUNT_IF(e.ORGANIZATION IS NULL) AS missing_organization_ids,
    COUNT_IF(e.ORGANIZATION IS NOT NULL AND o."Id" IS NULL) AS unmatched_organization_ids,
    COUNT_IF(
        p."Id" IS NOT NULL
        AND p.ORGANIZATION IS NOT NULL
        AND e.ORGANIZATION IS NOT NULL
        AND p.ORGANIZATION <> e.ORGANIZATION
    ) AS provider_encounter_organization_mismatches
FROM synthea.encounters AS e
LEFT JOIN synthea.providers AS p
    ON e.PROVIDER = p."Id"
LEFT JOIN synthea.organizations AS o
    ON e.ORGANIZATION = o."Id";

-- @block 6. Create target encounter mart
-- Grain: one row per encounter for a target patient
CREATE OR REPLACE TABLE analytics.synthea_target_encounter_mart AS
WITH target_condition_by_encounter AS (
    SELECT
        c.ENCOUNTER AS encounter_id,
        COUNT(*) AS mapped_condition_records,
        COUNT(DISTINCT m.risk_segment) AS mapped_risk_segments_on_encounter,
        MAX(CASE WHEN m.risk_segment = 'Anemia diagnosis (not iron-specific)' THEN 1 ELSE 0 END)
            AS anemia_condition_on_encounter_flag,
        MAX(CASE WHEN m.risk_segment = 'Pregnancy-related risk' THEN 1 ELSE 0 END)
            AS pregnancy_condition_on_encounter_flag,
        MAX(CASE WHEN m.risk_segment = 'Kidney or renal disease risk' THEN 1 ELSE 0 END)
            AS kidney_condition_on_encounter_flag,
        MAX(CASE WHEN m.risk_segment = 'Congestive heart failure' THEN 1 ELSE 0 END)
            AS heart_failure_condition_on_encounter_flag
    FROM synthea.conditions AS c
    INNER JOIN reference.synthea_target_condition_map AS m
        ON c.CODE = m.condition_code
    WHERE c.ENCOUNTER IS NOT NULL
    GROUP BY c.ENCOUNTER
)
SELECT
    e."Id" AS encounter_id,
    e.START AS encounter_start,
    e.STOP AS encounter_stop,
    CAST(DATE_TRUNC('month', e.START) AS DATE) AS service_month,
    CAST(e.START AS DATE) AS service_date,
    e.PATIENT AS patient_id,

    rf.gender,
    rf.race,
    rf.ethnicity,
    rf.state AS patient_state,
    rf.county AS patient_county,
    rf.anemia_diagnosis_flag,
    rf.pregnancy_related_flag,
    rf.kidney_renal_risk_flag,
    rf.heart_failure_flag,
    rf.risk_flag_count,

    tc.priority_risk_segment,
    tc.evidence_category,

    e.ORGANIZATION AS organization_id,
    COALESCE(o.NAME, 'Unknown organization') AS organization_name,
    COALESCE(o.CITY, 'Unknown') AS organization_city,
    COALESCE(o.STATE, 'Unknown') AS organization_state,
    o.ZIP AS organization_zip,

    e.PROVIDER AS provider_id,
    COALESCE(p.NAME, 'Unknown provider') AS provider_name,
    COALESCE(NULLIF(TRIM(p.SPECIALITY), ''), 'Unknown specialty') AS provider_specialty,
    p.ORGANIZATION AS provider_affiliated_organization_id,

    CASE
        WHEN p.ORGANIZATION IS NOT NULL
         AND e.ORGANIZATION IS NOT NULL
         AND p.ORGANIZATION <> e.ORGANIZATION
            THEN 1
        ELSE 0
    END AS provider_organization_mismatch_flag,

    e.PAYER AS payer_id,
    COALESCE(NULLIF(TRIM(e.ENCOUNTERCLASS), ''), 'Unknown') AS encounter_class,
    e.CODE AS encounter_code,
    e.DESCRIPTION AS encounter_description,

    CASE WHEN tbe.encounter_id IS NOT NULL THEN 1 ELSE 0 END
        AS target_condition_encounter_flag,
    COALESCE(tbe.mapped_condition_records, 0) AS mapped_condition_records,
    COALESCE(tbe.mapped_risk_segments_on_encounter, 0) AS mapped_risk_segments_on_encounter,
    COALESCE(tbe.anemia_condition_on_encounter_flag, 0) AS anemia_condition_on_encounter_flag,
    COALESCE(tbe.pregnancy_condition_on_encounter_flag, 0) AS pregnancy_condition_on_encounter_flag,
    COALESCE(tbe.kidney_condition_on_encounter_flag, 0) AS kidney_condition_on_encounter_flag,
    COALESCE(tbe.heart_failure_condition_on_encounter_flag, 0) AS heart_failure_condition_on_encounter_flag,

    e.BASE_ENCOUNTER_COST AS synthea_base_encounter_cost,
    e.TOTAL_CLAIM_COST AS synthea_total_claim_cost,
    e.PAYER_COVERAGE AS synthea_payer_coverage

FROM synthea.encounters AS e
INNER JOIN analytics.synthea_patient_risk_flags AS rf
    ON e.PATIENT = rf.patient_id
   AND rf.risk_flag_count > 0
LEFT JOIN analytics.synthea_target_cohort AS tc
    ON e.PATIENT = tc.patient_id
LEFT JOIN synthea.organizations AS o
    ON e.ORGANIZATION = o."Id"
LEFT JOIN synthea.providers AS p
    ON e.PROVIDER = p."Id"
LEFT JOIN target_condition_by_encounter AS tbe
    ON e."Id" = tbe.encounter_id;

-- @block 7. Validate target encounter mart
SELECT
    COUNT(*) AS mart_rows,
    COUNT(DISTINCT encounter_id) AS unique_encounters,
    COUNT(*) - COUNT(DISTINCT encounter_id) AS duplicate_encounter_rows,
    COUNT(DISTINCT patient_id) AS unique_target_patients,
    COUNT_IF(target_condition_encounter_flag = 1) AS target_condition_encounters,
    COUNT_IF(provider_id IS NULL) AS missing_provider_ids,
    COUNT_IF(organization_id IS NULL) AS missing_organization_ids,
    SUM(provider_organization_mismatch_flag) AS provider_organization_mismatch_rows
FROM analytics.synthea_target_encounter_mart;

-- @block 8. Reconcile target patient count
SELECT
    (SELECT COUNT(DISTINCT patient_id)
     FROM analytics.synthea_target_encounter_mart) AS target_patients_with_encounters,
    (SELECT COUNT(DISTINCT patient_id)
     FROM analytics.synthea_patient_risk_flags
     WHERE risk_flag_count > 0) AS expected_target_patients,
    (SELECT COUNT(DISTINCT patient_id)
     FROM analytics.synthea_patient_risk_flags
     WHERE risk_flag_count > 0)
    -
    (SELECT COUNT(DISTINCT patient_id)
     FROM analytics.synthea_target_encounter_mart) AS target_patients_without_encounters;

-- @block 9. Create organization opportunity mart
-- Grain: one row per encounter organization
CREATE OR REPLACE TABLE mart.organization_opportunity AS
WITH patient_organization AS (
    SELECT
        organization_id,
        organization_name,
        organization_city,
        organization_state,
        patient_id,
        COUNT(DISTINCT encounter_id) AS patient_encounters_at_organization,
        COUNT(DISTINCT CASE WHEN target_condition_encounter_flag = 1 THEN encounter_id END)
            AS patient_target_condition_encounters,
        MAX(anemia_diagnosis_flag) AS anemia_diagnosis_flag,
        MAX(pregnancy_related_flag) AS pregnancy_related_flag,
        MAX(kidney_renal_risk_flag) AS kidney_renal_risk_flag,
        MAX(heart_failure_flag) AS heart_failure_flag
    FROM analytics.synthea_target_encounter_mart
    GROUP BY
        organization_id,
        organization_name,
        organization_city,
        organization_state,
        patient_id
),
organization_patient_summary AS (
    SELECT
        organization_id,
        organization_name,
        organization_city,
        organization_state,
        COUNT(DISTINCT patient_id) AS unique_target_patients,
        SUM(patient_encounters_at_organization) AS all_encounters_for_target_patients,
        SUM(patient_target_condition_encounters) AS target_condition_encounters,
        COUNT_IF(patient_encounters_at_organization >= 2) AS repeat_target_patients,
        COUNT(DISTINCT CASE WHEN anemia_diagnosis_flag = 1 THEN patient_id END)
            AS anemia_segment_patients,
        COUNT(DISTINCT CASE WHEN pregnancy_related_flag = 1 THEN patient_id END)
            AS pregnancy_segment_patients,
        COUNT(DISTINCT CASE WHEN kidney_renal_risk_flag = 1 THEN patient_id END)
            AS kidney_segment_patients,
        COUNT(DISTINCT CASE WHEN heart_failure_flag = 1 THEN patient_id END)
            AS heart_failure_segment_patients
    FROM patient_organization
    GROUP BY
        organization_id,
        organization_name,
        organization_city,
        organization_state
),
organization_encounter_summary AS (
    SELECT
        organization_id,
        COUNT(DISTINCT provider_id) AS distinct_providers,
        COUNT(DISTINCT service_month) AS active_service_months,
        MIN(service_date) AS first_service_date,
        MAX(service_date) AS latest_service_date,
        COUNT_IF(LOWER(encounter_class) = 'ambulatory') AS ambulatory_encounters,
        COUNT_IF(LOWER(encounter_class) = 'outpatient') AS outpatient_encounters,
        COUNT_IF(LOWER(encounter_class) = 'inpatient') AS inpatient_encounters,
        COUNT_IF(LOWER(encounter_class) = 'emergency') AS emergency_encounters,
        ROUND(SUM(synthea_total_claim_cost), 2) AS synthea_total_claim_cost,
        ROUND(SUM(synthea_payer_coverage), 2) AS synthea_payer_coverage
    FROM analytics.synthea_target_encounter_mart
    GROUP BY organization_id
),
combined AS (
    SELECT
        p.organization_id,
        p.organization_name,
        p.organization_city,
        p.organization_state,
        p.unique_target_patients,
        p.all_encounters_for_target_patients,
        p.target_condition_encounters,
        p.repeat_target_patients,
        ROUND(
            100.0 * p.repeat_target_patients
            / NULLIF(p.unique_target_patients, 0),
            2
        ) AS repeat_target_patient_pct,
        p.anemia_segment_patients,
        p.pregnancy_segment_patients,
        p.kidney_segment_patients,
        p.heart_failure_segment_patients,
        e.distinct_providers,
        e.active_service_months,
        e.first_service_date,
        e.latest_service_date,
        e.ambulatory_encounters,
        e.outpatient_encounters,
        e.inpatient_encounters,
        e.emergency_encounters,
        e.synthea_total_claim_cost,
        e.synthea_payer_coverage
    FROM organization_patient_summary AS p
    LEFT JOIN organization_encounter_summary AS e
        ON p.organization_id = e.organization_id
)
SELECT
    *,
    ROUND(
        100.0 * unique_target_patients
        / NULLIF(SUM(unique_target_patients) OVER (), 0),
        2
    ) AS organization_patient_membership_share_pct,
    DENSE_RANK() OVER (
        ORDER BY unique_target_patients DESC
    ) AS organization_opportunity_rank
FROM combined;

-- @block 10. Validate organization mart
SELECT
    COUNT(*) AS organization_rows,
    COUNT(DISTINCT organization_id) AS unique_organization_ids,
    COUNT(*) - COUNT(DISTINCT organization_id) AS duplicate_organization_rows,
    SUM(unique_target_patients) AS summed_organization_patient_memberships,
    (SELECT COUNT(DISTINCT patient_id)
     FROM analytics.synthea_target_encounter_mart) AS unique_target_patients_overall
FROM mart.organization_opportunity;

-- @block 11. Preview top organizations
SELECT
    organization_opportunity_rank,
    organization_name,
    organization_city,
    organization_state,
    unique_target_patients,
    target_condition_encounters,
    all_encounters_for_target_patients,
    repeat_target_patient_pct,
    distinct_providers,
    anemia_segment_patients,
    pregnancy_segment_patients,
    kidney_segment_patients,
    heart_failure_segment_patients
FROM mart.organization_opportunity
ORDER BY organization_opportunity_rank, organization_name
LIMIT 20;

-- @block 12. Create provider opportunity mart
-- Grain: one row per provider within encounter organization
CREATE OR REPLACE TABLE mart.provider_opportunity AS
WITH patient_provider AS (
    SELECT
        organization_id,
        organization_name,
        organization_city,
        organization_state,
        provider_id,
        provider_name,
        provider_specialty,
        patient_id,
        COUNT(DISTINCT encounter_id) AS patient_encounters_with_provider,
        COUNT(DISTINCT CASE WHEN target_condition_encounter_flag = 1 THEN encounter_id END)
            AS patient_target_condition_encounters,
        MAX(anemia_diagnosis_flag) AS anemia_diagnosis_flag,
        MAX(pregnancy_related_flag) AS pregnancy_related_flag,
        MAX(kidney_renal_risk_flag) AS kidney_renal_risk_flag,
        MAX(heart_failure_flag) AS heart_failure_flag
    FROM analytics.synthea_target_encounter_mart
    GROUP BY
        organization_id,
        organization_name,
        organization_city,
        organization_state,
        provider_id,
        provider_name,
        provider_specialty,
        patient_id
),
provider_summary AS (
    SELECT
        organization_id,
        organization_name,
        organization_city,
        organization_state,
        provider_id,
        provider_name,
        provider_specialty,
        COUNT(DISTINCT patient_id) AS unique_target_patients,
        SUM(patient_encounters_with_provider) AS all_encounters_for_target_patients,
        SUM(patient_target_condition_encounters) AS target_condition_encounters,
        COUNT_IF(patient_encounters_with_provider >= 2) AS repeat_target_patients,
        COUNT(DISTINCT CASE WHEN anemia_diagnosis_flag = 1 THEN patient_id END)
            AS anemia_segment_patients,
        COUNT(DISTINCT CASE WHEN pregnancy_related_flag = 1 THEN patient_id END)
            AS pregnancy_segment_patients,
        COUNT(DISTINCT CASE WHEN kidney_renal_risk_flag = 1 THEN patient_id END)
            AS kidney_segment_patients,
        COUNT(DISTINCT CASE WHEN heart_failure_flag = 1 THEN patient_id END)
            AS heart_failure_segment_patients
    FROM patient_provider
    GROUP BY
        organization_id,
        organization_name,
        organization_city,
        organization_state,
        provider_id,
        provider_name,
        provider_specialty
),
provider_with_org_total AS (
    SELECT
        p.*,
        o.unique_target_patients AS organization_unique_target_patients
    FROM provider_summary AS p
    LEFT JOIN mart.organization_opportunity AS o
        ON p.organization_id = o.organization_id
)
SELECT
    *,
    ROUND(
        100.0 * repeat_target_patients
        / NULLIF(unique_target_patients, 0),
        2
    ) AS repeat_target_patient_pct,
    ROUND(
        100.0 * unique_target_patients
        / NULLIF(organization_unique_target_patients, 0),
        2
    ) AS provider_share_of_organization_target_patients_pct,
    DENSE_RANK() OVER (
        PARTITION BY organization_id
        ORDER BY unique_target_patients DESC
    ) AS provider_rank_within_organization,
    DENSE_RANK() OVER (
        ORDER BY unique_target_patients DESC
    ) AS provider_opportunity_rank_overall
FROM provider_with_org_total;

-- @block 13. Validate provider mart
SELECT
    COUNT(*) AS provider_rows,
    COUNT(DISTINCT CONCAT_WS('|', COALESCE(organization_id, 'NULL'), COALESCE(provider_id, 'NULL')))
        AS unique_organization_provider_keys,
    COUNT(*)
        - COUNT(DISTINCT CONCAT_WS('|', COALESCE(organization_id, 'NULL'), COALESCE(provider_id, 'NULL')))
        AS duplicate_organization_provider_rows,
    COUNT_IF(provider_id IS NULL) AS missing_provider_rows
FROM mart.provider_opportunity;

-- @block 14. Preview top providers
SELECT
    provider_opportunity_rank_overall,
    organization_name,
    provider_name,
    provider_specialty,
    unique_target_patients,
    target_condition_encounters,
    all_encounters_for_target_patients,
    repeat_target_patient_pct,
    provider_rank_within_organization,
    anemia_segment_patients,
    pregnancy_segment_patients,
    kidney_segment_patients,
    heart_failure_segment_patients
FROM mart.provider_opportunity
ORDER BY
    provider_opportunity_rank_overall,
    organization_name,
    provider_name
LIMIT 25;

-- @block 15. Create city-level market mart
-- Grain: one row per organization city and state
CREATE OR REPLACE TABLE mart.target_market_by_city AS
WITH patient_city AS (
    SELECT
        organization_state,
        organization_city,
        patient_id,
        COUNT(DISTINCT encounter_id) AS patient_encounters_in_city,
        COUNT(DISTINCT CASE WHEN target_condition_encounter_flag = 1 THEN encounter_id END)
            AS patient_target_condition_encounters_in_city
    FROM analytics.synthea_target_encounter_mart
    GROUP BY organization_state, organization_city, patient_id
)
SELECT
    organization_state,
    organization_city,
    COUNT(DISTINCT patient_id) AS unique_target_patients,
    SUM(patient_encounters_in_city) AS all_encounters_for_target_patients,
    SUM(patient_target_condition_encounters_in_city) AS target_condition_encounters,
    COUNT_IF(patient_encounters_in_city >= 2) AS repeat_target_patients,
    ROUND(
        100.0 * COUNT_IF(patient_encounters_in_city >= 2)
        / NULLIF(COUNT(DISTINCT patient_id), 0),
        2
    ) AS repeat_target_patient_pct,
    DENSE_RANK() OVER (
        ORDER BY COUNT(DISTINCT patient_id) DESC
    ) AS city_opportunity_rank
FROM patient_city
GROUP BY organization_state, organization_city;

-- @block 16. Validate and preview city mart
SELECT
    COUNT(*) AS city_rows,
    COUNT(DISTINCT organization_state) AS represented_states,
    SUM(unique_target_patients) AS summed_city_patient_memberships
FROM mart.target_market_by_city;

SELECT *
FROM mart.target_market_by_city
ORDER BY city_opportunity_rank, organization_city
LIMIT 20;

-- @block 17. Export Tableau organization table
COPY mart.organization_opportunity
TO 'outputs/marts/organization_opportunity.csv'
WITH (HEADER true, DELIMITER ',');

-- @block 18. Export Tableau provider table
COPY mart.provider_opportunity
TO 'outputs/marts/provider_opportunity.csv'
WITH (HEADER true, DELIMITER ',');

-- @block 19. Export Tableau city table
COPY mart.target_market_by_city
TO 'outputs/marts/target_market_by_city.csv'
WITH (HEADER true, DELIMITER ',');

